import Foundation
import NIOCore
import XCTest
@testable import BicTermCore

private enum JumpHandshakeTimeout: Error { case expired }

private struct GatedJumpMetadata: SSHKeyMetadataProviding {
    let entered: EventLoopPromise<Void>
    let release: EventLoopPromise<Void>

    func availableKeys() async throws -> [KeyMetadata] {
        entered.succeed(())
        try await release.futureResult.get()
        return try await FixtureKeyMetadataProvider(references: ["fixture"]).availableKeys()
    }
}

final class JumpHandshakeRegressionTests: XCTestCase {
    func testJumpDestinationPreservesGreetingWhileMetadataIsSuspended() async throws {
        let server = LoopbackPasswordSSHServer(
            username: "pwduser", password: PasswordAuthTests.correctPassword, keyAuthentication: .rejected
        )
        let port = try await server.start(port: 0)
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let store = InMemoryPasswordStore()
        let prompt = RecordingPasswordPrompt(answer: PasswordAuthTests.correctPassword, store: store)
        var hop: (any JumpHopConnection)?
        do {
            let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
            let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
            try await verifier.trust(host: "127.0.0.1", port: port, key: blob, algorithm: String(components[0]))
            let hostKey = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
            try await verifier.trust(host: "127.0.0.1", port: 12222, key: hostKey.blob, algorithm: hostKey.algorithm)
            let key = try await SSHTestFixture.loadFixtureEd25519Key()
            let dialer = NIOJumpDialer(
                hostKeyVerifier: verifier, authenticationKeyProvider: StaticKeyProvider(key: key),
                passwordStore: store, passwordPrompt: prompt,
                metadataProvider: FixtureKeyMetadataProvider(references: ["fixture"])
            )
            let first = try await dialer.connectTCP(to: JumpHopEndpoint(
                host: "127.0.0.1", port: 12222, username: SSHTestFixture.username, customKeys: ["fixture"]
            ))
            hop = first
            let parent = try XCTUnwrap(first as? NIOJumpHopConnection).channel
            let loop = parent.eventLoop
            let gate = GatedJumpMetadata(entered: loop.makePromise(), release: loop.makePromise())
            // Close the real connection, not just a waiting Swift task, so a lost
            // greeting fails queued NIO promises and teardown can finish.
            let deadline = loop.scheduleTask(in: .seconds(3)) {
                gate.entered.fail(JumpHandshakeTimeout.expired)
                gate.release.fail(JumpHandshakeTimeout.expired)
                parent.close(promise: nil)
            }
            defer {
                deadline.cancel()
                gate.entered.fail(JumpHandshakeTimeout.expired)
                gate.release.fail(JumpHandshakeTimeout.expired)
            }
            let link = try await first.openForward(toHost: "127.0.0.1", port: port)
            let channel = try XCTUnwrap(link as? NIOJumpRawLink).channel
            let initialAutoRead = try await channel.getOption(ChannelOptions.autoRead).get()
            XCTAssertFalse(initialAutoRead, "Forward must retain the SSH greeting before a nested consumer exists")
            var nestedDialer = dialer
            nestedDialer.metadataProvider = gate
            let connection = try Connection(name: "jump-regression", type: .ssh, host: "127.0.0.1", port: port,
                                            username: "pwduser", customKeys: ["fixture"])
            let endpoint = JumpHopEndpoint(
                host: connection.host, port: port, username: connection.username, customKeys: ["fixture"],
                promptedPasswordTag: connection.promptedPasswordTag, canRemember: true
            )
            let gatedDialer = nestedDialer
            let nested = Task { try await gatedDialer.connectNested(over: link, to: endpoint) }
            do {
                try await gate.entered.futureResult.get()
                let suspendedAutoRead = try await channel.getOption(ChannelOptions.autoRead).get()
                XCTAssertFalse(suspendedAutoRead, "Metadata suspension must not expose an empty inbound pipeline")
                // Deliberately widen the historical race window. Correctness is
                // asserted above without timing; this also exercises queued bytes.
                try await loop.scheduleTask(in: .milliseconds(100)) {}.futureResult.get()
                gate.release.succeed(())
                let destination = try await nested.value
                let resumedAutoRead = try await channel.getOption(ChannelOptions.autoRead).get()
                XCTAssertTrue(resumedAutoRead)
                let session = try await destination.openSession(cols: 80, rows: 24)
                let requests = await prompt.requests
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.saveTag, connection.promptedPasswordTag)
                XCTAssertEqual(requests.first?.port, port)
                XCTAssertEqual(server.authenticatedConnectionCount, 1)
                await session.close()
                await destination.close()
            } catch {
                gate.release.fail(error)
                try? await parent.close().get()
                _ = await nested.result
                throw error
            }
            await first.close()
            await server.stop()
        } catch {
            await hop?.close()
            await server.stop()
            throw error
        }
    }
}
