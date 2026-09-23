import UIKit
import XCTest

/// Sticky software-keyboard dismissal (K1): the accessory strip's dismiss
/// control takes the on-screen keyboard down AND keeps it down — the
/// fork's blocker input view means neither a strip interaction nor
/// UIKit's focus machinery can resurrect it — until a terminal tap
/// re-enables it app-side (one tap brings the keyboard back).
///
/// The hardware-keyboard heuristic can hide the strip on the simulator
/// (the Mac keyboard bridges as a GCKeyboard), so every test first
/// ensures the strip is explicitly visible through the session menu.
@MainActor
final class TerminalKeyboardDismissalUITests: XCTestCase {
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

    private var terminal: XCUIElement {
        app.descendants(matching: .any)["terminalView"]
    }

    private var dismissButton: XCUIElement {
        app.buttons["terminal-keyboard-dismiss"]
    }

    private var softwareKeyboard: XCUIElement {
        app.keyboards.firstMatch
    }

    /// The dismiss control lives in the strip row: make sure the strip is
    /// explicitly shown (the hardware-keyboard heuristic may have hidden
    /// it on this simulator).
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
            "the strip must be visible for the dismiss control"
        )
    }

    /// Taps the terminal away from the shell prompt (top of the
    /// scrollback) so SwiftTerm's own single-tap handling never opens the
    /// cursor-adjacent context menu.
    private func tapTerminal() {
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    }

    // MARK: - Tests

    /// Dismiss → keyboard hidden; a strip interaction must NOT resurrect
    /// it (sticky); one terminal tap brings it back.
    func testDismissIsStickyUntilTerminalTap() {
        launch()
        ensureStripVisible()

        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "tapping the terminal must show the software keyboard"
        )

        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 5),
            "dismiss control missing from the strip"
        )
        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard"
        )

        // Sticky: using the strip (a key tap) must not resurrect the
        // keyboard — the blocker keeps UIKit's focus path keyboard-less.
        accessory.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertFalse(
            softwareKeyboard.waitForExistence(timeout: 3),
            "strip interaction must not resurrect the keyboard while sticky-hidden"
        )

        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "a terminal tap must bring the keyboard back (one-tap re-enable)"
        )
    }

    /// The dismiss control participates in the strip layout: it sits in
    /// the strip row (same vertical band as the accessory), and the
    /// accessory keeps the strip row's leading width.
    func testDismissControlLivesInStripRow() {
        launch()
        ensureStripVisible()

        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 5),
            "dismiss control missing from the strip"
        )
        XCTAssertTrue(dismissButton.isHittable)

        let stripRow = accessory.frame
        let dismissFrame = dismissButton.frame
        XCTAssertEqual(
            dismissFrame.minY, stripRow.minY, accuracy: 2,
            "the dismiss control must sit in the strip row"
        )
        XCTAssertEqual(
            dismissFrame.height, stripRow.height, accuracy: 2,
            "the dismiss control must fill the strip height"
        )
        XCTAssertGreaterThan(
            dismissFrame.minX, stripRow.minX,
            "the dismiss control must trail the accessory, not overlap it"
        )
    }
}
