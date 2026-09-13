import Foundation

/// ``HerdrByteTransport`` over a non-PTY SSH exec session running herdr's
/// `remote-client-bridge` (integration doc §5).
///
/// Transport-agnostic by construction: it wraps ANY ``SSHExecSession`` —
/// one opened on a direct-TCP SSHTransport, on a UDS-dialed transport,
/// or on a future jump-chain/tunnel source. The
/// convenience init builds the fixed wrapper command via
/// ``HerdrCommandBuilder`` and opens the channel on an established
/// ``SSHTransport`` connection.
///
/// stderr stays SEPARATE: the ``HerdrByteTransport`` surface carries only
/// stdout bytes, so diagnostic text can never enter the protocol decoder.
/// The session's stderr stream remains reachable on ``session`` for
/// callers that want it.
///
/// Inbound bridging policy (T14): demand-driven and LOSSLESS. The stream
/// handed out by ``inboundBytes()`` pulls the session's stdout once per
/// consumer demand, so the bridge itself buffers at most one chunk; a slow
/// consumer suspends the pull chain and the bound lives one layer down —
/// ``ExecChannelCore``'s 256 KiB per-stream high-water mark plus the SSH
/// receive window (~2 MiB), which blocks the remote instead of ever
/// discarding bytes. (The previous `.bufferingNewest(64)` bridge had no
/// backpressure: a consumer that fell 64 chunks behind killed the session
/// with a typed overflow error.)
public final class HerdrSSHTransport: HerdrByteTransport, @unchecked Sendable {
    // @unchecked Sendable: lock-confined lazy bridge state; the wrapped
    // session is Sendable.

    public let session: SSHExecSession

    /// The connection this transport owns (nil when wrapping a bare exec
    /// session): `close()` tears it down with the session, so a
    /// connector-produced transport never leaks its SSH connection.
    private let ownedCarrier: (any SSHExecCapableConnection)?

    private let lock = NSLock()
    private var inboundStream: AsyncThrowingStream<Data, Error>?
    private var isClosed = false

    /// Wraps an already-open exec session (any transport source); the
    /// caller keeps owning the underlying connection.
    public init(execSession: SSHExecSession) {
        self.session = execSession
        self.ownedCarrier = nil
    }

    /// Builds herdr's fixed bridge command and opens the exec channel on
    /// an ESTABLISHED exec-capable SSH connection (direct or jump-chained;
    /// doc §3.5 shared-connection shape — the connection's own shell
    /// session, if any, is untouched). TAKES OWNERSHIP of `transport`:
    /// ``close()`` tears the connection down after the session.
    /// Throws ``HerdrCommandBuilder/BuildError`` for hostile inputs and
    /// ``TransportError`` for connection-level refusals.
    public init(
        transport: any SSHExecCapableConnection,
        executablePath: String,
        sessionName: String? = nil
    ) async throws {
        let command = try HerdrCommandBuilder.bridgeCommand(
            executablePath: executablePath,
            sessionName: sessionName
        )
        self.session = try await transport.openExecChannel(command: command)
        self.ownedCarrier = transport
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
        // Demand-driven handoff: the unfolding closure runs once per
        // consumer pull, so nothing is bridged ahead of demand and the
        // backpressure chain (bridge → ExecChannelCore → SSH window →
        // remote) stays intact. EOF from stdout (remote EOF or close())
        // returns nil here, which finishes the stream cleanly.
        let stdout = session.stdout
        let stream = AsyncThrowingStream<Data, Error> {
            var iterator = stdout.makeAsyncIterator()
            return await iterator.next()
        }
        inboundStream = stream
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
        let (shouldClose, carrier) = claimClose()
        guard shouldClose else { return }
        await session.close()
        if let carrier {
            await carrier.close()
        }
    }

    /// Sync lock-confined close claiming (NSLock is unavailable from async
    /// contexts; locked state never straddles an await). Idempotent.
    private func claimClose() -> (Bool, (any SSHExecCapableConnection)?) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return (false, nil) }
        isClosed = true
        return (true, ownedCarrier)
    }
}
