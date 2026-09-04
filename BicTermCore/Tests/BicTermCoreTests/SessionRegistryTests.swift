import Foundation
import XCTest
@testable import BicTermCore

final class SessionRegistryTests: XCTestCase {
    private let fastPolicy = ReconnectPolicy(
        maxAttempts: 3,
        initialDelay: .milliseconds(10),
        backoffMultiplier: 1
    )

    private func makeRegistry(
        factory: FakeSessionTransportFactory,
        store: InMemorySnapshotStore = InMemorySnapshotStore(),
        policy: ReconnectPolicy? = nil
    ) -> SessionRegistry {
        SessionRegistry(
            transportFactory: factory,
            snapshotStore: store,
            reconnectPolicy: policy ?? fastPolicy
        )
    }

    func testSecondStartForOccupiedSceneThrowsSceneOccupied() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()

        try await registry.startSession(sceneID: "s1", connection: connection)

        do {
            try await registry.startSession(sceneID: "s1", connection: connection)
            XCTFail("second start for an occupied scene must throw")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .sceneOccupied(sceneID: "s1"))
        }
        XCTAssertEqual(factory.makeCount, 1, "rejected start must not build a transport")
        await registry.closeSession(sceneID: "s1")
    }

    func testRestoreForOccupiedSceneThrowsSceneOccupied() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()

        try await registry.startSession(sceneID: "s1", connection: connection)

        do {
            try await registry.restore(sceneID: "s1", connection: connection)
            XCTFail("restore onto an occupied scene must throw")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .sceneOccupied(sceneID: "s1"))
        }
        await registry.closeSession(sceneID: "s1")
    }

    func testStartSessionTransitionsThroughConnectingToActive() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()

        try await registry.startSession(sceneID: "s1", connection: connection, cols: 100, rows: 30)

        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .active)
        let history = await registry.stateHistory(sceneID: "s1")
        XCTAssertEqual(history, [.connecting, .active])

        let transport = factory.transports[0]
        let lastConnection = await transport.lastConnection
        XCTAssertEqual(lastConnection, connection)
        let lastSize = await transport.lastSize
        XCTAssertEqual(lastSize?.cols, 100)
        XCTAssertEqual(lastSize?.rows, 30)
        await registry.closeSession(sceneID: "s1")
    }

    func testStateStreamReplaysHistoryThenYieldsLiveTransitions() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)

        guard let stream = await registry.states(sceneID: "s1") else {
            return XCTFail("state stream must exist for a live session")
        }

        actor Collected {
            private(set) var states: [SessionState] = []
            func append(_ state: SessionState) { states.append(state) }
        }
        let collected = Collected()
        let collector = Task {
            for await state in stream {
                await collected.append(state)
            }
        }
        defer { collector.cancel() }

        // History replay is synchronous: connecting + active arrive even
        // though the subscription happened after connect completed.
        let replayed = await waitForCondition {
            await collected.states.count >= 2
        }
        XCTAssertTrue(replayed, "state stream must replay history")

        await factory.transports[0].finishOutput()
        let completed = await waitForCondition {
            await collected.states.count >= 5
        }
        XCTAssertTrue(completed, "state stream must yield live drop+reconnect transitions")

        let states = await collected.states
        XCTAssertEqual(
            Array(states.prefix(5)),
            [.connecting, .active, .disconnected, .reconnecting, .active]
        )
        await registry.closeSession(sceneID: "s1")
    }

    func testCloseSessionTransitionsToClosedAndFinishesStreams() async throws {
        let store = InMemorySnapshotStore()
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory, store: store)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)

        guard let output = await registry.output(sceneID: "s1"),
              let states = await registry.states(sceneID: "s1") else {
            return XCTFail("streams must exist for a live session")
        }
        let outputFinished = Task {
            for await _ in output {}
        }
        let statesFinished = Task {
            for await _ in states {}
        }

        await registry.closeSession(sceneID: "s1")

        let missing = await registry.state(sceneID: "s1")
        XCTAssertNil(missing, "closed sessions are removed from the registry")
        _ = await outputFinished.value
        _ = await statesFinished.value
        let closeCalls = await factory.transports[0].closeCalls
        XCTAssertEqual(closeCalls, 1)
        let snapshot = try await store.snapshot(sceneID: "s1")
        XCTAssertNil(snapshot, "closing removes any persisted snapshot")
    }

    func testDropDetectionTriggersAutoReconnectWithFreshTransportOnStableStream() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)

        guard let output = await registry.output(sceneID: "s1") else {
            return XCTFail("output stream must exist")
        }
        let sink = SSHOutputSink()
        let collector = Task {
            for await chunk in output {
                await sink.append(chunk)
            }
            await sink.markFinished()
        }
        defer { collector.cancel() }

        await factory.transports[0].yield(Data("before-drop".utf8))
        let sawBefore = await waitForContent(sink: sink, marker: "before-drop")
        XCTAssertTrue(sawBefore)

        // Remote drop: stream finishes without close(). Wait for the
        // history to show the FULL drop cycle — the state is already
        // .active pre-drop, so a state-only wait would race.
        await factory.transports[0].finishOutput()

        let reconnected = await waitForCondition {
            let history = await registry.stateHistory(sceneID: "s1")
            return history.contains(.reconnecting) && history.last == .active
        }
        XCTAssertTrue(reconnected, "drop must auto-reconnect to active")
        XCTAssertEqual(factory.makeCount, 2, "reconnect builds a fresh transport")

        let oldCloseCalls = await factory.transports[0].closeCalls
        XCTAssertEqual(oldCloseCalls, 1, "reconnect closes the dropped transport")

        await factory.transports[1].yield(Data("after-reconnect".utf8))
        let sawAfter = await waitForContent(sink: sink, marker: "after-reconnect")
        XCTAssertTrue(
            sawAfter,
            "stable output stream must bridge the fresh transport"
        )
        let finished = await sink.isFinished
        XCTAssertFalse(finished, "stable stream must survive reconnects")

        let history = await registry.stateHistory(sceneID: "s1")
        XCTAssertEqual(history, [.connecting, .active, .disconnected, .reconnecting, .active])
        await registry.closeSession(sceneID: "s1")
    }

    func testReconnectReplaysLatestTerminalSize() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(sceneID: "s1", connection: makeUnitConnection(), cols: 80, rows: 24)

        await registry.resize(sceneID: "s1", cols: 132, rows: 43)
        await factory.transports[0].finishOutput()

        let reconnected = await waitForCondition {
            let history = await registry.stateHistory(sceneID: "s1")
            return history.contains(.reconnecting) && history.last == .active
        }
        XCTAssertTrue(reconnected)
        let lastSize = await factory.transports[1].lastSize
        XCTAssertEqual(lastSize?.cols, 132)
        XCTAssertEqual(lastSize?.rows, 43)
        await registry.closeSession(sceneID: "s1")
    }

    func testConcurrentReconnectsCoalesceIntoSingleAttempt() async throws {
        let factory = FakeSessionTransportFactory(queued: [.succeed, .gated])
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)
        await registry.didEnterBackground(sceneID: "s1")

        let first = Task { try await registry.reconnect(sceneID: "s1") }
        let second = Task { try await registry.reconnect(sceneID: "s1") }

        let gated = await waitForCondition { factory.makeCount >= 2 }
        XCTAssertTrue(gated, "reconnect must reach the gated transport")
        // Let both callers enqueue on the actor before releasing.
        try await Task.sleep(for: .milliseconds(100))
        await factory.transports[1].releaseConnectGate()

        try await first.value
        try await second.value

        XCTAssertEqual(factory.makeCount, 2, "concurrent reconnects share one transport attempt")
        let connectCalls = await factory.transports[1].connectCalls
        XCTAssertEqual(connectCalls, 1)
        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .active)
        await registry.closeSession(sceneID: "s1")
    }

    func testStaleReconnectResultIsDiscardedAfterClose() async throws {
        let factory = FakeSessionTransportFactory(queued: [.succeed, .gated])
        let registry = makeRegistry(factory: factory)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)
        await registry.didEnterBackground(sceneID: "s1")

        let reconnect = Task { try await registry.reconnect(sceneID: "s1") }
        let gated = await waitForCondition { factory.makeCount >= 2 }
        XCTAssertTrue(gated)

        // Close WHILE the reconnect is suspended in connect: generation
        // bumps, the record is removed, the late result must be discarded.
        await registry.closeSession(sceneID: "s1")
        await factory.transports[1].releaseConnectGate()
        try await reconnect.value

        let closeCalls = await factory.transports[1].closeCalls
        XCTAssertEqual(closeCalls, 1, "stale fresh transport must be closed, never adopted")
        let state = await registry.state(sceneID: "s1")
        XCTAssertNil(state, "closed session must not be resurrected by a stale result")
        XCTAssertEqual(factory.makeCount, 2, "stale completion must not trigger further attempts")
    }

    func testBoundedBackoffExhaustionLandsInFailedStateAndStops() async throws {
        let factory = FakeSessionTransportFactory(
            queued: [.succeed],
            fallback: .fail(.unreachable)
        )
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(sceneID: "s1", connection: makeUnitConnection())

        await factory.transports[0].finishOutput()

        let failed = await waitForState(registry, sceneID: "s1") { state in
            if case .failed(.reconnectAttemptsExhausted) = state { return true }
            return false
        }
        XCTAssertTrue(failed, "exhaustion must land in a typed failed state")

        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(
            state,
            .failed(.reconnectAttemptsExhausted(attempts: 3, lastError: .unreachable))
        )
        XCTAssertEqual(factory.makeCount, 1 + 3, "exactly maxAttempts reconnect attempts")

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(factory.makeCount, 4, "no further attempts after exhaustion (bounded)")
        await registry.closeSession(sceneID: "s1")
    }

    func testManualReconnectRecoversFromFailedState() async throws {
        let factory = FakeSessionTransportFactory(
            queued: [.succeed, .fail(.unreachable), .succeed]
        )
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(sceneID: "s1", connection: makeUnitConnection())
        await registry.didEnterBackground(sceneID: "s1")

        do {
            try await registry.reconnect(sceneID: "s1")
            XCTFail("failing transport must surface a typed error")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .transport(.unreachable))
        }
        let failedState = await registry.state(sceneID: "s1")
        XCTAssertEqual(failedState, .failed(.transport(.unreachable)))

        try await registry.reconnect(sceneID: "s1")
        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .active, "manual retry from .failed must recover")
        await registry.closeSession(sceneID: "s1")
    }

    func testDidEnterBackgroundPersistsSnapshotAndClosesTransportEagerly() async throws {
        let store = InMemorySnapshotStore()
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory, store: store)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)

        await registry.didEnterBackground(sceneID: "s1")

        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .suspended)
        let snapshot = try await store.snapshot(sceneID: "s1")
        XCTAssertEqual(snapshot?.connectionID, connection.id)
        XCTAssertEqual(snapshot?.state, .reconnectRequired)

        let closeCalls = await factory.transports[0].closeCalls
        XCTAssertEqual(closeCalls, 1, "backgrounding must eagerly close the transport")
        XCTAssertEqual(factory.makeCount, 1, "backgrounding must not reconnect")

        // A background-close stream finish must NOT be read as a drop:
        // no disconnected/reconnecting transitions may appear.
        let history = await registry.stateHistory(sceneID: "s1")
        XCTAssertEqual(history, [.connecting, .active, .suspended])
        await registry.closeSession(sceneID: "s1")
    }

    func testWillEnterForegroundReconnectsSuspendedSession() async throws {
        let store = InMemorySnapshotStore()
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory, store: store)
        let connection = try makeUnitConnection()
        try await registry.startSession(sceneID: "s1", connection: connection)
        await registry.didEnterBackground(sceneID: "s1")

        await registry.willEnterForeground(sceneID: "s1")

        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .active)
        XCTAssertEqual(factory.makeCount, 2)
        let history = await registry.stateHistory(sceneID: "s1")
        XCTAssertEqual(history, [.connecting, .active, .suspended, .reconnecting, .active])
        let snapshot = try await store.snapshot(sceneID: "s1")
        XCTAssertNil(snapshot, "successful reconnect clears the stale snapshot")
        await registry.closeSession(sceneID: "s1")
    }

    func testWillTerminatePersistsSnapshotsAndNeverReconnects() async throws {
        let store = InMemorySnapshotStore()
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory, store: store)
        let c1 = try makeUnitConnection(name: "one")
        let c2 = try makeUnitConnection(name: "two")
        try await registry.startSession(sceneID: "s1", connection: c1)
        try await registry.startSession(sceneID: "s2", connection: c2)

        await registry.willTerminate()

        let snapshots = try await store.loadSnapshots()
        XCTAssertEqual(Set(snapshots.map(\.sceneID)), ["s1", "s2"])
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.state, .reconnectRequired)
        }

        let s1 = await registry.state(sceneID: "s1")
        let s2 = await registry.state(sceneID: "s2")
        XCTAssertNil(s1)
        XCTAssertNil(s2)
        for transport in factory.transports {
            let closeCalls = await transport.closeCalls
            XCTAssertEqual(closeCalls, 1)
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(factory.makeCount, 2, "termination must never auto-reconnect")
    }

    func testRestoreFromSnapshotLandsSuspendedAndReconnectsManually() async throws {
        let store = InMemorySnapshotStore()
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory, store: store)
        let connection = try makeUnitConnection()
        try await store.save(SessionSnapshot(
            connectionID: connection.id,
            sceneID: "s1",
            state: .reconnectRequired
        ))

        try await registry.restore(sceneID: "s1", connection: connection)

        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .suspended, "restored sessions land at reconnect-required")
        XCTAssertEqual(factory.makeCount, 0, "restoration must never auto-connect")

        do {
            try await registry.send(sceneID: "s1", Data("x".utf8))
            XCTFail("send on a suspended session must throw")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .invalidTransition(sceneID: "s1", state: .suspended))
        }

        let restorable = try await registry.restorableSnapshots()
        XCTAssertEqual(restorable.map(\.sceneID), ["s1"])

        try await registry.reconnect(sceneID: "s1")
        let reconnected = await registry.state(sceneID: "s1")
        XCTAssertEqual(reconnected, .active)
        XCTAssertEqual(factory.makeCount, 1)
        await registry.closeSession(sceneID: "s1")
    }

    func testInitialConnectFailureThrowsTypedErrorAndLandsInFailedState() async throws {
        let factory = FakeSessionTransportFactory(queued: [.fail(.authenticationFailed)])
        let registry = makeRegistry(factory: factory)

        do {
            try await registry.startSession(sceneID: "s1", connection: makeUnitConnection())
            XCTFail("failed connect must throw")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .transport(.authenticationFailed))
        }

        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .failed(.transport(.authenticationFailed)))
        await registry.closeSession(sceneID: "s1")
    }

    func testReconnectOnActiveSessionThrowsInvalidTransition() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(sceneID: "s1", connection: makeUnitConnection())

        do {
            try await registry.reconnect(sceneID: "s1")
            XCTFail("reconnect on an active session must throw")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .invalidTransition(sceneID: "s1", state: .active))
        }
        XCTAssertEqual(factory.makeCount, 1, "rejected reconnect must not build a transport")
        await registry.closeSession(sceneID: "s1")
    }

    func testReconnectOnUnknownSceneThrowsNoSession() async throws {
        let registry = makeRegistry(factory: FakeSessionTransportFactory())

        do {
            try await registry.reconnect(sceneID: "missing")
            XCTFail("reconnect on an unknown scene must throw")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .noSession(sceneID: "missing"))
        }
    }

    func testManualReconnectWinsOverPendingAutoReconnect() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(
            factory: factory,
            policy: ReconnectPolicy(
                maxAttempts: 3,
                initialDelay: .milliseconds(500),
                backoffMultiplier: 1
            )
        )
        try await registry.startSession(sceneID: "s1", connection: makeUnitConnection())

        await factory.transports[0].finishOutput()
        let disconnected = await waitForState(registry, sceneID: "s1") { $0 == .disconnected }
        XCTAssertTrue(disconnected)

        // Manual reconnect during the auto backoff window: the auto loop
        // must observe .active and stop instead of double-connecting.
        try await registry.reconnect(sceneID: "s1")
        let state = await registry.state(sceneID: "s1")
        XCTAssertEqual(state, .active)

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(factory.makeCount, 2, "auto loop must stop after a manual reconnect succeeds")
        await registry.closeSession(sceneID: "s1")
    }

    private func waitForCondition(
        timeoutMilliseconds: UInt64 = 5000,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}
