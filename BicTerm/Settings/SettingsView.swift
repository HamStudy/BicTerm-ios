import SwiftUI

struct SettingsView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    /// The shared terminal font-size preference; the Appearance row shows
    /// its live value and the detail screen edits it.
    let fontModel: TerminalFontModel

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

                NavigationLink {
                    FontSizeSettingsView(fontModel: fontModel)
                } label: {
                    HStack {
                        Text("Font Size")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Spacer()
                        Text(FontSizeSettingsView.label(for: fontModel.size))
                            .font(typography.body)
                            .foregroundColor(colors.dimmed)
                    }
                }
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-font-size")
            }

            Section("Security") {
                NavigationLink {
                    KeyManagementView()
                } label: {
                    Text("SSH Keys")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                }
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-ssh-keys")
            }

            Section("About") {
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Text("Acknowledgements")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                }
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-acknowledgements")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Settings")
        .accessibilityIdentifier("settingsView")
    }
}
