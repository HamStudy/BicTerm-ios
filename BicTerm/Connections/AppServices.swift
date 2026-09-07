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

        let coder = ProtocolDescriptor(
            id: "coder",
            displayName: "Coder",
            supportsAgentForwarding: false,
            supportsJumpChain: false,
            supportsRoamingResume: false,
            requiresServerComponent: true,
            defaultPort: 443,
            keyAlgorithmsAccepted: ["ssh-ed25519"],
            resumeStrategy: .rehandshake
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

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset-configuration") {
            startupResetTask = Task { @MainActor in
                await Self.resetCoderConfiguration(
                    coderServerStore: coderServerStore,
                    tokenStore: tokenStore
                )
            }
        }
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

    func descriptor(forProtocolID id: String) -> ProtocolDescriptor? {
        registry.descriptor(forProtocolID: id)
    }
}

#if DEBUG
private struct UITestCoderRequestLoader: CoderRequestLoading {
    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.path == "/api/v2/workspaces" else {
            throw .invalidURL
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest-coder-unauthorized") {
            return CoderHTTPResponse(statusCode: 401, body: Data())
        }
        if arguments.contains("--uitest-coder-workspaces") {
            let body = Data(#"{"workspaces":[{"id":"11111111-1111-1111-1111-111111111111","name":"Running Dev","owner_name":"me","latest_build":{"status":"running"}},{"id":"22222222-2222-2222-2222-222222222222","name":"Stopped Old","owner_name":"me","latest_build":{"status":"stopped"}}],"count":2}"#.utf8)
            return CoderHTTPResponse(statusCode: 200, body: body)
        }
        let token = request.value(forHTTPHeaderField: "Coder-Session-Token")
        if token == "fixture-token" {
            let body = Data(#"{"workspaces":[],"count":0}"#.utf8)
            return CoderHTTPResponse(statusCode: 200, body: body)
        }
        return CoderHTTPResponse(statusCode: 401, body: Data())
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
