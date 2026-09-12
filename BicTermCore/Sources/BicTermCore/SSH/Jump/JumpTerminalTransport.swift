import Foundation

/// ``TerminalTransport`` for a jump-chained connection. The chain (≤5
/// nested SSH-over-direct-tcpip handshakes) is built lazily at `connect`
/// via ``JumpChainBuilder``; I/O then delegates to the established
/// ``SSHSessionTransport`` of the final hop.
///
/// `output` is owned by this adapter (created at init, bridged from the
/// built transport at connect), so it exists before connect and finishes
/// exactly once — on remote drop or `close()`. `close()` tears the whole
/// chain down in reverse hop order via the built transport.
public actor JumpTerminalTransport: TerminalTransport {
    private let builder: JumpChainBuilder
    private var inner: (any SSHSessionTransport)?
    private var bridgeTask: Task<Void, Never>?
    private let outputContinuation: AsyncStream<Data>.Continuation
    public private(set) var output: AsyncStream<Data>
    private var isClosed = false
    public var closeReason: TransportCloseReason {
        get async { await inner?.closeReason ?? .connectionLost }
    }

    public init(builder: JumpChainBuilder) {
        self.builder = builder
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.output = stream
        self.outputContinuation = continuation
    }

    public func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        guard !isClosed, inner == nil else { throw .channelDenied }
        let built: any SSHSessionTransport
        do {
            built = try await builder.build(connection: connection, cols: cols, rows: rows)
        } catch let error as JumpError {
            throw Self.transportError(error)
        } catch {
            throw .unreachable
        }
        guard !isClosed else {
            await built.close()
            throw .channelDenied
        }
        inner = built
        let stream = await built.output
        bridgeTask = Task { [outputContinuation] in
            for await chunk in stream {
                outputContinuation.yield(chunk)
            }
            outputContinuation.finish()
        }
    }

    public func send(_ bytes: Data) async throws(TransportError) {
        guard !isClosed, let inner else { throw .channelDenied }
        try await inner.send(bytes)
    }

    public func resize(cols: Int, rows: Int) async {
        guard !isClosed, let inner else { return }
        await inner.resize(cols: cols, rows: rows)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        bridgeTask?.cancel()
        bridgeTask = nil
        if let inner {
            self.inner = nil
            await inner.close()
        }
        outputContinuation.finish()
    }

    /// `.hopFailed` already carries the typed cause of the failing hop;
    /// chain-shape errors (cycle, too many hops) are connect-time
    /// refusals, which map to `.channelDenied`.
    private static func transportError(_ error: JumpError) -> TransportError {
        switch error {
        case let .hopFailed(_, _, _, underlying):
            underlying
        case .cycleDetected, .tooManyHops:
            .channelDenied
        }
    }
}
