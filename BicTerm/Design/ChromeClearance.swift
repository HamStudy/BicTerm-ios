import SwiftUI
import UIKit

/// iPadOS 26 freeform windows draw the traffic-light window controls over
/// the top-leading region, and the top safe area has no leading component,
/// so on iPad top chrome clears that region (~80pt: three lights +
/// margins). iPhone keeps the original `spacing.sm` leading. Shared by the
/// session scene chrome and the herdr workspace header so both window
/// kinds clear the controls identically.
private struct WindowControlsClearanceModifier: ViewModifier {
    @Environment(\.terminalSpacing) private var spacing

    func body(content: Content) -> some View {
        content.padding(
            .leading,
            spacing.sm + (UIDevice.current.userInterfaceIdiom == .pad ? 80 : 0)
        )
    }
}

extension View {
    /// Leading padding that keeps top chrome clear of the iPad window
    /// controls (traffic lights) in freeform windows; `spacing.sm` only
    /// on iPhone. Apply INSTEAD of the plain leading padding.
    func windowControlsClearance() -> some View {
        modifier(WindowControlsClearanceModifier())
    }
}
