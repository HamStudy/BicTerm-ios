import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import XCTest
@testable import BicTermCore

final class SSHTransportStaticGuardTests: XCTestCase {
    private func makeConfiguration() -> SSHClientConfiguration {
        SSHClientPipelineFactory.makeConfiguration(
            userAuthDelegate: SingleKeyUserAuthenticationDelegate(
                username: "guard",
                key: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
            ),
            serverAuthDelegate: VerifyingHostKeyDelegate(
                host: "127.0.0.1",
                port: 22,
                verifier: HostKeyVerifier(store: EphemeralHostKeyStore())
            )
        )
    }

    func testRejectAllInboundChildChannelInitializerFails() async throws {
        let channel = EmbeddedChannel(loop: EmbeddedEventLoop())
        defer { _ = try? channel.finish() }
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 8080)

        for type: SSHChannelType in [
            .session,
            .forwardedTCPIP(.init(listeningHost: "127.0.0.1", listeningPort: 8080, originatorAddress: address)),
            .directTCPIP(.init(targetHost: "127.0.0.1", targetPort: 22, originatorAddress: address)),
        ] {
            let future = SSHClientPipelineFactory.rejectAllInboundChildChannels(
                channel: channel,
                channelType: type
            )
            await assertThrowsSSHError(.channelDenied) {
                try await future.get()
            }
        }
    }

    func testNoGlobalRequestDelegateInstalledAndDefaultRejectsTCPForwarding() async throws {
        let configuration = makeConfiguration()
        let loop = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let handler = NIOSSHHandler(
            role: .client(configuration),
            allocator: ByteBufferAllocator(),
            inboundChildChannelInitializer: nil
        )
        let promise = loop.next().makePromise(of: GlobalRequest.TCPForwardingResponse.self)
        configuration.globalRequestDelegate.tcpForwardingRequest(
            .listen(host: "127.0.0.1", port: 8080),
            handler: handler,
            promise: promise
        )
        let response: GlobalRequest.TCPForwardingResponse?
        do {
            response = try await promise.futureResult.get()
        } catch {
            response = nil
            XCTAssertTrue(
                String(describing: error).contains("unsupportedGlobalRequest"),
                "default delegate must reject tcpip-forward, got: \(error)"
            )
        }
        XCTAssertNil(response, "default delegate must reject tcpip-forward")
        try await loop.shutdownGracefully()
    }

    func testUnconnectedTransportSurfacesTypedErrors() async throws {
        let transport = SSHTransport(hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()))

        await assertThrowsSSHError(.channelDenied) {
            try await transport.send(Data("x".utf8))
        }
        await assertThrowsSSHError(.channelDenied) {
            _ = try await transport.sessionChannelHandle()
        }
        await assertThrowsSSHError(.channelDenied) {
            _ = try await transport.openDirectTCPIPChannel(toHost: "127.0.0.1", port: 22)
        }

        await transport.resize(cols: 0, rows: 0)
        await transport.resize(cols: -1, rows: 24)
        await transport.resize(cols: 120, rows: 40)
        await transport.close()
    }

    func testConnectRejectsInvalidDimensions() async throws {
        let transport = SSHTransport(hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore()))
        let connection = try SSHTestFixture.makeConnection()
        await assertThrowsSSHError(.channelDenied) {
            try await transport.connect(to: connection, cols: 0, rows: 24)
        }
        await assertThrowsSSHError(.channelDenied) {
            try await transport.connect(to: connection, cols: 80, rows: -1)
        }
        await transport.close()
    }

    func testDefaultProviderThrowsForUnknownReference() async throws {
        let provider = DefaultSSHAuthenticationKeyProvider()
        do {
            _ = try await provider.authenticationPrivateKey(
                with: "definitely-missing-\(UUID().uuidString)",
                reason: "test"
            )
            XCTFail("unknown reference must not resolve a key")
        } catch {
            // Expected: keyNotFound from both stores.
        }
    }
}
