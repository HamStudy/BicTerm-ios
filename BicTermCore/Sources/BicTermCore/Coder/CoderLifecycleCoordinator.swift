import Foundation

/// One registered Coder session as the coordinator needs to see it: the
/// routing anchor (Go handle → registry scene, server) plus the handles the
/// coordinator acts on directly (usage reporting only — transport I/O stays
/// behind the registry/transport boundary).
public struct CoderSessionRegistration: Sendable {
    public let handle: Int
    public let sceneID: String
    public let serverID: UUID
    public let credentialGenerationID: UInt64
    public let usageReporter: (any CoderUsageReporting)?

    public init(
        handle: Int,
        sceneID: String,
        serverID: UUID,
        credentialGenerationID: UInt64,
        usageReporter: (any CoderUsageReporting)?
    ) {
        self.handle = handle
        self.sceneID = sceneID
        self.serverID = serverID
        self.credentialGenerationID = credentialGenerationID
        self.usageReporter = usageReporter
    }
}

/// What a ``CoderTransport`` reports to the lifecycle owner: registrations
/// let handle-tagged ``CoderNetEvent``s find their scene and their server.
public protocol CoderSessionReporting: Sendable {
    func register(_ registration: CoderSessionRegistration) async
    func unregister(handle: Int) async
}

/// Session-side counterpart of the spec §14 lifecycle map (spec §14.1–14.5,
/// §13 `ConnectionManager.Events()`): consumes classified ``CoderNetEvent``s
/// and drives the two boundaries the events name —
///
/// - `authRequired` (genuine primary 401 per ``CoderEventClassifier``): marks
///   the server's credential generation `AuthRequired` (spec §14.5 step 3).
///   The mark broadcast stops that server's usage heartbeats and notifies the
///   app, whose Reauthenticate flow (T19) owns replacement. Transient errors
///   and resume-token rejections never reach here.
/// - `sshClosed` (SSH-level EOF): parks the session at reconnect-required via
///   the registry (no command replay, spec §14.4).
///
/// Foreground/background itself stays on the registry's hooks
/// (`didEnterBackground`/`willEnterForeground`): backgrounding is a phase
/// flip for the roaming transport inside the ~5s system grace window, and
/// foreground resume is a rebind plus a redial ONLY when the SSH stream
/// died. This coordinator adds no parallel state machine — it routes events.
///
/// Handle-less events describe the core itself: without a routing anchor
/// they are intentionally not routed (a genuine unattributed REST 401
/// already surfaces at resolve/connect time through ``CoderTransport``'s
/// generation marking — never through this channel).
public actor CoderLifecycleCoordinator: CoderSessionReporting {
    public nonisolated let generations: CoderCredentialGenerations

    private let events: AsyncStream<CoderNetEvent>?
    private let onAuthLoss: @Sendable (UUID) async -> Void

    private var registry: SessionRegistry?
    private var routes: [Int: CoderSessionRegistration] = [:]
    private var consumers: [Task<Void, Never>] = []

    /// - Parameter events: handle-tagged event stream from the Go bridge (the
    ///   tagged-line contract in ``CoderNetEvent``). `nil` while no bridge
    ///   producer is installed: the coordinator then still funnels
    ///   connect-time generation marks to heartbeats and the app.
    public init(
        generations: CoderCredentialGenerations = CoderCredentialGenerations(),
        events: AsyncStream<CoderNetEvent>? = nil,
        onAuthLoss: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.generations = generations
        self.events = events
        self.onAuthLoss = onAuthLoss
    }

    /// Cycle-breaker for the composition root (registry → factory →
    /// coordinator → registry). First value wins; later calls are no-ops.
    public func attach(registry: SessionRegistry) {
        guard self.registry == nil else { return }
        self.registry = registry
    }

    /// Start consuming the event channel (when one was injected) and the
    /// generation-mark broadcast. Idempotent.
    public func start() {
        guard consumers.isEmpty else { return }
        if let events {
            consumers.append(Task { [weak self] in
                for await event in events {
                    await self?.route(event)
                }
            })
        }
        let losses = generations.authLosses
        consumers.append(Task { [weak self] in
            for await serverID in losses {
                await self?.generationMarked(serverID: serverID)
            }
        })
    }

    // MARK: - CoderSessionReporting

    public func register(_ registration: CoderSessionRegistration) {
        routes[registration.handle] = registration
    }

    public func unregister(handle: Int) {
        routes[handle] = nil
    }

    // MARK: - Routing

    private func route(_ event: CoderNetEvent) async {
        switch CoderEventClassifier.disposition(of: event) {
        case .consumeInternally:
            // §8.7/§15: coord recovery, path changes, resume refreshes and
            // transient errors move no session or credential state.
            return
        case .authRequired:
            guard let handle = event.handle, let route = routes[handle] else { return }
            // A generation marked after this session registered means the
            // credential was already replaced: an OLD handle's late auth
            // event must not condemn the replacement generation.
            let current = await generations.generation(for: route.serverID)
            guard current.id == route.credentialGenerationID else { return }
            await generations.markAuthRequired(for: route.serverID)
        case .sessionReconnectRequired:
            guard let handle = event.handle, let route = routes[handle] else { return }
            await registry?.markReconnectRequired(sceneID: route.sceneID)
        }
    }

    /// A generation mark (from either the event channel or a connect-time
    /// REST 401) stops that server's usage heartbeats through one funnel,
    /// then notifies the app exactly once per generation.
    private func generationMarked(serverID: UUID) async {
        for route in routes.values where route.serverID == serverID {
            await route.usageReporter?.end()
        }
        await onAuthLoss(serverID)
    }
}

extension CoderTransport: SessionSceneAttachable {
    /// The registry has anchored this session to a scene: register the live
    /// Go handle so handle-tagged events (authRequired, sshClosed) route
    /// back to this exact session. No-op without a live handle.
    public func sessionAttachedToScene(_ sceneID: String) async {
        await registerWithLifecycle(sceneID: sceneID)
    }
}
