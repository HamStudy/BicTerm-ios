import Foundation
import HerdrCore

/// Typed mirror of the FFI result codes; details are copied out of the
/// borrowed C string immediately so no Rust-owned memory crosses back.
public enum HerdrClientError: Error, Sendable, Equatable {
    case invalidArgument(String)
    case panic(String)
    case disconnected(String)
    case protocolViolation(String)
    case handshakeTimedOut(String)
    case handshakeExpectedWelcome(String)
    case handshakeInvalidWelcome(String)
    case handshakeIncompatible(String)
    case handshakeRejected(String)
    case notOnline(String)
    case inputFrozen(String)
    case inputStaleTarget(String)
    case inputWriteFailed(String)
    case surfaceRejected(String)
    case clientFailed(String)
    /// Non-fatal: an OSC 52 clipboard frame was dropped (oversized or
    /// malformed); the client stays Online and keeps decoding.
    case clipboardDropped(String)
    case unknown(code: Int32, String)

    static func from(_ result: HerdrResult) -> HerdrClientError {
        let detail = result.detail.map { String(cString: $0) } ?? ""
        return fromCode(result.code, detail: detail)
    }

    static func fromCode(_ code: Int32, detail: String) -> HerdrClientError {
        switch code {
        case HERDR_CODE_INVALID_ARGUMENT: return .invalidArgument(detail)
        case HERDR_CODE_PANIC: return .panic(detail)
        case HERDR_CODE_DISCONNECTED: return .disconnected(detail)
        case HERDR_CODE_PROTOCOL_VIOLATION: return .protocolViolation(detail)
        case HERDR_CODE_HANDSHAKE_TIMED_OUT: return .handshakeTimedOut(detail)
        case HERDR_CODE_HANDSHAKE_EXPECTED_WELCOME: return .handshakeExpectedWelcome(detail)
        case HERDR_CODE_HANDSHAKE_INVALID_WELCOME: return .handshakeInvalidWelcome(detail)
        case HERDR_CODE_HANDSHAKE_INCOMPATIBLE: return .handshakeIncompatible(detail)
        case HERDR_CODE_HANDSHAKE_REJECTED: return .handshakeRejected(detail)
        case HERDR_CODE_NOT_ONLINE: return .notOnline(detail)
        case HERDR_CODE_INPUT_FROZEN: return .inputFrozen(detail)
        case HERDR_CODE_INPUT_STALE_TARGET: return .inputStaleTarget(detail)
        case HERDR_CODE_INPUT_WRITE_FAILED: return .inputWriteFailed(detail)
        case HERDR_CODE_SURFACE_REJECTED: return .surfaceRejected(detail)
        case HERDR_CODE_CLIENT_FAILED: return .clientFailed(detail)
        case HERDR_CODE_CLIPBOARD_DROPPED: return .clipboardDropped(detail)
        default: return .unknown(code: code, detail)
        }
    }
}

/// Lifecycle phase reported by the Rust core.
public enum HerdrPhase: UInt32, Sendable, Equatable {
    case awaitingWelcome = 0
    case online = 1
    case failed = 2

    init(rawValueOrUnknown raw: UInt32) {
        self = HerdrPhase(rawValue: raw) ?? .failed
    }
}

/// Conservative hello parameters (integration doc §4): advertise only what
/// the app implements; the Rust core forces generation 1, the four v1 codecs
/// and `direct_graphics = false`.
public struct HerdrClientConfig: Sendable, Equatable {
    public var cols: UInt32
    public var rows: UInt32
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32
    public var pixelMouse: Bool
    public var mouseCapture: Bool
    /// Inbound frame byte cap; 0 selects the protocol default. Tests that
    /// exercise the clipboard drop path lift this so an oversized clipboard
    /// frame reaches the dedicated drop branch instead of failing the whole
    /// frame as a protocol violation.
    public var maxFrameSize: UInt32
    /// Outbound queue byte budget; 0 selects the FFI default (4 MiB), which
    /// cannot hold a maximum-size clipboard image frame (16 MiB payload plus
    /// envelope). The app lifts this so bounded image paste can drain.
    public var outboundByteLimit: UInt32

    public init(
        cols: UInt32,
        rows: UInt32,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        pixelMouse: Bool = false,
        mouseCapture: Bool = false,
        maxFrameSize: UInt32 = 0,
        outboundByteLimit: UInt32 = 0
    ) {
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.pixelMouse = pixelMouse
        self.mouseCapture = mouseCapture
        self.maxFrameSize = maxFrameSize
        self.outboundByteLimit = outboundByteLimit
    }

    var ffi: herdr_client_config {
        herdr_client_config(
            cols: cols,
            rows: rows,
            cell_width_px: cellWidthPx,
            cell_height_px: cellHeightPx,
            pixel_mouse: pixelMouse,
            mouse_capture: mouseCapture,
            max_frame_size: maxFrameSize,
            outbound_message_limit: 0,
            outbound_byte_limit: outboundByteLimit
        )
    }
}

/// Semantic key event routed to a pane. This is input classification, not
/// protocol construction — the frozen wire encoding stays in Rust.
public enum HerdrKeyCode: Sendable, Equatable {
    case backspace, enter, left, right, up, down, home, end
    case pageUp, pageDown, tab, backTab, delete, insert, esc, null
    case char(Unicode.Scalar)
    case function(UInt8)
}

public enum HerdrKeyKind: UInt8, Sendable, Equatable {
    case press = 0, `repeat` = 1, release = 2
}

public struct HerdrKeyInput: Sendable, Equatable {
    public var code: HerdrKeyCode
    public var modifiers: UInt8
    public var kind: HerdrKeyKind
    public var repeatCount: UInt16
    public var shiftedCodepoint: Unicode.Scalar?

    public init(
        code: HerdrKeyCode,
        modifiers: UInt8 = 0,
        kind: HerdrKeyKind = .press,
        repeatCount: UInt16 = 1,
        shiftedCodepoint: Unicode.Scalar? = nil
    ) {
        self.code = code
        self.modifiers = modifiers
        self.kind = kind
        self.repeatCount = repeatCount
        self.shiftedCodepoint = shiftedCodepoint
    }}
