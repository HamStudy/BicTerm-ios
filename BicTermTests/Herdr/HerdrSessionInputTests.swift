import BicTermCore
import HerdrClientCore
import XCTest

@testable import BicTerm

/// T17 semantic input over the replay transport: gate ordering (runtime →
/// online → surface), the presentation-fence frozen window (app gate and the
/// FFI's own frozen bounce), golden wire frames after the fence, focus
/// targeting, ordering, and live resize. The staleTarget/writeFailed notes
/// are covered at the echo-mapping level — enqueue-time target validation
/// makes the in-flight race unrepresentable on a deterministic replay.
@MainActor
final class HerdrSessionInputTests: XCTestCase {
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

    /// The full presentation fence: both surface-set acks, the evidence
    /// resend, and the ready control. Every chunk produces a render-state
    /// apply, so `debugAppliedChunks == 8` means the input lane is unfrozen.
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

    private func connectThroughFence(
        _ model: HerdrSessionModel,
        endpoint: HerdrEndpointID
    ) async throws -> HerdrReplayTransport {
        let transport = HerdrReplayTransport(script: try fenceScript())
        model.connect(endpoint: endpoint, transport: transport)
        let applied = await waitUntil { model.debugAppliedChunks >= 8 }
        XCTAssertTrue(applied, "the fence must fully apply before input is sent")
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online)
        // The fence's surface resend is byte-identical: surfaceRevision stays
        // 1; `debugAppliedChunks == 8` is the fence-complete signal.
        XCTAssertNotNil(model.endpoints[endpoint]?.surface)
        return transport
    }

    // MARK: - Gates

    func testInputWithoutRuntimeIsSilent() throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "never-connected")
        model.sendText("hi", endpoint: endpoint)
        model.sendKey(HerdrKeyInput(code: .esc), endpoint: endpoint)
        model.setInputTarget(paneID: "w1:p1", endpoint: endpoint)
        model.moveInputTarget(.left, endpoint: endpoint)
        XCTAssertTrue(model.debugInputEcho.isEmpty, "no runtime, no note, no echo")
        XCTAssertNil(model.endpoints[endpoint])
    }

    func testInputBeforeOnlineRecordsOfflineNote() async throws {
        let model = HerdrSessionModel()
        let transport = HerdrReplayTransport(script: [], stall: true)
        let endpoint = HerdrEndpointID(rawValue: "connecting")
        model.connect(endpoint: endpoint, transport: transport)
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .connecting)
        let helloWritten = await waitUntil { transport.writeLedger.count == 1 }
        XCTAssertTrue(helloWritten, "the conservative hello lands even while the server stalls")

        model.sendText("hi", endpoint: endpoint)
        XCTAssertEqual(model.debugInputEcho, ["offline"])
        XCTAssertEqual(model.endpoints[endpoint]?.inputNote, .offline)
        XCTAssertEqual(transport.writeLedger.count, 1, "only the hello may reach the wire")

        await model.disconnectAll()
    }

    func testInputBeforeSurfaceRecordsFrozenAtTheGate() async throws {
        let model = HerdrSessionModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "pre-surface")
        model.connect(endpoint: endpoint, transport: transport)
        let online = await waitUntil { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online)
        XCTAssertNil(model.endpoints[endpoint]?.surface)

        model.sendText("hi", endpoint: endpoint)
        XCTAssertEqual(model.debugInputEcho, ["frozen"], "the gate rejects before the FFI is touched")
        XCTAssertEqual(model.endpoints[endpoint]?.inputNote, .frozen)
        XCTAssertFalse(
            transport.writeLedger.contains(try herdrGolden("input-text-hi-p2")),
            "a gate-rejected event never queues a wire frame"
        )

        await model.disconnectAll()
    }

    func testInputDuringFenceBouncesFrozenFromTheFFI() async throws {
        let model = HerdrSessionModel()
        // The committed surface without the fence tail: the app gate passes
        // (online + surface + resolvable target) but the FFI input lane stays
        // frozen until the ready control arrives.
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("surface-ack-2x2"),
            try herdrGolden("surface-2x2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "mid-fence")
        model.connect(endpoint: endpoint, transport: transport)
        let committed = await waitUntil { model.endpoints[endpoint]?.surface != nil }
        XCTAssertTrue(committed)

        model.sendText("hi", endpoint: endpoint)
        let bounced = await waitUntil { model.debugInputEcho.contains("frozen") }
        XCTAssertTrue(bounced, "the FFI must bounce the event with inputFrozen")
        XCTAssertEqual(model.endpoints[endpoint]?.inputNote, .frozen)
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online, "a frozen bounce is not a failure")
        XCTAssertFalse(
            transport.writeLedger.contains(try herdrGolden("input-text-hi-p2")),
            "a frozen event is rejected, never queued"
        )

        await model.disconnectAll()
    }

    // MARK: - Golden wire frames after the fence

    func testTextCommitAfterFenceWritesTheGoldenFrame() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "text")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.sendText("hi", endpoint: endpoint)
        let written = await waitUntil {
            transport.writeLedger.contains((try? self.herdrGolden("input-text-hi-p2")) ?? Data())
        }
        XCTAssertTrue(written, "the FFI-queued text frame must be byte-identical to the golden")
        XCTAssertTrue(model.debugInputEcho.contains("text(\"hi\"→w1:p2)"))
        XCTAssertNil(model.endpoints[endpoint]?.inputNote)

        await model.disconnectAll()
    }

    func testCJKCommitAfterFenceWritesTheGoldenFrame() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "cjk")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.sendText("こんにちは世界", endpoint: endpoint)
        let written = await waitUntil {
            transport.writeLedger.contains((try? self.herdrGolden("input-text-cjk-p2")) ?? Data())
        }
        XCTAssertTrue(written, "IME-committed text crosses the FFI unmodified")
        XCTAssertTrue(model.debugInputEcho.contains("text(\"こんにちは世界\"→w1:p2)"))

        await model.disconnectAll()
    }

    func testKeyEventsAfterFenceWriteTheGoldenFrames() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "keys")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        let cases: [(HerdrKeyInput, String, String)] = [
            (HerdrKeyInput(code: .char("c"), modifiers: 2), "input-key-ctrl-c-p2", "key(ctrl+c→w1:p2)"),
            (HerdrKeyInput(code: .esc), "input-key-esc-p2", "key(esc→w1:p2)"),
            (HerdrKeyInput(code: .home), "input-key-home-p2", "key(home→w1:p2)"),
            (HerdrKeyInput(code: .end), "input-key-end-p2", "key(end→w1:p2)"),
            (HerdrKeyInput(code: .pageUp), "input-key-pageup-p2", "key(pageup→w1:p2)"),
            (HerdrKeyInput(code: .pageDown), "input-key-pagedown-p2", "key(pagedown→w1:p2)"),
            (HerdrKeyInput(code: .up), "input-key-up-p2", "key(up→w1:p2)"),
            (HerdrKeyInput(code: .down), "input-key-down-p2", "key(down→w1:p2)"),
            (HerdrKeyInput(code: .left), "input-key-left-p2", "key(left→w1:p2)"),
            (HerdrKeyInput(code: .right), "input-key-right-p2", "key(right→w1:p2)"),
        ]
        var goldens: [Data] = []
        for (key, fixture, _) in cases {
            goldens.append(try herdrGolden(fixture))
            model.sendKey(key, endpoint: endpoint)
        }

        for (index, golden) in goldens.enumerated() {
            let written = await waitUntil { transport.writeLedger.contains(golden) }
            XCTAssertTrue(written, "\(cases[index].1) must reach the wire byte-identical to the golden")
        }
        for (_, _, echo) in cases {
            XCTAssertTrue(model.debugInputEcho.contains(echo), "missing echo \(echo)")
        }

        await model.disconnectAll()
    }

    func testInputOrderingMatchesEnqueueOrder() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "ordering")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.sendText("hi", endpoint: endpoint)
        model.sendKey(HerdrKeyInput(code: .esc), endpoint: endpoint)

        let textFrame = try herdrGolden("input-text-hi-p2")
        let keyFrame = try herdrGolden("input-key-esc-p2")
        let written = await waitUntil {
            let ledger = transport.writeLedger
            return ledger.contains(textFrame) && ledger.contains(keyFrame)
        }
        XCTAssertTrue(written)

        let ledger = transport.writeLedger
        let textIndex = try XCTUnwrap(ledger.firstIndex(of: textFrame))
        let keyIndex = try XCTUnwrap(ledger.firstIndex(of: keyFrame))
        XCTAssertLessThan(textIndex, keyIndex, "the single writer preserves enqueue FIFO order")

        let echo = model.debugInputEcho
        let textEcho = try XCTUnwrap(echo.firstIndex(of: "text(\"hi\"→w1:p2)"))
        let keyEcho = try XCTUnwrap(echo.firstIndex(of: "key(esc→w1:p2)"))
        XCTAssertLessThan(textEcho, keyEcho)

        await model.disconnectAll()
    }

    // MARK: - Focus targeting

    func testTargetOverrideRoutesTextToTheChosenPane() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "tap-target")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.setInputTarget(paneID: "w1:p1", endpoint: endpoint)
        XCTAssertEqual(model.debugInputEcho, ["target(w1:p1)"])
        XCTAssertEqual(model.endpoints[endpoint]?.inputTargetPaneID, "w1:p1")

        model.sendText("q", endpoint: endpoint)
        let written = await waitUntil {
            transport.writeLedger.contains((try? self.herdrGolden("input-text-q-p1")) ?? Data())
        }
        XCTAssertTrue(written)
        XCTAssertTrue(model.debugInputEcho.contains("text(\"q\"→w1:p1)"))

        model.setInputTarget(paneID: "w1:p9", endpoint: endpoint)
        XCTAssertEqual(
            model.endpoints[endpoint]?.inputTargetPaneID, "w1:p1",
            "a pane that is not on the surface is ignored"
        )
        XCTAssertFalse(model.debugInputEcho.contains("target(w1:p9)"))

        await model.disconnectAll()
    }

    func testSpatialNavigationWalksTheGrid() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "nav")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        // 2x2 grid: p1 top-left, p2 top-right (focused), p3 bottom-left,
        // p4 bottom-right. The default target is the snapshot focus p2.
        XCTAssertEqual(model.endpoints[endpoint]?.inputTargetPaneID, "w1:p2")

        model.moveInputTarget(.left, endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.inputTargetPaneID, "w1:p1")
        model.moveInputTarget(.down, endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.inputTargetPaneID, "w1:p3")
        model.moveInputTarget(.right, endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.inputTargetPaneID, "w1:p4")
        model.moveInputTarget(.up, endpoint: endpoint)
        XCTAssertEqual(model.endpoints[endpoint]?.inputTargetPaneID, "w1:p2")
        XCTAssertEqual(
            model.debugInputEcho,
            ["target(w1:p1)", "target(w1:p3)", "target(w1:p4)", "target(w1:p2)"]
        )

        let echoCount = model.debugInputEcho.count
        model.moveInputTarget(.up, endpoint: endpoint)
        XCTAssertEqual(model.debugInputEcho.count, echoCount, "no pane above p2 — nothing moves")

        model.sendText("hi", endpoint: endpoint)
        let written = await waitUntil {
            transport.writeLedger.contains((try? self.herdrGolden("input-text-hi-p2")) ?? Data())
        }
        XCTAssertTrue(written, "after the walk the target is back on the focused pane")

        await model.disconnectAll()
    }

    // MARK: - Resize

    func testResizeAfterFenceWritesTheGoldenFrame() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "resize-live")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.resize(cols: 100, rows: 30)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredCols, 100)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredRows, 30)

        let written = await waitUntil {
            transport.writeLedger.contains((try? self.herdrGolden("input-resize-100x30")) ?? Data())
        }
        XCTAssertTrue(written, "a live resize routes through the FFI on the input lane")
        XCTAssertTrue(model.debugInputEcho.contains("resize(100x30)"))

        await model.disconnectAll()
    }

    func testResizeBeforeSurfaceOnlyUpdatesDesiredGeometry() async throws {
        let model = HerdrSessionModel()
        let transport = HerdrReplayTransport(script: [try vendorGolden("server-20")])
        let endpoint = HerdrEndpointID(rawValue: "resize-early")
        model.connect(endpoint: endpoint, transport: transport)
        let online = await waitUntil { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online)

        model.resize(cols: 0, rows: 0)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredCols, 80, "non-positive sizes are ignored")

        model.resize(cols: 100, rows: 30)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredCols, 100)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredRows, 30)
        XCTAssertFalse(
            model.debugInputEcho.contains { $0.hasPrefix("resize(") },
            "mid-activation resizes stay out of the FFI — the next hello carries them"
        )

        await model.disconnectAll()
    }

    func testInputAfterDisconnectIsSilent() async throws {
        let model = HerdrSessionModel()
        let endpoint = HerdrEndpointID(rawValue: "torn-down")
        _ = try await connectThroughFence(model, endpoint: endpoint)
        await model.disconnectAll()

        model.sendText("hi", endpoint: endpoint)
        model.sendKey(HerdrKeyInput(code: .esc), endpoint: endpoint)
        XCTAssertTrue(model.debugInputEcho.isEmpty, "a torn-down runtime swallows input silently")
    }

    // MARK: - Echo contract (UI tests match on these strings)

    func testEchoStringsCoverTheEventAndNoteMatrix() {
        XCTAssertEqual(
            HerdrSessionModel.echoLine(for: .text("hi", paneID: "w1:p2")),
            "text(\"hi\"→w1:p2)"
        )
        XCTAssertEqual(
            HerdrSessionModel.echoLine(for: .key(HerdrKeyInput(code: .esc), paneID: "w1:p2")),
            "key(esc→w1:p2)"
        )
        XCTAssertEqual(
            HerdrSessionModel.echoLine(for: .resize(cols: 100, rows: 30)),
            "resize(100x30)"
        )
        XCTAssertEqual(HerdrSessionModel.echoLine(for: .offline), "offline")
        XCTAssertEqual(HerdrSessionModel.echoLine(for: .frozen), "frozen")
        XCTAssertEqual(
            HerdrSessionModel.echoLine(for: .staleTarget("w1:p3")),
            "staleTarget(w1:p3)"
        )
        XCTAssertEqual(
            HerdrSessionModel.echoLine(for: .writeFailed("boom")),
            "writeFailed(boom)"
        )

        XCTAssertEqual(
            HerdrSessionModel.echoDescriptor(for: HerdrKeyInput(code: .char("c"), modifiers: 2)),
            "ctrl+c"
        )
        XCTAssertEqual(
            HerdrSessionModel.echoDescriptor(for: HerdrKeyInput(code: .enter, modifiers: 15)),
            "ctrl+alt+shift+super+enter",
            "modifier order is fixed so UI assertions are stable"
        )
        XCTAssertEqual(
            HerdrSessionModel.echoDescriptor(for: HerdrKeyInput(code: .function(5))),
            "f5"
        )
        XCTAssertEqual(
            HerdrSessionModel.echoDescriptor(for: HerdrKeyInput(code: .backTab, modifiers: 1)),
            "shift+backtab"
        )
    }
}
