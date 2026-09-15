import Foundation
import SwiftTerm
import UIKit

/// One OSC 52 write request as the app's coordinator sees it: a
/// foreground-evaluated `Osc52ClipboardDecision` plus the data the
/// scene-level sink needs to surface an attribution toast. The router
/// produces exactly one of these per inbound write attempt; the scene
/// model renders the toast (write/clear) and silently records the
/// denial (DEBUG only) — never a toast for a denial.
struct Osc52ClipboardOutcome: Sendable {
    let decision: Osc52ClipboardDecision
    /// Source label the toast shows ("session-name" for terminal
    /// sessions, "Herdr" for the embedded TUI). Computed by the surface
    /// that originated the request so the router stays UI-agnostic.
    let sourceLabel: String

    init(decision: Osc52ClipboardDecision, sourceLabel: String) {
        self.decision = decision
        self.sourceLabel = sourceLabel
    }
}

/// App-side glue between the fork's typed OSC 52 callback
/// (``ClipboardWriteRequest``) and the policy layer
/// (``Osc52ClipboardPolicy``). Each SwiftTerm surface (terminal
/// session, herdr TUI) instantiates one router, hands it the
/// `Osc52ClipboardSettings` and a foreground predicate, and calls
/// ``evaluate(_:sourceLabel:)`` whenever the fork fires
/// `oscClipboardWriteRequest`. The router applies the policy, writes
/// to `UIPasteboard.general` via ``Osc52ClipboardSink`` on approval,
/// and hands the outcome to the caller so the scene-level toast can
/// render the attribution.
///
/// Reads stay absolutely denied at the fork's `clipboardRead` default
/// (returns nil); this router never has a read path.
@MainActor
struct Osc52Router {
    let settings: Osc52ClipboardSettings
    /// Predicate the caller uses to prove the originating surface is
    /// attached to a window hierarchy. Evaluated synchronously at the
    /// time the OSC 52 fires (i.e. on the main thread inside the
    /// SwiftTerm delegate callback).
    let isForeground: @MainActor () -> Bool

    init(
        settings: Osc52ClipboardSettings,
        isForeground: @escaping @MainActor () -> Bool
    ) {
        self.settings = settings
        self.isForeground = isForeground
    }

    /// One inbound OSC 52 write request. Returns the policy decision
    /// AFTER the clipboard write (when approved). The caller renders
    /// the toast off the returned outcome.
    func evaluate(
        _ request: ClipboardWriteRequest,
        sourceLabel: String
    ) -> Osc52ClipboardOutcome {
        // The fork's parse path surfaced every write attempt at the new
        // typed callback; the policy runs the raw base64 through the
        // foreground + size + settings gate so malformed/oversized stay
        // diagnosable.
        let decision = Osc52ClipboardPolicy.evaluateRawBase64Write(
            base64Bytes: request.rawBase64,
            settings: settings,
            isForeground: isForeground()
        )
        switch decision {
        case .write(let text, _):
            Osc52ClipboardSink.write(text)
        case .clear:
            Osc52ClipboardSink.clear()
        case .deny(let reason):
            #if DEBUG
            Osc52ClipboardSink.recordDenial(reason)
            #endif
            break
        }
        return Osc52ClipboardOutcome(decision: decision, sourceLabel: sourceLabel)
    }
}