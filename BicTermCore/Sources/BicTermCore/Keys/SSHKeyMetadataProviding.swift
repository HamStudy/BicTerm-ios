public protocol SSHKeyMetadataProviding: Sendable {
    func availableKeys() async throws -> [KeyMetadata]
}

/// Enumerates metadata only; key material is resolved lazily during authentication.
public struct DefaultSSHKeyMetadataProvider: SSHKeyMetadataProviding {
    public init() {}

    public func availableKeys() async throws -> [KeyMetadata] {
        let keychainKeys = try KeychainMetadataStore.list(service: KeychainKeyRepository().keychainService)
        let enclaveKeys = try KeychainMetadataStore.list(service: SecureEnclaveKeyService().keychainService)
        return keychainKeys + enclaveKeys
    }
}
