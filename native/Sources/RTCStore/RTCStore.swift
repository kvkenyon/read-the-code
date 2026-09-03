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
        for continuation in observations[snapshot.review.id]?.values ?? [] { continuation.yield(snapshot) }
    }

    private func removeObservation(_ id: ReviewID, token: UUID) { observations[id]?[token] = nil }

    private static func configure(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")
        }
    }

    private static func migrate(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY, checksum TEXT NOT NULL);")
            let checksum = SHA256.hash(data: Data(Migration.v1.utf8)).map { String(format: "%02x", $0) }.joined()
            let existing = try String.fetchOne(db, sql: "SELECT checksum FROM schema_migrations WHERE id = 1")
            if let existing, existing != checksum { throw RTCStoreError.corrupt("migration checksum") }
            if existing == nil {
                try db.inTransaction {
                    try db.execute(sql: Migration.v1)
                    try db.execute(sql: "INSERT INTO schema_migrations (id, checksum) VALUES (1, ?)", arguments: [checksum])
                    return .commit
                }
            }
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            guard result == "ok" else { throw RTCStoreError.corrupt(result ?? "integrity check failed") }
        }
    }

    private static func protect(_ url: URL, mode: Int16) throws {
        guard chmod(url.path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
    }
}

public final class SQLiteReviewRepository: ReviewRepository, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func review(id: ReviewID) async throws -> ReviewManifest? {
        try await store.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM reviews WHERE id = ?", arguments: [id.value]) else { return nil }
            return try JSONDecoder.rtc.decode(ReviewManifest.self, from: data)
        }
    }

    public func save(_ review: ReviewManifest) async throws {
        let data = try JSONEncoder.rtc.encode(review)
        try await store.write { db in
            try db.execute(sql: "INSERT INTO reviews (id, repo_path, base_sha, head_sha, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at", arguments: [review.id.value, review.revision.repositoryPath, review.revision.baseSHA, review.revision.headSHA, data, review.updatedAt.timeIntervalSince1970])
        }
        await store.publish(StoreSnapshot(review: review))
    }

    public func markStale(_ id: ReviewID) async throws {
        guard let review = try await review(id: id) else { return }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder.rtc.encode(review)) as! [String: Any]
        object["stale"] = true
        object["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let updated = try JSONDecoder.rtc.decode(ReviewManifest.self, from: JSONSerialization.data(withJSONObject: object))
        try await save(updated)
    }
}

public final class SQLiteEventRepository: EventRepository, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func append(_ event: ReviewEvent) async throws {
        try await store.write { db in
            try db.inTransaction {
                if try Int.fetchOne(db, sql: "SELECT 1 FROM review_events WHERE event_id = ?", arguments: [event.id.uuidString]) != nil { return .commit }
                let next = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM review_events WHERE review_id = ?", arguments: [event.reviewID.value])) ?? 1
                let data = try Self.payload(event, sequence: next)
                try db.execute(sql: "INSERT INTO review_events (review_id, sequence, event_id, payload, created_at) VALUES (?, ?, ?, ?, ?)", arguments: [event.reviewID.value, next, event.id.uuidString, data, event.createdAt.timeIntervalSince1970])
                return .commit
            }
        }
    }

    public func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] {
        try await store.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM review_events WHERE review_id = ? AND sequence > ? ORDER BY sequence", arguments: [reviewID.value, sequence]).map { try JSONDecoder.rtc.decode(ReviewEvent.self, from: $0) }
        }
    }

    private static func payload(_ event: ReviewEvent, sequence: Int) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder.rtc.encode(event)) as! [String: Any]
        object["sequence"] = sequence
        return try JSONSerialization.data(withJSONObject: object)
    }
}

public final class JobQueue: JobRepository, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func enqueue(_ job: JobRecord) async throws {
        try await store.write { db in try db.execute(sql: "INSERT OR IGNORE INTO jobs (id, kind, review_id, state, attempt, available_at, lease_owner) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [job.id.uuidString, job.kind.rawValue, job.reviewID.value, job.state.rawValue, job.attempt, job.availableAt.timeIntervalSince1970, job.leaseOwner?.value]) }
    }

    public func leaseNext(owner: BoundedString, now: Date) async throws -> (JobRecord, JobLease)? {
        try await store.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE state = 'queued' AND available_at <= ? ORDER BY available_at, id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            let id = UUID(uuidString: row["id"] as String)!; let expiry = now.addingTimeInterval(30)
            try db.execute(sql: "UPDATE jobs SET state = 'running', attempt = attempt + 1, lease_owner = ?, lease_expires = ? WHERE id = ? AND state = 'queued'", arguments: [owner.value, expiry.timeIntervalSince1970, id.uuidString])
            let job = JobRecord(id: id, kind: JobKind(rawValue: row["kind"] as String)!, reviewID: try ReviewID(row["review_id"] as String), state: .running, attempt: (row["attempt"] as Int) + 1, availableAt: Date(timeIntervalSince1970: row["available_at"] as Double), leaseOwner: owner)
            return (job, JobLease(jobID: id, owner: owner, expiresAt: expiry))
        }
    }

    public func complete(_ jobID: UUID, state: JobState) async throws { try await store.write { db in try db.execute(sql: "UPDATE jobs SET state = ?, lease_owner = NULL, lease_expires = NULL WHERE id = ?", arguments: [state.rawValue, jobID.uuidString]) } }
}

public final class BlobStore: @unchecked Sendable {
    public let rootURL: URL
    public init(rootURL: URL) throws { self.rootURL = rootURL.appendingPathComponent("blobs/sha256", isDirectory: true); try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true); try chmod(self.rootURL.path, 0o700) }
    public func put(_ data: Data) throws -> SHA256Digest {
        let digest = SHA256Digest(data: data); let dir = rootURL.appendingPathComponent(String(digest.hex.prefix(2)), isDirectory: true); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(digest.hex + ".rtcb"); if FileManager.default.fileExists(atPath: target.path) { return digest }
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)"); try data.write(to: temp, options: [.atomic]); try chmod(temp.path, 0o600); let fd = open(temp.path, O_RDONLY); if fd >= 0 { _ = fsync(fd); close(fd) }
        do { try FileManager.default.moveItem(at: temp, to: target); try chmod(target.path, 0o600) } catch CocoaError.fileWriteFileExists { try? FileManager.default.removeItem(at: temp) }
        return digest
    }
    public func get(_ digest: SHA256Digest) throws -> Data { let data = try Data(contentsOf: rootURL.appendingPathComponent(String(digest.hex.prefix(2))).appendingPathComponent(digest.hex + ".rtcb")); guard SHA256Digest(data: data) == digest else { throw RTCStoreError.invalidBlob }; return data }

    @discardableResult
    public func collectOrphans(referenced: Set<SHA256Digest>, olderThan cutoff: Date = Date().addingTimeInterval(-24 * 60 * 60)) throws -> Int {
        var removed = 0
        for prefix in try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try? prefix.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: prefix, includingPropertiesForKeys: [.contentModificationDateKey]) where file.pathExtension == "rtcb" {
                guard let digest = try? SHA256Digest(String(file.deletingPathExtension().lastPathComponent)), !referenced.contains(digest), let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff else { continue }
                try FileManager.default.removeItem(at: file); removed += 1
            }
        }
        return removed
    }
}

private extension JSONEncoder { static var rtc: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
private extension JSONDecoder { static var rtc: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

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
}
