import Foundation
import XCTest
@testable import BicTermCore

/// UDS dial conformance (plan T8): key-auth PTY round-trip through the
/// fixtures-up uds-forward.py bridge, plus the per-session bridge lifecycle
/// contract (stale sweep, 0600, distinct concurrent sockets, no leaks).
/// Scaffolding lives in SSHTransportTestSupport.swift.

// MARK: - Tests

final class UDSTransportTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    /// The forwarder socket fixtures-up.sh binds, bridging UDS -> hop1's
    /// 127.0.0.1:12222 sshd. Key auth is used through it (real sshd), which
    /// conformance-proves the UDS dial path against an unmodified server.
    private var fixtureUDSPath: String {
        SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/sshd-uds.sock")
            .path
    }

    private func makeFixtureKeyTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier()
        return SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
    }

    private func beginCollecting(_ transport: SSHTransport) async -> SSHOutputSink {
        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        return sink
    }

    /// Neutralizes the interactive shell and drains until the ready marker —
    /// same contract the TCP integration tests use.
    private func quiesce(_ transport: SSHTransport, sink: SSHOutputSink) async throws {
        try await transport.send(Data(
            "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"
                .utf8
        ))
        let ready = await waitForContent(sink: sink, marker: "__READY__", timeoutMilliseconds: 8000)
        XCTAssertTrue(ready, "shell did not reach ready marker")
        await sink.reset()
    }

    func testUDSPTYRoundTripThroughFixtureForwarder() async throws {
        // Given: the fixtures-up UDS forwarder socket exists, mode 0600
        let attributes = try FileManager.default.attributesOfItem(atPath: fixtureUDSPath)
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType, .typeSocket,
            "Fixtures/run/sshd-uds.sock missing — run scripts/fixtures-up.sh"
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        // When: a key-authenticated session connects over the socket
        let transport = try await makeFixtureKeyTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(
            unixSocketPath: fixtureUDSPath,
            to: SSHTestFixture.makeConnection(),
            cols: 80,
            rows: 24
        )
        let sink = await beginCollecting(transport)
        try await quiesce(transport, sink: sink)

        // Then: shell bytes round-trip exactly, and server-closed exit ends the stream
        try await transport.send(Data("printf bicterm-uds-ok; exit\n".utf8))
        let finished = await waitForFinished(sink: sink)
        XCTAssertTrue(finished, "server did not close the channel after exit")

        let normalized = String(decoding: await sink.snapshot(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(normalized, "bicterm-uds-ok")
    }

    func testStalePathCollisionIsSweptBeforeBind() async throws {
        // Given: a leftover non-socket file at the intended socket path
        let path = makeTestSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale-crash-leftover".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // When: the bridge binds at that path
        let bridge = UDSTestBridge(path: path, targetPort: SSHTestFixture.hop1Port)
        try await bridge.start()
        defer { Task { await bridge.stop() } }

        // Then: the stale file was replaced by a working socket
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let transport = try await makeFixtureKeyTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(
            unixSocketPath: path,
            to: SSHTestFixture.makeConnection(),
            cols: 80,
            rows: 24
        )
        let sink = await beginCollecting(transport)
        try await quiesce(transport, sink: sink)
        try await transport.send(Data("printf stale-swept; exit\n".utf8))
        let finished = await waitForFinished(sink: sink)
        XCTAssertTrue(finished)
        let output = String(decoding: await sink.snapshot(), as: UTF8.self)
        XCTAssertTrue(output.contains("stale-swept"), "expected round-trip, got: \(output)")
        await transport.close()
        await bridge.stop()
    }

    func testConcurrentSessionsDistinctSocketsNoCrossTalk() async throws {
        // Given: two per-session bridges and two transports
        let pathOne = makeTestSocketPath()
        let pathTwo = makeTestSocketPath()
        XCTAssertNotEqual(pathOne, pathTwo, "per-session socket paths must be distinct")
        let bridgeOne = UDSTestBridge(path: pathOne, targetPort: SSHTestFixture.hop1Port)
        let bridgeTwo = UDSTestBridge(path: pathTwo, targetPort: SSHTestFixture.hop1Port)
        try await bridgeOne.start()
        try await bridgeTwo.start()
        defer {
            Task { await bridgeOne.stop() }
            Task { await bridgeTwo.stop() }
        }

        // When: both sessions connect and emit distinct markers
        let transportOne = try await makeFixtureKeyTransport()
        let transportTwo = try await makeFixtureKeyTransport()
        defer {
            Task { await transportOne.close() }
            Task { await transportTwo.close() }
        }
        let connection = try SSHTestFixture.makeConnection()
        try await transportOne.connect(unixSocketPath: pathOne, to: connection, cols: 80, rows: 24)
        try await transportTwo.connect(unixSocketPath: pathTwo, to: connection, cols: 80, rows: 24)
        let sinkOne = await beginCollecting(transportOne)
        let sinkTwo = await beginCollecting(transportTwo)
        try await quiesce(transportOne, sink: sinkOne)
        try await quiesce(transportTwo, sink: sinkTwo)

        try await transportOne.send(Data("printf session-one-mark; exit\n".utf8))
        try await transportTwo.send(Data("printf session-two-mark; exit\n".utf8))
        let finishedOne = await waitForFinished(sink: sinkOne)
        let finishedTwo = await waitForFinished(sink: sinkTwo)
        XCTAssertTrue(finishedOne)
        XCTAssertTrue(finishedTwo)

        // Then: each sink carries only its own session's marker
        let outputOne = String(decoding: await sinkOne.snapshot(), as: UTF8.self)
        let outputTwo = String(decoding: await sinkTwo.snapshot(), as: UTF8.self)
        XCTAssertTrue(outputOne.contains("session-one-mark"))
        XCTAssertFalse(outputOne.contains("session-two-mark"), "cross-talk from session two into one")
        XCTAssertTrue(outputTwo.contains("session-two-mark"))
        XCTAssertFalse(outputTwo.contains("session-one-mark"), "cross-talk from session one into two")
        await transportOne.close()
        await transportTwo.close()
        await bridgeOne.stop()
        await bridgeTwo.stop()
    }

    func testPartialStartupFailureSurfacesTypedErrorAndNoSocketLeak() async throws {
        // Given #1: no listener at the dialed path at all
        let noListenerPath = makeTestSocketPath()
        let transport = try await makeFixtureKeyTransport()
        defer { Task { await transport.close() } }

        // When/Then #1: the dial fails typed .unreachable, before any session state
        await assertThrowsSSHError(.unreachable) {
            try await transport.connect(
                unixSocketPath: noListenerPath,
                to: SSHTestFixture.makeConnection(),
                cols: 80,
                rows: 24
            )
        }

        // Given #2: a bridge whose TCP target is dead
        let deadTargetPath = makeTestSocketPath()
        let bridge = UDSTestBridge(path: deadTargetPath, targetPort: 9)
        try await bridge.start()

        // When/Then #2: the connect fails typed (peer pipe closes mid-handshake),
        // and stopping the bridge removes the socket — no leftover file
        do {
            try await transport.connect(
                unixSocketPath: deadTargetPath,
                to: SSHTestFixture.makeConnection(),
                cols: 80,
                rows: 24
            )
            XCTFail("connect to a dead-target bridge must fail")
        } catch is SSHTransportError {
            // typed surface; exact case depends on where the pipe dropped
        }
        await bridge.stop()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: deadTargetPath),
            "bridge teardown must unlink the socket path"
        )
    }

    func testCleanupOnCancelRemovesSocketPath() async throws {
        // Given: a live bridge and a connected transport
        let path = makeTestSocketPath()
        let bridge = UDSTestBridge(path: path, targetPort: SSHTestFixture.hop1Port)
        try await bridge.start()
        let transport = try await makeFixtureKeyTransport()
        try await transport.connect(
            unixSocketPath: path,
            to: SSHTestFixture.makeConnection(),
            cols: 80,
            rows: 24
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // When: the session is cancelled and the bridge stops
        await transport.close()
        await bridge.stop()

        // Then: the socket path is gone
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "closed session's socket path must be removed"
        )
    }
}
