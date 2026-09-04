import CryptoKit
import NIOSSH
import Security
import XCTest
@testable import BicTermCore

final class KeyRepositoryTests: XCTestCase {
    private var services: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let service = "com.bicterm.tests.keychain-preflight.\(UUID().uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "preflight",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data("preflight".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("SPM simulator test bundle has no Data Protection Keychain entitlement")
        }
        guard status == errSecSuccess else {
            throw KeyRepositoryError.keychain(status)
        }
        SecItemDelete(query as CFDictionary)
    }

    override func tearDown() {
        for service in services {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
        services.removeAll()
        super.tearDown()
    }

    func testGenerateListSignAndDeleteEd25519() async throws {
        let repository = makeRepository()
        let metadata = try await repository.generateEd25519(
            label: "Generated test key",
            requiresBiometry: false
        )

        let listed = try await repository.list()
        XCTAssertEqual(listed, [metadata])
        XCTAssertEqual(metadata.algorithm, .ed25519)

        let message = Data("bicterm-signature-test".utf8)
        let signature = try await repository.sign(data: message, with: metadata.reference)
        let rawPublicKey = try SSHWireFormat.ed25519RawPublicKey(from: metadata.publicKeyBlob)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        XCTAssertEqual(signature.algorithm, .ed25519)
        XCTAssertTrue(publicKey.isValidSignature(signature.rawRepresentation, for: message))

        try await repository.delete(reference: metadata.reference)
        let remainingKeys = try await repository.list()
        XCTAssertEqual(remainingKeys, [])
    }

    func testGeneratedKeyUsesWhenUnlockedThisDeviceOnlyAccessibility() async throws {
        let repository = makeRepository()
        let metadata = try await repository.generateEd25519(
            label: "Accessibility test",
            requiresBiometry: false
        )

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: repository.keychainService,
            kSecAttrAccount as String: metadata.reference,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, &item)

        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    func testImportsFixtureThroughRepository() async throws {
        let repository = makeRepository()
        let metadata = try await repository.importOpenSSHPrivateKey(
            fixture(named: "bicterm-fixture-ed25519_passphrase"),
            passphrase: Data("testpass".utf8),
            label: "Imported fixture",
            requiresBiometry: false
        )

        XCTAssertEqual(
            metadata.fingerprint,
            "SHA256:R9XaxtlJKgrJE0AbFdKibF9+X1cPt0yWTzvTWUvh1r4"
        )
        let listedKeys = try await repository.list()
        XCTAssertEqual(listedKeys, [metadata])
    }

    func testCreatesOpaqueNIOSSHAuthenticationKey() async throws {
        let repository = makeRepository()
        let metadata = try await repository.generateEd25519(
            label: "NIOSSH authentication key",
            requiresBiometry: false
        )

        let authenticationKey = try await repository.authenticationPrivateKey(
            with: metadata.reference,
            reason: "Authenticate test connection"
        )
        let expectedPublicKey = try NIOSSHPublicKey(
            openSSHPublicKey: "ssh-ed25519 \(metadata.publicKeyBlob.base64EncodedString())"
        )

        XCTAssertEqual(authenticationKey.publicKey, expectedPublicKey)
    }

    func testPrivateKeyNeverAppearsInEncodedConnectionState() async throws {
        let repository = makeRepository()
        let metadata = try await repository.generateEd25519(
            label: "Secret absence test",
            requiresBiometry: false
        )
        let privateData = try readPrivateData(
            service: repository.keychainService,
            reference: metadata.reference
        )

        let encodedMetadata = try JSONEncoder().encode(try await repository.list())
        XCTAssertNil(encodedMetadata.range(of: privateData), "Encoded metadata contained private bytes")
        XCTAssertNil(
            encodedMetadata.range(of: privateData.base64EncodedData()),
            "Encoded metadata contained Base64 private bytes"
        )
    }

    private func makeRepository() -> KeychainKeyRepository {
        let service = "com.bicterm.tests.keys.\(UUID().uuidString)"
        services.append(service)
        return KeychainKeyRepository(keychainService: service)
    }

    private func fixture(named name: String) -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try! Data(contentsOf: repositoryRoot.appendingPathComponent("Fixtures/keys/\(name)"))
    }

    private func readPrivateData(service: String, reference: String) throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(item as? Data)
    }
}
