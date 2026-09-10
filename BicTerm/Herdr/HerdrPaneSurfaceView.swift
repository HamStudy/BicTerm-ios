import SwiftUI

/// App-owned color decode of herdr's packed u32 cell colors
/// (upstream `color_to_u32`): tag byte 0x00 = named (0..=16), 0x01 = xterm
/// palette index, 0x02 = direct RGB.
enum HerdrCellColor {
    static func color(_ packed: UInt32, foreground: Bool, palette: HerdrTerminalPalette) -> Color {
        switch packed >> 24 {
        case 0x00:
            return named(packed & 0xFF, foreground: foreground, palette: palette)
        case 0x01:
            return palette.indexed(Int(packed & 0xFF))
        default:
            let r = Double((packed >> 16) & 0xFF) / 255
            let g = Double((packed >> 8) & 0xFF) / 255
            let b = Double(packed & 0xFF) / 255
            return Color(red: r, green: g, blue: b)
        }
    }

    private static func named(_ raw: UInt32, foreground: Bool, palette: HerdrTerminalPalette) -> Color {
        switch raw {
        case 0:
            return foreground ? palette.defaultForeground : palette.defaultBackground
        case 1...16:
            return palette.indexed(Int(raw) - 1)
        default:
            return foreground ? palette.defaultForeground : palette.defaultBackground
        }
    }
}

/// ratatui-style modifier bits carried in `CellData.modifier` (extension
/// bits beyond the known set render without their effect — conservative).
enum HerdrCellModifier {
    static let bold: UInt16 = 1 << 0
    static let italic: UInt16 = 1 << 2
    static let underlined: UInt16 = 1 << 3
    static let reversed: UInt16 = 1 << 6
}

/// xterm-256 palette matching the app's terminal colors (design tokens).
struct HerdrTerminalPalette {
    let defaultForeground: Color
    let defaultBackground: Color
    private let indexedColors: [Color]

    init(defaultForeground: Color, defaultBackground: Color) {
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground

        var colors: [Color] = []
        let base: [[UInt]] = [
            [0x000000, 0xCD3131, 0x00BC00, 0xBCBC00, 0x0070FF, 0xBC00BC, 0x00BCBC, 0xE6EDF3],
            [0x666666, 0xFF6E6E, 0x00FF00, 0xFFFF00, 0x00A5FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF],
        ]
        for row in base {
            for value in row {
                colors.append(Color(hex: value))
            }
        }
        for green in 0...5 {
            for red in 0...5 {
                for blue in 0...5 {
                    let component: (Int) -> Double = { level in
                        Double(level == 0 ? 0 : 40 * level + 55) / 255
                    }
                    colors.append(Color(
                        red: component(red),
                        green: component(green),
                        blue: component(blue)
                    ))
                }
            }
        }
        for step in 0...23 {
            let level = Double(8 + step * 10) / 255
            colors.append(Color(red: level, green: level, blue: level))
        }
        indexedColors = colors
    }

    func indexed(_ index: Int) -> Color {
        guard index >= 0, index < indexedColors.count else { return defaultForeground }
        return indexedColors[index]
    }
}

/// Native renderer for one committed ``HerdrPaneSurface`` (integration doc
/// §3.3): the cell grid is drawn directly from the immutable snapshot — it
/// NEVER re-encodes cells to ANSI through the VT parser. Pane chrome
/// (borders, focused highlight, cursor) overlays the exact surface geometry
/// the remote produced, and each pane is an accessibility element labeled
/// from that same geometry.
struct HerdrPaneSurfaceView: View {
    @Environment(\.terminalColors) private var colors

    let surface: HerdrPaneSurface
    let paneMetadata: [String: String]
    var inputTargetID: String?
    var onPaneTap: ((String) -> Void)?
    var onGridChange: ((Int, Int) -> Void)?

    @State private var reportedCols = 0
    @State private var reportedRows = 0

    private var palette: HerdrTerminalPalette {
        HerdrTerminalPalette(
            defaultForeground: colors.foreground,
            defaultBackground: colors.background
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let cellWidth = geometry.size.width / CGFloat(surface.frame.width)
            let cellHeight = geometry.size.height / CGFloat(surface.frame.height)
            ZStack {
                Canvas { context, _ in
                    drawCells(context: context, cellWidth: cellWidth, cellHeight: cellHeight)
                    drawCursor(context: context, cellWidth: cellWidth, cellHeight: cellHeight)
                }
                paneChrome(cellWidth: cellWidth, cellHeight: cellHeight)
            }
            .onChange(of: geometry.size, initial: true) { _, newSize in
                reportGrid(for: newSize)
            }
        }
        .background(colors.background)
    }

    /// Desired grid at the current pixel size, quantized to the 8x16 cell
    /// the FFI is configured with. The first layout is a silent baseline —
    /// the connect-time fence geometry stands until the geometry genuinely
    /// changes (rotation, window resize), and only then is a resize sent.
    private func reportGrid(for size: CGSize) {
        let cols = Int(size.width / 8)
        let rows = Int(size.height / 16)
        guard cols > 0, rows > 0 else { return }
        if reportedCols == 0 && reportedRows == 0 {
            reportedCols = cols
            reportedRows = rows
            return
        }
        guard cols != reportedCols || rows != reportedRows else { return }
        reportedCols = cols
        reportedRows = rows
        onGridChange?(cols, rows)
    }

    private func drawCells(context: GraphicsContext, cellWidth: CGFloat, cellHeight: CGFloat) {
        // Fit glyphs inside the cell box in BOTH axes: a monospaced advance
        // is ~0.6em, so the width constraint binds whenever the grid is
        // wider than a terminal-aspect layout (phone-width 80-column grid).
        let fontSize = min(cellHeight * 0.78, cellWidth / 0.62)
        for y in 0..<surface.frame.height {
            for x in 0..<surface.frame.width {
                guard let index = surface.frame.cellIndex(x: x, y: y) else { continue }
                let cell = surface.frame.cells[index]
                let rect = CGRect(
                    x: CGFloat(x) * cellWidth,
                    y: CGFloat(y) * cellHeight,
                    width: cellWidth.rounded(.up),
                    height: cellHeight.rounded(.up)
                )
                let reversed = cell.modifier & HerdrCellModifier.reversed != 0
                let foreground = HerdrCellColor.color(
                    cell.fg, foreground: true, palette: palette
                )
                let background = HerdrCellColor.color(
                    cell.bg, foreground: false, palette: palette
                )
                let symbol = cell.symbol.isEmpty ? " " : cell.symbol

                let fill = reversed ? foreground : background
                if fill != palette.defaultBackground {
                    context.fill(Path(rect), with: .color(fill))
                }
                var text = Text(symbol)
                    .font(.system(size: fontSize, weight: cell.modifier & HerdrCellModifier.bold != 0 ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(reversed ? background : foreground)
                if cell.modifier & HerdrCellModifier.italic != 0 {
                    text = text.italic()
                }
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    private func drawCursor(context: GraphicsContext, cellWidth: CGFloat, cellHeight: CGFloat) {
        guard let cursor = surface.frame.cursor, cursor.visible else { return }
        let rect = CGRect(
            x: CGFloat(cursor.x) * cellWidth,
            y: CGFloat(cursor.y) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        let shape = cursor.shape
        let cursorRect: CGRect
        if shape == 3 || shape == 4 {
            cursorRect = CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)
        } else if shape == 5 || shape == 6 {
            cursorRect = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        } else {
            cursorRect = rect
        }
        context.fill(
            Path(cursorRect),
            with: .color(colors.accent.opacity(0.75))
        )
    }

    @ViewBuilder
    private func paneChrome(cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        // Layout-based placement, not .position: a positioned view reports
        // the container's frame to accessibility, so every pane element
        // claimed the whole pane area and XCUI/VoiceOver landed on the
        // wrong pane (observed: tap on p1's center hit p4's corner).
        ZStack(alignment: .topLeading) {
            ForEach(surface.panes) { pane in
                let rect = CGRect(
                    x: CGFloat(pane.rect.x) * cellWidth,
                    y: CGFloat(pane.rect.y) * cellHeight,
                    width: CGFloat(pane.rect.width) * cellWidth,
                    height: CGFloat(pane.rect.height) * cellHeight
                )
                let isTarget = pane.paneID == inputTargetID
                ZStack {
                    Rectangle()
                        .stroke(
                            isTarget ? colors.accent : colors.selection,
                            lineWidth: isTarget ? 2 : 1
                        )
                    // Invisible element base: Color.clear frames reliably
                    // materialize as accessibility elements; bare stroke shapes
                    // are pruned unless they carry traits.
                    Color.clear
                }
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .onTapGesture { onPaneTap?(pane.paneID) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(paneAccessibilityLabel(pane))
                .accessibilityIdentifier("herdr-pane-\(pane.paneID)")
                .accessibilityAddTraits(isTarget ? [.isSelected] : [.isStaticText])
                .padding(.leading, rect.minX)
                .padding(.top, rect.minY)
            }
        }
    }

    private func paneAccessibilityLabel(_ pane: HerdrSurfacePane) -> String {
        var parts = ["Pane \(pane.paneID)"]
        parts.append(pane.focused ? "focused" : "background")
        if pane.paneID == inputTargetID {
            parts.append("input target")
        }
        parts.append("\(pane.innerRect.width) by \(pane.innerRect.height) cells")
        if let metadata = paneMetadata[pane.paneID], !metadata.isEmpty {
            parts.append(metadata)
        }
        return parts.joined(separator: ", ")
    }
}
