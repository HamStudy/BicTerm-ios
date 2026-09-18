import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import BicTermCore

/// Stage B connector variant (``HerdrEndpointConnector/establishProbedOfferingInstall(_:)``
/// and ``connectOfferingInstall(_:)``): the missing-binary probe outcome
/// proposes the pinned install through the injected approval, decline and
/// install failure map onto typed connector errors, a present-but-
/// incompatible herdr NEVER proposes (no upgrade/replace flows), and the
/// pre-stage-B surfaces (no seams injected, plain ``connect(_:)``) keep
/// the incompatibleEndpoint semantics. The offline fixture round-trip
/// runs the whole proposal → install → re-probe arc end-to-end through
/// the connector against the fixture sshd. No test touches the network.
final class HerdrEndpointConnectorInstallTests: XCTestCase {
    private var transports: [SSHTransport] = []

    override func tearDown() async throws {
        for transport in transports {
            await transport.close()
        }
        transports.removeAll()
        try await super.tearDown()
    }

    // MARK: - Test doubles

    private struct StaticBinaryProvider: HerdrBinaryProvider {
        let data: Data

        func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data {
            data
        }
    }

    /// Provider double that records calls and serves fixed (wrong) bytes:
    /// the decline tests assert it was never asked for the binary.
    private final class RecordingBinaryProvider: HerdrBinaryProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [HerdrReleasePins.Target] = []

        func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data {
            lock.withLock { calls.append(target) }
            return Data("definitely not the pinned herdr binary".utf8)
        }

        var requestedTargets: [HerdrReleasePins.Target] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// Thread-safe install-consent recorder wrapping the injected approval.
    private final class InstallApprovalRecorder: @unchecked Sendable {
        private let decision: Bool
        private let lock = NSLock()
        private var recorded: [HerdrInstallConsent] = []

        init(decision: Bool) {
            self.decision = decision
        }

        var recordedConsents: [HerdrInstallConsent] {
            lock.withLock { recorded }
        }

        func approve(_ consent: HerdrInstallConsent) async -> Bool {
            lock.withLock { recorded.append(consent) }
            return decision
        }
    }

    /// Lock-confined progress collector (the progress callback is
    /// `@Sendable`; a captured local var array would not be).
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.withLock { lines.append(line) }
        }

        var snapshot: [String] {
            lock.withLock { lines }
        }
    }

    // MARK: - Fixture helpers

    private static func fixtureSSHDIsReachable() async -> Bool {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ClientBootstrap(group: group)
                .connect(host: SSHTestFixture.hop1Host, port: SSHTestFixture.hop1Port)
                .get()
            try await channel.close().get()
            try await group.shutdownGracefully()
            return true
        } catch {
            try? await group.shutdownGracefully()
            return false
        }
    }

    private func makeConnector(
        searchPaths: [String],
        installer: HerdrRemoteInstaller? = nil,
        approveInstall: InstallApprovalRecorder? = nil,
        installDir: String = HerdrRemoteInstaller.defaultInstallDir
    ) async throws -> HerdrEndpointConnector {
        HerdrEndpointConnector(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: searchPaths,
            approveHostKey: { _ in false },
            installer: installer,
            approveInstall: approveInstall.map { $0.approve },
            installDir: installDir
        )
    }

    /// One probe over a fresh fixture transport: learns this host's
    /// normalized platform (for the expected consent target) and proves
    /// the missing-binary precondition for the given search paths.
    private func fixtureProbe(searchPaths: [String]) async throws -> HerdrProbe.Result {
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        transports.append(transport)
        return try await HerdrProbe.run(
            on: transport,
            host: "fixture-install",
            searchPaths: searchPaths
        )
    }

    /// Materializes a one-shot executable status shim answering the probe's
    /// status query with `statusReply` (a raw line, valid JSON or not).
    private static func materializeStatusShim(replying statusReply: String) throws -> String {
        let dir = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("herdr")
        let script = """
        #!/bin/sh
        if [ "$1" = status ] && [ "$2" = client ] && [ "$3" = --json ]; then
          printf '%s\\n' '\(statusReply)'
          exit 0
        fi
        exit 2

        """
        try script.data(using: .utf8)?.write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        return shim.path
    }

    // MARK: - Missing-binary proposal and decline

    /// The missing-binary outcome proposes exactly once with a consent
    /// naming the host, the pinned target for the host's platform, and the
    /// configured install dir; a decline fails typed
    /// (``HerdrEndpointConnectorError/installDeclined``) without ever
    /// asking the binary provider for bytes.
    func testMissingBinaryProposesInstallAndDeclineYieldsTypedOutcome() async throws {
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(sshdUp, "fixture sshd not up — run scripts/fixtures-up.sh")
        let searchPaths = ["/nonexistent-bicterm-install/herdr"]
        let probe = try await fixtureProbe(searchPaths: searchPaths)
        XCTAssertNil(probe.foundPath, "precondition: no herdr on the fixture host")
        let expectedTarget = try XCTUnwrap(
            HerdrReleasePins.target(os: probe.platformOS ?? "", arch: probe.platformArch ?? ""),
            "precondition: the fixture host's platform must be pinned"
        )

        let provider = RecordingBinaryProvider()
        let approval = InstallApprovalRecorder(decision: false)
        let connector = try await makeConnector(
            searchPaths: searchPaths,
            installer: HerdrRemoteInstaller(binaryProvider: provider),
            approveInstall: approval,
            installDir: "/opt/bicterm-install-test"
        )

        do {
            _ = try await connector.establishProbedOfferingInstall(SSHTestFixture.makeConnection())
            XCTFail("a declined install must fail the establish")
        } catch let error as HerdrEndpointConnectorError {
            XCTAssertEqual(
                error,
                .installDeclined(HerdrInstallConsent(
                    host: SSHTestFixture.hop1Host,
                    target: expectedTarget,
                    installDir: "/opt/bicterm-install-test"
                ))
            )
        }
        XCTAssertEqual(approval.recordedConsents.count, 1, "exactly one install proposal")
        XCTAssertTrue(
            provider.requestedTargets.isEmpty,
            "a declined install never fetches the binary"
        )
    }

    /// An approved install that fails maps onto the typed
    /// ``HerdrEndpointConnectorError/installFailed`` — here the
    /// client-side checksum gate refusing wrong bytes before any upload.
    func testInstallFailureSurfacesTypedInstallFailedError() async throws {
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(sshdUp, "fixture sshd not up — run scripts/fixtures-up.sh")
        let searchPaths = ["/nonexistent-bicterm-install/herdr"]
        let probe = try await fixtureProbe(searchPaths: searchPaths)
        let expectedTarget = try XCTUnwrap(
            HerdrReleasePins.target(os: probe.platformOS ?? "", arch: probe.platformArch ?? "")
        )
        let wrongBytes = Data("definitely not the pinned herdr binary".utf8)

        let connector = try await makeConnector(
            searchPaths: searchPaths,
            installer: HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: wrongBytes)),
            approveInstall: InstallApprovalRecorder(decision: true)
        )

        do {
            _ = try await connector.establishProbedOfferingInstall(SSHTestFixture.makeConnection())
            XCTFail("a checksum-mismatched install must fail the establish")
        } catch let error as HerdrEndpointConnectorError {
            XCTAssertEqual(
                error,
                .installFailed(.checksumMismatch(
                    target: expectedTarget,
                    expected: HerdrReleasePins.asset(for: expectedTarget).sha256,
                    actual: HerdrReleasePins.sha256Hex(wrongBytes)
                ))
            )
        }
    }

    // MARK: - Strict trigger

    /// A present-but-incompatible herdr NEVER proposes the install — the
    /// existing `.incompatibleEndpoint` path is untouched (no upgrade or
    /// replace flows).
    func testPresentButIncompatibleHerdrNeverProposesInstall() async throws {
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(sshdUp, "fixture sshd not up — run scripts/fixtures-up.sh")
        let shim = try Self.materializeStatusShim(
            replying: #"{"version":"0.8.0","endpoint_protocol_generation":99,"endpoint_capabilities":[]}"#
        )
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path) }

        let approval = InstallApprovalRecorder(decision: true)
        let connector = try await makeConnector(
            searchPaths: [shim],
            installer: HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: Data("x".utf8))),
            approveInstall: approval
        )

        do {
            _ = try await connector.establishProbedOfferingInstall(SSHTestFixture.makeConnection())
            XCTFail("an off-version herdr must fail the establish")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .incompatibleEndpoint(result, detail) = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
            XCTAssertEqual(result.foundPath, shim)
            XCTAssertTrue(detail.contains("herdr 0.8.0"), detail)
        }
        XCTAssertTrue(approval.recordedConsents.isEmpty, "no install proposal may be made for a present herdr")
    }

    /// Without the installer/approval seams injected, the variant keeps
    /// the exact ``establishProbed(_:)`` semantics for the missing-binary
    /// outcome.
    func testMissingBinaryWithoutInstallerKeepsIncompatibleEndpointSemantics() async throws {
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(sshdUp, "fixture sshd not up — run scripts/fixtures-up.sh")
        let connector = try await makeConnector(
            searchPaths: ["/nonexistent-bicterm-install/herdr"]
        )

        do {
            _ = try await connector.establishProbedOfferingInstall(SSHTestFixture.makeConnection())
            XCTFail("a missing herdr with no installer must fail the establish")
        } catch let error as HerdrEndpointConnectorError {
            guard case let .incompatibleEndpoint(result, detail) = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
            XCTAssertNil(result.foundPath)
            XCTAssertTrue(detail.contains("No herdr executable was found"), detail)
        }
    }

    /// The pre-stage-B ``connect(_:)`` never offers the install, even with
    /// the seams injected — the offering is exclusive to the stage-B
    /// variants.
    func testConnectNeverOffersInstallEvenWithSeamsInjected() async throws {
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(sshdUp, "fixture sshd not up — run scripts/fixtures-up.sh")
        let approval = InstallApprovalRecorder(decision: true)
        let connector = try await makeConnector(
            searchPaths: ["/nonexistent-bicterm-install/herdr"],
            installer: HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: Data("x".utf8))),
            approveInstall: approval
        )

        do {
            _ = try await connector.connect(SSHTestFixture.makeConnection())
            XCTFail("a missing herdr must fail the connect")
        } catch let error as HerdrEndpointConnectorError {
            guard case .incompatibleEndpoint = error else {
                return XCTFail("expected incompatibleEndpoint, got \(error)")
            }
        }
        XCTAssertTrue(approval.recordedConsents.isEmpty, "connect() must never propose the install")
    }

    // MARK: - Offline fixture round-trip through the connector

    /// End-to-end through the connector against the fixture sshd: the
    /// probe misses (search paths point at the not-yet-created install
    /// destination), the approval passes, the pinned macos-aarch64 binary
    /// is installed through the ``HerdrBinaryProvider`` seam into a
    /// gitignored dir under `Fixtures/run/`, and the connector's OWN
    /// re-probe with the same search paths finds a compatible herdr —
    /// bring-up continues on the same carrier.
    func testOfflineFixtureRoundTripThroughConnectorInstallsAndReprobes() async throws {
        let fm = FileManager.default
        let binaryURL = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr/herdr")
        try XCTSkipUnless(
            fm.fileExists(atPath: binaryURL.path),
            "pinned herdr fixture binary missing — run scripts/herdr-server-fetch.sh"
        )
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(
            sshdUp,
            "fixture sshd not up — run scripts/fixtures-up.sh"
        )
        let platform = try await fixtureProbe(searchPaths: ["/nonexistent-bicterm-install/herdr"])
        try XCTSkipUnless(
            platform.platformArch == "aarch64",
            "round-trip needs the pinned macos-aarch64 artifact (host arch: \(platform.platformArch ?? "unknown"))"
        )

        let installDir = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-install-target").path
        let dest = installDir + "/herdr"
        try? fm.removeItem(atPath: installDir)
        defer { try? fm.removeItem(atPath: installDir) }

        let logOffset = fixtureLogSize("hop1.log")
        let approval = InstallApprovalRecorder(decision: true)
        let progress = ProgressLog()
        let connector = try await makeConnector(
            searchPaths: [dest],
            installer: HerdrRemoteInstaller(
                binaryProvider: StaticBinaryProvider(data: try Data(contentsOf: binaryURL))
            ),
            approveInstall: approval,
            installDir: installDir
        )

        let probed = try await connector.establishProbedOfferingInstall(
            SSHTestFixture.makeConnection(),
            installProgress: { progress.append($0) }
        )
        await probed.carrier.close()

        // The consent named the host, the pinned macos-aarch64 target,
        // and the overridden install dir.
        XCTAssertEqual(
            approval.recordedConsents,
            [HerdrInstallConsent(
                host: SSHTestFixture.hop1Host,
                target: .macosAarch64,
                installDir: installDir
            )]
        )

        // The installer's milestone stream was forwarded verbatim.
        let lines = progress.snapshot
        XCTAssertFalse(lines.isEmpty, "the install must report progress milestones")
        XCTAssertTrue(lines.contains { $0.contains("uploading") })
        XCTAssertTrue(lines.contains { $0.contains("installed herdr 0.9.0") })

        // The connector's re-probe found the installed binary compatible.
        XCTAssertEqual(probed.executablePath, dest)
        XCTAssertEqual(probed.probe.foundPath, dest)
        XCTAssertEqual(probed.probe.version, "0.9.0")
        XCTAssertEqual(probed.probe.endpointGeneration, HerdrProbe.Result.requiredGeneration)
        XCTAssertTrue(probed.probe.isCompatible)
        XCTAssertTrue(fm.fileExists(atPath: dest), "installed binary must exist at \(dest)")

        // Every step rode the fixture sshd: the probe, the upload's tee,
        // and the re-probe.
        let appendage = fixtureLogAppendage("hop1.log", from: logOffset)
        XCTAssertEqual(
            appendage.components(separatedBy: "command -v herdr").count - 1, 2,
            "the probe and the re-probe both ran on the sshd"
        )
        XCTAssertTrue(appendage.contains("tee "), "the binary upload ran on the sshd")
    }
}
