import NIOSSH

/// Coalesces authentication-key resolutions for one connect scope (a
/// herdr bring-up, a herd open): the first resolution for a key
/// reference goes to the underlying provider, concurrent resolutions of
/// the same reference await that one in-flight read, and later reads
/// return the resolved key. The resolved `NIOSSHPrivateKey` is an
/// opaque signing handle that already lives in memory for each
/// connection's lifetime; sharing one instance across this scope's
/// connections is the same exposure class, and it is what turns N
/// concurrent biometric evaluations (one per machine) into ONE.
///
/// Lifetime rule (connect intent): one instance belongs to exactly one
/// connect scope — create it where the scope begins (bring-up, herd
/// open) and let it deallocate when the scope ends.
/// ``invalidate()`` is the defense-in-depth seam for scopes that
/// outlive their transport state (teardown): it drops every resolved
/// key and bumps an internal epoch, so a resolution still in flight
/// when invalidation lands can never repopulate the cache when it
/// completes. Throwing resolutions are never cached.
public actor ConnectScopedKeyResolution {
    private var resolved: [String: NIOSSHPrivateKey] = [:]
    private var inFlight: [String: Task<NIOSSHPrivateKey, any Error>] = [:]
    private var epoch = 0

    public init() {}

    nonisolated public func wrapping(
        _ underlying: any SSHAuthenticationKeyProvider
    ) -> any SSHAuthenticationKeyProvider {
        CoalescedKeyProvider(cache: self, underlying: underlying)
    }

    /// Drops every resolved key and every in-flight join point, and
    /// bumps the epoch so resolutions that started before this call
    /// cannot repopulate the cache when they complete. In-flight
    /// resolutions are NOT cancelled — their awaiters still receive
    /// their result; only the caching is suppressed.
    public func invalidate() {
        resolved.removeAll()
        inFlight.removeAll()
        epoch += 1
    }

    func key(
        for reference: String,
        reason: String,
        underlying: any SSHAuthenticationKeyProvider
    ) async throws -> NIOSSHPrivateKey {
        if let key = resolved[reference] {
            return key
        }
        if let task = inFlight[reference] {
            return try await task.value
        }
        let resolutionEpoch = epoch
        let task = Task {
            try await underlying.authenticationPrivateKey(with: reference, reason: reason)
        }
        inFlight[reference] = task
        do {
            let key = try await task.value
            // Epoch guard: an invalidation since this resolution started
            // means its result belongs to a superseded scope — store
            // nothing and leave the (already-cleared) in-flight table
            // alone so a newer resolution's entry is never clobbered.
            if epoch == resolutionEpoch {
                resolved[reference] = key
                inFlight[reference] = nil
            }
            return key
        } catch {
            if epoch == resolutionEpoch {
                inFlight[reference] = nil
            }
            throw error
        }
    }
}

private struct CoalescedKeyProvider: SSHAuthenticationKeyProvider {
    let cache: ConnectScopedKeyResolution
    let underlying: any SSHAuthenticationKeyProvider

    func authenticationPrivateKey(
        with reference: String,
        reason: String
    ) async throws -> NIOSSHPrivateKey {
        try await cache.key(for: reference, reason: reason, underlying: underlying)
    }
}
