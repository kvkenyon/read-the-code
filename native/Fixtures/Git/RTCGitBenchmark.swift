import Darwin
import Foundation
import RTCContracts
import RTCGit

private let referenceBudgetMilliseconds = 2_000.0
private let maximumProcessesPerIteration = 110

private actor MeasuringRunner: GitBatchProcessRunning {
    private let system = SystemGitProcessRunner()
    private var counts: [String: Int] = [:]

    func run(repository: String, arguments: [String], environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        try await measured(arguments) {
            try await system.run(repository: repository, arguments: arguments, environment: environment, outputLimit: outputLimit, timeout: timeout)
        }
    }

    func runBatch(repository: String, arguments: [String], standardInput: Data, environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        try await measured(arguments) {
            try await system.runBatch(repository: repository, arguments: arguments, standardInput: standardInput, environment: environment, outputLimit: outputLimit, timeout: timeout)
        }
    }

    private func measured(_ arguments: [String], operation: () async throws -> GitProcessResult) async throws -> GitProcessResult {
        let command = arguments.first == "-c" ? arguments.dropFirst(2).first ?? "unknown" : arguments.first ?? "unknown"
        let result = try await operation()
        counts[command, default: 0] += 1
        return result
    }

    func snapshot() -> [String: Int] { counts }
}

@main
private enum RTCGitBenchmark {
    static func main() async throws {
        let warmups = integerEnvironment("RTC_GIT_BENCHMARK_WARMUPS", default: 2)
        let iterations = integerEnvironment("RTC_GIT_BENCHMARK_ITERATIONS", default: 20)
        let fixture = try RepresentativeFixture()
        defer { fixture.remove() }

        let runner = MeasuringRunner()
        let engine = ExactGitEngine(runner: runner)
        let revision = try await engine.resolveRevision(repositoryPath: fixture.repository.path, base: fixture.base, head: fixture.head)
        for _ in 0..<warmups { _ = try await engine.materialize(revision) }
        let countsBefore = await runner.snapshot()

        var samples: [Double] = []
        for _ in 0..<iterations {
            let started = ContinuousClock.now
            let manifest = try await engine.materialize(revision)
            precondition(manifest.files.count == 101)
            samples.append(milliseconds(started.duration(to: .now)))
        }
        let countsAfter = await runner.snapshot()
        let measuredCounts = Dictionary(uniqueKeysWithValues: countsAfter.map { key, value in
            (key, value - (countsBefore[key] ?? 0))
        })
        let processCount = measuredCounts.values.reduce(0, +)
        let processRegressionPassed = processCount <= maximumProcessesPerIteration * iterations

        let sorted = samples.sorted()
        let p50 = percentile(0.50, sorted)
        let p95 = percentile(0.95, sorted)
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count)
        let chip = sysctl("machdep.cpu.brand_string")
        let memoryBytes = Int64(sysctl("hw.memsize")) ?? 0
        let referenceHardwareMatched = chip.contains("Apple M1") && memoryBytes == 16 * 1_024 * 1_024 * 1_024
        let explicitlyEnforced = ProcessInfo.processInfo.environment["RTC_GIT_ENFORCE_REFERENCE_BUDGET"] == "1"
        let wallBudgetEnforced = referenceHardwareMatched || explicitlyEnforced
        let wallBudgetPassed = !wallBudgetEnforced || p95 <= referenceBudgetMilliseconds

        let output: [String: Any] = [
            "schemaVersion": 1,
            "workload": ["changedFiles": 101, "largeFileChangedLines": 5_000],
            "measurementBoundary": "resolved exact revision through materialized diff artifacts",
            "buildMode": "release (-O)",
            "warmups": warmups,
            "iterations": iterations,
            "samplesMs": samples,
            "p50Ms": p50,
            "p95Ms": p95,
            "meanMs": mean,
            "varianceMs2": variance,
            "processCounts": measuredCounts,
            "machine": [
                "chip": chip,
                "memoryBytes": memoryBytes,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
            ],
            "gate": [
                "referenceHardware": "baseline Apple M1 with 16 GiB RAM",
                "referenceP95BudgetMs": referenceBudgetMilliseconds,
                "referenceHardwareMatched": referenceHardwareMatched,
                "wallBudgetEnforced": wallBudgetEnforced,
                "wallBudgetPassed": wallBudgetPassed,
                "maximumProcessesPerIteration": maximumProcessesPerIteration,
                "processRegressionPassed": processRegressionPassed,
            ],
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        if !processRegressionPassed || !wallBudgetPassed { exit(1) }
    }

    private static func integerEnvironment(_ name: String, default defaultValue: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name], let value = Int(raw), value > 0 else { return defaultValue }
        return value
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func percentile(_ value: Double, _ sorted: [Double]) -> Double {
        sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * value)) - 1)]
    }

    private static func sysctl(_ name: String) -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", name]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return "unknown" }
        guard process.terminationStatus == 0 else { return "unknown" }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class RepresentativeFixture {
    let repository: URL
    let base: String
    let head: String

    init() throws {
        repository = FileManager.default.temporaryDirectory.appendingPathComponent("RTCGitBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
        do {
            try Self.git(repository, ["init", "-q", "--initial-branch=main"])
            let deep = (0..<20).reduce(repository) { partial, index in
                partial.appendingPathComponent("level-\(String(format: "%02d", index))", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try Self.writeFiles(repository: repository, in: deep, increment: 0)
            try Self.git(repository, ["add", "--all"])
            try Self.git(repository, ["-c", "user.name=Read the Code Performance Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "representative base"])
            base = try Self.git(repository, ["rev-parse", "HEAD"])
            try Self.writeFiles(repository: repository, in: deep, increment: 1)
            try Self.git(repository, ["add", "--all"])
            try Self.git(repository, ["-c", "user.name=Read the Code Performance Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "representative head"])
            head = try Self.git(repository, ["rev-parse", "HEAD"])
        } catch {
            try? FileManager.default.removeItem(at: repository)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: repository) }

    private static func writeFiles(repository: URL, in deep: URL, increment: Int) throws {
        for index in 0..<100 {
            let path = deep.appendingPathComponent("component-with-a-stable-long-name-\(String(format: "%04d", index)).ts")
            try Data("export const value\(index) = \(index + increment);\n".utf8).write(to: path)
        }
        let lines = (0..<5_000).map { "export const line\($0) = \($0 + increment);" }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: repository.appendingPathComponent("large-diff.ts"))
    }

    @discardableResult
    private static func git(_ repository: URL, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: SystemGitProcessRunner.executable)
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = output
        process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RTCGitBenchmark", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
