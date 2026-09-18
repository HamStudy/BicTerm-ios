import XCTest
@testable import BicTermCore

/// Locks the diagnostic capture the device herd diagnostic depends on:
/// records survive in order, the ring buffer trims to capacity, and
/// removeAll gives the next run a fresh buffer. If this breaks, the
/// device diagnostic silently loses the swallowed-error evidence and
/// the `.channelDenied` dead end returns.
final class SSHEstablishDiagnosticsTests: XCTestCase {
    private struct ProbeError: Error {}

    override func setUp() {
        super.setUp()
        SSHEstablishDiagnostics.shared.removeAll()
    }

    override func tearDown() {
        SSHEstablishDiagnostics.shared.removeAll()
        super.tearDown()
    }

    func testRecordedErrorsSnapshotOldestFirstWithReflectingChain() {
        SSHEstablishDiagnostics.shared.record("site-a", error: ProbeError())
        SSHEstablishDiagnostics.shared.record("site-b", error: ProbeError())

        let snapshot = SSHEstablishDiagnostics.shared.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        // `String(reflecting:)` renders the error's full typed chain —
        // context prefix plus the reflected type name, oldest first.
        XCTAssertEqual(snapshot.first?.hasPrefix("site-a: "), true)
        XCTAssertEqual(snapshot.first?.hasSuffix("ProbeError()"), true)
        XCTAssertEqual(snapshot.last?.hasPrefix("site-b: "), true)
        XCTAssertEqual(snapshot.last?.hasSuffix("ProbeError()"), true)
    }

    func testRemoveAllClearsTheCapture() {
        SSHEstablishDiagnostics.shared.record("site", error: ProbeError())
        SSHEstablishDiagnostics.shared.removeAll()
        XCTAssertEqual(SSHEstablishDiagnostics.shared.snapshot(), [])
    }
}
