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
    private let keyListProvider: () async -> [KeyMetadata]
    private let protocolDescriptors: [ProtocolDescriptor]
    private let descriptorProvider: (String) -> ProtocolDescriptor?

    private(set) var connections: [Connection] = []
    private(set) var keys: [KeyMetadata] = []
    private(set) var isLoading = false
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
        self.keyListProvider = { (try? await services.keyRepository.list()) ?? [] }
        self.protocolDescriptors = services.protocols
        self.descriptorProvider = services.descriptor(forProtocolID:)
    }

    internal init(
        connectionStore: any ConnectionStoreProtocol,
        protocolDescriptors: [ProtocolDescriptor],
        descriptorProvider: @escaping (String) -> ProtocolDescriptor?,
        keyListProvider: @escaping () async -> [KeyMetadata] = { [] }
    ) {
        self.services = .shared
        self.connectionStore = connectionStore
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
        let tags = Self.passwordTags(in: connection)
        do {
            try await connectionStore.deleteConnection(id: connection.id)
            connections.removeAll { $0.id == connection.id }
            let stillReferenced = Set(connections.flatMap(Self.passwordTags(in:)))
            for tag in tags where !stillReferenced.contains(tag) {
                try? await services.passwordStore.deletePassword(for: tag)
            }
        } catch {
            loadError = "Couldn't delete connection: \(error.localizedDescription)"
        }
    }

    /// Keychain tags of a connection's password credentials (destination and
    /// hops). The persisted model stores tags only — never password bytes —
    /// so cleanup is driven entirely from the model.
    static func passwordTags(in connection: Connection) -> [String] {
        var tags: [String] = [connection.promptedPasswordTag]
        if connection.authMethod == .password, !connection.keyReference.isEmpty {
            tags.append(connection.keyReference)
        }
        for hop in connection.jumpChain where hop.authMethod == .password {
            if !hop.keyReference.isEmpty {
                tags.append(hop.keyReference)
            }
        }
        return tags
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
    //   --uitest-herdr-connection        seed a herdr-enabled fixture connection
    //                                     (port via --uitest-herdr-connection-port)
    //   --uitest-herd-e2e                seed the Herd Alpha/Beta machine
    //                                     connections for the herd live E2E

    #if DEBUG
    private func runUITestHooksIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitest-reset")
            || arguments.contains("--uitest-seed-keys")
            || arguments.contains("--uitest-demo")
            || arguments.contains("--uitest-demo-editor")
            || arguments.contains("--uitest-unavailable-connection")
            || arguments.contains("--uitest-herdr-connection")
            || arguments.contains("--uitest-herd-e2e")
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
        if arguments.contains("--uitest-herdr-connection") {
            await seedHerdrConnection()
        }
        if arguments.contains("--uitest-herd-e2e") {
            await seedHerdE2EConnections()
        }
    }

    private func resetConnections() async {
        if let existing = try? await services.connectionStore.loadConnections() {
            for connection in existing {
                try? await services.connectionStore.deleteConnection(id: connection.id)
                for tag in Self.passwordTags(in: connection) {
                    try? await services.passwordStore.deletePassword(for: tag)
                }
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

    /// Seeds "Herdr Alpha", the herdr-enabled fixture connection the live
    /// connect-flow E2E connects to (default hop-1 on 12222).
    private func seedHerdrConnection() async {
        let existing = (try? await services.connectionStore.loadConnections()) ?? []
        guard !existing.contains(where: { $0.name == "Herdr Alpha" }) else { return }
        let keys = (try? await services.keyRepository.list()) ?? []
        let keyReference = keys.first { $0.label == "Fixture Ed25519" }?.reference
            ?? keys.first?.reference ?? "seed-key-missing"
        let port = TerminalSceneUITest.value(after: "--uitest-herdr-connection-port")
            .flatMap(Int.init) ?? 12222
        guard let options = try? ProtocolOptions([
            ProtocolOptions.herdrEnabledKey: .bool(true)
        ]) else { return }
        guard let connection = try? Connection(
            name: "Herdr Alpha",
            type: .ssh,
            host: "127.0.0.1",
            port: port,
            username: SessionFixtureSeeder.fixtureUsername(),
            keyReference: keyReference,
            protocolOptions: options
        ) else { return }
        try? await services.connectionStore.save(connection)
    }

    /// Seeds the two plain SSH connections the herd live E2E uses as
    /// machines: one per fixture sshd port (herd machines do not need the
    /// per-connection herdr toggle — the herd path always opens herdr).
    private func seedHerdE2EConnections() async {
        let existing = (try? await services.connectionStore.loadConnections()) ?? []
        let keys = (try? await services.keyRepository.list()) ?? []
        let keyReference = keys.first { $0.label == "Fixture Ed25519" }?.reference
            ?? keys.first?.reference ?? "seed-key-missing"
        for (name, port) in [("Herd Alpha", 12222), ("Herd Beta", 12223)] {
            guard !existing.contains(where: { $0.name == name }) else { continue }
            guard let connection = try? Connection(
                name: name,
                type: .ssh,
                host: "127.0.0.1",
                port: port,
                username: SessionFixtureSeeder.fixtureUsername(),
                keyReference: keyReference
            ) else { continue }
            try? await services.connectionStore.save(connection)
        }
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
