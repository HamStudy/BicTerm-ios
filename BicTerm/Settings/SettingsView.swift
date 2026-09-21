import SwiftUI

struct SettingsView: View {
    @Environment(TerminalMarginModel.self) private var marginModel
    @Environment(KeyAvailabilityPreferences.self) private var keyPreferences
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    /// The shared terminal font-size preference; the Appearance row shows
    /// its live value and the detail screen edits it.
    let fontModel: TerminalFontModel
    /// The shared appearance preference; the Theme row shows its live
    /// value and the detail screen edits it.
    let themeModel: ThemeModel
    /// App-global OSC 52 clipboard-write toggle. The "Remote Clipboard
    /// Writes" row binds directly to this model's live value; flipping it
    /// updates every terminal surface and the embedded herdr TUI in one
    /// step (all read the same UserDefaults key).
    let osc52Model: Osc52ClipboardModel
    /// App-global keep-screen-on toggle. The Terminal section's "Keep
    /// Screen On" row binds directly to this model's live value; the
    /// model applies the choice to the UIKit idle timer on every change.
    let keepAwakeModel: KeepAwakeModel
    /// App-global app-lock toggle. The Security section's "App Lock" row
    /// binds directly to this model; enabling persists the choice and
    /// arms the per-scene privacy covers for the next background
    /// transition.
    let appLockModel: AppLockModel

    var body: some View {
        @Bindable var keyPreferences = keyPreferences
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

            Section("Terminal") {
                Toggle(isOn: Binding(
                    get: { keepAwakeModel.keepScreenOn },
                    set: { keepAwakeModel.setKeepScreenOn($0) }
                )) {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text("Keep Screen On")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Text("Prevents the display from sleeping while the app is open.")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(typography.body)
                .foregroundStyle(colors.foreground)
                .tint(colors.accent)
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-keep-screen-on")
            }

            Section("Security") {
                Toggle(isOn: Binding(
                    get: { appLockModel.isEnabled },
                    set: { appLockModel.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text("App Lock")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Text("Require Face ID or your passcode to unlock BicTerm after it moves to the background. Every window is covered while locked.")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(typography.body)
                .foregroundStyle(colors.foreground)
                .tint(colors.accent)
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-app-lock")
            }

            Section {
                NavigationLink {
                    KeyManagementView()
                } label: {
                    Text("SSH Keys")
                        .font(typography.body)
                        .foregroundColor(colors.foreground)
                }
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-ssh-keys")
Toggle(isOn: Binding(
                    get: { osc52Model.writesEnabled },
                    set: { osc52Model.setWritesEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: spacing.xxxs) {
                        Text("Remote Clipboard Writes")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Text("Allow TUI programs to copy text to your clipboard. Every write shows a toast and only the foreground session applies.")
                            .font(typography.caption)
                            .foregroundColor(colors.dimmed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(typography.body)
                .foregroundStyle(colors.foreground)
                .tint(colors.accent)
                .listRowBackground(colors.background)
                .accessibilityIdentifier("settings-osc52-writes")

                Toggle("Offer Hardware Keys by Default", isOn: $keyPreferences.hardwareOfferedByDefault)
                    .font(typography.body)
                    .foregroundStyle(colors.foreground)
                    .tint(colors.accent)
                    .listRowBackground(colors.background)
                    .accessibilityIdentifier("settings-hardware-keys")
            } header: {
                Text("Keys & Clipboard")
            } footer: {
                Text("Applies to keys offered by default. Explicitly selected keys always apply.")
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
