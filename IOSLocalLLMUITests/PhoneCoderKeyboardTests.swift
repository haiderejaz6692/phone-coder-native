import XCTest

/// Runs the production Phone Coder shell. No model download, automatic server
/// start, fake keyboard, or UI-test-only app launch path is needed.
final class PhoneCoderKeyboardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Server"].waitForExistence(timeout: 10))
    }

    func testChatReturnEditsMultilineDraftAndDonePreservesIt() {
        open("Chat")
        let draft = input("phonecoder.chat.draft")
        draft.tap()
        draft.typeText("first line\nsecond line")
        hideKeyboard()
        XCTAssertEqual(draft.value as? String, "first line\nsecond line")
        draft.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        hideKeyboard()
        XCTAssertEqual(draft.value as? String, "first line\nsecond line")
    }

    func testAcceptedSendDismissesKeyboardAndSubmitsDraft() {
        open("Chat")
        let draft = input("phonecoder.chat.draft")
        draft.tap()
        draft.typeText("keyboard acceptance test")
        app.buttons["phonecoder.chat.send"].tap()
        assertKeyboardHidden()
        XCTAssertTrue(app.staticTexts["keyboard acceptance test"].exists)
        XCTAssertNotEqual(draft.value as? String, "keyboard acceptance test")
        // A subsequent runtime/model error remains visible in the normal UI;
        // acceptance here means the user message was queued, not inference success.
    }

    func testHistorySheetAndTabTransitionsReleaseChatFocusWithoutErasingDraft() throws {
        open("Chat")
        let draft = input("phonecoder.chat.draft")
        draft.tap()
        draft.typeText("keep this draft")
        let history = app.buttons["phonecoder.chat.history"]
        guard history.isEnabled else { throw XCTSkip("Local history is disabled on this test device") }
        history.tap()
        assertKeyboardHidden()
        app.buttons["phonecoder.chat.history.done"].tap()
        assertKeyboardHidden()
        XCTAssertEqual(draft.value as? String, "keep this draft")
        draft.tap()
        open("Models")
        assertKeyboardHidden()
        open("Chat")
        assertKeyboardHidden()
        XCTAssertEqual(draft.value as? String, "keep this draft")
    }

    func testEveryImageInputHasDoneAndPreservesItsValue() {
        open("Images")
        let prompt = input("phonecoder.images.prompt")
        prompt.tap()
        prompt.typeText("first line\nsecond line")
        hideKeyboard()
        XCTAssertEqual(prompt.value as? String, "first line\nsecond line")
        app.buttons["Generation options"].tap()
        for (id, value) in [("negative", "blur\nnoise"), ("steps", "12"), ("seed", "42")] {
            let field = input("phonecoder.images." + id)
            reveal(field)
            replace(field, with: value)
            hideKeyboard()
            XCTAssertEqual(field.value as? String, value)
        }
    }

    func testImageValidationRetainsKeyboardAndInput() throws {
        open("Images")
        try requireInstalledImageModel()
        app.buttons["Generation options"].tap()
        let steps = input("phonecoder.images.steps")
        reveal(steps)
        replace(steps, with: "0")
        let generate = app.buttons["phonecoder.images.generate"]
        // Ensure validation reaches the invalid numeric field rather than the
        // earlier empty-prompt guard, without invoking the native runtime.
        hideKeyboard()
        let prompt = input("phonecoder.images.prompt")
        reveal(prompt)
        prompt.tap(); prompt.typeText("a landscape")
        hideKeyboard()
        reveal(steps)
        steps.tap()
        XCTAssertTrue(generate.isHittable, "Generate must remain reachable with a number pad")
        generate.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(steps.value as? String, "0")
        XCTAssertTrue(app.descendants(matching: .any)["Needs attention. Use 1 through 100 steps."].firstMatch.exists)
    }

    func testAcceptedGenerateDismissesKeyboardAndPreservesPrompt() throws {
        open("Images")
        try requireInstalledImageModel()
        let prompt = input("phonecoder.images.prompt")
        reveal(prompt)
        prompt.tap(); prompt.typeText("a landscape")
        let generate = app.buttons["phonecoder.images.generate"]
        XCTAssertTrue(generate.isHittable, "Generate must remain reachable while editing")
        generate.tap()
        assertKeyboardHidden()
        XCTAssertEqual(prompt.value as? String, "a landscape")
        // This case is for a prepared simulator/device with a downloaded model.
        // Stop as soon as admission is observed; image quality is a separate gate.
        let cancel = app.buttons["Cancel generation"]
        if cancel.exists && cancel.isEnabled { cancel.tap() }
    }

    func testPortNumberPadDonePreservesValueAndAcceptedApplyDismisses() {
        open("Settings")
        let port = input("phonecoder.settings.port")
        let original = port.value as? String ?? "11434"
        replace(port, with: "12034")
        hideKeyboard()
        XCTAssertEqual(port.value as? String, "12034")
        port.tap()
        app.buttons["phonecoder.settings.apply-port"].tap()
        assertKeyboardHidden()
        XCTAssertEqual(port.value as? String, "12034")
        // Restore the user's original saved port on a successful run.
        replace(port, with: original)
        app.buttons["phonecoder.settings.apply-port"].tap()
        assertKeyboardHidden()
    }

    func testInvalidPortRetainsValueKeyboardAndVisibleValidation() {
        open("Settings")
        let port = input("phonecoder.settings.port")
        replace(port, with: "80")
        app.buttons["phonecoder.settings.apply-port"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(port.value as? String, "80")
        XCTAssertTrue(app.descendants(matching: .any)["Needs attention. Use a port from 1024 through 65535."].firstMatch.exists)
        hideKeyboard()
        XCTAssertEqual(port.value as? String, "80")
        XCTAssertTrue(app.descendants(matching: .any)["Needs attention. Use a port from 1024 through 65535."].firstMatch.exists)
    }

    func testSettingsScrollDismissesNumberPadWithoutApplyingInput() {
        open("Settings")
        let port = input("phonecoder.settings.port")
        replace(port, with: "12345")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        assertKeyboardHidden()
        // Return to the top without tapping Apply.
        for _ in 0..<3 where !port.isHittable { app.swipeDown() }
        XCTAssertEqual(port.value as? String, "12345")
    }

    func testTabChangesReleaseImageAndPortFocus() {
        open("Images")
        let prompt = input("phonecoder.images.prompt")
        prompt.tap(); prompt.typeText("keep image prompt")
        open("Server")
        assertKeyboardHidden()
        open("Images")
        assertKeyboardHidden()
        XCTAssertEqual(prompt.value as? String, "keep image prompt")
        open("Settings")
        input("phonecoder.settings.port").tap()
        open("Server")
        assertKeyboardHidden()
        open("Settings")
        assertKeyboardHidden()
    }

    private func open(_ tab: String) { app.tabBars.buttons[tab].tap() }
    private func input(_ id: String) -> XCUIElement {
        let field = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), id)
        return field
    }
    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 1) + value)
    }
    private func reveal(_ field: XCUIElement) {
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
    }
    private func hideKeyboard() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let done = app.buttons["phonecoder.keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        assertKeyboardHidden()
    }
    private func assertKeyboardHidden() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }
    private func requireInstalledImageModel() throws {
        guard app.staticTexts["Downloaded on this phone"].exists else {
            throw XCTSkip("Requires an installed selected image model; this test never downloads weights")
        }
    }
}
