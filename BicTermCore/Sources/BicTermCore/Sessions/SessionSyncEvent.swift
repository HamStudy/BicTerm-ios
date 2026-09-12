import Foundation

/// Sync-integrity signals for the terminal inbound chain (T12). The
/// terminal byte stream is a VT feed: ANY gap or server-side session
/// replacement desynchronizes the local screen. These events are how the
/// registry tells surface consumers — without polluting the byte stream
/// itself — that a resync decision is required.
public enum SessionSyncEvent: Equatable, Sendable {
    /// A reconnect adopted a FRESHLY handshaked transport: the remote
    /// session (shell, pty) was replaced, so every byte of local VT state
    /// predating the adoption is stale. Consumers should perform a full
    /// local resync (VT reset + remote redraw poke). Not emitted for
    /// `.nativeRoaming` resumes — those reattach the SAME server-side
    /// session, where local VT state is still valid.
    case sessionReplaced
    /// A bounded inbound buffer in the terminal chain dropped chunks (slow
    /// consumer). The VT byte stream is now suspect: the cut can fall
    /// mid-escape-sequence, so the screen may render garbage. Never
    /// silent: this event is the user-visible anomaly signal.
    case inboundDropped
}

/// Capability for transports whose inbound bridging is bounded and must
/// be loud on overflow (mirrors the herdr transport's bounded-loud
/// policy). The registry installs one observer per adopted transport so a
/// drop at the transport's own yield site surfaces as
/// ``SessionSyncEvent/inboundDropped`` instead of vanishing.
public protocol InboundDropObserving: Sendable {
    func setInboundDropObserver(_ observer: (@Sendable () -> Void)?) async
}
