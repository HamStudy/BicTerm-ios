import XCTest

/// T10 key-offer pool UI tests. Every connection is created through the
/// editor so the draft → `ConnectionDraft.makeConnection()` → model
/// persistence path is under test, then exercised against a real server:
/// the inherited pool connects to the fixture sshd (12222, key-only),
/// keys-off + saved password and blank-password flows ride the in-process
/// password seam (18090, user `uitest`).
@MainActor
final class KeyOfferUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: Default pool — inherited keys connect against the fixture sshd

    func testDefaultPoolConnectsAgainstFixtureServer() {
        // Wipe ALL keys, then reseed the three fixture ed25519 keys so the
        // inherited pool is exactly three enabled keys regardless of what
        // earlier suites in the same run left in the Keychain.
        launchApp(arguments: ["-uitest-reset-keys", "--uitest-reset"])

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Pool Default")
        typeInto(app.textFields["field-host"], "127.0.0.1")
        typeInto(app.textFields["field-port"], "12222", clearing: "22")
        typeInto(app.textFields["field-username"], Self.fixtureUsername)

        // No key selection, no password: the draft keeps its inherited
        // state (Offer Keys on, customization nil) and must save as such.
        XCTAssertTrue(
            app.buttons["key-selector"].label.contains("All keys (3 offered)"),
            "the editor must summarize the inherited pool, got: \(app.buttons["key-selector"].label)"
        )
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Pool-Default"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.staticTexts["auth-method-Pool-Default"].label, "All keys (3 offered)",
            "an inherited connection must round-trip as nil customization, not an empty list"
        )

        row.tap()
        if app.buttons["trust-confirm"].waitForExistence(timeout: 5) {
            app.buttons["trust-confirm"].tap()
        }
        waitForConnected(named: "Pool-Default")
    }

    // MARK: Keys off + saved password — password-only connect via the seam

    func testKeysOffSavedPasswordConnectsViaPasswordSeam() {
        launchApp(arguments: ["-uitest-reset-keys", "--uitest-reset", "--uitest-pwd-server"])

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Pool Password")
        typeInto(app.textFields["field-host"], "127.0.0.1")
        typeInto(app.textFields["field-port"], "18090", clearing: "22")
        typeInto(app.textFields["field-username"], "uitest")
        setOfferKeys(false)
        typeIntoSecure(app.secureTextFields["password-field"], "bicterm-uitest-fixture-password")
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()
        dismissSystemSavePromptIfPresent()

        let row = app.buttons["connection-Pool-Password"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["auth-method-Pool-Password"].label, "Password")

        row.tap()
        if app.buttons["trust-confirm"].waitForExistence(timeout: 5) {
            app.buttons["trust-confirm"].tap()
        }
        waitForConnected(named: "Pool-Password")
        XCTAssertFalse(
            app.secureTextFields["password-prompt-field"].exists,
            "a saved password must authenticate without prompting"
        )
    }

    // MARK: Blank password — save, interactive prompt, remember

    func testBlankPasswordPromptsAndRemembers() {
        launchApp(arguments: ["-uitest-reset-keys", "--uitest-reset", "--uitest-pwd-server"])

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Pool Blank")
        typeInto(app.textFields["field-host"], "127.0.0.1")
        typeInto(app.textFields["field-port"], "18090", clearing: "22")
        typeInto(app.textFields["field-username"], "uitest")
        setOfferKeys(false)
        XCTAssertTrue(
            app.staticTexts["password-field-status"].label.contains("server requests"),
            "a blank password must explain that prompting occurs only if the server requests a password"
        )
        waitForEnabled(app.buttons["save-editor"])
        app.buttons["save-editor"].tap()
        XCTAssertTrue(app.buttons["connection-Pool-Blank"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["auth-method-Pool-Blank"].label, "Password")

        app.buttons["connection-Pool-Blank"].tap()
        if app.buttons["trust-confirm"].waitForExistence(timeout: 5) {
            app.buttons["trust-confirm"].tap()
        }
        XCTAssertTrue(app.secureTextFields["password-prompt-field"].waitForExistence(timeout: 10))
        typeIntoSecure(app.secureTextFields["password-prompt-field"], "bicterm-uitest-fixture-password")
        let toggle = app.switches["password-prompt-save"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["password-prompt-connect"].tap()
        waitForConnected(named: "Pool-Blank")

        app.terminate()
        launchApp(arguments: ["--uitest-pwd-server"])
        openEditorForConnection(named: "Pool-Blank")
        scrollToHittable(app.secureTextFields["password-field"])
        XCTAssertTrue(
            app.staticTexts["password-saved-badge"].waitForExistence(timeout: 5),
            "a remembered prompt password must surface the saved badge after relaunch"
        )
        app.buttons["cancel-editor"].tap()
    }

    // MARK: Helpers

    /// The fixture sshd on 12222 runs as the host user owning this
    /// checkout; the simulator app process resolves NSUserName() to ""
    /// (the same gap `SessionFixtureSeeder` works around), so derive the
    /// name from `#filePath`, which is baked in at compile time.
    private static var fixtureUsername: String {
        for candidate in [ProcessInfo.processInfo.environment["USER"],
                          ProcessInfo.processInfo.environment["LOGNAME"]] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        let components = URL(fileURLWithPath: #filePath).pathComponents
        if components.count > 3, components[0] == "/", components[1] == "Users" {
            return components[2]
        }
        return NSUserName()
    }

    private func waitForConnected(named identifier: String, timeout: TimeInterval = 20) {
        let status = app.staticTexts["scene-statuschip-\(identifier)"]
        expectation(for: NSPredicate(format: "label == 'Connected'"), evaluatedWith: status)
        waitForExpectations(timeout: timeout)
    }

    private func launchApp(arguments: [String]) {
        app.launchArguments = arguments + ["--uitest-pretrust-fixtures"]
        app.launch()
    }

    private func openEditorForNewConnection() {
        let add = app.buttons["add-connection"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.textFields["field-name"].waitForExistence(timeout: 10))
    }

    private func openEditorForConnection(named identifier: String) {
        swipeRow(named: identifier)
        let edit = app.buttons["edit-\(identifier)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.buttons["cancel-editor"].waitForExistence(timeout: 10))
    }

    private func setOfferKeys(_ enabled: Bool) {
        dismissKeyboard()
        let toggle = app.switches["offer-keys-toggle"]
        scrollToHittable(toggle, swipingUp: false)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String == "1") != enabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    private func typeInto(_ field: XCUIElement, _ text: String, clearing existing: String? = nil) {
        scrollToHittable(field, swipingUp: false)
        field.tap()
        awaitKeyboardFocus(on: field)
        if existing != nil {
            clearField(field)
        }
        app.typeText(text)
        XCTAssertEqual(field.value as? String, text, "input must land exactly")
        dismissKeyboard()
    }

    private func typeIntoSecure(_ field: XCUIElement, _ text: String) {
        scrollToHittable(field, swipingUp: false)
        // Tap toward the trailing edge: on regular-width sheets SwiftUI can
        // report the whole row as the field's frame, and a center tap then
        // lands between the label and the text box, never focusing the
        // editor. 75% width is inside the text box in both AX shapes.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        awaitKeyboardFocus(on: field)
        app.typeText(text)
        let bullets = field.value as? String
        XCTAssertEqual(bullets?.count, text.count, "secure input must land exactly")
        dismissKeyboard()
    }

    private func awaitKeyboardFocus(on field: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: timeout)
    }

    private func waitForEnabled(_ button: XCUIElement, timeout: TimeInterval = 8) {
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: timeout)
    }

    private func clearField(_ field: XCUIElement) {
        // Double-tap selects the whole word ("22"-style defaults are a
        // single token), so the following typeText REPLACES it.
        field.doubleTap()
    }

    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let toolbarDone = app.toolbars.buttons["Done"]
        let plainDone = app.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2) {
            toolbarDone.tap()
            return
        }
        if plainDone.exists, plainDone.identifier != "customize-done" {
            plainDone.tap()
            return
        }
        for keyLabel in ["return", "done"] where app.keyboards.buttons[keyLabel].exists {
            app.keyboards.buttons[keyLabel].tap()
            return
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// The editor opts out of the system password-vault flow via
    /// `.textContentType(.oneTimeCode)`, and BicTerm owns persistence (the
    /// saved-password badge assertions prove the app's own flow). iOS 26.5's
    /// AutoFill still presents its "Save Password?" sheet once the
    /// simulator's password subsystem is active, regardless of the opt-out,
    /// so dismiss the OS sheet when it appears and keep the flow under test
    /// moving.
    private func dismissSystemSavePromptIfPresent() {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) {
            notNow.tap()
            let dismissed = NSPredicate(format: "exists == false")
            expectation(for: dismissed, evaluatedWith: notNow)
            waitForExpectations(timeout: 3)
        }
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        swipingUp: Bool = true,
        maxSwipes: Int = 8
    ) {
        var attempts = 0
        while !isFullyVisibleInWindow(element) && attempts < maxSwipes {
            if swipingUp {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            attempts += 1
        }
    }

    private func isFullyVisibleInWindow(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        let inset: CGFloat = 8
        guard frame.minX >= window.minX + inset,
              frame.maxX <= window.maxX - inset,
              frame.minY >= window.minY + inset,
              frame.maxY <= window.maxY - inset else { return false }
        let navBars = app.navigationBars
        for index in 0..<navBars.count {
            let bar = navBars.element(boundBy: index).frame
            if !bar.isEmpty, frame.minY < bar.maxY + 4 { return false }
        }
        return true
    }

    private func swipeRow(named identifier: String) {
        let row = app.buttons["connection-\(identifier)"]
        let cell = app.cells.containing(.button, identifier: "connection-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            row.swipeLeft()
        }
    }
}
