import BicTermCore
import CryptoKit
import Foundation
import Security

/// App-side keychain queries for key metadata that `BicTermCore` repositories do
/// not expose (Secure Enclave listing/deletion, item creation dates).
///
/// Listing delegates to `KeychainMetadataStore.list(_:)`, which owns the
/// one-time legacy layout scan and the metadata items (the no-access-control
/// sibling service — attribute reads of the secret's item evaluate its ACL
/// on device). Deletion removes both the metadata item and the secret item.
enum KeychainItemQuery {
    struct Item {
        let reference: String
        let metadata: KeyMetadata
        let createdDate: Date?
    }

    static func listItems(service: String) throws -> [Item] {
        let metadata = try KeychainMetadataStore.list(service: service)
        let creationDates = try readCreationDates(
            service: KeychainMetadataStore.metadataService(service)
        )
        return metadata.map {
            Item(reference: $0.reference, metadata: $0, createdDate: creationDates[$0.reference])
        }
    }

    private static func readCreationDates(service: String) throws -> [String: Date] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let attributes = item as? [[String: Any]] else {
            throw KeyRepositoryError.keychain(status)
        }
        var dates: [String: Date] = [:]
        for entry in attributes {
            guard let reference = entry[kSecAttrAccount as String] as? String,
                  let created = entry[kSecAttrCreationDate as String] as? Date else {
                continue
            }
            dates[reference] = created
        }
        return dates
    }

    static func deleteItem(service: String, reference: String) throws {
        for target in [service, KeychainMetadataStore.metadataService(service)] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: target,
                kSecAttrAccount as String: reference,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeyRepositoryError.keychain(status)
            }
        }
    }

    static func addItem(service: String, metadata: KeyMetadata) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainMetadataStore.metadataService(service),
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
