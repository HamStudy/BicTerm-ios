import Foundation
import XCTest
@testable import BicTermCore

/// Local-repro harness for the device-only herd second-machine failure:
/// two machines establishing CONCURRENTLY (the herd bring-up shape — one
/// connector per machine, ONE shared host-key verifier, ONE shared
/// resolved key instance, exactly what the KeyResolutionCache hands both
/// machines post-81b2cca) against the two fixture sshd instances on
/// 12222 and 12223, looped.
///
/// The device failure collapses to `sshEstablish(.channelDenied)` with
/// the real error swallowed; any failure here therefore also dumps the
/// `SSHEstablishDiagnostics` capture (full `String(reflecting:)` error
/// chains) into the failure message. A green loop on the simulator is
/// ITSELF evidence: the remaining shared resource is device-only
/// hardware (Secure Enclave signing inside the NIOSSH handshake), which
/// the simulator cannot exercise — the fixture key is a software
/// ed25519 key and `SecureEnclave.isAvailable` is false in the
/// simulator.
final class HerdrConcurrentEstablishTests: XCTestCase {
    private static let statusShimPath = SSHTestFixture.repoRoot
        .appendingPathComponent("Fixtures/herdr/fake-herdr-status").path

    private static let iterations = 20

    func testTwoMachinesEstablishConcurrentlyAcrossBothFixturesLooped() async throws {
        let verifier = try await JumpFixture.makeVerifier()
        let sharedKeyProvider = StaticKeyProvider(
            key: try await SSHTestFixture.loadFixtureEd25519Key()
        )
        let metadata = FixtureKeyMetadataProvider()
        let machineA = try Connection(
            name: "concurrent-a",
            type: .ssh,
            host: SSHTestFixture.hop1Host,
            port: SSHTestFixture.hop1Port,
            username: SSHTestFixture.username,
            customKeys: ["fixture-ed25519"]
        )
        let machineB = try Connection(
            name: "concurrent-b",
            type: .ssh,
            host: SSHTestFixture.hop1Host,
            port: SSHTestFixture.hop2Port,
            username: SSHTestFixture.username,
            customKeys: ["fixture-ed25519"]
        )

        for iteration in 0..<Self.iterations {
            SSHEstablishDiagnostics.shared.removeAll()
            let connectorA = HerdrEndpointConnector(
                hostKeyVerifier: verifier,
                authenticationKeyProvider: sharedKeyProvider,
                metadataProvider: metadata,
                searchPaths: [Self.statusShimPath],
                approveHostKey: { _ in false }
            )
            let connectorB = HerdrEndpointConnector(
                hostKeyVerifier: verifier,
                authenticationKeyProvider: sharedKeyProvider,
                metadataProvider: metadata,
                searchPaths: [Self.statusShimPath],
                approveHostKey: { _ in false }
            )

            async let probedA = connectorA.establishProbed(machineA)
            async let probedB = connectorB.establishProbed(machineB)

            do {
                let probedA = try await probedA
                let probedB = try await probedB
                // The production per-machine shape: probe connection +
                // factory-resolved bridge connection, both under the
                // concurrent establish.
                let carrierA = try await probedA.carrierFactory()
                let carrierB = try await probedB.carrierFactory()
                await carrierA.close()
                await carrierB.close()
            } catch {
                let diagnostics = SSHEstablishDiagnostics.shared.snapshot()
                XCTFail(
                    "iteration \(iteration): concurrent establish failed: \(error)\n"
                        + "establishDiagnostics:\n"
                        + (diagnostics.isEmpty
                            ? "(nothing captured)" : diagnostics.joined(separator: "\n"))
                )
                return
            }
        }
    }
}
