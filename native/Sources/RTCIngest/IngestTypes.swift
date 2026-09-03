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
    public let expectedSHA: String?

    public init(label: String, expectedSHA: String? = nil) {
        self.label = label
        self.expectedSHA = expectedSHA?.lowercased()
    }
}

public struct ReviewSubmission: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let idempotencyKey: UUID
    public let repositoryPath: String
    public let base: SubmittedRef
    public let head: SubmittedRef
    public let title: String
    public let notify: Bool

    public init(
        schemaVersion: Int = RTCConstants.schemaVersion,
        idempotencyKey: UUID = UUID(),
        repositoryPath: String,
        base: SubmittedRef,
        head: SubmittedRef,
        title: String = "Code review",
        notify: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.idempotencyKey = idempotencyKey
        self.repositoryPath = repositoryPath
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

    public init(reviewID: ReviewID, after: Int? = nil) {
        self.reviewID = reviewID
        self.after = after
    }
}

public struct IngestReviewRecord: Equatable, Sendable {
    public let reviewID: ReviewID
    public let revision: RevisionIdentity
    public let baseRef: String
    public let headRef: String
    public let title: String
    public let notify: Bool
    public let unread: Bool
    public let stale: Bool
    public let status: ReviewStatus
    public let errorCode: String?
    public let errorMessage: String?
    public let supersedes: ReviewID?
    public let supersededBy: ReviewID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        reviewID: ReviewID,
        revision: RevisionIdentity,
        baseRef: String,
        headRef: String,
        title: String,
        notify: Bool,
        unread: Bool,
        stale: Bool,
        status: ReviewStatus,
        errorCode: String?,
        errorMessage: String?,
        supersedes: ReviewID?,
        supersededBy: ReviewID?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.reviewID = reviewID
        self.revision = revision
        self.baseRef = baseRef
        self.headRef = headRef
        self.title = title
        self.notify = notify
        self.unread = unread
        self.stale = stale
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func updating(
        status: ReviewStatus? = nil,
        unread: Bool? = nil,
        stale: Bool? = nil,
        errorCode: String?? = nil,
        errorMessage: String?? = nil,
        supersededBy: ReviewID?? = nil,
        updatedAt: Date = Date()
    ) -> IngestReviewRecord {
        IngestReviewRecord(
            reviewID: reviewID,
            revision: revision,
            baseRef: baseRef,
            headRef: headRef,
            title: title,
            notify: notify,
            unread: unread ?? self.unread,
            stale: stale ?? self.stale,
            status: status ?? self.status,
            errorCode: errorCode ?? self.errorCode,
            errorMessage: errorMessage ?? self.errorMessage,
            supersedes: supersedes,
            supersededBy: supersededBy ?? self.supersededBy,
            createdAt: createdAt,
            updatedAt: updatedAt
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
        cursor = Int(record.updatedAt.timeIntervalSince1970 * 1_000)
    }
}
