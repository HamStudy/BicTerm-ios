import BicTermCore
import HerdrClientCore
import XCTest

@testable import BicTerm

/// T8 herd session coordinator: connect-all fan-out behind one workspace,
/// per-machine failure isolation, endpoint identity, selection coherence
/// (persisted last-selected machine, user switches never overridden by a
/// late-connecting machine), and the in-flight dedup keyed by herd id.
@MainActor
final class HerdSessionCoordinatorTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var center: HerdrWorkspaceCenter!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        center = HerdrWorkspaceCenter()
        defaultsSuiteName = "herd-coordinator-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    private func vendorGolden(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("Vendor/herdr/herdr-protocol/tests/fixtures/golden/\(name).bin"))
    }

    private func herdrGolden(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("Fixtures/herdr/golden/\(name).bin"))
    }

    private func fenceScript() throws -> [Data] {
        [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("surface-ack-2x2"),
            try herdrGolden("surface-2x2"),
            try herdrGolden("surface-sync-ack-2x2"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("surface-2x2"),
            try herdrGolden("presentation-ready-2x2"),
        ]
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeConnection(name: String) throws -> Connection {
        try Connection(
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: "fixture",
            keyReference: "seed-key"
        )
    }

    private func makeHerd(
        connections: [Connection],
        sessionNames: [String?] = []
    ) throws -> Herd {
        var machines: [HerdMachine] = []
        for (index, connection) in connections.enumerated() {
            machines.append(try HerdMachine(
                connectionID: connection.id,
                sessionName: sessionNames.indices.contains(index) ? sessionNames[index] : nil
            ))
        }
        return try Herd(name: "Test Herd", machines: machines)
    }

    private func endpoint(
        _ herd: Herd, _ connection: Connection
    ) -> HerdrEndpointID {
        BicTerm.HerdSessionCoordinator.HerdDescriptor.endpointID(
            herdID: herd.id, connectionID: connection.id
        )
    }

    private func firstEntry() async throws -> HerdrWorkspaceCenter.Entry {
        let ready = await waitUntil { !self.center.entries.isEmpty }
        XCTAssertTrue(ready, "the herd workspace must open")
        return try XCTUnwrap(center.entries.first)
    }

    // MARK: - Fan-out

    func testOpenFansOutOneEndpointPerMachineAndConnectsAll() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let herd = try makeHerd(connections: [alpha, beta])
        let script = try fenceScript()
        var presented: [UUID] = []

        let connect: HerdSessionCoordinator.MachineConnect = { _, _ in
            HerdrReplayTransport(script: script)
        }
        let coordinator = HerdSessionCoordinator(
            center: center,
            defaults: defaults,
            connectMachine: connect,
            lookupConnection: { id in
                [alpha, beta].first { $0.id == id }
            }
        )
        coordinator.open(herd, hostKeyVerifier: nil) { presented.append($0) }

        let alphaEndpoint = endpoint(herd, alpha)
        let betaEndpoint = endpoint(herd, beta)
        XCTAssertEqual(
            alphaEndpoint.rawValue,
            "herd/\(herd.id.uuidString)/machine/\(alpha.id.uuidString)",
            "endpoint ids follow the herd/<herdId>/machine/<connectionId> contract"
        )

        let opened = await waitUntil { presented.count == 1 }
        XCTAssertTrue(opened)
        XCTAssertEqual(center.entries.count, 1, "one workspace entry for the whole herd")
        let entry = try XCTUnwrap(center.entries.first)
        XCTAssertEqual(entry.herd?.machines.count, 2)
        XCTAssertEqual(entry.herd?.machines.map(\.label), ["Alpha", "Beta"])

        let model = entry.model
        let bothOnline = await waitUntil(timeout: 10) {
            model.endpoints[alphaEndpoint]?.phase == .online
                && model.endpoints[betaEndpoint]?.phase == .online
        }
        XCTAssertTrue(bothOnline, "every machine endpoint reaches Online")
        let surfacesCommitted = await waitUntil(timeout: 10) {
            model.endpoints[alphaEndpoint]?.surface != nil
                && model.endpoints[betaEndpoint]?.surface != nil
        }
        XCTAssertTrue(surfacesCommitted, "each endpoint commits its own surface")
    }

    // MARK: - Isolation

    func testFailingMachineNeverBlocksTheOthers() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let herd = try makeHerd(connections: [alpha, beta])
        let script = try fenceScript()

        let connect: HerdSessionCoordinator.MachineConnect =
            { (connection: Connection, _: HostKeyVerifier?)
                async throws(HerdrEndpointConnectorError) -> any HerdrByteTransport in
                if connection.id == alpha.id {
                    throw HerdrEndpointConnectorError.sshEstablish(.unreachable)
                }
                return HerdrReplayTransport(script: script)
            }
        let coordinator = HerdSessionCoordinator(
            center: center,
            defaults: defaults,
            connectMachine: connect,
            lookupConnection: { id in
                [alpha, beta].first { $0.id == id }
            }
        )
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }

        let alphaEndpoint = endpoint(herd, alpha)
        let betaEndpoint = endpoint(herd, beta)
        let entry = try await firstEntry()

        let settled = await waitUntil(timeout: 10) {
            entry.model.endpoints[alphaEndpoint]?.phase == .failed
                && entry.model.endpoints[betaEndpoint]?.phase == .online
        }
        XCTAssertTrue(settled, "the failed machine settles failed while the other reaches online")
        XCTAssertEqual(
            entry.model.endpoints[alphaEndpoint]?.diagnostic?.kind, .transportLost,
            "SSH establish failures map to the typed transport-lost diagnostic"
        )
        XCTAssertNil(entry.model.endpoints[betaEndpoint]?.diagnostic)
        let betaSurface = await waitUntil(timeout: 10) {
            entry.model.endpoints[betaEndpoint]?.surface != nil
        }
        XCTAssertTrue(betaSurface, "the healthy machine's surface commits")
    }

    // MARK: - Orphans

    func testOrphanMachineIsSkippedAndLabeledMissing() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let orphanID = UUID()
        let herd = try Herd(name: "Orphan Herd", machines: [
            try HerdMachine(connectionID: alpha.id),
            try HerdMachine(connectionID: orphanID),
        ])
        let script = try fenceScript()
        let counter = LockedCounter()

        let connect: HerdSessionCoordinator.MachineConnect = { _, _ in
            counter.increment()
            return HerdrReplayTransport(script: script)
        }
        let coordinator = HerdSessionCoordinator(
            center: center,
            defaults: defaults,
            connectMachine: connect,
            lookupConnection: { id in id == alpha.id ? alpha : nil }
        )
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }

        let entry = try await firstEntry()
        let orphanMachine = try XCTUnwrap(
            entry.herd?.machines.first { $0.connectionID == orphanID }
        )
        XCTAssertEqual(orphanMachine.label, "Missing connection")

        let connected = await waitUntil(timeout: 10) {
            entry.model.endpoints[self.endpoint(herd, alpha)]?.phase == .online
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(counter.value, 1, "the orphan machine never spawns a connector pass")
        XCTAssertNil(
            entry.model.endpoints[orphanMachine.endpointID],
            "no endpoint state exists for the orphan until the user re-adds it"
        )
    }

    // MARK: - Selection

    func testPersistedSelectionRestoresAndSurvivesLateConnects() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let herd = try makeHerd(connections: [alpha, beta])
        let script = try fenceScript()

        defaults.set(
            beta.id.uuidString,
            forKey: HerdSessionCoordinator.selectionKey(herdID: herd.id)
        )

        let connect: HerdSessionCoordinator.MachineConnect = { connection, _ in
            if connection.id == alpha.id {
                try? await Task.sleep(for: .milliseconds(400))
            }
            return HerdrReplayTransport(script: script)
        }
        let coordinator = HerdSessionCoordinator(
            center: center,
            defaults: defaults,
            connectMachine: connect,
            lookupConnection: { id in
                [alpha, beta].first { $0.id == id }
            }
        )
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }
        let entry = try await firstEntry()
        let model = entry.model

        let betaEndpoint = endpoint(herd, beta)
        let alphaEndpoint = endpoint(herd, alpha)
        XCTAssertEqual(
            model.selectedEndpointID, betaEndpoint,
            "the persisted last-selected machine is restored"
        )

        let allOnline = await waitUntil(timeout: 10) {
            model.endpoints[alphaEndpoint]?.phase == .online
                && model.endpoints[betaEndpoint]?.phase == .online
        }
        XCTAssertTrue(allOnline)
        XCTAssertEqual(
            model.selectedEndpointID, betaEndpoint,
            "a machine connecting late never steals selection"
        )

        let alphaMachine = try XCTUnwrap(
            entry.herd?.machines.first { $0.connectionID == alpha.id }
        )
        coordinator.select(alphaMachine, in: model)
        XCTAssertEqual(model.selectedEndpointID, alphaEndpoint)
        XCTAssertEqual(
            defaults.string(forKey: HerdSessionCoordinator.selectionKey(herdID: herd.id)),
            alpha.id.uuidString,
            "the user's switch persists as the herd's last-selected machine"
        )
    }

    func testSelectionSwitchMidActivationKeepsBothEndpointsCoherent() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let herd = try makeHerd(connections: [alpha, beta])
        let script = try fenceScript()

        let connect: HerdSessionCoordinator.MachineConnect = { _, _ in
            HerdrReplayTransport(script: script)
        }
        let coordinator = HerdSessionCoordinator(
            center: center,
            defaults: defaults,
            connectMachine: connect,
            lookupConnection: { id in
                [alpha, beta].first { $0.id == id }
            }
        )
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }
        let entry = try await firstEntry()
        let model = entry.model

        let alphaEndpoint = endpoint(herd, alpha)
        let betaEndpoint = endpoint(herd, beta)
        let betaMachine = try XCTUnwrap(
            entry.herd?.machines.first { $0.connectionID == beta.id }
        )

        let firstConnecting = await waitUntil {
            model.endpoints[alphaEndpoint]?.phase == .connecting
                || model.endpoints[alphaEndpoint]?.phase == .online
        }
        XCTAssertTrue(firstConnecting)
        coordinator.select(betaMachine, in: model)

        let bothOnline = await waitUntil(timeout: 10) {
            model.endpoints[alphaEndpoint]?.phase == .online
                && model.endpoints[betaEndpoint]?.phase == .online
        }
        XCTAssertTrue(
            bothOnline,
            "switching selection mid-activation never disturbs either activation transaction"
        )
        XCTAssertEqual(
            model.selectedEndpointID, betaEndpoint,
            "the user's switch stands after both endpoints commit"
        )
        let surfacesKept = await waitUntil(timeout: 10) {
            model.endpoints[alphaEndpoint]?.surface != nil
                && model.endpoints[betaEndpoint]?.surface != nil
        }
        XCTAssertTrue(surfacesKept, "both endpoints keep committed surfaces after the switch")
    }

    // MARK: - Dedup

    func testReentrantOpensYieldOneConnectPass() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let herd = try makeHerd(connections: [alpha, beta])
        let script = try fenceScript()
        let gate = AsyncStream<Void>.makeStream()

        let connect: HerdSessionCoordinator.MachineConnect = { _, _ in
            _ = await gate.stream.first { _ in true }
            return HerdrReplayTransport(script: script)
        }
        let coordinator = HerdSessionCoordinator(
            center: center,
            defaults: defaults,
            connectMachine: connect,
            lookupConnection: { id in
                [alpha, beta].first { $0.id == id }
            }
        )
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }
        coordinator.open(herd, hostKeyVerifier: nil) { _ in }
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(center.entries.count, 1, "re-entrant opens open one workspace")
        gate.continuation.finish()

        let settled = await waitUntil(timeout: 10) {
            let endpoints = self.center.entries.first?.model.endpoints ?? [:]
            return endpoints.count == 2
                && endpoints.values.allSatisfy { $0.phase == .online }
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            coordinator.debugConnectAttempts, 2,
            "three opens fired exactly one connector pass per machine"
        )
    }

    // MARK: - Herd deletion isolation

    func testDeletingAHerdNeverTouchesConnections() async throws {
        let alpha = try makeConnection(name: "Alpha")
        let herdStore = SpyHerdStore()
        let connectionStore = SpyConnectionStore(connections: [alpha])
        let model = HerdsModel(
            connectionStore: connectionStore,
            herdStore: herdStore
        )
        try await herdStore.save(try makeHerd(connections: [alpha]))
        await model.reload()

        await model.delete(model.herds[0])

        let herdDeleted = await herdStore.deleted
        let connectionDeletes = await connectionStore.deleteCalls
        let connectionSaves = await connectionStore.saveCalls
        XCTAssertTrue(herdDeleted, "the herd record is deleted")
        XCTAssertEqual(connectionDeletes, 0, "connections are never touched")
        XCTAssertEqual(connectionSaves, 0)
        XCTAssertTrue(model.herds.isEmpty)
        XCTAssertEqual(
            model.connections.map(\.name), ["Alpha"],
            "the connection list survives the herd delete"
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private actor SpyHerdStore: HerdStoreProtocol {
    var storage: [UUID: Herd] = [:]
    var deleted = false

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
        deleted = true
        storage[id] = nil
    }
}

private actor SpyConnectionStore: ConnectionStoreProtocol {
    var storage: [UUID: Connection]
    var deleteCalls = 0
    var saveCalls = 0

    init(connections: [Connection]) {
        storage = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
    }

    func loadConnections() async throws(PersistenceError) -> [Connection] {
        storage.values.sorted { $0.name < $1.name }
    }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? {
        storage[id]
    }

    func save(_ connection: Connection) async throws(PersistenceError) {
        saveCalls += 1
        storage[connection.id] = connection
    }

    func deleteConnection(id: UUID) async throws(PersistenceError) {
        deleteCalls += 1
        storage[id] = nil
    }
}
