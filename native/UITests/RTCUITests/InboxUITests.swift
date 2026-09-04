import XCTest

final class InboxUITests: XCTestCase {
    func testKeyboardAccessibleRowActivatesExactReviewID() {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-inbox-fixture"]
        app.launch()

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox-row-'"))
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let reviewID = String(row.identifier.dropFirst("inbox-row-".count))
        XCTAssertFalse(row.label.isEmpty)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Review \(reviewID)"].waitForExistence(timeout: 3))
    }

    func testRetryIsSeparateAndStatusIsAnnounced() {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-inbox-fixture"]
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox-row-'" )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let status = row.value as? String ?? ""
        XCTAssertTrue(status.contains("Unread"))
        XCTAssertTrue(status.contains("Pending") || status.contains("Failed"))

        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox-retry-'" )).firstMatch
        if retry.waitForExistence(timeout: 5) {
            retry.click()
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).firstMatch.exists)
        }
    }
}
