import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Key-authenticated SSH terminal transport over SwiftNIO SSH.
///
/// Lifecycle: one `connect` per session — it performs TCP connect, host-key
/// TOFU verification (via T4's `HostKeyVerifier`), single-shot public-key
/// auth, session channel open, `pty-req` (xterm-256color) and `shell`
/// (both with reply tracking). `output` is a FRESH stream per connection;
/// the previous one is finished on reconnect or `close`.
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

    private let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider

    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var group: MultiThreadedEventLoopGroup?
    private var connectionChannel: (any Channel)?
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
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider()
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        let (stream, _) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(32))
        self.output = stream
    }

    public func connect(to connection: Connection, cols: Int, rows: Int) async throws(SSHTransportError) {
        guard cols > 0, rows > 0 else { throw .channelDenied }

        await tearDown()

        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try await authenticationKeyProvider.authenticationPrivateKey(
                with: connection.keyReference,
                reason: "Authenticate to \(connection.host)"
            )
        } catch {
            throw .authenticationFailed
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = TransportErrorRecorder()
        let serverAuth = VerifyingHostKeyDelegate(
            host: connection.host,
            port: connection.port,
            verifier: hostKeyVerifier
        )
        let userAuth = SingleKeyUserAuthenticationDelegate(username: connection.username, key: privateKey)
        let agentInitializer = agentChannelInitializer

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
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
            channel = try await bootstrap.connect(host: connection.host, port: connection.port).get()
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
        if agentChannelInitializer != nil {
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

    /// Opens a `direct-tcpip` channel (T9 ProxyJump). The returned channel
    /// already carries the `SSHChannelData`↔`ByteBuffer` adapter, so a
    /// nested `NIOSSHHandler` can handshake over it directly.
    public func openDirectTCPIPChannel(
        toHost host: String,
        port: Int
    ) async throws(SSHTransportError) -> SSHChannelHandle {
        guard let parent = connectionChannel, parent.isActive else { throw .channelDenied }
        guard port > 0, port <= Int(UInt16.max) else { throw .channelDenied }

        let originator: SocketAddress
        do {
            originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        } catch {
            throw .channelDenied
        }
        let target = SSHChannelType.DirectTCPIP(
            targetHost: host,
            targetPort: port,
            originatorAddress: originator
        )

        do {
            let child = try await openChildChannel(on: parent, type: .directTCPIP(target)) { channel, channelType in
                guard case .directTCPIP = channelType else {
                    return channel.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SSHChannelDataByteBufferWrapper())
                }
            }
            return SSHChannelHandle(channel: child)
        } catch let error as SSHTransportError {
            throw error
        } catch {
            throw .channelDenied
        }
    }

    // MARK: - Private

    /// `createChannel` must run on the connection's EventLoop; everything
    /// stays inside future closures so the explicitly non-Sendable
    /// `NIOSSHHandler` never crosses an isolation boundary.
    private func openChildChannel(
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

    private func tearDown() async {
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
