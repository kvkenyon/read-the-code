import Foundation
import RTCContracts

public enum IngestError: Error, Equatable, Sendable {
    case invalidSubmission
    case idempotencyConflict
    case notFound
    case invalidTransition
}

public struct SubmittedRef: Codable, Hashable, Sendable {
    public let label: String
    public let expectedSHA: String

    public init(label: String, expectedSHA: String) {
        self.label = label
        self.expectedSHA = expectedSHA.lowercased()
    }
}

public struct ReviewSubmission: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let idempotencyKey: UUID
    public let repositoryPath: String
    public let repositoryIdentity: SHA256Digest
    public let base: SubmittedRef
    public let head: SubmittedRef
    public let title: String
    public let notify: Bool

    public init(
        schemaVersion: Int = RTCConstants.schemaVersion,
        idempotencyKey: UUID = UUID(),
        repositoryPath: String,
        repositoryIdentity: SHA256Digest,
        base: SubmittedRef,
        head: SubmittedRef,
        title: String = "Code review",
        notify: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.idempotencyKey = idempotencyKey
        self.repositoryPath = repositoryPath
        self.repositoryIdentity = repositoryIdentity
        self.base = base
        self.head = head
        self.title = title
        self.notify = notify
    }
}

public enum SubmissionDisposition: String, Codable, Sendable { case created, resumed }

public struct SubmissionReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let reviewID: ReviewID
    public let baseSHA: String
    public let headSHA: String
    public let disposition: SubmissionDisposition
    public let materialization: String

    public init(reviewID: ReviewID, revision: RevisionIdentity, disposition: SubmissionDisposition) {
        self.schemaVersion = RTCConstants.schemaVersion
        self.reviewID = reviewID
        self.baseSHA = revision.baseSHA
        self.headSHA = revision.headSHA
        self.disposition = disposition
        self.materialization = "accepted"
    }
}

public struct ReviewLookup: Codable, Equatable, Sendable {
    public let reviewID: ReviewID
    public let after: Int?
    public let timeoutMilliseconds: Int?
    public let full: Bool

    public init(reviewID: ReviewID, after: Int? = nil, timeoutMilliseconds: Int? = nil, full: Bool = false) {
        self.reviewID = reviewID
        self.after = after
        self.timeoutMilliseconds = timeoutMilliseconds
        self.full = full
    }
}

public struct IngestReviewRecord: Equatable, Sendable {
    public let reviewID: ReviewID
    public let revision: RevisionIdentity
    public let repositoryIdentity: SHA256Digest
    public let baseRef: String
    public let headRef: String
    public let title: String
    public let notify: Bool
    public let unread: Bool
    public let stale: Bool
    public let status: ReviewStatus
    public let errorCode: String?
    public let errorMessage: String?
    public let refreshErrorCode: String?
    public let refreshErrorMessage: String?
    public let supersedes: ReviewID?
    public let supersededBy: ReviewID?
    public let createdAt: Date
    public let updatedAt: Date
    public let changeSequence: Int

    public init(
        reviewID: ReviewID,
        revision: RevisionIdentity,
        repositoryIdentity: SHA256Digest,
        baseRef: String,
        headRef: String,
        title: String,
        notify: Bool,
        unread: Bool,
        stale: Bool,
        status: ReviewStatus,
        errorCode: String?,
        errorMessage: String?,
        refreshErrorCode: String? = nil,
        refreshErrorMessage: String? = nil,
        supersedes: ReviewID?,
        supersededBy: ReviewID?,
        createdAt: Date,
        updatedAt: Date,
        changeSequence: Int = 1
    ) {
        self.reviewID = reviewID
        self.revision = revision
        self.repositoryIdentity = repositoryIdentity
        self.baseRef = baseRef
        self.headRef = headRef
        self.title = title
        self.notify = notify
        self.unread = unread
        self.stale = stale
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.refreshErrorCode = refreshErrorCode
        self.refreshErrorMessage = refreshErrorMessage
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.changeSequence = changeSequence
    }

    public func updating(
        status: ReviewStatus? = nil,
        unread: Bool? = nil,
        stale: Bool? = nil,
        errorCode: String?? = nil,
        errorMessage: String?? = nil,
        refreshErrorCode: String?? = nil,
        refreshErrorMessage: String?? = nil,
        supersededBy: ReviewID?? = nil,
        updatedAt: Date = Date(),
        incrementSequence: Bool = true
    ) -> IngestReviewRecord {
        IngestReviewRecord(
            reviewID: reviewID,
            revision: revision,
            repositoryIdentity: repositoryIdentity,
            baseRef: baseRef,
            headRef: headRef,
            title: title,
            notify: notify,
            unread: unread ?? self.unread,
            stale: stale ?? self.stale,
            status: status ?? self.status,
            errorCode: errorCode ?? self.errorCode,
            errorMessage: errorMessage ?? self.errorMessage,
            refreshErrorCode: refreshErrorCode ?? self.refreshErrorCode,
            refreshErrorMessage: refreshErrorMessage ?? self.refreshErrorMessage,
            supersedes: supersedes,
            supersededBy: supersededBy ?? self.supersededBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            changeSequence: incrementSequence ? changeSequence + 1 : changeSequence
        )
    }
}

public struct ReviewStatusResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let reviewID: ReviewID
    public let baseSHA: String
    public let headSHA: String
    public let status: ReviewStatus
    public let stale: Bool
    public let unread: Bool
    public let errorCode: String?
    public let errorMessage: String?
    public let cursor: Int

    public init(record: IngestReviewRecord) {
        schemaVersion = RTCConstants.schemaVersion
        reviewID = record.reviewID
        baseSHA = record.revision.baseSHA
        headSHA = record.revision.headSHA
        status = record.status
        stale = record.stale
        unread = record.unread
        errorCode = record.errorCode
        errorMessage = record.errorMessage
        cursor = record.changeSequence
    }
}

public struct ReviewPollResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let reviewID: ReviewID
    public let cursor: Int
    public let timedOut: Bool
    public let changes: [ReviewStatusResponse]

    public init(reviewID: ReviewID, cursor: Int, timedOut: Bool, changes: [ReviewStatusResponse]) {
        schemaVersion = RTCConstants.schemaVersion
        self.reviewID = reviewID
        self.cursor = cursor
        self.timedOut = timedOut
        self.changes = changes
    }
}
