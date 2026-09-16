import BicTermCore
import SwiftUI

/// Main-window section listing termination snapshots that can be restored.
/// Every entry restores as reconnect-required and exposes two actions: the
/// manual Reconnect button, and Dismiss, which permanently deletes the
/// entry's persisted snapshot (the saved connection is kept).
struct RestorableSessionsSection: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let entries: [SessionStore.RestorableSession]
    let onReconnect: (SessionStore.RestorableSession) -> Void
    let onDismiss: (SessionStore.RestorableSession) -> Void

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

                    Button {
                        onDismiss(entry)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(typography.headline)
                    }
                    .buttonStyle(.borderless)
                    .tint(colors.dimmed)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Dismiss \(entry.connection.name)")
                    .accessibilityIdentifier("restorable-dismiss-\(sanitized(entry.connection.name))")
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
