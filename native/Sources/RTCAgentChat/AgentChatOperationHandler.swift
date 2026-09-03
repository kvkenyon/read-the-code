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

/// Narrow IPC adapter for the durable chat operations. It has no authority over review decisions.
public struct AgentChatOperationHandler: IPCOperationHandler {
    private let coordinator: AgentChatCoordinator
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(coordinator: AgentChatCoordinator) {
        self.coordinator = coordinator
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            guard let payload = request.payload else { throw AgentChatError.invalidEvent("missing payload") }
            let snapshot: ConversationSnapshot
            switch request.operation.value {
            case "pollConversationEvents":
                let poll = try decoder.decode(ConversationPollRequest.self, from: payload)
                snapshot = try await coordinator.poll(after: poll.after)
            case "postConversationReply":
                let reply = try decoder.decode(ConversationReplyRequest.self, from: payload)
                snapshot = try await coordinator.reply(reply.body)
            default: throw AgentChatError.invalidEvent("unknown chat operation")
            }
            return IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: true, error: nil, payload: try encoder.encode(snapshot.events))
        } catch {
            let message = (try? BoundedString(String(describing: error), maxCharacters: 512)) ?? BoundedString("chat operation failed")
            let rtcError = RTCError(code: .internalError, message: message, retryable: true)
            return IPCResponse(schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: false, error: rtcError, payload: nil)
        }
    }
}
