import SwiftUI

struct SettingsView: View {
    @Environment(TerminalMarginModel.self) private var marginModel
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    /// The shared terminal font-size preference; the Appearance row shows
    /// its live value and the detail screen edits it.
    let fontModel: TerminalFontModel
    /// The shared appearance preference; the Theme row shows its live
    /// value and the detail screen edits it.
    let themeModel: ThemeModel

    var body: some View {
        List {
            Section("Appearance") {
                NavigationLink {
                    ThemeSettingsView(themeModel: themeModel)
                } label: {
                    HStack {
                        Text("Theme")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Spacer()
                        Text(themeModel.preference.label)
                            .font(typography.body)
                            .foregroundColor(colors.dimmed)
                    }
                }
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-theme")

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

                Picker("Margins", selection: Binding(
                    get: { marginModel.margin },
                    set: { marginModel.setMargin($0) }
                )) {
                    ForEach(TerminalMargin.allCases, id: \.self) { margin in
                        Text(margin.label).tag(margin)
                    }
                }
                .font(typography.body)
                .foregroundStyle(colors.foreground)
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-margins")
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
