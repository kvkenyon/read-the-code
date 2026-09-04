import Foundation
import XCTest
@testable import RTCStore

final class StoreTests: XCTestCase {
    func testBlobStoreIsContentAddressedAndReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root)
        let bytes = Data("immutable".utf8)
        let digest = try blobs.put(bytes)
        XCTAssertEqual(try blobs.put(bytes), digest)
        XCTAssertEqual(try blobs.get(digest), bytes)
    }
}

extension StoreTests {
    func testVirginConversationAllowsOnlyEmptyCursorZeroPage() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtc-virgin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(rootURL: root)
        let repository = SQLiteConversationEventRepository(store: store)
        let reviewID = try ReviewID("0123456789abcdef01234567")
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

        let empty = try await repository.page(reviewID: reviewID, conversationID: conversationID, after: 0, maximumEvents: 100, maximumBytes: 1024)
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.nextCursor, 0)
        do { _ = try await repository.page(reviewID: reviewID, conversationID: conversationID, after: 1, maximumEvents: 100, maximumBytes: 1024); XCTFail("virgin nonzero cursor must fail") } catch { }

        let otherReview = try ReviewID("fedcba9876543210fedcba98")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode([ConversationEvent].self, from: Data(contentsOf: URL(fileURLWithPath: "native/Fixtures/Chat/replay-lossless.json")))
        try await repository.append(fixture[0])
        do { _ = try await repository.page(reviewID: otherReview, conversationID: conversationID, after: 0, maximumEvents: 100, maximumBytes: 1024); XCTFail("mismatched binding must fail") } catch { }
    }

    func testConversationReplayIsLosslessAcrossRepositoryInstances() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtc-conversation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode([ConversationEvent].self, from: Data(contentsOf: URL(fileURLWithPath: "native/Fixtures/Chat/replay-lossless.json")))
        let store = try SQLiteStore(rootURL: root)
        let repository = SQLiteConversationEventRepository(store: store)
        for event in fixture { try await repository.append(event) }
        try await repository.append(fixture[1]) // duplicate delivery must not duplicate the log
        let replayed = try await SQLiteConversationEventRepository(store: store).replay(reviewID: fixture[0].reviewID, conversationID: fixture[0].conversationID, after: 1)
        XCTAssertEqual(replayed.map(\.sequence), [2, 3])
        XCTAssertEqual(replayed.map(\.id), Array(fixture.dropFirst()).map(\.id))
    }
}
