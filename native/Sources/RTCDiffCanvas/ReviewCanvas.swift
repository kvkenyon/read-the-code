import AppKit
import SwiftUI
import RTCContracts

/// The immutable, bounded input to a review canvas. Providers are deliberately
/// outside the view layer so a snapshot can be rendered offline and replayed.
public struct CanvasSnapshot: Sendable {
    public let files: [CanvasFile]
    public let selected: CanvasSelection?
    public let revision: RevisionIdentity
    public let threads: [CanvasInlineThread]
    public let composer: CanvasSelection?
    public let contentVersion: Int

    public init(revision: RevisionIdentity, files: [CanvasFile], selected: CanvasSelection? = nil, threads: [CanvasInlineThread] = [], composer: CanvasSelection? = nil, contentVersion: Int = 0) {
        self.revision = revision
        self.files = files
        self.selected = selected
        self.threads = threads
        self.composer = composer
        self.contentVersion = contentVersion
    }
}

public struct CanvasFile: Sendable {
    public let artifact: DiffArtifact
    public let hunks: [CanvasHunk]

    public init(artifact: DiffArtifact, hunks: [CanvasHunk]? = nil) {
        self.artifact = artifact
        self.hunks = hunks ?? artifact.hunks.enumerated().map { CanvasHunk($0.element, index: $0.offset) }
    }
}

public struct CanvasHunk: Sendable {
    public let index: Int
    public let header: String
    public let lines: [DiffLine]
    public let contextBefore: Int
    public let contextAfter: Int

    public init(index: Int, header: String, lines: [DiffLine], contextBefore: Int = 0, contextAfter: Int = 0) {
        self.index = index
        self.header = header
        self.lines = lines
        self.contextBefore = max(0, contextBefore)
        self.contextAfter = max(0, contextAfter)
    }

    fileprivate init(_ hunk: DiffHunk, index: Int) {
        self.init(index: index, header: hunk.header.value, lines: hunk.lines)
    }
}

public struct CanvasSelection: Codable, Hashable, Sendable {
    public let path: String
    public let side: AnchorSide
    public let startLine: Int
    public let endLine: Int

    public init(path: String, side: AnchorSide, startLine: Int, endLine: Int) {
        self.path = path
        self.side = side
        self.startLine = min(startLine, endLine)
        self.endLine = max(startLine, endLine)
    }
}

public struct CanvasInlineThread: Hashable, Sendable {
    public let id: UUID
    public let selection: CanvasSelection
    public let state: String
    public let body: String
    public init(id: UUID, selection: CanvasSelection, state: String, body: String) { self.id=id; self.selection=selection; self.state=state; self.body=body }
}

private struct CanvasAnchorKey: Hashable, Sendable {
    let path: String
    let side: AnchorSide
    let endLine: Int

    init(_ selection: CanvasSelection) {
        path = selection.path
        side = selection.side
        endLine = selection.endLine
    }

    init(path: String, side: AnchorSide, endLine: Int) {
        self.path = path
        self.side = side
        self.endLine = endLine
    }
}

public protocol SyntaxHighlighter: Sendable {
    func spans(for line: DiffLine, path: String) async -> [SyntaxSpan]
}

public struct SyntaxSpan: Hashable, Sendable {
    public let range: Range<Int>
    public let token: String
    public init(range: Range<Int>, token: String) { self.range = range; self.token = token }
}

public protocol CanvasDiagramProvider: Sendable {
    func view(for anchor: ReviewAnchor) -> NSView?
}

public protocol CanvasThreadProvider: Sendable {
    func view(for item: CanvasItemID) -> NSView?
    func threadCount(for item: CanvasItemID) -> Int
}

public enum CanvasItemID: Hashable, Sendable {
    case file(String)
    case hunk(path: String, index: Int)
    case contextGap(path: String, hunk: Int, side: GapSide)
    case line(path: String, hunk: Int, index: Int)
    case thread(UUID)
    case composer(path: String, hunk: Int, index: Int)

    fileprivate var threadID: UUID? {
        if case let .thread(id) = self { return id }
        return nil
    }
}

public enum GapSide: String, Hashable, Sendable { case before, after }

public enum CanvasSection: Hashable, Sendable { case file(String) }

public struct CanvasNavigationEvent: Sendable {
    public let selection: CanvasSelection
    public init(selection: CanvasSelection) { self.selection = selection }
}

@MainActor public protocol ReviewCanvasDelegate: AnyObject {
    func canvas(_ canvas: ReviewCanvasController, didSelect event: CanvasNavigationEvent)
    func canvas(_ canvas: ReviewCanvasController, didRequestCommentAt selection: CanvasSelection)
    func canvas(_ canvas: ReviewCanvasController, didActivateThread id: UUID)
    func canvasDidSaveComposer(_ canvas: ReviewCanvasController)
    func canvasDidCancelComposer(_ canvas: ReviewCanvasController)
    func canvas(_ canvas: ReviewCanvasController, didUpdateComposer body: String)
    func canvas(_ canvas: ReviewCanvasController, didRequestThreadAction id: UUID)
}

public extension ReviewCanvasDelegate {
    func canvas(_ canvas: ReviewCanvasController, didActivateThread id: UUID) {}
    func canvasDidSaveComposer(_ canvas: ReviewCanvasController) {}
    func canvasDidCancelComposer(_ canvas: ReviewCanvasController) {}
    func canvas(_ canvas: ReviewCanvasController, didUpdateComposer body: String) {}
    func canvas(_ canvas: ReviewCanvasController, didRequestThreadAction id: UUID) {}
}

/// A reusable AppKit bridge. The collection view owns only visible cells;
/// rows remain flat and immutable so thread insertion does not rebuild a file.
@MainActor
public final class ReviewCanvasController: NSViewController {
    public weak var delegate: ReviewCanvasDelegate?
    public var syntaxHighlighter: (any SyntaxHighlighter)?
    public let collectionView: NSCollectionView
    private var snapshot: CanvasSnapshot?
    private var selected: CanvasSelection?
    private var restoreAnchor: CanvasSelection?
    private var appliedRevision: RevisionIdentity?
    private var appliedFiles: [CanvasFile] = []
    private var appliedContentVersion: Int?
    private var appliedThreads: [CanvasInlineThread] = []
    private var appliedComposer: CanvasSelection?
    private var threadsByID: [UUID: CanvasInlineThread] = [:]
    private var threadCountsByAnchor: [CanvasAnchorKey: Int] = [:]
    private var threadIDsByAnchor: [CanvasAnchorKey: [UUID]] = [:]
    private var lineItemsByAnchor: [CanvasAnchorKey: CanvasItemID] = [:]
    private var linesByAnchor: [CanvasAnchorKey: DiffLine] = [:]
    private lazy var dataSource = makeDataSource()
    public private(set) var fullSnapshotApplicationCount = 0
    public private(set) var enumeratedLineCount = 0
    public private(set) var syntaxRequestCount = 0
    public private(set) var indexedThreadCount = 0
    public private(set) var incrementalInsertedItemCount = 0
    public private(set) var incrementalDeletedItemCount = 0
    public private(set) var incrementalReloadedItemCount = 0

    public init() {
        collectionView = ReviewCanvasCollectionView()
        super.init(nibName: nil, bundle: nil)
        (collectionView as? ReviewCanvasCollectionView)?.reviewCanvas = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = collectionView
        view = scroll
        collectionView.collectionViewLayout = makeLayout()
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(CanvasRowView.self, forItemWithIdentifier: CanvasRowView.reuseIdentifier)
        collectionView.register(CanvasFileHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: CanvasFileHeaderView.reuseIdentifier)
        collectionView.dataSource = dataSource
        collectionView.delegate = self
        dataSource.supplementaryViewProvider = { [weak self] collection, kind, indexPath in
            guard let self, let section = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section],
                  case let .file(path) = section,
                  let header = collection.makeSupplementaryView(ofKind: kind, withIdentifier: CanvasFileHeaderView.reuseIdentifier, for: indexPath) as? CanvasFileHeaderView else { return nil }
            header.title = path
            return header
        }
    }

    public func apply(_ snapshot: CanvasSnapshot, animatingDifferences: Bool = false) {
        precondition(Thread.isMainThread)
        let incomingSelection = snapshot.selected ?? selected
        let coreChanged = appliedRevision != snapshot.revision || appliedContentVersion != snapshot.contentVersion || appliedFiles.map(\.artifact.path) != snapshot.files.map(\.artifact.path)
        let inlineChanged = appliedThreads != snapshot.threads || appliedComposer != snapshot.composer
        let selectionChanged = selected != incomingSelection
        guard coreChanged || inlineChanged || selectionChanged else { return }
        restoreAnchor = incomingSelection
        self.snapshot = snapshot
        appliedRevision = snapshot.revision
        appliedFiles = snapshot.files
        appliedContentVersion = snapshot.contentVersion
        let previousThreads = appliedThreads
        let previousComposer = appliedComposer
        appliedThreads = snapshot.threads
        appliedComposer = snapshot.composer
        threadsByID = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0) })
        threadCountsByAnchor = Dictionary(grouping: snapshot.threads, by: { CanvasAnchorKey($0.selection) }).mapValues(\.count)
        threadIDsByAnchor = Dictionary(grouping: snapshot.threads, by: { CanvasAnchorKey($0.selection) })
            .mapValues { $0.map(\.id).sorted { $0.uuidString < $1.uuidString } }
        if let incomingSelection = snapshot.selected { selected = incomingSelection }
        if !coreChanged {
            if inlineChanged { updateInlineItems(removing: previousThreads, previousComposer: previousComposer, adding: snapshot.threads, composer: snapshot.composer) }
            if selectionChanged { reloadSelectionRows() }
            return
        }
        var diff = NSDiffableDataSourceSnapshot<CanvasSection, CanvasItemID>()
        let threadsByAnchor = Dictionary(grouping: snapshot.threads, by: { CanvasAnchorKey($0.selection) })
            .mapValues { $0.sorted { $0.id.uuidString < $1.id.uuidString } }
        indexedThreadCount = snapshot.threads.count
        enumeratedLineCount = 0
        lineItemsByAnchor = [:]
        linesByAnchor = [:]
        for file in snapshot.files {
            let section = CanvasSection.file(file.artifact.path)
            diff.appendSections([section])
            diff.appendItems(items(for: file, threadsByAnchor: threadsByAnchor), toSection: section)
        }
        fullSnapshotApplicationCount += 1
        dataSource.apply(diff, animatingDifferences: animatingDifferences) { [weak self] in
            self?.restoreSelectionAndScroll()
        }
    }

    public func saveScrollPosition() -> CanvasSelection? { selected }

    public func restore(scrollPosition: CanvasSelection?) {
        restoreAnchor = scrollPosition
        restoreSelectionAndScroll()
    }

    public func navigate(to selection: CanvasSelection, focus: Bool = false) {
        selected = selection; restoreAnchor = selection; restoreSelectionAndScroll()
        if focus { view.window?.makeFirstResponder(collectionView) }
        delegate?.canvas(self, didSelect: CanvasNavigationEvent(selection: selection))
    }

    public func navigate(toFile path: String, focus: Bool = false) {
        guard let file = snapshot?.files.first(where: { $0.artifact.path == path }),
              let line = file.hunks.flatMap(\.lines).first,
              let number = line.newLine ?? line.oldLine else { return }
        navigate(to: CanvasSelection(path: path, side: line.newLine == nil ? .old : .new, startLine: number, endLine: number), focus: focus)
    }

    public func copySelection() {
        guard let selection = selected else { return }
        let text = (selection.startLine...selection.endLine).compactMap {
            linesByAnchor[CanvasAnchorKey(path: selection.path, side: selection.side, endLine: $0)]?.text
        }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The canvas keeps keyboard comment creation next to the selected evidence.
    /// It never creates a thread itself; the workspace owns the domain mutation.
    public func requestComment() {
        guard let selected else { return }
        delegate?.canvas(self, didRequestCommentAt: selected)
    }

    private func items(for file: CanvasFile, threadsByAnchor: [CanvasAnchorKey: [CanvasInlineThread]]) -> [CanvasItemID] {
        var result: [CanvasItemID] = []
        for hunk in file.hunks {
            if hunk.contextBefore > 0 { result.append(.contextGap(path: file.artifact.path, hunk: hunk.index, side: .before)) }
            result.append(.hunk(path: file.artifact.path, index: hunk.index))
            for (index, line) in hunk.lines.enumerated() {
                result.append(.line(path: file.artifact.path, hunk: hunk.index, index: index))
                enumeratedLineCount += 1
                let side: AnchorSide = line.newLine == nil ? .old : .new
                let number = line.newLine ?? line.oldLine
                let key = number.map { CanvasAnchorKey(path: file.artifact.path, side: side, endLine: $0) }
                if let key {
                    lineItemsByAnchor[key] = .line(path: file.artifact.path, hunk: hunk.index, index: index)
                    linesByAnchor[key] = line
                }
                result.append(contentsOf: key.flatMap { threadsByAnchor[$0] }?.map { .thread($0.id) } ?? [])
                if let composer = snapshot?.composer, composer.path == file.artifact.path, composer.side == side, composer.endLine == number { result.append(.composer(path: file.artifact.path, hunk: hunk.index, index: index)) }
            }
            if hunk.contextAfter > 0 { result.append(.contextGap(path: file.artifact.path, hunk: hunk.index, side: .after)) }
        }
        return result
    }

    private func makeDataSource() -> NSCollectionViewDiffableDataSource<CanvasSection, CanvasItemID> {
        NSCollectionViewDiffableDataSource<CanvasSection, CanvasItemID>(collectionView: collectionView) { [weak self] collection, indexPath, item in
            guard let self else { return nil }
            let cell = collection.makeItem(withIdentifier: CanvasRowView.reuseIdentifier, for: indexPath) as! CanvasRowView
            let thread = item.threadID.flatMap { self.threadsByID[$0] }
            let threadCount: Int
            if case let .line(path, hunkIndex, lineIndex) = item,
               let line = self.snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == hunkIndex })?.lines[lineIndex],
               let number = line.newLine ?? line.oldLine {
                threadCount = self.threadCountsByAnchor[CanvasAnchorKey(path: path, side: line.newLine == nil ? .old : .new, endLine: number), default: 0]
            } else { threadCount = 0 }
            cell.represent(item: item, snapshot: self.snapshot, selected: self.selected, representedThread: thread, threadCount: threadCount, action: { [weak self] action in self?.handle(action) })
            if case let .line(path, hunkIndex, lineIndex) = item,
               let line = self.snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == hunkIndex })?.lines[lineIndex],
               let highlighter = self.syntaxHighlighter {
                self.syntaxRequestCount += 1
                Task { [weak cell] in
                    let spans = await highlighter.spans(for: line, path: path)
                    await MainActor.run { cell?.applySyntax(spans, for: item) }
                }
            }
            return cell
        }
    }

    private func updateInlineItems(removing oldThreads: [CanvasInlineThread], previousComposer: CanvasSelection?, adding newThreads: [CanvasInlineThread], composer: CanvasSelection?) {
        var diff = dataSource.snapshot()
        let oldByID = Dictionary(uniqueKeysWithValues: oldThreads.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newThreads.map { ($0.id, $0) })
        let removedOrMoved = oldThreads.filter { newByID[$0.id]?.selection != $0.selection }
        let addedOrMoved = newThreads.filter { oldByID[$0.id]?.selection != $0.selection }
        let edited = newThreads.filter { oldByID[$0.id]?.selection == $0.selection && oldByID[$0.id] != $0 }
        var removedItems = removedOrMoved.map { CanvasItemID.thread($0.id) }.filter { diff.indexOfItem($0) != nil }
        if previousComposer != composer, let previousItem = composerItem(for: previousComposer), diff.indexOfItem(previousItem) != nil { removedItems.append(previousItem) }
        if !removedItems.isEmpty { diff.deleteItems(removedItems); incrementalDeletedItemCount += removedItems.count }
        for thread in addedOrMoved.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            insert(.thread(thread.id), for: thread, into: &diff)
            incrementalInsertedItemCount += 1
        }
        let editedItems = edited.map { CanvasItemID.thread($0.id) }.filter { diff.indexOfItem($0) != nil }
        if !editedItems.isEmpty { diff.reloadItems(editedItems); incrementalReloadedItemCount += editedItems.count }
        if previousComposer != composer, let composerItem = composerItem(for: composer), let composer {
            insert(composerItem, after: composer, into: &diff)
            incrementalInsertedItemCount += 1
        }
        dataSource.apply(diff, animatingDifferences: false) { [weak self] in self?.restoreSelectionAndScroll() }
    }

    private func insert(_ item: CanvasItemID, for thread: CanvasInlineThread, into diff: inout NSDiffableDataSourceSnapshot<CanvasSection, CanvasItemID>) {
        let peers = threadIDsByAnchor[CanvasAnchorKey(thread.selection), default: []]
        guard let position = peers.firstIndex(of: thread.id) else { return }
        if let followingID = peers.dropFirst(position + 1).first(where: { diff.indexOfItem(.thread($0)) != nil }) {
            diff.insertItems([item], beforeItem: .thread(followingID)); return
        }
        if let precedingID = peers.prefix(position).last(where: { diff.indexOfItem(.thread($0)) != nil }) {
            diff.insertItems([item], afterItem: .thread(precedingID)); return
        }
        guard let anchor = lineItemsByAnchor[CanvasAnchorKey(thread.selection)], diff.indexOfItem(anchor) != nil else { return }
        diff.insertItems([item], afterItem: anchor)
    }

    private func composerItem(for selection: CanvasSelection?) -> CanvasItemID? {
        guard let selection,
              let item = lineItemsByAnchor[CanvasAnchorKey(selection)],
              case let .line(path, hunk, index) = item else { return nil }
        return .composer(path: path, hunk: hunk, index: index)
    }

    private func insert(_ item: CanvasItemID, after selection: CanvasSelection, into diff: inout NSDiffableDataSourceSnapshot<CanvasSection, CanvasItemID>) {
        let key = CanvasAnchorKey(selection)
        guard let anchor = lineItemsByAnchor[key], diff.indexOfItem(anchor) != nil else { return }
        if let lastThread = threadIDsByAnchor[key]?.last(where: { diff.indexOfItem(.thread($0)) != nil }) {
            diff.insertItems([item], afterItem: .thread(lastThread))
        } else { diff.insertItems([item], afterItem: anchor) }
    }

    private func reloadSelectionRows() {
        var diff = dataSource.snapshot()
        let visible = collectionView.indexPathsForVisibleItems().compactMap { dataSource.itemIdentifier(for: $0) }
        diff.reloadItems(visible); dataSource.apply(diff, animatingDifferences: false)
    }

    fileprivate enum RowAction { case thread(UUID), threadAction(UUID), saveComposer, cancelComposer, updateComposer(String) }
    private func handle(_ action: RowAction) {
        switch action {
        case let .thread(id): delegate?.canvas(self, didActivateThread: id)
        case let .threadAction(id): delegate?.canvas(self, didRequestThreadAction: id)
        case .saveComposer: delegate?.canvasDidSaveComposer(self)
        case .cancelComposer: delegate?.canvasDidCancelComposer(self)
        case let .updateComposer(body): delegate?.canvas(self, didUpdateComposer: body)
        }
    }

    private func makeLayout() -> NSCollectionViewLayout {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(28)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(28)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 0
        section.boundarySupplementaryItems = [.init(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(42)), elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)]
        section.boundarySupplementaryItems[0].pinToVisibleBounds = true
        return NSCollectionViewCompositionalLayout(section: section)
    }

    private func restoreSelectionAndScroll() {
        guard let anchor = restoreAnchor, let indexPath = indexPath(for: anchor) else { return }
        collectionView.selectItems(at: [indexPath], scrollPosition: .centeredVertically)
        restoreAnchor = nil
    }

    private func indexPath(for selection: CanvasSelection) -> IndexPath? {
        lineItemsByAnchor[CanvasAnchorKey(path: selection.path, side: selection.side, endLine: selection.startLine)]
            .flatMap { dataSource.indexPath(for: $0) }
    }

}

extension ReviewCanvasController: NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let item = indexPaths.compactMap({ dataSource.itemIdentifier(for: $0) }).first,
              case let .line(path, hunkIndex, index) = item,
              let line = snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == hunkIndex })?.lines[index],
              let side: AnchorSide = line.newLine == nil ? .old : .new,
              let lineNumber = side == .old ? line.oldLine : line.newLine else { return }
        let extending = NSEvent.modifierFlags.contains(.shift)
        let newSelection: CanvasSelection
        if extending, let prior = selected, prior.path == path, prior.side == side {
            newSelection = CanvasSelection(path: path, side: side, startLine: prior.startLine, endLine: lineNumber)
        } else {
            newSelection = CanvasSelection(path: path, side: side, startLine: lineNumber, endLine: lineNumber)
        }
        selected = newSelection
        delegate?.canvas(self, didSelect: CanvasNavigationEvent(selection: newSelection))
    }

}

public final class ReviewCanvasRepresentable: NSViewRepresentable {
    public let snapshot: CanvasSnapshot
    public weak var delegate: ReviewCanvasDelegate?
    public init(snapshot: CanvasSnapshot, delegate: ReviewCanvasDelegate? = nil) { self.snapshot = snapshot; self.delegate = delegate }
    public func makeNSView(context: Context) -> NSScrollView {
        let controller = ReviewCanvasController()
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.apply(snapshot)
        context.coordinator.controller = controller
        return controller.view as! NSScrollView
    }
    public func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.controller?.delegate = delegate; context.coordinator.controller?.apply(snapshot) }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public final class Coordinator { fileprivate var controller: ReviewCanvasController? }
}

final class CanvasRowView: NSCollectionViewItem, NSTextFieldDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CanvasRowView")
    private let label = NSTextField(labelWithString: "")
    private var action: ((ReviewCanvasController.RowAction) -> Void)?
    private var representedItem: CanvasItemID?
    private var codePrefixCharacters = 0
    override func loadView() { view = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; label.font = .monospacedSystemFont(ofSize: 12, weight: .regular); label.maximumNumberOfLines = 0; view.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), label.topAnchor.constraint(equalTo: view.topAnchor, constant: 5), label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5)]) }
    override func prepareForReuse() { super.prepareForReuse(); view.subviews.filter { $0 !== label }.forEach { $0.removeFromSuperview() }; label.isHidden = false; view.layer?.backgroundColor = nil; action = nil; representedItem = nil; codePrefixCharacters = 0 }
    fileprivate func represent(item: CanvasItemID, snapshot: CanvasSnapshot?, selected: CanvasSelection?, representedThread: CanvasInlineThread?, threadCount: Int, action: @escaping (ReviewCanvasController.RowAction) -> Void) {
        prepareForReuse(); self.action = action; representedItem = item
        switch item {
        case let .hunk(path, index): label.stringValue = snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == index })?.header ?? ""
        case let .contextGap(_, _, side): label.stringValue = side == .before ? "⋯  context above" : "⋯  context below"
        case let .line(path, hunk, index):
            guard let line = snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == hunk })?.lines[index] else { return }
            let prefix = "\(line.oldLine.map(String.init) ?? "   ")  \(line.newLine.map(String.init) ?? "   ")  \(line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " ") "
            codePrefixCharacters = (prefix as NSString).length; label.stringValue = prefix + line.text
            label.textColor = line.kind == .addition ? .systemGreen : line.kind == .deletion ? .systemRed : .labelColor
            label.setAccessibilityLabel("\(line.kind.rawValue) line \(line.newLine ?? line.oldLine ?? 0), \(threadCount) comments: \(line.text)")
            let side: AnchorSide = line.newLine == nil ? .old : .new
            let number = line.newLine ?? line.oldLine ?? 0
            let isSelected = selected.map { $0.path == path && $0.side == side && $0.startLine...$0.endLine ~= number } ?? false
            view.wantsLayer = true; view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor : nil
            view.setAccessibilitySelected(isSelected)
        case let .thread(id):
            guard let thread = representedThread, thread.id == id else { return }
            label.isHidden = true; installThread(thread)
        case .composer:
            label.isHidden = true; installComposer()
        case .file: label.stringValue = ""
        }
    }
    fileprivate func applySyntax(_ spans: [SyntaxSpan], for item: CanvasItemID) {
        guard representedItem == item, !label.stringValue.isEmpty else { return }
        let attributed=NSMutableAttributedString(string: label.stringValue, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: label.textColor ?? NSColor.labelColor])
        let length=attributed.length
        for span in spans {
            let location=codePrefixCharacters + span.range.lowerBound, count=span.range.count
            guard location >= codePrefixCharacters, count >= 0, location + count <= length else { continue }
            let color: NSColor
            switch span.token { case "keyword": color = .systemPink; case "string": color = .systemPurple; case "comment": color = .secondaryLabelColor; case "number": color = .systemBlue; default: color = label.textColor ?? .labelColor }
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: location, length: count))
        }
        label.attributedStringValue=attributed
    }

    private func installThread(_ thread: CanvasInlineThread) {
        let title = NSTextField(labelWithString: "\(thread.state.capitalized) thread  ·  Line \(thread.selection.startLine)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: thread.body); body.font = .systemFont(ofSize: 12)
        let open = NSButton(title: "Show in comments", target: self, action: #selector(showThread)); open.tag = 0
        let state = NSButton(title: thread.state == "resolved" ? "Reopen" : thread.state == "open" ? "Resolve" : "Draft", target: self, action: #selector(threadAction)); state.isEnabled = thread.state == "open" || thread.state == "resolved"
        let row = NSStackView(views: [open, state]); row.orientation = .horizontal
        let stack = NSStackView(views: [title, body, row]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.identifier = NSUserInterfaceItemIdentifier(thread.id.uuidString); view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 58), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)])
        view.setAccessibilityElement(true); view.setAccessibilityLabel("\(thread.state) thread on line \(thread.selection.startLine): \(thread.body)")
    }

    private func installComposer() {
        let title = NSTextField(labelWithString: "Draft thread"); title.font = .systemFont(ofSize: 12, weight: .semibold)
        let field = NSTextField(); field.placeholderString = "Write a comment…"; field.delegate = self
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelComposer))
        let save = NSButton(title: "Save to Review", target: self, action: #selector(saveComposer)); save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [cancel, save]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, field, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 58), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10), field.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        view.setAccessibilityElement(true); view.setAccessibilityLabel("Inline comment composer")
    }

    public func controlTextDidChange(_ obj: Notification) { if let field = obj.object as? NSTextField { action?(.updateComposer(field.stringValue)) } }
    @objc private func showThread(_ sender: NSButton) { guard let id = view.subviews.compactMap({ $0.identifier?.rawValue }).compactMap(UUID.init(uuidString:)).first else { return }; action?(.thread(id)) }
    @objc private func threadAction(_ sender: NSButton) { guard let id = view.subviews.compactMap({ $0.identifier?.rawValue }).compactMap(UUID.init(uuidString:)).first else { return }; action?(.threadAction(id)) }
    @objc private func saveComposer() { action?(.saveComposer) }
    @objc private func cancelComposer() { action?(.cancelComposer) }
}

private final class ReviewCanvasCollectionView: NSCollectionView {
    weak var reviewCanvas: ReviewCanvasController?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "c", let canvas = reviewCanvas {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == [.command] {
                canvas.copySelection()
                return
            }
            if modifiers.isEmpty {
                canvas.requestComment()
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class CanvasFileHeaderView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CanvasFileHeaderView")
    var title: String = "" { didSet { label.stringValue = title } }
    private let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
