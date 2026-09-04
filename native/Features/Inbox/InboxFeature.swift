import Combine
import RTCContracts
import RTCDesign
import RTCIngest
import SwiftUI

public enum InboxSection: String, CaseIterable, Sendable {
    case pending = "Pending"
    case ready = "Ready"
    case failed = "Failed"
    case stale = "Stale"
}

public struct InboxItem: Identifiable, Equatable, Sendable {
    public let id: ReviewID
    public let title: String
    public let repositoryName: String
    public let baseSHA: String
    public let headSHA: String
    public let status: ReviewStatus
    public let unread: Bool
    public let stale: Bool
    public let errorMessage: String?
    public let updatedAt: Date

    public init(record: IngestReviewRecord) {
        id = record.reviewID
        title = record.title
        repositoryName = URL(fileURLWithPath: record.revision.repositoryPath).lastPathComponent
        baseSHA = record.revision.baseSHA
        headSHA = record.revision.headSHA
        status = record.status
        unread = record.unread
        stale = record.stale || record.status == .superseded
        errorMessage = record.errorMessage
        updatedAt = record.updatedAt
    }

    public var section: InboxSection {
        if stale { return .stale }
        if status == .failed { return .failed }
        if status == .accepted || status == .materializing { return .pending }
        return .ready
    }

    public var accessibilityValue: String {
        var parts = [unread ? "Unread" : "Read", section.rawValue]
        if status == .materializing { parts.append("Materializing committed evidence") }
        else if status == .accepted { parts.append("Waiting to materialize") }
        if stale { parts.append("Submitted refs moved") }
        if let errorMessage { parts.append(errorMessage) }
        return parts.joined(separator: ", ")
    }
}

public struct InboxSnapshot: Equatable, Sendable {
    public let items: [InboxItem]

    public init(records: [IngestReviewRecord]) {
        items = records.map(InboxItem.init).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.value < $1.id.value
        }
    }

    public func items(in section: InboxSection) -> [InboxItem] {
        items.filter { $0.section == section }
    }
}

@MainActor
public final class InboxModel: ObservableObject {
    @Published public private(set) var snapshot = InboxSnapshot(records: [])
    @Published public private(set) var errorMessage: String?

    private let records: SQLiteIngestRepository
    private let coordinator: SubmissionCoordinator
    private let activate: @Sendable (ReviewID) async -> Void

    public init(
        records: SQLiteIngestRepository,
        coordinator: SubmissionCoordinator,
        activate: @escaping @Sendable (ReviewID) async -> Void
    ) {
        self.records = records
        self.coordinator = coordinator
        self.activate = activate
    }

    public func refresh() async {
        do {
            snapshot = InboxSnapshot(records: try await records.reviews(limit: 1_000))
            errorMessage = nil
        } catch {
            errorMessage = "The Inbox could not be refreshed."
        }
    }

    public func retry(_ item: InboxItem) async {
        do {
            try await coordinator.retry(item.id)
            await refresh()
        } catch {
            errorMessage = "The review could not be retried."
        }
    }

    public func open(_ item: InboxItem) async {
        do {
            try await coordinator.markRead(item.id)
            await refresh()
            await activate(item.id)
        } catch {
            errorMessage = "The review could not be opened."
        }
    }

    public func monitor() async {
        await refresh()
        let changes = await records.observeInbox()
        for await _ in changes where !Task.isCancelled { await refresh() }
    }
}

public struct InboxView: View {
    @ObservedObject private var model: InboxModel
    @State private var selection: ReviewID?

    public init(model: InboxModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(InboxSection.allCases, id: \.self) { section in
                    let items = model.snapshot.items(in: section)
                    if !items.isEmpty {
                        Section(section.rawValue) {
                            ForEach(items) { item in row(item).tag(item.id) }
                        }
                    }
                }
                if model.snapshot.items.isEmpty, model.errorMessage == nil {
                    RTCEmptyState(title: "No reviews yet", message: "Submitted exact revisions will appear here.")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Inbox")
            .overlay(alignment: .bottom) {
                if let error = model.errorMessage {
                    Text(error).padding(8).background(.regularMaterial).clipShape(.rect(cornerRadius: 8))
                }
            }
            .task { await model.monitor() }
            .refreshable { await model.refresh() }
            .onChange(of: model.snapshot) { _, snapshot in
                if selection == nil { selection = snapshot.items.first?.id }
            }
            .onKeyPress(.return) {
                guard let selected = selection, let item = model.snapshot.items.first(where: { $0.id == selected }) else { return .ignored }
                Task { await model.open(item); selection = nil }
                return .handled
            }
        }
    }

    @ViewBuilder
    private func row(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            Button { Task { await model.open(item) } } label: {
                HStack(spacing: 12) {
                    if item.section == .pending { ProgressView().controlSize(.small) }
                    else { Image(systemName: symbol(item)).foregroundStyle(color(item)) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title).fontWeight(item.unread ? .semibold : .regular)
                            Spacer()
                            RTCBadge(item.section.rawValue, tone: badgeTone(item))
                        }
                        Text(item.repositoryName).foregroundStyle(.secondary)
                        Text("\(item.baseSHA.prefix(8)) → \(item.headSHA.prefix(8))")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        if let message = item.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox-row-\(item.id.value)")
            .accessibilityLabel("\(item.title), \(item.repositoryName)")
            .accessibilityValue(item.accessibilityValue)
            if item.status == .failed {
                Button("Retry") { Task { await model.retry(item) } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("inbox-retry-\(item.id.value)")
                    .accessibilityLabel("Retry \(item.title)")
            }
        }
    }

    private func symbol(_ item: InboxItem) -> String {
        switch item.section {
        case .pending: "clock"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stale: "clock.arrow.circlepath"
        }
    }

    private func color(_ item: InboxItem) -> Color {
        switch item.section {
        case .pending: .secondary
        case .ready: .green
        case .failed: .red
        case .stale: .orange
        }
    }

    private func badgeTone(_ item: InboxItem) -> RTCBadge.Tone {
        switch item.section {
        case .pending: .neutral
        case .ready: .success
        case .failed: .danger
        case .stale: .warning
        }
    }
}
