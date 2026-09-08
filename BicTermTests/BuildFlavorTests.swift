import XCTest
@testable import BicTerm

/// The build flavor flag must agree with the compilation condition in BOTH
/// configuration families: running this suite in default Debug proves the
/// tunnel is advertised; in AppStore-Debug it proves the tunnel is absent.
final class BuildFlavorTests: XCTestCase {
    func testCoderTailnetTunnelSupportMatchesCompilationCondition() {
        #if CODER_TUNNEL
        XCTAssertTrue(BuildFlavor.coderTailnetTunnelSupported)
        #else
        XCTAssertFalse(BuildFlavor.coderTailnetTunnelSupported)
        #endif
    }

    @MainActor
    func testCoderDescriptorTailnetFlagFollowsBuildFlavor() {
        let descriptor = AppServices.shared.descriptor(forProtocolID: "coder")
        XCTAssertEqual(
            descriptor?.supportsTailnetTunnel,
            BuildFlavor.coderTailnetTunnelSupported,
            "the registered coder descriptor must mirror the build flavor exactly"
        )
    }
}
