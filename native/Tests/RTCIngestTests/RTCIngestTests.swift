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
        let git = FakeGit()
        let notifications = RecordingNotifications()
        let coordinator = SubmissionCoordinator(git: git, records: records, notifications: notifications)

        let base = String(repeating: "a", count: 40)
        let firstHead = String(repeating: "b", count: 40)
        let secondHead = String(repeating: "c", count: 40)
        await git.set(ref: "main", sha: base)
        await git.set(ref: "feature", sha: firstHead)

        let first = ReviewSubmission(
            idempotencyKey: UUID(),
            repositoryPath: "/tmp/example-repository",
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8)),
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
        let waiting = Task { try await coordinator.poll(ReviewLookup(reviewID: receipt.reviewID, after: firstStatus.cursor, timeoutMilliseconds: 500)) }
        try await Task.sleep(for: .milliseconds(10))
        try await coordinator.markRead(receipt.reviewID)
        let observed = try await waiting.value
        check(!observed.timedOut && observed.cursor > firstStatus.cursor, "concurrent long poll observes the next durable sequence")
        let evidenceAfterRead = try await reviews.review(id: receipt.reviewID)
        check(evidenceAfterRead?.files.count == 1, "non-evidence transitions preserve immutable evidence")

        let duplicate = ReviewSubmission(
            idempotencyKey: UUID(),
            repositoryPath: first.repositoryPath,
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8)),
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
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8)),
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
        await git.remove(ref: "feature")
        try await coordinator.refreshStaleness()
        let unavailable = try await records.review(replacementReceipt.reviewID)
        check(unavailable?.stale == false && unavailable?.refreshErrorCode == "REFRESH_UNAVAILABLE", "transient ref failure is distinct from stale")
        await git.set(ref: "feature", sha: secondHead)
        await git.set(ref: "main", sha: firstHead)
        try await coordinator.refreshStaleness()
        let baseMoved = try await coordinator.status(replacementReceipt.reviewID)
        check(baseMoved.stale, "successful base movement marks the exact review stale")
        await git.set(ref: "main", sha: base)

        let failingHead = String(repeating: "d", count: 40)
        await git.set(ref: "oversized", sha: failingHead)
        await git.setFailure(.patchLimit)
        let failing = try await coordinator.submit(ReviewSubmission(
            repositoryPath: first.repositoryPath,
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8)),
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
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8)),
            base: SubmittedRef(label: base, expectedSHA: base),
            head: SubmittedRef(label: firstHead, expectedSHA: firstHead),
            title: "Stable review"
        )
        _ = try await stableRecords.accept(stableSubmission, revision: stableRevision)
        let failingRecords = SQLiteIngestRepository(store: rollbackStore) { throw AtomicityProbe.injected }
        let rolledBackRevision = try RevisionIdentity(repositoryPath: "/tmp/rollback", baseSHA: base, headSHA: secondHead)
        let rolledBackSubmission = ReviewSubmission(
            repositoryPath: rolledBackRevision.repositoryPath,
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8)),
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

        let restartRoot = root.appendingPathComponent("restart", isDirectory: true)
        let restartStore = try SQLiteStore(rootURL: restartRoot)
        let restartRecords = SQLiteIngestRepository(store: restartStore)
        let restartRevision = try RevisionIdentity(repositoryPath: "/tmp/restart", baseSHA: base, headSHA: firstHead)
        let restartSubmission = ReviewSubmission(repositoryPath: restartRevision.repositoryPath, repositoryIdentity: SHA256Digest(data: Data("restart".utf8)), base: SubmittedRef(label: base, expectedSHA: base), head: SubmittedRef(label: firstHead, expectedSHA: firstHead), notify: false)
        _ = try await restartRecords.accept(restartSubmission, revision: restartRevision)
        let beforeRestart = try await restartRecords.close(restartRevision.reviewID)
        let reopenedStore = try SQLiteStore(rootURL: restartRoot)
        let reopenedRecords = SQLiteIngestRepository(store: reopenedStore)
        let reopened = try await reopenedRecords.review(restartRevision.reviewID)
        check(reopened?.changeSequence == beforeRestart.changeSequence, "change sequence survives store restart")
        let mismatched = ReviewManifest(id: restartRevision.reviewID, revision: restartRevision, createdAt: Date(), updatedAt: Date(), status: .ready, stale: false, summary: ReviewSummary(files: 0, additions: 0, deletions: 0), files: [])
        let reopenedReviews = SQLiteReviewRepository(store: reopenedStore)
        try await reopenedReviews.save(mismatched)
        try await reopenedRecords.reconcile()
        let reconciledManifest = try await reopenedReviews.review(id: restartRevision.reviewID)
        check(reconciledManifest?.status == .closed, "restart reconciliation repairs manifest from durable ingest state")

        let outboxStore = try SQLiteStore(rootURL: root.appendingPathComponent("outbox", isDirectory: true))
        let outbox = SQLiteIngestRepository(store: outboxStore)
        let outboxRevision = try RevisionIdentity(repositoryPath: "/tmp/outbox", baseSHA: base, headSHA: firstHead)
        let outboxSubmission = ReviewSubmission(repositoryPath: outboxRevision.repositoryPath, repositoryIdentity: SHA256Digest(data: Data("outbox".utf8)), base: SubmittedRef(label: base, expectedSHA: base), head: SubmittedRef(label: firstHead, expectedSHA: firstHead), notify: true)
        _ = try await outbox.accept(outboxSubmission, revision: outboxRevision)
        let ownerA: BoundedString = "owner-a", ownerB: BoundedString = "owner-b"
        guard let materialization = try await outbox.leaseMaterialization(owner: ownerA) else { preconditionFailure("materialization lease") }
        try await outbox.completeReady(materialization, evidence: try await git.materialize(outboxRevision))
        async let claimA = outbox.claimNotification(owner: ownerA)
        async let claimB = outbox.claimNotification(owner: ownerB)
        let (firstClaim, secondClaim) = try await (claimA, claimB)
        let claims = [firstClaim, secondClaim].compactMap { $0 }
        check(claims.count == 1, "notification outbox has a single CAS claimant")

        try await checkStalenessPagination(root: root, base: base, head: firstHead, movedBase: secondHead)
        try await checkEventTransactions(root: root, revision: restartRevision)
        try await checkOfflineCLI(root: root)
        try await checkGitSizeBoundaries(root: root)

        print("RTC ingest checks passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

    static func checkOfflineCLI(root: URL) async throws {
        let repository = root.appendingPathComponent("r", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(repository, ["init", "--quiet"])
        let source = repository.appendingPathComponent("example.txt")
        try Data("committed base\n".utf8).write(to: source)
        try Data("example.txt text\n".utf8).write(to: repository.appendingPathComponent(".gitattributes"))
        try runGit(repository, ["add", "--", "example.txt", ".gitattributes"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "base"])
        let base = try gitOutput(repository, ["rev-parse", "HEAD"])
        try runGit(repository, ["branch", "base-ref", base])
        try Data("committed head\n".utf8).write(to: source)
        try runGit(repository, ["add", "--", "example.txt"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "head"])
        let head = try gitOutput(repository, ["rev-parse", "HEAD"])
        try runGit(repository, ["branch", "head-ref", head])
        try Data("dirty working tree must not appear\n".utf8).write(to: source)
        try Data("example.txt binary\n".utf8).write(to: repository.appendingPathComponent(".gitattributes"))
        try Data("example.txt binary\n".utf8).write(to: repository.appendingPathComponent(".git/info/attributes"))
        let externalAttributes = root.appendingPathComponent("external-attributes")
        try Data("example.txt binary\n".utf8).write(to: externalAttributes)
        try runGit(repository, ["config", "core.attributesFile", externalAttributes.path])
        let engine = ExactGitEngine()
        let directlyResolved = try await engine.resolveSubmission(
            repositoryPath: repository.path,
            base: "base-ref",
            head: "head-ref"
        )
        check(directlyResolved.revision.baseSHA == base && directlyResolved.revision.headSHA == head, "real Git resolver pins submitted refs")
        let alias = root.appendingPathComponent("repository-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let aliasResolved = try await engine.resolveSubmission(repositoryPath: alias.path, base: "base-ref", head: "head-ref")
        check(aliasResolved.revision.repositoryPath == directlyResolved.revision.repositoryPath && aliasResolved.repositoryIdentity == directlyResolved.repositoryIdentity, "repository aliases canonicalize to one identity")

        let paths = RTCInstallationPaths(root: root.appendingPathComponent("s", isDirectory: true))
        let executor = RTCCLIExecutor(paths: paths, activator: ProvisioningActivator(paths: paths), retryDuration: .milliseconds(5))
        do {
            _ = try await executor.run(.submit(
                repo: repository.path,
                base: "base-ref",
                head: "head-ref",
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
        let capability = try paths.prepare(createCapability: false)
        check(capability.count == 64, "first activation securely provisions capability")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.capability.path)
        check((try? paths.prepare(createCapability: false)) == nil, "capability requires private mode")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.capability.path)

        let sentinel = paths.root.appendingPathComponent("sentinel")
        try Data("safe".utf8).write(to: sentinel)
        try Data("occupied".utf8).write(to: paths.spool.appendingPathComponent("hostile.rejected"))
        try FileManager.default.createSymbolicLink(at: paths.spool.appendingPathComponent("hostile.spool"), withDestinationURL: sentinel)
        let oversized = paths.spool.appendingPathComponent("oversized.spool")
        try Data(repeating: 0, count: IPCConstants.maxFrameBytes + 5).write(to: oversized)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.path)
        try Data("symbolic ref moved after durable acceptance\n".utf8).write(to: source)
        try runGit(repository, ["add", "--", "example.txt"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "moved"])
        let movedHead = try gitOutput(repository, ["rev-parse", "HEAD"])
        try runGit(repository, ["branch", "--force", "base-ref", head])
        try runGit(repository, ["branch", "--force", "head-ref", movedHead])
        try runGit(repository, ["replace", base, head])

        // Temporary CI probe for the security-pinned process path: both batch modes
        // must accept a NUL-delimited committed-object request and close within three
        // seconds. The status assertion below carries this evidence if materialization
        // still fails on a different host.
        let runner = SystemGitProcessRunner()
        let request = Data("\(head):example.txt\0".utf8)
        let gitVersion = try await runner.run(
            repository: repository.path,
            arguments: ["--version"],
            outputLimit: 1_024,
            timeout: .seconds(3)
        )
        let checkBatch = try await runner.runBatch(
            repository: repository.path,
            arguments: ["cat-file", "--batch-check=%(objecttype) %(objectsize)", "-Z"],
            standardInput: request,
            outputLimit: 1_024,
            timeout: .seconds(3)
        )
        let contentBatch = try await runner.runBatch(
            repository: repository.path,
            arguments: ["cat-file", "--batch=%(objecttype) %(objectsize)", "-Z"],
            standardInput: request,
            outputLimit: 1_024,
            timeout: .seconds(3)
        )
        check(checkBatch.stdout.starts(with: Data("blob ".utf8)) && contentBatch.stdout.last == 0, "pinned Git batch runner completes bounded requests")

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
        let version = String(decoding: gitVersion.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = "status=\(status.status.rawValue) code=\(status.errorCode ?? "none") message=\(status.errorMessage ?? "none") git=\(version)"
        check(status.status == .ready, "spooled submission materializes after app launch (\(failure))")
        check(evidence?.files.count == 1, "real Git evidence persisted")
        let evidenceText = evidence?.files.flatMap(\.hunks).flatMap(\.lines).map(\.text).joined(separator: "\n") ?? ""
        check(!evidenceText.contains("dirty working tree") && !evidenceText.contains("symbolic ref moved"), "materialization excludes working tree and moved labels")
        check(!(evidence?.files.first?.binary ?? true) && !(evidence?.files.first?.hunks.isEmpty ?? true), "committed attributes win over dirty attributes")
        let notificationCount = await presenter.count
        check(notificationCount == 1, "spooled review notifies once when ready")
        let permissionRequests = await presenter.permissionRequests
        check(permissionRequests == 0, "background runtime never requests notification permission")
        let sentinelValue = try String(contentsOf: sentinel, encoding: .utf8)
        check(sentinelValue == "safe", "spool symlink is never followed")
        let rejected = try FileManager.default.contentsOfDirectory(at: paths.spool, includingPropertiesForKeys: nil).filter { $0.pathExtension == "rejected" }
        check(rejected.count >= 3, "malformed spool files are quarantined without collision overwrite")

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
        let decodedPoll = try JSONDecoder().decode(ReviewPollResponse.self, from: Data(pollJSON.utf8))
        check(decodedPoll.reviewID == record.reviewID && decodedPoll.cursor > 0, "poll IPC returns durable cursor")
        let timeoutPoll = try await runtime.coordinator.poll(ReviewLookup(reviewID: record.reviewID, after: decodedPoll.cursor, timeoutMilliseconds: 5))
        check(timeoutPoll.timedOut && timeoutPoll.cursor == decodedPoll.cursor && timeoutPoll.changes.isEmpty, "poll timeout preserves cursor")
        do {
            _ = try await runtime.coordinator.poll(ReviewLookup(reviewID: record.reviewID, after: decodedPoll.cursor + 1))
            preconditionFailure("future cursor must fail")
        } catch IngestError.invalidSubmission {}

        let unauthorized = try IPCClient(socketPath: paths.socket.path).send(IPCEnvelope(
            operation: "status",
            capability: "wrong-capability",
            body: try RTCCanonicalJSON.encode(ReviewLookup(reviewID: record.reviewID))
        ))
        check(!unauthorized.ok && unauthorized.error?.code == "UNAUTHORIZED", "IPC capability remains enforced")
        let closeJSON = try await executor.run(.close(review: record.reviewID.value, json: true))
        let closed = try JSONDecoder().decode(ReviewStatusResponse.self, from: Data(closeJSON.utf8))
        check(closed.status == .closed && closed.reviewID == record.reviewID, "close IPC targets exact review")
        check(closed.cursor > decodedPoll.cursor, "same-clock transitions retain monotonic cursors")

        runtime.stop()
        let saved = root.appendingPathComponent("saved-repository")
        try FileManager.default.moveItem(at: repository, to: saved)
        try FileManager.default.copyItem(at: saved, to: repository)
        do {
            _ = try await engine.materialize(directlyResolved.revision, repositoryIdentity: directlyResolved.repositoryIdentity)
            preconditionFailure("repository replacement must fail")
        } catch GitEngineError.invalidRepository {}
    }

    static func checkStalenessPagination(root: URL, base: String, head: String, movedBase: String) async throws {
        let pageRoot = root.appendingPathComponent("staleness-pages", isDirectory: true)
        let store = try SQLiteStore(rootURL: pageRoot)
        let records = SQLiteIngestRepository(store: store)
        let git = FakeGit()
        await git.set(ref: "base", sha: base)
        await git.set(ref: "head", sha: head)
        let identity = SHA256Digest(data: Data("fake-repository".utf8))
        var active = [IngestReviewRecord]()
        for index in 0..<5 {
            let revision = try RevisionIdentity(repositoryPath: "/tmp/staleness-active-\(index)", baseSHA: base, headSHA: head)
            let submission = ReviewSubmission(
                repositoryPath: revision.repositoryPath,
                repositoryIdentity: identity,
                base: SubmittedRef(label: "base", expectedSHA: base),
                head: SubmittedRef(label: "head", expectedSHA: head),
                notify: false
            )
            active.append(try await records.accept(submission, revision: revision).0)
        }
        var terminalPaths = Set<String>()
        for index in 0..<3 {
            let revision = try RevisionIdentity(repositoryPath: "/tmp/staleness-terminal-\(index)", baseSHA: base, headSHA: head)
            let submission = ReviewSubmission(
                repositoryPath: revision.repositoryPath,
                repositoryIdentity: identity,
                base: SubmittedRef(label: "base", expectedSHA: base),
                head: SubmittedRef(label: "head", expectedSHA: head),
                notify: false
            )
            _ = try await records.accept(submission, revision: revision)
            _ = try await records.close(revision.reviewID)
            terminalPaths.insert(revision.repositoryPath)
        }

        let coordinator = SubmissionCoordinator(git: git, records: records, notifications: RecordingNotifications())
        await git.clearResolvedPaths()
        try await coordinator.refreshStaleness(limit: 2)
        try await coordinator.refreshStaleness(limit: 2)
        let beforeRestart = await git.resolvedPaths
        check(Set(beforeRestart).count == 4 && Set(beforeRestart).isDisjoint(with: terminalPaths), "staleness pages filter terminal rows before the limit")

        let ordered = active.sorted { $0.reviewID.value < $1.reviewID.value }
        let reopenedStore = try SQLiteStore(rootURL: pageRoot)
        let reopenedRecords = SQLiteIngestRepository(store: reopenedStore)
        let reopenedCoordinator = SubmissionCoordinator(git: git, records: reopenedRecords, notifications: RecordingNotifications())
        await git.clearResolvedPaths()
        try await reopenedCoordinator.refreshStaleness(limit: 2)
        let afterRestart = await git.resolvedPaths
        check(afterRestart.first == ordered[4].revision.repositoryPath, "staleness cursor survives restart and resumes the next page")
        check(Set(beforeRestart + afterRestart) == Set(active.map(\.revision.repositoryPath)), "bounded staleness rotation covers every active review")

        let movedHead = String(repeating: "e", count: 40)
        await git.set(ref: "base", sha: movedBase)
        await git.set(ref: "head", sha: movedHead)
        for _ in 0..<3 { try await reopenedCoordinator.refreshStaleness(limit: 2) }
        let refreshed = try await reopenedRecords.reviews().filter { !terminalPaths.contains($0.revision.repositoryPath) }
        check(refreshed.count == active.count && refreshed.allSatisfy(\.stale), "simultaneous base and head movement eventually marks every active review stale")
    }

    static func checkEventTransactions(root: URL, revision: RevisionIdentity) async throws {
        let store = try SQLiteStore(rootURL: root.appendingPathComponent("event-transactions", isDirectory: true))
        let manifest = ReviewManifest(
            id: revision.reviewID,
            revision: revision,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            status: .ready,
            stale: false,
            summary: ReviewSummary(files: 0, additions: 0, deletions: 0),
            files: []
        )
        try await SQLiteReviewRepository(store: store).save(manifest)
        let events = SQLiteEventRepository(store: store)
        let duplicateID = UUID()
        let first = event(id: duplicateID, revision: revision, payload: ["value": "first"])
        let appendedFirst = try await events.append(first, after: 0)
        let retriedFirst = try await events.append(first, after: 99)
        check(appendedFirst == retriedFirst, "an exact event retry returns the committed sequence")
        do {
            _ = try await events.append(
                event(id: duplicateID, revision: revision, payload: ["value": "duplicate"]), after: 1)
            preconditionFailure("an event ID collision must fail")
        } catch {
            check(error as? EventRepositoryError == .idempotencyConflict, "an event ID cannot change payload")
        }
        _ = try await events.append(event(id: UUID(), revision: revision, payload: ["value": "second"]), after: 1)
        let initial = try await events.events(after: 0, reviewID: revision.reviewID)
        check(initial.map(\.sequence) == [1, 2] && initial.first?.payload["value"] == "first", "event retries do not consume a sequence")

        let winners = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        _ = try await events.append(
                            event(id: UUID(), revision: revision, payload: ["index": "\(index)"]), after: 2)
                        return true
                    } catch EventRepositoryError.concurrentModification {
                        return false
                    }
                }
            }
            var successes = 0
            for try await won in group where won { successes += 1 }
            return successes
        }
        let appended = try await events.events(after: 0, reviewID: revision.reviewID)
        check(winners == 1 && appended.map(\.sequence) == [1, 2, 3], "concurrent event appends have one monotonic CAS winner")
    }

    static func event(id: UUID, revision: RevisionIdentity, payload: [String: String]) -> PendingReviewEvent {
        PendingReviewEvent(
            id: id,
            reviewID: revision.reviewID,
            revision: revision,
            kind: .feedback,
            payload: payload,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    static func checkGitSizeBoundaries(root: URL) async throws {
        let repository = root.appendingPathComponent("limits", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(repository, ["init", "--quiet"])
        try Data().write(to: repository.appendingPathComponent("seed"))
        try runGit(repository, ["add", "--", "seed"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "base"])
        let base = try gitOutput(repository, ["rev-parse", "HEAD"])
        let cap = RTCConstants.maxPatchBytesPerFile
        try Data(repeating: 0x61, count: cap - 1).write(to: repository.appendingPathComponent("below.txt"))
        try Data(repeating: 0x62, count: cap).write(to: repository.appendingPathComponent("at.txt"))
        try Data(repeating: 0x63, count: cap + 1).write(to: repository.appendingPathComponent("above.txt"))
        try runGit(repository, ["add", "--", "below.txt", "at.txt", "above.txt"])
        try runGit(repository, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "boundaries"])
        let head = try gitOutput(repository, ["rev-parse", "HEAD"])
        let resolved = try await ExactGitEngine().resolveSubmission(repositoryPath: repository.path, base: base, head: head)
        let evidence = try await ExactGitEngine().materialize(resolved.revision, repositoryIdentity: resolved.repositoryIdentity)
        check(evidence.files.first(where: { $0.path == "below.txt" })?.truncated == false, "blob below cap materializes")
        check(evidence.files.first(where: { $0.path == "at.txt" })?.truncated == false, "blob at cap materializes")
        let above = evidence.files.first(where: { $0.path == "above.txt" })
        check(above?.truncated == true && above?.newLineCount == nil, "blob above cap is never read for line count")

        let aggregate = root.appendingPathComponent("aggregate", isDirectory: true)
        try FileManager.default.createDirectory(at: aggregate, withIntermediateDirectories: true)
        try runGit(aggregate, ["init", "--quiet"])
        try Data().write(to: aggregate.appendingPathComponent("seed"))
        try runGit(aggregate, ["add", "--", "seed"])
        try runGit(aggregate, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "base"])
        let aggregateBase = try gitOutput(aggregate, ["rev-parse", "HEAD"])
        for index in 0..<9 { try Data(repeating: UInt8(65 + index), count: cap - 1).write(to: aggregate.appendingPathComponent("file-\(index).txt")) }
        try runGit(aggregate, ["add", "--", "."])
        try runGit(aggregate, ["-c", "user.name=RTC", "-c", "user.email=rtc@example.invalid", "commit", "--quiet", "-m", "aggregate"])
        let aggregateHead = try gitOutput(aggregate, ["rev-parse", "HEAD"])
        let aggregateRevision = try await ExactGitEngine().resolveSubmission(repositoryPath: aggregate.path, base: aggregateBase, head: aggregateHead)
        do {
            _ = try await ExactGitEngine().materialize(aggregateRevision.revision, repositoryIdentity: aggregateRevision.repositoryIdentity)
            preconditionFailure("aggregate patch cap must fail")
        } catch GitEngineError.patchLimit {}
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
    private(set) var resolvedPaths = [String]()

    func set(ref: String, sha: String) { refs[ref] = sha }
    func remove(ref: String) { refs[ref] = nil }
    func setFailure(_ failure: GitEngineError?) { self.failure = failure }
    func clearResolvedPaths() { resolvedPaths.removeAll() }

    func resolveRevision(repositoryPath: String, base: String, head: String) async throws -> RevisionIdentity {
        guard let baseSHA = refs[base] ?? full(base), let headSHA = refs[head] ?? full(head) else {
            throw GitEngineError.invalidRef
        }
        return try RevisionIdentity(repositoryPath: repositoryPath, baseSHA: baseSHA, headSHA: headSHA)
    }

    func resolveSubmission(repositoryPath: String, base: String, head: String) async throws -> ExactGitEngine.ResolvedSubmission {
        resolvedPaths.append(repositoryPath)
        return ExactGitEngine.ResolvedSubmission(
            revision: try await resolveRevision(repositoryPath: repositoryPath, base: base, head: head),
            repositoryIdentity: SHA256Digest(data: Data("fake-repository".utf8))
        )
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

    func materialize(_ revision: RevisionIdentity, repositoryIdentity: SHA256Digest?) async throws -> ReviewManifest {
        try await materialize(revision)
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
    private(set) var permissionRequests = 0
    var count: Int { requests.count }
    func authorization() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> NotificationAuthorization { permissionRequests += 1; return .authorized }
    func present(_ request: NotificationRequestData) async throws { requests.append(request) }
    func setBadge(_ value: Int) async {}
}

private struct ProvisioningActivator: AppActivator {
    let paths: RTCInstallationPaths
    func activate() async -> Bool { (try? paths.prepare(createCapability: true)) != nil }
}
