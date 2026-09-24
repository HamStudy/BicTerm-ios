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
        let secretStatus = SecItemDelete(KeychainMetadataStore.baseQuery(
            service: keychainService,
            reference: reference
        ) as CFDictionary)
        let metadataStatus = SecItemDelete(KeychainMetadataStore.baseQuery(
            service: KeychainMetadataStore.metadataService(keychainService),
            reference: reference
        ) as CFDictionary)
        if secretStatus == errSecSuccess || metadataStatus == errSecSuccess {
            return
        }
        if secretStatus == errSecItemNotFound, metadataStatus == errSecItemNotFound {
            throw KeyRepositoryError.keyNotFound
        }
        throw KeyRepositoryError.keychain(secretStatus == errSecItemNotFound ? metadataStatus : secretStatus)
    }

    public func sign(data: Data, with reference: String) async throws -> KeySignature {
        let metadata = try KeychainMetadataStore.metadata(
            service: keychainService,
            reference: reference
        )
        let requiresBiometry = metadata.requiresBiometry
        let reason = requiresBiometry ? "Authenticate to use your SSH key" : nil
        BiometricAccessLog.log.notice(
            "agent-sign keychain read begin ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) biometry=\(requiresBiometry) reason=\"\(reason ?? "none", privacy: .public)\""
        )
        var rawKey = try await gatedPrivateKeyData(
            reference: reference,
            reason: reason,
            biometricContext: nil
        )
        defer { rawKey.resetBytes(in: rawKey.startIndex..<rawKey.endIndex) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return KeySignature(algorithm: .ed25519, rawRepresentation: try key.signature(for: data))
    }

    public func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) async throws -> NIOSSHPrivateKey {
        let metadata = try KeychainMetadataStore.metadata(
            service: keychainService,
            reference: reference
        )
        let requiresBiometry = metadata.requiresBiometry
        BiometricAccessLog.log.notice(
            "ssh-auth keychain read begin ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) biometry=\(requiresBiometry) scoped=\(biometricContext != nil) reason=\"\(reason, privacy: .public)\""
        )
        let rawKey: Data
        do {
            rawKey = try await gatedPrivateKeyData(
                reference: reference,
                reason: requiresBiometry ? reason : nil,
                biometricContext: biometricContext
            )
        } catch {
            BiometricAccessLog.log.error(
                "ssh-auth keychain read failed ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        BiometricAccessLog.log.notice(
            "ssh-auth keychain read ok ref=\(BiometricAccessLog.referenceDigest(reference), privacy: .public)"
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
    /// biometry-protected and the read must not be serialized. A scoped
    /// read authorizes the connect action's shared context FIRST (one
    /// evaluation per connect action); the read then rides the
    /// authenticated context.
    private func gatedPrivateKeyData(
        reference: String,
        reason: String?,
        biometricContext: ConnectScopedBiometricContext?
    ) async throws -> Data {
        guard let reason else {
            return try privateKeyData(reference: reference, reason: nil, biometricContext: biometricContext)
        }
        return try await gate.enqueue {
            try await biometricContext?.authorize(reason: reason)
            return try self.privateKeyData(reference: reference, reason: reason, biometricContext: biometricContext)
        }
    }

    private func privateKeyData(
        reference: String,
        reason: String?,
        biometricContext: ConnectScopedBiometricContext?
    ) throws -> Data {
        var query = KeychainMetadataStore.baseQuery(service: keychainService, reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let reason {
            if let biometricContext {
                // Connect-scoped read: the context was authorized under
                // the gate, so the query reuses it instead of evaluating
                // a fresh LAContext.
                biometricContext.context.localizedReason = reason
                query[kSecUseAuthenticationContext as String] = biometricContext.context
            } else {
                let context = LAContext()
                context.localizedReason = reason
                query[kSecUseAuthenticationContext as String] = context
            }
        } else if let biometricContext {
            query[kSecUseAuthenticationContext as String] = biometricContext.context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainMetadataStore.error(status)
        }
        return data
    }
}

public enum KeychainMetadataStore {
    /// Metadata lives in its OWN item, in a sibling service with NO access
    /// control. The legacy layout stored the metadata JSON in
    /// `kSecAttrGeneric` of the secret's item, which carries the biometric
    /// access control — and attribute-only reads (key listings,
    /// `requiresBiometry` checks) of an access-controlled item evaluate
    /// the ACL on device (device evidence: three silent
    /// `evaluateAccessControl` evaluations per connect, one per attribute
    /// read of the combined item). The secret keeps its access control;
    /// the metadata is not secret and must stay readable without an
    /// evaluation.
    public static func metadataService(_ service: String) -> String { "\(service).metadata" }

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
        var secretAttributes = baseQuery(service: service, reference: metadata.reference)
        secretAttributes[kSecValueData as String] = secret

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
            secretAttributes[kSecAttrAccessControl as String] = access
        } else {
            secretAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(secretAttributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
        // The metadata item is written second; a failure here rolls the
        // secret item back so no orphan secret outlives the failed add.
        do {
            try addMetadataItem(service: service, metadata: metadata)
        } catch {
            SecItemDelete(baseQuery(service: service, reference: metadata.reference) as CFDictionary)
            throw error
        }
    }

    /// Writes (or replaces) the metadata-only item. Never carries an
    /// access control; attribute reads of this item must not evaluate.
    static func addMetadataItem(service: String, metadata: KeyMetadata) throws {
        var attributes = baseQuery(service: metadataService(service), reference: metadata.reference)
        attributes[kSecAttrLabel as String] = metadata.label
        attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(metadata)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = Data()
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    /// Marks, in the (no-access-control) metadata service, that the legacy
    /// layout scan has completed for a service: every legacy item found
    /// has been migrated. Once set, neither `list(_:)` nor
    /// `metadata(_:reference:)` reads the secret service's attributes
    /// again — such reads evaluate the secret's access control on device
    /// and must happen at most once.
    private static let legacyScanMarkerAccount = "bicterm.legacy-scan-complete"

    private static func legacyScanCompleted(service: String) -> Bool {
        var query = baseQuery(
            service: metadataService(service),
            reference: legacyScanMarkerAccount
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    private static func markLegacyScanComplete(service: String) {
        let status = SecItemAdd(
            baseQuery(
                service: metadataService(service),
                reference: legacyScanMarkerAccount
            ) as CFDictionary,
            nil
        )
        // A previous scan already wrote it; a keychain failure leaves the
        // scan unmarked, so the next scan retries (one more evaluation).
        if status == errSecDuplicateItem { return }
    }

    static func metadata(service: String, reference: String) throws -> KeyMetadata {
        if let metadata = try readMetadataItem(service: service, reference: reference) {
            return metadata
        }
        guard !legacyScanCompleted(service: service) else {
            throw KeyRepositoryError.keyNotFound
        }
        // Legacy layout: the metadata JSON lives in `kSecAttrGeneric` of
        // the secret's item, under the secret's access control, so this
        // attribute read may trigger one (last) biometric evaluation.
        // Migrate the metadata to its own item so later reads are
        // prompt-free. The legacy item itself is left untouched — updates
        // to an access-controlled item evaluate too.
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
        do {
            try addMetadataItem(service: service, metadata: metadata)
        } catch KeyRepositoryError.duplicateReference {
            // A concurrent resolution migrated the same legacy key first.
        }
        return metadata
    }

    private static func readMetadataItem(
        service: String,
        reference: String
    ) throws -> KeyMetadata? {
        var query = baseQuery(service: metadataService(service), reference: reference)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
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
            baseQuery(service: metadataService(service), reference: reference) as CFDictionary,
            attributes as CFDictionary
        )
        // The metadata item can be missing when an earlier migration best
        // effort failed; (re)create it rather than evaluating the legacy
        // item's access control via a misplaced update.
        if status == errSecItemNotFound {
            try addMetadataItem(service: service, metadata: updated)
            return
        }
        guard status == errSecSuccess else { throw error(status) }
    }

    /// All key metadata of a service, from the prompt-free metadata items.
    /// Owns the one-time legacy layout scan (see the marker's docs); the
    /// app layer's key listing delegates here so migration happens in
    /// exactly one place.
    public static func list(service: String) throws -> [KeyMetadata] {
        var result = try readMetadataList(service: service)
        if !legacyScanCompleted(service: service) {
            // One-time legacy layout scan: metadata that still lives on
            // the secret's item surfaces here (reading it may evaluate
            // once per legacy key) and is migrated on sight. The marker is
            // written only when every migration succeeded, so a broken
            // keychain retries the scan instead of silently hiding keys.
            let have = Set(result.map(\.reference))
            let legacy = try readLegacyList(service: service)
                .filter { !have.contains($0.reference) }
            var migratedAll = true
            for metadata in legacy {
                do {
                    try addMetadataItem(service: service, metadata: metadata)
                } catch KeyRepositoryError.duplicateReference {
                    // A concurrent resolution migrated it first.
                } catch {
                    migratedAll = false
                }
            }
            result.append(contentsOf: legacy)
            if migratedAll {
                markLegacyScanComplete(service: service)
            }
        }
        var seen = Set<String>()
        return result
            .filter { seen.insert($0.reference).inserted }
            .sorted { $0.reference < $1.reference }
    }

    private static func readMetadataList(service: String) throws -> [KeyMetadata] {
        var query = baseQuery(service: metadataService(service))
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let attributes = item as? [[String: Any]] else {
            throw error(status)
        }
        return try attributes
            // The scan marker shares this service (see its docs); it is
            // not a key's metadata item.
            .filter { ($0[kSecAttrAccount as String] as? String) != legacyScanMarkerAccount }
            .map { attributes in
                guard let encoded = attributes[kSecAttrGeneric as String] as? Data else {
                    throw KeyRepositoryError.invalidStoredKey
                }
                return try JSONDecoder().decode(KeyMetadata.self, from: encoded)
            }
    }

    private static func readLegacyList(service: String) throws -> [KeyMetadata] {
        var query = baseQuery(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let attributes = item as? [[String: Any]] else {
            throw error(status)
        }
        return try attributes.compactMap { attributes in
            // Items whose metadata has already been migrated keep only
            // the secret: no kSecAttrGeneric, nothing to do for them.
            guard let encoded = attributes[kSecAttrGeneric as String] as? Data else {
                return nil
            }
            return try JSONDecoder().decode(KeyMetadata.self, from: encoded)
        }
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
