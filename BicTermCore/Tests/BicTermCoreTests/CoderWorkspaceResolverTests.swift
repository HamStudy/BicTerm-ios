import Foundation
import XCTest
@testable import BicTermCore

/// Typed taxonomy of coder session resolution (spec §5.2, §6.2): the
/// transport consumes ``CoderAgentEndpoint`` values; every failure class the
/// transport maps onto ``TransportError`` cases is exercised here against a
/// scripted REST boundary.
final class CoderWorkspaceResolverTests: XCTestCase {
    private let serverID = UUID()
    private let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let agentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private func makeServer() throws -> CoderServer {
        try CoderServer(
            id: serverID,
            name: "fixture",
            baseURL: URL(string: "https://coder.fixture.invalid")!,
            tokenKeychainTag: "resolver-test"
        )
    }

    private func envelope(workspaceID: UUID?, state: String, agents: [(id: UUID, name: String, status: String)]) -> String {
        var object: [String: Any] = ["workspaces": [Any](), "count": 0]
        if let workspaceID {
            let agentObjects: [[String: Any]] = agents.map { agent in
                ["id": agent.id.uuidString.lowercased(), "name": agent.name, "status": agent.status]
            }
            let workspace: [String: Any] = [
                "id": workspaceID.uuidString.lowercased(),
                "name": "ws",
                "owner_name": "fixture-user",
                "latest_build": [
                    "status": state,
                    "resources": agents.isEmpty ? [] : [["agents": agentObjects]],
                ] as [String: Any],
            ]
            object = ["workspaces": [workspace], "count": 1]
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func response(statusCode: Int = 200, body: String) -> CoderHTTPResponse {
        CoderHTTPResponse(statusCode: statusCode, body: Data(body.utf8))
    }

    private func makeResolver(
        server: CoderServer? = nil,
        token: String? = "fixture-token",
        results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]
    ) throws -> CoderWorkspaceResolver {
        let serverStore = try TestCoderServerStore(server: server ?? makeServer())
        let tokenStore = TestCoderTokenStore(tokens: token.map { ["resolver-test": $0] } ?? [:])
        return CoderWorkspaceResolver(
            serverStore: serverStore,
            tokenStore: tokenStore,
            requestLoader: TestScriptedLoader(results)
        )
    }

    private var reference: CoderReference {
        CoderReference(serverID: serverID, workspaceID: workspaceID)
    }

    func testRunningWorkspaceWithConnectedAgentResolvesEndpoint() async throws {
        let resolver = try makeResolver(results: [.success(response(body: envelope(
            workspaceID: workspaceID,
            state: "running",
            agents: [(id: agentID, name: "main", status: "connected")]
        )))])

        let endpoint = try await resolver.resolve(reference)

        XCTAssertEqual(endpoint.serverURL.absoluteString, "https://coder.fixture.invalid")
        XCTAssertEqual(endpoint.sessionToken, "fixture-token")
        XCTAssertEqual(endpoint.agentID, agentID)
    }

    func testUnknownServerIsTyped() async throws {
        let orphanRef = CoderReference(serverID: UUID(), workspaceID: workspaceID)
        let resolver = try makeResolver(results: [])
        await assertThrowsResolutionError(.serverUnknown) {
            try await resolver.resolve(orphanRef)
        }
    }

    func testBlockingUnknownLifecycleWaitsAndSurfacesStartupFailure() async throws {
        let results = ["unknown", "start_error"].map { lifecycle in
            Result<CoderHTTPResponse, CoderRequestLoadingError>.success(response(body: """
            {"workspaces":[{"id":"\(workspaceID)","name":"ws","owner_name":"fixture-user",
            "latest_build":{"status":"running","resources":[{"agents":[{
            "id":"\(agentID)","name":"main","status":"connected",
            "lifecycle_state":"\(lifecycle)","scripts":[{"start_blocks_login":true}]
            }]}]}}],"count":1}
            """))
        }
        let resolver = try makeResolver(results: results)

        await assertThrowsResolutionError(.agentStartupFailed(state: "start_error")) {
            try await resolver.resolve(reference)
        }
    }

    func testMissingTokenIsTyped() async throws {
        let resolver = try makeResolver(token: nil, results: [])
        await assertThrowsResolutionError(.tokenMissing) {
            try await resolver.resolve(reference)
        }
    }

    func testUnauthorizedServerResponseIsTyped() async throws {
        let resolver = try makeResolver(results: [
            .success(response(statusCode: 401, body: #"{"message":"invalid api key"}"#)),
        ])
        await assertThrowsResolutionError(.unauthorized) {
            try await resolver.resolve(reference)
        }
    }

    func testUnreachableServerResponseIsTyped() async throws {
        let resolver = try makeResolver(results: [.failure(.networkFailure)])
        await assertThrowsResolutionError(.serverUnreachable) {
            try await resolver.resolve(reference)
        }
    }

    func testWorkspaceAbsentFromListingIsTyped() async throws {
        let resolver = try makeResolver(results: [.success(response(body: envelope(
            workspaceID: nil, state: "running", agents: []
        )))])
        await assertThrowsResolutionError(.workspaceMissing) {
            try await resolver.resolve(reference)
        }
    }

    func testStoppedWorkspaceIsTyped() async throws {
        let resolver = try makeResolver(results: [.success(response(body: envelope(
            workspaceID: workspaceID,
            state: "stopped",
            agents: [(id: agentID, name: "main", status: "disconnected")]
        )))])
        await assertThrowsResolutionError(.workspaceNotRunning(state: .stopped)) {
            try await resolver.resolve(reference)
        }
    }

    /// §6.2: the agent layer is checked independently of the build state.
    func testRunningWorkspaceWithoutConnectedAgentIsTyped() async throws {
        let resolver = try makeResolver(results: [.success(response(body: envelope(
            workspaceID: workspaceID,
            state: "running",
            agents: [(id: agentID, name: "main", status: "connecting")]
        )))])
        await assertThrowsResolutionError(.agentUnavailable) {
            try await resolver.resolve(reference)
        }
    }

    /// §5.2 MVP selection policy: ambiguity is a typed error, never a
    /// silent first-element pick.
    func testMultipleConnectedAgentsAreTypedAmbiguity() async throws {
        let second = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let resolver = try makeResolver(results: [.success(response(body: envelope(
            workspaceID: workspaceID,
            state: "running",
            agents: [
                (id: agentID, name: "main", status: "connected"),
                (id: second, name: "secondary", status: "connected"),
            ]
        )))])
        await assertThrowsResolutionError(.agentUnavailable) {
            try await resolver.resolve(reference)
        }
    }

    private func assertThrowsResolutionError(
        _ expected: CoderResolutionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> CoderAgentEndpoint
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CoderResolutionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private actor TestCoderServerStore: CoderServerStoreProtocol {
    private let server: CoderServer?

    init(server: CoderServer?) {
        self.server = server
    }

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        server.map { [$0] } ?? []
    }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        server?.id == id ? server : nil
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {}
    func deleteCoderServer(id: UUID) async throws(PersistenceError) {}
}

private actor TestCoderTokenStore: CoderTokenStoring {
    private var tokens: [String: String]

    init(tokens: [String: String]) {
        self.tokens = tokens
    }

    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        tokens[keychainTag]
    }

    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        tokens[keychainTag] = token
    }

    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
        tokens[keychainTag] = nil
    }
}

private actor TestScriptedLoader: CoderRequestLoading {
    private var results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]

    init(_ results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]) {
        self.results = results
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        guard !results.isEmpty else { throw .networkFailure }
        return try results.removeFirst().get()
    }
}
