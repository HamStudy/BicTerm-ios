import Foundation

/// Fatal bridging failures surfaced on ``inboundBytes()``.
public enum HerdrTransportError: Error, Equatable {
    /// The bounded inbound bridge overflowed (slow consumer). Bytes are
    /// never dropped silently — the stream finishes with this error.
    case inboundOverflow
}

/// ``HerdrByteTransport`` over a non-PTY SSH exec session running herdr's
/// `remote-client-bridge` (integration doc §5).
///
/// Transport-agnostic by construction: it wraps ANY ``SSHExecSession`` —
/// one opened on a direct-TCP SSHTransport, on a UDS-dialed transport
/// (Coder bridge shape), or on a future jump-chain/tunnel source. The
/// convenience init builds the fixed wrapper command via
/// ``HerdrCommandBuilder`` and opens the channel on an established
/// ``SSHTransport`` connection.
///
/// stderr stays SEPARATE: the ``HerdrByteTransport`` surface carries only
/// stdout bytes, so diagnostic text can never enter the protocol decoder.
/// The session's stderr stream remains reachable on ``session`` for
/// callers that want it.
///
/// Inbound bridging policy: a producer task pulls the session's
/// demand-driven stdout stream (lossless, SSH-window backpressured) and
/// yields into an `AsyncThrowingStream` bounded at 64 chunks × 32 KiB
/// (≈2 MiB). Overflow finishes the stream with
/// ``HerdrTransportError/inboundOverflow`` — bounded and loud, never a
/// silent drop.
public final class HerdrSSHTransport: HerdrByteTransport, @unchecked Sendable {
    // @unchecked Sendable: lock-confined lazy bridge state; the wrapped
    // session is Sendable.

    /// Inbound bridge bound: 64 chunks × ≤32 KiB ≈ 2 MiB (see class docs).
    static let inboundChunkLimit = 64

    public let session: SSHExecSession

    private let lock = NSLock()
    private var inboundStream: AsyncThrowingStream<Data, Error>?
    private var bridgeTask: Task<Void, Never>?
    private var isClosed = false

    /// Wraps an already-open exec session (any transport source).
    public init(execSession: SSHExecSession) {
        self.session = execSession
    }

    /// Builds herdr's fixed bridge command and opens the exec channel on
    /// an ESTABLISHED SSHTransport connection (doc §3.5 shared-connection
    /// shape; the connection's own shell session, if any, is untouched).
    /// Throws ``HerdrCommandBuilder/BuildError`` for hostile inputs and
    /// ``TransportError`` for connection-level refusals.
    public init(
        transport: SSHTransport,
        executablePath: String,
        sessionName: String? = nil
    ) async throws {
        let command = try HerdrCommandBuilder.bridgeCommand(
            executablePath: executablePath,
            sessionName: sessionName
        )
        self.session = try await transport.openExecChannel(command: command)
    }

    public func write(_ bytes: Data) async throws {
        try await session.write(bytes)
    }

    public func inboundBytes() -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let inboundStream {
            return inboundStream
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(Self.inboundChunkLimit)
        )
        inboundStream = stream
        bridgeTask = Task { [session] in
            for await chunk in session.stdout {
                if case .dropped = continuation.yield(chunk) {
                    continuation.finish(throwing: HerdrTransportError.inboundOverflow)
                    return
                }
            }
            continuation.finish()
        }
        return stream
    }

    public func closeWrite() async throws {
        try await session.closeWrite()
    }

    /// Doc §6.3 taxonomy signal: maps the exec channel's exit status so the
    /// session layer can distinguish clean EOF (exit 0) from an abnormal
    /// remote end (non-zero) and from a status-less channel death.
    public func termination() async -> HerdrTransportTermination {
        switch await session.termination() {
        case .exited(let status): .exited(status)
        case .failed: .failed
        case .closedLocally: .closedLocally
        }
    }

    public func close() async {
        let (shouldClose, task) = claimClose()
        guard shouldClose else { return }
        task?.cancel()
        await session.close()
    }

    /// Sync lock-confined close claiming (NSLock is unavailable from async
    /// contexts; locked state never straddles an await). Idempotent.
    private func claimClose() -> (Bool, Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return (false, nil) }
        isClosed = true
        let task = bridgeTask
        bridgeTask = nil
        return (true, task)
    }
}
