import Foundation
import GRDB
import RTCContracts
import RTCStore

public protocol TourPersistence: Sendable {
    func publishValidatedTour(
        _ validated: ValidatedTourDocument, attachment: TourAttachmentRecord?
    ) async throws
    func tour(reviewID: ReviewID, id: UUID) async throws -> TourDocument?
    func tours(reviewID: ReviewID) async throws -> [TourDocument]
    func saveRun(_ run: TourRunRecord) async throws
    func runs(reviewID: ReviewID) async throws -> [TourRunRecord]
    func saveAttachment(_ attachment: TourAttachmentRecord) async throws
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
        let tour = validated.document
        let payload = try JSONEncoder.tour.encode(tour)
        let attachmentPayload = try attachment.map { try JSONEncoder.tour.encode($0) }
        try await store.write { db in
            if let existing = try Data.fetchOne(
                db,
                sql: "SELECT payload FROM tour_documents WHERE review_id = ? AND tour_id = ?",
                arguments: [tour.revision.reviewID.value, tour.id.uuidString]
            ), existing != payload {
                throw TourIntegrationError.tourIDConflict
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO tour_documents (review_id, tour_id, payload) VALUES (?, ?, ?)",
                arguments: [tour.revision.reviewID.value, tour.id.uuidString, payload]
            )
            let selection = try JSONEncoder.tour.encode(tour.id)
            try db.execute(
                sql:
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["tour.selection.\(tour.revision.reviewID.value)", selection]
            )
            if let attachment, let attachmentPayload {
                try db.execute(
                    sql:
                        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [
                        "tour.attachment.\(attachment.reviewID.value).\(attachment.id.uuidString)",
                        attachmentPayload,
                    ]
                )
            }
        }
    }

    public func tour(reviewID: ReviewID, id: UUID) async throws -> TourDocument? {
        try await store.read { db in
            guard
                let data = try Data.fetchOne(
                    db,
                    sql: "SELECT payload FROM tour_documents WHERE review_id = ? AND tour_id = ?",
                    arguments: [reviewID.value, id.uuidString]
                )
            else { return nil }
            return try JSONDecoder.tour.decode(TourDocument.self, from: data)
        }
    }

    public func tours(reviewID: ReviewID) async throws -> [TourDocument] {
        try await store.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT payload FROM tour_documents WHERE review_id = ? ORDER BY tour_id",
                arguments: [reviewID.value]
            ).map { try JSONDecoder.tour.decode(TourDocument.self, from: $0) }
        }
    }

    public func saveRun(_ run: TourRunRecord) async throws {
        let payload = try JSONEncoder.tour.encode(run)
        try await store.write { db in
            try db.execute(
                sql:
                    "INSERT INTO tour_runs (id, review_id, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                arguments: [run.id.uuidString, run.reviewID.value, payload]
            )
        }
    }

    public func runs(reviewID: ReviewID) async throws -> [TourRunRecord] {
        try await store.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT payload FROM tour_runs WHERE review_id = ?",
                arguments: [reviewID.value]
            ).map { try JSONDecoder.tour.decode(TourRunRecord.self, from: $0) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func saveAttachment(_ attachment: TourAttachmentRecord) async throws {
        try await saveSetting(
            key: "tour.attachment.\(attachment.reviewID.value).\(attachment.id.uuidString)",
            value: attachment
        )
    }

    public func attachments(reviewID: ReviewID) async throws -> [TourAttachmentRecord] {
        try await store.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT value FROM settings WHERE key LIKE ?",
                arguments: ["tour.attachment.\(reviewID.value).%"]
            ).compactMap { row -> TourAttachmentRecord? in
                let data: Data = row["value"]
                return try? JSONDecoder.tour.decode(TourAttachmentRecord.self, from: data)
            }.sorted { $0.receivedAt > $1.receivedAt }
        }
    }

    public func select(reviewID: ReviewID, tourID: UUID) async throws {
        guard try await tour(reviewID: reviewID, id: tourID) != nil else { throw TourIntegrationError.noSelectedTour }
        try await saveSetting(key: "tour.selection.\(reviewID.value)", value: tourID)
    }

    public func selectedTourID(reviewID: ReviewID) async throws -> UUID? {
        try await setting(key: "tour.selection.\(reviewID.value)", as: UUID.self)
    }

    public func saveRating(_ rating: TourRatingRecord) async throws {
        guard try await tour(reviewID: rating.reviewID, id: rating.tourID) != nil else {
            throw TourIntegrationError.noSelectedTour
        }
        try await saveSetting(
            key: "tour.rating.\(rating.reviewID.value).\(rating.tourID.uuidString)",
            value: rating
        )
    }

    public func rating(reviewID: ReviewID, tourID: UUID) async throws -> TourRatingRecord? {
        try await setting(key: "tour.rating.\(reviewID.value).\(tourID.uuidString)", as: TourRatingRecord.self)
    }

    private func saveSetting<T: Encodable & Sendable>(key: String, value: T) async throws {
        let data = try JSONEncoder.tour.encode(value)
        try await store.write { db in
            try db.execute(
                sql:
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, data]
            )
        }
    }

    private func setting<T: Decodable & Sendable>(key: String, as type: T.Type) async throws -> T? {
        try await store.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
            else {
                return nil
            }
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
