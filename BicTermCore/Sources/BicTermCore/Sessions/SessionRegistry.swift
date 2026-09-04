import Foundation

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

        let transport = transportFactory.makeTransport()
        do {
            try await transport.connect(to: connection, cols: cols, rows: rows)
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
        await adopt(record, transport: transport, generation: generation)
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
        record.bridgeTask?.cancel()
        record.bridgeTask = nil
        if let old = record.transport {
            record.transport = nil
            await old.close()
        }

        let transport = transportFactory.makeTransport()
        do {
            try await transport.connect(to: record.connection, cols: record.cols, rows: record.rows)
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
        await adopt(record, transport: transport, generation: generation)
    }

    /// Installs the fresh transport and bridges its output into the
    /// session's stable stream. The stale snapshot (if any) is dropped:
    /// the session is live again.
    private func adopt(
        _ record: SessionRecord,
        transport: any SessionTransport,
        generation: UInt64
    ) async {
        record.transport = transport
        startBridge(record, transport: transport, generation: generation)
        setState(record, .active)
        try? await snapshotStore.deleteSnapshot(sceneID: record.sceneID)
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

    /// Persists a reconnect-required snapshot, then EAGERLY closes the
    /// transport: socket survival across backgrounding is never assumed.
    public func didEnterBackground(sceneID: String) async {
        guard let record = records[sceneID], record.state != .closed else { return }
        try? await snapshotStore.save(SessionSnapshot(
            connectionID: record.connection.id,
            sceneID: sceneID,
            state: .reconnectRequired
        ))
        record.autoReconnectTask?.cancel()
        record.autoReconnectTask = nil
        _ = nextGeneration(record)
        setState(record, .suspended)
        record.bridgeTask?.cancel()
        record.bridgeTask = nil
        if let transport = record.transport {
            record.transport = nil
            await transport.close()
        }
    }

    /// Reconnects suspended sessions; failures surface as `.failed` state
    /// rather than throwing (this is a fire-and-forget lifecycle hook).
    public func willEnterForeground(sceneID: String) async {
        guard let record = records[sceneID], record.state == .suspended else { return }
        try? await reconnect(sceneID: sceneID)
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
        if let transport {
            await transport.close()
        }
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

    private func startBridge(
        _ record: SessionRecord,
        transport: any SessionTransport,
        generation: UInt64
    ) {
        record.bridgeTask = Task { [self] in
            let stream = await transport.output
            for await chunk in stream {
                await bridgeYield(chunk, for: record, generation: generation)
            }
            await bridgeFinished(for: record, generation: generation)
        }
    }

    private func bridgeYield(_ chunk: Data, for record: SessionRecord, generation: UInt64) {
        guard record.generation == generation, records[record.sceneID] === record else { return }
        record.outputContinuation.yield(chunk)
    }

    private func bridgeFinished(for record: SessionRecord, generation: UInt64) {
        guard record.generation == generation, records[record.sceneID] === record else { return }
        guard record.state == .active else { return }
        setState(record, .disconnected)
        scheduleAutoReconnect(record)
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
            } catch {
                // noSession / sessionClosed / invalidTransition: another
                // path owns the session now — stop retrying.
                return
            }
        }
        guard records[record.sceneID] === record else { return }
        switch record.state {
        case .active, .suspended, .closed:
            return
        default:
            setState(record, .failed(.reconnectAttemptsExhausted(
                attempts: reconnectPolicy.maxAttempts,
                lastError: lastError ?? .unreachable
            )))
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
    var reconnectWaiters: [CheckedContinuation<Result<Void, SessionRegistryError>, Never>] = []

    let outputStream: AsyncStream<Data>
    let outputContinuation: AsyncStream<Data>.Continuation
    var stateContinuations: [UUID: AsyncStream<SessionState>.Continuation] = [:]

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
