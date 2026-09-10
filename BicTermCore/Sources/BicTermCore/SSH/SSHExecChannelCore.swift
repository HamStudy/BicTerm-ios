import Foundation
import NIOCore
import NIOSSH

/// How an exec channel ended. `.exited` is only reported when the remote
/// actually delivered `exit-status`; a channel that dies without one
/// (network drop, protocol violation) is `.failed`. `closedLocally` is the
/// owner's own ``SSHExecSession/close()``.
public enum SSHExecTermination: Sendable, Equatable {
    case exited(status: Int)
    case failed
    case closedLocally
}

/// Lock-confined state shared between the exec channel's EventLoop handler
/// and consumer tasks. ALL mutable state lives behind `lock`; no lock is
/// ever held across an await, and the only cross-thread dispatch is
/// `channel.read()` scheduling (repo lock-confined pattern).
///
/// Backpressure/buffering policy (the T15 contract):
/// - The child channel runs with autoRead OFF. NIOSSH queues undelivered
///   data in `pendingReads` and only re-grants the SSH receive window when
///   a `read()` demand actually delivers bytes, so data the consumer has
///   not pulled BLOCKS the remote at the SSH window (~2 MiB).
/// - Locally, each stream buffers at most ``highWaterBytes`` (256 KiB).
///   One read demand is kept outstanding only while some live stream is
///   below its watermark; draining either stream re-arms the demand.
/// - Nothing is ever dropped: the bound is enforced by flow control, not by
///   discarding bytes. A consumer that stops reading BOTH streams stalls
///   the channel — intended, and why the herdr client drains stderr.
final class ExecChannelCore: @unchecked Sendable {
    enum StreamKind: Sendable {
        case stdout
        case stderr
    }

    /// Per-stream high-water mark for the local buffer.
    static let highWaterBytes = 256 * 1024

    private let lock = NSLock()
    /// Set exactly once by the channel initializer (before any event can
    /// fire); read-only afterwards. Guarded by `lock` only for the
    /// set-once handshake.
    private var channel: (any Channel)?
    private var buffers: [StreamKind: [Data]] = [:]
    private var bufferedBytes: [StreamKind: Int] = [:]
    private var waiters: [StreamKind: ExecWaitToken] = [:]
    private var finished: [StreamKind: Bool] = [.stdout: false, .stderr: false]
    private var readDemandOutstanding = false
    private var termination: SSHExecTermination?
    private var terminationWaiters: [CheckedContinuation<SSHExecTermination, Never>] = []
    private(set) var exitStatus: Int?

    init() {}

    /// Called exactly once from the child-channel initializer, before the
    /// channel activates and before any handler event can fire.
    func attach(channel: any Channel) {
        lock.lock()
        defer { lock.unlock() }
        precondition(self.channel == nil, "attach(channel:) called twice")
        self.channel = channel
    }

    /// Arms the initial read demand once the exec request succeeded.
    func beginReading() {
        reevaluateReadDemand()
    }

    // MARK: EventLoop side (invoked by ExecChannelHandler only)

    /// Buffers one chunk (already re-sliced to ≤32 KiB) or hands it straight
    /// to a parked consumer. Delivery under an outstanding read demand
    /// satisfies it — the flag mirrors NIOSSH's `unsatisfiedRead`, which is
    /// only consumed by actual delivery, never by `read()` returning.
    func offer(_ chunk: Data, on stream: StreamKind) {
        lock.lock()
        readDemandOutstanding = false
        // Fast path: resume the parked consumer with this chunk directly.
        if let parked = waiters[stream] {
            if let continuation = parked.takeContinuation() {
                lock.unlock()
                continuation.resume(returning: chunk)
                return
            }
            waiters[stream] = nil
        }
        buffers[stream, default: []].append(chunk)
        bufferedBytes[stream, default: 0] += chunk.count
        lock.unlock()
    }

    /// Marks both streams finished (remote EOF or channel end): parked
    /// consumers resume with `nil`; buffered chunks are still deliverable.
    /// EOF is delivered under an outstanding read demand, satisfying it.
    func finishStreams() {
        let parked: [ExecWaitToken]
        lock.lock()
        readDemandOutstanding = false
        for stream in [StreamKind.stdout, .stderr] {
            finished[stream] = true
        }
        parked = [.stdout, .stderr].compactMap { waiters[$0] }
        waiters[.stdout] = nil
        waiters[.stderr] = nil
        lock.unlock()
        for token in parked {
            token.cancel()
        }
    }

    /// End of a delivery batch (handler `channelReadComplete`): re-arms the
    /// read demand while consumers still want data — required for liveness
    /// when a parked consumer awaits more remote output.
    func readCycleCompleted() {
        reevaluateReadDemand()
    }

    /// Records the remote exit status (first one wins).
    func recordExitStatus(_ status: Int) {
        lock.lock()
        if exitStatus == nil { exitStatus = status }
        lock.unlock()
    }

    /// Resolves termination exactly once; parked waiters resume.
    func setTermination(_ value: SSHExecTermination) {
        let waitersToResume: [CheckedContinuation<SSHExecTermination, Never>]
        lock.lock()
        guard termination == nil else {
            lock.unlock()
            return
        }
        termination = value
        waitersToResume = terminationWaiters
        terminationWaiters = []
        lock.unlock()
        for waiter in waitersToResume {
            waiter.resume(returning: value)
        }
    }

    /// Channel end seen from the pipeline (inactive or error). Classifies by
    /// what the remote told us: an exit status means a clean remote exit.
    func channelEnded() {
        finishStreams()
        lock.lock()
        let status = exitStatus
        let alreadyTerminated = termination != nil
        lock.unlock()
        guard !alreadyTerminated else { return }
        setTermination(status.map { .exited(status: $0) } ?? .failed)
    }

    // MARK: Consumer side

    /// Pulls the next chunk from `stream`, or `nil` once finished+drained.
    /// Single consumer per stream (multiple iterators compete, like
    /// `AsyncStream`).
    func next(_ stream: StreamKind) async -> Data? {
        if let chunk = popBuffered(stream) {
            reevaluateReadDemand()
            return chunk
        }
        if isFinished(stream) { return nil }

        let token = ExecWaitToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                // Non-nil: resume immediately with this value (buffered
                // chunk, finished, or cancelled-before-park). Nil: parked.
                if let immediate = parkOrTake(stream: stream, token: token, continuation: continuation) {
                    continuation.resume(returning: immediate)
                    if immediate != nil { reevaluateReadDemand() }
                } else {
                    // Parked: our demand must still be armed (never hold the
                    // core lock while scheduling onto the EventLoop).
                    reevaluateReadDemand()
                }
            }
        } onCancel: {
            cancelWaiter(stream, token: token)
        }
    }

    /// Resolves when the channel ends (clean exit, failure, or local close).
    func awaitTermination() async -> SSHExecTermination {
        if let resolved = terminationSnapshot() { return resolved }
        return await withCheckedContinuation { continuation in
            if let immediate = registerTerminationWaiter(continuation) {
                continuation.resume(returning: immediate)
            }
        }
    }

    var isRemoteEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished[.stdout] == true && finished[.stderr] == true
    }

    // MARK: Read-demand scheduling

    /// Keeps exactly one `channel.read()` demand outstanding while any LIVE
    /// (unfinished) stream sits below its high-water mark. Must be called
    /// WITHOUT the lock held. Finished streams never re-arm the demand —
    /// otherwise a fully-drained EOF channel would spin on empty reads.
    /// `eventLoop.execute` runs INLINE when already on the loop, so the
    /// block must never re-arm synchronously after `read()` (delivery —
    /// offer/EOF — or the next `channelReadComplete` clears the flag).
    private func reevaluateReadDemand() {
        lock.lock()
        guard !readDemandOutstanding, let channel else {
            lock.unlock()
            return
        }
        let stdoutWants = !(finished[.stdout]!) && (bufferedBytes[.stdout] ?? 0) < Self.highWaterBytes
        let stderrWants = !(finished[.stderr]!) && (bufferedBytes[.stderr] ?? 0) < Self.highWaterBytes
        guard stdoutWants || stderrWants else {
            lock.unlock()
            return
        }
        readDemandOutstanding = true
        lock.unlock()

        channel.eventLoop.execute { [channel] in
            if channel.isActive {
                channel.read()
            }
        }
    }

    private func popBuffered(_ stream: StreamKind) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let chunk = buffers[stream]?.first else { return nil }
        buffers[stream]?.removeFirst()
        bufferedBytes[stream] = (bufferedBytes[stream] ?? 0) - chunk.count
        return chunk
    }

    private func isFinished(_ stream: StreamKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished[stream] == true
    }

    /// Sync critical section for `next()`'s continuation body. Returns
    /// `.some(immediate)` to resume the continuation right away (buffered
    /// chunk, finished stream, or cancellation that beat the park); returns
    /// `nil` when the continuation is parked for later resume.
    private func parkOrTake(
        stream: StreamKind,
        token: ExecWaitToken,
        continuation: CheckedContinuation<Data?, Never>
    ) -> Data?? {
        lock.lock()
        defer { lock.unlock() }
        if let buffered = buffers[stream]?.first {
            buffers[stream]?.removeFirst()
            bufferedBytes[stream] = (bufferedBytes[stream] ?? 0) - buffered.count
            return .some(buffered)
        }
        if finished[stream] == true || !token.park(continuation) {
            return .some(nil)
        }
        waiters[stream] = token
        return nil
    }

    private func terminationSnapshot() -> SSHExecTermination? {
        lock.lock()
        defer { lock.unlock() }
        return termination
    }

    /// Sync critical section for `awaitTermination()`'s continuation body:
    /// registers the waiter unless termination already resolved.
    private func registerTerminationWaiter(
        _ continuation: CheckedContinuation<SSHExecTermination, Never>
    ) -> SSHExecTermination? {
        lock.lock()
        defer { lock.unlock() }
        if let termination {
            return termination
        }
        terminationWaiters.append(continuation)
        return nil
    }

    private func cancelWaiter(_ stream: StreamKind, token: ExecWaitToken) {
        lock.lock()
        if waiters[stream] === token {
            waiters[stream] = nil
        }
        lock.unlock()
        token.cancel()
    }
}

/// One parked `next()` call. `park`/`takeContinuation`/`cancel` are
/// serialized by `ExecChannelCore.lock` (outer) + the token's own lock —
/// each continuation resumes exactly once.
final class ExecWaitToken: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var cancelled = false

    /// Installs the continuation unless the call was already cancelled.
    /// Returns false when cancelled (caller resumes immediately with nil).
    func park(_ continuation: CheckedContinuation<Data?, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.continuation = continuation
        return true
    }

    /// Takes the parked continuation to resume it with a value, exactly once.
    func takeContinuation() -> (CheckedContinuation<Data?, Never>)? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }

    /// Resumes a still-parked continuation with nil (stream finished or the
    /// awaiting task was cancelled).
    func cancel() {
        takeContinuation()?.resume(returning: nil)
    }
}
