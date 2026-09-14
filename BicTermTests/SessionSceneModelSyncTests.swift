import BicTermCore
import XCTest
@testable import BicTerm

/// T12 honest-UX state machine on ``SessionSceneModel``: the suspect
/// banner flag, the reconnect toast, the one-tap resync action, and the
/// view-facing resync command stream the terminal surface consumes.
@MainActor
final class SessionSceneModelSyncTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private func makeConnection() throws -> Connection {
        try Connection(
            name: "sync-unit",
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
    }

    private func makeModel(
        factory: ScriptedSessionTransportFactory
    ) async throws -> (SessionSceneModel, SessionStore) {
        let store = SessionStore(
            transportFactory: factory,
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
        let descriptor = store.openSession(for: try makeConnection())
        guard let model = store.sceneModel(for: descriptor.id) else {
            throw NSError(domain: "SessionSceneModelSyncTests", code: 1)
        }
        await model.start()
        return (model, store)
    }

    private func waitFor<T: Equatable>(
        timeout: TimeInterval = 5,
        on model: SessionSceneModel,
        keyPath: KeyPath<SessionSceneModel, T>,
        equals expected: T
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model[keyPath: keyPath] == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model[keyPath: keyPath] == expected
    }

    /// Starts the model's resync-command stream's single consumer.
    private func recordResyncCommands(
        from model: SessionSceneModel
    ) -> ResyncCommandBox {
        let box = ResyncCommandBox()
        collectors.append(Task {
            for await _ in model.resyncCommands {
                await box.note()
            }
        })
        return box
    }

    func testSlowViewConsumerDropRaisesSuspectFlag() async throws {
        let factory = ScriptedSessionTransportFactory()
        let (model, _) = try await makeModel(factory: factory)
        let active = await waitFor(on: model, keyPath: \.state, equals: SessionState.active)
        XCTAssertTrue(active)

        // NO surface consumes viewOutput: the model's 256-chunk view
        // buffer overflows while the transport produces, dropping the
        // oldest chunks — previously a silent mid-stream cut.
        guard let transport = factory.transport(named: "sync-unit") else {
            XCTFail("transport not created")
            return
        }
        for index in 0..<400 {
            await transport.yield(Data("view-chunk-\(index)-padding-padding-padding\n".utf8))
        }

        let suspect = await waitFor(on: model, keyPath: \.syncSuspect, equals: true)
        XCTAssertTrue(suspect, "a view-site drop must raise the out-of-sync banner flag")
    }

    func testReconnectRefreshesScreenAndShowsToast() async throws {
        let factory = ScriptedSessionTransportFactory()
        let (model, _) = try await makeModel(factory: factory)
        let resyncBox = recordResyncCommands(from: model)
        let active = await waitFor(on: model, keyPath: \.state, equals: SessionState.active)
        XCTAssertTrue(active)

        // Drop the connection; the registry auto-reconnects with a fresh
        // transport and emits .sessionReplaced.
        guard let transport = factory.transport(named: "sync-unit") else {
            XCTFail("transport not created")
            return
        }
        await transport.finishOutput()

        let sawToast = await waitFor(on: model, keyPath: \.showReconnectedToast, equals: true)
        XCTAssertTrue(sawToast, "a normal reconnect must show the reconnected toast")

        let commands = await resyncBox.waitUntil(atLeast: 1, timeoutMilliseconds: 3000)
        XCTAssertTrue(commands, "the surface must receive a local VT reset command")

        let backActive = await waitFor(on: model, keyPath: \.state, equals: SessionState.active)
        XCTAssertTrue(backActive)

        // The toast is brief.
        let cleared = await waitFor(timeout: 6, on: model, keyPath: \.showReconnectedToast, equals: false)
        XCTAssertTrue(cleared, "the reconnected toast must auto-dismiss")
    }

    func testResyncNowClearsSuspectAndSignalsSurface() async throws {
        let factory = ScriptedSessionTransportFactory()
        let (model, _) = try await makeModel(factory: factory)
        let resyncBox = recordResyncCommands(from: model)

        guard let transport = factory.transport(named: "sync-unit") else {
            XCTFail("transport not created")
            return
        }

        // Raise the banner through a view-site drop, then tap Resync.
        for index in 0..<400 {
            await transport.yield(Data("view-chunk-\(index)-padding-padding-padding\n".utf8))
        }
        let suspect = await waitFor(on: model, keyPath: \.syncSuspect, equals: true)
        XCTAssertTrue(suspect)

        model.resyncNow()

        let cleared = await waitFor(on: model, keyPath: \.syncSuspect, equals: false)
        XCTAssertTrue(cleared, "one tap must clear the banner")

        let commands = await resyncBox.waitUntil(atLeast: 1, timeoutMilliseconds: 3000)
        XCTAssertTrue(commands, "one tap must command the surface's VT reset")

        // …and the registry's redraw poke must reach the transport.
        let pokeLanded = await resyncBox.waitUntilPoke(on: transport)
        XCTAssertTrue(pokeLanded, "one tap must poke the remote redraw")
    }
}

/// Counts resync commands arriving on the model's command stream.
actor ResyncCommandBox {
    private var count = 0

    func note() {
        count += 1
    }

    func currentCount() -> Int {
        count
    }

    func waitUntil(atLeast threshold: Int, timeoutMilliseconds: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if count >= threshold { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return count >= threshold
    }

    /// True once the transport recorded the window-change bounce
    /// (rows+1 then rows back) that forces a remote repaint.
    func waitUntilPoke(on transport: ScriptedSessionTransport) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while clock.now < deadline {
            let resizes = await transport.resizes
            let bounced = resizes.count >= 2
                && resizes[resizes.count - 2].rows == resizes[resizes.count - 1].rows + 1
                && resizes[resizes.count - 1].rows == 24
            if bounced { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
}
