import Foundation
import XCTest
@testable import TailnetSpike

final class TailnetEndpointsTests: XCTestCase {
    private let agentID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!

    func testHTTPSBaseBuildsAuthenticatedRESTAndWSSCoordinateContracts() throws {
        let endpoints = try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: "https://coder.example.com/base/")),
            agentID: agentID
        )

        let rest = try endpoints.connectionRequest(token: "test-token")
        let coordinate = try endpoints.coordinateRequest(token: "test-token")

        XCTAssertEqual(rest.url?.absoluteString, "https://coder.example.com/base/api/v2/workspaceagents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/connection")
        XCTAssertEqual(rest.httpMethod, "GET")
        XCTAssertEqual(rest.value(forHTTPHeaderField: "Coder-Session-Token"), "test-token")
        XCTAssertEqual(coordinate.url?.scheme, "wss")
        XCTAssertEqual(coordinate.url?.path, "/base/api/v2/workspaceagents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/coordinate")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(coordinate.url), resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "version", value: "2.0"),
        ])
        XCTAssertEqual(coordinate.value(forHTTPHeaderField: "Coder-Session-Token"), "test-token")
        XCTAssertNil(coordinate.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"))
        XCTAssertNil(coordinate.value(forHTTPHeaderField: "Sec-WebSocket-Extensions"))
    }

    func testMissingCoordinateTokenProducesARequestWithoutTheAuthenticationHeader() throws {
        let endpoints = try localEndpoints()

        let request = try endpoints.coordinateRequest(token: nil)

        XCTAssertNil(request.value(forHTTPHeaderField: "Coder-Session-Token"))
    }

    func testEmptyTokenIsRejectedBeforeNetworkIO() throws {
        let endpoints = try localEndpoints()

        XCTAssertThrowsError(try endpoints.connectionRequest(token: "")) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .missingToken)
        }
        XCTAssertThrowsError(try endpoints.coordinateRequest(token: "")) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .missingToken)
        }
    }

    func testPlainHTTPIsAllowedOnlyForAnExplicitLoopbackFixture() throws {
        XCTAssertThrowsError(try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: "http://coder.example.com")),
            agentID: agentID,
            allowsInsecureLoopback: true
        )) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .insecureBaseURL)
        }
        XCTAssertThrowsError(try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18082")),
            agentID: agentID
        )) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .insecureBaseURL)
        }

        let endpoints = try localEndpoints()

        XCTAssertEqual(endpoints.connectionURL.scheme, "http")
        XCTAssertEqual(endpoints.coordinateURL.scheme, "ws")
    }

    func testUnsupportedSchemeAndCredentialBearingBaseURLAreRejected() throws {
        XCTAssertThrowsError(try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: "ftp://coder.example.com")),
            agentID: agentID
        )) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: "https://user:password@coder.example.com")),
            agentID: agentID
        )) { error in
            XCTAssertEqual(error as? TailnetSpikeError, .invalidBaseURL)
        }
    }

    private func localEndpoints() throws -> TailnetEndpoints {
        try TailnetEndpoints(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18082")),
            agentID: agentID,
            allowsInsecureLoopback: true
        )
    }
}
