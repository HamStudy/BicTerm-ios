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

    var message: String {
        switch self {
        case .offline: "Herdr endpoint is not online; input ignored"
        case .frozen: "Server is still syncing the surface; input held off"
        case .staleTarget(let paneID): "Pane \(paneID) is gone; input retargeted"
        case .writeFailed(let detail): "Input could not be sent: \(detail)"
        }
    }
}

enum HerdrFocusDirection: Sendable, Equatable {
    case up, down, left, right
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
    var desiredCols: UInt32 = 80
    var desiredRows: UInt32 = 24
    var inputTargetOverride: String?
    var inputNote: HerdrInputNote?

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
