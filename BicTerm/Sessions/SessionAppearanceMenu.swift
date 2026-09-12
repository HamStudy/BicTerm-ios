import SwiftUI

struct SessionAppearanceMenu: View {
    let store: SessionStore
    let sceneID: String
    var onEditFont: () -> Void

    private var overrides: SessionAppearanceOverrides {
        store.appearanceOverrides[sceneID] ?? SessionAppearanceOverrides()
    }

    var body: some View {
        Section("Appearance") {
            Menu {
                Button("Global") { store.setTheme(nil, sceneID: sceneID) }
                    .accessibilityIdentifier("session-theme-global")
                ForEach(AppearancePreference.allCases, id: \.self) { preference in
                    Button(preference.label) { store.setTheme(preference, sceneID: sceneID) }
                        .accessibilityIdentifier("session-theme-\(preference.rawValue)")
                }
            } label: {
                Text("Theme: \(overrides.theme == nil ? "Global — " : "")\(store.effectiveTheme(sceneID).label)")
            }
            .accessibilityIdentifier("session-appearance-theme")

            Menu {
                Button("Global") { store.setFontSize(nil, sceneID: sceneID) }
                    .accessibilityIdentifier("session-font-global")
                Button("Adjust Font Size…", action: onEditFont)
                    .accessibilityIdentifier("session-font-adjust")
                Button("Increase by 0.5 pt") {
                    store.setFontSize(store.effectiveFontSize(sceneID) + TerminalFontSettings.step, sceneID: sceneID)
                }
                .disabled(store.effectiveFontSize(sceneID) >= TerminalFontSettings.maximumSize)
                .accessibilityIdentifier("session-font-increase")
                Button("Decrease by 0.5 pt") {
                    store.setFontSize(store.effectiveFontSize(sceneID) - TerminalFontSettings.step, sceneID: sceneID)
                }
                .disabled(store.effectiveFontSize(sceneID) <= TerminalFontSettings.minimumSize)
                .accessibilityIdentifier("session-font-decrease")
            } label: {
                Text("Font Size: \(overrides.fontSize == nil ? "Global — " : "")\(FontSizeSettingsView.label(for: store.effectiveFontSize(sceneID)))")
            }
            .accessibilityIdentifier("session-appearance-font")

            Menu {
                Button("Global") { store.setMargin(nil, sceneID: sceneID) }
                    .accessibilityIdentifier("session-margin-global")
                ForEach(TerminalMargin.allCases, id: \.self) { margin in
                    Button(margin.label) { store.setMargin(margin, sceneID: sceneID) }
                        .accessibilityIdentifier("session-margin-\(Int(margin.rawValue))")
                }
            } label: {
                Text("Margins: \(overrides.margin == nil ? "Global — " : "")\(store.effectiveMargin(sceneID).label)")
            }
            .accessibilityIdentifier("session-appearance-margin")
        }
    }
}

struct SessionFontSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    let store: SessionStore
    let sceneID: String

    var body: some View {
        NavigationStack {
            List {
                Section("This Session") {
                    Text(FontSizeSettingsView.label(for: store.effectiveFontSize(sceneID)))
                        .font(typography.body)
                    Slider(value: Binding(
                        get: { store.effectiveFontSize(sceneID) },
                        set: { store.setFontSize($0, sceneID: sceneID) }
                    ), in: TerminalFontSettings.minimumSize...TerminalFontSettings.maximumSize,
                       step: TerminalFontSettings.step)
                        .accessibilityLabel("Session font size")
                        .accessibilityIdentifier("session-font-slider")
                    Button("Reset to Global") { store.setFontSize(nil, sceneID: sceneID) }
                        .font(typography.body)
                        .foregroundStyle(colors.accent)
                }
                .listRowBackground(colors.background)
            }
            .foregroundStyle(colors.foreground)
            .tint(colors.accent)
            .scrollContentBackground(.hidden)
            .background(colors.background)
            .navigationTitle("Font Size")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
