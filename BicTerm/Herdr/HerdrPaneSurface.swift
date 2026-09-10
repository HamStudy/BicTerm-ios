import Foundation

/// Swift decode of the stable pane-surface JSON carrier produced by the Rust
/// core (`herdr_client_surface`). Render-side data only: the frozen bincode
/// codec stays in Rust (integration doc §3.3/§3.4) and these types never
/// encode anything back onto the wire.
struct HerdrPaneSurface: Sendable, Equatable, Decodable {
    let bootID: String
    let projectionRevision: UInt64
    let surfaceRevision: UInt64
    let frame: HerdrSurfaceFrame
    let panes: [HerdrSurfacePane]
    let splits: [HerdrSurfaceSplit]

    enum CodingKeys: String, CodingKey {
        case bootID = "boot_id"
        case projectionRevision = "projection_revision"
        case surfaceRevision = "surface_revision"
        case frame, panes, splits
    }
}

struct HerdrSurfaceFrame: Sendable, Equatable, Decodable {
    let cells: [HerdrSurfaceCell]
    let width: Int
    let height: Int
    let cursor: HerdrSurfaceCursor?
    let hyperlinks: [String]

    var cellCountIsValid: Bool {
        cells.count == width * height
    }

    func cellIndex(x: Int, y: Int) -> Int? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let index = y * width + x
        guard index < cells.count else { return nil }
        return index
    }
}

struct HerdrSurfaceCell: Sendable, Equatable, Decodable {
    let symbol: String
    let fg: UInt32
    let bg: UInt32
    let modifier: UInt16
    let skip: Bool
    let hyperlink: UInt32?
}

struct HerdrSurfaceCursor: Sendable, Equatable, Decodable {
    let x: Int
    let y: Int
    let visible: Bool
    let shape: UInt8
}

struct HerdrSurfacePane: Sendable, Equatable, Decodable, Identifiable {
    let paneID: String
    let contentRevision: UInt64
    let rect: HerdrSurfaceRect
    let innerRect: HerdrSurfaceRect
    let scrollbarRect: HerdrSurfaceRect?
    let scroll: HerdrSurfaceScrollMetrics?
    let focused: Bool
    let mouseReporting: Bool
    let sgrPixelMouse: Bool
    let alternateScreenActive: Bool
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case contentRevision = "content_revision"
        case rect
        case innerRect = "inner_rect"
        case scrollbarRect = "scrollbar_rect"
        case scroll, focused
        case mouseReporting = "mouse_reporting"
        case sgrPixelMouse = "sgr_pixel_mouse"
        case alternateScreenActive = "alternate_screen_active"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}

struct HerdrSurfaceScrollMetrics: Sendable, Equatable, Decodable {
    let offsetFromBottom: UInt64
    let maxOffsetFromBottom: UInt64
    let viewportRows: UInt64

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }
}

struct HerdrSurfaceSplit: Sendable, Equatable, Decodable {
    enum Direction: String, Sendable, Equatable, Decodable {
        case horizontal = "Horizontal"
        case vertical = "Vertical"
    }

    let direction: Direction
    let pos: Int
    let area: HerdrSurfaceRect
    let hitRect: HerdrSurfaceRect
    let path: [Bool]

    enum CodingKeys: String, CodingKey {
        case direction, pos, area
        case hitRect = "hit_rect"
        case path
    }
}

struct HerdrSurfaceRect: Sendable, Equatable, Decodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}
