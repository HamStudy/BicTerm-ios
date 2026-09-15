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
struct Osc52ToastView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let toast: Osc52ClipboardToast
    /// Identifier suffix so multiple sessions can coexist in the
    /// accessibility tree without colliding.
    var sceneID: String = ""

    var body: some View {
        HStack(spacing: spacing.xs) {
            Image(systemName: symbolName)
                .foregroundColor(colors.success)
            Text(toast.fullText)
                .font(typography.caption)
                .foregroundColor(colors.foreground)
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(colors.selection.opacity(0.9), in: Capsule())
        .accessibilityIdentifier("osc52-toast-\(sceneID)")
        .accessibilityLabel(toast.fullText)
        .padding(.top, spacing.xs)
        .allowsHitTesting(false)
    }

    private var symbolName: String {
        switch toast.kind {
        case .copied: "doc.on.clipboard.fill"
        case .cleared: "trash.slash.fill"
        }
    }
}
