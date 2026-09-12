import Foundation
import XCTest
@testable import BicTermCore

/// T12 sync-integrity seams: the registry's ``SessionSyncEvent`` contract
/// (session replacement after a rehandshake, inbound-drop detection) and
/// the resync poke, all against scripted transports.
final class TerminalSyncIntegrityTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private func makeRegistry(factory: FakeSessionTransportFactory) -> SessionRegistry {
        SessionRegistry(
            transportFactory: factory,
            snapshotStore: InMemorySnapshotStore(),
            reconnectPolicy: ReconnectPolicy(
                maxAttempts: 4,
                initialDelay: .milliseconds(50),
                backoffMultiplier: 1
            )
        )
    }

    /// Starts the stream's ONE iterator, recording every event into the
    /// returned box for polling assertions.
    private func recordSyncEvents(
        from stream: AsyncStream<SessionSyncEvent>?
    ) -> SyncEventBox {
        let box = SyncEventBox()
        collectors.append(Task {
            for await event in stream ?? AsyncStream { $0.finish() } {
                await box.record(event)
            }
        })
        return box
    }

    private func waitUntil(
        timeoutMilliseconds: UInt64 = 5000,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    func testInitialConnectEmitsNoSyncEvent() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(
            sceneID: "scene",
            connection: try makeUnitConnection(),
            cols: 80,
            rows: 24
        )
        let box = recordSyncEvents(from: await registry.syncEvents(sceneID: "scene"))
        let stayedQuiet = await waitUntil(timeoutMilliseconds: 400) { await box.all.isEmpty }
        let events = await box.all
        XCTAssertTrue(stayedQuiet, "first adoption must not signal replacement: \(events)")
    }

    func testRehandshakeReconnectEmitsSessionReplaced() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(
            sceneID: "scene",
            connection: try makeUnitConnection(),
            cols: 80,
            rows: 24
        )
        let box = recordSyncEvents(from: await registry.syncEvents(sceneID: "scene"))

        await factory.transports[0].finishOutput()

        let gotEvent = await waitUntil { await box.all.contains(.sessionReplaced) }
        XCTAssertTrue(gotEvent, "rehandshake adoption must emit .sessionReplaced")

        let reconnected = await waitForState(registry, sceneID: "scene") { $0 == .active }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(factory.makeCount, 2, "a fresh transport was built")

        // The replacement poke must reach the FRESH transport: bounce the
        // row count by one, then restore (a same-size window-change would
        // not SIGWINCH).
        let second = factory.transports[1]
        let pokeLanded = await waitUntil {
            let resizes = await second.resizes
            return resizes.suffix(2).elementsEqual([(cols: 80, rows: 25), (cols: 80, rows: 24)]) {
                $0.cols == $1.cols && $0.rows == $1.rows
            }
        }
        XCTAssertTrue(pokeLanded, "resync poke must bounce rows by one and restore")
    }

    func testRoamingResumeEmitsNoSyncEvent() async throws {
        let factory = FakeSessionTransportFactory(roaming: true)
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(
            sceneID: "scene",
            connection: try makeUnitConnection(),
            cols: 80,
            rows: 24
        )
        let box = recordSyncEvents(from: await registry.syncEvents(sceneID: "scene"))

        await registry.didEnterBackground(sceneID: "scene")
        await registry.willEnterForeground(sceneID: "scene")
        let reconnected = await waitForState(registry, sceneID: "scene") { $0 == .active }
        XCTAssertTrue(reconnected, "roaming transport must resume in place")
        XCTAssertEqual(factory.makeCount, 1, "resume must NOT build a fresh transport")

        let stayedQuiet = await waitUntil(timeoutMilliseconds: 400) { await box.all.isEmpty }
        let events = await box.all
        XCTAssertTrue(
            stayedQuiet,
            "roaming resume reattaches the SAME server-side session — local VT stays valid, no resync signal: \(events)"
        )
    }

    func testSlowConsumerDropAtRegistryBridgeMarksSuspect() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(
            sceneID: "scene",
            connection: try makeUnitConnection(),
            cols: 80,
            rows: 24
        )
        let box = recordSyncEvents(from: await registry.syncEvents(sceneID: "scene"))

        // NO consumer iterates registry.output(sceneID:) — the record's
        // 64-chunk bounded buffer overflows while the transport keeps
        // producing, dropping the oldest chunks.
        let transport = factory.transports[0]
        for index in 0..<200 {
            await transport.yield(Data("chunk-\(index)-padding-padding-padding\n".utf8))
        }

        let gotDrop = await waitUntil { await box.all.contains(.inboundDropped) }
        XCTAssertTrue(gotDrop, "a bounded-buffer drop must surface as .inboundDropped, never silently")
        let dropCount = await box.all.filter { $0 == .inboundDropped }.count
        XCTAssertEqual(dropCount, 1, "one suspicion window, one event (deduped)")
    }

    func testTransportDropObserverFiresRegistrySuspect() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(
            sceneID: "scene",
            connection: try makeUnitConnection(),
            cols: 80,
            rows: 24
        )
        let box = recordSyncEvents(from: await registry.syncEvents(sceneID: "scene"))

        // The transport's own bounded site reports its overflow through
        // the installed observer (the registry bridges it into the same
        // suspect signal).
        await factory.transports[0].reportInboundDrop()

        let gotDrop = await waitUntil { await box.all.contains(.inboundDropped) }
        XCTAssertTrue(gotDrop, "transport-site drops must reach the session's suspect signal")
    }

    func testResyncClearsSuspectAndReArmsDropDetection() async throws {
        let factory = FakeSessionTransportFactory()
        let registry = makeRegistry(factory: factory)
        try await registry.startSession(
            sceneID: "scene",
            connection: try makeUnitConnection(),
            cols: 80,
            rows: 24
        )
        let box = recordSyncEvents(from: await registry.syncEvents(sceneID: "scene"))

        let transport = factory.transports[0]
        await transport.reportInboundDrop()
        let firstDrop = await waitUntil { await box.all.contains(.inboundDropped) }
        XCTAssertTrue(firstDrop)

        await registry.resync(sceneID: "scene")

        let pokeLanded = await waitUntil {
            let resizes = await transport.resizes
            return resizes.suffix(2).elementsEqual([(cols: 80, rows: 25), (cols: 80, rows: 24)]) {
                $0.cols == $1.cols && $0.rows == $1.rows
            }
        }
        XCTAssertTrue(pokeLanded, "manual resync pokes the remote into a redraw")

        // Dedupe held across the resync window…
        let stillOne = await waitUntil { await box.all.count == 1 }
        let events = await box.all
        XCTAssertTrue(stillOne, "no spurious events during the resync window: \(events)")

        // …and detection re-arms: a NEW drop signals again.
        await transport.reportInboundDrop()
        let secondDrop = await waitUntil { await box.all.filter { $0 == .inboundDropped }.count == 2 }
        XCTAssertTrue(secondDrop, "drop detection re-arms after a resync")
    }
}

/// Accumulates sync events for polling assertions.
actor SyncEventBox {
    private(set) var all: [SessionSyncEvent] = []

    func record(_ event: SessionSyncEvent) {
        all.append(event)
    }
}
