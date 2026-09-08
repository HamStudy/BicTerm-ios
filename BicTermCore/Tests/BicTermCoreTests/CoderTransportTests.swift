import Foundation
import XCTest
@testable import BicTermCore

/// Hermetic CoderTransport coverage (plan T9): every behavior is scripted
/// through a fake CoderTunneling boundary plus the in-process
/// NoClientAuth UDS loopback server — no Go core, no fixture dependency.
/// The fixture-backed live run is CoderTransportConformanceTests.
final class CoderTransportTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []
    private var liveServers: [LoopbackNoAuthSSHUDSServer] = []

    override func tearDown() async throws {
        for collector in collectors { collector.cancel() }
        collectors = []
        for server in liveServers { await server.stop() }
        liveServers = []
        try await super.tearDown()
    }

    private let serverID = UUID()
    private let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let agentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let placeholderSocketDir = "coder-transport-tests"

    // MARK: - Hermetic scaffolding

    private func makeCoderConnection(reference: CoderReference? = nil) throws -> Connection {
        try Connection(
            name: "coder-ws",
            type: .coder,
            host: "coder.invalid",
            port: 443,
            username: "coder",
            keyReference: "none",
            coderRef: reference ?? CoderReference(serverID: serverID, workspaceID: workspaceID)
        )
    }

    private func workspaceBody(state: String, agentStatus: String) throws -> String {
        let workspace: [String: Any] = [
            "id": workspaceID.uuidString.lowercased(),
            "name": "ws",
            "owner_name": "fixture-user",
            "latest_build": [
                "status": state,
                "resources": [["agents": [[
                    "id": agentID.uuidString.lowercased(),
                    "name": "main",
                    "status": agentStatus,
                ]]]],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["workspaces": [workspace], "count": 1],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func makeResolver(
        results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]
    ) throws -> CoderWorkspaceResolver {
        let server = try CoderServer(
            id: serverID,
            name: "fixture",
            baseURL: URL(string: "https://coder.fixture.invalid")!,
            tokenKeychainTag: "coder-transport-test"
        )
        return CoderWorkspaceResolver(
            serverStore: ScriptedServerStore(server: server),
            tokenStore: ScriptedTokenStore(tokens: ["coder-transport-test": "fixture-token"]),
            requestLoader: ScriptedLoader(results)
        )
    }

    private func runningResolver() throws -> CoderWorkspaceResolver {
        try makeResolver(results: [.success(CoderHTTPResponse(
            statusCode: 200,
            body: Data(try workspaceBody(state: "running", agentStatus: "connected").utf8)
        ))])
    }

    private func startServer(closesAfterGreeting: Bool = false) async throws -> LoopbackNoAuthSSHUDSServer {
        let server = LoopbackNoAuthSSHUDSServer(
            path: makeTestSocketPath(),
            closesChannelAfterGreeting: closesAfterGreeting
        )
        try await server.start()
        liveServers.append(server)
        return server
    }

    // MARK: - Full conformance suite, hermetic

    private func makeSuite() async throws -> TransportConformanceSuite {
        let sink = TransportTestSink()
        return TransportConformanceSuite(
            descriptor: .coder(supportsTailnetTunnel: true),
            expectedResumeStrategy: .nativeRoaming,
            expectedConnectFailure: .unreachable,
            makeTransport: {
                let server = try await self.startServer()
                let tunnel = ScriptTunnel(dialScenarios: [.path(server.path)])
                return CoderTransport(resolver: try self.runningResolver(), tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)
            },
            connectWorking: { transport in
                try await transport.connect(to: self.makeCoderConnection(), cols: 80, rows: 24)
                let sink = sink
                let stream = await transport.output
                self.collectors.append(Task {
                    for await chunk in stream { await sink.append(chunk) }
                    await sink.markFinished()
                })
                let greeted = await waitForSuiteCondition(timeoutMilliseconds: 8000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self)
                        .contains(LoopbackNoAuthSSHUDSServer.greeting.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                XCTAssertTrue(greeted, "no-auth session must reach the shell grant")
                await sink.reset()
            },
            roundTrip: { transport, marker in
                try await transport.send(Data(marker.utf8))
                return await waitForSuiteCondition(timeoutMilliseconds: 8000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains(marker)
                }
            },
            verifyResize: { _, cols, rows in
                await waitForSuiteCondition {
                    self.liveServers.contains { server in
                        server.windowChanges.sizes.contains { $0.cols == cols && $0.rows == rows }
                    }
                }
            },
            outputFinished: { await sink.isFinished },
            makeFailingTransport: {
                let resolver = try self.makeResolver(results: [.failure(.networkFailure)])
                return CoderTransport(resolver: resolver, tunnel: ScriptTunnel(dialScenarios: []), socketBaseDirectory: Self.placeholderSocketDir)
            },
            connectFailing: { transport in
                try await transport.connect(to: self.makeCoderConnection(), cols: 80, rows: 24)
            },
            expectedResumeFailure: .unreachable,
            makeResumeFailingTransport: {
                let server = try await self.startServer(closesAfterGreeting: true)
                let tunnel = ScriptTunnel(dialScenarios: [.path(server.path), .fail])
                return CoderTransport(resolver: try self.runningResolver(), tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)
            },
            observeRoamingResume: { transport in
                guard let coder = transport as? CoderTransport else {
                    return RoamingResumeObservation(
                        connectAttempts: -1,
                        authenticationAttempts: -1,
                        resumeAttempts: -1
                    )
                }
                return await coder.roamingObservation
            }
        )
    }

    func testConnectSucceedsAndOutputStreamIsLive() async throws {
        try await makeSuite().runConnectSucceedsAndOutputStreamIsLive()
    }

    func testInputOutputRoundTrip() async throws {
        try await makeSuite().runInputOutputRoundTrip()
    }

    func testResizeIsObserved() async throws {
        try await makeSuite().runResizeIsObserved()
    }

    func testSuspendResumeFollowsDeclaredStrategy() async throws {
        try await makeSuite().runSuspendResumeFollowsDeclaredStrategy()
    }

    func testResumeFailureSurfacesTypedTransportError() async throws {
        try await makeSuite().runResumeFailureSurfacesTypedTransportError()
    }

    func testCloseIsTerminalIdempotentAndFinishesOutput() async throws {
        try await makeSuite().runCloseIsTerminalIdempotentAndFinishesOutput()
    }

    func testSendBeforeConnectThrowsTypedChannelDenied() async throws {
        try await makeSuite().runSendBeforeConnectThrowsTypedChannelDenied()
    }

    func testConnectFailureSurfacesTypedTransportError() async throws {
        try await makeSuite().runConnectFailureSurfacesTypedTransportError()
    }

    // MARK: - Typed failure paths (MUST DO triage)

    func testDialFailureSurfacesUnreachableAndClosesHandle() async throws {
        let tunnel = ScriptTunnel(dialScenarios: [.fail])
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)

        await assertThrowsTransportError(.unreachable) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }
        let starts = tunnel.startConfigs.count
        let closes = tunnel.closedHandles
        XCTAssertEqual(starts, 1, "the tunnel session was started before the refused dial")
        XCTAssertEqual(closes, [1], "a refused dial must not leak the Go-side session handle")
        await transport.close()
    }

    func testUnauthorizedListingSurfacesAuthRequiredWithoutTouchingTunnel() async throws {
        let resolver = try makeResolver(results: [.success(CoderHTTPResponse(
            statusCode: 401,
            body: Data(#"{"message":"invalid api key"}"#.utf8)
        ))])
        let tunnel = ScriptTunnel(dialScenarios: [])
        let transport = CoderTransport(resolver: resolver, tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)

        await assertThrowsTransportError(.authRequired) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }
        let starts = tunnel.startConfigs.count
        XCTAssertEqual(starts, 0, "a rejected token must never be handed to the tunnel core")
        await transport.close()
    }

    func testAgentGoneSurfacesReconnectRequired() async throws {
        let resolver = try makeResolver(results: [.success(CoderHTTPResponse(
            statusCode: 200,
            body: Data(try workspaceBody(state: "running", agentStatus: "disconnected").utf8)
        ))])
        let tunnel = ScriptTunnel(dialScenarios: [])
        let transport = CoderTransport(resolver: resolver, tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)

        await assertThrowsTransportError(.reconnectRequired) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }
        await transport.close()
    }

    func testWorkspaceMissingSurfacesReconnectRequired() async throws {
        let resolver = try makeResolver(results: [.success(CoderHTTPResponse(
            statusCode: 200,
            body: Data(#"{"workspaces":[],"count":0}"#.utf8)
        ))])
        let tunnel = ScriptTunnel(dialScenarios: [])
        let transport = CoderTransport(resolver: resolver, tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)

        await assertThrowsTransportError(.reconnectRequired) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }
        await transport.close()
    }

    // MARK: - Transport-unit semantics

    func testStartConfigCarriesResolutionVerbatim() async throws {
        let tunnel = ScriptTunnel(dialScenarios: [.fail])
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)
        await assertThrowsTransportError(.unreachable) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }

        let configs = tunnel.startConfigs
        let raw = try XCTUnwrap(configs.first)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["server_url"] as? String, "https://coder.fixture.invalid")
        XCTAssertEqual(decoded["session_token"] as? String, "fixture-token")
        XCTAssertEqual(decoded["agent_id"] as? String, agentID.uuidString.lowercased())
        XCTAssertEqual(decoded["relay_only"] as? Bool, false)
        XCTAssertEqual(decoded["socket_dir"] as? String, Self.placeholderSocketDir)
        await transport.close()
    }

    func testSessionChannelHandleLifecycle() async throws {
        let server = try await startServer()
        let tunnel = ScriptTunnel(dialScenarios: [.path(server.path)])
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)

        await assertThrowsTransportError(.channelDenied) {
            _ = try await transport.sessionChannelHandle()
        }

        try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        let handle = try await transport.sessionChannelHandle()
        XCTAssertTrue(handle.isActive)

        await transport.close()
        await assertThrowsTransportError(.channelDenied) {
            _ = try await transport.sessionChannelHandle()
        }
    }

    func testConnectRejectsNonCoderConnection() async throws {
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: ScriptTunnel(dialScenarios: []), socketBaseDirectory: Self.placeholderSocketDir)
        await assertThrowsTransportError(.protocolUnavailable(protocolID: "ssh")) {
            try await transport.connect(to: makeUnitConnection(name: "ssh-typed"), cols: 80, rows: 24)
        }
        await transport.close()
    }

    func testCoderConnectionWithoutReferenceThrowsReconnectRequired() async throws {
        let orphan = try Connection(
            name: "orphan",
            type: .coder,
            host: "coder.invalid",
            port: 443,
            username: "coder",
            keyReference: "none"
        )
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: ScriptTunnel(dialScenarios: []), socketBaseDirectory: Self.placeholderSocketDir)
        await assertThrowsTransportError(.reconnectRequired) {
            try await transport.connect(to: orphan, cols: 80, rows: 24)
        }
        await transport.close()
    }

    func testSuspendWithoutConnectIsNoOpAndResumeIsChannelDenied() async throws {
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: ScriptTunnel(dialScenarios: []), socketBaseDirectory: Self.placeholderSocketDir)
        await transport.suspend()
        await assertThrowsTransportError(.channelDenied) {
            try await transport.resume()
        }
        await transport.close()
    }

    func testDeadChannelDuringSuspendRedisalsOnResumeWithoutReauth() async throws {
        let serverA = try await startServer()
        let serverB = try await startServer()
        let tunnel = ScriptTunnel(dialScenarios: [.path(serverA.path), .path(serverB.path)])
        let transport = CoderTransport(resolver: try runningResolver(), tunnel: tunnel, socketBaseDirectory: Self.placeholderSocketDir)
        try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)

        await transport.suspend()
        await serverA.closeChildren()
        let dropped = await waitForSuiteCondition {
            await transport.diedWhileSuspended
        }
        XCTAssertTrue(dropped, "the bridge must report the dead stream before resume decides")

        try await transport.resume()
        let observation = await transport.roamingObservation
        XCTAssertEqual(observation.authenticationAttempts, 1, "redial reanchors on the SAME tunnel session")
        XCTAssertEqual(observation.connectAttempts, 2, "a fresh SSH session rides the surviving coordination")
        XCTAssertEqual(observation.resumeAttempts, 1)

        let sink = TransportTestSink()
        let stream = await transport.output
        collectors.append(Task {
            for await chunk in stream { await sink.append(chunk) }
            await sink.markFinished()
        })
        try await transport.send(Data("reattached-marker".utf8))
        let echoed = await waitForSuiteCondition(timeoutMilliseconds: 8000) {
            await String(decoding: sink.snapshot(), as: UTF8.self).contains("reattached-marker")
        }
        XCTAssertTrue(echoed, "I/O must work on the redialed session")
        await transport.close()
    }

    func testRegistryHasNoCoderNetImports() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources/BicTermCore")
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "core sources must exist to audit")

        let forbidden = [
            "import CoderNet",
            "import CoderTunnel",
            "CoderNetStart",
            "CoderNetDialSSH",
            "CoderNetRebind",
            "CoderNetClose",
            "CoderNetVersion",
            "CoderNetFreeString",
            "CoderNetSetLogCallback",
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    source.contains(token),
                    "\(file.lastPathComponent) must not reference \(token) — the Go bridge is dependency-inverted behind CoderTunneling"
                )
            }
        }
    }
}

/// Scripted CoderTunneling double: dials resolve from a scenario queue,
/// every boundary is counted for roaming-resume and leakage assertions.
/// Lock-confined sync methods mirror ``CoderNetTunnel``'s sync FFI surface;
/// no lock ever straddles an await.
private final class ScriptTunnel: CoderTunneling, @unchecked Sendable {
    enum DialScenario: Sendable {
        case path(String)
        case fail
    }

    private let lock = NSLock()
    private var dialScenarios: [DialScenario]
    private var startConfigsStorage: [String] = []
    private var closedHandlesStorage: [Int] = []
    private var rebindCount = 0
    private var nextHandle = 1

    init(dialScenarios: [DialScenario]) {
        self.dialScenarios = dialScenarios
    }

    func version() -> String { "script-tunnel/1.0" }

    var startConfigs: [String] {
        lock.withLock { startConfigsStorage }
    }

    var closedHandles: [Int] {
        lock.withLock { closedHandlesStorage }
    }

    var rebindCalls: Int {
        lock.withLock { rebindCount }
    }

    func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        lock.withLock {
            startConfigsStorage.append(configJSON)
            defer { nextHandle += 1 }
            return nextHandle
        }
    }

    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String {
        lock.withLock {
            guard !dialScenarios.isEmpty else { return "" }
            switch dialScenarios.removeFirst() {
            case let .path(socketPath):
                return socketPath
            case .fail:
                return ""
            }
        }
    }

    func rebind(handle: Int) {
        _ = lock.withLock { rebindCount += 1 }
    }

    func close(handle: Int) {
        _ = lock.withLock { closedHandlesStorage.append(handle) }
    }
}

private actor ScriptedLoader: CoderRequestLoading {
    private var results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]

    init(_ results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]) {
        self.results = results
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        guard !results.isEmpty else { throw .networkFailure }
        return try results.removeFirst().get()
    }
}

private actor ScriptedTokenStore: CoderTokenStoring {
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

private actor ScriptedServerStore: CoderServerStoreProtocol {
    private let server: CoderServer

    init(server: CoderServer) {
        self.server = server
    }

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        [server]
    }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        server.id == id ? server : nil
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {}
    func deleteCoderServer(id: UUID) async throws(PersistenceError) {}
}
