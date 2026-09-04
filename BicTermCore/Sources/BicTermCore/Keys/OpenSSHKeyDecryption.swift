import CBcryptPBKDF
import Foundation

public enum OpenSSHKeyDecryptionError: Error, Equatable, Sendable {
    case invalidParameters
    case derivationFailed
    case cipherFailed(Int32)
}

public enum OpenSSHKeyDecryption {
    public static func deriveBCryptKey(
        passphrase: Data,
        salt: Data,
        rounds: UInt32,
        outputLength: Int
    ) throws -> Data {
        guard !passphrase.isEmpty, !salt.isEmpty, rounds > 0, outputLength > 0 else {
            throw OpenSSHKeyDecryptionError.invalidParameters
        }
        var output = Data(count: outputLength)
        let status = output.withUnsafeMutableBytes { outputBytes in
            passphrase.withUnsafeBytes { passphraseBytes in
                salt.withUnsafeBytes { saltBytes in
                    bcrypt_pbkdf(
                        passphraseBytes.bindMemory(to: CChar.self).baseAddress,
                        passphrase.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputLength,
                        rounds
                    )
                }
            }
        }
        guard status == 0 else { throw OpenSSHKeyDecryptionError.derivationFailed }
        return output
    }

    public static func cryptAES256CTR(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else {
            throw OpenSSHKeyDecryptionError.invalidParameters
        }
        guard !input.isEmpty else { return Data() }
        var output = Data(count: input.count)
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        bicterm_aes256_ctr_crypt(
                            inputBytes.bindMemory(to: UInt8.self).baseAddress,
                            input.count,
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBytes.bindMemory(to: UInt8.self).baseAddress,
                            iv.count,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress
                        )
                    }
                }
            }
        }
        guard status == 0 else { throw OpenSSHKeyDecryptionError.cipherFailed(status) }
        return output
    }
}
