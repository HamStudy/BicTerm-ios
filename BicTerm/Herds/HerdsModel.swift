import BicTermCore
import Foundation
import Observation

/// App-side model for the Herds section of the connections screen: loads
/// herds plus the connections they reference, resolves per-machine display
/// state (including orphaned machines whose connection was deleted), and
/// owns herd persistence. Deleting a herd only removes the herd record —
/// connections and any live remote sessions are never touched.
@MainActor
@Observable
final class HerdsModel {
    private let connectionStore: any ConnectionStoreProtocol
    private let herdStore: any HerdStoreProtocol

    private(set) var herds: [Herd] = []
    private(set) var connections: [Connection] = []
    var loadError: String?

    init(services: AppServices = .shared) {
        self.connectionStore = services.connectionStore
        self.herdStore = services.herdStore
    }

    init(
        connectionStore: any ConnectionStoreProtocol,
        herdStore: any HerdStoreProtocol
    ) {
        self.connectionStore = connectionStore
        self.herdStore = herdStore
    }

    func bootstrap() async {
        #if DEBUG
        await seedFixtureHerdIfRequested()
        #endif
        await reload()
    }

    func reload() async {
        do {
            herds = try await herdStore.loadHerds()
            connections = try await connectionStore.loadConnections()
            loadError = nil
        } catch {
            loadError = "Couldn't load herds: \(error.localizedDescription)"
        }
    }

    func persist(_ herd: Herd) async -> Result<Void, PersistenceError> {
        do {
            try await herdStore.save(herd)
            if let index = herds.firstIndex(where: { $0.id == herd.id }) {
                herds[index] = herd
            } else {
                herds.append(herd)
            }
            herds.sort { $0.name < $1.name }
            loadError = nil
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Herd-only delete: nothing but the herd record is removed. Machines
    /// whose connections still exist keep connecting exactly as before;
    /// live herd workspaces keep running until the user closes them.
    func delete(_ herd: Herd) async {
        do {
            try await herdStore.deleteHerd(id: herd.id)
            herds.removeAll { $0.id == herd.id }
        } catch {
            loadError = "Couldn't delete herd: \(error.localizedDescription)"
        }
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Herds referencing a connection — drives the delete-confirmation
    /// warning on that connection.
    func herdsReferencing(connectionID: UUID) -> [Herd] {
        herds.filter { herd in
            herd.machines.contains { $0.connectionID == connectionID }
        }
    }

    /// Row subtitle: machine count plus the orphan count when some
    /// machines reference deleted connections.
    func statusSummary(for herd: Herd) -> String {
        let count = herd.machines.count
        let noun = count == 1 ? "machine" : "machines"
        let missing = herd.machines.filter { connection(id: $0.connectionID) == nil }.count
        let base = "\(count) \(noun)"
        guard missing > 0 else { return base }
        let missingNoun = missing == 1 ? "connection is missing" : "connections are missing"
        return "\(base) · \(missing) \(missingNoun)"
    }

    // MARK: DEBUG UI-test hooks
    //
    // Launch-argument contracts used by BicTermUITests (DEBUG builds only):
    //   --uitest-herd-reset     wipe all herds (fresh editor-test state)
    //   --uitest-herd-fixture   seed the two-machine "Fixture Herd" over
    //                           connections named Herd Alpha / Herd Beta
    //                           (live E2E; pair with --uitest-herd-connection)
    //   --uitest-herd-layout    seed a five-machine herd whose connections
    //                           do not exist (switcher layout check; no
    //                           fixtures required)

    #if DEBUG
    private func seedFixtureHerdIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitest-herd-reset")
            || arguments.contains("--uitest-herd-fixture")
            || arguments.contains("--uitest-herd-layout")
        else { return }

        if arguments.contains("--uitest-herd-reset") {
            for herd in (try? await herdStore.loadHerds()) ?? [] {
                try? await herdStore.deleteHerd(id: herd.id)
            }
        }

        if arguments.contains("--uitest-herd-fixture") {
            await seedHerd(
                name: "Fixture Herd",
                machineConnectionNames: ["Herd Alpha", "Herd Beta"],
                sessionNames: [nil, nil]
            )
        }

        if arguments.contains("--uitest-herd-layout") {
            // Deterministic distinct ids that never resolve to connections:
            // every chip renders Offline, so the layout check needs no
            // fixtures.
            let ids = [
                "10000000-0000-0000-0000-000000000001",
                "10000000-0000-0000-0000-000000000002",
                "10000000-0000-0000-0000-000000000003",
                "10000000-0000-0000-0000-000000000004",
                "10000000-0000-0000-0000-000000000005",
            ]
            var machines: [HerdMachine] = []
            for (index, idString) in ids.enumerated() {
                guard let id = UUID(uuidString: idString),
                      let machine = try? HerdMachine(
                          connectionID: id,
                          label: "Layout \(index + 1)",
                          sessionName: nil
                      ) else { continue }
                machines.append(machine)
            }
            await seedHerd(name: "Layout Herd", machines: machines)
        }
    }

    private func seedHerd(
        name: String,
        machineConnectionNames: [String],
        sessionNames: [String?]
    ) async {
        let existing = (try? await connectionStore.loadConnections()) ?? []
        let machines = machineConnectionNames.enumerated().compactMap { index, connectionName -> HerdMachine? in
            guard let connection = existing.first(where: { $0.name == connectionName }) else { return nil }
            return try? HerdMachine(
                connectionID: connection.id,
                sessionName: sessionNames.indices.contains(index) ? sessionNames[index] : nil
            )
        }
        await seedHerd(name: name, machines: machines)
    }

    private func seedHerd(name: String, machines: [HerdMachine]) async {
        let existing = (try? await herdStore.loadHerds()) ?? []
        guard !existing.contains(where: { $0.name == name }),
              let herd = try? Herd(name: name, machines: machines) else { return }
        try? await herdStore.save(herd)
    }
    #endif
}
