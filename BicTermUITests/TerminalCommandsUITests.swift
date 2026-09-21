import UIKit
import XCTest

/// Plan todo 9 (C5): focused iPad keyboard commands, driven through the
/// REAL app. XCUITest cannot synthesize hardware Command chords on the
/// simulator, so every action here fires through the DEBUG
/// `--uitest-terminal-commands` seam — which dispatches the exact
/// `performTerminalCommand` handler each registered chord routes
/// through — while the chord registration itself (⌘N/⌘W/⌘]/⌘[/⌘,) is
/// pinned at model level in TerminalCommandsTests. Covers focused-scene
/// resolution between two terminal windows, close through the existing
/// confirmation, next/previous wraparound (in-window and cross-window),
/// New Session, and Settings opening without terminal actions. Runs
/// against the real fixture sshd instances (hop1=12222, hop2=12223).
@MainActor
final class TerminalCommandsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func baseLaunchArguments(extra: [String] = []) -> [String] {
        [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-terminal-commands",
        ] + extra
    }

    /// SwiftUI Texts report an EMPTY `value` to XCUI — content lives in
    /// `label`.
    private func label(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    @discardableResult
    private func waitUntil(
        _ element: XCUIElement,
        contains marker: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label(of: element).contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return label(of: element).contains(marker)
    }

    /// The seam status is the GLOBAL focused-scene resolution — every
    /// terminal window's copy shows the same text, so any copy proves
    /// which session the commands would act on.
    @discardableResult
    private func waitUntilFocusedSession(
        _ expected: String,
        timeout: TimeInterval = 20
    ) -> Bool {
        waitUntil(
            app.staticTexts["cmd-focus-status"].firstMatch,
            contains: "focus:\(expected)",
            timeout: timeout
        )
    }

    /// Several windows may each carry a seam copy — tap whichever is
    /// actually hittable (the frontmost window's).
    @discardableResult
    private func tapSeamButton(_ identifier: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = app.buttons.matching(identifier: identifier)
            for index in 0..<candidates.count where candidates.element(boundBy: index).isHittable {
                candidates.element(boundBy: index).tap()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: - Focused-scene resolution (two windows)

    /// With two terminal windows, the focused-scene target resolves to
    /// the FRONTMOST scene only: the close command acts on the frontmost
    /// window's session (its confirmation names it), and the other
    /// window's session is untouched.
    func testFocusedTargetResolvesToFrontmostSceneOnly() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Keyboard-command scenarios require the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(
            app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60),
            "both sessions never attached"
        )
        // Beta's window opened last — it is the frontmost (active) scene.
        XCTAssertTrue(waitUntilFocusedSession("Beta"), "the frontmost window must own the command target")

        XCTAssertTrue(tapSeamButton("cmd-close"), "close command never fired")
        let confirm = app.buttons["scene-confirm-close"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "close must route through the confirmation")
        XCTAssertTrue(
            app.descendants(matching: .any)["Disconnect from Beta?"].exists,
            "the confirmation must name the FRONTMOST window's session"
        )

        // Cancel (iOS 26 drops Cancel-role buttons from the AX tree —
        // dismiss by tapping outside the dialog) and prove both sessions
        // survived the command.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let goneDeadline = Date().addingTimeInterval(10)
        while Date() < goneDeadline && confirm.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(confirm.exists, "Cancel must dismiss the confirmation")
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Alpha"], contains: "status:active", timeout: 30),
            "the unfocused window's session must be untouched: "
                + label(of: app.staticTexts["scene-status-Alpha"])
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Beta"], contains: "status:active", timeout: 30),
            "the focused window's session must survive the cancelled close: "
                + label(of: app.staticTexts["scene-status-Beta"])
        )
    }

    // MARK: - Next / Previous

    /// ⌘] from the frontmost window resolves the wraparound neighbor
    /// and FOCUSES the window already hosting it (never a duplicate
    /// window, never one session in two windows); the previously focused
    /// window keeps its session.
    func testNextSessionFromFocusedWindowFocusesNeighborHostedWindow() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Keyboard-command scenarios require the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntilFocusedSession("Beta"))

        // Order is [Alpha, Beta]: next from Beta WRAPS AROUND to Alpha,
        // which the other window hosts — the command focuses that window.
        XCTAssertTrue(tapSeamButton("cmd-next"), "next command never fired")
        XCTAssertTrue(
            waitUntilFocusedSession("Alpha", timeout: 30),
            "next must move the command target to the neighbor's window"
        )

        // Structural guarantee (XCUI cannot observe z-order directly): one
        // window per session, both intact, no duplicates spawned.
        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Alpha").count, 1,
            "next must never open a duplicate window"
        )
        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Beta").count, 1,
            "next must never open a duplicate window"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Beta"], contains: "status:active", timeout: 30),
            "the previously focused window's session must keep running: "
                + label(of: app.staticTexts["scene-status-Beta"])
        )
    }

    /// ⌘]/⌘[ cycle the FOCUSED window's attached session with wraparound
    /// when the neighbor is detached: the window's content switches in
    /// place, the switched-away session keeps running, and the cycle
    /// wraps in both directions.
    func testNextAndPreviousCycleInWindowWithWraparound() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Keyboard-command scenarios require the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session-detached", "Beta"]
        )
        app.launch()

        XCTAssertTrue(
            app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60),
            "presented Alpha window never appeared"
        )
        XCTAssertTrue(waitUntilFocusedSession("Alpha"))

        // Next: detached Beta attaches in THIS window.
        XCTAssertTrue(tapSeamButton("cmd-next"))
        XCTAssertTrue(
            app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 15),
            "next must switch the focused window to the detached neighbor"
        )
        XCTAssertTrue(waitUntilFocusedSession("Beta"))

        // Next again: wraparound back to Alpha (now detached) — and Alpha
        // must still be alive after having been switched away from.
        XCTAssertTrue(tapSeamButton("cmd-next"))
        XCTAssertTrue(
            app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 15),
            "wraparound must switch the window back to Alpha"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Alpha"], contains: "status:active", timeout: 30),
            "the switched-away session must have kept running: "
                + label(of: app.staticTexts["scene-status-Alpha"])
        )
        XCTAssertTrue(waitUntilFocusedSession("Alpha"))

        // Previous: wraparound backward from Alpha lands on Beta.
        XCTAssertTrue(tapSeamButton("cmd-prev"))
        XCTAssertTrue(
            app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 15),
            "previous must wrap around backward to Beta"
        )
        XCTAssertTrue(waitUntilFocusedSession("Beta"))
    }

    // MARK: - New Session

    /// ⌘N presents the connection list in the FOCUSED terminal window —
    /// the same sheet the session menu's New Session opens (`list-done`
    /// exists only inside that sheet).
    func testNewSessionCommandPresentsConnectionListInFocusedWindow() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Keyboard-command scenarios require the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntilFocusedSession("Alpha"))

        XCTAssertTrue(tapSeamButton("cmd-new"), "new-session command never fired")
        XCTAssertTrue(
            app.buttons["list-done"].waitForExistence(timeout: 15),
            "New Session must present the connection list sheet in the focused window"
        )
        app.buttons["list-done"].tap()
    }

    // MARK: - Settings

    /// ⌘, opens the independent Settings window WITHOUT any terminal
    /// session action: the focused-terminal target is retired while
    /// Settings holds focus (commands no-op there — model-pinned in
    /// TerminalCommandsTests), and the terminal session is untouched.
    func testSettingsCommandOpensSettingsWindowAndClearsTerminalFocus() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Keyboard-command scenarios require the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntilFocusedSession("Alpha"))

        XCTAssertTrue(tapSeamButton("cmd-settings"), "settings command never fired")
        let settingsView = app.descendants(matching: .any)["settingsView"]
        XCTAssertTrue(settingsView.waitForExistence(timeout: 15), "Settings never appeared")

        // The Settings window took focus: the terminal scene went
        // background, so no terminal scene owns the command target.
        XCTAssertTrue(
            waitUntilFocusedSession("none", timeout: 30),
            "the focused-terminal target must be retired while Settings holds focus"
        )
        XCTAssertFalse(
            app.buttons["scene-confirm-close"].exists,
            "Settings must never trigger a terminal close"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Alpha"], contains: "status:active", timeout: 30),
            "the terminal session must be untouched by opening Settings: "
                + label(of: app.staticTexts["scene-status-Alpha"])
        )

        // Suite hygiene: iPadOS restores the last-active scene, and the
        // Settings scene is the only one that does not fall back to the
        // connection list — destroy the scene session so later launches
        // (this suite and others) restore the connection list again.
        app.terminate()
        app.launchArguments = ["--uitest-open-settings-scene", "--uitest-dismiss-settings-scene"]
        app.launch()
        app.terminate()
    }
}
