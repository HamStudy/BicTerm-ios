import Foundation
import XCTest
@testable import BicTermCore

/// T15 herdr bridge transport round-trips over the framed-protocol mock
/// (`Fixtures/herdr/mock-bridge.py` via the `mock-herdr` shim, run by the
/// fixture sshd's exec channel) — no real herdr involved.
///
/// Proves the ``HerdrSSHTransport`` byte-stream seam over BOTH transport
/// sources: direct TCP SSH and the UDS forwarder chain, plus chunk-boundary
/// independence, stderr isolation, and behavioral command-injection
/// resistance through the real sshd shell.
final class HerdrSSHTransportTests: XCTestCase {
    private var transport: SSHTransport?

    /// Mirror of the mock's canned payloads (Fixtures/herdr/mock-bridge.py).
    private static let welcomePayload = Data("MOCK-WELCOME-v1".utf8)
        + Data([0x00, 0x01, 0xff, 0x80, 0xfe])
        + Data((1...16).map { UInt8($0) })
    private static let snapshotPayload = Data("MOCK-SNAPSHOT-v1".utf8)
        + Data((0..<256).map { UInt8($0) }) * 4

    static let shimPath = SSHTestFixture.repoRoot
        .appendingPathComponent("Fixtures/herdr/mock-herdr").path

    override func tearDown() async throws {
        if let transport {
            await transport.close()
        }
        transport = nil
        try await super.tearDown()
    }

    private func makeDirectTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        self.transport = transport
        return transport
    }

    /// Chained path: UDS dial through the fixtures-up forwarder to the same
    /// fixture sshd.
    private func makeUDSTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        let udsPath = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/sshd-uds.sock").path
        try await transport.connect(unixSocketPath: udsPath, to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        self.transport = transport
        return transport
    }

    // MARK: - Frame helpers (herdr outer envelope: 4-byte LE length)

    private func frame(_ payload: Data) -> Data {
        var framed = Data()
        let length = UInt32(payload.count)
        framed.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        framed.append(payload)
        return framed
    }

    private var expectedWelcomeAndSnapshot: Data {
        frame(Self.welcomePayload) + frame(Self.snapshotPayload)
    }

    private func collectInbound(_ herdr: HerdrSSHTransport) async throws -> Data {
        var data = Data()
        for try await chunk in herdr.inboundBytes() {
            data.append(chunk)
        }
        return data
    }

    // MARK: - Mock handshake + lossless binary round-trip

    func testMockBridgeHandshakeAndEchoRoundTripOverDirectTCP() async throws {
        let transport = try await makeDirectTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: Self.shimPath
        )

        try await herdr.write(frame(Data("HELLO".utf8) + Data([0x00, 0xFF])))
        let echoPayloads = [
            Data("tiny".utf8),
            Data((0..<256).map { UInt8($0) }),                    // NULs + >0x7f sweep
            Data(repeating: 0x5a, count: 70_000),                 // spans several SSH packets
        ]
        for payload in echoPayloads {
            try await herdr.write(frame(payload))
        }
        try await herdr.closeWrite()

        let received = try await collectInbound(herdr)
        XCTAssertEqual(
            received,
            expectedWelcomeAndSnapshot + echoPayloads.map(frame).reduce(Data(), +),
            "welcome+snapshot canned frames followed by byte-identical echoes"
        )
        let termination = await herdr.session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    func testMockBridgeHandshakeRoundTripOverUDSForwarderChain() async throws {
        let transport = try await makeUDSTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: Self.shimPath,
            sessionName: "work"
        )

        try await herdr.write(frame(Data("uds-hello".utf8)))
        try await herdr.write(frame(Data("uds-echo".utf8)))
        try await herdr.closeWrite()

        let received = try await collectInbound(herdr)
        XCTAssertEqual(
            received,
            expectedWelcomeAndSnapshot
                + frame(Data("uds-echo".utf8))
        )

        // The validated session name reached the remote argv: the mock's
        // stderr diagnostic proves the --session flag traversed the chain.
        var stderr = Data()
        for await chunk in herdr.session.stderr {
            stderr.append(chunk)
        }
        XCTAssertTrue(
            String(decoding: stderr, as: UTF8.self).contains("session=work"),
            "stderr diagnostic must reflect the --session flag: \(String(decoding: stderr, as: UTF8.self))"
        )
        let termination = await herdr.session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    /// Chunk-boundary independence: the same frame sequence fed
    /// one-byte-at-a-time and as whole-frame writes must decode to the
    /// identical byte stream.
    func testChunkBoundaryIndependenceAcrossWriteStyles() async throws {
        let transport = try await makeDirectTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: Self.shimPath
        )

        let payloads = [
            Data("chunked".utf8),
            Data((0..<64).map { UInt8(($0 * 7) & 0xff) }),
        ]
        // The mock consumes one hello frame (payload ignored, not echoed).
        try await herdr.write(frame(Data("hello".utf8)))
        let wholeFrames = payloads.map(frame).reduce(Data(), +)
        for byte in wholeFrames {
            try await herdr.write(Data([byte]))
        }
        try await herdr.closeWrite()

        let received = try await collectInbound(herdr)
        XCTAssertEqual(
            received,
            expectedWelcomeAndSnapshot + payloads.map(frame).reduce(Data(), +),
            "1-byte-at-a-time writes must produce the identical frame stream"
        )
    }

    /// stderr garbage never enters the byte stream: inbound bytes equal the
    /// canned frames EXACTLY (the mock always writes a diagnostic line to
    /// stderr first), and the diagnostic is reachable only on the session's
    /// stderr stream.
    func testStderrDiagnosticsNeverEnterInboundBytes() async throws {
        let transport = try await makeDirectTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: Self.shimPath
        )

        // The mock consumes one hello frame (payload ignored, not echoed).
        try await herdr.write(frame(Data("hello".utf8)))
        try await herdr.write(frame(Data("x".utf8)))
        try await herdr.closeWrite()

        let received = try await collectInbound(herdr)
        XCTAssertEqual(received, expectedWelcomeAndSnapshot + frame(Data("x".utf8)))
        XCTAssertFalse(received.contains(Data("mock-bridge".utf8)))

        var stderr = Data()
        for await chunk in herdr.session.stderr {
            stderr.append(chunk)
        }
        XCTAssertTrue(String(decoding: stderr, as: UTF8.self).contains("mock-bridge: ready"))
    }

    // MARK: - Injection resistance, behavioral (through the real sshd shell)

    /// The builder-quoted command must exec the mock even when the
    /// executable path itself carries spaces, a quote, `$()`, backticks
    /// and UTF-8 — every vector inert under POSIX single-quoting.
    func testHostileExecutablePathIsSafelyQuotedAgainstRealShell() async throws {
        let hostile = try Self.materializeHostileShim()
        defer { try? FileManager.default.removeItem(at: hostile.dir) }
        let transport = try await makeDirectTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: hostile.shim
        )

        // The mock consumes one hello frame (payload ignored, not echoed).
        try await herdr.write(frame(Data("hello".utf8)))
        try await herdr.write(frame(Data("injection-proof".utf8)))
        try await herdr.closeWrite()

        let received = try await collectInbound(herdr)
        XCTAssertEqual(
            received,
            expectedWelcomeAndSnapshot + frame(Data("injection-proof".utf8)),
            "the hostile path must exec the mock, not a shell artifact"
        )
        let termination = await herdr.session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    /// A hostile session name is rejected by the builder BEFORE any channel
    /// is opened — the typed builder error surfaces from the transport init.
    func testHostileSessionNameIsRejectedBeforeQuoting() async throws {
        let transport = try await makeDirectTransport()
        do {
            _ = try await HerdrSSHTransport(
                transport: transport,
                executablePath: Self.shimPath,
                sessionName: "work; rm -rf /"
            )
            XCTFail("hostile session name must be rejected")
        } catch let error as HerdrCommandBuilder.BuildError {
            XCTAssertEqual(error, .invalidSessionName)
        }
    }

    /// Channel-open failure surfaces as a thrown error from the convenience
    /// init — never a crash (regression guard for the init error path).
    func testChannelOpenFailureThrowsWithoutCrash() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let offline = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        do {
            _ = try await HerdrSSHTransport(transport: offline, executablePath: Self.shimPath)
            XCTFail("init on an unconnected transport must throw")
        } catch let error as TransportError {
            XCTAssertEqual(error, .channelDenied)
        }
    }

    // MARK: - HerdrByteTransport surface semantics

    func testCloseIsTerminalAndFinishesInboundStream() async throws {
        let transport = try await makeDirectTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: Self.shimPath
        )
        try await herdr.write(frame(Data("bye".utf8)))

        await herdr.close()
        await herdr.close()

        var sawError: Error?
        do {
            for try await _ in herdr.inboundBytes() {}
        } catch {
            sawError = error
        }
        XCTAssertNil(sawError, "close() must finish the inbound stream cleanly")
    }

    // MARK: - Lossless inbound bridging under burst (T14)

    /// The real-iPad failure shape: a surface-output burst floods stdout
    /// faster than the decode consumer drains it (main-actor contention),
    /// and the inbound bridge must deliver EVERY byte while the consumer
    /// is slow — no drops, no overflow teardown. The consumer runs
    /// concurrently with the flood writes because a demand-driven bridge
    /// (SSH-window backpressure) otherwise legitimately throttles the
    /// remote: that coupling IS the contract under test.
    func testInboundBridgeIsLosslessUnderBurstFloodWithSlowConsumer() async throws {
        let transport = try await makeDirectTransport()
        let herdr = try await HerdrSSHTransport(
            transport: transport,
            executablePath: Self.shimPath
        )

        // 4 MiB deterministic echo flood in 16 KiB frames (256 frames).
        var entropy = Data()
        var seed: UInt64 = 0x9E3779B97F4A7C15
        while entropy.count < 16 * 1024 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var value = seed
            withUnsafeBytes(of: &value) { entropy.append(contentsOf: $0) }
        }
        let payload = Data(entropy.prefix(16 * 1024))

        // Slow decode consumer: 4 ms per ≤32 KiB chunk, mirroring a decode
        // pump that hops to the main actor per chunk under load.
        let consumer = Task<(received: Data, streamError: String?), Never> {
            var received = Data()
            do {
                for try await chunk in herdr.inboundBytes() {
                    received.append(chunk)
                    try? await Task.sleep(for: .milliseconds(4))
                }
                return (received, nil)
            } catch {
                return (received, "\(error)")
            }
        }

        try await herdr.write(frame(Data("hello".utf8)))
        let floodFrames = (0..<256).map { _ in frame(payload) }
        for floodFrame in floodFrames {
            try await herdr.write(floodFrame)
        }
        try await herdr.closeWrite()

        let (received, streamError) = await consumer.value
        let expected = expectedWelcomeAndSnapshot + floodFrames.reduce(Data(), +)
        print(
            "T14 flood: expected \(expected.count) bytes, received \(received.count) bytes"
                + (streamError.map { ", stream finished with \($0)" } ?? "")
        )
        XCTAssertNil(
            streamError,
            "the inbound bridge must stay lossless, not die on overflow: \(streamError ?? "")"
        )
        XCTAssertEqual(
            received,
            expected,
            "burst flood with a slow consumer must arrive byte-exactly"
        )
    }

    // MARK: - Hostile shim materialization

    /// Per-run unique hostile dir: no shared Fixtures/run state, immune to
    /// wrapper fixture resets and concurrent duplicate runs. Caller must
    /// remove the returned dir (see test's defer).
    private static func materializeHostileShim() throws -> (dir: URL, shim: String) {
        let runRoot = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run")
        let uniqueDir = runRoot.appendingPathComponent("herdr-hostile-\(UUID().uuidString)")
        let hostileDir = uniqueDir.appendingPathComponent("herdr 'q\"$(`dir)`'")
        let destination = hostileDir.appendingPathComponent("mock-herdr")
        try FileManager.default.createDirectory(at: hostileDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: shimPath), to: destination)
        // The shim resolves mock-bridge.py relative to itself; copy the sibling too.
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/herdr/mock-bridge.py").path),
            to: hostileDir.appendingPathComponent("mock-bridge.py")
        )
        return (uniqueDir, destination.path)
    }
}

private func * (data: Data, count: Int) -> Data {
    var result = Data()
    result.reserveCapacity(data.count * count)
    for _ in 0..<count {
        result.append(data)
    }
    return result
}
