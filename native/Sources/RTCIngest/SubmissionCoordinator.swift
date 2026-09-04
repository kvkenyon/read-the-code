import Foundation
import RTCContracts
import RTCGit

public protocol IngestGitService: ExactGitService {
    func resolveSubmission(repositoryPath: String, base: String, head: String) async throws -> ExactGitEngine.ResolvedSubmission
    func materialize(_ revision: RevisionIdentity, repositoryIdentity: SHA256Digest?) async throws -> ReviewManifest
}

extension ExactGitEngine: IngestGitService {}

public actor SubmissionCoordinator {
    private let git: any IngestGitService
    private let records: SQLiteIngestRepository
    private let notifications: any NotificationService
    private let owner: BoundedString
    private var draining = false
    private var maintenanceStarted = false

    public init(git: any IngestGitService, records: SQLiteIngestRepository, notifications: any NotificationService) {
        self.git = git
        self.records = records
        self.notifications = notifications
        owner = try! BoundedString("ingest-\(UUID().uuidString)", maxCharacters: 64)
    }

    public func submit(_ submission: ReviewSubmission) async throws -> SubmissionReceipt {
        try validate(submission)
        let revision = try RevisionIdentity(repositoryPath: submission.repositoryPath, baseSHA: submission.base.expectedSHA, headSHA: submission.head.expectedSHA)
        guard revision.repositoryPath == submission.repositoryPath,
              URL(fileURLWithPath: submission.repositoryPath).isFileURL,
              submission.repositoryPath.hasPrefix("/") else { throw IngestError.invalidSubmission }
        let (record, disposition, _) = try await records.accept(submission, revision: revision)
        scheduleDrain()
        return SubmissionReceipt(reviewID: record.reviewID, revision: record.revision, disposition: disposition)
    }

    public func resumeOutstanding() async throws {
        try await records.reconcile()
        scheduleDrain()
        startMaintenance()
    }

    public func retry(_ id: ReviewID) async throws { try await records.retry(id); scheduleDrain() }
    public func close(_ id: ReviewID) async throws -> ReviewStatusResponse { ReviewStatusResponse(record: try await records.close(id)) }
    public func markRead(_ id: ReviewID) async throws { try await records.markRead(id) }

    public func status(_ id: ReviewID) async throws -> ReviewStatusResponse {
        guard let record = try await records.review(id) else { throw IngestError.notFound }
        return ReviewStatusResponse(record: record)
    }

    public func poll(_ lookup: ReviewLookup) async throws -> ReviewPollResponse {
        guard let current = try await records.review(lookup.reviewID) else { throw IngestError.notFound }
        let after = lookup.after ?? 0
        guard after >= 0, after <= current.changeSequence else { throw IngestError.invalidSubmission }
        if let response = try await pollResult(lookup, after: after) { return response }
        let timeout = min(max(lookup.timeoutMilliseconds ?? 0, 0), 120_000)
        guard timeout > 0 else { return ReviewPollResponse(reviewID: lookup.reviewID, cursor: after, timedOut: true, changes: []) }
        let stream = await records.observe(lookup.reviewID)
        if let response = try await pollResult(lookup, after: after) { return response }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() != nil }
            group.addTask { try await Task.sleep(for: .milliseconds(timeout)); return false }
            let changed = try await group.next() ?? false
            group.cancelAll()
            if changed, let response = try await self.pollResult(lookup, after: after) { return response }
            return ReviewPollResponse(reviewID: lookup.reviewID, cursor: after, timedOut: true, changes: [])
        }
    }

    public func refreshStaleness(limit: Int = 8) async throws {
        for record in try await records.reviews(limit: max(0, min(limit, 64))) where record.status != .superseded && record.status != .closed {
            do {
                let resolved = try await git.resolveSubmission(repositoryPath: record.revision.repositoryPath, base: record.baseRef, head: record.headRef)
                guard resolved.repositoryIdentity == record.repositoryIdentity else {
                    try await records.recordRefreshError(record.reviewID, code: "REPOSITORY_CHANGED", message: "Repository identity changed; staleness will be retried.")
                    continue
                }
                if resolved.revision != record.revision { try await records.markStale(record.reviewID) }
                else { try await records.clearRefreshError(record.reviewID) }
            } catch {
                try await records.recordRefreshError(record.reviewID, code: "REFRESH_UNAVAILABLE", message: "Submitted refs are temporarily unavailable; staleness will be retried.")
            }
        }
    }

    public func runUntilIdle() async {
        while draining { await Task.yield() }
        await drain()
    }

    private func pollResult(_ lookup: ReviewLookup, after: Int) async throws -> ReviewPollResponse? {
        let changes = try await records.changes(reviewID: lookup.reviewID, after: after, full: lookup.full)
        guard let cursor = changes.last?.cursor else { return nil }
        return ReviewPollResponse(reviewID: lookup.reviewID, cursor: cursor, timedOut: false, changes: changes)
    }

    private func scheduleDrain(after delay: Duration? = nil) {
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            await self.drain()
        }
    }

    private func startMaintenance() {
        guard !maintenanceStarted else { return }
        maintenanceStarted = true
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.drain()
                do { try await self.refreshStaleness() }
                catch {
                    do { try await self.records.recordRuntimeFailure(code: "REFRESH_FAILED", message: "Periodic staleness refresh failed.") }
                    catch { /* The next maintenance pass retries store access. */ }
                }
            }
        }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        do {
            while let lease = try await records.leaseMaterialization(owner: owner) {
                guard let record = try await records.review(lease.reviewID) else { throw IngestError.notFound }
                do {
                    let evidence = try await git.materialize(record.revision, repositoryIdentity: record.repositoryIdentity)
                    try await records.completeReady(lease, evidence: evidence)
                } catch {
                    let failure = durableFailure(error)
                    try await records.completeFailure(lease, code: failure.code, message: failure.message)
                }
            }
            while let lease = try await records.claimNotification(owner: owner) {
                do {
                    try await notifications.notify(reviewID: lease.reviewID, generic: true)
                    try await records.completeNotification(lease)
                } catch {
                    try await records.retryNotification(lease)
                    scheduleDrain(after: .seconds(30))
                    break
                }
            }
        } catch {
            do { try await records.recordRuntimeFailure(code: "WORKER_FAILED", message: "Background processing will be retried.") }
            catch { /* SQLite failure remains observable to the next resume/start attempt. */ }
        }
    }

    private func validate(_ submission: ReviewSubmission) throws {
        guard submission.schemaVersion == RTCConstants.schemaVersion,
              !submission.repositoryPath.isEmpty, submission.repositoryPath.utf8.count <= RTCConstants.maxPathBytes,
              !submission.repositoryPath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !submission.base.label.isEmpty, !submission.head.label.isEmpty,
              submission.base.label.utf8.count <= 1024, submission.head.label.utf8.count <= 1024,
              submission.base.expectedSHA.count == 40, submission.head.expectedSHA.count == 40,
              submission.base.expectedSHA.allSatisfy(\.isHexDigit), submission.head.expectedSHA.allSatisfy(\.isHexDigit),
              submission.title.utf8.count <= 512,
              (try? BoundedString(submission.title, maxCharacters: 512)) != nil else { throw IngestError.invalidSubmission }
    }

    private func durableFailure(_ error: Error) -> (code: String, message: String) {
        switch error {
        case GitEngineError.invalidRepository: return ("INVALID_REVISION", "Repository is unavailable, invalid, or has been replaced.")
        case GitEngineError.invalidRef: return ("INVALID_REF", "A submitted revision cannot be resolved.")
        case GitEngineError.tooManyFiles, GitEngineError.patchLimit, GitEngineError.outputLimit: return ("LIMIT_EXCEEDED", "The committed comparison exceeds review limits.")
        case GitEngineError.timedOut: return ("GIT_TIMEOUT", "Git materialization timed out.")
        case GitEngineError.cancelled: return ("GIT_CANCELLED", "Git materialization was cancelled.")
        default: return ("INTERNAL_ERROR", "The committed comparison could not be materialized.")
        }
    }
}
