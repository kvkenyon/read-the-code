import XCTest

final class TourWorkspaceUITests: XCTestCase {
    func testTourWorkspaceExposesStatusAndKeyboardDiagramControls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--fixture", "tour-workspace-accessibility"]
        app.launch()

        XCTAssertTrue(app.otherElements["tour.workspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["tour.status"].exists)
        XCTAssertTrue(app.buttons["Zoom in diagram"].isEnabled)
        XCTAssertTrue(app.buttons["Zoom out diagram"].isEnabled)
        XCTAssertTrue(app.buttons["Fit and reset diagram"].isEnabled)
        XCTAssertTrue(app.buttons["Pan diagram left"].isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Relationship '")).count > 0)
    }

    func testStaleTourIsReadOnlyButExactSourceRemainsFocusable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--fixture", "tour-workspace-stale"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Read-only"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Generate Local Tour"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sources/'")).count > 0)
    }
}
