import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeAuthAcceptanceTests: XCTestCase {
    func testNativeInvalidTokenRequiresAuthenticationWithoutRetryOrTunnelDial() async throws {
        let server = try CoderServer(
            name: "native-acceptance",
            baseURL: URL(string: "http://127.0.0.1:7080")!,
            tokenKeychainTag: "native-invalid-token"
        )
        let loader = NativeAuthRequestLedger()
        let resolver = CoderWorkspaceResolver(
            serverStore: NativeAuthServerStore(server: server),
            tokenStore: NativeAuthTokens(),
            requestLoader: loader
        )
        let transport = CoderTransport(
            resolver: resolver, tunnel: UndialedAcceptanceTunnel(),
            socketBaseDirectory: SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/g12s").path
        )
        let connection = try Connection(
            name: "invalid-token", type: .coder, host: "127.0.0.1", port: 7080,
            username: "coder", keyReference: "none",
            coderRef: CoderReference(serverID: server.id, workspaceID: UUID())
        )

        do {
            try await transport.connect(to: connection, cols: 80, rows: 24)
            XCTFail("Invalid native token must not connect")
        } catch {
            XCTAssertEqual(error, .authRequired)
        }

        let statuses = await loader.statuses
        XCTAssertEqual(statuses, [401], "Native authentication denial must not retry")
        print("A02 native HTTP statuses: \(statuses)")
        await transport.close()
    }
}

private actor NativeAuthRequestLedger: CoderRequestLoading {
    private let upstream = SystemCoderRequestLoader()
    private(set) var statuses: [Int] = []

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        let response = try await upstream.load(request)
        statuses.append(response.statusCode)
        return response
    }
}

private actor NativeAuthTokens: CoderTokenStoring {
    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        "g12-invalid-user-token-sentinel"
    }
    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        XCTFail("An invalid-token read must not mutate credentials")
    }
    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
        XCTFail("An invalid-token read must not delete credentials")
    }
}

private actor NativeAuthServerStore: CoderServerStoreProtocol {
    let server: CoderServer
    init(server: CoderServer) { self.server = server }
    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] { [server] }
    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        id == server.id ? server : nil
    }
    func save(_ server: CoderServer) async throws(PersistenceError) {
        XCTFail("Resolution must not mutate server metadata")
    }
    func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        XCTFail("Resolution must not delete server metadata")
    }
}

private struct UndialedAcceptanceTunnel: CoderTunneling {
    func version() -> String { "acceptance" }
    func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        XCTFail("Authentication denial must precede tunnel allocation")
        throw .startRejected
    }
    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String {
        XCTFail("Authentication denial must precede SSH dial")
        throw .startRejected
    }
    func rebind(handle: Int) { XCTFail("An unauthenticated transport must not rebind") }
    func close(handle: Int) { XCTFail("No tunnel handle should have been allocated") }
}
