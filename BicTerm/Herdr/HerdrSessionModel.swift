import BicTermCore
import Foundation
import HerdrClientCore

/// Lock-confined one-shot slot for the bounded termination wait.
final class TerminationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HerdrTransportTermination?

    func set(_ value: HerdrTransportTermination) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> HerdrTransportTermination? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}


/// Per-scene herdr coordinator (integration doc §3.5): one endpoint runtime
/// per saved SSH target + session, machine-qualified published state above
/// them, and a single selected endpoint whose surface feeds this scene.
///
/// T16 drives exactly one endpoint; the dictionary-shaped state and the
/// routing keys are the multi-machine structure T17/T19 expand into
/// (endpoint catalog, activation transactions, per-machine supervision).
///
/// Threading: network decode and snapshot/surface JSON decoding run on the
/// ``HerdrClient`` actor and its detached feeding task (off the main
/// actor); only immutable published values hop to the main actor
/// (integration doc §3.2). FFI clients are released either by explicit
/// teardown or by ``HerdrClient``'s own deinit destroy — exactly once.
@MainActor
@Observable
final class HerdrSessionModel {
    var endpoints: [HerdrEndpointID: HerdrEndpointState] = [:]
    var selectedEndpointID: HerdrEndpointID?

    #if DEBUG
    /// Test surface only (unit/UI suites): semantic input events and gate
    /// notes in the order the model recorded them.
    var debugInputEcho: [String] = []
    /// Counts render-state applies so replay-driven UI tests can wait for
    /// exact script exhaustion instead of polling labels.
    private(set) var debugAppliedChunks = 0
    /// Test surface only (unit/UI suites): lifecycle transitions in order
    /// (detach, background close, reconnect attempts) for assertions.
    var debugLifecycleLog: [String] = []
    #endif

    struct Runtime {
        let client: HerdrClient
        let transport: any HerdrByteTransport
        let generation: UInt
        let inputContinuation: AsyncStream<HerdrInputEvent>.Continuation
        let kickContinuation: AsyncStream<Void>.Continuation
        var inboundTask: Task<Void, Never>?
        var inputTask: Task<Void, Never>?
        var writerTask: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
    }

    var runtimes: [HerdrEndpointID: Runtime] = [:]
    private var generations: [HerdrEndpointID: UInt] = [:]
    /// Transport factory per endpoint for re-attach/foreground reconnects
    /// (doc §6.3): nil for endpoints with no live source (unit fixtures
    /// without one); the factory is the ONLY way a reconnect transport
    /// comes into existence.
    var reconnectSources: [HerdrEndpointID: HerdrReconnectSource] = [:]
    /// Running reconnect loops; presence is the "no retry storm" latch.
    var reconnectTasks: [HerdrEndpointID: Task<Void, Never>] = [:]
    /// Aggregate reconnect budget (herdr-support T10): at most this many
    /// reconnect loops run concurrently across EVERY endpoint in the model.
    /// The value reuses the T19 per-endpoint attempt budget
    /// (`HerdrReconnectBackoff.standard.maxAttempts`) as the model-wide
    /// cap, so a herd of N machines shares one budget of 4 — each machine
    /// effectively gets budget/N — and a foreground recovery or N-machine
    /// failure fans out at most 4 concurrent transport establishments no
    /// matter how large N grows. Endpoints beyond the cap queue FIFO in
    /// `pendingReconnects` and start as loops settle.
    let aggregateReconnectBudget: Int
    /// Endpoints waiting for a free aggregate-budget slot, oldest first.
    var pendingReconnects: [HerdrEndpointID] = []
    /// Bumped on every loop start/cancel so a finished loop never clears a
    /// successor's task slot.
    var reconnectEpochs: [HerdrEndpointID: UInt] = [:]
    /// Endpoints the background policy detached and foreground must
    /// reconnect (doc §10 step 4).
    var awaitingForegroundReconnect: Set<HerdrEndpointID> = []
    /// Scene-inactive input suspension (doc §10 step 1).
    var sceneInputSuspended = false
    let reconnectBackoff: HerdrReconnectBackoff
    /// Retained-surface cache bound (herdr-support T10, T20 audit pattern):
    /// a detached endpoint keeps its last committed snapshot+surface for
    /// the dimmed machine view, but at most this many endpoints retain
    /// caches at once (the `TerminalViewCache` cap-8 precedent). Endpoints
    /// with a live runtime and the selected endpoint are never evicted;
    /// beyond the cap the least-recently-committed retained cache drops —
    /// the machine chip keeps its honest phase and diagnostic, only the
    /// stale pixels go.
    static let maxRetainedSurfaceCaches = 8
    /// Monotonic commit clock for the retained-cache LRU.
    private var surfaceCommitClock: UInt = 0
    /// Last commit tick per endpoint holding a surface/snapshot cache.
    var surfaceCommittedAt: [HerdrEndpointID: UInt] = [:]
    private var lastOnlineLoggedGeneration: [HerdrEndpointID: UInt] = [:]
    private let handshakeTimeout: Duration
    let clipboardSettings: HerdrClipboardSettings
    /// How long the remote-clipboard banner stays up without a copy or
    /// dismiss gesture before the pending bytes are dropped. Injectable
    /// for tests.
    let remoteClipboardBannerDuration: Duration
    /// How long a transient input note stays on the feedback strip before
    /// auto-clearing. Injectable for tests.
    let inputNoteDuration: Duration

    init(
        handshakeTimeout: Duration = .seconds(60),
        clipboardSettings: HerdrClipboardSettings = HerdrClipboardSettings(),
        reconnectBackoff: HerdrReconnectBackoff = .standard,
        remoteClipboardBannerDuration: Duration = .seconds(10),
        inputNoteDuration: Duration = .seconds(8),
        aggregateReconnectBudget: Int = HerdrReconnectBackoff.standard.maxAttempts
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.clipboardSettings = clipboardSettings
        self.reconnectBackoff = reconnectBackoff
        self.remoteClipboardBannerDuration = remoteClipboardBannerDuration
        self.inputNoteDuration = inputNoteDuration
        self.aggregateReconnectBudget = max(1, aggregateReconnectBudget)
    }

    // MARK: - Connection

    func connect(
        endpoint id: HerdrEndpointID,
        transport: any HerdrByteTransport,
        reconnectSource: HerdrReconnectSource? = nil
    ) {
        teardown(endpoint: id)

        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        if let reconnectSource {
            reconnectSources[id] = reconnectSource
        } else {
            reconnectSources.removeValue(forKey: id)
        }

        var state = endpoints[id] ?? HerdrEndpointState()
        state.phase = .connecting
        state.generation = generation
        state.surface = nil
        state.surfaceUnavailable = false
        state.diagnostic = nil
        state.probe = nil
        state.reconnectAttempt = nil
        // Fresh connection, fresh authoritative state (spec hard rule): a
        // pane override chosen on a previous connection generation must not
        // leak into the snapshot-driven target of this one.
        state.inputTargetOverride = nil
        state.inputNote = nil
        endpoints[id] = state
        selectedEndpointID = id

        // Cell px stays the canonical 8x16 the protocol goldens encode:
        // the server lays panes out by cols/rows (the surface view's
        // font-derived resize drives those), while wire cell px only feeds
        // remote pixel reporting this client never consumes.
        let config = HerdrClientConfig(
            cols: state.desiredCols,
            rows: state.desiredRows,
            cellWidthPx: 8,
            cellHeightPx: 16,
            // A max-size clipboard image (16 MiB) plus envelope must fit the
            // outbound queue; the FFI default budget (4 MiB) would reject it.
            outboundByteLimit: 24 * 1024 * 1024
        )
        let client: HerdrClient
        do {
            client = try HerdrClient(config: config)
        } catch let error as HerdrClientError {
            fail(
                endpoint: id,
                diagnostic: .simple(.transportLost, detail: Self.detail(of: error))
            )
            Task {
                await transport.close()
            }
            return
        }

        let (inputStream, inputContinuation) = AsyncStream<HerdrInputEvent>.makeStream()
        let (kickStream, kickContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var runtime = Runtime(
            client: client,
            transport: transport,
            generation: generation,
            inputContinuation: inputContinuation,
            kickContinuation: kickContinuation
        )
        let timeout = handshakeTimeout
        runtime.watchdog = Task { [weak self, id, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.handshakeTimedOut(endpoint: id)
        }
        runtime.inboundTask = Task.detached(priority: .userInitiated) { [weak self, client, transport, id, generation, kickContinuation] in
            await HerdrSessionModel.runInboundPump(
                model: self,
                client: client,
                transport: transport,
                endpoint: id,
                generation: generation,
                kick: kickContinuation
            )
        }
        runtime.inputTask = Task.detached(priority: .userInitiated) { [weak self, client, id, generation, inputStream, kickContinuation] in
            await HerdrSessionModel.runInputLane(
                model: self,
                client: client,
                endpoint: id,
                generation: generation,
                events: inputStream,
                kick: kickContinuation
            )
        }
        runtime.writerTask = Task.detached(priority: .userInitiated) { [weak self, client, transport, id, generation, kickStream] in
            await HerdrSessionModel.runWriter(
                model: self,
                client: client,
                transport: transport,
                endpoint: id,
                generation: generation,
                kicks: kickStream
            )
        }
        runtimes[id] = runtime
        kickContinuation.yield(())
    }

    func disconnect(endpoint id: HerdrEndpointID) async {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        pendingReconnects.removeAll { $0 == id }
        runtime.inboundTask?.cancel()
        runtime.inputTask?.cancel()
        runtime.writerTask?.cancel()
        runtime.watchdog?.cancel()
        runtime.inputContinuation.finish()
        runtime.kickContinuation.finish()
        runtime.client.destroy()
        await runtime.transport.close()
        if endpoints[id]?.phase == .connecting || endpoints[id]?.phase == .online {
            endpoints[id]?.phase = .disconnected
        }
    }

    func disconnectAll() async {
        for id in Array(runtimes.keys) {
            await disconnect(endpoint: id)
        }
    }

    /// Records the scene's desired grid geometry (machine-qualified per
    /// endpoint). Before a surface commits it is only carried by the NEXT
    /// connection's hello — mid-activation resizes would restart fence
    /// evidence, so the committed fence geometry wins. Once online with a
    /// committed surface it also routes through the FFI's live
    /// `herdr_client_resize` on the ordered input lane — but only for an
    /// endpoint whose grid actually changed: SwiftUI layout passes can
    /// re-report identical geometry, and a repeated no-op resize must not
    /// restart a fence cycle.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        for id in endpoints.keys {
            guard let state = endpoints[id] else { continue }
            let changed = state.desiredCols != UInt32(cols) || state.desiredRows != UInt32(rows)
            endpoints[id]?.desiredCols = UInt32(cols)
            endpoints[id]?.desiredRows = UInt32(rows)
            guard changed, let runtime = runtimes[id],
                  state.phase == .online, state.surface != nil else { continue }
            runtime.inputContinuation.yield(.resize(cols: UInt32(cols), rows: UInt32(rows)))
        }
    }

    // MARK: - Machine-qualified identity

    func paneRoutingKeys(for endpoint: HerdrEndpointID) -> [HerdrPaneRoutingKey] {
        guard let state = endpoints[endpoint], let snapshot = state.snapshot else { return [] }
        return snapshot.panes.map { pane in
            HerdrPaneRoutingKey(
                endpoint: endpoint,
                generation: state.generation,
                bootID: snapshot.bootID,
                paneID: pane.paneID
            )
        }
    }

    static func paneRoutingKey(
        paneID: String,
        endpoint: HerdrEndpointID,
        generation: UInt,
        bootID: String
    ) -> HerdrPaneRoutingKey {
        HerdrPaneRoutingKey(
            endpoint: endpoint,
            generation: generation,
            bootID: bootID,
            paneID: paneID
        )
    }

    // MARK: - Inbound pump (nonisolated: decode off the main actor)

    private static func runInboundPump(
        model: HerdrSessionModel?,
        client: HerdrClient,
        transport: any HerdrByteTransport,
        endpoint id: HerdrEndpointID,
        generation: UInt,
        kick: AsyncStream<Void>.Continuation
    ) async {
        var lastSnapshotRevision: UInt64?
        var lastSurfaceRevision: UInt64?
        do {
            for try await chunk in transport.inboundBytes() {
                do {
                    try await client.receive(chunk)
                } catch {
                    // A dropped OSC 52 clipboard frame surfaces through
                    // receive but is non-fatal: note it and keep decoding.
                    // (Not rethrown: the typed catch + rethrow inside this
                    // async loop trips a swift-frontend ownership crash.)
                    if case .clipboardDropped(let detail) = error {
                        await model?.noteClipboardDropped(
                            endpoint: id, generation: generation, detail: detail
                        )
                        continue
                    }
                    await model?.handleClientError(
                        error,
                        endpoint: id,
                        generation: generation,
                        context: Self.decodeBoundaryContext(chunk)
                    )
                    return
                }
                // The FFI queues activation/control frames mid-session (the
                // activation transaction after a snapshot, fence controls);
                // the single writer drains them in queue order.
                kick.yield(())

                if let clipboard = try await client.takeClipboard() {
                    await model?.remoteClipboardArrived(
                        endpoint: id, generation: generation, data: clipboard
                    )
                }

                let phase = await client.phase
                let snapshot = try? await client.snapshot()
                let surfaceData = try? await client.surfaceJSON()
                let surface = surfaceData.flatMap {
                    try? JSONDecoder().decode(HerdrPaneSurface.self, from: $0)
                }

                var freshSnapshot: HerdrShellSnapshot?
                if let snapshot, snapshot.revision != lastSnapshotRevision {
                    lastSnapshotRevision = snapshot.revision
                    freshSnapshot = snapshot
                }
                var freshSurface: HerdrPaneSurface?
                if let surface, surface.surfaceRevision != lastSurfaceRevision {
                    lastSurfaceRevision = surface.surfaceRevision
                    freshSurface = surface
                }
                if freshSnapshot != nil || freshSurface != nil || phase == .online {
                    await model?.applyRenderState(
                        endpoint: id,
                        generation: generation,
                        phase: phase,
                        snapshot: freshSnapshot,
                        surface: freshSurface
                    )
                }
            }
            let termination = await Self.termination(of: transport)
            await model?.remoteClosed(endpoint: id, generation: generation, termination: termination)
        } catch let error as HerdrClientError {
            await model?.handleClientError(error, endpoint: id, generation: generation)
        } catch {
            await model?.failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(.transportLost, detail: "\(error)")
            )
        }
    }

    private func applyRenderState(
        endpoint id: HerdrEndpointID,
        generation: UInt,
        phase: HerdrPhase,
        snapshot: HerdrShellSnapshot?,
        surface: HerdrPaneSurface?
    ) {
        guard isActive(endpoint: id, generation: generation) else { return }
        #if DEBUG
        debugAppliedChunks += 1
        #endif
        if let snapshot {
            endpoints[id]?.snapshot = snapshot
        }
        if let surface {
            endpoints[id]?.surface = surface
        }
        if snapshot != nil || surface != nil {
            surfaceCommitClock &+= 1
            surfaceCommittedAt[id] = surfaceCommitClock
        }
        if phase == .online {
            endpoints[id]?.phase = .online
            runtimes[id]?.watchdog?.cancel()
            #if DEBUG
            if lastOnlineLoggedGeneration[id] != generation {
                lastOnlineLoggedGeneration[id] = generation
                debugLifecycleLog.append(
                    "online:\(id.rawValue):gen:\(generation):rev:\(endpoints[id]?.snapshot?.revision ?? 0)"
                )
            }
            #endif
        }
    }

    // MARK: - Outbound writer (nonisolated: single drain/write lane)

    /// The only drainer of the client's outbound queue and the only writer
    /// to the transport: connect-time hellos, activation frames the core
    /// queues mid-session, and semantic input frames all reach the wire in
    /// queue FIFO order (integration doc §3.2). Kicks coalesce via
    /// `.bufferingNewest(1)`; every drain empties the queue.
    private static func runWriter(
        model: HerdrSessionModel?,
        client: HerdrClient,
        transport: any HerdrByteTransport,
        endpoint id: HerdrEndpointID,
        generation: UInt,
        kicks: AsyncStream<Void>
    ) async {
        do {
            for await _ in kicks {
                for frame in try await client.drainOutbound() {
                    try await transport.write(frame)
                }
            }
        } catch let error as HerdrClientError {
            await model?.handleClientError(error, endpoint: id, generation: generation)
        } catch {
            await model?.failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(.transportLost, detail: "\(error)")
            )
        }
    }

    // MARK: - Typed failure handling

    private func handleClientError(
        _ error: HerdrClientError,
        endpoint id: HerdrEndpointID,
        generation: UInt,
        context: String? = nil
    ) {
        switch error {
        case .surfaceRejected:
            // A surface that does not belong to the active endpoint lease
            // (stale evidence, revision conflict, wrong boot — doc §7
            // coherence checks). The Rust core drops the frame whole —
            // never half-applied — and the client stays Online, so the
            // session continues with the last committed surface.
            guard isActive(endpoint: id, generation: generation) else { return }
            endpoints[id]?.surfaceUnavailable = true
        case .handshakeIncompatible, .handshakeInvalidWelcome:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .incompatibleGeneration(
                    detail: Self.detail(of: error, context: context)
                )
            )
        case .handshakeRejected:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .handshakeRejected(detail: Self.detail(of: error, context: context))
            )
        case .handshakeTimedOut, .handshakeExpectedWelcome:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(
                    .handshakeTimedOut, detail: Self.detail(of: error, context: context)
                )
            )
        case .protocolViolation:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(
                    .protocolViolation, detail: Self.detail(of: error, context: context)
                )
            )
        default:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(
                    .transportLost, detail: Self.detail(of: error, context: context)
                )
            )
        }
    }

    private func handshakeTimedOut(endpoint id: HerdrEndpointID) async {
        guard let runtime = runtimes[id] else { return }
        let phase = await runtime.client.phase
        guard phase != .online else { return }
        failAndTeardown(
            endpoint: id,
            generation: runtime.generation,
            diagnostic: .simple(
                .handshakeTimedOut,
                detail: "no endpoint welcome within \(handshakeTimeout.components.seconds)s"
            )
        )
    }

    private func remoteClosed(
        endpoint id: HerdrEndpointID,
        generation: UInt,
        termination: HerdrTransportTermination
    ) {
        guard isActive(endpoint: id, generation: generation) else { return }
        teardown(endpoint: id)
        // Doc §6.3 taxonomy, split by the only signal that distinguishes
        // them: a clean EOF (exit 0) is a session end; a non-zero exit is
        // the remote bridge dying under us; a status-less channel death is
        // a network loss.
        let diagnostic: HerdrDiagnostic
        switch termination {
        case .exited(let status) where status != 0:
            diagnostic = .simple(
                .serverShutdown,
                detail: "remote bridge exited with status \(status)"
            )
        case .failed:
            diagnostic = .simple(
                .transportLost,
                detail: "channel died without a remote exit status"
            )
        case .exited, .unknown, .closedLocally:
            diagnostic = .simple(.remoteClosed, detail: "remote bridge closed the session")
        }
        endpoints[id]?.phase = .disconnected
        endpoints[id]?.diagnostic = diagnostic
        #if DEBUG
        debugLifecycleLog.append("closed:\(id.rawValue):\(diagnostic.kind)")
        #endif
    }

    private func fail(endpoint: HerdrEndpointID, diagnostic: HerdrDiagnostic) {
        endpoints[endpoint]?.diagnostic = diagnostic
        endpoints[endpoint]?.phase = .failed
    }

    private func failAndTeardown(endpoint id: HerdrEndpointID, generation: UInt, diagnostic: HerdrDiagnostic) {
        guard isActive(endpoint: id, generation: generation) else { return }
        teardown(endpoint: id)
        fail(endpoint: id, diagnostic: diagnostic)
    }

    // MARK: - Runtime lifecycle

    func isActive(endpoint id: HerdrEndpointID, generation: UInt) -> Bool {
        runtimes[id]?.generation == generation
    }

    func teardown(endpoint id: HerdrEndpointID) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        runtime.inboundTask?.cancel()
        runtime.inputTask?.cancel()
        runtime.writerTask?.cancel()
        runtime.watchdog?.cancel()
        runtime.inputContinuation.finish()
        runtime.kickContinuation.finish()
        runtime.client.destroy()
        let transport = runtime.transport
        Task {
            await transport.close()
        }
        trimRetainedSurfaceCaches()
    }

    /// Enforces `maxRetainedSurfaceCaches`: endpoints without a live
    /// runtime that still hold a snapshot/surface keep them oldest-first
    /// only up to the bound (the selected endpoint's cache is protected —
    /// it is the dimmed view on screen). Eviction drops the stale pixels,
    /// never the phase or diagnostic.
    func trimRetainedSurfaceCaches() {
        let retained = surfaceCommittedAt.keys.filter { id in
            runtimes[id] == nil
                && (endpoints[id]?.surface != nil || endpoints[id]?.snapshot != nil)
        }
        guard retained.count > Self.maxRetainedSurfaceCaches else { return }
        let evictable = retained
            .filter { $0 != selectedEndpointID }
            .sorted { (surfaceCommittedAt[$0] ?? 0) < (surfaceCommittedAt[$1] ?? 0) }
        guard !evictable.isEmpty else { return }
        for id in evictable.prefix(retained.count - Self.maxRetainedSurfaceCaches) {
            endpoints[id]?.surface = nil
            endpoints[id]?.snapshot = nil
            surfaceCommittedAt.removeValue(forKey: id)
        }
    }

    /// Bounded wait for the transport's remote-exit observation: the status
    /// normally arrives with the channel end, but a wedged conformer must
    /// not pin the pump — after the bound the end is treated as `.unknown`
    /// (clean-EOF taxonomy). Polling with an abandoned detached waiter is
    /// deliberate: a task-group race would deadlock at scope exit, because
    /// awaiting a non-cancellable continuation ignores child cancellation.
    private static func termination(
        of transport: any HerdrByteTransport
    ) async -> HerdrTransportTermination {
        let box = TerminationBox()
        Task.detached { box.set(await transport.termination()) }
        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            if let value = box.get() { return value }
        }
        return .unknown
    }

    static func detail(of error: HerdrClientError, context: String? = nil) -> String {
        let base: String
        switch error {
        case .invalidArgument(let detail),
             .panic(let detail),
             .disconnected(let detail),
             .protocolViolation(let detail),
             .handshakeTimedOut(let detail),
             .handshakeExpectedWelcome(let detail),
             .handshakeInvalidWelcome(let detail),
             .handshakeIncompatible(let detail),
             .handshakeRejected(let detail),
             .notOnline(let detail),
             .inputFrozen(let detail),
             .inputStaleTarget(let detail),
             .inputWriteFailed(let detail),
             .surfaceRejected(let detail),
             .clientFailed(let detail),
             .clipboardDropped(let detail):
            base = detail
        case .unknown(let code, let detail):
            base = "code \(code): \(detail)"
        }
        guard let context else { return base }
        return "\(base) [\(context)]"
    }

    /// T14 defense in depth: when the decoder rejects a chunk, the
    /// diagnostic carries the protocol-core version plus a bounded hex
    /// head of the chunk at the failure boundary — enough to adjudicate
    /// foreign bytes on stdout (shell rc output) against server-side
    /// malformation from a field report. 32 bytes of wire framing only;
    /// the app never places key material in this stream.
    static func decodeBoundaryContext(_ chunk: Data) -> String {
        let head = chunk.prefix(32)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
        return "core \(HerdrClient.coreVersion); failing chunk head (32 B): \(head)"
    }
}
