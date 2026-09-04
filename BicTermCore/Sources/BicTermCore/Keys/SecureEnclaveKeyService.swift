import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

public final class SecureEnclaveKeyService: @unchecked Sendable {
    public let keychainService: String

    public init(keychainService: String = "com.bicterm.keys.secure-enclave") {
        self.keychainService = keychainService
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
            requiresBiometry: requiresBiometry
        )
        try KeychainMetadataStore.add(
            service: keychainService,
            metadata: metadata,
            secret: key.dataRepresentation,
            requiresBiometry: false
        )
        return metadata
    }

    public func sign(data: Data, with reference: String, reason: String) async throws -> KeySignature {
        let key = try load(reference: reference, reason: reason)
        let signature = try key.signature(for: data)
        return KeySignature(algorithm: .ecdsaP256, rawRepresentation: signature.rawRepresentation)
    }

    public func authenticationPrivateKey(
        with reference: String,
        reason: String
    ) async throws -> NIOSSHPrivateKey {
        NIOSSHPrivateKey(secureEnclaveP256Key: try load(reference: reference, reason: reason))
    }

    public func opaqueRepresentationForTesting(_ reference: String) async throws -> Data {
        try storedRepresentation(reference: reference)
    }

    private func load(
        reference: String,
        reason: String
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let context = LAContext()
        context.localizedReason = reason
        return try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: storedRepresentation(reference: reference),
            authenticationContext: context
        )
    }

    private func storedRepresentation(reference: String) throws -> Data {
        var query = KeychainMetadataStore.baseQuery(service: keychainService, reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainMetadataStore.error(status)
        }
        return data
    }
}
