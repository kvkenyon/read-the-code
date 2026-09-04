import SwiftUI
import RTCContracts
import RTCAgentChat
import RTCDesign

@MainActor
public final class AgentConversationRailModel: ObservableObject {
    public enum DeliveryState: Equatable { case idle, pending, sending, failed, reconnecting }
    @Published public private(set) var events: [ConversationEvent] = []
    @Published public private(set) var availability: WorkerAvailability = .offline
    @Published public private(set) var deliveryState: DeliveryState = .idle
    @Published public var composerText = ""

    private let queue: @Sendable (UUID, RichText) async throws -> ConversationSnapshot
    private let replay: @Sendable (Int) async throws -> ConversationSnapshot
    private var cursor = 0
    private var pendingRequestID: UUID?
    private static let maximumRenderedEvents = 200

    public init(queue: @escaping @Sendable (UUID, RichText) async throws -> ConversationSnapshot,
                replay: @escaping @Sendable (Int) async throws -> ConversationSnapshot) {
        self.queue = queue; self.replay = replay
    }

    public func reconnect() async {
        deliveryState = .reconnecting
        do { apply(try await replay(cursor)); deliveryState = .idle }
        catch { deliveryState = .failed }
    }

    public func send() async {
        guard !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let body = try? RichText(runs: [RichTextRun(kind: .plain, text: BoundedString(composerText))]) else { deliveryState = .failed; return }
        deliveryState = .pending; let requestID = pendingRequestID ?? UUID(); pendingRequestID = requestID
        let text = composerText; composerText = ""
        deliveryState = .sending
        do { apply(try await queue(requestID, body)); pendingRequestID = nil; deliveryState = .idle }
        catch { composerText = text; deliveryState = .failed }
    }

    private func apply(_ snapshot: ConversationSnapshot) {
        cursor = max(cursor, snapshot.cursor); availability = snapshot.availability
        let merged = (events + snapshot.events.filter { incoming in !events.contains(where: { $0.id == incoming.id }) }).sorted { $0.sequence < $1.sequence }
        events = Array(merged.suffix(Self.maximumRenderedEvents))
    }
}

/// Conversation is a collaboration surface only. It deliberately exposes no review
/// decision, thread mutation, or promotion action; those remain in RTCReview.
public struct AgentConversationRail: View {
    @ObservedObject private var model: AgentConversationRailModel
    public init(model: AgentConversationRailModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: RTCDesign.compactSpacing) {
            HStack { Text("Agent conversation").font(.headline); Spacer(); statusBadge }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.events, id: \.id) { event in ConversationRow(event: event) }
                        if model.events.isEmpty { RTCEmptyState(title: "No conversation yet", message: "Messages here are not review decisions.") }
                    }.padding(.vertical, 4)
                }
                .onChange(of: model.events.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            if model.deliveryState == .failed { HStack { Button("Retry send") { Task { await model.send() } }.buttonStyle(RTCButtonStyle(prominent: true)); Button("Reconnect") { Task { await model.reconnect() } }.buttonStyle(RTCButtonStyle()) } }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to the worker", text: $model.composerText, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.send() } }
                    .accessibilityLabel("Conversation reply")
                Button("Send") { Task { await model.send() } }
                    .buttonStyle(RTCButtonStyle(prominent: true))
                    .disabled(model.deliveryState != .idle || model.availability == .ended || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }.padding(14).task { await model.reconnect() }
    }

    @ViewBuilder private var statusBadge: some View {
        switch model.deliveryState {
        case .pending, .sending: RTCBadge("Sending", tone: .warning)
        case .reconnecting: RTCBadge("Reconnecting", tone: .warning)
        case .failed: RTCBadge("Reconnect needed", tone: .danger)
        case .idle: RTCBadge(model.availability == .online ? "Connected" : "Worker offline", tone: model.availability == .online ? .success : .neutral)
        }
    }
}

private struct ConversationRow: View {
    let event: ConversationEvent
    var body: some View {
        Group {
            if event.kind == .humanMessageQueued || event.kind == .assistantMessageDelta, let body = event.body { Text(body.runs.map(\.text.value).joined()).textSelection(.enabled) }
            else { Text(label).foregroundStyle(RTCDesign.color(.textSecondary)) }
        }
        .font(.system(size: 13)).padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(event.kind == .humanMessageQueued ? RTCDesign.color(.selection) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: RTCDesign.cornerRadius))
        .id(event.id)
        .accessibilityLabel(label)
    }
    private var label: String { switch event.kind { case .assistantMessageStarted: "Agent is replying…"; case .assistantMessageCompleted: "Reply complete"; case .assistantMessageFailed: "Reply failed"; case .workerAvailabilityChanged: "Worker availability changed"; case .workerAcknowledged: "Worker received messages"; case .workerWakeSignaled: "Worker notified"; case .conversationEnded: "Conversation ended"; default: "Conversation update" } }
}
