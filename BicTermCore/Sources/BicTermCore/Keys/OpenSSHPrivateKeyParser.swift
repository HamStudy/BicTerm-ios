import CryptoKit
import Foundation

public enum OpenSSHPrivateKeyParserError: Error, Equatable, Sendable {
    case invalidFormat
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case unsupportedKeyType(String)
    case missingPassphrase
    case wrongPassphrase
}

public struct ParsedOpenSSHPrivateKey {
    public let algorithm: KeyAlgorithm
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKeyBlob: Data
    public let comment: String
}

public struct OpenSSHPrivateKeyParser: Sendable {
    private static let magic = Data("openssh-key-v1\0".utf8)

    public init() {}

    public func parse(_ input: Data, passphrase: Data? = nil) async throws -> ParsedOpenSSHPrivateKey {
        let binary = try decodePEMIfNeeded(input)
        guard binary.starts(with: Self.magic) else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }

        var reader = SSHWireReader(Data(binary.dropFirst(Self.magic.count)))
        let cipherName = try string(try reader.readString())
        let kdfName = try string(try reader.readString())
        let kdfOptions = try reader.readString()
        guard try reader.readUInt32() == 1 else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }

        let publicKeyBlob = try reader.readString()
        let encryptedPrivateSection = try reader.readString()
        guard reader.isAtEnd else { throw OpenSSHPrivateKeyParserError.invalidFormat }

        var publicReader = SSHWireReader(publicKeyBlob)
        let publicAlgorithm = try string(try publicReader.readString())
        guard publicAlgorithm == KeyAlgorithm.ed25519.rawValue else {
            throw OpenSSHPrivateKeyParserError.unsupportedKeyType(publicAlgorithm)
        }

        let privateSection: Data
        switch (cipherName, kdfName) {
        case ("none", "none"):
            guard kdfOptions.isEmpty else { throw OpenSSHPrivateKeyParserError.invalidFormat }
            privateSection = encryptedPrivateSection
        case ("aes256-ctr", "bcrypt"):
            guard let passphrase, !passphrase.isEmpty else {
                throw OpenSSHPrivateKeyParserError.missingPassphrase
            }
            var optionsReader = SSHWireReader(kdfOptions)
            let salt = try optionsReader.readString()
            let rounds = try optionsReader.readUInt32()
            guard optionsReader.isAtEnd else { throw OpenSSHPrivateKeyParserError.invalidFormat }
            let material = try OpenSSHKeyDecryption.deriveBCryptKey(
                passphrase: passphrase,
                salt: salt,
                rounds: rounds,
                outputLength: 48
            )
            privateSection = try OpenSSHKeyDecryption.cryptAES256CTR(
                encryptedPrivateSection,
                key: Data(material.prefix(32)),
                iv: Data(material.dropFirst(32))
            )
        case (let unsupported, "bcrypt"):
            throw OpenSSHPrivateKeyParserError.unsupportedCipher(unsupported)
        case (_, let unsupported):
            throw OpenSSHPrivateKeyParserError.unsupportedKDF(unsupported)
        }

        do {
            return try parseEd25519PrivateSection(privateSection, publicKeyBlob: publicKeyBlob)
        } catch let error as OpenSSHPrivateKeyParserError {
            if cipherName != "none", error == .invalidFormat {
                throw OpenSSHPrivateKeyParserError.wrongPassphrase
            }
            throw error
        } catch {
            throw cipherName == "none"
                ? OpenSSHPrivateKeyParserError.invalidFormat
                : OpenSSHPrivateKeyParserError.wrongPassphrase
        }
    }

    private func parseEd25519PrivateSection(
        _ data: Data,
        publicKeyBlob: Data
    ) throws -> ParsedOpenSSHPrivateKey {
        var reader = SSHWireReader(data)
        let firstCheck = try reader.readUInt32()
        guard firstCheck == (try reader.readUInt32()) else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }
        let keyType = try string(try reader.readString())
        guard keyType == KeyAlgorithm.ed25519.rawValue else {
            throw OpenSSHPrivateKeyParserError.unsupportedKeyType(keyType)
        }
        let publicKey = try reader.readString()
        let privateAndPublicKey = try reader.readString()
        let comment = try string(try reader.readString())
        let padding = reader.readRemaining()

        guard publicKey.count == 32,
              privateAndPublicKey.count == 64,
              Data(privateAndPublicKey.suffix(32)) == publicKey,
              SSHWireFormat.ed25519PublicKeyBlob(rawPublicKey: publicKey) == publicKeyBlob,
              padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) }) else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }

        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(privateAndPublicKey.prefix(32))
        )
        guard privateKey.publicKey.rawRepresentation == publicKey else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }
        return ParsedOpenSSHPrivateKey(
            algorithm: .ed25519,
            privateKey: privateKey,
            publicKeyBlob: publicKeyBlob,
            comment: comment
        )
    }

    private func decodePEMIfNeeded(_ input: Data) throws -> Data {
        if input.starts(with: Self.magic) { return input }
        guard let pem = String(data: input, encoding: .utf8),
              pem.contains("-----BEGIN OPENSSH PRIVATE KEY-----"),
              pem.contains("-----END OPENSSH PRIVATE KEY-----") else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: base64) else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }
        return decoded
    }

    private func string(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw OpenSSHPrivateKeyParserError.invalidFormat
        }
        return value
    }
}
