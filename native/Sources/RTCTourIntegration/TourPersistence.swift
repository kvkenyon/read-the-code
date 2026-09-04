import Foundation
import GRDB
import RTCContracts
import RTCStore

public protocol TourPersistence: Sendable {
    func publishValidatedTour(_ validated: ValidatedTourDocument, attachment: TourAttachmentRecord?) async throws
    func publishValidatedTour(
        _ validated: ValidatedTourDocument, attachment: TourAttachmentRecord?, finishing run: TourRunRecord,
        jobState: JobState?) async throws
    func tourRecord(reviewID: ReviewID, id: UUID) async throws -> PersistedTourRecord?
    func tourRecords(reviewID: ReviewID) async throws -> [PersistedTourRecord]
    func saveRun(_ run: TourRunRecord) async throws
    func finalizeRunAndJob(_ run: TourRunRecord, jobState: JobState) async throws
    func run(id: UUID) async throws -> TourRunRecord?
    func runs(reviewID: ReviewID) async throws -> [TourRunRecord]
    func saveGenerationRequest(_ request: TourGenerationRequestRecord) async throws
    func generationRequest(jobID: UUID) async throws -> TourGenerationRequestRecord?
    func generationRequests() async throws -> [TourGenerationRequestRecord]
    func saveAttachment(_ attachment: TourAttachmentRecord) async throws
    func saveAttachment(_ attachment: TourAttachmentRecord, run: TourRunRecord) async throws
    func attachments(reviewID: ReviewID) async throws -> [TourAttachmentRecord]
    func select(reviewID: ReviewID, tourID: UUID) async throws
    func selectedTourID(reviewID: ReviewID) async throws -> UUID?
    func saveRating(_ rating: TourRatingRecord) async throws
    func rating(reviewID: ReviewID, tourID: UUID) async throws -> TourRatingRecord?
}

extension TourPersistence {
    public func publishValidatedTour(_ validated: ValidatedTourDocument) async throws {
        try await publishValidatedTour(validated, attachment: nil)
    }
}

public final class SQLiteTourPersistence: TourPersistence, @unchecked Sendable {
    private let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func publishValidatedTour(
        _ validated: ValidatedTourDocument, attachment: TourAttachmentRecord?
    ) async throws {
        try await publishValidatedTour(validated, attachment: attachment, finishing: nil, jobState: nil)
    }

    public func publishValidatedTour(
        _ validated: ValidatedTourDocument, attachment: TourAttachmentRecord?,
        finishing run: TourRunRecord, jobState: JobState?
    ) async throws {
        try await publishValidatedTour(
            validated, attachment: attachment, finishing: Optional(run), jobState: jobState)
    }

    private func publishValidatedTour(
        _ validated: ValidatedTourDocument, attachment: TourAttachmentRecord?,
        finishing run: TourRunRecord?, jobState: JobState?
    ) async throws {
        let record = try PersistedTourRecord(
            rawPayload: validated.rawPayload, revision: validated.revision,
            contextDigest: validated.inputDigest, provenance: validated.provenance)
        let payload = try JSONEncoder.tour.encode(record)
        let attachmentPayload = try attachment.map { try JSONEncoder.tour.encode($0) }
        try await store.write { db in
            if let existingData = try Data.fetchOne(
                db, sql: "SELECT payload FROM tour_documents WHERE review_id = ? AND tour_id = ?",
                arguments: [validated.revision.reviewID.value, validated.id.uuidString]
            ) {
                let existing = try JSONDecoder.tour.decode(PersistedTourRecord.self, from: existingData)
                try existing.verifyIntegrity()
                guard existing.payloadDigest == record.payloadDigest,
                    existing.provenance == record.provenance,
                    existing.contextDigest == record.contextDigest
                else {
                    throw TourIntegrationError.tourIDConflict
                }
            } else {
                try db.execute(
                    sql: "INSERT INTO tour_documents (review_id, tour_id, payload) VALUES (?, ?, ?)",
                    arguments: [validated.revision.reviewID.value, validated.id.uuidString, payload])
            }
            let selection = try JSONEncoder.tour.encode(validated.id)
            try db.execute(
                sql:
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["tour.selection.\(validated.revision.reviewID.value)", selection])
            if let attachment, let attachmentPayload {
                try db.execute(
                    sql:
                        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [
                        "tour.attachment.\(attachment.reviewID.value).\(attachment.id.uuidString)", attachmentPayload,
                    ])
            }
            if let run {
                try Self.upsert(run: run, payload: JSONEncoder.tour.encode(run), db: db)
                if let jobState, let jobID = run.jobID {
                    try db.execute(
                        sql: "UPDATE jobs SET state = ?, lease_owner = NULL, lease_expires = NULL WHERE id = ?",
                        arguments: [jobState.rawValue, jobID.uuidString])
                    guard db.changesCount == 1 else { throw TourIntegrationError.invalidJob }
                }
            }
        }
    }

    public func tourRecord(reviewID: ReviewID, id: UUID) async throws -> PersistedTourRecord? {
        try await store.read { db in
            guard
                let data = try Data.fetchOne(
                    db, sql: "SELECT payload FROM tour_documents WHERE review_id = ? AND tour_id = ?",
                    arguments: [reviewID.value, id.uuidString])
            else { return nil }
            let record = try JSONDecoder.tour.decode(PersistedTourRecord.self, from: data)
            try record.verifyIntegrity()
            return record
        }
    }

    public func tourRecords(reviewID: ReviewID) async throws -> [PersistedTourRecord] {
        try await store.read { db in
            try Data.fetchAll(
                db, sql: "SELECT payload FROM tour_documents WHERE review_id = ? ORDER BY tour_id",
                arguments: [reviewID.value]
            ).map {
                let record = try JSONDecoder.tour.decode(PersistedTourRecord.self, from: $0)
                try record.verifyIntegrity()
                return record
            }
        }
    }

    public func saveRun(_ run: TourRunRecord) async throws {
        let payload = try JSONEncoder.tour.encode(run)
        try await store.write { db in try Self.upsert(run: run, payload: payload, db: db) }
    }

    public func finalizeRunAndJob(_ run: TourRunRecord, jobState: JobState) async throws {
        let payload = try JSONEncoder.tour.encode(run)
        try await store.write { db in
            try Self.upsert(run: run, payload: payload, db: db)
            if let jobID = run.jobID {
                try db.execute(
                    sql: "UPDATE jobs SET state = ?, lease_owner = NULL, lease_expires = NULL WHERE id = ?",
                    arguments: [jobState.rawValue, jobID.uuidString])
                guard db.changesCount == 1 else { throw TourIntegrationError.invalidJob }
            }
        }
    }

    public func run(id: UUID) async throws -> TourRunRecord? {
        try await store.read { db in
            guard
                let data = try Data.fetchOne(
                    db, sql: "SELECT payload FROM tour_runs WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            return try JSONDecoder.tour.decode(TourRunRecord.self, from: data)
        }
    }

    public func runs(reviewID: ReviewID) async throws -> [TourRunRecord] {
        try await store.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM tour_runs WHERE review_id = ?", arguments: [reviewID.value])
                .map { try JSONDecoder.tour.decode(TourRunRecord.self, from: $0) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func saveGenerationRequest(_ request: TourGenerationRequestRecord) async throws {
        try await saveSetting(key: "tour.request.\(request.jobID.uuidString)", value: request)
    }

    public func generationRequest(jobID: UUID) async throws -> TourGenerationRequestRecord? {
        try await setting(key: "tour.request.\(jobID.uuidString)", as: TourGenerationRequestRecord.self)
    }

    public func generationRequests() async throws -> [TourGenerationRequestRecord] {
        try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT value FROM settings WHERE key LIKE 'tour.request.%'").map { row in
                let data: Data = row["value"]
                return try JSONDecoder.tour.decode(TourGenerationRequestRecord.self, from: data)
            }
        }
    }

    public func saveAttachment(_ attachment: TourAttachmentRecord) async throws {
        try await saveSetting(
            key: "tour.attachment.\(attachment.reviewID.value).\(attachment.id.uuidString)", value: attachment)
    }

    public func saveAttachment(_ attachment: TourAttachmentRecord, run: TourRunRecord) async throws {
        let attachmentData = try JSONEncoder.tour.encode(attachment)
        let runData = try JSONEncoder.tour.encode(run)
        try await store.write { db in
            try db.execute(
                sql:
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["tour.attachment.\(attachment.reviewID.value).\(attachment.id.uuidString)", attachmentData])
            try Self.upsert(run: run, payload: runData, db: db)
        }
    }

    public func attachments(reviewID: ReviewID) async throws -> [TourAttachmentRecord] {
        try await store.read { db in
            try Row.fetchAll(
                db, sql: "SELECT value FROM settings WHERE key LIKE ?",
                arguments: ["tour.attachment.\(reviewID.value).%"]
            ).map { row in
                let data: Data = row["value"]
                return try JSONDecoder.tour.decode(TourAttachmentRecord.self, from: data)
            }.sorted { $0.receivedAt > $1.receivedAt }
        }
    }

    public func select(reviewID: ReviewID, tourID: UUID) async throws {
        guard try await tourRecord(reviewID: reviewID, id: tourID) != nil else {
            throw TourIntegrationError.noSelectedTour
        }
        try await saveSetting(key: "tour.selection.\(reviewID.value)", value: tourID)
    }

    public func selectedTourID(reviewID: ReviewID) async throws -> UUID? {
        try await setting(key: "tour.selection.\(reviewID.value)", as: UUID.self)
    }

    public func saveRating(_ rating: TourRatingRecord) async throws {
        guard try await tourRecord(reviewID: rating.reviewID, id: rating.tourID) != nil else {
            throw TourIntegrationError.noSelectedTour
        }
        try await saveSetting(key: "tour.rating.\(rating.reviewID.value).\(rating.tourID.uuidString)", value: rating)
    }

    public func rating(reviewID: ReviewID, tourID: UUID) async throws -> TourRatingRecord? {
        try await setting(key: "tour.rating.\(reviewID.value).\(tourID.uuidString)", as: TourRatingRecord.self)
    }

    private static func upsert(run: TourRunRecord, payload: Data, db: Database) throws {
        try db.execute(
            sql:
                "INSERT INTO tour_runs (id, review_id, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
            arguments: [run.id.uuidString, run.reviewID.value, payload])
    }

    private func saveSetting<T: Encodable & Sendable>(key: String, value: T) async throws {
        let data = try JSONEncoder.tour.encode(value)
        try await store.write { db in
            try db.execute(
                sql:
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, data])
        }
    }

    private func setting<T: Decodable & Sendable>(key: String, as type: T.Type) async throws -> T? {
        try await store.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
            else { return nil }
            return try JSONDecoder.tour.decode(T.self, from: data)
        }
    }
}

private extension JSONEncoder {
    static var tour: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
}
private extension JSONDecoder {
    static var tour: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
