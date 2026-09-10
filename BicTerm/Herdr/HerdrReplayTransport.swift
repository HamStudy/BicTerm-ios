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
/// `appendInbound` stages additional frames mid-session (frozen-window
/// tests feed the presentation-fence tail only after probing input).
final class HerdrReplayTransport: HerdrByteTransport, @unchecked Sendable {
    // @unchecked Sendable: lock-confined ledger + closed flag; the script is
    // immutable and the append channel is a single-yielder AsyncStream.
    private let lock = NSLock()
    private let script: [Data]
    private let stall: Bool
    private let holdOpen: Bool
    private var writes: [Data] = []
    private var closed = false
    private let appends: AsyncStream<Data>
    private let appendContinuation: AsyncStream<Data>.Continuation

    init(script: [Data], stall: Bool = false, holdOpen: Bool = true) {
        self.script = script
        self.stall = stall
        self.holdOpen = holdOpen
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
        let staged = appends
        Task {
            if !shouldStall {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if !shouldHoldOpen {
                    continuation.finish()
                    return
                }
            }
            for await chunk in staged {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return stream
    }

    func closeWrite() async throws {}

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
