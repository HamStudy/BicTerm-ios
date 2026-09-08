import Foundation

/// ``TerminalTransport`` conformer for Coder workspace sessions: Go dial →
/// per-session unix-domain socket → NIOSSH (`none` auth, community-trust host
/// key), per spec §12.2/§14.
///
/// Ownership:
/// - ONE ``CoderTunneling`` session handle (dependency-injected so BicTermCore
///   never links the AGPL Go core) owns the authenticated tailnet
///   coordination. It is the access boundary (spec §10.5) AND the
///   native-roaming asset: it survives backgrounding while the app process
///   lives.
/// - ONE ``SSHTransport`` dials the socket path the bridge returned and
///   serves shell I/O. Its public output is bridged onto THIS transport's
///   persistent stream, which survives `suspend()`/`resume()` per the
///   `.nativeRoaming` contract (T11).
/// - Workspace/agent resolution rides ``CoderWorkspaceResolver``; the raw
///   session token crosses into the tunnel config exactly once, at
///   ``connect``, and is never logged.
///
/// Resume semantics (spec §14.4 — reconnect the right layer): `resume()`
/// rebinds the tailnet to the current network path, then re-dials ONLY when
/// the SSH-level stream died while suspended. The coordination — and with it
/// the client identity — is never re-authenticated.
public actor CoderTransport: TerminalTransport {
    private enum Phase: Sendable {
        case idle, connecting, connected, suspended, closed
    }

    public nonisolated var resumeStrategy: ResumeStrategy { .nativeRoaming }
    public private(set) var output: AsyncStream<Data>

    private let resolver: CoderWorkspaceResolver
    private let tunnel: any CoderTunneling
    private let socketBaseDirectory: String
    private let outputContinuation: AsyncStream<Data>.Continuation

    private var phase: Phase = .idle
    private var tunnelHandle: Int?
    private var sshTransport: SSHTransport?
    private var lastCols = 0
    private var lastRows = 0

    private var bridgeTask: Task<Void, Never>?
    private var bridgeGeneration: UInt64 = 0

    /// Set by the output bridge when the SSH-level stream ends on its own —
    /// the remote-drop detector the registry keys on, and (under
    /// suspension) the signal that tells `resume()` to redial.
    private var sessionDied = false

    internal private(set) var sessionEstablishments = 0
    internal private(set) var tunnelSessionStarts = 0
    internal private(set) var resumeCallCount = 0

    /// `socketBaseDirectory` is where the bridge binds its per-session
    /// socket: ALWAYS a short, caller-controlled directory because Darwin's
    /// `sockaddr_un.sun_path` holds only 104 bytes and container tmp
    /// prefixes blow past it (Docs/SECURITY.md).
    public init(
        resolver: CoderWorkspaceResolver,
        tunnel: any CoderTunneling,
        socketBaseDirectory: String
    ) {
        self.resolver = resolver
        self.tunnel = tunnel
        self.socketBaseDirectory = socketBaseDirectory
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.output = stream
        self.outputContinuation = continuation
    }

    /// Test/suite seam: whether the SSH-level stream died while suspended.
    internal var diedWhileSuspended: Bool {
        sessionDied && phase == .suspended
    }

    public func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        guard phase == .idle else { throw .channelDenied }
        guard connection.type == .coder else {
            throw .protocolUnavailable(protocolID: connection.type.rawValue)
        }
        guard let reference = connection.coderRef else { throw .reconnectRequired }
        phase = .connecting
        defer {
            if phase == .connecting { phase = .idle }
        }

        let endpoint: CoderAgentEndpoint
        do {
            endpoint = try await resolver.resolve(reference)
        } catch let error as CoderResolutionError {
            throw Self.transportError(error)
        }

        let handle: Int
        do {
            handle = try await tunnel.start(configJSON: startConfigJSON(for: endpoint))
        } catch is CoderTunnelError {
            throw .unreachable
        }
        tunnelSessionStarts += 1
        guard let socketPath = try await dialForSession(handle: handle) else {
            throw .unreachable
        }
        let ssh = SSHTransport(hostKeyVerifier: .coderTunnel())
        do {
            try await ssh.connect(unixSocketPath: socketPath, cols: cols, rows: rows)
        } catch let error as TransportError {
            tunnel.close(handle: handle)
            throw error
        }
        sessionEstablishments += 1

        tunnelHandle = handle
        sshTransport = ssh
        lastCols = cols
        lastRows = rows
        startBridge(over: ssh)
        phase = .connected
    }

    public func send(_ bytes: Data) async throws(TransportError) {
        guard phase == .connected, let sshTransport else { throw .channelDenied }
        try await sshTransport.send(bytes)
    }

    public func resize(cols: Int, rows: Int) async {
        await sshTransport?.resize(cols: cols, rows: rows)
    }

    /// The exec seam for later tasks: the live session channel's raw handle.
    /// Throws typed ``TransportError/channelDenied`` outside an established
    /// connection.
    public func sessionChannelHandle() async throws(TransportError) -> SSHChannelHandle {
        guard phase == .connected, let sshTransport else { throw .channelDenied }
        return try await sshTransport.sessionChannelHandle()
    }

    /// `.nativeRoaming` suspend: the coordination and the SSH stream are left
    /// running (the Go core keeps them while the process lives); only the
    /// phase flips. A remote drop during suspension is recorded for resume's
    /// redial decision rather than finishing the stream.
    public func suspend() async {
        guard phase == .connected else { return }
        phase = .suspended
    }

    public func resume() async throws(TransportError) {
        guard phase == .suspended, let sshTransport, let handle = tunnelHandle else {
            throw .channelDenied
        }
        resumeCallCount += 1
        tunnel.rebind(handle: handle)

        let channelAlive = (try? await sshTransport.sessionChannelHandle())?.isActive ?? false
        if channelAlive, !sessionDied {
            phase = .connected
            return
        }

        // §14.4: keep the authorization boundary, rebuild only the stream.
        guard let socketPath = try await redialForSession(handle: handle) else {
            throw .unreachable
        }
        do {
            try await sshTransport.connect(unixSocketPath: socketPath, cols: lastCols, rows: lastRows)
        } catch let error as TransportError {
            throw error
        }
        sessionEstablishments += 1
        sessionDied = false
        startBridge(over: sshTransport)
        phase = .connected
    }

    public func close() async {
        guard phase != .closed else { return }
        phase = .closed
        bridgeTask?.cancel()
        bridgeTask = nil
        if let sshTransport {
            self.sshTransport = nil
            await sshTransport.close()
        }
        if let handle = tunnelHandle {
            tunnelHandle = nil
            tunnel.close(handle: handle)
        }
        outputContinuation.finish()
    }

    // MARK: - Private

    /// A refused/empty dial MUST NOT leak the allocated Go-side session
    /// handle: start-acquired resources unwind in reverse order.
    private func dialForSession(handle: Int) async throws(TransportError) -> String? {
        do {
            let path = try await tunnel.dialSSH(handle: handle)
            guard !path.isEmpty else {
                tunnel.close(handle: handle)
                return nil
            }
            return path
        } catch is CoderTunnelError {
            tunnel.close(handle: handle)
            return nil
        }
    }

    /// Redial keeps the handle on failure (unlike the first dial): the
    /// coordination is still the session's live asset, only this stream
    /// attempt died.
    private func redialForSession(handle: Int) async throws(TransportError) -> String? {
        do {
            let path = try await tunnel.dialSSH(handle: handle)
            guard !path.isEmpty else { return nil }
            return path
        } catch is CoderTunnelError {
            return nil
        }
    }

    private func startBridge(over ssh: SSHTransport) {
        bridgeTask?.cancel()
        bridgeGeneration &+= 1
        let generation = bridgeGeneration
        bridgeTask = Task { [weak self, outputContinuation] in
            let inner = await ssh.output
            for await chunk in inner {
                outputContinuation.yield(chunk)
            }
            await self?.innerStreamFinished(generation: generation)
        }
    }

    /// A stale bridge (superseded by a resume redial) must never finish the
    /// stream of its successor — the same identity/generation discipline the
    /// session registry applies at its own boundary.
    private func innerStreamFinished(generation: UInt64) {
        guard generation == bridgeGeneration else { return }
        switch phase {
        case .connected:
            // Remote drop while in use: the registry reads a finished output
            // stream as a drop and drives its own reconnect policy.
            outputContinuation.finish()
            sessionDied = true
        case .suspended:
            sessionDied = true
        case .idle, .connecting, .closed:
            break
        }
    }

    private func startConfigJSON(for endpoint: CoderAgentEndpoint) -> String {
        struct StartConfig: Encodable {
            let serverURL: String
            let sessionToken: String
            let agentID: String
            let relayOnly: Bool
            let socketDir: String

            enum CodingKeys: String, CodingKey {
                case serverURL = "server_url"
                case sessionToken = "session_token"
                case agentID = "agent_id"
                case relayOnly = "relay_only"
                case socketDir = "socket_dir"
            }
        }
        let config = StartConfig(
            serverURL: endpoint.serverURL.absoluteString,
            sessionToken: endpoint.sessionToken,
            agentID: endpoint.agentID.uuidString.lowercased(),
            relayOnly: false,
            socketDir: socketBaseDirectory
        )
        // The type has no fallible members; encoding cannot fail.
        return String(decoding: (try? JSONEncoder().encode(config)) ?? Data(), as: UTF8.self)
    }

    private static func transportError(_ error: CoderResolutionError) -> TransportError {
        switch error {
        case .tokenMissing, .unauthorized:
            .authRequired
        case .serverUnreachable:
            .unreachable
        case .serverUnknown, .workspaceMissing, .workspaceNotRunning, .agentUnavailable:
            .reconnectRequired
        }
    }
}

/// Produces fresh ``CoderTransport`` instances for coder-typed connections.
/// The tunnel conformer arrives via closure so this module never names the
/// CoderTunnel framework; AppStore flavors simply never register the factory
/// and keep the registry's typed ``TransportError/protocolUnavailable``.
public struct CoderTransportFactory: TerminalTransportFactory {
    private let resolver: CoderWorkspaceResolver
    private let socketBaseDirectory: String
    private let makeTunnel: @Sendable () -> any CoderTunneling

    public init(
        resolver: CoderWorkspaceResolver,
        socketBaseDirectory: String,
        tunnelFactory: @escaping @Sendable () -> any CoderTunneling
    ) {
        self.resolver = resolver
        self.socketBaseDirectory = socketBaseDirectory
        self.makeTunnel = tunnelFactory
    }

    public func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        guard connection.type == .coder else {
            throw .protocolUnavailable(protocolID: connection.type.rawValue)
        }
        return CoderTransport(
            resolver: resolver,
            tunnel: makeTunnel(),
            socketBaseDirectory: socketBaseDirectory
        )
    }
}
