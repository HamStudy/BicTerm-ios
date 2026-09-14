import Foundation
import XCTest
@testable import BicTermCore

/// T12 end-to-end: terminal sync integrity under packet loss, through the
/// userspace lossy proxy (Fixtures/bin/lossy-proxy.py, started by
/// `HERDR_LOSSY=12322:delay=80ms scripts/fixtures-up.sh`).
///
/// The proxy's `kill` control aborts the TCP connection mid-session (the
/// packet-loss endgame); the registry auto-reconnects with a fresh
/// handshake — a NEW remote shell. The screen harness below models the
/// local VT surface: output is painted continuously, and a
/// ``SessionSyncEvent/sessionReplaced`` event RESETS the painted state
/// (what TerminalSurface's resync task does via
/// `Terminal.resetToInitialState()`).
final class LossyProxySyncIntegrationTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private let quiesceCommand =
        "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"

    private func makeRegistry() async throws -> SessionRegistry {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: try await lossyVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        return SessionRegistry(
            transportFactory: factory,
            snapshotStore: InMemorySnapshotStore(),
            reconnectPolicy: ReconnectPolicy(
                maxAttempts: 6,
                initialDelay: .milliseconds(300),
                backoffMultiplier: 2
            )
        )
    }

    private func lossyHop1Connection() throws -> Connection {
        try Connection(
            name: "fixture-hop1-lossy",
            type: .ssh,
            host: "127.0.0.1",
            port: 12322,
            username: SSHTestFixture.username,
            customKeys: ["fixture-ed25519"]
        )
    }

    private func lossyVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let key = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        try await verifier.trust(host: "127.0.0.1", port: 12322, key: key.blob, algorithm: key.algorithm)
        return verifier
    }

    private func quiesce(
        _ registry: SessionRegistry,
        sceneID: String,
        screen: ScreenHarness
    ) async throws {
        try await registry.send(sceneID: sceneID, Data(quiesceCommand.utf8))
        let ready = await screen.waitFor(marker: "__READY__", timeoutMilliseconds: 20000)
        XCTAssertTrue(ready, "shell did not reach ready marker")
        await screen.reset()
    }

    func testKillInducedReconnectResyncsScreenAndSignalsReplacement() async throws {
        let registry = try await makeRegistry()
        let sceneID = "scene-lossy"
        try await registry.startSession(
            sceneID: sceneID,
            connection: lossyHop1Connection(),
            cols: 80,
            rows: 24
        )
        defer { Task { await registry.closeSession(sceneID: sceneID) } }

        guard let output = await registry.output(sceneID: sceneID),
              let syncEvents = await registry.syncEvents(sceneID: sceneID) else {
            XCTFail("session streams missing")
            return
        }
        let screen = ScreenHarness()
        collectors.append(Task {
            for await chunk in output {
                await screen.paint(chunk)
            }
        })
        collectors.append(Task {
            for await event in syncEvents {
                await screen.noteSyncEvent(event)
            }
        })

        try await quiesce(registry, sceneID: sceneID, screen: screen)

        try await registry.send(sceneID: sceneID, Data("printf '__STA''LE_MARK__\\n'\n".utf8))
        let sawStale = await screen.waitFor(marker: "__STALE_MARK__")
        XCTAssertTrue(sawStale)
        await screen.reset()

        // Induce the connection death: the proxy aborts every active
        // connection (RST).
        try appendLossyControl("kill")

        let sawDisconnected = await waitForState(registry, sceneID: sceneID) { $0 == .disconnected }
        XCTAssertTrue(sawDisconnected, "proxy kill must be observed as a drop")
        let reconnected = await waitForState(registry, sceneID: sceneID, timeoutMilliseconds: 25000) {
            $0 == .active
        }
        XCTAssertTrue(reconnected, "auto-reconnect must reach .active through the proxy")

        // HONEST SIGNAL: the adoption of the replacement session was
        // announced on the sync-event surface.
        let gotReplacement = await screen.waitForEvent(.sessionReplaced, timeoutMilliseconds: 5000)
        XCTAssertTrue(gotReplacement, "rehandshake adoption must emit .sessionReplaced")

        // HONEST SCREEN: the replacement event reset the painted surface
        // (TerminalSurface's VT reset) — the fresh shell's output lands on
        // a clean screen, not interleaved with dead-session state.
        try await quiesce(registry, sceneID: sceneID, screen: screen)
        try await registry.send(sceneID: sceneID, Data("printf '__FRE''SH_MARK__\\n'\n".utf8))
        let sawFresh = await screen.waitFor(marker: "__FRESH_MARK__")
        XCTAssertTrue(sawFresh, "post-reconnect output must arrive on the same stable stream")

        // The remote pty keeps the correct geometry after the resync poke
        // (rows bounced by one and restored).
        await screen.reset()
        try await registry.send(sceneID: sceneID, Data("stty size; printf '__SI''ZE__\\n'\n".utf8))
        let sawSize = await screen.waitFor(marker: "__SIZE__", timeoutMilliseconds: 10000)
        XCTAssertTrue(sawSize)
        let painted = await screen.text
        XCTAssertTrue(
            painted.contains("24 80"),
            "pty geometry must be intact after the redraw poke; painted=\(painted.suffix(80))"
        )
    }

    func testSustainedLatencyKeepsMarkerIntegrity() async throws {
        let registry = try await makeRegistry()
        let sceneID = "scene-latency"
        try await registry.startSession(
            sceneID: sceneID,
            connection: lossyHop1Connection(),
            cols: 80,
            rows: 24
        )
        defer { Task { await registry.closeSession(sceneID: sceneID) } }

        guard let output = await registry.output(sceneID: sceneID) else {
            XCTFail("session stream missing")
            return
        }
        let screen = ScreenHarness()
        collectors.append(Task {
            for await chunk in output {
                await screen.paint(chunk)
            }
        })

        try await quiesce(registry, sceneID: sceneID, screen: screen)

        // Crank the impairment: heavy latency. TCP retransmits keep the
        // bytestream intact (channel-window effects can only STALL or
        // kill the connection, never truncate in-band data).
        try appendLossyControl("delay=400ms")
        defer { try? appendLossyControl("reset") }

        try await registry.send(sceneID: sceneID, Data("printf '__SLO''W_OK__\\n'\n".utf8))
        let sawMarker = await screen.waitFor(marker: "__SLOW_OK__", timeoutMilliseconds: 20000)
        XCTAssertTrue(sawMarker, "session must stay functional under sustained latency")
    }

    /// The transport's own bounded site (32 chunks × ≤32 KiB) drops the
    /// oldest chunks under a slow consumer; the installed
    /// ``InboundDropObserving`` observer must fire — the drop is bounded
    /// but never silent. Companion evidence to the pre-fix
    /// characterization (1,888 of ~2,000,000 bytes survived, zero signal).
    func testTransportSiteDropUnderSlowConsumerFiresObserver() async throws {
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            )
        )
        defer { Task { await transport.close() } }

        let dropCount = DropCounter()
        await transport.setInboundDropObserver { dropCount.note() }
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)

        try await transport.send(Data(quiesceCommand.utf8))
        try await transport.send(Data("seq 1 300000; printf '__BLA''ST_DONE__\\n'\n".utf8))

        try? await Task.sleep(for: .seconds(6))

        let sink = SSHOutputSink()
        collectors.append(Task {
            let stream = await transport.output
            for await chunk in stream {
                await sink.append(chunk)
            }
            await sink.markFinished()
        })

        let sawDone = await waitForContent(sink: sink, marker: "__BLAST_DONE__", timeoutMilliseconds: 20000)
        XCTAssertTrue(sawDone, "newest output survives the overflow (bufferingNewest)")

        let fired = await dropCount.waitUntil(atLeast: 1, timeoutMilliseconds: 5000)
        XCTAssertTrue(fired, "a transport-site bounded drop must fire the inbound-drop observer")
    }
}

/// Atomic counter for the @Sendable drop observer; the lock is only ever
/// taken inside synchronous methods.
final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func note() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    private func currentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func waitUntil(atLeast threshold: Int, timeoutMilliseconds: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if currentCount() >= threshold { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return currentCount() >= threshold
    }
}

/// Appends one command to the lossy proxy's control file. APPENDS — the
/// proxy tails by byte offset, so an overwrite-style write would desync
/// its offset and silently swallow the command.
private func appendLossyControl(_ command: String) throws {
    let ctl = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/lossy-proxy-12322.ctl")
    let handle = try FileHandle(forWritingTo: ctl)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((command + "\n").utf8))
}

/// Local-surface stand-in: paints output continuously, resets on
/// `.sessionReplaced` — the exact consumer contract TerminalSurface
/// implements against the registry's sync events.
actor ScreenHarness {
    private var painted = Data()
    private var events: [SessionSyncEvent] = []

    var text: String {
        String(decoding: painted, as: UTF8.self)
    }

    func paint(_ chunk: Data) {
        painted.append(chunk)
    }

    func noteSyncEvent(_ event: SessionSyncEvent) {
        events.append(event)
        if event == .sessionReplaced {
            painted.removeAll(keepingCapacity: true)
        }
    }

    func reset() {
        painted.removeAll(keepingCapacity: true)
    }

    func waitFor(marker: String, timeoutMilliseconds: UInt64 = 8000) async -> Bool {
        await pollUntil(timeoutMilliseconds: timeoutMilliseconds) {
            String(decoding: self.painted, as: UTF8.self).contains(marker)
        }
    }

    func waitForEvent(_ event: SessionSyncEvent, timeoutMilliseconds: UInt64 = 5000) async -> Bool {
        await pollUntil(timeoutMilliseconds: timeoutMilliseconds) {
            self.events.contains(event)
        }
    }

    private func pollUntil(
        timeoutMilliseconds: UInt64,
        condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}
