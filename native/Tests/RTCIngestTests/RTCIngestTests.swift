import Foundation
import RTCCLI
import RTCContracts
import RTCGit
@_spi(Testing) import RTCIngest
import RTCIPC
import RTCLifecycle
import RTCStore

@main
struct RTCIngestTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-state/i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStore(rootURL: root)
        let records = SQLiteIngestRepository(store: store)
        let reviews = SQLiteReviewRepository(store: store)
        let jobs = JobQueue(store: store)
        let git = FakeGit()
        let notifications = RecordingNotifications()
        let coordinator = SubmissionCoordinator(
            git: git,
            records: records,
            reviews: reviews,
            jobs: jobs,
            notifications: notifications
        )

        let base = String(repeating: "a", count: 40)
        let firstHead = String(repeating: "b", count: 40)
        let secondHead = String(repeating: "c", count: 40)
        await git.set(ref: "main", sha: base)
        await git.set(ref: "feature", sha: firstHead)

        let first = ReviewSubmission(
            idempotencyKey: UUID(),
            repositoryPath: "/tmp/example-repository",
            base: SubmittedRef(label: "main", expectedSHA: base),
            head: SubmittedRef(label: "feature", expectedSHA: firstHead),
            title: "First exact review"
        )
        let receipt = try await coordinator.submit(first)
        await coordinator.runUntilIdle()
        check(receipt.disposition == .created, "first submission created")
        let firstStatus = try await coordinator.status(receipt.reviewID)
        let firstReview = try await reviews.review(id: receipt.reviewID)
        let firstNotificationCount = await notifications.count
        check(firstStatus.status == .ready, "first review ready")
        check(firstReview?.files.count == 1, "bounded evidence persisted")
        check(firstNotificationCount == 1, "ready notification sent once")

        let duplicate = ReviewSubmission(
            idempotencyKey: UUID(),
            repositoryPath: first.repositoryPath,
            base: first.base,
            head: first.head,
            title: first.title
        )
        let resumed = try await coordinator.submit(duplicate)
        await coordinator.runUntilIdle()
        check(resumed.reviewID == receipt.reviewID && resumed.disposition == .resumed, "same revision resumes")
        let resumedNotificationCount = await notifications.count
        check(resumedNotificationCount == 1, "resume does not duplicate notification")

        await git.set(ref: "feature", sha: secondHead)
        try await coordinator.refreshStaleness()
        let staleStatus = try await coordinator.status(receipt.reviewID)
        check(staleStatus.stale, "moved submitted ref marks exact review stale")

        let replacement = ReviewSubmission(
            repositoryPath: first.repositoryPath,
            base: SubmittedRef(label: "main", expectedSHA: base),
            head: SubmittedRef(label: "feature", expectedSHA: secondHead),
            title: "Replacement exact review"
        )
        let replacementReceipt = try await coordinator.submit(replacement)
        await coordinator.runUntilIdle()
        let supersededStatus = try await coordinator.status(receipt.reviewID)
        let replacementStatus = try await coordinator.status(replacementReceipt.reviewID)
        check(supersededStatus.status == .superseded, "new head supersedes old review")
        check(replacementStatus.status == .ready, "replacement ready")

        let failingHead = String(repeating: "d", count: 40)
        await git.set(ref: "oversized", sha: failingHead)
        await git.setFailure(.patchLimit)
        let failing = try await coordinator.submit(ReviewSubmission(
            repositoryPath: first.repositoryPath,
            base: SubmittedRef(label: "main", expectedSHA: base),
            head: SubmittedRef(label: "oversized", expectedSHA: failingHead),
            title: "Oversized review"
        ))
        await coordinator.runUntilIdle()
        let failed = try await coordinator.status(failing.reviewID)
        check(failed.status == .failed && failed.errorCode == "LIMIT_EXCEEDED", "bounded failure is durable")
        await git.setFailure(nil)
        try await coordinator.retry(failing.reviewID)
        await coordinator.runUntilIdle()
        let retried = try await coordinator.status(failing.reviewID)
        check(retried.status == .ready, "failed job retries idempotently")

        let rollbackRoot = root.appendingPathComponent("b", isDirectory: true)
        let rollbackStore = try SQLiteStore(rootURL: rollbackRoot)
        let stableRecords = SQLiteIngestRepository(store: rollbackStore)
        let stableRevision = try RevisionIdentity(repositoryPath: "/tmp/rollback", baseSHA: base, headSHA: firstHead)
        let stableSubmission = ReviewSubmission(
            repositoryPath: stableRevision.repositoryPath,
            base: SubmittedRef(label: base, expectedSHA: base),
            head: SubmittedRef(label: firstHead, expectedSHA: firstHead),
            title: "Stable review"
        )
        _ = try await stableRecords.accept(stableSubmission, revision: stableRevision)
        let failingRecords = SQLiteIngestRepository(store: rollbackStore) { throw AtomicityProbe.injected }
        let rolledBackRevision = try RevisionIdentity(repositoryPath: "/tmp/rollback", baseSHA: base, headSHA: secondHead)
        let rolledBackSubmission = ReviewSubmission(
            repositoryPath: rolledBackRevision.repositoryPath,
            base: SubmittedRef(label: base, expectedSHA: base),
            head: SubmittedRef(label: secondHead, expectedSHA: secondHead),
            title: "Must roll back"
        )
        do {
            _ = try await failingRecords.accept(rolledBackSubmission, revision: rolledBackRevision)
            preconditionFailure("atomicity probe must throw")
        } catch AtomicityProbe.injected {}
        let afterRollback = try await stableRecords.reviews()
        check(afterRollback.count == 1, "failed accept rolls back new review and idempotency")
        check(afterRollback[0].status == .accepted && afterRollback[0].supersededBy == nil, "failed accept rolls back supersession")
        let acceptedAfterRollback = try await stableRecords.accept(rolledBackSubmission, revision: rolledBackRevision)
        check(acceptedAfterRollback.1 == .created, "rolled-back idempotency key remains reusable")

        try await checkOfflineCLI(root: root)

        print("RTC ingest checks passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

    static func checkOfflineCLI(root: URL) async throws {
        let repository = root.appendingPathComponent("r", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(repository, ["init", "--quiet"])
        let source = repository.appendingPathComponent("example.txt")
        try Data("committed base\n".utf8).write(to: source)
        try runGit(repository, ["add", "--", "example.txt"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "base"])
        let base = try gitOutput(repository, ["rev-parse", "HEAD"])
        try Data("committed head\n".utf8).write(to: source)
        try runGit(repository, ["add", "--", "example.txt"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "head"])
        let head = try gitOutput(repository, ["rev-parse", "HEAD"])
        try Data("dirty working tree must not appear\n".utf8).write(to: source)
        let directlyResolved = try await ExactGitEngine().resolveRevision(
            repositoryPath: repository.path,
            base: base,
            head: head
        )
        check(directlyResolved.baseSHA == base && directlyResolved.headSHA == head, "real Git resolver pins submitted refs")

        let paths = RTCInstallationPaths(root: root.appendingPathComponent("s", isDirectory: true))
        _ = try paths.prepare(createCapability: true)
        let executor = RTCCLIExecutor(paths: paths, activator: NoopAppActivator(), retryDuration: .milliseconds(1))
        do {
            _ = try await executor.run(.submit(
                repo: repository.path,
                base: base,
                head: head,
                metadata: nil,
                tour: nil,
                wakeFile: nil,
                notify: true,
                json: true
            ))
            preconditionFailure("offline CLI must report unavailable")
        } catch let error as RTCCLIError {
            guard case let .remote(wire) = error, wire.code == "APP_UNAVAILABLE" else { throw error }
        }
        let queued = try FileManager.default.contentsOfDirectory(at: paths.spool, includingPropertiesForKeys: nil)
        check(queued.filter { $0.pathExtension == "spool" }.count == 1, "offline CLI durably spools submission")

        let presenter = RecordingPresenter()
        let runtime = try await RTCIngestRuntime(paths: paths, notificationPresenter: presenter)
        try await runtime.start()
        defer { runtime.stop() }
        await runtime.coordinator.runUntilIdle()
        let materializedRecords = try await runtime.records.reviews()
        check(materializedRecords.count == 1, "app ingests one spooled submission")
        guard let record = materializedRecords.first else { return }
        let status = try await runtime.coordinator.status(record.reviewID)
        let evidence = try await runtime.reviewRepository.review(id: record.reviewID)
        check(record.revision.baseSHA == base && record.revision.headSHA == head, "app resolves exact full SHAs")
        check(status.status == .ready, "spooled submission materializes after app launch")
        check(evidence?.files.count == 1, "real Git evidence persisted")
        let evidenceText = evidence?.files.flatMap(\.hunks).flatMap(\.lines).map(\.text).joined(separator: "\n") ?? ""
        check(!evidenceText.contains("dirty working tree"), "materialization excludes working tree")
        let notificationCount = await presenter.count
        check(notificationCount == 1, "spooled review notifies once when ready")

        let statusJSON = try await executor.run(.status(review: record.reviewID.value, json: true))
        let decodedStatus = try JSONDecoder().decode(ReviewStatusResponse.self, from: Data(statusJSON.utf8))
        check(decodedStatus.reviewID == record.reviewID && decodedStatus.status == .ready, "status IPC returns exact review")
        let pollJSON = try await executor.run(.poll(
            review: record.reviewID.value,
            after: 0,
            timeoutMilliseconds: 1,
            full: false,
            json: true,
            conversation: false
        ))
        let decodedPoll = try JSONDecoder().decode(ReviewStatusResponse.self, from: Data(pollJSON.utf8))
        check(decodedPoll.reviewID == record.reviewID && decodedPoll.cursor > 0, "poll IPC returns durable cursor")

        let unauthorized = try IPCClient(socketPath: paths.socket.path).send(IPCEnvelope(
            operation: "status",
            capability: "wrong-capability",
            body: try RTCCanonicalJSON.encode(ReviewLookup(reviewID: record.reviewID))
        ))
        check(!unauthorized.ok && unauthorized.error?.code == "UNAUTHORIZED", "IPC capability remains enforced")
        let closeJSON = try await executor.run(.close(review: record.reviewID.value, json: true))
        let closed = try JSONDecoder().decode(ReviewStatusResponse.self, from: Data(closeJSON.utf8))
        check(closed.status == .closed && closed.reviewID == record.reviewID, "close IPC targets exact review")
    }

    static func runGit(_ repository: URL, _ arguments: [String]) throws {
        _ = try git(repository, arguments)
    }

    static func gitOutput(_ repository: URL, _ arguments: [String]) throws -> String {
        String(decoding: try git(repository, arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func git(_ repository: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitEngineError.gitFailed }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}

private enum AtomicityProbe: Error { case injected }

private actor FakeGit: IngestGitService {
    private var refs = [String: String]()
    private var failure: GitEngineError?

    func set(ref: String, sha: String) { refs[ref] = sha }
    func setFailure(_ failure: GitEngineError?) { self.failure = failure }

    func resolveRevision(repositoryPath: String, base: String, head: String) async throws -> RevisionIdentity {
        guard let baseSHA = refs[base] ?? full(base), let headSHA = refs[head] ?? full(head) else {
            throw GitEngineError.invalidRef
        }
        return try RevisionIdentity(repositoryPath: repositoryPath, baseSHA: baseSHA, headSHA: headSHA)
    }

    func materialize(_ revision: RevisionIdentity) async throws -> ReviewManifest {
        if let failure { throw failure }
        let file = DiffArtifact(
            path: "Sources/Feature.swift",
            status: .modified,
            additions: 1,
            deletions: 0,
            binary: false,
            truncated: false,
            hunks: []
        )
        return ReviewManifest(
            id: revision.reviewID,
            revision: revision,
            createdAt: Date(),
            updatedAt: Date(),
            status: .ready,
            stale: false,
            summary: ReviewSummary(files: 1, additions: 1, deletions: 0),
            files: [file]
        )
    }

    func context(_ request: GitContextRequest) async throws -> GitContext { throw GitEngineError.invalidPath }
    func verifyCurrentHead(_ revision: RevisionIdentity) async throws -> Bool { true }
    func cancel(_ cancellation: GitCancellation) async {}

    private func full(_ value: String) -> String? {
        value.count == 40 && value.allSatisfy(\.isHexDigit) ? value : nil
    }
}

private actor RecordingNotifications: NotificationService {
    private(set) var ids = [ReviewID]()
    var count: Int { ids.count }
    func notify(reviewID: ReviewID, generic: Bool) async throws {
        if !ids.contains(reviewID) { ids.append(reviewID) }
    }
}

private actor RecordingPresenter: NotificationPresenter {
    private var requests = [NotificationRequestData]()
    var count: Int { requests.count }
    func authorization() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> NotificationAuthorization { .authorized }
    func present(_ request: NotificationRequestData) async throws { requests.append(request) }
    func setBadge(_ value: Int) async {}
}
