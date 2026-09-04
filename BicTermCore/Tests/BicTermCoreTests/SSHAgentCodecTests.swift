import CryptoKit
import Foundation
import XCTest
@testable import BicTermCore

final class SSHAgentCodecTests: XCTestCase {
    private func makeSignRequestFrame(
        keyBlob: Data? = nil,
        data: Data = Data("hello agent".utf8),
        flags: UInt32 = 0
    ) -> Data {
        let blob = keyBlob ?? SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        var payload = Data([SSHAgentCodec.opcodeSignRequest])
        payload.append(SSHWireFormat.encodeString(blob))
        payload.append(SSHWireFormat.encodeString(data))
        payload.appendUInt32(flags)
        return SSHAgentCodec.frame(payload)
    }

    // MARK: Round trips

    func testRequestIdentitiesDecodes() throws {
        var codec = SSHAgentCodec()
        let messages = try codec.feed(SSHAgentCodec.frame(Data([SSHAgentCodec.opcodeRequestIdentities])))
        XCTAssertEqual(messages, [.requestIdentities])
        try codec.finish()
    }

    func testSignRequestDecodesWithExactFields() throws {
        let key = Curve25519.Signing.PrivateKey()
        let blob = SSHWireFormat.ed25519PublicKeyBlob(rawPublicKey: key.publicKey.rawRepresentation)
        let data = Data("sign me".utf8)
        var codec = SSHAgentCodec()
        let messages = try codec.feed(makeSignRequestFrame(keyBlob: blob, data: data, flags: 0))
        XCTAssertEqual(messages, [.signRequest(keyBlob: blob, data: data, flags: 0)])
    }

    func testTwoFramesInOneReadDecodeAsTwoMessages() throws {
        var codec = SSHAgentCodec()
        let two = SSHAgentCodec.frame(Data([SSHAgentCodec.opcodeRequestIdentities]))
            + makeSignRequestFrame()
        let messages = try codec.feed(two)
        XCTAssertEqual(messages.count, 2)
        guard case .requestIdentities = messages[0], case .signRequest = messages[1] else {
            return XCTFail("unexpected messages: \(messages)")
        }
    }

    func testIdentitiesAnswerRoundTripsThroughWireShape() throws {
        let blob = SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        let encoded = SSHAgentCodec.encodeIdentitiesAnswer([
            SSHAgentIdentity(blob: blob, comment: "work key")
        ])
        var reader = SSHWireReader(encoded)
        let length = Int(try reader.readUInt32())
        XCTAssertEqual(length, encoded.count - 4)
        XCTAssertEqual(encoded[encoded.startIndex + 4], SSHAgentCodec.opcodeIdentitiesAnswer)
        var payload = SSHWireReader(encoded.subdata(in: encoded.startIndex + 5..<encoded.endIndex))
        XCTAssertEqual(try payload.readUInt32(), 1)
        XCTAssertEqual(try payload.readString(), blob)
        XCTAssertEqual(String(data: try payload.readString(), encoding: .utf8), "work key")
        XCTAssertTrue(payload.isAtEnd)
    }

    func testSignResponseWrapsEd25519SignatureBlob() throws {
        let raw = Data((0..<64).map { UInt8($0) })
        let blob = try SSHAgentCodec.signatureBlob(
            for: KeySignature(algorithm: .ed25519, rawRepresentation: raw)
        )
        var reader = SSHWireReader(blob)
        XCTAssertEqual(try reader.readString(), Data(KeyAlgorithm.ed25519.rawValue.utf8))
        XCTAssertEqual(try reader.readString(), raw)
        XCTAssertTrue(reader.isAtEnd)

        let framed = SSHAgentCodec.encodeSignResponse(signatureBlob: blob)
        XCTAssertEqual(framed[framed.startIndex + 4], SSHAgentCodec.opcodeSignResponse)
    }

    func testSignatureBlobEncodesECDSAAsMpintPair() throws {
        // r has its high bit set (needs 0x00 pad); s has a leading zero byte
        // (must be stripped to minimal width).
        var raw = Data([0x80]) + Data(repeating: 0x01, count: 31)
        raw.append(0x00)
        raw.append(contentsOf: repeatElement(UInt8(0x02), count: 31))
        let blob = try SSHAgentCodec.signatureBlob(
            for: KeySignature(algorithm: .ecdsaP256, rawRepresentation: raw)
        )
        var outer = SSHWireReader(blob)
        XCTAssertEqual(try outer.readString(), Data(KeyAlgorithm.ecdsaP256.rawValue.utf8))
        var inner = SSHWireReader(try outer.readString())
        let r = try inner.readString()
        let s = try inner.readString()
        XCTAssertEqual(r.count, 33)
        XCTAssertEqual(r.first, 0x00)
        XCTAssertEqual(r[r.startIndex + 1], 0x80)
        XCTAssertEqual(s.count, 31)
        XCTAssertEqual(s.first, 0x02)
        XCTAssertTrue(inner.isAtEnd)
        XCTAssertTrue(outer.isAtEnd)
    }

    // MARK: Torture

    func testFragmentedSignRequestDecodesOnce() throws {
        let frame = makeSignRequestFrame()
        XCTAssertGreaterThan(frame.count, 7)
        let cuts = (0..<7).map { frame.count * $0 / 7 } + [frame.count]
        var codec = SSHAgentCodec()
        var decoded: [SSHAgentMessage] = []
        for index in 0..<7 {
            decoded.append(contentsOf: try codec.feed(frame[cuts[index]..<cuts[index + 1]]))
        }
        XCTAssertEqual(decoded.count, 1)
        guard case .signRequest = decoded[0] else {
            return XCTFail("expected one signRequest, got \(decoded)")
        }
        try codec.finish()
    }

    func testTruncatedLengthPrefixThrowsOnFinish() throws {
        var codec = SSHAgentCodec()
        XCTAssertEqual(try codec.feed(Data([0x00, 0x00])), [])
        XCTAssertThrowsError(try codec.finish()) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .truncatedFrame)
        }
    }

    func testTruncatedPayloadThrowsOnFinish() throws {
        var codec = SSHAgentCodec()
        var partial = Data()
        partial.appendUInt32(64)
        partial.append(SSHAgentCodec.opcodeRequestIdentities)
        XCTAssertEqual(try codec.feed(partial), [])
        XCTAssertThrowsError(try codec.finish()) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .truncatedFrame)
        }
    }

    func testOneGigabyteDeclaredLengthRejected() throws {
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(Data([0x40, 0x00, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .frameTooLarge(declaredBytes: 0x4000_0000))
        }
    }

    func testDeclaredLengthExactlyAtCapIsAccepted() throws {
        var codec = SSHAgentCodec()
        XCTAssertEqual(try codec.feed(Data([0x00, 0x04, 0x00, 0x00])), [])
    }

    func testUnknownOpcodeRejectedAndStreamTerminates() throws {
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(SSHAgentCodec.frame(Data([0xFF])))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .unknownOpcode(0xFF))
        }
        // Terminal: subsequent feeds rethrow, never resynchronize.
        XCTAssertThrowsError(try codec.feed(SSHAgentCodec.frame(Data([SSHAgentCodec.opcodeRequestIdentities])))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .unknownOpcode(0xFF))
        }
    }

    func testKeyAddOpcodeRejected() throws {
        // SSH_AGENTC_ADD_IDENTITY (17): this agent is read-only.
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(SSHAgentCodec.frame(Data([17])))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .unknownOpcode(17))
        }
    }

    func testZeroLengthFrameRejected() throws {
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .emptyFrame)
        }
    }

    func testSignRequestWithTruncatedPayloadRejected() throws {
        // Frame length is honest, but the payload's inner string overruns.
        var payload = Data([SSHAgentCodec.opcodeSignRequest])
        payload.appendUInt32(4096)
        payload.append(Data("short".utf8))
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(SSHAgentCodec.frame(payload))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .malformedPayload(opcode: 13))
        }
    }

    func testSignRequestWithUnsupportedKeyAlgorithmRejected() throws {
        let rsaBlob = SSHWireFormat.encodeString(Data("ssh-rsa".utf8))
            + SSHWireFormat.encodeString(Data("n".utf8))
            + SSHWireFormat.encodeString(Data("e".utf8))
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(makeSignRequestFrame(keyBlob: rsaBlob))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .malformedPayload(opcode: 13))
        }
    }

    func testSignRequestWithTrailingGarbageRejected() throws {
        let blob = SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        var payload = Data([SSHAgentCodec.opcodeSignRequest])
        payload.append(SSHWireFormat.encodeString(blob))
        payload.append(SSHWireFormat.encodeString(Data("d".utf8)))
        payload.appendUInt32(0)
        payload.append(0xAA)
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(SSHAgentCodec.frame(payload))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .malformedPayload(opcode: 13))
        }
    }

    func testRequestIdentitiesWithPayloadRejected() throws {
        var codec = SSHAgentCodec()
        XCTAssertThrowsError(try codec.feed(SSHAgentCodec.frame(Data([11, 0x00])))) { error in
            XCTAssertEqual(error as? SSHAgentCodecError, .malformedPayload(opcode: 11))
        }
    }
}
