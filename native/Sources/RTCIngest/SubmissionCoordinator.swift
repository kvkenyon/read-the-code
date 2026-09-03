import Foundation
import RTCContracts
import RTCGit
import RTCStore

public protocol IngestGitService: ExactGitService {
    func resolveRevision(repositoryPath: String, base: String, head: String) async throws -> RevisionIdentity
}

extension ExactGitEngine: IngestGitService {}

public actor SubmissionCoordinator {
    private let git: any IngestGitService
    private let records: SQLiteIngestRepository
    private let reviews: any ReviewRepository
    private let jobs: JobQueue
    private let notifications: any NotificationService
    private var draining = false

    public init(
        git: any IngestGitService,
        records: SQLiteIngestRepository,
        reviews: any ReviewRepository,
        jobs: JobQueue,
        notifications: any NotificationService
    ) {
        self.git = git
        self.records = records
        self.reviews = reviews
        self.jobs = jobs
        self.notifications = notifications
    }

    public func submit(_ submission: ReviewSubmission) async throws -> SubmissionReceipt {
        try validate(submission)
        let revision = try await git.resolveRevision(
            repositoryPath: submission.repositoryPath,
            base: submission.base.label,
            head: submission.head.label
        )
        guard matches(submission.base.expectedSHA, revision.baseSHA),
              matches(submission.head.expectedSHA, revision.headSHA)
        else { throw GitEngineError.invalidRef }

        let (record, disposition, superseded) = try await records.accept(submission, revision: revision)
        if try await reviews.review(id: record.reviewID) == nil {
            try await reviews.save(manifest(for: record, status: record.status))
        }
        if let superseded, let old = try await reviews.review(id: superseded) {
            try await reviews.save(copy(old, status: .superseded, stale: old.stale))
        }
        try await jobs.enqueue(JobRecord(
            id: UUID(), kind: .materialize, reviewID: record.reviewID, state: .queued,
            attempt: 0, availableAt: Date()
        ))
        if record.status == .failed || record.status == .materializing {
            try await jobs.requeue(reviewID: record.reviewID, kind: .materialize)
            try await records.save(record.updating(
                status: .accepted,
                errorCode: .some(nil),
                errorMessage: .some(nil)
            ))
        }
        scheduleDrain()
        return SubmissionReceipt(reviewID: record.reviewID, revision: revision, disposition: disposition)
    }

    public func resumeOutstanding() async throws {
        try await jobs.reclaimExpired()
        for record in try await records.reviews() {
            if record.status == .accepted || record.status == .materializing {
                try await enqueue(kind: .materialize, reviewID: record.reviewID)
                try await jobs.requeue(reviewID: record.reviewID, kind: .materialize)
            } else if record.status == .ready && record.notify {
                try await enqueue(kind: .notification, reviewID: record.reviewID)
                try await jobs.requeue(reviewID: record.reviewID, kind: .notification)
            }
        }
        scheduleDrain()
    }

    public func retry(_ id: ReviewID) async throws {
        guard let record = try await records.review(id), record.status == .failed else { throw IngestError.invalidTransition }
        try await records.save(record.updating(
            status: .accepted,
            errorCode: .some(nil),
            errorMessage: .some(nil)
        ))
        try await jobs.requeue(reviewID: id, kind: .materialize)
        scheduleDrain()
    }

    public func close(_ id: ReviewID) async throws -> ReviewStatusResponse {
        guard let record = try await records.review(id) else { throw IngestError.notFound }
        guard record.status != .superseded else { throw IngestError.invalidTransition }
        let closed = record.updating(status: .closed)
        try await records.save(closed)
        if let review = try await reviews.review(id: id) {
            try await reviews.save(copy(review, status: .closed, stale: review.stale))
        }
        return ReviewStatusResponse(record: closed)
    }

    public func status(_ id: ReviewID) async throws -> ReviewStatusResponse {
        guard let record = try await records.review(id) else { throw IngestError.notFound }
        return ReviewStatusResponse(record: record)
    }

    public func markRead(_ id: ReviewID) async throws {
        guard let record = try await records.review(id) else { throw IngestError.notFound }
        if record.unread { try await records.save(record.updating(unread: false)) }
    }

    public func refreshStaleness() async throws {
        for record in try await records.reviews() where record.status != .superseded && record.status != .closed {
            let current = try? await git.resolveRevision(
                repositoryPath: record.revision.repositoryPath,
                base: record.baseRef,
                head: record.headRef
            )
            guard current?.headSHA != record.revision.headSHA, !record.stale else { continue }
            try await records.save(record.updating(stale: true))
            try await reviews.markStale(record.reviewID)
        }
    }

    public func runUntilIdle() async {
        while draining { await Task.yield() }
        await drain()
    }

    private func scheduleDrain() {
        Task { await self.drain() }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        let owner: BoundedString = "ingest-worker"
        while let leased = try? await jobs.leaseNext(owner: owner, now: Date(), kind: .materialize) {
            let (job, _) = leased
            guard let record = try? await records.review(job.reviewID) else {
                try? await jobs.complete(job.id, state: .failed)
                continue
            }
            guard record.status != .superseded && record.status != .closed else {
                try? await jobs.complete(job.id, state: .cancelled)
                continue
            }
            let materializing = record.updating(status: .materializing)
            try? await records.save(materializing)
            try? await reviews.save(manifest(for: materializing, status: .materializing))
            do {
                let evidence = try await git.materialize(record.revision)
                let ready = materializing.updating(
                    status: .ready,
                    unread: true,
                    errorCode: .some(nil),
                    errorMessage: .some(nil)
                )
                try await reviews.save(copy(evidence, status: .ready, stale: ready.stale))
                try await records.save(ready)
                try await jobs.complete(job.id, state: .succeeded)
                if ready.notify { try await enqueue(kind: .notification, reviewID: ready.reviewID) }
            } catch {
                let failure = durableFailure(error)
                let failed = materializing.updating(
                    status: .failed,
                    errorCode: .some(failure.code),
                    errorMessage: .some(failure.message)
                )
                try? await records.save(failed)
                try? await reviews.save(manifest(for: failed, status: .failed))
                try? await jobs.complete(job.id, state: .failed)
            }
        }
        while let leased = try? await jobs.leaseNext(owner: owner, now: Date(), kind: .notification) {
            let (job, _) = leased
            guard let record = try? await records.review(job.reviewID), record.notify, record.status == .ready else {
                try? await jobs.complete(job.id, state: .cancelled)
                continue
            }
            do {
                try await notifications.notify(reviewID: record.reviewID, generic: true)
                try await jobs.complete(job.id, state: .succeeded)
            } catch {
                try? await jobs.requeue(
                    reviewID: record.reviewID,
                    kind: .notification,
                    now: Date().addingTimeInterval(30)
                )
                scheduleDrain(after: .seconds(30))
                break
            }
        }
    }

    private func enqueue(kind: JobKind, reviewID: ReviewID) async throws {
        try await jobs.enqueue(JobRecord(
            id: UUID(), kind: kind, reviewID: reviewID, state: .queued,
            attempt: 0, availableAt: Date()
        ))
    }

    private func scheduleDrain(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            await self.drain()
        }
    }

    private func validate(_ submission: ReviewSubmission) throws {
        guard submission.schemaVersion == RTCConstants.schemaVersion,
              !submission.repositoryPath.isEmpty,
              submission.repositoryPath.utf8.count <= RTCConstants.maxPathBytes,
              !submission.repositoryPath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !submission.base.label.isEmpty, !submission.head.label.isEmpty,
              submission.title.utf8.count <= 512,
              (try? BoundedString(submission.title, maxCharacters: 512)) != nil
        else { throw IngestError.invalidSubmission }
    }

    private func matches(_ expected: String?, _ actual: String) -> Bool {
        guard let expected else { return true }
        return expected.lowercased() == actual.lowercased()
    }

    private func manifest(for record: IngestReviewRecord, status: ReviewStatus) -> ReviewManifest {
        ReviewManifest(
            id: record.reviewID,
            revision: record.revision,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            status: status,
            stale: record.stale,
            summary: ReviewSummary(files: 0, additions: 0, deletions: 0),
            files: []
        )
    }

    private func copy(_ review: ReviewManifest, status: ReviewStatus, stale: Bool) -> ReviewManifest {
        ReviewManifest(
            id: review.id,
            revision: review.revision,
            createdAt: review.createdAt,
            updatedAt: Date(),
            status: status,
            stale: stale,
            summary: review.summary,
            files: review.files
        )
    }

    private func durableFailure(_ error: Error) -> (code: String, message: String) {
        switch error {
        case GitEngineError.invalidRepository: return ("INVALID_REVISION", "Repository is unavailable or invalid.")
        case GitEngineError.invalidRef: return ("INVALID_REF", "A submitted revision cannot be resolved.")
        case GitEngineError.tooManyFiles, GitEngineError.patchLimit, GitEngineError.outputLimit:
            return ("LIMIT_EXCEEDED", "The committed comparison exceeds review limits.")
        case GitEngineError.timedOut: return ("GIT_TIMEOUT", "Git materialization timed out.")
        case GitEngineError.cancelled: return ("GIT_CANCELLED", "Git materialization was cancelled.")
        default: return ("INTERNAL_ERROR", "The committed comparison could not be materialized.")
        }
    }
}
