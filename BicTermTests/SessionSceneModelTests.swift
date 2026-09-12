import BicTermCore
import XCTest
@testable import BicTerm

// MARK: - Test doubles

actor ScriptedSessionTransport: TerminalTransport {
    enum ConnectBehavior: Sendable {
        case succeed
        case fail(TransportError)
    }

    private let behavior: ConnectBehavior
    private let continuation: AsyncStream<Data>.Continuation
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated var resumeStrategy: ResumeStrategy { .rehandshake }

    private(set) var connectCalls = 0
    private(set) var closeCalls = 0
    private(set) var sent: [Data] = []

    init(behavior: ConnectBehavior) {
        self.behavior = behavior
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.outputStream = stream
        self.continuation = continuation
    }

    var output: AsyncStream<Data> { outputStream }

    func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {
        connectCalls += 1
        if case .fail(let error) = behavior {
            throw error
        }
    }

    func send(_ bytes: Data) async throws(TransportError) {
        sent.append(bytes)
    }

    func resize(cols: Int, rows: Int) async {}

    func close() async {
        closeCalls += 1
        continuation.finish()
    }

    func yield(_ data: Data) {
        continuation.yield(data)
    }

    private(set) var closeReason: TransportCloseReason = .connectionLost

    func remoteExit() {
        closeReason = .remoteExit
        continuation.finish()
    }
}

final class ScriptedSessionTransportFactory: TerminalTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [(transport: ScriptedSessionTransport, connectionName: String)] = []
    private var queuedBehaviors: [ScriptedSessionTransport.ConnectBehavior]
    private let fallbackBehavior: ScriptedSessionTransport.ConnectBehavior

    /// - Parameters:
    ///   - queued: behaviors consumed in order, one per `makeTransport`
    ///     call (e.g. fail with `.requiresTrust`, then succeed on retry).
    ///   - fallback: behavior used once `queued` is exhausted.
    init(
        queued: [ScriptedSessionTransport.ConnectBehavior] = [],
        fallback behavior: ScriptedSessionTransport.ConnectBehavior = .succeed
    ) {
        self.queuedBehaviors = queued
        self.fallbackBehavior = behavior
    }

    var createdCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return created.count
    }

    func transport(named connectionName: String) -> ScriptedSessionTransport? {
        lock.lock()
        defer { lock.unlock() }
        return created.first { $0.connectionName == connectionName }?.transport
    }

    func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        lock.lock()
        let behavior = queuedBehaviors.isEmpty
            ? fallbackBehavior
            : queuedBehaviors.removeFirst()
        lock.unlock()
        let transport = ScriptedSessionTransport(behavior: behavior)
        lock.lock()
        defer { lock.unlock() }
        created.append((transport, connection.name))
        return transport
    }
}

actor InMemoryAppSnapshotStore: SessionSnapshotStoreProtocol {
    private var snapshots: [String: SessionSnapshot] = [:]

    func loadSnapshots() async throws(PersistenceError) -> [SessionSnapshot] {
        Array(snapshots.values)
    }

    func snapshot(sceneID: String) async throws(PersistenceError) -> SessionSnapshot? {
        snapshots[sceneID]
    }

    func save(_ snapshot: SessionSnapshot) async throws(PersistenceError) {
        snapshots[snapshot.sceneID] = snapshot
    }

    func deleteSnapshot(sceneID: String) async throws(PersistenceError) {
        snapshots[sceneID] = nil
    }
}

/// Collects an output stream's bytes on a background task so tests can
/// assert what a scene's terminal surface actually received.
final class StreamCollector: @unchecked Sendable {
    private final class CollectorState {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            chunks.append(data)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return chunks.map { String(decoding: $0, as: UTF8.self) }.joined()
        }
    }

    private let storage: CollectorState
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Data>) {
        let storage = CollectorState()
        self.storage = storage
        self.task = Task {
            for await chunk in stream {
                storage.append(chunk)
            }
        }
    }

    var text: String { storage.text }

    func stop() {
        task.cancel()
    }
}

// MARK: - Scene model behavior

@MainActor
final class SessionSceneModelTests: XCTestCase {
    private func makeConnection(name: String, id: UUID = UUID()) throws -> Connection {
        try Connection(
            id: id,
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            keyReference: "unit-key"
        )
    }

    private func makeStore(
        factory: ScriptedSessionTransportFactory,
        snapshots: InMemoryAppSnapshotStore = InMemoryAppSnapshotStore(),
        connections: [Connection] = []
    ) -> SessionStore {
        let byID = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        return SessionStore(
            transportFactory: factory,
            snapshotStore: snapshots,
            connectionLookup: { id in byID[id] }
        )
    }

    private func waitFor(
        _ model: SessionSceneModel,
        timeout: TimeInterval = 5,
        matching predicate: (SessionState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.state) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(model.state)
    }

    /// Two scenes = two registry sessions = two transports; each scene's
    /// terminal stream carries ONLY its own session's bytes.
    func testTwoScenesCarryOnlyTheirOwnSessionOutput() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let alpha = try makeConnection(name: "Alpha")
        let beta = try makeConnection(name: "Beta")
        let store = makeStore(factory: factory, connections: [alpha, beta])

        let alphaDescriptor = store.openSession(for: alpha)
        let betaDescriptor = store.openSession(for: beta)
        let alphaModel = try XCTUnwrap(store.sceneModel(for: alphaDescriptor.id))
        let betaModel = try XCTUnwrap(store.sceneModel(for: betaDescriptor.id))
        XCTAssertNotEqual(alphaModel.sceneID, betaModel.sceneID)

        let alphaCollector = StreamCollector(alphaModel.viewOutput)
        let betaCollector = StreamCollector(betaModel.viewOutput)
        defer { alphaCollector.stop(); betaCollector.stop() }

        async let startAlpha: Void = alphaModel.start()
        async let startBeta: Void = betaModel.start()
        _ = await (startAlpha, startBeta)

        let alphaActive = await waitFor(alphaModel) { $0 == .active }
        XCTAssertTrue(alphaActive, "Alpha never became active: \(alphaModel.state)")
        let betaActive = await waitFor(betaModel) { $0 == .active }
        XCTAssertTrue(betaActive, "Beta never became active: \(betaModel.state)")
        XCTAssertEqual(factory.createdCount, 2)

        let alphaTransport = try XCTUnwrap(factory.transport(named: "Alpha"))
        let betaTransport = try XCTUnwrap(factory.transport(named: "Beta"))

        await alphaTransport.yield(Data("__MARKER_ALPHA__".utf8))
        await betaTransport.yield(Data("__MARKER_BETA__".utf8))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline
            && !(alphaCollector.text.contains("__MARKER_ALPHA__") && betaCollector.text.contains("__MARKER_BETA__")) {
            try? await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertTrue(alphaCollector.text.contains("__MARKER_ALPHA__"))
        XCTAssertFalse(alphaCollector.text.contains("__MARKER_BETA__"), "cross-scene leakage into Alpha")
        XCTAssertTrue(betaCollector.text.contains("__MARKER_BETA__"))
        XCTAssertFalse(betaCollector.text.contains("__MARKER_ALPHA__"), "cross-scene leakage into Beta")

        // Keyboard input routes to the scene's own transport only.
        alphaModel.send(Data("typed-in-alpha\n".utf8))
        let sentDeadline = Date().addingTimeInterval(3)
        while Date() < sentDeadline {
            let alphaSent = await alphaTransport.sent
            let betaSent = await betaTransport.sent
            if alphaSent.contains(Data("typed-in-alpha\n".utf8)) {
                XCTAssertFalse(betaSent.contains(Data("typed-in-alpha\n".utf8)))
                break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let finalAlphaSent = await alphaTransport.sent
        XCTAssertTrue(finalAlphaSent.contains(Data("typed-in-alpha\n".utf8)))
    }

    /// Restored sessions land `.reconnectRequired` (suspended), never
    /// auto-connect on foreground cycles, and reconnect only after the
    /// user's explicit action.
    func testRestoredSessionNeverAutoConnectsAndRequiresManualReconnect() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let snapshots = InMemoryAppSnapshotStore()
        let alpha = try makeConnection(name: "Alpha")
        let snapshot = SessionSnapshot(connectionID: alpha.id, sceneID: "terminated-scene")
        try await snapshots.save(snapshot)
        let store = makeStore(factory: factory, snapshots: snapshots, connections: [alpha])

        let listed = await store.loadRestorableSessions()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.snapshot.state, .reconnectRequired)
        XCTAssertEqual(listed.first?.connection.id, alpha.id)

        let descriptor = store.openRestoredSession(snapshot: snapshot, connection: alpha)
        XCTAssertEqual(
            store.openRestoredSession(snapshot: snapshot, connection: alpha).id,
            descriptor.id,
            "a second window on the same snapshot must reuse the same scene, never a second session"
        )

        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()
        XCTAssertEqual(model.state, .suspended)
        XCTAssertTrue(model.canRetry)

        await model.scenePhaseChanged(.active)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.state, .suspended, "restored session must not auto-connect on foreground")
        XCTAssertEqual(factory.createdCount, 0, "no transport may be created before the user acts")

        await model.reconnect()
        let reconnected = await waitFor(model) { $0 == .active }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(factory.createdCount, 1)

        let remaining = await store.loadRestorableSessions()
        XCTAssertTrue(remaining.isEmpty, "a successful manual reconnect consumes the snapshot")
    }

    /// The restorable list's Reconnect button IS the manual action: the
    /// scene it opens restores AND reconnects (never a bare auto-connect).
    func testRestorableRowReconnectButtonInitiatesManualReconnect() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let snapshots = InMemoryAppSnapshotStore()
        let alpha = try makeConnection(name: "Alpha")
        let snapshot = SessionSnapshot(connectionID: alpha.id, sceneID: "terminated-scene-2")
        try await snapshots.save(snapshot)
        let store = makeStore(factory: factory, snapshots: snapshots, connections: [alpha])

        let descriptor = store.openRestoredSession(
            snapshot: snapshot,
            connection: alpha,
            initiatesReconnect: true
        )
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()

        let reconnected = await waitFor(model) { $0 == .active }
        XCTAssertTrue(reconnected, "row-button path must reconnect after restore: \(model.state)")
        XCTAssertEqual(factory.createdCount, 1)
    }

    /// Closing a live scene asks for confirmation first; confirming
    /// terminates the session and clears scene ownership.
    func testClosingLiveSessionRequiresConfirmationThenTerminates() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let alpha = try makeConnection(name: "Alpha")
        let store = makeStore(factory: factory, connections: [alpha])
        let descriptor = store.openSession(for: alpha)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()
        let active = await waitFor(model) { $0 == .active }
        XCTAssertTrue(active)

        model.requestClose()
        XCTAssertTrue(model.pendingCloseConfirmation, "live session close must confirm first")
        XCTAssertEqual(model.state, .active)

        model.confirmClose()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !model.isClosed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isClosed)
        XCTAssertNil(store.descriptor(id: descriptor.id))
        let registryState = await store.registry.state(sceneID: model.sceneID)
        XCTAssertNil(registryState, "registry session must be gone after close")
    }

    /// A failed session closes without the confirmation step.
    func testFailedSessionClosesWithoutConfirmation() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .fail(.unreachable))
        let alpha = try makeConnection(name: "Alpha")
        let store = makeStore(factory: factory, connections: [alpha])
        let descriptor = store.openSession(for: alpha)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        await model.start()

        let failed = await waitFor(model) {
            if case .failed = $0 { return true }
            return false
        }
        XCTAssertTrue(failed, "expected typed failure, got \(model.state)")
        if case .failed(let failure) = model.state {
            XCTAssertEqual(failure, .transport(.unreachable))
        }
        XCTAssertEqual(model.statusText, "Failed: \(TransportError.unreachable.localizedDescription)")

        model.requestClose()
        XCTAssertFalse(model.pendingCloseConfirmation)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !model.isClosed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isClosed)
    }

    func testDeadWindowReservationsPreferLatestExitAndExcludeLiveSessions() async throws {
        let factory = ScriptedSessionTransportFactory()
        let store = makeStore(factory: factory)
        let alpha = store.openSession(for: try makeConnection(name: "Alpha"))
        let beta = store.openSession(for: try makeConnection(name: "Beta"))
        let a = try XCTUnwrap(store.sceneModel(for: alpha.id))
        let b = try XCTUnwrap(store.sceneModel(for: beta.id))
        let alphaWindow = UUID()
        let betaWindow = UUID()
        store.noteWindowHosting(windowValue: alphaWindow, shows: alpha.id)
        store.noteWindowHosting(windowValue: betaWindow, shows: beta.id)
        XCTAssertNil(store.requestDeadWindowAttachment(for: UUID()))
        await a.start()
        await b.start()
        let aActive = await waitFor(a) { $0 == .active }
        let bActive = await waitFor(b) { $0 == .active }
        XCTAssertTrue(aActive && bActive)
        XCTAssertNil(store.requestDeadWindowAttachment(for: UUID()))
        let first = try XCTUnwrap(factory.transport(named: "Alpha"))
        let second = try XCTUnwrap(factory.transport(named: "Beta"))
        await first.remoteExit()
        let aDead = await waitFor(a) { $0 == .disconnected }
        XCTAssertTrue(aDead)
        await second.remoteExit()
        let bDead = await waitFor(b) { $0 == .disconnected }
        XCTAssertTrue(bDead)
        let replacement = UUID()
        XCTAssertEqual(store.requestDeadWindowAttachment(for: replacement), betaWindow)
        XCTAssertEqual(store.requestDeadWindowAttachment(for: UUID()), alphaWindow)
        XCTAssertNil(store.requestDeadWindowAttachment(for: UUID()))
        XCTAssertEqual(store.takeWindowAttachment(for: betaWindow), replacement)
        store.noteWindowHosting(windowValue: betaWindow, shows: replacement)
        XCTAssertEqual(store.hostingWindowValue(for: replacement), betaWindow)
        store.noteWindowClosed(windowValue: alphaWindow)
        XCTAssertNil(store.pendingWindowAttachments[alphaWindow])
        await a.closeNow()
        await b.closeNow()
    }

    func testUnresolvedRestoredWindowIsNotADeadSessionHost() {
        let store = makeStore(factory: ScriptedSessionTransportFactory())
        let restoredWindow = UUID()
        store.noteWindowHosting(windowValue: restoredWindow, shows: restoredWindow)
        XCTAssertNil(store.requestDeadWindowAttachment(for: UUID()))
        XCTAssertTrue(store.pendingWindowAttachments.isEmpty)
    }

    func testReconnectResetsCachedTerminalModesAndPreservesText() async throws {
        let factory = ScriptedSessionTransportFactory()
        let store = makeStore(factory: factory)
        let descriptor = store.openSession(for: try makeConnection(name: "Alpha"))
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        let surface = store.viewCache.attachSurface(for: descriptor.id, model: model).surface
        await model.start()
        let active = await waitFor(model) { $0 == .active }
        XCTAssertTrue(active)
        let terminal = surface.view.getTerminal()
        terminal.feed(text: "transcript\u{1b}[?1003h\u{1b}[?2004h")
        let transport = try XCTUnwrap(factory.transport(named: "Alpha"))
        await transport.remoteExit()
        let dead = await waitFor(model) { $0 == .disconnected }
        XCTAssertTrue(dead)
        XCTAssertEqual(terminal.mouseMode, .anyEvent)
        await model.reconnect()
        let reconnected = await waitFor(model) { $0 == .active }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(terminal.mouseMode, .off)
        XCTAssertFalse(terminal.bracketedPasteMode)
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "t")
        XCTAssertTrue(store.viewCache.attachSurface(for: descriptor.id, model: model).surface === surface)
        await model.closeNow()
    }

    /// Chrome status text covers connecting/reconnecting/failed states
    /// (snapshot of the user-visible status surface).
    func testStatusTextCoversConnectionStates() throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let alpha = try makeConnection(name: "Alpha")
        let store = makeStore(factory: factory, connections: [alpha])
        let model = try XCTUnwrap(store.sceneModel(for: store.openSession(for: alpha).id))

        XCTAssertEqual(model.statusText, "Connecting…")
        XCTAssertEqual(model.protocolID, "ssh")
        XCTAssertEqual(model.connectionName, "Alpha")
    }
}
