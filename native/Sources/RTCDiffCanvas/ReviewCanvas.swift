import AppKit
import SwiftUI
import RTCContracts

/// The immutable, bounded input to a review canvas. Providers are deliberately
/// outside the view layer so a snapshot can be rendered offline and replayed.
public struct CanvasSnapshot: Sendable {
    public let files: [CanvasFile]
    public let selected: CanvasSelection?
    public let revision: RevisionIdentity

    public init(revision: RevisionIdentity, files: [CanvasFile], selected: CanvasSelection? = nil) {
        self.revision = revision
        self.files = files
        self.selected = selected
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

public struct CanvasSelection: Hashable, Sendable {
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
    case thread(path: String, hunk: Int, index: Int)
}

public enum GapSide: String, Hashable, Sendable { case before, after }

public enum CanvasSection: Hashable, Sendable { case file(String) }

public struct CanvasNavigationEvent: Sendable {
    public let selection: CanvasSelection
    public init(selection: CanvasSelection) { self.selection = selection }
}

public protocol ReviewCanvasDelegate: AnyObject {
    func canvas(_ canvas: ReviewCanvasController, didSelect event: CanvasNavigationEvent)
    func canvas(_ canvas: ReviewCanvasController, didRequestCommentAt selection: CanvasSelection)
}

/// A reusable AppKit bridge. The collection view owns only visible cells;
/// rows remain flat and immutable so thread insertion does not rebuild a file.
@MainActor
public final class ReviewCanvasController: NSViewController {
    public weak var delegate: ReviewCanvasDelegate?
    public let collectionView: NSCollectionView
    private var snapshot: CanvasSnapshot?
    private var selected: CanvasSelection?
    private var restoreAnchor: CanvasSelection?
    private lazy var dataSource = makeDataSource()

    public init() {
        collectionView = NSCollectionView()
        super.init(nibName: nil, bundle: nil)
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
        restoreAnchor = selected
        self.snapshot = snapshot
        selected = snapshot.selected
        var diff = NSDiffableDataSourceSnapshot<CanvasSection, CanvasItemID>()
        for file in snapshot.files {
            let section = CanvasSection.file(file.artifact.path)
            diff.appendSections([section])
            diff.appendItems(items(for: file), toSection: section)
        }
        dataSource.apply(diff, animatingDifferences: animatingDifferences) { [weak self] in
            self?.restoreSelectionAndScroll()
        }
    }

    public func saveScrollPosition() -> CanvasSelection? { selected }

    public func restore(scrollPosition: CanvasSelection?) {
        restoreAnchor = scrollPosition
        restoreSelectionAndScroll()
    }

    public func copySelection() {
        guard let selection = selected, let line = line(for: selection) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.text, forType: .string)
    }

    private func items(for file: CanvasFile) -> [CanvasItemID] {
        var result: [CanvasItemID] = []
        for hunk in file.hunks {
            if hunk.contextBefore > 0 { result.append(.contextGap(path: file.artifact.path, hunk: hunk.index, side: .before)) }
            result.append(.hunk(path: file.artifact.path, index: hunk.index))
            for (index, line) in hunk.lines.enumerated() {
                result.append(.line(path: file.artifact.path, hunk: hunk.index, index: index))
                if line.kind != .context { result.append(.thread(path: file.artifact.path, hunk: hunk.index, index: index)) }
            }
            if hunk.contextAfter > 0 { result.append(.contextGap(path: file.artifact.path, hunk: hunk.index, side: .after)) }
        }
        return result
    }

    private func makeDataSource() -> NSCollectionViewDiffableDataSource<CanvasSection, CanvasItemID> {
        NSCollectionViewDiffableDataSource<CanvasSection, CanvasItemID>(collectionView: collectionView) { [weak self] collection, indexPath, item in
            guard let self else { return nil }
            let cell = collection.makeItem(withIdentifier: CanvasRowView.reuseIdentifier, for: indexPath) as! CanvasRowView
            cell.represent(item: item, snapshot: self.snapshot, selected: self.selected)
            return cell
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
        guard let file = snapshot?.files.first(where: { $0.artifact.path == selection.path }) else { return nil }
        guard let hunk = file.hunks.first(where: { hunk in hunk.lines.contains { $0.newLine == selection.startLine || $0.oldLine == selection.startLine } }) else { return nil }
        guard let row = hunk.lines.firstIndex(where: { $0.newLine == selection.startLine || $0.oldLine == selection.startLine }) else { return nil }
        let item = CanvasItemID.line(path: selection.path, hunk: hunk.index, index: row)
        return dataSource.indexPath(for: item)
    }

    private func line(for selection: CanvasSelection) -> DiffLine? {
        snapshot?.files.first(where: { $0.artifact.path == selection.path })?.hunks.flatMap(\.lines).first { $0.newLine == selection.startLine || $0.oldLine == selection.startLine }
    }
}

extension ReviewCanvasController: NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let item = indexPaths.compactMap({ dataSource.itemIdentifier(for: $0) }).first,
              case let .line(path, hunkIndex, index) = item,
              let line = snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == hunkIndex })?.lines[index],
              let side: AnchorSide = line.newLine == nil ? .old : .new,
              let lineNumber = side == .old ? line.oldLine : line.newLine else { return }
        let newSelection = CanvasSelection(path: path, side: side, startLine: lineNumber, endLine: lineNumber)
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

final class CanvasRowView: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CanvasRowView")
    private let label = NSTextField(labelWithString: "")
    override func loadView() { view = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; label.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), label.topAnchor.constraint(equalTo: view.topAnchor, constant: 5), label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5)]) }
    func represent(item: CanvasItemID, snapshot: CanvasSnapshot?, selected: CanvasSelection?) {
        switch item {
        case let .hunk(_, index): label.stringValue = snapshot?.files.flatMap(\.hunks).first(where: { $0.index == index })?.header ?? ""
        case let .contextGap(_, _, side): label.stringValue = side == .before ? "⋯  context above" : "⋯  context below"
        case let .line(path, hunk, index):
            guard let line = snapshot?.files.first(where: { $0.artifact.path == path })?.hunks.first(where: { $0.index == hunk })?.lines[index] else { return }
            label.stringValue = "\(line.oldLine.map(String.init) ?? "   ")  \(line.newLine.map(String.init) ?? "   ")  \(line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " ") \(line.text)"
            label.textColor = line.kind == .addition ? .systemGreen : line.kind == .deletion ? .systemRed : .labelColor
        case .thread: label.stringValue = "  ↳  Add inline comment"
        case .file: label.stringValue = ""
        }
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
