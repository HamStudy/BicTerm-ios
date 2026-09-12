import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

// MARK: - Fakes

final class JumpFakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func log(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }
}

final class FakeJumpDialer: JumpDialer, @unchecked Sendable {
    let recorder: JumpFakeRecorder
    let keyProvider: RecordingKeyProvider
    /// "host:port" of the hop whose connectNested/connectTCP should fail.
    var failingHopKey: String?
    var failureError: SSHTransportError = .authenticationFailed
    /// When set, openForward on the hop whose name matches throws this error.
    var forwardFailure: (fromKey: String, error: SSHTransportError)?

    init(recorder: JumpFakeRecorder, keyProvider: RecordingKeyProvider) {
        self.recorder = recorder
        self.keyProvider = keyProvider
    }

    /// Fakes resolve through the (recording) provider so tests prove each
    /// hop authenticates with its OWN keyReference.
    private func resolve(_ endpoint: JumpHopEndpoint) async throws(SSHTransportError) {
        do {
            _ = try await keyProvider.authenticationPrivateKey(with: endpoint.keyReference, reason: "fake")
        } catch {
            throw .authenticationFailed
        }
    }

    func connectTCP(to endpoint: JumpHopEndpoint) async throws(SSHTransportError) -> any JumpHopConnection {
        let key = "\(endpoint.host):\(endpoint.port)"
        recorder.log("connectTCP(\(key))")
        try await resolve(endpoint)
        if failingHopKey == key { throw failureError }
        return FakeHopConnection(name: key, recorder: recorder, dialer: self)
    }

    func connectNested(over link: any JumpRawLink, to endpoint: JumpHopEndpoint) async throws(SSHTransportError) -> any JumpHopConnection {
        let key = "\(endpoint.host):\(endpoint.port)"
        recorder.log("nested(\(key))")
        try await resolve(endpoint)
        if failingHopKey == key { throw failureError }
        return FakeHopConnection(name: key, recorder: recorder, dialer: self)
    }
}

final class FakeHopConnection: JumpHopConnection, @unchecked Sendable {
    let name: String
    let recorder: JumpFakeRecorder
    let dialer: FakeJumpDialer

    init(name: String, recorder: JumpFakeRecorder, dialer: FakeJumpDialer) {
        self.name = name
        self.recorder = recorder
        self.dialer = dialer
    }

    func openForward(toHost host: String, port: Int) async throws(SSHTransportError) -> any JumpRawLink {
        recorder.log("forward(\(host):\(port))")
        if let failure = dialer.forwardFailure, failure.fromKey == name {
            throw failure.error
        }
        return FakeRawLink(name: "\(host):\(port)", recorder: recorder)
    }

    func openSession(cols: Int, rows: Int) async throws(SSHTransportError) -> any JumpSession {
        recorder.log("session(\(cols)x\(rows))")
        return FakeJumpSession(name: name, recorder: recorder)
    }

    func openExec(command: String) async throws(SSHTransportError) -> SSHExecSession {
        recorder.log("exec(\(name))")
        throw .channelDenied
    }

    func close() async {
        recorder.log("close(\(name))")
    }
}

final class FakeRawLink: JumpRawLink, @unchecked Sendable {
    let name: String
    let recorder: JumpFakeRecorder

    init(name: String, recorder: JumpFakeRecorder) {
        self.name = name
        self.recorder = recorder
    }

    func close() async {
        recorder.log("linkClose(\(name))")
    }
}

final class FakeJumpSession: JumpSession, @unchecked Sendable {
    let name: String
    let recorder: JumpFakeRecorder
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init(name: String, recorder: JumpFakeRecorder) {
        self.name = name
        self.recorder = recorder
        (self.output, self.continuation) = AsyncStream.makeStream(of: Data.self)
    }

    func send(_ bytes: Data) async throws(SSHTransportError) {}
    func resize(cols: Int, rows: Int) async {}

    func sessionChannelHandle() throws(SSHTransportError) -> SSHChannelHandle {
        throw .channelDenied
    }

    func close() async {
        recorder.log("sessionClose(\(name))")
        continuation.finish()
    }
}

// MARK: - Tests

/// Composition, validation, attribution and cleanup proofs for
/// `JumpChainBuilder`, driven by an injected fake dialer — no sockets.
/// (The fixture ships only two sshds, so a LIVE 3+ hop chain is impossible
/// without tripping (host,port) cycle detection; composition beyond two
/// hops is proven here instead. Live two-hop coverage: ProxyJumpTests.)
final class ProxyJumpCompositionTests: XCTestCase {
    private let host = "127.0.0.1"

    private func makeEndpoint(_ port: Int, ref: String? = nil) -> JumpHopEndpoint {
        JumpHopEndpoint(host: host, port: port, username: "u", keyReference: ref ?? "key-\(port)")
    }

    private func makeConnection(ports: [Int], destinationPort: Int) throws -> Connection {
        try Connection(
            name: "fake-chain",
            type: .ssh,
            host: host,
            port: destinationPort,
            username: "u",
            keyReference: "key-\(destinationPort)",
            jumpChain: ports.map { Hop(host: host, port: $0, username: "u", keyReference: "key-\($0)") }
        )
    }

    private func makeSUT() async throws -> (JumpChainBuilder, FakeJumpDialer, RecordingKeyProvider, JumpFakeRecorder) {
        let recorder = JumpFakeRecorder()
        let provider = RecordingKeyProvider(keys: [:])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let builder = JumpChainBuilder(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: provider,
            dialer: dialer
        )
        return (builder, dialer, provider, recorder)
    }

    private func makeKeyedProvider(ports: [Int]) async throws -> RecordingKeyProvider {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        var map: [String: NIOSSHPrivateKey] = [:]
        for port in ports {
            map["key-\(port)"] = key
        }
        return RecordingKeyProvider(keys: map)
    }

    func testThreeHopChainComposesSequentiallyWithPerHopCredentials() async throws {
        let recorder = JumpFakeRecorder()
        let provider = try await makeKeyedProvider(ports: [2001, 2002, 2003])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        let builder = JumpChainBuilder(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: provider,
            dialer: dialer
        )

        let transport = try await builder.build(
            connection: makeConnection(ports: [2001, 2002], destinationPort: 2003),
            cols: 100,
            rows: 30
        )
        XCTAssertTrue(transport is JumpTransport)
        XCTAssertEqual(recorder.events, [
            "connectTCP(127.0.0.1:2001)",
            "forward(127.0.0.1:2002)",
            "nested(127.0.0.1:2002)",
            "forward(127.0.0.1:2003)",
            "nested(127.0.0.1:2003)",
            "session(100x30)",
        ])
        XCTAssertEqual(
            provider.calls.map(\.reference),
            ["key-2001", "key-2002", "key-2003"],
            "each hop must be authenticated with ITS OWN keyReference"
        )

        await transport.close()
        XCTAssertEqual(Array(recorder.events.suffix(4)), [
            "sessionClose(127.0.0.1:2003)",
            "close(127.0.0.1:2003)",
            "close(127.0.0.1:2002)",
            "close(127.0.0.1:2001)",
        ], "close must tear down the session then hops in reverse order")
    }

    func testFiveHopChainComposesAtBound() async throws {
        let recorder = JumpFakeRecorder()
        let provider = try await makeKeyedProvider(ports: [2001, 2002, 2003, 2004, 2005])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        let builder = JumpChainBuilder(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: provider,
            dialer: dialer
        )

        let transport = try await builder.build(
            connection: makeConnection(ports: [2001, 2002, 2003, 2004], destinationPort: 2005),
            cols: 80,
            rows: 24
        )
        XCTAssertTrue(transport is JumpTransport)
        XCTAssertEqual(recorder.events.count, 10, "5 hops = 5 connects, 4 forwards, 1 session")
        await transport.close()
    }

    func testHopFailureAtThirdHopNamesIndexAndClosesReverseOrder() async throws {
        let recorder = JumpFakeRecorder()
        let provider = try await makeKeyedProvider(ports: [2001, 2002, 2003])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        dialer.failingHopKey = "127.0.0.1:2003"
        dialer.failureError = .authenticationFailed
        let builder = JumpChainBuilder(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: provider,
            dialer: dialer
        )

        do {
            _ = try await builder.build(
                connection: makeConnection(ports: [2001, 2002], destinationPort: 2003),
                cols: 80,
                rows: 24
            )
            XCTFail("chain must fail")
        } catch let error as JumpError {
            XCTAssertEqual(
                error,
                .hopFailed(hopIndex: 3, host: host, port: 2003, underlying: .authenticationFailed)
            )
        }
        XCTAssertEqual(Array(recorder.events.suffix(3)), [
            "linkClose(127.0.0.1:2003)",
            "close(127.0.0.1:2002)",
            "close(127.0.0.1:2001)",
        ], "failed link closes, then established hops in reverse order")
    }

    func testHopFailureAtFirstHopNamesIndexOne() async throws {
        let recorder = JumpFakeRecorder()
        let provider = try await makeKeyedProvider(ports: [2001, 2002])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        dialer.failingHopKey = "127.0.0.1:2001"
        dialer.failureError = .unreachable
        let builder = JumpChainBuilder(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: provider,
            dialer: dialer
        )

        await assertThrowsJumpError(
            .hopFailed(hopIndex: 1, host: host, port: 2001, underlying: .unreachable)
        ) {
            _ = try await builder.build(
                connection: makeConnection(ports: [2001], destinationPort: 2002),
                cols: 80,
                rows: 24
            )
        }
        XCTAssertEqual(recorder.events, ["connectTCP(127.0.0.1:2001)"], "nothing to close")
    }

    func testForwardHandshakeClassErrorAttributesToOwnerHop() async throws {
        let recorder = JumpFakeRecorder()
        let provider = try await makeKeyedProvider(ports: [2001, 2002, 2003])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        // Hop 2's handshake dies; the failure surfaces when hop 2 is asked
        // to open the forward toward hop 3.
        dialer.forwardFailure = (fromKey: "127.0.0.1:2002", error: .authenticationFailed)
        let builder = JumpChainBuilder(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: provider,
            dialer: dialer
        )

        await assertThrowsJumpError(
            .hopFailed(hopIndex: 2, host: host, port: 2002, underlying: .authenticationFailed)
        ) {
            _ = try await builder.build(
                connection: makeConnection(ports: [2001, 2002], destinationPort: 2003),
                cols: 80,
                rows: 24
            )
        }
        XCTAssertEqual(Array(recorder.events.suffix(2)), [
            "close(127.0.0.1:2002)",
            "close(127.0.0.1:2001)",
        ])
    }

    func testForwardRefusalAttributesToTargetHop() async throws {
        let recorder = JumpFakeRecorder()
        let provider = try await makeKeyedProvider(ports: [2001, 2002, 2003])
        let dialer = FakeJumpDialer(recorder: recorder, keyProvider: provider)
        // Hop 2's sshd refuses the direct-tcpip toward hop 3.
        dialer.forwardFailure = (fromKey: "127.0.0.1:2002", error: .channelDenied)
        let builder = JumpChainBuilder(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()),
            authenticationKeyProvider: provider,
            dialer: dialer
        )

        await assertThrowsJumpError(
            .hopFailed(hopIndex: 3, host: host, port: 2003, underlying: .channelDenied)
        ) {
            _ = try await builder.build(
                connection: makeConnection(ports: [2001, 2002], destinationPort: 2003),
                cols: 80,
                rows: 24
            )
        }
    }

    func testCycleAcrossJumpChainAndDestinationRejectedBeforeDialing() async throws {
        let (builder, dialer, provider, _) = try await makeSUT()
        let connection = try Connection(
            name: "cyclic",
            type: .ssh,
            host: host,
            port: 2001,
            username: "u",
            keyReference: "key-2001",
            jumpChain: [
                Hop(host: host, port: 2001, username: "u", keyReference: "key-2001"),
                Hop(host: host, port: 2002, username: "u", keyReference: "key-2002"),
            ]
        )

        await assertThrowsJumpError(.cycleDetected(host: host, port: 2001)) {
            _ = try await builder.build(connection: connection, cols: 80, rows: 24)
        }
        XCTAssertTrue(dialer.recorder.events.isEmpty, "validation must run before any network I/O")
        XCTAssertTrue(provider.calls.isEmpty, "validation must run before any key resolution")
    }

    func testCycleWithinJumpChainRejected() async throws {
        let (builder, _, _, _) = try await makeSUT()
        let connection = try Connection(
            name: "cyclic-jumps",
            type: .ssh,
            host: host,
            port: 2003,
            username: "u",
            keyReference: "key-2003",
            jumpChain: [
                Hop(host: host, port: 2001, username: "u", keyReference: "key-2001a"),
                Hop(host: host, port: 2002, username: "u", keyReference: "key-2002"),
                Hop(host: host, port: 2001, username: "u", keyReference: "key-2001b"),
            ]
        )
        await assertThrowsJumpError(.cycleDetected(host: host, port: 2001)) {
            _ = try await builder.build(connection: connection, cols: 80, rows: 24)
        }
    }

    func testSameHostDifferentPortsIsNotACycle() throws {
        try JumpChainBuilder.validate(
            jumps: [makeEndpoint(12222), makeEndpoint(12223)],
            destination: makeEndpoint(12224)
        )
    }

    func testSixJumpsRejectedAtBuilderLevel() throws {
        let jumps = (1...6).map { makeEndpoint(2000 + $0) }
        XCTAssertThrowsError(
            try JumpChainBuilder.validate(jumps: jumps, destination: makeEndpoint(3000))
        ) { error in
            XCTAssertEqual(error as? JumpError, .tooManyHops(maximum: 5, actual: 6))
        }
    }

    func testFiveJumpsAcceptedAtBuilderLevel() throws {
        let jumps = (1...5).map { makeEndpoint(2000 + $0) }
        try JumpChainBuilder.validate(jumps: jumps, destination: makeEndpoint(3000))
    }
}

private func assertThrowsJumpError(
    _ expected: JumpError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as JumpError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
