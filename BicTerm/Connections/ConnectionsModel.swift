import BicTermCore
import Foundation
import Observation

@MainActor
@Observable
final class ConnectionsModel {
    struct ConnectionGroup: Identifiable {
        let id: String
        let title: String
        let connections: [Connection]
        let isAvailable: Bool
    }

    private let services: AppServices
    private let connectionStore: any ConnectionStoreProtocol
    private let coderServerStore: any CoderServerStoreProtocol
    private let coderClientFactory: CoderClientFactory
    private let coderTokenStore: any CoderTokenStoring
    private let keyListProvider: () async -> [KeyMetadata]
    private let protocolDescriptors: [ProtocolDescriptor]
    private let descriptorProvider: (String) -> ProtocolDescriptor?

    private(set) var connections: [Connection] = []
    private(set) var keys: [KeyMetadata] = []
    private(set) var isLoading = false
    private(set) var coderStatuses: [UUID: CoderConnectionStatus] = [:]
    var loadError: String?

    #if DEBUG
    private static let seedLabels = [
        "Fixture Ed25519",
        "Fixture Ed25519 Passphrase",
        "Fixture Hop2 Unauthorized",
    ]
    #endif

    init(services: AppServices = .shared) {
        self.services = services
        self.connectionStore = services.connectionStore
        self.coderServerStore = services.coderServerStore
        self.coderClientFactory = services.coderClientFactory
        self.coderTokenStore = services.coderTokenStore
        self.keyListProvider = { (try? await services.keyRepository.list()) ?? [] }
        self.protocolDescriptors = services.protocols
        self.descriptorProvider = services.descriptor(forProtocolID:)
    }

    internal init(
        connectionStore: any ConnectionStoreProtocol,
        coderServerStore: any CoderServerStoreProtocol,
        coderClientFactory: @escaping CoderClientFactory,
        coderTokenStore: any CoderTokenStoring,
        protocolDescriptors: [ProtocolDescriptor],
        descriptorProvider: @escaping (String) -> ProtocolDescriptor?,
        keyListProvider: @escaping () async -> [KeyMetadata] = { [] }
    ) {
        self.services = .shared
        self.connectionStore = connectionStore
        self.coderServerStore = coderServerStore
        self.coderClientFactory = coderClientFactory
        self.coderTokenStore = coderTokenStore
        self.protocolDescriptors = protocolDescriptors
        self.descriptorProvider = descriptorProvider
        self.keyListProvider = keyListProvider
    }

    var groupedConnections: [ConnectionGroup] {
        let grouped = Dictionary(grouping: connections) { $0.type.rawValue }
        var groups = protocolDescriptors.compactMap { descriptor -> ConnectionGroup? in
            guard let group = grouped[descriptor.id], !group.isEmpty else { return nil }
            return ConnectionGroup(
                id: descriptor.id,
                title: descriptor.displayName,
                connections: group,
                isAvailable: true
            )
        }
        let registeredIDs = Set(protocolDescriptors.map(\.id))
        let unavailable = connections.filter { !registeredIDs.contains($0.type.rawValue) }
        if !unavailable.isEmpty {
            groups.append(ConnectionGroup(
                id: "unavailable",
                title: "Unavailable",
                connections: unavailable,
                isAvailable: false
            ))
        }
        return groups
    }

    var protocols: [ProtocolDescriptor] { protocolDescriptors }

    func descriptor(forProtocolID id: String) -> ProtocolDescriptor? {
        descriptorProvider(id)
    }

    func isProtocolAvailable(for connection: Connection) -> Bool {
        descriptor(forProtocolID: connection.type.rawValue) != nil
    }

    func bootstrap() async {
        #if DEBUG
        await runUITestHooksIfRequested()
        await SessionFixtureSeeder.seedIfNeeded()
        #endif
        await reload()
        await refreshCoderStatuses()
    }

    func refreshCoderStatuses() async {
        let coderConnections = connections.filter { $0.type == .coder }
        guard !coderConnections.isEmpty else {
            coderStatuses = [:]
            return
        }

        let servers: [CoderServer]
        do {
            servers = try await coderServerStore.loadCoderServers()
        } catch {
            return
        }

        let client = coderClientFactory(coderTokenStore)
        let byServerID = Dictionary(grouping: coderConnections) { $0.coderRef?.serverID }
        var newStatuses: [UUID: CoderConnectionStatus] = [:]

        for (serverID, connectionsForServer) in byServerID {
            guard let serverID,
                  let server = servers.first(where: { $0.id == serverID }) else {
                for connection in connectionsForServer {
                    newStatuses[connection.id] = fallbackCoderStatus(for: connection)
                }
                continue
            }

            do {
                let workspaces = try await client.workspaces(for: server)
                let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
                for connection in connectionsForServer {
                    guard let ref = connection.coderRef else {
                        newStatuses[connection.id] = fallbackCoderStatus(for: connection, serverName: server.name, serverID: server.id)
                        continue
                    }
                    if let workspace = workspaceByID[ref.workspaceID] {
                        newStatuses[connection.id] = CoderConnectionStatus(
                            workspaceName: workspace.name,
                            serverName: server.name,
                            state: workspace.state,
                            isConnectable: workspace.isConnectable,
                            isUnauthorized: false,
                            serverID: server.id
                        )
                    } else {
                        newStatuses[connection.id] = CoderConnectionStatus(
                            workspaceName: persistedCoderWorkspaceName(for: connection),
                            serverName: server.name,
                            state: nil,
                            isConnectable: false,
                            isUnauthorized: false,
                            serverID: server.id
                        )
                    }
                }
            } catch let error as CoderClientError where error == .unauthorized || error == .tokenStorageFailure {
                for connection in connectionsForServer {
                    newStatuses[connection.id] = CoderConnectionStatus(
                        workspaceName: persistedCoderWorkspaceName(for: connection),
                        serverName: server.name,
                        state: nil,
                        isConnectable: false,
                        isUnauthorized: true,
                        serverID: server.id
                    )
                }
            } catch {
                for connection in connectionsForServer {
                    newStatuses[connection.id] = fallbackCoderStatus(for: connection, serverName: server.name, serverID: server.id)
                }
            }
        }

        coderStatuses = newStatuses
    }

    func reload() async {
        isLoading = true
        loadError = nil
        do {
            connections = try await connectionStore.loadConnections()
            keys = await keyListProvider()
        } catch {
            loadError = "Couldn't load connections: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func coderStatus(for connection: Connection) -> CoderConnectionStatus? {
        coderStatuses[connection.id]
    }

    private func fallbackCoderStatus(
        for connection: Connection,
        serverName: String? = nil,
        serverID: UUID? = nil
    ) -> CoderConnectionStatus {
        let persistedServerName = connection.protocolOptions["coder.serverName"]?.stringValue ?? ""
        return CoderConnectionStatus(
            workspaceName: persistedCoderWorkspaceName(for: connection),
            serverName: serverName ?? persistedServerName,
            state: nil,
            isConnectable: false,
            isUnauthorized: false,
            serverID: serverID ?? connection.coderRef?.serverID
        )
    }

    private func persistedCoderWorkspaceName(for connection: Connection) -> String {
        connection.protocolOptions["coder.workspaceName"]?.stringValue ?? "Unknown workspace"
    }

    struct CoderConnectionStatus: Equatable, Sendable {
        let workspaceName: String
        let serverName: String
        let state: CoderWorkspaceState?
        let isConnectable: Bool
        let isUnauthorized: Bool
        let serverID: UUID?
    }

    func persist(_ connection: Connection) async -> Result<Void, PersistenceError> {
        do {
            try await connectionStore.save(connection)
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[index] = connection
            } else {
                connections.append(connection)
            }
            loadError = nil
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func delete(_ connection: Connection) async {
        do {
            try await connectionStore.deleteConnection(id: connection.id)
            connections.removeAll { $0.id == connection.id }
        } catch {
            loadError = "Couldn't delete connection: \(error.localizedDescription)"
        }
    }

    func duplicate(_ connection: Connection) async {
        let copyName = nextDuplicateName(of: connection.name)
        guard let copy = try? Connection(
            name: copyName,
            type: connection.type,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            keyReference: connection.keyReference,
            jumpChain: connection.jumpChain,
            protocolOptions: connection.protocolOptions,
            coderRef: connection.coderRef
        ) else { return }
        _ = await persist(copy)
    }

    func nextDuplicateName(of name: String) -> String {
        let taken = Set(connections.map(\.name))
        if !taken.contains("\(name) (copy)") { return "\(name) (copy)" }
        var counter = 2
        while taken.contains("\(name) (copy \(counter))") { counter += 1 }
        return "\(name) (copy \(counter))"
    }

    func keyLabel(forReference reference: String) -> String? {
        keys.first { $0.reference == reference }?.label
    }

    // MARK: DEBUG UI-test hooks
    //
    // Launch-argument contracts used by BicTermUITests (DEBUG builds only):
    //   --uitest-reset          wipe connections + re-seed fixture keys
    //   --uitest-seed-keys      idempotently import fixture keys
    //   --uitest-demo           seed a demo 2-hop connection
    //   --uitest-demo-editor    demo connection + auto-open its editor
    //   --uitest-unavailable-connection  seed a known but unregistered protocol

    #if DEBUG
    private func runUITestHooksIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitest-reset")
            || arguments.contains("--uitest-seed-keys")
            || arguments.contains("--uitest-demo")
            || arguments.contains("--uitest-demo-editor")
            || arguments.contains("--uitest-unavailable-connection")
        else { return }

        if arguments.contains("--uitest-reset") || arguments.contains("--uitest-unavailable-connection") {
            await resetConnections()
            await seedFixtureKeys()
        } else if arguments.contains("--uitest-seed-keys") {
            await seedFixtureKeys()
        }

        if arguments.contains("--uitest-demo") || arguments.contains("--uitest-demo-editor") {
            await seedDemoConnection()
        }
        if arguments.contains("--uitest-demo-editor") {
            services.debugAutoOpenEditorForConnectionNamed = "Demo Jump Chain"
        }
        if arguments.contains("--uitest-unavailable-connection") {
            await seedUnavailableConnection()
        }
    }

    private func resetConnections() async {
        if let existing = try? await services.connectionStore.loadConnections() {
            for connection in existing {
                try? await services.connectionStore.deleteConnection(id: connection.id)
            }
        }
    }

    private func seedFixtureKeys() async {
        guard let repository = fixtureKeyRepository() else { return }
        let existing = (try? await repository.list()) ?? []
        for metadata in existing where Self.seedLabels.contains(metadata.label) {
            try? await repository.delete(reference: metadata.reference)
        }

        let fixtures: [(pathComponent: String, label: String, passphrase: Data?)] = [
            ("bicterm-fixture-ed25519", "Fixture Ed25519", nil),
            ("bicterm-fixture-ed25519_passphrase", "Fixture Ed25519 Passphrase", Data("testpass".utf8)),
            ("bicterm-fixture-ed25519_hop2_unauthorized", "Fixture Hop2 Unauthorized", nil),
        ]
        for fixture in fixtures {
            guard let data = fixtureKeyData(named: fixture.pathComponent) else { continue }
            _ = try? await repository.importOpenSSHPrivateKey(
                data,
                passphrase: fixture.passphrase,
                label: fixture.label,
                requiresBiometry: false
            )
        }
    }

    private func seedDemoConnection() async {
        let existing = (try? await services.connectionStore.loadConnections()) ?? []
        guard !existing.contains(where: { $0.name == "Demo Jump Chain" }) else { return }

        let keys = (try? await services.keyRepository.list()) ?? []
        let keyReference = keys.first { $0.label == "Fixture Ed25519" }?.reference
            ?? keys.first?.reference ?? "seed-key-missing"
        let hop1 = Hop(host: "127.0.0.1", port: 12222, username: "hop1user", keyReference: keyReference)
        let hop2 = Hop(host: "127.0.0.1", port: 12223, username: "hop2user", keyReference: keyReference)
        guard let demo = try? Connection(
            name: "Demo Jump Chain",
            type: .ssh,
            host: "10.2.4.9",
            port: 22,
            username: "alice",
            keyReference: keyReference,
            jumpChain: [hop1, hop2]
        ) else { return }
        try? await services.connectionStore.save(demo)
    }

    private func seedUnavailableConnection() async {
        let keys = (try? await services.keyRepository.list()) ?? []
        let keyReference = keys.first?.reference ?? "seed-key-missing"
        guard let connection = try? Connection(
            name: "Future Protocol",
            type: .uppercaseEcho,
            host: "future.example.com",
            port: 2022,
            username: "alice",
            keyReference: keyReference
        ) else { return }
        try? await services.connectionStore.save(connection)
    }

    private func fixtureKeyRepository() -> KeychainKeyRepository? {
        fixtureKeyData(named: "bicterm-fixture-ed25519") != nil ? services.keyRepository : nil
    }

    private func fixtureKeyData(named name: String) -> Data? {
        let connectionsFile = URL(fileURLWithPath: #filePath)
        let repoRoot = connectionsFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keyURL = repoRoot
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent(name)
        return try? Data(contentsOf: keyURL)
    }
    #endif
}
