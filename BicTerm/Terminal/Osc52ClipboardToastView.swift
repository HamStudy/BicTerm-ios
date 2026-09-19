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
/// Styling reads the injected `palette` / `typography` / `spacing`
/// parameters — NOT the `terminalColors` / `terminalTypography` /
/// `terminalSpacing` environment — because the overlay is hosted by
/// `SessionSceneView` inside a SwiftUI `.overlay { ... }` closure whose
/// re-evaluation may sample the environment values from a build context
/// that has not propagated the latest `terminalStyle()` injection —
/// `@Environment(\.terminalColors)` returned empty colors for the
/// overlay under iOS 26.3, causing the toast to render with
/// `Color.clear` text/background and zero-frame image. Callers inject
/// their live environment values explicitly, avoiding the propagation
/// race while keeping the toast on-palette in both appearance modes.
struct Osc52ToastView: View {
    let toast: Osc52ClipboardToast
    let palette: TerminalColors
    let typography: TerminalTypography
    let spacing: TerminalSpacing
    /// Identifier suffix so multiple sessions can coexist in the
    /// accessibility tree without colliding.
    var sceneID: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundColor(palette.success)
            Text(toast.fullText)
                .font(typography.body)
                .foregroundColor(palette.foreground)
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(palette.background.opacity(0.92), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(palette.success.opacity(0.6), lineWidth: 1)
        )
        // Drop shadows are scheme-independent — Color.black is correct in both modes.
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("osc52-toast-\(sceneID)")
        .accessibilityLabel(toast.fullText)
        .padding(.top, spacing.xxs)
        .allowsHitTesting(false)
    }

    private var symbolName: String {
        switch toast.kind {
        case .copied: "doc.on.clipboard.fill"
        case .cleared: "trash.slash.fill"
        }
    }
}
