import Foundation
import XCTest
@testable import BicTermCore

/// T10 lifecycle: fake-tunnel event sequences → registry state machine
/// assertions. Hermetic throughout: a scripted `CoderTunneling` double plus
/// the in-process NoClientAuth UDS loopback server — no Go core, no fixture.
final class CoderLifecycleTests: XCTestCase {
    private var liveServers: [LoopbackNoAuthSSHUDSServer] = []

    override func tearDown() async throws {
        for server in liveServers { await server.stop() }
        liveServers = []
        try await super.tearDown()
    }

    private let serverID = UUID()
    private let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let agentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let placeholderSocketDir = "coder-lifecycle-tests"

    // MARK: - Scaffolding

    private func makeCoderConnection() throws -> Connection {
        try Connection(
            name: "coder-ws",
            type: .coder,
            host: "coder.invalid",
            port: 443,
            username: "coder",
            keyReference: "none",
            coderRef: CoderReference(serverID: serverID, workspaceID: workspaceID)
        )
    }

    private func startServer() async throws -> LoopbackNoAuthSSHUDSServer {
        let server = LoopbackNoAuthSSHUDSServer(path: makeTestSocketPath())
        try await server.start()
        liveServers.append(server)
        return server
    }

    /// A loader that serves the running-workspace listing, repeating forever.
    private func runningWorkspaceLoader() -> LifecycleLoader {
        LifecycleLoader(results: [.success(CoderHTTPResponse(
            statusCode: 200,
            body: Data(workspaceBody().utf8)
        ))])
    }

    private func workspaceBody() -> String {
        let workspace: [String: Any] = [
            "id": workspaceID.uuidString.lowercased(),
            "name": "ws",
            "owner_name": "fixture-user",
            "latest_build": [
                "status": "running",
                "resources": [["agents": [[
                    "id": agentID.uuidString.lowercased(),
                    "name": "main",
                    "status": "connected",
                ]]]],
            ],
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: ["workspaces": [workspace], "count": 1],
            options: [.sortedKeys]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeResolver(loader: LifecycleLoader) throws -> CoderWorkspaceResolver {
        let server = try CoderServer(
            id: serverID,
            name: "fixture",
            baseURL: URL(string: "https://coder.fixture.invalid")!,
            tokenKeychainTag: "coder-lifecycle-test"
        )
        return CoderWorkspaceResolver(
            serverStore: LifecycleServerStore(server: server),
            tokenStore: LifecycleTokenStore(tokens: ["coder-lifecycle-test": "fixture-token"]),
            requestLoader: loader
        )
    }

    private func makeTransport(
        tunnel: LifecycleScriptTunnel,
        loader: LifecycleLoader,
        lifecycle: CoderSessionLifecycleDependencies?
    ) throws -> CoderTransport {
        CoderTransport(
            resolver: try makeResolver(loader: loader),
            tunnel: tunnel,
            socketBaseDirectory: Self.placeholderSocketDir,
            lifecycle: lifecycle
        )
    }

    /// One wired session: registry + coordinator (attached, started) + one
    /// connected CoderTransport adopted by the registry to `.active`.
    private func startWiredSession(
        sceneID: String = "scene-lifecycle",
        tunnel: LifecycleScriptTunnel,
        reporter: RecordingUsageReporter,
        events: AsyncStream<CoderNetEvent>,
        generations: CoderCredentialGenerations
    ) async throws -> (registry: SessionRegistry, transport: CoderTransport) {
        let factory = SingleTransportFactory()
        let registry = SessionRegistry(
            transportFactory: factory,
            snapshotStore: InMemorySnapshotStore(),
            reconnectPolicy: ReconnectPolicy(maxAttempts: 1, initialDelay: .milliseconds(1))
        )
        let coordinator = CoderLifecycleCoordinator(generations: generations, events: events)
        await coordinator.attach(registry: registry)
        await coordinator.start()
        let transport = try makeTransport(
            tunnel: tunnel,
            loader: runningWorkspaceLoader(),
            lifecycle: CoderSessionLifecycleDependencies(
                reporting: coordinator,
                generations: generations,
                makeUsageReporter: { reporter }
            )
        )
        factory.store(transport)

        try await registry.startSession(sceneID: sceneID, connection: makeCoderConnection())
        let active = await waitForState(registry, sceneID: sceneID) { $0 == .active }
        XCTAssertTrue(active, "session must adopt to .active")
        return (registry, transport)
    }

    // MARK: - Background/foreground lifecycle map

    func testBackgroundSuspendsAndKeepsCoordinationAlive() async throws {
        let server = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(server.path)])
        let reporter = RecordingUsageReporter()
        let (events, _) = AsyncStream<CoderNetEvent>.makeStream()
        let wired = try await startWiredSession(
            tunnel: tunnel, reporter: reporter, events: events,
            generations: CoderCredentialGenerations()
        )
        XCTAssertEqual(tunnel.closedHandles, [], "no teardown at connect")
        XCTAssertEqual(reporter.beginCount(), 1, "usage reporting attaches with the real session")

        await wired.registry.didEnterBackground(sceneID: "scene-lifecycle")

        let state = await wired.registry.state(sceneID: "scene-lifecycle")
        XCTAssertEqual(state, .suspended, "backgrounding parks the session at reconnect-required")
        XCTAssertEqual(tunnel.closedHandles, [], "the Go core keeps coordination while the process lives")
        XCTAssertEqual(reporter.endCount(), 1, "detach stops the usage heartbeat")
    }

    func testForegroundResumesWithRebindAndNoRedial() async throws {
        let server = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(server.path)])
        let reporter = RecordingUsageReporter()
        let (events, _) = AsyncStream<CoderNetEvent>.makeStream()
        let wired = try await startWiredSession(
            tunnel: tunnel, reporter: reporter, events: events,
            generations: CoderCredentialGenerations()
        )

        await wired.registry.didEnterBackground(sceneID: "scene-lifecycle")
        await wired.registry.willEnterForeground(sceneID: "scene-lifecycle")

        let active = await waitForState(wired.registry, sceneID: "scene-lifecycle") { $0 == .active }
        XCTAssertTrue(active)
        XCTAssertEqual(tunnel.rebindCalls, 1, "foreground reanchors the network path exactly once")
        XCTAssertEqual(tunnel.dialCount, 1, "a live SSH stream is NOT redialed")
        XCTAssertEqual(tunnel.startCount, 1, "the coordination is never re-authenticated")
        XCTAssertEqual(reporter.beginCount(), 2, "resume re-attaches usage reporting")
    }

    func testForegroundAfterStreamDeathRedisalsWithoutReauth() async throws {
        let serverA = try await startServer()
        let serverB = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(serverA.path), .path(serverB.path)])
        let reporter = RecordingUsageReporter()
        let (events, _) = AsyncStream<CoderNetEvent>.makeStream()
        let wired = try await startWiredSession(
            tunnel: tunnel, reporter: reporter, events: events,
            generations: CoderCredentialGenerations()
        )

        await wired.registry.didEnterBackground(sceneID: "scene-lifecycle")
        await serverA.closeChildren()
        let died = await waitForSuiteCondition { await wired.transport.diedWhileSuspended }
        XCTAssertTrue(died, "the dead stream must be recorded before resume decides")

        await wired.registry.willEnterForeground(sceneID: "scene-lifecycle")
        let active = await waitForState(wired.registry, sceneID: "scene-lifecycle") { $0 == .active }
        XCTAssertTrue(active, "resume must rebuild the session through reconnect")
        XCTAssertEqual(tunnel.dialCount, 2, "the dead SSH stream is redialed")
        XCTAssertEqual(tunnel.startCount, 1, "no re-authentication: one coordination throughout")
        XCTAssertEqual(tunnel.rebindCalls, 1)
    }

    // MARK: - Event-driven state transitions

    func testSSHClosedEventParksSessionAtReconnectRequired() async throws {
        let server = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(server.path)])
        let reporter = RecordingUsageReporter()
        let (events, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let wired = try await startWiredSession(
            tunnel: tunnel, reporter: reporter, events: events,
            generations: CoderCredentialGenerations()
        )

        continuation.yield(CoderNetEvent(type: .sshClosed, source: .ssh, handle: 1))

        let parked = await waitForState(wired.registry, sceneID: "scene-lifecycle") { $0 == .suspended }
        XCTAssertTrue(parked, "sshClosed must park the session at reconnect-required")
        XCTAssertEqual(tunnel.closedHandles, [], "parking never tears the coordination down")
        let history = await wired.registry.stateHistory(sceneID: "scene-lifecycle")
        XCTAssertFalse(history.contains(.disconnected), "no drop-driven auto-reconnect intervened")

        // The user's own reconnect action resumes the SAME coordination.
        try await wired.registry.reconnect(sceneID: "scene-lifecycle")
        let active = await waitForState(wired.registry, sceneID: "scene-lifecycle") { $0 == .active }
        XCTAssertTrue(active)
        XCTAssertEqual(tunnel.dialCount, 1, "the UDS stream outlived the synthetic event; nothing redialed")
        XCTAssertEqual(tunnel.rebindCalls, 1)
        XCTAssertEqual(reporter.beginCount(), 2)
    }

    func testSSHClosedEventIsIgnoredAfterSessionClosed() async throws {
        let server = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(server.path)])
        let (events, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let wired = try await startWiredSession(
            tunnel: tunnel, reporter: RecordingUsageReporter(), events: events,
            generations: CoderCredentialGenerations()
        )

        await wired.registry.closeSession(sceneID: "scene-lifecycle")
        continuation.yield(CoderNetEvent(type: .sshClosed, source: .ssh, handle: 1))
        try? await Task.sleep(for: .milliseconds(150))
        let state = await wired.registry.state(sceneID: "scene-lifecycle")
        XCTAssertNil(state, "closed sessions are gone; late events route nowhere")
    }

    // MARK: - Auth-loss routes: generation, heartbeat, notification

    func testAuthRequiredEventMarksGenerationStopsHeartbeatAndNotifies() async throws {
        let server = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(server.path)])
        let reporter = RecordingUsageReporter()
        let (events, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let generations = CoderCredentialGenerations()
        let authLosses = LifecycleAuthLossLog()
        let factory = SingleTransportFactory()
        let registry = SessionRegistry(
            transportFactory: factory,
            snapshotStore: InMemorySnapshotStore(),
            reconnectPolicy: ReconnectPolicy(maxAttempts: 1, initialDelay: .milliseconds(1))
        )
        let coordinator = CoderLifecycleCoordinator(generations: generations, events: events) { id in
            await authLosses.record(id)
        }
        await coordinator.attach(registry: registry)
        await coordinator.start()
        factory.store(try makeTransport(
            tunnel: tunnel,
            loader: runningWorkspaceLoader(),
            lifecycle: CoderSessionLifecycleDependencies(
                reporting: coordinator,
                generations: generations,
                makeUsageReporter: { reporter }
            )
        ))

        let sceneID = "scene-authloss"
        try await registry.startSession(sceneID: sceneID, connection: makeCoderConnection())
        let adopted = await waitForState(registry, sceneID: sceneID) { $0 == .active }
        XCTAssertTrue(adopted)
        XCTAssertEqual(reporter.endCount(), 0)

        continuation.yield(CoderNetEvent(type: .authRequired, source: .coord, httpStatus: 401, handle: 1))

        let marked = await waitForSuiteCondition {
            await generations.generation(for: self.serverID).state == .authRequired
        }
        XCTAssertTrue(marked, "genuine 401 must mark the credential generation")
        let heartbeatStopped = await waitForSuiteCondition { reporter.endCount() == 1 }
        XCTAssertTrue(heartbeatStopped, "generation marking stops the heartbeat")
        let lossCount = await authLosses.count()
        let firstLoss = await authLosses.first()
        XCTAssertEqual(lossCount, 1)
        XCTAssertEqual(firstLoss, serverID)

        // Explicit client policy (spec §14.5, Docs/SECURITY.md): the
        // established session continues until its natural end.
        let state = await registry.state(sceneID: sceneID)
        XCTAssertEqual(state, .active, "auth loss never force-kills an established session")
    }

    // MARK: - Credential generation refusal and replacement (spec §4.3)

    func testMarkedGenerationRefusesNewDialBeforeAnyNetwork() async throws {
        let tunnel = LifecycleScriptTunnel(dialScenarios: [])
        let loader = runningWorkspaceLoader()
        let generations = CoderCredentialGenerations()
        let transport = try makeTransport(
            tunnel: tunnel, loader: loader,
            lifecycle: CoderSessionLifecycleDependencies(generations: generations)
        )
        await generations.markAuthRequired(for: serverID)

        await assertThrowsTransportError(.authRequired) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }
        XCTAssertEqual(tunnel.startCount, 0, "no Go handle is allocated for a dead generation")
        let loaderCalls = await loader.callCount
        XCTAssertEqual(loaderCalls, 0, "no REST call rides a dead generation")
        await transport.close()
    }

    func testReplacementGenerationAllocatesFreshHandleCarryingNewGeneration() async throws {
        let serverOne = try await startServer()
        let serverTwo = try await startServer()
        let tunnel = LifecycleScriptTunnel(dialScenarios: [.path(serverOne.path), .path(serverTwo.path)])
        let generations = CoderCredentialGenerations()
        let dependencies = CoderSessionLifecycleDependencies(generations: generations)
        let connection = try makeCoderConnection()

        let first = try makeTransport(tunnel: tunnel, loader: runningWorkspaceLoader(), lifecycle: dependencies)
        try await first.connect(to: connection, cols: 80, rows: 24)
        await first.close()

        await generations.markAuthRequired(for: serverID)
        let refused = try makeTransport(tunnel: tunnel, loader: runningWorkspaceLoader(), lifecycle: dependencies)
        await assertThrowsTransportError(.authRequired) {
            try await refused.connect(to: connection, cols: 80, rows: 24)
        }
        await refused.close()

        let replacement = await generations.installReplacement(for: serverID)
        XCTAssertEqual(replacement.id, 2)
        let reconnected = try makeTransport(tunnel: tunnel, loader: runningWorkspaceLoader(), lifecycle: dependencies)
        try await reconnected.connect(to: connection, cols: 80, rows: 24)
        await reconnected.close()

        XCTAssertEqual(tunnel.startCount, 2, "the refused middle dial never allocated a handle")
        let generationsOnWire = try tunnel.startConfigs.map { raw -> Int in
            let decoded = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            return try XCTUnwrap(decoded?["credential_generation"] as? Int)
        }
        XCTAssertEqual(generationsOnWire, [1, 2], "each dial carries its own credential generation")
        XCTAssertEqual(Set(tunnel.allocatedHandles).count, 2, "a fresh Go handle per dial — never the old one")
    }

    func testConnectTimeRest401MarksTheGeneration() async throws {
        let tunnel = LifecycleScriptTunnel(dialScenarios: [])
        let generations = CoderCredentialGenerations()
        let loader = LifecycleLoader(results: [.success(CoderHTTPResponse(
            statusCode: 401,
            body: Data(#"{"message":"invalid api key"}"#.utf8)
        ))])
        let transport = try makeTransport(
            tunnel: tunnel, loader: loader,
            lifecycle: CoderSessionLifecycleDependencies(generations: generations)
        )

        await assertThrowsTransportError(.authRequired) {
            try await transport.connect(to: makeCoderConnection(), cols: 80, rows: 24)
        }
        let generation = await generations.generation(for: serverID)
        XCTAssertEqual(generation.state, .authRequired, "a connect-time REST 401 confirms auth loss")
        await transport.close()
    }

    // MARK: - Registry: auth loss is terminal for auto-reconnect

    func testAutoReconnectStopsOnAuthRequiredInsteadOfSpinning() async throws {
        let factory = FakeSessionTransportFactory(
            queued: [.succeed, .fail(.authRequired)],
            fallback: .succeed,
            roaming: false
        )
        let registry = SessionRegistry(
            transportFactory: factory,
            snapshotStore: InMemorySnapshotStore(),
            reconnectPolicy: ReconnectPolicy(maxAttempts: 4, initialDelay: .milliseconds(1))
        )
        let sceneID = "scene-auth-terminal"
        try await registry.startSession(sceneID: sceneID, connection: makeUnitConnection())
        let initialState = await registry.state(sceneID: sceneID)
        XCTAssertEqual(initialState, .active)

        await factory.transports[0].finishOutput()

        let failed = await waitForState(registry, sceneID: sceneID) { state in
            if case .failed = state { return true }
            return false
        }
        XCTAssertTrue(failed)
        let finalState = await registry.state(sceneID: sceneID)
        XCTAssertEqual(finalState, .failed(.transport(.authRequired)))

        // §15: the loop must not keep presenting the same dead token.
        let spun = await waitForSuiteCondition(timeoutMilliseconds: 500) { factory.makeCount > 2 }
        XCTAssertFalse(spun, "no retry storm: exactly one doomed attempt, then .failed")
        let history = await registry.stateHistory(sceneID: sceneID)
        let sawExhaustion = history.contains { state in
            guard case .failed(.reconnectAttemptsExhausted) = state else { return false }
            return true
        }
        XCTAssertFalse(sawExhaustion)
    }
}

// MARK: - Doubles

/// Scripted store doubles and loaders for the resolver boundary, mirroring
/// the CoderTransportTests pattern; local to this suite to keep the two
/// suites' scenarios independently editable.
private actor LifecycleLoader: CoderRequestLoading {
    private var results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]
    private(set) var callCount = 0

    init(results: [Result<CoderHTTPResponse, CoderRequestLoadingError>]) {
        self.results = results
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        callCount += 1
        if results.count > 1 { return try results.removeFirst().get() }
        if let last = results.first { return try last.get() }
        throw .networkFailure
    }
}

private actor LifecycleTokenStore: CoderTokenStoring {
    private var tokens: [String: String]

    init(tokens: [String: String]) { self.tokens = tokens }

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

private actor LifecycleServerStore: CoderServerStoreProtocol {
    private let server: CoderServer

    init(server: CoderServer) { self.server = server }

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] { [server] }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        server.id == id ? server : nil
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {}
    func deleteCoderServer(id: UUID) async throws(PersistenceError) {}
}

/// Factory holding exactly one transport — a session's CoderTransport is
/// built ahead of time so test scenarios control its doubles directly.
private final class SingleTransportFactory: TerminalTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any TerminalTransport)?

    func store(_ transport: any TerminalTransport) {
        lock.withLock { stored = transport }
    }

    func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        guard let transport = lock.withLock({ stored }) else { throw .unreachable }
        return transport
    }
}

/// Scripted CoderTunneling double with full call accounting (dial queue,
/// start configs, closes, rebinds) — the fake-tunnel half of the suite.
private final class LifecycleScriptTunnel: CoderTunneling, @unchecked Sendable {
    enum DialStep: Sendable {
        case path(String)
    }

    private let lock = NSLock()
    private var dialScenarios: [DialStep]
    private var configs: [String] = []
    private var closes: [Int] = []
    private var rebinds = 0
    private var dials = 0
    private var handles: [Int] = []
    private var nextHandle = 1

    init(dialScenarios: [DialStep]) { self.dialScenarios = dialScenarios }

    var startConfigs: [String] { lock.withLock { configs } }
    var closedHandles: [Int] { lock.withLock { closes } }
    var rebindCalls: Int { lock.withLock { rebinds } }
    var dialCount: Int { lock.withLock { dials } }
    var startCount: Int { lock.withLock { configs.count } }
    var allocatedHandles: [Int] { lock.withLock { handles } }

    func version() -> String { "lifecycle-script-tunnel/1.0" }

    func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        lock.withLock {
            configs.append(configJSON)
            let handle = nextHandle
            nextHandle += 1
            handles.append(handle)
            return handle
        }
    }

    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String {
        lock.withLock {
            dials += 1
            guard let step = dialScenarios.first else { return "" }
            dialScenarios.removeFirst()
            switch step {
            case .path(let socketPath):
                return socketPath
            }
        }
    }

    func rebind(handle: Int) {
        _ = lock.withLock { rebinds += 1 }
    }

    func close(handle: Int) {
        _ = lock.withLock { closes.append(handle) }
    }
}

/// Records begin/end calls from the transport/coordinator.
private final class RecordingUsageReporter: CoderUsageReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var begins: [CoderUsageScope] = []
    private var ends = 0

    func begin(_ scope: CoderUsageScope) {
        lock.withLock { begins.append(scope) }
    }

    func end() {
        _ = lock.withLock { ends += 1 }
    }

    func beginCount() -> Int { lock.withLock { begins.count } }
    func endCount() -> Int { lock.withLock { ends } }
    func scopes() -> [CoderUsageScope] { lock.withLock { begins } }
}

private actor LifecycleAuthLossLog {
    private var seen: [UUID] = []
    func record(_ serverID: UUID) { seen.append(serverID) }
    func count() -> Int { seen.count }
    func first() -> UUID? { seen.first }
}
