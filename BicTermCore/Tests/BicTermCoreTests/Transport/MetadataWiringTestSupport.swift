import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

actor MutableKeyMetadataProvider: SSHKeyMetadataProviding {
    private var keys: [KeyMetadata]
    private(set) var calls = 0

    init(_ keys: [KeyMetadata]) { self.keys = keys }

    func replace(with keys: [KeyMetadata]) { self.keys = keys }

    func availableKeys() async throws -> [KeyMetadata] {
        calls += 1
        return keys
    }
}

func wiringMetadata(_ reference: String, enabled: Bool = true, hardware: Bool = false) -> KeyMetadata {
    KeyMetadata(reference: reference, label: reference, algorithm: hardware ? .ecdsaP256 : .ed25519,
                fingerprint: "test", publicKeyBlob: Data(), requiresBiometry: false, enabledByDefault: enabled)
}

enum MetadataWiringPath {
    case direct, uds, factoryDirect, factoryJump, hop, destination, herdrDirect, herdrJump
}

extension TransportAbstractionTests {
    func exerciseMetadataPath(_ path: MetadataWiringPath) async throws {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let provider = RecordingKeyProvider(keys: ["destination": key, "hop": key])
        let metadata = MutableKeyMetadataProvider([
            wiringMetadata("disabled", enabled: false), wiringMetadata("aaa-hardware", hardware: true),
            wiringMetadata("hop"), wiringMetadata("destination")
        ])
        let verifier = try await JumpFixture.makeVerifier()
        let jumped = path == .factoryJump || path == .destination || path == .herdrJump
        let connection = try Connection(
            name: "metadata-wiring", type: .ssh, host: "127.0.0.1", port: jumped ? 12223 : 12222,
            username: SSHTestFixture.username, customKeys: jumped ? ["disabled", "destination", "stale"] : nil,
            jumpChain: jumped ? [Hop(host: "127.0.0.1", port: 12222, username: SSHTestFixture.username,
                                    customKeys: ["hop"])] : []
        )
        switch path {
        case .direct, .uds:
            let transport = SSHTransport(hostKeyVerifier: verifier, authenticationKeyProvider: provider,
                                         passwordStore: InMemoryPasswordStore(), hardwareKeysEnabledByDefault: { false },
                                         metadataProvider: metadata)
            do {
                if path == .uds {
                    try await transport.connect(
                        unixSocketPath: SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/sshd-uds.sock").path,
                        to: connection, cols: 80, rows: 24
                    )
                } else {
                    try await transport.connect(to: connection, cols: 80, rows: 24)
                }
            } catch { await transport.close(); throw error }
            await transport.close()
        case .factoryDirect, .factoryJump:
            let factory = SSHSessionTransportFactory(
                hostKeyVerifier: verifier, authenticationKeyProvider: provider, passwordStore: InMemoryPasswordStore(),
                hardwareKeysEnabledByDefault: { false }, metadataProvider: metadata
            )
            let transport = try factory.makeTransport(for: connection)
            do { try await transport.connect(to: connection, cols: 80, rows: 24) }
            catch { await transport.close(); throw error }
            await transport.close()
        case .hop:
            let dialer = NIOJumpDialer(
                hostKeyVerifier: verifier, authenticationKeyProvider: provider, passwordStore: InMemoryPasswordStore(),
                hardwareKeysEnabledByDefault: { false }, metadataProvider: metadata
            )
            let hop = try await dialer.connectTCP(to: JumpHopEndpoint(hop: Hop(
                host: "127.0.0.1", port: 12222, username: SSHTestFixture.username, customKeys: ["hop"]
            )))
            do {
                let session = try await hop.openSession(cols: 80, rows: 24)
                await session.close()
            } catch { await hop.close(); throw error }
            await hop.close()
        case .destination:
            let builder = JumpChainBuilder(
                hostKeyVerifier: verifier, authenticationKeyProvider: provider, passwordStore: InMemoryPasswordStore(),
                hardwareKeysEnabledByDefault: { false }, metadataProvider: metadata
            )
            let transport = try await builder.build(connection: connection, cols: 80, rows: 24)
            await transport.close()
        case .herdrDirect, .herdrJump:
            let connector = HerdrEndpointConnector(
                hostKeyVerifier: verifier, authenticationKeyProvider: provider, passwordStore: InMemoryPasswordStore(),
                hardwareKeysEnabledByDefault: { false }, metadataProvider: metadata,
                searchPaths: ["/nonexistent-t5-herdr"], approveHostKey: { _ in false }
            )
            do {
                let transport = try await connector.connect(connection)
                await transport.close()
                XCTFail("Missing executable must fail the probe after successful authentication")
            } catch {
                guard case .incompatibleEndpoint = error else {
                    return XCTFail("Expected authenticated probe failure, got \(error)")
                }
            }
        }
        XCTAssertEqual(provider.calls.map(\.reference), jumped ? ["hop", "destination"] : [path == .hop ? "hop" : "destination"])
        let metadataCalls = await metadata.calls
        XCTAssertEqual(metadataCalls, jumped ? 2 : 1)
    }
}
