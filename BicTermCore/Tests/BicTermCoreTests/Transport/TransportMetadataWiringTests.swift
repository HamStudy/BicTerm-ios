import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

extension TransportAbstractionTests {
    func testDirectPathMetadataInjection() async throws { try await exerciseMetadataPath(.direct) }
    func testUDSPathMetadataInjection() async throws { try await exerciseMetadataPath(.uds) }
    func testFactoryDirectPathMetadataInjection() async throws { try await exerciseMetadataPath(.factoryDirect) }
    func testFactoryJumpPathMetadataInjection() async throws { try await exerciseMetadataPath(.factoryJump) }
    func testJumpHopMetadataInjection() async throws { try await exerciseMetadataPath(.hop) }
    func testJumpDestinationMetadataInjection() async throws { try await exerciseMetadataPath(.destination) }
    func testDirectHerdrMetadataInjection() async throws { try await exerciseMetadataPath(.herdrDirect) }
    func testJumpedHerdrMetadataInjection() async throws { try await exerciseMetadataPath(.herdrJump) }

    func testSameFactoryTwoConnectMetadataChange() async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let provider = RecordingKeyProvider(keys: ["first": key, "second": key])
        let metadata = MutableKeyMetadataProvider([wiringMetadata("first")])
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(), authenticationKeyProvider: provider,
            passwordStore: InMemoryPasswordStore(), metadataProvider: metadata
        )
        let connection = try Connection(name: "fresh-pool", type: .ssh, host: "127.0.0.1", port: 12222,
                                        username: SSHTestFixture.username)
        for reference in ["first", "second"] {
            await metadata.replace(with: [wiringMetadata(reference)])
            let transport = try factory.makeTransport(for: connection)
            do { try await transport.connect(to: connection, cols: 80, rows: 24) }
            catch { await transport.close(); throw error }
            await transport.close()
        }
        XCTAssertEqual(provider.calls.map(\.reference), ["first", "second"])
        let calls = await metadata.calls
        XCTAssertEqual(calls, 2)
    }

    func testEightKeyNoCapDownstream() async throws {
        try await exerciseLoopbackPool(count: 8, acceptLastKey: false)
    }

    func testEighthKeyOnlyLoopbackAccepts() async throws {
        try await exerciseLoopbackPool(count: 8, acceptLastKey: true)
    }

    func testDisabledCustomFilteredDownstream() async throws {
        try await exerciseLoopbackPool(count: 3, acceptLastKey: true, disabled: ["key-0", "key-1"])
    }

    func testOffersKeysFalseSkipsKeyRounds() async throws {
        try await exerciseLoopbackPool(count: 3, acceptLastKey: false, offersKeys: false)
    }

    private func exerciseLoopbackPool(
        count: Int, acceptLastKey: Bool, disabled: Set<String> = [], offersKeys: Bool = true
    ) async throws {
        let references = (0..<count).map { "key-\($0)" }
        let keys = Dictionary(uniqueKeysWithValues: references.map {
            ($0, NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()))
        })
        let last = try XCTUnwrap(keys[references[count - 1]])
        let components = String(openSSHPublicKey: last.publicKey).split(separator: " ")
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        let server = LoopbackPasswordSSHServer(
            username: "pool-user", password: "pool-password",
            keyAuthentication: acceptLastKey ? .acceptedPublicKeys([blob]) : .rejected
        )
        let port = try await server.start(port: 0)
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        let host = server.hostKeyOpenSSH.split(separator: " ")
        try await verifier.trust(host: "127.0.0.1", port: port,
                                 key: XCTUnwrap(Data(base64Encoded: String(host[1]))), algorithm: String(host[0]))
        let provider = RecordingKeyProvider(keys: keys)
        let metadata = MutableKeyMetadataProvider(references.reversed().map {
            wiringMetadata($0, enabled: !disabled.contains($0))
        })
        let transport = SSHTransport(
            hostKeyVerifier: verifier, authenticationKeyProvider: provider,
            passwordStore: InMemoryPasswordStore(acceptLastKey ? [:] : ["saved": "pool-password"]),
            metadataProvider: metadata
        )
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await transport.close()
        }
        defer { timeout.cancel() }
        let connection = try Connection(
            name: "loopback-pool", type: .ssh, host: "127.0.0.1", port: port, username: "pool-user",
            offersKeys: offersKeys, customKeys: Array(references.reversed()) + ["stale", "key-0"], passwordTag: "saved"
        )
        do { try await transport.connect(to: connection, cols: 80, rows: 24) }
        catch { await transport.close(); await server.stop(); throw error }
        XCTAssertEqual(provider.calls.map(\.reference), offersKeys ? references.filter { !disabled.contains($0) } : [])
        XCTAssertEqual(server.authenticatedConnectionCount, 1)
        let calls = await metadata.calls
        XCTAssertEqual(calls, 1)
        await transport.close()
        await server.stop()
    }
}
