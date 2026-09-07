import BicTermCore
import CryptoKit
import Foundation
import Security

/// App-side keychain queries for key metadata that `BicTermCore` repositories do
/// not expose (Secure Enclave listing/deletion, item creation dates).
///
/// The queries mirror `KeychainMetadataStore` in BicTermCore: the same services,
/// the same `kSecAttrGeneric` JSON payload of `KeyMetadata`, and read-only
/// attribute access (reading attributes never triggers the biometric access
/// control, which only guards secret values).
enum KeychainItemQuery {
    struct Item {
        let reference: String
        let metadata: KeyMetadata
        let createdDate: Date?
    }

    static func listItems(service: String) throws -> [Item] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let attributes = item as? [[String: Any]] else {
            throw KeyRepositoryError.keychain(status)
        }
        let decoder = JSONDecoder()
        return try attributes.compactMap { entry in
            guard let encoded = entry[kSecAttrGeneric as String] as? Data,
                  let metadata = try? decoder.decode(KeyMetadata.self, from: encoded) else {
                return nil
            }
            let created = entry[kSecAttrCreationDate as String] as? Date
            return Item(reference: metadata.reference, metadata: metadata, createdDate: created)
        }
    }

    static func deleteItem(service: String, reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyRepositoryError.keychain(status)
        }
    }

    static func addItem(service: String, metadata: KeyMetadata) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadata.reference,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrLabel as String: metadata.label,
            kSecAttrGeneric as String: try JSONEncoder().encode(metadata),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyRepositoryError.keychain(status)
        }
    }
}
