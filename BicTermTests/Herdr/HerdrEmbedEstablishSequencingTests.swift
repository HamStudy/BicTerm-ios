import BicTermCore
import NIOSSH
import XCTest

@testable import BicTerm

/// Regression tests for the device-only herd establish race: concurrent
/// herd-machine SSH handshakes sign through ONE shared LAContext /
/// Secure Enclave path (the resolved key instance is shared across
/// machines — KeyResolutionCache, aa4f75b), and on device the losing
/// establish's signing failure was swallowed to `.channelDenied`
/// (device evidence: `.sisyphus/evidence/device-container/herd-diagnostic.txt`
/// — BOTH concurrent establishes failed; the simulator has no Secure
/// Enclave, so the race never reproduces there). The fix serializes
/// `establishAll`: one machine's establish at a time, in catalog order,
/// with per-machine failure isolation unchanged.
@MainActor
final class HerdrEmbedEstablishSequencingTests: XCTestCase {
    /// Repository root via this file's path — the app-hosted test
    /// convention (sibling Herdr tests) for repo-local fixture paths.
    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var scratch: URL!
    private var cwdBefore: String!
    private var savedTransportDir: String?
    private var savedStateHome: String?

    override func setUp() async throws {
        try await super.setUp()
        cwdBefore = FileManager.default.currentDirectoryPath
        // applyEnvironment() sets process-global env; save and restore so
        // a bring-up never leaks into sibling tests.
        savedTransportDir = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        savedStateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        // Repo-local scratch on the simulator host (containment rule); on
        // a physical device the build-machine path does not exist, so the
        // scratch falls back to the app container's own tmp.
        let scratchBase: URL
        if FileManager.default.fileExists(atPath: Self.repoRoot.path) {
            scratchBase = Self.repoRoot
                .appendingPathComponent("Fixtures/run/herdr-establish-sequencing-tests", isDirectory: true)
        } else {
            scratchBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("herdr-establish-sequencing-tests", isDirectory: true)
        }
        scratch = scratchBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        addTeardownBlock { [scratch] in
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    override func tearDown() async throws {
        // Belt and braces: the process cwd is global — a failed assertion
        // must not leak a pin into other tests.
        chdir(cwdBefore)
        restoreEnv("HERDR_EMBED_TRANSPORT_DIR", value: savedTransportDir)
        restoreEnv("XDG_STATE_HOME", value: savedStateHome)
        try await super.tearDown()
    }

    /// The serialization contract: no two machine establishes may overlap,
    /// and they run in catalog order. The establish seam records each
    /// machine's start/end; with the previous concurrent Task-per-link
    /// shape every machine's establish started while the first was still
    /// in flight (maxInFlight == machine count, starts before ends).
    func testEstablishesNeverOverlapAndRunInCatalogOrder() async throws {
        let links = try makeLinks(labels: ["first", "second", "third"])
        let recorder = EstablishRecorder()
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: links,
            hostKeyVerifier: nil
        )
        coordinator.homeDirectoryForTesting = scratch.path
        coordinator.establishForTesting = { link in
            await recorder.recordStart(link.machine.label)
            // Human-scale establish latency (an SSH handshake): wide
            // enough that a concurrent establish reliably starts inside
            // the window — the shape the device signing race needs.
            try? await Task.sleep(nanoseconds: 120_000_000)
            await recorder.recordEnd(link.machine.label)
            return HerdrEmbedTransportCoordinator.Established(
                link: link,
                carrierFactory: { NoopCarrier() },
                executablePath: "/usr/bin/herdr"
            )
        }

        _ = try await coordinator.prepare()

        let maxInFlight = await recorder.maxInFlight
        XCTAssertEqual(
            maxInFlight, 1,
            "machine establishes must never overlap — concurrent handshakes sign through one shared Secure Enclave path on device"
        )
        let events = await recorder.events
        XCTAssertEqual(
            events,
            [
                "started first", "ended first",
                "started second", "ended second",
                "started third", "ended third",
            ],
            "establishes run serially, in catalog order"
        )
        // Nobody lost: every machine got its bridge socket (the device
        // race's loser got none).
        for link in links {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: socketFile(for: link, coordinator: coordinator).path),
                "machine \(link.machine.label)'s bridge socket was bound"
            )
        }

        await coordinator.teardown()
    }

    /// Failure isolation across the serialization: the FIRST machine's
    /// establish failure must not block, cancel, or mark the second —
    /// the second still establishes, gets its bridge socket, and the
    /// failed machine stays in the client catalog with its own event
    /// line. Machine "alpha" fails typed before any network I/O (a
    /// session name that fails herdr's grammar); machine "beta" is a
    /// real fixture establish through the production connector path.
    func testFailingFirstMachineStillLetsTheSecondEstablish() async throws {
        try requireFixture()
        let key = try await parseFixtureKey()
        let failing = try makeLink(label: "alpha", sessionName: "-invalid")
        let healthy = try makeLink(label: "beta", sessionName: nil)
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: [failing, healthy],
            preferredSelection: nil,
            hostKeyVerifier: try await makeTrustedVerifier(),
            authenticationKeyProvider: { SequencingKeyProvider(key: key) },
            metadataProvider: FixtureHerdrKeyMetadataProvider(),
            searchPaths: [Self.herdrBin]
        )
        coordinator.homeDirectoryForTesting = scratch.path

        _ = try await coordinator.prepare()

        XCTAssertTrue(
            coordinator.eventLines.contains {
                $0.hasPrefix("alpha: bring-up failed — connector: ")
            },
            "alpha's failure surfaced as its own per-machine event line: \(coordinator.eventLines)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile(for: healthy, coordinator: coordinator).path),
            "beta established and bridged despite alpha's failure"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketFile(for: failing, coordinator: coordinator).path),
            "the failed machine got no bridge socket"
        )
        // The isolation contract: the failed machine stays in the client
        // catalog so the client renders its own dial-failure state.
        let stateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        let catalogURL = URL(fileURLWithPath: try XCTUnwrap(stateHome))
            .appendingPathComponent("herdr/client/endpoints.json")
        let catalog = try String(contentsOf: catalogURL, encoding: .utf8)
        XCTAssertTrue(
            catalog.contains(healthy.machine.profileID),
            "the catalog seeds the healthy machine"
        )
        XCTAssertTrue(
            catalog.contains(failing.machine.profileID),
            "the catalog still seeds the failed machine"
        )

        await coordinator.teardown()
    }

    // MARK: - Helpers

    private func makeLinks(labels: [String]) throws -> [HerdrEmbedMachineLink] {
        try labels.map { try makeLink(label: $0, sessionName: nil) }
    }

    private func makeLink(label: String, sessionName: String?) throws -> HerdrEmbedMachineLink {
        var options = ProtocolOptions()
        if let sessionName {
            options = try ProtocolOptions([
                ProtocolOptions.herdrSessionKey: .string(sessionName)
            ])
        }
        let connection = try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            customKeys: ["fixture-ed25519"],
            protocolOptions: options
        )
        return HerdrEmbedMachineLink(
            machine: HerdrEmbedMachine.forConnection(connection),
            connection: connection,
            bridgeSessionName: connection.herdrSessionName
        )
    }

    private func socketFile(
        for link: HerdrEmbedMachineLink,
        coordinator: HerdrEmbedTransportCoordinator
    ) -> URL {
        scratch.appendingPathComponent(coordinator.socketPath(for: link.machine))
    }

    private func parseFixtureKey() async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: Self.repoRoot.appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519"))
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }

    /// Pre-trusts the direct fixture endpoint (127.0.0.1:12222) so the
    /// healthy machine's establish never prompts.
    private func makeTrustedVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let keyURL = Self.repoRoot
            .appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        let line = try String(contentsOf: keyURL, encoding: .utf8)
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw NSError(domain: "HerdrEmbedEstablishSequencingTests", code: 1)
        }
        try await verifier.trust(
            host: "127.0.0.1",
            port: 12222,
            key: blob,
            algorithm: String(parts[0])
        )
        return verifier
    }

    private func requireFixture() throws {
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.herdrBin)
                && fm.fileExists(
                    atPath: Self.repoRoot
                        .appendingPathComponent("Fixtures/run/herdr/server-12222/herdr-client.sock")
                        .path
                ),
            "herdr fixture on 12222 not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
        )
    }

    private func restoreEnv(_ name: String, value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    private nonisolated static var fixtureUsername: String {
        for candidate in [
            ProcessInfo.processInfo.environment["USER"],
            ProcessInfo.processInfo.environment["LOGNAME"],
            NSUserName(),
        ] where candidate != nil && !candidate!.isEmpty {
            return candidate!
        }
        return "richard"
    }

    private nonisolated static var herdrBin: String {
        repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr").path
    }
}

/// Records per-machine establish intervals from inside the establish
/// seam: `maxInFlight` is the overlap signal (the pre-fix concurrent
/// Task-per-link shape drove it to the machine count), `events` is the
/// strict serial-order proof.
private actor EstablishRecorder {
    private(set) var events: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0

    func recordStart(_ label: String) {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        events.append("started \(label)")
    }

    func recordEnd(_ label: String) {
        inFlight -= 1
        events.append("ended \(label)")
    }
}

/// Supplies the fixture ed25519 key regardless of the Keychain reference
/// (the app-hosted test process has no Keychain entry for it).
private struct SequencingKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext? = nil
    ) async throws -> NIOSSHPrivateKey {
        key
    }
}

/// Carrier double: the bridge only touches it when a relay connects, and
/// nothing ever dials the test's bridge sockets.
private struct NoopCarrier: SSHExecCapableConnection {
    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        throw .channelDenied
    }

    func close() async {}
}
