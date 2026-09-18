import BicTermCore
import XCTest

@testable import BicTerm

/// T6 catalog seeding semantics: the herd edit a user makes must be
/// reflected in what the embedded client reads — on the NEXT open (the
/// catalog is rewritten atomically per seed, so a removed machine is gone
/// and an added one appears) AND mid-run: a config reload re-seeds the
/// live herd run's `endpoints.json` (embed patch 0008), whose rewrite the
/// client's 1s poll treats as a reload that re-arms attention-state
/// machines. The selection file is NEVER rewritten mid-run — the live
/// client owns it.
@MainActor
final class HerdEmbedCatalogTests: XCTestCase {
    private var stateHome: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("herd-embed-catalog-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        stateHome = base
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateHome)
    }

    private func machine(_ label: String, id: String = UUID().uuidString) -> HerdrEmbedMachine {
        HerdrEmbedMachine(
            profileID: id,
            label: label,
            target: "user@\(label).example:22",
            sessionName: "default"
        )
    }

    private func seededProfileIDs() throws -> [String] {
        let file = stateHome.appendingPathComponent("herdr/client/endpoints.json")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ssh = try XCTUnwrap(object["ssh"] as? [[String: Any]])
        return ssh.compactMap { $0["id"] as? String }
    }

    private func seededSelection() throws -> String? {
        let file = stateHome.appendingPathComponent("herdr/client/endpoint-selection.json")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object["selected_profile"] as? String
    }

    func testReseedingReplacesTheCatalogSoHerdEditsReflectOnNextOpen() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        let beta = machine("beta", id: "profile-beta")

        try HerdrEmbedClientCatalog.seed(
            machines: [alpha, beta],
            selectedProfileID: "profile-alpha",
            stateHome: stateHome
        )
        XCTAssertEqual(Set(try seededProfileIDs()), ["profile-alpha", "profile-beta"])
        XCTAssertEqual(try seededSelection(), "profile-alpha")

        let gamma = machine("gamma", id: "profile-gamma")
        try HerdrEmbedClientCatalog.seed(
            machines: [beta, gamma],
            selectedProfileID: "profile-gamma",
            stateHome: stateHome
        )
        let ids = Set(try seededProfileIDs())
        XCTAssertEqual(ids, ["profile-beta", "profile-gamma"])
        XCTAssertFalse(
            ids.contains("profile-alpha"),
            "a machine removed from the herd is gone from the catalog on re-seed"
        )
        XCTAssertEqual(
            try seededSelection(), "profile-gamma",
            "the seeded selection follows the herd's persisted machine choice"
        )
    }

    func testSeedMarksEveryMachineEnabledWithCatalogTargets() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        try HerdrEmbedClientCatalog.seed(
            machines: [alpha],
            selectedProfileID: nil,
            stateHome: stateHome
        )
        let file = stateHome.appendingPathComponent("herdr/client/endpoints.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any]
        )
        let entry = try XCTUnwrap(
            (object["ssh"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["target"] as? String, "user@alpha.example:22")
        XCTAssertEqual(entry["session"] as? String, "default")
        XCTAssertNil(
            try seededSelection(),
            "no selection is JSON null — the client falls back to Local without a warning"
        )
    }

    // MARK: - Mid-run re-seed (config reload → embed patch 0008)

    private func selectionFileBytes() throws -> Data {
        try Data(
            contentsOf: stateHome.appendingPathComponent("herdr/client/endpoint-selection.json")
        )
    }

    private func endpointsObject() throws -> [String: Any] {
        let file = stateHome.appendingPathComponent("herdr/client/endpoints.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any]
        )
    }

    func testMidRunReseedRewritesEndpointsAndLeavesSelectionByteIdentical() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        let beta = machine("beta", id: "profile-beta")
        try HerdrEmbedClientCatalog.seed(
            machines: [alpha, beta],
            selectedProfileID: "profile-alpha",
            stateHome: stateHome
        )
        let selectionBefore = try selectionFileBytes()

        let gamma = machine("gamma", id: "profile-gamma")
        try HerdrEmbedClientCatalog.reseed(
            machines: [beta, gamma],
            stateHome: stateHome
        )

        // The rewrite is atomic (same writeJSON path as seed): a torn
        // write would surface here as a JSON parse failure.
        let ids = Set(try seededProfileIDs())
        XCTAssertEqual(ids, ["profile-beta", "profile-gamma"])
        XCTAssertFalse(
            ids.contains("profile-alpha"),
            "a machine removed from the herd retires from the live catalog"
        )
        XCTAssertEqual(
            try selectionFileBytes(), selectionBefore,
            "a mid-run re-seed never rewrites the client-owned selection file"
        )
    }

    func testMidRunReseedKeepsSelectionOutOfTheCatalog() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        try HerdrEmbedClientCatalog.seed(
            machines: [alpha],
            selectedProfileID: "profile-alpha",
            stateHome: stateHome
        )

        try HerdrEmbedClientCatalog.reseed(machines: [alpha], stateHome: stateHome)

        XCTAssertNil(
            try endpointsObject()["selected_profile"],
            "the client's reload path reads only the ssh array — selection stays in the client-owned file"
        )
        XCTAssertEqual(try seededSelection(), "profile-alpha")
    }

    func testMidRunReseedWithIdenticalContentIsAValidRetrySignal() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        let beta = machine("beta", id: "profile-beta")
        try HerdrEmbedClientCatalog.seed(
            machines: [alpha, beta],
            selectedProfileID: "profile-alpha",
            stateHome: stateHome
        )
        let selectionBefore = try selectionFileBytes()

        // The identical-content rewrite IS the "retry attention machines
        // now" signal (patch 0008's mtime detection fires on any rewrite);
        // the Swift side's contract is that the rewrite succeeds and the
        // catalog stays valid and unchanged in content.
        try HerdrEmbedClientCatalog.reseed(
            machines: [alpha, beta],
            stateHome: stateHome
        )

        XCTAssertEqual(Set(try seededProfileIDs()), ["profile-alpha", "profile-beta"])
        XCTAssertEqual(try selectionFileBytes(), selectionBefore)
    }

    // MARK: - Membership re-resolution (HerdrEmbedHerdSeeder.reloadLinks)

    private func connection(named name: String) throws -> Connection {
        try Connection(
            name: name,
            type: .ssh,
            host: "\(name).example",
            port: 22,
            username: "user"
        )
    }

    func testReloadLinksReResolvesMembershipFromCurrentStoreState() async throws {
        let alphaConnection = try connection(named: "alpha")
        let betaConnection = try connection(named: "beta")
        let gammaConnection = try connection(named: "gamma")
        let herd = try Herd(
            name: "fleet",
            machines: [
                HerdMachine(connectionID: alphaConnection.id),
                HerdMachine(connectionID: betaConnection.id, sessionName: "logs"),
            ]
        )
        let store = StubHerdStore(herd: herd)
        let lookup: HerdSessionCoordinator.ConnectionLookup = { id in
            [alphaConnection, betaConnection, gammaConnection].first { $0.id == id }
        }

        let initialResolved = await HerdrEmbedHerdSeeder.reloadLinks(
            herdID: herd.id, herdStore: store, lookup: lookup
        )
        let initial = try XCTUnwrap(initialResolved)
        XCTAssertEqual(initial.map(\.machine.label), ["alpha", "beta"])
        XCTAssertEqual(initial.last?.machine.sessionName, "logs")

        // The herd edit lands in the store AFTER the run opened: the
        // re-seed sees current state — alpha removed, gamma added, and
        // beta's session override edited.
        let edited = try Herd(
            id: herd.id,
            name: herd.name,
            machines: [
                HerdMachine(connectionID: betaConnection.id, sessionName: "main"),
                HerdMachine(connectionID: gammaConnection.id),
            ]
        )
        try await store.save(edited)

        let reresolved = await HerdrEmbedHerdSeeder.reloadLinks(
            herdID: herd.id, herdStore: store, lookup: lookup
        )
        let resolved = try XCTUnwrap(reresolved)
        XCTAssertEqual(resolved.map(\.machine.label), ["beta", "gamma"])
        XCTAssertEqual(resolved.first?.machine.sessionName, "main")
        XCTAssertEqual(
            resolved.map(\.machine.profileID),
            [betaConnection, gammaConnection].map { HerdrEmbedMachine.profileID(for: $0.id) }
        )
    }

    func testReloadLinksSkipsMachinesWhoseConnectionNoLongerResolves() async throws {
        let alphaConnection = try connection(named: "alpha")
        let missingID = UUID()
        let herd = try Herd(
            name: "fleet",
            machines: [
                HerdMachine(connectionID: alphaConnection.id),
                HerdMachine(connectionID: missingID),
            ]
        )
        let store = StubHerdStore(herd: herd)
        let lookup: HerdSessionCoordinator.ConnectionLookup = { id in
            id == alphaConnection.id ? alphaConnection : nil
        }

        let resolvedLinks = await HerdrEmbedHerdSeeder.reloadLinks(
            herdID: herd.id, herdStore: store, lookup: lookup
        )
        let links = try XCTUnwrap(resolvedLinks)
        XCTAssertEqual(
            links.map(\.machine.profileID),
            [HerdrEmbedMachine.profileID(for: alphaConnection.id)],
            "a deleted connection's machine is skipped — the catalog reflects the resolvable rest"
        )
    }

    func testReloadLinksReturnsNilWhenTheHerdRecordIsGone() async throws {
        let store = StubHerdStore(herd: nil)
        let links = await HerdrEmbedHerdSeeder.reloadLinks(
            herdID: UUID(),
            herdStore: store,
            lookup: { _ in nil }
        )
        XCTAssertNil(
            links,
            "a deleted herd record must not yank a live workspace's catalog"
        )
    }

    // MARK: - Coordinator/runtime guards

    func testModeACoordinatorNeverReseeds() async throws {
        let coordinator = HerdrEmbedTransportCoordinator(
            connection: try connection(named: "solo"),
            hostKeyVerifier: nil
        )
        await coordinator.reseedCatalog()
        XCTAssertTrue(
            coordinator.eventLines.isEmpty,
            "Mode A keeps its empty catalog — a config reload never writes it"
        )
    }

    func testHerdCoordinatorReseedIsANoOpBeforePrepare() async throws {
        let alphaConnection = try connection(named: "alpha")
        let herd = try Herd(
            name: "fleet",
            machines: [HerdMachine(connectionID: alphaConnection.id)]
        )
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: [
                HerdrEmbedMachineLink(
                    machine: .forConnection(alphaConnection),
                    connection: alphaConnection,
                    bridgeSessionName: nil
                ),
            ],
            herdID: herd.id,
            hostKeyVerifier: nil
        )
        coordinator.reseedHerdStoreForTesting = StubHerdStore(herd: herd)
        coordinator.reseedConnectionLookupForTesting = { _ in alphaConnection }

        // No prepare() ran — no live run — so the re-seed must not write.
        await coordinator.reseedCatalog()
        XCTAssertTrue(coordinator.eventLines.isEmpty)
    }

    func testRuntimeReseedHookIsANoOpWithoutALiveRun() async {
        let runtime = HerdrEmbedRuntime()
        await runtime.reseedCatalogIfLive()
        XCTAssertEqual(runtime.phase, .idle)
    }
}

/// Store double for the re-seed resolution path (shared with the herd
/// fixture tests): a single optional herd record, writable mid-test.
actor StubHerdStore: HerdStoreProtocol {
    private var herd: Herd?

    init(herd: Herd?) {
        self.herd = herd
    }

    func loadHerds() async throws(PersistenceError) -> [Herd] {
        herd.map { [$0] } ?? []
    }

    func herd(id: UUID) async throws(PersistenceError) -> Herd? {
        herd?.id == id ? herd : nil
    }

    func save(_ herd: Herd) async throws(PersistenceError) {
        self.herd = herd
    }

    func deleteHerd(id: UUID) async throws(PersistenceError) {
        if herd?.id == id { herd = nil }
    }
}
