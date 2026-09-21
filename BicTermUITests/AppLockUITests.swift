import UIKit
import XCTest

/// T10/T11 manual-QA channel for the app-lock policy and the per-scene
/// privacy covers, driven through the DEBUG pended fake
/// owner-authentication client (real LAContext cannot run in simulator
/// tests). Exercises the production `AppLockState` code path and the
/// covers end-to-end: real background/foreground lifecycle transitions,
/// cover-before-auth (the cover's Unlock button is the single unlock
/// path — nothing starts until it is tapped), unlock, relock,
/// stale-completion rejection after a relock, and cross-window cover
/// behavior.
@MainActor
final class AppLockUITests: XCTestCase {
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

    @discardableResult
    private func waitUntilStatus(
        _ status: XCUIElement,
        contains marker: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status.label.contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return status.label.contains(marker)
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// Real background transition (springboard) then foreground return —
    /// the same lifecycle path a user's swipe-home produces.
    private func backgroundThenForeground() {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        Thread.sleep(forTimeInterval: 2)
        app.activate()
    }

    /// The cover's Unlock button in the FOREGROUND window — background
    /// windows' covers exist in the element tree but are not hittable.
    private func foregroundUnlockButton() -> XCUIElement? {
        app.buttons.matching(identifier: "applock-cover-unlock")
            .allElementsBoundByIndex
            .first { $0.isHittable }
    }

    /// Waits for the foreground window's cover — the cover renders a
    /// moment after the foreground return; a single immediate probe
    /// races it.
    private func waitUntilForegroundCover(timeout: TimeInterval = 15) -> XCUIElement? {
        let appeared = waitUntil(timeout: timeout) { foregroundUnlockButton() != nil }
        return appeared ? foregroundUnlockButton() : nil
    }

    // MARK: - Single window

    func testCoverBeforeAuthUnlockRelockAndStaleRejection() {
        app.launchArguments = [
            AppLockUITestSeamLaunchArguments.pend,
            AppLockUITestSeamLaunchArguments.enable,
            // Deterministic scene state: the session driver clears
            // snapshots so every restored window resolves to the
            // connection list, and the Settings-scene dismisser guards
            // against a restored Settings window.
            "--uitest-sessions",
            "--uitest-dismiss-settings-scene",
        ]
        app.launch()

        let status = app.staticTexts["applock-status"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 30),
            "the app-lock test overlay must appear at launch"
        )

        // Enabled at bootstrap, not yet locked (the user is present) —
        // no cover while unlocked.
        XCTAssertTrue(waitUntilStatus(status, contains: "enabled:1", timeout: 10))
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 5))
        let content = app.collectionViews["connectionList"].firstMatch
        XCTAssertTrue(
            content.waitForExistence(timeout: 30),
            "the connection list must appear while unlocked"
        )
        XCTAssertFalse(
            app.buttons["applock-cover-unlock"].firstMatch.exists,
            "no cover while unlocked"
        )

        // True background transition: relock, generation advances, and
        // the cover is up BEFORE any authentication — with the
        // auto-trigger removed, nothing starts until the Unlock tap.
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:1", timeout: 5))
        let unlock = waitUntilForegroundCover()
        XCTAssertNotNil(unlock, "the foreground window's cover must appear on relock")
        XCTAssertTrue(
            waitUntilStatus(status, contains: "auth:idle", timeout: 5),
            "no authentication may start before the cover's Unlock tap"
        )
        XCTAssertFalse(content.isHittable, "covered content must not be hittable")

        // Unlock via the cover's button; the fake client pends it. The
        // cover stays (and content stays unreachable) while it pends.
        unlock!.tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))
        XCTAssertNotNil(
            foregroundUnlockButton(),
            "the cover must stay while authentication pends"
        )
        XCTAssertFalse(
            content.isHittable,
            "covered content stays unreachable during authentication"
        )

        // Release success: unlocked, cover gone.
        app.buttons["applock-release-success"].tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 10))
        XCTAssertTrue(
            waitUntil { !app.buttons["applock-cover-unlock"].firstMatch.exists },
            "the cover must clear on unlock"
        )

        // Relock: a second background transition engages the lock again.
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:2", timeout: 5))
        XCTAssertNotNil(waitUntilForegroundCover(), "the cover must return on relock")

        // Background AGAIN while the sheet pends: the in-flight attempt
        // is stale (generation 3 now owns the UI) and a fresh attempt
        // starts on return.
        let relockUnlock = waitUntilForegroundCover()
        relockUnlock?.tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:3", timeout: 5))
        let freshUnlock = waitUntilForegroundCover()
        freshUnlock?.tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))

        // Release resolves the OLDEST pended attempt — the stale one. It
        // must be rejected: the cover stays engaged.
        app.buttons["applock-release-success"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(
            status.label.contains("locked:0"),
            "a stale authentication completion must not unlock"
        )
        XCTAssertTrue(status.label.contains("locked:1"))
        XCTAssertNotNil(
            foregroundUnlockButton(),
            "the cover must survive a stale release"
        )

        // The CURRENT-generation attempt still unlocks when released.
        app.buttons["applock-release-success"].tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 10))
        XCTAssertTrue(
            waitUntil { !app.buttons["applock-cover-unlock"].firstMatch.exists },
            "the cover must clear on the current-generation unlock"
        )
    }

    // MARK: - Two windows

    /// iPad: two terminal windows (Alpha + Beta) both lock on one
    /// background transition — every window carries a cover — and ONE
    /// unlock clears them all.
    func testTwoWindowsBothCoveredAndClearOnOneUnlock() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Two-window scenario requires the iPad form factor"
        )

        app.launchArguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
            "--uitest-open-session", "Beta",
            AppLockUITestSeamLaunchArguments.pend,
            AppLockUITestSeamLaunchArguments.enable,
        ]
        app.launch()

        // Both terminal windows host live sessions.
        let alphaTail = app.staticTexts["scene-tail-Alpha"]
        let betaTail = app.staticTexts["scene-tail-Beta"]
        XCTAssertTrue(alphaTail.waitForExistence(timeout: 60), "Alpha scene never appeared")
        XCTAssertTrue(betaTail.waitForExistence(timeout: 60), "Beta scene never appeared")

        let status = app.staticTexts["applock-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 10))
        XCTAssertFalse(
            app.buttons["applock-cover-unlock"].firstMatch.exists,
            "no cover while unlocked"
        )

        // The foreground window's terminal content is reachable before
        // the lock (the covered sibling window's is not — iPad keeps
        // only the focused window hittable).
        let foregroundTail = [alphaTail, betaTail].first { $0.isHittable }
        XCTAssertNotNil(foregroundTail, "one terminal window must be foreground")

        // Background: both windows lock.
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))

        // Both session windows carry a cover (the connection-list main
        // window may add one more — every window must be covered).
        let covers = app.buttons.matching(identifier: "applock-cover-unlock")
        XCTAssertTrue(
            waitUntil(timeout: 15) { covers.count >= 2 },
            "expected a cover on each window (at least the two session windows), found \(covers.count)"
        )

        // One unlock clears EVERY cover.
        let unlock = waitUntilForegroundCover()
        XCTAssertNotNil(unlock, "the foreground window's cover must be hittable")
        unlock!.tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))
        app.buttons["applock-release-success"].tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 10))
        XCTAssertTrue(
            waitUntil(timeout: 15) { covers.count == 0 },
            "every cover must clear on one unlock"
        )
        XCTAssertTrue(
            waitUntil { foregroundTail!.isHittable },
            "the foreground terminal content must be reachable again"
        )
    }
}

/// Launch-argument constants mirrored from the app-side DEBUG seam (the
/// UI-test target cannot import the app module).
enum AppLockUITestSeamLaunchArguments {
    static let pend = "--uitest-applock-pend"
    static let enable = "--uitest-applock-enable"
}
