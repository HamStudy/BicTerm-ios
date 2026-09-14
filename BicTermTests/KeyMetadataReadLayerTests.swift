import BicTermCore
import Security
import XCTest
@testable import BicTerm

@MainActor
final class KeyMetadataReadLayerTests: XCTestCase {
    func testLegacyMetadataDecodesEnabledByDefault() async throws {
        let service = "com.bicterm.tests.metadata.\(UUID().uuidString)"
        let reference = UUID().uuidString
        defer { try? KeychainItemQuery.deleteItem(service: service, reference: reference) }
        let legacy = Data("""
        {"reference":"\(reference)","label":"Legacy key","algorithm":"ssh-ed25519",
         "fingerprint":"SHA256:legacy","publicKeyBlob":"AQID","requiresBiometry":true}
        """.utf8)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrGeneric as String: legacy,
            kSecValueData as String: Data(),
        ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        let repository = KeychainKeyRepository(keychainService: service)
        let coreItems = try await repository.list()
        let appItems = try KeychainItemQuery.listItems(service: service)
        XCTAssertEqual(appItems.map(\.metadata), coreItems)
        XCTAssertTrue(try XCTUnwrap(appItems.first).metadata.enabledByDefault)
        XCTAssertTrue(try XCTUnwrap(appItems.first).metadata.requiresBiometry)
        try repository.setEnabled(false, reference: reference)
        XCTAssertFalse(try XCTUnwrap(KeychainItemQuery.listItems(service: service).first).metadata.enabledByDefault)
    }

    func testSetEnabledRoundTripAcrossReadLayers() async throws {
        let service = "com.bicterm.tests.metadata.\(UUID().uuidString)"
        let repository = KeychainKeyRepository(keychainService: service)
        let original = try await repository.generateEd25519(label: "Read layers", requiresBiometry: false)
        defer { try? KeychainItemQuery.deleteItem(service: service, reference: original.reference) }
        let createdDate = try XCTUnwrap(KeychainItemQuery.listItems(service: service).first).createdDate
        XCTAssertTrue(original.enabledByDefault)
        for enabled in [false, true] {
            try repository.setEnabled(enabled, reference: original.reference)
            let coreItems = try await repository.list()
            let appItems = try KeychainItemQuery.listItems(service: service)
            XCTAssertEqual(appItems.map(\.metadata), coreItems)
            let item = try XCTUnwrap(appItems.first)
            XCTAssertEqual(item.metadata.enabledByDefault, enabled)
            XCTAssertEqual(item.reference, original.reference)
            XCTAssertEqual(item.createdDate, createdDate)
        }
    }

    func testSecureEnclaveWrapperMatchesCoreReadLayer() async throws {
        let service = "com.bicterm.tests.metadata.se.\(UUID().uuidString)"
        let metadata = KeyMetadata(
            reference: UUID().uuidString, label: "SE metadata", algorithm: .ecdsaP256,
            fingerprint: "SHA256:fixture", publicKeyBlob: Data([1, 2, 3]), requiresBiometry: true
        )
        defer { try? KeychainItemQuery.deleteItem(service: service, reference: metadata.reference) }
        try KeychainItemQuery.addItem(service: service, metadata: metadata)
        let secureEnclave = SecureEnclaveKeyService(keychainService: service)
        let repository = KeychainKeyRepository(keychainService: service)
        for enabled in [false, true] {
            try secureEnclave.setEnabled(enabled, reference: metadata.reference)
            let coreItems = try await repository.list()
            let appItems = try KeychainItemQuery.listItems(service: service)
            XCTAssertEqual(appItems.map(\.metadata), coreItems)
            XCTAssertEqual(try XCTUnwrap(appItems.first).metadata.enabledByDefault, enabled)
            XCTAssertTrue(try XCTUnwrap(appItems.first).metadata.requiresBiometry)
        }
    }

    func testSetEnabledMissingReferenceThrowsKeyNotFound() throws {
        let service = "com.bicterm.tests.metadata.\(UUID().uuidString)"
        let repository = KeychainKeyRepository(keychainService: service)
        XCTAssertThrowsError(try repository.setEnabled(true, reference: "nonexistent-\(UUID().uuidString)")) {
            XCTAssertEqual($0 as? KeyRepositoryError, .keyNotFound)
        }
    }

    func testSignStillWorksAfterDisable() async throws {
        let service = "com.bicterm.tests.metadata.\(UUID().uuidString)"
        let repository = KeychainKeyRepository(keychainService: service)
        let metadata = try await repository.generateEd25519(label: "Still signs", requiresBiometry: false)
        defer { try? KeychainItemQuery.deleteItem(service: service, reference: metadata.reference) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadata.reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var before: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &before), errSecSuccess)
        let originalSecret = try XCTUnwrap(before as? Data)
        XCTAssertFalse(originalSecret.isEmpty)

        try repository.setEnabled(false, reference: metadata.reference)
        XCTAssertFalse(try XCTUnwrap(KeychainItemQuery.listItems(service: service).first).metadata.enabledByDefault)
        let signature = try await repository.sign(data: Data("disabled-key-signature".utf8), with: metadata.reference)
        XCTAssertEqual(signature.algorithm, .ed25519)
        XCTAssertEqual(signature.rawRepresentation.count, 64)

        var after: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &after), errSecSuccess)
        XCTAssertEqual(try XCTUnwrap(after as? Data), originalSecret)
    }
}
