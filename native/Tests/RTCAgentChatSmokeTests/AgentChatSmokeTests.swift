import Foundation
import RTCContracts
import RTCIPC
import RTCStore
import RTCAgentChat

@main struct RTCAgentChatSmokeTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }

    static func main() async throws {
        let legacyReviewID = Data("{\"value\":\"0123456789abcdef01234567\"}".utf8)
        check(try JSONDecoder().decode(ReviewID.self, from: legacyReviewID).value == "0123456789abcdef01234567", "legacy review id remains readable")
        let hostileRuns = "{\"runs\":[" + Array(repeating: "{\"kind\":\"plain\",\"text\":\"x\"}", count: 257).joined(separator: ",") + "]}"
        check((try? JSONDecoder().decode(RichText.self, from: Data(hostileRuns.utf8))) == nil, "decoded rich text stays bounded")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let fixtureURL = URL(fileURLWithPath: "native/Fixtures/Chat/replay-lossless.json")
        let fixture = try decoder.decode([ConversationEvent].self, from: Data(contentsOf: fixtureURL))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-chat-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SQLiteConversationEventRepository(store: try SQLiteStore(rootURL: root))
        for event in fixture { try await repository.append(event) }
        try await repository.append(fixture[1])
        let replay = try await repository.replay(reviewID: fixture[0].reviewID, conversationID: fixture[0].conversationID, after: 1)
        check(replay.map(\.sequence) == [2, 3], "lossless replay and duplicate delivery")

        let conversationID = UUID()
        let coordinator = AgentChatCoordinator(reviewID: fixture[0].reviewID, conversationID: conversationID, repository: repository, wakeSink: NoopWake())
        let handler = AgentChatOperationHandler(coordinator: coordinator, journal: repository)
        let availability = try JSONEncoder().encode(ConversationAvailabilityRequest(conversationID: conversationID, availability: .online))
        let online = IPCRequest(schemaVersion: 2, id: UUID(), operation: BoundedString("setConversationAvailability"), reviewID: fixture[0].reviewID, payload: availability)
        check((await handler.handle(online)).ok, "worker reconnects")
        let body = try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString("reply"))])
        let replyPayload = try JSONEncoder().encode(ConversationReplyRequest(conversationID: conversationID, body: body))
        let request = IPCRequest(schemaVersion: 2, id: UUID(), operation: BoundedString("postConversationReply"), reviewID: fixture[0].reviewID, payload: replyPayload)
        let first = await handler.handle(request); let duplicate = await handler.handle(request)
        let pageDecoder = JSONDecoder(); pageDecoder.dateDecodingStrategy = .iso8601
        let firstEvents = try pageDecoder.decode(ConversationPage.self, from: first.payload!).events.map(\.id)
        let duplicateEvents = try pageDecoder.decode(ConversationPage.self, from: duplicate.payload!).events.map(\.id)
        check(first.ok && duplicate.ok && firstEvents == duplicateEvents, "request retry is idempotent")
        let restarted = AgentChatCoordinator(reviewID: fixture[0].reviewID, conversationID: conversationID, repository: repository, wakeSink: NoopWake())
        let restartedHandler = AgentChatOperationHandler(coordinator: restarted, journal: repository)
        let replayedReply = await restartedHandler.handle(request)
        check(replayedReply.ok && replayedReply.payload == first.payload, "request retry survives handler restart")
        let altered = try JSONEncoder().encode(ConversationReplyRequest(conversationID: conversationID, body: try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString("different"))])))
        let conflict = await restartedHandler.handle(IPCRequest(schemaVersion: 2, id: request.id, operation: BoundedString("postConversationReply"), reviewID: fixture[0].reviewID, payload: altered))
        check(!conflict.ok, "request UUID conflict is rejected")
        let page = try await repository.page(reviewID: fixture[0].reviewID, conversationID: conversationID, after: 1, maximumEvents: 2, maximumBytes: 64 * 1024)
        check(page.events.count == 2 && page.events.allSatisfy { $0.sequence > 1 } && page.hasMore, "bounded cursor page")
        _ = try await coordinator.end()
        do { _ = try await coordinator.queueMessage(body); preconditionFailure("ended conversation accepted message") }
        catch AgentChatError.ended { }

        let scopes = IPCScopedCapabilityStore(["worker": ["pollConversationEvents", "postConversationReply"]])
        check(!scopes.isAuthorized("worker", operation: "approveReview"), "chat has no decision authority")
        check((try? IPCFrameCodec.encode(String(repeating: "x", count: IPCConstants.maxFrameBytes + 1))) == nil, "frame cap")
    }
}

private struct NoopWake: WakeSink { func wake(reviewID: ReviewID, conversationID: UUID, highestSequence: Int) async throws {} }
