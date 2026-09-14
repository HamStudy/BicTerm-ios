import Foundation

/// Key source for the forwarded agent. Implementations must never export
/// private key material: only public blobs leave the process, and signing is
/// resolved strictly by EXACT public-blob match.
public protocol AgentKeyProvider: Sendable {
    /// Public identities (wire-format blobs + labels) the agent may advertise.
    func publicKeys() async throws -> [KeyMetadata]

    /// Signs `data` with the key whose public blob equals `publicKeyBlob`
    /// byte-for-byte. Throws ``KeyRepositoryError/keyNotFound`` on any
    /// mismatch — signing for anything but the exact requested key is
    /// impossible through this interface.
    func sign(data: Data, publicKeyBlob: Data) async throws -> KeySignature
}

/// Production provider over T3's stores: Ed25519 keys from the Keychain
/// repository, ECDSA P-256 keys from the Secure Enclave service. Both are
/// enumerated through their metadata stores so blobs can be matched without
/// touching key material.
public struct DefaultAgentKeyProvider: AgentKeyProvider {
    private let keychainRepository: KeychainKeyRepository
    private let secureEnclaveService: SecureEnclaveKeyService
    private let metadataLoader: @Sendable () throws -> [KeyMetadata]

    public init() {
        self.init(metadataLoader: {
            let ed25519Keys = try KeychainMetadataStore.list(service: KeychainKeyRepository().keychainService)
            let enclaveKeys = try KeychainMetadataStore.list(service: SecureEnclaveKeyService().keychainService)
            return ed25519Keys + enclaveKeys
        })
    }

    init(metadataLoader: @escaping @Sendable () throws -> [KeyMetadata]) {
        self.keychainRepository = KeychainKeyRepository()
        self.secureEnclaveService = SecureEnclaveKeyService()
        self.metadataLoader = metadataLoader
    }

    public func publicKeys() async throws -> [KeyMetadata] {
        let keys = canonicalKeyMetadata(try metadataLoader())
        let references = Set(KeyOfferResolver().resolve(
            KeyOfferRequest(offersKeys: true, customKeys: nil, hardwareKeysEnabledByDefault: true),
            keys: keys
        ))
        return keys.filter { references.contains($0.reference) }
    }

    public func sign(data: Data, publicKeyBlob: Data) async throws -> KeySignature {
        guard let metadata = try await publicKeys().first(where: { $0.publicKeyBlob == publicKeyBlob }) else {
            throw KeyRepositoryError.keyNotFound
        }
        switch metadata.algorithm {
        case .ed25519:
            return try await keychainRepository.sign(data: data, with: metadata.reference)
        case .ecdsaP256:
            return try await secureEnclaveService.sign(
                data: data,
                with: metadata.reference,
                reason: "Sign via forwarded SSH agent for \(metadata.label)"
            )
        }
    }
}
