import Foundation
import GRDB
import RTCContracts
import RTCLifecycle
import RTCStore

public struct IngestJobLease: Sendable {
    public let jobID: UUID
    public let reviewID: ReviewID
    public let owner: BoundedString
    public let expiresAt: Date
}

public struct NotificationLease: Sendable {
    public let reviewID: ReviewID
    public let owner: BoundedString
    public let platformID: String
    public let expiresAt: Date
}

/// Owns every ingest state transition so the Inbox row, public review manifest,
/// job lease, event cursor, and notification outbox commit together.
public actor SQLiteIngestRepository {
    private let store: SQLiteStore
    private let beforeIdempotencyWrite: (@Sendable () throws -> Void)?
    private var observers: [ReviewID: [UUID: AsyncStream<Int>.Continuation]] = [:]
    private var inboxObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

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
        let hook = beforeIdempotencyWrite
        let result = try await store.write { db -> (IngestReviewRecord, SubmissionDisposition, ReviewID?, [IngestReviewRecord]) in
            if let row = try Row.fetchOne(db, sql: "SELECT request_digest, review_id FROM ingest_idempotency WHERE idempotency_key = ?", arguments: [submission.idempotencyKey.uuidString]) {
                guard row["request_digest"] as String == digest else { throw IngestError.idempotencyConflict }
                let id = try ReviewID(row["review_id"] as String)
                guard let record = try Self.fetch(id, db: db) else { throw IngestError.notFound }
                return (record, .resumed, nil, [])
            }
            if let existing = try Self.fetch(revision.reviewID, db: db) {
                try db.execute(sql: "INSERT INTO ingest_idempotency (idempotency_key, request_digest, review_id) VALUES (?, ?, ?)", arguments: [submission.idempotencyKey.uuidString, digest, existing.reviewID.value])
                return (existing, .resumed, nil, [])
            }

            let now = Date()
            let prior = try Row.fetchOne(db, sql: "SELECT * FROM ingest_reviews WHERE repository_path = ? AND status NOT IN ('closed', 'superseded') ORDER BY updated_at DESC LIMIT 1", arguments: [revision.repositoryPath]).map { try Self.decode($0) }
            var changed: [IngestReviewRecord] = []
            if let prior {
                let superseded = prior.updating(status: .superseded, supersededBy: .some(revision.reviewID), updatedAt: now)
                try Self.persistChange(superseded, db: db)
                try Self.saveManifest(try Self.transitionManifest(for: superseded, db: db), db: db)
                try db.execute(sql: "UPDATE jobs SET state = 'cancelled', lease_owner = NULL, lease_expires = NULL WHERE review_id = ? AND kind IN ('materialize', 'notification') AND state != 'succeeded'", arguments: [prior.reviewID.value])
                try db.execute(sql: "DELETE FROM notification_outbox WHERE review_id = ? AND state != 'delivered'", arguments: [prior.reviewID.value])
                changed.append(superseded)
            }
            let record = IngestReviewRecord(
                reviewID: revision.reviewID, revision: revision, repositoryIdentity: submission.repositoryIdentity,
                baseRef: submission.base.label, headRef: submission.head.label, title: submission.title,
                notify: submission.notify, unread: true, stale: false, status: .accepted,
                errorCode: nil, errorMessage: nil, supersedes: prior?.reviewID, supersededBy: nil,
                createdAt: now, updatedAt: now
            )
            try Self.persistChange(record, db: db)
            try Self.saveManifest(Self.manifest(for: record), db: db)
            try Self.enqueueMaterialization(record.reviewID, at: now, db: db)
            try hook?()
            try db.execute(sql: "INSERT INTO ingest_idempotency (idempotency_key, request_digest, review_id) VALUES (?, ?, ?)", arguments: [submission.idempotencyKey.uuidString, digest, record.reviewID.value])
            changed.append(record)
            return (record, .created, prior?.reviewID, changed)
        }
        await publish(result.3)
        return (result.0, result.1, result.2)
    }

    public func review(_ id: ReviewID) async throws -> IngestReviewRecord? {
        try await store.read { db in try Self.fetch(id, db: db) }
    }

    public func reviews(limit: Int? = nil) async throws -> [IngestReviewRecord] {
        try await store.read { db in
            var sql = "SELECT * FROM ingest_reviews ORDER BY updated_at DESC, review_id"
            var arguments: StatementArguments = []
            if let limit { sql += " LIMIT ?"; arguments = [limit] }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try Self.decode($0) }
        }
    }

    /// Advances a durable cursor across active reviews before returning a bounded
    /// page. Wrapping within one page keeps every review in the rotation even
    /// when terminal rows or newly inserted review IDs surround the cursor.
    public func nextStalenessBatch(limit: Int) async throws -> [IngestReviewRecord] {
        let boundedLimit = max(0, min(limit, 64))
        guard boundedLimit > 0 else { return [] }
        return try await store.write { db in
            let key = "rtc.ingest.staleness-cursor"
            let cursorData = try Data.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
            let cursor = cursorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let active = "status NOT IN ('closed', 'superseded')"
            var rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM ingest_reviews WHERE \(active) AND review_id > ? ORDER BY review_id LIMIT ?",
                arguments: [cursor, boundedLimit]
            )
            if rows.count < boundedLimit {
                rows += try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM ingest_reviews WHERE \(active) AND review_id <= ? ORDER BY review_id LIMIT ?",
                    arguments: [cursor, boundedLimit - rows.count]
                )
            }
            let records = try rows.map { try Self.decode($0) }
            if let nextCursor = records.last?.reviewID.value {
                try db.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, Data(nextCursor.utf8)]
                )
            }
            return records
        }
    }

    public func changes(reviewID: ReviewID, after: Int, full: Bool) async throws -> [ReviewStatusResponse] {
        try await store.read { db in
            let limit = full ? 256 : 1
            let order = full ? "ASC" : "DESC"
            let rows = try Data.fetchAll(db, sql: "SELECT payload FROM ingest_changes WHERE review_id = ? AND sequence > ? ORDER BY sequence \(order) LIMIT ?", arguments: [reviewID.value, after, limit])
            let values = try rows.map { try JSONDecoder.rtc.decode(ReviewStatusResponse.self, from: $0) }
            return full ? values : Array(values.reversed())
        }
    }

    public func observe(_ id: ReviewID) -> AsyncStream<Int> {
        let token = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id, token: token) } }
            observers[id, default: [:]][token] = continuation
        }
    }

    public func observeInbox() -> AsyncStream<Void> {
        let token = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in Task { await self?.removeInboxObserver(token) } }
            inboxObservers[token] = continuation
        }
    }

    public func leaseMaterialization(owner: BoundedString, now: Date = Date()) async throws -> IngestJobLease? {
        let result = try await store.write { db -> (IngestJobLease, IngestReviewRecord)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM jobs WHERE kind = 'materialize' AND available_at <= ?
                AND (state = 'queued' OR (state = 'running' AND lease_expires <= ?))
                ORDER BY available_at, id LIMIT 1
                """, arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]) else { return nil }
            let id = UUID(uuidString: row["id"] as String)!
            let reviewID = try ReviewID(row["review_id"] as String)
            guard let record = try Self.fetch(reviewID, db: db) else { throw IngestError.notFound }
            if record.status == .closed || record.status == .superseded {
                try db.execute(sql: "UPDATE jobs SET state = 'cancelled', lease_owner = NULL, lease_expires = NULL WHERE id = ?", arguments: [id.uuidString])
                return nil
            }
            let expiry = now.addingTimeInterval(120)
            try db.execute(sql: "UPDATE jobs SET state = 'running', attempt = attempt + 1, lease_owner = ?, lease_expires = ? WHERE id = ? AND (state = 'queued' OR (state = 'running' AND lease_expires <= ?))", arguments: [owner.value, expiry.timeIntervalSince1970, id.uuidString, now.timeIntervalSince1970])
            guard db.changesCount == 1 else { return nil }
            let changed = record.status == .materializing ? record : record.updating(status: .materializing, errorCode: .some(nil), errorMessage: .some(nil), updatedAt: now)
            if changed != record {
                try Self.persistChange(changed, db: db)
                try Self.saveManifest(Self.manifest(for: changed), db: db)
            }
            return (IngestJobLease(jobID: id, reviewID: reviewID, owner: owner, expiresAt: expiry), changed)
        }
        if let result { await publish([result.1]); return result.0 }
        return nil
    }

    public func completeReady(_ lease: IngestJobLease, evidence: ReviewManifest, now: Date = Date()) async throws {
        let changed = try await store.write { db -> IngestReviewRecord in
            try Self.requireJobLease(lease, db: db)
            guard let record = try Self.fetch(lease.reviewID, db: db), record.status == .materializing else { throw IngestError.invalidTransition }
            guard evidence.id == record.reviewID, evidence.revision == record.revision else { throw IngestError.invalidTransition }
            let ready = record.updating(status: .ready, unread: true, errorCode: .some(nil), errorMessage: .some(nil), updatedAt: now)
            try Self.persistChange(ready, db: db)
            try Self.saveManifest(Self.copy(evidence, record: ready), db: db)
            try Self.finishJob(lease, state: "succeeded", db: db)
            if ready.notify {
                try db.execute(sql: "INSERT INTO notification_outbox (review_id, platform_id, state, attempt, available_at, lease_owner, lease_expires, updated_at) VALUES (?, ?, 'queued', 0, ?, NULL, NULL, ?) ON CONFLICT(review_id) DO NOTHING", arguments: [ready.reviewID.value, "review-\(ready.reviewID.value)", now.timeIntervalSince1970, now.timeIntervalSince1970])
            }
            return ready
        }
        await publish([changed])
    }

    public func completeFailure(_ lease: IngestJobLease, code: String, message: String, now: Date = Date()) async throws {
        let changed = try await store.write { db -> IngestReviewRecord in
            try Self.requireJobLease(lease, db: db)
            guard let record = try Self.fetch(lease.reviewID, db: db) else { throw IngestError.notFound }
            let failed = record.updating(status: .failed, errorCode: .some(code), errorMessage: .some(message), updatedAt: now)
            try Self.persistChange(failed, db: db)
            try Self.saveManifest(Self.manifest(for: failed), db: db)
            try Self.finishJob(lease, state: "failed", db: db)
            return failed
        }
        await publish([changed])
    }

    public func retry(_ id: ReviewID, now: Date = Date()) async throws {
        let changed = try await store.write { db -> IngestReviewRecord in
            guard let record = try Self.fetch(id, db: db), record.status == .failed else { throw IngestError.invalidTransition }
            let accepted = record.updating(status: .accepted, errorCode: .some(nil), errorMessage: .some(nil), updatedAt: now)
            try Self.persistChange(accepted, db: db)
            try Self.saveManifest(Self.manifest(for: accepted), db: db)
            try Self.enqueueMaterialization(id, at: now, db: db, replace: true)
            return accepted
        }
        await publish([changed])
    }

    public func close(_ id: ReviewID, now: Date = Date()) async throws -> IngestReviewRecord {
        let changed = try await store.write { db -> IngestReviewRecord in
            guard let record = try Self.fetch(id, db: db) else { throw IngestError.notFound }
            guard record.status != .superseded else { throw IngestError.invalidTransition }
            let closed = record.updating(status: .closed, updatedAt: now)
            try Self.persistChange(closed, db: db)
            try Self.saveManifest(try Self.transitionManifest(for: closed, db: db), db: db)
            try db.execute(sql: "UPDATE jobs SET state = 'cancelled', lease_owner = NULL, lease_expires = NULL WHERE review_id = ? AND state != 'succeeded'", arguments: [id.value])
            try db.execute(sql: "DELETE FROM notification_outbox WHERE review_id = ? AND state != 'delivered'", arguments: [id.value])
            return closed
        }
        await publish([changed]); return changed
    }

    public func markRead(_ id: ReviewID) async throws {
        let changed = try await store.write { db -> IngestReviewRecord? in
            guard let record = try Self.fetch(id, db: db) else { throw IngestError.notFound }
            guard record.unread else { return nil }
            let value = record.updating(unread: false)
            try Self.persistChange(value, db: db); try Self.saveManifest(try Self.transitionManifest(for: value, db: db), db: db)
            return value
        }
        if let changed { await publish([changed]) }
    }

    public func markStale(_ id: ReviewID) async throws {
        try await updateRefresh(id) { record in record.stale ? nil : record.updating(stale: true, refreshErrorCode: .some(nil), refreshErrorMessage: .some(nil)) }
    }

    public func clearRefreshError(_ id: ReviewID) async throws {
        try await updateRefresh(id) { record in
            guard record.refreshErrorCode != nil || record.refreshErrorMessage != nil else { return nil }
            return record.updating(refreshErrorCode: .some(nil), refreshErrorMessage: .some(nil))
        }
    }

    public func recordRefreshError(_ id: ReviewID, code: String, message: String) async throws {
        try await updateRefresh(id) { record in
            guard record.refreshErrorCode != code || record.refreshErrorMessage != message else { return nil }
            return record.updating(refreshErrorCode: .some(code), refreshErrorMessage: .some(message))
        }
    }

    public func claimNotification(owner: BoundedString, now: Date = Date()) async throws -> NotificationLease? {
        try await store.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM notification_outbox WHERE available_at <= ? AND (state = 'queued' OR (state = 'claimed' AND lease_expires <= ?)) ORDER BY available_at, review_id LIMIT 1", arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]) else { return nil }
            let reviewID = try ReviewID(row["review_id"] as String); let expiry = now.addingTimeInterval(30)
            try db.execute(sql: "UPDATE notification_outbox SET state = 'claimed', attempt = attempt + 1, lease_owner = ?, lease_expires = ?, updated_at = ? WHERE review_id = ? AND (state = 'queued' OR (state = 'claimed' AND lease_expires <= ?))", arguments: [owner.value, expiry.timeIntervalSince1970, now.timeIntervalSince1970, reviewID.value, now.timeIntervalSince1970])
            guard db.changesCount == 1 else { return nil }
            return NotificationLease(reviewID: reviewID, owner: owner, platformID: row["platform_id"], expiresAt: expiry)
        }
    }

    public func completeNotification(_ lease: NotificationLease, now: Date = Date()) async throws {
        try await updateNotification(lease, state: "delivered", availableAt: now, now: now)
    }

    public func retryNotification(_ lease: NotificationLease, now: Date = Date()) async throws {
        try await store.write { db in
            let attempt = try Int.fetchOne(db, sql: "SELECT attempt FROM notification_outbox WHERE review_id = ? AND state = 'claimed' AND lease_owner = ? AND lease_expires > ?", arguments: [lease.reviewID.value, lease.owner.value, now.timeIntervalSince1970])
            guard let attempt else { throw RTCStoreError.leaseLost }
            let next = now.addingTimeInterval(min(pow(2, Double(attempt)), 300))
            try db.execute(sql: "UPDATE notification_outbox SET state = 'queued', available_at = ?, lease_owner = NULL, lease_expires = NULL, updated_at = ? WHERE review_id = ? AND state = 'claimed' AND lease_owner = ? AND lease_expires > ?", arguments: [next.timeIntervalSince1970, now.timeIntervalSince1970, lease.reviewID.value, lease.owner.value, now.timeIntervalSince1970])
            guard db.changesCount == 1 else { throw RTCStoreError.leaseLost }
        }
    }

    public func reconcile(now: Date = Date()) async throws {
        let changed = try await store.write { db -> [IngestReviewRecord] in
            let records = try Row.fetchAll(db, sql: "SELECT * FROM ingest_reviews").map { try Self.decode($0) }
            for record in records {
                try Self.saveManifest(try Self.transitionManifest(for: record, db: db), db: db)
                if record.status == .accepted || record.status == .materializing { try Self.enqueueMaterialization(record.reviewID, at: now, db: db, replace: true) }
                if record.status == .ready && record.notify {
                    try db.execute(sql: "INSERT INTO notification_outbox (review_id, platform_id, state, attempt, available_at, lease_owner, lease_expires, updated_at) SELECT ?, ?, 'queued', 0, ?, NULL, NULL, ? WHERE NOT EXISTS (SELECT 1 FROM notification_deliveries WHERE review_id = ?) ON CONFLICT(review_id) DO NOTHING", arguments: [record.reviewID.value, "review-\(record.reviewID.value)", now.timeIntervalSince1970, now.timeIntervalSince1970, record.reviewID.value])
                }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM ingest_changes WHERE review_id = ? LIMIT 1", arguments: [record.reviewID.value]) == nil { try Self.insertChange(record, db: db) }
            }
            return records
        }
        await publish(changed)
    }

    public func spoolRetry(fileName: String) async throws -> (attempt: Int, nextRetry: Date)? {
        try await store.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT attempt, next_retry FROM spool_retries WHERE file_name = ?", arguments: [fileName]) else { return nil }
            return (row["attempt"], Date(timeIntervalSince1970: row["next_retry"]))
        }
    }

    public func recordSpoolRetry(fileName: String, code: String, now: Date = Date()) async throws -> (attempt: Int, nextRetry: Date) {
        try await store.write { db in
            let attempt = (try Int.fetchOne(db, sql: "SELECT attempt FROM spool_retries WHERE file_name = ?", arguments: [fileName]) ?? 0) + 1
            let next = now.addingTimeInterval(min(pow(2, Double(attempt)), 300))
            try db.execute(sql: "INSERT INTO spool_retries (file_name, attempt, next_retry, error_code) VALUES (?, ?, ?, ?) ON CONFLICT(file_name) DO UPDATE SET attempt = excluded.attempt, next_retry = excluded.next_retry, error_code = excluded.error_code", arguments: [fileName, attempt, next.timeIntervalSince1970, code])
            return (attempt, next)
        }
    }

    public func clearSpoolRetry(fileName: String) async throws { try await store.write { db in try db.execute(sql: "DELETE FROM spool_retries WHERE file_name = ?", arguments: [fileName]) } }

    public func recordRuntimeFailure(code: String, message: String) async throws {
        try await store.write { db in
            try db.execute(sql: "INSERT INTO ingest_runtime_failures (code, message, created_at) VALUES (?, ?, ?)", arguments: [code, message, Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM ingest_runtime_failures WHERE id NOT IN (SELECT id FROM ingest_runtime_failures ORDER BY id DESC LIMIT 128)")
        }
    }

    private func updateRefresh(_ id: ReviewID, transform: @escaping @Sendable (IngestReviewRecord) -> IngestReviewRecord?) async throws {
        let changed = try await store.write { db -> IngestReviewRecord? in
            guard let record = try Self.fetch(id, db: db) else { throw IngestError.notFound }
            guard let value = transform(record) else { return nil }
            try Self.persistChange(value, db: db); try Self.saveManifest(try Self.transitionManifest(for: value, db: db), db: db); return value
        }
        if let changed { await publish([changed]) }
    }

    private func updateNotification(_ lease: NotificationLease, state: String, availableAt: Date, now: Date) async throws {
        try await store.write { db in
            try db.execute(sql: "UPDATE notification_outbox SET state = ?, available_at = ?, lease_owner = NULL, lease_expires = NULL, updated_at = ? WHERE review_id = ? AND state = 'claimed' AND lease_owner = ? AND lease_expires > ?", arguments: [state, availableAt.timeIntervalSince1970, now.timeIntervalSince1970, lease.reviewID.value, lease.owner.value, now.timeIntervalSince1970])
            guard db.changesCount == 1 else { throw RTCStoreError.leaseLost }
        }
    }

    private func publish(_ records: [IngestReviewRecord]) async {
        guard !records.isEmpty else { return }
        for record in records {
            if let continuations = observers[record.reviewID]?.values { for continuation in continuations { continuation.yield(record.changeSequence) } }
            await store.publish(StoreSnapshot(review: Self.manifest(for: record)))
        }
        for continuation in inboxObservers.values { continuation.yield(()) }
    }

    private func removeObserver(_ id: ReviewID, token: UUID) { observers[id]?[token] = nil }
    private func removeInboxObserver(_ token: UUID) { inboxObservers[token] = nil }

    private static func fetch(_ id: ReviewID, db: Database) throws -> IngestReviewRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM ingest_reviews WHERE review_id = ?", arguments: [id.value]).map { try decode($0) }
    }

    private static func decode(_ row: Row) throws -> IngestReviewRecord {
        let revision = try RevisionIdentity(repositoryPath: row["repository_path"], baseSHA: row["base_sha"], headSHA: row["head_sha"])
        guard let status = ReviewStatus(rawValue: row["status"]) else { throw RTCStoreError.corrupt("ingest status") }
        return IngestReviewRecord(
            reviewID: try ReviewID(row["review_id"]), revision: revision,
            repositoryIdentity: try SHA256Digest(row["repository_identity"]),
            baseRef: row["base_ref"], headRef: row["head_ref"], title: row["title"], notify: row["notify"],
            unread: row["unread"], stale: row["stale"], status: status, errorCode: row["error_code"], errorMessage: row["error_message"],
            refreshErrorCode: row["refresh_error_code"], refreshErrorMessage: row["refresh_error_message"],
            supersedes: try (row["supersedes"] as String?).map(ReviewID.init), supersededBy: try (row["superseded_by"] as String?).map(ReviewID.init),
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]), changeSequence: row["change_sequence"]
        )
    }

    private static func persistChange(_ record: IngestReviewRecord, db: Database) throws { try persist(record, db: db); try insertChange(record, db: db) }

    private static func insertChange(_ record: IngestReviewRecord, db: Database) throws {
        let payload = try JSONEncoder.rtc.encode(ReviewStatusResponse(record: record))
        try db.execute(sql: "INSERT OR REPLACE INTO ingest_changes (review_id, sequence, payload, created_at) VALUES (?, ?, ?, ?)", arguments: [record.reviewID.value, record.changeSequence, payload, record.updatedAt.timeIntervalSince1970])
    }

    private static func persist(_ record: IngestReviewRecord, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO ingest_reviews (review_id, repository_path, repository_identity, base_sha, head_sha, base_ref, head_ref, title, notify, unread, stale, status, error_code, error_message, refresh_error_code, refresh_error_message, supersedes, superseded_by, created_at, updated_at, change_sequence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(review_id) DO UPDATE SET unread=excluded.unread, stale=excluded.stale, status=excluded.status, error_code=excluded.error_code, error_message=excluded.error_message, refresh_error_code=excluded.refresh_error_code, refresh_error_message=excluded.refresh_error_message, superseded_by=excluded.superseded_by, updated_at=excluded.updated_at, change_sequence=excluded.change_sequence
            """, arguments: [record.reviewID.value, record.revision.repositoryPath, record.repositoryIdentity.hex, record.revision.baseSHA, record.revision.headSHA, record.baseRef, record.headRef, record.title, record.notify, record.unread, record.stale, record.status.rawValue, record.errorCode, record.errorMessage, record.refreshErrorCode, record.refreshErrorMessage, record.supersedes?.value, record.supersededBy?.value, record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970, record.changeSequence])
    }

    private static func enqueueMaterialization(_ id: ReviewID, at date: Date, db: Database, replace: Bool = false) throws {
        let jobID = UUID().uuidString
        if replace {
            try db.execute(sql: "INSERT INTO jobs (id, kind, review_id, state, attempt, available_at, lease_owner, lease_expires) VALUES (?, 'materialize', ?, 'queued', 0, ?, NULL, NULL) ON CONFLICT(kind, review_id) DO UPDATE SET state='queued', available_at=excluded.available_at, lease_owner=NULL, lease_expires=NULL WHERE jobs.state != 'running' OR jobs.lease_expires <= excluded.available_at", arguments: [jobID, id.value, date.timeIntervalSince1970])
        } else {
            try db.execute(sql: "INSERT OR IGNORE INTO jobs (id, kind, review_id, state, attempt, available_at, lease_owner, lease_expires) VALUES (?, 'materialize', ?, 'queued', 0, ?, NULL, NULL)", arguments: [jobID, id.value, date.timeIntervalSince1970])
        }
    }

    private static func requireJobLease(_ lease: IngestJobLease, db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT 1 FROM jobs WHERE id = ? AND review_id = ? AND state = 'running' AND lease_owner = ? AND lease_expires > ?", arguments: [lease.jobID.uuidString, lease.reviewID.value, lease.owner.value, Date().timeIntervalSince1970])
        guard count != nil else { throw RTCStoreError.leaseLost }
    }

    private static func finishJob(_ lease: IngestJobLease, state: String, db: Database) throws {
        try db.execute(sql: "UPDATE jobs SET state = ?, lease_owner = NULL, lease_expires = NULL WHERE id = ? AND lease_owner = ? AND state = 'running'", arguments: [state, lease.jobID.uuidString, lease.owner.value])
        guard db.changesCount == 1 else { throw RTCStoreError.leaseLost }
    }

    private static func manifest(for record: IngestReviewRecord) -> ReviewManifest {
        ReviewManifest(id: record.reviewID, revision: record.revision, createdAt: record.createdAt, updatedAt: record.updatedAt, status: record.status, stale: record.stale, summary: ReviewSummary(files: 0, additions: 0, deletions: 0), files: [])
    }

    private static func copy(_ evidence: ReviewManifest, record: IngestReviewRecord) -> ReviewManifest {
        ReviewManifest(id: record.reviewID, revision: record.revision, createdAt: record.createdAt, updatedAt: record.updatedAt, status: record.status, stale: record.stale, summary: evidence.summary, files: evidence.files)
    }

    private static func transitionManifest(for record: IngestReviewRecord, db: Database) throws -> ReviewManifest {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM reviews WHERE id = ?", arguments: [record.reviewID.value]) else { return manifest(for: record) }
        let existing: ReviewManifest
        do { existing = try JSONDecoder.rtc.decode(ReviewManifest.self, from: data) }
        catch { throw RTCStoreError.corrupt("review manifest") }
        return copy(existing, record: record)
    }

    private static func saveManifest(_ manifest: ReviewManifest, db: Database) throws {
        let data = try JSONEncoder.rtc.encode(manifest)
        try db.execute(sql: "INSERT INTO reviews (id, repo_path, base_sha, head_sha, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at", arguments: [manifest.id.value, manifest.revision.repositoryPath, manifest.revision.baseSHA, manifest.revision.headSHA, data, manifest.updatedAt.timeIntervalSince1970])
    }
}

public actor SQLiteNotificationDeliveryStore: NotificationDeliveryStore {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }
    public func wasDelivered(reviewID: ReviewID) async throws -> Bool { try await store.read { db in try Int.fetchOne(db, sql: "SELECT 1 FROM notification_deliveries WHERE review_id = ?", arguments: [reviewID.value]) != nil } }
    public func markDelivered(reviewID: ReviewID) async throws { try await store.write { db in try db.execute(sql: "INSERT OR IGNORE INTO notification_deliveries (review_id, delivered_at) VALUES (?, ?)", arguments: [reviewID.value, Date().timeIntervalSince1970]) } }
}

private extension JSONEncoder { static var rtc: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value } }
private extension JSONDecoder { static var rtc: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value } }
