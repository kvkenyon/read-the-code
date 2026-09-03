import Foundation
import GRDB
import RTCContracts
import RTCLifecycle
import RTCStore

public actor SQLiteIngestRepository {
    private let store: SQLiteStore
    private let beforeIdempotencyWrite: (@Sendable () throws -> Void)?

    public init(store: SQLiteStore) {
        self.store = store
        beforeIdempotencyWrite = nil
    }

    @_spi(Testing)
    public init(store: SQLiteStore, beforeIdempotencyWrite: @escaping @Sendable () throws -> Void) {
        self.store = store
        self.beforeIdempotencyWrite = beforeIdempotencyWrite
    }

    public func accept(
        _ submission: ReviewSubmission,
        revision: RevisionIdentity
    ) async throws -> (IngestReviewRecord, SubmissionDisposition, ReviewID?) {
        let digest = try RTCCanonicalJSON.digest(submission).hex
        let beforeIdempotencyWrite = self.beforeIdempotencyWrite
        return try await store.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT request_digest, review_id FROM ingest_idempotency WHERE idempotency_key = ?",
                arguments: [submission.idempotencyKey.uuidString]
            ) {
                guard row["request_digest"] as String == digest else { throw IngestError.idempotencyConflict }
                let id = try ReviewID(row["review_id"] as String)
                guard let record = try Self.fetch(id, db: db) else { throw IngestError.notFound }
                return (record, .resumed, nil)
            }

            if let existing = try Self.fetch(revision.reviewID, db: db) {
                try db.execute(
                    sql: "INSERT INTO ingest_idempotency (idempotency_key, request_digest, review_id) VALUES (?, ?, ?)",
                    arguments: [submission.idempotencyKey.uuidString, digest, existing.reviewID.value]
                )
                return (existing, .resumed, nil)
            }

            let now = Date()
            let previousRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM ingest_reviews WHERE repository_path = ? AND status NOT IN ('closed', 'superseded') ORDER BY updated_at DESC LIMIT 1",
                arguments: [revision.repositoryPath]
            )
            let previous = try previousRow.map(Self.decode)
            if let previous {
                try Self.persist(
                    previous.updating(status: .superseded, supersededBy: .some(revision.reviewID)),
                    db: db
                )
            }
            let record = IngestReviewRecord(
                reviewID: revision.reviewID,
                revision: revision,
                baseRef: submission.base.label,
                headRef: submission.head.label,
                title: submission.title,
                notify: submission.notify,
                unread: true,
                stale: false,
                status: .accepted,
                errorCode: nil,
                errorMessage: nil,
                supersedes: previous?.reviewID,
                supersededBy: nil,
                createdAt: now,
                updatedAt: now
            )
            try Self.persist(record, db: db)
            try beforeIdempotencyWrite?()
            try db.execute(
                sql: "INSERT INTO ingest_idempotency (idempotency_key, request_digest, review_id) VALUES (?, ?, ?)",
                arguments: [submission.idempotencyKey.uuidString, digest, record.reviewID.value]
            )
            return (record, .created, previous?.reviewID)
        }
    }

    public func review(_ id: ReviewID) async throws -> IngestReviewRecord? {
        try await store.read { db in try Self.fetch(id, db: db) }
    }

    public func reviews() async throws -> [IngestReviewRecord] {
        try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ingest_reviews ORDER BY updated_at DESC, review_id").map(Self.decode)
        }
    }

    public func save(_ record: IngestReviewRecord) async throws {
        try await store.write { db in try Self.persist(record, db: db) }
    }

    private static func fetch(_ id: ReviewID, db: Database) throws -> IngestReviewRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM ingest_reviews WHERE review_id = ?", arguments: [id.value]).map(decode)
    }

    private static func decode(_ row: Row) throws -> IngestReviewRecord {
        let revision = try RevisionIdentity(
            repositoryPath: row["repository_path"],
            baseSHA: row["base_sha"],
            headSHA: row["head_sha"]
        )
        guard let status = ReviewStatus(rawValue: row["status"]) else { throw RTCStoreError.corrupt("ingest status") }
        return IngestReviewRecord(
            reviewID: try ReviewID(row["review_id"]),
            revision: revision,
            baseRef: row["base_ref"],
            headRef: row["head_ref"],
            title: row["title"],
            notify: row["notify"],
            unread: row["unread"],
            stale: row["stale"],
            status: status,
            errorCode: row["error_code"],
            errorMessage: row["error_message"],
            supersedes: try (row["supersedes"] as String?).map(ReviewID.init),
            supersededBy: try (row["superseded_by"] as String?).map(ReviewID.init),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    private static func persist(_ record: IngestReviewRecord, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO ingest_reviews (
                review_id, repository_path, base_sha, head_sha, base_ref, head_ref, title,
                notify, unread, stale, status, error_code, error_message, supersedes,
                superseded_by, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(review_id) DO UPDATE SET
                unread = excluded.unread, stale = excluded.stale, status = excluded.status,
                error_code = excluded.error_code, error_message = excluded.error_message,
                superseded_by = excluded.superseded_by, updated_at = excluded.updated_at
            """,
            arguments: [
                record.reviewID.value, record.revision.repositoryPath, record.revision.baseSHA,
                record.revision.headSHA, record.baseRef, record.headRef, record.title, record.notify,
                record.unread, record.stale, record.status.rawValue, record.errorCode,
                record.errorMessage, record.supersedes?.value, record.supersededBy?.value,
                record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970,
            ]
        )
    }
}

public actor SQLiteNotificationDeliveryStore: NotificationDeliveryStore {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func wasDelivered(reviewID: ReviewID) async throws -> Bool {
        try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM notification_deliveries WHERE review_id = ?", arguments: [reviewID.value]) != nil
        }
    }

    public func markDelivered(reviewID: ReviewID) async throws {
        try await store.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO notification_deliveries (review_id, delivered_at) VALUES (?, ?)",
                arguments: [reviewID.value, Date().timeIntervalSince1970]
            )
        }
    }
}
