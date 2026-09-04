import CryptoKit
import Foundation

public enum SSHWireFormatError: Error, Equatable, Sendable {
    case truncated
    case invalidLength
    case unexpectedValue
}

public enum SSHWireFormat {
    public static func encodeString(_ value: Data) -> Data {
        var result = Data()
        result.appendUInt32(UInt32(value.count))
        result.append(value)
        return result
    }

    public static func ed25519PublicKeyBlob(rawPublicKey: Data) -> Data {
        encodeString(Data(KeyAlgorithm.ed25519.rawValue.utf8)) + encodeString(rawPublicKey)
    }

    public static func ed25519RawPublicKey(from blob: Data) throws -> Data {
        var reader = SSHWireReader(blob)
        guard try reader.readString() == Data(KeyAlgorithm.ed25519.rawValue.utf8) else {
            throw SSHWireFormatError.unexpectedValue
        }
        let key = try reader.readString()
        guard key.count == 32, reader.isAtEnd else {
            throw SSHWireFormatError.invalidLength
        }
        return key
    }

    public static func ecdsaP256PublicKeyBlob(x963PublicKey: Data) -> Data {
        encodeString(Data(KeyAlgorithm.ecdsaP256.rawValue.utf8))
            + encodeString(Data("nistp256".utf8))
            + encodeString(x963PublicKey)
    }

    public static func ecdsaP256RawPublicKey(from blob: Data) throws -> Data {
        var reader = SSHWireReader(blob)
        guard try reader.readString() == Data(KeyAlgorithm.ecdsaP256.rawValue.utf8),
              try reader.readString() == Data("nistp256".utf8) else {
            throw SSHWireFormatError.unexpectedValue
        }
        let key = try reader.readString()
        guard key.count == 65, key.first == 4, reader.isAtEnd else {
            throw SSHWireFormatError.invalidLength
        }
        return key
    }
}

public struct SSHWireReader {
    private let data: Data
    private var offset = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var isAtEnd: Bool { offset == data.count }

    public mutating func readUInt32() throws -> UInt32 {
        guard data.count - offset >= 4 else { throw SSHWireFormatError.truncated }
        let value = data[offset..<(offset + 4)].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    public mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard length >= 0, length <= data.count - offset else {
            throw SSHWireFormatError.invalidLength
        }
        let value = Data(data[offset..<(offset + length)])
        offset += length
        return value
    }

    public mutating func readRemaining() -> Data {
        defer { offset = data.count }
        return Data(data[offset...])
    }
}

public enum OpenSSHFingerprint {
    public static func sha256(publicKeyBlob: Data) -> String {
        let digest = Data(SHA256.hash(data: publicKeyBlob))
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
