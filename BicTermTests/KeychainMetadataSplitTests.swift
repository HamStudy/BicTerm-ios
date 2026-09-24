import BicTermCore
import Security
import XCTest
@testable import BicTerm

/// The metadata/secret keychain split: metadata lives in a no-access-control
/// sibling service so attribute reads (key listings, `requiresBiometry`
/// checks) never evaluate the secret item's biometric ACL — the device
/// evidence behind the split was three silent `evaluateAccessControl`
/// evaluations per connect, one per attribute read of the combined item.
final class KeychainMetadataSplitTests: XCTestCase {
    private func deleteServiceTree(_ service: String) {
        for target in [service, KeychainMetadataStore.metadataService(service)] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: target,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
    }

    private func readAttributes(
        service: String,
        reference: String
    ) throws -> [String: Any]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeyRepositoryError.keychain(status)
        }
        return item as? [String: Any]
    }

    private func plantLegacyItem(
        service: String,
        reference: String,
        label: String
    ) throws {
        let legacy = Data("""
        {"reference":"\(reference)","label":"\(label)","algorithm":"ssh-ed25519",
         "fingerprint":"SHA256:legacy","publicKeyBlob":"AQID","requiresBiometry":false}
        """.utf8)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrGeneric as String: legacy,
            kSecValueData as String: Data("legacy-secret".utf8),
        ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }

    func testGeneratedKeySplitsSecretAndMetadataItems() async throws {
        let service = "com.bicterm.tests.split.\(UUID().uuidString)"
        defer { deleteServiceTree(service) }
        let repository = KeychainKeyRepository(keychainService: service)

        let metadata = try await repository.generateEd25519(
            label: "Split key",
            requiresBiometry: false
        )

        let secretAttributes = try readAttributes(
            service: service,
            reference: metadata.reference
        )
        XCTAssertNotNil(secretAttributes, "the secret item must exist in the secret service")
        XCTAssertNil(
            secretAttributes?[kSecAttrGeneric as String],
            "the secret item must not carry metadata — attribute reads of an access-controlled item evaluate its ACL"
        )

        let metadataAttributes = try readAttributes(
            service: KeychainMetadataStore.metadataService(service),
            reference: metadata.reference
        )
        XCTAssertNotNil(metadataAttributes, "the metadata item must exist in the metadata service")

        let listed = try await repository.list()
        XCTAssertEqual(listed, [metadata])

        let appItems = try KeychainItemQuery.listItems(service: service)
        XCTAssertEqual(appItems.map(\.reference), [metadata.reference])
        XCTAssertEqual(appItems.first?.createdDate, metadataAttributes?[kSecAttrCreationDate as String] as? Date)

        let key = try await repository.authenticationPrivateKey(
            with: metadata.reference,
            reason: "Authenticate to test"
        )
        XCTAssertNotNil(key)
    }

    func testLegacyItemMigratesOnceAndLaterLegacyKeysStayHidden() async throws {
        let service = "com.bicterm.tests.split-legacy.\(UUID().uuidString)"
        defer { deleteServiceTree(service) }
        let repository = KeychainKeyRepository(keychainService: service)

        let firstReference = UUID().uuidString
        try plantLegacyItem(service: service, reference: firstReference, label: "Legacy one")

        let listed = try await repository.list()
        XCTAssertEqual(listed.map(\.reference), [firstReference])

        let migrated = try readAttributes(
            service: KeychainMetadataStore.metadataService(service),
            reference: firstReference
        )
        XCTAssertNotNil(migrated, "the legacy scan must migrate metadata into its own item")

        let lateReference = UUID().uuidString
        try plantLegacyItem(service: service, reference: lateReference, label: "Legacy two")

        let afterScan = try await repository.list()
        XCTAssertEqual(
            afterScan.map(\.reference),
            [firstReference],
            "the completed scan marker must keep later reads off the secret service"
        )

        do {
            _ = try await repository.authenticationPrivateKey(
                with: lateReference,
                reason: "Authenticate to test"
            )
            XCTFail("an unscanned legacy key must not resolve once the scan marker is set")
        } catch KeyRepositoryError.keyNotFound {
            // Expected: the completed scan keeps reads off the ACL'd item,
            // so a legacy key that was never migrated does not resolve.
        }
    }

    func testDeleteRemovesBothItems() async throws {
        let service = "com.bicterm.tests.split-delete.\(UUID().uuidString)"
        defer { deleteServiceTree(service) }
        let repository = KeychainKeyRepository(keychainService: service)

        let metadata = try await repository.generateEd25519(
            label: "Delete me",
            requiresBiometry: false
        )
        try await repository.delete(reference: metadata.reference)

        let secretAttributes = try readAttributes(service: service, reference: metadata.reference)
        XCTAssertNil(secretAttributes)
        let metadataAttributes = try readAttributes(
            service: KeychainMetadataStore.metadataService(service),
            reference: metadata.reference
        )
        XCTAssertNil(metadataAttributes)
        let listed = try await repository.list()
        XCTAssertEqual(listed, [])

        do {
            try await repository.delete(reference: metadata.reference)
            XCTFail("deleting a missing key must throw keyNotFound")
        } catch let error as KeyRepositoryError {
            XCTAssertEqual(error, .keyNotFound)
        }
    }
}
