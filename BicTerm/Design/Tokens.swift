import SwiftUI

// MARK: - Design Tokens

/// Dark-first terminal aesthetic color palette
struct TerminalColors: EnvironmentKey {
    static let defaultValue = TerminalColors()

    let background: Color
    let foreground: Color
    let accent: Color
    let selection: Color
    let dimmed: Color
    let error: Color
    let success: Color

    init(
        background: Color = Color(hex: 0x0D1117),
        foreground: Color = Color(hex: 0xE6EDF3),
        accent: Color = Color(hex: 0x58A6FF),
        selection: Color = Color(hex: 0x264F78),
        dimmed: Color = Color(hex: 0x8B949E),
        error: Color = Color(hex: 0xF85149),
        success: Color = Color(hex: 0x3FB950)
    ) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.selection = selection
        self.dimmed = dimmed
        self.error = error
        self.success = success
    }
}

/// SF Mono typography scale for terminal UI
struct TerminalTypography: EnvironmentKey {
    static let defaultValue = TerminalTypography()

    let caption: Font
    let body: Font
    let headline: Font
    let title: Font

    init(
        caption: Font = .system(size: 12, weight: .regular, design: .monospaced),
        body: Font = .system(size: 14, weight: .regular, design: .monospaced),
        headline: Font = .system(size: 16, weight: .semibold, design: .monospaced),
        title: Font = .system(size: 20, weight: .bold, design: .monospaced)
    ) {
        self.caption = caption
        self.body = body
        self.headline = headline
        self.title = title
    }
}

/// Spacing scale for consistent layout rhythm
struct TerminalSpacing: EnvironmentKey {
    static let defaultValue = TerminalSpacing()

    let xxxs: CGFloat = 2
    let xxs: CGFloat = 4
    let xs: CGFloat = 8
    let sm: CGFloat = 12
    let md: CGFloat = 16
    let lg: CGFloat = 24
    let xl: CGFloat = 32
    let xxl: CGFloat = 48
}

// MARK: - Environment Values

extension EnvironmentValues {
    var terminalColors: TerminalColors {
        get { self[TerminalColorsKey.self] }
        set { self[TerminalColorsKey.self] = newValue }
    }

    var terminalTypography: TerminalTypography {
        get { self[TerminalTypographyKey.self] }
        set { self[TerminalTypographyKey.self] = newValue }
    }

    var terminalSpacing: TerminalSpacing {
        get { self[TerminalSpacingKey.self] }
        set { self[TerminalSpacingKey.self] = newValue }
    }
}

private struct TerminalColorsKey: EnvironmentKey {
    static let defaultValue = TerminalColors()
}

private struct TerminalTypographyKey: EnvironmentKey {
    static let defaultValue = TerminalTypography()
}

private struct TerminalSpacingKey: EnvironmentKey {
    static let defaultValue = TerminalSpacing()
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - View Extension for Easy Token Access

extension View {
    func terminalStyle() -> some View {
        self
            .environment(\.terminalColors, TerminalColors())
            .environment(\.terminalTypography, TerminalTypography())
            .environment(\.terminalSpacing, TerminalSpacing())
    }
}
