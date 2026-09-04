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

public struct ReviewWorkspaceRestorationState: Codable, Equatable, Sendable {
    public static let currentVersion=1
    public var version=currentVersion
    public var selection: CanvasSelection?
    public var selectedFile: String?
    public var selectedThreadID: UUID?
    public init(selection: CanvasSelection? = nil, selectedFile: String? = nil, selectedThreadID: UUID? = nil) { self.selection=selection; self.selectedFile=selectedFile; self.selectedThreadID=selectedThreadID }
    public static func decode(_ data: Data?) -> ReviewWorkspaceRestorationState {
        guard let data, let value=try? JSONDecoder().decode(Self.self, from: data), value.version == currentVersion else { return Self() }
        return value
    }
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

@MainActor
public final class ReviewWorkspaceModel: ObservableObject {
    public enum ThreadFilter: String, CaseIterable, Sendable { case open, drafts, resolved, all }
    public struct Composer: Equatable, Sendable {
        public let selection: CanvasSelection
        public var body: String
        public init(selection: CanvasSelection, body: String = "") { self.selection=selection; self.body=body }
    }
    public struct NavigationRequest: Equatable, Sendable {
        public let id = UUID()
        public let selection: CanvasSelection?
        public let file: String?
        public let focus: Bool
    }

    public let revision: RevisionIdentity
    public let handler: ReviewCommandHandler
    public let files: [CanvasFile]
    @Published public private(set) var selection: CanvasSelection?
    @Published public private(set) var selectedFile: String?
    @Published public private(set) var selectedThreadID: UUID?
    @Published public private(set) var composer: Composer?
    @Published public private(set) var threads: [ReviewThread] = []
    @Published public private(set) var progress: [FileProgress] = []
    @Published public private(set) var isReadOnly = true
    @Published public private(set) var stale = false
    @Published public private(set) var verificationAvailable = true
    @Published public private(set) var status: ReviewStatus = .ready
    @Published public private(set) var isLoading = true
    @Published public private(set) var operationError: String?
    @Published public private(set) var anchorIssues: [UUID: RTCDomainError] = [:]
    @Published public private(set) var navigationRequest: NavigationRequest?
    @Published public var threadFilter: ThreadFilter = .open
    @Published public var commentQuery = ""
    @Published public var replyBody = ""
    @Published public var requestChangesSummary = ""
    private var operationIDs: [String: UUID] = [:]

    public init(revision: RevisionIdentity, files: [CanvasFile], handler: ReviewCommandHandler, restorationData: Data? = nil) {
        let restoration=ReviewWorkspaceRestorationState.decode(restorationData)
        self.revision=revision; self.files=files; self.handler=handler
        selection=restoration.selection; selectedFile=restoration.selectedFile ?? files.first?.artifact.path; selectedThreadID=restoration.selectedThreadID
        if let selection=restoration.selection { navigationRequest=NavigationRequest(selection: selection, file: nil, focus: false) }
    }

    public var canvas: CanvasSnapshot {
        let inlineThreads = threads.compactMap { thread -> CanvasInlineThread? in
            guard let side = thread.anchor.side, let start = thread.anchor.startLine, let end = thread.anchor.endLine else { return nil }
            let selected = CanvasSelection(path: thread.anchor.path, side: side, startLine: start, endLine: end)
            let state=anchorIssues[thread.id] == nil ? thread.state.rawValue : "stale anchor"
            return CanvasInlineThread(id: thread.id, selection: selected, state: state, body: bodyText(thread.latestMessage?.body))
        }
        return CanvasSnapshot(revision: revision, files: files, selected: selection, threads: inlineThreads, composer: composer?.selection)
    }

    public var filteredThreads: [ReviewThread] {
        threads.filter { thread in
            let filterMatch = threadFilter == .all || (threadFilter == .open && thread.state == .open) || (threadFilter == .drafts && thread.state == .draft) || (threadFilter == .resolved && thread.state == .resolved)
            let body = thread.messages.map { bodyText($0.body) }.joined(separator: " ")
            return filterMatch && (commentQuery.isEmpty || thread.anchor.path.localizedCaseInsensitiveContains(commentQuery) || body.localizedCaseInsensitiveContains(commentQuery))
        }
    }
    public var selectedThread: ReviewThread? { selectedThreadID.flatMap { id in threads.first { $0.id == id } } }
    public var viewedCount: Int { progress.filter(\.viewed).count }
    public var draftCount: Int { threads.filter { $0.state == .draft }.count }
    public var approvalWarning: String? {
        let unviewed=progress.count-viewedCount, active=threads.filter { $0.state != .resolved }.count
        guard unviewed > 0 || active > 0 else { return nil }
        return "Approves this exact head with \(unviewed) unviewed files and \(active) active threads."
    }
    public var mutationLabel: String {
        if !verificationAvailable { return "Revision verification unavailable — changes are disabled" }
        if stale { return "Moved symbolic head — exact revision evidence remains readable" }
        if isReadOnly { return "Historical evidence — changes are disabled" }
        return "Exact committed revision"
    }

    public func refresh() async {
        let snapshot = await handler.snapshot()
        let issues = await handler.anchorIssues()
        threads=snapshot.threads; progress=snapshot.progress; isReadOnly = !snapshot.isMutable; stale=snapshot.stale
        anchorIssues=issues
        verificationAvailable=snapshot.verificationAvailable; status=snapshot.status; isLoading=false
        if let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) { self.selectedThreadID=nil }
    }

    public func select(_ next: CanvasSelection) { selection=next; selectedFile=next.path }
    public func selectFile(_ path: String, focus: Bool = true) { selectedFile=path; navigationRequest=NavigationRequest(selection: nil, file: path, focus: focus) }
    public func selectThread(_ id: UUID, focus: Bool = true) {
        guard let thread=threads.first(where: { $0.id == id }), let side=thread.anchor.side, let start=thread.anchor.startLine, let end=thread.anchor.endLine else { return }
        selectedThreadID=id; selectedFile=thread.anchor.path
        let target=CanvasSelection(path: thread.anchor.path, side: side, startLine: start, endLine: end)
        selection=target; navigationRequest=NavigationRequest(selection: target, file: nil, focus: focus)
    }
    public func openComposer() { guard !isReadOnly, let selection else { return }; composer=Composer(selection: selection); operationError=nil }
    public func cancelComposer() { composer=nil; operationIDs["composer"]=nil; if let selection { navigationRequest=NavigationRequest(selection: selection, file: nil, focus: true) } }
    public func updateComposer(_ body: String) { composer?.body=body }
    public func clearError() { operationError=nil }
    public func report(_ error: Error) { operationError=String(describing: error) }

    public func anchor(for selection: CanvasSelection) throws -> ReviewAnchor {
        guard let file=files.first(where: { $0.artifact.path == selection.path }) else { throw RTCDomainError.invalidAnchor }
        let matching=file.hunks.flatMap(\.lines).filter { line in
            let number=selection.side == .new ? line.newLine : line.oldLine
            return number.map { selection.startLine...selection.endLine ~= $0 } ?? false
        }
        guard let first=matching.first, let last=matching.last else { throw RTCDomainError.staleAnchor }
        return try ReviewAnchor(revision: revision, path: selection.path, oldPath: file.artifact.oldPath, scope: .line, side: selection.side, startLine: selection.startLine, endLine: selection.endLine, startContextHash: first.contextHash, endContextHash: last.contextHash)
    }

    @discardableResult public func saveComposer() async throws -> UUID {
        guard !isReadOnly, let composer, !composer.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RTCDomainError.readOnly }
        let key="composer", operationID=id(for: key)
        do {
            let threadID=try await handler.createDraft(anchor: try anchor(for: composer.selection), body: try richText(composer.body), operationID: operationID)
            self.composer=nil; operationIDs[key]=nil; selectedThreadID=threadID; navigationRequest=NavigationRequest(selection: composer.selection, file: nil, focus: true); try await finish(); return threadID
        } catch { await refresh(); throw error }
    }

    public func markViewed(_ path: String, viewed: Bool? = nil) async throws {
        guard !isReadOnly, let current=progress.first(where: { $0.path == path }) else { throw RTCDomainError.readOnly }
        let next=viewed ?? !current.viewed, key="progress:\(path)", operationID=id(for: key)
        do { _=try await handler.markViewed(path: path, viewed: next, expectedVersion: current.version, operationID: operationID); operationIDs[key]=nil; try await finish() }
        catch { await refresh(); throw error }
    }
    public func resolve(_ threadID: UUID) async throws { try await threadAction("resolve", threadID) { try await handler.resolve(threadID: threadID, operationID: $0) } }
    public func reopen(_ threadID: UUID) async throws { try await threadAction("reopen", threadID) { try await handler.reopen(threadID: threadID, operationID: $0) } }
    public func toggleThreadState(_ threadID: UUID) async throws { if threads.first(where: { $0.id == threadID })?.state == .resolved { try await reopen(threadID) } else { try await resolve(threadID) } }
    public func reply(_ threadID: UUID) async throws {
        guard !replyBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RTCDomainError.invalidTransition }
        let key="reply:\(threadID)", operationID=id(for: key)
        do { _=try await handler.reply(threadID: threadID, body: try richText(replyBody), operationID: operationID); replyBody=""; operationIDs[key]=nil; try await finish() }
        catch { await refresh(); throw error }
    }
    public func sendDrafts() async throws -> ReviewEvent {
        let key="send", operationID=id(for: key)
        do { let event=try await handler.sendReview(threadIDs: threads.filter { $0.state == .draft }.map(\.id), operationID: operationID); operationIDs[key]=nil; try await finish(); return event }
        catch { await refresh(); throw error }
    }
    public func requestChanges(summary: String) async throws -> ReviewEvent {
        let key="requestChanges", operationID=id(for: key), rich=summary.isEmpty ? nil : try richText(summary)
        do { let event=try await handler.requestChanges(threadIDs: threads.filter { $0.state == .draft }.map(\.id), summary: rich, operationID: operationID); operationIDs[key]=nil; requestChangesSummary=""; try await finish(); return event }
        catch { await refresh(); throw error }
    }
    public func approve() async throws -> ReviewEvent { try await decision("approve") { try await handler.approveExactRevision(operationID: $0) } }
    public func close() async throws -> ReviewEvent { try await decision("close") { try await handler.closeReview(operationID: $0) } }
    public func markHead(_ head: String) async { await handler.markHead(head); await refresh() }
    public func restorationData() -> Data? { ReviewWorkspaceRestorationState(selection: selection, selectedFile: selectedFile, selectedThreadID: selectedThreadID).encoded() }

    public func perform(_ command: WorkspaceCommand) async throws {
        switch command {
        case .markViewed: if let selectedFile { try await markViewed(selectedFile) }
        case .comment: openComposer()
        case .sendReview: _=try await sendDrafts()
        case .requestChanges: _=try await requestChanges(summary: requestChangesSummary)
        case .approve: _=try await approve()
        case .close: _=try await close()
        case .showDiff, .showTour, .toggleInbox, .toggleAgentRail, .toggleComments: break
        }
    }

    private func threadAction(_ action: String, _ threadID: UUID, perform: (UUID) async throws -> ReviewEvent) async throws {
        let key="\(action):\(threadID)", operationID=id(for: key)
        do { _=try await perform(operationID); operationIDs[key]=nil; try await finish() } catch { await refresh(); throw error }
    }
    private func decision(_ key: String, perform: (UUID) async throws -> ReviewEvent) async throws -> ReviewEvent {
        let operationID=id(for: key)
        do { let event=try await perform(operationID); operationIDs[key]=nil; try await finish(); return event } catch { await refresh(); throw error }
    }
    private func finish() async throws { operationError=nil; await refresh() }
    private func id(for key: String) -> UUID { if let existing=operationIDs[key] { return existing }; let value=UUID(); operationIDs[key]=value; return value }
    private func richText(_ value: String) throws -> RichText {
        guard value.utf8.count <= RTCConstants.maxCommentBytes else { throw RTCContractError.invalid("comment bytes") }
        return try RichText(runs: [RichTextRun(kind: .plain, text: BoundedString(value, maxCharacters: RTCConstants.maxCommentBytes))])
    }
    private func bodyText(_ body: RichText?) -> String { body?.runs.map(\.text.value).joined() ?? "" }
}

@MainActor
public final class ReviewWorkspaceCommandRouter: NSObject {
    private let model: ReviewWorkspaceModel
    public init(model: ReviewWorkspaceModel) { self.model=model }
    public func reviewMenu() -> NSMenu {
        let menu=WorkspaceMenus.review(target: self, action: #selector(performMenuCommand(_:)))
        for item in menu.items { item.representedObject=WorkspaceCommand.allCases.first(where: { $0.title == item.title })?.rawValue }
        return menu
    }
    @objc public func performMenuCommand(_ sender: NSMenuItem) {
        guard let raw=sender.representedObject as? String, let command=WorkspaceCommand(rawValue: raw) else { return }
        Task { do { try await model.perform(command) } catch { model.report(error) } }
    }
}

public struct ReviewWorkspaceSyntaxAdapter: RTCDiffCanvas.SyntaxHighlighter {
    private let highlighter: RTCSyntaxHighlighter
    public init(highlighter: RTCSyntaxHighlighter = RTCSyntaxHighlighter()) { self.highlighter=highlighter }
    public func spans(for line: DiffLine, path: String) async -> [RTCDiffCanvas.SyntaxSpan] {
        let digest=SHA256Digest(data: Data(line.text.utf8))
        let spans=(try? await highlighter.highlight(path: path, fileDigest: digest, source: line.text, language: nil, lines: 1..<2)) ?? []
        return spans.map { RTCDiffCanvas.SyntaxSpan(range: $0.startColumn..<$0.endColumn, token: $0.token.value) }
    }
}

public struct RTCReviewWorkspaceView: View {
    @ObservedObject private var model: ReviewWorkspaceModel
    public init(model: ReviewWorkspaceModel) { self.model=model }
    public var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model)
            if let error=model.operationError { RTCErrorState(title: "Review action failed", message: error, retry: { model.clearError() }).padding(.vertical, 6) }
            if model.isLoading { ProgressView("Loading exact revision…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ReviewWorkspaceSplitHost(model: model) }
        }
        .task { await model.refresh() }
        .background(RTCDesign.color(.canvas))
    }
}

private struct ReviewHeader: View {
    @ObservedObject var model: ReviewWorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RTCBadge(!model.verificationAvailable ? "unverified" : model.stale ? "stale revision" : model.status.rawValue, tone: model.isReadOnly ? .warning : .neutral)
                Text(model.revision.baseSHA.prefix(8) + " → " + model.revision.headSHA.prefix(8)).font(.system(.caption, design: .monospaced)).help("Exact committed revision: \(model.revision.baseSHA) → \(model.revision.headSHA)")
                Text("\(model.files.reduce(0) { $0 + $1.artifact.additions }) additions").foregroundStyle(RTCDesign.color(.addition)).font(.caption)
                Text("\(model.files.reduce(0) { $0 + $1.artifact.deletions }) deletions").foregroundStyle(RTCDesign.color(.deletion)).font(.caption)
                Spacer()
                Text("\(model.viewedCount) / \(model.progress.count) Files Viewed").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                Text("\(model.threads.count) Comments").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                Button("Comment") { model.openComposer() }.buttonStyle(RTCButtonStyle()).keyboardShortcut("c", modifiers: [.command]).disabled(model.isReadOnly || model.selection == nil)
                Button("Send review") { run { _=try await model.sendDrafts() } }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly || model.draftCount == 0)
                Button("Request changes") { run { _=try await model.requestChanges(summary: model.requestChangesSummary) } }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly || (model.draftCount == 0 && model.requestChangesSummary.isEmpty))
                Button("Approve") { run { _=try await model.approve() } }.buttonStyle(RTCButtonStyle(prominent: true)).keyboardShortcut("a", modifiers: [.command]).disabled(model.isReadOnly).help(model.approvalWarning ?? "Approve this exact committed revision")
                Button("Close") { run { _=try await model.close() } }.buttonStyle(RTCButtonStyle()).disabled(model.isReadOnly)
            }.padding(10)
            if model.isReadOnly { Text(model.mutationLabel).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 7) }
        }.accessibilityElement(children: .contain).accessibilityLabel("Review status and actions")
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { model.report(error) } } }
}

private struct ReviewWorkspaceSplitHost: NSViewControllerRepresentable {
    @ObservedObject var model: ReviewWorkspaceModel
    func makeNSViewController(context: Context) -> WorkspaceShell {
        WorkspaceShell(content: [
            .story: NSHostingController(rootView: FileNavigator(model: model)),
            .canvas: NSHostingController(rootView: CanvasPane(model: model)),
            .comments: NSHostingController(rootView: CommentsRail(model: model)),
        ], enabledPanes: [.story, .canvas, .comments])
    }
    func updateNSViewController(_ controller: WorkspaceShell, context: Context) {}
}

private struct FileNavigator: View {
    @ObservedObject var model: ReviewWorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changed files").font(.headline).padding(.horizontal, 10).padding(.top, 10)
            if model.files.isEmpty { RTCEmptyState(title: "No changed files", message: "This exact revision has no materialized diff rows.") }
            else {
                List(model.files, id: \.artifact.path) { file in
                    HStack(spacing: 6) {
                        Button { run { try await model.markViewed(file.artifact.path) } } label: { Image(systemName: viewed(file.artifact.path) ? "checkmark.circle.fill" : "circle").foregroundStyle(RTCDesign.color(.storySpine)) }.buttonStyle(.plain).disabled(model.isReadOnly).accessibilityLabel(viewed(file.artifact.path) ? "Mark \(file.artifact.path) unviewed" : "Mark \(file.artifact.path) viewed")
                        Button { model.selectFile(file.artifact.path) } label: {
                            HStack { Text(file.artifact.path).lineLimit(1); Spacer(); Text("+\(file.artifact.additions) −\(file.artifact.deletions)").font(.caption2).foregroundStyle(RTCDesign.color(.textSecondary)) }
                        }.buttonStyle(.plain).accessibilityLabel("Open \(file.artifact.path), \(file.artifact.additions) additions, \(file.artifact.deletions) deletions")
                    }.padding(.vertical, 2).background(model.selectedFile == file.artifact.path ? RTCDesign.color(.selection) : .clear)
                }.listStyle(.sidebar)
            }
        }.background(RTCDesign.color(.canvas)).accessibilityLabel("Changed files")
    }
    private func viewed(_ path: String) -> Bool { model.progress.first(where: { $0.path == path })?.viewed == true }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { model.report(error) } } }
}

private struct CanvasPane: View {
    @ObservedObject var model: ReviewWorkspaceModel
    var body: some View {
        ZStack(alignment: .top) {
            if model.files.isEmpty { RTCEmptyState(title: "Nothing to review", message: "The immutable diff contains no text rows.") }
            else { ReviewCanvasHost(model: model) }
            let exceptional=model.files.filter { $0.artifact.binary || $0.artifact.truncated }
            if !exceptional.isEmpty {
                Text(exceptional.map { "\($0.artifact.path): \($0.artifact.binary ? "binary" : "truncated") evidence" }.joined(separator: "  ·  ")).font(.caption).padding(7).background(.thinMaterial).accessibilityLabel("Limited diff evidence")
            }
        }.background(RTCDesign.color(.canvas))
    }
}

private struct CommentsRail: View {
    @ObservedObject var model: ReviewWorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search comments", text: $model.commentQuery).textFieldStyle(.roundedBorder).accessibilityLabel("Search comments by file or body")
            Picker("Thread filter", selection: $model.threadFilter) { ForEach(ReviewWorkspaceModel.ThreadFilter.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().pickerStyle(.segmented)
            TextField("Request-changes summary", text: $model.requestChangesSummary).textFieldStyle(.roundedBorder).disabled(model.isReadOnly).accessibilityHint("Optional summary submitted atomically with draft comments")
            if model.filteredThreads.isEmpty { RTCEmptyState(title: "No \(model.threadFilter.rawValue) comments", message: "Select a diff line and choose Comment to start a review thread.") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.filteredThreads, id: \.id) { thread in
                        Button { model.selectThread(thread.id) } label: {
                            RTCCard { VStack(alignment: .leading, spacing: 6) {
                                HStack { RTCBadge(model.anchorIssues[thread.id] == nil ? thread.state.rawValue : "stale anchor", tone: model.anchorIssues[thread.id] == nil ? .neutral : .warning); Spacer(); Text(thread.anchor.path).font(.caption).lineLimit(1) }
                                Text(thread.latestMessage?.body.runs.map(\.text.value).joined() ?? "").font(.subheadline).multilineTextAlignment(.leading)
                                Text("Lines \(thread.anchor.startLine ?? 0)–\(thread.anchor.endLine ?? 0)").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                            }}
                        }.buttonStyle(.plain).accessibilityLabel("\(thread.state.rawValue) comment in \(thread.anchor.path), line \(thread.anchor.startLine ?? 0)").accessibilityAddTraits(model.selectedThreadID == thread.id ? .isSelected : [])
                    }
                }
            }
            if let thread=model.selectedThread {
                Divider()
                Text("Selected thread · \(thread.anchor.path):\(thread.anchor.startLine ?? 0)").font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                TextField("Reply", text: $model.replyBody).textFieldStyle(.roundedBorder).disabled(model.isReadOnly || thread.state != .open)
                HStack {
                    Button(thread.state == .resolved ? "Reopen" : "Resolve") { run { try await model.toggleThreadState(thread.id) } }.disabled(model.isReadOnly || thread.state == .draft)
                    Spacer()
                    Button("Reply") { run { try await model.reply(thread.id) } }.buttonStyle(RTCButtonStyle(prominent: true)).disabled(model.isReadOnly || thread.state != .open || model.replyBody.isEmpty)
                }
            }
        }.padding(10).background(RTCDesign.color(.canvas)).accessibilityLabel("Comments")
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { model.report(error) } } }
}

private struct ReviewCanvasHost: NSViewRepresentable {
    @ObservedObject var model: ReviewWorkspaceModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let controller=ReviewCanvasController(); controller.delegate=context.coordinator; controller.syntaxHighlighter=ReviewWorkspaceSyntaxAdapter(); controller.loadView(); controller.apply(model.canvas); context.coordinator.controller=controller; return controller.view as! NSScrollView
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.model=model; context.coordinator.controller?.apply(model.canvas)
        if let request=model.navigationRequest, request.id != context.coordinator.lastNavigationID {
            context.coordinator.lastNavigationID=request.id
            if let selection=request.selection { context.coordinator.controller?.navigate(to: selection, focus: request.focus) }
            else if let file=request.file { context.coordinator.controller?.navigate(toFile: file, focus: request.focus) }
        }
    }
    final class Coordinator: NSObject, ReviewCanvasDelegate {
        weak var controller: ReviewCanvasController?
        var model: ReviewWorkspaceModel
        var lastNavigationID: UUID?
        init(model: ReviewWorkspaceModel) { self.model=model }
        func canvas(_ canvas: ReviewCanvasController, didSelect event: CanvasNavigationEvent) { model.select(event.selection) }
        func canvas(_ canvas: ReviewCanvasController, didRequestCommentAt selection: CanvasSelection) { model.select(selection); model.openComposer() }
        func canvas(_ canvas: ReviewCanvasController, didActivateThread id: UUID) { model.selectThread(id, focus: false) }
        func canvasDidSaveComposer(_ canvas: ReviewCanvasController) { Task { do { _=try await model.saveComposer() } catch { model.report(error) } } }
        func canvasDidCancelComposer(_ canvas: ReviewCanvasController) { model.cancelComposer() }
        func canvas(_ canvas: ReviewCanvasController, didUpdateComposer body: String) { model.updateComposer(body) }
        func canvas(_ canvas: ReviewCanvasController, didRequestThreadAction id: UUID) { Task { do { try await model.toggleThreadState(id) } catch { model.report(error) } } }
    }
}
