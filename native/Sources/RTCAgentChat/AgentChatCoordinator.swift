import Foundation
import RTCContracts

public enum WorkerAvailability: String, Codable, Sendable {
    case online, sleeping, offline, ended
}

public enum AgentChatError: Error, Equatable, Sendable {
    case invalidEvent(String)
    case ended
    case workerUnavailable
    case notStreaming
    case invalidCursor
}

public struct ConversationSnapshot: Sendable, Equatable {
    public let reviewID: ReviewID
    public let conversationID: UUID
    public let events: [ConversationEvent]
    public let cursor: Int
    public let acknowledgedCursor: Int
    public let availability: WorkerAvailability
    public let ended: Bool
    public let queuedMessageCount: Int
    public let streamingText: String?

    public init(reviewID: ReviewID, conversationID: UUID, events: [ConversationEvent], cursor: Int,
                acknowledgedCursor: Int, availability: WorkerAvailability, ended: Bool,
                queuedMessageCount: Int, streamingText: String?) {
        self.reviewID = reviewID; self.conversationID = conversationID; self.events = events
        self.cursor = cursor; self.acknowledgedCursor = acknowledgedCursor; self.availability = availability
        self.ended = ended; self.queuedMessageCount = queuedMessageCount; self.streamingText = streamingText
    }
}

public struct PromotedConversationMessage: Sendable, Equatable {
    public let reviewID: ReviewID
    public let conversationID: UUID
    public let sourceEventID: UUID
    public let sequence: Int
    public let body: RichText?
    public let citedAnchors: [ReviewAnchor]

    public init(source: ConversationEvent) {
        reviewID = source.reviewID; conversationID = source.conversationID; sourceEventID = source.id
        sequence = source.sequence; body = source.body; citedAnchors = source.citedAnchors
    }
}

/// Coordinates durable conversation events. Wake delivery is deliberately advisory: callers can
/// always recover the complete stream by polling from `acknowledgedCursor`.
public actor AgentChatCoordinator {
    private let repository: ConversationEventRepository
    private let wakeSink: WakeSink
    private let reviewID: ReviewID
    private let conversationID: UUID
    private var events: [ConversationEvent] = []
    private var wakePending = false
    private var availability: WorkerAvailability = .offline
    private var ended = false
    private var acknowledgedCursor = 0

    public init(reviewID: ReviewID, conversationID: UUID, repository: ConversationEventRepository, wakeSink: WakeSink) {
        self.reviewID = reviewID; self.conversationID = conversationID
        self.repository = repository; self.wakeSink = wakeSink
    }

    public func replay(after cursor: Int = 0) async throws -> ConversationSnapshot {
        guard cursor >= 0 else { throw AgentChatError.invalidCursor }
        let received = try await repository.replay(reviewID: reviewID, conversationID: conversationID, after: cursor)
        try validate(received, after: cursor)
        merge(received)
        return snapshot()
    }

    /// Worker-facing poll operation. The cursor is a durable acknowledgement cursor, not a wake token.
    public func poll(after cursor: Int) async throws -> ConversationSnapshot { try await replay(after: cursor) }

    /// Worker-facing reply operation; replies are represented by assistant lifecycle events.
    public func reply(_ body: RichText) async throws -> ConversationSnapshot {
        _ = try await startAssistantMessage()
        _ = try await appendAssistantDelta(body.runs.map(\.text.value).joined())
        return try await completeAssistantMessage()
    }

    public func queueMessage(_ body: RichText, citedAnchors: [ReviewAnchor] = []) async throws -> ConversationSnapshot {
        guard !ended else { throw AgentChatError.ended }
        try validateAnchors(citedAnchors)
        let event = try event(kind: .humanMessageQueued, body: body, citedAnchors: citedAnchors)
        try await append(event)
        try await coalescedWake()
        return snapshot()
    }

    public func acknowledge(upTo cursor: Int) async throws -> ConversationSnapshot {
        guard cursor >= acknowledgedCursor, cursor <= events.last?.sequence ?? 0 else { throw AgentChatError.invalidCursor }
        guard cursor > acknowledgedCursor else { return snapshot() }
        let event = try event(kind: .workerAcknowledged, sequence: cursor)
        try await append(event)
        acknowledgedCursor = cursor
        return snapshot()
    }

    public func setAvailability(_ value: WorkerAvailability) async throws -> ConversationSnapshot {
        let event = try event(kind: .workerAvailabilityChanged, body: try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString(value.rawValue))]))
        try await append(event)
        availability = value
        return snapshot()
    }

    public func startAssistantMessage() async throws -> ConversationSnapshot {
        guard !ended else { throw AgentChatError.ended }
        guard availability == .online else { throw AgentChatError.workerUnavailable }
        try await append(event(kind: .assistantMessageStarted))
        return snapshot()
    }

    public func appendAssistantDelta(_ delta: String) async throws -> ConversationSnapshot {
        guard !ended else { throw AgentChatError.ended }
        guard !delta.isEmpty else { return snapshot() }
        let text = try BoundedString(delta, maxCharacters: 4_096)
        let body = try RichText(runs: [RichTextRun(kind: .plain, text: text)])
        try await append(event(kind: .assistantMessageDelta, body: body))
        return snapshot()
    }

    public func completeAssistantMessage() async throws -> ConversationSnapshot { try await finish(.assistantMessageCompleted) }
    public func failAssistantMessage() async throws -> ConversationSnapshot { try await finish(.assistantMessageFailed) }

    public func retry() async throws -> ConversationSnapshot {
        guard !ended else { throw AgentChatError.ended }
        guard availability == .online else { throw AgentChatError.workerUnavailable }
        try await coalescedWake()
        return snapshot()
    }

    public func end() async throws -> ConversationSnapshot {
        guard !ended else { return snapshot() }
        try await append(event(kind: .conversationEnded)); ended = true; availability = .ended
        return snapshot()
    }

    public func promoteMessage(sequence: Int) throws -> PromotedConversationMessage {
        guard let source = events.first(where: { $0.sequence == sequence && $0.kind == .humanMessageQueued }) else { throw AgentChatError.invalidCursor }
        return PromotedConversationMessage(source: source)
    }

    public func flushWake() async throws {
        guard wakePending else { return }
        wakePending = false
        try await wakeSink.wake(reviewID: reviewID, conversationID: conversationID, highestSequence: events.last?.sequence ?? 0)
    }

    private func finish(_ kind: ConversationEventKind) async throws -> ConversationSnapshot {
        guard events.contains(where: { $0.kind == .assistantMessageStarted && $0.sequence > (events.last(where: { $0.kind == .assistantMessageCompleted || $0.kind == .assistantMessageFailed })?.sequence ?? 0) }) else { throw AgentChatError.notStreaming }
        try await append(event(kind: kind)); return snapshot()
    }

    private func coalescedWake() async throws { wakePending = true }

    private func append(_ value: ConversationEvent) async throws {
        try await repository.append(value); events.append(value)
    }

    private func validate(_ values: [ConversationEvent], after cursor: Int) throws {
        var expected = cursor + 1
        for value in values {
            guard value.reviewID == reviewID, value.conversationID == conversationID, value.sequence == expected else { throw AgentChatError.invalidEvent("non-contiguous conversation replay") }
            expected += 1
        }
    }

    private func validateAnchors(_ anchors: [ReviewAnchor]) throws {
        guard anchors.count <= RTCConstants.maxAnchors else { throw AgentChatError.invalidEvent("too many cited anchors") }
        guard anchors.allSatisfy({ !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") && ($0.oldPath == nil || (!$0.oldPath!.hasPrefix("/") && !$0.oldPath!.split(separator: "/").contains(".."))) }) else { throw AgentChatError.invalidEvent("malicious anchor path") }
    }

    private func merge(_ values: [ConversationEvent]) { for value in values where !events.contains(where: { $0.id == value.id }) { events.append(value) }; events.sort { $0.sequence < $1.sequence } }

    private func snapshot() -> ConversationSnapshot {
        let queued = events.filter { $0.kind == .humanMessageQueued && $0.sequence > acknowledgedCursor }.count
        let active = events.last?.kind == .assistantMessageStarted || events.last?.kind == .assistantMessageDelta
        let text = active ? events.reversed().first(where: { $0.kind == .assistantMessageDelta })?.body?.runs.map(\.text.value).joined() : nil
        return ConversationSnapshot(reviewID: reviewID, conversationID: conversationID, events: events, cursor: events.last?.sequence ?? 0, acknowledgedCursor: acknowledgedCursor, availability: availability, ended: ended, queuedMessageCount: queued, streamingText: text)
    }

    private func event(kind: ConversationEventKind, body: RichText? = nil, citedAnchors: [ReviewAnchor] = [], sequence: Int? = nil) throws -> ConversationEvent {
        let next = sequence ?? ((events.last?.sequence ?? 0) + 1)
        let anchors = try JSONSerialization.jsonObject(with: RTCCanonicalJSON.encode(citedAnchors))
        let object: [String: Any] = ["schemaVersion": 2, "id": UUID().uuidString, "reviewID": reviewID.value, "conversationID": conversationID.uuidString, "sequence": next, "kind": kind.rawValue, "citedAnchors": anchors, "createdAt": ISO8601DateFormatter().string(from: Date())]
        var json = object
        if let body { json["body"] = try JSONSerialization.jsonObject(with: RTCCanonicalJSON.encode(body)) }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder.rtc.decode(ConversationEvent.self, from: data)
    }
}

private extension JSONDecoder {
    static let rtc: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }()
}
