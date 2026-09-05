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
    let keyRepository = KeychainKeyRepository()

    #if DEBUG
    /// Set by the `--uitest-demo-editor` launch hook: name of a connection
    /// whose editor should be presented once after launch (screenshot aid).
    var debugAutoOpenEditorForConnectionNamed: String?
    #endif

    private let registry: TransportRegistry

    init() {
        var registry = TransportRegistry()

        // v1 protocols: ssh (T11 descriptor) and coder (editing/persistence
        // now; transport + workspace picker land in T19).
        let deferredSSH = DeferredTransportFactory(protocolID: ProtocolDescriptor.ssh.id)
        registry.register(ProtocolDescriptor.ssh, factory: deferredSSH)

        // coder — v1 registered for editing/persistence; workspace wiring
        // lands in T19. Until its tunnel exists, it advertises fresh
        // handshakes rather than native roaming; default TLS port is 443.
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

        // SwiftData-backed T2 configuration store. A failure here is fatal
        // for editing; the in-memory fallback keeps the UI alive so the
        // error surfaces in the list banner instead of crashing.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-fail-persistence") {
            self.connectionStore = FailingConnectionStore()
        } else if let store = try? PersistenceStoreFactory.makeConfigurationStore() {
            self.connectionStore = store
        } else {
            self.connectionStore = (try? PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true))
                ?? InMemoryConnectionStore()
        }
        #else
        if let store = try? PersistenceStoreFactory.makeConfigurationStore() {
            self.connectionStore = store
        } else {
            self.connectionStore = (try? PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true))
                ?? InMemoryConnectionStore()
        }
        #endif
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
