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
    /// Connect-scoped key resolution for THIS transport's connect action,
    /// installed by ``SSHSessionTransportFactory`` (one scope per
    /// constructed transport). Invalidated at every ``connect(to:cols:rows:)``
    /// exit — after ALL hop handshakes and the destination session open
    /// settle, the key handle is no longer needed by NIOSSH auth.
    private let connectKeyScope: ConnectScopedKeyResolution?
    private var inner: (any SSHSessionTransport)?
    private var bridgeTask: Task<Void, Never>?
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let inboundDropSignal = InboundDropSignal()
    public private(set) var output: AsyncStream<Data>
    private var isClosed = false
    public var closeReason: TransportCloseReason {
        get async { await inner?.closeReason ?? .connectionLost }
    }

    public init(builder: JumpChainBuilder, connectKeyScope: ConnectScopedKeyResolution? = nil) {
        self.builder = builder
        self.connectKeyScope = connectKeyScope
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.output = stream
        self.outputContinuation = continuation
    }

    public func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        guard !isClosed, inner == nil else {
            await connectKeyScope?.invalidate()
            throw .channelDenied
        }
        let built: any SSHSessionTransport
        do {
            built = try await builder.build(connection: connection, cols: cols, rows: rows)
        } catch {
            // The connect action settled (failed): every hop handshake is
            // done and the key handle is no longer needed — drop the
            // scope's resolved key so nothing outlives the failed connect.
            await connectKeyScope?.invalidate()
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? JumpError {
                throw Self.transportError(error)
            } else {
                throw .unreachable
            }
        }
        guard !isClosed else {
            await built.close()
            await connectKeyScope?.invalidate()
            throw .channelDenied
        }
        inner = built
        if let observable = built as? any InboundDropObserving {
            let dropSignal = inboundDropSignal
            await observable.setInboundDropObserver { dropSignal.fire() }
        }
        let stream = await built.output
        bridgeTask = Task { [outputContinuation, inboundDropSignal] in
            for await chunk in stream {
                if case .dropped = outputContinuation.yield(chunk) {
                    inboundDropSignal.fire()
                }
            }
            outputContinuation.finish()
        }
        // Settled (success): all hop handshakes AND the destination
        // session open completed — same drop, so a reconnect (a fresh
        // makeTransport = a fresh scope) re-evaluates.
        await connectKeyScope?.invalidate()
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

extension JumpTerminalTransport: InboundDropObserving {
    public func setInboundDropObserver(_ observer: (@Sendable () -> Void)?) async {
        inboundDropSignal.setObserver(observer)
        if let inner, let observable = inner as? any InboundDropObserving {
            let dropSignal = inboundDropSignal
            await observable.setInboundDropObserver { dropSignal.fire() }
        }
    }
}
