import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Hop endpoint

/// One hop's coordinates, resolved from `Hop` or from the destination
/// triple of `Connection`.
struct JumpHopEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let offersKeys: Bool
    let customKeys: [String]?
    let passwordTag: String?
    let promptedPasswordTag: String?
    let canRemember: Bool

    init(hop: Hop) {
        self.init(
            host: hop.host,
            port: hop.port,
            username: hop.username,
            offersKeys: hop.offersKeys,
            customKeys: hop.customKeys,
            passwordTag: hop.passwordTag
        )
    }

    init(host: String, port: Int, username: String, offersKeys: Bool = true,
         customKeys: [String]? = nil, passwordTag: String? = nil,
         promptedPasswordTag: String? = nil, canRemember: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.offersKeys = offersKeys
        self.customKeys = customKeys
        self.passwordTag = passwordTag
        self.promptedPasswordTag = promptedPasswordTag
        self.canRemember = canRemember
    }
}

// MARK: - Dialer seam

/// Abstraction over "establish an authenticated SSH connection to a hop" so
/// `JumpChainBuilder`'s composition, failure-attribution and cleanup logic is
/// unit-testable without sockets. The production implementation is
/// ``NIOJumpDialer``; tests inject a recording fake.
protocol JumpDialer: Sendable {
    /// TCP-connect + full SSH client handshake (host-key verify, key auth).
    /// No pty/shell: intermediate hops are bare connections.
    func connectTCP(to endpoint: JumpHopEndpoint) async throws(SSHTransportError) -> any JumpHopConnection

    /// Full nested SSH client handshake over an open direct-tcpip link from
    /// the previous hop. The link's channel already carries the
    /// SSHChannelData↔ByteBuffer wrapper.
    func connectNested(over link: any JumpRawLink, to endpoint: JumpHopEndpoint) async throws(SSHTransportError) -> any JumpHopConnection
}

/// An authenticated SSH connection to one hop.
protocol JumpHopConnection: Sendable {
    /// Opens a direct-tcpip child channel toward the next hop. A failure of
    /// THIS hop's handshake (queued until the first channel open) surfaces
    /// here as the recorded typed error; a refusal of the forward itself
    /// surfaces as `.channelDenied`.
    func openForward(toHost host: String, port: Int) async throws(SSHTransportError) -> any JumpRawLink

    /// Final hop only: session channel + pty-req + shell, both wantReply-tracked.
    func openSession(cols: Int, rows: Int) async throws(SSHTransportError) -> any JumpSession

    /// Non-PTY exec channel on this hop's connection — the herdr probe and
    /// bridge surface over jump chains. Same channel posture as
    /// `SSHTransport.openExecChannel(command:)`.
    func openExec(command: String) async throws(SSHTransportError) -> SSHExecSession

    func close() async
}

/// An open direct-tcpip child channel before the nested handshake starts.
protocol JumpRawLink: Sendable {
    func close() async
}

/// The established shell session on the final hop.
protocol JumpSession: Sendable {
    var output: AsyncStream<Data> { get }
    var closeReason: TransportCloseReason { get }
    func send(_ bytes: Data) async throws(SSHTransportError)
    func resize(cols: Int, rows: Int) async
    func sessionChannelHandle() throws(SSHTransportError) -> SSHChannelHandle
    func close() async
}

extension JumpSession {
    var closeReason: TransportCloseReason { .connectionLost }
}

// MARK: - NIO implementation

struct NIOJumpDialer: JumpDialer {
    let hostKeyVerifier: HostKeyVerifier
    let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    let passwordStore: any PasswordStoring
    var passwordPrompt: (any SSHPasswordPrompting)? = nil
    var hardwareKeysEnabledByDefault: @Sendable () -> Bool = { true }
    var keyOfferResolver: KeyOfferResolver = KeyOfferResolver()
    var metadataProvider: any SSHKeyMetadataProviding = DefaultSSHKeyMetadataProvider()

    func connectTCP(to endpoint: JumpHopEndpoint) async throws(SSHTransportError) -> any JumpHopConnection {
        let userAuth = try await makeUserAuthDelegate(for: endpoint)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = TransportErrorRecorder()
        let serverAuth = VerifyingHostKeyDelegate(host: endpoint.host, port: endpoint.port, verifier: hostKeyVerifier)

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
                        inboundChildChannelInitializer: SSHClientPipelineFactory.rejectAllInboundChildChannels
                    ))
                    if let cascade = userAuth as? CascadeUserAuthenticationDelegate {
                        try channel.pipeline.syncOperations.addHandler(cascade)
                    }
                    try channel.pipeline.syncOperations.addHandler(recorder)
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            try? await group.shutdownGracefully()
            throw .unreachable
        }
        return NIOJumpHopConnection(channel: channel, group: group, recorder: recorder)
    }

    func connectNested(over link: any JumpRawLink, to endpoint: JumpHopEndpoint) async throws(SSHTransportError) -> any JumpHopConnection {
        guard let nioLink = link as? NIOJumpRawLink else { throw .channelDenied }
        let userAuth = try await makeUserAuthDelegate(for: endpoint)
        let recorder = TransportErrorRecorder()
        let serverAuth = VerifyingHostKeyDelegate(host: endpoint.host, port: endpoint.port, verifier: hostKeyVerifier)
        let channel = nioLink.channel

        // The child channel is already active; NIOSSHHandler.handlerAdded
        // starts the version exchange immediately on already-active channels
        // (NIOSSHHandler.swift:126-131).
        do {
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .client(SSHClientPipelineFactory.makeConfiguration(
                        userAuthDelegate: userAuth,
                        serverAuthDelegate: serverAuth
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: SSHClientPipelineFactory.rejectAllInboundChildChannels
                ))
                if let cascade = userAuth as? CascadeUserAuthenticationDelegate {
                    try channel.pipeline.syncOperations.addHandler(cascade)
                }
                try channel.pipeline.syncOperations.addHandler(recorder)
                try channel.setOption(ChannelOptions.autoRead, value: true)
                // SSHChildChannel's option setter does not initiate a read.
                channel.read()
            }.get()
        } catch {
            throw .channelDenied
        }
        return NIOJumpHopConnection(channel: channel, group: nil, recorder: recorder)
    }

    private func makeUserAuthDelegate(
        for endpoint: JumpHopEndpoint
    ) async throws(SSHTransportError) -> any NIOSSHClientUserAuthenticationDelegate {
        let keys = (try? await metadataProvider.availableKeys()) ?? []
        let references = keyOfferResolver.resolve(
            KeyOfferRequest(offersKeys: endpoint.offersKeys, customKeys: endpoint.customKeys,
                            hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault()),
            keys: keys
        )
        return CascadeUserAuthenticationDelegate(
            host: endpoint.host, port: endpoint.port, username: endpoint.username,
            keyReferences: references, keyProvider: authenticationKeyProvider,
            effectivePasswordTag: endpoint.passwordTag, promptedPasswordTag: endpoint.promptedPasswordTag,
            canRemember: endpoint.canRemember, passwordStore: passwordStore, prompt: passwordPrompt
        )
    }
}

final class NIOJumpRawLink: JumpRawLink, @unchecked Sendable {
    // EventLoop-confined; close() is funnelled onto the channel's loop.
    let channel: any Channel

    init(channel: any Channel) {
        self.channel = channel
    }

    func close() async {
        try? await channel.close().get()
    }
}

final class NIOJumpHopConnection: JumpHopConnection, @unchecked Sendable {
    // EventLoop-confined NIO objects; group is non-nil only for the TCP
    // first hop (nested connections share the first hop's EventLoop).
    let channel: any Channel
    let group: MultiThreadedEventLoopGroup?
    let recorder: TransportErrorRecorder

    init(channel: any Channel, group: MultiThreadedEventLoopGroup?, recorder: TransportErrorRecorder) {
        self.channel = channel
        self.group = group
        self.recorder = recorder
    }

    func openForward(toHost host: String, port: Int) async throws(SSHTransportError) -> any JumpRawLink {
        guard channel.isActive else {
            throw await recordedFirstError() ?? .channelDenied
        }
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
            let child = try await openChild(type: .directTCPIP(target)) { channel, channelType in
                guard case .directTCPIP = channelType else {
                    return channel.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return channel.eventLoop.makeCompletedFuture {
                    // Retain the peer's identification bytes until connectNested
                    // installs their consumer, including across metadata awaits.
                    try channel.setOption(ChannelOptions.autoRead, value: false)
                    try channel.pipeline.syncOperations.addHandler(SSHChannelDataByteBufferWrapper())
                }
            }
            return NIOJumpRawLink(channel: child)
        } catch let error as SSHTransportError {
            throw error
        } catch {
            // A dead handshake fails the queued createChannel promise with a
            // generic ChannelError — recover the typed cause first.
            throw await recordedFirstError() ?? .channelDenied
        }
    }

    func openSession(cols: Int, rows: Int) async throws(SSHTransportError) -> any JumpSession {
        guard cols > 0, rows > 0 else { throw .channelDenied }
        guard channel.isActive else {
            throw await recordedFirstError() ?? .channelDenied
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        let termination = SessionTermination()
        let handler = SessionChannelHandler(
            onOutput: { continuation.yield($0) },
            onClosed: {
                termination.record($0)
                continuation.finish()
            }
        )

        let session: any Channel
        do {
            session = try await openChild(type: .session) { child, channelType in
                guard channelType == .session else {
                    return child.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
        } catch {
            throw await recordedFirstError() ?? .channelDenied
        }

        do {
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
        } catch {
            try? await session.close().get()
            throw await recordedFirstError() ?? .channelDenied
        }

        return NIOJumpSession(channel: session, handler: handler, output: stream, termination: termination)
    }

    /// Mirrors `SSHTransport.openExecChannel` channel-for-channel: half-close
    /// as in-order EOF event, demand-driven reads, wantReply-tracked exec
    /// request whose refusal never leaks the opened channel.
    func openExec(command: String) async throws(SSHTransportError) -> SSHExecSession {
        guard channel.isActive else {
            throw await recordedFirstError() ?? .channelDenied
        }

        let core = ExecChannelCore()
        let handler = ExecChannelHandler(core: core)
        let session: any Channel
        do {
            session = try await openChild(type: .session) { child, channelType in
                guard channelType == .session else {
                    return child.eventLoop.makeFailedFuture(SSHTransportError.channelDenied)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    try child.setOption(ChannelOptions.autoRead, value: false)
                    core.attach(channel: child)
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
        } catch {
            throw await recordedFirstError() ?? .channelDenied
        }

        do {
            try await handler.sendRequestExpectingSuccess(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        } catch let error as SSHTransportError {
            try? await session.close().get()
            throw error
        }
        core.beginReading()
        return SSHExecSession(channel: session, handler: handler, core: core)
    }

    func close() async {
        try? await channel.close().get()
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    private func recordedFirstError() async -> SSHTransportError? {
        await recorder.recordedError() as? SSHTransportError
    }

    /// Mirrors `SSHTransport.openChildChannel`: createChannel must run on the
    /// connection's EventLoop; the non-Sendable NIOSSHHandler stays inside
    /// future closures.
    private func openChild(
        type: SSHChannelType,
        initializer: @escaping @Sendable (any Channel, SSHChannelType) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let channel = self.channel
        return try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: type, initializer)
            return promise.futureResult
        }.get()
    }
}

final class NIOJumpSession: JumpSession, @unchecked Sendable {
    // EventLoop-confined; mirrors SSHTransport's session I/O semantics.
    let channel: any Channel
    let handler: SessionChannelHandler
    let output: AsyncStream<Data>
    private let termination: SessionTermination
    var closeReason: TransportCloseReason { termination.reason }

    init(channel: any Channel, handler: SessionChannelHandler, output: AsyncStream<Data>, termination: SessionTermination) {
        self.channel = channel
        self.handler = handler
        self.output = output
        self.termination = termination
    }

    func send(_ bytes: Data) async throws(SSHTransportError) {
        guard channel.isActive else { throw .channelDenied }
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

    func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0, channel.isActive else { return }
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        ), promise: nil)
    }

    func sessionChannelHandle() throws(SSHTransportError) -> SSHChannelHandle {
        guard channel.isActive else { throw .channelDenied }
        return SSHChannelHandle(channel: channel)
    }

    func close() async {
        try? await channel.close().get()
    }
}
