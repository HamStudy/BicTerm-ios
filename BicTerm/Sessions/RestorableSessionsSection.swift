import BicTermCore
import SwiftUI

/// Main-window section listing termination snapshots that can be restored.
/// Every entry restores as reconnect-required — the only connect action is
/// the manual Reconnect button.
struct RestorableSessionsSection: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let entries: [SessionStore.RestorableSession]
    let onReconnect: (SessionStore.RestorableSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Label("Restorable Sessions", systemImage: "arrow.clockwise.circle")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)

            ForEach(entries) { entry in
                HStack(spacing: spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(colors.accent)

                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text(entry.connection.name)
                            .font(typography.headline)
                            .foregroundColor(colors.foreground)
                            .accessibilityIdentifier("restorable-name-\(sanitized(entry.connection.name))")
                        Text("Reconnect required")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .accessibilityIdentifier("restorable-state-\(sanitized(entry.connection.name))")
                    }

                    Spacer()

                    Button("Reconnect") {
                        onReconnect(entry)
                    }
                    .buttonStyle(.bordered)
                    .tint(colors.accent)
                    .accessibilityIdentifier("restorable-reconnect-\(sanitized(entry.connection.name))")
                }
                .padding(spacing.xs)
                .background(colors.selection.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, spacing.sm)
        .padding(.top, spacing.xs)
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }
}
