import BicTermCore
import Foundation
import HerdrClientCore

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
    private(set) var selectedEndpointID: HerdrEndpointID?

    #if DEBUG
    /// Test surface only (unit/UI suites): semantic input events and gate
    /// notes in the order the model recorded them.
    var debugInputEcho: [String] = []
    /// Counts render-state applies so replay-driven UI tests can wait for
    /// exact script exhaustion instead of polling labels.
    private(set) var debugAppliedChunks = 0
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
    private let handshakeTimeout: Duration

    init(handshakeTimeout: Duration = .seconds(60)) {
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: - Connection

    func connect(endpoint id: HerdrEndpointID, transport: any HerdrByteTransport) {
        teardown(endpoint: id)

        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation

        var state = endpoints[id] ?? HerdrEndpointState()
        state.phase = .connecting
        state.generation = generation
        state.surface = nil
        state.surfaceUnavailable = false
        state.diagnostic = nil
        endpoints[id] = state
        selectedEndpointID = id

        let config = HerdrClientConfig(
            cols: state.desiredCols,
            rows: state.desiredRows,
            cellWidthPx: 8,
            cellHeightPx: 16
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
    /// `herdr_client_resize` on the ordered input lane.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        for id in endpoints.keys {
            endpoints[id]?.desiredCols = UInt32(cols)
            endpoints[id]?.desiredRows = UInt32(rows)
            guard let runtime = runtimes[id], let state = endpoints[id],
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
                try await client.receive(chunk)
                // The FFI queues activation/control frames mid-session (the
                // activation transaction after a snapshot, fence controls);
                // the single writer drains them in queue order.
                kick.yield(())

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
            await model?.remoteClosed(endpoint: id, generation: generation)
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
        if phase == .online {
            endpoints[id]?.phase = .online
            runtimes[id]?.watchdog?.cancel()
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
        generation: UInt
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
                diagnostic: .incompatibleGeneration(detail: Self.detail(of: error))
            )
        case .handshakeRejected:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .handshakeRejected(detail: Self.detail(of: error))
            )
        case .handshakeTimedOut, .handshakeExpectedWelcome:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(.handshakeTimedOut, detail: Self.detail(of: error))
            )
        case .protocolViolation:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(.protocolViolation, detail: Self.detail(of: error))
            )
        default:
            failAndTeardown(
                endpoint: id,
                generation: generation,
                diagnostic: .simple(.transportLost, detail: Self.detail(of: error))
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

    private func remoteClosed(endpoint id: HerdrEndpointID, generation: UInt) {
        guard isActive(endpoint: id, generation: generation) else { return }
        teardown(endpoint: id)
        endpoints[id]?.phase = .disconnected
        endpoints[id]?.diagnostic = .simple(.remoteClosed, detail: "remote bridge closed the session")
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

    private func teardown(endpoint id: HerdrEndpointID) {
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
    }

    static func detail(of error: HerdrClientError) -> String {
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
             .clientFailed(let detail):
            detail
        case .unknown(let code, let detail):
            "code \(code): \(detail)"
        }
    }
}
