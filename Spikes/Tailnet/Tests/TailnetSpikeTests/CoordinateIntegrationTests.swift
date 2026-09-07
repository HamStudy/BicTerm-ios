import Foundation
import XCTest
@testable import TailnetSpike

final class CoordinateIntegrationTests: XCTestCase {
    private let agentID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!

    func testWebSocketAcceptMatchesRFC6455KnownAnswer() {
        XCTAssertEqual(
            WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testLiveFixtureDecodesConnectionAndEnforcesCoordinateAuthentication() throws {
        let rawBaseURL = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TAILNET_SPIKE_BASE_URL"],
            "Run Scripts/run-coordinate-spike.sh so the deterministic fixture is available"
        )
        let endpoints = try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: rawBaseURL)),
            agentID: agentID,
            allowsInsecureLoopback: true
        )

        let info = try LoopbackAgentConnectionClient().fetch(
            endpoints.connectionRequest(token: "fixture-token")
        )
        let valid = try CoordinateWebSocketProbe().connect(
            endpoints.coordinateRequest(token: "fixture-token")
        )
        let missing = try CoordinateWebSocketProbe().connect(
            endpoints.coordinateRequest(token: nil)
        )
        let invalid = try CoordinateWebSocketProbe().connect(
            endpoints.coordinateRequest(token: "invalid-fixture-token")
        )

        XCTAssertEqual(info.derpMap.regions.count, 2)
        XCTAssertEqual(valid, .upgraded(binaryPayload: Data("fixture-coordinate-binary".utf8)))
        XCTAssertEqual(missing, .rejected(statusCode: 401))
        XCTAssertEqual(invalid, .rejected(statusCode: 401))
    }

    func testLiveFixtureRejectsInvalidRESTAuthentication() throws {
        let rawBaseURL = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TAILNET_SPIKE_BASE_URL"],
            "Run Scripts/run-coordinate-spike.sh so the deterministic fixture is available"
        )
        let endpoints = try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: rawBaseURL)),
            agentID: agentID,
            allowsInsecureLoopback: true
        )

        XCTAssertThrowsError(try LoopbackAgentConnectionClient().fetch(
            endpoints.connectionRequest(token: "invalid-fixture-token")
        )) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .unexpectedHTTPStatus(401))
        }
    }
}
