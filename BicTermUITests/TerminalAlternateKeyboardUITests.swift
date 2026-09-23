import UIKit
import XCTest

/// T2: the vendored strip's keyboard button used to toggle SwiftTerm's
/// alternate function-key keyboard — a 3-row panel (F1–F10 / brackets,
/// ins, home, pgup / operators, del, end, pgdn) that replaced the system
/// keyboard as the terminal's inputView and had NO dismissal path once
/// the app's strip was hidden (real-device defect: the panel stuck with
/// Terminal Toolbar off). SwiftTerm fork hunk 16 removed the button and
/// neutered the toggle; this test pins that tapping the strip's right
/// edge — where the button lived — never swaps the system keyboard for
/// the panel.
@MainActor
final class TerminalAlternateKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func launch() {
        app.launchArguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
        ]
        app.launch()
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 60),
            "scene chrome never appeared"
        )
    }

    private var menuButton: XCUIElement {
        app.buttons["scene-menu"].firstMatch
    }

    private var toolbarToggleButton: XCUIElement {
        app.buttons["terminal-toolbar-toggle"]
    }

    private var accessory: XCUIElement {
        app.descendants(matching: .any)["terminal-accessory"]
    }

    private var softwareKeyboard: XCUIElement {
        app.keyboards.firstMatch
    }

    /// The strip can default hidden on the simulator (the Mac keyboard
    /// bridges as a GCKeyboard): make sure it is explicitly shown.
    private func ensureStripVisible() {
        if !accessory.exists {
            menuButton.tap()
            XCTAssertTrue(
                toolbarToggleButton.waitForExistence(timeout: 5),
                "toolbar toggle missing from the session menu"
            )
            toolbarToggleButton.tap()
        }
        XCTAssertTrue(
            accessory.waitForExistence(timeout: 10),
            "the strip must be visible for the right-edge tap"
        )
    }

    // MARK: - Tests

    /// Tapping the strip's rightmost slot (where SwiftTerm's keyboard
    /// button lived, immediately left of the app's trailing dismiss
    /// control) must never replace the system keyboard with the alternate
    /// function-key panel.
    func testStripRightEdgeTapNeverSwapsInAlternateFunctionKeyboard() {
        launch()
        ensureStripVisible()

        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the software keyboard must be up at launch (terminal focuses on attach)"
        )

        accessory.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(
            softwareKeyboard.exists,
            "the system keyboard must survive a strip right-edge tap (no alternate-keyboard swap)"
        )
        XCTAssertFalse(
            app.buttons["pgdn"].exists,
            "the alternate function-key panel must never appear (pgdn key)"
        )
        XCTAssertFalse(
            app.buttons["pgup"].exists,
            "the alternate function-key panel must never appear (pgup key)"
        )
        XCTAssertFalse(
            app.buttons["F5"].exists,
            "the alternate function-key panel must never appear (F5 key)"
        )
    }
}
