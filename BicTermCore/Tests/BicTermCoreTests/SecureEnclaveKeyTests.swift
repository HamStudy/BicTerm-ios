import CryptoKit
import LocalAuthentication
import NIOSSH
import Security
import XCTest
@testable import BicTermCore

final class SecureEnclaveKeyTests: XCTestCase {
    func testSecureEnclavePreflight() {
        print("BicTerm Secure Enclave preflight: available=\(SecureEnclave.isAvailable)")
    }

    func testP256PublicBlobUsesOpenSSHWireFormat() throws {
        let key = P256.Signing.PrivateKey()
        let blob = SSHWireFormat.ecdsaP256PublicKeyBlob(x963PublicKey: key.publicKey.x963Representation)
        let line = "ecdsa-sha2-nistp256 \(blob.base64EncodedString())"

        XCTAssertNoThrow(try NIOSSHPublicKey(openSSHPublicKey: line))
        var reader = SSHWireReader(blob)
        XCTAssertEqual(try reader.readString(), Data("ecdsa-sha2-nistp256".utf8))
        XCTAssertEqual(try reader.readString(), Data("nistp256".utf8))
        XCTAssertEqual(try reader.readString(), key.publicKey.x963Representation)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testGenerateSignAndPersistWhenSecureEnclaveAvailable() async throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "Secure Enclave is unavailable in this environment")
        try requireDataProtectionKeychain()
        let service = "com.bicterm.tests.secure-enclave.\(UUID().uuidString)"
        let keyService = SecureEnclaveKeyService(keychainService: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }

        let metadata = try await keyService.generate(
            label: "Secure Enclave test",
            requiresBiometry: false
        )
        let message = Data("secure-enclave-signature".utf8)
        let signature = try await keyService.sign(
            data: message,
            with: metadata.reference,
            reason: "Test Secure Enclave signing"
        )
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: SSHWireFormat.ecdsaP256RawPublicKey(from: metadata.publicKeyBlob)
        )
        let cryptoSignature = try P256.Signing.ECDSASignature(
            rawRepresentation: signature.rawRepresentation
        )

        XCTAssertTrue(publicKey.isValidSignature(cryptoSignature, for: message))
        let opaqueRepresentation = try await keyService.opaqueRepresentationForTesting(metadata.reference)
        XCTAssertFalse(opaqueRepresentation.isEmpty)
    }

    func testBiometricSecureEnclaveKeyWhenAvailableAndEnrolled() async throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "Secure Enclave is unavailable in this environment")
        try requireDataProtectionKeychain()
        let context = LAContext()
        var evaluationError: NSError?
        try XCTSkipUnless(
            context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError),
            "Biometrics are not enrolled"
        )
        let service = "com.bicterm.tests.secure-enclave-biometric.\(UUID().uuidString)"
        let keyService = SecureEnclaveKeyService(keychainService: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }

        let metadata = try await keyService.generate(
            label: "Biometric Secure Enclave test",
            requiresBiometry: true
        )

        XCTAssertTrue(metadata.requiresBiometry)
    }

    private func requireDataProtectionKeychain() throws {
        let service = "com.bicterm.tests.secure-enclave-preflight.\(UUID().uuidString)"
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
}
