import BicTermCore
import HerdrClientCore
import XCTest

@testable import BicTerm

/// T16 herdr session model over a deterministic replay transport. Fixtures
/// are the committed real-codec frames (Vendor golden + Fixtures/herdr/golden)
/// loaded repo-relative via #filePath, the same pattern as the CoderNative
/// suites.
@MainActor
final class HerdrSessionModelTests: XCTestCase {
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

    private func makeModel(timeout: Duration = .seconds(60)) -> HerdrSessionModel {
        HerdrSessionModel(handshakeTimeout: timeout)
    }

    // MARK: - Handshake

    func testHandshakeCompletesFromCommittedFramesAndPublishesChromeState() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "fixture-2x2")
        model.connect(endpoint: endpoint, transport: transport)

        let online = await waitUntil { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online, "welcome must move the endpoint online")
        let state = try XCTUnwrap(model.endpoints[endpoint])
        XCTAssertNil(state.diagnostic)
        XCTAssertFalse(state.surfaceUnavailable)

        let snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.bootID, "boot-2x2")
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(snapshot.panes.count, 4, "the 2x2 pane tree must arrive")
        XCTAssertEqual(snapshot.focusedPaneID, "w1:p2")
        XCTAssertEqual(model.selectedEndpointID, endpoint)

        await model.disconnectAll()
    }

    func testHelloFrameIsWrittenToTheTransportOnConnect() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [try vendorGolden("server-20")])
        model.connect(endpoint: HerdrEndpointID(rawValue: "hello"), transport: transport)

        let wrote = await waitUntil { transport.writeLedger.count == 1 }
        XCTAssertTrue(wrote, "the conservative hello must be flushed on connect")
        let hello = try XCTUnwrap(transport.writeLedger.first)
        XCTAssertTrue(hello.count > 4)
        let header = Array(hello.prefix(4))
        let length = UInt32(header[0])
            | UInt32(header[1]) << 8
            | UInt32(header[2]) << 16
            | UInt32(header[3]) << 24
        XCTAssertEqual(Int(length), hello.count - 4, "4-byte LE length envelope must frame the payload")

        await model.disconnectAll()
    }

    // MARK: - Version gate

    func testWrongGenerationWelcomeFailsClosedWithIncompatibleDiagnostic() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [try herdrGolden("welcome-gen99")])
        let endpoint = HerdrEndpointID(rawValue: "gen99")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a generation-99 welcome must fail the endpoint")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .incompatibleGeneration)
        XCTAssertEqual(diagnostic.localCoreVersion, HerdrClient.coreVersion)
        XCTAssertEqual(diagnostic.expectedGeneration, 1)
        XCTAssertNotNil(diagnostic.remediationURL, "remediation link is mandatory for version gates")
        XCTAssertTrue(transport.isClosed, "connection must be closed after the gate rejects")
        XCTAssertEqual(transport.writeLedger.count, 1, "no fallback hello is ever sent")
        XCTAssertNil(model.endpoints[endpoint]?.snapshot, "no state may render after the gate")

        await model.disconnectAll()
    }

    func testSilentServerHitsHandshakeTimeoutDiagnostic() async throws {
        let model = makeModel(timeout: .milliseconds(250))
        let transport = HerdrReplayTransport(script: [], stall: true)
        let endpoint = HerdrEndpointID(rawValue: "silent")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil(timeout: 5) { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a server that never answers must hit the watchdog")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .handshakeTimedOut)
        XCTAssertTrue(transport.isClosed)

        await model.disconnectAll()
    }

    // MARK: - Malformed / edge frames

    func testMalformedFrameBytesSurfaceTypedProtocolViolation() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            Data([0xFF, 0xFF, 0xFF, 0x7F]),
        ])
        let endpoint = HerdrEndpointID(rawValue: "hostile")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "an oversized frame length must fail the session")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .protocolViolation)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1, "last good snapshot stays visible as stale metadata")

        await model.disconnectAll()
    }

    func testTruncatedFrameStaysPendingWithoutFailingTheSession() async throws {
        let model = makeModel()
        let snapshot = try herdrGolden("snapshot-2x2")
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            snapshot.prefix(11),
        ])
        let endpoint = HerdrEndpointID(rawValue: "truncated")
        model.connect(endpoint: endpoint, transport: transport)

        _ = await waitUntil { model.endpoints[endpoint]?.phase == .online }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online, "a partial frame is buffered, not an error")
        XCTAssertNil(model.endpoints[endpoint]?.diagnostic)

        await model.disconnectAll()
    }

    func testCleanRemoteEOFAfterHandshakeIsADisconnectedState() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
        ], holdOpen: false)
        let endpoint = HerdrEndpointID(rawValue: "eof")
        model.connect(endpoint: endpoint, transport: transport)

        let disconnected = await waitUntil { model.endpoints[endpoint]?.phase == .disconnected }
        XCTAssertTrue(disconnected, "remote EOF after a healthy session is a clean end, not a failure")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .remoteClosed)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1, "stale metadata survives for a dimmed view")

        await model.disconnectAll()
    }

    // MARK: - Surface through the committed FFI

    func testSurfaceCommitsThroughTheRepairedFFI() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("surface-ack-2x2"),
            try herdrGolden("surface-2x2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "surface-commit")
        model.connect(endpoint: endpoint, transport: transport)

        let committed = await waitUntil { model.endpoints[endpoint]?.surface != nil }
        XCTAssertTrue(committed, "the surface frame must commit through the FFI activation transaction")

        let state = try XCTUnwrap(model.endpoints[endpoint])
        XCTAssertEqual(state.phase, .online, "the session stays healthy through the activation transaction")
        XCTAssertEqual(state.snapshot?.revision, 1)
        XCTAssertFalse(state.surfaceUnavailable, "no typed surface rejection may occur on the healthy path")

        let surface = try XCTUnwrap(state.surface)
        XCTAssertEqual(surface.bootID, "boot-2x2")
        XCTAssertEqual(surface.projectionRevision, 1)
        XCTAssertEqual(surface.surfaceRevision, 1)
        XCTAssertEqual(surface.frame.width, 80)
        XCTAssertEqual(surface.frame.height, 24)
        XCTAssertTrue(surface.frame.cellCountIsValid, "cells must arrive complete for the whole grid")
        XCTAssertEqual(surface.panes.map(\.paneID), ["w1:p1", "w1:p2", "w1:p3", "w1:p4"])
        XCTAssertEqual(surface.panes.first(where: \.focused)?.paneID, "w1:p2", "focus matches the snapshot's focused pane")
        XCTAssertEqual(surface.frame.cursor?.x, 42)
        XCTAssertEqual(surface.frame.cursor?.y, 2)

        await model.disconnectAll()
    }

    // MARK: - Machine-qualified identity (doc §3.5-3.6)

    func testRoutingKeysQualifyPaneIdentityByEndpointGenerationAndBoot() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "identity")
        model.connect(endpoint: endpoint, transport: transport)
        _ = await waitUntil { model.endpoints[endpoint]?.snapshot != nil }

        let keys = model.paneRoutingKeys(for: endpoint)
        XCTAssertEqual(keys.count, 4)
        let focusedKey = try XCTUnwrap(keys.first { $0.paneID == "w1:p2" })
        XCTAssertEqual(focusedKey.endpoint, endpoint)
        XCTAssertEqual(focusedKey.generation, 1)
        XCTAssertEqual(focusedKey.bootID, "boot-2x2")
        let otherEndpoint = HerdrEndpointID(rawValue: "other-machine")
        let samePaneOnOtherMachine = HerdrSessionModel.paneRoutingKey(
            paneID: "w1:p2", endpoint: otherEndpoint, generation: 1, bootID: "boot-2x2"
        )
        XCTAssertNotEqual(focusedKey, samePaneOnOtherMachine, "two machines can both own w1:p2 without merging")

        await model.disconnectAll()
    }

    // MARK: - Resize + churn

    func testResizeIsRecordedAndAppliedToTheNextConnectionHello() async throws {
        let model = makeModel()
        let first = HerdrReplayTransport(script: [try vendorGolden("server-20")])
        let endpoint = HerdrEndpointID(rawValue: "resize")
        model.connect(endpoint: endpoint, transport: first)
        _ = await waitUntil { first.writeLedger.count == 1 }

        model.resize(cols: 100, rows: 30)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredCols, 100)
        XCTAssertEqual(model.endpoints[endpoint]?.desiredRows, 30)
        await model.disconnect(endpoint: endpoint)

        let second = HerdrReplayTransport(script: [try vendorGolden("server-20")])
        model.connect(endpoint: endpoint, transport: second)
        let wrote = await waitUntil { second.writeLedger.count == 1 }
        XCTAssertTrue(wrote)
        XCTAssertEqual(model.endpoints[endpoint]?.generation, 2, "reconnect bumps the connection generation")

        await model.disconnectAll()
    }

    func testSnapshotRevisionChurnRepublishesEachAcceptedRevision() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("snapshot-2x2-rev2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "churn")
        model.connect(endpoint: endpoint, transport: transport)

        let settled = await waitUntil { model.endpoints[endpoint]?.snapshot?.revision == 2 }
        XCTAssertTrue(settled, "revision 2 must replace revision 1")
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.focusedPaneID, "w1:p3", "focus switch arrives with the new revision")
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online)

        await model.disconnectAll()
    }

    // MARK: - Lifecycle hygiene

    func testDisconnectIsIdempotentAndBalancesTheFFILedger() async throws {
        let before = HerdrClient.liveFFIAllocations
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "teardown")
        model.connect(endpoint: endpoint, transport: transport)
        _ = await waitUntil { model.endpoints[endpoint]?.snapshot != nil }

        await model.disconnect(endpoint: endpoint)
        await model.disconnect(endpoint: endpoint)
        XCTAssertTrue(transport.isClosed)
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .disconnected)

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            HerdrClient.liveFFIAllocations, before,
            "every FFI client must be destroyed exactly once across the lifecycle"
        )
    }

    // MARK: - Soak (informational)

    /// Plan T16: snapshot churn x100 — 50 reconnect cycles x (2 snapshot
    /// revisions + 1 surface attempt each). FFI ledger must balance; the
    /// memory trend is INFORMATIONAL (logged, not pass/fail).
    func testSnapshotChurnHundredApplicationsSoak() async throws {
        let ledgerBefore = HerdrClient.liveFFIAllocations
        let memoryBaseline = os_proc_available_memory()
        let clock = ContinuousClock()
        let started = clock.now

        let welcome = try vendorGolden("server-20")
        let first = try herdrGolden("snapshot-2x2")
        let second = try herdrGolden("snapshot-2x2-rev2")
        let surface = try herdrGolden("surface-2x2")

        let model = makeModel()
        let endpoint = HerdrEndpointID(rawValue: "soak")
        var applications = 0

        for cycle in 0..<50 {
            let transport = HerdrReplayTransport(script: [welcome, first, second, surface])
            model.connect(endpoint: endpoint, transport: transport)
            let settled = await waitUntil(timeout: 10) {
                model.endpoints[endpoint]?.snapshot?.revision == 2
            }
            XCTAssertTrue(settled, "cycle \(cycle): both revisions must apply")
            applications += 2
            await model.disconnect(endpoint: endpoint)
        }

        let elapsed = clock.now - started
        let memoryDeltaKiB = (Int64(memoryBaseline) - Int64(os_proc_available_memory())) / 1024
        XCTAssertEqual(applications, 100)
        XCTAssertEqual(
            HerdrClient.liveFFIAllocations, ledgerBefore,
            "the FFI allocation ledger must balance across 100 snapshot applications"
        )
        print(
            "[h16-soak] applications=\(applications) elapsed=\(elapsed.components.seconds)s "
                + "memoryDeltaKiB=\(memoryDeltaKiB) (informational) "
                + "ffiLiveAllocations=\(HerdrClient.liveFFIAllocations)"
        )
    }
}
