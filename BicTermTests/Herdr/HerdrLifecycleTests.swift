import BicTermCore
import HerdrClientCore
import XCTest

@testable import BicTerm

/// T19 herdr lifecycle: user detach / re-attach continuity (fresh hello,
/// authoritative state, never a replay of speculative input), the doc §10
/// background/foreground policy, the doc §6.3 failure taxonomy with input
/// disabled wherever ordering cannot be guaranteed, and the bounded
/// jittered-backoff reconnect loop (no retry storms, manual cancel,
/// auth-loss attention state).
@MainActor
final class HerdrLifecycleTests: XCTestCase {
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
        handshakeTimeout: Duration = .seconds(60),
        backoff: HerdrReconnectBackoff = HerdrReconnectBackoff(
            maxAttempts: 3, base: .milliseconds(30), cap: .milliseconds(120), jitter: .milliseconds(10)
        )
    ) -> HerdrSessionModel {
        HerdrSessionModel(handshakeTimeout: handshakeTimeout, reconnectBackoff: backoff)
    }

    /// Connects through the full presentation fence and waits for online.
    private func connectThroughFence(
        _ model: HerdrSessionModel,
        endpoint: HerdrEndpointID,
        source: HerdrReconnectSource? = nil
    ) async throws -> HerdrReplayTransport {
        if let source, let fromSource = try? source.makeTransport() as? HerdrReplayTransport {
            model.connect(endpoint: endpoint, transport: fromSource, reconnectSource: source)
            let online = await waitUntil { model.endpoints[endpoint]?.phase == .online }
            XCTAssertTrue(online, "the fence must complete before lifecycle assertions")
            return fromSource
        }
        let transport = HerdrReplayTransport(script: try fenceScript())
        model.connect(endpoint: endpoint, transport: transport)
        let online = await waitUntil { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online, "the fence must complete before lifecycle assertions")
        return transport
    }

    private func lifecycleEcho(_ model: HerdrSessionModel, contains needle: String) -> Bool {
        model.debugLifecycleLog.contains { $0.contains(needle) }
    }

    // MARK: - Detach

    func testUserDetachClosesTheChannelWithinBoundAndKeepsTheSnapshot() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "detach")
        let transport = try await connectThroughFence(model, endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1)

        let started = ContinuousClock().now
        await model.detach(endpoint: endpoint, reason: .user)
        let elapsed = ContinuousClock().now - started

        XCTAssertTrue(transport.isClosed, "the channel must close inside the detach call")
        XCTAssertLessThan(elapsed, .seconds(4), "the bounded drain never exceeds its deadline")
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .disconnected)
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .userDetach)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1, "the authoritative snapshot survives for the dimmed view")
        XCTAssertTrue(lifecycleEcho(model, contains: "detach:user"))
        XCTAssertTrue(lifecycleEcho(model, contains: "detached:"))

        let echoBefore = model.debugInputEcho
        model.sendText("late", endpoint: endpoint)
        XCTAssertEqual(
            model.debugInputEcho, echoBefore,
            "input after detach is inert — ordering can never be guaranteed"
        )
    }

    // MARK: - Re-attach (spec hard rule: never replay speculative input)

    func testReattachSendsFreshHelloAndNeverReplaysPreDetachInput() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "reattach")
        let first = try await connectThroughFence(model, endpoint: endpoint)

        model.sendText("hi", endpoint: endpoint)
        let inputFrame = try herdrGolden("input-text-hi-p2")
        let inputOnWire = await waitUntil {
            first.writeLedger.contains(inputFrame)
        }
        XCTAssertTrue(inputOnWire, "pre-detach input reaches the first transport")

        await model.detach(endpoint: endpoint, reason: .user)

        var second: HerdrReplayTransport?
        let source = HerdrReconnectSource {
            let transport = HerdrReplayTransport(script: (try? self.fenceScript()) ?? [])
            second = transport
            return transport
        }
        model.reconnectSources[endpoint] = source
        model.reconnect(endpoint: endpoint)

        let online = await waitUntil(timeout: 8) { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online, "re-attach reconnects with the fresh hello")
        let newTransport = try XCTUnwrap(second)
        XCTAssertEqual(model.endpoints[endpoint]?.generation, 2, "reconnect bumps the connection generation")
        XCTAssertTrue(lifecycleEcho(model, contains: "online:\(endpoint.rawValue):gen:2"))

        let writes = newTransport.writeLedger
        XCTAssertGreaterThanOrEqual(writes.count, 1, "the fresh hello reaches the wire")
        let hello = try XCTUnwrap(writes.first)
        XCTAssertGreaterThan(hello.count, 4)
        let header = Array(hello.prefix(4))
        let length = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        XCTAssertEqual(Int(length), hello.count - 4, "the reconnect's FIRST frame is the fresh hello")
        XCTAssertFalse(
            writes.contains(inputFrame),
            "pre-detach speculative input must never replay onto the new transport"
        )
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1, "authoritative state arrives from the new snapshot")
        XCTAssertNil(model.endpoints[endpoint]?.inputTargetOverride, "no stale pane override leaks across generations")

        // The FFI input lane unfreezes only at the fence's ready control:
        // wait for the SECOND fence to fully apply (8 chunks per fence)
        // before proving the new lane carries fresh input.
        let fenceDone = await waitUntil(timeout: 8) { model.debugAppliedChunks >= 16 }
        XCTAssertTrue(fenceDone, "the re-attached connection's presentation fence completes")

        model.sendText("q", endpoint: endpoint)
        let newInput = await waitUntil {
            model.debugInputEcho.contains { $0.contains("text(\"q\"") }
        }
        XCTAssertTrue(newInput, "post-reattach input flows on the new lane only")
    }

    // MARK: - Background / foreground (doc §10)

    func testBackgroundPolicyClosesTheChannelAndForegroundReconnectsCleanly() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "bgfg")
        var transports: [HerdrReplayTransport] = []
        let source = HerdrReconnectSource {
            let transport = HerdrReplayTransport(script: (try? self.fenceScript()) ?? [])
            transports.append(transport)
            return transport
        }
        let first = try await connectThroughFence(model, endpoint: endpoint, source: source)
        XCTAssertEqual(transports.count, 1)

        let started = ContinuousClock().now
        await model.suspendForSceneBackground()
        XCTAssertLessThan(
            ContinuousClock().now - started, .seconds(4),
            "the channel must close within the granted background window"
        )
        XCTAssertTrue(first.isClosed, "channel closed within the granted time")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .userDetach)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1, "detached view keeps stale metadata")
        XCTAssertTrue(lifecycleEcho(model, contains: "detach:background"))

        model.resumeFromSceneForeground()
        let online = await waitUntil(timeout: 8) { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online, "foreground reconnects cleanly")
        XCTAssertEqual(transports.count, 2, "exactly one fresh transport was built")
        let reconnectHello = try XCTUnwrap(transports[1].writeLedger.first)
        XCTAssertGreaterThan(reconnectHello.count, 4)
        let header = Array(reconnectHello.prefix(4))
        let length = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        XCTAssertEqual(Int(length), reconnectHello.count - 4, "the reconnect opens with the fresh hello envelope")
        XCTAssertEqual(model.endpoints[endpoint]?.generation, 2)
    }

    func testUserDetachDoesNotAutoReconnectOnForeground() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "user-no-auto")
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.detach(endpoint: endpoint, reason: .user)

        model.resumeFromSceneForeground()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .disconnected, "user detach waits for an explicit re-attach")
    }

    func testSceneInactiveSuspendsInputUntilActiveAgain() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "scene-input")
        let transport = try await connectThroughFence(model, endpoint: endpoint)
        let baselineWrites = transport.writeLedger.count

        model.sceneResignedActive()
        model.sendText("x", endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.inputNote, .suspended)
        XCTAssertEqual(transport.writeLedger.count, baselineWrites, "suspended input never reaches the wire")

        model.sceneBecameActive()
        model.sendText("y", endpoint: endpoint)
        let flowed = await waitUntil {
            model.debugInputEcho.contains { $0.contains("text(\"y\"") }
        }
        XCTAssertTrue(flowed, "active again: input flows")
        XCTAssertEqual(
            model.endpoints[endpoint]?.inputNote, .suspended,
            "the suspended note stays until a later note replaces it"
        )
    }

    // MARK: - Failure taxonomy (doc §6.3)

    func testCleanEOFAfterHealthySessionIsRemoteClosed() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: try fenceScript(), holdOpen: false, exitStatus: 0)
        let endpoint = HerdrEndpointID(rawValue: "eof-0")
        model.connect(endpoint: endpoint, transport: transport)

        let done = await waitUntil { model.endpoints[endpoint]?.phase == .disconnected }
        XCTAssertTrue(done)
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .remoteClosed)
    }

    func testNonZeroRemoteExitIsServerShutdownNotCleanEOF() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: try fenceScript(), holdOpen: false, exitStatus: 3)
        let endpoint = HerdrEndpointID(rawValue: "eof-3")
        model.connect(endpoint: endpoint, transport: transport)

        let done = await waitUntil { model.endpoints[endpoint]?.phase == .disconnected }
        XCTAssertTrue(done)
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .serverShutdown)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1)
    }

    func testChannelDeathWithoutExitStatusIsNetworkLoss() async throws {
        let model = makeModel()
        struct Lost: Error {}
        let transport = HerdrReplayTransport(
            script: try fenceScript(), holdOpen: false, failWith: Lost()
        )
        let endpoint = HerdrEndpointID(rawValue: "netloss")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .transportLost)
    }

    func testProtocolViolationMidSessionFailsClosedAndDisablesInput() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: try fenceScript() + [Data([0xFF, 0xFF, 0xFF, 0x7F])])
        let endpoint = HerdrEndpointID(rawValue: "violation")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a mid-session protocol violation must fail closed")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)
        let closed = await waitUntil { transport.isClosed }
        XCTAssertTrue(closed, "fail-closed disconnects the channel")

        let echoBefore = model.debugInputEcho
        model.sendText("nope", endpoint: endpoint)
        XCTAssertEqual(model.debugInputEcho, echoBefore, "input is disabled when ordering cannot be guaranteed")
    }

    /// The taxonomy's input guard, one state at a time: for every
    /// ordering-undefined state, a send is inert (no echo growth, no wire
    /// write on any transport the endpoint could still hold).
    func testInputIsDisabledInEveryOrderingUndefinedTaxonomyState() async throws {
        let cases: [(String, @MainActor (HerdrSessionModel, HerdrEndpointID) async throws -> Void)] = [
            ("userDetach", { model, endpoint in
                _ = try await self.connectThroughFence(model, endpoint: endpoint)
                await model.detach(endpoint: endpoint, reason: .user)
            }),
            ("serverShutdown", { model, endpoint in
                let transport = HerdrReplayTransport(script: try self.fenceScript(), holdOpen: false, exitStatus: 9)
                model.connect(endpoint: endpoint, transport: transport)
                _ = await self.waitUntil { model.endpoints[endpoint]?.phase == .disconnected }
            }),
            ("networkLoss", { model, endpoint in
                struct Lost: Error {}
                let transport = HerdrReplayTransport(script: try self.fenceScript(), holdOpen: false, failWith: Lost())
                model.connect(endpoint: endpoint, transport: transport)
                _ = await self.waitUntil { model.endpoints[endpoint]?.phase == .failed }
            }),
            ("protocolViolation", { model, endpoint in
                let transport = HerdrReplayTransport(script: try self.fenceScript() + [Data([0xFF, 0xFF, 0xFF, 0x7F])])
                model.connect(endpoint: endpoint, transport: transport)
                _ = await self.waitUntil { model.endpoints[endpoint]?.phase == .failed }
            }),
            ("authLost", { model, endpoint in
                _ = try await self.connectThroughFence(model, endpoint: endpoint)
                await model.detach(endpoint: endpoint, reason: .user)
                model.reconnectSources[endpoint] = HerdrReconnectSource {
                    throw HerdrReconnectSource.OpenError.authenticationLost
                }
                model.reconnect(endpoint: endpoint)
                _ = await self.waitUntil { model.endpoints[endpoint]?.diagnostic?.kind == .authLost }
            }),
        ]

        for (name, arrange) in cases {
            let model = makeModel()
            let endpoint = HerdrEndpointID(rawValue: "gate-\(name)")
            try await arrange(model, endpoint)

            let phase = model.endpoints[endpoint]?.phase
            XCTAssertTrue(
                phase == .failed || phase == .disconnected,
                "\(name): the endpoint must sit in an ordering-undefined state"
            )
            let echoBefore = model.debugInputEcho
            model.sendText("x", endpoint: endpoint)
            model.pasteText("x", endpoint: endpoint)
            model.sendKey(HerdrKeyInput(code: .enter), endpoint: endpoint)
            XCTAssertEqual(
                model.debugInputEcho, echoBefore,
                "\(name): semantic input must be disabled in this state"
            )
        }
    }

    // MARK: - Bounded backoff (doc §6.3: no retry storms)

    func testAuthLossStopsTheReconnectLoopImmediatelyAsAttentionState() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "auth")
        let source = HerdrReconnectSource {
            throw HerdrReconnectSource.OpenError.authenticationLost
        }
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.detach(endpoint: endpoint, reason: .user)
        model.reconnectSources[endpoint] = source

        model.reconnect(endpoint: endpoint)
        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .authLost)
        XCTAssertEqual(model.endpoints[endpoint]?.reconnectAttempt, nil)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            model.debugLifecycleLog.filter { $0.hasPrefix("reconnect:attempt:") }.count, 1,
            "auth loss is never retried"
        )
    }

    func testReconnectBackoffIsBoundedAndStopsExactlyAtMaxAttempts() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "storm")
        var factoryCalls = 0
        let source = HerdrReconnectSource { () throws -> HerdrReplayTransport in
            factoryCalls += 1
            struct Unreachable: Error {}
            throw Unreachable()
        }
        // Seed the endpoint's published state with a connection first (the
        // loop only mutates existing endpoint state).
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.detach(endpoint: endpoint, reason: .user)
        model.reconnectSources[endpoint] = source

        model.reconnect(endpoint: endpoint)
        let failed = await waitUntil(timeout: 8) { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "the loop terminates in a failure state")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .transportLost)
        XCTAssertEqual(factoryCalls, 3, "exactly maxAttempts transport creations — no retry storm")

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(factoryCalls, 3, "no further attempts appear after the bound")
    }

    func testReconnectWhileReconnectingIsLatched() async throws {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "latch")
        var factoryCalls = 0
        let source = HerdrReconnectSource { () throws -> HerdrReplayTransport in
            factoryCalls += 1
            struct Unreachable: Error {}
            throw Unreachable()
        }
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.detach(endpoint: endpoint, reason: .user)
        model.reconnectSources[endpoint] = source

        model.reconnect(endpoint: endpoint)
        model.reconnect(endpoint: endpoint)
        model.reconnect(endpoint: endpoint)
        _ = await waitUntil(timeout: 8) { model.endpoints[endpoint]?.phase == .failed }

        XCTAssertEqual(factoryCalls, 3, "concurrent reconnect calls share one loop")
        XCTAssertEqual(
            model.debugLifecycleLog.filter { $0.hasPrefix("reconnect:start:") }.count, 1
        )
    }

    func testManualCancelStopsTheBackoffLoop() async throws {
        let model = makeModel(backoff: .init(
            maxAttempts: 3, base: .milliseconds(700), cap: .seconds(2), jitter: .milliseconds(10)
        ))
        let endpoint = HerdrEndpointID(rawValue: "cancel")
        var factoryCalls = 0
        let source = HerdrReconnectSource { () throws -> HerdrReplayTransport in
            factoryCalls += 1
            struct Unreachable: Error {}
            throw Unreachable()
        }
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.detach(endpoint: endpoint, reason: .user)
        model.reconnectSources[endpoint] = source

        model.reconnect(endpoint: endpoint)
        let firstAttempt = await waitUntil { factoryCalls == 1 }
        XCTAssertTrue(firstAttempt)
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .reconnecting)

        model.cancelReconnect(endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .disconnected)
        try? await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(factoryCalls, 1, "cancel stops the bounded backoff for good")
        XCTAssertTrue(lifecycleEcho(model, contains: "reconnect:cancel"))
    }

    // MARK: - Preflight probe state (doc §11)

    func testProbeFailureFailsTheEndpointBeforeAnyBridgeOpens() {
        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "probe-missing")
        let result = HerdrProbe.Result(
            host: "fixture-no-herdr",
            rawOS: "Linux",
            rawArch: "aarch64",
            foundPath: nil,
            version: nil,
            endpointGeneration: nil,
            capabilities: []
        )

        model.failProbe(endpoint: endpoint, result: result)

        XCTAssertEqual(model.endpoints[endpoint]?.phase, .failed)
        XCTAssertEqual(model.endpoints[endpoint]?.probe?.host, "fixture-no-herdr")
        XCTAssertFalse(model.endpoints[endpoint]?.probe?.isCompatible ?? true)
        XCTAssertNil(model.endpoints[endpoint]?.diagnostic)
        XCTAssertNil(model.runtimes[endpoint], "no bridge channel was ever opened")
        XCTAssertEqual(model.selectedEndpointID, endpoint)
    }
}
