import Foundation
import RTCContracts

public enum GitEngineError: Error, Equatable, Sendable {
    case invalidRepository
    case invalidRef
    case invalidPath
    case gitFailed
    case timedOut
    case cancelled
    case outputLimit
    case tooManyFiles
    case patchLimit
    case invalidDiff
}

public struct GitProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.status = status
    }
}

public protocol GitProcessRunning: Sendable {
    func run(repository: String, arguments: [String], environment: [String: String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult
}

public extension GitProcessRunning {
    func run(repository: String, arguments: [String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        try await run(repository: repository, arguments: arguments, environment: [:], outputLimit: outputLimit, timeout: timeout)
    }
}

private final class ProcessBox: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    func set(_ process: Process) { lock.lock(); self.process = process; lock.unlock() }
    func terminate() { lock.lock(); process?.terminate(); lock.unlock() }
}

public struct SystemGitProcessRunner: GitProcessRunning {
    public static let executable = "/usr/bin/git"
    public init() {}

    public func run(repository: String, arguments: [String], environment: [String: String] = [:], outputLimit: Int = RTCConstants.maxPatchBytesTotal + 128_000, timeout: Duration = .seconds(30)) async throws -> GitProcessResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.executable)
                process.arguments = ["-C", repository] + arguments
                var policyEnvironment = [
                    "PATH": "/usr/bin:/bin",
                    "HOME": "/var/empty",
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_SYSTEM": "/dev/null",
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_ATTR_NOSYSTEM": "1",
                    "GIT_NO_REPLACE_OBJECTS": "1",
                    "GIT_OPTIONAL_LOCKS": "0",
                ]
                if let attributesSource = environment["GIT_ATTR_SOURCE"] { policyEnvironment["GIT_ATTR_SOURCE"] = attributesSource }
                process.environment = policyEnvironment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out; process.standardError = err
                box.set(process)
                let state = OutputState(limit: outputLimit, continuation: continuation, process: process)
                out.fileHandleForReading.readabilityHandler = { state.append($0.availableData, to: .stdout) }
                err.fileHandleForReading.readabilityHandler = { state.append($0.availableData, to: .stderr) }
                process.terminationHandler = { _ in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    state.finish(stdout: out.fileHandleForReading.readDataToEndOfFile(), stderr: err.fileHandleForReading.readDataToEndOfFile(), status: process.terminationStatus)
                }
                do { try process.run() } catch { state.fail(GitEngineError.gitFailed) }
                Task {
                    do { try await Task.sleep(for: timeout); if !Task.isCancelled { state.timeout(); box.terminate() } }
                    catch { }
                }
            }
        }, onCancel: { box.terminate() })
    }
}

private final class OutputState: @unchecked Sendable {
    enum Stream { case stdout, stderr }
    let lock = NSLock(); let limit: Int; let continuation: CheckedContinuation<GitProcessResult, Error>; let process: Process
    var stdout = Data(), stderr = Data(), completed = false, timedOut = false
    init(limit: Int, continuation: CheckedContinuation<GitProcessResult, Error>, process: Process) { self.limit=limit; self.continuation=continuation; self.process=process }
    func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }; lock.lock(); defer { lock.unlock() }; guard !completed else { return }
        if stream == .stdout { stdout.append(data) } else { stderr.append(data) }
        if stdout.count + stderr.count > limit { completed=true; process.terminate(); continuation.resume(throwing: GitEngineError.outputLimit) }
    }
    func timeout() { lock.lock(); defer { lock.unlock() }; guard !completed else { return }; timedOut=true }
    func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; guard !completed else { return }; completed = true; continuation.resume(throwing: error) }
    func finish(stdout: Data, stderr: Data, status: Int32) {
        lock.lock(); defer { lock.unlock() }; guard !completed else { return }; completed=true
        self.stdout.append(stdout)
        self.stderr.append(stderr)
        if timedOut { continuation.resume(throwing: GitEngineError.timedOut) }
        else if self.stdout.count + self.stderr.count > limit { continuation.resume(throwing: GitEngineError.outputLimit) }
        else if status != 0 { continuation.resume(throwing: GitEngineError.gitFailed) }
        else { continuation.resume(returning: GitProcessResult(stdout: self.stdout, stderr: self.stderr, status: status)) }
    }
}

public actor ExactGitEngine: GitService {
    private let runner: any GitProcessRunning
    private var cancellationRequested = false
    public init(runner: any GitProcessRunning = SystemGitProcessRunner()) { self.runner = runner }

    public struct ResolvedSubmission: Codable, Hashable, Sendable {
        public let revision: RevisionIdentity
        public let repositoryIdentity: SHA256Digest
        public init(revision: RevisionIdentity, repositoryIdentity: SHA256Digest) {
            self.revision = revision
            self.repositoryIdentity = repositoryIdentity
        }
    }

    /// Resolves labels before durable delivery and captures the repository object-store identity.
    public func resolveSubmission(repositoryPath: String, base: String, head: String) async throws -> ResolvedSubmission {
        let repository = try await resolveRepository(repositoryPath)
        let baseSHA = try await resolveCommit(repository, base)
        let headSHA = try await resolveCommit(repository, head)
        let revision = try RevisionIdentity(repositoryPath: repository, baseSHA: baseSHA, headSHA: headSHA)
        return ResolvedSubmission(revision: revision, repositoryIdentity: try await repositoryIdentity(repository))
    }

    public func resolveRevision(repositoryPath: String, base: String, head: String) async throws -> RevisionIdentity {
        try await resolveSubmission(repositoryPath: repositoryPath, base: base, head: head).revision
    }

    public func materialize(_ revision: RevisionIdentity) async throws -> ReviewManifest {
        try await materialize(revision, repositoryIdentity: nil)
    }

    public func materialize(_ revision: RevisionIdentity, repositoryIdentity expectedIdentity: SHA256Digest?) async throws -> ReviewManifest {
        cancellationRequested = false
        let repository = try await resolveRepository(revision.repositoryPath)
        guard repository == revision.repositoryPath else { throw GitEngineError.invalidRepository }
        if let expectedIdentity, try await repositoryIdentity(repository) != expectedIdentity { throw GitEngineError.invalidRepository }
        let base = try await resolveCommit(repository, revision.baseSHA)
        let head = try await resolveCommit(repository, revision.headSHA)
        guard base == revision.baseSHA.lowercased(), head == revision.headSHA.lowercased() else { throw GitEngineError.invalidRef }
        let names = try await nameStatus(repository, base: base, head: head)
        guard names.count <= RTCConstants.maxFiles else { throw GitEngineError.tooManyFiles }
        var files = [DiffArtifact](); var totalPatch = 0
        for change in names {
            try checkCancellation()
            let oldPath = change.oldPath ?? change.path
            let oldSize = change.status == .added ? 0 : try await blobSize(repository, sha: base, path: oldPath)
            let newSize = change.status == .deleted ? 0 : try await blobSize(repository, sha: head, path: change.path)
            let stats = try await numstat(repository, base: base, head: head, paths: [oldPath, change.path])
            let truncated = max(oldSize, newSize) > RTCConstants.maxPatchBytesPerFile
            if truncated || stats.binary {
                let oldLines = oldSize > RTCConstants.maxPatchBytesPerFile ? nil : try await lineCount(repository, sha: base, path: change.status == .added ? nil : oldPath)
                let newLines = newSize > RTCConstants.maxPatchBytesPerFile ? nil : try await lineCount(repository, sha: head, path: change.status == .deleted ? nil : change.path)
                files.append(DiffArtifact(path: change.path, oldPath: change.oldPath, status: stats.binary ? .binary : change.status, additions: stats.additions, deletions: stats.deletions, binary: stats.binary, truncated: truncated, oldLineCount: oldLines, newLineCount: newLines, hunks: [])); continue
            }
            let patch = try await run(repository, ["-c", "core.quotePath=true", "diff", "--find-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=4", base, head, "--", oldPath, change.path], limit: RTCConstants.maxPatchBytesPerFile + 100_000, attributesSource: head)
            totalPatch += patch.count; guard totalPatch <= RTCConstants.maxPatchBytesTotal else { throw GitEngineError.patchLimit }
            let hunks = try parsePatch(String(decoding: patch, as: UTF8.self), path: change.path)
            files.append(DiffArtifact(path: change.path, oldPath: change.oldPath, status: change.status, additions: stats.additions, deletions: stats.deletions, binary: false, truncated: false, oldLineCount: try await lineCount(repository, sha: base, path: change.status == .added ? nil : oldPath), newLineCount: try await lineCount(repository, sha: head, path: change.status == .deleted ? nil : change.path), hunks: hunks))
        }
        let summary = ReviewSummary(files: files.count, additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
        return ReviewManifest(id: revision.reviewID, revision: revision, createdAt: Date(), updatedAt: Date(), status: .ready, stale: false, summary: summary, files: files)
    }

    public func context(_ request: GitContextRequest) async throws -> GitContext {
        try checkCancellation()
        let repo = try await resolveRepository(request.revision.repositoryPath)
        let manifest = try await materialize(request.revision)
        guard let file = manifest.files.first(where: { $0.path == request.path }), request.hunkIndex >= 0, request.hunkIndex < file.hunks.count, !file.binary, !file.truncated else { throw GitEngineError.invalidPath }
        let hunk = file.hunks[request.hunkIndex], old = try await blobLines(repo, sha: request.revision.baseSHA, path: file.oldPath ?? file.path), new = try await blobLines(repo, sha: request.revision.headSHA, path: file.path)
        let previous = request.position == .before ? file.hunks[..<request.hunkIndex].last : nil
        let next = request.position == .after && request.hunkIndex + 1 < file.hunks.count ? file.hunks[request.hunkIndex + 1] : nil
        let oldStart = request.position == .before ? (previous.map { $0.oldStart + $0.oldLines } ?? 1) : hunk.oldStart + hunk.oldLines
        let newStart = request.position == .before ? (previous.map { $0.newStart + $0.newLines } ?? 1) : hunk.newStart + hunk.newLines
        let oldEnd = request.position == .before ? hunk.oldStart - 1 : (next?.oldStart ?? old.count)
        let newEnd = request.position == .before ? hunk.newStart - 1 : (next?.newStart ?? new.count)
        let total = max(0, max(oldEnd - oldStart + 1, newEnd - newStart + 1)), count = min(request.lineCount, total), offset = request.position == .before ? total - count : 0
        let lines = (0..<count).map { index -> DiffLine in
            let logical = offset + index, oi = logical - max(0, total - (oldEnd - oldStart + 1)), ni = logical - max(0, total - (newEnd - newStart + 1)), ol = oi >= 0 && oi < oldEnd - oldStart + 1 ? oldStart + oi : nil, nl = ni >= 0 && ni < newEnd - newStart + 1 ? newStart + ni : nil, text = nl.map { new[$0 - 1] } ?? ol.map { old[$0 - 1] } ?? ""
            return DiffLine(kind: .context, oldLine: ol, newLine: nl, text: text, contextHash: contextHash(path: request.path, kind: .context, old: ol, new: nl, text: text, nearby: []))
        }
        return GitContext(path: request.path, hunkIndex: request.hunkIndex, lines: lines)
    }

    public func verifyCurrentHead(_ revision: RevisionIdentity) async throws -> Bool { (try? await resolveCommit(revision.repositoryPath, revision.headSHA)) == revision.headSHA.lowercased() }
    public func cancel(_ cancellation: GitCancellation) async { cancellationRequested = cancellation.requested }

    private func checkCancellation() throws { if cancellationRequested || Task.isCancelled { throw GitEngineError.cancelled } }

    private func run(_ repo: String, _ args: [String], limit: Int = RTCConstants.maxPatchBytesTotal + 128_000, attributesSource: String? = nil) async throws -> Data {
        let environment = attributesSource.map { ["GIT_ATTR_SOURCE": $0] } ?? [:]
        return try await runner.run(repository: repo, arguments: args, environment: environment, outputLimit: limit, timeout: .seconds(30)).stdout
    }
    private func resolveRepository(_ path: String) async throws -> String {
        do {
            let value = try await run(path, ["rev-parse", "--show-toplevel"], limit: 4_096)
            let root = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !root.isEmpty else { throw GitEngineError.invalidRepository }
            return URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        } catch GitEngineError.gitFailed { throw GitEngineError.invalidRepository }
    }
    private func repositoryIdentity(_ repository: String) async throws -> SHA256Digest {
        let value = try await run(repository, ["rev-parse", "--git-common-dir"], limit: 4_096)
        let raw = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw GitEngineError.invalidRepository }
        let url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: repository, isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw GitEngineError.invalidRepository }
        return SHA256Digest(data: Data("\(url.path)\0\(device.uint64Value)\0\(inode.uint64Value)".utf8))
    }
    private func resolveCommit(_ repo: String, _ ref: String) async throws -> String {
        guard !ref.isEmpty, !ref.hasPrefix("-"), ref.utf8.count <= 512,
              !ref.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw GitEngineError.invalidRef }
        do {
            let value = try await run(repo, ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], limit: 4_096)
            let sha = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard sha.count == 40 || sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw GitEngineError.invalidRef }
            return sha
        } catch GitEngineError.gitFailed { throw GitEngineError.invalidRef }
    }
    private struct Change { let status: ChangeStatus; let path: String; let oldPath: String? }
    private func nameStatus(_ repo: String, base: String, head: String) async throws -> [Change] { let data = try await run(repo, ["diff", "--name-status", "-z", "--find-renames", "--no-ext-diff", "--no-textconv", base, head, "--"], limit: 2 * 1024 * 1024, attributesSource: head); let f = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init); var result=[Change](); var i=0; while i < f.count { let code=f[i]; i += 1; guard i < f.count else { throw GitEngineError.invalidDiff }; if code.first == "R" || code.first == "C" { guard i + 1 < f.count else { throw GitEngineError.invalidDiff }; result.append(Change(status: .renamed, path: f[i+1], oldPath: f[i])); i += 2 } else { let status: ChangeStatus = code.first == "A" ? .added : code.first == "D" ? .deleted : .modified; result.append(Change(status: status, path: f[i], oldPath: nil)); i += 1 } }; return result }
    private struct Stats { let additions: Int; let deletions: Int; let binary: Bool }
    private func numstat(_ repo: String, base: String, head: String, paths: [String]) async throws -> Stats { let d=try await run(repo,["diff","--numstat","-z","--find-renames","--no-ext-diff","--no-textconv",base,head,"--"]+paths,limit:4096,attributesSource:head); let p=String(decoding:d,as:UTF8.self).split(separator:"\t",omittingEmptySubsequences:false); guard p.count >= 2 else { return Stats(additions: 0, deletions: 0, binary: false) }; return Stats(additions: Int(p[0]) ?? 0, deletions: Int(p[1]) ?? 0, binary: p[0] == "-" || p[1] == "-") }
    private func blobSize(_ repo: String, sha: String, path: String) async throws -> Int { Int(String(decoding: try await run(repo,["cat-file","-s","\(sha):\(path)"],limit:1024),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) ?? 0 }
    private func lineCount(_ repo: String, sha: String, path: String?) async throws -> Int? { guard let path else { return nil }; let d=try await run(repo,["cat-file","blob","\(sha):\(path)"],limit:RTCConstants.maxPatchBytesPerFile+1); guard d.count <= RTCConstants.maxPatchBytesPerFile else { return nil }; let s=String(decoding:d,as:UTF8.self); return s.isEmpty ? 0 : s.split(separator:"\n",omittingEmptySubsequences:false).count - (s.hasSuffix("\n") ? 1 : 0) }
    private func blobLines(_ repo: String, sha: String, path: String) async throws -> [String] { let d=try await run(repo,["cat-file","blob","\(sha):\(path)"],limit:RTCConstants.maxPatchBytesPerFile+1); var lines=String(decoding:d,as:UTF8.self).components(separatedBy:"\n"); if lines.last == "" { lines.removeLast() }; return lines }
}

private func contextHash(path: String, kind: DiffLineKind, old: Int?, new: Int?, text: String, nearby: [String]) -> SHA256Digest {
    let encoded = [path, kind.rawValue, old.map(String.init) ?? "null", new.map(String.init) ?? "null", text, nearby.joined(separator: "\u{1f}")].joined(separator: "\u{0}")
    return SHA256Digest(data: Data(encoded.utf8))
}

private func parsePatch(_ patch: String, path: String) throws -> [DiffHunk] {
    if patch.contains("Binary files") || patch.contains("GIT binary patch") { return [] }
    var result=[DiffHunk](), lines=patch.split(separator:"\n",omittingEmptySubsequences:false).map(String.init), index=0
    while index < lines.count { guard lines[index].hasPrefix("@@ ") else { index += 1; continue }; let header=lines[index]; let parts=header.split(separator:" "); guard parts.count >= 3 else { throw GitEngineError.invalidDiff }; var old=parseRange(String(parts[1])), new=parseRange(String(parts[2])); var diff=[DiffLine](); index += 1; while index < lines.count && !lines[index].hasPrefix("@@ ") && !lines[index].hasPrefix("diff --git ") { let raw=lines[index]; if raw == "\\ No newline at end of file" { index += 1; continue }; let kind: DiffLineKind = raw.first == "+" ? .addition : raw.first == "-" ? .deletion : .context; let text=raw.first.map { (_: Character) in String(raw.dropFirst()) } ?? raw; let oldLine=kind == .addition ? nil : old.next; let newLine=kind == .deletion ? nil : new.next; diff.append(DiffLine(kind:kind,oldLine:oldLine,newLine:newLine,text:text,contextHash:contextHash(path:path,kind:kind,old:oldLine,new:newLine,text:text,nearby:[]))); if kind != .addition { old.advance() }; if kind != .deletion { new.advance() }; index += 1 }; result.append(DiffHunk(header:(try? BoundedString(header)) ?? "@@",oldStart:old.start,oldLines:old.count,newStart:new.start,newLines:new.count,lines:diff)) }; return result
}

private struct DiffRange { let start: Int; let count: Int; var cursor: Int; var next: Int { cursor }; mutating func advance() { cursor += 1 } }
private func parseRange(_ value: String) -> DiffRange { let v=value.dropFirst(), p=v.split(separator:","); let start=Int(p[0]) ?? 0, count=p.count > 1 ? Int(p[1]) ?? 0 : 1; return DiffRange(start:start,count:count,cursor:start) }
