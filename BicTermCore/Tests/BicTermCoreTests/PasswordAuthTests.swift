import Foundation
import CryptoKit
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import Security
import XCTest
@testable import BicTermCore

// MARK: - Test doubles

/// In-memory ``PasswordStoring`` fake. Lets transport/editor tests run
/// hermetically without the Keychain entitlement gap of SPM simulator bundles.
actor InMemoryPasswordStore: PasswordStoring {
    private var storage: [String: String]

    init(_ initial: [String: String] = [:]) {
        storage = initial
    }

    func password(for keychainTag: String) async throws(PasswordStoreError) -> String? {
        storage[keychainTag]
    }

    func save(_ password: String, for keychainTag: String) async throws(PasswordStoreError) {
        storage[keychainTag] = password
    }

    func deletePassword(for keychainTag: String) async throws(PasswordStoreError) {
        storage.removeValue(forKey: keychainTag)
    }
}

/// Key provider that always fails: proves the password path never touches
/// key material providers (and vice versa that key sessions never fall back
/// to passwords).
struct NoKeyProvider: SSHAuthenticationKeyProvider {
    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        throw KeyRepositoryError.keyNotFound
    }
}

actor RecordingPasswordPrompt: SSHPasswordPrompting {
    let answer: String?
    let store: (any PasswordStoring)?
    private(set) var requests: [SSHPasswordRequest] = []

    init(answer: String?, store: (any PasswordStoring)? = nil) {
        self.answer = answer
        self.store = store
    }

    func promptForPassword(_ request: SSHPasswordRequest) async -> String? {
        requests.append(request)
        if let answer, let tag = request.saveTag {
            try? await store?.save(answer, for: tag)
        }
        return answer
    }
}

private actor PoolKeyProvider: SSHAuthenticationKeyProvider {
    let keys: [String: NIOSSHPrivateKey]
    let biometricFailure: Bool
    private(set) var references: [String] = []
    private(set) var reasons: [String] = []

    init(keys: [String: NIOSSHPrivateKey] = [:], biometricFailure: Bool = false) {
        self.keys = keys
        self.biometricFailure = biometricFailure
    }

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        references.append(reference)
        reasons.append(reason)
        if biometricFailure { throw KeyRepositoryError.keychain(errSecAuthFailed) }
        guard let key = keys[reference] else { throw KeyRepositoryError.keyNotFound }
        return key
    }
}

private enum CascadeTestTimeout: Error { case round, connection }

private final class CascadeAuthenticationObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let completion: EventLoopPromise<Void>

    init(completion: EventLoopPromise<Void>) { self.completion = completion }

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

private final class RecordingCascade: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let delegate: CascadeUserAuthenticationDelegate
    private let lock = NSLock()
    private var offers: [String] = []
    var offeredMethods: [String] { lock.withLock { offers } }

    init(_ delegate: CascadeUserAuthenticationDelegate) { self.delegate = delegate }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let loop = nextChallengePromise.futureResult.eventLoop
        let round = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        let timeout = loop.scheduleTask(in: .seconds(10)) { round.fail(CascadeTestTimeout.round) }
        round.futureResult.whenComplete { result in
            timeout.cancel()
            if case .success(let offer) = result {
                switch offer?.offer {
                case .privateKey: self.lock.withLock { self.offers.append("key") }
                case .password: self.lock.withLock { self.offers.append("password") }
                default: break
                }
            }
            nextChallengePromise.completeWith(result)
        }
        delegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: round)
    }
}

// MARK: - Model, delegate, end-to-end, secret absence, log audit

final class PasswordAuthTests: XCTestCase {
    static let correctPassword = "correct-horse-7x-sentinel"

    // MARK: Model — AuthMethod Codable

    func testConnectionDefaultsToPublicKeyAuthWhenOmitted() throws {
        let connection = try SSHTestFixture.makeConnection()

        XCTAssertTrue(connection.offersKeys)
    }

    func testConnectionRoundTripsPasswordAuthMethod() throws {
        let hop = Hop(
            host: "hop.example.com",
            port: 2201,
            username: "hop-user",
            offersKeys: false,
            passwordTag: "keychain://passwords/hop-1"
        )
        let connection = try Connection(
            name: "password auth",
            type: .ssh,
            host: "ssh.example.com",
            port: 22,
            username: "fixture-user",
            offersKeys: false,
            passwordTag: "keychain://passwords/main",
            jumpChain: [hop]
        )

        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))

        XCTAssertEqual(decoded, connection)
        XCTAssertFalse(decoded.offersKeys)
        XCTAssertEqual(decoded.jumpChain.first?.offersKeys, false)
    }

    func testLegacyConnectionPayloadMissingAuthMethodDecodesAsPublicKey() throws {
        let legacy: [String: Any] = [
            "id": TestModels.connectionID.uuidString,
            "name": "Legacy Key Connection",
            "type": "ssh",
            "host": "legacy.example.com",
            "port": 22,
            "username": "legacy-user",
            "keyReference": "keychain://keys/main",
            "jumpChain": [[
                "host": "hop1.example.com",
                "port": 2201,
                "username": "hop-user",
                "keyReference": "keychain://keys/hop-1",
            ]],
            "protocolOptions": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try JSONDecoder().decode(Connection.self, from: data)

        XCTAssertTrue(decoded.offersKeys)
        XCTAssertEqual(decoded.jumpChain.first?.offersKeys, true)
    }

    func testHopDefaultsToPublicKeyAuthWhenOmitted() {
        let hop = TestModels.hop()

        XCTAssertTrue(hop.offersKeys)
    }

    func testUnknownAuthMethodFailsDecoding() throws {
        let payload: [String: Any] = [
            "host": "hop1.example.com",
            "port": 2201,
            "username": "hop-user",
            "keyReference": "keychain://keys/hop-1",
            "authMethod": "totally-unsupported",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder().decode(Hop.self, from: data))
    }

    func testAuthMethodIsSendableAndHashable() {
        requireSendable(AuthMethod.password)
        XCTAssertEqual(Set([AuthMethod.publickey, .publickey, .password]).count, 2)
    }

    // MARK: Delegate offer semantics

    func testOffersStoredPasswordExactlyOnce() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()
        let delegate = CascadeUserAuthenticationDelegate(
            host: "example.com", port: 22, username: "pwd-user", keyReferences: [], keyProvider: NoKeyProvider(),
            effectivePasswordTag: "stored", promptedPasswordTag: nil, canRemember: false,
            passwordStore: InMemoryPasswordStore(["stored": "hunter2-sentinel"]), prompt: nil
        )

        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        loop.execute { delegate.nextAuthenticationType(
            availableMethods: [.publicKey, .password],
            nextChallengePromise: first
        ) }
        let offer = try await first.futureResult.get()

        XCTAssertEqual(offer?.username, "pwd-user")
        guard case .password(let offered) = offer?.offer else {
            return XCTFail("expected a password offer, got \(String(describing: offer))")
        }
        XCTAssertEqual(offered.password, "hunter2-sentinel")

        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        loop.execute { delegate.nextAuthenticationType(
            availableMethods: [.publicKey, .password],
            nextChallengePromise: second
        ) }
        await assertThrowsSSHError(.authenticationFailed) {
            _ = try await second.futureResult.get()
        }
    }

    func testFailsTypedWhenServerDoesNotAdvertisePassword() async throws {
        let loop = EmbeddedEventLoop()
        let delegate = CascadeUserAuthenticationDelegate(
            host: "example.com", port: 22, username: "pwd-user", keyReferences: [], keyProvider: NoKeyProvider(),
            effectivePasswordTag: "stored", promptedPasswordTag: nil, canRemember: false,
            passwordStore: InMemoryPasswordStore(["stored": "hunter2-sentinel"]), prompt: nil
        )
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

        delegate.nextAuthenticationType(availableMethods: [.publicKey], nextChallengePromise: promise)

        await assertThrowsSSHError(.authenticationFailed) {
            _ = try await promise.futureResult.get()
        }
    }

    // MARK: End-to-end over the in-process loopback password server

    func testCascadeOffersKeyThenPasswordOnceAfterRejectionOrPartialSuccess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword)
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let delegate = CascadeUserAuthenticationDelegate(
            host: "hop.example.com", port: 2222, username: "hop-user", keyReferences: ["fixture"],
            keyProvider: StaticKeyProvider(key: key), effectivePasswordTag: nil, promptedPasswordTag: nil,
            canRemember: false, passwordStore: InMemoryPasswordStore(), prompt: prompt
        )
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        loop.execute { delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: first) }
        let keyOffer = try await first.futureResult.get()
        guard case .privateKey = keyOffer?.offer else { return XCTFail("Expected key first") }
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        loop.execute { delegate.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: second) }
        let passwordOffer = try await second.futureResult.get()
        guard case .password = passwordOffer?.offer else { return XCTFail("Expected password second") }
        let third = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        loop.execute { delegate.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: third) }
        await assertThrowsSSHError(.authenticationFailed) { _ = try await third.futureResult.get() }
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.host, "hop.example.com")
        XCTAssertEqual(requests.first?.username, "hop-user")
        XCTAssertNil(requests.first?.saveTag)
    }

    func testCascadeDoesNotPromptWithoutAdvertisedPassword() async throws {
        let loop = EmbeddedEventLoop()
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword)
        let delegate = CascadeUserAuthenticationDelegate(
            host: "example.com", port: 22, username: "user", keyReferences: [], keyProvider: NoKeyProvider(),
            effectivePasswordTag: "tag", promptedPasswordTag: nil,
            canRemember: true, passwordStore: InMemoryPasswordStore(), prompt: prompt
        )
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey], nextChallengePromise: promise)
        await assertThrowsSSHError(.authenticationFailed) { _ = try await promise.futureResult.get() }
        let requests = await prompt.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInteractivePasswordIsRememberedAndReusedAcrossTransports() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let store = InMemoryPasswordStore()
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword, store: store)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let connection = try makePasswordConnection(port: port, username: "pwduser", tag: "interactive-tag")
        for _ in 0..<2 {
            let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: NoKeyProvider(),
                                         passwordStore: store, passwordPrompt: prompt)
            try await transport.connect(to: connection, cols: 80, rows: 24)
            await transport.close()
        }
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.saveTag, "interactive-tag")
        XCTAssertEqual(server.authenticatedConnectionCount, 2)
        await server.stop()
    }

    func testInteractiveCancelFailsTypedDuringHandshake() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let prompt = RecordingPasswordPrompt(answer: nil)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let transport = SSHTransport(hostKeyVerifier: verifier, passwordStore: InMemoryPasswordStore(), passwordPrompt: prompt)
        let connection = try makePasswordConnection(port: port, username: "pwduser", tag: "cancel-tag")
        await assertThrowsSSHError(.authenticationFailed) {
            try await transport.connect(to: connection, cols: 80, rows: 24)
        }
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(server.inboundConnectionCount, 1)
        XCTAssertEqual(server.authenticatedConnectionCount, 0)
        await transport.close()
        await server.stop()
    }

    func testKeyFallbackAndDualAuthReuseDerivedPasswordTag() async throws {
        for mode in [LoopbackPasswordSSHServer.KeyAuthentication.rejected, .requiresPassword] {
            let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword, keyAuthentication: mode)
            let port = try await server.start(port: 0)
            let verifier = try await pretrustingVerifier(for: server, port: port)
            let connection = try Connection(name: "dual", type: .ssh, host: "127.0.0.1", port: port,
                                            username: "pwduser", customKeys: ["fixture-ed25519"])
            let store = InMemoryPasswordStore()
            let prompt = RecordingPasswordPrompt(answer: Self.correctPassword, store: store)
            let key = try await SSHTestFixture.loadFixtureEd25519Key()
            for _ in 0..<2 {
                let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: StaticKeyProvider(key: key),
                                             passwordStore: store, passwordPrompt: prompt,
                                             metadataProvider: FixtureKeyMetadataProvider())
                try await transport.connect(to: connection, cols: 80, rows: 24)
                await transport.close()
            }
            let requests = await prompt.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.saveTag, connection.promptedPasswordTag)
            XCTAssertEqual(server.authenticatedConnectionCount, 2)
            await server.stop()
        }
    }

    func testJumpHopPromptsForItsOwnIdentityWithoutRemembering() async throws {
        let server = LoopbackPasswordSSHServer(username: "hop-user", password: Self.correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let dialer = NIOJumpDialer(hostKeyVerifier: verifier, authenticationKeyProvider: NoKeyProvider(),
                                  passwordStore: InMemoryPasswordStore(), passwordPrompt: prompt)
        let hop = try await dialer.connectTCP(to: JumpHopEndpoint(
            host: "127.0.0.1", port: port, username: "hop-user", offersKeys: false, passwordTag: "hop-password"
        ))
        let session = try await hop.openSession(cols: 80, rows: 24)
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.username, "hop-user")
        XCTAssertEqual(requests.first?.port, port)
        XCTAssertNil(requests.first?.saveTag)
        await session.close()
        await hop.close()
        await server.stop()
    }

    func testJumpDestinationUsesDerivedTagAfterKeyRejection() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword, keyAuthentication: .rejected)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let hostKey = try SSHTestFixture.hostPublicKey("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        try await verifier.trust(host: "127.0.0.1", port: 12222, key: hostKey.blob, algorithm: hostKey.algorithm)
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let store = InMemoryPasswordStore()
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword, store: store)
        let builder = JumpChainBuilder(hostKeyVerifier: verifier, authenticationKeyProvider: StaticKeyProvider(key: key),
                                       passwordStore: store, passwordPrompt: prompt,
                                       metadataProvider: FixtureKeyMetadataProvider(references: ["fixture"]))
        let connection = try Connection(name: "jump-password", type: .ssh, host: "127.0.0.1", port: port,
                                        username: "pwduser", customKeys: ["fixture"], jumpChain: [
                                            Hop(host: "127.0.0.1", port: 12222, username: SSHTestFixture.username, customKeys: ["fixture"])
                                        ])
        let transport = try await builder.build(connection: connection, cols: 80, rows: 24)
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.saveTag, connection.promptedPasswordTag)
        XCTAssertEqual(requests.first?.port, port)
        await transport.close()
        await server.stop()
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

    private func makePasswordConnection(port: Int, username: String, tag: String) throws -> Connection {
        try Connection(
            name: "password-fixture",
            type: .ssh,
            host: "127.0.0.1",
            port: port,
            username: username,
            offersKeys: false,
            passwordTag: tag
        )
    }

    func testPasswordConnectSendsAndReceivesThroughLoopbackServer() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let store = InMemoryPasswordStore(["pwd-tag": Self.correctPassword])
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: store
        )
        let connection = try makePasswordConnection(port: port, username: "pwduser", tag: "pwd-tag")

        try await transport.connect(to: connection, cols: 80, rows: 24)

        let sink = SSHOutputSink()
        let collector = await startCollecting(from: transport, into: sink)
        defer { collector.cancel() }

        let greeted = await waitForContent(sink: sink, marker: LoopbackPasswordSSHServer.greeting, timeoutMilliseconds: 15000)
        XCTAssertTrue(greeted, "password session should deliver the server greeting")

        try await transport.send(Data("echo-marker-42\n".utf8))
        let echoed = await waitForContent(sink: sink, marker: "echo-marker-42", timeoutMilliseconds: 15000)
        XCTAssertTrue(echoed, "password session should echo input back")

        let authCount = server.authenticatedConnectionCount
        XCTAssertEqual(authCount, 1)
        await transport.close()
        await server.stop()
    }

    func testWrongPasswordSurfacesTypedAuthenticationFailed() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let store = InMemoryPasswordStore(["pwd-tag": "definitely-wrong"])
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: store
        )
        let connection = try makePasswordConnection(port: port, username: "pwduser", tag: "pwd-tag")

        await assertThrowsSSHError(.authenticationFailed) {
            try await transport.connect(to: connection, cols: 80, rows: 24)
        }
        let authCount = server.authenticatedConnectionCount
        XCTAssertEqual(authCount, 0)
        await transport.close()
        await server.stop()
    }

    func testCascadeSecondKeyAcceptedOverLoopback() async throws {
        let first = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let second = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let components = String(openSSHPublicKey: second.publicKey).split(separator: " ")
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        let provider = PoolKeyProvider(keys: ["first": first, "second": second])
        let prompt = RecordingPasswordPrompt(answer: nil)
        try await exerciseCascade(policy: .acceptedPublicKeys([blob]), references: ["first", "second"],
                                  provider: provider, prompt: prompt, expectedOffers: ["key", "key"])
        let references = await provider.references
        let reasons = await provider.reasons
        let requests = await prompt.requests
        XCTAssertEqual(references, ["first", "second"])
        XCTAssertEqual(reasons, Array(repeating: "Authenticate to 127.0.0.1", count: 2))
        XCTAssertTrue(requests.isEmpty)
    }

    func testCascadeAllKeysRejectedThenStoredPasswordAcceptedExactlyOnce() async throws {
        let provider = PoolKeyProvider(keys: [
            "first": NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()),
            "second": NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()),
        ])
        let prompt = RecordingPasswordPrompt(answer: nil)
        try await exerciseCascade(policy: .rejected, references: ["first", "second"], provider: provider,
                                  effectiveTag: "saved", promptedTag: "derived",
                                  store: InMemoryPasswordStore(["saved": Self.correctPassword, "derived": "wrong"]),
                                  prompt: prompt, expectedOffers: ["key", "key", "password"])
        let references = await provider.references
        let requests = await prompt.requests
        XCTAssertEqual(references, ["first", "second"])
        XCTAssertTrue(requests.isEmpty)
    }

    func testCascadeEmptyKeyListUsesOnlyPassword() async throws {
        let provider = PoolKeyProvider()
        try await exerciseCascade(policy: .rejected, references: [], provider: provider,
                                  promptedTag: "derived", store: InMemoryPasswordStore(["derived": Self.correctPassword]),
                                  expectedOffers: ["password"])
        let references = await provider.references
        XCTAssertTrue(references.isEmpty)
    }

    func testCascadeExhaustionFailsTypedWithinTimeout() async throws {
        let provider = PoolKeyProvider(keys: ["key": NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())])
        try await exerciseCascade(policy: .rejected, references: ["key"], provider: provider,
                                  effectiveTag: "wrong", store: InMemoryPasswordStore(["wrong": "not-accepted"]),
                                  expectedOffers: ["key", "password"], shouldAuthenticate: false)
    }

    func testCascadeBiometricResolutionFailureIsTypedDuringAuthentication() async throws {
        let provider = PoolKeyProvider(biometricFailure: true)
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword)
        try await exerciseCascade(policy: .rejected, references: ["biometric", "unused"], provider: provider,
                                  prompt: prompt, expectedOffers: [], shouldAuthenticate: false)
        let references = await provider.references
        let requests = await prompt.requests
        XCTAssertEqual(references, ["biometric"])
        XCTAssertTrue(requests.isEmpty)
    }

    func testCascadeMissingStoredPasswordFallsThroughToPrompt() async throws {
        let prompt = RecordingPasswordPrompt(answer: Self.correctPassword)
        try await exerciseCascade(policy: .disabled, references: [], provider: NoKeyProvider(),
                                  effectiveTag: "missing", promptedTag: "derived",
                                  store: InMemoryPasswordStore(["derived": "must-not-be-used"]),
                                  prompt: prompt, expectedOffers: ["password"])
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.saveTag, "missing")
    }

    func testCascadeHeadlessMissingStoredPasswordFailsTypedDuringAuthentication() async throws {
        try await exerciseCascade(policy: .disabled, references: [], provider: NoKeyProvider(),
                                  effectiveTag: "missing", expectedOffers: [], shouldAuthenticate: false)
    }

    private func exerciseCascade(
        policy: LoopbackPasswordSSHServer.KeyAuthentication,
        references: [String], provider: any SSHAuthenticationKeyProvider,
        effectiveTag: String? = nil, promptedTag: String? = nil,
        store: any PasswordStoring = InMemoryPasswordStore(), prompt: (any SSHPasswordPrompting)? = nil,
        expectedOffers: [String], shouldAuthenticate: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword, keyAuthentication: policy)
        let port = try await server.start(port: 0)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let cascade = RecordingCascade(CascadeUserAuthenticationDelegate(
            host: "127.0.0.1", port: port, username: "pwduser", keyReferences: references, keyProvider: provider,
            effectivePasswordTag: effectiveTag, promptedPasswordTag: promptedTag, canRemember: true,
            passwordStore: store, prompt: prompt
        ))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let completion = loop.makePromise(of: Void.self)
        let timeout = loop.scheduleTask(in: .seconds(30)) {
            completion.fail(CascadeTestTimeout.connection)
        }
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .client(SSHClientPipelineFactory.makeConfiguration(
                            userAuthDelegate: cascade,
                            serverAuthDelegate: VerifyingHostKeyDelegate(host: "127.0.0.1", port: port, verifier: verifier)
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: SSHClientPipelineFactory.rejectAllInboundChildChannels
                    ))
                    try channel.pipeline.syncOperations.addHandler(cascade.delegate)
                    try channel.pipeline.syncOperations.addHandler(CascadeAuthenticationObserver(completion: completion))
                }
            }
        var channel: (any Channel)?
        do {
            channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
            try await completion.futureResult.get()
            XCTAssertTrue(shouldAuthenticate, "Expected typed authentication failure", file: file, line: line)
        } catch {
            XCTAssertFalse(shouldAuthenticate, "Unexpected connect failure: \(error)", file: file, line: line)
            XCTAssertEqual(error as? SSHTransportError, .authenticationFailed, "Must fail typed, not time out: \(error)", file: file, line: line)
        }
        timeout.cancel()
        completion.fail(SSHTransportError.unreachable)
        if let channel { try? await channel.close().get() }
        XCTAssertEqual(cascade.offeredMethods, expectedOffers, file: file, line: line)
        XCTAssertEqual(server.inboundConnectionCount, 1, "Resolution happens after dialing", file: file, line: line)
        XCTAssertEqual(server.authenticatedConnectionCount, shouldAuthenticate ? 1 : 0, file: file, line: line)
        await server.stop()
        try await group.shutdownGracefully()
    }

    func testKeyAuthPathUntouchedWhenAuthMethodIsPublicKey() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: Self.correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        // The store DOES hold the password under this reference — if the key
        // path silently fell back to password auth the connection would
        // succeed and this assertion would invert.
        let store = InMemoryPasswordStore(["some-ref": Self.correctPassword])
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: NoKeyProvider(),
            passwordStore: store
        )
        let connection = try Connection(
            name: "key-fixture",
            type: .ssh,
            host: "127.0.0.1",
            port: port,
            username: "pwduser",
            customKeys: ["some-ref"]
        )

        await assertThrowsSSHError(.authenticationFailed) {
            try await transport.connect(to: connection, cols: 80, rows: 24)
        }
        let authCount = server.authenticatedConnectionCount
        XCTAssertEqual(authCount, 0)
        await transport.close()
        await server.stop()
    }

    // MARK: Secret absence (encoded payloads)

    func testPasswordAuthConnectionAndHopEncodingContainsNoSecrets() throws {
        let privateKey = try SecretAbsenceAssertions.fixturePrivateKeyData()
        let sentinel = "s3cret-password-sentinel-never-encoded"
        let hop = Hop(
            host: "hop.example.com",
            port: 2201,
            username: "hop-user",
            offersKeys: false,
            passwordTag: "keychain://passwords/hop-1"
        )
        let connection = try Connection(
            name: "password auth",
            type: .ssh,
            host: "ssh.example.com",
            port: 22,
            username: "fixture-user",
            offersKeys: false,
            passwordTag: "keychain://passwords/main",
            jumpChain: [hop]
        )
        let encoded = [
            try JSONEncoder().encode(connection),
            try JSONEncoder().encode(hop),
        ]

        let findings = try SecretAbsenceAssertions.findings(
            in: encoded,
            privateKeyData: privateKey,
            passwordSentinels: [sentinel]
        )

        XCTAssertEqual(findings, [], "Encoded password-auth state leaked secrets: \(findings)")
    }

    func testSecretScannerDetectsPasswordSentinelPositiveControl() throws {
        let privateKey = try SecretAbsenceAssertions.fixturePrivateKeyData()
        let sentinel = "s3cret-password-sentinel-never-encoded"
        let planted: [String: Any] = ["nested": ["note": "the password is \(sentinel)"]]
        let encoded = try JSONSerialization.data(withJSONObject: planted)

        let findings = try SecretAbsenceAssertions.findings(
            in: [encoded],
            privateKeyData: privateKey,
            passwordSentinels: [sentinel]
        )

        XCTAssertTrue(findings.contains { $0.reason == "password text" }, "scanner must catch planted password text")
    }

    // MARK: Log audit (static source guard)

    func testNoCoreLogLineReferencesPasswordIdentifiers() throws {
        let sourcesRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BicTermCore")

        var findings: [String] = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard Self.isLogLine(line), Self.mentionsPassword(line) else { continue }
                findings.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertEqual(findings, [], "log statements must never carry passwords: \(findings)")
    }

    func testLogAuditMatcherRecognizesPlantedPositiveControls() {
        let planted = [
            #"print("auth failed for password \(password)")"#,
            #"logger.debug("password=\(password)")"#,
            #"NSLog("got password %@")"#,
            #"logger.info("channel opened for user")"#,
            #"let password = readLine()"#,
        ]

        let flagged = planted.filter { Self.isLogLine($0) && Self.mentionsPassword($0) }

        XCTAssertEqual(flagged.count, 3, "matcher flags only log calls carrying password identifiers")
    }

    private static let logCallPattern = #"(print\s*\(|debugPrint\s*\(|NSLog\s*\(|os_log\s*\(|[Ll]ogger[.(])"#
    private static let passwordPattern = #"(?i)password"#

    private static func isLogLine(_ line: String) -> Bool {
        line.range(of: logCallPattern, options: .regularExpression) != nil
    }

    private static func mentionsPassword(_ line: String) -> Bool {
        line.range(of: passwordPattern, options: .regularExpression) != nil
    }

    private func requireSendable<Value: Sendable>(_: Value) {}
}

// MARK: - Keychain store (preflight-skips on SPM simulator bundles)

final class KeychainPasswordStoreTests: XCTestCase {
    private var service: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = "com.bicterm.tests.password-preflight.\(UUID().uuidString)"
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "preflight",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data("preflight".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("SPM simulator test bundle has no Data Protection Keychain entitlement")
        }
        guard status == errSecSuccess else {
            throw PasswordStoreError.keychain(status)
        }
        SecItemDelete(probe as CFDictionary)
    }

    override func tearDown() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
        super.tearDown()
    }

    func testSaveLoadRoundTrip() async throws {
        let store = KeychainPasswordStore(keychainService: service)
        let tag = "tag-\(UUID().uuidString)"

        try await store.save("correct-horse-7x", for: tag)
        let loaded = try await store.password(for: tag)

        XCTAssertEqual(loaded, "correct-horse-7x")
    }

    func testSaveOverwritesExistingEntry() async throws {
        let store = KeychainPasswordStore(keychainService: service)
        let tag = "tag-\(UUID().uuidString)"

        try await store.save("first", for: tag)
        try await store.save("second", for: tag)
        let loaded = try await store.password(for: tag)

        XCTAssertEqual(loaded, "second")
    }

    func testMissingTagReturnsNil() async throws {
        let store = KeychainPasswordStore(keychainService: service)

        let loaded = try await store.password(for: "missing-\(UUID().uuidString)")

        XCTAssertNil(loaded)
    }

    func testDeleteIsIdempotent() async throws {
        let store = KeychainPasswordStore(keychainService: service)
        let tag = "tag-\(UUID().uuidString)"

        try await store.save("temporary", for: tag)
        try await store.deletePassword(for: tag)
        try await store.deletePassword(for: tag)

        let loaded = try await store.password(for: tag)
        XCTAssertNil(loaded)
    }

    func testStoredItemUsesWhenUnlockedThisDeviceOnlyAccessibility() async throws {
        let store = KeychainPasswordStore(keychainService: service)
        let tag = "tag-\(UUID().uuidString)"
        try await store.save("accessibility-check", for: tag)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
            kSecUseDataProtectionKeychain as String: true,
        ]
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        let accessible = attributes[kSecAttrAccessible as String] as? String
        XCTAssertEqual(accessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
