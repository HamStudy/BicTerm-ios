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

    private let lifecycle: CoderSessionLifecycleDependencies?
    private let usageReporter: (any CoderUsageReporting)?

    private var phase: Phase = .idle
    private var tunnelHandle: Int?
    private var sshTransport: SSHTransport?
    private var lastCols = 0
    private var lastRows = 0
    private var serverID: UUID?
    private var usageScope: CoderUsageScope?
    private var credentialGenerationID: UInt64 = 0

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
        socketBaseDirectory: String,
        lifecycle: CoderSessionLifecycleDependencies? = nil
    ) {
        self.resolver = resolver
        self.tunnel = tunnel
        self.socketBaseDirectory = socketBaseDirectory
        self.lifecycle = lifecycle
        self.usageReporter = lifecycle?.makeUsageReporter()
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
        serverID = reference.serverID

        // Spec §4.3/§14.5: a generation marked authRequired refuses NEW
        // dials outright — already-established sessions are unaffected.
        if let generations = lifecycle?.generations {
            let generation = await generations.generation(for: reference.serverID)
            guard generation.state == .active else { throw .authRequired }
            credentialGenerationID = generation.id
        }

        let endpoint: CoderAgentEndpoint
        do {
            let selection = try CoderAgentSelection(options: connection.protocolOptions)
            endpoint = try await resolver.resolve(reference, selecting: selection)
        } catch let error as CoderResolutionError {
            let mapped = Self.transportError(error)
            if mapped == .authRequired {
                // A genuine primary REST 401 confirms the loss (spec §15 row
                // 2): mark the generation before surfacing the typed error.
                await lifecycle?.generations?.markAuthRequired(for: reference.serverID)
            }
            throw mapped
        }

        guard phase == .connecting, !Task.isCancelled else { throw .channelDenied }
        let handle: Int
        do {
            handle = try await tunnel.start(configJSON: CoderTunnelStartConfig.json(
                endpoint: endpoint,
                socketDir: socketBaseDirectory,
                credentialGeneration: credentialGenerationID
            ))
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

        // Spec §14.3: the heartbeat attaches with the real session.
        let scope = CoderUsageScope(
            serverURL: endpoint.serverURL,
            sessionToken: endpoint.sessionToken,
            workspaceID: reference.workspaceID,
            agentID: endpoint.agentID
        )
        usageScope = scope
        await usageReporter?.begin(scope)
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
        // Detach stops usage posting; the session itself roams on.
        await usageReporter?.end()
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
            if let usageScope { await usageReporter?.begin(usageScope) }
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
        if let usageScope { await usageReporter?.begin(usageScope) }
    }

    public func close() async {
        guard phase != .closed else { return }
        phase = .closed
        await usageReporter?.end()
        bridgeTask?.cancel()
        bridgeTask = nil
        if let sshTransport {
            self.sshTransport = nil
            await sshTransport.close()
        }
        if let handle = tunnelHandle {
            tunnelHandle = nil
            tunnel.close(handle: handle)
            await lifecycle?.reporting?.unregister(handle: handle)
        }
        outputContinuation.finish()
    }

    // MARK: - Private

    /// The `SessionSceneAttachable` seam: ships the live handle's
    /// registration to the lifecycle coordinator. No-op pre-connect.
    func registerWithLifecycle(sceneID: String) async {
        guard let handle = tunnelHandle, let serverID else { return }
        await lifecycle?.reporting?.register(CoderSessionRegistration(
            handle: handle,
            sceneID: sceneID,
            serverID: serverID,
            credentialGenerationID: credentialGenerationID,
            usageReporter: usageReporter
        ))
    }

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

    private static func transportError(_ error: CoderResolutionError) -> TransportError {
        switch error {
        case .tokenMissing, .unauthorized:
            .authRequired
        case .serverUnreachable:
            .unreachable
        case .agentStartupFailed(let state):
            .remoteStartupFailed(state: state)
        case .serverUnknown, .workspaceMissing, .workspaceNotRunning, .agentUnavailable:
            .reconnectRequired
        }
    }
}
