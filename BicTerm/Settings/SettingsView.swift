import SwiftUI

struct SettingsView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    var body: some View {
        List {
            Section("Appearance") {
                HStack {
                    Text("Theme")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    Spacer()
                    Text("Dark")
                        .font(typography.body)
                        .foregroundColor(colors.dimmed)
                }
                .listRowBackground(colors.background)

                HStack {
                    Text("Font Size")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    Spacer()
                    Text("14pt")
                        .font(typography.body)
                        .foregroundColor(colors.dimmed)
                }
                .listRowBackground(colors.background)
            }

            Section("Connection") {
                HStack {
                    Text("Default Shell")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                    Spacer()
                    Text("/bin/bash")
                        .font(typography.body)
                        .foregroundColor(colors.dimmed)
                }
                .listRowBackground(colors.background)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Settings")
        .accessibilityIdentifier("settingsView")
    }
}
