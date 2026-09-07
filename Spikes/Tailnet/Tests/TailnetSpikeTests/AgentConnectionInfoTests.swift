import Foundation
import XCTest
@testable import TailnetSpike

final class AgentConnectionInfoTests: XCTestCase {
    func testRealisticConnectionResponsePreservesRequiredTailnetPolicyAndDERPSubset() throws {
        let data = try Data(contentsOf: fixtureURL)

        let info = try JSONDecoder().decode(AgentConnectionInfo.self, from: data)

        XCTAssertTrue(info.derpForceWebSockets)
        XCTAssertTrue(info.disableDirectConnections)
        XCTAssertEqual(info.hostnameSuffix, ".coder.fixture")
        XCTAssertTrue(info.derpMap.omitDefaultRegions)
        XCTAssertEqual(info.derpMap.regions.count, 2)
        let primary = try XCTUnwrap(info.derpMap.regions["1"])
        XCTAssertEqual(primary.regionID, 1)
        XCTAssertEqual(primary.regionCode, "fixture-primary")
        XCTAssertFalse(primary.avoid)
        let node = try XCTUnwrap(primary.nodes.first)
        XCTAssertEqual(node.hostName, "derp-primary.fixture.invalid")
        XCTAssertEqual(node.stunPort, 0, "wire zero means default STUN port 3478")
        XCTAssertEqual(node.derpPort, 0, "wire zero means default DERP port 443")
        XCTAssertEqual(node.insecureForTests, true)
        XCTAssertEqual(node.forceHTTP, false)
    }

    func testMissingRequiredDERPMapIsRejected() {
        let incomplete = Data(#"{"derp_force_websockets":true,"disable_direct_connections":true}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AgentConnectionInfo.self, from: incomplete))
    }

    func testOptionalHostnameSuffixAndOmitDefaultRegionsMayBeAbsent() throws {
        let minimal = Data(#"{"derp_map":{"Regions":{}},"derp_force_websockets":false,"disable_direct_connections":false}"#.utf8)

        let info = try JSONDecoder().decode(AgentConnectionInfo.self, from: minimal)

        XCTAssertNil(info.hostnameSuffix)
        XCTAssertFalse(info.derpMap.omitDefaultRegions)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-connection.json")
    }
}
