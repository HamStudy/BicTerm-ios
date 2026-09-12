import SwiftUI

/// The one token-driven pill/badge for the app: status chips, protocol and
/// key-type badges, hop counts, and tab pills. Type (caption), spacing,
/// fill band (TerminalMetric.badgeFill), and radius
/// (TerminalMetric.badgeRadius) come from the design tokens; a call site
/// supplies only its semantic tint and, for selected-state treatments, an
/// explicit fill and/or stroke. Accessibility identifiers stay on the call
/// sites.
struct TerminalBadge: View {
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    /// Padding presets matching the call sites the badge unified.
    enum Size {
        /// Inline chips next to titles (h:xs v:xxxs).
        case compact
        /// Pills inside tappable button labels (h:sm v:xs).
        case regular
        /// Tab-bar pills (h:sm v:xxs).
        case tab
    }

    enum Shape {
        case capsule
        /// Rounded rectangle at TerminalMetric.badgeRadius.
        case rounded
    }

    let text: String
    let systemImage: String?
    let tint: Color
    let fill: Color?
    let stroke: Color?
    let strokeWidth: CGFloat
    let size: Size
    let shape: Shape

    init(
        _ text: String,
        systemImage: String? = nil,
        tint: Color,
        fill: Color? = nil,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 1,
        size: Size = .compact,
        shape: Shape = .capsule
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.size = size
        self.shape = shape
    }

    var body: some View {
        content
            .font(typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .modifier(
                BadgeChrome(
                    shape: shape,
                    fill: fill ?? tint.opacity(TerminalMetric.badgeFill),
                    stroke: stroke,
                    strokeWidth: strokeWidth
                )
            )
    }

    @ViewBuilder
    private var content: some View {
        if let systemImage {
            Label(text, systemImage: systemImage)
        } else {
            Text(text)
        }
    }

    private var horizontalPadding: CGFloat {
        size == .compact ? spacing.xs : spacing.sm
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact: spacing.xxxs
        case .regular: spacing.xs
        case .tab: spacing.xxs
        }
    }
}

/// Shape-erased badge fill + optional stroke for the capsule/rounded
/// variants (the `background(_:in:)` shape types differ per case).
private struct BadgeChrome: ViewModifier {
    let shape: TerminalBadge.Shape
    let fill: Color
    let stroke: Color?
    let strokeWidth: CGFloat

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content
                .background(fill, in: Capsule())
                .overlay { stroke.map { Capsule().stroke($0, lineWidth: strokeWidth) } }
        case .rounded:
            content
                .background(fill, in: RoundedRectangle(cornerRadius: TerminalMetric.badgeRadius))
                .overlay {
                    stroke.map {
                        RoundedRectangle(cornerRadius: TerminalMetric.badgeRadius)
                            .stroke($0, lineWidth: strokeWidth)
                    }
                }
        }
    }
}
