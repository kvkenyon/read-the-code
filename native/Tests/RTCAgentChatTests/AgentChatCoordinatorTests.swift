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
        XCTAssertEqual(afterFlush, [3])
    }

    func testOperationRetriesAreIdempotentAndConversationBound() async throws {
        let reviewID = try ReviewID("0123456789abcdef01234567")
        let conversationID = UUID()
        let repository = MemoryRepository()
        let coordinator = AgentChatCoordinator(reviewID: reviewID, conversationID: conversationID, repository: repository, wakeSink: NoopWake())
        let handler = AgentChatOperationHandler(coordinator: coordinator, journal: repository)
        let body = try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString("one reply"))])
        let payload = try JSONEncoder().encode(ConversationAvailabilityRequest(conversationID: conversationID, availability: .online))
        let online = IPCRequest(schemaVersion: 2, id: UUID(), operation: BoundedString("setConversationAvailability"), reviewID: reviewID, payload: payload)
        XCTAssertTrue((await handler.handle(online)).ok)
        let replyPayload = try JSONEncoder().encode(ConversationReplyRequest(conversationID: conversationID, body: body))
        let request = IPCRequest(schemaVersion: 2, id: UUID(), operation: BoundedString("postConversationReply"), reviewID: reviewID, payload: replyPayload)
        let first = await handler.handle(request)
        let retry = await handler.handle(request)
        XCTAssertTrue(first.ok); XCTAssertEqual(first.payload, retry.payload)
        let snapshot = try await coordinator.replay()
        XCTAssertEqual(snapshot.events.filter { $0.kind == .assistantMessageStarted }.count, 1)
        let invalidPayload = try JSONEncoder().encode(ConversationPollRequest(conversationID: UUID(), after: 0))
        let invalid = IPCRequest(schemaVersion: 2, id: UUID(), operation: BoundedString("pollConversationEvents"), reviewID: reviewID, payload: invalidPayload)
        XCTAssertFalse((await handler.handle(invalid)).ok)
    }
}

private actor MemoryRepository: ConversationReplayRepository, ConversationRequestJournal {
    var events: [ConversationEvent]
    init(events: [ConversationEvent] = []) { self.events = events }
    func append(_ event: ConversationEvent) async throws { events.append(event) }
    func replay(reviewID: ReviewID, conversationID: UUID, after sequence: Int) async throws -> [ConversationEvent] {
        events.filter { $0.reviewID == reviewID && $0.conversationID == conversationID && $0.sequence > sequence }
    }
    func commit(reviewID: ReviewID, conversationID: UUID, requestID: UUID, operation: String, payloadDigest: SHA256Digest, events: [ConversationEvent]) async throws -> ConversationRequestCommit { self.events.append(contentsOf: events); return ConversationRequestCommit(events: events, reused: false) }
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
