import XCTest

/// T5 herdr connection option UI tests: the editor's Herdr section (toggle,
/// conditional remote-session field, consequence footer), the list's Herdr
/// capsule badge, and persistence across relaunch. Editor-only flows — no
/// fixtures required.
@MainActor
final class HerdrConnectionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testHerdrToggleSessionFieldAndBadgePersistAcrossRelaunch() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Herdr Edit")
        typeInto(app.textFields["field-host"], "10.4.5.6")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        let toggle = app.switches["herdr-toggle"]
        scrollTo(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "SSH connections offer the Herdr section")
        XCTAssertFalse(
            app.textFields["herdr-session-field"].exists,
            "the remote-session field stays hidden while herdr is off"
        )

        XCTAssertTrue(setToggle(toggle, on: true), "the herdr toggle must flip on")

        let sessionField = app.textFields["herdr-session-field"]
        XCTAssertTrue(sessionField.waitForExistence(timeout: 5), "enabling herdr reveals the session field")
        typeInto(sessionField, "work")

        let footer = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "herdr-section-footer")
        ).firstMatch
        scrollTo(footer)
        XCTAssertTrue(
            footer.label.contains("herdr 0.9"),
            "the footer states the server requirement: \(footer.label)"
        )
        XCTAssertTrue(
            footer.label.contains("workspace"),
            "the footer states the consequence of enabling herdr: \(footer.label)"
        )

        app.buttons["save-editor"].tap()

        let row = app.buttons["connection-Herdr-Edit"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["badge-herdr"].waitForExistence(timeout: 5),
            "a herdr-enabled connection carries the Herdr capsule"
        )
        attachScreenshot("herdr-badge-in-list")

        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(
            app.buttons["connection-Herdr-Edit"].waitForExistence(timeout: 10),
            "the connection must survive relaunch"
        )
        XCTAssertTrue(
            app.staticTexts["badge-herdr"].waitForExistence(timeout: 5),
            "the herdr badge must survive relaunch"
        )

        openEditorForConnection(named: "Herdr-Edit")
        let relaunchedToggle = app.switches["herdr-toggle"]
        scrollTo(relaunchedToggle)
        XCTAssertTrue(relaunchedToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(
            (relaunchedToggle.value as? String ?? "").lowercased(), "1",
            "the herdr toggle must persist across relaunch"
        )
        let relaunchedSession = app.textFields["herdr-session-field"]
        XCTAssertTrue(relaunchedSession.waitForExistence(timeout: 5))
        XCTAssertEqual(relaunchedSession.value as? String, "work", "the session name must persist")

        XCTAssertTrue(
            setToggle(relaunchedToggle, on: false),
            "the herdr toggle must flip off after relaunch"
        )
        XCTAssertTrue(
            app.textFields["herdr-session-field"].waitForNonExistence(timeout: 10),
            "disabling herdr hides the session field"
        )
        app.buttons["save-editor"].tap()

        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["badge-herdr"].exists,
            "the badge disappears once herdr is disabled"
        )
        XCTAssertTrue(app.buttons["connection-Herdr-Edit"].exists, "the connection itself is kept")
    }

    func testInvalidSessionNameBlocksSave() {
        app.launchArguments = ["--uitest-reset", "--uitest-seed-keys"]
        app.launch()

        openEditorForNewConnection()
        typeInto(app.textFields["field-name"], "Bad Session")
        typeInto(app.textFields["field-host"], "10.4.5.7")
        typeInto(app.textFields["field-username"], "alice")
        selectAuthenticationKey("Fixture Ed25519")

        let toggle = app.switches["herdr-toggle"]
        scrollTo(toggle)
        XCTAssertTrue(setToggle(toggle, on: true), "the herdr toggle must flip on")
        typeInto(app.textFields["herdr-session-field"], "bad session!")

        scrollTo(app.buttons["save-editor"])
        XCTAssertFalse(
            app.buttons["save-editor"].isEnabled,
            "an invalid remote session name must block saving"
        )
        app.buttons["cancel-editor"].tap()
    }

    // MARK: Helpers

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

    private func typeInto(_ field: XCUIElement, _ text: String) {
        field.tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText(text)
        dismissKeyboard()
    }

    private func selectAuthenticationKey(_ label: String) {
        dismissKeyboard()
        app.buttons["key-selector"].tap()
        let key = app.buttons["key-\(label.replacingOccurrences(of: " ", with: "-"))"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(label) must be listed")
        key.tap()
    }

    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let toolbarDone = app.toolbars.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2) {
            toolbarDone.tap()
            return
        }
        let plainDone = app.buttons["Done"]
        if plainDone.exists {
            plainDone.tap()
            return
        }
        for keyLabel in ["return", "done"] where app.keyboards.buttons[keyLabel].exists {
            app.keyboards.buttons[keyLabel].tap()
            return
        }
    }

    /// A SwiftUI Form Toggle's XCUI element spans the whole row; taps must
    /// land on the trailing edge where the switch renders.
    @discardableResult
    private func setToggle(_ element: XCUIElement, on: Bool) -> Bool {
        func isOn() -> Bool {
            let value = (element.value as? String ?? "").lowercased()
            return value == "1" || value == "true" || value == "on"
        }
        var swipes = 0
        while isOn() != on {
            if !element.isHittable, swipes < 3 {
                app.swipeUp()
                swipes += 1
                continue
            }
            guard swipes < 6 else { return false }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            swipes += 1
        }
        return true
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }

    private func swipeRow(named identifier: String) {
        let cell = app.cells.containing(.button, identifier: "connection-\(identifier)").firstMatch
        if cell.exists {
            cell.swipeLeft()
        } else {
            app.buttons["connection-\(identifier)"].swipeLeft()
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Manual removal poll: SwiftUI drops Form rows asynchronously (and the
    /// accessibility tree lags the animation), so the removal is re-queried
    /// fresh on every iteration rather than through one frozen expectation.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return !exists
    }
}
