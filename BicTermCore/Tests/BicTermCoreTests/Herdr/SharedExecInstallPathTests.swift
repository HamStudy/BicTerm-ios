import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

/// T4 shared-first install path: ``HerdrRemoteInstaller``'s three exec
/// steps (prepare/upload/commit) ride ONE lazily-dialed shared SSH
/// connection by default, and a channel-budget gateway's denial of the
/// shared carrier's channel open flips the installer's internal
/// ``SharedExecCarrierPool`` sticky-dedicated so every later step dials
/// its OWN connection — install success is preserved on both paths (the
/// user directive: efficient default, fallback recovery).
///
/// Hermetic: the ``LoopbackPasswordSSHServer`` in its opt-in exec drain
/// mode (stdin discarded until the client's SSH EOF, then the canned
/// reply — the wire shape a real stdin-consuming command takes, so the
/// binary upload can round-trip) plus a recording factory that counts
/// dials and per-connection exec attempts. No fixture sshd, no network.
/// The pinned macos-aarch64 binary is the checksum-gated payload (skip
/// when the repo-local fixture binary is absent); the probe result is
/// constructed directly, so the suite is host-arch independent.
final class SharedExecInstallPathTests: XCTestCase {
    private static let username = "shared-install-user"

    /// The prepare step's parseable stdout shape: `<tmp>\0<dest>\0`. The
    /// upload and commit steps ignore stdout (exit status only), so one
    /// canned reply serves all three execs.
    private static let cannedTmpPath = "/tmp/herdr-shared-install/herdr.tmp.42"
    private static let cannedDestPath = "/tmp/herdr-shared-install/herdr"
    private static let installPathsResponse =
        "\(cannedTmpPath)\u{0}\(cannedDestPath)\u{0}"

    // MARK: - Test doubles

    private struct StaticBinaryProvider: HerdrBinaryProvider {
        let data: Data

        func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data {
            data
        }
    }

    /// `SSHExecCapableConnection` double wrapping another connection:
    /// records every exec command ATTEMPTED on it and its `close()`
    /// receipts — the shared-vs-dedicated discipline probe.
    private final class RecordingConnection: SSHExecCapableConnection, @unchecked Sendable {
        private let underlying: any SSHExecCapableConnection
        private let lock = NSLock()
        private var attemptedCommands: [String] = []
        private var closeReceipts = 0

        init(underlying: any SSHExecCapableConnection) {
            self.underlying = underlying
        }

        func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
            lock.withLock { attemptedCommands.append(command) }
            return try await underlying.openExecChannel(command: command)
        }

        func close() async {
            await underlying.close()
            lock.withLock { closeReceipts += 1 }
        }

        var commands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return attemptedCommands
        }

        var closes: Int {
            lock.lock()
            defer { lock.unlock() }
            return closeReceipts
        }
    }

    /// Factory double: hands out recording-wrapped connections and
    /// exposes what was handed out — proves how many SSH connections the
    /// install dialed and which execs each carried.
    private final class RecordingInstallFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var handedOut: [RecordingConnection] = []
        private let make: @Sendable (Int) async throws -> any SSHExecCapableConnection

        init(make: @escaping @Sendable (Int) async throws -> any SSHExecCapableConnection) {
            self.make = make
        }

        func next() async throws -> any SSHExecCapableConnection {
            let index = lock.withLock { handedOut.count }
            let underlying = try await make(index)
            let recording = RecordingConnection(underlying: underlying)
            lock.withLock { handedOut.append(recording) }
            return recording
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return handedOut.count
        }

        var connections: [RecordingConnection] {
            lock.lock()
            defer { lock.unlock() }
            return handedOut
        }
    }

    // MARK: - Shared-first (unlimited gateway)

    /// An unlimited gateway: the three exec steps ride ONE lazily-dialed
    /// shared connection — the pre-pool shape resolved one FRESH
    /// connection per step (3 dials); the installer's pool collapses that
    /// to 1 dial, all three execs open on it, and the pool's close at
    /// install exit is the single close.
    func testUnlimitedGatewayInstallRidesOneSharedConnection() async throws {
        let binary = try Self.fixtureBinary()
        let (key, acceptedBlob) = try Self.makeClientKey()
        let server = LoopbackPasswordSSHServer(
            username: Self.username,
            password: "unused-password",
            keyAuthentication: .acceptedPublicKeys([acceptedBlob]),
            sessionChannelPolicy: .unlimited
        )
        server.execDrainsStdin = true
        server.execResponse = Self.installPathsResponse
        let port = try await server.start(port: 0)
        addTeardownBlock { await server.stop() }

        let factory = RecordingInstallFactory { _ in
            try await Self.makeLoopbackExecConnection(port: port, key: key, server: server)
        }
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let outcome = try await installer.install(
            using: { try await factory.next() },
            probe: Self.missingHerdrProbe,
            installDir: "$HOME/.local/bin"
        )

        // SHARED-FIRST: one dial for the whole install.
        XCTAssertEqual(
            factory.calls, 1,
            "the three exec steps rode ONE lazily-dialed shared connection (was 3 dials pre-pool)"
        )
        let connections = factory.connections
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(
            server.authenticatedConnectionCount, 1,
            "exactly one SSH connection authenticated for the whole install"
        )
        XCTAssertEqual(
            connections[0].commands,
            ["/bin/sh -s", "tee '\(Self.cannedTmpPath)'", "/bin/sh -s"],
            "prepare, upload, and commit all opened their exec on the shared carrier"
        )
        XCTAssertEqual(
            connections[0].closes, 1,
            "the pool's close at install exit closed the shared carrier exactly once"
        )

        XCTAssertEqual(outcome.destinationPath, Self.cannedDestPath)
        XCTAssertEqual(outcome.target, .macosAarch64)
    }

    // MARK: - Budget fallback (lifetime-1 gateway)

    /// The explicit budget-fallback pin: against a lifetime-1 gateway
    /// (ONE session-channel open per connection LIFETIME — the
    /// CoderSSHGW shape), prepare rides the shared carrier's only slot,
    /// the upload's open on that carrier is DENIED so the pool retires it
    /// and dials the upload its OWN dedicated connection, and the commit
    /// dials sticky-dedicated — 3 dials total (the Coder-era per-step
    /// shape, recovered exactly where the budget gateway requires it)
    /// AND the install still succeeds.
    func testLifetimeBudgetOneInstallFallsBackToDedicatedAndStillSucceeds() async throws {
        let binary = try Self.fixtureBinary()
        let (key, acceptedBlob) = try Self.makeClientKey()
        let server = LoopbackPasswordSSHServer(
            username: Self.username,
            password: "unused-password",
            keyAuthentication: .acceptedPublicKeys([acceptedBlob]),
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        server.execDrainsStdin = true
        server.execResponse = Self.installPathsResponse
        let port = try await server.start(port: 0)
        addTeardownBlock { await server.stop() }

        let factory = RecordingInstallFactory { _ in
            try await Self.makeLoopbackExecConnection(port: port, key: key, server: server)
        }
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let outcome = try await installer.install(
            using: { try await factory.next() },
            probe: Self.missingHerdrProbe,
            installDir: "$HOME/.local/bin"
        )

        // BUDGET FALLBACK: 3 dials — shared (prepare + the denied upload
        // attempt), the upload's dedicated fallback, and the commit's
        // sticky-dedicated connection.
        XCTAssertEqual(
            factory.calls, 3,
            "shared carrier, the upload's dedicated fallback, and the commit's sticky-dedicated connection"
        )
        let connections = factory.connections
        XCTAssertEqual(connections.count, 3)
        XCTAssertEqual(
            server.authenticatedConnectionCount, 3,
            "the budget gateway saw three connections — one per consumed lifetime slot"
        )
        XCTAssertEqual(
            connections[0].commands,
            ["/bin/sh -s", "tee '\(Self.cannedTmpPath)'"],
            "prepare succeeded on the shared carrier and the upload's open was ATTEMPTED (and denied) there first"
        )
        XCTAssertEqual(
            connections[0].closes, 1,
            "the denial retired the shared carrier exactly once"
        )
        XCTAssertEqual(
            connections[1].commands,
            ["tee '\(Self.cannedTmpPath)'"],
            "the upload retried its exec on the dedicated fallback connection"
        )
        XCTAssertEqual(
            connections[1].closes, 1,
            "the upload's lease owner-closed its dedicated connection"
        )
        XCTAssertEqual(
            connections[2].commands,
            ["/bin/sh -s"],
            "the commit dialed sticky-dedicated and ran its exec as that connection's only session channel"
        )
        XCTAssertEqual(
            connections[2].closes, 1,
            "the commit's lease owner-closed its dedicated connection"
        )

        // The fallback preserved install success.
        XCTAssertEqual(outcome.destinationPath, Self.cannedDestPath)
        XCTAssertEqual(outcome.target, .macosAarch64)
    }

    // MARK: - Fixtures

    /// The repo-local pinned macos-aarch64 binary (the checksum gate
    /// requires the real pinned bytes).
    private static func fixtureBinary() throws -> Data {
        let url = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "pinned herdr fixture binary missing — run scripts/herdr-server-fetch.sh"
        )
        return try Data(contentsOf: url)
    }

    /// A missing-binary probe result for the pinned macos-aarch64 target,
    /// constructed directly (host-arch independent — the probe is an
    /// input here, not a round-trip).
    private static let missingHerdrProbe = HerdrProbe.Result(
        host: "shared-install-fixture",
        rawOS: "Darwin",
        rawArch: "arm64",
        foundPath: nil,
        version: nil,
        endpointGeneration: nil,
        capabilities: []
    )

    /// Fresh software ed25519 key plus the blob the loopback server must
    /// accept for it.
    private static func makeClientKey() throws -> (key: NIOSSHPrivateKey, acceptedBlob: Data) {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let components = String(openSSHPublicKey: key.publicKey)
            .split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            throw NSError(domain: "SharedExecInstallPathTests", code: 1)
        }
        return (key, blob)
    }

    /// A FRESH channel-less exec-only connection to the loopback server
    /// (the production shape the installer's factory establishes).
    private static func makeLoopbackExecConnection(
        port: Int,
        key: NIOSSHPrivateKey,
        server: LoopbackPasswordSSHServer
    ) async throws -> any SSHExecCapableConnection {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        try await verifier.trust(
            host: "127.0.0.1",
            port: port,
            key: blob,
            algorithm: String(components[0])
        )
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key),
            passwordStore: InMemoryPasswordStore([:]),
            // The fixture metadata provider keeps the key offer non-empty
            // (the KeyOfferResolver filter would otherwise offer nothing
            // and authentication would fail).
            metadataProvider: FixtureKeyMetadataProvider()
        )
        let connection = try Connection(
            name: "shared-install", type: .ssh,
            host: "127.0.0.1", port: port,
            username: username,
            customKeys: ["fixture-ed25519"]
        )
        try await transport.connectExecOnly(to: connection)
        return transport
    }
}
