import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import BicTermCore

/// Password-only client auth delegate for the raw-NIOSSH tests: offers the
/// fixture password exactly as the server expects it.
private struct StaticPasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
        ))
    }
}

/// Succeeds the promise on `UserAuthSuccessEvent`; fails it on pre-auth
/// errors or connection loss. After success, later failures are no-ops on
/// an already-completed promise.
private final class AuthSuccessObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let completion: EventLoopPromise<Void>

    init(completion: EventLoopPromise<Void>) {
        self.completion = completion
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { completion.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completion.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        completion.fail(SSHTransportError.unreachable)
        context.fireChannelInactive()
    }
}

/// Focused tests for the `LoopbackPasswordSSHServer` CoderSSHGW-emulation
/// fixtures: the per-connection session-channel budget
/// (`SessionChannelPolicy.lifetimeTotal`) and the minimal exec support.
///
/// The lifetime tests drive a RAW NIOSSH client rather than `SSHTransport`
/// for two reasons: the exact client-observed channel-open error is
/// assertable at that layer, and a second session channel can be opened on
/// the SAME connection after a clean close — something `SSHTransport`'s API
/// (one session per connection; `close()` tears down the TCP connection)
/// cannot express. The exec test rides the production
/// `SSHTransport.openExecChannel` path, which is what later connector tests
/// will exercise against this fixture.
final class DebugPasswordServerFixtureTests: XCTestCase {
    private static let username = "pwduser"

    // MARK: Session-channel lifetime policy

    func testLifetimeTotalOneRejectsSecondSessionChannelAfterCleanClose() async throws {
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword,
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let channel = try await connectAuthenticatedClient(group: group, port: port, verifier: verifier)
        defer { Task { try? await channel.close().get() } }

        // Session channel #1: opens, then closes CLEANLY (the full SSH
        // close handshake — the CoderSSHGW reproduction requires the first
        // channel to be gone before the second open).
        let first = try await openRawSessionChannel(on: channel)
        try await first.close().get()

        // Session channel #2 on the SAME connection: must be rejected.
        do {
            _ = try await openRawSessionChannel(on: channel)
            XCTFail("lifetimeTotal(1) must reject the second session channel open")
        } catch let error as NIOSSHError {
            // Exact client-observed value: the vendored NIOSSH server path
            // answers a failed inbound child-channel initializer with
            // SSH_MSG_CHANNEL_OPEN_FAILURE carrying reason code 2 and an
            // empty description (hardcoded in
            // SSHChildChannel.initializerFailed), which the client surfaces
            // as NIOSSHError.channelSetupRejected. The real gateway sends
            // reason code 1 ("workspace connections permit one session
            // channel"); the error CLASS matches, the payload is a
            // vendored-fork constant.
            XCTAssertEqual(error.type, .channelSetupRejected)
            XCTAssertEqual(String(describing: error), "NIOSSHError.channelSetupRejected: Reason: 2 ")
        } catch {
            XCTFail("expected NIOSSHError.channelSetupRejected, got \(error)")
        }
        XCTAssertEqual(server.authenticatedConnectionCount, 1)
        await server.stop()
    }

    func testUnlimitedDefaultPolicyAllowsSequentialSessionChannels() async throws {
        // Default init — no policy argument — pins that the default is
        // `.unlimited` (every pre-existing consumer relies on this).
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let channel = try await connectAuthenticatedClient(group: group, port: port, verifier: verifier)
        defer { Task { try? await channel.close().get() } }

        let first = try await openRawSessionChannel(on: channel)
        try await first.close().get()
        // The second sequential session channel on the same connection must
        // still succeed — regression guard for the counting policy.
        let second = try await openRawSessionChannel(on: channel)
        try await second.close().get()
        XCTAssertEqual(server.authenticatedConnectionCount, 1)
        await server.stop()
    }

    // MARK: Exec support

    func testExecRequestRoundTripsCannedStdoutAndExitStatus() async throws {
        let server = LoopbackPasswordSSHServer(
            username: Self.username, password: PasswordAuthTests.correctPassword
        )
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let store = InMemoryPasswordStore(["pwd-tag": PasswordAuthTests.correctPassword])
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: store
        )
        let connection = try Connection(
            name: "exec-fixture", type: .ssh, host: "127.0.0.1", port: port,
            username: Self.username, offersKeys: false, passwordTag: "pwd-tag"
        )
        try await transport.connect(to: connection, cols: 80, rows: 24)

        // Exec #1 rides a SECOND session channel next to the live shell —
        // default canned output.
        let first = try await transport.openExecChannel(command: "command -v herdr")
        let firstStdout = await drainStdout(first)
        XCTAssertEqual(firstStdout, LoopbackPasswordSSHServer.defaultExecResponse)
        let firstTermination = await first.termination()
        XCTAssertEqual(firstTermination, .exited(status: 0))

        // Exec #2: the canned response is live-settable — the shape later
        // connector tests need to point the herdr probe at this server.
        let probePath = "bpo:path=/home/pwduser/.local/bin/herdr\n"
        server.execResponse = probePath
        let second = try await transport.openExecChannel(command: "command -v herdr")
        let secondStdout = await drainStdout(second)
        XCTAssertEqual(secondStdout, probePath)
        let secondTermination = await second.termination()
        XCTAssertEqual(secondTermination, .exited(status: 0))

        await transport.close()
        await server.stop()
    }

    // MARK: Raw NIOSSH client helpers

    private func connectAuthenticatedClient(
        group: MultiThreadedEventLoopGroup,
        port: Int,
        verifier: HostKeyVerifier
    ) async throws -> any Channel {
        let loop = group.next()
        let completion = loop.makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .client(SSHClientPipelineFactory.makeConfiguration(
                            userAuthDelegate: StaticPasswordAuthDelegate(
                                username: Self.username, password: PasswordAuthTests.correctPassword
                            ),
                            serverAuthDelegate: VerifyingHostKeyDelegate(
                                host: "127.0.0.1", port: port, verifier: verifier
                            )
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: SSHClientPipelineFactory.rejectAllInboundChildChannels
                    ))
                    try channel.pipeline.syncOperations.addHandler(AuthSuccessObserver(completion: completion))
                }
            }
        let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
        try await completion.futureResult.get()
        return channel
    }

    /// Opens a session child channel on a live client connection — mirrors
    /// `SSHTransport.openChildChannel` (`createChannel` must run on the
    /// connection's EventLoop).
    private func openRawSessionChannel(on channel: any Channel) async throws -> any Channel {
        try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .session, nil)
            return promise.futureResult
        }.get()
    }

    private func pretrustingVerifier(
        for server: LoopbackPasswordSSHServer,
        port: Int
    ) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        try await verifier.trust(
            host: "127.0.0.1",
            port: port,
            key: blob,
            algorithm: String(components[0])
        )
        return verifier
    }

    /// Drains an exec stdout stream with a hard timeout, so a fixture bug
    /// fails the assertion instead of hanging the test.
    private func drainStdout(_ session: SSHExecSession) async -> String {
        let drained: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var data = Data()
                for await chunk in session.stdout {
                    data.append(chunk)
                }
                return String(decoding: data, as: UTF8.self)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return drained ?? ""
    }
}
