import BicTermCore
import HerdrClientCore
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import BicTerm

/// T18 clipboard privacy and bounds (integration doc §8.2-§8.4): exact-text
/// paste vectors against FFI-captured goldens, the remote-copy trust
/// boundary (explicit action by default, per-endpoint opt-in), the
/// non-fatal drop path, the 16 MiB image bounds at both layers, EXIF
/// stripping, and the redaction contract — clipboard content never enters
/// the echo/log surface. Gesture-level coverage lives in
/// HerdrClipboardUITests.
@MainActor
final class HerdrClipboardTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Decoded payload of the clipboard-osc52-hello fixture (base64
    /// `aGVsbG8gcmVtb3RlIGNsaXBib2FyZCDwn5OL`).
    private static let remoteText = "hello remote clipboard 📋"

    /// The generator's 1x1 transparent PNG (kept byte-identical to the
    /// TINY_PNG constant behind the clipboard-image-p2 golden).
    private static let tinyPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])

    override func setUp() {
        HerdrPasteboard.resetCounters()
    }

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
        endpoint: HerdrEndpointID,
        extraChunks: [Data] = [],
        expectedApplies: Int? = nil
    ) async throws -> HerdrReplayTransport {
        let script = try fenceScript() + extraChunks
        let transport = HerdrReplayTransport(script: script)
        model.connect(endpoint: endpoint, transport: transport)
        // A chunk whose receive reports a non-fatal clipboard drop never
        // reaches the render-state apply, so the drop-path script applies
        // one chunk fewer than it feeds.
        let expected = expectedApplies ?? script.count
        let applied = await waitUntil { model.debugAppliedChunks >= expected }
        XCTAssertTrue(applied, "the replay script must fully apply")
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online)
        return transport
    }

    private func ephemeralSettings() throws -> HerdrClipboardSettings {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "h18.\(UUID().uuidString)"),
            "an ephemeral suite must always construct"
        )
        return HerdrClipboardSettings(defaults: defaults)
    }

    // MARK: - Text paste vectors (doc §8.2)

    func testEmptyPasteIsSilent() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "paste-empty")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        let writesBefore = transport.writeLedger.count
        model.pasteText("", endpoint: endpoint)
        XCTAssertTrue(model.debugInputEcho.isEmpty, "empty paste: no echo, no note, no frame")
        XCTAssertNil(model.endpoints[endpoint]?.inputNote)
        XCTAssertEqual(transport.writeLedger.count, writesBefore)

        await model.disconnectAll()
    }

    func testMultilinePasteWritesGoldenFrameByteExact() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "paste-multiline")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.pasteText("one\ntwo\r\nthree", endpoint: endpoint)
        let golden = try herdrGolden("input-paste-multiline-p2")
        let written = await waitUntil { transport.writeLedger.contains(golden) }
        XCTAssertTrue(written, "mixed newlines cross the wire byte-exact — no rewriting")
        XCTAssertTrue(model.debugInputEcho.contains("paste(14B→w1:p2)"))
        XCTAssertNil(model.endpoints[endpoint]?.inputNote)

        await model.disconnectAll()
    }

    func testBracketedSequencesPassThroughUnwrapped() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "paste-bracketed")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.pasteText("\u{1b}[200~already wrapped\u{1b}[201~", endpoint: endpoint)
        let golden = try herdrGolden("input-paste-bracketed-p2")
        let written = await waitUntil { transport.writeLedger.contains(golden) }
        XCTAssertTrue(
            written,
            "escape sequences pass through; the app never pre-wraps (the remote runtime owns bracketed paste)"
        )
        XCTAssertTrue(model.debugInputEcho.contains("paste(27B→w1:p2)"))

        await model.disconnectAll()
    }

    func testNonASCIIPasteWritesGoldenFrame() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "paste-cjk")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.pasteText("貼り付け📋", endpoint: endpoint)
        let golden = try herdrGolden("input-paste-cjk-p2")
        let written = await waitUntil { transport.writeLedger.contains(golden) }
        XCTAssertTrue(written)
        XCTAssertTrue(model.debugInputEcho.contains("paste(16B→w1:p2)"))

        await model.disconnectAll()
    }

    func testOversizePasteRejectedBeforeTheFFI() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "paste-oversize")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        let writesBefore = transport.writeLedger.count
        model.pasteText(String(repeating: "x", count: HerdrClipboard.maxTextPasteBytes + 1), endpoint: endpoint)
        XCTAssertEqual(model.debugInputEcho, ["pasteTooLarge"])
        XCTAssertEqual(model.endpoints[endpoint]?.inputNote, .pasteTooLarge)
        XCTAssertEqual(transport.writeLedger.count, writesBefore, "nothing reaches the wire")

        await model.disconnectAll()
    }

    // MARK: - Remote clipboard writes (doc §8.3)

    func testRemoteClipboardArrivesAsPendingNotPasteboard() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "remote-pending")
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )

        let pending = try XCTUnwrap(model.endpoints[endpoint]?.pendingRemoteClipboard)
        XCTAssertEqual(pending.byteCount, 27)
        XCTAssertEqual(pending.text, Self.remoteText)
        XCTAssertEqual(HerdrPasteboard.writeCount, 0, "arrival alone never touches the pasteboard")
        XCTAssertFalse(
            model.autoCopyRemoteClipboard(forEndpoint: endpoint),
            "auto-copy is opt-in, default OFF"
        )
        XCTAssertTrue(model.debugInputEcho.contains("remoteClipboard(27B)"))

        await model.disconnectAll()
    }

    func testExplicitCopyFromRemoteWritesPasteboard() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "remote-copy")
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )
        XCTAssertNotNil(model.endpoints[endpoint]?.pendingRemoteClipboard)

        model.copyRemoteClipboardToPasteboard(endpoint: endpoint)
        XCTAssertEqual(HerdrPasteboard.writeCount, 1)
        XCTAssertEqual(HerdrPasteboard.lastWrittenText, Self.remoteText)
        XCTAssertNil(model.endpoints[endpoint]?.pendingRemoteClipboard, "the pending write is consumed")
        XCTAssertTrue(model.debugInputEcho.contains("copyRemote(27B)"))

        await model.disconnectAll()
    }

    func testAutoCopyOptInWritesOnArrival() async throws {
        let settings = try ephemeralSettings()
        let endpoint = HerdrEndpointID(rawValue: "remote-autocopy")
        settings.setAutoCopyRemoteClipboard(true, for: endpoint)
        let model = HerdrSessionModel(clipboardSettings: settings)
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )

        XCTAssertEqual(HerdrPasteboard.writeCount, 1, "the opt-in applies the write on arrival")
        XCTAssertEqual(HerdrPasteboard.lastWrittenText, Self.remoteText)
        XCTAssertNil(model.endpoints[endpoint]?.pendingRemoteClipboard)
        XCTAssertTrue(model.debugInputEcho.contains("autoCopyRemote(27B)"))

        await model.disconnectAll()
    }

    func testAutoCopySettingPersistsPerEndpoint() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "h18.\(UUID().uuidString)"),
            "an ephemeral suite must always construct"
        )
        let endpointA = HerdrEndpointID(rawValue: "host-a")
        let endpointB = HerdrEndpointID(rawValue: "host-b")
        XCTAssertFalse(
            HerdrClipboardSettings(defaults: defaults).autoCopyRemoteClipboard(for: endpointA),
            "default is OFF"
        )

        HerdrClipboardSettings(defaults: defaults).setAutoCopyRemoteClipboard(true, for: endpointA)
        let reloaded = HerdrClipboardSettings(defaults: defaults)
        XCTAssertTrue(reloaded.autoCopyRemoteClipboard(for: endpointA), "a fresh instance reads the stored opt-in")
        XCTAssertFalse(reloaded.autoCopyRemoteClipboard(for: endpointB), "opt-in is per host")
    }

    func testMalformedClipboardFrameDropsNonFatally() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "remote-drop")
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [
                try herdrGolden("clipboard-osc52-malformed"),
                try herdrGolden("clipboard-osc52-hello"),
            ],
            expectedApplies: 9
        )

        XCTAssertTrue(model.debugInputEcho.contains("clipboardDropped"), "the drop is noted")
        XCTAssertTrue(
            model.debugInputEcho.contains("remoteClipboard(27B)"),
            "decoding continues after the drop — the session stays Online"
        )
        XCTAssertEqual(model.endpoints[endpoint]?.phase, .online)
        guard case .clipboardDropped = model.endpoints[endpoint]?.inputNote else {
            return XCTFail("expected a clipboardDropped note")
        }
        XCTAssertEqual(
            model.endpoints[endpoint]?.pendingRemoteClipboard?.text, Self.remoteText,
            "the well-formed frame after the malformed one still lands"
        )

        await model.disconnectAll()
    }

    // MARK: - Banner dismissal (doc §8.3: arrival alone never consents)

    func testDismissRemoteClipboardDropsPendingWithoutPasteboardWrite() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "remote-dismiss")
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )
        XCTAssertNotNil(model.endpoints[endpoint]?.pendingRemoteClipboard)

        model.dismissRemoteClipboard(endpoint: endpoint)
        XCTAssertNil(model.endpoints[endpoint]?.pendingRemoteClipboard)
        XCTAssertEqual(HerdrPasteboard.writeCount, 0, "dismissal never touches the pasteboard")
        XCTAssertTrue(model.debugInputEcho.contains("dismissRemote(27B)"))

        await model.disconnectAll()
    }

    func testPendingRemoteClipboardAutoDismissesAfterBannerDuration() async throws {
        let model = HerdrSessionModel(
            clipboardSettings: try ephemeralSettings(),
            remoteClipboardBannerDuration: .milliseconds(300)
        )
        let endpoint = HerdrEndpointID(rawValue: "remote-autodismiss")
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )
        XCTAssertNotNil(model.endpoints[endpoint]?.pendingRemoteClipboard)

        let dismissed = await waitUntil(timeout: 2) {
            model.endpoints[endpoint]?.pendingRemoteClipboard == nil
        }
        XCTAssertTrue(dismissed, "the banner auto-dismiss must drop the pending write")
        XCTAssertEqual(HerdrPasteboard.writeCount, 0)
        XCTAssertTrue(model.debugInputEcho.contains("dismissRemote(27B)"))

        await model.disconnectAll()
    }

    func testStaleAutoDismissTimerDoesNotDropNewerPending() async throws {
        let model = HerdrSessionModel(
            clipboardSettings: try ephemeralSettings(),
            remoteClipboardBannerDuration: .milliseconds(600)
        )
        let endpoint = HerdrEndpointID(rawValue: "remote-stale-timer")
        _ = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )
        XCTAssertEqual(model.endpoints[endpoint]?.pendingRemoteClipboard?.text, Self.remoteText)

        // A second arrival ~300ms later replaces the pending write and re-arms
        // the timer; the first timer (firing at ~600ms) must not drop it.
        try await Task.sleep(for: .milliseconds(300))
        let generation = try XCTUnwrap(model.endpoints[endpoint]?.generation)
        model.remoteClipboardArrived(
            endpoint: endpoint, generation: generation, data: Data("second".utf8)
        )
        XCTAssertEqual(model.endpoints[endpoint]?.pendingRemoteClipboard?.text, "second")

        // At ~700ms from the first arrival its timer has already fired.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            model.endpoints[endpoint]?.pendingRemoteClipboard?.text, "second",
            "the stale timer must not drop the newer pending write"
        )

        let dismissed = await waitUntil(timeout: 2) {
            model.endpoints[endpoint]?.pendingRemoteClipboard == nil
        }
        XCTAssertTrue(dismissed, "the newer write's own timer still dismisses it")
        XCTAssertEqual(
            model.debugInputEcho.filter { $0.hasPrefix("dismissRemote") },
            ["dismissRemote(6B)"],
            "exactly one dismissal — the stale timer stayed inert"
        )

        await model.disconnectAll()
    }

    // MARK: - Redaction (doc §8.3: never log clipboard content)

    func testEchoNeverContainsClipboardContent() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "redaction")
        let transport = try await connectThroughFence(
            model, endpoint: endpoint,
            extraChunks: [herdrGolden("clipboard-osc52-hello")]
        )

        let sentinel = "SENTINEL-PASTE-9f3a"
        model.pasteText(sentinel, endpoint: endpoint)
        let echoed = await waitUntil { model.debugInputEcho.contains("paste(19B→w1:p2)") }
        XCTAssertTrue(echoed)
        XCTAssertEqual(HerdrPasteboard.writeCount, 0)
        model.copyRemoteClipboardToPasteboard(endpoint: endpoint)
        XCTAssertEqual(HerdrPasteboard.lastWrittenText, Self.remoteText)
        XCTAssertTrue(model.debugInputEcho.contains("copyRemote(27B)"))

        for line in model.debugInputEcho {
            XCTAssertFalse(line.contains(sentinel), "outbound paste content must never be echoed: \(line)")
            XCTAssertFalse(
                line.contains(Self.remoteText),
                "inbound clipboard content must never be echoed: \(line)"
            )
        }
        _ = transport

        await model.disconnectAll()
    }

    // MARK: - Image bounds (doc §8.4)

    private func prepared(
        _ data: Data,
        pixelWidth: Int = 1,
        pixelHeight: Int = 1
    ) -> HerdrClipboard.PreparedImage {
        HerdrClipboard.PreparedImage(
            data: data,
            extension: "png",
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            metadataStripped: true
        )
    }

    func testClipboardImageSendWritesTheGoldenFrame() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "image-golden")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        model.sendClipboardImage(prepared(Self.tinyPNG), endpoint: endpoint)
        let golden = try herdrGolden("clipboard-image-p2")
        let written = await waitUntil { transport.writeLedger.contains(golden) }
        XCTAssertTrue(written, "the image frame is byte-identical to the FFI-captured golden")
        XCTAssertTrue(model.debugInputEcho.contains("image(67B.png→w1:p2)"))

        await model.disconnectAll()
    }

    func testClipboardImageAtCapMinusOneIsAccepted() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "image-cap-minus-one")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        let writesBefore = transport.writeLedger.count
        model.sendClipboardImage(
            prepared(Data(count: HerdrClipboard.maxImagePayloadBytes - 1)),
            endpoint: endpoint
        )
        let written = await waitUntil(timeout: 15) {
            transport.writeLedger.count == writesBefore + 1
        }
        XCTAssertTrue(written, "16 MiB−1 must be accepted")
        XCTAssertTrue(model.debugInputEcho.contains("image(16777215B.png→w1:p2)"))
        XCTAssertNil(model.endpoints[endpoint]?.inputNote)

        await model.disconnectAll()
    }

    func testClipboardImageAtCapIsAccepted() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "image-at-cap")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        let writesBefore = transport.writeLedger.count
        model.sendClipboardImage(
            prepared(Data(count: HerdrClipboard.maxImagePayloadBytes)),
            endpoint: endpoint
        )
        let written = await waitUntil(timeout: 15) {
            transport.writeLedger.count == writesBefore + 1
        }
        XCTAssertTrue(written, "exactly 16 MiB must be accepted (the FFI rejects only above the cap)")
        XCTAssertTrue(model.debugInputEcho.contains("image(16777216B.png→w1:p2)"))

        await model.disconnectAll()
    }

    func testClipboardImageOverCapIsRejectedByTheFFI() async throws {
        let model = HerdrSessionModel(clipboardSettings: try ephemeralSettings())
        let endpoint = HerdrEndpointID(rawValue: "image-over-cap")
        let transport = try await connectThroughFence(model, endpoint: endpoint)

        let writesBefore = transport.writeLedger.count
        model.sendClipboardImage(
            prepared(Data(count: HerdrClipboard.maxImagePayloadBytes + 1)),
            endpoint: endpoint
        )
        let rejected = await waitUntil {
            model.debugInputEcho.contains { $0.hasPrefix("writeFailed(") }
        }
        XCTAssertTrue(rejected, "16 MiB+1 must fail as a typed note, never a frame")
        guard case .writeFailed = model.endpoints[endpoint]?.inputNote else {
            return XCTFail("expected a writeFailed note")
        }
        XCTAssertEqual(transport.writeLedger.count, writesBefore, "nothing over the cap reaches the wire")

        await model.disconnectAll()
    }

    // MARK: - Image pipeline

    func testPipelineRejectsOversizeSourceBeforeDecode() {
        let result = HerdrClipboard.prepareImage(
            from: Data(count: HerdrClipboard.maxImagePayloadBytes + 1)
        )
        XCTAssertEqual(result, .failure(.exceedsCap))
    }

    func testPipelineStripsEXIFByDefault() throws {
        let jpeg = try makeJPEGWithEXIF()
        let stripped = HerdrClipboard.prepareImage(from: jpeg)
        guard case .success(let prepared) = stripped else {
            return XCTFail("a valid JPEG must prepare: \(stripped)")
        }
        XCTAssertTrue(prepared.metadataStripped)
        XCTAssertEqual(prepared.extension, "png", "re-encode, never trust the supplied type")
        let properties = try outputProperties(prepared.data)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(
            exif?[kCGImagePropertyExifUserComment],
            "source EXIF is stripped (ImageIO may still synthesize dimension entries)"
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "location stripped by default")

        guard case .success(let preserved) = HerdrClipboard.prepareImage(
            from: jpeg, preserveMetadata: true
        ) else {
            return XCTFail("the labeled preserve option must still prepare")
        }
        XCTAssertFalse(preserved.metadataStripped)
        let preservedProperties = try outputProperties(preserved.data)
        let preservedEXIF = preservedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(
            preservedEXIF?[kCGImagePropertyExifUserComment] as? String,
            "h18-test",
            "the labeled toggle carries source metadata forward"
        )
    }

    func testPipelineStripsCorruptEXIF() throws {
        let corrupt = try makeJPEGWithEXIF(corruptEXIF: true)
        let result = HerdrClipboard.prepareImage(from: corrupt)
        guard case .success(let prepared) = result else {
            return XCTFail("corrupt EXIF must still decode and prepare: \(result)")
        }
        XCTAssertTrue(prepared.metadataStripped)
        let properties = try outputProperties(prepared.data)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment], "corrupt EXIF is stripped like any other")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    func testPipelineDownscalePath() throws {
        let source = try makeNoisePNG(pixelSize: 512)
        let testCap = 300_000
        XCTAssertLessThan(source.count, HerdrClipboard.maxImagePayloadBytes)

        let full = HerdrClipboard.prepareImage(from: source, maxPayloadBytes: testCap)
        XCTAssertEqual(full, .failure(.needsDownscale), "re-encode over the cap asks for downscale")

        let scaled = HerdrClipboard.prepareImage(from: source, maxPixelSize: 256, maxPayloadBytes: testCap)
        guard case .success(let prepared) = scaled else {
            return XCTFail("downscaled image must prepare: \(scaled)")
        }
        XCTAssertLessThanOrEqual(prepared.data.count, testCap)
        XCTAssertEqual(prepared.pixelWidth, 256)
        XCTAssertEqual(prepared.pixelHeight, 256)
    }

    func testReadCappedEnforcesCapDuringLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("h18-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oversized = directory.appendingPathComponent("oversized.bin")
        try Data(count: 5_000).write(to: oversized)
        XCTAssertEqual(
            HerdrClipboard.readCapped(url: oversized, maxBytes: 1_024),
            .failure(.exceedsCap),
            "the read aborts the moment the running total crosses the cap"
        )

        let small = directory.appendingPathComponent("small.bin")
        try Data(count: 500).write(to: small)
        switch HerdrClipboard.readCapped(url: small, maxBytes: 1_024) {
        case .success(let data):
            XCTAssertEqual(data.count, 500)
        case .failure(let error):
            XCTFail("a file under the cap must read fully: \(error)")
        }
    }

    // MARK: - Binding round trip

    func testTakeClipboardBindingDrainsTheOneShotSlot() async throws {
        let client = try HerdrClient(
            config: HerdrClientConfig(
                cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16,
                pixelMouse: true, mouseCapture: true
            )
        )
        defer { client.destroy() }
        _ = try await client.drainOutbound()
        try await client.receive(vendorGolden("server-20"))
        let phase = await client.phase
        XCTAssertEqual(phase, .online)

        let before = try await client.takeClipboard()
        XCTAssertNil(before, "the slot starts empty")

        try await client.receive(herdrGolden("clipboard-osc52-hello"))
        let taken = try await client.takeClipboard()
        XCTAssertEqual(
            taken.flatMap { String(data: $0, encoding: .utf8) },
            Self.remoteText,
            "the FFI decoded and capped the payload; Swift owns the freed copy"
        )
        let drained = try await client.takeClipboard()
        XCTAssertNil(drained, "the slot is one-shot")
    }

    // MARK: - Test image construction

    private func makeNoisePNG(pixelSize: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)
        var state: UInt64 = 0xB1C7
        for index in bytes.indices {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            bytes[index] = UInt8(truncatingIfNeeded: mixed ^ (mixed >> 31))
        }
        let image = try makeCGImage(bytes: bytes, pixelSize: pixelSize)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeJPEGWithEXIF(corruptEXIF: Bool = false) throws -> Data {
        let pixelSize = 8
        var bytes = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = 200
            bytes[offset + 1] = 100
            bytes[offset + 2] = 50
            bytes[offset + 3] = 255
        }
        let image = try makeCGImage(bytes: bytes, pixelSize: pixelSize)
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifPixelXDimension: pixelSize,
                kCGImagePropertyExifPixelYDimension: pixelSize,
                kCGImagePropertyExifUserComment: "h18-test",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.03,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var data = output as Data
        if corruptEXIF {
            // Overwrite the APP1 "Exif\0\0" header with garbage; ImageIO
            // still decodes the scan and drops the malformed segment.
            var corrupted = false
            for index in 0..<(data.count - 10) where data[index] == 0xFF && data[index + 1] == 0xE1 {
                for fill in (index + 4)...(index + 9) { data[fill] = 0xAA }
                corrupted = true
                break
            }
            XCTAssertTrue(corrupted, "the synthesized JPEG must contain an APP1 segment to corrupt")
        }
        return data
    }

    private func makeCGImage(bytes: [UInt8], pixelSize: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func outputProperties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}
