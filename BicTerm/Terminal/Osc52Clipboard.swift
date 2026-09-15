import Foundation
import UIKit

/// UserDefaults-backed persistence for the user's "allow remote OSC 52
/// clipboard writes" choice. Default ON — the user must opt out per
/// session. Same struct-over-UserDefaults convention as
/// `HerdrClipboardSettings` / `TerminalToolbarSettings`: an absent key
/// means "no explicit choice", and the ``Osc52ClipboardPolicy`` applies
/// the default (ON) at evaluation time.
///
/// Reads stay absolutely denied under any flag (the fork's delegate
/// returns nil for every OSC 52 query); this toggle governs writes
/// only. Empty payloads clear the clipboard when writes are enabled.
struct Osc52ClipboardSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "bicterm.osc52.writes.enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `true` when the user has explicitly enabled OSC 52 writes, OR when
    /// the user has never chosen (default). `false` only when the user has
    /// explicitly disabled the feature.
    var writesEnabled: Bool {
        guard let stored = defaults.object(forKey: key) as? Bool else {
            return true
        }
        return stored
    }

    func setWritesEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }

    /// Drops the stored choice; the next read returns the default (ON).
    /// Used by UITEST setup so launch state is deterministic.
    func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// The maximum size of a single OSC 52 clipboard write payload, in
/// DECODED bytes (the UTF-8 byte length of the text). Larger payloads are
/// denied — the toast does not fire, the clipboard is not touched, and a
/// typed diagnostic is recorded for DEBUG observability. 100 KiB covers
/// realistic copy flows (commands, paths, stack traces, log snippets)
/// without inviting megabyte pastes.
enum Osc52ClipboardLimits {
    static let maxPayloadBytes = 100 * 1024
}

/// Per-call policy result. The fork's delegate is the source of the call;
/// the policy layer decides whether to set the system pasteboard, clear
/// it, or drop the request with a typed reason.
enum Osc52ClipboardDecision: Equatable, Sendable {
    /// Write `text` to the system clipboard and surface a "Copied N chars
    /// from <source>" toast.
    case write(text: String, bytes: Int)
    /// Clear the system clipboard and surface a "Clipboard cleared"
    /// toast.
    case clear
    /// Drop the request without touching the clipboard or firing a toast.
    case deny(Osc52ClipboardDenial)

    var isApproved: Bool {
        switch self {
        case .write, .clear: true
        case .deny: false
        }
    }
}

/// Typed reason a write was denied. Surfaced in DEBUG logs so a test or
/// developer can prove why a particular call was dropped; the UI never
/// shows a denial (no toast, no banner — silent on purpose so a denied
/// call from a runaway TUI cannot spam the user).
enum Osc52ClipboardDenial: Equatable, Hashable, Sendable {
    /// The user disabled OSC 52 writes in Settings.
    case disabled
    /// The originating surface's view is not attached to a window
    /// hierarchy (detached background tab) — only the foreground
    /// session's writes apply.
    case notForeground
    /// The decoded payload exceeds ``Osc52ClipboardLimits.maxPayloadBytes``.
    /// No clipboard write, no toast.
    case tooLarge(bytes: Int)
    /// The base64 payload did not decode — malformed OSC 52. No
    /// clipboard write, no toast.
    case malformedBase64
}

/// The fork's OSC 52 parser delivers `Data` that is ALREADY base64-decoded
/// when valid; a malformed payload never reaches this type because the
/// parser drops it before invoking the delegate. The policy treats the
/// incoming bytes as decoded text (UTF-8) and enforces the size cap and
/// the foreground gate.
enum Osc52ClipboardPolicy {
    /// Evaluates one OSC 52 write request and returns a decision the
    /// surface's coordinator can act on. `decodedBytes` is the
    /// already-decoded payload (the fork's `clipboardCopy` contract);
    /// `settings` reads the current toggle; the `isForeground`
    /// autoclosure lets the caller prove the surface is attached to a
    /// window.
    static func evaluateWrite(
        decodedBytes: Data,
        settings: Osc52ClipboardSettings,
        isForeground: @autoclosure () -> Bool
    ) -> Osc52ClipboardDecision {
        guard settings.writesEnabled else { return .deny(.disabled) }
        guard isForeground() else { return .deny(.notForeground) }
        let text = String(data: decodedBytes, encoding: .utf8) ?? ""
        if text.isEmpty {
            return .clear
        }
        let byteCount = text.utf8.count
        guard byteCount <= Osc52ClipboardLimits.maxPayloadBytes else {
            return .deny(.tooLarge(bytes: byteCount))
        }
        return .write(text: text, bytes: byteCount)
    }

    /// Direct base64-decode entry-point for tests that bypass the fork's
    /// parser. Used by ``Osc52ClipboardPolicyTests`` to assert the
    /// malformed-base64 path against the raw OSC 52 wire bytes; the
    /// production path always reaches the delegate already decoded.
    static func evaluateRawBase64Write(
        base64Bytes: Data,
        settings: Osc52ClipboardSettings,
        isForeground: @autoclosure () -> Bool
    ) -> Osc52ClipboardDecision {
        guard settings.writesEnabled else { return .deny(.disabled) }
        guard isForeground() else { return .deny(.notForeground) }
        guard let decoded = Data(base64Encoded: base64Bytes) else {
            return .deny(.malformedBase64)
        }
        return evaluateWrite(
            decodedBytes: decoded,
            settings: settings,
            isForeground: isForeground()
        )
    }
}

/// App-side pasteboard sink for OSC 52 writes — the only writer of
/// `UIPasteboard.general` for remote-initiated copies. Local user
/// selection copies (the container view's `copy:` action, T12) write
/// through their own path and never touch this type.
///
/// Reads stay absolutely denied: no API surface exists here for a
/// clipboard → remote transfer. The fork's `clipboardRead` delegate
/// method returns nil unconditionally; nothing in this layer changes
/// that contract.
@MainActor
enum Osc52ClipboardSink {
    #if DEBUG
    /// DEBUG-only counter so the unit test can prove the policy path
    /// without inspecting UIPasteboard (which is process-global).
    private(set) static var writeCount = 0
    private(set) static var clearCount = 0
    /// Last written text — recorded only in DEBUG builds, never logged.
    private(set) static var lastWrittenText: String?
    /// Per-reason denial counts so a UI suite can prove which branch
    /// fired in the test scenario.
    private(set) static var denials: [Osc52ClipboardDenial: Int] = [:]

    static func resetCounters() {
        writeCount = 0
        clearCount = 0
        lastWrittenText = nil
        denials = [:]
    }

    static func recordDenial(_ reason: Osc52ClipboardDenial) {
        denials[reason, default: 0] += 1
    }
    #endif

    /// Set the system pasteboard to `text`. No-op for empty strings; that
    /// case is handled as `.clear` upstream.
    static func write(_ text: String) {
        #if DEBUG
        writeCount += 1
        lastWrittenText = text
        #endif
        UIPasteboard.general.string = text
    }

    /// Clear the system pasteboard.
    static func clear() {
        #if DEBUG
        clearCount += 1
        #endif
        UIPasteboard.general.string = ""
    }
}
