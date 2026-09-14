import BicTermCore
import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit
import XCTest

@testable import BicTerm

/// herdr-embed T8 hardening, four areas:
/// (a) sync honesty — the detach key ends the run with clean teardown, a
///     severed carrier keeps honest state with bounded redials, and the
///     workspace REOPEN cycle reconnects through a fresh carrier with a
///     fresh terminal (no stale-garble survives a cycle);
/// (b) memory/CPU bounds — a flood against a stalled consumer stays
///     bounded (256-chunk view buffer, `bufferingNewest`), drops are
///     counted loudly and answered with the T12 resync pair (local VT
///     reset + SIGWINCH redraw poke), and repeated open/close cycles
///     leak no file descriptors or threads;
/// (c) authLost + trust edges — a key revoked mid-session surfaces the
///     typed authLost diagnostic on reopen after exactly one attempt
///     (never auto-retried), and declining a herd's TOFU prompts machine
///     by machine ends quietly while declining just one runs the rest;
/// (d) font parity — SwiftTerm's own font metrics govern the embed grid
///     and answer the client's cell-size query; nothing app-side
///     quantizes.
@MainActor
final class HerdrEmbedHardeningTests: XCTestCase {
    private var window: UIWindow?
    private var environmentGuard: String?

    override func setUp() async throws {
        try await super.setUp()
        environmentGuard = ProcessInfo.processInfo.environment["HERDR_EMBED_SOCKET_PATH"]
        setenv("HERDR_EMBED_SOCKET_PATH", "/dev/null/herdr-embed-hardening-socket", 1)
    }

    override func tearDown() async throws {
        if let environmentGuard {
            setenv("HERDR_EMBED_SOCKET_PATH", environmentGuard, 1)
        } else {
            unsetenv("HERDR_EMBED_SOCKET_PATH")
        }
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    // MARK: - (b) Flood bounds with a stalled consumer

    func testFloodWithNoConsumerStaysBoundedAndCountsDropsLoudly() async throws {
        let stub = FloodStubSession()
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        await startRun(runtime)

        runtime.setWinsize(cols: 80, rows: 24)
        let baseline = ProcessProbe.physicalFootprint

        // 4,000 x 128 KiB = 512 MiB of DISTINCT chunks against a consumer
        // that never attaches during the flood.
        stub.flood(chunks: 4_000, chunkSize: 128 * 1024)

        XCTAssertEqual(runtime.bytesRead, stub.emitted, "every flood byte was counted")
        XCTAssertGreaterThan(runtime.bytesDropped, 0, "drops are counted, never silent")
        await waitFor(runtime.syncSuspect, "a drop episode raised the sync-suspect signal")

        // The bound is behavioral: a consumer that attaches AFTER the
        // flood can only ever receive the retained view buffer (≤ 256
        // chunks plus the one in flight), never the flood's history.
        let received = ReceivedBytes()
        let output = try XCTUnwrap(runtime.output, "the run's stream exists while running")
        let drainTask = Task {
            for await chunk in output {
                received.add(chunk.count)
            }
        }
        await runtime.requestStop()
        _ = await drainTask.value

        XCTAssertLessThanOrEqual(
            received.total, 257 * 128 * 1024,
            "a late consumer receives only the bounded view buffer"
        )
        let growth = ProcessProbe.physicalFootprint - baseline
        Self.note("[flood-bound] emitted=\(stub.emitted) dropped=\(runtime.bytesDropped)"
                + " received=\(received.total) footprintGrowth=\(growth)")
        XCTAssertGreaterThan(stub.winsizes.count, 0)
    }

    func testFloodDropEpisodeResetsViewAndPokesClientRedraw() async throws {
        let stub = FloodStubSession()
        stub.scriptedOutput = [Data("\u{1b}[2J\u{1b}[HBEFORE-FLOOD\r\n".utf8)]
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        await startRun(runtime)

        let hosted = try await hostRendered(runtime: runtime, stub: stub)
        await waitFor(
            bufferText(hosted).contains("BEFORE-FLOOD"),
            "pre-flood content rendered before the flood"
        )
        let winsizesBeforeFlood = stub.winsizes.count

        // Synchronous burst on the main actor: the view's feed task is
        // stalled for the whole flood, so the 256-chunk view buffer
        // overflows and a drop episode is armed. 1 KiB chunks keep the
        // post-episode drain (SwiftTerm parse + scrollback) quick.
        stub.flood(chunks: 30_000, chunkSize: 1_024)

        let drained = await waitForOptional(
            bufferText(hosted).contains("FLOOD-29999"),
            timeout: 20
        )
        if !drained {
            let text = bufferText(hosted)
            Self.note(
                "[drop-episode-diag] bytesRead=\(runtime.bytesRead)"
                    + " dropped=\(runtime.bytesDropped) emitted=\(stub.emitted)"
                    + " writes=\(stub.writes.count) winsizes=\(stub.winsizes.count)"
                    + " bufferBytes=\(text.utf8.count)"
            )
            Self.note("[drop-episode-diag] buffer tail: \(String(text.suffix(300)))")
        }
        XCTAssertTrue(
            drained,
            "the newest flood chunks reached the view after the episode"
        )
        let text = bufferText(hosted)
        XCTAssertFalse(
            text.contains("BEFORE-FLOOD"),
            "the resync reset the local VT state — stale pre-drop pixels are gone"
        )
        XCTAssertGreaterThan(runtime.bytesDropped, 0)
        await waitFor(!runtime.syncSuspect, "the handled episode stepped the suspect signal down")

        let terminal = hosted.getTerminal()
        XCTAssertEqual(
            stub.winsizes.last?.cols, terminal.cols,
            "the redraw poke re-applied the terminal's own geometry"
        )
        XCTAssertEqual(stub.winsizes.last?.rows, terminal.rows)
        XCTAssertGreaterThan(stub.winsizes.count, winsizesBeforeFlood, "a poke was recorded")

        await runtime.requestStop()
    }

    // MARK: - (d) Font parity: SwiftTerm metrics govern

    func testEmbedGridAndCellSizeQueryFollowSwiftTermFontMetrics() async throws {
        let smallStub = FloodStubSession()
        let largeStub = FloodStubSession()
        smallStub.scriptedOutput = [Data("\u{1b}[16t".utf8)]
        largeStub.scriptedOutput = [Data("\u{1b}[16t".utf8)]

        let smallRuntime = HerdrEmbedRuntime(sessionFactory: { smallStub })
        let largeRuntime = HerdrEmbedRuntime(sessionFactory: { largeStub })
        await startRun(smallRuntime)
        await startRun(largeRuntime)

        // An isolated defaults suite: the metrics probe must not disturb
        // the app's persisted terminal font size.
        let suite = try XCTUnwrap(UserDefaults(suiteName: "herdr-embed-hardening-fonts"))
        let smallFont = TerminalFontModel(settings: TerminalFontSettings(defaults: suite))
        smallFont.setSize(12)
        let largeFont = TerminalFontModel(settings: TerminalFontSettings(defaults: suite))
        largeFont.setSize(24)

        let smallView = try await hostRendered(
            runtime: smallRuntime, stub: smallStub, fontModel: smallFont, identifier: "embed-font-12"
        )
        let largeView = try await hostRendered(
            runtime: largeRuntime, stub: largeStub, fontModel: largeFont, identifier: "embed-font-24"
        )

        let smallTerminal = smallView.getTerminal()
        let largeTerminal = largeView.getTerminal()

        for (stub, view, terminal) in [
            (smallStub, smallView, smallTerminal),
            (largeStub, largeView, largeTerminal),
        ] {
            let winsize = try XCTUnwrap(stub.winsizes.last, "layout delivered a winsize")
            XCTAssertEqual(
                winsize.cols, terminal.cols,
                "the pty grid equals SwiftTerm's own grid for this font — no app-side quantization"
            )
            XCTAssertEqual(winsize.rows, terminal.rows)
        }
        XCTAssertGreaterThan(
            smallTerminal.cols, largeTerminal.cols,
            "a smaller SwiftTerm font yields more columns at the same frame"
        )
        XCTAssertGreaterThan(smallTerminal.rows, largeTerminal.rows)

        for (stub, view) in [(smallStub, smallView), (largeStub, largeView)] {
            await waitFor(
                stub.writes.contains { data in
                    let text = String(decoding: data, as: UTF8.self)
                    return text.hasPrefix("\u{1b}[6;") && text.hasSuffix("t")
                },
                "SwiftTerm answered the client's CSI 16 t cell-size query"
            )
            let reply = try XCTUnwrap(
                stub.writes.first { data in
                    let text = String(decoding: data, as: UTF8.self)
                    return text.hasPrefix("\u{1b}[6;") && text.hasSuffix("t")
                },
                "SwiftTerm answered the client's CSI 16 t cell-size query"
            )
            let parts = String(decoding: reply, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{1b}[t"))
                .split(separator: ";")
            XCTAssertEqual(parts.count, 3, "reply shape: CSI 6 ; height ; width t")
            let reportedHeight = Int(parts[1] ?? "")
            let reportedWidth = Int(parts[2] ?? "")
            let cell = try XCTUnwrap(
                view.cellSizeInPixels(source: view.getTerminal()),
                "the hosting view reports its cell metrics"
            )
            XCTAssertEqual(
                reportedWidth, cell.width,
                "the query answer equals the view's real font metrics"
            )
            XCTAssertEqual(reportedHeight, cell.height)
        }

        await smallRuntime.requestStop()
        await largeRuntime.requestStop()
    }

    // MARK: - (a) Sync honesty through live cycles (fixtures)

    /// T8 probe (env-gated: `HERDR_EMBED_DETACH_PROBE=1`, run SOLO): the
    /// detach key ends the embedded run honestly — `.stopped` with a clean
    /// drain, socket unlinked, cwd restored — and since embed patch 0005
    /// (`run_client` returns its loop error instead of
    /// `std::process::exit`) the host process SURVIVES the non-detached
    /// error paths that follow teardown. The gate remains because the
    /// detach key itself is timing-sensitive through the SwiftUI-hosted
    /// TUI (T3/T5 learnings) — this is a solo evidence probe, not a
    /// shared-suite test.
    func testDetachKeySequenceEndsLiveRunWithCleanTeardown() async throws {
        guard Self.detachProbeEnabled else {
            throw XCTSkip("set HERDR_EMBED_DETACH_PROBE=1 and run this test solo (evidence runs)")
        }
        try requireFixtures(serverPort: 12222)
        let connection = try makeDirectConnection(label: "detach")
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let (runtime, _) = try await startTransportRuntime(connection: connection)

        _ = try await hostAndWaitForRender(runtime)

        // herdr's stock detach prefix+key: ctrl+b, then q. The single-write
        // form is deterministic on this stack (both bytes in one pty
        // read); the gapped two-write form is the documented fallback.
        runtime.writeInput(Data([0x02, 0x71]))
        let singleWrite = await waitForOptional(runtime.phase != .running, timeout: 12)
        Self.note("[detach] single-write form \(singleWrite ? "detached" : "did not detach")")
        if !singleWrite {
            runtime.writeInput(Data([0x02]))
            try await Task.sleep(for: .milliseconds(150))
            runtime.writeInput(Data("q".utf8))
        }

        await waitFor(
            runtime.phase != .running,
            "the detach key ended the embedded run",
            timeout: 20
        )
        guard case let .stopped(exit) = runtime.phase else {
            XCTFail("detach must stop the run, got \(runtime.phase)")
            return
        }
        XCTAssertNil(exit, "a detach-key stop is a clean drain")

        let socketFile = expectedSocketFile(for: connection)
        await waitFor(
            !FileManager.default.fileExists(atPath: socketFile),
            "bridge socket removed after detach",
            timeout: 10
        )
        await waitFor(
            FileManager.default.currentDirectoryPath == cwdBeforeStart,
            "process cwd restored after detach",
            timeout: 10
        )
    }

    func testSeveredCarrierKeepsHonestStateWithBoundedRedialsAndReopenReconnects() async throws {
        try requireFixtures(serverPort: 12222)
        let connection = try makeDirectConnection(label: "sever")
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let (runtime, coordinator) = try await startTransportRuntime(connection: connection)
        let hosted = try await hostAndWaitForRender(runtime)

        await coordinator.severMachineTransport(profileID: HerdrEmbedMachine.profileID(for: connection.id))

        await waitFor(
            coordinator.eventLines.contains { $0.contains("bridge carrier lost") },
            "the severed machine surfaced through its bridge",
            timeout: 15
        )

        // Watch the client's redial behavior against the still-listening
        // bridge for a fixed window: every redial's exec open fails on the
        // dead carrier — the churn must stay bounded (no retry storm).
        let churnStart = coordinator.eventLines.filter { $0.contains("bridge carrier lost") }.count
        try await Task.sleep(for: .seconds(8))
        let churn = coordinator.eventLines.filter { $0.contains("bridge carrier lost") }.count - churnStart
        XCTAssertLessThanOrEqual(churn, 12, "redials against the dead carrier stay bounded")

        XCTAssertEqual(runtime.phase, .running, "the run itself keeps honest running state")
        XCTAssertEqual(runtime.bytesDropped, 0, "no silent drops during the loss cycle")
        let writtenBefore = runtime.bytesWritten
        runtime.writeInput(Data("j".utf8))
        await waitFor(runtime.bytesWritten > writtenBefore, "input still accepted while the machine is down")

        // The v1 reconnect surface is the workspace REOPEN: stop, then a
        // fresh coordinator establish → new carrier, new relay, fresh TUI
        // (a new terminal view — no stale VT state can survive).
        await runtime.requestStop()
        await waitFor(runtime.phase != .running, "run stopped before reopen", timeout: 20)

        let freshCoordinator = try await makeTrustedCoordinator(connection: connection)
        runtime.attachTransport(freshCoordinator)
        await runtime.startIfNeeded()
        guard case .running = runtime.phase else {
            XCTFail("reopen never reconnected: \(runtime.phase)")
            return
        }
        await waitFor(
            freshCoordinator.eventLines.contains { $0.contains("bridge relay opened") },
            "the reopened machine dialed through its fresh carrier",
            timeout: 15
        )
        _ = try await hostAndWaitForRender(runtime)
        XCTAssertEqual(
            runtime.bytesDropped, 0,
            "the reconnect cycle fed the fresh surface losslessly"
        )

        await runtime.requestStop()
        await waitFor(
            FileManager.default.currentDirectoryPath == cwdBeforeStart,
            "cwd restored at final teardown",
            timeout: 10
        )
    }

    func testServerDeathKeepsRunHonestAndBounded() async throws {
        try requireFixtures(serverPort: 12222)
        let serverDirectory = Self.repoRoot
            .appendingPathComponent("Fixtures/run/herdr/server-12222", isDirectory: true)
        let pidFile = serverDirectory.appendingPathComponent("server.pid")
        let pidString = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverPID = Int32(pidString), serverPID > 0, kill(serverPID, 0) == 0 else {
            throw XCTSkip("fixture herdr server pid unavailable")
        }
        addTeardownBlock { @MainActor in
            Self.reseedFixtureServerForNextTest(port: 12222)
        }

        let connection = try makeDirectConnection(label: "kill")
        let (runtime, coordinator) = try await startTransportRuntime(connection: connection)
        let hosted = try await hostAndWaitForRender(runtime)

        XCTAssertEqual(kill(serverPID, SIGTERM), 0, "fixture server killed from its pidfile")

        await waitFor(
            coordinator.eventLines.contains { $0.contains("relay ended") },
            "the machine's relay ended when its server died",
            timeout: 15
        )
        XCTAssertEqual(runtime.phase, .running, "the embedded run survives a machine's server death")

        let endsBefore = coordinator.eventLines.filter { $0.contains("relay ended") }.count
        try await Task.sleep(for: .seconds(6))
        let ends = coordinator.eventLines.filter { $0.contains("relay ended") }.count - endsBefore
        XCTAssertLessThanOrEqual(ends, 12, "relay churn after server death stays bounded")

        let writtenBefore = runtime.bytesWritten
        runtime.writeInput(Data("j".utf8))
        await waitFor(runtime.bytesWritten > writtenBefore, "input still accepted after server death")
        XCTAssertEqual(runtime.bytesDropped, 0, "no silent drops during the server-death cycle")

        // Wait for the fixture server to come back (the bridge's
        // remote-client-bridge auto-starts one on its next redial; a
        // direct spawn is the fallback) and record whether the client
        // recovers on its own — honest documentation either way.
        Self.ensureFixtureServerBack(port: 12222, timeout: 15)
        let readBefore = runtime.bytesRead
        try await Task.sleep(for: .seconds(6))
        let recovered = runtime.bytesRead > readBefore
            && coordinator.eventLines.filter { $0.contains("relay opened") }.count > 1
        let record = recovered
            ? "client re-established its machine after the server restart"
            : "client kept the machine down after the server restart (user reopen required)"
        Self.note("[server-death] \(record)")

        await runtime.requestStop()
    }

    // MARK: - (c) authLost + trust edges (fixtures)

    func testRevokedKeyMidSessionSurfacesAuthLostOnReopenWithoutAutoRetry() async throws {
        try requireFixtures(serverPort: 12222)
        let authorizedKeys = Self.repoRoot
            .appendingPathComponent("Fixtures/sshd/authorized_keys_hop1")
        let original = try String(contentsOf: authorizedKeys, encoding: .utf8)
        addTeardownBlock {
            try? original.write(to: authorizedKeys, atomically: true, encoding: .utf8)
        }

        let connection = try makeDirectConnection(label: "revoke")
        let (runtime, coordinator) = try await startTransportRuntime(connection: connection)
        _ = try await hostAndWaitForRender(runtime)

        // Revoke the fixture key server-side while the session runs.
        let revoked = original
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasSuffix("bicterm-fixture-ed25519") }
            .joined(separator: "\n") + "\n"
        try revoked.write(to: authorizedKeys, atomically: true, encoding: .utf8)

        await coordinator.severMachineTransport(profileID: HerdrEmbedMachine.profileID(for: connection.id))
        await waitFor(
            coordinator.eventLines.contains { $0.contains("bridge carrier lost") },
            "the severed machine surfaced while the key was revoked",
            timeout: 15
        )
        await runtime.requestStop()

        // Reopen: the fresh establish meets the revoked key → typed
        // authLost after ONE attempt, never auto-retried.
        let deniedCoordinator = try await makeTrustedCoordinator(connection: connection)
        runtime.attachTransport(deniedCoordinator)
        await runtime.startIfNeeded()

        guard case .failed = runtime.phase else {
            XCTFail("reopen with a revoked key must fail, got \(runtime.phase)")
            return
        }
        let diagnostic = try XCTUnwrap(runtime.failureDiagnostic, "the failure is typed, not a bare string")
        XCTAssertEqual(diagnostic.kind, .authLost)
        XCTAssertEqual(diagnostic.title, "Authentication lost")

        let attempts = deniedCoordinator.eventLines
            .filter { $0.contains("bring-up failed") }.count
        XCTAssertEqual(attempts, 1, "exactly one establish attempt — a revoked key never auto-retries")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(
            deniedCoordinator.eventLines.filter { $0.contains("bring-up failed") }.count,
            1,
            "no further attempts appeared"
        )

        // Honest recovery: restore the key and reopen — the machine comes back.
        try original.write(to: authorizedKeys, atomically: true, encoding: .utf8)
        let restoredCoordinator = try await makeTrustedCoordinator(connection: connection)
        runtime.attachTransport(restoredCoordinator)
        await runtime.startIfNeeded()
        guard case .running = runtime.phase else {
            XCTFail("reopen after key restoration must run, got \(runtime.phase)")
            return
        }
        await waitFor(
            restoredCoordinator.eventLines.contains { $0.contains("bridge relay opened") },
            "the restored machine dialed through its fresh carrier",
            timeout: 15
        )
        await runtime.requestStop()
    }

    func testDecliningEveryHerdMachineTrustPromptEndsQuietly() async throws {
        try requireFixtures(serverPort: 12222)
        let parsed = try await parseFixtureKey()
        let machines = [
            try link(for: makeDirectConnection(label: "alpha")),
            try link(for: makeDirectConnection(label: "beta")),
        ]
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            hostKeyVerifier: HostKeyVerifier(store: InMemoryHostKeyStoreFallback()),
            authenticationKeyProvider: { StaticFixtureKeyProvider(key: parsed) },
            searchPaths: [Self.herdrBin]
        )
        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }

        // Bring-up suspends INSIDE prepare() while each machine's TOFU
        // prompt is pending (the app's presenter sheet resolves it); the
        // test drives the same shape — start in flight, decide, then the
        // bring-up settles.
        let settled = XCTestExpectation(description: "bring-up settled")
        let startTask = Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }

        var declined: [Int] = []
        for expectation in 1...2 {
            await waitFor(
                coordinator.trustPrompt != nil,
                "machine \(expectation)'s TOFU challenge was presented",
                timeout: 15
            )
            guard let prompt = coordinator.trustPrompt else { return }
            XCTAssertEqual(prompt.challenge.port, 12222)
            declined.append(expectation)
            coordinator.resolveTrustPrompt(false)
        }
        XCTAssertEqual(declined, [1, 2], "each machine's challenge was declined, one decision at a time")

        await fulfillment(of: [settled], timeout: 30)
        _ = await startTask.result

        await waitFor(
            phaseIsStopped(runtime),
            "declining every machine ends the bring-up quietly (user cancellation)",
            timeout: 15
        )
        XCTAssertNil(
            runtime.failureDiagnostic,
            "a declined trust prompt is not a failure screen"
        )
        XCTAssertFalse(coordinator.eventLines.contains { $0.contains("bridge relay opened") })
    }

    func testDecliningOneHerdMachineRunsTheRest() async throws {
        try requireFixtures(serverPort: 12222)
        let parsed = try await parseFixtureKey()
        let machines = [
            try link(for: makeDirectConnection(label: "alpha")),
            try link(for: makeDirectConnection(label: "beta")),
        ]
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            hostKeyVerifier: HostKeyVerifier(store: InMemoryHostKeyStoreFallback()),
            authenticationKeyProvider: { StaticFixtureKeyProvider(key: parsed) },
            searchPaths: [Self.herdrBin]
        )
        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }

        let declined = TrackingTrustSink(coordinator: coordinator)

        // Same shape as the decline-all test: bring-up in flight while
        // the prompts are decided.
        let settled = XCTestExpectation(description: "bring-up settled")
        Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }

        // Decline the FIRST presented challenge, approve the second: the
        // declined machine's bring-up fails alone; the approved one
        // retries its establish and serves the run.
        await declined.nextDecision(approve: false, timeout: 15)
        await declined.nextDecision(approve: true, timeout: 15)

        await fulfillment(of: [settled], timeout: 30)

        guard case .running = runtime.phase else {
            XCTFail("the herd must run with its approved machine, got \(runtime.phase)")
            return
        }
        await waitFor(
            coordinator.eventLines.contains { $0.contains("bridge relay opened") },
            "the approved machine dialed through its bridge",
            timeout: 15
        )
        XCTAssertEqual(
            coordinator.eventLines.filter { $0.contains("bring-up failed") }.count,
            1,
            "exactly the declined machine failed bring-up"
        )

        let catalog = try String(
            contentsOf: URL.applicationSupportDirectory
                .appendingPathComponent("herdr-embed/state-home/herdr/client/endpoints.json"),
            encoding: .utf8
        )
        for label in ["alpha", "beta"] {
            XCTAssertTrue(catalog.contains(label), "machine \(label) stays in the client catalog")
        }

        _ = try await hostAndWaitForRender(runtime)
        await runtime.requestStop()
    }

    // MARK: - (b) fd/thread audit across repeat open/close cycles

    func testRepeatOpenCloseCyclesLeakNoFileDescriptorsOrThreads() async throws {
        try requireFixtures(serverPort: 12222)
        let connection = try makeDirectConnection(label: "cycles")

        let (runtime, _) = try await startTransportRuntime(connection: connection)
        await runtime.requestStop()
        await waitFor(runtime.phase != .running, "warm-up cycle stopped", timeout: 20)
        try await Task.sleep(for: .seconds(2))

        let fdsBefore = ProcessProbe.openFileDescriptorCount()
        let threadsBefore = ProcessProbe.threadCount

        for _ in 0..<3 {
            let coordinator = try await makeTrustedCoordinator(connection: connection)
            runtime.attachTransport(coordinator)
            await runtime.startIfNeeded()
            guard case .running = runtime.phase else {
                XCTFail("cycle never reached running: \(runtime.phase)")
                return
            }
            await waitFor(
                coordinator.eventLines.contains { $0.contains("bridge relay opened") },
                "the machine dialed in this cycle",
                timeout: 15
            )
            await runtime.requestStop()
            await waitFor(runtime.phase != .running, "cycle stopped", timeout: 25)
        }
        try await Task.sleep(for: .seconds(2))

        let fdsAfter = ProcessProbe.openFileDescriptorCount()
        let threadsAfter = ProcessProbe.threadCount
        Self.note("[fd-audit] fds \(fdsBefore) -> \(fdsAfter), threads \(threadsBefore) -> \(threadsAfter)")
        XCTAssertLessThanOrEqual(
            fdsAfter, fdsBefore + 6,
            "repeat open/close cycles leak no file descriptors"
        )
        XCTAssertLessThanOrEqual(
            threadsAfter, threadsBefore + 6,
            "repeat open/close cycles leak no threads"
        )
    }

    // MARK: - Run/host helpers

    private func startRun(_ runtime: HerdrEmbedRuntime) async {
        let started = XCTestExpectation(description: "run started")
        Task {
            await runtime.startIfNeeded()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
    }

    private func hostRendered(
        runtime: HerdrEmbedRuntime,
        stub: FloodStubSession,
        fontModel: TerminalFontModel? = nil,
        identifier: String = "herdr-embed-hardening"
    ) async throws -> TerminalContainerView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(
            rootView: HerdrTUIHostingView(runtime: runtime, fontModel: fontModel)
                .frame(width: 390, height: 844)
        )
        window.makeKeyAndVisible()
        self.window = window
        window.layoutIfNeeded()

        let hosted = try XCTUnwrap(
            window.rootViewController?.view
                .firstDescendant(matching: { $0 is TerminalContainerView }) as? TerminalContainerView
        )
        hosted.accessibilityIdentifier = identifier
        await waitFor(
            !stub.winsizes.isEmpty,
            "the hosted surface delivered SwiftTerm's layout geometry"
        )
        return hosted
    }

    private func hostAndWaitForRender(
        _ runtime: HerdrEmbedRuntime,
        timeout: TimeInterval = 25
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
            "embedded client booted and produced output",
            timeout: timeout
        )
        let hosted = try XCTUnwrap(
            window.rootViewController?.view
                .firstDescendant(matching: { $0 is TerminalContainerView }) as? TerminalContainerView
        )
        await waitFor(
            !Self.bufferText(hosted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "TUI frame rendered into the terminal buffer",
            timeout: 20
        )
        return hosted
    }

    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        timeout: TimeInterval = 8
    ) async {
        let met = await poll({ condition() }, timeout: timeout)
        XCTAssertTrue(met, message)
    }

    private func waitForOptional(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 8
    ) async -> Bool {
        await poll({ condition() }, timeout: timeout)
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func phaseIsStopped(_ runtime: HerdrEmbedRuntime) -> Bool {
        if case .stopped = runtime.phase { return true }
        return false
    }

    private static func bufferText(_ view: TerminalContainerView) -> String {
        String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func bufferText(_ view: TerminalContainerView) -> String {
        Self.bufferText(view)
    }

    // MARK: - Fixture transport plumbing

    private func startTransportRuntime(
        connection: Connection
    ) async throws -> (HerdrEmbedRuntime, HerdrEmbedTransportCoordinator) {
        let coordinator = try await makeTrustedCoordinator(connection: connection)
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

        await runtime.startIfNeeded()
        if case let .failed(message) = runtime.phase {
            XCTFail("transport bring-up failed: \(message)")
        }
        return (runtime, coordinator)
    }

    private func makeTrustedCoordinator(
        connection: Connection
    ) async throws -> HerdrEmbedTransportCoordinator {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let keyPath = Self.repoRoot
            .appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        let line = try String(contentsOf: keyPath, encoding: .utf8)
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw NSError(domain: "HerdrEmbedHardeningTests", code: 1)
        }
        try await verifier.trust(
            host: connection.host, port: connection.port,
            key: blob, algorithm: String(parts[0])
        )
        let key = try await parseFixtureKey()
        return HerdrEmbedTransportCoordinator(
            connection: connection,
            hostKeyVerifier: verifier,
            authenticationKeyProvider: { StaticFixtureKeyProvider(key: key) },
            searchPaths: [Self.herdrBin]
        )
    }

    private func link(for connection: Connection) throws -> HerdrEmbedMachineLink {
        HerdrEmbedMachineLink(
            machine: HerdrEmbedMachine.forConnection(connection),
            connection: connection,
            bridgeSessionName: connection.herdrSessionName
        )
    }

    private func makeDirectConnection(label: String) throws -> Connection {
        try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519"
        )
    }

    private func parseFixtureKey() async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: Self.repoRoot.appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519"))
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }

    private func expectedSocketFile(for connection: Connection) -> String {
        let profile = HerdrEmbedMachine.profileID(for: connection.id)
        return NSHomeDirectory()
            + "/\(HerdrEmbedClientCatalog.transportDirectoryName)/\(profile).sock"
    }

    private func requireFixtures(serverPort: Int) throws {
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.herdrBin)
                && fm.fileExists(
                    atPath: Self.repoRoot
                        .appendingPathComponent("Fixtures/run/herdr/server-\(serverPort)/herdr-client.sock")
                        .path
                ),
            "herdr fixture not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
        )
    }

    /// Restarted-state reconciliation for `port` after the test kills the
    /// fixture server. The honest recovery picture: the client's bridge
    /// (`remote-client-bridge`, run through the fixture sshd with
    /// HERDR_SOCKET_PATH set) AUTO-STARTS a replacement server on its next
    /// redial — that server belongs to no pidfile. So the body path only
    /// WAITS for it (spawning itself as a fallback), and the teardown path
    /// reseeds deterministically: `herdr server stop` against whatever
    /// owner exists, socket files cleared, then one fresh spawn whose pid
    /// IS written — leaving pidfile == live owner for the next consumer.
    private static let restoreClaimLock = NSLock()
    private static var restoredPorts: Set<Int> = []

    private static func fixtureServerDirectory(port: Int) -> URL {
        repoRoot.appendingPathComponent("Fixtures/run/herdr/server-\(port)", isDirectory: true)
    }

    /// Body path: waits for the bridge-autostarted server (up to
    /// `timeout` seconds); spawns one itself only if none appeared.
    private static func ensureFixtureServerBack(port: Int, timeout: TimeInterval) {
        let sdir = fixtureServerDirectory(port: port)
        let clientSocket = sdir.appendingPathComponent("herdr-client.sock").path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probeUnixSocket(path: clientSocket) {
                note("[server-death] bridge auto-started the replacement server")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        note("[server-death] no auto-start within \(timeout)s; spawning directly")
        spawnFixtureServer(port: port)
    }

    /// Teardown path (once per port per run): stop any owner, clear the
    /// socket files and pidfile, spawn fresh, and record the spawned pid.
    private static func reseedFixtureServerForNextTest(port: Int) {
        restoreClaimLock.lock()
        let alreadyRestored = restoredPorts.contains(port)
        restoredPorts.insert(port)
        restoreClaimLock.unlock()
        if alreadyRestored {
            return
        }
        stopFixtureServer(port: port)
        spawnFixtureServer(port: port)
    }

    /// `herdr server stop` against the fixture env, then the socket files
    /// and pidfile are removed — a clean slate whether or not the current
    /// owner is the one the pidfile names.
    private static func stopFixtureServer(port: Int) {
        let sdir = fixtureServerDirectory(port: port)
        runFixtureHerdr(port: port, arguments: ["server", "stop"])
        let serverSocket = sdir.appendingPathComponent("herdr.sock").path
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && probeUnixSocket(path: serverSocket) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: sdir.appendingPathComponent("herdr.sock"))
        try? fm.removeItem(at: sdir.appendingPathComponent("herdr-client.sock"))
        try? fm.removeItem(at: sdir.appendingPathComponent("server.pid"))
    }

    /// posix_spawn of `<fixture herdr> server` exactly the way
    /// `scripts/fixtures-up.sh` does (own HERDR_SOCKET_PATH + HOME,
    /// detached), pidfile written with the spawned pid, then waits for the
    /// server socket to accept.
    private static func spawnFixtureServer(port: Int) {
        let sdir = fixtureServerDirectory(port: port)
        guard !probeUnixSocket(path: sdir.appendingPathComponent("herdr-client.sock").path) else {
            return
        }
        let pid = runFixtureHerdr(port: port, arguments: ["server"])
        guard pid > 0 else { return }
        do {
            let pidFile = sdir.appendingPathComponent("server.pid")
            try String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            note("[server-restore] pidfile write failed: \(error)")
        }
        let serverSocket = sdir.appendingPathComponent("herdr.sock").path
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if probeUnixSocket(path: serverSocket) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// posix_spawn `<fixture herdr> <arguments>` with the fixture server
    /// environment (HERDR_SOCKET_PATH + HOME pinned to the server dir,
    /// output to /dev/null, new session). Returns the spawned pid, or -1.
    private static func runFixtureHerdr(port: Int, arguments: [String]) -> pid_t {
        let sdir = fixtureServerDirectory(port: port)
        let binary = repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr").path
        let socketPath = sdir.appendingPathComponent("herdr.sock").path
        let home = sdir.appendingPathComponent("home").path

        var argvPointers: [UnsafeMutablePointer<CChar>?] =
            [strdup(binary)] + arguments.map { strdup($0) } + [nil]
        defer { for case let pointer? in argvPointers { free(UnsafeMutableRawPointer(pointer)) } }
        let environment = [
            "HERDR_SOCKET_PATH=\(socketPath)",
            "HOME=\(home)",
            "PATH=/usr/bin:/bin:/usr/local/bin",
        ]
        var env: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }
        defer { for case let pointer? in env { free(UnsafeMutableRawPointer(pointer)) } }
        env.append(nil)

        let devnull = open("/dev/null", O_RDWR)
        guard devnull >= 0 else { return -1 }
        defer { close(devnull) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, devnull, 0)
        posix_spawn_file_actions_adddup2(&actions, devnull, 1)
        posix_spawn_file_actions_adddup2(&actions, devnull, 2)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary, &actions, &attributes, argvPointers, env)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        guard result == 0, pid > 0 else {
            note("[server-restore] posix_spawn \(arguments) failed: \(result)")
            return -1
        }
        return pid
    }

    /// Connect(2) probe against a Unix domain socket: true when something
    /// is listening and accepting at `path` (the same live-vs-stale
    /// distinction `Fixtures/bin/uds-forward.py` and the Swift bridge's
    /// stale-socket sweep enforce).
    private static func probeUnixSocket(path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(probe, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// Appends a line to the T8 evidence notes file (host-readable via the
    /// app container; surfaced in the test log too).
    private static func note(_ line: String) {
        print("herdr-embed-t8 \(line)")
        let url = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/t8-notes.log")
        let handle = try? FileHandle(forWritingTo: url)
        if let handle {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

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

    /// Host-side marker file (`.scratch/enable-detach-probe`) opts the
    /// process-poisoning detach probe in for solo evidence runs.
    nonisolated static var detachProbeEnabled: Bool {
        FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent(".scratch/enable-detach-probe").path
        )
    }

    private nonisolated static var herdrBin: String {
        repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr").path
    }
}

// MARK: - Flood stub

/// Lock-confined byte counter the drain task feeds.
final class ReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func add(_ bytes: Int) {
        lock.lock()
        count += bytes
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// `HerdrEmbedSession` double with an on-demand synchronous flood: the
/// burst runs on the caller's thread with the consumer stalled, which is
/// the same contention shape the real read thread produces against a slow
/// main-actor feed.
final class FloodStubSession: HerdrEmbedSession, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var recordedWrites: [Data] = []
    private var recordedWinsizes: [(cols: Int, rows: Int)] = []

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (_ detail: String?) -> Void)?

    var scriptedOutput: [Data] = []

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites
    }

    var winsizes: [(cols: Int, rows: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWinsizes
    }

    func start(config: HerdrEmbedSessionConfig) throws {
        lock.lock()
        running = true
        lock.unlock()
        for chunk in scriptedOutput {
            onOutput?(chunk)
        }
    }

    func writeInput(_ data: Data) {
        lock.lock()
        recordedWrites.append(data)
        lock.unlock()
    }

    func setWinsize(cols: Int, rows: Int) {
        lock.lock()
        recordedWinsizes.append((cols, rows))
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stopBlocking() {
        lock.lock()
        running = false
        lock.unlock()
        onExit?(nil)
    }

    /// Emits `chunks` distinct `chunkSize`-byte outputs, each tagged with
    /// its index ("FLOOD-<i>-…"), synchronously on the calling thread.
    func flood(chunks: Int, chunkSize: Int) {
        let padding = Data(repeating: 0x2e, count: max(0, chunkSize - 32))
        for index in 0..<chunks {
            var chunk = Data("FLOOD-\(index)-".utf8)
            chunk.append(padding)
            emitted += chunk.count
            onOutput?(chunk)
        }
    }

    private(set) var emitted: Int = 0
}

// MARK: - Process probes (fd / thread / footprint)

enum ProcessProbe {
    static var physicalFootprint: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    static var threadCount: Int {
        var threads: thread_act_array_t? = nil
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else { return -1 }
        let size = vm_size_t(MemoryLayout<thread_t>.stride) * vm_size_t(count)
        if let threads {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        }
        return Int(count)
    }

    static func openFileDescriptorCount() -> Int {
        var open = 0
        for fd in 0..<1024 where fcntl(Int32(fd), F_GETFD) != -1 {
            open += 1
        }
        return open
    }
}

// MARK: - Trust decision driver

    /// Resolves the coordinator's TOFU prompts in presentation order (one
    /// decision at a time — the T6 queued-challenge contract).
    @MainActor
    private final class TrackingTrustSink {
    private let coordinator: HerdrEmbedTransportCoordinator

    init(coordinator: HerdrEmbedTransportCoordinator) {
        self.coordinator = coordinator
    }

    func nextDecision(approve: Bool, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.trustPrompt == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard coordinator.trustPrompt != nil else {
            XCTFail("no TOFU prompt arrived within \(timeout)s")
            return
        }
        coordinator.resolveTrustPrompt(approve)
    }
}

/// Fixture-key provider for coordinator-injected establish paths.
struct StaticFixtureKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        key
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
