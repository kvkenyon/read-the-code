import Foundation
import RTCContracts

/// The complete, deliberately small operation vocabulary available to a chat
/// worker. Keeping it here makes capability grants auditable alongside the
/// handler; no review mutation verb belongs in this set.
public enum AgentChatIPCOperation {
    public static let poll = "pollConversationEvents"
    public static let reply = "postConversationReply"
    public static let availability = "setConversationAvailability"
    public static let acknowledge = "acknowledgeConversationEvents"
    public static let all: Set<String> = [poll, reply, availability, acknowledge]
    public static let maximumPayloadBytes = RTCConstants.maxRequestBytes
}

public struct ConversationPollRequest: Codable, Sendable {
    public let conversationID: UUID
    public let after: Int
    public init(conversationID: UUID, after: Int) { self.conversationID = conversationID; self.after = after }
}

public struct ConversationReplyRequest: Codable, Sendable {
    public let conversationID: UUID
    public let body: RichText
    public init(conversationID: UUID, body: RichText) { self.conversationID = conversationID; self.body = body }
}

public struct ConversationAvailabilityRequest: Codable, Sendable {
    public let conversationID: UUID
    public let availability: WorkerAvailability
    public init(conversationID: UUID, availability: WorkerAvailability) { self.conversationID = conversationID; self.availability = availability }
}
public struct ConversationAcknowledgementRequest: Codable, Sendable {
    public let conversationID: UUID, cursor: Int
    public init(conversationID: UUID, cursor: Int) { self.conversationID=conversationID; self.cursor=cursor }
}

/// Narrow IPC adapter for the durable chat operations. It has no authority over review decisions.
public actor AgentChatOperationHandler: IPCOperationHandler {
    private let coordinator: AgentChatCoordinator
    private let journal: any ConversationRequestJournal
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(coordinator: AgentChatCoordinator, journal: any ConversationRequestJournal) {
        self.coordinator = coordinator; self.journal = journal
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        let response: IPCResponse
        do {
            guard let payload = request.payload else { throw AgentChatError.invalidEvent("missing payload") }
            guard payload.count <= AgentChatIPCOperation.maximumPayloadBytes else { throw AgentChatError.invalidEvent("request limit") }
            guard AgentChatIPCOperation.all.contains(request.operation.value) else { throw AgentChatError.invalidEvent("unknown chat operation") }
            switch request.operation.value {
            case AgentChatIPCOperation.poll:
                let poll = try decoder.decode(ConversationPollRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard poll.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                let page = try await coordinator.pollPage(after: poll.after)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            case AgentChatIPCOperation.reply:
                let reply = try decoder.decode(ConversationReplyRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard reply.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                try await coordinator.hydrate()
                let events = try await coordinator.prepareReply(reply.body)
                let digest = RTCContracts.SHA256Digest(data: try RTCCanonicalJSON.encode(reply))
                let reviewID = await coordinator.reviewIDValue
                guard request.reviewID == nil || request.reviewID == reviewID else { throw AgentChatError.invalidEvent("review mismatch") }
                let committed = try await journal.commit(reviewID: reviewID, conversationID: conversationID, requestID: request.id, operation: request.operation.value, payloadDigest: digest, events: events)
                try await coordinator.applyCommitted(committed.events)
                let page = ConversationPage(after: committed.events.first!.sequence - 1, nextCursor: committed.events.last!.sequence, events: committed.events, hasMore: false)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            case AgentChatIPCOperation.availability:
                let availability = try decoder.decode(ConversationAvailabilityRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard availability.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                let snapshot = try await coordinator.setAvailability(availability.availability)
                let page = ConversationPage(after: max(0, snapshot.cursor - 1), nextCursor: snapshot.cursor, events: Array(snapshot.events.suffix(1)), hasMore: false)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            case AgentChatIPCOperation.acknowledge:
                let acknowledgement = try decoder.decode(ConversationAcknowledgementRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard acknowledgement.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                try await coordinator.hydrate()
                let snapshot = try await coordinator.acknowledge(upTo: acknowledgement.cursor)
                let page = ConversationPage(after: max(0, snapshot.cursor - 1), nextCursor: snapshot.cursor, events: Array(snapshot.events.suffix(1)), hasMore: false)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            default: throw AgentChatError.invalidEvent("unknown chat operation")
            }
        } catch {
            // Never serialize a thrown value: errors may contain paths, credentials, or prompts.
            let retryable = !(error is AgentChatError)
            let code: RTCErrorCode = error is AgentChatError ? .invalidJSON : .internalError
            response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: false, error: RTCError(code: code, message: BoundedString("chat operation rejected"), retryable: retryable), payload: nil)
        }
        return response
    }
}
