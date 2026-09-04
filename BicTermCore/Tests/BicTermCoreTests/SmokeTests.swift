import NIOSSH
import XCTest
@testable import BicTermCore

final class SmokeTests: XCTestCase {
    /// RED→GREEN harness proof (task T1):
    /// first run asserted `false` and failed as expected (see task report),
    /// then fixed to `true` for the committed GREEN state.
    func testHarnessWorks() {
        XCTAssertEqual(BicTermCore.moduleName, "BicTermCore")
        XCTAssertTrue(true, "test harness is wired up")
    }
}
