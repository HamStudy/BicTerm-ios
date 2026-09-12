import BicTermCore
import HerdrClientCore
import XCTest

@testable import BicTerm

/// herdr-support T10 multi-endpoint hardening: the aggregate reconnect
/// budget (no retry storms across N endpoints), parallel background detach
/// with foreground recovery for every machine, the bounded retained-surface
/// cache, and the live-source authLost mapping (a revoked key mid-session
/// is a typed attention state after ONE attempt, never an auto-retry).
@MainActor
final class HerdrMultiEndpointHardeningTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func vendorGolden(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("Vendor/herdr/herdr-protocol/tests/fixtures/golden/\(name).bin"))
    }

    private func herdrGolden(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("Fixtures/herdr/golden/\(name).bin"))
    }

    private func fenceScript() throws -> [Data] {
        [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("surface-ack-2x2"),
            try herdrGolden("surface-2x2"),
            try herdrGolden("surface-sync-ack-2x2"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("surface-2x2"),
            try herdrGolden("presentation-ready-2x2"),
        ]
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeModel(
        backoff: HerdrReconnectBackoff = HerdrReconnectBackoff(
            maxAttempts: 3, base: .milliseconds(30), cap: .milliseconds(120), jitter: .milliseconds(10)
        ),
        aggregateReconnectBudget: Int = HerdrReconnectBackoff.standard.maxAttempts
    ) -> HerdrSessionModel {
        HerdrSessionModel(
            reconnectBackoff: backoff,
            aggregateReconnectBudget: aggregateReconnectBudget
        )
    }

    private func connectThroughFence(
        _ model: HerdrSessionModel,
        endpoint: HerdrEndpointID,
        source: HerdrReconnectSource? = nil
    ) async throws -> HerdrReplayTransport {
        if let source,
            let fromSource = try? await source.makeTransport() as? HerdrReplayTransport {
            model.connect(endpoint: endpoint, transport: fromSource, reconnectSource: source)
            let online = await waitUntil(timeout: 8) {
                model.endpoints[endpoint]?.phase == .online
                    && model.endpoints[endpoint]?.surface != nil
            }
            XCTAssertTrue(online, "the fence must complete before hardening assertions")
            return fromSource
        }
        let transport = HerdrReplayTransport(script: try fenceScript())
        model.connect(endpoint: endpoint, transport: transport, reconnectSource: source)
        let online = await waitUntil(timeout: 8) {
            model.endpoints[endpoint]?.phase == .online
                && model.endpoints[endpoint]?.surface != nil
        }
        XCTAssertTrue(online, "the fence must complete before hardening assertions")
        return transport
    }

    // MARK: - Aggregate reconnect budget

    func testAggregateBudgetCapsConcurrentLoopsAndQueuesTheOverflow() async throws {
        let model = makeModel()
        let endpoints = (0..<6).map { HerdrEndpointID(rawValue: "budget-\($0)") }
        var gates: [AsyncStream<Void>.Continuation] = []
        var gateOpened = false
        var startedEndpoints: Set<HerdrEndpointID> = []
        var attempts: [HerdrEndpointID: Int] = [:]

        for endpoint in endpoints {
            let gate = AsyncStream<Void>.makeStream()
            gates.append(gate.continuation)
            model.endpoints[endpoint] = HerdrEndpointState()
            model.reconnectSources[endpoint] = HerdrReconnectSource {
                startedEndpoints.insert(endpoint)
                attempts[endpoint, default: 0] += 1
                _ = await gate.stream.first { @Sendable _ in true }
                if gateOpened {
                    struct Unreachable: Error {}
                    throw Unreachable()
                }
                return HerdrReplayTransport(script: [])
            }
        }

        for endpoint in endpoints {
            model.reconnect(endpoint: endpoint)
        }

        // While every factory is held at its gate, only the budget (4) may
        // run; the overflow queues — the storm never fans out past the cap.
        let fourStarted = await waitUntil { startedEndpoints.count == 4 }
        XCTAssertTrue(fourStarted, "exactly the aggregate budget of loops started")
        XCTAssertEqual(model.reconnectTasks.count, 4)
        XCTAssertEqual(model.pendingReconnects, Array(endpoints[4...]))
        XCTAssertTrue(
            endpoints.allSatisfy { model.endpoints[$0]?.phase == .reconnecting },
            "queued endpoints read Reconnecting too — waiting is honest state"
        )
        XCTAssertTrue(
            model.debugLifecycleLog.contains { $0.contains("reconnect:queued:") },
            "queueing is visible in the lifecycle log"
        )

        gateOpened = true
        gates.forEach { $0.finish() }

        let allSettled = await waitUntil(timeout: 8) {
            endpoints.allSatisfy { model.endpoints[$0]?.phase == .failed }
        }
        XCTAssertTrue(allSettled, "running and queued endpoints alike exhaust their bounded loops")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: endpoints.map { ($0, 3) }), attempts,
            "every endpoint — queued or not — gets exactly its per-endpoint attempt budget"
        )
        XCTAssertTrue(
            endpoints.allSatisfy { model.endpoints[$0]?.diagnostic?.kind == .transportLost }
        )
        XCTAssertEqual(startedEndpoints, Set(endpoints), "the queued endpoints started once slots freed")
    }

    // MARK: - Multi-endpoint background/foreground recovery

    func testBackgroundDetachIsParallelAndForegroundRecoversEveryMachine() async throws {
        let model = makeModel()
        let endpoints = (0..<5).map { HerdrEndpointID(rawValue: "bgfg-\($0)") }
        var builtTransports = 0
        for endpoint in endpoints {
            let script = try fenceScript()
            let source = HerdrReconnectSource {
                builtTransports += 1
                return HerdrReplayTransport(script: script)
            }
            _ = try await connectThroughFence(model, endpoint: endpoint, source: source)
        }
        model.selectedEndpointID = endpoints[2]

        let started = ContinuousClock().now
        await model.suspendForSceneBackground()
        let elapsed = ContinuousClock().now - started

        // Five concurrent detaches share one 1 s drain window; a serial
        // implementation would need five.
        XCTAssertLessThan(
            elapsed, .seconds(3),
            "an N-machine herd suspends inside one drain window, not N"
        )
        XCTAssertTrue(
            endpoints.allSatisfy { model.endpoints[$0]?.phase == .disconnected }
        )
        XCTAssertTrue(
            endpoints.allSatisfy { model.endpoints[$0]?.snapshot != nil },
            "every machine keeps its dimmed-view cache across background"
        )
        XCTAssertEqual(builtTransports, 5, "suspend built nothing new")

        model.resumeFromSceneForeground()
        let allOnline = await waitUntil(timeout: 10) {
            endpoints.allSatisfy { model.endpoints[$0]?.phase == .online }
        }
        XCTAssertTrue(
            allOnline,
            "the fifth machine (over the aggregate budget) recovers from the queue"
        )
        XCTAssertEqual(builtTransports, 10, "exactly one fresh transport per machine")
        XCTAssertEqual(model.endpoints[endpoints[2]]?.generation, 2)
    }

    // MARK: - Retained-surface cache bound

    func testRetainedSurfaceCachesAreBoundedAndNeverEvictSelectedOrLiveMachines() async throws {
        let model = makeModel()
        let live = HerdrEndpointID(rawValue: "cache-live")
        _ = try await connectThroughFence(model, endpoint: live)
        let surface = try XCTUnwrap(model.endpoints[live]?.surface)
        let snapshot = try XCTUnwrap(model.endpoints[live]?.snapshot)

        // Nine detached machines retaining the same committed cache, older
        // first; the newest is the selected (on-screen, dimmed) machine.
        let detached = (0..<9).map { HerdrEndpointID(rawValue: "cache-\($0)") }
        for (index, endpoint) in detached.enumerated() {
            var state = HerdrEndpointState()
            state.phase = .disconnected
            state.surface = surface
            state.snapshot = snapshot
            model.endpoints[endpoint] = state
            model.surfaceCommittedAt[endpoint] = UInt(index + 2)
        }
        let selected = detached.last!
        model.selectedEndpointID = selected

        model.trimRetainedSurfaceCaches()

        XCTAssertEqual(
            model.surfaceCommittedAt.keys.filter {
                model.runtimes[$0] == nil && model.endpoints[$0]?.surface != nil
            }.count,
            HerdrSessionModel.maxRetainedSurfaceCaches,
            "exactly the bound of detached machines retain caches"
        )
        XCTAssertNil(
            model.endpoints[detached[0]]?.surface,
            "the least-recently-committed cache is the one evicted"
        )
        XCTAssertNil(model.endpoints[detached[0]]?.snapshot)
        XCTAssertEqual(
            model.endpoints[detached[0]]?.phase, .disconnected,
            "eviction drops stale pixels, never the honest phase"
        )
        XCTAssertNotNil(model.endpoints[detached[1]]?.surface)
        XCTAssertNotNil(
            model.endpoints[selected]?.surface,
            "the selected machine's dimmed view is never evicted"
        )
        XCTAssertNotNil(
            model.endpoints[live]?.surface,
            "a live machine's surface is current state, not a cache — never evicted"
        )
        XCTAssertEqual(
            model.endpoints[live]?.surface, surface,
            "the live machine's cache bytes are untouched by the trim"
        )
    }

    // MARK: - authLost through the live source

    func testLiveSourceMapsOnlyAuthenticationFailuresToAuthLost() async throws {
        let authSource = HerdrReconnectSource.live {
            throw HerdrEndpointConnectorError.sshEstablish(.authenticationFailed)
        }
        do {
            _ = try await authSource.makeTransport()
            XCTFail("an SSH auth failure must throw")
        } catch let error as HerdrReconnectSource.OpenError {
            XCTAssertEqual(String(describing: error), "authenticationLost")
        }

        let bridgeAuthSource = HerdrReconnectSource.live {
            throw HerdrEndpointConnectorError.bridgeChannelFailed(.authRequired)
        }
        do {
            _ = try await bridgeAuthSource.makeTransport()
            XCTFail("a bridge-channel auth failure must throw")
        } catch is HerdrReconnectSource.OpenError {
        }

        let reachableSource = HerdrReconnectSource.live {
            throw HerdrEndpointConnectorError.sshEstablish(.unreachable)
        }
        do {
            _ = try await reachableSource.makeTransport()
            XCTFail("a transport failure must still throw")
        } catch let error as HerdrEndpointConnectorError {
            XCTAssertEqual(error, .sshEstablish(.unreachable))
        } catch {
            XCTFail("non-auth failures pass the connector's typed error through, got \(error)")
        }

        let transport = HerdrReplayTransport(script: [])
        let healthySource = HerdrReconnectSource.live { transport }
        let opened = try await healthySource.makeTransport()
        XCTAssertTrue(opened as? HerdrReplayTransport === transport)
    }

    func testRevokedKeyMidSessionStopsAfterOneAttemptWithTypedDiagnostic() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "revoked")
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.detach(endpoint: endpoint, reason: .user)
        // The key was revoked while the session ran: the next establish
        // (re-attach or foreground recovery) meets an auth rejection.
        model.reconnectSources[endpoint] = HerdrReconnectSource.live {
            throw HerdrEndpointConnectorError.sshEstablish(.authenticationFailed)
        }

        model.reconnect(endpoint: endpoint)
        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .authLost)
        XCTAssertEqual(
            model.endpoints[endpoint]?.diagnostic?.title, "Authentication lost"
        )
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            model.debugLifecycleLog.filter { $0.hasPrefix("reconnect:attempt:") }.count, 1,
            "a revoked key is a user action, never an automatic retry"
        )
        XCTAssertTrue(
            model.debugLifecycleLog.contains { $0.contains("reconnect:auth-lost:") }
        )
    }
}
