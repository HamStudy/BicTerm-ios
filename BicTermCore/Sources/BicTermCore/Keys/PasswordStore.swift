import Foundation
import Security

public enum PasswordStoreError: Error, Equatable, Sendable {
    case invalidStoredPassword
    case keychain(OSStatus)
}

extension PasswordStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidStoredPassword:
            "The saved SSH password is unreadable."
        case let .keychain(status):
            "Secure password storage failed (status \(status))."
        }
    }
}

/// Stores SSH passwords for `.password`-method connections and hops. Callers
/// pass an opaque tag (persisted in the model's credential-reference field);
/// the tag must never be derived from the password itself.
public protocol PasswordStoring: Sendable {
    /// Returns the stored password, or nil when the tag has no entry.
    func password(for keychainTag: String) async throws(PasswordStoreError) -> String?
    /// Upserts the password under the tag. An existing entry is replaced.
    func save(_ password: String, for keychainTag: String) async throws(PasswordStoreError)
    /// Idempotent: deleting a missing tag succeeds (connection deletion must
    /// not fail because a credential was already gone).
    func deletePassword(for keychainTag: String) async throws(PasswordStoreError)
}

/// Keychain-backed ``PasswordStoring``: generic-password items protected by
/// the data-protection Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// (never migrated to a new device, never readable while locked).
public actor KeychainPasswordStore: PasswordStoring {
    public let keychainService: String

    public init(keychainService: String = "com.bicterm.passwords") {
        self.keychainService = keychainService
    }

    public func password(for keychainTag: String) async throws(PasswordStoreError) -> String? {
        var query = baseQuery(for: keychainTag)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychain(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw .invalidStoredPassword
        }
        return password
    }

    public func save(_ password: String, for keychainTag: String) async throws(PasswordStoreError) {
        let query = baseQuery(for: keychainTag)
        let passwordData = Data(password.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: passwordData] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw .keychain(updateStatus) }

        var attributes = query
        attributes[kSecValueData as String] = passwordData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: passwordData] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw .keychain(retryStatus) }
            return
        }
        guard addStatus == errSecSuccess else { throw .keychain(addStatus) }
    }

    public func deletePassword(for keychainTag: String) async throws(PasswordStoreError) {
        let status = SecItemDelete(baseQuery(for: keychainTag) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status)
        }
    }

    private func baseQuery(for keychainTag: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainTag,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
