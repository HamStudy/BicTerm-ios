import Foundation
import XCTest
@testable import BicTermCore

/// T15 exec-channel primitives against the live hop-1 fixture sshd
/// (127.0.0.1:12222, key auth). Every command runs on a NON-PTY exec
/// session channel — the byte-stream semantics these tests pin are exactly
/// what the herdr bridge transport (integration doc §5) builds on:
///
/// - stdout is an opaque binary stream (no PTY → no \r\n munging),
/// - stderr is a separate stream,
/// - the remote exit status is observable,
/// - write half-close (SSH EOF) is distinct from full close,
/// - buffering is bounded and LOSSLESS even under a slow consumer.
/// Collects a pull stream into a buffer, finishing when the stream ends.
/// Free function: an instance method would send non-Sendable XCTestCase
/// `self` across the `async let` boundaries in the isolation tests.
private func collect(_ stream: SSHExecByteStream) async -> Data {
    var data = Data()
    for await chunk in stream {
        data.append(chunk)
    }
    return data
}

final class SSHExecSessionTests: XCTestCase {
    private var transport: SSHTransport?

    override func tearDown() async throws {
        if let transport {
            await transport.close()
        }
        transport = nil
        try await super.tearDown()
    }

    /// Established transport (TCP dial → handshake → auth → shell session)
    /// whose connection then carries dedicated exec channels.
    private func makeConnectedTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let verifier = try await SSHTestFixture.makeVerifier()
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        self.transport = transport
        return transport
    }

    // MARK: - Opaque binary stdout (no PTY, no newline translation)

    func testExecStdoutIsByteExactWithoutPtyTranslation() async throws {
        let transport = try await makeConnectedTransport()
        let session = try await transport.openExecChannel(command: "printf 'a\\tb\\nc'")

        let stdout = await collect(session.stdout)
        XCTAssertEqual(stdout, Data("a\tb\nc".utf8), "no PTY means the kernel must not rewrite \\n to \\r\\n")

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    func testExecCarriesNonUtf8BytesLosslessly() async throws {
        let transport = try await makeConnectedTransport()
        // Byte sweep incl. NUL and >0x7f via octal escapes (verified against
        // the fixture sshd) — proves the stream is never decoded as UTF-8
        // or otherwise normalized.
        let session = try await transport.openExecChannel(
            command: "printf '\\000\\001\\177\\200\\253\\377'"
        )

        let stdout = await collect(session.stdout)
        XCTAssertEqual(stdout, Data([0x00, 0x01, 0x7f, 0x80, 0xab, 0xff]))

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    // MARK: - Exit status

    func testExitStatusPropagatesFromRemoteCommand() async throws {
        let transport = try await makeConnectedTransport()
        let session = try await transport.openExecChannel(command: "exit 7")

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 7))
        _ = await collect(session.stdout)
    }

    // MARK: - stderr isolation

    func testStderrNeverEntersTheStdoutStream() async throws {
        let transport = try await makeConnectedTransport()
        // Deterministic "garbage" on stderr plus payload on stdout. The
        // embedded NUL/0xff bytes would corrupt any UTF-8 decode of a
        // wrongly-multiplexed stream.
        let session = try await transport.openExecChannel(
            command: "printf 'ERR\\000\\377GARBAGE' 1>&2; printf 'OUT-abc'"
        )

        async let stdout = collect(session.stdout)
        async let stderr = collect(session.stderr)
        let (out, err) = await (stdout, stderr)
        XCTAssertEqual(out, Data("OUT-abc".utf8))
        XCTAssertEqual(err, Data("ERR".utf8) + Data([0x00, 0xff]) + Data("GARBAGE".utf8))

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    // MARK: - EOF / half-close

    func testCloseWriteSignalsEofToRemoteAndRemoteExitIsObservable() async throws {
        let transport = try await makeConnectedTransport()
        // `cat` echoes until ITS stdin (our write side) sees EOF.
        let session = try await transport.openExecChannel(command: "cat")

        try await session.write(Data("bicterm-eof-proof".utf8))
        try await session.closeWrite()

        let stdout = await collect(session.stdout)
        XCTAssertEqual(stdout, Data("bicterm-eof-proof".utf8), "cat must echo exactly the pre-EOF writes")

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    func testWriteAfterCloseWriteThrowsTypedChannelDenied() async throws {
        let transport = try await makeConnectedTransport()
        let session = try await transport.openExecChannel(command: "cat")

        try await session.closeWrite()
        await assertThrowsAsyncError(TransportError.channelDenied) {
            try await session.write(Data("x".utf8))
        }
        _ = await collect(session.stdout)

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    func testCloseIsTerminalIdempotentAndFinishesStreams() async throws {
        let transport = try await makeConnectedTransport()
        let session = try await transport.openExecChannel(command: "cat")

        await session.close()
        await session.close()

        let stdout = await collect(session.stdout)
        XCTAssertEqual(stdout.count, 0)

        let termination = await session.termination()
        XCTAssertEqual(termination, .closedLocally)
    }

    /// The remote finishing (command exit) sends channel EOF, exit-status,
    /// then close, in that order — the clean-shutdown shape the doc
    /// requires be distinguishable from network failure.
    func testRemoteCompletionDeliversOutputThenCleanExit() async throws {
        let transport = try await makeConnectedTransport()
        let session = try await transport.openExecChannel(command: "printf 'eof-marker'")

        let stdout = await collect(session.stdout)
        XCTAssertEqual(stdout, Data("eof-marker".utf8))

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    // MARK: - Bounded, lossless buffering under a slow consumer

    func testLargeTransferIsLosslessWithSlowConsumer() async throws {
        let transport = try await makeConnectedTransport()
        let session = try await transport.openExecChannel(command: "cat")

        // 2 MiB of deterministic pseudo-random bytes in 64 KiB writes.
        var entropy = Data()
        var seed: UInt64 = 0x9E3779B97F4A7C15
        while entropy.count < 2 * 1024 * 1024 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var value = seed
            withUnsafeBytes(of: &value) { entropy.append(contentsOf: $0) }
        }
        let payload = entropy.prefix(2 * 1024 * 1024)
        for index in 0..<32 {
            let start = payload.startIndex.advanced(by: index * 65536)
            try await session.write(payload[start..<start.advanced(by: 65536)])
        }
        try await session.closeWrite()

        // Consume SLOWER than the network delivers: the transport must apply
        // backpressure (the SSH window closes on the remote) instead of
        // dropping bytes or buffering without bound.
        var received = Data()
        for await chunk in session.stdout {
            received.append(chunk)
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(Data(received), Data(payload))

        let termination = await session.termination()
        XCTAssertEqual(termination, .exited(status: 0))
    }

    // MARK: - Channel multiplexing (doc §3.5 shared-connection shape)

    func testTwoExecChannelsOverOneConnectionDoNotCrossTalk() async throws {
        let transport = try await makeConnectedTransport()
        let first = try await transport.openExecChannel(command: "printf 'first-payload'")
        let second = try await transport.openExecChannel(command: "printf 'second-payload'")

        async let firstOut = collect(first.stdout)
        async let secondOut = collect(second.stdout)
        let (a, b) = await (firstOut, secondOut)
        XCTAssertEqual(a, Data("first-payload".utf8))
        XCTAssertEqual(b, Data("second-payload".utf8))

        let (firstEnd, secondEnd) = await (first.termination(), second.termination())
        XCTAssertEqual(firstEnd, .exited(status: 0))
        XCTAssertEqual(secondEnd, .exited(status: 0))
    }

    // MARK: - Connection-level refusals stay typed

    func testOpenExecChannelBeforeConnectThrowsTypedChannelDenied() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let offline = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        await assertThrowsAsyncError(TransportError.channelDenied) {
            _ = try await offline.openExecChannel(command: "printf x")
        }
    }
}

// MARK: - Test helpers

func assertThrowsAsyncError(
    _ expected: TransportError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as TransportError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
