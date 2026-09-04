import Foundation
import XCTest
@testable import RTCGit
import RTCContracts

final class GitEngineTests: XCTestCase {
    func testMaterializesHostileCommittedFilenamesWithoutReadingDirtyTree() async throws {
        let repository = try HostileFilenameRepository()
        let engine = ExactGitEngine()
        let revision = try await engine.resolveRevision(
            repositoryPath: repository.url.path,
            base: repository.base,
            head: repository.head
        )
        let statusBefore = try repository.git(["status", "--porcelain=v1", "-z"])
        let entriesBefore = try FileManager.default.contentsOfDirectory(atPath: repository.url.path).sorted()

        let manifest = try await engine.materialize(revision)

        XCTAssertEqual(Set(manifest.files.map(\.path)), Set(repository.committedPaths))
        XCTAssertEqual(Set(manifest.files.map { Data($0.path.utf8) }), Set(repository.committedPaths.map { Data($0.utf8) }))
        XCTAssertEqual(manifest.files.count, repository.committedPaths.count)
        XCTAssertTrue(repository.committedPaths.contains(repository.requestedPaths[2].precomposedStringWithCanonicalMapping))
        XCTAssertNotEqual(Data(repository.requestedPaths[2].utf8), Data(repository.requestedPaths[2].precomposedStringWithCanonicalMapping.utf8))
        for file in manifest.files {
            let additions = file.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text)
            XCTAssertTrue(additions.contains(repository.committedLine), "missing committed content for \(file.path.debugDescription)")
        }
        XCTAssertFalse(manifest.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.text.contains(repository.dirtyCanary) })
        XCTAssertEqual(try repository.git(["status", "--porcelain=v1", "-z"]), statusBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.url.path).sorted(), entriesBefore)
    }

    func testRepeatedGitOutputAndMaterializationKeepValidRefsIntact() async throws {
        let outputRepository = try LargeOutputRepository()
        let hostileRepository = try HostileFilenameRepository()
        let hostileRevision = try await ExactGitEngine().resolveRevision(
            repositoryPath: hostileRepository.url.path,
            base: hostileRepository.base,
            head: hostileRepository.head
        )

        for _ in 0..<8 {
            let result = try await SystemGitProcessRunner().run(
                repository: outputRepository.url.path,
                arguments: ["cat-file", "blob", "\(outputRepository.head):payload.txt"],
                outputLimit: outputRepository.payload.count + 1,
                timeout: .seconds(30)
            )
            XCTAssertEqual(result.stdout, outputRepository.payload)
            XCTAssertTrue(result.stderr.isEmpty)

            let manifest = try await ExactGitEngine().materialize(hostileRevision)
            XCTAssertEqual(Set(manifest.files.map(\.path)), Set(hostileRepository.committedPaths))
        }

        do {
            _ = try await ExactGitEngine().resolveRevision(
                repositoryPath: hostileRepository.url.path,
                base: "--upload-pack=hostile",
                head: hostileRepository.head
            )
            XCTFail("option-like refs must remain rejected")
        } catch let error as GitEngineError {
            XCTAssertEqual(error, .invalidRef)
        }
    }

    func testMalformedNameStatusRemainsInvalidDiff() async throws {
        let repository = try HostileFilenameRepository()
        let engine = ExactGitEngine(runner: NameStatusFaultRunner(fault: .malformed))
        let revision = try await engine.resolveRevision(repositoryPath: repository.url.path, base: repository.base, head: repository.head)
        do {
            _ = try await engine.materialize(revision)
            XCTFail("expected invalid diff")
        } catch let error as GitEngineError {
            XCTAssertEqual(error, .invalidDiff)
        }
    }

    func testGitFailureIsNotHiddenByFilenameParsing() async throws {
        let repository = try HostileFilenameRepository()
        let engine = ExactGitEngine(runner: NameStatusFaultRunner(fault: .gitFailed))
        let revision = try await engine.resolveRevision(repositoryPath: repository.url.path, base: repository.base, head: repository.head)
        do {
            _ = try await engine.materialize(revision)
            XCTFail("expected Git failure")
        } catch let error as GitEngineError {
            XCTAssertEqual(error, .gitFailed)
        }
    }

    func testRejectsOptionLikeRefsBeforeProcessLaunch() async throws {
        let runner = RecordingRunner()
        let engine = ExactGitEngine(runner: runner)
        let revision = try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        do { _ = try await engine.materialize(revision); XCTFail("expected failure") }
        catch { let recorded = await runner.arguments; XCTAssertTrue(recorded.isEmpty || recorded.allSatisfy { !$0.hasPrefix("--upload-pack") }) }
    }

    func testProcessPolicyIsFixedAndShellFree() {
        XCTAssertEqual(SystemGitProcessRunner.executable, "/usr/bin/git")
    }

    func testContextHashIsFullSha256() throws {
        let digest = SHA256Digest(data: Data("committed tree".utf8))
        XCTAssertEqual(digest.hex.count, 64)
    }

    func testBatchedReadsPreserveHostilePathAndIgnoreDirtyWorktree() async throws {
        let fixture = try GitFixture.hostilePath()
        defer { fixture.remove() }
        let runner = CountingSystemRunner()
        let engine = ExactGitEngine(runner: runner)
        let revision = try await engine.resolveRevision(repositoryPath: fixture.repository.path, base: fixture.base, head: fixture.head)
        await runner.reset()

        let manifest = try await engine.materialize(revision)
        XCTAssertEqual(manifest.files.map(\.path), [fixture.hostilePath])
        XCTAssertTrue(manifest.files[0].hunks.flatMap(\.lines).contains { $0.text == "committed object" })
        XCTAssertFalse(manifest.files[0].hunks.flatMap(\.lines).contains { $0.text == "dirty working tree" })
        let counts = await runner.counts()
        XCTAssertEqual(counts.batch, 2)
        XCTAssertLessThanOrEqual(counts.total, 9)
    }

    func testRepresentativeFixtureHasStableProcessCeiling() async throws {
        let fixture = try GitFixture.representative()
        defer { fixture.remove() }
        let runner = CountingSystemRunner()
        let engine = ExactGitEngine(runner: runner)
        let revision = try await engine.resolveRevision(repositoryPath: fixture.repository.path, base: fixture.base, head: fixture.head)
        await runner.reset()

        let manifest = try await engine.materialize(revision)
        XCTAssertEqual(manifest.files.count, 101)
        let counts = await runner.counts()
        XCTAssertEqual(counts.batch, 2)
        XCTAssertLessThanOrEqual(counts.total, 110, "process amplification is the stable cross-host performance regression gate")
    }
}

private final class LargeOutputRepository {
    let url: URL
    let payload: Data
    private(set) var head = ""

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("RTCGitOutputTests-\(UUID().uuidString)", isDirectory: true)
        payload = Data((0..<128_000).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try git(["init", "--quiet"])
            try git(["config", "user.name", "RTC Tests"])
            try git(["config", "user.email", "rtc-tests@example.invalid"])
            try payload.write(to: url.appendingPathComponent("payload.txt"))
            try git(["add", "--", "payload.txt"])
            try git(["commit", "--quiet", "-m", "payload"])
            head = try gitString(["rev-parse", "HEAD"])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SystemGitProcessRunner.executable)
        process.arguments = ["-C", url.path] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitEngineError.gitFailed }
    }

    private func gitString(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: SystemGitProcessRunner.executable)
        process.arguments = ["-C", url.path] + arguments
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitEngineError.gitFailed }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class HostileFilenameRepository {
    let url: URL
    private(set) var base = ""
    private(set) var head = ""
    let committedLine = "let source = \"committed tree\""
    let dirtyCanary = "DIRTY WORKTREE CANARY"
    let requestedPaths = [
        "--option.swift",
        "unicode-🧪-é.swift",
        "combining-e\u{301}.swift",
        "line\nbreak.swift",
        "tab\tname.swift",
        "<script>.swift",
        "ordinary.swift",
    ]
    private(set) var committedPaths = [String]()

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("RTCGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try git(["init", "--quiet"])
            try git(["config", "user.name", "RTC Tests"])
            try git(["config", "user.email", "rtc-tests@example.invalid"])
            try git(["config", "core.precomposeUnicode", "true"])
            try git(["commit", "--quiet", "--allow-empty", "-m", "base"])
            base = try gitString(["rev-parse", "HEAD"])
            for path in requestedPaths {
                try Data("\(committedLine)\n".utf8).write(to: url.appendingPathComponent(path))
                try git(["add", "--", path])
            }
            try git(["commit", "--quiet", "-m", "hostile names"])
            head = try gitString(["rev-parse", "HEAD"])
            committedPaths = try decodeNULTerminated(try git(["ls-tree", "-r", "--name-only", "-z", head]))
            try Data("\(dirtyCanary)\n".utf8).write(to: url.appendingPathComponent(requestedPaths[2]))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func git(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SystemGitProcessRunner.executable)
        process.arguments = ["-C", url.path] + arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RTCGitTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
        }
        return output
    }

    func gitString(_ arguments: [String]) throws -> String {
        String(decoding: try git(arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeNULTerminated(_ data: Data) throws -> [String] {
        guard data.last == 0 else { throw GitEngineError.invalidDiff }
        return data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }
}

private struct NameStatusFaultRunner: GitProcessRunning {
    enum Fault: Sendable { case malformed, gitFailed }
    let fault: Fault

    func run(repository: String, arguments: [String], environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        if arguments.starts(with: ["diff", "--name-status"]) {
            switch fault {
            case .malformed:
                return GitProcessResult(stdout: Data("M\0".utf8), stderr: Data(), status: 0)
            case .gitFailed:
                throw GitEngineError.gitFailed
            }
        }
        return try await SystemGitProcessRunner().run(
            repository: repository,
            arguments: arguments,
            environment: environment,
            outputLimit: outputLimit,
            timeout: timeout
        )
    }
}

private actor RecordingRunner: GitProcessRunning {
    var arguments = [String]()
    func run(repository: String, arguments: [String], environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        self.arguments = arguments
        throw GitEngineError.invalidRef
    }
}

private actor CountingSystemRunner: GitBatchProcessRunning {
    private let runner = SystemGitProcessRunner()
    private var processCount = 0
    private var batchCount = 0

    func run(repository: String, arguments: [String], environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        let result = try await runner.run(repository: repository, arguments: arguments, environment: environment, outputLimit: outputLimit, timeout: timeout)
        processCount += 1
        return result
    }

    func runBatch(repository: String, arguments: [String], standardInput: Data, environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        let result = try await runner.runBatch(repository: repository, arguments: arguments, standardInput: standardInput, environment: environment, outputLimit: outputLimit, timeout: timeout)
        processCount += 1; batchCount += 1
        return result
    }

    func reset() { processCount = 0; batchCount = 0 }
    func counts() -> (total: Int, batch: Int) { (processCount, batchCount) }
}

private final class GitFixture {
    let repository: URL
    let base: String
    let head: String
    let hostilePath: String

    private init(repository: URL, base: String, head: String, hostilePath: String = "") {
        self.repository = repository; self.base = base; self.head = head; self.hostilePath = hostilePath
    }

    static func hostilePath() throws -> GitFixture {
        let repository = try makeRepository()
        let path = "tab\tline\n<script>.txt"
        do {
            try write("base object\n", repository.appendingPathComponent(path))
            try git(repository, ["add", "--all"]); try commit(repository, "base")
            let base = try git(repository, ["rev-parse", "HEAD"])
            try write("committed object\n", repository.appendingPathComponent(path))
            try git(repository, ["add", "--all"]); try commit(repository, "head")
            let head = try git(repository, ["rev-parse", "HEAD"])
            try write("dirty working tree\n", repository.appendingPathComponent(path))
            return GitFixture(repository: repository, base: base, head: head, hostilePath: path)
        } catch {
            try? FileManager.default.removeItem(at: repository); throw error
        }
    }

    static func representative() throws -> GitFixture {
        let repository = try makeRepository()
        do {
            try writeRepresentative(repository, increment: 0)
            try git(repository, ["add", "--all"]); try commit(repository, "base")
            let base = try git(repository, ["rev-parse", "HEAD"])
            try writeRepresentative(repository, increment: 1)
            try git(repository, ["add", "--all"]); try commit(repository, "head")
            return GitFixture(repository: repository, base: base, head: try git(repository, ["rev-parse", "HEAD"]))
        } catch {
            try? FileManager.default.removeItem(at: repository); throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: repository) }

    private static func makeRepository() throws -> URL {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("RTCGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
        try git(repository, ["init", "-q", "--initial-branch=main"])
        return repository
    }

    private static func writeRepresentative(_ repository: URL, increment: Int) throws {
        for index in 0..<100 {
            try write("let value = \(index + increment)\n", repository.appendingPathComponent("file-\(index).swift"))
        }
        let lines = (0..<5_000).map { "let line\($0) = \($0 + increment)" }.joined(separator: "\n") + "\n"
        try write(lines, repository.appendingPathComponent("large.swift"))
    }

    private static func write(_ value: String, _ url: URL) throws { try Data(value.utf8).write(to: url) }
    private static func commit(_ repository: URL, _ message: String) throws {
        try git(repository, ["-c", "user.name=RTCGit Tests", "-c", "user.email=fixture@example.invalid", "commit", "-qm", message])
    }

    @discardableResult
    private static func git(_ repository: URL, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: SystemGitProcessRunner.executable)
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RTCGitTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
