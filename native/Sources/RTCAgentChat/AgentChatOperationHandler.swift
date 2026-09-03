import Foundation
import RTCContracts

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
            let snapshot: ConversationSnapshot
            switch request.operation.value {
            case "pollConversationEvents":
                let poll = try decoder.decode(ConversationPollRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard poll.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                let page = try await coordinator.pollPage(after: poll.after)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            case "postConversationReply":
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
            case "setConversationAvailability":
                let availability = try decoder.decode(ConversationAvailabilityRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard availability.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                snapshot = try await coordinator.setAvailability(availability.availability)
                let page = ConversationPage(after: max(0, snapshot.cursor - 1), nextCursor: snapshot.cursor, events: Array(snapshot.events.suffix(1)), hasMore: false)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            case "acknowledgeConversationEvents":
                let acknowledgement = try decoder.decode(ConversationAcknowledgementRequest.self, from: payload)
                let conversationID = await coordinator.conversationIDValue
                guard acknowledgement.conversationID == conversationID else { throw AgentChatError.invalidEvent("conversation mismatch") }
                try await coordinator.hydrate()
                snapshot = try await coordinator.acknowledge(upTo: acknowledgement.cursor)
                let page = ConversationPage(after: max(0, snapshot.cursor - 1), nextCursor: snapshot.cursor, events: Array(snapshot.events.suffix(1)), hasMore: false)
                response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(page))
                return response
            default: throw AgentChatError.invalidEvent("unknown chat operation")
            }
            response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(snapshot.events))
        } catch {
            // Never serialize a thrown value: errors may contain paths, credentials, or prompts.
            let retryable = !(error is AgentChatError)
            let code: RTCErrorCode = error is AgentChatError ? .invalidJSON : .internalError
            response = IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: false, error: RTCError(code: code, message: BoundedString("chat operation rejected"), retryable: retryable), payload: nil)
        }
        return response
    }
}
