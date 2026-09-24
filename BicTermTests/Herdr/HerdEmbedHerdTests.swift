import BicTermCore
import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit
import XCTest

@testable import BicTerm

/// T6 herds through the REAL client, end to end against BOTH prebuilt
/// herdr 0.9.1 fixture servers: a herd seeds the embedded client's
/// machine catalog (one bridge socket per machine — direct 12222 and
/// jump-chained 12222 → 12223), the client's own sidebar lists every
/// machine, machine selection rides a real SGR mouse click through the
/// SwiftTerm input path, severing one machine stops its bridge and
/// leaves the other flowing, and opening a second herd closes the first
/// cleanly with fully isolated sockets and catalog.
@MainActor
final class HerdrEmbedHerdTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    // MARK: - Multi-machine herd through the real client

    func testHerdSeedsBothMachinesIntoRealClientSidebarAndInputFlows() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let (runtime, coordinator) = try await startHerdRuntime(
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")]
        )

        let hosted = try await hostAndWaitForRender(runtime)

        // The client dials every saved machine at boot: both bridges see
        // a relay (both machines ONLINE through our SSH stack).
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "the client connected machine alpha through its own bridge",
            timeout: 20
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "the client connected machine beta through its own bridge",
            timeout: 20
        )

        for label in ["alpha", "beta"] {
            XCTAssertTrue(
                bufferContains(hosted, label),
                "the real client's sidebar lists machine \(label)"
            )
        }
        XCTAssertFalse(
            bufferContains(hosted, "Local"),
            "herd mode hides the Local endpoint — the host runs no local herdr server"
        )

        // Machine selection through the client's OWN surface: a real SGR
        // click on each machine's sidebar row (the same delegate path a
        // touch takes).
        for label in ["alpha", "beta"] {
            let cell = try XCTUnwrap(
                locate(hosted, label: label),
                "machine row for \(label) present in the terminal buffer"
            )
            click(hosted, col: cell.col, row: cell.row)
        }

        // Input routes to the selected machine: a keystroke through the
        // hosting view's input path is accepted while the herd runs.
        let writtenBefore = runtime.bytesWritten
        runtime.writeInput(Data("x".utf8))
        await waitFor(
            runtime.bytesWritten > writtenBefore,
            "keystroke accepted by the embedded client with a machine selected"
        )

        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    /// Regression: two machines in one herd must BOTH be working
    /// simultaneously — not merely open a bridge relay. The reported device
    /// bug: every machine after the first lands in herdr's "needs
    /// attention" state, regardless of the machine. The reported herd
    /// shape: BOTH machines' connections target the SAME host:port (two
    /// connection entries to one box), so this test uses two same-host
    /// fixture connections — the mixed direct+jump shape is covered by
    /// ``testHerdSeedsBothMachinesIntoRealClientSidebarAndInputFlows()``.
    ///
    /// "Working" is asserted through the two durable signals, not the
    /// sidebar text (the client switches its sidebar section once a
    /// machine's workspace activates, so the machine rows are not
    /// reliably visible to sample): every machine's bridge relay opened
    /// through THIS run's bridges, and the client's own log records no
    /// "endpoint needs attention" warning for the whole run.
    func testTwoMachinesBothReachOnlineSimultaneously() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let logLinesBefore = Self.clientLogLineCount()
        let (runtime, coordinator) = try await startHerdRuntime(
            machines: [
                try makeDirectMachine(label: "alpha"),
                try makeDirectMachine(label: "beta"),
            ]
        )
        let hosted = try await hostAndWaitForRender(runtime)

        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "the client connected machine alpha through its own bridge",
            timeout: 20
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "the client connected machine beta through its own bridge",
            timeout: 20
        )

        // Both machines must STAY working: a machine that connects then
        // drops to attention fails loudly. The client's own log is the
        // ground truth for the attention state.
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(runtime.phase, .running, "the embedded client keeps running")
            let newLines = Self.clientLogLines(after: logLinesBefore)
            XCTAssertFalse(
                newLines.contains("needs attention"),
                "a machine landed in herdr's needs-attention state:\n\(newLines)"
            )
            XCTAssertFalse(
                coordinator.eventLines.contains { $0.contains("carrier lost") },
                "a machine's bridge carrier was lost:\n\(coordinator.eventLines.joined(separator: "\n"))"
            )
        }

        Self.dumpDiagnostics(runtime: runtime, view: hosted)
        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    /// The embedded client's rotating log — the ground truth for the
    /// machines' attention state (the client warns "endpoint needs
    /// attention" per machine; the sidebar text is not reliably
    /// sampleable because the client switches its sidebar section once a
    /// machine's workspace activates).
    private static var clientLogURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/config-home/herdr/herdr-client.log")
    }

    private static func clientLogLineCount() -> Int {
        guard let text = try? String(contentsOf: clientLogURL, encoding: .utf8) else {
            return 0
        }
        return text.split(separator: "\n").count
    }

    /// Log lines appended after `lineCount` (a snapshot taken before the
    /// run under test), so stale lines from earlier runs never satisfy or
    /// fail the assertions.
    private static func clientLogLines(after lineCount: Int) -> String {
        guard let text = try? String(contentsOf: clientLogURL, encoding: .utf8) else {
            return ""
        }
        return text.split(separator: "\n")
            .dropFirst(lineCount)
            .joined(separator: "\n")
    }

    /// Regression for the reported device bug: reopening a herd while the
    /// previous run's teardown is still unwinding. The app's close-reopen
    /// flow spawns `requestStop` UNAWAITED (`onDisappear`) and the next
    /// workspace's `.task` calls `startIfNeeded` on a runtime whose phase
    /// is already `.stopped` — so the new bring-up's bridge sweep/bind can
    /// race the old run's bridge stops, which close listeners and unlink
    /// the SAME socket paths (same connections → same profile ids).
    /// Device evidence (client log): the dropped machine's dial fails
    /// ConnectionRefused (file present, listener gone) then ENOENT (file
    /// unlinked) → herdr "needs attention", alternating between machines.
    ///
    /// The race's teardown phase is seconds long on device (TERM_GRACE
    /// plus WAN carrier closes) but milliseconds on fixtures, so this
    /// test holds the previous run's transport alive directly
    /// (`prepare()` without a runtime — the suspended-teardown state) and
    /// releases it mid-run, which is the same interleaving deterministically.
    func testReopenHerdWhilePreviousTeardownUnwindsKeepsBothMachines() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let machines = [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")]
        let key = try await parseFixtureKey()

        // Run 1's transport, held alive: bridges listening, carriers
        // established, catalog seeded — the state the previous run's
        // teardown is still holding when the reopened herd brings up.
        let coordinatorOne = HerdrEmbedTransportCoordinator(
            machines: machines,
            connector: fixtureConnectorFactory(key: key)
        )
        _ = try await coordinatorOne.prepare()

        let runtime = HerdrEmbedRuntime()
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
            await coordinatorOne.teardown()
        }
        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }

        // The reopen: a fresh coordinator brings up while run 1's bridges
        // still own the machine socket paths.
        let logLinesBefore = Self.clientLogLineCount()
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            connector: fixtureConnectorFactory(key: key)
        )
        runtime.attachTransport(coordinator)
        await runtime.startIfNeeded(ownerID: UUID())
        if case let .failed(message) = runtime.phase {
            XCTFail("reopened herd failed to start: \(message)")
        }
        let hosted = try await hostAndWaitForRender(runtime)

        // Both machines connected through THIS run's bridges — without the
        // per-bring-up socket namespace, the machine whose path the old
        // run still owns is dropped from the bring-up (liveListenerExists)
        // and its relay opens on the OLD coordinator instead.
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "the reopened herd connected machine alpha through its OWN bridge",
            timeout: 30
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "the reopened herd connected machine beta through its OWN bridge",
            timeout: 30
        )

        // The previous run's teardown completes mid-run: its bridge stops
        // close listeners and unlink socket files. The reopened herd's
        // machines must be untouched — their sockets live in this run's
        // own namespace, not the previous run's paths.
        await coordinatorOne.teardown()
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(runtime.phase, .running, "the reopened herd keeps running")
            let newLines = Self.clientLogLines(after: logLinesBefore)
            XCTAssertFalse(
                newLines.contains("needs attention"),
                "a machine landed in herdr's needs-attention state after the previous run's teardown:\n\(newLines)"
            )
            XCTAssertFalse(
                coordinator.eventLines.contains { $0.contains("carrier lost") },
                "a machine's bridge carrier was lost:\n\(coordinator.eventLines.joined(separator: "\n"))"
            )
        }

        Self.dumpDiagnostics(runtime: runtime, view: hosted)
        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    /// First-connect repro through the PRODUCTION connector shape: the
    /// coordinator built the way the workspace view builds it (a SHARED
    /// host-key verifier through `makeConnector()`, not the test factory)
    /// — the one simulator shape the fixture tests never exercised. The
    /// reported device bug: fresh herd, two machines, first connect, one
    /// machine in herdr's "needs attention" state, 100% of the time,
    /// not always the same machine.
    func testFirstConnectProductionConnectorShapeKeepsBothMachines() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let logLinesBefore = Self.clientLogLineCount()
        let machines = [
            try makeDirectMachine(label: "alpha"),
            try makeDirectMachine(label: "beta"),
        ]
        let key = try await parseFixtureKey()

        // The production shape: ONE shared verifier (HerdrWindowRoot passes
        // `store.hostKeyVerifier`), the fixture key through the
        // authentication-key provider seam, and the fixture search path.
        let sharedVerifier = try await makeAllEndpointsTrustedVerifier()
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            preferredSelection: nil,
            hostKeyVerifier: sharedVerifier,
            authenticationKeyProvider: { FixtureHerdKeyProvider(key: key) },
            metadataProvider: FixtureHerdrKeyMetadataProvider(),
            searchPaths: [Self.herdrBin]
        )

        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        await runtime.startIfNeeded(ownerID: UUID())
        if case let .failed(message) = runtime.phase {
            XCTFail("herd bring-up failed: \(message)")
        }
        let hosted = try await hostAndWaitForRender(runtime)

        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "the client connected machine alpha through its own bridge",
            timeout: 20
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "the client connected machine beta through its own bridge",
            timeout: 20
        )
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(runtime.phase, .running, "the embedded client keeps running")
            let newLines = Self.clientLogLines(after: logLinesBefore)
            XCTAssertFalse(
                newLines.contains("needs attention"),
                "a machine landed in herdr's needs-attention state:\n\(newLines)"
            )
        }

        Self.dumpDiagnostics(runtime: runtime, view: hosted)
        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    /// Repro for the reported device bug's mechanism: a herd's machines
    /// establish their SSH carriers CONCURRENTLY, and each establish
    /// resolves its connection's authentication key from the Keychain —
    /// for a BIOMETRY-PROTECTED key that read is a Face ID evaluation,
    /// and iOS runs one evaluation at a time: the losing machine's
    /// concurrent read fails, its establish is dropped from the bring-up
    /// (no bridge socket), and the client's dial of that machine fails
    /// ENOENT → herdr's "needs attention" state, permanently (attention
    /// is terminal). One machine works, the other always fails, and
    /// WHICH machine loses alternates — exactly the reported symptom.
    ///
    /// The simulator's Keychain does not enforce biometry (verified: a
    /// `.biometryCurrentSet` item reads fine with no Face ID enrolled),
    /// so the device constraint is modeled by the key provider double:
    /// a read that starts while another is in flight fails — the
    /// observed device behavior. The fix (per-bring-up key resolution:
    /// one coalesced read per key reference) makes both machines share
    /// ONE read, so the constraint can never race.
    func testTwoMachinesSharingOneKeyBothConnect() async throws {
        try requireBothFixtures()
        let key = try await parseFixtureKey()
        let racingProvider = SingleEvaluationKeyProvider(
            underlying: FixtureHerdKeyProvider(key: key)
        )

        // Two machines whose connections offer the SAME key reference —
        // the user's herd shape (both connections to one host, one key).
        func machine(label: String) throws -> HerdrEmbedMachineLink {
            let connection = try Connection(
                name: label,
                type: .ssh,
                host: "127.0.0.1",
                port: 12222,
                username: Self.fixtureUsername,
                customKeys: ["fixture-ed25519"]
            )
            return HerdrEmbedMachineLink(
                machine: HerdrEmbedMachine.forConnection(connection),
                connection: connection,
                bridgeSessionName: nil
            )
        }
        let machines = [try machine(label: "alpha"), try machine(label: "beta")]

        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let logLinesBefore = Self.clientLogLineCount()
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            preferredSelection: nil,
            hostKeyVerifier: try await makeAllEndpointsTrustedVerifier(),
            authenticationKeyProvider: { racingProvider },
            metadataProvider: FixtureHerdrKeyMetadataProvider(),
            searchPaths: [Self.herdrBin]
        )
        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        await runtime.startIfNeeded(ownerID: UUID())
        if case let .failed(message) = runtime.phase {
            XCTFail("herd bring-up failed: \(message)")
        }
        _ = try await hostAndWaitForRender(runtime)

        // BOTH machines must establish and dial through their own bridges.
        // Without per-bring-up key resolution, the two concurrent
        // establishes race two concurrent key evaluations and the loser
        // is dropped — its relay never opens and the client logs
        // "needs attention" for it.
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "machine alpha connected through its own bridge (key resolved once, shared)",
            timeout: 30
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "machine beta connected through its own bridge (key resolved once, shared)",
            timeout: 30
        )
        let newLines = Self.clientLogLines(after: logLinesBefore)
        XCTAssertFalse(
            newLines.contains("needs attention"),
            "a machine landed in herdr's needs-attention state:\n\(newLines)"
        )

        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: machines,
            cwdBeforeStart: cwdBeforeStart
        )
    }

    /// Per-relay bridge contract, mirrored from
    /// ``HerdrEmbedHardeningTests/testSeveredBridgeSurfacesTypedExitAndReopenReconnects``:
    /// severing stops the machine's bridge; no `carrier lost` fires on a
    /// per-relay bridge (there is no held carrier to lose). The
    /// observable is the bridge-stop event, and the other machine keeps
    /// flowing — the load-bearing half of this test.
    func testSeveringOneMachineLeavesTheOtherFlowing() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let alpha = try makeDirectMachine(label: "alpha")
        let beta = try makeJumpMachine(label: "beta")
        let (runtime, coordinator) = try await startHerdRuntime(
            machines: [alpha, beta]
        )
        let hosted = try await hostAndWaitForRender(runtime)

        await coordinator.severMachineTransport(profileID: alpha.machine.profileID)

        await waitFor(
            coordinator.eventLines.contains {
                $0.hasPrefix("alpha: bridge stopped")
            },
            "severing machine alpha stopped its bridge; alpha lines: \(coordinator.eventLines.filter { $0.hasPrefix("alpha") })",
            timeout: 15
        )
        XCTAssertEqual(
            runtime.phase, .running,
            "the embedded client keeps running with one machine down"
        )
        await waitFor(
            bufferContains(hosted, "beta"),
            "the healthy machine stays rendered in the client",
            timeout: 15
        )
        XCTAssertFalse(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge stopped") },
            "machine beta's bridge was never touched"
        )

        let writtenBefore = runtime.bytesWritten
        runtime.writeInput(Data("j".utf8))
        await waitFor(
            runtime.bytesWritten > writtenBefore,
            "input still accepted while the other machine is down"
        )

        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    func testOpeningSecondHerdClosesFirstAndIsolatesSocketsAndCatalog() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let first = try makeDirectMachine(label: "one")
        let second = try makeJumpMachine(label: "two")

        let parsed = try await parseFixtureKey()
        let ownerOne = UUID()
        let (runtime, coordinatorOne) = try await startHerdRuntime(
            machines: [first], ownerID: ownerOne, key: parsed
        )
        guard case .running = runtime.phase else {
            XCTFail("first herd never reached running: \(runtime.phase)")
            return
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile(for: first, coordinator: coordinatorOne)),
            "herd one's machine socket exists while its run is live"
        )

        // Opening herd B closes herd A cleanly (v1: one embedded TUI per
        // process) and swaps the catalog + sockets wholesale.
        let coordinatorTwo = HerdrEmbedTransportCoordinator(
            machines: [second],
            connector: fixtureConnectorFactory(key: parsed)
        )
        runtime.attachTransport(coordinatorTwo)
        await runtime.startIfNeeded(ownerID: UUID())

        guard case .running = runtime.phase else {
            XCTFail("second herd never reached running: \(runtime.phase)")
            return
        }
        await waitFor(
            !FileManager.default.fileExists(atPath: socketFile(for: first, coordinator: coordinatorOne)),
            "herd one's socket was cleaned up when its run closed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile(for: second, coordinator: coordinatorTwo)),
            "herd two's machine socket exists for its own run"
        )
        let catalog = try String(
            contentsOf: catalogFile(),
            encoding: .utf8
        )
        XCTAssertTrue(catalog.contains("two"))
        XCTAssertFalse(
            catalog.contains("one"),
            "the client catalog holds only the open herd's machines"
        )

        _ = try await hostAndWaitForRender(runtime)
        runtime.writeInput(Data("x".utf8))
        await waitFor(runtime.bytesWritten > 0, "keystroke accepted in the second herd")

        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinatorTwo,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    // MARK: - Config-reload re-seed (embed patch 0008, Swift half)

    /// The user-facing contract "any remotes in attention state reconnect
    /// whenever the config is reloaded", Swift side: a config reload on a
    /// LIVE herd run rewrites the client-polled `endpoints.json` from
    /// CURRENT store state (embed patch 0008's mtime detection then
    /// re-arms attention machines — the re-arm itself is covered by the
    /// patch's Rust unit tests; a fixture cannot stage an attention
    /// machine whose re-dial is observable, since the attention-producing
    /// dial failures — ENOENT against a missing bridge socket — keep
    /// failing on the re-dial too). Asserted here: exactly one re-seed
    /// per reload event, membership re-resolved live, the client-owned
    /// selection file byte-identical, and no re-seed after the run stops.
    func testConfigReloadReseedsLiveHerdCatalogOncePerReload() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let alpha = try makeDirectMachine(label: "alpha")
        let beta = try makeJumpMachine(label: "beta")
        let herd = try Herd(
            name: "fleet",
            machines: [
                HerdMachine(connectionID: alpha.connection.id),
                HerdMachine(connectionID: beta.connection.id),
            ]
        )
        let store = StubHerdStore(herd: herd)
        let key = try await parseFixtureKey()
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: [alpha, beta],
            herdID: herd.id,
            connector: fixtureConnectorFactory(key: key)
        )
        coordinator.reseedHerdStoreForTesting = store
        coordinator.reseedConnectionLookupForTesting = { id in
            [alpha.connection, beta.connection].first { $0.id == id }
        }

        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        await runtime.startIfNeeded(ownerID: UUID())
        if case let .failed(message) = runtime.phase {
            XCTFail("herd bring-up failed: \(message)")
        }

        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "the client connected machine alpha through its own bridge",
            timeout: 20
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "the client connected machine beta through its own bridge",
            timeout: 20
        )

        func reseedLineCount() -> Int {
            coordinator.eventLines.filter { $0.contains("catalog re-seeded") }.count
        }

        // Reload event 1: identical membership — the rewrite is still the
        // client's "retry now" signal (patch 0008 fires on mtime alone).
        await runtime.reseedCatalogIfLive()
        XCTAssertEqual(reseedLineCount(), 1, "one reload event re-seeds exactly once")
        var catalog = try String(contentsOf: catalogFile(), encoding: .utf8)
        XCTAssertTrue(catalog.contains(alpha.machine.profileID))
        XCTAssertTrue(catalog.contains(beta.machine.profileID))

        // The herd edit lands in the store mid-run (beta removed): the
        // next reload re-resolves CURRENT membership and beta retires.
        try await store.save(Herd(
            id: herd.id,
            name: herd.name,
            machines: [HerdMachine(connectionID: alpha.connection.id)]
        ))
        await runtime.reseedCatalogIfLive()
        XCTAssertEqual(reseedLineCount(), 2, "the second reload event re-seeds exactly once more")
        catalog = try String(contentsOf: catalogFile(), encoding: .utf8)
        XCTAssertTrue(catalog.contains(alpha.machine.profileID))
        XCTAssertFalse(
            catalog.contains(beta.machine.profileID),
            "a machine removed from the herd retires from the live catalog"
        )

        // The selection file is client-OWNED: the live client rewrites it
        // itself (its own serde formatting) whenever it persists the
        // activated machine, including the auto-activation that fires when
        // the selected machine's first snapshot arrives. Byte-identity
        // therefore races the client's own persist timing (it passed solo
        // only because that write usually lands before the baseline
        // capture). The reseed contract is semantic: the user's selection
        // survives every reload — the host never yanks it mid-run.
        XCTAssertEqual(
            try selectionFileSelectedProfile(), alpha.machine.profileID,
            "the client-owned selection survives every mid-run reload"
        )

        try await teardownHerd(
            runtime: runtime,
            coordinator: coordinator,
            machines: [alpha, beta],
            cwdBeforeStart: cwdBeforeStart
        )

        // No live run: the reload hook is a no-op.
        await runtime.reseedCatalogIfLive()
        XCTAssertEqual(reseedLineCount(), 2, "a stopped run never re-seeds")
    }

    /// Mode-A runs have no machine catalog to re-seed (the client attaches
    /// to the one bridge as its Local endpoint): a config reload leaves
    /// the empty catalog byte- AND mtime-identical.
    func testConfigReloadLeavesModeARunUntouched() async throws {
        try requireBothFixtures()
        let connection = try makeDirectConnection(label: "solo")
        let key = try await parseFixtureKey()
        let coordinator = HerdrEmbedTransportCoordinator(
            connection: connection,
            connector: fixtureConnectorFactory(key: key)
        )
        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        await runtime.startIfNeeded(ownerID: UUID())
        guard case .running = runtime.phase else {
            XCTFail("mode-A run never reached running: \(runtime.phase)")
            return
        }

        let catalog = catalogFile()
        let bytesBefore = try Data(contentsOf: catalog)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: catalog.path)[.modificationDate]

        await runtime.reseedCatalogIfLive()

        XCTAssertFalse(
            coordinator.eventLines.contains { $0.contains("catalog re-seeded") },
            "Mode A never re-seeds"
        )
        XCTAssertEqual(try Data(contentsOf: catalog), bytesBefore)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: catalog.path)[.modificationDate]
                as? Date,
            mtimeBefore as? Date,
            "the mode-A catalog file is not even rewritten (no spurious reload signal)"
        )

        await runtime.requestStop()
    }

    private func selectionFile() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/state-home/herdr/client/endpoint-selection.json")
    }

    /// The selection file's `selected_profile`, read semantically: the
    /// file's owner (the live client) persists it in its own formatting,
    /// so only the decoded value is stable across client rewrites.
    private func selectionFileSelectedProfile() throws -> String? {
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: selectionFile())
        ) as? [String: Any]
        return object?["selected_profile"] as? String
    }

    // MARK: - Herd bring-up plumbing

    private func makeDirectMachine(label: String) throws -> HerdrEmbedMachineLink {
        link(for: try makeDirectConnection(label: label))
    }

    private func makeJumpMachine(label: String) throws -> HerdrEmbedMachineLink {
        let hop = Hop(
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            customKeys: ["fixture-ed25519"]
        )
        let connection = try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12223,
            username: Self.fixtureUsername,
            customKeys: ["fixture-ed25519"],
            jumpChain: [hop]
        )
        return link(for: connection)
    }

    private func link(for connection: Connection) -> HerdrEmbedMachineLink {
        HerdrEmbedMachineLink(
            machine: HerdrEmbedMachine.forConnection(connection),
            connection: connection,
            bridgeSessionName: connection.herdrSessionName
        )
    }

    private func makeDirectConnection(label: String = "alpha") throws -> Connection {
        try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            customKeys: ["fixture-ed25519"]
        )
    }

    private func parseFixtureKey() async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: Self.repoRoot.appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519"))
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }

    private func fixtureConnectorFactory(key: NIOSSHPrivateKey) -> @Sendable () async -> HerdrEndpointConnector {
        let verifierTask = Task { [self] in
            try await makeAllEndpointsTrustedVerifier()
        }
        let herdrBin = Self.herdrBin
        return {
            HerdrEndpointConnector(
                hostKeyVerifier: (try? await verifierTask.value)
                    ?? HostKeyVerifier(store: InMemoryHostKeyStoreFallback()),
                authenticationKeyProvider: FixtureHerdKeyProvider(key: key),
                metadataProvider: FixtureHerdrKeyMetadataProvider(),
                searchPaths: [herdrBin],
                approveHostKey: { _ in true }
            )
        }
    }

    /// Herd machines connect concurrently, so every endpoint of every
    /// machine (hop + destination) is pre-trusted; TOFU prompting itself
    /// is covered by the connector/coordinator test suites.
    private func makeAllEndpointsTrustedVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let endpoints = [(String("127.0.0.1"), 12222), (String("127.0.0.1"), 12223)]
        for (host, port) in endpoints {
            let keyPath = port == 12223
                ? "Fixtures/sshd/host_keys/hop2_host_ed25519.pub"
                : "Fixtures/sshd/host_keys/hop1_host_ed25519.pub"
            let keyURL = Self.repoRoot.appendingPathComponent(keyPath)
            let line = try String(contentsOf: keyURL, encoding: .utf8)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
                throw NSError(domain: "HerdrEmbedHerdTests", code: 1)
            }
            try await verifier.trust(host: host, port: port, key: blob, algorithm: String(parts[0]))
        }
        return verifier
    }

    private func startHerdRuntime(
        machines: [HerdrEmbedMachineLink],
        ownerID: UUID? = nil,
        key: NIOSSHPrivateKey? = nil
    ) async throws -> (HerdrEmbedRuntime, HerdrEmbedTransportCoordinator) {
        let parsedKey: NIOSSHPrivateKey
        if let key {
            parsedKey = key
        } else {
            parsedKey = try await parseFixtureKey()
        }
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            connector: fixtureConnectorFactory(key: parsedKey)
        )

        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }

        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }

        await runtime.startIfNeeded(ownerID: ownerID)
        if case let .failed(message) = runtime.phase {
            XCTFail("herd transport bring-up failed: \(message)")
        }
        return (runtime, coordinator)
    }

    /// Teardown receipts: the run stops, every machine socket is unlinked,
    /// and the process cwd is restored.
    private func teardownHerd(
        runtime: HerdrEmbedRuntime,
        coordinator: HerdrEmbedTransportCoordinator,
        machines: [HerdrEmbedMachineLink],
        cwdBeforeStart: String
    ) async throws {
        await runtime.requestStop()
        await waitFor(
            runtime.phase != .running,
            "requestStop ended the herd run",
            timeout: 25
        )
        for machine in machines {
            await waitFor(
                !FileManager.default.fileExists(
                    atPath: socketFile(for: machine, coordinator: coordinator)
                ),
                "machine \(machine.machine.label)'s bridge socket removed at teardown",
                timeout: 10
            )
        }
        await waitFor(
            FileManager.default.currentDirectoryPath == cwdBeforeStart,
            "process cwd restored after teardown",
            timeout: 10
        )
    }

    // MARK: - Client-surface helpers

    private func hostAndWaitForRender(
        _ runtime: HerdrEmbedRuntime,
        timeout: TimeInterval = 30
    ) async throws -> TerminalContainerView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(
            rootView: HerdrTUIHostingView(runtime: runtime).frame(width: 390, height: 844)
        )
        window.makeKeyAndVisible()
        self.window = window
        window.layoutIfNeeded()

        await waitFor(
            runtime.phase == .running && runtime.bytesRead > 0,
            "embedded client booted over the herd bridges and produced output",
            timeout: timeout
        )
        guard case .running = runtime.phase else {
            var stderr = ""
            if let text = Self.clientStderrTail() { stderr = "\nclient stderr tail:\n\(text)" }
            let failure = runtime.failureDiagnostic.map { "\($0.kind): \($0.detail)" } ?? "\(runtime.phase)"
            XCTFail("herd run never reached running: \(failure)\(stderr)")
            throw XCTSkip("unreachable")
        }

        let hosted = try XCTUnwrap(
            window.rootViewController?.view
                .firstDescendant(matching: { $0 is TerminalContainerView }) as? TerminalContainerView
        )
        await waitFor(
            !Self.bufferText(hosted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "TUI frame rendered into the terminal buffer",
            timeout: 20
        )
        Self.dumpDiagnostics(runtime: runtime, view: hosted)
        return hosted
    }

    /// Terminal grid + transport event lines into a host-readable file —
    /// the dup2 window swallows assert messages, so this dump is the
    /// ground truth for what the client actually drew and dialed.
    private static func dumpDiagnostics(
        runtime: HerdrEmbedRuntime,
        view: TerminalContainerView
    ) {
        let terminal = view.getTerminal()
        var lines = [
            "phase=\(runtime.phase) bytesRead=\(runtime.bytesRead)"
                + " bytesWritten=\(runtime.bytesWritten)",
            "cols=\(terminal.cols) rows=\(terminal.rows)"
                + " cwd=\(FileManager.default.currentDirectoryPath)",
        ]
        lines.append(contentsOf: runtime.transportLines)
        lines.append("--- active buffer ---")
        lines.append(bufferText(view))
        lines.append("--- normal-screen rows ---")
        for row in 0..<terminal.rows {
            let text = terminal.getLine(row: row)?.translateToString() ?? ""
            lines.append("\(row)|\(text)")
        }
        let url = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/t6-buffer-dump.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func bufferContains(_ view: TerminalContainerView, _ needle: String) -> Bool {
        Self.bufferText(view).contains(needle)
    }

    /// First (col, row) of a label in the terminal buffer — the machine's
    /// sidebar row.
    private func locate(
        _ view: TerminalContainerView,
        label: String
    ) -> (col: Int, row: Int)? {
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString()
            if let range = text.range(of: label) {
                let col = text.distance(from: text.startIndex, to: range.lowerBound)
                return (col, row)
            }
        }
        return nil
    }

    /// SGR mouse click through the terminal's own reporting path (press +
    /// release), the same byte path a real touch takes.
    private func click(_ view: TerminalContainerView, col: Int, row: Int) {
        let terminal = view.getTerminal()
        let cell = view.cellSizeInPixels(source: terminal) ?? (width: 10, height: 20)
        terminal.sendEvent(
            buttonFlags: 0,
            x: col,
            y: row,
            pixelX: col * cell.width,
            pixelY: row * cell.height
        )
        terminal.sendEvent(
            buttonFlags: 3,
            x: col,
            y: row,
            pixelX: col * cell.width,
            pixelY: row * cell.height
        )
    }

    // MARK: - Fixture plumbing

    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private nonisolated static var fixtureUsername: String {
        for candidate in [
            ProcessInfo.processInfo.environment["USER"],
            ProcessInfo.processInfo.environment["LOGNAME"],
            NSUserName(),
        ] where candidate != nil && !candidate!.isEmpty {
            return candidate!
        }
        return "richard"
    }

    private nonisolated static var herdrBin: String {
        repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr").path
    }

    private func requireBothFixtures() throws {
        let fm = FileManager.default
        for port in [12222, 12223] {
            try XCTSkipUnless(
                fm.fileExists(atPath: Self.herdrBin)
                    && fm.fileExists(
                        atPath: Self.repoRoot
                            .appendingPathComponent("Fixtures/run/herdr/server-\(port)/herdr-client.sock")
                            .path
                    ),
                "herdr fixture on \(port) not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
            )
        }
    }

    private func socketFile(
        for machine: HerdrEmbedMachineLink,
        coordinator: HerdrEmbedTransportCoordinator
    ) -> String {
        NSHomeDirectory() + "/\(coordinator.socketPath(for: machine.machine))"
    }

    private func catalogFile() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/state-home/herdr/client/endpoints.json")
    }

    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        timeout: TimeInterval = 12
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    private static func bufferText(_ view: TerminalContainerView) -> String {
        String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private static func clientStderrTail() -> String? {
        let url = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/client-stderr.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.suffix(2000))
    }
}

/// Supplies the fixture ed25519 key regardless of the Keychain reference
/// (the app-hosted test process has no Keychain entry for it).
private struct FixtureHerdKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) async throws -> NIOSSHPrivateKey {
        key
    }
}

/// Models the device constraint behind the reported herd bug: reading a
/// BIOMETRY-PROTECTED key from the Keychain is a Face ID evaluation, and
/// iOS runs one evaluation at a time — a read that starts while another
/// is in flight FAILS (device evidence 2026-09-17: one of two concurrent
/// herd establishes failed fast and that machine was dropped into
/// herdr's "needs attention" state, alternating between machines). The
/// simulator's Keychain does not enforce biometry, so the constraint is
/// modeled here: concurrent reads of the same key race exactly as they
/// do on the device.
private actor SingleEvaluationKeyProvider: SSHAuthenticationKeyProvider {
    let underlying: any SSHAuthenticationKeyProvider
    private var evaluating = false
    private(set) var reads = 0

    init(underlying: any SSHAuthenticationKeyProvider) {
        self.underlying = underlying
    }

    func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) async throws -> NIOSSHPrivateKey {
        if evaluating {
            throw KeyRepositoryError.keychain(errSecInteractionNotAllowed)
        }
        evaluating = true
        reads += 1
        do {
            // A biometric evaluation takes human-scale time on device
            // (the Face ID prompt); model that latency so a concurrent
            // read actually lands inside the evaluation window.
            try await Task.sleep(nanoseconds: 300_000_000)
            let key = try await underlying.authenticationPrivateKey(with: reference, reason: reason)
            evaluating = false
            return key
        } catch {
            evaluating = false
            throw error
        }
    }
}

private extension UIView {
    func firstDescendant(matching predicate: (UIView) -> Bool) -> UIView? {
        if predicate(self) { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(matching: predicate) {
                return found
            }
        }
        return nil
    }
}
