import BicTermCore
import Foundation
import HerdrClientCore

/// How a reconnecting endpoint builds its next transport (doc §6.3): the
/// factory is the app's live-session source. A thrown
/// ``HerdrReconnectSource/OpenError/authenticationLost`` stops the retry
/// loop immediately (attention state, never auto-retried); any other throw
/// is retried within the bounded backoff.
struct HerdrReconnectSource: Sendable {
    enum OpenError: Error {
        case authenticationLost
    }

    let makeTransport: @MainActor () throws -> any HerdrByteTransport
}

/// Reconnect pacing (doc §6.3: bounded exponential backoff with jitter, no
/// retry storms): at most `maxAttempts` transport-creation attempts; the
/// wait before attempt n (n >= 2) is `base * 2^(n-2)` capped at `cap`, plus
/// up to `jitter`.
struct HerdrReconnectBackoff: Sendable, Equatable {
    let maxAttempts: Int
    let base: Duration
    let cap: Duration
    let jitter: Duration

    static let standard = HerdrReconnectBackoff(
        maxAttempts: 4,
        base: .milliseconds(400),
        cap: .seconds(6),
        jitter: .milliseconds(250)
    )

    func delay(beforeAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        let shift = min(attempt - 2, 30)
        let scaled = min(Self.nanoseconds(of: base) << shift, Self.nanoseconds(of: cap))
        let jitterBound = max(1, Self.nanoseconds(of: jitter))
        return .nanoseconds(scaled + Int64.random(in: 0...jitterBound))
    }

    private static func nanoseconds(of duration: Duration) -> Int64 {
        duration.components.seconds * 1_000_000_000
            + duration.components.attoseconds / 1_000_000_000
    }
}

/// Why a local detach happened — a user detach offers an explicit
/// re-attach; the background policy's detach reconnects on foreground
/// (doc §10).
enum HerdrDetachReason: Sendable, Equatable {
    case user
    case sceneBackground
}

extension HerdrSessionModel {
    /// Clean local detach (doc §6.3/§10): the input lane closes first —
    /// input ordering can never be guaranteed past this point — then the
    /// write side half-closes (SSH EOF tells the server the client is
    /// done), the pump gets a bounded window to drain what the server
    /// flushes back, and the channel closes. The endpoint KEEPS its last
    /// authoritative snapshot for the dimmed detached view; nothing is
    /// replayed on re-attach.
    func detach(endpoint id: HerdrEndpointID, reason: HerdrDetachReason) async {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        #if DEBUG
        debugLifecycleLog.append("detach:\(reason == .user ? "user" : "background"):\(id.rawValue)")
        #endif
        if reason == .sceneBackground {
            awaitingForegroundReconnect.insert(id)
        }
        markDetached(endpoint: id)

        runtime.inputContinuation.finish()
        runtime.watchdog?.cancel()
        try? await runtime.transport.closeWrite()
        // Bounded drain window: a cooperative server EOFs right after our
        // EOF and its final bytes land on the (now inactive) pump; the fixed
        // bound is the safety net either way — a task-group race on the
        // pump's completion would deadlock, because awaiting a
        // non-cancellable stream ignores child cancellation.
        try? await Task.sleep(for: .seconds(1))
        runtime.inboundTask?.cancel()
        runtime.writerTask?.cancel()
        runtime.client.destroy()
        await runtime.transport.close()
        markDetached(endpoint: id)
        #if DEBUG
        debugLifecycleLog.append("detached:\(id.rawValue)")
        #endif
    }

    /// Scene resigns active (doc §10 step 1): interactive input stops
    /// immediately; nothing else changes yet.
    func sceneResignedActive() {
        sceneInputSuspended = true
    }

    func sceneBecameActive() {
        sceneInputSuspended = false
    }

    /// Scene entered background (doc §10 steps 2-3, running inside the
    /// host's granted background window): clean detach of every live
    /// endpoint.
    func suspendForSceneBackground() async {
        let ids = Array(runtimes.keys)
        for id in ids {
            await detach(endpoint: id, reason: .sceneBackground)
        }
    }

    /// Scene returned to foreground (doc §10 step 4): every endpoint the
    /// background policy detached reconnects — fresh hello, authoritative
    /// snapshot, never a replay of speculative input.
    func resumeFromSceneForeground() {
        let ids = awaitingForegroundReconnect
        awaitingForegroundReconnect.subtract(ids)
        for id in ids {
            reconnect(endpoint: id)
        }
    }

    /// Records a preflight probe outcome (doc §6.1/§11): a missing or
    /// incompatible herdr ends the connection attempt BEFORE any bridge
    /// opens, surfacing the probe diagnostic screen instead.
    func failProbe(endpoint id: HerdrEndpointID, result: HerdrProbe.Result) {
        teardown(endpoint: id)
        reconnectSources.removeValue(forKey: id)
        var state = endpoints[id] ?? HerdrEndpointState()
        state.phase = .failed
        state.probe = result
        state.diagnostic = nil
        state.reconnectAttempt = nil
        state.surface = nil
        endpoints[id] = state
        selectedEndpointID = id
        #if DEBUG
        debugLifecycleLog.append("probe:\(id.rawValue):compatible:\(result.isCompatible)")
        #endif
    }

    /// Starts the bounded reconnect loop for an endpoint with a live
    /// source. Idempotent while a loop is already running — no retry storms.
    func reconnect(endpoint id: HerdrEndpointID) {
        guard reconnectTasks[id] == nil else { return }
        guard let source = reconnectSources[id] else {
            endpoints[id]?.reconnectAttempt = nil
            return
        }
        endpoints[id]?.phase = .reconnecting
        endpoints[id]?.diagnostic = nil
        #if DEBUG
        debugLifecycleLog.append("reconnect:start:\(id.rawValue)")
        #endif
        reconnectEpochs[id, default: 0] += 1
        let epoch = reconnectEpochs[id] ?? 0
        reconnectTasks[id] = Task { [weak self] in
            await self?.runReconnectLoop(endpoint: id, source: source, attempt: 1)
            self?.finishReconnectTask(endpoint: id, epoch: epoch)
        }
    }

    /// Manual cancel of the visible reconnect state (doc §6.3): the loop
    /// stops, the endpoint stays detached with its retained snapshot.
    func cancelReconnect(endpoint id: HerdrEndpointID) {
        reconnectEpochs[id, default: 0] += 1
        reconnectTasks.removeValue(forKey: id)?.cancel()
        awaitingForegroundReconnect.remove(id)
        if endpoints[id]?.phase == .reconnecting {
            endpoints[id]?.phase = .disconnected
        }
        endpoints[id]?.reconnectAttempt = nil
        #if DEBUG
        debugLifecycleLog.append("reconnect:cancel:\(id.rawValue)")
        #endif
    }

    // MARK: - Internals

    private func markDetached(endpoint id: HerdrEndpointID) {
        endpoints[id]?.phase = .disconnected
        endpoints[id]?.diagnostic = .simple(
            .userDetach,
            detail: "local client detached; the remote workspace keeps running"
        )
    }

    /// Removes the finished loop's task slot only when no newer loop (or
    /// cancel) superseded it — a finished task must never clear a successor.
    private func finishReconnectTask(endpoint id: HerdrEndpointID, epoch: UInt) {
        guard reconnectEpochs[id] == epoch else { return }
        reconnectTasks.removeValue(forKey: id)
    }

    private func runReconnectLoop(
        endpoint id: HerdrEndpointID,
        source: HerdrReconnectSource,
        attempt: Int
    ) async {
        guard attempt <= reconnectBackoff.maxAttempts else {
            endpoints[id]?.phase = .failed
            endpoints[id]?.reconnectAttempt = nil
            endpoints[id]?.diagnostic = .simple(
                .transportLost,
                detail: "reconnect gave up after \(reconnectBackoff.maxAttempts) attempts"
            )
            #if DEBUG
            debugLifecycleLog.append("reconnect:exhausted:\(id.rawValue)")
            #endif
            return
        }
        endpoints[id]?.reconnectAttempt = attempt
        #if DEBUG
        debugLifecycleLog.append("reconnect:attempt:\(attempt):\(id.rawValue)")
        #endif
        do {
            let transport = try source.makeTransport()
            // Fresh client + fresh generation: the only frames the new
            // transport ever carries are the fresh hello and input the user
            // sends AFTER the new authoritative state arrives.
            connect(endpoint: id, transport: transport, reconnectSource: source)
            endpoints[id]?.reconnectAttempt = nil
            return
        } catch is HerdrReconnectSource.OpenError {
            endpoints[id]?.phase = .failed
            endpoints[id]?.reconnectAttempt = nil
            endpoints[id]?.diagnostic = .simple(
                .authLost,
                detail: "re-authentication is required before reconnecting"
            )
            #if DEBUG
            debugLifecycleLog.append("reconnect:auth-lost:\(id.rawValue)")
            #endif
            return
        } catch {
            // bounded backoff below
        }
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: reconnectBackoff.delay(beforeAttempt: attempt + 1))
        guard !Task.isCancelled else { return }
        await runReconnectLoop(endpoint: id, source: source, attempt: attempt + 1)
    }
}
