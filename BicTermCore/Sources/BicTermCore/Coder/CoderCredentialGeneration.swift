import Foundation

/// One server's credential generation (spec §4.3: a generation number is
/// stored with every connection; a replacement token starts a NEW
/// generation — mutating an in-flight generation is forbidden).
public struct CoderCredentialGeneration: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// New dials with this generation proceed.
        case active
        /// Confirmed authentication loss: NO new dials (spec §14.5 step 3).
        /// Established sessions are unaffected — they continue until
        /// natural end (explicit client policy, Docs/SECURITY.md).
        case authRequired
    }

    public let id: UInt64
    public let state: State
}

/// Per-server credential-generation tracker. The tracker never holds token
/// bytes — it records only the generation lifecycle:
///
/// 1. First contact with a server mints generation 1, `.active`.
/// 2. A classified genuine `authRequired` (see ``CoderEventClassifier``) — or
///    the connect-time REST 401 a fresh resolution hit — marks the current
///    generation `.authRequired` ONCE (re-marks of the same generation are
///    no-ops, so duplicate signals never double-fire) and broadcasts the
///    server on ``authLosses``.
/// 3. The reauthenticate flow (T19) validates the replacement credential
///    with a FRESH client (identity check included), persists it, then calls
///    ``installReplacement(for:)``: the generation bumps and returns to
///    `.active`. Transports stamp the new id into every tunnel start config,
///    and each new dial allocates a FRESH Go handle — an old handle (and old
///    generation) is never reused for a post-replacement connection.
///
/// Single mutation authority for generation state; safe to share across the
/// transport factory, the lifecycle coordinator, and the UI flow.
public actor CoderCredentialGenerations {
    private var generations: [UUID: CoderCredentialGeneration] = [:]
    private let lossContinuation: AsyncStream<UUID>.Continuation

    /// Fires once per generation that transitions to `.authRequired`,
    /// carrying the server ID. Single consumer (session-derived consumers
    /// compete for elements if attached more than once).
    public nonisolated let authLosses: AsyncStream<UUID>

    public init() {
        let (stream, continuation) = AsyncStream<UUID>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.authLosses = stream
        self.lossContinuation = continuation
    }

    /// The current generation, minting `.active` generation 1 on first
    /// contact with the server.
    public func generation(for serverID: UUID) -> CoderCredentialGeneration {
        if let existing = generations[serverID] { return existing }
        let minted = CoderCredentialGeneration(id: 1, state: .active)
        generations[serverID] = minted
        return minted
    }

    /// Mark the server's current generation `AuthRequired`. Idempotent per
    /// generation: only the first mark broadcasts (spec §15: the genuine-401
    /// path surfaces exactly once, then waits on the reauthenticate flow).
    public func markAuthRequired(for serverID: UUID) {
        let current = generation(for: serverID)
        guard current.state == .active else { return }
        generations[serverID] = CoderCredentialGeneration(id: current.id, state: .authRequired)
        lossContinuation.yield(serverID)
    }

    /// Install the validated replacement: bump the generation and return it
    /// to `.active`. Call ONLY after the replacement credential was validated
    /// (identity included) and persisted by the reauthenticate flow.
    @discardableResult
    public func installReplacement(for serverID: UUID) -> CoderCredentialGeneration {
        let current = generation(for: serverID)
        let next = CoderCredentialGeneration(id: current.id + 1, state: .active)
        generations[serverID] = next
        return next
    }
}
