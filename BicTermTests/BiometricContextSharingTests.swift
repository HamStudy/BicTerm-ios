import BicTermCore
import CryptoKit
import Security
import XCTest

/// Service-level proof of ONE biometric evaluation per connect action:
/// the key services authorize the connect scope's shared context before
/// the first biometry-protected read, later resolutions of the SAME scope
/// reuse it (no second evaluation), and the scoped read still serializes
/// through the ``BiometricEvaluationGate``.
///
/// App-hosted (not the SPM core suite) because the reads need the Data
/// Protection Keychain entitlement — the SPM simulator bundle skips every
/// Keychain-touching test (known harness limitation, see
/// `.omo/notepads/ssh-key-pool/issues.md` T2-closeout).
///
/// Biometry is faked at the metadata level (the ``BiometricKeyGatingTests``
/// idiom): items are stored WITHOUT an access control so reads never
/// prompt and need no hardware, while their metadata claims
/// `requiresBiometry` — exactly the flag the services consult. The
/// context's evaluation is the injected counting stand-in.
final class BiometricContextSharingTests: XCTestCase {
    private var services: [String] = []

    override func tearDown() {
        for service in services {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
        services.removeAll()
        super.tearDown()
    }

    /// The headline property: a connect action that resolves TWO
    /// different biometry-protected keys performs ONE biometric
    /// evaluation — the first resolution authorizes the shared context,
    /// the second reuses it.
    func testOneEvaluationPerScopeAcrossKeychainResolutions() async throws {
        let repository = makeRepository()
        let first = try plantFakeBiometricEd25519Key(in: repository, label: "first")
        let second = try plantFakeBiometricEd25519Key(in: repository, label: "second")
        let counter = EvaluationCounter()
        let context = ConnectScopedBiometricContext(evaluate: { _, _ in counter.record() })

        _ = try await repository.authenticationPrivateKey(
            with: first.reference, reason: "Authenticate to host", biometricContext: context
        )
        _ = try await repository.authenticationPrivateKey(
            with: second.reference, reason: "Authenticate to host", biometricContext: context
        )

        XCTAssertEqual(
            counter.value, 1,
            "two resolutions of one connect action must share ONE biometric evaluation"
        )
    }

    /// A scoped resolution of a NON-biometric key never evaluates: no
    /// authorize, no gate.
    func testScopedNonBiometricResolutionNeverEvaluates() async throws {
        let repository = makeRepository()
        let metadata = try await repository.generateEd25519(
            label: "Ungated scoped", requiresBiometry: false
        )
        let counter = EvaluationCounter()
        let context = ConnectScopedBiometricContext(evaluate: { _, _ in counter.record() })

        _ = try await repository.authenticationPrivateKey(
            with: metadata.reference, reason: "Authenticate to host", biometricContext: context
        )

        XCTAssertEqual(counter.value, 0, "a non-biometric key must not trigger an evaluation")
    }

    /// The scoped biometric read still serializes through the gate: the
    /// authorize + read sit inside one gated operation, so an evaluation
    /// in flight elsewhere in the process is waited for, not failed.
    /// Observed through public API only — the read must not complete
    /// while another operation holds the gate turn.
    func testScopedBiometricResolutionStillWaitsForTheGate() async throws {
        let gate = BiometricEvaluationGate()
        let repository = makeRepository(gate: gate)
        let metadata = try plantFakeBiometricEd25519Key(in: repository, label: "gated scoped")
        let context = ConnectScopedBiometricContext(evaluate: { _, _ in })
        let hold = GateHold()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        let completion = CompletionFlag()
        let loadTask = Task {
            defer { completion.markCompleted() }
            _ = try await repository.authenticationPrivateKey(
                with: metadata.reference, reason: "Authenticate to host", biometricContext: context
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(
            completion.isCompleted,
            "the scoped biometric read must not run while the gate turn is held elsewhere"
        )

        await hold.signal()
        _ = try? await holder.value
        _ = try await loadTask.value
    }

    // MARK: - Fixtures

    /// Stores a real ed25519 key whose METADATA claims biometry while the
    /// item itself carries no access control: the service takes the
    /// gated, context-authorizing path, but the Keychain read succeeds
    /// without any biometric prompt.
    private func plantFakeBiometricEd25519Key(
        in repository: KeychainKeyRepository,
        label: String
    ) throws -> KeyMetadata {
        let key = Curve25519.Signing.PrivateKey()
        let publicBlob = SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: key.publicKey.rawRepresentation
        )
        let metadata = KeyMetadata(
            reference: UUID().uuidString,
            label: label,
            algorithm: .ed25519,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: publicBlob),
            publicKeyBlob: publicBlob,
            requiresBiometry: true
        )
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: repository.keychainService,
            kSecAttrAccount as String: metadata.reference,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrLabel as String: metadata.label,
            kSecAttrGeneric as String: try JSONEncoder().encode(metadata),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
        return metadata
    }

    private func makeRepository(gate: BiometricEvaluationGate = BiometricEvaluationGate()) -> KeychainKeyRepository {
        let service = "com.bicterm.tests.context.\(UUID().uuidString)"
        services.append(service)
        return KeychainKeyRepository(keychainService: service, gate: gate)
    }
}

// MARK: - Test doubles

/// Lock-confined evaluation counter (the evaluation closure is @Sendable).
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Holds a `BiometricEvaluationGate` turn until the test signals, with an
/// observable `held` flag for deterministic sequencing.
private actor GateHold {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var held = false

    func wait() async {
        held = true
        await withCheckedContinuation { continuation in
            release = continuation
        }
    }

    func signal() {
        release?.resume()
        release = nil
    }
}

/// Records whether a task finished, so a test can assert completion (or
/// non-completion) while a gate turn is still held elsewhere.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

/// Polls `condition` until it returns true or the timeout elapses.
@discardableResult
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}
