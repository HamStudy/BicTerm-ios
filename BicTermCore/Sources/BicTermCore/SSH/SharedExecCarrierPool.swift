import Foundation

/// Shared-first exec carrier pool: exec consumers (herdr probe, bridge,
/// installer steps) ride ONE lazily-dialed shared SSH connection by
/// default, and fall back to a DEDICATED per-lease connection only when a
/// channel-budget gateway (Coder-style: one session channel per
/// connection LIFETIME — see ``SSHTransport/connectExecOnly(to:)``)
/// denies the shared carrier's channel open.
///
/// Policy:
/// - **Shared-first.** The first ``lease()`` establishes the pool's
///   single shared connection via `dial` (concurrent `lease()` and
///   first-open calls dedupe onto ONE in-flight dial); every lease's
///   ``Lease/openExecChannel(command:)`` tries that carrier.
/// - **Denial → dedicated, sticky.** A typed `.channelDenied` from the
///   shared carrier's open retires the shared carrier, flips the pool
///   sticky-dedicated, dials a dedicated connection, and retries the
///   open once on it; that lease then OWNS the connection
///   (`lease.close()` closes it — the pre-pool consumer owner-close
///   contract). Every lease issued after the flip dials its own
///   dedicated connection directly at `lease()` time, recovering the
///   Coder-era per-consumer shape exactly where a budget gateway
///   requires it.
/// - **Dead-shared recovery.** A NON-denial error from a stale shared
///   carrier closes it, redials the shared connection once, and retries
///   the open; a second failure propagates. Recovery never flips
///   sticky — the shared era continues on the replacement.
/// - **Close semantics.** A shared-mode lease's `close()` is a release
///   only (the shared carrier survives between consumers).
///   ``close()`` closes the shared carrier if established and is
///   idempotent; leases that already own a dedicated carrier keep it
///   across pool close (their carrier closes via the lease's own
///   `close()`).
///
/// Swift 6 hazard notes (repo conventions): `dial` and every internal
/// helper that can surface its failures are UNTYPED `throws` — the
/// ``JumpChainBuilder/build(connection:cols:rows:)`` precedent (typed
/// throws returning protocol existentials crashes the SIL verifier) —
/// so typed dial errors (e.g. `.requiresTrust`) keep their payload; only
/// the typed ``Lease/openExecChannel(command:)`` boundary splits the
/// error via a conditional-cast catch (the swift-frontend 6.4 SILGen
/// assertion workaround). The pool never touches NIO event-loop threads.
public actor SharedExecCarrierPool {
    /// Per-lease state. `ownedConnection` is non-nil exactly when the
    /// lease owns a dedicated carrier (sticky era or post-fallback).
    private struct LeaseRecord {
        var ownedConnection: (any SSHExecCapableConnection)?
    }

    private let dial: @Sendable () async throws -> any SSHExecCapableConnection
    private var sharedConnection: (any SSHExecCapableConnection)?
    private var stickyDedicated = false
    private var closed = false
    private var leaseRecords: [UUID: LeaseRecord] = [:]

    // Single-in-flight shared-establish dedupe.
    private var establishing = false
    private var establishWaiters: [CheckedContinuation<any SSHExecCapableConnection, Error>] = []

    public init(dial: @escaping @Sendable () async throws -> any SSHExecCapableConnection) {
        self.dial = dial
    }

    /// One exec consumer's handle onto the pool's policy. Conforms to
    /// ``SSHExecCapableConnection`` so consumers ride it exactly as they
    /// rode their own connection before the pool existed.
    public struct Lease: SSHExecCapableConnection {
        let pool: SharedExecCarrierPool
        let leaseID: UUID

        public func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
            do {
                return try await pool.openChannel(for: leaseID, command: command)
            } catch {
                // Conditional cast: swift-frontend 6.4 SILGen assertion on
                // catch-as in typed-throws funcs. Typed failures pass
                // through; the dial closure's untyped failures collapse to
                // .unreachable (the connection could not be established).
                if let error = error as? TransportError {
                    throw error
                } else {
                    throw TransportError.unreachable
                }
            }
        }

        /// Owner-close: closes the lease's dedicated carrier when it owns
        /// one; in shared mode this is a release only (the shared carrier
        /// survives between consumers).
        public func close() async {
            await pool.closeLease(leaseID)
        }
    }

    /// Returns a new lease. In the shared era this establishes (or joins)
    /// the pool's single shared connection; once sticky-dedicated, every
    /// lease dials its OWN connection via `dial` directly.
    ///
    /// Untyped `throws` (the ``JumpChainBuilder/build(connection:cols:rows:)``
    /// precedent): dial failures surface raw so typed dial errors keep
    /// their payload. After ``close()`` this throws typed
    /// ``TransportError/channelDenied``.
    public func lease() async throws -> Lease {
        guard !closed else {
            throw TransportError.channelDenied
        }
        if stickyDedicated {
            return try await leaseDedicated()
        }
        do {
            _ = try await establishShared()
        } catch {
            // The shared era may have ended (another lease's denial went
            // sticky) while this lease was joining the in-flight
            // establish — fall through to the dedicated path instead of
            // failing the lease.
            guard stickyDedicated else { throw error }
            return try await leaseDedicated()
        }
        let leaseID = UUID()
        leaseRecords[leaseID] = LeaseRecord(ownedConnection: nil)
        return Lease(pool: self, leaseID: leaseID)
    }

    /// Closes the shared connection if one is established. Terminal for
    /// the shared era; leases that own dedicated carriers keep them (the
    /// owner-close contract). Idempotent.
    public func close() async {
        closed = true
        if let shared = sharedConnection {
            sharedConnection = nil
            await shared.close()
        }
    }

    // MARK: Lease backing (actor-isolated)

    /// Untyped `throws` (existential-returning internals; the typed split
    /// lives at the ``Lease`` boundary).
    func openChannel(for leaseID: UUID, command: String) async throws -> SSHExecSession {
        guard leaseRecords[leaseID] != nil else {
            // The lease was closed; every subsequent op fails typed.
            throw TransportError.channelDenied
        }
        if let owned = leaseRecords[leaseID]?.ownedConnection {
            return try await owned.openExecChannel(command: command)
        }
        if stickyDedicated {
            // The era flipped between lease() and this open: dial this
            // lease's dedicated connection now.
            return try await openViaDedicated(leaseID: leaseID, command: command)
        }
        return try await openViaShared(leaseID: leaseID, command: command, allowRecovery: true)
    }

    func closeLease(_ leaseID: UUID) async {
        guard let record = leaseRecords.removeValue(forKey: leaseID) else { return }
        if let owned = record.ownedConnection {
            await owned.close()
        }
        // Shared mode: release only — the shared carrier survives.
    }

    // MARK: Shared era

    /// Establishes (or joins) the single shared connection. Concurrent
    /// callers dedupe onto ONE in-flight dial: the first caller runs it
    /// and resumes the parked waiters with the same carrier (or the same
    /// failure).
    private func establishShared() async throws -> any SSHExecCapableConnection {
        if let shared = sharedConnection { return shared }
        guard !establishing else {
            return try await withCheckedThrowingContinuation { continuation in
                establishWaiters.append(continuation)
            }
        }
        guard !closed, !stickyDedicated else {
            throw TransportError.channelDenied
        }
        establishing = true
        let connection: any SSHExecCapableConnection
        do {
            connection = try await dial()
        } catch {
            establishing = false
            resumeWaiters(throwing: error)
            throw error
        }
        // The era may have flipped (pool close, or another lease's
        // denial went sticky) while the dial was in flight — never
        // install, never leak the fresh carrier.
        if closed || stickyDedicated {
            establishing = false
            resumeWaiters(throwing: TransportError.channelDenied)
            await connection.close()
            throw TransportError.channelDenied
        }
        sharedConnection = connection
        establishing = false
        resumeWaiters(returning: connection)
        return connection
    }

    /// Shared-era open with both fallbacks. `allowRecovery` bounds the
    /// lossy-link recovery to ONE redial+retry per open call.
    private func openViaShared(
        leaseID: UUID,
        command: String,
        allowRecovery: Bool
    ) async throws -> SSHExecSession {
        let shared: any SSHExecCapableConnection
        do {
            shared = try await establishShared()
        } catch {
            // The era flipped while joining the establish — ride the
            // dedicated path instead of failing the open.
            if stickyDedicated {
                return try await openViaDedicated(leaseID: leaseID, command: command)
            }
            throw error
        }
        do {
            return try await shared.openExecChannel(command: command)
        } catch {
            // No cast: the do-block throws only TransportError, so the
            // catch binds it typed (a catch-as pattern here would trip
            // the swift-frontend 6.4 SILGen assertion).
            if error == .channelDenied {
                // Budget-gateway denial: retire the shared carrier, go
                // sticky, and hand this lease its own dedicated carrier.
                stickyDedicated = true
                await retireShared()
                return try await openViaDedicated(leaseID: leaseID, command: command)
            }
            guard allowRecovery else { throw error }
            // Stale/dead shared carrier: one redial + one retry, then
            // propagate.
            await retireShared()
            return try await openViaShared(leaseID: leaseID, command: command, allowRecovery: false)
        }
    }

    /// Drops and closes the current shared carrier (if any). Safe to
    /// call redundantly — carrier `close()` is idempotent by the existing
    /// transport contract, and the nil-first drop means only the path
    /// that observes the carrier closes it.
    private func retireShared() async {
        let shared = sharedConnection
        sharedConnection = nil
        await shared?.close()
    }

    // MARK: Dedicated era

    /// Sticky-era lease(): dial a dedicated connection up front (the
    /// Coder-era per-consumer establish shape).
    private func leaseDedicated() async throws -> Lease {
        let dedicated = try await dial()
        let leaseID = UUID()
        leaseRecords[leaseID] = LeaseRecord(ownedConnection: dedicated)
        return Lease(pool: self, leaseID: leaseID)
    }

    /// Dials a dedicated connection the lease owns, then opens on it.
    private func openViaDedicated(leaseID: UUID, command: String) async throws -> SSHExecSession {
        let dedicated = try await dial()
        // The lease may have been closed while the dial was in flight —
        // never leak the fresh carrier.
        guard leaseRecords[leaseID] != nil else {
            await dedicated.close()
            throw TransportError.channelDenied
        }
        leaseRecords[leaseID]?.ownedConnection = dedicated
        return try await dedicated.openExecChannel(command: command)
    }

    // MARK: Establish dedupe

    private func resumeWaiters(returning connection: any SSHExecCapableConnection) {
        let waiters = establishWaiters
        establishWaiters = []
        for waiter in waiters {
            waiter.resume(returning: connection)
        }
    }

    private func resumeWaiters(throwing error: any Error) {
        let waiters = establishWaiters
        establishWaiters = []
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}
