import BicTermCore
import Foundation

enum HerdrReplayTransportError: Error, Equatable {
    case writeAfterClose
}

/// Deterministic ``HerdrByteTransport`` for tests and the DEBUG fixture
/// replay: emits a scripted sequence of server frames chunk-by-chunk,
/// records client writes, and can stall forever (handshake-timeout tests).
///
/// Chunks preserve their scripted boundaries, so partial-frame chunking is
/// exercisable exactly like real SSH segmentation. `holdOpen` keeps the
/// inbound stream alive after the script (a live server does not EOF right
/// after its snapshot); pass `false` to replay a clean remote close.
/// `exitStatus` shapes ``termination()`` so the doc §6.3 taxonomy can
/// distinguish a clean EOF (0) from a server shutdown (non-zero).
/// `failWith` finishes inbound with an error instead (network loss).
/// `appendInbound` stages additional frames mid-session (frozen-window
/// tests feed the presentation-fence tail only after probing input).
final class HerdrReplayTransport: HerdrByteTransport, @unchecked Sendable {
    // @unchecked Sendable: lock-confined ledger + closed flag; the script is
    // immutable and the append channel is a single-yielder AsyncStream.
    private let lock = NSLock()
    private let script: [Data]
    private let stall: Bool
    private let holdOpen: Bool
    private let exitStatus: Int
    private let failWith: (any Error)?
    private var writes: [Data] = []
    private var closed = false
    private let appends: AsyncStream<Data>
    private let appendContinuation: AsyncStream<Data>.Continuation

    init(
        script: [Data],
        stall: Bool = false,
        holdOpen: Bool = true,
        exitStatus: Int = 0,
        failWith: (any Error)? = nil
    ) {
        self.script = script
        self.stall = stall
        self.holdOpen = holdOpen
        self.exitStatus = exitStatus
        self.failWith = failWith
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        appends = stream
        appendContinuation = continuation
    }

    var scriptChunkCount: Int {
        script.count
    }

    var writeLedger: [Data] {
        recordedWrites()
    }

    var isClosed: Bool {
        closedFlag()
    }

    func appendInbound(_ chunk: Data) {
        appendContinuation.yield(chunk)
    }

    func write(_ bytes: Data) async throws {
        let accepted = recordWrite(bytes)
        guard accepted else { throw HerdrReplayTransportError.writeAfterClose }
    }

    func inboundBytes() -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let chunks = script
        let shouldStall = stall
        let shouldHoldOpen = holdOpen
        let finishError = failWith
        let staged = appends
        Task {
            if !shouldStall {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if !shouldHoldOpen, let finishError {
                    continuation.finish(throwing: finishError)
                    return
                }
                if !shouldHoldOpen {
                    continuation.finish()
                    return
                }
            }
            for await chunk in staged {
                continuation.yield(chunk)
            }
            if let finishError {
                continuation.finish(throwing: finishError)
            } else {
                continuation.finish()
            }
        }
        return stream
    }

    func closeWrite() async throws {}

    func termination() async -> HerdrTransportTermination {
        failWith != nil ? .failed : .exited(exitStatus)
    }

    func close() async {
        markClosed()
    }

    // Lock-confined sync accessors: NSLock is unavailable from async
    // contexts, so no locked state ever straddles an await.

    private func recordedWrites() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    private func closedFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func recordWrite(_ bytes: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        writes.append(bytes)
        return true
    }

    private func markClosed() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }
}
