import CryptoKit
import Security
import XCTest
@testable import BicTermCore

/// Service-level gating: biometry-protected key operations must route
/// through the ``BiometricEvaluationGate``; non-biometric operations must
/// not be serialized.
///
/// Biometry is faked at the metadata level: items are stored WITHOUT an
/// access control (so reads never prompt and need no hardware), while
/// their metadata claims `requiresBiometry` — exactly the flag the
/// services consult to decide gating.
final class BiometricKeyGatingTests: XCTestCase {
    private var services: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let service = "com.bicterm.tests.gate-preflight.\(UUID().uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "preflight",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data("preflight".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("SPM simulator test bundle has no Data Protection Keychain entitlement")
        }
        guard status == errSecSuccess else {
            throw KeyRepositoryError.keychain(status)
        }
        SecItemDelete(query as CFDictionary)
    }

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

    func testBiometricKeychainSignWaitsForTheGate() async throws {
        let gate = BiometricEvaluationGate()
        let repository = makeRepository(gate: gate)
        let metadata = try plantFakeBiometricEd25519Key(in: repository)
        let hold = GateHold()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        let message = Data("gated-biometric-sign".utf8)
        let signTask = Task {
            try await repository.sign(data: message, with: metadata.reference)
        }
        let biometricReadQueued = await waitUntil { await gate.pendingWaiterCountForTesting >= 1 }
        XCTAssertTrue(biometricReadQueued, "biometric keychain read must enter the gate")

        await hold.signal()
        _ = try? await holder.value

        let signature = try await signTask.value
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: SSHWireFormat.ed25519RawPublicKey(from: metadata.publicKeyBlob)
        )
        XCTAssertTrue(publicKey.isValidSignature(signature.rawRepresentation, for: message))
    }

    func testNonBiometricKeychainAuthenticationKeyBypassesTheGate() async throws {
        let gate = BiometricEvaluationGate()
        let repository = makeRepository(gate: gate)
        let metadata = try await repository.generateEd25519(
            label: "Ungated ed25519",
            requiresBiometry: false
        )
        let hold = GateHold()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        let completion = CompletionFlag()
        let loadTask = Task {
            defer { completion.markCompleted() }
            return try await repository.authenticationPrivateKey(
                with: metadata.reference,
                reason: "Authenticate test connection"
            )
        }
        let ungatedReadCompleted = await waitUntil { completion.isCompleted }
        XCTAssertTrue(ungatedReadCompleted, "non-biometric keychain read must not wait for the gate")
        let queuedAfterUngatedRead = await gate.pendingWaiterCountForTesting
        XCTAssertEqual(queuedAfterUngatedRead, 0)

        await hold.signal()
        _ = try? await holder.value
        _ = try await loadTask.value
    }

    func testBiometricSecureEnclaveAuthenticationKeyWaitsForTheGate() async throws {
        let gate = BiometricEvaluationGate()
        let service = makeSecureEnclaveService(gate: gate)
        let metadata = try plantSecureEnclaveMetadata(requiresBiometry: true, in: service)
        let hold = GateHold()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        let loadTask = Task {
            try await service.authenticationPrivateKey(with: metadata.reference, reason: "test")
        }
        let enclaveLoadQueued = await waitUntil { await gate.pendingWaiterCountForTesting >= 1 }
        XCTAssertTrue(enclaveLoadQueued, "biometric Secure Enclave load must enter the gate")

        await hold.signal()
        _ = try? await holder.value

        // The load runs once granted and fails (no Secure Enclave in the
        // simulator and a deliberately bogus blob) — but only after release.
        do {
            _ = try await loadTask.value
            XCTFail("expected the gated load to fail on the bogus blob")
        } catch {}
    }

    func testNonBiometricSecureEnclaveAuthenticationKeyBypassesTheGate() async throws {
        let gate = BiometricEvaluationGate()
        let service = makeSecureEnclaveService(gate: gate)
        let metadata = try plantSecureEnclaveMetadata(requiresBiometry: false, in: service)
        let hold = GateHold()

        let holder = Task {
            try await gate.enqueue { await hold.wait() }
        }
        let holderAcquired = await waitUntil { await hold.held }
        XCTAssertTrue(holderAcquired, "holder never acquired the gate")

        let completion = CompletionFlag()
        let loadTask = Task {
            defer { completion.markCompleted() }
            return try await service.authenticationPrivateKey(with: metadata.reference, reason: "test")
        }
        let ungatedLoadCompleted = await waitUntil { completion.isCompleted }
        XCTAssertTrue(ungatedLoadCompleted, "non-biometric Secure Enclave load must not wait for the gate")
        let queuedAfterUngatedLoad = await gate.pendingWaiterCountForTesting
        XCTAssertEqual(queuedAfterUngatedLoad, 0)

        await hold.signal()
        _ = try? await holder.value
        _ = try? await loadTask.value
    }

    /// Stores a real ed25519 key whose METADATA claims biometry while the
    /// item itself carries no access control: the services take the gated
    /// path, but the Keychain read succeeds without any biometric prompt.
    private func plantFakeBiometricEd25519Key(
        in repository: KeychainKeyRepository
    ) throws -> KeyMetadata {
        let key = Curve25519.Signing.PrivateKey()
        let publicBlob = SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: key.publicKey.rawRepresentation
        )
        let metadata = KeyMetadata(
            reference: UUID().uuidString,
            label: "Fake biometric ed25519",
            algorithm: .ed25519,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: publicBlob),
            publicKeyBlob: publicBlob,
            requiresBiometry: true
        )
        try KeychainMetadataStore.add(
            service: repository.keychainService,
            metadata: metadata,
            secret: key.rawRepresentation,
            requiresBiometry: false
        )
        return metadata
    }

    /// Plants Secure Enclave metadata with a bogus blob: the load fails once
    /// the turn is granted (no Secure Enclave hardware in the simulator),
    /// which is exactly what lets the test observe the gating.
    private func plantSecureEnclaveMetadata(
        requiresBiometry: Bool,
        in service: SecureEnclaveKeyService
    ) throws -> KeyMetadata {
        let metadata = KeyMetadata(
            reference: UUID().uuidString,
            label: "SE \(requiresBiometry ? "biometric" : "plain")",
            algorithm: .ecdsaP256,
            fingerprint: "SHA256:fixture",
            publicKeyBlob: Data([1, 2, 3]),
            requiresBiometry: requiresBiometry
        )
        try KeychainMetadataStore.add(
            service: service.keychainService,
            metadata: metadata,
            secret: Data("bogus-secure-enclave-blob".utf8),
            requiresBiometry: false
        )
        return metadata
    }

    private func makeRepository(gate: BiometricEvaluationGate) -> KeychainKeyRepository {
        let service = "com.bicterm.tests.gate.\(UUID().uuidString)"
        services.append(service)
        return KeychainKeyRepository(keychainService: service, gate: gate)
    }

    private func makeSecureEnclaveService(gate: BiometricEvaluationGate) -> SecureEnclaveKeyService {
        let service = "com.bicterm.tests.gate-se.\(UUID().uuidString)"
        services.append(service)
        return SecureEnclaveKeyService(keychainService: service, gate: gate)
    }
}
