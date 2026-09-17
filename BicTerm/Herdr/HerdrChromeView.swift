import BicTermCore
import SwiftUI

/// The herdr workspace's top chrome: the SAME row layout as the terminal
/// session chrome (`SessionSceneView.chrome`) — leading title + Herdr badge
/// + live status chip, trailing session menu and Close — so a herdr
/// workspace window (iPad) or full-screen cover (iPhone) presents like any
/// other session window.
///
/// Identifiers: title and status keep the long-standing herdr identifiers
/// (`herdr-endpoint-label`, `herdr-embed-status`); every element shared
/// with the session chrome is suffixed `-herdr` so a terminal window and a
/// herdr window on screen together (iPad) never duplicate the session
/// scene's identifiers.
struct HerdrChromeView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let store: SessionStore
    /// Workspace label (the connection or herd name).
    let title: String
    /// Live status line for the chip (the embed runtime's phase text).
    let statusText: String
    let statusColor: Color
    /// The workspace entry id, passed to the menu as `currentSessionID`. It
    /// is never a SessionStore session, so `descriptor(id:)` returns nil and
    /// the per-session Appearance submenu stays hidden — the intended
    /// behavior for workspaces. Nil only in legacy/test hosting.
    let ownerID: UUID?
    var onPickSession: (UUID) -> Void
    var onNewConnection: () -> Void
    var onClose: () -> Void

    @State private var switcherPresented = false

    var body: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                Text(title)
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
                    .lineLimit(1)
                    .accessibilityIdentifier("herdr-endpoint-label")

                HStack(spacing: spacing.xxs) {
                    TerminalBadge(
                        "Herdr",
                        tint: colors.accent,
                        stroke: colors.accent.opacity(0.5),
                        strokeWidth: 0.5
                    )
                    .accessibilityIdentifier("badge-herdr")
                    TerminalBadge(statusText, tint: statusColor)
                        .accessibilityIdentifier("herdr-embed-status")
                }
            }

            Spacer()

            SessionMenuView(
                store: store,
                currentSessionID: ownerID ?? Self.unownedSessionID,
                identifierSuffix: "-herdr",
                onPickSession: onPickSession,
                onNewConnection: onNewConnection,
                onManageSessions: { switcherPresented = true }
            )

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Close workspace")
            .accessibilityIdentifier("scene-close-\(sanitized)-herdr")
            .foregroundColor(colors.dimmed)
        }
        .windowControlsClearance()
        .padding(.trailing, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(colors.background)
        .sheet(isPresented: $switcherPresented) {
            SessionSwitcherView(
                store: store,
                currentSessionID: ownerID,
                onPick: { pickedID in
                    switcherPresented = false
                    onPickSession(pickedID)
                },
                onNewConnection: {
                    switcherPresented = false
                    onNewConnection()
                }
            )
        }
    }

    /// Stable stand-in for a surface with no workspace identity: any
    /// non-session UUID behaves identically here (the store has no
    /// descriptor for it), so a fixed value avoids per-render churn.
    private static let unownedSessionID = UUID(uuidString: "2F8C0E1C-7A2D-4B3A-9E5F-1C6D8A4B2E0F")!

    private var sanitized: String {
        title.replacingOccurrences(of: " ", with: "-")
    }
}
