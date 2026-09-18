import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

public final class KeychainKeyRepository: @unchecked Sendable {
    public let keychainService: String
    private let parser: OpenSSHPrivateKeyParser
    private let gate: BiometricEvaluationGate

    public init(
        keychainService: String = "com.bicterm.keys.ed25519",
        parser: OpenSSHPrivateKeyParser = OpenSSHPrivateKeyParser(),
        gate: BiometricEvaluationGate = .shared
    ) {
        self.keychainService = keychainService
        self.parser = parser
        self.gate = gate
    }

    public func generateEd25519(label: String, requiresBiometry: Bool) async throws -> KeyMetadata {
        let key = Curve25519.Signing.PrivateKey()
        return try store(key: key, label: label, requiresBiometry: requiresBiometry)
    }

    public func importOpenSSHPrivateKey(
        _ data: Data,
        passphrase: Data? = nil,
        label: String,
        requiresBiometry: Bool
    ) async throws -> KeyMetadata {
        let parsed = try await parser.parse(data, passphrase: passphrase)
        return try store(key: parsed.privateKey, label: label, requiresBiometry: requiresBiometry)
    }

    public func list() async throws -> [KeyMetadata] {
        try KeychainMetadataStore.list(service: keychainService)
    }

    public func setEnabled(_ enabled: Bool, reference: String) throws {
        try KeychainMetadataStore.setEnabled(service: keychainService, reference: reference, enabled: enabled)
    }

    public func delete(reference: String) async throws {
        let status = SecItemDelete(KeychainMetadataStore.baseQuery(
            service: keychainService,
            reference: reference
        ) as CFDictionary)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeyRepositoryError.keyNotFound }
            throw KeyRepositoryError.keychain(status)
        }
    }

    public func sign(data: Data, with reference: String) async throws -> KeySignature {
        let metadata = try KeychainMetadataStore.metadata(
            service: keychainService,
            reference: reference
        )
        var rawKey = try await gatedPrivateKeyData(
            reference: reference,
            reason: metadata.requiresBiometry ? "Authenticate to use your SSH key" : nil
        )
        defer { rawKey.resetBytes(in: rawKey.startIndex..<rawKey.endIndex) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return KeySignature(algorithm: .ed25519, rawRepresentation: try key.signature(for: data))
    }

    public func authenticationPrivateKey(
        with reference: String,
        reason: String
    ) async throws -> NIOSSHPrivateKey {
        let metadata = try KeychainMetadataStore.metadata(
            service: keychainService,
            reference: reference
        )
        let rawKey = try await gatedPrivateKeyData(
            reference: reference,
            reason: metadata.requiresBiometry ? reason : nil
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    private func store(
        key: Curve25519.Signing.PrivateKey,
        label: String,
        requiresBiometry: Bool
    ) throws -> KeyMetadata {
        let reference = UUID().uuidString
        let publicBlob = SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: key.publicKey.rawRepresentation
        )
        let metadata = KeyMetadata(
            reference: reference,
            label: label,
            algorithm: .ed25519,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: publicBlob),
            publicKeyBlob: publicBlob,
            requiresBiometry: requiresBiometry,
            enabledByDefault: true
        )
        try KeychainMetadataStore.add(
            service: keychainService,
            metadata: metadata,
            secret: key.rawRepresentation,
            requiresBiometry: requiresBiometry
        )
        return metadata
    }

    /// `SecItemCopyMatching` on a biometry-protected item is where the
    /// LAContext evaluation happens, so that call — and only that call — is
    /// routed through the gate. A nil reason means the key is not
    /// biometry-protected and the read must not be serialized.
    private func gatedPrivateKeyData(reference: String, reason: String?) async throws -> Data {
        guard let reason else {
            return try privateKeyData(reference: reference, reason: nil)
        }
        return try await gate.enqueue {
            try self.privateKeyData(reference: reference, reason: reason)
        }
    }

    private func privateKeyData(reference: String, reason: String?) throws -> Data {
        var query = KeychainMetadataStore.baseQuery(service: keychainService, reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let reason {
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainMetadataStore.error(status)
        }
        return data
    }
}

enum KeychainMetadataStore {
    static func baseQuery(service: String, reference: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let reference { query[kSecAttrAccount as String] = reference }
        return query
    }

    static func add(
        service: String,
        metadata: KeyMetadata,
        secret: Data,
        requiresBiometry: Bool
    ) throws {
        var attributes = baseQuery(service: service, reference: metadata.reference)
        attributes[kSecAttrLabel as String] = metadata.label
        attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(metadata)
        attributes[kSecValueData as String] = secret

        if requiresBiometry {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .biometryCurrentSet,
                &accessError
            ) else {
                throw KeyRepositoryError.invalidStoredKey
            }
            attributes[kSecAttrAccessControl as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    static func metadata(service: String, reference: String) throws -> KeyMetadata {
        var query = baseQuery(service: service, reference: reference)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let encoded = attributes[kSecAttrGeneric as String] as? Data,
              let metadata = try? JSONDecoder().decode(KeyMetadata.self, from: encoded) else {
            throw status == errSecSuccess ? KeyRepositoryError.invalidStoredKey : error(status)
        }
        return metadata
    }

    static func setEnabled(service: String, reference: String, enabled: Bool) throws {
        let current = try metadata(service: service, reference: reference)
        let updated = KeyMetadata(
            reference: current.reference,
            label: current.label,
            algorithm: current.algorithm,
            fingerprint: current.fingerprint,
            publicKeyBlob: current.publicKeyBlob,
            requiresBiometry: current.requiresBiometry,
            enabledByDefault: enabled
        )
        let attributes = [kSecAttrGeneric as String: try JSONEncoder().encode(updated)]
        let status = SecItemUpdate(
            baseQuery(service: service, reference: reference) as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else { throw error(status) }
    }

    static func list(service: String) throws -> [KeyMetadata] {
        var query = baseQuery(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let attributes = item as? [[String: Any]] else {
            throw error(status)
        }
        return try attributes
            .map { attributes in
                guard let encoded = attributes[kSecAttrGeneric as String] as? Data else {
                    throw KeyRepositoryError.invalidStoredKey
                }
                return try JSONDecoder().decode(KeyMetadata.self, from: encoded)
            }
            .sorted { $0.reference < $1.reference }
    }

    static func error(_ status: OSStatus) -> KeyRepositoryError {
        switch status {
        case errSecItemNotFound:
            return .keyNotFound
        case errSecDuplicateItem:
            return .duplicateReference
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .authenticationFailed
        default:
            return .keychain(status)
        }
    }
}
