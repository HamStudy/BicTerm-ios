import Foundation

/// A public key served by the agent: wire-format blob (the bytes base64'd in
/// an `authorized_keys` line) plus a free-form comment (we use the key label).
public struct SSHAgentIdentity: Equatable, Sendable {
    public let blob: Data
    public let comment: String

    public init(blob: Data, comment: String) {
        self.blob = blob
        self.comment = comment
    }
}

/// Decoded client→agent request. The allowlist is deliberately minimal: this
/// agent is read-only — no key add/remove/lock opcodes exist here at all.
public enum SSHAgentMessage: Equatable, Sendable {
    /// SSH_AGENTC_REQUEST_IDENTITIES (11).
    case requestIdentities
    /// SSH_AGENTC_SIGN_REQUEST (13): string key blob, string data, uint32 flags.
    case signRequest(keyBlob: Data, data: Data, flags: UInt32)
}

/// Every error is terminal: the agent stream cannot be resynchronized after a
/// framing or protocol violation, so the channel must be closed. The codec
/// latches the first failure and rethrows it on any further `feed`.
public enum SSHAgentCodecError: Error, Equatable, Sendable {
    /// Declared frame length exceeds the hard cap (256 KiB).
    case frameTooLarge(declaredBytes: UInt32)
    /// Stream ended (or was finished) with a partial length prefix or payload buffered.
    case truncatedFrame
    /// Declared length 0 — a frame must carry at least an opcode byte.
    case emptyFrame
    /// Opcode outside the allowlist {11, 13}.
    case unknownOpcode(UInt8)
    /// Allowed opcode whose payload does not parse per PROTOCOL.agent.
    case malformedPayload(opcode: UInt8)
}

/// Incremental decoder/encoder for the OpenSSH agent wire protocol
/// (PROTOCOL.agent): uint32-BE length prefix + payload, payload's first byte
/// is the opcode. Pure value type — no NIO, no I/O — so torture tests drive
/// it directly with arbitrary fragmentation.
public struct SSHAgentCodec: Sendable {
    public static let maximumFrameBytes: UInt32 = 256 * 1024

    public static let opcodeFailure: UInt8 = 5
    public static let opcodeRequestIdentities: UInt8 = 11
    public static let opcodeIdentitiesAnswer: UInt8 = 12
    public static let opcodeSignRequest: UInt8 = 13
    public static let opcodeSignResponse: UInt8 = 14

    private var buffer = Data()
    private var failure: SSHAgentCodecError?

    public init() {}

    /// Feeds raw bytes; returns one message per COMPLETE frame, exactly once,
    /// regardless of how the bytes were fragmented across calls.
    public mutating func feed(_ bytes: Data) throws(SSHAgentCodecError) -> [SSHAgentMessage] {
        if let failure { throw failure }
        buffer.append(bytes)
        do {
            return try drain()
        } catch {
            failure = error
            throw error
        }
    }

    /// Call on EOF. A non-empty buffer means the peer hung up mid-frame.
    public mutating func finish() throws(SSHAgentCodecError) {
        if let failure { throw failure }
        if !buffer.isEmpty {
            let error = SSHAgentCodecError.truncatedFrame
            failure = error
            throw error
        }
    }

    private mutating func drain() throws(SSHAgentCodecError) -> [SSHAgentMessage] {
        var messages: [SSHAgentMessage] = []
        while buffer.count >= 4 {
            let declared = buffer[buffer.startIndex..<buffer.startIndex + 4]
                .reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
            guard declared <= Self.maximumFrameBytes else {
                throw .frameTooLarge(declaredBytes: declared)
            }
            guard declared >= 1 else {
                throw .emptyFrame
            }
            let frameLength = 4 + Int(declared)
            guard buffer.count >= frameLength else {
                break
            }
            let payload = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + frameLength)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + frameLength)
            messages.append(try Self.parse(payload))
        }
        return messages
    }

    private static func parse(_ payload: Data) throws(SSHAgentCodecError) -> SSHAgentMessage {
        let opcode = payload[payload.startIndex]
        switch opcode {
        case opcodeRequestIdentities:
            guard payload.count == 1 else {
                throw .malformedPayload(opcode: opcode)
            }
            return .requestIdentities
        case opcodeSignRequest:
            return try parseSignRequest(payload)
        default:
            throw .unknownOpcode(opcode)
        }
    }

    private static func parseSignRequest(_ payload: Data) throws(SSHAgentCodecError) -> SSHAgentMessage {
        var reader = SSHWireReader(payload.subdata(in: payload.startIndex + 1..<payload.endIndex))
        do {
            let keyBlob = try reader.readString()
            let data = try reader.readString()
            let flags = try reader.readUInt32()
            guard reader.isAtEnd, supportedAlgorithm(forKeyBlob: keyBlob) != nil else {
                throw SSHAgentCodecError.malformedPayload(opcode: opcodeSignRequest)
            }
            return .signRequest(keyBlob: keyBlob, data: data, flags: flags)
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? SSHAgentCodecError {
                throw error
            } else {
                throw .malformedPayload(opcode: opcodeSignRequest)
            }
        }
    }

    /// Returns the algorithm named by a key blob's leading type string, or nil
    /// when the blob is unparsable or names an algorithm we do not hold.
    public static func supportedAlgorithm(forKeyBlob blob: Data) -> KeyAlgorithm? {
        var reader = SSHWireReader(blob)
        guard let raw = try? reader.readString(),
              let name = String(data: raw, encoding: .utf8) else {
            return nil
        }
        return KeyAlgorithm(rawValue: name)
    }

    // MARK: - Encoding (agent → client)

    public static func frame(_ payload: Data) -> Data {
        var framed = Data()
        framed.appendUInt32(UInt32(payload.count))
        framed.append(payload)
        return framed
    }

    public static func encodeIdentitiesAnswer(_ identities: [SSHAgentIdentity]) -> Data {
        var payload = Data([opcodeIdentitiesAnswer])
        payload.appendUInt32(UInt32(identities.count))
        for identity in identities {
            payload.append(SSHWireFormat.encodeString(identity.blob))
            payload.append(SSHWireFormat.encodeString(Data(identity.comment.utf8)))
        }
        return frame(payload)
    }

    /// Wraps a raw signature as the agent expects it:
    /// `string( string(algorithm-name) || string(signature-blob) )` where the
    /// inner signature blob is the raw 64-byte value for Ed25519 and
    /// `string(r) || string(s)` mpints for ECDSA (RFC 4253 §6.6).
    public static func signatureBlob(for signature: KeySignature) throws -> Data {
        var inner = Data()
        inner.append(SSHWireFormat.encodeString(Data(signature.algorithm.rawValue.utf8)))
        switch signature.algorithm {
        case .ed25519:
            guard signature.rawRepresentation.count == 64 else {
                throw SSHAgentCodecError.malformedPayload(opcode: opcodeSignResponse)
            }
            inner.append(SSHWireFormat.encodeString(signature.rawRepresentation))
        case .ecdsaP256:
            guard signature.rawRepresentation.count == 64 else {
                throw SSHAgentCodecError.malformedPayload(opcode: opcodeSignResponse)
            }
            let r = signature.rawRepresentation.prefix(32)
            let s = signature.rawRepresentation.suffix(32)
            var ecdsaBlob = Data()
            ecdsaBlob.append(SSHWireFormat.encodeString(mpint(r)))
            ecdsaBlob.append(SSHWireFormat.encodeString(mpint(s)))
            inner.append(SSHWireFormat.encodeString(ecdsaBlob))
        }
        return inner
    }

    /// SSH mpint: minimal big-endian two's-complement — strip leading zero
    /// bytes, then prepend 0x00 when the high bit would read as negative.
    static func mpint(_ fixedWidth: Data.SubSequence) -> Data {
        let bytes = fixedWidth.drop(while: { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 {
            return Data([0x00]) + bytes
        }
        return Data(bytes)
    }

    public static func encodeSignResponse(signatureBlob: Data) -> Data {
        var payload = Data([opcodeSignResponse])
        payload.append(SSHWireFormat.encodeString(signatureBlob))
        return frame(payload)
    }

    public static func encodeFailure() -> Data {
        frame(Data([opcodeFailure]))
    }
}
