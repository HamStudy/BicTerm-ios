import UIKit
import XCTest

/// Herdr keyboard parity (K1/K2 for the embed): the embedded herdr TUI
/// must never sit under the software keyboard — the embed host tracks
/// the keyboard frame and reflows the TUI (plus the accessory strip,
/// stacked) above the actual geometric overlap, and the strip carries
/// the same sticky-dismiss control and terminal-tap re-enable as SSH
/// session surfaces.
///
/// Requires the fixture herdr server (scripts/herdr-server-fetch.sh +
/// scripts/fixtures-up.sh); tests skip when the fixture is down so the
/// rest of the UI suite stays runnable.
final class HerdrEmbedKeyboardUITests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var fixtureSocket: String {
        Self.repoRoot
            .appendingPathComponent("Fixtures/run/herdr/server-12222/herdr-client.sock")
            .path
    }

    private var fixtureIsUp: Bool {
        FileManager.default.fileExists(atPath: fixtureSocket)
    }

    private let fixtureSkipMessage =
        "herdr fixture server not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var app: XCUIApplication!

    /// Launches the embed workspace against the fixture and waits for
    /// the TUI surface. The TUI becomes first responder on attach, so
    /// the software keyboard is up once the surface exists.
    private func launchRunningEmbed() throws {
        try XCTSkipUnless(fixtureIsUp, fixtureSkipMessage)
        app = XCUIApplication()
        app.launchArguments = ["--uitest-herdr-embed"]
        app.launchEnvironment["HERDR_EMBED_SOCKET_PATH"] = fixtureSocket
        app.launch()

        let status = app.descendants(matching: .any)["herdr-embed-status"]
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "embedded client running"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [running], timeout: 20),
            .completed,
            "embedded client reached running (status: \(status.label))"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["herdr-embed-tui"].waitForExistence(timeout: 10),
            "SwiftTerm surface for the embedded TUI exists"
        )
    }

    private var tui: XCUIElement {
        app.descendants(matching: .any)["herdr-embed-tui"]
    }

    private var accessory: XCUIElement {
        app.descendants(matching: .any)["terminal-accessory"]
    }

    private var dismissButton: XCUIElement {
        app.buttons["terminal-keyboard-dismiss"]
    }

    private var softwareKeyboard: XCUIElement {
        app.keyboards.firstMatch
    }

    /// The strip can default hidden on the simulator (the Mac keyboard
    /// bridges as a GCKeyboard): make sure it is explicitly shown through
    /// the herdr chrome's session menu.
    private func ensureStripVisible() {
        if !accessory.exists {
            openHerdrMenu()
            let toggle = app.buttons["terminal-toolbar-toggle-herdr"]
            XCTAssertTrue(
                toggle.waitForExistence(timeout: 5),
                "toolbar toggle missing from the herdr session menu"
            )
            toggle.tap()
        }
        XCTAssertTrue(
            accessory.waitForExistence(timeout: 10),
            "the strip must be visible for the stacked-inset case"
        )
    }

    /// Same convergence loop as HerdrEmbedUITests (re-tapping closes an
    /// already-open menu, so failed attempts retry cleanly).
    private func openHerdrMenu() {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let candidates = app.buttons.matching(identifier: "scene-menu-herdr")
            for index in 0..<candidates.count where candidates.element(boundBy: index).isHittable {
                candidates.element(boundBy: index).tap()
                if app.buttons["scene-sessions-herdr"].waitForExistence(timeout: 5) {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("herdr session menu never opened")
    }

    /// Taps the TUI away from the client's chrome rows (top of the
    /// surface) so the tap re-enables the keyboard without driving a
    /// client-local overlay.
    private func tapTUI() {
        tui.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }

    // MARK: - Tests

    /// The TUI (and the strip below it) must sit fully above the
    /// keyboard's frame while the keyboard is up, and restore the full
    /// height after the sticky dismissal.
    func testEmbeddedTUIReflowsAboveKeyboardAndRestoresAfterDismiss() throws {
        try launchRunningEmbed()
        ensureStripVisible()

        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "the software keyboard must be up at launch (the TUI focuses on attach)"
        )
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 5),
            "dismiss control missing from the herdr strip (K1 parity)"
        )

        // Baseline: dismiss first, then measure the no-keyboard TUI.
        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard on the embed"
        )
        Thread.sleep(forTimeInterval: 1.0)
        let baselineFrame = tui.frame
        XCTAssertGreaterThan(baselineFrame.height, 400, "baseline (no keyboard) TUI height")

        // Re-enable with a terminal tap (K1 parity: one tap brings the
        // keyboard back on the tapped surface).
        tapTUI()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "a TUI tap must bring the software keyboard back"
        )
        Thread.sleep(forTimeInterval: 1.0)

        let keyboardFrame = softwareKeyboard.frame
        let tuiFrame = tui.frame
        let stripFrame = accessory.frame
        XCTAssertLessThan(
            tuiFrame.height, baselineFrame.height - 100,
            "the TUI must reflow (shrink) above the keyboard"
        )
        XCTAssertLessThanOrEqual(
            tuiFrame.maxY, keyboardFrame.minY + 1,
            "the TUI's bottom row must sit above the keyboard"
        )
        XCTAssertLessThanOrEqual(
            stripFrame.maxY, keyboardFrame.minY + 1,
            "the accessory strip must sit above the keyboard"
        )

        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard again"
        )
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(
            tui.frame.height, baselineFrame.height, accuracy: 2,
            "the TUI must restore its full height after dismissal"
        )
    }

    /// Dismissal parity: the sticky hide must survive a strip interaction
    /// (a strip key tap must not resurrect the keyboard) exactly as on
    /// session surfaces.
    func testDismissIsStickyUntilTUITap() throws {
        try launchRunningEmbed()
        ensureStripVisible()

        tapTUI()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "tapping the TUI must show the software keyboard"
        )
        dismissButton.tap()
        XCTAssertTrue(
            softwareKeyboard.waitForNonExistence(timeout: 10),
            "the dismiss control must hide the software keyboard"
        )

        accessory.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertFalse(
            softwareKeyboard.waitForExistence(timeout: 3),
            "strip interaction must not resurrect the keyboard while sticky-hidden"
        )

        tapTUI()
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 10),
            "a TUI tap must bring the keyboard back (one-tap re-enable)"
        )
    }
}
