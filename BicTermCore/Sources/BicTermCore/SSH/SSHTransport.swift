import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Key- or password-authenticated SSH terminal transport over SwiftNIO SSH.
///
/// Lifecycle: one `connect` per session — it performs TCP connect, host-key
/// TOFU verification (via T4's `HostKeyVerifier`), single-shot user auth
/// (public key or password per the connection's `authMethod`), session
/// channel open, `pty-req` (xterm-256color) and `shell`
/// (both with reply tracking). `output` is a FRESH stream per connection;
/// the previous one is finished on reconnect or `close`.
///
/// Unix-domain-socket dialing (fixture conformance) lives in
/// SSHTransport+UDS.swift and shares the session-establish tail through
/// `openSessionAndActivate`.
///
/// Output buffering policy: the stream holds at most 32 chunks of at most
/// 32 KiB (≈1 MiB). On overflow the OLDEST queued chunks are dropped
/// (`.bufferingNewest`) — a slow consumer loses scrollback, never blocks
/// the network read path.
///
/// Inbound security posture: every server-initiated channel open is
/// rejected and no `GlobalRequestDelegate` is installed — see
/// `SSHClientPipelineFactory`.
public actor SSHTransport {
    public private(set) var output: AsyncStream<Data>

    // Internal (not private) so the UDS entry points in SSHTransport+UDS.swift
    // can reach them — Swift `private` is file-scoped.
    let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    private let passwordStore: any PasswordStoring
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

    /// Internal additive hook (T8) — not part of the public API surface.
    internal func installAgentChannelInitializer(
        _ initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) {
        agentChannelInitializer = initializer
    }

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider(),
        passwordStore: any PasswordStoring = KeychainPasswordStore()
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.passwordStore = passwordStore
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

    /// Resolves the user-auth delegate strictly from the connection's
    /// declared method — a password endpoint never offers keys and a key
    /// endpoint never falls back to passwords. A credential that cannot be
    /// resolved is the typed `.authenticationFailed`, thrown before any dial.
    func userAuthDelegate(
        for connection: Connection
    ) async throws(SSHTransportError) -> any NIOSSHClientUserAuthenticationDelegate {
        switch connection.authMethod {
        case .publickey:
            let privateKey: NIOSSHPrivateKey
            do {
                privateKey = try await authenticationKeyProvider.authenticationPrivateKey(
                    with: connection.keyReference,
                    reason: "Authenticate to \(connection.host)"
                )
            } catch {
                throw .authenticationFailed
            }
            return SingleKeyUserAuthenticationDelegate(username: connection.username, key: privateKey)
        case .password:
            return PasswordUserAuthenticationDelegate(
                username: connection.username,
                password: try await resolvedPassword(forTag: connection.keyReference)
            )
        }
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

    /// Dial → SSH handshake → session channel → pty-req → shell. Entry points
    /// have already validated dimensions, torn down prior state, and resolved
    /// auth; the `dial` closure owns socket creation (TCP with TCP_NODELAY,
    /// or UDS) and its errors collapse to the typed `.unreachable` after the
    /// group is shut down. Everything downstream of the dial — recorder
    /// wiring, channel-open, agent-forward request, pty/shell replies — is
    /// shared by every entry point so the paths cannot drift.
    func openSessionAndActivate(
        _ setup: SessionSetup,
        dial: (ClientBootstrap) async throws -> any Channel
    ) async throws(SSHTransportError) {
        let cols = setup.cols
        let rows = setup.rows
        let userAuth = setup.userAuth
        let serverAuth = setup.serverAuth
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = TransportErrorRecorder()
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

        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        let handler = SessionChannelHandler(
            onOutput: { continuation.yield($0) },
            onClosed: { continuation.finish() }
        )

        let session: any Channel
        do {
            session = try await openChildChannel(on: channel, type: .session) { child, channelType in
                guard channelType == .session else {
                    return child.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
        } catch {
            let recorded = await recorder.recordedError()
            await tearDown()
            if let typed = recorded as? SSHTransportError {
                throw typed
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

    /// Resolves the stored password for a `.password`-method endpoint. Any
    /// store failure or a missing entry is the typed `.authenticationFailed`
    /// — no credential probe ever reaches the network.
    private func resolvedPassword(forTag tag: String) async throws(SSHTransportError) -> String {
        let stored: String?
        do {
            stored = try await passwordStore.password(for: tag)
        } catch {
            throw .authenticationFailed
        }
        guard let stored else { throw .authenticationFailed }
        return stored
    }

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
