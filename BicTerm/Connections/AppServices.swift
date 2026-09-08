import BicTermCore
import Foundation
import Observation

/// App-side service wiring for the Connections feature.
///
/// T13 scope: the `TransportRegistry` drives the connection-type selector
/// and capability-driven UI (jump-chain visibility, protocol options).
/// Transport FACTORIES are not consumed yet — T14 wires the session
/// registry, so both v1 protocols register ``DeferredTransportFactory``
/// which answers a typed ``TransportError/protocolUnavailable`` instead of
/// pretending to connect.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let protocols: [ProtocolDescriptor]
    let connectionStore: any ConnectionStoreProtocol
    let coderServerStore: any CoderServerStoreProtocol
    let keyRepository = KeychainKeyRepository()
    let coderClientFactory: CoderClientFactory
    let coderTokenStore: any CoderTokenStoring
    let coderRequestLoader: any CoderRequestLoading
    let passwordStore: any PasswordStoring

    #if DEBUG
    /// Set by the `--uitest-demo-editor` launch hook: name of a connection
    /// whose editor should be presented once after launch (screenshot aid).
    var debugAutoOpenEditorForConnectionNamed: String?

    /// Await this in production UI entry points before reading Coder
    /// configuration, so `-uitest-reset-configuration` finishes before
    /// any list/model reload observes stale data.
    private(set) var startupResetTask: Task<Void, Never>?
    #endif

    private let registry: TransportRegistry

    init() {
        var registry = TransportRegistry()

        let deferredSSH = DeferredTransportFactory(protocolID: ProtocolDescriptor.ssh.id)
        registry.register(ProtocolDescriptor.ssh, factory: deferredSSH)

        let coder = ProtocolDescriptor.coder(
            supportsTailnetTunnel: BuildFlavor.coderTailnetTunnelSupported
        )
        registry.register(coder, factory: DeferredTransportFactory(protocolID: coder.id))

        self.registry = registry
        self.protocols = [ProtocolDescriptor.ssh, coder]

        let (connectionStore, coderServerStore) = Self.makeConfigurationStores()
        self.connectionStore = connectionStore
        self.coderServerStore = coderServerStore

        let tokenStore = KeychainCoderTokenStore()
        self.coderTokenStore = tokenStore
        self.coderClientFactory = Self.makeCoderClientFactory(tokenStore: tokenStore)
        self.coderRequestLoader = Self.makeCoderRequestLoader()
        self.passwordStore = KeychainPasswordStore()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset-configuration") {
            startupResetTask = Task { @MainActor in
                await Self.resetCoderConfiguration(
                    coderServerStore: coderServerStore,
                    tokenStore: tokenStore
                )
            }
        }
        UITestPasswordServerSeam.startIfRequested()
        #endif
    }

    #if DEBUG
    static func resetCoderConfiguration(
        coderServerStore: any CoderServerStoreProtocol,
        tokenStore: any CoderTokenStoring
    ) async {
        let servers = (try? await coderServerStore.loadCoderServers()) ?? []
        for server in servers {
            try? await tokenStore.deleteToken(for: server.tokenKeychainTag)
            try? await coderServerStore.deleteCoderServer(id: server.id)
        }
    }
    #endif

    private static func makeConfigurationStores() -> (
        connectionStore: any ConnectionStoreProtocol,
        coderServerStore: any CoderServerStoreProtocol
    ) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-fail-persistence") {
            return (FailingConnectionStore(), FailingCoderServerStore())
        }
        #endif

        if let store = try? PersistenceStoreFactory.makeConfigurationStore() {
            return (store, store)
        }

        if let store = try? PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true) {
            return (store, store)
        }

        return (InMemoryConnectionStore(), InMemoryCoderServerStore())
    }

    private static func makeCoderClientFactory(tokenStore: any CoderTokenStoring) -> CoderClientFactory {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-coder-fake-validation") {
            return { injectedTokenStore in
                CoderClient(
                    tokenStore: injectedTokenStore,
                    requestLoader: UITestCoderRequestLoader()
                )
            }
        }
        #endif
        return { CoderClient(tokenStore: $0) }
    }

    private static func makeCoderRequestLoader() -> any CoderRequestLoading {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-coder-fake-validation") {
            return UITestCoderRequestLoader()
        }
        #endif
        return SystemCoderRequestLoader()
    }

    func descriptor(forProtocolID id: String) -> ProtocolDescriptor? {
        registry.descriptor(forProtocolID: id)
    }
}

#if DEBUG

/// Stateful backing store for ``UITestCoderRequestLoader``: counts accepted
/// start-build POSTs and flips started workspaces to a running build so UI
/// tests can assert exactly-once start semantics and the absence of silent
/// workspace mutation (spec §6.1). State is process-lifetime by design —
/// a relaunched UI test process starts from zero.
final class UITestCoderFixtureState: @unchecked Sendable {
    static let shared = UITestCoderFixtureState()

    private let lock = NSLock()
    private var startedWorkspaceIDs: Set<String> = []
    private var startPosts = 0
    private var pendingStartFetches = 0

    var startPostCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startPosts
    }

    func acceptStartPost(workspaceID: String) {
        lock.lock()
        defer { lock.unlock() }
        startPosts += 1
        startedWorkspaceIDs.insert(workspaceID.lowercased())
        if ProcessInfo.processInfo.arguments.contains("--uitest-coder-start-pending-once") {
            pendingStartFetches += 2
        }
    }

    func hasStarted(workspaceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedWorkspaceIDs.contains(workspaceID.lowercased())
    }

    /// With `--uitest-coder-start-pending-once`: the first two detail reads
    /// after a start POST report a provisioning build, keeping the layered
    /// progress screen observable across XCUI's one-second polling cadence.
    func consumePendingStartFetch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingStartFetches > 0 else { return false }
        pendingStartFetches -= 1
        return true
    }
}

private struct UITestCoderRequestLoader: CoderRequestLoading {
    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.path.hasPrefix("/api/v2/") else {
            throw .invalidURL
        }
        let arguments = ProcessInfo.processInfo.arguments
        let path = url.path

        if path == "/api/v2/buildinfo" {
            let body = Data(#"{"version":"v2.36.4-uitest","external_url":""}"#.utf8)
            return CoderHTTPResponse(statusCode: 200, body: body)
        }

        guard path == "/api/v2/workspaces" || path.hasPrefix("/api/v2/workspaces/") else {
            throw .invalidURL
        }
        let segments = path.split(separator: "/").map(String.init)

        guard arguments.contains("--uitest-coder-workspaces") else {
            if arguments.contains("--uitest-coder-unauthorized") {
                return CoderHTTPResponse(statusCode: 401, body: Data())
            }
            if path == "/api/v2/workspaces",
               request.value(forHTTPHeaderField: "Coder-Session-Token") == "fixture-token" {
                let body = Data(#"{"workspaces":[],"count":0}"#.utf8)
                return CoderHTTPResponse(statusCode: 200, body: body)
            }
            return CoderHTTPResponse(statusCode: 401, body: Data())
        }

        // "/api/v2/workspaces" (list) = 3 segments; detail/build paths carry
        // the workspace UUID at index 3 and a sub-resource at index 4.
        guard segments.count >= 4 else {
            let body = Data(#"{"workspaces":[\#(Self.workspaceJSON(id: Self.runningDevID)),\#(Self.workspaceJSON(id: Self.stoppedOldID))],"count":2}"#.utf8)
            return CoderHTTPResponse(statusCode: 200, body: body)
        }
        let id = segments[3]

        if segments.count == 5, segments[4] == "builds", request.httpMethod == "POST" {
            guard id == Self.runningDevID || id == Self.stoppedOldID else {
                return CoderHTTPResponse(statusCode: 404, body: Data())
            }
            UITestCoderFixtureState.shared.acceptStartPost(workspaceID: id)
            let body = Data(#"{"id":"33333333-3333-4333-8333-333333333333","status":"pending","transition":"start","reason":"ssh_connection"}"#.utf8)
            return CoderHTTPResponse(statusCode: 201, body: body)
        }

        if segments.count == 5, segments[4] == "resolve-autostart", request.httpMethod == "GET" {
            let mismatch = arguments.contains("--uitest-coder-param-mismatch")
            let body = Data(#"{"parameter_mismatch":\#(mismatch ? "true" : "false")}"#.utf8)
            return CoderHTTPResponse(statusCode: 200, body: body)
        }

        guard id == Self.runningDevID || id == Self.stoppedOldID else {
            return CoderHTTPResponse(statusCode: 404, body: Data())
        }
        if UITestCoderFixtureState.shared.hasStarted(workspaceID: id),
           UITestCoderFixtureState.shared.consumePendingStartFetch() {
            let body = Data(Self.startingJSON(id: id).utf8)
            return CoderHTTPResponse(statusCode: 200, body: body)
        }
        let body = Data(Self.workspaceJSON(id: id).utf8)
        return CoderHTTPResponse(statusCode: 200, body: body)
    }

    private static let runningDevID = "11111111-1111-1111-1111-111111111111"
    private static let stoppedOldID = "22222222-2222-2222-2222-222222222222"

    private static func workspaceJSON(id: String) -> String {
        let arguments = ProcessInfo.processInfo.arguments
        let name = id == runningDevID ? "Running Dev" : "Stopped Old"
        let multi = arguments.contains("--uitest-coder-multi-agent")
        if UITestCoderFixtureState.shared.hasStarted(workspaceID: id) {
            return runningJSON(id: id, name: name, agents: agentSet(multi: multi && id == runningDevID))
        }
        if id == runningDevID {
            if arguments.contains("--uitest-coder-dormant") {
                return stateJSON(id: id, name: name, dormant: true)
            }
            if arguments.contains("--uitest-coder-workspace-stopped") {
                return stateJSON(id: id, name: name, dormant: false)
            }
        }
        if id == runningDevID {
            return runningJSON(id: id, name: name, agents: agentSet(multi: multi))
        }
        return stateJSON(id: id, name: name, dormant: false)
    }

    private static func agentSet(multi: Bool) -> String {
        multi
            ? #"{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"connected"},{"id":"55555555-5555-4555-8555-555555555555","name":"sidecar","status":"connected"}"#
            : #"{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"connected"}"#
    }

    private static func runningJSON(id: String, name: String, agents: String) -> String {
        #"{"id":"\#(id)","name":"\#(name)","owner_name":"me","dormant_at":null,"latest_build":{"status":"running","transition":"start","resources":[{"agents":[\#(agents)]}]}}"#
    }

    private static func startingJSON(id: String) -> String {
        let name = id == runningDevID ? "Running Dev" : "Stopped Old"
        return #"{"id":"\#(id)","name":"\#(name)","owner_name":"me","dormant_at":null,"latest_build":{"status":"starting","transition":"start","resources":[{"agents":[{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"connecting"}]}]}}"#
    }

    private static func stateJSON(id: String, name: String, dormant: Bool) -> String {
        let dormantAt = dormant ? "\"2026-01-01T00:00:00Z\"" : "null"
        return #"{"id":"\#(id)","name":"\#(name)","owner_name":"me","dormant_at":\#(dormantAt),"latest_build":{"status":"stopped","transition":"stop","resources":[{"agents":[{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"disconnected"}]}]}}"#
    }
}

private actor FailingConnectionStore: ConnectionStoreProtocol {
    func loadConnections() async throws(PersistenceError) -> [Connection] { [] }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? { nil }

    func save(_ connection: Connection) async throws(PersistenceError) {
        throw .operationFailed("the test store rejected the write")
    }

    func deleteConnection(id: UUID) async throws(PersistenceError) {
        throw .operationFailed("the test store rejected the delete")
    }
}

private actor FailingCoderServerStore: CoderServerStoreProtocol {
    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] { [] }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? { nil }

    func save(_ server: CoderServer) async throws(PersistenceError) {
        throw .operationFailed("the test store rejected the write")
    }

    func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        throw .operationFailed("the test store rejected the delete")
    }
}
#endif

/// Honest placeholder until T14 registers real factories: building a
/// transport through the registry for a protocol whose session wiring has
/// not landed fails with the typed registry error — never a silent SSH
/// fallback.
private struct DeferredTransportFactory: TerminalTransportFactory {
    let protocolID: String

    func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        throw .protocolUnavailable(protocolID: protocolID)
    }
}

/// Last-resort store so a SwiftData initialization failure degrades to a
/// readable banner instead of a crash.
private actor InMemoryConnectionStore: ConnectionStoreProtocol {
    private var storage: [UUID: Connection] = [:]

    func loadConnections() async throws(PersistenceError) -> [Connection] {
        storage.values.sorted { $0.name < $1.name }
    }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? {
        storage[id]
    }

    func save(_ connection: Connection) async throws(PersistenceError) {
        storage[connection.id] = connection
    }

    func deleteConnection(id: UUID) async throws(PersistenceError) {
        storage[id] = nil
    }
}

private actor InMemoryCoderServerStore: CoderServerStoreProtocol {
    private var storage: [UUID: CoderServer] = [:]

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        storage.values.sorted { $0.name < $1.name }
    }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        storage[id]
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {
        storage[server.id] = server
    }

    func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        storage[id] = nil
    }
}
