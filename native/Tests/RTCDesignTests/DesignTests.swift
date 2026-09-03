import XCTest
import SwiftUI
@testable import RTCDesign

final class DesignTests: XCTestCase {
    func testSemanticTokensAreComplete() { XCTAssertEqual(RTCColorToken.allCases.count, 12); XCTAssertEqual(RTCDesign.cornerRadius, 7) }
    func testRestorationCorruptAndUnknownVersionFallsBack() { XCTAssertEqual(WorkspaceRestorationState.decode(Data("{}".utf8)), WorkspaceRestorationState()); XCTAssertEqual(WorkspaceRestorationState.decode(Data("{\"version\":99}".utf8)), WorkspaceRestorationState()) }
    func testRestorationRoundTrip() { var state = WorkspaceRestorationState(); state.mode = .diff; state.collapsed = [.agent]; state.widths[.story] = 280; XCTAssertEqual(WorkspaceRestorationState.decode(state.encoded()!), state) }
    func testSizingThresholds() { XCTAssertEqual(WorkspaceSizing.behavior(for: 1_400, agentOpen: true), "split"); XCTAssertEqual(WorkspaceSizing.behavior(for: 1_200, agentOpen: true), "overlay-comments"); XCTAssertEqual(WorkspaceSizing.behavior(for: 900, agentOpen: false), "inspector") }
}
