import CryptoKit
import Foundation
import GRDB
import RTCContracts

public enum RTCStoreError: Error, Equatable, Sendable {
    case readOnly
    case corrupt(String)
    case invalidBlob
    case leaseLost
}

public struct StoreSnapshot: Sendable, Equatable {
    public let review: ReviewManifest
    public init(review: ReviewManifest) { self.review = review }
}

public actor SQLiteStore {
    public let rootURL: URL
    private let database: DatabaseQueue
    private var observations: [ReviewID: [UUID: AsyncStream<StoreSnapshot>.Continuation]] = [:]

    public init(rootURL: URL, readOnly: Bool = false) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Self.protect(rootURL, mode: 0o700)
        let dbURL = rootURL.appendingPathComponent("ReviewStore.sqlite")
        if readOnly {
            var config = Configuration()
            config.readonly = true
            database = try DatabaseQueue(path: dbURL.path, configuration: config)
        } else {
            database = try DatabaseQueue(path: dbURL.path)
            try Self.configure(database)
            try Self.migrate(database)
            try Self.protect(dbURL, mode: 0o600)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: dbURL.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) { try Self.protect(sidecar, mode: 0o600) }
            }
        }
    }

    public func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) throws -> T {
        try database.write(body)
    }

    public func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) throws -> T {
        try database.read(body)
    }

    public func observe(_ id: ReviewID) -> AsyncStream<StoreSnapshot> {
        let token = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObservation(id, token: token) }
            }
            observations[id, default: [:]][token] = continuation
        }
    }

    public func publish(_ snapshot: StoreSnapshot) {
        guard let continuations = observations[snapshot.review.id]?.values else { return }
        for continuation in continuations { continuation.yield(snapshot) }
    }

    private func removeObservation(_ id: ReviewID, token: UUID) { observations[id]?[token] = nil }

    private static func configure(_ db: DatabaseQueue) throws {
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")
        }
    }

    private static func migrate(_ db: DatabaseQueue) throws {
        try db.writeWithoutTransaction { db in
            try db.execute(
                sql: "CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY, checksum TEXT NOT NULL);")
            for (id, sql) in [(1, Migration.v1), (2, Migration.v2), (3, Migration.v3)] {
                let checksum = SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
                let existing = try String.fetchOne(db, sql: "SELECT checksum FROM schema_migrations WHERE id = ?", arguments: [id])
                if let existing, existing != checksum { throw RTCStoreError.corrupt("migration checksum") }
                if existing == nil {
                    try db.execute(sql: sql)
                    try db.execute(sql: "INSERT INTO schema_migrations (id, checksum) VALUES (?, ?)", arguments: [id, checksum])
                }
            }
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            guard result == "ok" else { throw RTCStoreError.corrupt(result ?? "integrity check failed") }
        }
    }

    private static func protect(_ url: URL, mode: mode_t) throws {
        guard chmod(url.path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
    }
}

public final class SQLiteReviewRepository: ReviewRepository, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func review(id: ReviewID) async throws -> ReviewManifest? {
        try await store.read { db in
            guard
                let data = try Data.fetchOne(db, sql: "SELECT payload FROM reviews WHERE id = ?", arguments: [id.value])
            else { return nil }
            return try JSONDecoder.rtc.decode(ReviewManifest.self, from: data)
        }
    }

    public func save(_ review: ReviewManifest) async throws {
        let data = try JSONEncoder.rtc.encode(review)
        try await store.write { db in
            try db.execute(
                sql:
                    "INSERT INTO reviews (id, repo_path, base_sha, head_sha, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
                arguments: [
                    review.id.value, review.revision.repositoryPath, review.revision.baseSHA, review.revision.headSHA,
                    data, review.updatedAt.timeIntervalSince1970,
                ])
        }
        await store.publish(StoreSnapshot(review: review))
    }

    public func markStale(_ id: ReviewID) async throws {
        guard let review = try await review(id: id) else { return }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder.rtc.encode(review)) as! [String: Any]
        object["stale"] = true
        object["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let updated = try JSONDecoder.rtc.decode(
            ReviewManifest.self, from: JSONSerialization.data(withJSONObject: object))
        try await save(updated)
    }
}

public final class SQLiteEventRepository: EventRepository, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func append(_ proposal: PendingReviewEvent, after expectedSequence: Int) async throws -> ReviewEvent {
        try await store.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM review_events WHERE event_id = ?", arguments: [proposal.id.uuidString]) {
                let stored = try JSONDecoder.rtc.decode(ReviewEvent.self, from: data)
                guard stored.reviewID == proposal.reviewID, stored.revision == proposal.revision, stored.kind == proposal.kind, stored.payload == proposal.payload, stored.createdAt == proposal.createdAt else { throw EventRepositoryError.idempotencyConflict }
                return stored
            }
            guard let reviewData = try Data.fetchOne(db, sql: "SELECT payload FROM reviews WHERE id = ?", arguments: [proposal.reviewID.value]) else { throw EventRepositoryError.reviewUnavailable }
            let review = try JSONDecoder.rtc.decode(ReviewManifest.self, from: reviewData)
            guard review.id == proposal.reviewID, review.revision == proposal.revision, !review.stale,
                  ![.approved, .changesRequested, .closed, .superseded].contains(review.status) else { throw EventRepositoryError.reviewUnavailable }
            let current = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) FROM review_events WHERE review_id = ?", arguments: [proposal.reviewID.value])) ?? 0
            guard current == expectedSequence else { throw EventRepositoryError.concurrentModification }
            let event = ReviewEvent(id: proposal.id, reviewID: proposal.reviewID, revision: proposal.revision, sequence: current + 1, kind: proposal.kind, payload: proposal.payload, createdAt: proposal.createdAt)
            let data = try JSONEncoder.rtc.encode(event)
            try db.execute(sql: "INSERT INTO review_events (review_id, sequence, event_id, payload, created_at) VALUES (?, ?, ?, ?, ?)", arguments: [event.reviewID.value, event.sequence, event.id.uuidString, data, event.createdAt.timeIntervalSince1970])
            return event
        }
    }

    public func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] {
        try await store.read { db in
            try Data.fetchAll(
                db, sql: "SELECT payload FROM review_events WHERE review_id = ? AND sequence > ? ORDER BY sequence",
                arguments: [reviewID.value, sequence]
            ).map { try JSONDecoder.rtc.decode(ReviewEvent.self, from: $0) }
        }
    }

}

/// Private SQLite-backed replay log. Event/request identities make delivery and
/// retried replies idempotent without exposing conversation state to a repo.
public final class SQLiteConversationEventRepository: ConversationReplayRepository, ConversationRequestJournal, @unchecked Sendable {
    private let store: SQLiteStore
    private static let maximumEventBytes = 256 * 1024
    public init(store: SQLiteStore) { self.store = store }

    public func append(_ event: ConversationEvent) async throws {
        let data = try JSONEncoder.rtc.encode(event)
        guard data.count <= Self.maximumEventBytes else { throw RTCStoreError.corrupt("conversation event limit") }
        try await store.write { db in
            try self.bind(db, reviewID: event.reviewID, conversationID: event.conversationID)
            if let existing = try Data.fetchOne(db, sql: "SELECT payload FROM conversation_events WHERE event_id = ?", arguments: [event.id.uuidString]) {
                guard try JSONDecoder.rtc.decode(ConversationEvent.self, from: existing) == event else { throw RTCStoreError.corrupt("conversation event id collision") }
                return
            }
            let next = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM conversation_events WHERE conversation_id = ?", arguments: [event.conversationID.uuidString])) ?? 1
            guard event.sequence == next else { throw RTCStoreError.corrupt("conversation sequence") }
            try db.execute(sql: "INSERT INTO conversation_events (conversation_id, sequence, event_id, payload) VALUES (?, ?, ?, ?)", arguments: [event.conversationID.uuidString, event.sequence, event.id.uuidString, data])
        }
    }

    public func replay(reviewID: ReviewID, conversationID: UUID, after sequence: Int) async throws -> [ConversationEvent] {
        guard sequence >= 0 else { throw RTCStoreError.corrupt("negative conversation cursor") }
        return try await store.read { db in
            try self.requireBinding(db, reviewID: reviewID, conversationID: conversationID)
            return try Data.fetchAll(db, sql: "SELECT payload FROM conversation_events WHERE conversation_id = ? AND sequence > ? ORDER BY sequence", arguments: [conversationID.uuidString, sequence]).map {
                let event = try JSONDecoder.rtc.decode(ConversationEvent.self, from: $0)
                guard event.reviewID == reviewID else { throw RTCStoreError.corrupt("conversation review mismatch") }
                return event
            }
        }
    }

    public func state(reviewID: ReviewID, conversationID: UUID) async throws -> [ConversationEvent] {
        try await store.read { db in
            guard let binding = try String.fetchOne(db, sql: "SELECT review_id FROM conversations WHERE id = ?", arguments: [conversationID.uuidString]) else { return [] }
            guard binding == reviewID.value else { throw RTCStoreError.corrupt("conversation scope") }
            return try Data.fetchAll(db, sql: "SELECT payload FROM conversation_events WHERE conversation_id = ? ORDER BY sequence", arguments: [conversationID.uuidString]).map { try JSONDecoder.rtc.decode(ConversationEvent.self, from: $0) }
        }
    }

    public func page(reviewID: ReviewID, conversationID: UUID, after: Int, maximumEvents: Int, maximumBytes: Int) async throws -> ConversationPage {
        guard after >= 0, maximumEvents > 0, maximumBytes > 0 else { throw RTCStoreError.corrupt("invalid conversation page") }
        return try await store.read { db in
            try self.requireBinding(db, reviewID: reviewID, conversationID: conversationID)
            let last = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) FROM conversation_events WHERE conversation_id = ?", arguments: [conversationID.uuidString])) ?? 0
            guard after <= last else { throw RTCStoreError.corrupt("conversation cursor ahead") }
            let rows = try Data.fetchAll(db, sql: "SELECT payload FROM conversation_events WHERE conversation_id = ? AND sequence > ? ORDER BY sequence LIMIT ?", arguments: [conversationID.uuidString, after, maximumEvents + 1])
            var bytes = 0; var events: [ConversationEvent] = []; var hasMore = rows.count > maximumEvents
            for data in rows.prefix(maximumEvents) {
                guard data.count <= maximumBytes - bytes else { hasMore = true; break }
                events.append(try JSONDecoder.rtc.decode(ConversationEvent.self, from: data)); bytes += data.count
            }
            return ConversationPage(after: after, nextCursor: events.last?.sequence ?? after, events: events, hasMore: hasMore)
        }
    }

    public func commit(reviewID: ReviewID, conversationID: UUID, requestID: UUID, operation: String, payloadDigest: RTCContracts.SHA256Digest, events: [ConversationEvent]) async throws -> ConversationRequestCommit {
        try await store.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT operation, payload_digest, response FROM conversation_requests WHERE review_id = ? AND conversation_id = ? AND request_id = ?", arguments: [reviewID.value, conversationID.uuidString, requestID.uuidString]) {
                guard row["operation"] as String == operation, row["payload_digest"] as String == payloadDigest.hex else { throw RTCStoreError.corrupt("conversation request conflict") }
                return ConversationRequestCommit(events: try JSONDecoder.rtc.decode([ConversationEvent].self, from: row["response"] as Data), reused: true)
            }
            try self.bind(db, reviewID: reviewID, conversationID: conversationID)
            let last = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) FROM conversation_events WHERE conversation_id = ?", arguments: [conversationID.uuidString])) ?? 0
            guard !events.isEmpty, events.enumerated().allSatisfy({ $0.element.reviewID == reviewID && $0.element.conversationID == conversationID && $0.element.sequence == last + $0.offset + 1 }) else { throw RTCStoreError.corrupt("conversation request sequence") }
            for event in events {
                let encoded = try JSONEncoder.rtc.encode(event)
                guard encoded.count <= Self.maximumEventBytes else { throw RTCStoreError.corrupt("conversation event limit") }
                try db.execute(sql: "INSERT INTO conversation_events (conversation_id, sequence, event_id, payload) VALUES (?, ?, ?, ?)", arguments: [conversationID.uuidString, event.sequence, event.id.uuidString, encoded])
            }
            let response = try JSONEncoder.rtc.encode(events)
            try db.execute(sql: "INSERT INTO conversation_requests (review_id, conversation_id, request_id, operation, payload_digest, response, first_sequence, last_sequence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [reviewID.value, conversationID.uuidString, requestID.uuidString, operation, payloadDigest.hex, response, events.first!.sequence, events.last!.sequence])
            return ConversationRequestCommit(events: events, reused: false)
        }
    }

    private func bind(_ db: Database, reviewID: ReviewID, conversationID: UUID) throws {
        if let existing = try String.fetchOne(db, sql: "SELECT review_id FROM conversations WHERE id = ?", arguments: [conversationID.uuidString]) { guard existing == reviewID.value else { throw RTCStoreError.corrupt("conversation scope") }; return }
        try db.execute(sql: "INSERT INTO conversations (id, review_id, payload) VALUES (?, ?, ?)", arguments: [conversationID.uuidString, reviewID.value, Data()])
    }
    private func requireBinding(_ db: Database, reviewID: ReviewID, conversationID: UUID) throws {
        guard let existing = try String.fetchOne(db, sql: "SELECT review_id FROM conversations WHERE id = ?", arguments: [conversationID.uuidString]), existing == reviewID.value else { throw RTCStoreError.corrupt("conversation scope") }
    }
}

public final class JobQueue: JobRepository, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func enqueue(_ job: JobRecord) async throws {
        try await store.write { db in
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO jobs (id, kind, review_id, state, attempt, available_at, lease_owner) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    job.id.uuidString, job.kind.rawValue, job.reviewID.value, job.state.rawValue, job.attempt,
                    job.availableAt.timeIntervalSince1970, job.leaseOwner?.value,
                ])
        }
    }

    public func leaseNext(owner: BoundedString, now: Date) async throws -> (JobRecord, JobLease)? {
        try await leaseNext(kind: nil, owner: owner, now: now)
    }

    public func leaseNext(kind: JobKind, owner: BoundedString, now: Date) async throws -> (JobRecord, JobLease)? {
        try await leaseNext(kind: Optional(kind), owner: owner, now: now)
    }

    private func leaseNext(kind requestedKind: JobKind?, owner: BoundedString, now: Date) async throws -> (
        JobRecord, JobLease
    )? {
        try await store.write { db in
            let row: Row?
            if let requestedKind {
                row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM jobs WHERE kind = ? AND state = 'queued' AND available_at <= ? ORDER BY available_at, id LIMIT 1",
                    arguments: [requestedKind.rawValue, now.timeIntervalSince1970])
            } else {
                row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM jobs WHERE state = 'queued' AND available_at <= ? ORDER BY available_at, id LIMIT 1",
                    arguments: [now.timeIntervalSince1970])
            }
            guard let row else { return nil }
            guard let id = UUID(uuidString: row["id"] as String), let kind = JobKind(rawValue: row["kind"] as String)
            else { throw RTCStoreError.corrupt("job") }
            let expiry = now.addingTimeInterval(30)
            try db.execute(
                sql:
                    "UPDATE jobs SET state = 'running', attempt = attempt + 1, lease_owner = ?, lease_expires = ? WHERE id = ? AND state = 'queued'",
                arguments: [owner.value, expiry.timeIntervalSince1970, id.uuidString])
            guard db.changesCount == 1 else { throw RTCStoreError.leaseLost }
            let job = JobRecord(
                id: id, kind: kind, reviewID: try ReviewID(row["review_id"] as String), state: .running,
                attempt: (row["attempt"] as Int) + 1,
                availableAt: Date(timeIntervalSince1970: row["available_at"] as Double), leaseOwner: owner)
            return (job, JobLease(jobID: id, owner: owner, expiresAt: expiry))
        }
    }

    public func renew(_ lease: JobLease, now: Date) async throws -> JobLease {
        let renewed = JobLease(jobID: lease.jobID, owner: lease.owner, expiresAt: now.addingTimeInterval(30))
        try await store.write { db in
            try db.execute(
                sql:
                    "UPDATE jobs SET lease_expires = ? WHERE id = ? AND state = 'running' AND lease_owner = ? AND lease_expires >= ?",
                arguments: [
                    renewed.expiresAt.timeIntervalSince1970, lease.jobID.uuidString, lease.owner.value,
                    now.timeIntervalSince1970,
                ])
            guard db.changesCount == 1 else { throw RTCStoreError.leaseLost }
        }
        return renewed
    }

    public func requeueExpired(kind: JobKind, now: Date) async throws -> [UUID] {
        try await store.write { db in
            let ids = try String.fetchAll(
                db, sql: "SELECT id FROM jobs WHERE kind = ? AND state = 'running' AND lease_expires < ? ORDER BY id",
                arguments: [kind.rawValue, now.timeIntervalSince1970]
            ).compactMap(UUID.init(uuidString:))
            try db.execute(
                sql:
                    "UPDATE jobs SET state = 'queued', lease_owner = NULL, lease_expires = NULL, available_at = ? WHERE kind = ? AND state = 'running' AND lease_expires < ?",
                arguments: [now.timeIntervalSince1970, kind.rawValue, now.timeIntervalSince1970])
            return ids
        }
    }

    public func job(id: UUID) async throws -> JobRecord? {
        try await store.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]),
                let kind = JobKind(rawValue: row["kind"] as String),
                let state = JobState(rawValue: row["state"] as String)
            else { return nil }
            let owner: BoundedString? = try (row["lease_owner"] as String?).map {
                try BoundedString($0, maxCharacters: 4_096)
            }
            return JobRecord(
                id: id, kind: kind, reviewID: try ReviewID(row["review_id"] as String), state: state,
                attempt: row["attempt"], availableAt: Date(timeIntervalSince1970: row["available_at"]),
                leaseOwner: owner)
        }
    }

    public func complete(_ jobID: UUID, state: JobState) async throws {
        try await store.write { db in
            try db.execute(
                sql: "UPDATE jobs SET state = ?, lease_owner = NULL, lease_expires = NULL WHERE id = ?",
                arguments: [state.rawValue, jobID.uuidString])
        }
    }
}

public final class BlobStore: @unchecked Sendable {
    public let rootURL: URL
    public init(rootURL: URL) throws {
        self.rootURL = rootURL.appendingPathComponent("blobs/sha256", isDirectory: true);
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true);
        try Self.protect(self.rootURL, mode: 0o700)
    }
    public func put(_ data: Data) throws -> RTCContracts.SHA256Digest {
        let digest = RTCContracts.SHA256Digest(data: data);
        let dir = rootURL.appendingPathComponent(String(digest.hex.prefix(2)), isDirectory: true);
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(digest.hex + ".rtcb");
        if FileManager.default.fileExists(atPath: target.path) { return digest }
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)");
        try data.write(to: temp, options: [.atomic]); try Self.protect(temp, mode: 0o600);
        let fd = open(temp.path, O_RDONLY); if fd >= 0 { _ = fsync(fd); close(fd) }
        do {
            try FileManager.default.moveItem(at: temp, to: target); try Self.protect(target, mode: 0o600)
        } catch CocoaError.fileWriteFileExists { try? FileManager.default.removeItem(at: temp) }
        return digest
    }
    public func get(_ digest: RTCContracts.SHA256Digest) throws -> Data {
        let data = try Data(
            contentsOf: rootURL.appendingPathComponent(String(digest.hex.prefix(2))).appendingPathComponent(
                digest.hex + ".rtcb"));
        guard RTCContracts.SHA256Digest(data: data) == digest else { throw RTCStoreError.invalidBlob }; return data
    }

    @discardableResult
    public func collectOrphans(
        referenced: Set<RTCContracts.SHA256Digest>, olderThan cutoff: Date = Date().addingTimeInterval(-24 * 60 * 60)
    ) throws -> Int {
        var removed = 0
        for prefix in try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
        {
            guard (try? prefix.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            for file in try FileManager.default.contentsOfDirectory(
                at: prefix, includingPropertiesForKeys: [.contentModificationDateKey])
            where file.pathExtension == "rtcb" {
                guard
                    let digest = try? RTCContracts.SHA256Digest(String(file.deletingPathExtension().lastPathComponent)),
                    !referenced.contains(digest),
                    let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                    date < cutoff
                else { continue }
                try FileManager.default.removeItem(at: file); removed += 1
            }
        }
        return removed
    }

    private static func protect(_ url: URL, mode: mode_t) throws {
        guard chmod(url.path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
    }
}

private extension JSONEncoder {
    static var rtc: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var rtc: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private enum Migration {
    static let v1 = """
        CREATE TABLE reviews (id TEXT PRIMARY KEY, repo_path TEXT NOT NULL, base_sha TEXT NOT NULL, head_sha TEXT NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE review_events (review_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(review_id, sequence));
        CREATE TABLE jobs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, review_id TEXT NOT NULL, state TEXT NOT NULL, attempt INTEGER NOT NULL, available_at REAL NOT NULL, lease_owner TEXT, lease_expires REAL);
        CREATE TABLE review_files (review_id TEXT NOT NULL, path TEXT NOT NULL, blob_digest TEXT, ordinal INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(review_id, path));
        CREATE TABLE threads (id TEXT PRIMARY KEY, review_id TEXT NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE thread_messages (thread_id TEXT NOT NULL, sequence INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(thread_id, sequence));
        CREATE TABLE file_progress (review_id TEXT NOT NULL, path TEXT NOT NULL, viewed INTEGER NOT NULL, viewed_at REAL, version INTEGER NOT NULL, PRIMARY KEY(review_id, path));
        CREATE TABLE tour_documents (review_id TEXT NOT NULL, tour_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(review_id, tour_id));
        CREATE TABLE tour_runs (id TEXT PRIMARY KEY, review_id TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE conversations (id TEXT PRIMARY KEY, review_id TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE conversation_events (conversation_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL, PRIMARY KEY(conversation_id, sequence));
        CREATE TABLE settings (key TEXT PRIMARY KEY, value BLOB NOT NULL);
        """
    static let v2 = """
    CREATE INDEX IF NOT EXISTS conversation_events_replay ON conversation_events(conversation_id, sequence);
    """
    static let v3 = """
    INSERT OR IGNORE INTO conversations (id, review_id, payload)
      SELECT conversation_id,
        CASE json_type(CAST(payload AS TEXT), '$.reviewID')
          WHEN 'object' THEN json_extract(CAST(payload AS TEXT), '$.reviewID.value')
          ELSE json_extract(CAST(payload AS TEXT), '$.reviewID') END,
        X'' FROM conversation_events GROUP BY conversation_id;
    CREATE TABLE conversation_requests (review_id TEXT NOT NULL, conversation_id TEXT NOT NULL, request_id TEXT NOT NULL, operation TEXT NOT NULL, payload_digest TEXT NOT NULL, response BLOB NOT NULL, first_sequence INTEGER NOT NULL, last_sequence INTEGER NOT NULL, PRIMARY KEY(review_id, conversation_id, request_id), FOREIGN KEY(conversation_id) REFERENCES conversations(id));
    CREATE INDEX conversation_requests_lookup ON conversation_requests(review_id, conversation_id, request_id);
    """
}
