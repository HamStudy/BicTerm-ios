import Foundation
import XCTest
@testable import BicTermCore

/// LIVE two-hop ProxyJump tests against the fixture sshds:
/// hop1 127.0.0.1:12222 (bastion, AllowTcpForwarding) → hop2 127.0.0.1:12223
/// (final). NOTE: XCTest runs methods alphabetically;
/// `testSecondHopFailure...` intentionally sorts FIRST among the tests that
/// touch hop2 auth, and the round-trip waits out the resulting deferred
/// PerSourcePenalty before dialing.
final class ProxyJumpTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []
    private var liveTransports: [any SSHSessionTransport] = []

    override func tearDown() async throws {
        for transport in liveTransports {
            await transport.close()
        }
        liveTransports = []
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private func makeBuilder(trustingHop2: Bool = true) async throws -> (JumpChainBuilder, RecordingKeyProvider) {
        let provider = try await JumpFixture.makeRecordingProvider()
        let verifier = try await JumpFixture.makeVerifier(trustingHop2: trustingHop2)
        return (JumpChainBuilder(hostKeyVerifier: verifier, authenticationKeyProvider: provider), provider)
    }

    func testEmptyChainBuildsDirectSSHTransport() async throws {
        let (builder, _) = try await makeBuilder()
        let transport = try await builder.build(
            connection: SSHTestFixture.makeConnection(),
            cols: 80,
            rows: 24
        )
        liveTransports.append(transport)
        XCTAssertTrue(transport is SSHTransport, "zero-hop chain must use T7's direct transport")
        _ = try await transport.sessionChannelHandle()
    }

    func testSecondHopFailureClosesPriorHopAndNamesFailingHost() async throws {
        let hop1LogOffset = fixtureLogSize("hop1.log")
        let (builder, provider) = try await makeBuilder()
        let connection = try JumpFixture.twoHopConnection(
            destinationKeyReference: JumpFixture.hop2UnauthorizedKeyReference
        )

        do {
            _ = try await builder.build(connection: connection, cols: 80, rows: 24)
            XCTFail("hop2 must reject the unauthorized key")
        } catch let error as JumpError {
            XCTAssertEqual(
                error,
                .hopFailed(
                    hopIndex: 2,
                    host: JumpFixture.host,
                    port: JumpFixture.hop2Port,
                    underlying: .authenticationFailed
                )
            )
        }

        XCTAssertEqual(
            provider.calls.map(\.reference),
            [JumpFixture.goodKeyReference, JumpFixture.hop2UnauthorizedKeyReference],
            "hop1 must authenticate with its own key, hop2 with the unauthorized one"
        )

        let appended = await waitForLogContent(
            "hop1.log",
            from: hop1LogOffset,
            markers: ["Connection closed", "disconnect"]
        )
        XCTAssertNotNil(
            appended,
            "hop1 sshd never observed the client disconnect — the first hop leaked"
        )
    }

    func testTwoHopChainShellRoundTripAndProvenance() async throws {
        // Wait out the deferred PerSourcePenalty hop2 recorded when the
        // (alphabetically earlier) failure test's unauthorized key was
        // rejected — the penalty is 5s, so 7s guarantees expiry before this
        // connection reaches hop2's userauth.
        try await Task.sleep(for: .seconds(7))

        let hop1LogOffset = fixtureLogSize("hop1.log")
        let (builder, _) = try await makeBuilder()
        let transport = try await builder.build(
            connection: JumpFixture.twoHopConnection(),
            cols: 80,
            rows: 24
        )
        liveTransports.append(transport)

        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        try await quiesceSession(transport, sink: sink)

        // Provenance part 1: the final hop sees the connection arriving from
        // hop1's forward (127.0.0.1 ephemeral → 127.0.0.1:12223), i.e. the
        // test process never dialed 12223 directly. The trailing \n avoids
        // zsh's partial-line `%` indicator gluing onto the last field.
        try await transport.send(Data("printf '%s\\n' \"$SSH_CONNECTION\"\n".utf8))
        let gotConnection = await waitForContent(sink: sink, marker: " 12223", timeoutMilliseconds: 8000)
        XCTAssertTrue(gotConnection, "final hop did not report SSH_CONNECTION via the forward")
        let stripped = String(decoding: await sink.snapshot(), as: UTF8.self)
            .replacingOccurrences(of: #"\x1B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\][^\x07]*\x07"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        let connectionLine = stripped.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("\(JumpFixture.host) ") && $0.hasSuffix(" \(JumpFixture.hop2Port)") }
        let fields = connectionLine?.split(separator: " ").map(String.init) ?? []
        XCTAssertEqual(fields.count, 4, "SSH_CONNECTION must have 4 fields, got: \(stripped)")
        XCTAssertEqual(fields[0], JumpFixture.host)
        XCTAssertEqual(fields[2], JumpFixture.host)
        XCTAssertEqual(fields[3], String(JumpFixture.hop2Port))

        // Provenance part 2: hop1's DEBUG3 log recorded the direct-tcpip
        // forward toward hop2's port.
        let hop1Appended = fixtureLogAppendage("hop1.log", from: hop1LogOffset)
        XCTAssertTrue(
            hop1Appended.contains("direct-tcpip") && hop1Appended.contains(String(JumpFixture.hop2Port)),
            "hop1 log must show the direct-tcpip forward toward \(JumpFixture.hop2Port)"
        )

        // Exact-output shell round trip through the full chain.
        await sink.reset()
        try await transport.send(Data("printf bicterm-jump-ok; exit\n".utf8))
        let finished = await waitForFinished(sink: sink)
        XCTAssertTrue(finished, "server did not close the channel after exit")
        let normalized = String(decoding: await sink.snapshot(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(normalized, "bicterm-jump-ok")
    }

    func testUntrustedSecondHopSurfacesRequiresTrustForThatHop() async throws {
        let (builder, _) = try await makeBuilder(trustingHop2: false)

        do {
            _ = try await builder.build(
                connection: JumpFixture.twoHopConnection(),
                cols: 80,
                rows: 24
            )
            XCTFail("untrusted hop2 must not connect")
        } catch let JumpError.hopFailed(hopIndex, host, port, underlying) {
            XCTAssertEqual(hopIndex, 2)
            XCTAssertEqual(host, JumpFixture.host)
            XCTAssertEqual(port, JumpFixture.hop2Port)
            guard case let .requiresTrust(fingerprint, algorithm, publicKeyData) = underlying else {
                XCTFail("expected requiresTrust for hop2, got \(underlying)")
                return
            }
            let hop2Key = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop2_host_ed25519.pub")
            XCTAssertEqual(fingerprint, OpenSSHFingerprint.sha256(publicKeyBlob: hop2Key.blob))
            XCTAssertEqual(algorithm, "ssh-ed25519")
            XCTAssertEqual(publicKeyData, hop2Key.blob)
        }
    }
}
