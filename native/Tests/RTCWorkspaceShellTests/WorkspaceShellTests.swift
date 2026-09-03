import XCTest
@testable import RTCWorkspaceShell

final class WorkspaceShellTests: XCTestCase {
    func testCommandsHaveKeyboardEquivalents() { XCTAssertEqual(WorkspaceCommand.showDiff.keyEquivalent, "1"); XCTAssertEqual(WorkspaceCommand.showTour.keyEquivalent, "2"); XCTAssertEqual(WorkspaceCommand.toggleAgentRail.keyEquivalent, "i") }
    func testReviewMenuContainsNativeShortcuts() { let menu = WorkspaceMenus.review(target: NSObject(), action: #selector(NSObject.description)); XCTAssertEqual(menu.items.first?.keyEquivalentModifierMask, [.command]); XCTAssertTrue(menu.items.contains { $0.keyEquivalent == "i" }) }
    func testMinimumWindowContracts() { XCTAssertEqual(WorkspaceSizing.minimumWindow.width, 1_050); XCTAssertEqual(WorkspaceSizing.minimumWindowWithAgent.width, 1_360); XCTAssertEqual(WorkspaceSizing.minimumCanvas, 560) }
}
