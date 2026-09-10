import HerdrClientCore
import XCTest

final class HerdrClientCoreSmokeTests: XCTestCase {
    /// Values of the committed golden hello fixture: the drained frame must be
    /// byte-identical to golden client-20.bin.
    private static let goldenConfig = HerdrClientConfig(
        cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16,
        pixelMouse: true, mouseCapture: true
    )

    private func golden(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "bin"),
            "committed golden fixture \(name).bin must be bundled"
        )
        return try Data(contentsOf: url)
    }

    func testCoreVersionMatchesVendoredBaseline() async {
        XCTAssertEqual(HerdrClient.coreVersion, "0.9.0")
    }

    func testGoldenHelloWelcomeSnapshotRoundTrip() async throws {
        let client = try HerdrClient(config: Self.goldenConfig)
        defer { client.destroy() }

        // Given a fresh client, the only outbound frame is the golden hello.
        let phase0 = await client.phase
        XCTAssertEqual(phase0, .awaitingWelcome)
        let outbound = try await client.drainOutbound()
        XCTAssertEqual(outbound.count, 1)
        XCTAssertEqual(outbound[0], try golden("client-20"))
        let drainedAgain = try await client.drainOutbound()
        XCTAssertTrue(drainedAgain.isEmpty)

        // When the golden welcome arrives split across two chunks.
        let welcome = try golden("server-20")
        try await client.receive(welcome.prefix(5))
        let midPhase = await client.phase
        XCTAssertEqual(midPhase, .awaitingWelcome)
        let pending = await client.pendingInbound
        XCTAssertEqual(pending, 5)
        try await client.receive(welcome.dropFirst(5))
        let onlinePhase = await client.phase
        XCTAssertEqual(onlinePhase, .online)
        let settled = await client.pendingInbound
        XCTAssertEqual(settled, 0)

        // Then the golden snapshot frame surfaces through the typed accessor.
        try await client.receive(try golden("server-21"))
        let snapshot = try await client.snapshot()
        let unwrapped = try XCTUnwrap(snapshot)
        XCTAssertEqual(unwrapped.bootID, "boot-v1")
        XCTAssertEqual(unwrapped.revision, 7)
        XCTAssertEqual(unwrapped.panes.first?.paneID, "w1:p1")
    }

    func testAllocationLedgerBalancesAcrossALifecycle() async throws {
        let before = HerdrClient.liveFFIAllocations
        for _ in 0..<8 {
            let client = try HerdrClient(config: Self.goldenConfig)
            _ = try await client.drainOutbound()
            try await client.receive(try golden("server-20"))
            try await client.receive(try golden("server-21"))
            _ = try await client.snapshot()
            _ = try await client.surfaceJSON()
            client.destroy()
        }
        let after = HerdrClient.liveFFIAllocations
        XCTAssertEqual(
            before, after,
            "create/destroy and every handed-out buffer must balance exactly"
        )
    }

    func testInputRoutesAreTypedBeforeActivation() async throws {
        let client = try HerdrClient(config: Self.goldenConfig)
        defer { client.destroy() }

        do {
            try await client.sendText("x", to: "w1:p1")
            XCTFail("input before the handshake must fail")
        } catch let error as HerdrClientError {
            guard case .notOnline = error else { return XCTFail("expected notOnline, got \(error)") }
        }

        try await client.receive(try golden("server-20"))
        do {
            try await client.sendText("x", to: "w1:p1")
            XCTFail("input before a snapshot must fail")
        } catch let error as HerdrClientError {
            guard case .inputFrozen = error else { return XCTFail("expected inputFrozen, got \(error)") }
        }

        try await client.receive(try golden("server-21"))
        // Input stays frozen until T16's activation transaction unfreezes the
        // surface, whatever pane identity is addressed.
        do {
            try await client.sendKey(HerdrKeyInput(code: .char("界")), to: "w1:p1")
            XCTFail("input must stay frozen before activation")
        } catch let error as HerdrClientError {
            guard case .inputFrozen = error else { return XCTFail("expected inputFrozen, got \(error)") }
        }
    }

    func testInvalidKeyPayloadsFailAtTheBoundary() async throws {
        let client = try HerdrClient(config: Self.goldenConfig)
        defer { client.destroy() }
        try await client.receive(try golden("server-20"))
        do {
            try await client.sendKey(HerdrKeyInput(code: .function(99)), to: "w1:p1")
            XCTFail("function key 99 is outside the frozen key code space")
        } catch let error as HerdrClientError {
            guard case .invalidArgument = error else { return XCTFail("expected invalidArgument, got \(error)") }
        }
    }
}

/// Deterministic SplitMix64 so the fuzz smoke is reproducible.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

final class HerdrPanicContainmentTests: XCTestCase {
    private func golden(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "bin"),
            "committed golden fixture \(name).bin must be bundled"
        )
        return try Data(contentsOf: url)
    }

    /// Feeds truncated, mutated, and pure-garbage byte streams; every call
    /// either succeeds or throws a structured `HerdrClientError`, the process
    /// never crashes, the decoder buffer stays bounded by what was fed, and
    /// the allocation ledger returns to zero.
    func testMalformedStreamsNeverCrashAndStayBounded() async throws {
        var random = SeededRandom(seed: 0xB1C7)
        let welcome = try golden("server-20")
        let snapshot = try golden("server-21")
        let before = HerdrClient.liveFFIAllocations
        var structuredErrors = 0
        var protocolViolations = 0
        var acceptedChunks = 0

        for iteration in 0..<500 {
            let client = try HerdrClient(
                config: HerdrClientConfig(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16)
            )
            var fed: UInt64 = 0
            var live = true
            for chunk in Self.malformedCase(iteration: iteration, welcome: welcome, snapshot: snapshot, random: &random) {
                guard live else { break }
                fed += UInt64(chunk.count)
                do {
                    try await client.receive(chunk)
                    acceptedChunks += 1
                } catch let error as HerdrClientError {
                    structuredErrors += 1
                    if case .protocolViolation = error {
                        protocolViolations += 1
                        live = false
                        let phase = await client.phase
                        XCTAssertEqual(phase, .failed, "violation must fail the client deterministically")
                    }
                }
            }
            if live {
                let pending = await client.pendingInbound
                XCTAssertLessThanOrEqual(
                    pending, fed,
                    "decoder buffering must stay bounded by fed bytes"
                )
            }
            client.destroy()
        }

        XCTAssertGreaterThan(protocolViolations, 0, "garbage must surface typed violations")
        XCTAssertGreaterThan(structuredErrors, protocolViolations, "non-fatal rejections observed too")
        XCTAssertEqual(
            HerdrClient.liveFFIAllocations, before,
            "fuzz clients and buffers must all be returned"
        )
    }

    private static func malformedCase(
        iteration: Int,
        welcome: Data,
        snapshot: Data,
        random: inout SeededRandom
    ) -> [Data] {
        switch iteration % 5 {
        case 0:
            var garbage = Data(capacity: 64)
            for _ in 0..<Int(random.next() % 256 + 1) { garbage.append(random.byte()) }
            return [garbage]
        case 1:
            var mutated = welcome
            for _ in 0..<Int(random.next() % 8 + 1) {
                mutated[Int(random.next() % UInt64(mutated.count))] ^= random.byte()
            }
            return [mutated]
        case 2:
            return [welcome.prefix(Int(random.next() % UInt64(welcome.count)))]
        case 3:
            return [Data([0xFF, 0xFF, 0xFF, 0x7F])]
        default:
            return [welcome, snapshot.prefix(Int(random.next() % UInt64(snapshot.count)))]
        }
    }
}
