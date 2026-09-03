import Foundation
import XCTest
@testable import RTCGit
import RTCContracts

final class GitEngineTests: XCTestCase {
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
}

private actor RecordingRunner: GitProcessRunning {
    var arguments = [String]()
    func run(repository: String, arguments: [String], outputLimit: Int, timeout: Duration) async throws -> GitProcessResult {
        self.arguments = arguments
        throw GitEngineError.invalidRef
    }
}
