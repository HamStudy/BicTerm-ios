import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Key- or password-authenticated SSH terminal transport over SwiftNIO SSH.
///
/// Lifecycle: one establish per connection — TCP connect, host-key TOFU
/// verification (via T4's `HostKeyVerifier`), key-pool/password auth.
/// `connect(to:cols:rows:)` continues into the interactive session:
/// session channel open, `pty-req` (xterm-256color) and `shell`
/// (both with reply tracking). `connectExecOnly(to:)` stops after
/// authentication — no channel — for consumers that open their own
/// channels on fresh connections (herdr's connection-per-consumer shape).
/// `output` is a FRESH stream per connection; the previous one is
/// finished on reconnect or `close`.
///
/// Unix-domain-socket dialing (fixture conformance) lives in
/// SSHTransport+UDS.swift and shares the session-establish tail through
/// `openSessionAndActivate`.
///
/// Output buffering policy: the stream holds at most 32 chunks of at most
/// 32 KiB (≈1 MiB). On overflow the OLDEST queued chunks are dropped
/// (`.bufferingNewest`) — a slow consumer loses scrollback, never blocks
/// the network read path. A drop is NEVER silent for the terminal path:
/// the installed ``InboundDropObserving`` observer fires so the session
/// layer can flag the VT stream as suspect (T12).
///
/// Inbound security posture: every server-initiated channel open is
/// rejected and no `GlobalRequestDelegate` is installed — see
/// `SSHClientPipelineFactory`.
public actor SSHTransport {
    public private(set) var output: AsyncStream<Data>
    private var termination = SessionTermination()
    public var closeReason: TransportCloseReason { termination.reason }

    // Internal (not private) so the UDS entry points in SSHTransport+UDS.swift
    // can reach them — Swift `private` is file-scoped.
    let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    private let passwordStore: any PasswordStoring
    private let passwordPrompt: (any SSHPasswordPrompting)?
    private let hardwareKeysEnabledByDefault: @Sendable () -> Bool
    private let keyOfferResolver: KeyOfferResolver
    private let metadataProvider: any SSHKeyMetadataProviding
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var group: MultiThreadedEventLoopGroup?
    var connectionChannel: (any Channel)?
    private var errorRecorder: TransportErrorRecorder?
    private var sessionChannel: (any Channel)?
    private var sessionHandler: SessionChannelHandler?

    /// T8 (agent forwarding): optional acceptor for inbound
    /// `auth-agent@openssh.com` channels. Installed by
    /// `AgentForwardingBridge.install(on:)` BEFORE connect; captured by value
    /// into the inbound child channel initializer when the NIOSSHHandler is
    /// built. Every other server-initiated channel type stays rejected.
    private var agentChannelInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)?

    /// T12 (sync integrity): fires when the bounded output bridge drops a
    /// chunk. Boxed because the yield runs on the channel's EventLoop while
    /// the observer is swapped from actor context.
    private let inboundDropSignal = InboundDropSignal()

    /// Internal additive hook (T8) — not part of the public API surface.
    internal func installAgentChannelInitializer(
        _ initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) {
        agentChannelInitializer = initializer
    }

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider(),
        passwordStore: any PasswordStoring = KeychainPasswordStore(),
        passwordPrompt: (any SSHPasswordPrompting)? = nil,
        hardwareKeysEnabledByDefault: @escaping @Sendable () -> Bool = { true },
        keyOfferResolver: KeyOfferResolver = KeyOfferResolver(),
        metadataProvider: any SSHKeyMetadataProviding = DefaultSSHKeyMetadataProvider()
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.passwordStore = passwordStore
        self.passwordPrompt = passwordPrompt
        self.hardwareKeysEnabledByDefault = hardwareKeysEnabledByDefault
        self.keyOfferResolver = keyOfferResolver
        self.metadataProvider = metadataProvider
        let (stream, _) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(32))
        self.output = stream
    }

    public func connect(to connection: Connection, cols: Int, rows: Int) async throws(SSHTransportError) {
        guard cols > 0, rows > 0 else { throw .channelDenied }
        await tearDown()
        let userAuth = try await userAuthDelegate(for: connection)
        let serverAuth = VerifyingHostKeyDelegate(
            host: connection.host,
            port: connection.port,
            verifier: hostKeyVerifier
        )
        try await openSessionAndActivate(
            SessionSetup(cols: cols, rows: rows, userAuth: userAuth, serverAuth: serverAuth)
        ) { bootstrap in
            try await bootstrap
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .connect(host: connection.host, port: connection.port)
                .get()
        }
    }

    /// Channel-less establish: TCP dial + SSH handshake + authentication,
    /// stopping BEFORE any session channel is opened. Resolves the same
    /// auth delegates and host-key verification as ``connect(to:cols:rows:)``
    /// and surfaces the same typed errors — including `.requiresTrust`
    /// (TOFU), which arises during the handshake, before any channel.
    ///
    /// For endpoints that permit a bounded number of `session`-type
    /// channel opens per connection LIFETIME (CoderSSHGW permits exactly
    /// one): exec channels are `session`-type channels on the wire
    /// (RFC 4254), so a terminal establish would burn the slot. Consumers
    /// (herdr probe, bridge, installer steps) establish here and each
    /// rides its own fresh connection; the first `openExecChannel` is
    /// the connection's first session-channel open.
    public func connectExecOnly(to connection: Connection) async throws(SSHTransportError) {
        await tearDown()
        let userAuth = try await userAuthDelegate(for: connection)
        let serverAuth = VerifyingHostKeyDelegate(
            host: connection.host,
            port: connection.port,
            verifier: hostKeyVerifier
        )
        try await openAuthenticatedConnection(
            userAuth: userAuth,
            serverAuth: serverAuth
        ) { bootstrap in
            try await bootstrap
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .connect(host: connection.host, port: connection.port)
                .get()
        }
    }

    /// Resolve the current availability pool for each attempt, including UDS.
    func userAuthDelegate(
        for connection: Connection
    ) async throws(SSHTransportError) -> any NIOSSHClientUserAuthenticationDelegate {
        let keys = (try? await metadataProvider.availableKeys()) ?? []
        let references = keyOfferResolver.resolve(
            KeyOfferRequest(offersKeys: connection.offersKeys, customKeys: connection.customKeys,
                            hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault()),
            keys: keys
        )
        return CascadeUserAuthenticationDelegate(
            host: connection.host, port: connection.port, username: connection.username,
            keyReferences: references, keyProvider: authenticationKeyProvider,
            effectivePasswordTag: connection.passwordTag, promptedPasswordTag: connection.promptedPasswordTag,
            canRemember: true, passwordStore: passwordStore, prompt: passwordPrompt
        )
    }

    /// Inputs for one session-establish run: PTY dimensions plus the resolved
    /// auth delegates (key/password/none user auth + host-key policy) chosen
    /// by the public entry point.
    struct SessionSetup {
        let cols: Int
        let rows: Int
        let userAuth: any NIOSSHClientUserAuthenticationDelegate
        let serverAuth: any NIOSSHClientServerAuthenticationDelegate
    }

    /// Dial → SSH handshake → authenticated connection, NO channel. The
    /// shared establish core: entry points have already torn down prior
    /// state and resolved auth; the `dial` closure owns socket creation
    /// (TCP with TCP_NODELAY, or UDS) and its errors collapse to the
    /// typed `.unreachable` after the group is shut down. Everything
    /// downstream of the dial — recorder wiring, host-key verification,
    /// userauth — is shared by every entry point so the paths cannot
    /// drift. Returns the connection channel once userauth succeeded
    /// (``HandshakeCompletionObserver``); opening any channel is the
    /// caller's job.
    @discardableResult
    func openAuthenticatedConnection(
        userAuth: any NIOSSHClientUserAuthenticationDelegate,
        serverAuth: any NIOSSHClientServerAuthenticationDelegate,
        dial: (ClientBootstrap) async throws -> any Channel
    ) async throws(SSHTransportError) -> any Channel {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = TransportErrorRecorder()
        let handshakeObserver = HandshakeCompletionObserver()
        let agentInitializer = agentChannelInitializer

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .client(SSHClientPipelineFactory.makeConfiguration(
                            userAuthDelegate: userAuth,
                            serverAuthDelegate: serverAuth
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, channelType in
                            if channelType == .authAgent, let agentInitializer {
                                return agentInitializer(child)
                            }
                            return SSHClientPipelineFactory.rejectAllInboundChildChannels(
                                channel: child,
                                channelType: channelType
                            )
                        }
                    ))
                    if let cascade = userAuth as? CascadeUserAuthenticationDelegate {
                        try channel.pipeline.syncOperations.addHandler(cascade)
                    }
                    try channel.pipeline.syncOperations.addHandler(handshakeObserver)
                    try channel.pipeline.syncOperations.addHandler(recorder)
                }
            }

        let channel: any Channel
        do {
            channel = try await dial(bootstrap)
        } catch {
            try? await group.shutdownGracefully()
            throw .unreachable
        }

        self.group = group
        self.connectionChannel = channel
        self.errorRecorder = recorder

        do {
            try await handshakeObserver.awaitCompletion()
        } catch {
            let recorded = await recorder.recordedError()
            await tearDown()
            if let typed = recorded as? SSHTransportError {
                throw typed
            }
            // The typed contract cannot carry the real cause (Secure
            // Enclave signing, Keychain, channel death) — capture it for
            // the device diagnostic before the `.channelDenied` collapse.
            SSHEstablishDiagnostics.shared.record(
                "ssh handshake failed, connection error",
                error: error
            )
            if let recorded {
                SSHEstablishDiagnostics.shared.record(
                    "ssh handshake failed, pipeline-recorded error",
                    error: recorded
                )
            } else {
                SSHEstablishDiagnostics.shared.record(
                    "ssh handshake failed with no pipeline-recorded error"
                )
            }
            throw .channelDenied
        }
        return channel
    }

    /// Session channel → pty-req → shell on an authenticated connection.
    /// Entry points have already validated dimensions and resolved auth;
    /// dialing and the authenticated handshake are shared via
    /// `openAuthenticatedConnection`, so handshake, channel-open, PTY and
    /// shell semantics cannot drift between entry points.
    func openSessionAndActivate(
        _ setup: SessionSetup,
        dial: (ClientBootstrap) async throws -> any Channel
    ) async throws(SSHTransportError) {
        let cols = setup.cols
        let rows = setup.rows
        let agentInitializer = agentChannelInitializer
        let channel = try await openAuthenticatedConnection(
            userAuth: setup.userAuth,
            serverAuth: setup.serverAuth,
            dial: dial
        )

        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        let termination = SessionTermination()
        self.termination = termination
        let dropSignal = inboundDropSignal
        let handler = SessionChannelHandler(
            onOutput: { chunk in
                if case .dropped = continuation.yield(chunk) {
                    dropSignal.fire()
                }
            },
            onClosed: { error in
                termination.record(error)
                continuation.finish()
            }
        )

        let session: any Channel
        do {
            session = try await openChildChannel(on: channel, type: .session) { child, channelType in
                guard channelType == .session else {
                    return child.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return child.eventLoop.makeCompletedFuture {
                    // EOF may precede exit-status. Keep receiving requests
                    // until channel CLOSE rather than mistaking EOF for loss.
                    try child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
        } catch {
            let recorded = await errorRecorder?.recordedError()
            await tearDown()
            if let typed = recorded as? SSHTransportError {
                throw typed
            }
            // The typed contract cannot carry the real cause (Secure
            // Enclave signing, Keychain, channel death) — capture it for
            // the device diagnostic before the `.channelDenied` collapse.
            SSHEstablishDiagnostics.shared.record(
                "session channel open failed, channel-open error",
                error: error
            )
            if let recorded {
                SSHEstablishDiagnostics.shared.record(
                    "session channel open failed, pipeline-recorded error",
                    error: recorded
                )
            } else {
                SSHEstablishDiagnostics.shared.record(
                    "session channel open failed with no pipeline-recorded error"
                )
            }
            throw .channelDenied
        }

        self.output = stream
        self.outputContinuation = continuation
        self.sessionChannel = session
        self.sessionHandler = handler

        // T8: request agent forwarding BEFORE pty-req/shell — sshd only puts
        // SSH_AUTH_SOCK into the spawned shell's environment when the
        // auth-agent-req arrived first. wantReply: false (OpenSSH parity):
        // denial is non-fatal and produces no reply event, so this cannot
        // race the handler's FIFO success/failure tracker below.
        if agentInitializer != nil {
            session.triggerUserOutboundEvent(
                SSHChannelRequestEvent.AgentForwardingRequest(wantReply: false),
                promise: nil
            )
        }

        try await handler.sendRequestExpectingSuccess(SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        ))
        try await handler.sendRequestExpectingSuccess(SSHChannelRequestEvent.ShellRequest(wantReply: true))
    }

    public func send(_ bytes: Data) async throws(SSHTransportError) {
        guard let channel = sessionChannel, let handler = sessionHandler, channel.isActive else {
            throw .channelDenied
        }
        // Backpressure: suspend while the child channel's SSH flow-control
        // window is exhausted instead of queueing unbounded writes.
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

    /// Fire-and-forget per RFC 4254 §6.7 (window-change carries no reply).
    /// Zero/negative dimensions are ignored: NIOSSH converts to `UInt32`
    /// and would trap on them.
    public func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0, let channel = sessionChannel, channel.isActive else { return }
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        ), promise: nil)
    }

    public func close() async {
        await tearDown()
    }

    public func sessionChannelHandle() throws(SSHTransportError) -> SSHChannelHandle {
        guard let channel = sessionChannel, channel.isActive else { throw .channelDenied }
        return SSHChannelHandle(channel: channel)
    }

    // MARK: - Private

    /// `createChannel` must run on the connection's EventLoop; everything
    /// stays inside future closures so the explicitly non-Sendable
    /// `NIOSSHHandler` never crosses an isolation boundary. Internal (not
    /// private) so SSHTransport+DirectTCPIP.swift can open `direct-tcpip`
    /// child channels — Swift `private` is file-scoped.
    func openChildChannel(
        on parent: any Channel,
        type: SSHChannelType,
        initializer: @escaping @Sendable (any Channel, SSHChannelType) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        try await parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: type, initializer)
            return promise.futureResult
        }.get()
    }

    func tearDown() async {
        outputContinuation?.finish()
        outputContinuation = nil
        sessionHandler = nil

        if let session = sessionChannel {
            sessionChannel = nil
            try? await session.close().get()
        }
        if let connection = connectionChannel {
            connectionChannel = nil
            errorRecorder = nil
            try? await connection.close().get()
        }
        if let group {
            self.group = nil
            try? await group.shutdownGracefully()
        }
    }
}

/// T11: SSH is the reference ``TerminalTransport`` conformer. Every
/// signature already matches (typed `TransportError` via the
/// `SSHTransportError` typealias); suspend/resume take the protocol
/// extension defaults (`.rehandshake`: `suspend()` ≡ `close()`,
/// `resume()` throws `.resumeUnsupported`).
///
/// Capability-gated extension point (agent forwarding): consumers check
/// `ProtocolDescriptor.ssh.supportsAgentForwarding`, then conditionally
/// cast to `SSHTransport` (pre-connect `AgentForwardingBridge.install(on:)`)
/// or to `any SSHSessionTransport` (post-connect `sessionChannelHandle()`).
/// No NIO type crosses the cast — `SSHChannelHandle`'s channel is
/// module-internal.
extension SSHTransport: TerminalTransport {}

extension SSHTransport: InboundDropObserving {
    public func setInboundDropObserver(_ observer: (@Sendable () -> Void)?) async {
        inboundDropSignal.setObserver(observer)
    }
}

/// Lock-confined optional closure: written from `SSHTransport`'s actor
/// context, fired from the session channel's EventLoop.
final class InboundDropSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable () -> Void)?

    func setObserver(_ observer: (@Sendable () -> Void)?) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let current = observer
        lock.unlock()
        current?()
    }
}

/// Connection-pipeline observer for the channel-less establish wait:
/// succeeds once userauth completes (`UserAuthSuccessEvent` — the
/// connection is active and channels may open), fails with the pipeline
/// error (or `ioOnClosedChannel` when the connection dies silently
/// pre-auth). Installed BEFORE ``TransportErrorRecorder`` so errors still
/// reach it; every callback passes events onward — the observer never
/// swallows. EventLoop-confined like the recorder.
final class HandshakeCompletionObserver: ChannelInboundHandler, @unchecked Sendable {
    // @unchecked Sendable: EventLoop-confined state (`promise` is written
    // in handlerAdded and read by `awaitCompletion` on that same loop).
    typealias InboundIn = Any

    private var eventLoop: (any EventLoop)?
    private var promise: EventLoopPromise<Void>?
    private var finished = false

    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop = context.eventLoop
        promise = context.eventLoop.makePromise(of: Void.self)
    }

    /// Removal without prior completion (dial failure: never-active channel,
    /// no inactive/error event) must not leak the promise.
    func handlerRemoved(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            promise?.fail(ChannelError.ioOnClosedChannel)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !finished {
            finished = true
            promise?.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !finished {
            finished = true
            promise?.fail(error)
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            promise?.fail(ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }

    /// Suspends until userauth succeeds. Hops onto the connection's
    /// EventLoop to read the handler-added promise (the recorder's
    /// `recordedError()` idiom).
    func awaitCompletion() async throws {
        guard let eventLoop else { throw SSHTransportError.channelDenied }
        try await eventLoop.flatSubmit {
            self.promise?.futureResult
                ?? eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
        }.get()
    }
}
