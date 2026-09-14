import Foundation
import XCTest
@testable import BicTermCore

/// Abstraction-level proofs for the T11 keystone: the FakeTransport runs
/// the full lifecycle through the `any TerminalTransport` existential with
/// zero SSH types, the Sessions layer stays free of SSH internals, and
/// protocol resolution never silently downgrades.
final class TransportAbstractionTests: XCTestCase {
    private var collectors: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for collector in collectors { collector.cancel() }
        collectors = []
        try await super.tearDown()
    }

    private func makeSSHRegistry() async throws -> TransportRegistry {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        var registry = TransportRegistry()
        registry.register(
            .ssh,
            factory: SSHSessionTransportFactory(hostKeyVerifier: verifier)
        )
        return registry
    }

    func testFakeTransportPassesConformanceSuite() async throws {
        // Full lifecycle through the existential; this function references
        // no SSH-specific type at all.
        let transport: any TerminalTransport = FakeTransport(
            script: FakeTransport.Script(greeting: Data("banner".utf8))
        )
        let sink = TransportTestSink()
        let stream = await transport.output
        collectors.append(Task {
            for await chunk in stream { await sink.append(chunk) }
            await sink.markFinished()
        })

        try await transport.connect(to: makeUnitConnection(name: "abstraction"), cols: 100, rows: 30)
        XCTAssertEqual(transport.resumeStrategy, .nativeRoaming)

        try await transport.send(Data("ping".utf8))
        let echoed = await waitForSuiteCondition {
            await String(decoding: sink.snapshot(), as: UTF8.self).contains("ping")
        }
        XCTAssertTrue(echoed, "loopback echo must arrive on the output stream")

        await transport.resize(cols: 132, rows: 43)
        let fake = try XCTUnwrap(transport as? FakeTransport)
        let resizes = await fake.resizes
        XCTAssertEqual(resizes.last?.cols, 132)
        XCTAssertEqual(resizes.last?.rows, 43)

        await transport.suspend()
        let finishedDuringSuspend = await sink.isFinished
        XCTAssertFalse(finishedDuringSuspend, "roaming suspend keeps the stream open")
        try await transport.resume()
        try await transport.send(Data("after-resume".utf8))
        let echoedAfterResume = await waitForSuiteCondition {
            await String(decoding: sink.snapshot(), as: UTF8.self).contains("after-resume")
        }
        XCTAssertTrue(echoedAfterResume)

        await transport.close()
        let finished = await waitForSuiteCondition { await sink.isFinished }
        XCTAssertTrue(finished, "close() finishes the output stream")
        await assertThrowsTransportError(.channelDenied) {
            try await transport.send(Data("x".utf8))
        }
    }

    func testSessionRegistryHasNoSSHImports() throws {
        let sessionsDir = SSHTestFixture.repoRoot
            .appendingPathComponent("BicTermCore/Sources/BicTermCore/Sessions")
        let files = try FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Sessions/ sources must exist to be audited")

        let forbidden = [
            "import NIO",
            "NIOSSH",
            "SSHTransport",
            "SSHChannelHandle",
            "SSHSessionTransport",
            "SSHAuthenticationKeyProvider",
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    source.contains(token),
                    "\(file.lastPathComponent) must not reference \(token) — Sessions/ drives only TerminalTransport"
                )
            }
        }
    }

    func testSelectedProtocolNeverSilentlyDowngrades() async throws {
        let registry = try await makeSSHRegistry()

        // A known-but-unregistered protocol (the uppercase-echo proof case)
        // fails typed, never downgraded to SSH.
        let echoConnection = try Connection(
            name: "echo",
            type: .uppercaseEcho,
            host: "echo.invalid",
            port: 2022,
            username: "unit",
            customKeys: ["unit-key"]
        )
        await assertThrowsTransportError(.protocolUnavailable(protocolID: "uppercase-echo")) {
            _ = try registry.makeTransport(for: echoConnection)
        }

        // Unknown/future persisted protocol ids resolve to nil descriptor,
        // never to a substitute.
        XCTAssertNil(registry.descriptor(forProtocolID: "mosh"))
        XCTAssertNil(registry.descriptor(forProtocolID: "et"))

        // End-to-end through SessionRegistry: an unavailable protocol fails
        // typed at start, without touching the network or dialing SSH.
        let sessionRegistry = SessionRegistry(
            transportFactory: registry,
            snapshotStore: InMemorySnapshotStore()
        )
        do {
            try await sessionRegistry.startSession(sceneID: "echo-scene", connection: echoConnection)
            XCTFail("an unavailable protocol must throw, never downgrade")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .transport(.protocolUnavailable(protocolID: "uppercase-echo")))
        }
        let state = await sessionRegistry.state(sceneID: "echo-scene")
        XCTAssertEqual(state, .failed(.transport(.protocolUnavailable(protocolID: "uppercase-echo"))))
        await sessionRegistry.closeSession(sceneID: "echo-scene")
    }

    func testSSHDescriptorResolvesEndToEndFromPersistedConnection() async throws {
        let registry = try await makeSSHRegistry()

        let descriptor = try XCTUnwrap(registry.descriptor(forProtocolID: "ssh"))
        XCTAssertEqual(descriptor, .ssh)
        XCTAssertEqual(descriptor.displayName, "SSH")
        XCTAssertTrue(descriptor.supportsAgentForwarding)
        XCTAssertTrue(descriptor.supportsJumpChain)
        XCTAssertFalse(descriptor.supportsRoamingResume)
        XCTAssertFalse(descriptor.requiresServerComponent)
        XCTAssertEqual(descriptor.defaultPort, 22)
        XCTAssertEqual(
            descriptor.keyAlgorithmsAccepted,
            ["ssh-ed25519", "ecdsa-sha2-nistp256"]
        )
        XCTAssertEqual(descriptor.resumeStrategy, .rehandshake)
        XCTAssertEqual(registry.registeredProtocolIDs, ["ssh"])

        // Persist + reload the connection (the SwiftData store round-trips
        // encoded DTOs); resolution still yields an SSH transport.
        let persisted = try SSHTestFixture.makeConnection()
        let data = try JSONEncoder().encode(persisted)
        let reloaded = try JSONDecoder().decode(Connection.self, from: data)
        let transport = try registry.makeTransport(for: reloaded)
        XCTAssertTrue(
            transport is SSHTransport,
            "an ssh-typed connection must resolve to the SSH conformer, got \(type(of: transport))"
        )
        await transport.close()
    }

    func testSSHFactoryRejectsNonSSHConnectionsWithTypedError() async throws {
        let factory = SSHSessionTransportFactory(
            hostKeyVerifier: HostKeyVerifier(store: EphemeralHostKeyStore())
        )
        let echoConnection = try Connection(
            name: "echo",
            type: .uppercaseEcho,
            host: "echo.invalid",
            port: 2022,
            username: "unit",
            customKeys: ["unit-key"]
        )
        await assertThrowsTransportError(.protocolUnavailable(protocolID: "uppercase-echo")) {
            _ = try factory.makeTransport(for: echoConnection)
        }
    }
}
