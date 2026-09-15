import Foundation
import XCTest
@testable import BicTermCore

/// T4 herdr endpoint connector against the fixture sshd on 12222 (and the
/// two-hop 12222→12223 chain): full establish→probe→bridge ordering, the
/// TOFU approval surface, typed failure mapping, and the read-only probe
/// boundary — an incompatible probe never opens the bridge exec channel
/// (proven through the sshd's own exec log).
final class HerdrEndpointConnectorTests: XCTestCase {
    private static let statusShimPath = SSHTestFixture.repoRoot
        .appendingPathComponent("Fixtures/herdr/fake-herdr-status").path

    private var bridge: HerdrSSHTransport?

    override func tearDown() async throws {
        if let bridge {
            await bridge.close()
        }
        bridge = nil
        try await super.tearDown()
    }

    private func makeConnector(
        searchPaths: [String],
        approval: @escaping @Sendable (HerdrHostTrustChallenge) async -> Bool = { _ in false }
    ) async throws -> HerdrEndpointConnector {
        HerdrEndpointConnector(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: searchPaths,
            approveHostKey: approval
        )
    }

    private func frame(_ payload: Data) -> Data {
        var framed = Data()
        let length = UInt32(payload.count)
        framed.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        framed.append(payload)
        return framed
    }

    /// Materializes a one-shot herdr stand-in under Fixtures/run that
    /// answers the probe's `status client --json` with a compatible
    /// generation-1 status AND forwards `remote-client-bridge` to the
    /// framed-protocol mock (mock-bridge.py, copied as a sibling). Returns
    /// the shim path; caller removes `URL(fileURLWithPath:).deletingLastPathComponent()`.
    private static func materializeProbeAndBridgeShim() throws -> String {
        let dir = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("herdr")
        let script = """
        #!/bin/sh
        if [ "$1" = status ] && [ "$2" = client ] && [ "$3" = --json ]; then
          printf '{"version":"0.9.0-fixture","channel":"stable","protocol":22,"endpoint_protocol_generation":1,"endpoint_capabilities":["surface_interest"],"binary":"%s","session":null}\n' "$0"
          exit 0
        fi
        for last in "$@"; do :; done
        if [ "$last" = remote-client-bridge ]; then
          exec python3 "$(dirname "$0")/mock-bridge.py" "$@"
        fi
        exit 2

        """
        try script.data(using: .utf8)?.write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        try FileManager.default.copyItem(
            at: SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/herdr/mock-bridge.py"),
            to: dir.appendingPathComponent("mock-bridge.py")
        )
        return shim.path
    }

    /// Materializes a one-shot executable status shim answering the probe's
    /// status query with `statusReply` (a raw line, valid JSON or not).
    private static func materializeStatusShim(replying statusReply: String) throws -> String {
        let dir = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("herdr")
        let script = """
        #!/bin/sh
        if [ "$1" = status ] && [ "$2" = client ] && [ "$3" = --json ]; then
          printf '%s\\n' '\(statusReply)'
          exit 0
        fi
        exit 2

        """
        try script.data(using: .utf8)?.write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        return shim.path
    }

    // MARK: - Full ordering: establish → probe → bridge

    func testCompatibleProbeOpensReadyBridgeOnSameConnection() async throws {
        let shim = try Self.materializeProbeAndBridgeShim()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path) }
        let connector = try await makeConnector(searchPaths: [shim])
        let herdr = try await connector.connect(SSHTestFixture.makeConnection())
        bridge = herdr

        // The mock bridge speaks: canned welcome+snapshot, then echo.
        try await herdr.write(frame(Data("connector-hello".utf8)))
        try await herdr.write(frame(Data("connector-echo".utf8)))
        try await herdr.closeWrite()

        var received = Data()
        for try await chunk in herdr.inboundBytes() {
            received.append(chunk)
        }
        XCTAssertTrue(received.contains(Data("MOCK-WELCOME-v1".utf8)))
        XCTAssertTrue(received.contains(frame(Data("connector-echo".utf8))))
        let termination = await herdr.session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    /// Ordering invariant, sshd-side proof: the probe's exec ran
    /// (`command -v herdr`) but NO `remote-client-bridge` exec ever opened
    /// when the probe found nothing — the no-server case simulated exactly
    /// as briefed (search paths point at a nonexistent location).
    func testIncompatibleProbeNeverOpensBridgeExec() async throws {
        let logOffset = fixtureLogSize("hop1.log")
        let connector = try await makeConnector(
            searchPaths: ["/nonexistent-bicterm-connector/herdr"]
        )

        do {
            _ = try await connector.connect(SSHTestFixture.makeConnection())
            XCTFail("missing herdr must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .incompatibleEndpoint(result, detail) = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
            XCTAssertFalse(result.isCompatible)
            XCTAssertNil(result.foundPath)
            XCTAssertTrue(detail.contains("No herdr executable was found"), detail)
        }

        let appendage = fixtureLogAppendage("hop1.log", from: logOffset)
        XCTAssertTrue(
            appendage.contains("command -v herdr"),
            "the probe exec must have run on the sshd"
        )
        XCTAssertFalse(
            appendage.contains("remote-client-bridge"),
            "no bridge exec may run after an incompatible probe"
        )
    }

    // MARK: - Typed diagnostics: off-version and unknown-version wording

    func testOffVersionHerdrSurfacesTypedIncompatibleEndpointWithVersionWording() async throws {
        let shim = try Self.materializeStatusShim(
            replying: #"{"version":"0.8.0","endpoint_protocol_generation":99,"endpoint_capabilities":[]}"#
        )
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path) }
        let connector = try await makeConnector(searchPaths: [shim])

        do {
            _ = try await connector.connect(SSHTestFixture.makeConnection())
            XCTFail("generation-99 herdr must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .incompatibleEndpoint(result, detail) = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
            XCTAssertEqual(result.version, "0.8.0")
            XCTAssertEqual(result.endpointGeneration, 99)
            XCTAssertTrue(detail.contains("herdr 0.8.0"), detail)
            XCTAssertTrue(detail.contains("generation 99"), detail)
            XCTAssertTrue(detail.contains("requires generation 1"), detail)
        }
    }

    func testUnknownVersionHerdrSurfacesTypedIncompatibleEndpointWithUnknownWording() async throws {
        // Found and executable, but the status query answers nothing the
        // probe can parse: version/generation stay nil → fail-closed.
        let shim = try Self.materializeStatusShim(replying: "{not json")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path) }
        let connector = try await makeConnector(searchPaths: [shim])

        do {
            _ = try await connector.connect(SSHTestFixture.makeConnection())
            XCTFail("unreporting herdr must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .incompatibleEndpoint(result, detail) = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
            XCTAssertEqual(result.foundPath, shim)
            XCTAssertNil(result.version)
            XCTAssertNil(result.endpointGeneration)
            XCTAssertTrue(detail.contains("did not report its version"), detail)
            XCTAssertTrue(detail.contains("generation 1"), detail)
        }
    }

    // MARK: - TOFU approval surface

    func testFirstSeenHostKeyPromptsApprovalOnceThenConnectsAfterTrust() async throws {
        let approvalRecorder = ApprovalRecorder(decision: true)
        let connector = HerdrEndpointConnector(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: [Self.statusShimPath],
            approveHostKey: approvalRecorder.approve
        )

        let herdr = try await connector.connect(SSHTestFixture.makeConnection())
        bridge = herdr

        let challenges = approvalRecorder.recordedChallenges
        XCTAssertEqual(challenges.count, 1, "exactly one approval round-trip")
        let challenge = try XCTUnwrap(challenges.first)
        XCTAssertEqual(challenge.host, SSHTestFixture.hop1Host)
        XCTAssertEqual(challenge.port, SSHTestFixture.hop1Port)
        XCTAssertEqual(challenge.fingerprint, SSHTestFixture.normalHostKeyFingerprint)
        XCTAssertFalse(challenge.publicKeyData.isEmpty)

        // Trust persisted by the connector: a second connect needs no approval.
        let second = try await connector.connect(SSHTestFixture.makeConnection())
        await second.close()
        XCTAssertEqual(approvalRecorder.recordedChallenges.count, 1)
    }

    func testDeclinedHostKeyTrustFailsTypedWithoutTrusting() async throws {
        let approvalRecorder = ApprovalRecorder(decision: false)
        let connector = HerdrEndpointConnector(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: [Self.statusShimPath],
            approveHostKey: approvalRecorder.approve
        )

        do {
            _ = try await connector.connect(SSHTestFixture.makeConnection())
            XCTFail("declined trust must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .trustDeclined(challenge) = error else {
                return XCTFail("expected trustDeclined, got \(error)")
            }
            XCTAssertEqual(challenge.fingerprint, SSHTestFixture.normalHostKeyFingerprint)
        }
        XCTAssertEqual(approvalRecorder.recordedChallenges.count, 1)
    }

    // MARK: - Pre-probe typed failures

    func testUnreachableHostSurfacesTypedSSHEstablishError() async throws {
        let connector = try await makeConnector(searchPaths: [Self.statusShimPath])
        let deadHost = try Connection(
            name: "dead",
            type: .ssh,
            host: "127.0.0.1",
            port: 1,
            username: "u",
            customKeys: ["fixture-ed25519"]
        )

        do {
            _ = try await connector.connect(deadHost)
            XCTFail("unreachable host must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            XCTAssertEqual(error, .sshEstablish(.unreachable))
        }
    }

    func testInvalidSessionNameFailsBeforeAnyNetworkIO() async throws {
        let logOffset = fixtureLogSize("hop1.log")
        let connector = try await makeConnector(searchPaths: [Self.statusShimPath])
        let hostile = try Connection(
            name: "hostile-session",
            type: .ssh,
            host: SSHTestFixture.hop1Host,
            port: SSHTestFixture.hop1Port,
            username: SSHTestFixture.username,
            customKeys: ["fixture-ed25519"],
            protocolOptions: ProtocolOptions([
                ProtocolOptions.herdrSessionKey: .string("work; rm -rf /")
            ])
        )

        do {
            _ = try await connector.connect(hostile)
            XCTFail("hostile session name must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            XCTAssertEqual(error, .invalidSessionName("work; rm -rf /"))
        }
        XCTAssertFalse(
            fixtureLogAppendage("hop1.log", from: logOffset).contains("command -v herdr"),
            "the session-name grammar gate must run before any network I/O"
        )
    }

    // MARK: - Jump-chain transparency

    /// The whole connect flow over the two-hop fixture chain: the probe and
    /// the bridge exec ride the FINAL hop's connection, hops stay invisible.
    func testJumpChainedConnectionProbesAndBridgesThroughFinalHop() async throws {
        let shim = try Self.materializeProbeAndBridgeShim()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path) }
        let connector = HerdrEndpointConnector(
            hostKeyVerifier: try await JumpFixture.makeVerifier(),
            authenticationKeyProvider: try await JumpFixture.makeRecordingProvider(),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: [shim],
            approveHostKey: { _ in false }
        )
        let herdr = try await connector.connect(try JumpFixture.twoHopConnection())
        bridge = herdr

        try await herdr.write(frame(Data("jump-hello".utf8)))
        try await herdr.write(frame(Data("jump-echo".utf8)))
        try await herdr.closeWrite()

        var received = Data()
        for try await chunk in herdr.inboundBytes() {
            received.append(chunk)
        }
        XCTAssertTrue(received.contains(Data("MOCK-WELCOME-v1".utf8)))
        XCTAssertTrue(received.contains(frame(Data("jump-echo".utf8))))
    }

    /// The bridge session name comes from the connection's herdr option
    /// (todo 1 accessor): the mock's stderr diagnostic proves --session
    /// reached the remote argv.
    func testSessionNameOptionReachesBridgeCommand() async throws {
        let shim = try Self.materializeProbeAndBridgeShim()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path) }
        let keyed = try SSHTestFixture.makeConnection()
        let connection = try Connection(
            id: keyed.id,
            name: keyed.name,
            type: .ssh,
            host: keyed.host,
            port: keyed.port,
            username: keyed.username,
            offersKeys: keyed.offersKeys,
            customKeys: keyed.customKeys,
            passwordTag: keyed.passwordTag,
            protocolOptions: ProtocolOptions([
                ProtocolOptions.herdrSessionKey: .string("team-session")
            ])
        )
        let connector = try await makeConnector(searchPaths: [shim])
        let herdr = try await connector.connect(connection)
        bridge = herdr

        try await herdr.write(frame(Data("named-hello".utf8)))
        try await herdr.closeWrite()
        // Drain stdout to completion first: reads are demand-driven and the
        // stderr diagnostic arrives interleaved on the same channel.
        for try await _ in herdr.inboundBytes() {}
        var stderr = Data()
        for await chunk in herdr.session.stderr {
            stderr.append(chunk)
        }
        XCTAssertTrue(
            String(decoding: stderr, as: UTF8.self).contains("session=team-session"),
            "--session must reach the remote argv: \(String(decoding: stderr, as: UTF8.self))"
        )
    }
}

/// Thread-safe approval-surface recorder wrapping the injected callback.
final class ApprovalRecorder: @unchecked Sendable {
    // @unchecked Sendable: lock-confined challenge list (same idiom as the
    // jump-fake recorders).
    private let decision: Bool
    private let lock = NSLock()
    private var recorded: [HerdrHostTrustChallenge] = []

    init(decision: Bool) {
        self.decision = decision
    }

    var recordedChallenges: [HerdrHostTrustChallenge] {
        lock.withLock { recorded }
    }

    func approve(_ challenge: HerdrHostTrustChallenge) async -> Bool {
        lock.withLock { recorded.append(challenge) }
        return decision
    }
}
