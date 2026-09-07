import UIKit
import XCTest

/// Plan T2: concurrent sessions with detach-without-close and the session
/// switcher — switching keeps detached sessions alive (receiving output,
/// unread dot), close still goes through the confirmation guard, the
/// terminal view cache preserves scrollback up to its bound, and eviction
/// surfaces the scrollback-released notice. Runs against the real fixture
/// sshd instances (hop1=12222, hop2=12223).
@MainActor
final class SessionSwitcherUITests: XCTestCase {
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

    private func baseLaunchArguments(
        command: String? = nil,
        extra: [String] = []
    ) -> [String] {
        var arguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
        ]
        if let command {
            arguments += ["--uitest-session-command", command]
        }
        arguments += extra
        return arguments
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

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && element.exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !element.exists
    }

    /// Several windows may each carry a Sessions button (iPad multi-window)
    /// — tap whichever is actually hittable (the frontmost window's).
    @discardableResult
    private func openSwitcher(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = app.buttons.matching(identifier: "scene-sessions")
            for index in 0..<candidates.count where candidates.element(boundBy: index).isHittable {
                candidates.element(boundBy: index).tap()
                if app.buttons["switcher-new-connection"].waitForExistence(timeout: 10) {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func attachViaSwitcher(key: String) {
        let row = app.staticTexts["switcher-name-\(key)"]
        XCTAssertTrue(
            scrollToHittable(row, timeout: 15),
            "switcher row \(key) never became reachable"
        )
        row.tap()
    }

    /// Lazy List rows off-screen do not exist in the AX tree — swipe the
    /// switcher sheet up until the row is present and hittable.
    @discardableResult
    private func scrollToHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .fast)
        }
        return element.exists && element.isHittable
    }

    // MARK: - Switcher listing

    /// The switcher lists every live session with a state badge and marks
    /// the session currently attached in this window.
    func testSwitcherListsLiveSessionsWithStateBadgesAndCurrentMarker() {
        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(
            app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60),
            "last-opened session never attached (cover)"
        )
        XCTAssertTrue(openSwitcher(), "Sessions button must open the switcher")

        XCTAssertTrue(app.staticTexts["switcher-name-Alpha-1"].exists)
        XCTAssertTrue(app.staticTexts["switcher-name-Beta-1"].exists)
        XCTAssertTrue(
            waitUntil(app.staticTexts["switcher-state-Alpha-1"], contains: "connected", timeout: 45),
            "Alpha badge: \(label(of: app.staticTexts["switcher-state-Alpha-1"]))"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["switcher-state-Beta-1"], contains: "connected", timeout: 45),
            "Beta badge: \(label(of: app.staticTexts["switcher-state-Beta-1"]))"
        )
        XCTAssertTrue(
            app.staticTexts["switcher-current-Beta-1"].exists,
            "the cover's session must be marked Current"
        )
        XCTAssertFalse(
            app.staticTexts["switcher-current-Alpha-1"].exists,
            "only the presented session may carry the Current marker"
        )

        app.buttons["switcher-done"].tap()
        XCTAssertTrue(
            app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 10),
            "dismiss must re-show the still-attached session"
        )
    }

    // MARK: - Detach-without-close

    /// Brings the app to a state where ALPHA is live but detached: iPhone
    /// presents the next session as the cover (detaching Alpha), iPad
    /// switches Alpha's window content to Beta in place (windows stay
    /// open, so presenting alone would keep Alpha attached).
    private func prepareDetachedAlpha() {
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(
                app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60),
                "Beta (last presented) never attached"
            )
            return
        }
        XCTAssertTrue(
            app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60),
            "Alpha window never attached"
        )
        XCTAssertTrue(openSwitcher(), "switcher must open for the in-window switch")
        attachViaSwitcher(key: "Beta-1")
        XCTAssertTrue(
            app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 15),
            "in-window switch to Beta never attached"
        )
    }

    private func detachFlowLaunchArguments(markerPrefix: String) -> [String] {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return baseLaunchArguments(
                command: "(sleep 12; echo \(markerPrefix)_{NAME}__) &",
                extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
            )
        }
        return baseLaunchArguments(
            command: "(sleep 12; echo \(markerPrefix)_{NAME}__) &",
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session-detached", "Beta"]
        )
    }

    /// Switching away never closes a session: the detached session keeps
    /// receiving output (unread dot), and re-attaching shows that output.
    func testSwitchKeepsDetachedSessionAliveAndReceivingOutput() {
        app.launchArguments = detachFlowLaunchArguments(markerPrefix: "__DETACHED")
        app.launch()

        prepareDetachedAlpha()

        XCTAssertTrue(openSwitcher(), "Sessions button must open the switcher")
        let alphaUnread = app.staticTexts["switcher-unread-Alpha-1"]
        XCTAssertTrue(
            alphaUnread.waitForExistence(timeout: 45),
            "detached Alpha never showed its unread dot"
        )

        attachViaSwitcher(key: "Alpha-1")

        let alphaStatus = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(alphaStatus.waitForExistence(timeout: 15), "switching must attach Alpha in place")
        XCTAssertTrue(
            waitUntil(alphaStatus, contains: "status:active", timeout: 45),
            "detached Alpha must still be an active session: \(label(of: alphaStatus))"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-tail-Alpha"], contains: "__DETACHED_Alpha__", timeout: 30),
            "output produced while detached must be present after re-attach: "
                + label(of: app.staticTexts["scene-tail-Alpha"])
        )
    }

    /// The unread dot disappears once the session is attached again.
    func testUnreadDotClearsOnReattach() {
        app.launchArguments = detachFlowLaunchArguments(markerPrefix: "__LATER")
        app.launch()

        prepareDetachedAlpha()

        XCTAssertTrue(openSwitcher())
        XCTAssertTrue(
            app.staticTexts["switcher-unread-Alpha-1"].waitForExistence(timeout: 45),
            "detached Alpha never showed its unread dot"
        )

        attachViaSwitcher(key: "Alpha-1")
        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 15))

        XCTAssertTrue(openSwitcher())
        XCTAssertTrue(
            waitForGone(app.staticTexts["switcher-unread-Alpha-1"], timeout: 10),
            "attached session must not keep the unread dot"
        )
    }

    // MARK: - Close guard

    /// Closing from the switcher reuses the close-confirmation guard:
    /// Cancel keeps the session; Disconnect terminates it and removes the
    /// row.
    func testCloseFromSwitcherRequiresConfirmationGuard() {
        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSwitcher())

        let confirm = app.buttons["switcher-confirm-close"]
        let alphaRow = app.staticTexts["switcher-name-Alpha-1"]

        app.buttons["switcher-close-Alpha-1"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "live-session close must confirm first")

        // iOS 26 confirmation dialogs drop Cancel-role buttons from the AX
        // tree entirely — cancel by tapping outside the dialog.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(waitForGone(confirm, timeout: 10), "Cancel must dismiss the guard")
        XCTAssertTrue(alphaRow.exists, "Cancel must keep the session listed")

        app.buttons["switcher-close-Alpha-1"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        // The dialog button is mirrored twice in the AX tree on this OS.
        confirm.firstMatch.tap()

        XCTAssertTrue(
            waitForGone(alphaRow, timeout: 20),
            "confirmed close must remove the session from the switcher"
        )
        XCTAssertTrue(
            app.staticTexts["switcher-name-Beta-1"].exists,
            "the other session must be untouched"
        )
    }

    // MARK: - New connection

    /// "New connection…" dismisses the terminal surface back to the
    /// connection list WITHOUT closing the live session — the session is
    /// still listed and connected afterwards.
    func testNewConnectionRowReturnsToListWithoutClosingSession() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSwitcher(), "Sessions button must open the switcher")

        app.buttons["switcher-new-connection"].tap()

        if UIDevice.current.userInterfaceIdiom == .phone {
            // The cover popped to the MAIN list — its Sessions button
            // re-opens the switcher.
            XCTAssertTrue(
                app.buttons["add-connection"].waitForExistence(timeout: 15),
                "New connection… must return to the connection list"
            )
            app.buttons["open-sessions"].tap()
        } else {
            // iPad: the list presented as a sheet in the terminal window.
            // `list-done` exists ONLY in that sheet (the main window's own
            // list always contributes `add-connection`), so it is the
            // truthful sheet-presence/dismissal probe.
            XCTAssertTrue(
                app.buttons["list-done"].waitForExistence(timeout: 15),
                "New connection… must present the connection list sheet"
            )
            app.buttons["list-done"].tap()
            XCTAssertTrue(
                waitForGone(app.buttons["list-done"], timeout: 10),
                "list sheet must dismiss"
            )
            XCTAssertTrue(openSwitcher())
        }
        XCTAssertTrue(app.buttons["switcher-new-connection"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            waitUntil(app.staticTexts["switcher-state-Alpha-1"], contains: "connected", timeout: 30),
            "session must still be alive after dismissing its surface: "
                + label(of: app.staticTexts["switcher-state-Alpha-1"])
        )
    }

    // MARK: - Eviction

    /// The terminal view cache is bounded: after attaching 9 sessions in
    /// one window, the oldest was evicted — re-attaching it shows the
    /// one-line scrollback-released notice.
    func testEvictedSurfaceReattachShowsScrollbackReleasedNotice() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "Nine-cover attach loop runs on the phone form factor"
        )

        var extra = [String]()
        for _ in 0..<9 {
            extra += ["--uitest-open-session-detached", "Alpha"]
        }
        app.launchArguments = baseLaunchArguments(extra: extra)
        app.launch()

        XCTAssertTrue(
            app.buttons["open-sessions"].waitForExistence(timeout: 30),
            "connection list must be reachable (no cover was presented)"
        )

        // Attach all nine sessions through the list-side switcher: each
        // pick presents the session as the cover, bumping cache recency.
        app.buttons["open-sessions"].tap()
        XCTAssertTrue(app.buttons["switcher-new-connection"].waitForExistence(timeout: 15))
        attachViaSwitcher(key: "Alpha-1")
        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 30))

        for index in 2...9 {
            XCTAssertTrue(openSwitcher(), "switcher failed to open before attaching Alpha-\(index)")
            attachViaSwitcher(key: "Alpha-\(index)")
            XCTAssertTrue(
                app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 30),
                "attach \(index) never presented the scene"
            )
        }

        // Cache capacity is 8: Alpha-1 (LRU) was evicted. Re-attaching it
        // builds a fresh surface and flags the released scrollback.
        XCTAssertTrue(openSwitcher())
        attachViaSwitcher(key: "Alpha-1")
        XCTAssertTrue(
            app.staticTexts["scene-scrollback-released-Alpha"].waitForExistence(timeout: 15),
            "re-attaching an evicted session must show the scrollback-released notice"
        )
    }

    // MARK: - iPad in-window switching

    /// iPad keeps multi-window AND gains in-window switching: picking a
    /// detached session from a terminal window's switcher attaches it in
    /// THAT window — no new window, and the originally shown session keeps
    /// running.
    func testPadSwitcherAttachesDetachedSessionInPlaceWithoutNewWindow() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "In-window switching scenario requires the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session-detached", "Beta"]
        )
        app.launch()

        XCTAssertTrue(
            app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60),
            "presented Alpha window never appeared"
        )

        XCTAssertTrue(openSwitcher(), "terminal window must expose the switcher")
        XCTAssertTrue(app.staticTexts["switcher-name-Alpha-1"].exists)
        XCTAssertTrue(app.staticTexts["switcher-name-Beta-1"].exists)

        attachViaSwitcher(key: "Beta-1")

        let betaStatus = app.staticTexts["scene-status-Beta"]
        XCTAssertTrue(betaStatus.waitForExistence(timeout: 15), "Beta must attach in this window")
        XCTAssertTrue(
            waitUntil(betaStatus, contains: "status:active", timeout: 45),
            "detached-opened Beta must already be active: \(label(of: betaStatus))"
        )

        XCTAssertTrue(openSwitcher())
        XCTAssertTrue(
            app.staticTexts["switcher-current-Beta-1"].exists,
            "Beta must now be the window's current session"
        )
        XCTAssertTrue(
            app.staticTexts["switcher-name-Alpha-1"].exists,
            "switched-away Alpha must still be listed (never auto-closed)"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["switcher-state-Alpha-1"], contains: "connected", timeout: 30),
            "switched-away Alpha must still be connected: "
                + label(of: app.staticTexts["switcher-state-Alpha-1"])
        )
    }

    /// "New connection…" inside a terminal window presents the connection
    /// list as a sheet in that window. `list-done` only exists inside that
    /// sheet, so it proves the sheet (not the main window's list) appeared.
    func testPadNewConnectionRowPresentsConnectionListSheet() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Terminal-window list sheet scenario requires the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSwitcher())

        app.buttons["switcher-new-connection"].tap()
        XCTAssertTrue(
            app.buttons["list-done"].waitForExistence(timeout: 15),
            "New connection… must present the connection list in this window"
        )
    }
}
