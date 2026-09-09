import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeStartPolicyAcceptanceTests: XCTestCase {
    func testNativeStoppedWorkspaceWithStartDisabledSendsNoMutation() async throws {
        let ledger = NativeStartPolicyLedger()
        let fixture = try await CoderNativeFixture.load(name: "bicterm-stopped", loader: ledger)
        XCTAssertEqual(fixture.workspace.state, .stopped)
        let options = try ProtocolOptions(["coder.startPolicy": .bool(false)])
        let transport = fixture.transport()

        do {
            try await transport.connect(to: fixture.connection(options: options), cols: 80, rows: 24)
            XCTFail("Start-disabled connection must not connect to a stopped workspace")
        } catch let error as TransportError {
            XCTAssertEqual(error, .reconnectRequired)
        }

        let methods = await ledger.methods
        XCTAssertFalse(methods.isEmpty)
        XCTAssertTrue(methods.allSatisfy { $0 == "GET" }, "Start-disabled must issue no mutation")
        print("A07 native request methods: \(methods)")
        await transport.close()
    }
}

private actor NativeStartPolicyLedger: CoderRequestLoading {
    private let upstream = SystemCoderRequestLoader()
    private(set) var methods: [String] = []
    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        methods.append(request.httpMethod ?? "GET")
        return try await upstream.load(request)
    }
}
