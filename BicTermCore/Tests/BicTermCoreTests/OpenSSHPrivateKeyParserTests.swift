import CryptoKit
import XCTest
@testable import BicTermCore

final class OpenSSHPrivateKeyParserTests: XCTestCase {
    private let parser = OpenSSHPrivateKeyParser()

    func testImportsUnencryptedEd25519AndMatchesOpenSSHGoldenValues() async throws {
        // Ground truth:
        // ssh-keygen -y -f Fixtures/keys/bicterm-fixture-ed25519
        // ssh-keygen -l -f Fixtures/keys/bicterm-fixture-ed25519.pub
        let parsed = try await parser.parse(fixture(named: "bicterm-fixture-ed25519"))

        XCTAssertEqual(parsed.algorithm, .ed25519)
        XCTAssertEqual(
            parsed.publicKeyBlob.base64EncodedString(),
            "AAAAC3NzaC1lZDI1NTE5AAAAIHFcpLR7cwsdJb3tgRBocxaGvMmTqB8kO8H9GF+h4EUX"
        )
        XCTAssertEqual(
            OpenSSHFingerprint.sha256(publicKeyBlob: parsed.publicKeyBlob),
            "SHA256:+r0XE2pE/ZCcOeGWrisHbWLLrEFKapNtuqH9LUZ7QqU"
        )
        XCTAssertEqual(
            parsed.privateKey.publicKey.rawRepresentation,
            try SSHWireFormat.ed25519RawPublicKey(from: parsed.publicKeyBlob)
        )
    }

    func testImportsPassphraseEncryptedEd25519() async throws {
        // Ground truth:
        // ssh-keygen -y -P "$BICTERM_FIXTURE_PASSPHRASE" \
        //   -f Fixtures/keys/bicterm-fixture-ed25519_passphrase
        // ssh-keygen -l -f Fixtures/keys/bicterm-fixture-ed25519_passphrase.pub
        let parsed = try await parser.parse(
            fixture(named: "bicterm-fixture-ed25519_passphrase"),
            passphrase: Data("testpass".utf8)
        )

        XCTAssertEqual(
            parsed.publicKeyBlob.base64EncodedString(),
            "AAAAC3NzaC1lZDI1NTE5AAAAIANfEz2hpfIm10JT8FPYm5OiSKwVyGdu622i9UkwyoHk"
        )
        XCTAssertEqual(
            OpenSSHFingerprint.sha256(publicKeyBlob: parsed.publicKeyBlob),
            "SHA256:R9XaxtlJKgrJE0AbFdKibF9+X1cPt0yWTzvTWUvh1r4"
        )
    }

    func testWrongPassphraseIsTyped() async throws {
        do {
            _ = try await parser.parse(
                fixture(named: "bicterm-fixture-ed25519_passphrase"),
                passphrase: Data("incorrect".utf8)
            )
            XCTFail("Expected the encrypted fixture to reject the passphrase")
        } catch let error as OpenSSHPrivateKeyParserError {
            XCTAssertEqual(error, .wrongPassphrase)
        }
    }

    func testRSAIsRejectedWithUnsupportedKeyType() async throws {
        do {
            _ = try await parser.parse(fixture(named: "bicterm-fixture-rsa3072"))
            XCTFail("Expected RSA to be unsupported")
        } catch let error as OpenSSHPrivateKeyParserError {
            XCTAssertEqual(error, .unsupportedKeyType("ssh-rsa"))
        }
    }

    func testDSAIsRejectedWithUnsupportedKeyType() async throws {
        let publicBlob = SSHWireFormat.encodeString(Data("ssh-dss".utf8))
        let container = makeContainer(publicBlob: publicBlob)

        do {
            _ = try await parser.parse(pem(container))
            XCTFail("Expected DSA to be unsupported")
        } catch let error as OpenSSHPrivateKeyParserError {
            XCTAssertEqual(error, .unsupportedKeyType("ssh-dss"))
        }
    }

    func testBCryptPBKDFMatchesOpenBSDVector() throws {
        let result = try OpenSSHKeyDecryption.deriveBCryptKey(
            passphrase: Data("password".utf8),
            salt: Data("salt".utf8),
            rounds: 4,
            outputLength: 32
        )

        XCTAssertEqual(
            result,
            Data(hex: "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
        )
    }

    func testAES256CTRMatchesNISTVector() throws {
        let plaintext = Data(hex:
            "6bc1bee22e409f96e93d7e117393172a" +
            "ae2d8a571e03ac9c9eb76fac45af8e51"
        )
        let encrypted = try OpenSSHKeyDecryption.cryptAES256CTR(
            plaintext,
            key: Data(hex:
                "603deb1015ca71be2b73aef0857d7781" +
                "1f352c073b6108d72d9810a30914dff4"
            ),
            iv: Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        )

        XCTAssertEqual(
            encrypted,
            Data(hex:
                "601ec313775789a5b7a7f504bbf3d228" +
                "f443e3ca4d62b59aca84e990cacaf5c5"
            )
        )
    }

    private func fixture(named name: String) -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("Fixtures/keys/\(name)")
        return try! Data(contentsOf: url)
    }

    private func makeContainer(publicBlob: Data) -> Data {
        var data = Data("openssh-key-v1\0".utf8)
        data.append(SSHWireFormat.encodeString(Data("none".utf8)))
        data.append(SSHWireFormat.encodeString(Data("none".utf8)))
        data.append(SSHWireFormat.encodeString(Data()))
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(SSHWireFormat.encodeString(publicBlob))
        data.append(SSHWireFormat.encodeString(Data(repeating: 0, count: 8)))
        return data
    }

    private func pem(_ binary: Data) -> Data {
        let base64 = binary.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        self.init()
        reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
