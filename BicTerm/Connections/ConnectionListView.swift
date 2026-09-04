import SwiftUI

struct ConnectionListView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    private let placeholderConnections = [
        "Example SSH",
        "Example Coder"
    ]

    var body: some View {
        List {
            ForEach(placeholderConnections, id: \.self) { name in
                NavigationLink(value: name) {
                    HStack(spacing: spacing.sm) {
                        Circle()
                            .fill(colors.success)
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                    }
                    .padding(.vertical, spacing.xs)
                }
                .listRowBackground(colors.background)
            }

            HStack(spacing: spacing.sm) {
                Circle()
                    .fill(colors.dimmed)
                    .frame(width: 8, height: 8)
                Text("Add Connection…")
                    .font(typography.body)
                    .foregroundColor(colors.dimmed)
            }
            .padding(.vertical, spacing.xs)
            .disabled(true)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("BicTerm")
        .navigationDestination(for: String.self) { connectionName in
            TerminalPlaceholderView(connectionName: connectionName)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gear")
                        .foregroundColor(colors.accent)
                }
            }
        }
        .accessibilityIdentifier("connectionList")
    }
}
