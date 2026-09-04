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
