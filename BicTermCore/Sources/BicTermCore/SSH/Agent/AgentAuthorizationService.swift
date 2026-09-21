import Foundation

/// One agent sign request awaiting a user decision. This is the complete
/// payload T14's approval sheet renders — no UI types cross this boundary.
public struct AgentAuthorizationRequest: Equatable, Sendable {
    /// Owning terminal session (T10's identity; only this session's cache entry applies).
    public let sessionID: String
    /// Remote host the session is connected to.
    public let host: String
    /// "SHA256:…" fingerprint of the requested key (OpenSSHFingerprint.sha256).
    public let keyFingerprint: String
    /// Exact wire-format public key blob the remote asked us to sign with.
    public let publicKeyBlob: Data

    public init(sessionID: String, host: String, keyFingerprint: String, publicKeyBlob: Data) {
        self.sessionID = sessionID
        self.host = host
        self.keyFingerprint = keyFingerprint
        self.publicKeyBlob = publicKeyBlob
    }
}

public enum AgentAuthorizationDecision: Equatable, Sendable {
    /// Sign this one request; ask again next time.
    case allowOnce
    /// Sign requests for this key for the rest of THIS session; ask again in any other session.
    case allowForSession
    case deny
}

/// UI-facing decision hook. T14 implements this with a SwiftUI sheet; tests
/// implement it with scripted decisions. Called at most `maxConcurrentPrompts`
/// at a time by the service.
public protocol AgentAuthorizationPrompt: Sendable {
    func decide(_ request: AgentAuthorizationRequest) async -> AgentAuthorizationDecision
}

/// Answers whether the app is in a state where a user could meaningfully
/// approve a signature. Foreground + unlocked is interactive; backgrounded or
/// locked is not. Sync on purpose: lock state must be checkable without
/// suspension on the decision hot path.
public protocol LockStateProvider: Sendable {
    var isInteractive: Bool { get }
    /// Monotonic counter incremented on every true background transition
    /// (regardless of app-lock enablement). Authorization flows capture it
    /// before deciding and revalidate it before acting on the decision: an
    /// unchanged generation proves the app never left the foreground in
    /// between, so a gesture recorded before a background excursion can
    /// never authorize work performed after the return.
    var interactivityGeneration: UInt64 { get }
}

/// Guarded sign-authorization policy for the forwarded SSH agent.
///
/// Policy order, exactly:
/// 1. Not interactive (backgrounded/locked) → deny WITHOUT prompting, even for
///    session-cached keys. A gesture recorded earlier cannot authorize
///    signatures while the user cannot observe the app.
/// 2. `.allowForSession` cache hit for (sessionID, keyFingerprint) → allow.
/// 3. Otherwise prompt. Only `.allowForSession` populates the cache.
///
/// Flood bound: at most `maxConcurrentPrompts` prompts in flight; requests
/// beyond `maxPendingRequests` waiting for a prompt are denied immediately.
public actor AgentAuthorizationService {
    private let prompt: any AgentAuthorizationPrompt
    private let lockState: any LockStateProvider
    private let maxConcurrentPrompts: Int
    private let maxPendingRequests: Int

    private var sessionApprovals: Set<SessionKey> = []
    private var inFlightPrompts = 0
    private var pendingRequests = 0
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []

    private struct SessionKey: Hashable {
        let sessionID: String
        let keyFingerprint: String
    }

    public init(
        prompt: any AgentAuthorizationPrompt,
        lockState: any LockStateProvider,
        maxConcurrentPrompts: Int = 1,
        maxPendingRequests: Int = 64
    ) {
        self.prompt = prompt
        self.lockState = lockState
        self.maxConcurrentPrompts = max(1, maxConcurrentPrompts)
        self.maxPendingRequests = max(0, maxPendingRequests)
    }

    /// Interactivity generation at the start of an authorization flow. The
    /// bridge captures it before ``authorize(_:)`` and revalidates it after
    /// signing, immediately before the success response is enqueued.
    nonisolated public var currentAuthorizationGeneration: UInt64 {
        lockState.interactivityGeneration
    }

    /// Pre-enqueue revalidation: an authorization that began at `generation`
    /// is still valid only if the app never backgrounded since (generation
    /// unchanged) and is interactive now.
    nonisolated public func isAuthorizationValid(generation: UInt64) -> Bool {
        lockState.isInteractive && lockState.interactivityGeneration == generation
    }

    public func authorize(_ request: AgentAuthorizationRequest) async -> Bool {
        guard lockState.isInteractive else { return false }

        let key = SessionKey(sessionID: request.sessionID, keyFingerprint: request.keyFingerprint)
        if sessionApprovals.contains(key) { return true }

        guard await acquirePromptSlot() else { return false }
        defer { releasePromptSlot() }

        // Re-check after the wait: another request may have recorded a
        // session approval, and the app may have backgrounded meanwhile.
        guard lockState.isInteractive else { return false }
        if sessionApprovals.contains(key) { return true }

        switch await prompt.decide(request) {
        case .allowOnce:
            return true
        case .allowForSession:
            sessionApprovals.insert(key)
            return true
        case .deny:
            return false
        }
    }

    /// False when the pending-request bound is exceeded (immediate denial).
    private func acquirePromptSlot() async -> Bool {
        if inFlightPrompts < maxConcurrentPrompts {
            inFlightPrompts += 1
            return true
        }
        guard pendingRequests < maxPendingRequests else { return false }
        pendingRequests += 1
        defer { pendingRequests -= 1 }
        await withCheckedContinuation { promptWaiters.append($0) }
        inFlightPrompts += 1
        return true
    }

    private func releasePromptSlot() {
        inFlightPrompts -= 1
        if !promptWaiters.isEmpty, inFlightPrompts < maxConcurrentPrompts {
            promptWaiters.removeFirst().resume()
        }
    }
}
