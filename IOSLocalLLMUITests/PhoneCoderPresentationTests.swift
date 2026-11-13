import XCTest

/// Exercises the shipped shell, with no test-only routing or model downloads.
final class PhoneCoderPresentationTests: XCTestCase {
    func testLaunchSelectsServerAndPreservesNativeDockOrder() {
        let app = XCUIApplication()
        app.launch()
        let server = app.tabBars.buttons["Server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(server.isSelected)
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label),
                       ["Chat", "Models", "Server", "Images", "Settings"])
        XCTAssertEqual(app.buttons.matching(identifier: "phonecoder.server.primary").count, 1)
        XCTAssertFalse(app.buttons["phonecoder.server.primary"].label.isEmpty)
    }

    func testScreenHeadersAndPrimaryActionsHaveAccessibleNames() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Server"].waitForExistence(timeout: 10))
        for (tab, id) in [("Server", "server"), ("Models", "models"), ("Images", "images"), ("Settings", "settings")] {
            app.tabBars.buttons[tab].tap()
            let header = app.descendants(matching: .any)["phonecoder." + id + ".status"].firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 5), tab)
            XCTAssertFalse(header.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tab)
        }
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.buttons["phonecoder.chat.model"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["phonecoder.chat.model"].label.isEmpty)
        XCTAssertEqual(app.buttons.matching(identifier: "phonecoder.chat.send").count, 1)
        XCTAssertFalse(app.buttons["phonecoder.chat.send"].label.isEmpty)
        XCTAssertTrue(app.descendants(matching: .any)["phonecoder.chat.draft"].firstMatch.exists)
    }
}
