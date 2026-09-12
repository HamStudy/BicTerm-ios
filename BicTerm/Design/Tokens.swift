import SwiftUI
import UIKit

// MARK: - Design Tokens

/// Terminal aesthetic color palette, in two fixed variants — ``dark`` (the
/// original dark-first set) and ``light``. The palette is selected from the
/// effective color scheme at the `terminalStyle()` injection point, so
/// token call sites never branch on appearance.
struct TerminalColors {

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

    /// The dark palette (GitHub-dark-derived). Also the fallback when no
    /// scheme is known (environment default, `.unspecified` traits).
    static let dark = TerminalColors()

    /// The light palette (GitHub-light-derived): white canvas with dark
    /// text; accent/semantic hues chosen for WCAG-AA contrast on white.
    static let light = TerminalColors(
        background: Color(hex: 0xFFFFFF),
        foreground: Color(hex: 0x1F2328),
        accent: Color(hex: 0x0969DA),
        selection: Color(hex: 0xC8E1FA),
        dimmed: Color(hex: 0x59636E),
        error: Color(hex: 0xD1242F),
        success: Color(hex: 0x1A7F37)
    )

    /// The palette for a SwiftUI color scheme.
    static func palette(for scheme: ColorScheme) -> TerminalColors {
        scheme == .dark ? .dark : .light
    }

    /// The palette for a UIKit interface style; `.unspecified` stays dark
    /// (the dark-first default).
    static func palette(for style: UIUserInterfaceStyle) -> TerminalColors {
        style == .light ? .light : .dark
    }

    /// Native (UIKit) surface colors for SwiftTerm. SwiftTerm snapshots
    /// UIColors into its `Terminal` model at assignment time (and copies
    /// the background into the view layer in `setupOptions`), so
    /// `UIColor(dynamicProvider:)` values would NOT re-resolve on a scheme
    /// change — these are static per-palette colors, re-applied on trait
    /// changes by `TerminalContainerView.applyNativeTerminalColors()`.
    var nativeBackground: UIColor { UIColor(background) }
    var nativeForeground: UIColor { UIColor(foreground) }
}

/// SF Mono typography scale for terminal UI
struct TerminalTypography {

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
struct TerminalSpacing {
    let xxxs: CGFloat = 2
    let xxs: CGFloat = 4
    let xs: CGFloat = 8
    let sm: CGFloat = 12
    let md: CGFloat = 16
    let lg: CGFloat = 24
    let xl: CGFloat = 32
    let xxl: CGFloat = 48
}

// MARK: - Fixed shape/opacity bands

/// Scheme-independent shape and opacity bands for badge pills and
/// text-bearing banners. Fixed constants (not environment tokens): they do
/// not vary by palette, and no call site injects a variant.
enum TerminalMetric {
    /// Corner radius for the rounded (non-capsule) badge shape.
    static let badgeRadius: CGFloat = 6

    /// Fill band of a badge pill: `tint.opacity(badgeFill)` over the
    /// surrounding background. 0.15 keeps every palette tint at WCAG AA or
    /// better against its own chip fill (weakest pair, dark error #F85149
    /// on error@0.15 over #0D1117, measures ~4.8:1).
    static let badgeFill: Double = 0.15

    /// Selection band behind TEXT-BEARING banners (status banner,
    /// scrollback notice, remote-clipboard banner). The previous 0.4 band
    /// measured 4.37:1 for dark-scheme error text (#F85149 over
    /// selection@0.4 on #0D1117, blended bg ≈ rgb(23,42,62)) — just under
    /// WCAG AA 4.5:1. At 0.3 the blended bg is ≈ rgb(20,36,52) and the
    /// same error text measures ~4.7:1; every brighter banner foreground
    /// (accent ~6.3:1, dimmed ~5.1:1, foreground) clears AA with more
    /// margin. Light scheme improves the same way (error #D1242F over
    /// selection@0.3 on white ≈ 4.8:1).
    static let bannerFill: Double = 0.3
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
    static let defaultValue = TerminalColors.dark
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

/// Injects the terminal design tokens, selecting the light or dark color
/// palette from the EFFECTIVE color scheme — the app-level appearance
/// override (`ThemeModel`) when one is set, otherwise the device
/// appearance. A preference change re-themes every styled view; token call
/// sites never branch on scheme.
private struct TerminalStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.terminalColors, .palette(for: colorScheme))
            .environment(\.terminalTypography, TerminalTypography())
            .environment(\.terminalSpacing, TerminalSpacing())
            #if DEBUG
            .modifier(UITestKeyManagementOverlay())
            #endif
    }
}

extension View {
    /// Injects terminal design tokens with the scheme-appropriate palette.
    func terminalStyle() -> some View {
        modifier(TerminalStyleModifier())
    }
}
