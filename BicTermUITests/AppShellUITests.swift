import XCTest

@MainActor
final class AppShellUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testAppLaunchesAndHasWindows() {
        app.launch()
        XCTAssertTrue(app.windows.count >= 1)
    }
}
