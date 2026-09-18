import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import BicTermCore

/// Stage A herdr remote installer: script construction mirrors upstream
/// attach.rs vectors, client-side gates (platform / already-present /
/// install-dir grammar / checksum) that refuse BEFORE any remote exec, pin
/// table completeness (cross-checked against the committed fixture
/// lockfile), and the offline fixture round-trip — the repo-local pinned
/// macos-aarch64 binary injected through the ``HerdrBinaryProvider`` seam,
/// installed through the fixture sshd into a gitignored target dir, and
/// found again by a probe-style candidate check. No test touches the
/// network.
final class HerdrRemoteInstallerTests: XCTestCase {
    private var transport: SSHTransport?

    override func tearDown() async throws {
        if let transport {
            await transport.close()
        }
        transport = nil
        try await super.tearDown()
    }

    // MARK: - Test doubles

    /// Serves fixed bytes for every target (the offline round-trip injects
    /// the repo-local pinned binary this way).
    private struct StaticBinaryProvider: HerdrBinaryProvider {
        let data: Data

        func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data {
            data
        }
    }

    /// Connection double that fails every exec-channel open. Client-side
    /// gates must refuse BEFORE any remote exec — an install that (wrongly)
    /// reached the remote would surface the open failure as a
    /// remotePrepareFailed/uploadFailed-shaped error instead of its
    /// client-side gate error.
    private struct RefusingConnection: SSHExecCapableConnection {
        func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
            throw .channelDenied
        }

        func close() async {}
    }

    /// Lock-confined progress collector (the progress callback is
    /// `@Sendable`; a captured local var array would not be).
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    private func missingHerdrProbe(rawOS: String, rawArch: String) -> HerdrProbe.Result {
        HerdrProbe.Result(
            host: "fixture-install",
            rawOS: rawOS,
            rawArch: rawArch,
            foundPath: nil,
            version: nil,
            endpointGeneration: nil,
            capabilities: []
        )
    }

    // MARK: - Script construction (upstream attach.rs vectors)

    func testPrepareScriptMirrorsUpstreamShape() throws {
        let script = try HerdrRemoteInstaller.prepareScript(installDir: "$HOME/.local/bin")
        XCTAssertTrue(script.hasPrefix("set -eu\n"))
        XCTAssertTrue(script.contains("dest=\"$HOME/.local/bin/herdr\""), "default dest must be $HOME/.local/bin/herdr")
        XCTAssertTrue(script.contains("dir=\"${dest%/*}\""))
        XCTAssertTrue(script.contains("mkdir -p \"$dir\""))
        XCTAssertTrue(script.contains("tmp=\"${dest}.tmp.$$\""))
        XCTAssertTrue(script.contains("printf '%s\\0%s\\0' \"$tmp\" \"$dest\""))
        XCTAssertTrue(script.hasSuffix("\"\n"), "upstream's script ends with a newline after the printf")

        let overridden = try HerdrRemoteInstaller.prepareScript(installDir: "/opt/custom/bin")
        XCTAssertTrue(overridden.contains("dest=\"/opt/custom/bin/herdr\""))
    }

    func testCommitScriptMirrorsUpstreamShape() {
        // Exact vector from upstream attach.rs
        // remote_install_prepare_and_commit_scripts_quote_paths.
        XCTAssertEqual(
            HerdrRemoteInstaller.commitScript(tmpPath: "/home/a b/herdr.tmp.42", destPath: "/home/a b/herdr"),
            "set -eu\nchmod 755 '/home/a b/herdr.tmp.42'\nmv '/home/a b/herdr.tmp.42' '/home/a b/herdr'\n"
        )
    }

    func testStreamCommandIsTeeWithPosixQuotedPath() {
        // Exact vector from upstream attach.rs
        // remote_install_stream_command_avoids_shell_c_wrapper.
        XCTAssertEqual(
            HerdrRemoteInstaller.streamCommand(tmpPath: "/home/a b/.local/bin/herdr.tmp.123"),
            "tee '/home/a b/.local/bin/herdr.tmp.123'"
        )
    }

    func testParseInstallPathsVectors() {
        // Vectors from upstream parse_remote_install_paths.
        let plain = Data("/home/a b/herdr.tmp.42\0/home/a b/herdr\0".utf8)
        XCTAssertEqual(HerdrRemoteInstaller.parseInstallPaths(plain)?.tmpPath, "/home/a b/herdr.tmp.42")
        XCTAssertEqual(HerdrRemoteInstaller.parseInstallPaths(plain)?.destPath, "/home/a b/herdr")
        // Embedded newlines are path bytes, not separators.
        let newliney = Data("/home/a b\n/herdr.tmp.42\0/home/a b\n/herdr\0".utf8)
        XCTAssertEqual(HerdrRemoteInstaller.parseInstallPaths(newliney)?.tmpPath, "/home/a b\n/herdr.tmp.42")
        XCTAssertEqual(HerdrRemoteInstaller.parseInstallPaths(newliney)?.destPath, "/home/a b\n/herdr")
        XCTAssertNil(HerdrRemoteInstaller.parseInstallPaths(Data()))
        XCTAssertNil(HerdrRemoteInstaller.parseInstallPaths(Data("\0\0".utf8)))
        // Invalid UTF-8 in either path refuses (fail closed).
        XCTAssertNil(HerdrRemoteInstaller.parseInstallPaths(Data([0xff, 0x00, 0x41, 0x00])))
        XCTAssertNil(HerdrRemoteInstaller.parseInstallPaths(Data([0x41, 0x00, 0xfe, 0x00])))
    }

    // MARK: - Client-side gates (refuse before any remote exec)

    func testChecksumMismatchRefusesUploadBeforeAnyRemoteExec() async throws {
        let probe = missingHerdrProbe(rawOS: "Darwin", rawArch: "arm64")
        let wrongBytes = Data("definitely not the pinned herdr binary".utf8)
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: wrongBytes))

        do {
            _ = try await installer.install(
                on: RefusingConnection(),
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected checksumMismatch")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(
                error,
                .checksumMismatch(
                    target: .macosAarch64,
                    expected: HerdrReleasePins.asset(for: .macosAarch64).sha256,
                    actual: HerdrReleasePins.sha256Hex(wrongBytes)
                )
            )
        }
    }

    func testUnsupportedPlatformFailsClosedBeforeAnyRemoteExec() async throws {
        let probe = missingHerdrProbe(rawOS: "FreeBSD", rawArch: "amd64")
        let installer = HerdrRemoteInstaller(
            binaryProvider: StaticBinaryProvider(data: Data("x".utf8))
        )

        do {
            _ = try await installer.install(
                on: RefusingConnection(),
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected unsupportedPlatform")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(error, .unsupportedPlatform(os: "FreeBSD", arch: "amd64"))
        }
    }

    func testInstallRefusesWhenProbeAlreadyFoundHerdr() async throws {
        let probe = HerdrProbe.Result(
            host: "fixture-present",
            rawOS: "Linux",
            rawArch: "aarch64",
            foundPath: "/usr/local/bin/herdr",
            version: nil,
            endpointGeneration: nil,
            capabilities: []
        )
        let installer = HerdrRemoteInstaller(
            binaryProvider: StaticBinaryProvider(data: Data("x".utf8))
        )

        do {
            _ = try await installer.install(
                on: RefusingConnection(),
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected herdrAlreadyPresent")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(error, .herdrAlreadyPresent(path: "/usr/local/bin/herdr"))
        }
    }

    func testInvalidInstallDirRejectedBeforeAnyFetchOrExec() async throws {
        let probe = missingHerdrProbe(rawOS: "Darwin", rawArch: "arm64")
        let installer = HerdrRemoteInstaller(
            binaryProvider: StaticBinaryProvider(data: Data("x".utf8))
        )

        for hostile in ["/opt/$(rm -rf ~)/bin", "/opt/herdr';id'", "", "/tmp/x y/bin", "/opt/$ORIGIN/bin"] {
            do {
                _ = try await installer.install(
                    on: RefusingConnection(),
                    probe: probe,
                    installDir: hostile
                )
                XCTFail("expected invalidInstallDir for \(hostile)")
            } catch let error as HerdrRemoteInstallerError {
                XCTAssertEqual(error, .invalidInstallDir(hostile), "hostile dir \(hostile) must be rejected")
            }
        }
    }

    // MARK: - Pin table

    func testPinTableCompleteness() {
        XCTAssertEqual(HerdrReleasePins.version, "0.9.0")
        XCTAssertEqual(
            HerdrReleasePins.Target.allCases.map(\.rawValue),
            ["linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64"]
        )
        let hex64 = try? NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        for target in HerdrReleasePins.Target.allCases {
            let asset = HerdrReleasePins.asset(for: target)
            XCTAssertEqual(
                asset.url,
                "https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-\(target.rawValue)",
                "asset URL must be the v0.9.0 GitHub release asset for \(target.rawValue)"
            )
            XCTAssertEqual(hex64?.firstMatch(
                in: asset.sha256, range: NSRange(asset.sha256.startIndex..., in: asset.sha256)
            ) != nil, true, "sha256 for \(target.rawValue) must be 64 lowercase hex chars")
        }
        // Probe-normalized platform pairs map onto the table; anything
        // else is nil (fail closed, never guess).
        XCTAssertEqual(HerdrReleasePins.target(os: "linux", arch: "x86_64"), .linuxX86_64)
        XCTAssertEqual(HerdrReleasePins.target(os: "linux", arch: "aarch64"), .linuxAarch64)
        XCTAssertEqual(HerdrReleasePins.target(os: "macos", arch: "x86_64"), .macosX86_64)
        XCTAssertEqual(HerdrReleasePins.target(os: "macos", arch: "aarch64"), .macosAarch64)
        XCTAssertNil(HerdrReleasePins.target(os: "freebsd", arch: "x86_64"))
        XCTAssertNil(HerdrReleasePins.target(os: "linux", arch: "riscv64"))
        XCTAssertNil(HerdrReleasePins.target(os: "", arch: ""))
    }

    /// The macos-aarch64 pin and the committed fixture lockfile describe
    /// the same artifact family — they must never drift apart silently.
    func testMacosAarch64PinMatchesCommittedFixtureLockfile() throws {
        let lockfile = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/herdr/server-0.9.0.sha256")
        let line = try String(contentsOf: lockfile, encoding: .utf8)
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        XCTAssertEqual(fields.first.map(String.init), HerdrReleasePins.asset(for: .macosAarch64).sha256)
    }

    /// The default install dir's destination is the probe's FIRST
    /// candidate search path — the re-probe-finds-it property.
    func testDefaultInstallDirIsProbeFirstCandidatePath() {
        XCTAssertEqual(
            HerdrRemoteInstaller.defaultInstallDir + "/herdr",
            HerdrProbe.defaultSearchPaths.first
        )
    }

    // MARK: - Offline fixture round-trip (fixture sshd on 12222)

    /// True when the fixture sshd is accepting connections on 12222.
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

    private func makeFixtureTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        self.transport = transport
        return transport
    }

    /// Full offline round-trip against the fixture sshd (this macOS arm64
    /// host): missing-binary probe → install of the repo-local pinned
    /// macos-aarch64 binary through the ``HerdrBinaryProvider`` seam into a
    /// gitignored dir under `Fixtures/run/` → file present, executable,
    /// sha256 equal to the pin, and a probe-style candidate check with an
    /// overridden search path finding a compatible herdr there.
    func testOfflineFixtureRoundTripInstallsPinnedBinary() async throws {
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

        let transport = try await makeFixtureTransport()

        // 1. The missing-binary case: search paths point nowhere on the
        //    fixture host (its exec PATH excludes every herdr location).
        let probe = try await HerdrProbe.run(
            on: transport,
            host: "fixture-install",
            searchPaths: ["/nonexistent-bicterm-install/herdr"]
        )
        XCTAssertEqual(probe.platformOS, "macos", "the fixture sshd runs on the macOS host")
        XCTAssertNil(probe.foundPath)
        try XCTSkipUnless(
            probe.platformArch == "aarch64",
            "round-trip needs the pinned macos-aarch64 artifact (host arch: \(probe.platformArch ?? "unknown"))"
        )

        // 2. Install through the seam, into a gitignored target dir
        //    (Fixtures/run/ is ignored; the override mirrors upstream
        //    install.sh's HERDR_INSTALL_DIR).
        let installDir = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-install-target").path
        try? fm.removeItem(atPath: installDir)
        defer { try? fm.removeItem(atPath: installDir) }

        let binary = try Data(contentsOf: binaryURL)
        let progress = ProgressLog()
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let outcome = try await installer.install(
            on: transport,
            probe: probe,
            installDir: installDir,
            progress: { progress.append($0) }
        )

        // 3. Remote-reported destination, file present, executable bit,
        //    byte-identical to the pin.
        let dest = installDir + "/herdr"
        XCTAssertEqual(outcome.destinationPath, dest)
        XCTAssertEqual(outcome.target, .macosAarch64)
        XCTAssertTrue(fm.fileExists(atPath: dest), "installed binary must exist at \(dest)")
        let attributes = try fm.attributesOfItem(atPath: dest)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(permissions & 0o111, 0o111, "commit step must chmod the binary executable")
        let installed = try Data(contentsOf: URL(fileURLWithPath: dest))
        XCTAssertEqual(
            HerdrReleasePins.sha256Hex(installed),
            HerdrReleasePins.asset(for: .macosAarch64).sha256,
            "installed bytes must be the pinned macos-aarch64 artifact"
        )

        // 4. Probe-style candidate check with an overridden search path
        //    finds it and reports a compatible generation-1 herdr.
        let reprobe = try await HerdrProbe.run(
            on: transport,
            host: "fixture-install",
            searchPaths: [dest]
        )
        XCTAssertEqual(reprobe.foundPath, dest)
        XCTAssertEqual(reprobe.version, "0.9.0")
        XCTAssertEqual(reprobe.endpointGeneration, HerdrProbe.Result.requiredGeneration)
        XCTAssertTrue(reprobe.isCompatible)

        // 5. Progress reported the milestone sequence.
        let lines = progress.snapshot
        XCTAssertFalse(lines.isEmpty, "install must report progress milestones")
        XCTAssertTrue(lines.contains { $0.contains("uploading") })
        XCTAssertTrue(lines.contains { $0.contains("installed herdr 0.9.0") })
    }
}
