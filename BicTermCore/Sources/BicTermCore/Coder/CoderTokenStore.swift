import Foundation
import Security

public enum CoderTokenStoreError: Error, Equatable, Sendable {
    case invalidStoredToken
    case keychain(OSStatus)
}

extension CoderTokenStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidStoredToken:
            "The saved Coder token is invalid."
        case let .keychain(status):
            "Secure token storage failed (status \(status))."
        }
    }
}

public protocol CoderTokenStoring: Sendable {
    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String?
    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError)
    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError)
}

public actor KeychainCoderTokenStore: CoderTokenStoring {
    public let keychainService: String

    public init(keychainService: String = "com.bicterm.coder.session-tokens") {
        self.keychainService = keychainService
    }

    public func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        var query = baseQuery(for: keychainTag)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychain(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw .invalidStoredToken
        }
        return token
    }

    public func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        let query = baseQuery(for: keychainTag)
        let tokenData = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: tokenData] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw .keychain(updateStatus) }

        var attributes = query
        attributes[kSecValueData as String] = tokenData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: tokenData] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw .keychain(retryStatus) }
            return
        }
        guard addStatus == errSecSuccess else { throw .keychain(addStatus) }
    }

    public func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
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
