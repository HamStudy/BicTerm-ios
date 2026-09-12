import SwiftUI

/// Appearance preference editor: System (follows the device appearance),
/// Dark, or Light. Bound to the app-global ``ThemeModel``, so a selection
/// re-themes every window immediately — `BicTermApp` re-applies the
/// `.preferredColorScheme` override at each scene root — and persists
/// across launches.
struct ThemeSettingsView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    let themeModel: ThemeModel

    var body: some View {
        List {
            Section {
                ForEach(AppearancePreference.allCases, id: \.self) { preference in
                    Button {
                        themeModel.setPreference(preference)
                    } label: {
                        HStack {
                            Text(preference.label)
                                .font(typography.body)
                                .foregroundColor(colors.foreground)
                            Spacer()
                            if preference == themeModel.preference {
                                Image(systemName: "checkmark")
                                    .foregroundColor(colors.accent)
                                    .accessibilityIdentifier("theme-selected-\(preference.rawValue)")
                            }
                        }
                    }
                    .accessibilityIdentifier("theme-option-\(preference.rawValue)")
                    .listRowBackground(colors.background)
                }
            } header: {
                Text("Theme")
                    .foregroundColor(colors.dimmed)
                    .accessibilityIdentifier("theme-picker")
            } footer: {
                Text("System follows the device appearance. Dark and Light pin every window to that appearance.")
                    .foregroundColor(colors.dimmed)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Theme")
    }
}
