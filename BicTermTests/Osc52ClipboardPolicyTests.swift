import SwiftTerm
import XCTest
@testable import BicTerm

/// OSC 52 clipboard writes — every branch of the hardened policy at
/// the app layer (settings toggle, foreground gate, 100 KiB cap, empty
/// payload → clear, malformed base64 diagnostics, read/query always
/// denied). The fork's parse-path tests live in
/// `Vendor/SwiftTerm/Tests/SwiftTermTests/BicTermOSC52Tests.swift`;
/// this file exercises the app-side evaluation that's added on top.
@MainActor
final class Osc52ClipboardPolicyTests: XCTestCase {
    // MARK: - Test doubles

    private func settings(_ enabled: Bool) -> Osc52ClipboardSettings {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let s = Osc52ClipboardSettings(defaults: suite)
        s.setWritesEnabled(enabled)
        return s
    }

    private func defaultEnabledSettings() -> Osc52ClipboardSettings {
        // No explicit choice: the policy treats an absent key as the
        // default (ON).
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return Osc52ClipboardSettings(defaults: suite)
    }

    private func base64(_ text: String) -> Data {
        Data(text.utf8).base64EncodedData()
    }

    // MARK: - Allowed path

    func testForegroundEnabledValidWritesAreApproved() {
        let s = settings(true)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64("hello world"),
            settings: s,
            isForeground: true
        )
        guard case let .write(text, bytes) = decision else {
            return XCTFail("expected .write, got \(decision)")
        }
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(bytes, 11)
    }

    func testDefaultEnabledSettingsApproveWrites() {
        // No explicit user choice: the policy reads an absent UserDefaults
        // key as the default (ON).
        let s = defaultEnabledSettings()
        XCTAssertTrue(s.writesEnabled)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64("first run"),
            settings: s,
            isForeground: true
        )
        guard case .write = decision else {
            return XCTFail("default-ON settings should approve writes, got \(decision)")
        }
    }

    func testForegroundEnabledClearPayloadClearsClipboard() {
        let s = settings(true)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: Data(),
            settings: s,
            isForeground: true
        )
        XCTAssertEqual(decision, .clear)
    }

    // MARK: - Denied paths

    func testDisabledSettingDeniesWrite() {
        let s = settings(false)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64("anything"),
            settings: s,
            isForeground: true
        )
        XCTAssertEqual(decision, .deny(.disabled))
    }

    func testBackgroundSessionDeniesWrite() {
        let s = settings(true)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64("anything"),
            settings: s,
            isForeground: false
        )
        XCTAssertEqual(decision, .deny(.notForeground))
    }

    func testOversizedPayloadDeniesWithoutToast() {
        let s = settings(true)
        let text = String(repeating: "x", count: Osc52ClipboardLimits.maxPayloadBytes + 1)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64(text),
            settings: s,
            isForeground: true
        )
        guard case let .deny(reason) = decision else {
            return XCTFail("expected .deny(.tooLarge), got \(decision)")
        }
        guard case let .tooLarge(bytes) = reason else {
            return XCTFail("expected .tooLarge, got \(reason)")
        }
        XCTAssertEqual(bytes, Osc52ClipboardLimits.maxPayloadBytes + 1)
    }

    func testAtCapIsApproved() {
        let s = settings(true)
        let text = String(repeating: "y", count: Osc52ClipboardLimits.maxPayloadBytes)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64(text),
            settings: s,
            isForeground: true
        )
        guard case .write = decision else {
            return XCTFail("expected .write at cap, got \(decision)")
        }
    }

    func testMalformedBase64DeniesWithTypedDiagnostic() {
        let s = settings(true)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: Data("not!valid!base64!!!".utf8),
            settings: s,
            isForeground: true
        )
        XCTAssertEqual(decision, .deny(.malformedBase64))
    }

    // MARK: - Precedence

    func testDisabledBeatsForeground() {
        let s = settings(false)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: base64("payload"),
            settings: s,
            isForeground: true
        )
        XCTAssertEqual(decision, .deny(.disabled))
    }

    func testDisabledBeatsMalformed() {
        let s = settings(false)
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: Data("not!valid!".utf8),
            settings: s,
            isForeground: true
        )
        XCTAssertEqual(decision, .deny(.disabled))
    }

    // MARK: - Read/query

    /// The fork's `clipboardRead` is the source of truth here — its
    /// default returns nil, denying every read/query. The app surface
    /// does NOT implement the read path; this test pins that contract
    /// so a future re-introduction of a read handler is a deliberate
    /// decision visible in the test diff.
    func testReadContractIsForkDefaultDeny() {
        let delegate = ReadDenialProbeDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )
        terminal.feed(text: "\u{1b}]52;c;?\u{07}")
        XCTAssertEqual(delegate.readCalls, 1)
        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    func testRouterWritesPasteboardOnApproval() {
        // The router is the trust boundary — it consults the policy and
        // the foreground predicate; an approved write reaches the
        // sink. We assert on the policy's decision (the sink writes to
        // UIPasteboard, which is process-global and observed separately
        // by the DEBUG counters).
        let s = settings(true)
        let decision = Osc52Router(
            settings: s,
            isForeground: { true }
        )
        .evaluate(
            ClipboardWriteRequest(
                rawBase64: base64("copied from herdr"),
                selection: "c"
            ),
            sourceLabel: "Herdr"
        )
        guard case let .write(text, _) = decision.decision else {
            return XCTFail("expected .write, got \(decision.decision)")
        }
        XCTAssertEqual(text, "copied from herdr")
        XCTAssertEqual(decision.sourceLabel, "Herdr")
    }

    func testRouterPicksDenialWhenBackground() {
        let s = settings(true)
        let outcome = Osc52Router(
            settings: s,
            isForeground: { false }
        )
        .evaluate(
            ClipboardWriteRequest(
                rawBase64: base64("hidden tab write"),
                selection: "c"
            ),
            sourceLabel: "Session"
        )
        XCTAssertEqual(outcome.decision, .deny(.notForeground))
    }
}

private final class ReadDenialProbeDelegate: TerminalDelegate {
    var readCalls = 0
    var sentData: [UInt8] = []
    func clipboardRead(source: Terminal) -> Data? {
        readCalls += 1
        return nil
    }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sentData.append(contentsOf: data)
    }
}