import UIKit
import XCTest

/// The session scene's top-right chrome is exactly TWO controls — the
/// session menu (ellipsis) and Close — after the keyboard and sessions
/// buttons were absorbed into the menu. Covers menu contents, the toolbar
/// toggle's live On/Off state, New Session reachability, the Sessions
/// submenu (live rows, jump semantics per form factor), Manage Sessions…,
/// and Settings (sheet on iPhone, its own window on iPad). Runs against
/// the real fixture sshd instances (hop1=12222, hop2=12223).
@MainActor
final class SessionMenuUITests: XCTestCase {
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

    /// Several windows may each carry a session menu (iPad multi-window) —
    /// tap whichever is actually hittable (the frontmost window's).
    /// Re-tapping the menu button closes an already-open menu, so the loop
    /// converges after failed attempts.
    @discardableResult
    private func openSessionMenu(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = app.buttons.matching(identifier: "scene-menu")
            for index in 0..<candidates.count where candidates.element(boundBy: index).isHittable {
                candidates.element(boundBy: index).tap()
                if app.buttons["scene-sessions"].waitForExistence(timeout: 5) {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @discardableResult
    private func openSessionsSubmenu(timeout: TimeInterval = 15) -> Bool {
        guard openSessionMenu(timeout: timeout) else { return false }
        app.buttons["scene-sessions"].tap()
        return app.buttons["scene-manage-sessions"].waitForExistence(timeout: 5)
    }

    // MARK: - Chrome shape

    /// Exactly two top-right chrome controls: the session menu and Close.
    /// The absorbed buttons (toolbar toggle, sessions) must NOT exist in
    /// the AX tree while the menu is closed.
    func testChromeShowsExactlyMenuAndClose() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        let menu = app.buttons["scene-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 60), "session menu never appeared")
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(app.buttons["scene-close-Alpha"].exists, "Close must stay in the chrome")
        XCTAssertFalse(app.buttons["terminal-toolbar-toggle"].exists)
        XCTAssertFalse(app.buttons["scene-sessions"].exists)
    }

    /// The menu lists, in order: toolbar toggle (with On/Off state),
    /// Sessions submenu, New Session, Settings.
    func testMenuListsAllItems() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(openSessionMenu(), "session menu never opened")
        XCTAssertTrue(app.buttons["terminal-toolbar-toggle"].exists)
        XCTAssertTrue(
            label(of: app.buttons["terminal-toolbar-toggle"]).hasPrefix("Terminal Toolbar: "),
            "toggle item must show its On/Off state: \(label(of: app.buttons["terminal-toolbar-toggle"]))"
        )
        XCTAssertTrue(app.buttons["scene-sessions"].exists)
        XCTAssertTrue(app.buttons["scene-new-session"].exists)
        XCTAssertTrue(app.buttons["session-appearance-theme"].exists)
        XCTAssertTrue(app.buttons["session-appearance-font"].exists)
        XCTAssertTrue(app.buttons["session-appearance-margin"].exists)
        XCTAssertTrue(app.buttons["scene-settings"].exists)
    }

    func testAppearanceOverridesReflowAndReset() throws {
        app.launchArguments = baseLaunchArguments(
            command: "last=; while :; do size=$(stty size); if [ \"$size\" != \"$last\" ]; then printf 'SZ:%s\\n' \"$size\"; last=$size; fi; sleep 1; done",
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session-detached", "Beta"]
        )
        app.launch()
        let appearance = app.staticTexts["scene-appearance-Alpha"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(appearance, contains: "font:14.0", timeout: 10))
        let initialSize = try remoteSize("Alpha")

        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-font"].tap()
        app.buttons["session-font-increase"].tap()
        XCTAssertTrue(waitUntil(appearance, contains: "font:14.5", timeout: 10))
        let resizeDeadline = Date().addingTimeInterval(15)
        var resized = try remoteSize("Alpha")
        while resized == initialSize, Date() < resizeDeadline {
            Thread.sleep(forTimeInterval: 1)
            resized = try remoteSize("Alpha")
        }
        XCTAssertNotEqual(resized, initialSize)

        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-theme"].tap()
        app.buttons["session-theme-dark"].tap()
        XCTAssertTrue(waitUntil(appearance, contains: "theme:dark", timeout: 10))
        capture("appearance-dark-terminal")
        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-margin"].tap()
        app.buttons["session-margin-20"].tap()
        XCTAssertTrue(waitUntil(appearance, contains: "margin:20.0", timeout: 10))

        XCTAssertTrue(openSessionsSubmenu())
        app.buttons["menu-session-Beta-1"].tap()
        let beta = app.staticTexts["scene-appearance-Beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(beta, contains: "font:14.0", timeout: 10))
        XCTAssertTrue(label(of: beta).contains("margin:5.0"))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(label(of: appearance).contains("font:14.5"))
        }
        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-theme"].tap()
        app.buttons["session-theme-light"].tap()
        XCTAssertTrue(waitUntil(beta, contains: "theme:light", timeout: 10))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(label(of: appearance).contains("theme:dark"))
        }
        XCTAssertTrue(openSessionsSubmenu())
        app.buttons["menu-session-Alpha-1"].tap()
        for property in ["font", "theme", "margin"] {
            XCTAssertTrue(openSessionMenu())
            app.buttons["session-appearance-\(property)"].tap()
            app.buttons["session-\(property)-global"].tap()
        }
        XCTAssertTrue(waitUntil(appearance, contains: "font:14.0", timeout: 10))
        XCTAssertTrue(waitUntil(appearance, contains: "margin:5.0", timeout: 10))
        XCTAssertTrue(openSessionMenu())
        XCTAssertTrue(label(of: app.buttons["session-appearance-theme"]).contains("Global"))
        XCTAssertTrue(label(of: app.buttons["session-appearance-font"]).contains("Global"))
        XCTAssertTrue(label(of: app.buttons["session-appearance-margin"]).contains("Global"))
        capture("appearance-menu-global")
    }

    func testFontSliderSheetInheritsSessionTheme() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()
        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-theme"].tap()
        app.buttons["session-theme-dark"].tap()
        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-font"].tap()
        app.buttons["session-font-adjust"].tap()
        let slider = app.sliders["session-font-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        capture("appearance-dark-font-sheet")
        app.buttons["Reset to Global"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitUntil(app.staticTexts["scene-appearance-Alpha"], contains: "font:14.0", timeout: 10))
    }

    func testSystemOverrideSupersedesPinnedGlobalTheme() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()
        let appearance = app.staticTexts["scene-appearance-Alpha"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 60))
        let systemTheme = label(of: appearance).contains("theme:dark") ? "dark" : "light"
        let globalTheme = systemTheme == "dark" ? "light" : "dark"
        app.terminate()
        app.launchArguments = baseLaunchArguments(extra: [
            "--uitest-open-session", "Alpha", "--uitest-keep-theme-pref",
            "-bicterm.appearance.theme", globalTheme,
        ])
        app.launch()
        XCTAssertTrue(appearance.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(appearance, contains: "theme:\(globalTheme)", timeout: 10))
        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-theme"].tap()
        app.buttons["session-theme-system"].tap()
        XCTAssertTrue(waitUntil(appearance, contains: "theme:\(systemTheme)", timeout: 10))
        XCTAssertTrue(openSessionMenu())
        app.buttons["session-appearance-theme"].tap()
        app.buttons["session-theme-global"].tap()
        XCTAssertTrue(waitUntil(appearance, contains: "theme:\(globalTheme)", timeout: 10))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func remoteSize(_ name: String) throws -> String {
        let tail = app.staticTexts["scene-tail-\(name)"]
        XCTAssertTrue(waitUntil(tail, contains: "SZ:", timeout: 30))
        let matches = try NSRegularExpression(pattern: "SZ:[0-9]+ [0-9]+")
        let text = label(of: tail)
        let match = try XCTUnwrap(matches.matches(in: text, range: NSRange(text.startIndex..., in: text)).last)
        let range = try XCTUnwrap(Range(match.range, in: text))
        return String(text[range])
    }

    // MARK: - Toolbar toggle

    /// The toggle item's On/Off state tracks the strip's actual visibility
    /// and flipping it from the menu flips the strip.
    func testToolbarToggleItemStateTracksAndFlipsStrip() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        let accessory = app.descendants(matching: .any)["terminal-accessory"]
        let wasVisible = accessory.exists

        XCTAssertTrue(openSessionMenu())
        let toggle = app.buttons["terminal-toolbar-toggle"]
        XCTAssertTrue(
            label(of: toggle).contains(wasVisible ? "On" : "Off"),
            "menu state must match the strip: \(label(of: toggle)) vs strip visible=\(wasVisible)"
        )
        toggle.tap()

        if wasVisible {
            XCTAssertTrue(accessory.waitForNonExistence(timeout: 10), "strip must hide")
        } else {
            XCTAssertTrue(accessory.waitForExistence(timeout: 10), "strip must show")
        }

        XCTAssertTrue(openSessionMenu())
        XCTAssertTrue(
            label(of: toggle).contains(wasVisible ? "Off" : "On"),
            "menu state must flip with the strip: \(label(of: toggle))"
        )
    }

    // MARK: - New Session

    /// New Session routes to the connection list: on iPhone the cover pops
    /// back to the list; on iPad the list presents as a sheet in the
    /// terminal window (`list-done` exists only inside that sheet).
    func testNewSessionFromMenuReachesConnectionList() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSessionMenu())
        app.buttons["scene-new-session"].tap()

        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(
                app.buttons["add-connection"].waitForExistence(timeout: 15),
                "New Session must return to the connection list"
            )
        } else {
            XCTAssertTrue(
                app.buttons["list-done"].waitForExistence(timeout: 15),
                "New Session must present the connection list sheet in this window"
            )
            app.buttons["list-done"].tap()
        }
    }

    // MARK: - Sessions submenu

    /// The submenu lists every live session with a state line; the session
    /// attached in the menu's own scene is the (disabled) current marker.
    /// (iOS flattens each menu item into one AX element, so name and state
    /// are asserted on the row button's flattened label.)
    func testSessionsSubmenuListsLiveSessionsWithStateAndCurrent() {
        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSessionsSubmenu(), "Sessions submenu never opened")

        let alphaRow = app.buttons["menu-session-Alpha-1"]
        let betaRow = app.buttons["menu-session-Beta-1"]
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5), "Alpha row missing")
        XCTAssertTrue(betaRow.exists, "Beta row missing")

        XCTAssertTrue(
            waitUntil(alphaRow, contains: "connected", timeout: 45),
            "Alpha state: \(label(of: alphaRow))"
        )
        XCTAssertTrue(
            waitUntil(betaRow, contains: "connected", timeout: 45),
            "Beta state: \(label(of: betaRow))"
        )

        // Whichever scene's menu we opened marks its own session current:
        // exactly one row is disabled, and its state line says so.
        XCTAssertNotEqual(
            alphaRow.isEnabled, betaRow.isEnabled,
            "exactly one row must be the disabled current marker"
        )
        let currentRow = alphaRow.isEnabled ? betaRow : alphaRow
        XCTAssertTrue(
            label(of: currentRow).contains("current"),
            "current row must say so: \(label(of: currentRow))"
        )
    }

    /// iPhone jump: tapping another session's row activates it in the
    /// current scene (the switcher sheet's code path).
    func testPhoneJumpActivatesSessionInCurrentScene() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "In-scene activation scenario runs on the phone form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSessionsSubmenu(), "Sessions submenu never opened")

        app.buttons["menu-session-Alpha-1"].tap()

        XCTAssertTrue(
            app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 15),
            "jumping to Alpha must attach it in this scene"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Alpha"], contains: "status:active", timeout: 45),
            "Alpha must still be active after the jump"
        )
    }

    /// iPad jump to a DETACHED session: the session gets its own window —
    /// a new window appears hosting it, and the session is active there.
    func testPadJumpToDetachedSessionOpensItsWindow() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Window-jump scenario requires the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session-detached", "Beta"]
        )
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Beta").count, 0,
            "detached Beta must not have a window before the jump"
        )

        XCTAssertTrue(openSessionsSubmenu(), "Sessions submenu never opened")
        app.buttons["menu-session-Beta-1"].tap()

        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Beta").count, 1,
            "the jump must give detached Beta its own window"
        )
        XCTAssertTrue(
            waitUntil(app.staticTexts["scene-status-Beta"], contains: "status:active", timeout: 45),
            "Beta must be active in its new window"
        )
        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Alpha").count, 1,
            "Alpha's window must be untouched"
        )
    }

    /// iPad jump to a HOSTED session: the already-open window hosting it
    /// is focused — no duplicate window is created for that session.
    /// (XCUI cannot observe window z-order, so the assertion is the
    /// structural guarantee: one window per session, both intact.)
    func testPadJumpToHostedSessionFocusesWithoutDuplicateWindow() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Window-jump scenario requires the iPad form factor"
        )

        app.launchArguments = baseLaunchArguments(
            extra: ["--uitest-open-session", "Alpha", "--uitest-open-session", "Beta"]
        )
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["scene-status-Beta"].waitForExistence(timeout: 60))

        XCTAssertTrue(openSessionsSubmenu(), "Sessions submenu never opened")

        // Tap whichever row is NOT the current marker: from Beta's window
        // menu that is Alpha (focus Alpha's window), from Alpha's that is
        // Beta — either way a cross-window jump.
        let alphaRow = app.buttons["menu-session-Alpha-1"]
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5))
        if alphaRow.isEnabled {
            alphaRow.tap()
        } else {
            app.buttons["menu-session-Beta-1"].tap()
        }

        // Let any (incorrect) duplicate window have time to appear.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Alpha").count, 1,
            "the jump must focus the existing window, never open a duplicate"
        )
        XCTAssertEqual(
            app.windows.containing(.staticText, identifier: "scene-title-Beta").count, 1,
            "the jump must focus the existing window, never open a duplicate"
        )
    }

    // MARK: - Manage Sessions…

    /// Manage Sessions… opens the existing switcher sheet, fully
    /// functional (New connection row, live sessions, Done).
    func testManageSessionsOpensSwitcherSheet() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSessionsSubmenu(), "Sessions submenu never opened")
        app.buttons["scene-manage-sessions"].tap()

        XCTAssertTrue(
            app.buttons["switcher-new-connection"].waitForExistence(timeout: 10),
            "Manage Sessions… must open the switcher sheet"
        )
        XCTAssertTrue(app.staticTexts["switcher-name-Alpha-1"].exists)

        app.buttons["switcher-done"].tap()
        XCTAssertTrue(
            app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 10),
            "dismissing the switcher must return to the scene"
        )
    }

    // MARK: - Settings

    /// Settings…: iPhone presents the settings page as a sheet (dismissed
    /// by Done); iPad opens it in ANOTHER window — the settings view must
    /// not live in the terminal window.
    func testSettingsFromMenu() {
        app.launchArguments = baseLaunchArguments(extra: ["--uitest-open-session", "Alpha"])
        app.launch()

        XCTAssertTrue(app.staticTexts["scene-status-Alpha"].waitForExistence(timeout: 60))
        XCTAssertTrue(openSessionMenu(), "session menu never opened")
        app.buttons["scene-settings"].tap()

        let settingsView = app.descendants(matching: .any)["settingsView"]
        XCTAssertTrue(settingsView.waitForExistence(timeout: 15), "Settings never appeared")
        XCTAssertTrue(app.buttons["settings-margins"].exists)
        capture("appearance-global-settings")

        if UIDevice.current.userInterfaceIdiom == .phone {
            app.buttons["menu-settings-done"].tap()
            XCTAssertTrue(
                settingsView.waitForNonExistence(timeout: 10),
                "Done must dismiss the settings sheet"
            )
        } else {
            let alphaWindow = app.windows.containing(.staticText, identifier: "scene-title-Alpha")
            XCTAssertEqual(alphaWindow.count, 1)
            XCTAssertFalse(
                alphaWindow.firstMatch.descendants(matching: .any)["settingsView"].exists,
                "on iPad Settings must open in ANOTHER window, not the terminal window"
            )
        }
    }
}
