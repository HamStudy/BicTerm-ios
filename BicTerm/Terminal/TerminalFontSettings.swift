import CoreText
import Foundation
import UIKit

/// Cell metrics for one terminal-font point size, computed exactly like
/// SwiftTerm's `computeFontDimensions`: the monospaced advance of "W" for
/// the width, ascent + descent + leading for the height, both snapped to
/// the pixel grid. The herdr native pane surface quantizes its grid with
/// the same math the SwiftTerm terminal view uses, so both render the
/// same point size at the same grid density — and like the terminal, the
/// herdr pane font follows the app's terminal font setting, never
/// Dynamic Type.
struct TerminalCellMetrics: Equatable {
    /// Snapped monospaced advance ("W") per cell.
    let width: CGFloat
    /// Snapped ascent + descent + leading per cell.
    let height: CGFloat
    /// advance ÷ point size; clamps glyphs inside cells of a frame whose
    /// grid does not match the requested one (the connect-time fence).
    let advanceRatio: CGFloat
    /// line height ÷ point size; same clamp purpose as ``advanceRatio``.
    let lineRatio: CGFloat

    static func compute(fontSize: Double, displayScale: CGFloat) -> TerminalCellMetrics {
        let size = CGFloat(TerminalFontSettings.normalize(fontSize))
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = "W".size(withAttributes: [.font: font]).width
        // CTFont metrics, not UIFont.ascender/descender: CTFontGetDescent
        // returns the positive magnitude (UIFont.descender is negative on
        // this SDK), matching SwiftTerm's computeFontDimensions exactly.
        let ctFont = font as CTFont
        let lineHeight = CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        let scale = max(1, displayScale)
        return TerminalCellMetrics(
            width: max(1, (advance * scale).rounded() / scale),
            height: max(1, (ceil(lineHeight) * scale).rounded(.up) / scale),
            advanceRatio: advance / size,
            lineRatio: lineHeight / size
        )
    }
}

/// UserDefaults-backed persistence for the terminal font point size (same
/// struct-over-UserDefaults convention as `HerdrClipboardSettings` /
/// `TerminalToolbarSettings`). An absent key means the default size; every
/// stored value is normalized (clamped, quantized) on write AND on read so
/// a stale or foreign value can never produce a fractional-cell terminal.
struct TerminalFontSettings {
    static let defaultSize: Double = 14
    static let minimumSize: Double = 9
    static let maximumSize: Double = 32
    /// Point-size granularity for pinch zoom and the Settings slider.
    static let step: Double = 0.5

    private let defaults: UserDefaults
    private let key = "bicterm.terminal.fontSize"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var size: Double {
        guard let stored = defaults.object(forKey: key) as? Double else {
            return Self.defaultSize
        }
        return Self.normalize(stored)
    }

    func setSize(_ size: Double) {
        defaults.set(Self.normalize(size), forKey: key)
    }

    /// Drops the stored size; the next read returns the default.
    func reset() {
        defaults.removeObject(forKey: key)
    }

    /// Clamps to 9...32 and quantizes to 0.5pt steps (nearest, halves away
    /// from zero). Pure — shared by the pinch handler, the Settings slider,
    /// and persistence reads/writes.
    static func normalize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultSize }
        let clamped = min(max(size, minimumSize), maximumSize)
        return (clamped / step).rounded() * step
    }
}

/// Persisted global default edited by Settings. SessionStore resolves this
/// against each scene's override before applying changes to cached surfaces;
/// session pinch gestures write the scene override instead of this default.
///
/// Deliberately INDEPENDENT of Dynamic Type: the terminal is a fixed
/// character grid, not body text — the user's point-size choice must not be
/// re-scaled by the system text-size preference.
@MainActor
@Observable
final class TerminalFontModel {
    private var settings: TerminalFontSettings

    /// Current point size (always normalized). SwiftUI observes this;
    /// UIKit reads it at pinch-gesture start.
    private(set) var size: Double

    /// Fires after every APPLIED change (already normalized) so the view
    /// cache can re-font live surfaces. Untracked by Observation: it is a
    /// wiring hook, not view state.
    @ObservationIgnored var onApplied: ((Double) -> Void)?

    init(settings: TerminalFontSettings = TerminalFontSettings()) {
        self.settings = settings
        self.size = settings.size
    }

    /// Normalizes, persists, publishes, and notifies the cache. No-op when
    /// the normalized value equals the current size (pinch `.changed` events
    /// between 0.5pt steps land here constantly).
    func setSize(_ newSize: Double) {
        let normalized = TerminalFontSettings.normalize(newSize)
        guard normalized != size else { return }
        size = normalized
        settings.setSize(normalized)
        onApplied?(normalized)
    }

    /// Back to the default size; clears the persisted value.
    func reset() {
        settings.reset()
        guard size != TerminalFontSettings.defaultSize else { return }
        size = TerminalFontSettings.defaultSize
        onApplied?(size)
    }
}
