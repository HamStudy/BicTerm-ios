import XCTest

/// Shared dismissal for iOS's "Save Password?" AutoFill sheet.
///
/// The connection editor's password fields advertise `.password`
/// semantics, so typing a password can surface the system save prompt
/// over the connection list; the covered list chrome still exists but is
/// not hittable, which times out list-waiting assertions. The prompt is
/// stateful across a run (once dismissed per install it may not
/// reappear), so this is try-if-present.
///
/// The alert's AX tree exposes "Not Now" before the alert accepts
/// touches, so a tap synthesized in that window can be silently
/// swallowed — verify the dismissal outcome and re-tap instead of
/// trusting the first tap.
@MainActor
extension XCUIApplication {
    func dismissSystemSavePromptIfPresent() {
        let notNow = buttons["Not Now"]
        guard notNow.waitForExistence(timeout: 3) else { return }
        let dismissed = NSPredicate(format: "exists == false")
        for _ in 0..<4 {
            notNow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: dismissed, object: notNow)],
                timeout: 2
            ) == .completed {
                return
            }
        }
        XCTFail("the system Save Password alert did not dismiss after repeated Not Now taps")
    }
}
