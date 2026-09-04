import SwiftUI

struct TerminalPlaceholderView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    let connectionName: String

    var body: some View {
        ZStack {
            colors.background
                .ignoresSafeArea()

            VStack(spacing: spacing.md) {
                Text("Terminal — coming in T12")
                    .font(typography.title)
                    .foregroundColor(colors.foreground)

                Text(connectionName)
                    .font(typography.headline)
                    .foregroundColor(colors.dimmed)

                RoundedRectangle(cornerRadius: 4)
                    .stroke(colors.accent, lineWidth: 1)
                    .frame(width: 200, height: 100)
                    .overlay(
                        Text("⌘ + T")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                    )
            }
        }
        .accessibilityIdentifier("terminalPlaceholder")
    }
}
