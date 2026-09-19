import Foundation
import XCTest
@testable import BicTermCore

/// Unit 6 (A): one `PasswordPromptCache` per bring-up turns N transports
/// dialing the same password destination into ONE interactive prompt and
/// pins the first answer — declines included — for the bring-up's life.
final class PasswordPromptCacheTests: XCTestCase {
    private let correctPassword = PasswordAuthTests.correctPassword

    func testSharedCachePromptsOnceAcrossSequentialTransports() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        // No store on the prompt: the second connect must reach the prompt
        // layer, where the cache — not the Keychain — supplies the answer.
        let prompt = RecordingPasswordPrompt(answer: correctPassword)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let connection = try makeConnection(port: port, tag: "cache-tag")
        let cached = PasswordPromptCache().wrapping(prompt)
        for _ in 0..<2 {
            let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: NoKeyProvider(),
                                         passwordStore: InMemoryPasswordStore(), passwordPrompt: cached)
            try await transport.connect(to: connection, cols: 80, rows: 24)
            await transport.close()
        }
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.saveTag, "cache-tag")
        XCTAssertEqual(server.authenticatedConnectionCount, 2)
        await server.stop()
    }

    func testDistinctTagsPromptIndividually() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let prompt = RecordingPasswordPrompt(answer: correctPassword)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let cached = PasswordPromptCache().wrapping(prompt)
        for tag in ["cache-tag-a", "cache-tag-b"] {
            let connection = try makeConnection(port: port, tag: tag)
            let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: NoKeyProvider(),
                                         passwordStore: InMemoryPasswordStore(), passwordPrompt: cached)
            try await transport.connect(to: connection, cols: 80, rows: 24)
            await transport.close()
        }
        let saveTags = await prompt.requests.map(\.saveTag)
        XCTAssertEqual(saveTags, ["cache-tag-a", "cache-tag-b"])
        await server.stop()
    }

    func testDeclineIsCachedForTheBringUp() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let prompt = RecordingPasswordPrompt(answer: nil)
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let connection = try makeConnection(port: port, tag: "decline-tag")
        let cached = PasswordPromptCache().wrapping(prompt)
        for _ in 0..<2 {
            let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: NoKeyProvider(),
                                         passwordStore: InMemoryPasswordStore(), passwordPrompt: cached)
            await assertThrowsSSHError(.authenticationFailed) {
                try await transport.connect(to: connection, cols: 80, rows: 24)
            }
            await transport.close()
        }
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(server.authenticatedConnectionCount, 0)
        await server.stop()
    }

    func testWrongAnswerIsCachedNotRetried() async throws {
        let server = LoopbackPasswordSSHServer(username: "pwduser", password: correctPassword)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let prompt = RecordingPasswordPrompt(answer: "not-the-password")
        let verifier = try await pretrustingVerifier(for: server, port: port)
        let connection = try makeConnection(port: port, tag: "wrong-tag")
        let cached = PasswordPromptCache().wrapping(prompt)
        for _ in 0..<2 {
            let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: NoKeyProvider(),
                                         passwordStore: InMemoryPasswordStore(), passwordPrompt: cached)
            await assertThrowsSSHError(.authenticationFailed) {
                try await transport.connect(to: connection, cols: 80, rows: 24)
            }
            await transport.close()
        }
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(server.authenticatedConnectionCount, 0)
        await server.stop()
    }

    func testConcurrentPromptsCoalesceToOneUnderlyingPrompt() async throws {
        let prompt = SlowPrompt()
        let wrapped = try XCTUnwrap(PasswordPromptCache().wrapping(prompt))
        let request = SSHPasswordRequest(host: "host", port: 22, username: "user", sceneID: nil, saveTag: "t")
        let answers = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { await wrapped.promptForPassword(request) }
            }
            var collected: [String?] = []
            for await answer in group { collected.append(answer) }
            return collected
        }
        XCTAssertEqual(answers.count, 8)
        XCTAssertTrue(answers.allSatisfy { $0 == SlowPrompt.answer })
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFallbackKeyUsesDestinationIdentityWhenNoTag() async throws {
        let prompt = RecordingPasswordPrompt(answer: correctPassword)
        let wrapped = try XCTUnwrap(PasswordPromptCache().wrapping(prompt))
        func request(_ username: String) -> SSHPasswordRequest {
            SSHPasswordRequest(host: "host", port: 22, username: username, sceneID: nil, saveTag: nil)
        }
        _ = await wrapped.promptForPassword(request("alice"))
        _ = await wrapped.promptForPassword(request("alice"))
        _ = await wrapped.promptForPassword(request("bob"))
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testWrappingNilStaysNil() {
        XCTAssertNil(PasswordPromptCache().wrapping(nil))
    }

    // MARK: - Helpers

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

    private func makeConnection(port: Int, tag: String) throws -> Connection {
        try Connection(
            name: "cache-fixture",
            type: .ssh,
            host: "127.0.0.1",
            port: port,
            username: "pwduser",
            offersKeys: false,
            passwordTag: tag
        )
    }
}

private actor SlowPrompt: SSHPasswordPrompting {
    static let answer = "slow-pw"
    private(set) var requests: [SSHPasswordRequest] = []

    func promptForPassword(_ request: SSHPasswordRequest) async -> String? {
        requests.append(request)
        try? await Task.sleep(for: .milliseconds(250))
        return Self.answer
    }
}
