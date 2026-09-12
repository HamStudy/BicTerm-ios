import BicTermCore
import Foundation
import Observation

/// App-side service wiring for the Connections feature.
///
/// T13 scope: the `TransportRegistry` drives the connection-type selector
/// and capability-driven UI (jump-chain visibility, protocol options).
/// Transport FACTORIES are not consumed yet — T14 wires the session
/// registry, so the v1 protocol registers ``DeferredTransportFactory``
/// which answers a typed ``TransportError/protocolUnavailable`` instead of
/// pretending to connect.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let protocols: [ProtocolDescriptor]
    let connectionStore: any ConnectionStoreProtocol
    let herdStore: any HerdStoreProtocol
    let keyRepository = KeychainKeyRepository()
    let passwordStore: any PasswordStoring

    #if DEBUG
    /// Set by the `--uitest-demo-editor` launch hook: name of a connection
    /// whose editor should be presented once after launch (screenshot aid).
    var debugAutoOpenEditorForConnectionNamed: String?
    #endif

    private let registry: TransportRegistry

    init() {
        var registry = TransportRegistry()
        let deferredSSH = DeferredTransportFactory(protocolID: ProtocolDescriptor.ssh.id)
        registry.register(ProtocolDescriptor.ssh, factory: deferredSSH)
        self.registry = registry
        self.protocols = [ProtocolDescriptor.ssh]

        self.connectionStore = Self.makeConfigurationStore()
        self.herdStore = Self.makeHerdStore()
        self.passwordStore = KeychainPasswordStore()

        #if DEBUG
        UITestPasswordServerSeam.startIfRequested()
        #endif
    }

    private static func makeConfigurationStore() -> any ConnectionStoreProtocol {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-fail-persistence") {
            return FailingConnectionStore()
        }
        #endif

        if let store = try? PersistenceStoreFactory.makeConfigurationStore() {
            return store
        }

        if let store = try? PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true) {
            return store
        }

        return InMemoryConnectionStore()
    }

    private static func makeHerdStore() -> any HerdStoreProtocol {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-fail-persistence") {
            return FailingHerdStore()
        }
        #endif

        if let store = try? PersistenceStoreFactory.makeHerdStore() {
            return store
        }

        if let store = try? PersistenceStoreFactory.makeHerdStore(inMemoryOnly: true) {
            return store
        }

        return InMemoryHerdStore()
    }

    func descriptor(forProtocolID id: String) -> ProtocolDescriptor? {
        registry.descriptor(forProtocolID: id)
    }
}

#if DEBUG

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

private actor FailingHerdStore: HerdStoreProtocol {
    func loadHerds() async throws(PersistenceError) -> [Herd] { [] }

    func herd(id: UUID) async throws(PersistenceError) -> Herd? { nil }

    func save(_ herd: Herd) async throws(PersistenceError) {
        throw .operationFailed("the test store rejected the write")
    }

    func deleteHerd(id: UUID) async throws(PersistenceError) {
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

/// Last-resort herd store mirroring ``InMemoryConnectionStore``: a SwiftData
/// initialization failure degrades to session-only herd support instead of a
/// crash.
private actor InMemoryHerdStore: HerdStoreProtocol {
    private var storage: [UUID: Herd] = [:]

    func loadHerds() async throws(PersistenceError) -> [Herd] {
        storage.values.sorted { $0.name < $1.name }
    }

    func herd(id: UUID) async throws(PersistenceError) -> Herd? {
        storage[id]
    }

    func save(_ herd: Herd) async throws(PersistenceError) {
        storage[herd.id] = herd
    }

    func deleteHerd(id: UUID) async throws(PersistenceError) {
        storage[id] = nil
    }
}
