import RTCContracts
import RTCDesign
import RTCDiagram
import RTCTourIntegration
import SwiftUI

public enum TourWorkspaceStatus: Equatable, Sendable {
    case loading
    case generating(TourProgressSnapshot)
    case ready
    case readOnly(String)
    case noChanges
    case fallback(String)
    case failed(String)
    case cancelled
    case rejected
}

@MainActor
public final class TourWorkspaceModel: ObservableObject {
    @Published public private(set) var status: TourWorkspaceStatus = .loading
    @Published public private(set) var history: TourHistorySnapshot?
    @Published public private(set) var resolvedSlices: [DiffSliceReference: ResolvedDiffSlice] = [:]
    @Published public private(set) var diagramLayouts: [String: DiagramLayout] = [:]
    /// Material diagram categories the selected validated document does not contain.
    /// This is evidence only: rendering never synthesizes a diagram from an intent.
    @Published public private(set) var unavailableDiagramKinds: [DiagramKind] = []
    @Published public var selectedSectionID = "overview"

    public let reviewID: ReviewID
    public let revision: RevisionIdentity
    public let configuration: LocalTourConfiguration?
    private let jobs: TourGenerationJobHandler
    private let artifacts: any TourArtifactResolving
    private let navigate: @MainActor (ReviewAnchor) -> Void
    private var generationTask: Task<Void, Never>?
    private var renderingTask: Task<Void, Never>?

    public init(
        reviewID: ReviewID, revision: RevisionIdentity,
        configuration: LocalTourConfiguration? = nil,
        jobs: TourGenerationJobHandler, artifacts: any TourArtifactResolving,
        navigate: @escaping @MainActor (ReviewAnchor) -> Void
    ) {
        self.reviewID = reviewID; self.revision = revision; self.configuration = configuration
        self.jobs = jobs; self.artifacts = artifacts; self.navigate = navigate
    }

    deinit { generationTask?.cancel(); renderingTask?.cancel() }

    public var document: ValidatedTourDocument? { history?.selectedTour }
    public var canGenerate: Bool {
        configuration != nil && generationTask == nil && (history?.reviewState.isWritable ?? false)
    }

    public func load() async {
        status = .loading
        discardRenderableContent()
        unavailableDiagramKinds = []
        do {
            _ = try await jobs.resumePending()
            var snapshot = try await jobs.history(reviewID: reviewID, revision: revision)
            if snapshot.selectedTour == nil, snapshot.reviewState.isWritable,
                !snapshot.reviewState.manifest.files.isEmpty
            {
                _ = try await jobs.deterministicFallback(reviewID: reviewID, revision: revision)
                snapshot = try await jobs.history(reviewID: reviewID, revision: revision)
            }
            history = snapshot
            let selectedRun = snapshot.selectedTour.flatMap { selected in
                snapshot.runs.first { $0.tourID == selected.id }
            }
            applyStatus(from: selectedRun ?? snapshot.runs.first)
            unavailableDiagramKinds = unavailableDiagramKinds(for: snapshot.selectedTour, run: selectedRun)
            prepareRendering(snapshot.selectedTour)
        } catch {
            discardRenderableContent()
            status = .failed("Tour history could not be loaded.")
        }
    }

    /// Publishing a strictly validated persisted document must not wait for optional
    /// rendering decoration (syntax spans and bounded diagram layout). In particular,
    /// first-open fallback remains visible even if decoration is slow.
    private func prepareRendering(_ document: ValidatedTourDocument?) {
        renderingTask?.cancel()
        guard let document else { return }
        let documentID = document.id
        renderingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepareForRendering(document)
            } catch is CancellationError {
                return
            } catch {
                // The validated document remains visible. Unavailable rendering data is
                // deliberately omitted rather than replaced with executable content.
                guard self.document?.id == documentID else { return }
                discardRenderableContent()
            }
        }
    }

    public func generate() {
        guard let configuration, generationTask == nil else { return }
        status = .generating(.init(phase: "queued", fraction: 0))
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let run = try await jobs.generate(
                    reviewID: reviewID, revision: revision,
                    configuration: configuration
                ) { [weak self] progress in
                    await self?.receive(progress)
                }
                generationTask = nil
                if Task.isCancelled || run.state == .cancelled {
                    status = .cancelled
                    return
                }
                await load()
            } catch {
                generationTask = nil
                status = .failed("Tour generation failed explicitly.")
            }
        }
    }

    public func cancel() {
        generationTask?.cancel(); generationTask = nil; status = .cancelled
        Task { try? await jobs.cancel(reviewID: reviewID) }
    }

    public func select(tourID: UUID) async {
        do { try await jobs.select(reviewID: reviewID, revision: revision, tourID: tourID); await load() } catch {
            status = .failed("The selected tour is unavailable.")
        }
    }

    public func rate(_ rating: TourRating) async {
        guard let tourID = document?.id else { return }
        do {
            try await jobs.rate(reviewID: reviewID, revision: revision, tourID: tourID, rating: rating); await load()
        } catch {
            status = .failed("The tour rating could not be saved.")
        }
    }

    public func navigate(to anchor: ReviewAnchor) {
        Task {
            do { try await jobs.validateNavigation(anchor); navigate(anchor) } catch {
                status = .failed("The exact source anchor is no longer available.")
            }
        }
    }

    private func receive(_ progress: TourProgressSnapshot) {
        guard generationTask != nil else { return }
        status = .generating(progress)
    }

    private func prepareForRendering(_ document: ValidatedTourDocument?) async throws {
        discardRenderableContent()
        guard let document else { throw TourIntegrationError.noSelectedTour }
        guard document.revision == revision else { throw TourIntegrationError.revisionMismatch }
        var slices: [DiffSliceReference: ResolvedDiffSlice] = [:]
        var layouts: [String: DiagramLayout] = [:]
        let references = allBlocks(document).compactMap { block -> DiffSliceReference? in
            if case .diffSlice(let reference) = block { return reference }; return nil
        }
        for slice in try await artifacts.resolve(references, revision: revision) {
            slices[slice.reference] = slice
        }
        for block in allBlocks(document) {
            switch block {
            case .diagram(let diagram):
                layouts[diagram.id.value] = try artifacts.layout(diagram)
            default: break
            }
        }
        resolvedSlices = slices; diagramLayouts = layouts
    }

    private func allBlocks(_ document: ValidatedTourDocument) -> [TourBlock] {
        document.overview + document.chapters.flatMap(\.blocks)
    }

    private func unavailableDiagramKinds(
        for document: ValidatedTourDocument?, run: TourRunRecord?
    ) -> [DiagramKind] {
        let available = Set(document.map(allBlocks)?.compactMap { block -> String? in
            if case let .diagram(diagram) = block { return diagram.kind.rawValue }
            return nil
        } ?? [])
        return (run?.diagramIntents ?? []).compactMap { intent in
            intent.material && !available.contains(intent.kind.rawValue) ? intent.kind : nil
        }
    }

    private func discardRenderableContent() {
        resolvedSlices = [:]; diagramLayouts = [:]
    }

    private func applyStatus(from run: TourRunRecord?) {
        if let reason = history?.reviewState.readOnlyReason { status = .readOnly(reason); return }
        guard let run else { status = .failed("No tour is available."); return }
        switch run.state {
        case .fallback: status = .fallback(run.fallbackReason ?? "Generated outline unavailable.")
        case .failed: status = .failed("Tour generation failed explicitly.")
        case .cancelled: status = .cancelled
        case .rejected: status = .rejected
        case .noChanges: status = .noChanges
        case .queued, .running: status = .generating(run.progress)
        case .succeeded: status = .ready
        }
    }
}

public struct TourWorkspaceView: View {
    @ObservedObject private var model: TourWorkspaceModel
    public init(model: TourWorkspaceModel) { self.model = model }

    public var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                outline { id in
                    model.selectedSectionID = id
                    withAnimation(.easeInOut(duration: 0.14)) { proxy.scrollTo(id, anchor: .top) }
                }
                Divider()
                content
            }
        }
        .background(RTCDesign.color(.canvas))
        .task { await model.load() }
        .accessibilityIdentifier("tour.workspace")
    }

    private func outline(select: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tour").font(.title3.weight(.semibold))
            statusBadge.accessibilityIdentifier("tour.status")
            if model.canGenerate {
                Button("Generate Local Tour") { model.generate() }
                    .buttonStyle(RTCButtonStyle(prominent: true))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    outlineButton("Overview", id: "overview", select: select)
                    if !(model.document?.reviewFocuses.isEmpty ?? true) {
                        outlineButton("Review focuses", id: "focuses", select: select)
                    }
                    ForEach(model.document?.chapters ?? [], id: \.id.value) { chapter in
                        outlineButton(chapter.title.value, id: chapter.id.value, select: select)
                    }
                }
            }
            history
        }
        .padding(16)
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
        .background(RTCDesign.color(.surface))
    }

    private func outlineButton(_ title: String, id: String, select: @escaping (String) -> Void) -> some View {
        Button {
            select(id)
        } label: {
            HStack(spacing: 8) {
                Rectangle().fill(model.selectedSectionID == id ? RTCDesign.color(.storySpine) : .clear)
                    .frame(width: 2, height: 18)
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title)")
    }

    @ViewBuilder private var statusBadge: some View {
        switch model.status {
        case .loading: RTCBadge("Loading")
        case .generating(let progress):
            VStack(alignment: .leading, spacing: 5) {
                RTCBadge(progress.phase)
                ProgressView(value: progress.fraction)
                Button("Cancel") { model.cancel() }.buttonStyle(RTCButtonStyle())
            }
        case .ready: RTCBadge("Validated", tone: .success)
        case .readOnly: RTCBadge("Read-only", tone: .warning)
        case .noChanges: RTCBadge("No changes")
        case .fallback: RTCBadge("Fallback", tone: .warning)
        case .failed: RTCBadge("Failed", tone: .danger)
        case .cancelled: RTCBadge("Cancelled", tone: .warning)
        case .rejected: RTCBadge("Rejected", tone: .danger)
        }
    }

    @ViewBuilder private var history: some View {
        if let history = model.history {
            DisclosureGroup("History") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(history.tours, id: \.id) { tour in
                        Button {
                            Task { await model.select(tourID: tour.id) }
                        } label: {
                            HStack {
                                Text(tour.title.value).lineLimit(1)
                                if tour.id == history.selectedTour?.id { Image(systemName: "checkmark") }
                            }
                        }.buttonStyle(.plain)
                    }
                    ForEach(history.attachments) { attachment in
                        Label(
                            attachment.state == .accepted ? "Attachment accepted" : "Attachment rejected",
                            systemImage: attachment.state == .accepted ? "paperclip.circle" : "xmark.circle"
                        )
                        .font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                    }
                    if let run = history.runs.first, !run.contextOmissions.isEmpty {
                        Label(
                            "\(run.contextOmissions.count) bounded context omissions",
                            systemImage: "ellipsis.rectangle"
                        )
                        .font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                    }
                    if let run = history.runs.first {
                        Label(
                            "\(run.provider.displayName) · \(run.provider.model ?? run.provider.workerIdentity ?? "deterministic")",
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                        Text("Context \(run.contextDigest.hex.prefix(12))")
                            .font(.caption2.monospaced()).foregroundStyle(RTCDesign.color(.textSecondary))
                        ForEach(model.unavailableDiagramKinds, id: \.rawValue) { kind in
                            Label(
                                "\(kind.rawValue) diagram unavailable (no validated diagram)",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption).foregroundStyle(RTCDesign.color(.textSecondary))
                        }
                    }
                }.padding(.top, 6)
            }.font(.caption)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.status {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            RTCErrorState(
                title: "Tour unavailable", message: message,
                retry: model.configuration == nil ? nil : { model.generate() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rejected:
            RTCErrorState(
                title: "Tour rejected", message: "The supplied tour failed strict validation.",
                retry: model.configuration == nil ? nil : { model.generate() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noChanges:
            RTCEmptyState(
                title: "No committed changes", message: "This exact review revision contains no changed files."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .readOnly(let reason) where model.document == nil:
            RTCEmptyState(title: "Read-only tour", message: reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cancelled where model.document == nil:
            RTCEmptyState(title: "Tour cancelled", message: "The exact diff remains available.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            documentContent
        }
    }

    @ViewBuilder private var documentContent: some View {
        if let document = model.document {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(document.title.value).font(.largeTitle.weight(.semibold))
                        if case .readOnly(let reason) = model.status {
                            Label(reason, systemImage: "lock.fill")
                                .font(.callout).foregroundStyle(RTCDesign.color(.textSecondary))
                        }
                        if case .fallback(let reason) = model.status {
                            Text(reason).font(.callout).foregroundStyle(RTCDesign.color(.textSecondary))
                        }
                        blocks(document.overview, prefix: "overview")
                    }.id("overview").onAppear { model.selectedSectionID = "overview" }
                    if !document.reviewFocuses.isEmpty {
                        section(title: "Review focuses", id: "focuses") {
                            ForEach(Array(document.reviewFocuses.enumerated()), id: \.offset) { _, focus in
                                anchorCard(title: focus.title.value, text: focus.body, anchors: focus.anchors)
                            }
                        }
                    }
                    ForEach(document.chapters, id: \.id.value) { chapter in
                        section(title: chapter.title.value, id: chapter.id.value) {
                            richText(chapter.summary)
                            anchors(chapter.anchors)
                            blocks(chapter.blocks, prefix: chapter.id.value)
                        }
                    }
                }.padding(24).frame(maxWidth: 920, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            RTCEmptyState(title: "Generated outline unavailable", message: "The exact diff remains available.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section<Content: View>(
        title: String, id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold)); content()
        }.padding(.leading, 12).overlay(alignment: .leading) {
            Rectangle().fill(RTCDesign.color(.storySpine)).frame(width: 2)
        }.id(id).onAppear { model.selectedSectionID = id }
    }

    private func blocks(_ values: [TourBlock], prefix: String) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { index, block in
            blockView(block).id("\(prefix)-\(index)")
        }
    }

    @ViewBuilder private func blockView(_ block: TourBlock) -> some View {
        switch block {
        case .paragraph(let text): richText(text)
        case .bulletList(let values):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .top) {
                        Text("•"); richText(value)
                    }
                }
            }
        case .callout(let kind, let text, let sourceAnchors):
            RTCCard {
                VStack(alignment: .leading, spacing: 8) {
                    RTCBadge(kind.rawValue, tone: kind == .risk ? .danger : .warning)
                    richText(text); anchors(sourceAnchors)
                }
            }
        case .diffSlice(let reference):
            if let slice = model.resolvedSlices[reference] { diffSlice(slice) }
        case .diagram(let diagram):
            if let layout = model.diagramLayouts[diagram.id.value] { diagramBlock(diagram, layout: layout) }
        }
    }

    private func anchorCard(title: String, text: RichText, anchors sourceAnchors: [ReviewAnchor]) -> some View {
        RTCCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline); richText(text); anchors(sourceAnchors)
            }
        }
    }

    private func diffSlice(_ slice: ResolvedDiffSlice) -> some View {
        RTCCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(slice.reference.path) · hunk \(slice.reference.hunkIndex + 1)")
                    .font(.caption.monospaced()).foregroundStyle(RTCDesign.color(.textSecondary)).padding(.bottom, 8)
                ForEach(Array(slice.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text((slice.reference.side == .new ? line.newLine : line.oldLine).map(String.init) ?? "")
                            .frame(width: 44, alignment: .trailing).foregroundStyle(RTCDesign.color(.textSecondary))
                        Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                        Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(RTCDesign.codeFont)
                    .padding(.vertical, 2)
                    .background(
                        line.kind == .addition
                            ? RTCDesign.color(.additionBackground)
                            : line.kind == .deletion ? RTCDesign.color(.deletionBackground) : .clear)
                }
            }
        }
    }

    private func diagramBlock(_ diagram: DiagramDocument, layout: DiagramLayout) -> some View {
        RTCCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(diagram.title.value).font(.headline)
                richText(diagram.summary)
                DiagramView(layout: layout).frame(minHeight: 300).accessibilityLabel(diagram.title.value)
                Text("Diagram sources").font(.caption.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading) {
                    ForEach(diagram.nodes, id: \.id.value) { node in
                        Button {
                            if let anchor = node.anchors.first { model.navigate(to: anchor) }
                        } label: {
                            Label(node.label.value, systemImage: "scope")
                        }.buttonStyle(.plain).disabled(node.anchors.isEmpty)
                    }
                }
            }
        }
    }

    private func anchors(_ values: [ReviewAnchor]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, anchor in
                Button("\(anchor.path):\(anchor.startLine.map(String.init) ?? "file")") {
                    model.navigate(to: anchor)
                }.buttonStyle(.link)
            }
        }
    }

    private func richText(_ value: RichText) -> Text {
        value.runs.reduce(Text("")) { result, run in
            let next = Text(run.text.value)
            switch run.kind {
            case .plain: return result + next
            case .emphasis: return result + next.italic()
            case .strong: return result + next.bold()
            case .code: return result + next.font(RTCDesign.codeFont)
            }
        }
    }
}
