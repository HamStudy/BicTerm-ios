import UIKit
import XCTest

/// T10 manual-QA channel for the app-lock policy, driven through the
/// DEBUG pended fake owner-authentication client (real LAContext cannot
/// run in simulator tests). Exercises the production `AppLockState` code
/// path end-to-end: real background/foreground lifecycle transitions,
/// relock, pended unlock, and stale-completion rejection after a relock.
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

    /// Real background transition (springboard) then foreground return —
    /// the same lifecycle path a user's swipe-home produces.
    private func backgroundThenForeground() {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        Thread.sleep(forTimeInterval: 2)
        app.activate()
    }

    // MARK: - Test

    func testPendedUnlockRelockAndStaleRejection() {
        app.launchArguments = [
            AppLockUITestSeamLaunchArguments.pend,
            AppLockUITestSeamLaunchArguments.enable,
        ]
        app.launch()

        let status = app.staticTexts["applock-status"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 30),
            "the app-lock test overlay must appear at launch"
        )

        // Enabled at bootstrap, not yet locked (the user is present).
        XCTAssertTrue(waitUntilStatus(status, contains: "enabled:1", timeout: 10))
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 5))

        // True background transition: relock, generation advances.
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:1", timeout: 5))

        // The unlock stand-in auto-requests authentication; the fake client
        // pends it.
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))

        // Release success: unlocked, same generation observed.
        app.buttons["applock-release-success"].tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 10))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:1", timeout: 5))

        // Relock: a second background transition engages the lock again.
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:2", timeout: 5))
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))

        // Background AGAIN while the sheet pends: the in-flight attempt is
        // stale (generation 3 now owns the UI) and a fresh attempt starts.
        backgroundThenForeground()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:1", timeout: 15))
        XCTAssertTrue(waitUntilStatus(status, contains: "gen:3", timeout: 5))
        XCTAssertTrue(waitUntilStatus(status, contains: "auth:authenticating", timeout: 10))

        // Release resolves the OLDEST pended attempt — the stale one. It
        // must be rejected: the lock stays engaged.
        app.buttons["applock-release-success"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(
            status.label.contains("locked:0"),
            "a stale authentication completion must not unlock"
        )
        XCTAssertTrue(status.label.contains("locked:1"))

        // The CURRENT-generation attempt still unlocks when released.
        app.buttons["applock-release-success"].tap()
        XCTAssertTrue(waitUntilStatus(status, contains: "locked:0", timeout: 10))
    }
}

/// Launch-argument constants mirrored from the app-side DEBUG seam (the
/// UI-test target cannot import the app module).
enum AppLockUITestSeamLaunchArguments {
    static let pend = "--uitest-applock-pend"
    static let enable = "--uitest-applock-enable"
}
