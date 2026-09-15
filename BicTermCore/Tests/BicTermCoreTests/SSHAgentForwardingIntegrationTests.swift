import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

private actor FixtureAgentKeyProvider: AgentKeyProvider {
    let key: Curve25519.Signing.PrivateKey
    let metadata: KeyMetadata
    private(set) var signCallCount = 0

    init(privateKey: Curve25519.Signing.PrivateKey, publicKeyBlob: Data, comment: String) {
        self.key = privateKey
        self.metadata = KeyMetadata(
            reference: "fixture",
            label: comment,
            algorithm: .ed25519,
            fingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: publicKeyBlob),
            publicKeyBlob: publicKeyBlob,
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

private final class IntegrationPrompt: AgentAuthorizationPrompt, @unchecked Sendable {
    // @unchecked Sendable: test double; state guarded by NSLock.
    private let lock = NSLock()
    private let decision: AgentAuthorizationDecision
    private(set) var requests: [AgentAuthorizationRequest] = []

    init(decision: AgentAuthorizationDecision) {
        self.decision = decision
    }

    func decide(_ request: AgentAuthorizationRequest) async -> AgentAuthorizationDecision {
        lock.withLock { requests.append(request) }
        return decision
    }
}

private struct InteractiveTestLock: LockStateProvider {
    let isInteractive: Bool
}

final class SSHAgentForwardingIntegrationTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors {
            collector.cancel()
        }
        collectors = []
        try await super.tearDown()
    }

    private struct FixtureSession {
        let transport: SSHTransport
        let sink: SSHOutputSink
        let provider: FixtureAgentKeyProvider
        let prompt: IntegrationPrompt
        let publicKeyBlob: Data
        let privateKey: Curve25519.Signing.PrivateKey
    }

    private func makeSession(decision: AgentAuthorizationDecision) async throws -> FixtureSession {
        let keyURL = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519")
        let parsed = try await OpenSSHPrivateKeyParser().parse(Data(contentsOf: keyURL))
        let provider = FixtureAgentKeyProvider(
            privateKey: parsed.privateKey,
            publicKeyBlob: parsed.publicKeyBlob,
            comment: parsed.comment
        )
        let prompt = IntegrationPrompt(decision: decision)
        let authorizer = AgentAuthorizationService(
            prompt: prompt,
            lockState: InteractiveTestLock(isInteractive: true)
        )
        let bridge = AgentForwardingBridge(
            keyProvider: provider,
            authorizer: authorizer,
            sessionID: "agent-integration",
            host: SSHTestFixture.hop1Host
        )
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: NIOSSHPrivateKey(ed25519Key: parsed.privateKey)),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        await bridge.install(on: transport)
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        let sink = SSHOutputSink()
        collectors.append(await startCollecting(from: transport, into: sink))
        return FixtureSession(
            transport: transport,
            sink: sink,
            provider: provider,
            prompt: prompt,
            publicKeyBlob: parsed.publicKeyBlob,
            privateKey: parsed.privateKey
        )
    }

    private func quiesce(_ transport: SSHTransport, sink: SSHOutputSink) async throws {
        try await transport.send(Data(
            "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"
                .utf8
        ))
        let ready = await waitForContent(sink: sink, marker: "__READY__", timeoutMilliseconds: 8000)
        XCTAssertTrue(ready, "shell did not reach ready marker")
        await sink.reset()
    }

    private func runAgentClient(
        _ session: FixtureSession,
        subcommand: String
    ) async throws -> String {
        let scriptPath = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/agent/agent_client.py").path
        let pubPath = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519.pub").path
        let arguments: String
        switch subcommand {
        case "sign":
            arguments = "sign \(pubPath) bicterm-agent-sign-test"
        default:
            arguments = subcommand
        }
        try await session.transport.send(Data(
            "python3 \(scriptPath) \(arguments); printf 'AGENT''EXIT:%s\\n' $?\n".utf8
        ))
        let completed = await waitForContent(sink: session.sink, marker: "AGENTEXIT:", timeoutMilliseconds: 15000)
        if !completed {
            let soFar = String(decoding: await session.sink.snapshot(), as: UTF8.self)
            XCTFail("agent_client did not finish; output so far: \(soFar)")
            return ""
        }
        let output = String(decoding: await session.sink.snapshot(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        await session.sink.reset()
        return output
    }

    func testForwardedSignRequestWithApprovalVerifiesAgainstFixtureKey() async throws {
        let session = try await makeSession(decision: .allowOnce)
        defer { Task { await session.transport.close() } }
        try await quiesce(session.transport, sink: session.sink)

        let data = "bicterm-agent-sign-test"
        let output = try await runAgentClient(session, subcommand: "sign")

        guard let algorithmLine = output.linesContaining("algorithm:").first,
              let signatureLine = output.linesContaining("signature:").first else {
            return XCTFail("agent_client did not report a signature:\n\(output)")
        }
        XCTAssertTrue(algorithmLine.contains("ssh-ed25519"), "unexpected algorithm: \(algorithmLine)")
        let hex = signatureLine.replacingOccurrences(of: "signature:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSignature = try XCTUnwrap(Data(hexString: hex), "signature line was not hex: \(signatureLine)")
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: SSHWireFormat.ed25519RawPublicKey(from: session.publicKeyBlob)
        )
        XCTAssertTrue(publicKey.isValidSignature(rawSignature, for: Data(data.utf8)))
        let signCalls = await session.provider.signCallCount
        XCTAssertEqual(signCalls, 1)
        let requests = session.prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, "agent-integration")
        XCTAssertEqual(requests.first?.keyFingerprint, session.provider.metadata.fingerprint)
        XCTAssertEqual(requests.first?.publicKeyBlob, session.publicKeyBlob)
        XCTAssertTrue(output.contains("AGENTEXIT:0"), "agent_client failed:\n\(output)")
    }

    func testForwardedSignRequestDeniedSeesAgentFailure() async throws {
        let session = try await makeSession(decision: .deny)
        defer { Task { await session.transport.close() } }
        try await quiesce(session.transport, sink: session.sink)

        let output = try await runAgentClient(session, subcommand: "sign")

        XCTAssertTrue(output.contains("AGENTEXIT:1"), "denied sign should fail remotely:\n\(output)")
        XCTAssertTrue(output.contains("agent-client-error"), "expected agent failure message:\n\(output)")
        XCTAssertFalse(output.contains("signature:"), "denied request must not produce a signature:\n\(output)")
        let deniedSignCalls = await session.provider.signCallCount
        XCTAssertEqual(deniedSignCalls, 0)
    }

    func testForwardedIdentitiesListMatchesFixtureKey() async throws {
        let session = try await makeSession(decision: .deny)
        defer { Task { await session.transport.close() } }
        try await quiesce(session.transport, sink: session.sink)

        let output = try await runAgentClient(session, subcommand: "list")

        XCTAssertTrue(output.contains("AGENTEXIT:0"), "list failed:\n\(output)")
        XCTAssertTrue(output.contains("identities: 1"), "expected exactly one identity:\n\(output)")
        XCTAssertTrue(output.contains("type=ssh-ed25519"), "unexpected key type:\n\(output)")
        XCTAssertTrue(output.contains("blob_len=\(session.publicKeyBlob.count)"), "blob length mismatch:\n\(output)")
    }
}

extension String {
    fileprivate func linesContaining(_ marker: String) -> [String] {
        split(separator: "\n").map(String.init).filter { $0.contains(marker) }
    }
}

extension Data {
    fileprivate init?(hexString: String) {
        guard hexString.count % 2 == 0, !hexString.isEmpty else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
