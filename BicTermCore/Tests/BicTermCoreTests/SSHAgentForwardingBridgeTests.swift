import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import BicTermCore

private actor InMemoryAgentKeyProvider: AgentKeyProvider {
    let key: Curve25519.Signing.PrivateKey
    let metadata: KeyMetadata
    private(set) var signCallCount = 0

    init() {
        let key = Curve25519.Signing.PrivateKey()
        let blob = SSHWireFormat.ed25519PublicKeyBlob(rawPublicKey: key.publicKey.rawRepresentation)
        self.key = key
        self.metadata = KeyMetadata(
            reference: "in-memory",
            label: "in-memory test key",
            algorithm: .ed25519,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: blob),
            publicKeyBlob: blob,
            requiresBiometry: false
        )
    }

    func publicKeys() async throws -> [KeyMetadata] { [metadata] }

    func sign(data: Data, publicKeyBlob: Data) async throws -> KeySignature {
        signCallCount += 1
        guard publicKeyBlob == metadata.publicKeyBlob else {
            throw KeyRepositoryError.keyNotFound
        }
        return KeySignature(algorithm: .ed25519, rawRepresentation: try key.signature(for: data))
    }
}

private final class BridgeTestPrompt: AgentAuthorizationPrompt, @unchecked Sendable {
    // @unchecked Sendable: test double; state guarded by NSLock.
    private let lock = NSLock()
    private var decision: AgentAuthorizationDecision
    private(set) var callCount = 0

    init(decision: AgentAuthorizationDecision) {
        self.decision = decision
    }

    func decide(_ request: AgentAuthorizationRequest) async -> AgentAuthorizationDecision {
        lock.withLock { callCount += 1 }
        return lock.withLock { decision }
    }
}

private struct InteractiveLock: LockStateProvider {
    let isInteractive: Bool
}

final class SSHAgentForwardingBridgeTests: XCTestCase {
    private func makeBridge(
        decision: AgentAuthorizationDecision = .allowOnce,
        interactive: Bool = true
    ) -> (AgentForwardingBridge, InMemoryAgentKeyProvider, BridgeTestPrompt) {
        let provider = InMemoryAgentKeyProvider()
        let prompt = BridgeTestPrompt(decision: decision)
        let authorizer = AgentAuthorizationService(prompt: prompt, lockState: InteractiveLock(isInteractive: interactive))
        let bridge = AgentForwardingBridge(
            keyProvider: provider,
            authorizer: authorizer,
            sessionID: "test-session",
            host: "127.0.0.1"
        )
        return (bridge, provider, prompt)
    }

    private func decodeSingleFrame(_ framed: Data) throws -> (opcode: UInt8, payload: Data) {
        var reader = SSHWireReader(framed)
        let length = Int(try reader.readUInt32())
        XCTAssertEqual(length, framed.count - 4)
        let payload = framed.subdata(in: framed.startIndex + 4..<framed.endIndex)
        return (payload[payload.startIndex], payload)
    }

    func testIdentitiesAnswerListsPublicKeyOnly() async throws {
        let (bridge, provider, _) = makeBridge()
        let response = await bridge.respond(to: .requestIdentities)
        let (opcode, payload) = try decodeSingleFrame(response)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeIdentitiesAnswer)
        var reader = SSHWireReader(payload.subdata(in: payload.startIndex + 1..<payload.endIndex))
        XCTAssertEqual(try reader.readUInt32(), 1)
        let blob = try reader.readString()
        let comment = try reader.readString()
        XCTAssertEqual(blob, provider.metadata.publicKeyBlob)
        XCTAssertEqual(String(decoding: comment, as: UTF8.self), "in-memory test key")
        XCTAssertTrue(reader.isAtEnd)
    }

    func testApprovedSignRequestProducesVerifiableSignature() async throws {
        let (bridge, provider, prompt) = makeBridge(decision: .allowOnce)
        let data = Data("remote payload".utf8)
        let response = await bridge.respond(
            to: .signRequest(keyBlob: provider.metadata.publicKeyBlob, data: data, flags: 0)
        )
        let (opcode, payload) = try decodeSingleFrame(response)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeSignResponse)
        var reader = SSHWireReader(payload.subdata(in: payload.startIndex + 1..<payload.endIndex))
        var sigBlob = SSHWireReader(try reader.readString())
        XCTAssertEqual(try sigBlob.readString(), Data(KeyAlgorithm.ed25519.rawValue.utf8))
        let rawSignature = try sigBlob.readString()
        XCTAssertEqual(rawSignature.count, 64)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: provider.key.publicKey.rawRepresentation)
        XCTAssertTrue(publicKey.isValidSignature(rawSignature, for: data))
        let signCalls = await provider.signCallCount
        XCTAssertEqual(signCalls, 1)
        XCTAssertEqual(prompt.callCount, 1)
    }

    func testGloballyDisabledKeyIsExcludedFromAgentIdentitiesAndSigning() async throws {
        let software = KeyMetadata(
            reference: "software", label: "Zulu", algorithm: .ed25519,
            fingerprint: "synthetic-software", publicKeyBlob: Data("software".utf8),
            requiresBiometry: false
        )
        let hardware = KeyMetadata(
            reference: "hardware", label: "Alpha", algorithm: .ecdsaP256,
            fingerprint: "synthetic-hardware", publicKeyBlob: Data("hardware".utf8),
            requiresBiometry: true
        )
        let disabled = KeyMetadata(
            reference: "disabled", label: "Disabled", algorithm: .ed25519,
            fingerprint: "synthetic-disabled", publicKeyBlob: Data("disabled".utf8),
            requiresBiometry: false, enabledByDefault: false
        )
        let provider = DefaultAgentKeyProvider(metadataLoader: { [software, disabled, hardware, software] })
        let keys = try await provider.publicKeys()
        XCTAssertEqual(keys, [hardware, software])
        let prompt = BridgeTestPrompt(decision: .allowOnce)
        let bridge = AgentForwardingBridge(
            keyProvider: provider,
            authorizer: AgentAuthorizationService(prompt: prompt, lockState: InteractiveLock(isInteractive: true)),
            sessionID: "enabled-pool", host: "127.0.0.1"
        )
        let identities = await bridge.respond(to: .requestIdentities)
        let (opcode, payload) = try decodeSingleFrame(identities)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeIdentitiesAnswer)
        var reader = SSHWireReader(payload.subdata(in: payload.startIndex + 1..<payload.endIndex))
        XCTAssertEqual(try reader.readUInt32(), 2)
        for metadata in [hardware, software] {
            XCTAssertEqual(try reader.readString(), metadata.publicKeyBlob)
            XCTAssertEqual(try reader.readString(), Data(metadata.label.utf8))
        }
        XCTAssertTrue(reader.isAtEnd)
        let response = await bridge.respond(
            to: .signRequest(keyBlob: disabled.publicKeyBlob, data: Data("x".utf8), flags: 0)
        )
        XCTAssertEqual(try decodeSingleFrame(response).opcode, SSHAgentCodec.opcodeFailure)
        XCTAssertEqual(prompt.callCount, 0)
        do {
            _ = try await provider.sign(data: Data("x".utf8), publicKeyBlob: disabled.publicKeyBlob)
            XCTFail("Disabled identities must not reach the signing stores")
        } catch {
            XCTAssertEqual(error as? KeyRepositoryError, .keyNotFound)
        }
    }

    func testDeniedSignRequestReturnsFailureAndNeverSigns() async throws {
        let (bridge, provider, _) = makeBridge(decision: .deny)
        let response = await bridge.respond(
            to: .signRequest(keyBlob: provider.metadata.publicKeyBlob, data: Data("x".utf8), flags: 0)
        )
        let (opcode, _) = try decodeSingleFrame(response)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeFailure)
        let signCalls = await provider.signCallCount
        XCTAssertEqual(signCalls, 0)
    }

    func testSignRequestForUnknownKeyFailsWithoutPromptingOrSigning() async throws {
        let (bridge, provider, prompt) = makeBridge()
        let foreignBlob = SSHWireFormat.ed25519PublicKeyBlob(
            rawPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        let response = await bridge.respond(
            to: .signRequest(keyBlob: foreignBlob, data: Data("x".utf8), flags: 0)
        )
        let (opcode, _) = try decodeSingleFrame(response)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeFailure)
        let signCalls = await provider.signCallCount
        XCTAssertEqual(signCalls, 0)
        XCTAssertEqual(prompt.callCount, 0)
    }

    func testBackgroundedBridgeDeniesWithoutPrompting() async throws {
        let (bridge, provider, prompt) = makeBridge(decision: .allowForSession, interactive: false)
        let response = await bridge.respond(
            to: .signRequest(keyBlob: provider.metadata.publicKeyBlob, data: Data("x".utf8), flags: 0)
        )
        let (opcode, _) = try decodeSingleFrame(response)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeFailure)
        XCTAssertEqual(prompt.callCount, 0)
        let signCalls = await provider.signCallCount
        XCTAssertEqual(signCalls, 0)
    }

    func testSessionApprovalCachesWithinSession() async throws {
        let (bridge, provider, prompt) = makeBridge(decision: .allowForSession)
        let blob = provider.metadata.publicKeyBlob
        _ = await bridge.respond(to: .signRequest(keyBlob: blob, data: Data("a".utf8), flags: 0))
        _ = await bridge.respond(to: .signRequest(keyBlob: blob, data: Data("b".utf8), flags: 0))
        XCTAssertEqual(prompt.callCount, 1)
        let signCalls = await provider.signCallCount
        XCTAssertEqual(signCalls, 2)
    }

    // MARK: Channel handler (NIOEmbedded)

    private func makeChannel(
        decision: AgentAuthorizationDecision = .allowOnce
    ) throws -> (EmbeddedChannel, AgentForwardingBridge, InMemoryAgentKeyProvider) {
        let (bridge, provider, _) = makeBridge(decision: decision)
        let channel = try EmbeddedChannel(handler: AgentChannelHandler(bridge: bridge))
        return (channel, bridge, provider)
    }

    private func writeInboundFrame(_ frame: Data, to channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    private func awaitOutboundFrame(
        from channel: EmbeddedChannel,
        timeoutMilliseconds: UInt64 = 5000
    ) async throws -> Data? {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        while clock.now < deadline {
            channel.embeddedEventLoop.run()
            if let outbound = try channel.readOutbound(as: SSHChannelData.self),
               case let .byteBuffer(buffer) = outbound.data {
                return Data(buffer.readableBytesView)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        channel.embeddedEventLoop.run()
        if let outbound = try channel.readOutbound(as: SSHChannelData.self),
           case let .byteBuffer(buffer) = outbound.data {
            return Data(buffer.readableBytesView)
        }
        return nil
    }

    func testFragmentedSignRequestThroughChannelRespondsOnce() async throws {
        let (channel, _, provider) = try makeChannel()
        let blob = await provider.metadata.publicKeyBlob
        var payload = Data([SSHAgentCodec.opcodeSignRequest])
        payload.append(SSHWireFormat.encodeString(blob))
        payload.append(SSHWireFormat.encodeString(Data("fragmented".utf8)))
        payload.appendUInt32(0)
        let frame = SSHAgentCodec.frame(payload)

        let cuts = (0..<7).map { frame.count * $0 / 7 } + [frame.count]
        for index in 0..<7 {
            try writeInboundFrame(Data(frame[cuts[index]..<cuts[index + 1]]), to: channel)
        }

        let maybeResponse = try await awaitOutboundFrame(from: channel)
        let response = try XCTUnwrap(maybeResponse)
        let (opcode, _) = try decodeSingleFrame(response)
        XCTAssertEqual(opcode, SSHAgentCodec.opcodeSignResponse)
        // Exactly one response for one (fragmented) request.
        channel.embeddedEventLoop.run()
        XCTAssertNil(try channel.readOutbound(as: SSHChannelData.self))
        try await channel.close()
    }

    func testMalformedFrameClosesChannel() async throws {
        let (channel, _, _) = try makeChannel()
        try writeInboundFrame(SSHAgentCodec.frame(Data([0xFF])), to: channel)
        XCTAssertFalse(channel.isActive)
    }

    func testRequestFloodIsBoundedAndChannelClosesAtCap() async throws {
        let (channel, _, provider) = try makeChannel(decision: .deny)
        let blob = await provider.metadata.publicKeyBlob
        var payload = Data([SSHAgentCodec.opcodeSignRequest])
        payload.append(SSHWireFormat.encodeString(blob))
        payload.append(SSHWireFormat.encodeString(Data("flood".utf8)))
        payload.appendUInt32(0)
        let frame = SSHAgentCodec.frame(payload)

        for _ in 0..<(AgentChannelHandler.maximumTotalRequests + 1) {
            // The channel closes at the cap; the final write may throw.
            try? writeInboundFrame(frame, to: channel)
        }
        XCTAssertFalse(channel.isActive)

        // Overflow beyond the 64-deep queue is answered with immediate
        // FAILURE frames, synchronously, before any actor hop completes:
        // exactly 1001 - 1 in flight - 64 queued.
        let expectedImmediateFailures =
            AgentChannelHandler.maximumTotalRequests - 1 - AgentChannelHandler.maximumQueuedRequests
        for _ in 0..<expectedImmediateFailures {
            let outbound = try XCTUnwrap(channel.readOutbound(as: SSHChannelData.self))
            guard case let .byteBuffer(buffer) = outbound.data else {
                return XCTFail("unexpected outbound payload")
            }
            let bytes = Data(buffer.readableBytesView)
            XCTAssertEqual(bytes[bytes.startIndex + 4], SSHAgentCodec.opcodeFailure)
        }

        // The in-flight and queued requests resolve (denied) once the loop
        // runs; every late response is a FAILURE too, and none exceed the cap.
        channel.embeddedEventLoop.run()
        try await Task.sleep(for: .milliseconds(200))
        channel.embeddedEventLoop.run()
        var lateResponses = 0
        while let outbound = try channel.readOutbound(as: SSHChannelData.self) {
            guard case let .byteBuffer(buffer) = outbound.data else { continue }
            let bytes = Data(buffer.readableBytesView)
            XCTAssertEqual(bytes[bytes.startIndex + 4], SSHAgentCodec.opcodeFailure)
            lateResponses += 1
        }
        XCTAssertLessThanOrEqual(lateResponses, 1 + AgentChannelHandler.maximumQueuedRequests)
    }
}
