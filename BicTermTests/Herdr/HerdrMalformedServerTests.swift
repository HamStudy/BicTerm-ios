import BicTermCore
import HerdrClientCore
import XCTest

@testable import BicTerm

/// T20 malformed-server suite: hostile server frames through a fake
/// transport (``HerdrReplayTransport``) driving the FULL decoder + FFI path
/// (`HerdrSessionModel.connect` → inbound pump → `HerdrClient.receive` →
/// the Rust core). Every vector must fail closed: a typed diagnostic, the
/// transport closed, no partial state rendered, and bounded buffering (the
/// decoder never buffers more than the bytes actually fed — the T14
/// bounded-PENDING-INBOUND rule; true RSS bounds belong to the fuzz
/// evidence, not the simulator).
///
/// Wire construction note: herdr frames are
/// `[u32LE length][bincode payload]`; `ServerMessage::EndpointControl` is
/// variant 20 (single varint byte `0x14`) followed by two
/// varint-length-prefixed strings (`kind`, `data`) — see
/// `Vendor/herdr/herdr-protocol/src/framing.rs` and `server.rs`.
@MainActor
final class HerdrMalformedServerTests: XCTestCase {
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

    // MARK: - Wire constructors

    private func frame(_ payload: [UInt8]) -> Data {
        var data = Data()
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }

    private func control(_ kind: String, _ data: String) -> Data {
        var payload: [UInt8] = [0x14] // EndpointControl variant tag
        payload.append(contentsOf: varint(kind.utf8.count))
        payload.append(contentsOf: Array(kind.utf8))
        payload.append(contentsOf: varint(data.utf8.count))
        payload.append(contentsOf: Array(data.utf8))
        return frame(payload)
    }

    /// LEB128 varint, matching bincode's Varint integer encoding.
    private func varint(_ value: Int) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private let validWelcomeJSON = """
        {"generation":1,"server_version":"0.9.0","snapshot_codec":"shell.snapshot.v1",\
        "surface_codec":"shell.surface.v1","input_codec":"shell.input.semantic.v1",\
        "blob_codec":"shell.blob.v1","methods":["client_shell.surface.set"],\
        "capabilities":["surface_interest","presentation_effects_fence","health_check"]}
        """

    // MARK: 1-2. Length-prefix violations

    func testOversizedClaimedLengthFailsClosedMidSession() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            Data([0xFF, 0xFF, 0xFF, 0x7F]), // claims a ~2 GiB frame
        ])
        let endpoint = HerdrEndpointID(rawValue: "malformed-oversized")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "an oversized claimed length must fail the endpoint")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .protocolViolation)
        XCTAssertEqual(model.endpoints[endpoint]?.snapshot?.revision, 1, "last good state stays as stale metadata")

        await model.disconnectAll()
    }

    func testTruncatedFrameTailStaysBufferedThenEndsCleanly() async throws {
        let model = makeModel()
        let snapshot = try herdrGolden("snapshot-2x2")
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            snapshot.prefix(11),
        ], holdOpen: false)
        let endpoint = HerdrEndpointID(rawValue: "malformed-truncated")
        model.connect(endpoint: endpoint, transport: transport)

        let settled = await waitUntil { model.endpoints[endpoint]?.phase == .disconnected }
        XCTAssertTrue(settled, "a partial frame followed by EOF ends the session, it never fails it")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .remoteClosed)

        await model.disconnectAll()
    }

    // MARK: 3. Trailing data inside the payload

    func testTrailingBytesInsidePayloadAreRejected() async throws {
        var patched = try vendorGolden("server-20")
        let claimed = patched.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        let inflated = claimed + 2
        patched.replaceSubrange(0..<4, with: withUnsafeBytes(of: inflated.littleEndian) { Data($0) })
        patched.append(contentsOf: [0x00, 0x00])

        let model = makeModel()
        let transport = HerdrReplayTransport(script: [patched])
        let endpoint = HerdrEndpointID(rawValue: "malformed-trailing")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "trailing bytes after the decoded message are a protocol violation")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .protocolViolation)

        await model.disconnectAll()
    }

    // MARK: 4. Unknown enum variant

    func testUnknownServerVariantTagFailsClosed() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [frame([0x63])]) // variant 99
        let endpoint = HerdrEndpointID(rawValue: "malformed-unknown-tag")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "an unknown enum variant must fail the session")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)
        XCTAssertNil(model.endpoints[endpoint]?.snapshot)

        await model.disconnectAll()
    }

    // MARK: 5-7. Handshake-order and welcome-content violations

    func testSnapshotBeforeWelcomeFailsTheHandshake() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [try herdrGolden("snapshot-2x2")])
        let endpoint = HerdrEndpointID(rawValue: "malformed-out-of-order")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a snapshot arriving before the welcome violates the handshake")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .handshakeTimedOut, "expected-welcome maps to the handshake diagnostic")

        await model.disconnectAll()
    }

    func testWelcomeWithMalformedJSONFailsHandshake() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            control("endpoint.welcome.v1", "not-json-at-all {{{"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "malformed-welcome-json")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a welcome whose body is not JSON must fail the handshake")
        let diagnostic = try XCTUnwrap(model.endpoints[endpoint]?.diagnostic)
        XCTAssertEqual(diagnostic.kind, .incompatibleGeneration)

        await model.disconnectAll()
    }

    func testWelcomeWithMismatchedGenerationFailsClosedAndStopsWriting() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [try herdrGolden("welcome-gen99")])
        let endpoint = HerdrEndpointID(rawValue: "malformed-gen99")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .incompatibleGeneration)
        let writesSettled = await waitUntil { transport.writeLedger.count >= 1 }
        XCTAssertTrue(writesSettled)
        let writesAfterFailure = transport.writeLedger.count
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            transport.writeLedger.count, writesAfterFailure,
            "no further client frames may be written after the version gate rejects"
        )

        await model.disconnectAll()
    }

    // MARK: 8-9. Post-handshake ordering and carrier violations

    func testSecondWelcomeAfterHandshakeIsAProtocolViolation() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try vendorGolden("server-20"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "malformed-second-welcome")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a welcome after the handshake completed is a violation")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)

        await model.disconnectAll()
    }

    func testSnapshotControlWithInvalidJSONFailsClosed() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            control("shell.snapshot.v1", "{\"revision\": truncated"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "malformed-snapshot-json")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a snapshot carrier with invalid JSON must fail the session")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)

        await model.disconnectAll()
    }

    // MARK: 10. Hostile container-length claim (the fuzz finding, app lane)

    func testHostileContainerLengthClaimFailsClosedWithBoundedBuffer() async throws {
        let hostile = frame([0x14] + [UInt8](repeating: 0xFF, count: 9) + [0x01])

        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            hostile,
        ])
        let endpoint = HerdrEndpointID(rawValue: "malformed-huge-claim")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "a near-u64::MAX string claim must fail closed, not allocate")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)

        await model.disconnectAll()

        // FFI-lane bound: the decoder buffers at most the fed bytes.
        let client = try HerdrClient(config: HerdrClientConfig(
            cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16
        ))
        defer { client.destroy() }
        do {
            try await client.receive(hostile)
            XCTFail("expected a protocolViolation from the hostile claim")
        } catch let error as HerdrClientError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        let pendingAfterFailure = await client.pendingInbound
        XCTAssertEqual(
            pendingAfterFailure, 0,
            "a failed decode clears the inbound buffer; nothing speculative is retained"
        )

        let truncated = try herdrGolden("snapshot-2x2").prefix(11)
        try await client.receive(truncated)
        let pendingAfterPartial = await client.pendingInbound
        XCTAssertEqual(
            pendingAfterPartial, UInt64(truncated.count),
            "a partial frame buffers exactly the fed bytes and no more"
        )
    }

    // MARK: 11-12. Degenerate frames

    func testZeroLengthFrameFailsClosed() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [frame([])])
        let endpoint = HerdrEndpointID(rawValue: "malformed-zero-length")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "an empty payload cannot decode a message")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)

        await model.disconnectAll()
    }

    func testGarbageFirstBytesFailClosed() async throws {
        let garbage: [UInt8] = (0..<96).map { UInt8(($0 &* 37 &+ 11) & 0xFF) }
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [frame(garbage)])
        let endpoint = HerdrEndpointID(rawValue: "malformed-garbage")
        model.connect(endpoint: endpoint, transport: transport)

        let failed = await waitUntil { model.endpoints[endpoint]?.phase == .failed }
        XCTAssertTrue(failed, "undecodable leading bytes must fail the session")
        XCTAssertEqual(model.endpoints[endpoint]?.diagnostic?.kind, .protocolViolation)
        XCTAssertTrue(transport.isClosed, "the transport is torn down after the failure")
        XCTAssertNil(model.endpoints[endpoint]?.snapshot, "nothing from the hostile server renders")

        await model.disconnectAll()
    }

    // MARK: 13. Non-fatal malformed clipboard

    func testMalformedClipboardBase64DropsTheFrameAndKeepsTheSession() async throws {
        let model = makeModel()
        let transport = HerdrReplayTransport(script: [
            try vendorGolden("server-20"),
            try herdrGolden("snapshot-2x2"),
            try herdrGolden("clipboard-osc52-malformed"),
        ])
        let endpoint = HerdrEndpointID(rawValue: "malformed-clipboard")
        model.connect(endpoint: endpoint, transport: transport)

        let online = await waitUntil { model.endpoints[endpoint]?.phase == .online }
        XCTAssertTrue(online, "a malformed clipboard frame is dropped, not fatal")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online)
        XCTAssertEqual(model.endpoints[endpoint]?.inputNote?.clipboardDroppedDetail != nil, true)

        await model.disconnectAll()
    }
}

private extension HerdrInputNote {
    var clipboardDroppedDetail: String? {
        if case .clipboardDropped(let detail) = self { return detail }
        return nil
    }
}
