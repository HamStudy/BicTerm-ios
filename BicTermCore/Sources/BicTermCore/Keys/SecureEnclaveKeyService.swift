import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

public final class SecureEnclaveKeyService: @unchecked Sendable {
    public let keychainService: String
    private let gate: BiometricEvaluationGate

    public init(
        keychainService: String = "com.bicterm.keys.secure-enclave",
        gate: BiometricEvaluationGate = .shared
    ) {
        self.keychainService = keychainService
        self.gate = gate
    }

    public func generate(label: String, requiresBiometry: Bool) async throws -> KeyMetadata {
        guard SecureEnclave.isAvailable else { throw KeyRepositoryError.invalidStoredKey }
        var accessError: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = requiresBiometry
            ? [.privateKeyUsage, .biometryCurrentSet]
            : [.privateKeyUsage]
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &accessError
        ) else {
            throw KeyRepositoryError.invalidStoredKey
        }

        let context = LAContext()
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            accessControl: access,
            authenticationContext: context
        )
        let reference = UUID().uuidString
        let publicBlob = SSHWireFormat.ecdsaP256PublicKeyBlob(
            x963PublicKey: key.publicKey.x963Representation
        )
        let metadata = KeyMetadata(
            reference: reference,
            label: label,
            algorithm: .ecdsaP256,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: publicBlob),
            publicKeyBlob: publicBlob,
            requiresBiometry: requiresBiometry,
            enabledByDefault: true
        )
        try KeychainMetadataStore.add(
            service: keychainService,
            metadata: metadata,
            secret: key.dataRepresentation,
            requiresBiometry: false
        )
        return metadata
    }

    public func setEnabled(_ enabled: Bool, reference: String) throws {
        try KeychainMetadataStore.setEnabled(service: keychainService, reference: reference, enabled: enabled)
    }

    public func sign(data: Data, with reference: String, reason: String) async throws -> KeySignature {
        let metadata = try KeychainMetadataStore.metadata(service: keychainService, reference: reference)
        guard metadata.requiresBiometry else {
            BiometricAccessLog.log.notice(
                "agent-sign secure-enclave load begin ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) biometry=false reason=\"\(reason, privacy: .public)\""
            )
            let key = try loadKeyAndContext(reference: reference, reason: reason).key
            let signature = try key.signature(for: data)
            return KeySignature(algorithm: .ecdsaP256, rawRepresentation: signature.rawRepresentation)
        }
        BiometricAccessLog.log.notice(
            "agent-sign secure-enclave load begin ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) biometry=true reason=\"\(reason, privacy: .public)\""
        )
        // The LAContext evaluation happens at signature(for:) time, not at
        // key construction (the initializer only retains the context), so
        // load and sign must both sit inside the gate.
        return try await gate.enqueue {
            let key = try self.loadKeyAndContext(reference: reference, reason: reason).key
            let signature = try key.signature(for: data)
            return KeySignature(algorithm: .ecdsaP256, rawRepresentation: signature.rawRepresentation)
        }
    }

    public func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) async throws -> NIOSSHPrivateKey {
        let metadata = try KeychainMetadataStore.metadata(service: keychainService, reference: reference)
        let requiresBiometry = metadata.requiresBiometry
        BiometricAccessLog.log.notice(
            "ssh-auth secure-enclave load begin ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) biometry=\(requiresBiometry) scoped=\(biometricContext != nil) reason=\"\(reason, privacy: .public)\""
        )
        guard requiresBiometry else {
            return NIOSSHPrivateKey(
                secureEnclaveP256Key: try loadKeyAndContext(
                    reference: reference, reason: reason, biometricContext: biometricContext
                ).key
            )
        }
        // This key's evaluation site is NIOSSH's handshake sign on the event
        // loop, which the gate cannot cover. Evaluate the context here, under
        // the gate, so the later NIOSSH signature consumes an
        // already-authenticated context instead of evaluating a second time
        // outside the gate. A scoped resolution evaluates the connect
        // action's ONE shared context; an unscoped one evaluates its own
        // fresh context.
        let key = try await gate.enqueue {
            let loaded = try self.loadKeyAndContext(
                reference: reference, reason: reason, biometricContext: biometricContext
            )
            if let biometricContext {
                try await biometricContext.authorize(reason: reason)
            } else {
                BiometricAccessLog.log.notice(
                    "secure-enclave policy evaluation begin ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) reason=\"\(reason, privacy: .public)\""
                )
                do {
                    try await loaded.context.evaluatePolicy(
                        .deviceOwnerAuthenticationWithBiometrics,
                        localizedReason: reason
                    )
                } catch {
                    BiometricAccessLog.log.error(
                        "secure-enclave policy evaluation failed ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) error=\(String(reflecting: error), privacy: .public)"
                    )
                    throw error
                }
                BiometricAccessLog.log.notice(
                    "secure-enclave policy evaluation ok ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public)"
                )
            }
            return loaded.key
        }
        return NIOSSHPrivateKey(secureEnclaveP256Key: key)
    }

    public func opaqueRepresentationForTesting(_ reference: String) async throws -> Data {
        try storedRepresentation(reference: reference)
    }

    /// The initializer retains the LAContext without evaluating it; the
    /// evaluation happens at the first `signature(for:)`, which is why
    /// callers that gate the evaluation need the context handle back.
    /// A scoped load hands the connect action's shared context to the
    /// key, so the handshake signature consumes the action's ONE
    /// evaluation instead of a fresh one.
    private func loadKeyAndContext(
        reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) throws -> (key: SecureEnclave.P256.Signing.PrivateKey, context: LAContext) {
        let context: LAContext = biometricContext?.context ?? LAContext()
        context.localizedReason = reason
        BiometricAccessLog.log.notice(
            "secure-enclave key materialized ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) scoped=\(biometricContext != nil)"
        )
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: storedRepresentation(reference: reference, biometricContext: biometricContext),
            authenticationContext: context
        )
        return (key, context)
    }

    private func storedRepresentation(
        reference: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) throws -> Data {
        var query = KeychainMetadataStore.baseQuery(service: keychainService, reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let biometricContext {
            query[kSecUseAuthenticationContext as String] = biometricContext.context
        }
        BiometricAccessLog.log.notice(
            "secure-enclave stored-representation read ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) scoped=\(biometricContext != nil)"
        )
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainMetadataStore.error(status)
        }
        return data
    }
}
