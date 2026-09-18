import UIKit
import XCTest
@testable import BicTerm

/// AppSceneCounter's decision predicate: a session close dismisses the
/// hosting window only when the app supports multiple windows AND more
/// than one window scene is visible — dismissing the app's last visible
/// scene would background the whole app, so that window falls back to
/// the in-window connection list instead.
///
/// The last-window branch is verified here rather than in a UI test:
/// XCUITest cannot dismiss one specific app window (the native window
/// close control is system chrome, like the resize grip
/// FreeformResizeUITests routes through SpringBoard), so building the
/// "terminal window is the only visible one" arrangement from a test is
/// not reliably expressible.
@MainActor
final class AppSceneCounterTests: XCTestCase {
    /// iPhone cover mode never dismisses, whatever the window count.
    func testCoverModeNeverDismisses() {
        XCTAssertFalse(AppSceneCounter.shouldDismissWindow(
            supportsMultipleWindows: false, visibleWindowSceneCount: 1
        ))
        XCTAssertFalse(AppSceneCounter.shouldDismissWindow(
            supportsMultipleWindows: false, visibleWindowSceneCount: 3
        ))
    }

    /// Sole visible window (the closing window's own scene): kept —
    /// the connection-list fallback renders in place.
    func testSoleVisibleWindowIsKept() {
        XCTAssertFalse(AppSceneCounter.shouldDismissWindow(
            supportsMultipleWindows: true, visibleWindowSceneCount: 1
        ))
    }

    /// Other visible windows remain (terminal + connection list, a
    /// Settings or herdr window): the closing window dismisses.
    func testWindowWithVisibleCompanyDismisses() {
        XCTAssertTrue(AppSceneCounter.shouldDismissWindow(
            supportsMultipleWindows: true, visibleWindowSceneCount: 2
        ))
        XCTAssertTrue(AppSceneCounter.shouldDismissWindow(
            supportsMultipleWindows: true, visibleWindowSceneCount: 3
        ))
    }

    /// Degenerate zero count (no visible scene — unreachable from a
    /// user-initiated close) stays on the keep side.
    func testZeroVisibleWindowsIsKept() {
        XCTAssertFalse(AppSceneCounter.shouldDismissWindow(
            supportsMultipleWindows: true, visibleWindowSceneCount: 0
        ))
    }

    /// Only foreground states are visible; background and unattached
    /// scenes never count toward the total.
    func testVisibilityFilterExcludesBackgroundScenes() {
        XCTAssertTrue(AppSceneCounter.isVisible(.foregroundActive))
        XCTAssertTrue(AppSceneCounter.isVisible(.foregroundInactive))
        XCTAssertFalse(AppSceneCounter.isVisible(.background))
        XCTAssertFalse(AppSceneCounter.isVisible(.unattached))
    }
}
