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
    private var transports: [SSHTransport] = []

    override func tearDown() async throws {
        for transport in transports {
            await transport.close()
        }
        transports.removeAll()
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

    /// `SSHExecCapableConnection` double wrapping another connection:
    /// records every exec command attempted on it and its `close()`
    /// receipts — the per-step connection-discipline probe (which execs
    /// rode which connection, closed by whom).
    private final class RecordingConnection: SSHExecCapableConnection, @unchecked Sendable {
        private let underlying: any SSHExecCapableConnection
        private let lock = NSLock()
        private var attemptedCommands: [String] = []
        private var closeReceipts = 0

        init(underlying: any SSHExecCapableConnection) {
            self.underlying = underlying
        }

        func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
            lock.withLock { attemptedCommands.append(command) }
            return try await underlying.openExecChannel(command: command)
        }

        func close() async {
            await underlying.close()
            lock.withLock { closeReceipts += 1 }
        }

        var commands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return attemptedCommands
        }

        var closes: Int {
            lock.lock()
            defer { lock.unlock() }
            return closeReceipts
        }
    }

    /// Channel-budget gateway model at the factory seam: permits exactly
    /// `budget` exec-channel opens on the wrapped connection over its
    /// LIFETIME, refusing every later open with typed `.channelDenied`
    /// (the CoderSSHGW shape — the signal ``SharedExecCarrierPool``
    /// reacts to).
    private final class BudgetedConnection: SSHExecCapableConnection, @unchecked Sendable {
        private let underlying: any SSHExecCapableConnection
        private let budget: Int
        private let lock = NSLock()
        private var opens = 0

        init(underlying: any SSHExecCapableConnection, budget: Int) {
            self.underlying = underlying
            self.budget = budget
        }

        func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
            guard consumeOpen() else { throw .channelDenied }
            return try await underlying.openExecChannel(command: command)
        }

        // NSLock is unavailable from async contexts; the lock-confined
        // decision lives in the sync helper.
        private func consumeOpen() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            opens += 1
            return opens <= budget
        }

        func close() async {
            await underlying.close()
        }
    }

    /// Factory double: hands out recording-wrapped connections from the
    /// injected per-call maker (`index` = call order) and exposes what was
    /// handed out — proves the factory is resolved once per exec step,
    /// each step gets a FRESH connection, and every resolved connection is
    /// closed by the installer (success and failure paths alike).
    private final class RecordingInstallFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var handedOut: [RecordingConnection] = []
        private let make: @Sendable (Int) async throws -> any SSHExecCapableConnection

        init(make: @escaping @Sendable (Int) async throws -> any SSHExecCapableConnection) {
            self.make = make
        }

        func next() async throws -> any SSHExecCapableConnection {
            let index = lock.withLock { handedOut.count }
            let underlying = try await make(index)
            let recording = RecordingConnection(underlying: underlying)
            lock.withLock { handedOut.append(recording) }
            return recording
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return handedOut.count
        }

        var connections: [RecordingConnection] {
            lock.lock()
            defer { lock.unlock() }
            return handedOut
        }
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
        let factory = RecordingInstallFactory { _ in RefusingConnection() }

        do {
            _ = try await installer.install(
                using: { try await factory.next() },
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
        XCTAssertEqual(factory.calls, 0, "the checksum gate must refuse before the factory is ever resolved")
    }

    func testUnsupportedPlatformFailsClosedBeforeAnyRemoteExec() async throws {
        let probe = missingHerdrProbe(rawOS: "FreeBSD", rawArch: "amd64")
        let installer = HerdrRemoteInstaller(
            binaryProvider: StaticBinaryProvider(data: Data("x".utf8))
        )
        let factory = RecordingInstallFactory { _ in RefusingConnection() }

        do {
            _ = try await installer.install(
                using: { try await factory.next() },
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected unsupportedPlatform")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(error, .unsupportedPlatform(os: "FreeBSD", arch: "amd64"))
        }
        XCTAssertEqual(factory.calls, 0, "the platform gate must refuse before the factory is ever resolved")
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
        let factory = RecordingInstallFactory { _ in RefusingConnection() }

        do {
            _ = try await installer.install(
                using: { try await factory.next() },
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected herdrAlreadyPresent")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(error, .herdrAlreadyPresent(path: "/usr/local/bin/herdr"))
        }
        XCTAssertEqual(factory.calls, 0, "the already-present gate must refuse before the factory is ever resolved")
    }

    func testInvalidInstallDirRejectedBeforeAnyFetchOrExec() async throws {
        let probe = missingHerdrProbe(rawOS: "Darwin", rawArch: "arm64")
        let installer = HerdrRemoteInstaller(
            binaryProvider: StaticBinaryProvider(data: Data("x".utf8))
        )

        for hostile in ["/opt/$(rm -rf ~)/bin", "/opt/herdr';id'", "", "/tmp/x y/bin", "/opt/$ORIGIN/bin"] {
            let factory = RecordingInstallFactory { _ in RefusingConnection() }
            do {
                _ = try await installer.install(
                    using: { try await factory.next() },
                    probe: probe,
                    installDir: hostile
                )
                XCTFail("expected invalidInstallDir for \(hostile)")
            } catch let error as HerdrRemoteInstallerError {
                XCTAssertEqual(error, .invalidInstallDir(hostile), "hostile dir \(hostile) must be rejected")
            }
            XCTAssertEqual(factory.calls, 0, "the install-dir gate must refuse before the factory is ever resolved")
        }
    }

    // MARK: - Per-step connection discipline on failure paths

    /// Repo-local pinned fixture binary (the checksum gate must pass
    /// before any exec step — the error-path tests need a real binary).
    private static var fixtureBinaryURL: URL {
        SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr")
    }

    /// A factory failure maps onto the failing step's typed case and
    /// resolves NO connection (nothing to close — the connection was never
    /// established).
    func testFactoryFailureMapsOntoTheFailingStepsTypedCase() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.fixtureBinaryURL.path),
            "pinned herdr fixture binary missing — run scripts/herdr-server-fetch.sh"
        )
        struct SentinelError: Error {}
        let probe = missingHerdrProbe(rawOS: "Darwin", rawArch: "arm64")
        let binary = try Data(contentsOf: Self.fixtureBinaryURL)
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let factory = RecordingInstallFactory { _ in throw SentinelError() }

        do {
            _ = try await installer.install(
                using: { try await factory.next() },
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected remotePrepareFailed")
        } catch let error as HerdrRemoteInstallerError {
            guard case let .remotePrepareFailed(detail) = error else {
                return XCTFail("expected remotePrepareFailed, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("failed to establish the install connection"),
                "the factory failure must map onto the prepare step's case: \(detail)"
            )
        }
        XCTAssertEqual(factory.calls, 0, "a throwing factory establishes nothing")
    }

    /// The prepare step's exec open is refused everywhere: the shared
    /// carrier's denial flips the installer's pool sticky-dedicated (the
    /// budget-fallback pin — a SECOND connection is dialed for the
    /// retried open), whose open is refused too, and the typed prepare
    /// failure surfaces. Both resolved connections are closed (the
    /// shared one retired by the pool, the dedicated one owner-closed by
    /// the failed step's lease) and no third connection is resolved —
    /// the upload and commit steps never ran.
    func testPrepareStepFailureClosesItsConnectionAndResolvesNoMore() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.fixtureBinaryURL.path),
            "pinned herdr fixture binary missing — run scripts/herdr-server-fetch.sh"
        )
        let probe = missingHerdrProbe(rawOS: "Darwin", rawArch: "arm64")
        let binary = try Data(contentsOf: Self.fixtureBinaryURL)
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let factory = RecordingInstallFactory { _ in RefusingConnection() }

        do {
            _ = try await installer.install(
                using: { try await factory.next() },
                probe: probe,
                installDir: "$HOME/.local/bin"
            )
            XCTFail("expected remotePrepareFailed")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(error, .remotePrepareFailed("failed to open the script exec channel"))
        }
        XCTAssertEqual(
            factory.calls, 2,
            "the shared carrier plus its dedicated fallback — the denial redialed; no step after prepare ran"
        )
        let connections = factory.connections
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(
            connections[0].closes, 1,
            "the denied shared carrier was retired (closed) by the pool"
        )
        XCTAssertEqual(
            connections[1].closes, 1,
            "the failed step's lease owner-closed its dedicated fallback connection"
        )
    }

    /// The upload step's exec open is denied by a budget gateway after a
    /// REAL prepare (the shared carrier is wrapped with a one-channel
    /// lifetime budget — the CoderSSHGW shape at the factory seam): the
    /// pool retires the shared carrier, flips sticky-dedicated, and dials
    /// the upload its OWN connection (the budget-fallback pin); the
    /// dedicated fallback's open is refused too, so the typed upload
    /// failure surfaces. Both resolved connections are closed (the
    /// shared one retired by the pool on the denial, the dedicated one
    /// owner-closed by the failed step's lease), and no third connection
    /// is resolved — the commit step never ran.
    func testUploadStepFailureClosesEveryResolvedConnection() async throws {
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.fixtureBinaryURL.path),
            "pinned herdr fixture binary missing — run scripts/herdr-server-fetch.sh"
        )
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(sshdUp, "fixture sshd not up — run scripts/fixtures-up.sh")
        let probe = try await fixtureMissingHerdrProbe()
        try XCTSkipUnless(
            probe.platformArch == "aarch64",
            "needs the pinned macos-aarch64 artifact (host arch: \(probe.platformArch ?? "unknown"))"
        )
        let installDir = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-upload-fail-target").path
        try? fm.removeItem(atPath: installDir)
        defer { try? fm.removeItem(atPath: installDir) }

        let binary = try Data(contentsOf: Self.fixtureBinaryURL)
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let factory = RecordingInstallFactory { index -> any SSHExecCapableConnection in
            switch index {
            case 0:
                // The shared carrier: a REAL fixture transport behind a
                // one-channel lifetime budget (the budget gateway) —
                // prepare succeeds on it, the upload's open is denied.
                return BudgetedConnection(
                    underlying: try await Self.makeFreshFixtureTransport(),
                    budget: 1
                )
            default:
                return RefusingConnection()
            }
        }

        do {
            _ = try await installer.install(
                using: { try await factory.next() },
                probe: probe,
                installDir: installDir
            )
            XCTFail("expected uploadFailed")
        } catch let error as HerdrRemoteInstallerError {
            XCTAssertEqual(error, .uploadFailed("failed to open the upload exec channel"))
        }
        XCTAssertEqual(
            factory.calls, 2,
            "the shared carrier plus the upload's dedicated fallback; the commit step was never reached"
        )
        let connections = factory.connections
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(
            connections[0].commands.count, 2,
            "prepare succeeded on the shared carrier and the upload's open was ATTEMPTED (and denied) there first"
        )
        XCTAssertEqual(
            connections[0].commands.first, "/bin/sh -s",
            "the prepare step ran its script exec on the shared carrier"
        )
        XCTAssertTrue(
            connections[0].commands.last?.hasPrefix("tee '") == true,
            "the denied upload attempt was the tee stream command: \(connections[0].commands)"
        )
        XCTAssertEqual(
            connections[0].closes, 1,
            "the denied shared carrier was retired (closed) by the pool"
        )
        XCTAssertEqual(
            connections[1].closes, 1,
            "the failed upload's lease owner-closed its dedicated fallback connection"
        )
    }

    // MARK: - Pin table

    func testPinTableCompleteness() {
        XCTAssertEqual(HerdrReleasePins.version, "0.9.1")
        XCTAssertEqual(
            HerdrReleasePins.Target.allCases.map(\.rawValue),
            ["linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64"]
        )
        let hex64 = try? NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        for target in HerdrReleasePins.Target.allCases {
            let asset = HerdrReleasePins.asset(for: target)
            XCTAssertEqual(
                asset.url,
                "https://github.com/herdrdev/herdr/releases/download/v0.9.1/herdr-\(target.rawValue)",
                "asset URL must be the v0.9.1 GitHub release asset for \(target.rawValue)"
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
            .appendingPathComponent("Fixtures/herdr/server-0.9.1.sha256")
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

    /// A FRESH channel-less fixture connection — the production shape the
    /// installer's factory is expected to establish (one exec per
    /// connection). NOT tracked for teardown: the installer closes the
    /// per-step connections it resolves.
    private static func makeFreshFixtureTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        try await transport.connectExecOnly(to: SSHTestFixture.makeConnection())
        return transport
    }

    /// One tracked fixture transport for the test's own probe/re-probe
    /// round-trips (closed in tearDown).
    private func makeFixtureTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key),
            metadataProvider: FixtureKeyMetadataProvider()
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        transports.append(transport)
        return transport
    }

    /// The missing-binary precondition probe over a tracked transport:
    /// search paths point nowhere on the fixture host (its exec PATH
    /// excludes every herdr location).
    private func fixtureMissingHerdrProbe() async throws -> HerdrProbe.Result {
        let transport = try await makeFixtureTransport()
        return try await HerdrProbe.run(
            on: transport,
            host: "fixture-install",
            searchPaths: ["/nonexistent-bicterm-install/herdr"]
        )
    }

    /// Full offline round-trip against the fixture sshd (this macOS arm64
    /// host): missing-binary probe → install of the repo-local pinned
    /// macos-aarch64 binary through the ``HerdrBinaryProvider`` seam into a
    /// gitignored dir under `Fixtures/run/` → file present, executable,
    /// sha256 equal to the pin, and a probe-style candidate check with an
    /// overridden search path finding a compatible herdr there. The
    /// install rides a recording factory — SHARED-FIRST: the three exec
    /// steps (prepare/upload/commit) ride ONE lazily-dialed shared
    /// connection, each exec opening on it, and the pool's close at
    /// install exit is the single close (the budget-gateway fallback
    /// shape — denial → per-step dedicated — is pinned in
    /// `SharedExecInstallPathTests` against the lifetime-1 loopback
    /// fixture).
    func testOfflineFixtureRoundTripInstallsPinnedBinary() async throws {
        let fm = FileManager.default
        let binaryURL = Self.fixtureBinaryURL
        try XCTSkipUnless(
            fm.fileExists(atPath: binaryURL.path),
            "pinned herdr fixture binary missing — run scripts/herdr-server-fetch.sh"
        )
        let sshdUp = await Self.fixtureSSHDIsReachable()
        try XCTSkipUnless(
            sshdUp,
            "fixture sshd not up — run scripts/fixtures-up.sh"
        )

        // 1. The missing-binary case: search paths point nowhere on the
        //    fixture host (its exec PATH excludes every herdr location).
        let probe = try await fixtureMissingHerdrProbe()
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
        let factory = RecordingInstallFactory { _ in try await Self.makeFreshFixtureTransport() }
        let installer = HerdrRemoteInstaller(binaryProvider: StaticBinaryProvider(data: binary))
        let outcome = try await installer.install(
            using: { try await factory.next() },
            probe: probe,
            installDir: installDir,
            progress: { progress.append($0) }
        )

        // SHARED-FIRST: exactly ONE factory resolution for the whole
        // install — the pool's lazily-dialed shared carrier carries the
        // prepare, upload, and commit execs (the pre-pool shape resolved
        // one FRESH connection per step: 3 dials).
        XCTAssertEqual(factory.calls, 1, "the three exec steps rode ONE shared connection")
        let connections = factory.connections
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(
            connections[0].commands.count, 3,
            "prepare, upload, and commit each opened their exec on the shared carrier"
        )
        XCTAssertEqual(connections[0].commands[0], "/bin/sh -s", "the prepare step runs exactly its script exec")
        XCTAssertTrue(
            connections[0].commands[1].hasPrefix("tee '"),
            "the upload step's exec is the tee stream command: \(connections[0].commands)"
        )
        XCTAssertEqual(connections[0].commands[2], "/bin/sh -s", "the commit step runs exactly its script exec")
        XCTAssertEqual(
            connections[0].closes, 1,
            "the pool's close at install exit closed the shared carrier exactly once"
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
        let reprobeTransport = try await makeFixtureTransport()
        let reprobe = try await HerdrProbe.run(
            on: reprobeTransport,
            host: "fixture-install",
            searchPaths: [dest]
        )
        XCTAssertEqual(reprobe.foundPath, dest)
        XCTAssertEqual(reprobe.version, "0.9.1")
        XCTAssertEqual(reprobe.endpointGeneration, HerdrProbe.Result.requiredGeneration)
        XCTAssertTrue(reprobe.isCompatible)

        // 5. Progress reported the milestone sequence.
        let lines = progress.snapshot
        XCTAssertFalse(lines.isEmpty, "install must report progress milestones")
        XCTAssertTrue(lines.contains { $0.contains("uploading") })
        XCTAssertTrue(lines.contains { $0.contains("installed herdr 0.9.1") })
    }
}
