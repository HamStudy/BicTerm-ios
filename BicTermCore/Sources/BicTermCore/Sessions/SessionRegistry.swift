import Foundation

/// Presentation metadata for the session switcher: whether a terminal
/// surface is attached, and whether a detached session received output the
/// user has not seen yet. Advisory only — no transport, lifecycle, or
/// reconnection behavior may depend on it.
public struct SessionPresentationState: Sendable, Equatable {
    public let isAttached: Bool
    public let hasUnseenOutput: Bool

    public init(isAttached: Bool, hasUnseenOutput: Bool) {
        self.isAttached = isAttached
        self.hasUnseenOutput = hasUnseenOutput
    }
}

/// Global actor owning every live terminal session. Single mutation
/// authority: scenes/UI read state and streams, never touch transports.
///
/// Reentrancy safety: every connect/reconnect/close bumps the session's
/// generation counter; async results arriving for a superseded generation
/// are discarded (the fresh transport is closed, state untouched). At most
/// one reconnect runs per session — concurrent callers coalesce onto the
/// in-flight attempt's shared result.
///
/// Drop detection: when the current transport's `output` stream finishes
/// while the session is `.active`, the session transitions to
/// `.disconnected` and a bounded auto-reconnect (per ``ReconnectPolicy``)
/// runs. `willTerminate` and explicit closes bump the generation BEFORE
/// closing, so those finishes are never misread as drops.
public actor SessionRegistry {
    private let transportFactory: any SessionTransportFactory
    private let snapshotStore: any SessionSnapshotStoreProtocol
    private let reconnectPolicy: ReconnectPolicy
    private var records: [String: SessionRecord] = [:]

    public init(
        transportFactory: any SessionTransportFactory,
        snapshotStore: any SessionSnapshotStoreProtocol,
        reconnectPolicy: ReconnectPolicy = .default
    ) {
        self.transportFactory = transportFactory
        self.snapshotStore = snapshotStore
        self.reconnectPolicy = reconnectPolicy
    }

    // MARK: - Starting and restoring

    public func startSession(
        sceneID: String,
        connection: Connection,
        cols: Int = 80,
        rows: Int = 24
    ) async throws(SessionRegistryError) {
        guard records[sceneID] == nil else { throw .sceneOccupied(sceneID: sceneID) }
        let record = SessionRecord(sceneID: sceneID, connection: connection, cols: cols, rows: rows)
        records[sceneID] = record
        setState(record, .connecting)
        let generation = nextGeneration(record)

        let transport: any SessionTransport
        do {
            transport = try transportFactory.makeTransport(for: connection)
        } catch let error {
            if isCurrent(record, generation: generation) {
                setState(record, .failed(.transport(error)))
            }
            throw .transport(error)
        }
        do {
            let result = await SessionTransportContext.$sceneID.withValue(sceneID) { () async -> Result<Void, TransportError> in
                do throws(TransportError) {
                    try await transport.connect(to: connection, cols: cols, rows: rows)
                    return .success(())
                } catch { return .failure(error) }
            }
            try result.get()
        } catch let error {
            if isCurrent(record, generation: generation) {
                setState(record, .failed(.transport(error)))
            } else {
                await transport.close()
            }
            throw .transport(error)
        }

        guard isCurrent(record, generation: generation) else {
            await transport.close()
            return
        }
        await adopt(record, transport: transport, generation: generation, replacedServerSession: false)
    }

    /// Registers a terminated-app session from its snapshot WITHOUT
    /// connecting (restoration always lands at `.suspended`, i.e.
    /// reconnect-required). Callers resolve the snapshot's `connectionID`
    /// to a `Connection` via the connection store.
    public func restore(
        sceneID: String,
        connection: Connection,
        cols: Int = 80,
        rows: Int = 24
    ) throws(SessionRegistryError) {
        guard records[sceneID] == nil else { throw .sceneOccupied(sceneID: sceneID) }
        let record = SessionRecord(sceneID: sceneID, connection: connection, cols: cols, rows: rows)
        records[sceneID] = record
        setState(record, .suspended)
    }

    public func restorableSnapshots() async throws(PersistenceError) -> [SessionSnapshot] {
        try await snapshotStore.loadSnapshots()
    }

    // MARK: - Reconnect

    /// Drives one reconnect attempt: fresh transport from the factory,
    /// fresh auth, replayed terminal size. Never reports `.active` until
    /// connect (handshake + auth + pty + shell) has fully completed.
    /// Concurrent calls coalesce onto the in-flight attempt's result.
    /// Valid from `.disconnected`, `.suspended`, and `.failed`.
    public func reconnect(sceneID: String) async throws(SessionRegistryError) {
        guard let record = records[sceneID] else { throw .noSession(sceneID: sceneID) }

        if record.reconnectInFlight {
            let result = await withCheckedContinuation { continuation in
                record.reconnectWaiters.append(continuation)
            }
            return try result.get()
        }

        switch record.state {
        case .disconnected, .suspended, .failed:
            break
        case .closed:
            throw .sessionClosed(sceneID: sceneID)
        case .connecting, .active, .reconnecting:
            throw .invalidTransition(sceneID: sceneID, state: record.state)
        }

        record.reconnectInFlight = true
        let generation = nextGeneration(record)
        setState(record, .reconnecting)

        let result: Result<Void, SessionRegistryError>
        do {
            try await performReconnect(record: record, generation: generation)
            result = .success(())
        } catch let error {
            result = .failure(error)
        }

        record.reconnectInFlight = false
        let waiters = record.reconnectWaiters
        record.reconnectWaiters = []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        return try result.get()
    }

    private func performReconnect(
        record: SessionRecord,
        generation: UInt64
    ) async throws(SessionRegistryError) {
        // Roaming transports survive suspension server-side with their
        // output stream (and its bridge task) intact: resume reattaches
        // the SAME instance without re-auth instead of building a fresh
        // transport.
        if let existing = record.transport, existing.resumeStrategy == .nativeRoaming {
            do {
                try await existing.resume()
            } catch let error {
                if isCurrent(record, generation: generation) {
                    setState(record, .failed(.transport(error)))
                }
                throw .transport(error)
            }
            guard isCurrent(record, generation: generation) else {
                await existing.close()
                return
            }
            setState(record, .active)
            try? await snapshotStore.deleteSnapshot(sceneID: record.sceneID)
            return
        }

        record.bridgeTask?.cancel()
        record.bridgeTask = nil
        if let old = record.transport {
            record.transport = nil
            await old.close()
        }

        let transport: any SessionTransport
        do {
            transport = try transportFactory.makeTransport(for: record.connection)
        } catch let error {
            if isCurrent(record, generation: generation) {
                setState(record, .failed(.transport(error)))
            }
            throw .transport(error)
        }
        do {
            let result = await SessionTransportContext.$sceneID.withValue(record.sceneID) { () async -> Result<Void, TransportError> in
                do throws(TransportError) {
                    try await transport.connect(to: record.connection, cols: record.cols, rows: record.rows)
                    return .success(())
                } catch { return .failure(error) }
            }
            try result.get()
        } catch let error {
            if isCurrent(record, generation: generation) {
                setState(record, .failed(.transport(error)))
            } else {
                await transport.close()
            }
            throw .transport(error)
        }

        guard isCurrent(record, generation: generation) else {
            await transport.close()
            return
        }
        await adopt(record, transport: transport, generation: generation, replacedServerSession: true)
    }

    /// Installs the fresh transport and bridges its output into the
    /// session's stable stream. The stale snapshot (if any) is dropped:
    /// the session is live again.
    ///
    /// - Parameter replacedServerSession: true when the adoption follows a
    ///   rehandshake (the remote shell/pty was replaced, so local VT state
    ///   is stale). Emits ``SessionSyncEvent/sessionReplaced`` and pokes a
    ///   remote redraw. False for a session's first transport; `.nativeRoaming`
    ///   resumes never re-adopt.
    private func adopt(
        _ record: SessionRecord,
        transport: any SessionTransport,
        generation: UInt64,
        replacedServerSession: Bool
    ) async {
        record.transport = transport
        record.remoteExited = false
        startBridge(record, transport: transport)
        installDropObserver(record, transport: transport)
        if let attachable = transport as? any SessionSceneAttachable {
            await attachable.sessionAttachedToScene(record.sceneID)
        }
        if replacedServerSession {
            record.isInboundSuspect = false
            emitSyncEvent(record, .sessionReplaced)
            pokeRedraw(record)
        }
        setState(record, .active)
        await sendStartupCommand(record)
        try? await snapshotStore.deleteSnapshot(sceneID: record.sceneID)
    }

    /// The connection's startup command (e.g. `tmux new-session -A -s main`)
    /// is terminal input for the fresh shell, so it must fire on EVERY adopt
    /// — first connect, manual reconnect, auto-reconnect-after-drop, and
    /// foreground resume all converge here — to reattach the persistent
    /// multiplexer session after a drop. Best-effort like ``pokeRedraw``: a
    /// failed send must never fail the establish. `.nativeRoaming` resumes
    /// return before ``adopt`` (their shell never died) and herdr carriers
    /// never reach this registry, so the command only ever runs on real
    /// terminal shells.
    private func sendStartupCommand(_ record: SessionRecord) async {
        guard let command = record.connection.startupCommand, !command.isEmpty,
              let transport = record.transport else { return }
        try? await transport.send(Data(command.utf8) + Data([0x0D]))
    }

    // MARK: - I/O

    public func send(sceneID: String, _ bytes: Data) async throws(SessionRegistryError) {
        guard let record = records[sceneID] else { throw .noSession(sceneID: sceneID) }
        guard record.state == .active, let transport = record.transport else {
            throw .invalidTransition(sceneID: sceneID, state: record.state)
        }
        do {
            try await transport.send(bytes)
        } catch let error {
            throw .transport(error)
        }
    }

    /// Fire-and-forget; the latest size is replayed on every reconnect.
    public func resize(sceneID: String, cols: Int, rows: Int) async {
        guard let record = records[sceneID] else { return }
        record.cols = cols
        record.rows = rows
        await record.transport?.resize(cols: cols, rows: rows)
    }

    // MARK: - Scene lifecycle hooks (T14 wires SwiftUI scene phases to these)

    /// Persists a reconnect-required snapshot, then suspends per the
    /// transport's ``ResumeStrategy``: `.rehandshake` transports are
    /// EAGERLY closed (socket survival across backgrounding is never
    /// assumed); `.nativeRoaming` transports are suspended and kept for
    /// an in-place resume without re-auth.
    public func didEnterBackground(sceneID: String) async {
        guard let record = records[sceneID], record.state != .closed else { return }
        guard !(record.remoteExited && record.state == .disconnected) else { return }
        try? await snapshotStore.save(SessionSnapshot(
            connectionID: record.connection.id,
            sceneID: sceneID,
            state: .reconnectRequired
        ))
        record.autoReconnectTask?.cancel()
        record.autoReconnectTask = nil
        _ = nextGeneration(record)
        setState(record, .suspended)
        if let transport = record.transport, transport.resumeStrategy == .nativeRoaming {
            // The bridge task and output stream stay alive across suspend.
            await transport.suspend()
        } else {
            record.bridgeTask?.cancel()
            record.bridgeTask = nil
            if let transport = record.transport {
                record.transport = nil
                await transport.close()
            }
        }
    }

    /// Reconnects suspended sessions; failures surface as `.failed` state
    /// rather than throwing (this is a fire-and-forget lifecycle hook).
    public func willEnterForeground(sceneID: String) async {
        guard let record = records[sceneID], record.state == .suspended else { return }
        try? await reconnect(sceneID: sceneID)
    }

    /// T10 (spec §14.4, reconnect the right layer): an out-of-band control
    /// event reported the SSH-level session ended while its backing
    /// coordination stays alive. Park the session at `.suspended` — the
    /// registry's reconnect-required state — keeping the roaming transport
    /// and output stream: a later `reconnect` resumes the same coordination
    /// and redials only the dead stream. Never replays a command, and only
    /// `.active` sessions transition (other states belong to their owners).
    public func markReconnectRequired(sceneID: String) async {
        guard let record = records[sceneID], record.state == .active else { return }
        setState(record, .suspended)
        if let transport = record.transport, transport.resumeStrategy == .nativeRoaming {
            await transport.suspend()
        }
    }

    /// Persists snapshots for all live sessions, then closes everything.
    /// NEVER reconnects — restored sessions come back as `.suspended`
    /// via ``restore(sceneID:connection:cols:rows:)``.
    public func willTerminate() async {
        let all = Array(records.values)
        for record in all {
            try? await snapshotStore.save(SessionSnapshot(
                connectionID: record.connection.id,
                sceneID: record.sceneID,
                state: .reconnectRequired
            ))
        }
        for record in all {
            await teardown(record)
        }
        records.removeAll()
    }

    // MARK: - Closing

    public func closeSession(sceneID: String) async {
        guard let record = records[sceneID] else { return }
        try? await snapshotStore.deleteSnapshot(sceneID: sceneID)
        await teardown(record)
        records[sceneID] = nil
    }

    private func teardown(_ record: SessionRecord) async {
        _ = nextGeneration(record)
        record.autoReconnectTask?.cancel()
        record.autoReconnectTask = nil
        record.bridgeTask?.cancel()
        record.bridgeTask = nil
        let transport = record.transport
        record.transport = nil
        setState(record, .closed)
        record.outputContinuation.finish()
        for continuation in record.stateContinuations.values {
            continuation.finish()
        }
        record.stateContinuations.removeAll()
        for continuation in record.syncContinuations.values {
            continuation.finish()
        }
        record.syncContinuations.removeAll()
        if let transport {
            await transport.close()
        }
    }

    // MARK: - Presentation state (session switcher)

    /// Marks the session as having a live terminal surface; clears any
    /// unseen-output flag. No-op for unknown sessions.
    public func attached(sceneID: String) async {
        guard let record = records[sceneID] else { return }
        record.isAttached = true
        record.hasUnseenOutput = false
    }

    /// Marks the session's surface as gone (window closed, cover
    /// dismissed, user switched to another session). The session itself
    /// keeps running. No-op for unknown sessions.
    public func detached(sceneID: String) async {
        records[sceneID]?.isAttached = false
    }

    public func presentationState(sceneID: String) -> SessionPresentationState? {
        guard let record = records[sceneID] else { return nil }
        return SessionPresentationState(
            isAttached: record.isAttached,
            hasUnseenOutput: record.hasUnseenOutput
        )
    }

    // MARK: - Observation

    public func state(sceneID: String) -> SessionState? {
        records[sceneID]?.state
    }

    /// Full transition sequence since session creation — deterministic
    /// even for subscribers that attach after transitions happened.
    public func stateHistory(sceneID: String) -> [SessionState] {
        records[sceneID]?.stateHistory ?? []
    }

    /// Replays the full history, then yields live transitions. Finishes
    /// when the session closes.
    public func states(sceneID: String) -> AsyncStream<SessionState>? {
        guard let record = records[sceneID] else { return nil }
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionState>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        record.stateContinuations[id] = continuation
        for state in record.stateHistory {
            continuation.yield(state)
        }
        return stream
    }

    /// The stable per-session output stream. It survives reconnects (the
    /// registry bridges each fresh transport's stream into it) and finishes
    /// only when the session closes. Single consumer: multiple iterators
    /// compete for bytes.
    public func output(sceneID: String) -> AsyncStream<Data>? {
        records[sceneID]?.outputStream
    }

    // MARK: - Drop detection bridge

    /// Bridges are guarded by TRANSPORT IDENTITY (not generation): a
    /// cancelled task's AsyncStream iterator does not reliably stop
    /// consuming, so a superseded bridge could still steal bytes — but a
    /// roaming transport's bridge legitimately survives suspend/resume.
    /// Identity distinguishes "still current" from "stale" in both cases.
    private func startBridge(
        _ record: SessionRecord,
        transport: any SessionTransport
    ) {
        record.bridgeTask = Task { [self] in
            let stream = await transport.output
            for await chunk in stream {
                await bridgeYield(chunk, for: record, transport: transport)
            }
            let reason = await transport.closeReason
            await bridgeFinished(for: record, transport: transport, reason: reason)
        }
    }

    private func bridgeYield(_ chunk: Data, for record: SessionRecord, transport: any SessionTransport) {
        guard isCurrentTransport(record, transport: transport) else { return }
        if case .dropped = record.outputContinuation.yield(chunk) {
            noteInboundDrop(record)
        }
        if !record.isAttached {
            record.hasUnseenOutput = true
        }
    }

    private func bridgeFinished(for record: SessionRecord, transport: any SessionTransport, reason: TransportCloseReason) {
        guard isCurrentTransport(record, transport: transport) else { return }
        guard record.state == .active else { return }
        record.remoteExited = reason == .remoteExit
        setState(record, .disconnected)
        if reason != .remoteExit {
            scheduleAutoReconnect(record)
        }
    }

    private func isCurrentTransport(_ record: SessionRecord, transport: any SessionTransport) -> Bool {
        records[record.sceneID] === record
            && record.state != .closed
            && record.transport === transport
    }

    // MARK: - Sync integrity (T12)

    /// Per-session sync-integrity events. Transient signals (no history
    /// replay): subscribers attach at scene start, and every event is
    /// also derivable from observable state for late attachers.
    public func syncEvents(sceneID: String) -> AsyncStream<SessionSyncEvent>? {
        guard let record = records[sceneID] else { return nil }
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionSyncEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        record.syncContinuations[id] = continuation
        return stream
    }

    /// Wires the transport's own bounded-overflow signal (if it has one)
    /// into this session's suspect flag. The observer hops back into the
    /// actor; transport identity is re-checked so a superseded
    /// transport's drop cannot flag the current session.
    private func installDropObserver(_ record: SessionRecord, transport: any SessionTransport) {
        guard let observable = transport as? any InboundDropObserving else { return }
        let sceneID = record.sceneID
        Task { [self] in
            await observable.setInboundDropObserver { [weak self] in
                guard let self else { return }
                Task { await self.transportReportedInboundDrop(sceneID: sceneID, transport: transport) }
            }
        }
    }

    private func transportReportedInboundDrop(sceneID: String, transport: any SessionTransport) {
        guard let record = records[sceneID] else { return }
        guard isCurrentTransport(record, transport: transport) else { return }
        noteInboundDrop(record)
    }

    /// A drop anywhere in the inbound chain marks the session's VT stream
    /// suspect and surfaces ``SessionSyncEvent/inboundDropped`` exactly
    /// once per suspicion window (re-armed by ``resync(sceneID:)`` or a
    /// session replacement).
    private func noteInboundDrop(_ record: SessionRecord) {
        guard !record.isInboundSuspect else { return }
        record.isInboundSuspect = true
        emitSyncEvent(record, .inboundDropped)
    }

    private func emitSyncEvent(_ record: SessionRecord, _ event: SessionSyncEvent) {
        for continuation in record.syncContinuations.values {
            continuation.yield(event)
        }
    }

    /// User-triggered resync: clears the suspect flag (the screen is
    /// about to be rebuilt) and pokes the remote into a full redraw.
    public func resync(sceneID: String) async {
        guard let record = records[sceneID], record.state != .closed else { return }
        record.isInboundSuspect = false
        pokeRedraw(record)
    }

    /// Forces a remote repaint: a same-size window-change does NOT
    /// SIGWINCH (the kernel compares sizes), so bounce the row count by
    /// one and back. Reading `record.cols`/`record.rows` again after the
    /// gap keeps a user resize during the bounce authoritative.
    private func pokeRedraw(_ record: SessionRecord) {
        Task { [self] in
            guard let transport = record.transport else { return }
            await transport.resize(cols: record.cols, rows: record.rows + 1)
            try? await Task.sleep(for: .milliseconds(120))
            guard records[record.sceneID] === record, record.transport === transport else { return }
            await transport.resize(cols: record.cols, rows: record.rows)
        }
    }

    // MARK: - Bounded auto-reconnect

    private func scheduleAutoReconnect(_ record: SessionRecord) {
        record.autoReconnectTask?.cancel()
        record.autoReconnectTask = Task { [self] in
            await runAutoReconnect(record)
        }
    }

    private func runAutoReconnect(_ record: SessionRecord) async {
        var lastError: SessionTransportError?
        var attempt = 0
        while attempt < reconnectPolicy.maxAttempts {
            attempt += 1
            if Task.isCancelled { return }
            guard autoReconnectShouldContinue(record) else { return }
            try? await Task.sleep(for: reconnectPolicy.delay(forAttempt: attempt))
            if Task.isCancelled { return }
            guard autoReconnectShouldContinue(record) else { return }
            do {
                try await reconnect(sceneID: record.sceneID)
                return
            } catch let SessionRegistryError.transport(error) {
                lastError = error
                if error == .authRequired {
                    // Spec §15: a genuine credential failure is terminal for
                    // the retry loop — retrying re-presents the same dead
                    // token. Park at `.failed` for the reauth flow instead.
                    failRetries(record, failure: .transport(error))
                    return
                }
            } catch {
                // noSession / sessionClosed / invalidTransition: another
                // path owns the session now — stop retrying.
                return
            }
        }
        failRetries(record, failure: .reconnectAttemptsExhausted(
            attempts: reconnectPolicy.maxAttempts,
            lastError: lastError ?? .unreachable
        ))
    }

    /// A retry loop that gave up (or hit an unretryable error) parks the
    /// session at `.failed` — unless another path already moved it out of
    /// retryable territory or the identical failure is already the state
    /// (performReconnect publishes `.failed` before rethrowing, so a second
    /// publication would duplicate stream events and history).
    private func failRetries(_ record: SessionRecord, failure: SessionFailure) {
        guard records[record.sceneID] === record else { return }
        guard record.state != .failed(failure) else { return }
        switch record.state {
        case .active, .suspended, .closed:
            return
        case .connecting, .reconnecting, .disconnected, .failed:
            setState(record, .failed(failure))
        }
    }

    /// Stops when the session left retryable territory: a manual reconnect
    /// may have made it `.active`, backgrounding `.suspended`, or a close
    /// removed/closed it.
    private func autoReconnectShouldContinue(_ record: SessionRecord) -> Bool {
        guard records[record.sceneID] === record else { return false }
        switch record.state {
        case .disconnected, .failed:
            return true
        case .connecting, .active, .reconnecting, .suspended, .closed:
            return false
        }
    }

    // MARK: - Shared helpers

    private func setState(_ record: SessionRecord, _ state: SessionState) {
        record.state = state
        record.stateHistory.append(state)
        for continuation in record.stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func nextGeneration(_ record: SessionRecord) -> UInt64 {
        record.generation &+= 1
        return record.generation
    }

    private func isCurrent(_ record: SessionRecord, generation: UInt64) -> Bool {
        records[record.sceneID] === record
            && record.generation == generation
            && record.state != .closed
    }
}

/// Mutable per-session state, touched only under `SessionRegistry`'s actor
/// isolation (bridge tasks reach it exclusively through actor hops).
final class SessionRecord: @unchecked Sendable {
    let sceneID: String
    var connection: Connection
    var cols: Int
    var rows: Int

    var state: SessionState = .connecting
    var stateHistory: [SessionState] = []
    var generation: UInt64 = 0

    var transport: (any SessionTransport)?
    var bridgeTask: Task<Void, Never>?
    var autoReconnectTask: Task<Void, Never>?

    var reconnectInFlight = false
    var remoteExited = false
    var reconnectWaiters: [CheckedContinuation<Result<Void, SessionRegistryError>, Never>] = []

    var isAttached = false
    var hasUnseenOutput = false
    var isInboundSuspect = false

    let outputStream: AsyncStream<Data>
    let outputContinuation: AsyncStream<Data>.Continuation
    var stateContinuations: [UUID: AsyncStream<SessionState>.Continuation] = [:]
    var syncContinuations: [UUID: AsyncStream<SessionSyncEvent>.Continuation] = [:]

    init(sceneID: String, connection: Connection, cols: Int, rows: Int) {
        self.sceneID = sceneID
        self.connection = connection
        self.cols = cols
        self.rows = rows
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.outputStream = stream
        self.outputContinuation = continuation
    }
}
