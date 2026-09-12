import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Security
import XCTest
@testable import BicTermCore

final class SSHTransportIntegrationTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private func makeConnectedTransport(
        cols: Int = 80,
        rows: Int = 24
    ) async throws -> (SSHTransport, SSHOutputSink) {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier()
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: cols, rows: rows)
        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        return (transport, sink)
    }

    /// Neutralizes the interactive shell (echo, ZLE line-editor redisplay,
    /// prompt and zshrc preexec/precmd title hooks) and waits for a
    /// split-string ready marker, so subsequent assertions see only the
    /// bytes produced by the next command. The marker is split so the
    /// ZLE-echoed command line never contains it contiguously.
    private func quiesce(_ transport: SSHTransport, sink: SSHOutputSink) async throws {
        try await transport.send(Data(
            "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"
                .utf8
        ))
        let ready = await waitForContent(sink: sink, marker: "__READY__", timeoutMilliseconds: 8000)
        XCTAssertTrue(ready, "shell did not reach ready marker")
        await sink.reset()
    }

    func testEd25519RoundTripProducesExactOutput() async throws {
        let (transport, sink) = try await makeConnectedTransport()
        defer { Task { await transport.close() } }

        try await quiesce(transport, sink: sink)

        try await transport.send(Data("printf bicterm-ok; exit\n".utf8))
        let finished = await waitForFinished(sink: sink)
        XCTAssertTrue(finished, "server did not close the channel after exit")

        let raw = await sink.snapshot()
        let normalized = String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(normalized, "bicterm-ok")
    }

    func testResizePropagatesToServerPTY() async throws {
        let (transport, sink) = try await makeConnectedTransport(cols: 80, rows: 24)
        defer { Task { await transport.close() } }

        try await quiesce(transport, sink: sink)

        await transport.resize(cols: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(300))
        try await transport.send(Data("stty size; exit\n".utf8))

        let finished = await waitForFinished(sink: sink)
        XCTAssertTrue(finished, "server did not close the channel after exit")

        let raw = await sink.snapshot()
        let normalized = String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(
            normalized.contains("40 120"),
            "expected server-side stty size to report 40 rows 120 cols, got: \(normalized)"
        )
    }

    func testUnknownHostRequiresTrustWithKnownFingerprint() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier(trustingNormalHop1Key: false)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        defer { Task { await transport.close() } }

        do {
            try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
            XCTFail("untrusted host must not connect")
        } catch let SSHTransportError.requiresTrust(fingerprint, algorithm, publicKeyData) {
            XCTAssertEqual(fingerprint, SSHTestFixture.normalHostKeyFingerprint)
            XCTAssertEqual(algorithm, "ssh-ed25519")
            let expected = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
            XCTAssertEqual(publicKeyData, expected.blob)
        } catch {
            XCTFail("expected requiresTrust, got \(error)")
        }
    }

    func testWrongKeyFailsWithAuthenticationFailed() async throws {
        // The preceding unknown-host test disconnects pre-auth, tripping
        // sshd's PerSourcePenalties noauth penalty for 127.0.0.1; wait out
        // the short deferred window so this connection reaches userauth.
        try await Task.sleep(for: .seconds(3))

        let wrongKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let verifier = try await SSHTestFixture.makeVerifier()
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: wrongKey)
        )
        defer { Task { await transport.close() } }

        do {
            try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
            XCTFail("unauthorized key must not connect")
        } catch let error as SSHTransportError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    func testClosedPortIsUnreachable() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier(trustingNormalHop1Key: false)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        defer { Task { await transport.close() } }

        let connection = try Connection(
            name: "closed-port",
            type: .ssh,
            host: "127.0.0.1",
            port: 9,
            username: SSHTestFixture.username,
            keyReference: "fixture-ed25519"
        )
        do {
            try await transport.connect(to: connection, cols: 80, rows: 24)
            XCTFail("closed port must not connect")
        } catch let error as SSHTransportError {
            XCTAssertEqual(error, .unreachable)
        }
    }

    func testDirectTCPIPCarriesByteStream() async throws {
        let (transport, _) = try await makeConnectedTransport()
        defer { Task { await transport.close() } }

        let handle = try await transport.openDirectTCPIPChannel(
            toHost: "127.0.0.1",
            port: SSHTestFixture.hop2Port
        )
        XCTAssertTrue(handle.isActive)

        final class ByteRecorder: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let sink: SSHOutputSink
            init(sink: SSHOutputSink) { self.sink = sink }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let buffer = unwrapInboundIn(data)
                let bytes = Data(buffer.readableBytesView)
                let sink = self.sink
                Task { await sink.append(bytes) }
            }
        }

        let sink = SSHOutputSink()
        try await handle.channel.pipeline.addHandler(ByteRecorder(sink: sink)).get()

        // hop2's sshd sends its identification banner on TCP connect; reading
        // it through the channel proves the byte stream end to end.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var received = ""
        while clock.now < deadline {
            received = String(decoding: await sink.snapshot(), as: UTF8.self)
            if received.contains("SSH-2.0") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            received.contains("SSH-2.0"),
            "expected sshd banner through direct-tcpip channel, got: \(received)"
        )
    }

    func testSoftwareP256AuthRoundTrip() async throws {
        let p256 = P256.Signing.PrivateKey()
        let openSSHLine = String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: p256).publicKey)
        XCTAssertTrue(openSSHLine.hasPrefix("ecdsa-sha2-nistp256 "))

        try await SSHTestFixture.withHop1AuthorizedKeyAdded(openSSHLine) {
            let verifier = try await SSHTestFixture.makeVerifier()
            let transport = SSHTransport(
                hostKeyVerifier: verifier,
                authenticationKeyProvider: StaticKeyProvider(key: NIOSSHPrivateKey(p256Key: p256))
            )
            defer { Task { await transport.close() } }

            try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
            let sink = SSHOutputSink()
            collectors.append(await startCollecting(from: transport, into: sink))
            try await quiesce(transport, sink: sink)

            try await transport.send(Data("printf bicterm-ok; exit\n".utf8))
            let finished = await waitForFinished(sink: sink)
            XCTAssertTrue(finished)
            let rawOutput = await sink.snapshot()
            let normalized = String(decoding: rawOutput, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(normalized, "bicterm-ok")
        }
    }

    func testSecureEnclaveAuthRoundTrip() async throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "Secure Enclave unavailable")

        let service = SecureEnclaveKeyService(
            keychainService: "com.bicterm.tests.t7-se.\(UUID().uuidString)"
        )
        let metadata: KeyMetadata
        do {
            metadata = try await service.generate(label: "T7 SE transport test", requiresBiometry: false)
        } catch {
            throw XCTSkip("SE keychain unavailable in this test environment: \(error)")
        }
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service.keychainService,
                kSecAttrAccount as String: metadata.reference,
                kSecUseDataProtectionKeychain as String: true,
            ]
            SecItemDelete(query as CFDictionary)
        }

        let openSSHLine = "ecdsa-sha2-nistp256 \(metadata.publicKeyBlob.base64EncodedString())"
        try await SSHTestFixture.withHop1AuthorizedKeyAdded(openSSHLine) {
            let verifier = try await SSHTestFixture.makeVerifier()
            let transport = SSHTransport(
                hostKeyVerifier: verifier,
                authenticationKeyProvider: StaticKeyProvider(
                    key: try await service.authenticationPrivateKey(
                        with: metadata.reference,
                        reason: "T7 SE transport test"
                    )
                )
            )
            defer { Task { await transport.close() } }

            try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
            let sink = SSHOutputSink()
            collectors.append(await startCollecting(from: transport, into: sink))
            try await quiesce(transport, sink: sink)

            try await transport.send(Data("printf bicterm-ok; exit\n".utf8))
            let finished = await waitForFinished(sink: sink)
            XCTAssertTrue(finished)
            let rawOutput = await sink.snapshot()
            let normalized = String(decoding: rawOutput, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(normalized, "bicterm-ok")
        }
    }

    /// Runs ONLY while hop1 serves the ALT host key (orchestrated by the
    /// host via `HOP1_ALT_KEY=1 scripts/fixtures-up.sh`); the store is
    /// pre-trusted with the NORMAL committed host key.
    func testChangedHostKeyProducesTypedRejection() async throws {
        try XCTSkipUnless(
            SSHTestFixture.hop1ActiveConfig().contains("alt"),
            "requires HOP1_ALT_KEY=1 fixtures-up"
        )

        let verifier = try await SSHTestFixture.makeVerifier(trustingNormalHop1Key: true)
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        defer { Task { await transport.close() } }

        do {
            try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
            XCTFail("changed host key must not connect")
        } catch let SSHTransportError.hostKeyChanged(host, port, oldFingerprint, newFingerprint) {
            XCTAssertEqual(host, SSHTestFixture.hop1Host)
            XCTAssertEqual(port, SSHTestFixture.hop1Port)
            XCTAssertEqual(oldFingerprint, SSHTestFixture.normalHostKeyFingerprint)
            XCTAssertEqual(newFingerprint, SSHTestFixture.altHostKeyFingerprint)
        }

        let shellBytes = await sink.snapshot()
        XCTAssertEqual(
            shellBytes.count, 0,
            "zero shell bytes may be delivered on host-key change"
        )
        await assertThrowsSSHError(.channelDenied) {
            _ = try await transport.sessionChannelHandle()
        }
    }
}
