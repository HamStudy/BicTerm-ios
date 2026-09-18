import Foundation
import XCTest
@testable import BicTermCore

/// Registry reconnect against the live hop1 fixture (127.0.0.1:12222).
/// The in-band `kill -9 $PPID` kills only the post-auth sshd-session
/// process for THIS connection: PerSourcePenalties crash monitoring covers
/// pre-auth children only, so parallel agents are unaffected.
final class SessionRegistryIntegrationTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private let reconnectPolicy = ReconnectPolicy(
        maxAttempts: 3,
        initialDelay: .milliseconds(300),
        backoffMultiplier: 2
    )

    private let quiesceCommand =
        "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"

    private func makeRegistry() async throws -> (SessionRegistry, InMemorySnapshotStore) {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier()
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        let store = InMemorySnapshotStore()
        let registry = SessionRegistry(
            transportFactory: factory,
            snapshotStore: store,
            reconnectPolicy: reconnectPolicy
        )
        return (registry, store)
    }

    private func startAndCollect(
        _ registry: SessionRegistry,
        sceneID: String,
        connection: Connection? = nil
    ) async throws -> SSHOutputSink {
        try await registry.startSession(
            sceneID: sceneID,
            connection: try connection ?? SSHTestFixture.makeConnection(),
            cols: 80,
            rows: 24
        )
        guard let output = await registry.output(sceneID: sceneID) else {
            throw SessionRegistryError.noSession(sceneID: sceneID)
        }
        let sink = SSHOutputSink()
        collectors.append(Task {
            for await chunk in output {
                await sink.append(chunk)
            }
            await sink.markFinished()
        })
        return sink
    }

    private func quiesce(
        _ registry: SessionRegistry,
        sceneID: String,
        sink: SSHOutputSink
    ) async throws {
        try await registry.send(sceneID: sceneID, Data(quiesceCommand.utf8))
        let ready = await waitForContent(sink: sink, marker: "__READY__", timeoutMilliseconds: 15000)
        XCTAssertTrue(ready, "shell did not reach ready marker for \(sceneID)")
        await sink.reset()
    }

    /// The startup command runs against a real shell: the registry injects
    /// it when the session is adopted, and its output must appear on the
    /// session's stable output stream.
    func testStartupCommandRunsWhenShellComesUp() async throws {
        let (registry, _) = try await makeRegistry()
        let sceneID = "scene-startup"
        let connection = try Connection(
            name: "fixture-hop1-startup",
            type: .ssh,
            host: SSHTestFixture.hop1Host,
            port: SSHTestFixture.hop1Port,
            username: SSHTestFixture.username,
            customKeys: ["fixture-ed25519"],
            startupCommand: #"printf '__START''UP__\n'"#
        )
        let sink = try await startAndCollect(registry, sceneID: sceneID, connection: connection)
        defer { Task { await registry.closeSession(sceneID: sceneID) } }

        let sawStartup = await waitForContent(sink: sink, marker: "__STARTUP__", timeoutMilliseconds: 15000)
        XCTAssertTrue(sawStartup, "the startup command's output must appear in session output")
    }

    func testCleanShellExitWaitsForManualReconnect() async throws {
        let (registry, _) = try await makeRegistry()
        let sceneID = "scene-exit"
        let sink = try await startAndCollect(registry, sceneID: sceneID)
        defer { Task { await registry.closeSession(sceneID: sceneID) } }
        try await quiesce(registry, sceneID: sceneID, sink: sink)
        try await registry.send(sceneID: sceneID, Data("exit\n".utf8))
        let disconnected = await waitForState(registry, sceneID: sceneID) { $0 == .disconnected }
        XCTAssertTrue(disconnected)
        try await Task.sleep(for: .seconds(3))
        let history = await registry.stateHistory(sceneID: sceneID)
        XCTAssertEqual(history, [.connecting, .active, .disconnected])
        try await registry.reconnect(sceneID: sceneID)
        try await quiesce(registry, sceneID: sceneID, sink: sink)
        try await registry.send(sceneID: sceneID, Data("printf '__MAN''UAL__\\n'\n".utf8))
        let roundTrip = await waitForContent(sink: sink, marker: "__MANUAL__")
        XCTAssertTrue(roundTrip)
    }

    func testInBandKillTriggersReconnectAndStableOutputStreamSurvives() async throws {
        let (registry, store) = try await makeRegistry()
        let sceneID = "scene-kill"
        let sink = try await startAndCollect(registry, sceneID: sceneID)
        defer { Task { await registry.closeSession(sceneID: sceneID) } }

        try await quiesce(registry, sceneID: sceneID, sink: sink)

        try await registry.send(sceneID: sceneID, Data("printf '__BEF''ORE__\\n'\n".utf8))
        let sawBefore = await waitForContent(sink: sink, marker: "__BEFORE__")
        XCTAssertTrue(sawBefore)
        await sink.reset()

        // In-band kill of the post-auth session process: the transport's
        // output stream finishes, which the registry reads as a drop.
        try await registry.send(sceneID: sceneID, Data("kill -9 $PPID\n".utf8))

        let sawDisconnected = await waitForState(registry, sceneID: sceneID) { $0 == .disconnected }
        XCTAssertTrue(sawDisconnected, "drop must transition to .disconnected")

        let reconnected = await waitForState(registry, sceneID: sceneID, timeoutMilliseconds: 20000) {
            $0 == .active
        }
        XCTAssertTrue(reconnected, "bounded auto-reconnect must reach .active with a fresh handshake")

        let sinkFinished = await sink.isFinished
        XCTAssertFalse(sinkFinished, "stable output stream must not finish across a reconnect")

        // Post-reconnect shell round-trip on the SAME consumer stream.
        try await quiesce(registry, sceneID: sceneID, sink: sink)
        try await registry.send(sceneID: sceneID, Data("printf '__AFT''ER__\\n'\n".utf8))
        let sawAfter = await waitForContent(sink: sink, marker: "__AFTER__")
        XCTAssertTrue(
            sawAfter,
            "post-reconnect output must arrive on the same stable stream"
        )

        let history = await registry.stateHistory(sceneID: sceneID)
        XCTAssertEqual(Array(history.prefix(2)), [.connecting, .active])
        XCTAssertTrue(history.contains(.disconnected), "drop must be observed")
        XCTAssertTrue(history.contains(.reconnecting), "reconnect must be observable")
        XCTAssertEqual(history.last, .active)
        XCTAssertFalse(
            history.contains { if case .failed = $0 { return true }; return false },
            "no false or failed states expected against a live fixture: \(history)"
        )

        let snapshot = try await store.snapshot(sceneID: sceneID)
        XCTAssertNil(snapshot, "live session has no lingering snapshot")
    }

    func testConcurrentSessionsReconnectIndependently() async throws {
        let (registry, _) = try await makeRegistry()
        let sceneIDs = ["scene-a", "scene-b", "scene-c"]
        var sinks: [String: SSHOutputSink] = [:]
        for sceneID in sceneIDs {
            sinks[sceneID] = try await startAndCollect(registry, sceneID: sceneID)
        }
        defer {
            for sceneID in sceneIDs {
                Task { await registry.closeSession(sceneID: sceneID) }
            }
        }

        for sceneID in sceneIDs {
            try await quiesce(registry, sceneID: sceneID, sink: sinks[sceneID]!)
        }

        // Kill only scene-b's session process.
        try await registry.send(sceneID: "scene-b", Data("kill -9 $PPID\n".utf8))

        // While scene-b detects the drop and reconnects, scenes a and c
        // must keep working undisturbed.
        for sceneID in ["scene-a", "scene-c"] {
            try await registry.send(sceneID: sceneID, Data("printf '__ALI''VE_\(sceneID.suffix(1).uppercased())__\\n'\n".utf8))
            let alive = await waitForContent(
                sink: sinks[sceneID]!,
                marker: "__ALIVE_\(sceneID.suffix(1).uppercased())__"
            )
            XCTAssertTrue(alive, "\(sceneID) must stay responsive while scene-b reconnects")
        }

        // scene-b was already .active pre-kill, so first wait for the
        // drop to be observed, then for the reconnect cycle to complete.
        let bDropped = await waitForState(registry, sceneID: "scene-b") { $0 == .disconnected }
        XCTAssertTrue(bDropped, "scene-b drop must be detected")
        let bReconnected = await waitForState(registry, sceneID: "scene-b", timeoutMilliseconds: 20000) {
            $0 == .active
        }
        XCTAssertTrue(bReconnected, "scene-b must reconnect")

        try await quiesce(registry, sceneID: "scene-b", sink: sinks["scene-b"]!)
        try await registry.send(sceneID: "scene-b", Data("printf '__BAC''K__\\n'\n".utf8))
        let sawBack = await waitForContent(sink: sinks["scene-b"]!, marker: "__BACK__")
        XCTAssertTrue(sawBack)

        for sceneID in ["scene-a", "scene-c"] {
            let history = await registry.stateHistory(sceneID: sceneID)
            XCTAssertEqual(
                history, [.connecting, .active],
                "\(sceneID) must be undisturbed by scene-b's drop: \(history)"
            )
        }
    }
}
