import XCTest

final class BicTermUITests: XCTestCase {
    func testAppLaunchesAndShowsPlaceholder() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["BicTerm"].waitForExistence(timeout: 10))
    }
}
