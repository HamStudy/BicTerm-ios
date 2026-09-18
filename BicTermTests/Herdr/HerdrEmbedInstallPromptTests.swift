import BicTermCore
import NIOSSH
import XCTest

@testable import BicTerm

/// Stage B install-consent prompts on the embed transport coordinator:
/// the missing-binary probe outcome proposes through the coordinator's
/// InstallPrompt queue (one decision at a time, per machine, per attempt),
/// a decline ends the bring-up quietly (user cancellation, no failure
/// screen, no binary ever fetched), an approved install that fails
/// surfaces the typed diagnostic, and a close with a pending consent
/// resumes it declined so nothing parks the coordinator. Mirrors the
/// TOFU trust-prompt tests' shapes (HerdrEmbedHardeningTests,
/// HerdrEmbedCloseDuringBringupTests).
@MainActor
final class HerdrEmbedInstallPromptTests: XCTestCase {
    private var environmentGuard: String?

    override func setUp() async throws {
        try await super.setUp()
        environmentGuard = ProcessInfo.processInfo.environment["HERDR_EMBED_SOCKET_PATH"]
        setenv("HERDR_EMBED_SOCKET_PATH", "/dev/null/herdr-embed-install-prompt", 1)
    }

    override func tearDown() async throws {
        if let environmentGuard {
            setenv("HERDR_EMBED_SOCKET_PATH", environmentGuard, 1)
        } else {
            unsetenv("HERDR_EMBED_SOCKET_PATH")
        }
        try await super.tearDown()
    }

    // MARK: - Test doubles

    /// Provider double that records calls and serves wrong bytes: the
    /// decline tests assert it was never asked for the binary, and the
    /// approval-failure test relies on the client-side checksum gate.
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

    // MARK: - Fixture plumbing

    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private nonisolated static var herdrBin: String {
        repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr").path
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

    private func requireFixtures() throws {
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.herdrBin)
                && fm.fileExists(
                    atPath: Self.repoRoot
                        .appendingPathComponent("Fixtures/run/herdr/server-12222/herdr-client.sock")
                        .path
                ),
            "herdr fixture not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
        )
    }

    private func makeDirectConnection(label: String) throws -> Connection {
        try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            customKeys: ["fixture-ed25519"]
        )
    }

    private func parseFixtureKey() async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: Self.repoRoot
                .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519"))
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }

    /// Verifier that already trusts the fixture sshd's host key, so the
    /// bring-up passes TOFU and reaches the probe (and its missing-binary
    /// install proposal) without a trust prompt.
    private func makeTrustedVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let keyPath = Self.repoRoot
            .appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        let line = try String(contentsOf: keyPath, encoding: .utf8)
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw NSError(domain: "HerdrEmbedInstallPromptTests", code: 1)
        }
        try await verifier.trust(
            host: "127.0.0.1", port: 12222,
            key: blob, algorithm: String(parts[0])
        )
        return verifier
    }

    /// Coordinator whose machines probe search paths that find nothing:
    /// every establish reaches the missing-binary install proposal. The
    /// installer is the seam-injected recording provider — no network.
    private func makeMissingHerdrCoordinator(
        connections: [Connection],
        provider: RecordingBinaryProvider
    ) async throws -> HerdrEmbedTransportCoordinator {
        let verifier = try await makeTrustedVerifier()
        let key = try await parseFixtureKey()
        let links = try connections.map { connection in
            HerdrEmbedMachineLink(
                machine: HerdrEmbedMachine.forConnection(connection),
                connection: connection,
                bridgeSessionName: connection.herdrSessionName
            )
        }
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: links,
            hostKeyVerifier: verifier,
            authenticationKeyProvider: { StaticFixtureKeyProvider(key: key) },
            metadataProvider: FixtureHerdrKeyMetadataProvider(),
            searchPaths: ["/nonexistent-herdr-install/herdr"]
        )
        coordinator.remoteInstallerForTesting = HerdrRemoteInstaller(
            binaryProvider: provider
        )
        return coordinator
    }

    private func poll(
        _ condition: () -> Bool,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - Decline ends quietly, one decision at a time

    /// Both machines' missing-binary outcomes propose the install, one
    /// consent at a time; declining each ends the bring-up quietly with
    /// no failure screen and no binary fetch.
    func testDecliningEveryHerdMachineInstallPromptEndsQuietly() async throws {
        try requireFixtures()
        let provider = RecordingBinaryProvider()
        let coordinator = try await makeMissingHerdrCoordinator(
            connections: [
                try makeDirectConnection(label: "alpha"),
                try makeDirectConnection(label: "beta"),
            ],
            provider: provider
        )
        let runtime = HerdrEmbedRuntime(sessionFactory: { CloseAuditStubSession() })
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }

        let settled = XCTestExpectation(description: "bring-up settled")
        let startTask = Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }

        var declined = 0
        for machine in 1...2 {
            let proposed = await poll({ coordinator.installPrompt != nil }, timeout: 15)
            XCTAssertTrue(proposed, "machine \(machine)'s install consent was presented")
            guard let prompt = coordinator.installPrompt else { return }
            XCTAssertEqual(prompt.consent.host, "127.0.0.1")
            XCTAssertEqual(prompt.consent.version, HerdrReleasePins.version)
            XCTAssertEqual(prompt.consent.installDir, HerdrRemoteInstaller.defaultInstallDir)
            XCTAssertEqual(prompt.consent.destinationPath, "$HOME/.local/bin/herdr")
            declined += 1
            coordinator.resolveInstallPrompt(false)
        }
        XCTAssertEqual(declined, 2, "each machine's consent was declined, one decision at a time")

        await fulfillment(of: [settled], timeout: 30)
        _ = await startTask.result

        await waitForQuietStop(runtime)
        XCTAssertTrue(
            provider.requestedTargets.isEmpty,
            "a declined install never fetches the binary"
        )
        XCTAssertFalse(
            coordinator.eventLines.contains { $0.contains("bridge relay opened") }
        )
    }

    // MARK: - Approved install failure surfaces the typed diagnostic

    /// Approving the consent runs the installer; a failing install (here
    /// the client-side checksum gate) surfaces the typed transportLost
    /// diagnostic — never a crash or a silent swallow.
    func testApprovedInstallFailureSurfacesTypedDiagnostic() async throws {
        try requireFixtures()
        let provider = RecordingBinaryProvider()
        let coordinator = try await makeMissingHerdrCoordinator(
            connections: [try makeDirectConnection(label: "install-fail")],
            provider: provider
        )
        let runtime = HerdrEmbedRuntime(sessionFactory: { CloseAuditStubSession() })
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }

        let settled = XCTestExpectation(description: "bring-up settled")
        let startTask = Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }

        let proposed = await poll({ coordinator.installPrompt != nil }, timeout: 15)
        XCTAssertTrue(proposed, "the install consent was presented")
        coordinator.resolveInstallPrompt(true)

        await fulfillment(of: [settled], timeout: 30)
        _ = await startTask.result

        XCTAssertEqual(provider.requestedTargets.count, 1, "the approved install fetched the binary")
        let diagnostic = try XCTUnwrap(
            runtime.failureDiagnostic,
            "the failed install is a typed diagnostic, not a bare string"
        )
        XCTAssertEqual(diagnostic.kind, .transportLost)
        XCTAssertTrue(
            diagnostic.detail.contains("sha256"),
            "the diagnostic carries the installer's typed failure: \(diagnostic.detail)"
        )
        guard case .failed = runtime.phase else {
            return XCTFail("a failed install must fail the run, got \(runtime.phase)")
        }
    }

    // MARK: - Close with a pending consent

    /// The bring-up suspends at the install consent; closing the
    /// workspace there must resume the consent's continuation (declined),
    /// release the coordinator, and leave the next open clean.
    func testCloseDuringPrepareWithPendingInstallPromptResumesPromptAndReleasesCoordinator() async throws {
        try requireFixtures()
        let stub = CloseAuditStubSession()
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        let provider = RecordingBinaryProvider()
        let connection = try makeDirectConnection(label: "close-install")
        weak var weakCoordinator: HerdrEmbedTransportCoordinator?
        do {
            let coordinator = try await makeMissingHerdrCoordinator(
                connections: [connection],
                provider: provider
            )
            weakCoordinator = coordinator
            runtime.attachTransport(coordinator)
            addTeardownBlock { @MainActor [weak coordinator] in
                coordinator?.resolveInstallPrompt(false)
            }
        }

        let settled = XCTestExpectation(description: "bring-up settled")
        Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }
        let prompted = await poll({ weakCoordinator?.installPrompt != nil }, timeout: 15)
        XCTAssertTrue(prompted, "the install consent suspended the bring-up at the prompt")

        await runtime.requestStop()

        await fulfillment(of: [settled], timeout: 20)

        XCTAssertEqual(stub.startCalls, 0, "no headless boot behind the pending consent")
        guard case .stopped = runtime.phase else {
            return XCTFail("closing at a pending install consent is a quiet stop, got \(runtime.phase)")
        }
        XCTAssertNil(runtime.failureDiagnostic, "the consent release is not a failure screen")
        XCTAssertNil(
            weakCoordinator?.installPrompt,
            "the consent was consumed by the unwind (nil when released or deallocated)"
        )
        XCTAssertTrue(
            provider.requestedTargets.isEmpty,
            "the released consent never fetched the binary"
        )
        let released = await poll({ weakCoordinator == nil }, timeout: 10)
        XCTAssertTrue(
            released,
            "the pending consent's continuation resumed and the coordinator deallocated"
        )
    }

    // MARK: - Helpers

    private func waitForQuietStop(_ runtime: HerdrEmbedRuntime) async {
        let stopped = await poll(
            {
                if case .stopped = runtime.phase { return true }
                return false
            },
            timeout: 15
        )
        XCTAssertTrue(stopped, "declining every install consent ends the bring-up quietly")
        XCTAssertNil(
            runtime.failureDiagnostic,
            "a declined install consent is not a failure screen"
        )
    }
}
