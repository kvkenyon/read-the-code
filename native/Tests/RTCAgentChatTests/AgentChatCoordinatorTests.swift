import Foundation
import XCTest
import RTCContracts
import RTCAgentChat

final class AgentChatCoordinatorTests: XCTestCase {
    func testReplayRejectsGapsAndWrongStream() async throws {
        let reviewID = try ReviewID("0123456789abcdef01234567")
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let repository = MemoryRepository(events: try loadFixture())
        let coordinator = AgentChatCoordinator(reviewID: reviewID, conversationID: conversationID, repository: repository, wakeSink: NoopWake())
        let snapshot = try await coordinator.replay()
        XCTAssertEqual(snapshot.cursor, 3)
        XCTAssertEqual(snapshot.events.count, 3)
    }

    func testWakeIsCoalescedAndFlushesHighestCursor() async throws {
        let reviewID = try ReviewID("0123456789abcdef01234567")
        let wake = RecordingWake()
        let coordinator = AgentChatCoordinator(reviewID: reviewID, conversationID: UUID(), repository: MemoryRepository(), wakeSink: wake)
        let text = try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString("hello"))])
        try await coordinator.queueMessage(text)
        try await coordinator.queueMessage(text)
        let beforeFlush = await wake.values()
        XCTAssertTrue(beforeFlush.isEmpty)
        try await coordinator.flushWake()
        let afterFlush = await wake.values()
        XCTAssertEqual(afterFlush, [2])
    }
}

private actor MemoryRepository: ConversationEventRepository {
    var events: [ConversationEvent]
    init(events: [ConversationEvent] = []) { self.events = events }
    func append(_ event: ConversationEvent) async throws { events.append(event) }
    func replay(reviewID: ReviewID, conversationID: UUID, after sequence: Int) async throws -> [ConversationEvent] {
        events.filter { $0.reviewID == reviewID && $0.conversationID == conversationID && $0.sequence > sequence }
    }
}

private actor RecordingWake: WakeSink {
    var recorded: [Int] = []
    func wake(reviewID: ReviewID, conversationID: UUID, highestSequence: Int) async throws { recorded.append(highestSequence) }
    func values() -> [Int] { recorded }
}

private struct NoopWake: WakeSink {
    func wake(reviewID: ReviewID, conversationID: UUID, highestSequence: Int) async throws {}
}

private func loadFixture() throws -> [ConversationEvent] {
    let url = URL(fileURLWithPath: "native/Fixtures/Chat/replay-lossless.json")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([ConversationEvent].self, from: Data(contentsOf: url))
}
