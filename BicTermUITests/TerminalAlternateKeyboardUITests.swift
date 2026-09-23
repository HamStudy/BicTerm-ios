import UIKit
import XCTest

/// The alternate function-key keyboard (SwiftTerm's 3-row `KeyboardView`
/// panel: F1–F10 / brackets, ins, home, pgup / operators, del, end,
/// pgdn) as a properly-integrated input mode (fork hunk 17).
///
/// History: upstream's strip button swapped the panel in as the
/// terminal's inputView with a glyph that read as "dismiss keyboard",
/// and with the app's strip hidden the panel had NO dismissal path
/// (real-device defect 2026-09-22). Hunk 16 removed the trap; hunk 17
/// reinstated the panel as an app-driven input mode: the panel installs
/// only through `TerminalView.setAlternateKeyboardActive`, the mode is
/// app-owned (`TerminalToolbarModel.inputMode`), and the toggle is
/// reachable from BOTH the strip's function-keys button (honest "function"
/// glyph) and the scene menu — chrome that never hides.
///
/// These tests pin the contract:
///   1. the toggle summons and dismisses the panel deterministically
///      (panel up + system keyboard replaced; toggle again → panel gone,
///      system keyboard back);
///   2. the terminal reflows above the panel (R1 layout parity — the
///      panel must never cover terminal rows) and the reflow reaches the
///      remote pty;
///   3. the panel dismisses with the Terminal Toolbar strip HIDDEN — the
///      exact hunk-16-era trap condition can never recur;
///   4. the strip's function-keys button is an honest, deterministic
///      toggle, and the dismiss control dismisses the panel into the
///      sticky-hidden state (one terminal tap returns the qwerty
///      keyboard).
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

    private func launch(command: String? = nil) {
        var arguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
        ]
        if let command {
            arguments += ["--uitest-session-command", command]
        }
        app.launchArguments = arguments
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

    private var functionKeysToggleButton: XCUIElement {
        app.buttons["terminal-function-keys-toggle"]
    }

    /// The strip's function-keys button (vendored TerminalAccessory,
    /// honest "function" glyph + accessibility label).
    private var stripFunctionKeysButton: XCUIElement {
        app.buttons["Function Keys"].firstMatch
    }

    private var dismissButton: XCUIElement {
        app.buttons["terminal-keyboard-dismiss"]
    }

    private var accessory: XCUIElement {
        app.descendants(matching: .any)["terminal-accessory"]
    }

    private var terminal: XCUIElement {
        app.descendants(matching: .any)["terminalView"]
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
            "the strip must be visible for this test"
        )
    }

    /// Opens the session menu and taps the Function Keys toggle.
    private func toggleFunctionKeysFromMenu() {
        menuButton.tap()
        XCTAssertTrue(
            functionKeysToggleButton.waitForExistence(timeout: 5),
            "Function Keys toggle missing from the session menu"
        )
        functionKeysToggleButton.tap()
    }

    /// Taps the terminal away from the shell prompt (top of the
    /// scrollback) so SwiftTerm's own single-tap handling never opens the
    /// cursor-adjacent context menu.
    private func tapTerminal() {
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    }

    // MARK: - Tests

    /// The menu toggle summons the panel deterministically (the system
    /// keyboard is replaced, the terminal reflows above the panel) and
    /// dismisses it deterministically (the system keyboard returns for
    /// the focused terminal).
    func testToggleSummonsAndDismissesFunctionKeyPanel() {
        launch()

        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the software keyboard must be up at launch (terminal focuses on attach)"
        )

        // Summon: the panel replaces the system keyboard.
        toggleFunctionKeysFromMenu()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForExistence(timeout: 10),
            "the function-key panel must appear (pgdn key)"
        )
        XCTAssertTrue(
            app.buttons["F5"].exists,
            "the function-key panel must appear (F5 key)"
        )
        XCTAssertTrue(
            app.buttons["pgup"].exists,
            "the function-key panel must appear (pgup key)"
        )
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the panel replaces the system keyboard as the input surface"
        )

        // R1 layout parity: the terminal (and the strip) must sit fully
        // above the panel — the panel never covers terminal rows. F5 is
        // the panel's TOP row, so the terminal's bottom row must sit at
        // or above F5's top edge.
        Thread.sleep(forTimeInterval: 1.0)
        let terminalFrame = terminal.frame
        let f5Frame = app.buttons["F5"].frame
        XCTAssertLessThanOrEqual(
            terminalFrame.maxY, f5Frame.minY + 1,
            "the terminal's bottom row must sit above the function-key panel"
        )
        if accessory.exists {
            XCTAssertLessThanOrEqual(
                accessory.frame.maxY, f5Frame.minY + 1,
                "the accessory strip must sit above the function-key panel"
            )
        }

        // Dismiss: the panel goes away and the system keyboard returns.
        toggleFunctionKeysFromMenu()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForNonExistence(timeout: 10),
            "the function-key panel must dismiss on the second toggle"
        )
        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the system keyboard must return after the panel dismisses"
        )
    }

    /// The reflow must reach the remote pty: a shell trap on SIGWINCH
    /// prints `stty size` exactly when the winsize changes. Dismissed to
    /// a grown baseline, summoning the panel must shrink the rows (the
    /// terminal reflows above the panel), and dismissing the panel must
    /// change them again.
    func testPanelOverlapReflowsRemotePtySize() {
        launch(command: "trap 'stty size' WINCH")
        ensureStripVisible()

        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 5),
            "dismiss control missing from the strip"
        )
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the software keyboard must be up at launch"
        )
        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard"
        )
        let grownRows = waitForTailRows(notEqualTo: nil, timeout: 20)
        XCTAssertNotNil(grownRows, "the grown winsize must reach the remote pty")

        toggleFunctionKeysFromMenu()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForExistence(timeout: 10),
            "the function-key panel must appear"
        )
        let panelRows = waitForTailRows(notEqualTo: grownRows?.rows, timeout: 20)
        XCTAssertNotNil(panelRows, "the panel-overlap winsize must reach the remote pty")
        XCTAssertLessThan(
            panelRows!.rows, grownRows!.rows,
            "rows must reflow down when the panel appears"
        )

        toggleFunctionKeysFromMenu()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForNonExistence(timeout: 10),
            "the function-key panel must dismiss"
        )
        // The terminal kept focus through the menu, so the system
        // keyboard returns — TALLER than the panel, so the row count
        // changes again (fewer rows). The pin is that the dismissal
        // reflow reaches the pty, not the direction.
        let restoredRows = waitForTailRows(notEqualTo: panelRows?.rows, timeout: 20)
        XCTAssertNotNil(restoredRows, "the panel-dismissed winsize must reach the remote pty")
        XCTAssertNotEqual(
            restoredRows!.rows, panelRows!.rows,
            "rows must reflow when the panel dismisses (the system keyboard returns)"
        )
    }

    /// The hunk-16-era trap, pinned as fixed: with the Terminal Toolbar
    /// strip HIDDEN, the panel still dismisses through the scene-menu
    /// toggle — dismissal never depends on the strip's visibility. (The
    /// strip's own keyboard button was the only upstream toggle-back,
    /// which is exactly what made the panel stick.)
    func testPanelDismissesWithStripHidden() {
        launch()
        ensureStripVisible()

        // Summon the panel while the strip is visible.
        toggleFunctionKeysFromMenu()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForExistence(timeout: 10),
            "the function-key panel must appear"
        )

        // Hide the strip — the trap condition. The panel itself stays
        // (it is an input mode, independent of the strip preference).
        menuButton.tap()
        XCTAssertTrue(
            toolbarToggleButton.waitForExistence(timeout: 5),
            "toolbar toggle missing from the session menu"
        )
        toolbarToggleButton.tap()
        XCTAssertTrue(
            accessory.waitForNonExistence(timeout: 10),
            "the strip must hide for the trap-condition check"
        )
        XCTAssertTrue(
            app.buttons["pgdn"].exists,
            "hiding the strip must not dismiss the panel (independent modes)"
        )

        // The panel must still dismiss with the strip gone.
        toggleFunctionKeysFromMenu()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForNonExistence(timeout: 10),
            "the panel must dismiss via the menu toggle with the strip hidden (the hunk-16 trap must not recur)"
        )
    }

    /// The strip's function-keys button is an honest, deterministic
    /// toggle (the hunk-16 trap was a dismiss-glyph button with no
    /// toggle-back), and the dismiss control dismisses the panel into
    /// the sticky-hidden state — one terminal tap returns the qwerty
    /// keyboard.
    func testStripFunctionKeysButtonTogglesPanel() {
        launch()
        ensureStripVisible()

        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the software keyboard must be up at launch"
        )
        XCTAssertTrue(
            stripFunctionKeysButton.waitForExistence(timeout: 5),
            "the strip's function-keys button must exist"
        )
        XCTAssertTrue(
            stripFunctionKeysButton.isHittable,
            "the strip's function-keys button must be tappable"
        )

        // Summon from the strip: the panel replaces the system keyboard.
        stripFunctionKeysButton.tap()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForExistence(timeout: 10),
            "the strip's function-keys button must summon the panel"
        )
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the panel replaces the system keyboard"
        )

        // Toggle back from the strip: the panel dismisses.
        stripFunctionKeysButton.tap()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForNonExistence(timeout: 10),
            "the strip's function-keys button must dismiss the panel"
        )
        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the system keyboard must return after the panel dismisses"
        )

        // Dismiss composition: with the panel up, the strip's dismiss
        // control dismisses BOTH (sticky hidden); one terminal tap
        // returns the qwerty keyboard.
        stripFunctionKeysButton.tap()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForExistence(timeout: 10),
            "the panel must return for the dismiss-composition check"
        )
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 5),
            "dismiss control missing from the strip while the panel is up"
        )
        dismissButton.tap()
        XCTAssertTrue(
            app.buttons["pgdn"].waitForNonExistence(timeout: 10),
            "the dismiss control must dismiss the function-key panel"
        )
        XCTAssertFalse(
            softwareKeyboard.exists,
            "the dismiss control must not resurrect the system keyboard (sticky hidden)"
        )

        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "a terminal tap must bring the qwerty keyboard back"
        )
    }

    /// Polls the scene tail for a `rows cols` pair from the SIGWINCH trap,
    /// optionally waiting until it differs from `notEqualTo`. The tail
    /// carries the whole recent output (login banners included), so every
    /// match is scanned and the LAST plausible pair wins — the trap print
    /// is always the newest output.
    private func waitForTailRows(notEqualTo previous: Int?, timeout: TimeInterval) -> (rows: Int, cols: Int)? {
        let regex = try! NSRegularExpression(pattern: #"(\d+) (\d+)"#)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let label = app.staticTexts["scene-tail-Alpha"].label
            let matches = regex.matches(
                in: label,
                range: NSRange(label.startIndex..., in: label)
            )
            for match in matches.reversed() {
                guard let rowsRange = Range(match.range(at: 1), in: label),
                      let colsRange = Range(match.range(at: 2), in: label),
                      let rows = Int(label[rowsRange]),
                      let cols = Int(label[colsRange]),
                      rows > 5, cols > 20, cols < 200,
                      rows != previous
                else { continue }
                return (rows, cols)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }
}
