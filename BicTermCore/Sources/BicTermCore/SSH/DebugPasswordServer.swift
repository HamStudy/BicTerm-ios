#if DEBUG

import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// DEBUG-ONLY in-process SSH server that accepts exactly one username+password
/// pair via the RFC 4252 `password` method (NIOSSH has no keyboard-interactive
/// support; OpenSSH servers need `PasswordAuthentication yes`, the default).
///
/// Two consumers:
///   1. BicTermCoreTests — hermetic end-to-end password-auth tests bind this
///      on loopback with an EPHEMERAL port (no fixtures, no external sshd).
///   2. The app's `--uitest-pwd-server` launch hook (see
///      ``UITestPasswordServerSeam``) — a fixed loopback listener UI tests
///      can point password-method connections at.
///
/// The session child channel answers pty-req/shell with success and echoes
/// data back, which is all a client-side transport test needs. Release builds
/// compile this file to nothing (whole-file `#if DEBUG`).
public final class LoopbackPasswordSSHServer: @unchecked Sendable {
    public enum KeyAuthentication: Sendable, Equatable {
        case disabled, rejected, requiresPassword
        case acceptedPublicKeys([Data])
    }
    public enum StartError: Error, Equatable {
        case alreadyStarted
        case bindFailed
    }

    /// Bytes emitted once a shell is granted — the deterministic "session is
    /// live" marker tests wait for.
    public static let greeting = "loopback-password-server ready\r\n"

    private let username: String
    private let offeredPassword: String
    private let hostKey: NIOSSHPrivateKey
    private let keyAuthentication: KeyAuthentication
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: (any Channel)?
    private var inboundChannelCount = 0
    private var authenticatedCount = 0

    public init(username: String, password: String, keyAuthentication: KeyAuthentication = .disabled,
                hostKey: NIOSSHPrivateKey? = nil) {
        self.username = username
        self.offeredPassword = password
        self.hostKey = hostKey ?? NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        self.keyAuthentication = keyAuthentication
    }

    /// `"algorithm base64-wire-blob"` in authorized_keys format — tests
    /// pre-trust the blob via `HostKeyVerifier.trust(host:port:key:algorithm:)`.
    public var hostKeyOpenSSH: String {
        String(openSSHPublicKey: hostKey.publicKey)
    }

    /// Number of TCP connections the server has accepted. Zero proves a
    /// client failure happened before the dial.
    public var inboundConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inboundChannelCount
    }

    /// Number of connections whose authentication succeeded.
    public var authenticatedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedCount
    }

    private func noteInboundConnection() {
        lock.lock()
        inboundChannelCount += 1
        lock.unlock()
    }

    private func noteAuthenticated() {
        lock.lock()
        authenticatedCount += 1
        lock.unlock()
    }

    private func installRunningState(channel: any Channel, group: MultiThreadedEventLoopGroup) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard serverChannel == nil else { return false }
        serverChannel = channel
        self.group = group
        return true
    }

    /// Atomically removes the running state so two concurrent stops never
    /// double-close. Sync: `NSLock` cannot cross async suspension points.
    private func takeRunningState() -> (channel: (any Channel)?, group: MultiThreadedEventLoopGroup?) {
        lock.lock()
        defer { lock.unlock() }
        let state = (serverChannel, group)
        serverChannel = nil
        group = nil
        return state
    }

    /// Binds `127.0.0.1:port` (port 0 = ephemeral) and returns the bound port.
    public func start(port: Int) async throws(StartError) -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = self.hostKey
        let username = username
        let password = offeredPassword
        let keyAuthentication = keyAuthentication

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                self?.noteInboundConnection()
                let authDelegate = AcceptanceCountingPasswordAuthDelegate(
                    username: username, password: password, keyAuthentication: keyAuthentication,
                    onAuthenticated: { [weak self] in self?.noteAuthenticated() }
                )
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [hostKey],
                            userAuthDelegate: authDelegate
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, channelType in
                            guard channelType == .session else {
                                return child.eventLoop.makeFailedFuture(TransportError.channelDenied)
                            }
                            return child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(EchoSessionHandler())
                            }
                        }
                    ))
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        } catch {
            try? await group.shutdownGracefully()
            throw .bindFailed
        }

        guard installRunningState(channel: channel, group: group) else {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw .alreadyStarted
        }
        return channel.localAddress?.port ?? port
    }

    public func stop() async {
        let state = takeRunningState()
        if let channel = state.channel { try? await channel.close().get() }
        if let group = state.group { try? await group.shutdownGracefully() }
    }
}

/// Server-side auth delegate: accepts the configured password pair or key blobs.
private final class AcceptanceCountingPasswordAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        keyAuthentication == .disabled ? .password : [.publicKey, .password]
    }

    private let username: String
    private let password: String
    private let onAuthenticated: @Sendable () -> Void
    private let keyAuthentication: LoopbackPasswordSSHServer.KeyAuthentication
    private var keyAccepted = false

    init(username: String, password: String, keyAuthentication: LoopbackPasswordSSHServer.KeyAuthentication,
         onAuthenticated: @escaping @Sendable () -> Void) {
        self.username = username
        self.password = password
        self.onAuthenticated = onAuthenticated
        self.keyAuthentication = keyAuthentication
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        if case .publicKey(let offer) = request.request {
            if keyAuthentication == .requiresPassword, request.username == username {
                keyAccepted = true
                responsePromise.succeed(.partialSuccess(remainingMethods: .password))
            } else if case .acceptedPublicKeys(let accepted) = keyAuthentication,
                      request.username == username {
                let components = String(openSSHPublicKey: offer.publicKey).split(separator: " ", maxSplits: 1)
                if components.count == 2,
                   let blob = Data(base64Encoded: String(components[1])), accepted.contains(blob) {
                    onAuthenticated()
                    responsePromise.succeed(.success)
                } else {
                    responsePromise.succeed(.failure)
                }
            } else {
                responsePromise.succeed(.failure)
            }
            return
        }
        guard case .password(let offer) = request.request,
              keyAuthentication != .requiresPassword || keyAccepted,
              request.username == username,
              offer.password == password
        else {
            responsePromise.succeed(.failure)
            return
        }
        onAuthenticated()
        responsePromise.succeed(.success)
    }
}

/// Session channel behavior: grant pty/shell (success replies are only sent
/// when the client asked for one), greet on shell, then echo data back.
private final class EchoSessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            if pty.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        case let shell as SSHChannelRequestEvent.ShellRequest:
            if shell.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            var buffer = context.channel.allocator.buffer(capacity: LoopbackPasswordSSHServer.greeting.utf8.count)
            buffer.writeString(LoopbackPasswordSSHServer.greeting)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer = message.data else { return }
        context.writeAndFlush(data, promise: nil)
    }
}

/// Launch-arg hook used by the app target: `--uitest-pwd-server` starts one
/// shared password-accepting server on loopback. Fixed port 18090, overridable
/// via the `UITEST_PWD_SERVER_PORT` environment variable; the accepted
/// password defaults to ``defaultPassword`` and may be overridden via
/// `UITEST_PWD_SERVER_PASSWORD` so UI tests can drive wrong-password paths.
public enum UITestPasswordServerSeam {
    public static let launchArgument = "--uitest-pwd-server"
    public static let defaultPort = 18090
    public static let portEnvironmentVariable = "UITEST_PWD_SERVER_PORT"
    public static let passwordEnvironmentVariable = "UITEST_PWD_SERVER_PASSWORD"
    public static let username = "uitest"
    public static let defaultPassword = "bicterm-uitest-fixture-password"

    private final class SharedServerBox: @unchecked Sendable {
        let lock = NSLock()
        var server: LoopbackPasswordSSHServer?
    }

    private static let shared = SharedServerBox()

    /// Idempotent: repeated calls (multi-scene relaunches share the process)
    /// never rebind the port. Never touches the network when the launch
    /// argument is absent.
    public static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }

        shared.lock.lock()
        let existing = shared.server
        shared.lock.unlock()
        guard existing == nil else { return }

        let port = environment[portEnvironmentVariable].flatMap(Int.init) ?? defaultPort
        let password = environment[passwordEnvironmentVariable] ?? defaultPassword
        // Stable DEBUG fixture identity lets relaunch tests reuse trust without
        // bypassing verification or mistaking a fresh random key for an attack.
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x5a, count: 32)) else { return }
        let server = LoopbackPasswordSSHServer(username: username, password: password,
                                              hostKey: NIOSSHPrivateKey(ed25519Key: signingKey))

        shared.lock.lock()
        shared.server = server
        shared.lock.unlock()

        Task {
            _ = try? await server.start(port: port)
        }
    }
}

#endif
