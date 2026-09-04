import AppKit
import SwiftUI
import RTCDesign

public enum WorkspacePane: String, Codable, CaseIterable, Sendable { case story, canvas, comments, agent }
public enum WorkspaceMode: String, Codable, Sendable { case diff, tour }

public enum WorkspaceCommand: String, CaseIterable, Sendable {
    case toggleInbox, showDiff, showTour, toggleAgentRail, toggleComments, markViewed, comment, sendReview, requestChanges, approve, close
    public var keyEquivalent: String { switch self { case .toggleInbox: "0"; case .showDiff: "1"; case .showTour: "2"; case .toggleAgentRail: "i"; case .toggleComments: "3"; case .markViewed: "m"; case .comment: "c"; case .approve: "a"; case .sendReview, .requestChanges, .close: "" } }
    public var title: String { switch self { case .toggleInbox: "Show Inbox"; case .showDiff: "Diff"; case .showTour: "Tour"; case .toggleAgentRail: "Toggle Agent Rail"; case .toggleComments: "Toggle Comments"; case .markViewed: "Mark File Viewed"; case .comment: "Add Comment"; case .sendReview: "Send Review"; case .requestChanges: "Request Changes"; case .approve: "Approve Review"; case .close: "Close Review" } }
    public func menuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.keyEquivalentModifierMask = [.command]
        return item
    }
}

public struct WorkspaceRestorationState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var mode: WorkspaceMode = .tour
    public var collapsed: Set<WorkspacePane> = []
    public var widths: [WorkspacePane: Double] = [.story: 250, .canvas: 680, .comments: 340, .agent: 380]
    public var agentPinned = false
    public init() {}

    public static func decode(_ data: Data) -> WorkspaceRestorationState {
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.version == currentVersion else { return Self() }
        return value
    }
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

public enum WorkspaceSizing {
    public static let minimumWindow = CGSize(width: 1_050, height: 680)
    public static let minimumWindowWithAgent = CGSize(width: 1_360, height: 720)
    public static let minimumCanvas: CGFloat = 560
    public static func behavior(for width: CGFloat, agentOpen: Bool) -> String { if width < 980 { return "inspector" }; if agentOpen && width < 1_250 { return "overlay-comments" }; return "split" }
}

public struct WorkspacePlaceholder: View {
    public let pane: WorkspacePane
    public init(pane: WorkspacePane) { self.pane = pane }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pane == .story ? "Review story" : pane == .canvas ? "Tour overview" : pane == .comments ? "Comments" : "Agent conversation").font(.title3.weight(.semibold))
            if pane == .story { Label("Overview", systemImage: "circle.fill"); Label("Review focuses", systemImage: "circle"); Label("Changed files", systemImage: "doc.text") }
            else { RTCEmptyState(title: "Ready for review", message: "This pane is a stable host for the next feature module.") }
            Spacer()
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(RTCDesign.color(.canvas))
    }
}

/// AppKit owns split mechanics and restoration; SwiftUI owns pane content.
public final class WorkspaceShell: NSSplitViewController {
    public private(set) var restoration = WorkspaceRestorationState()
    private var paneControllers: [WorkspacePane: NSSplitViewItem] = [:]

    public init(restorationData: Data? = nil, content: [WorkspacePane: NSViewController] = [:], enabledPanes: [WorkspacePane] = WorkspacePane.allCases) {
        restoration = restorationData.map(WorkspaceRestorationState.decode) ?? WorkspaceRestorationState()
        super.init(nibName: nil, bundle: nil)
        enabledPanes.forEach { pane in
            let controller = content[pane] ?? NSHostingController(rootView: WorkspacePlaceholder(pane: pane))
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = pane == .canvas ? WorkspaceSizing.minimumCanvas : 180
            item.canCollapse = pane != .canvas
            item.isCollapsed = restoration.collapsed.contains(pane)
            paneControllers[pane] = item
            addSplitViewItem(item)
        }
        splitView.isVertical = true
        splitView.dividerStyle = .thin
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("WorkspaceShell is programmatic") }
    public func setCollapsed(_ pane: WorkspacePane, _ collapsed: Bool) { paneControllers[pane]?.isCollapsed = collapsed; if collapsed { restoration.collapsed.insert(pane) } else { restoration.collapsed.remove(pane) } }
    public func apply(command: WorkspaceCommand) { switch command { case .toggleAgentRail: setCollapsed(.agent, !(paneControllers[.agent]?.isCollapsed ?? true)); case .toggleComments: setCollapsed(.comments, !(paneControllers[.comments]?.isCollapsed ?? false)); case .showDiff: restoration.mode = .diff; case .showTour: restoration.mode = .tour; default: break } }
    public func restorationData() -> Data? { restoration.encoded() }
}

public enum WorkspaceMenus {
    public static func review(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Review")
        WorkspaceCommand.allCases.filter { [.showDiff, .showTour, .toggleAgentRail, .toggleComments, .markViewed, .comment, .sendReview, .requestChanges, .approve, .close].contains($0) }.forEach { menu.addItem($0.menuItem(target: target, action: action)) }
        return menu
    }
}
