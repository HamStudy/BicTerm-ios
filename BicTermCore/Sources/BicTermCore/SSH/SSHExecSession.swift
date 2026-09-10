import Foundation
import NIOCore

/// A live non-PTY exec session channel (RFC 4254 §6.5) — the byte-stream
/// seam the herdr bridge rides on (integration doc §5).
///
/// Channel posture, enforced at open (``SSHTransport/openExecChannel(command:)``):
/// NO pty-req, NO shell request, NO agent-forward request. stdout and
/// stderr are distinct opaque binary streams — never decoded, never
/// newline-normalized. Write half-close sends SSH EOF; the remote exit
/// status is observable via ``termination()``.
///
/// Buffering/backpressure: see ``ExecChannelCore`` (demand-driven reads;
/// bounded local buffers + the SSH receive window; lossless by
/// construction).
public final class SSHExecSession: @unchecked Sendable {
    // @unchecked Sendable: immutable references; all mutable state is
    // EventLoop-confined (handler) or lock-confined (core).
    let channel: any Channel
    let handler: ExecChannelHandler
    let core: ExecChannelCore
    private let stateLock = NSLock()
    private var writeClosed = false
    private var closed = false

    init(channel: any Channel, handler: ExecChannelHandler, core: ExecChannelCore) {
        self.channel = channel
        self.handler = handler
        self.core = core
    }

    /// Opaque remote stdout. Single consumer; pull-based so backpressure
    /// reaches the SSH window.
    public var stdout: SSHExecByteStream {
        SSHExecByteStream(core: core, kind: .stdout)
    }

    /// Opaque remote stderr. Never mixed into ``stdout``; drain it (or the
    /// channel eventually stalls — see the buffering policy).
    public var stderr: SSHExecByteStream {
        SSHExecByteStream(core: core, kind: .stderr)
    }

    /// Resolves when the channel ends: `.exited` carries the remote
    /// exit-status, `.failed` means no status arrived (network/protocol
    /// death), `.closedLocally` follows the owner's own `close()`.
    public func termination() async -> SSHExecTermination {
        await core.awaitTermination()
    }

    /// Writes to the channel's stdin. Suspends while the SSH flow-control
    /// window is exhausted instead of queueing unbounded writes. Throws
    /// `.channelDenied` after `closeWrite()`/`close()` or channel death.
    public func write(_ bytes: Data) async throws(TransportError) {
        guard mayWrite(), channel.isActive else { throw .channelDenied }

        while !(await handler.isWritable()) {
            guard channel.isActive else { throw .channelDenied }
            await handler.waitUntilWritable()
        }
        do {
            try await channel.writeAndFlush(bytes).get()
        } catch {
            throw .unreachable
        }
    }

    /// Write half-close: sends SSH EOF to the remote. The channel stays
    /// open for the reply stream and exit status. A second call (or a call
    /// after `close()`) throws the typed error.
    public func closeWrite() async throws(TransportError) {
        guard markWriteClosed() else { throw .channelDenied }
        do {
            try await channel.close(mode: .output).get()
        } catch {
            throw .channelDenied
        }
    }

    /// Full close. Terminal and idempotent; finishes both streams and
    /// resolves ``termination()`` to `.closedLocally`.
    public func close() async {
        guard markClosed() else { return }
        core.setTermination(.closedLocally)
        try? await channel.close().get()
        core.finishStreams()
    }

    // Sync lock-confined state helpers (NSLock is unavailable from async
    // contexts; locked state never straddles an await).
    private func mayWrite() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !writeClosed && !closed
    }

    private func markWriteClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !writeClosed, !closed else { return false }
        writeClosed = true
        return true
    }

    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }
}

/// Pull-based byte stream over one exec channel stream (stdout or stderr).
/// `next()` returns `nil` after the stream ends and buffers drain; chunk
/// boundaries carry no protocol meaning — concatenate for the byte stream.
public struct SSHExecByteStream: AsyncSequence, Sendable {
    public typealias Element = Data

    let core: ExecChannelCore
    let kind: ExecChannelCore.StreamKind

    public struct AsyncIterator: AsyncIteratorProtocol {
        let core: ExecChannelCore
        let kind: ExecChannelCore.StreamKind

        public mutating func next() async -> Data? {
            await core.next(kind)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(core: core, kind: kind)
    }
}
