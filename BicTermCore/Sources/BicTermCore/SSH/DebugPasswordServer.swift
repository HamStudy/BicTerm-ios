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
/// data back; `exec` requests get a canned response (see
/// ``LoopbackPasswordSSHServer/execResponse``). Release builds compile
/// this file to nothing (whole-file `#if DEBUG`).
public final class LoopbackPasswordSSHServer: @unchecked Sendable {
    public enum KeyAuthentication: Sendable, Equatable {
        case disabled, rejected, requiresPassword
        case acceptedPublicKeys([Data])
    }

    /// Per-connection policy for inbound `session`-type channel opens.
    ///
    /// `.lifetimeTotal(n)` reproduces, at the real NIOSSH protocol level,
    /// the channel budget of CoderSSHGW_0.5.0 (the gateway behind
    /// `emailsupport@coder.ham.dev`): that gateway permits exactly ONE
    /// session channel per SSH connection LIFETIME — a second `session`
    /// open is refused with `SSH_MSG_CHANNEL_OPEN_FAILURE` even after the
    /// first channel closed cleanly (device-proven; an OpenSSH
    /// ControlMaster reproduction confirms the limit is per connection
    /// LIFETIME, not per concurrent channel). Under `.lifetimeTotal(n)`
    /// the server counts `.session` channel opens per TCP connection and
    /// the count NEVER decrements on close, so the (n+1)th open is
    /// rejected the same way and the client observes the channel open
    /// failing with `NIOSSHError.channelSetupRejected` — the same error
    /// class the real gateway produces.
    public enum SessionChannelPolicy: Sendable, Equatable {
        /// Any number of `session` channel opens per TCP connection —
        /// the historical behavior and the default.
        case unlimited
        /// At most `n` `session` channel opens per TCP connection
        /// LIFETIME; the count never decrements when a channel closes.
        case lifetimeTotal(Int)
    }
    public enum StartError: Error, Equatable {
        case alreadyStarted
        case bindFailed
    }

    /// Bytes emitted once a shell is granted — the deterministic "session is
    /// live" marker tests wait for.
    public static let greeting = "loopback-password-server ready\r\n"

    /// Default ``execResponse`` — the deterministic marker exec tests
    /// wait for.
    public static let defaultExecResponse = "exec-ok\n"

    private let username: String
    private let offeredPassword: String
    private let hostKey: NIOSSHPrivateKey
    private let keyAuthentication: KeyAuthentication
    private let sessionChannelPolicy: SessionChannelPolicy
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: (any Channel)?
    private var inboundChannelCount = 0
    private var authenticatedCount = 0
    private var execResponseStorage = defaultExecResponse

    public init(username: String, password: String, keyAuthentication: KeyAuthentication = .disabled,
                sessionChannelPolicy: SessionChannelPolicy = .unlimited,
                hostKey: NIOSSHPrivateKey? = nil) {
        self.username = username
        self.offeredPassword = password
        self.hostKey = hostKey ?? NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        self.keyAuthentication = keyAuthentication
        self.sessionChannelPolicy = sessionChannelPolicy
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

    /// Canned stdout the session handler writes for `exec` requests
    /// (followed by exit-status 0, EOF, and channel close). Settable at any
    /// time — including while connections are live — so connector tests can
    /// point the herdr probe at this server (the probe greps
    /// `command -v herdr`-style output). Lock-confined like the counters.
    public var execResponse: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return execResponseStorage
        }
        set {
            lock.lock()
            execResponseStorage = newValue
            lock.unlock()
        }
    }

    /// Opt-in `exec` drain mode: instead of replying immediately, the
    /// handler DISCARDS stdin until the client's SSH EOF (write
    /// half-close), then writes the canned response, exit-status 0, and
    /// closes — the wire shape a real stdin-consuming remote command
    /// takes, so streaming uploaders can round-trip against this
    /// server. Captured when ``start(port:)`` binds (set it before
    /// start); the drain shape needs the session child channel to
    /// allow remote half-closure, which is applied with it. Default
    /// false: the historical immediate-reply shape.
    public var execDrainsStdin: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return execDrainsStdinStorage
        }
        set {
            lock.lock()
            execDrainsStdinStorage = newValue
            lock.unlock()
        }
    }

    private var execDrainsStdinStorage = false

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
        let sessionChannelPolicy = sessionChannelPolicy
        let execDrainsStdin = self.execDrainsStdin

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                self?.noteInboundConnection()
                let authDelegate = AcceptanceCountingPasswordAuthDelegate(
                    username: username, password: password, keyAuthentication: keyAuthentication,
                    onAuthenticated: { [weak self] in self?.noteAuthenticated() }
                )
                // One budget per accepted TCP connection: the count spans
                // every session channel on that connection and never
                // resets (the CoderSSHGW lifetime shape).
                let sessionBudget = SessionChannelBudget(policy: sessionChannelPolicy)
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
                            guard sessionBudget.consumeSessionOpen() else {
                                // A failed initializer makes NIOSSH answer
                                // the open with SSH_MSG_CHANNEL_OPEN_FAILURE;
                                // the client observes
                                // NIOSSHError.channelSetupRejected.
                                return child.eventLoop.makeFailedFuture(TransportError.channelDenied)
                            }
                            return child.eventLoop.makeCompletedFuture {
                                if execDrainsStdin {
                                    // The drain shape replies on the client's
                                    // SSH EOF, which NIOSSH surfaces as
                                    // ChannelEvent.inputClosed only when the
                                    // child channel allows remote half-closure.
                                    try child.setOption(
                                        ChannelOptions.allowRemoteHalfClosure,
                                        value: true
                                    )
                                }
                                try child.pipeline.syncOperations.addHandler(
                                    EchoSessionHandler(
                                        execResponse: { [weak self] in self?.execResponse ?? "" },
                                        drainsStdin: execDrainsStdin
                                    )
                                )
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
/// `exec` requests get a minimal canned-command round-trip: success reply,
/// canned stdout, exit-status 0, EOF, then channel close — the wire shape a
/// real remote command takes, so exec-based clients (the herdr probe) can
/// run against this server.
private final class EchoSessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let execResponse: @Sendable () -> String
    private let drainsStdin: Bool
    /// Drain mode: an exec request arrived and the reply is deferred until
    /// the client's SSH EOF. EventLoop-confined (all handler callbacks run
    /// on the channel's loop).
    private var execPending = false

    init(
        execResponse: @escaping @Sendable () -> String,
        drainsStdin: Bool = false
    ) {
        self.execResponse = execResponse
        self.drainsStdin = drainsStdin
    }

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
        case let exec as SSHChannelRequestEvent.ExecRequest:
            if exec.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            if drainsStdin {
                // Drain shape: hold the reply until the client's SSH EOF
                // arrives as ChannelEvent.inputClosed.
                execPending = true
            } else {
                finishExec(context)
            }
        default:
            if let channelEvent = event as? ChannelEvent,
               channelEvent == .inputClosed,
               execPending {
                execPending = false
                finishExec(context)
            } else {
                context.fireUserInboundEventTriggered(event)
            }
        }
    }

    /// The exec round-trip's terminal half: canned stdout, exit-status 0,
    /// EOF, close (RFC 4254 §5.3 wire order).
    private func finishExec(_ context: ChannelHandlerContext) {
        let response = execResponse()
        var buffer = context.channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
        context.channel.close(mode: .output, promise: nil)
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Drain mode discards stdin (the reply is deferred to EOF).
        guard !execPending else { return }
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer = message.data else { return }
        context.writeAndFlush(data, promise: nil)
    }
}

/// Per-TCP-connection lifetime budget for `.session` channel opens (see
/// ``LoopbackPasswordSSHServer.SessionChannelPolicy``). One instance per
/// accepted connection, captured by that connection's inbound child-channel
/// initializer. The count only ever decrements — there is no close hook —
/// so a cleanly-closed channel never refunds an open. Touched from NIOSSH's
/// initializer on the connection's EventLoop; lock-confined (the file's
/// counter idiom) so it can be captured across closure boundaries under
/// strict concurrency.
private final class SessionChannelBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?

    init(policy: LoopbackPasswordSSHServer.SessionChannelPolicy) {
        switch policy {
        case .unlimited:
            remaining = nil
        case .lifetimeTotal(let total):
            remaining = total
        }
    }

    /// Consumes one session-channel open; `false` when the connection's
    /// lifetime budget is exhausted.
    func consumeSessionOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let budget = remaining else { return true }
        guard budget > 0 else { return false }
        remaining = budget - 1
        return true
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
