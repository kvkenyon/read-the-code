import AppKit
import Combine
import RTCContracts
import RTCDesign
import RTCDiffCanvas
import RTCDomain
import RTCReview
import RTCSyntax
import RTCWorkspaceShell
import SwiftUI

/// The view model is the composition boundary for Diff mode. It deliberately
/// delegates mutations to `ReviewCommandHandler`, so a pane never becomes an
/// alternative source of truth for durable threads or file progress.
@MainActor
public final class ReviewWorkspaceModel: ObservableObject {
    public enum ThreadFilter: String, CaseIterable, Sendable { case open, drafts, resolved, all }
    public struct Composer: Equatable, Sendable {
        public let selection: CanvasSelection
        public var body: String
        public init(selection: CanvasSelection, body: String = "") { self.selection = selection; self.body = body }
    }

    public let revision: RevisionIdentity
    public let handler: ReviewCommandHandler
    public let canvas: CanvasSnapshot
    @Published public private(set) var selection: CanvasSelection?
    @Published public private(set) var composer: Composer?
    @Published public private(set) var threads: [ReviewThread] = []
    @Published public private(set) var progress: [FileProgress] = []
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var status: ReviewStatus = .ready
    @Published public var threadFilter: ThreadFilter = .open
    @Published public var commentQuery = ""

    public init(revision: RevisionIdentity, files: [CanvasFile], handler: ReviewCommandHandler) {
        self.revision = revision
        self.handler = handler
        canvas = CanvasSnapshot(revision: revision, files: files)
    }

    public var filteredThreads: [ReviewThread] {
        threads.filter { thread in
            let filterMatch = threadFilter == .all ||
                (threadFilter == .open && thread.state == .open) ||
                (threadFilter == .drafts && thread.state == .draft) ||
                (threadFilter == .resolved && thread.state == .resolved)
            let body = thread.messages.map { $0.body.runs.map(\.text.value).joined() }.joined(separator: " ")
            return filterMatch && (commentQuery.isEmpty || thread.anchor.path.localizedCaseInsensitiveContains(commentQuery) || body.localizedCaseInsensitiveContains(commentQuery))
        }
    }

    public var viewedCount: Int { progress.filter(\.viewed).count }
    public var mutationLabel: String { isReadOnly ? "Historical evidence — changes are disabled" : "Exact revision" }

    public func refresh() async {
        threads = await handler.snapshotThreads()
        progress = await handler.snapshotProgress()
        let state = await handler.revisionState
        isReadOnly = state.stale || state.status == .closed || state.status == .superseded
        status = state.status
    }

    public func select(_ next: CanvasSelection) { selection = next }
    public func openComposer() { guard !isReadOnly, let selection else { return }; composer = Composer(selection: selection) }
    public func cancelComposer() { composer = nil }
    public func updateComposer(_ body: String) { composer?.body = body }

    private func richText(_ value: String) throws -> RichText {
        guard value.utf8.count <= RTCConstants.maxCommentBytes else { throw RTCContractError.invalid("comment bytes") }
        return try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString(value, maxCharacters: RTCConstants.maxCommentBytes))])
    }

    /// Context hashes are copied from the immutable materialized diff, never
    /// reconstructed from a working tree or from editor text.
    public func anchor(for selection: CanvasSelection) throws -> ReviewAnchor {
        guard let file = canvas.files.first(where: { $0.artifact.path == selection.path }) else { throw RTCDomainError.invalidAnchor }
        let matching = file.hunks.flatMap(\.lines).filter { line in
            switch selection.side { case .new: return line.newLine.map { selection.startLine...selection.endLine ~= $0 } ?? false
            case .old: return line.oldLine.map { selection.startLine...selection.endLine ~= $0 } ?? false }
        }
        guard let first = matching.first, let last = matching.last else { throw RTCDomainError.staleAnchor }
        return try ReviewAnchor(revision: revision, path: selection.path, oldPath: file.artifact.oldPath, scope: .line, side: selection.side, startLine: selection.startLine, endLine: selection.endLine, startContextHash: first.contextHash, endContextHash: last.contextHash)
    }

    @discardableResult public func saveComposer() async throws -> UUID {
        guard !isReadOnly, let composer, !composer.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RTCDomainError.readOnly }
        let anchor = try anchor(for: composer.selection)
        let text = try richText(composer.body)
        let id = try await handler.createDraft(anchor: anchor, body: text)
        self.composer = nil
        await refresh()
        return id
    }

    public func markViewed(_ path: String, viewed: Bool = true) async throws { guard !isReadOnly else { throw RTCDomainError.readOnly }; try await handler.markViewed(path: path, viewed: viewed); await refresh() }
    public func resolve(_ threadID: UUID) async throws { _ = try await handler.resolve(threadID: threadID); await refresh() }
    public func reopen(_ threadID: UUID) async throws { _ = try await handler.reopen(threadID: threadID); await refresh() }
    public func reply(_ threadID: UUID, body: String) async throws { try await handler.reply(threadID: threadID, body: try richText(body)); await refresh() }
    public func sendDrafts() async throws -> ReviewDomainEvent { let event = try await handler.sendReview(threadIDs: threads.filter { $0.state == .draft }.map(\.id)); await refresh(); return event }
    public func requestChanges(summary: String) async throws -> ReviewDomainEvent {
        let rich = summary.isEmpty ? nil : try richText(summary)
        let event = try await handler.requestChanges(threadIDs: threads.filter { $0.state == .draft }.map(\.id), summary: rich)
        await refresh(); return event
    }
    public func approve() async throws -> ReviewDecision { let decision = try await handler.approveExactRevision(); await refresh(); return decision }
    public func close() async throws -> ReviewDecision { let decision = try await handler.closeReview(); await refresh(); return decision }
    public func markHead(_ head: String) async { await handler.markHead(head); await refresh() }
}

/// Uses the bounded syntax service for canvas consumers without making the
/// canvas read files itself. Syntax remains a visual enhancement, not evidence.
public struct ReviewWorkspaceSyntaxAdapter: RTCDiffCanvas.SyntaxHighlighter {
    private let highlighter: RTCSyntaxHighlighter
    public init(highlighter: RTCSyntaxHighlighter = RTCSyntaxHighlighter()) { self.highlighter = highlighter }
    public func spans(for line: DiffLine, path: String) async -> [RTCDiffCanvas.SyntaxSpan] {
        let digest = SHA256Digest(data: Data(line.text.utf8))
        let spans = (try? await highlighter.highlight(path: path, fileDigest: digest, source: line.text, language: nil, lines: 1..<2)) ?? []
        return spans.map { RTCDiffCanvas.SyntaxSpan(range: $0.startColumn..<$0.endColumn, token: $0.token.value) }
    }
}

public struct RTCReviewWorkspaceView: View {
    @ObservedObject private var model: ReviewWorkspaceModel
    @State private var operationError: String?
    public init(model: ReviewWorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            header
            if let operationError { RTCErrorState(title: "Review action failed", message: operationError).padding(.vertical, 6) }
            HStack(spacing: 0) {
                fileNavigator.frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
                Divider()
                canvasPane.frame(minWidth: WorkspaceSizing.minimumCanvas)
                Divider()
                commentsRail.frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }.task { await model.refresh() }
    }

    private var canvasPane: some View {
        ZStack(alignment: .bottom) {
            ReviewCanvasHost(snapshot: model.canvas, selection: { model.select($0) }, comment: { selected in model.select(selected); model.openComposer() })
            if let composer = model.composer {
                RTCCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Draft thread").font(.subheadline.weight(.semibold)); Spacer(); Text("Lines \(composer.selection.startLine)–\(composer.selection.endLine)").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary)) }
                        TextEditor(text: Binding(get: { model.composer?.body ?? "" }, set: { model.updateComposer($0) })).font(.system(.body, design: .monospaced)).frame(minHeight: 76)
                        HStack { Spacer(); Button("Cancel") { model.cancelComposer() }.buttonStyle(RTCButtonStyle()); Button("Save to Review") { perform { _ = try await model.saveComposer() } }.buttonStyle(RTCButtonStyle(prominent: true)).keyboardShortcut(.return, modifiers: .command) }
                    }
                }.padding(16).accessibilityLabel("Inline comment composer")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RTCBadge(model.isReadOnly ? "stale revision" : model.status.rawValue, tone: model.isReadOnly ? .warning : .neutral)
            Text(model.revision.baseSHA.prefix(8) + " → " + model.revision.headSHA.prefix(8)).font(.system(.caption, design: .monospaced)).help("Exact committed revision")
            Spacer()
            Text("\(model.viewedCount) / \(model.progress.count) Files Viewed").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
            Button("Comment") { model.openComposer() }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly || model.selection == nil)
            Button("Send review") { perform { _ = try await model.sendDrafts() } }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly)
            Button("Request changes") { perform { _ = try await model.requestChanges(summary: "") } }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly)
            Button("Approve") { perform { _ = try await model.approve() } }.buttonStyle(RTCButtonStyle(prominent: true)).disabled(model.isReadOnly)
            Button("Close") { perform { _ = try await model.close() } }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly)
        }.padding(10).accessibilityElement(children: .contain).accessibilityLabel("Review actions")
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        operationError = nil
        Task { do { try await operation() } catch { operationError = String(describing: error) } }
    }

    private var fileNavigator: some View {
        List(model.canvas.files, id: \.artifact.path) { file in
            HStack { Image(systemName: model.progress.first(where: { $0.path == file.artifact.path })?.viewed == true ? "checkmark.circle.fill" : "circle").foregroundStyle(RTCDesign.color(.storySpine)); Text(file.artifact.path).lineLimit(1); Spacer(); Text("+\(file.artifact.additions) −\(file.artifact.deletions)").font(.caption2).foregroundStyle(RTCDesign.color(.textSecondary)) }
                .contentShape(Rectangle()).onTapGesture { perform { try await model.markViewed(file.artifact.path) } }
        }.listStyle(.sidebar).accessibilityLabel("Changed files")
    }

    private var commentsRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search comments", text: $model.commentQuery).textFieldStyle(.roundedBorder)
            Picker("Thread filter", selection: $model.threadFilter) { ForEach(ReviewWorkspaceModel.ThreadFilter.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.filteredThreads, id: \.id) { thread in
                        RTCCard {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { RTCBadge(thread.state.rawValue); Spacer(); Text(thread.anchor.path).font(.caption).lineLimit(1) }
                                Text(thread.latestMessage?.body.runs.map(\.text.value).joined() ?? "").font(.subheadline)
                                Text("Line \(thread.anchor.startLine ?? 0)").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                                HStack {
                                    Button("Reply") { perform { try await model.reply(thread.id, body: "Reply") } }.disabled(model.isReadOnly || thread.state == .resolved)
                                    if thread.state == .resolved { Button("Reopen") { perform { try await model.reopen(thread.id) } } }
                                    else if thread.state == .open { Button("Resolve") { perform { try await model.resolve(thread.id) } } }
                                }
                            }
                        }
                    }
                }
            }
        }.padding(10).background(RTCDesign.color(.canvas)).accessibilityLabel("Comments")
    }
}

private struct ReviewCanvasHost: NSViewRepresentable {
    let snapshot: CanvasSnapshot
    let selection: (CanvasSelection) -> Void
    let comment: (CanvasSelection) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selection: selection, comment: comment) }
    func makeNSView(context: Context) -> NSScrollView { let controller = ReviewCanvasController(); controller.delegate = context.coordinator; controller.loadView(); controller.apply(snapshot); context.coordinator.controller = controller; return controller.view as! NSScrollView }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.selection = selection; context.coordinator.comment = comment; context.coordinator.controller?.apply(snapshot) }
    final class Coordinator: NSObject, ReviewCanvasDelegate { weak var controller: ReviewCanvasController?; var selection: (CanvasSelection) -> Void; var comment: (CanvasSelection) -> Void; init(selection: @escaping (CanvasSelection) -> Void, comment: @escaping (CanvasSelection) -> Void) { self.selection = selection; self.comment = comment }; func canvas(_ canvas: ReviewCanvasController, didSelect event: CanvasNavigationEvent) { selection(event.selection) }; func canvas(_ canvas: ReviewCanvasController, didRequestCommentAt selection: CanvasSelection) { comment(selection) } }
}
