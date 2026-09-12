import SwiftUI

/// Live font-size editor for the terminal: slider (9–32pt in 0.5 steps),
/// a monospace preview rendered at the current point size, and Reset to
/// Default. Bound to the app-global ``TerminalFontModel``, so moving the
/// slider re-fonts every open terminal surface immediately — including
/// sessions behind this screen or in other windows.
///
/// The preview pins an explicit point size on purpose: the terminal is a
/// fixed character grid and its font deliberately does NOT follow Dynamic
/// Type; the preview must mirror the terminal, not the system text size.
struct FontSizeSettingsView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing

    let fontModel: TerminalFontModel

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { fontModel.size },
            set: { fontModel.setSize($0) }
        )
    }

    private var isDefault: Bool {
        fontModel.size == TerminalFontSettings.defaultSize
    }

    /// "14 pt" / "14.5 pt" — sizes are always quantized to 0.5, so an
    /// integral value renders without a fraction.
    static func label(for size: Double) -> String {
        size.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(size)) pt"
            : "\(size) pt"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: spacing.xs) {
                    HStack {
                        Text("Font Size")
                            .font(typography.body)
                            .foregroundColor(colors.foreground)
                        Spacer()
                        Text(Self.label(for: fontModel.size))
                            .font(typography.body)
                            .foregroundColor(colors.dimmed)
                            .accessibilityIdentifier("font-size-value")
                    }
                    Slider(
                        value: sizeBinding,
                        in: TerminalFontSettings.minimumSize...TerminalFontSettings.maximumSize,
                        step: TerminalFontSettings.step
                    )
                    .tint(colors.accent)
                    .accessibilityIdentifier("font-size-slider")
                }
                .listRowBackground(colors.background)
            } header: {
                Text("Terminal")
                    .foregroundColor(colors.dimmed)
            }

            Section {
                Text("The quick brown fox 0O1lI|")
                    .font(.system(size: fontModel.size, design: .monospaced))
                    .foregroundColor(colors.foreground)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, spacing.xs)
                    .accessibilityIdentifier("font-size-preview")
                    .listRowBackground(colors.background)
            } header: {
                Text("Preview")
                    .foregroundColor(colors.dimmed)
            }

            Section {
                Button {
                    fontModel.reset()
                } label: {
                    Text("Reset to Default")
                        .font(typography.body)
                        .foregroundColor(isDefault ? colors.dimmed : colors.accent)
                }
                .disabled(isDefault)
                .accessibilityIdentifier("font-size-reset")
                .listRowBackground(colors.background)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Font Size")
    }
}
