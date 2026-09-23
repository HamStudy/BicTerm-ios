import UIKit
import XCTest

/// K2: the terminal must NEVER be covered by the software keyboard on
/// iPhone — the host view tracks the keyboard frame and shrinks the
/// terminal (plus the accessory strip, stacked) above the actual
/// geometric overlap, so the bottom row stays visible while typing, and
/// the frame restores after dismissal.
@MainActor
final class TerminalKeyboardLayoutUITests: XCTestCase {
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
            "the strip must be visible for the stacked-inset case"
        )
    }

    private func tapTerminal() {
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    /// With the keyboard visible, the terminal (and the strip below it)
    /// must sit fully above the keyboard's frame; after dismissal the
    /// terminal grows back by the keyboard's overlap.
    func testTerminalReflowsAboveKeyboardAndRestoresAfterDismiss() {
        launch()
        ensureStripVisible()

        // The terminal is first responder from attach, so the keyboard is
        // up at launch — dismiss FIRST to establish the no-keyboard
        // baseline, then show it again.
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 5),
            "dismiss control missing from the strip"
        )
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the software keyboard must be up at launch (terminal focuses on attach)"
        )
        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard"
        )
        Thread.sleep(forTimeInterval: 1.0)

        let baselineFrame = terminal.frame
        print("K2FRAMES baseline=\(baselineFrame) strip=\(accessory.frame) status=\(app.descendants(matching: .any)["scene-status-Alpha"].firstMatch.exists ? app.descendants(matching: .any)["scene-status-Alpha"].firstMatch.frame : .zero)")
        attachScreenshot(named: "k2-baseline-no-keyboard")
        XCTAssertGreaterThan(baselineFrame.height, 400, "baseline (no keyboard) terminal height")

        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "tapping the terminal must show the software keyboard"
        )
        // Let the keyboard's slide-up animation settle before measuring.
        Thread.sleep(forTimeInterval: 1.0)

        let keyboardFrame = softwareKeyboard.frame
        let terminalFrame = terminal.frame
        let stripFrame = accessory.frame
        print("K2FRAMES keyboard=\(keyboardFrame) terminal=\(terminalFrame) strip=\(stripFrame)")

        XCTAssertLessThan(
            terminalFrame.height, baselineFrame.height - 100,
            "the terminal must reflow (shrink) above the keyboard"
        )
        XCTAssertLessThanOrEqual(
            terminalFrame.maxY, keyboardFrame.minY + 1,
            "the terminal's bottom row must sit above the keyboard"
        )
        XCTAssertLessThanOrEqual(
            stripFrame.maxY, keyboardFrame.minY + 1,
            "the accessory strip must sit above the keyboard"
        )
        XCTAssertGreaterThan(
            terminalFrame.height, 0,
            "the terminal must keep a usable height above the keyboard"
        )

        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard"
        )
        Thread.sleep(forTimeInterval: 1.0)

        let restoredFrame = terminal.frame
        print("K2FRAMES restored=\(restoredFrame) baseline=\(baselineFrame)")
        XCTAssertEqual(
            restoredFrame.height, baselineFrame.height, accuracy: 2,
            "the terminal must restore its full height after dismissal"
        )
    }

    /// The reflow must reach the remote pty: a shell trap on SIGWINCH
    /// prints `stty size` exactly when the winsize changes (the shell sits
    /// at its prompt as the foreground process group, so the kernel's
    /// SIGWINCH reaches the trap), and the tail shows the grown row count
    /// after dismissal and the shrunk count once the keyboard returns.
    func testKeyboardOverlapReflowsRemotePtySize() {
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
        let tailNow = app.staticTexts["scene-tail-Alpha"].label
        XCTAssertNotNil(grownRows, "the grown winsize must reach the remote pty; tail: \(tailNow.suffix(200))")

        tapTerminal()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "a terminal tap must bring the keyboard back"
        )
        let shrunkRows = waitForTailRows(notEqualTo: grownRows?.rows, timeout: 20)
        XCTAssertNotNil(shrunkRows, "the shrunk winsize must reach the remote pty")
        XCTAssertLessThan(
            shrunkRows!.rows, grownRows!.rows,
            "rows must reflow down when the keyboard returns"
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
