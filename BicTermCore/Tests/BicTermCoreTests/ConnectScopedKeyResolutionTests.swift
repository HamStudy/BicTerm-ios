import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

/// Connect-scoped key-resolution semantics (promoted from the herdr
/// path's private KeyResolutionCache): one underlying resolution per
/// key reference per connect scope, concurrent first-reads coalesced
/// onto that single read, invalidation drops resolved keys, an
/// in-flight resolution that outlives invalidation must not repopulate
/// the cache, and throwing resolutions are never cached.
final class ConnectScopedKeyResolutionTests: XCTestCase {
    /// Concurrent dedupe: N parallel resolutions of one reference
    /// coalesce onto exactly ONE underlying call (the property that
    /// turns N per-machine biometric evaluations into one).
    func testConcurrentResolutionsCoalesceOntoOneUnderlyingCall() async throws {
        let underlying = GatedCountingKeyProvider(gate: true)
        let wrapped = ConnectScopedKeyResolution().wrapping(underlying)
        let keys = await withTaskGroup(of: NIOSSHPrivateKey?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
                }
            }
            // The single coalesced underlying call parks at the gate;
            // release it once it is recorded.
            await underlying.waitForRecordedCalls(1)
            await underlying.releaseParkedCalls()
            var collected: [NIOSSHPrivateKey?] = []
            for await key in group { collected.append(key) }
            return collected
        }
        XCTAssertEqual(keys.count, 8)
        XCTAssertTrue(keys.allSatisfy { $0 != nil })
        let references = await underlying.references
        XCTAssertEqual(references.count, 1)
    }

    /// Resolved reuse: sequential resolutions of one reference hit the
    /// underlying provider once and hand every caller the SAME key.
    func testResolvedKeyIsReusedForSequentialCalls() async throws {
        let underlying = GatedCountingKeyProvider()
        let wrapped = ConnectScopedKeyResolution().wrapping(underlying)
        let first = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        let second = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        XCTAssertEqual(
            String(openSSHPublicKey: first.publicKey),
            String(openSSHPublicKey: second.publicKey)
        )
        let references = await underlying.references
        XCTAssertEqual(references.count, 1)
    }

    /// Invalidation clears: after invalidate(), the next resolution of
    /// a previously resolved reference goes back to the underlying
    /// provider.
    func testInvalidateDropsResolvedKeys() async throws {
        let underlying = GatedCountingKeyProvider()
        let cache = ConnectScopedKeyResolution()
        let wrapped = cache.wrapping(underlying)
        _ = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        await cache.invalidate()
        _ = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        let references = await underlying.references
        XCTAssertEqual(references.count, 2)
    }

    /// Epoch guard: a resolution still in flight when invalidate() lands
    /// must not repopulate the cache when it completes — its awaiter
    /// still gets the key, but the next resolution hits the underlying
    /// provider again.
    func testInFlightResolutionDoesNotRepopulateAfterInvalidation() async throws {
        let underlying = GatedCountingKeyProvider(gate: true)
        let cache = ConnectScopedKeyResolution()
        let wrapped = cache.wrapping(underlying)
        let inFlight = Task {
            try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        }
        // Deterministic ordering: the resolution is truly in flight
        // (recorded and parked at the gate) before invalidation lands.
        await underlying.waitForRecordedCalls(1)
        await cache.invalidate()
        await underlying.releaseParkedCalls()
        // The awaiter still receives its key — invalidation suppresses
        // caching, it does not cancel or fail the running resolution.
        _ = try await inFlight.value
        // The completed resolution must NOT have repopulated the cache.
        _ = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        let references = await underlying.references
        XCTAssertEqual(references.count, 2)
    }

    /// Failures are never cached: an underlying resolution that throws
    /// leaves nothing behind, so a retry reaches the underlying
    /// provider again and sees its success.
    func testThrowingResolutionIsNotCached() async throws {
        let underlying = GatedCountingKeyProvider()
        await underlying.queue(error: StubKeyError())
        let wrapped = ConnectScopedKeyResolution().wrapping(underlying)
        do {
            _ = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
            XCTFail("expected the first resolution to throw")
        } catch is StubKeyError {
            // expected
        }
        let retried = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        XCTAssertNotNil(retried)
        let references = await underlying.references
        XCTAssertEqual(references.count, 2)
    }

    /// ONE biometric context per scope: resolutions of DIFFERENT
    /// references receive the SAME shared context — the property that
    /// collapses N per-key Face ID evaluations of one connect action
    /// into ONE.
    func testScopeThreadsOneBiometricContextAcrossReferences() async throws {
        let underlying = ContextRecordingKeyProvider()
        let wrapped = ConnectScopedKeyResolution().wrapping(underlying)
        _ = try await wrapped.authenticationPrivateKey(with: "ref-a", reason: "testing")
        _ = try await wrapped.authenticationPrivateKey(with: "ref-b", reason: "testing")
        let identities = await underlying.contextIdentities
        XCTAssertEqual(identities.count, 2)
        XCTAssertNotNil(identities[0], "a scoped resolution must receive a shared context")
        XCTAssertEqual(identities[0], identities[1], "one connect scope = ONE shared biometric context")
    }

    /// Invalidation drops the shared biometric context with the resolved
    /// keys: a post-invalidation resolution gets a FRESH context (a
    /// superseded scope's authentication never carries into it).
    func testInvalidationDropsTheBiometricContext() async throws {
        let underlying = ContextRecordingKeyProvider()
        let cache = ConnectScopedKeyResolution()
        let wrapped = cache.wrapping(underlying)
        _ = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        await cache.invalidate()
        _ = try await wrapped.authenticationPrivateKey(with: "ref", reason: "testing")
        let identities = await underlying.contextIdentities
        XCTAssertEqual(identities.count, 2)
        XCTAssertNotEqual(identities[0], identities[1], "invalidation must drop the scope's biometric context")
    }
}

// MARK: - Test doubles

private struct StubKeyError: Error {}

/// Actor-confined counting/recording stub provider: every underlying
/// call is recorded by reference, a queued error is thrown before the
/// gate, and gated calls park on a continuation until the test releases
/// them (the deterministic stand-in for a slow biometric evaluation).
private actor GatedCountingKeyProvider: SSHAuthenticationKeyProvider {
    private(set) var references: [String] = []
    private var queuedErrors: [any Error] = []
    private var parked: [CheckedContinuation<NIOSSHPrivateKey, any Error>] = []
    private var gate: Bool

    init(gate: Bool = false) {
        self.gate = gate
    }

    func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) async throws -> NIOSSHPrivateKey {
        references.append(reference)
        if !queuedErrors.isEmpty {
            throw queuedErrors.removeFirst()
        }
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        guard gate else { return key }
        return try await withCheckedThrowingContinuation { continuation in
            parked.append(continuation)
        }
    }

    // MARK: Test controls

    func queue(error: any Error) {
        queuedErrors.append(error)
    }

    /// Suspends until at least `count` underlying calls are recorded.
    /// Bounded (10 s of 10 ms polls) so a broken implementation fails
    /// the subsequent assertion instead of hanging the suite.
    func waitForRecordedCalls(_ count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while references.count < count && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Resumes every parked call and opens the gate so later calls
    /// return immediately (a release is the scope's last word — nothing
    /// parks again).
    func releaseParkedCalls() {
        gate = false
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        for continuation in parked {
            continuation.resume(returning: key)
        }
        parked.removeAll()
    }
}

/// Records the identity of the biometric context each resolution
/// received, proving the scope threads ONE context across resolutions.
private actor ContextRecordingKeyProvider: SSHAuthenticationKeyProvider {
    private(set) var contextIdentities: [ObjectIdentifier?] = []

    func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext?
    ) async throws -> NIOSSHPrivateKey {
        contextIdentities.append(biometricContext.map(ObjectIdentifier.init))
        return NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    }
}
