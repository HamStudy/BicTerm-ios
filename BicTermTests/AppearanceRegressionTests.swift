import SwiftUI
import XCTest

@testable import BicTerm

/// Scheme-aware theming invariant: `terminalStyle()` injects the dark or
/// light `TerminalColors` palette according to the EFFECTIVE color scheme
/// (the app-level appearance override when set, otherwise the device).
/// The probes drive the effective scheme through the hosting window's
/// `overrideUserInterfaceStyle` — the same UIKit trait channel the app
/// root's `.preferredColorScheme` override resolves to in a live scene —
/// because a scene-less test window never resolves the presentation-level
/// preference. Under the pre-theming code both probes fail: the palette was
/// unconditionally dark and the modifier pinned `.preferredColorScheme(.dark)`.
@MainActor
final class AppearanceRegressionTests: XCTestCase {

    private struct PaletteProbe: View {
        @Environment(\.terminalColors) var colors
        @Environment(\.colorScheme) var scheme
        let sink: (ColorScheme, TerminalColors) -> Void

        var body: some View {
            // Test probe: sample the CURRENT environment on every body
            // evaluation; the last sample before the deadline is the
            // settled state.
            let _ = sink(scheme, colors)
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func injectedPalette(scheme: ColorScheme) -> (scheme: ColorScheme, colors: TerminalColors)? {
        var latest: (ColorScheme, TerminalColors)?
        let probe = PaletteProbe { latest = ($0, $1) }
        let host = UIHostingController(rootView: probe.terminalStyle())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(1.5)
        while latest?.0 != scheme, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        window.isHidden = true
        window.rootViewController = nil
        return latest
    }

    private func assertSameColor(
        _ lhs: Color, _ rhs: Color, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        UIColor(lhs).getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        UIColor(rhs).getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        XCTAssertEqual(lr, rr, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(lg, rg, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(lb, rb, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(la, ra, accuracy: 0.004, message, file: file, line: line)
    }

    func testDarkSchemeInjectsDarkPalette() throws {
        let settled = try XCTUnwrap(injectedPalette(scheme: .dark), "scheme pin never resolved to dark")
        XCTAssertEqual(settled.scheme, .dark)
        assertSameColor(settled.colors.background, TerminalColors.dark.background, "dark scheme must inject the dark background")
        assertSameColor(settled.colors.foreground, TerminalColors.dark.foreground, "dark scheme must inject the dark foreground")
    }

    func testLightSchemeInjectsLightPalette() throws {
        let settled = try XCTUnwrap(injectedPalette(scheme: .light), "scheme pin never resolved to light")
        XCTAssertEqual(settled.scheme, .light)
        assertSameColor(settled.colors.background, TerminalColors.light.background, "light scheme must inject the light background")
        assertSameColor(settled.colors.foreground, TerminalColors.light.foreground, "light scheme must inject the light foreground")
    }

    /// The palettes must differ — a selection that returns the same values
    /// for both schemes is a theming no-op.
    func testLightAndDarkPalettesDiffer() {
        var dark: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var light: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var alpha: CGFloat = 0
        UIColor(TerminalColors.dark.background).getRed(&dark.r, green: &dark.g, blue: &dark.b, alpha: &alpha)
        UIColor(TerminalColors.light.background).getRed(&light.r, green: &light.g, blue: &light.b, alpha: &alpha)
        XCTAssertFalse(
            abs(dark.r - light.r) < 0.01 && abs(dark.g - light.g) < 0.01 && abs(dark.b - light.b) < 0.01,
            "dark and light palette backgrounds must differ"
        )
    }
}
