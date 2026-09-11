import BicTermCore
import Foundation
import HerdrClientCore

/// Opaque stable profile identity for one herdr endpoint (doc §3.5): never a
/// hostname, label, or pane ID — those can change without changing identity.
struct HerdrEndpointID: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// App-side routing key for one pane across machines (doc §3.6):
/// (endpoint, connection generation, server boot, server-local pane ID).
/// Two servers can both own `w1:p1`; this key keeps their state unmerged.
struct HerdrPaneRoutingKey: Hashable, Sendable, Identifiable {
    let endpoint: HerdrEndpointID
    let generation: UInt
    let bootID: String
    let paneID: String

    var id: String { "\(endpoint.rawValue)#\(generation)#\(bootID)#\(paneID)" }
}

enum HerdrEndpointPhase: Sendable, Equatable {
    case connecting
    case online
    /// Bounded reconnect attempts are running (doc §6.3): input is disabled,
    /// the state is visible, and a manual cancel is offered.
    case reconnecting
    case disconnected
    case failed
}

/// Typed connection-end explanation for the diagnostic screen (doc §4/§6.3:
/// stop with a clear message; never a silent private-protocol fallback).
struct HerdrDiagnostic: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case incompatibleGeneration
        case handshakeRejected
        case handshakeTimedOut
        case protocolViolation
        case transportLost
        case remoteClosed
        /// Local detach (doc §6.3 taxonomy): the remote workspace persists;
        /// re-attach sends a fresh hello and receives authoritative state.
        case userDetach
        /// The remote bridge ended abnormally (non-zero exit) — the server
        /// stopped under us rather than closing the session cleanly.
        case serverShutdown
        /// Authentication/authorization was lost; re-auth is a user action,
        /// never an automatic retry.
        case authLost
    }

    /// Official upstream remediation target for compatibility failures.
    static let remediationURL = URL(string: "https://github.com/herdrdev/herdr")

    /// The endpoint generation this app's protocol core implements (doc §4:
    /// generation 1; the Rust handshake enforces it — this is display data).
    static let expectedGeneration: UInt32 = 1

    let kind: Kind
    let detail: String
    let localCoreVersion: String
    let expectedGeneration: UInt32
    let remediationURL: URL?

    var id: String { "\(kind)-\(detail)" }

    var title: String {
        switch kind {
        case .incompatibleGeneration: "Incompatible Herdr server"
        case .handshakeRejected: "Herdr server refused the connection"
        case .handshakeTimedOut: "Herdr server did not answer"
        case .protocolViolation: "Herdr protocol error"
        case .transportLost: "Connection lost"
        case .remoteClosed: "Session ended"
        case .userDetach: "Detached"
        case .serverShutdown: "Herdr server stopped"
        case .authLost: "Authentication lost"
        }
    }

    /// Kinds whose remote workspace survives the local end: re-attach
    /// (fresh hello, authoritative snapshot) is the offered action.
    var reattachOffered: Bool {
        switch kind {
        case .userDetach, .remoteClosed, .serverShutdown, .transportLost: true
        case .incompatibleGeneration, .handshakeRejected, .handshakeTimedOut,
             .protocolViolation, .authLost: false
        }
    }

    var remediationRequired: Bool {
        kind == .incompatibleGeneration || kind == .handshakeRejected
    }

    static func incompatibleGeneration(detail: String) -> HerdrDiagnostic {
        HerdrDiagnostic(
            kind: .incompatibleGeneration,
            detail: detail,
            localCoreVersion: HerdrClient.coreVersion,
            expectedGeneration: expectedGeneration,
            remediationURL: remediationURL
        )
    }

    static func handshakeRejected(detail: String) -> HerdrDiagnostic {
        HerdrDiagnostic(
            kind: .handshakeRejected,
            detail: detail,
            localCoreVersion: HerdrClient.coreVersion,
            expectedGeneration: expectedGeneration,
            remediationURL: remediationURL
        )
    }

    static func simple(_ kind: Kind, detail: String) -> HerdrDiagnostic {
        HerdrDiagnostic(
            kind: kind,
            detail: detail,
            localCoreVersion: HerdrClient.coreVersion,
            expectedGeneration: expectedGeneration,
            remediationURL: nil
        )
    }
}

/// Typed outcome when a semantic input event cannot reach a pane: surfaced
/// as a transient workspace note and recorded in the DEBUG input echo.
enum HerdrInputNote: Sendable, Equatable {
    case offline
    case frozen
    case staleTarget(String)
    case writeFailed(String)
    /// Non-fatal OSC 52 drop reported by the FFI (oversized or malformed).
    case clipboardDropped(String)
    case pasteTooLarge
    /// The pane or boot changed between pasteboard read and send (doc §8.2).
    case pasteTargetChanged
    /// Scene-inactive suspension (doc §10): input is paused before the
    /// background detach runs, so ordering is never ambiguous.
    case suspended

    var message: String {
        switch self {
        case .offline: "Herdr endpoint is not online; input ignored"
        case .frozen: "Server is still syncing the surface; input held off"
        case .staleTarget(let paneID): "Pane \(paneID) is gone; input retargeted"
        case .writeFailed(let detail): "Input could not be sent: \(detail)"
        case .clipboardDropped(let detail): "Server clipboard data was dropped: \(detail)"
        case .pasteTooLarge:
            "Pasted text exceeds the \(HerdrClipboard.maxTextPasteBytes)-byte limit; nothing was sent"
        case .pasteTargetChanged: "Paste target changed before sending; paste cancelled"
        case .suspended: "Input paused while the scene is inactive"
        }
    }
}

enum HerdrFocusDirection: Sendable, Equatable {
    case up, down, left, right
}

/// Decoded bytes of the most recent OSC 52 server clipboard frame, held
/// for an explicit user copy (integration doc §8.3). The wire message
/// carries no pane field, so attribution is endpoint-level. The content is
/// never logged and never reaches the system pasteboard without a gesture
/// or the per-endpoint auto-copy opt-in.
struct HerdrRemoteClipboard: Sendable, Equatable {
    let data: Data
    let receivedAt: Date

    var byteCount: Int { data.count }

    /// OSC 52 payloads are clipboard text; non-UTF-8 bytes cannot be
    /// offered to the pasteboard as a string.
    var text: String? { String(data: data, encoding: .utf8) }
}

/// Machine-qualified per-endpoint published state (doc §3.5 layer table):
/// the coordinator above holds one of these per endpoint so T17/T19 can add
/// machines without reshaping the model.
struct HerdrEndpointState: Sendable, Equatable {
    var phase: HerdrEndpointPhase = .connecting
    var generation: UInt = 0
    var snapshot: HerdrShellSnapshot?
    var surface: HerdrPaneSurface?
    var surfaceUnavailable = false
    var diagnostic: HerdrDiagnostic?
    /// Preflight probe outcome (doc §6.1/§11): a present-but-incompatible
    /// result renders the probe diagnostic screen instead of the workspace.
    var probe: HerdrProbe.Result?
    /// 1-based attempt number while `.reconnecting`; nil otherwise.
    var reconnectAttempt: Int?
    var desiredCols: UInt32 = 80
    var desiredRows: UInt32 = 24
    var inputTargetOverride: String?
    var inputNote: HerdrInputNote?
    /// Server clipboard bytes awaiting the explicit copy action; nil once
    /// copied or when the auto-copy opt-in consumed them on arrival.
    var pendingRemoteClipboard: HerdrRemoteClipboard?

    /// The pane semantic input routes to right now: an explicit tap/nav
    /// override while it names a pane on the committed surface, else the
    /// snapshot's focused pane, else the surface's first pane. The override
    /// is revalidated every read so a pane removed by a later surface can
    /// never keep receiving input.
    var inputTargetPaneID: String? {
        guard let surface else { return nil }
        if let inputTargetOverride,
           surface.panes.contains(where: { $0.paneID == inputTargetOverride }) {
            return inputTargetOverride
        }
        if let focused = snapshot?.focusedPaneID,
           surface.panes.contains(where: { $0.paneID == focused }) {
            return focused
        }
        return surface.panes.first?.paneID
    }
}
