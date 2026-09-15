import Foundation
import SwiftUI

/// The data the OSC 52 policy approved and the scene's overlay renders.
/// `sourceLabel` attributes the write to its origin ("session-name" for
/// terminal sessions, "Herdr" for the embedded TUI); `kind` carries the
/// message text the user sees ("Copied 214 chars", "Clipboard cleared").
struct Osc52ClipboardToast: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case copied(bytes: Int)
        case cleared
    }
    let kind: Kind
    let sourceLabel: String

    var headline: String {
        switch kind {
        case .copied(let bytes): "Copied \(bytes) chars"
        case .cleared: "Clipboard cleared"
        }
    }

    /// Full message rendered in the toast, including attribution.
    var fullText: String {
        switch kind {
        case .copied: "\(headline) from \(sourceLabel)"
        case .cleared: "\(headline) (\(sourceLabel))"
        }
    }
}

/// SwiftUI overlay for one scene's OSC 52 toast. Mirrors the
/// `reconnectedToast` styling (capsule background, success tint, caption
/// font) so a remote-initiated clipboard write is visually consistent
/// with the in-app reconnect signal. No focus shift, no input capture,
/// no accessibility element that steals the screen reader — toast is
/// advisory only.
///
/// Styling uses hard-coded `Color` / `Font` (not the `terminalColors` /
/// `terminalTypography` environment) because the overlay is hosted by
/// `SessionSceneView` inside a SwiftUI `.overlay { ... }` closure whose
/// re-evaluation may sample the environment values from a build context
/// that has not propagated the latest `terminalStyle()` injection —
/// `@Environment(\.terminalColors)` returned empty colors for the
/// overlay under iOS 26.3, causing the toast to render with
/// `Color.clear` text/background and zero-frame image. Hard-coded tokens
/// avoid the propagation race and keep the security guardrail visible
/// regardless of where the toast is hosted.
struct Osc52ToastView: View {
    let toast: Osc52ClipboardToast
    /// Identifier suffix so multiple sessions can coexist in the
    /// accessibility tree without colliding.
    var sceneID: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundColor(.green)
            Text(toast.fullText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground).opacity(0.92), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.green.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("osc52-toast-\(sceneID)")
        .accessibilityLabel(toast.fullText)
        .padding(.top, 4)
        .allowsHitTesting(false)
    }

    private var symbolName: String {
        switch toast.kind {
        case .copied: "doc.on.clipboard.fill"
        case .cleared: "trash.slash.fill"
        }
    }
}
