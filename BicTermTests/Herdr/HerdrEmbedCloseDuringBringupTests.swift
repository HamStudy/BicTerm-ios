import BicTermCore
import NIOSSH
import XCTest

@testable import BicTerm

/// F2 follow-up: the close-during-bringup orphan. A window closed while
/// the transport is still preparing (phase `.idle`, requestStop's old
/// guard no-oped) let the embedded client finish booting headless, and a
/// pending TOFU prompt's continuation leaked its coordinator for the
/// process lifetime. These tests drive open → close at each bring-up
/// suspension point and assert the orphan invariants:
/// - no headless boot completes (the session never starts, or boots then
///   immediately stops),
/// - the bridge socket path is left clean and the process cwd restored,
/// - the coordinator deallocates (weak-reference tracking — the prompt
///   continuation and establish tasks must unwind),
/// - the next open on the same runtime is clean.
/// Written failing-first against HEAD 3712ee9.
@MainActor
final class HerdrEmbedCloseDuringBringupTests: XCTestCase {
    private var environmentGuard: String?

    override func setUp() async throws {
        try await super.setUp()
        environmentGuard = ProcessInfo.processInfo.environment["HERDR_EMBED_SOCKET_PATH"]
        setenv("HERDR_EMBED_SOCKET_PATH", "/dev/null/herdr-embed-close-audit", 1)
    }

    override func tearDown() async throws {
        if let environmentGuard {
            setenv("HERDR_EMBED_SOCKET_PATH", environmentGuard, 1)
        } else {
            unsetenv("HERDR_EMBED_SOCKET_PATH")
        }
        try await super.tearDown()
    }

    // MARK: - (a) plain close mid-prepare (no TOFU pending)

    /// The bring-up suspends inside prepare() before any network work
    /// (the coordinator's authentication-key gate); closing the window
    /// there must unwind the bring-up instead of letting it finish.
    func testCloseDuringPlainPrepareUnwindsBringUpWithoutHeadlessBoot() async throws {
        let stub = CloseAuditStubSession()
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        let gate = SuspensionGate()
        // Port 1 is unbound: if the gate releases after cancellation and
        // establish proceeds anyway, it fails fast without fixtures.
        let connection = try Connection(
            name: "close-plain",
            type: .ssh,
            host: "127.0.0.1",
            port: 1,
            username: "fixture",
            customKeys: ["fixture-ed25519"]
        )
        weak var weakCoordinator: HerdrEmbedTransportCoordinator?
        var bringUpSocketPath = ""
        do {
            let coordinator = HerdrEmbedTransportCoordinator(
                connection: connection,
                hostKeyVerifier: HostKeyVerifier(store: InMemoryHostKeyStoreFallback()),
                authenticationKeyProvider: {
                    await gate.wait()
                    return DefaultSSHAuthenticationKeyProvider()
                },
                searchPaths: ["/nonexistent-herdr"]
            )
            weakCoordinator = coordinator
            runtime.attachTransport(coordinator)
            bringUpSocketPath = coordinator.socketPath(for: .forConnection(connection))
        }
        addTeardownBlock { @MainActor in gate.open() }
        let cwdBefore = FileManager.default.currentDirectoryPath

        let settled = XCTestExpectation(description: "bring-up settled")
        Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }
        let suspended = await poll({ gate.isWaiting }, timeout: 10)
        XCTAssertTrue(suspended, "prepare() suspended mid-bring-up before the close")

        await runtime.requestStop()

        await fulfillment(of: [settled], timeout: 15)

        XCTAssertEqual(stub.startCalls, 0, "no headless boot: the session factory never started a client")
        guard case .stopped = runtime.phase else {
            XCTFail("a close during prepare is a quiet stop, got \(runtime.phase)")
            return
        }
        XCTAssertNil(runtime.failureDiagnostic, "the unwind is not a failure screen")
        XCTAssertNil(runtime.output, "the output stream was finished")
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "the pinned cwd was restored (never left) by the unwind"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bringUpSocketPath),
            "no bridge socket survived the closed bring-up"
        )
        let released = await poll({ weakCoordinator == nil }, timeout: 10)
        XCTAssertTrue(released, "the coordinator deallocates — no establish task or continuation leak")

        // Next open on the SAME runtime is clean: the legacy socket path
        // boots the (stub) client and stops normally.
        await runtime.startIfNeeded()
        XCTAssertEqual(stub.startCalls, 1, "the next open boots exactly one client")
        guard case .running = runtime.phase else {
            XCTFail("next open after a closed bring-up must run, got \(runtime.phase)")
            return
        }
        await runtime.requestStop()
        guard case .stopped = runtime.phase else {
            XCTFail("the reopened run stops cleanly, got \(runtime.phase)")
            return
        }
        let stillReleased = await poll({ weakCoordinator == nil }, timeout: 10)
        XCTAssertTrue(stillReleased, "the coordinator stays released after the reopen cycle")
    }

    // MARK: - (b) close mid-prepare with a pending TOFU prompt (fixtures)

    /// The bring-up suspends at a REAL TOFU challenge from the fixture
    /// sshd; closing with the prompt pending must resume the prompt's
    /// continuation (declined), release the coordinator, and leave the
    /// next open clean.
    func testCloseDuringPrepareWithPendingTOFUPromptResumesPromptAndReleasesCoordinator() async throws {
        try requireFixtures(serverPort: 12222)
        let stub = CloseAuditStubSession()
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        let connection = try makeDirectConnection(label: "close-tofu")
        let key = try await parseFixtureKey()
        weak var weakCoordinator: HerdrEmbedTransportCoordinator?
        var bringUpSocketPath = ""
        do {
            let coordinator = HerdrEmbedTransportCoordinator(
                connection: connection,
                hostKeyVerifier: HostKeyVerifier(store: InMemoryHostKeyStoreFallback()),
                authenticationKeyProvider: { StaticFixtureKeyProvider(key: key) },
                metadataProvider: FixtureHerdrKeyMetadataProvider(),
                searchPaths: [Self.herdrBin]
            )
            weakCoordinator = coordinator
            runtime.attachTransport(coordinator)
            bringUpSocketPath = coordinator.socketPath(for: .forConnection(connection))
            addTeardownBlock { @MainActor [weak coordinator] in
                coordinator?.resolveTrustPrompt(false)
            }
        }
        let cwdBefore = FileManager.default.currentDirectoryPath

        let settled = XCTestExpectation(description: "bring-up settled")
        Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }
        let prompted = await poll({ weakCoordinator?.trustPrompt != nil }, timeout: 15)
        XCTAssertTrue(prompted, "the TOFU challenge suspended the bring-up at the prompt")

        await runtime.requestStop()

        await fulfillment(of: [settled], timeout: 20)

        XCTAssertEqual(stub.startCalls, 0, "no headless boot behind the pending prompt")
        guard case .stopped = runtime.phase else {
            XCTFail("closing at a pending TOFU prompt is a quiet stop, got \(runtime.phase)")
            return
        }
        XCTAssertNil(runtime.failureDiagnostic, "the prompt release is not a failure screen")
        XCTAssertNil(
            weakCoordinator?.trustPrompt,
            "the prompt was consumed by the unwind (nil when released or deallocated)"
        )
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "the pinned cwd was restored by the unwind"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bringUpSocketPath),
            "no bridge socket survived the closed bring-up"
        )
        let released = await poll({ weakCoordinator == nil }, timeout: 10)
        XCTAssertTrue(
            released,
            "the pending prompt's continuation resumed and the coordinator deallocated"
        )

        // Next open clean through a trusted coordinator: the transport
        // re-establishes, its bridge listener binds, and the run stops
        // with unlink + cwd-restore receipts. (The stub-hosted runtime
        // proves transport bring-up; the real client's relay-through is
        // HerdrEmbedTransportTests' surface.)
        let fresh = try await makeTrustedCoordinator(connection: connection)
        runtime.attachTransport(fresh)
        await runtime.startIfNeeded()
        guard case .running = runtime.phase else {
            XCTFail("next open after a prompt-close bring-up must run, got \(runtime.phase)")
            return
        }
        XCTAssertEqual(stub.startCalls, 1, "the reopened run booted exactly one (stub) client")
        let socketFile = NSHomeDirectory()
            + "/\(fresh.socketPath(for: .forConnection(connection)))"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile),
            "the reopened bring-up bound its bridge listener"
        )
        await runtime.requestStop()
        let cwdRestored = await poll(
            { FileManager.default.currentDirectoryPath == cwdBefore },
            timeout: 10
        )
        XCTAssertTrue(cwdRestored, "cwd restored at the final teardown")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketFile),
            "the reopened run's bridge socket unlinked at teardown"
        )
    }

    // MARK: - close during the boot window

    /// The boot continuation is cancellation-blind by FFI contract
    /// (`session.start` returns when it returns); a close while it is in
    /// flight must observe the stop AFTER it resumes and tear the client
    /// down instead of completing a headless run.
    func testCloseDuringBootWindowTearsDownInsteadOfCompletingHeadless() async throws {
        let stub = CloseAuditStubSession()
        stub.blockStartUntilStop = true
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })

        let settled = XCTestExpectation(description: "bring-up settled")
        Task {
            await runtime.startIfNeeded()
            settled.fulfill()
        }
        let entered = await poll({ stub.startEntered }, timeout: 10)
        XCTAssertTrue(entered, "the boot continuation is in flight")

        await runtime.requestStop()

        await fulfillment(of: [settled], timeout: 15)

        XCTAssertTrue(stub.startReturned, "the blocked start was released by the stop")
        XCTAssertGreaterThanOrEqual(stub.stopCalls, 1, "the FFI stop debt was settled")
        guard case .stopped = runtime.phase else {
            XCTFail("the boot continuation observed the stop, got \(runtime.phase)")
            return
        }
        XCTAssertNil(runtime.output, "the output stream was finished, not left headless")
        XCTAssertEqual(
            runtime.bytesWritten, 0,
            "a closed-during-boot run never accepts input"
        )

        // Next open clean: the same stub (unblocked now) boots and stops.
        stub.blockStartUntilStop = false
        await runtime.startIfNeeded()
        XCTAssertEqual(stub.startCalls, 2)
        guard case .running = runtime.phase else {
            XCTFail("next open after a boot-window close must run, got \(runtime.phase)")
            return
        }
        await runtime.requestStop()
        guard case .stopped = runtime.phase else {
            XCTFail("the reopened run stops cleanly, got \(runtime.phase)")
            return
        }
    }

    // MARK: - Helpers

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

    private func requireFixtures(serverPort: Int) throws {
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.herdrBin)
                && fm.fileExists(
                    atPath: Self.repoRoot
                        .appendingPathComponent("Fixtures/run/herdr/server-\(serverPort)/herdr-client.sock")
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

    private func makeTrustedCoordinator(
        connection: Connection
    ) async throws -> HerdrEmbedTransportCoordinator {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let keyPath = Self.repoRoot
            .appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")
        let line = try String(contentsOf: keyPath, encoding: .utf8)
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw NSError(domain: "HerdrEmbedCloseDuringBringupTests", code: 1)
        }
        try await verifier.trust(
            host: connection.host, port: connection.port,
            key: blob, algorithm: String(parts[0])
        )
        let key = try await parseFixtureKey()
        return HerdrEmbedTransportCoordinator(
            connection: connection,
            hostKeyVerifier: verifier,
            authenticationKeyProvider: { StaticFixtureKeyProvider(key: key) },
            metadataProvider: FixtureHerdrKeyMetadataProvider(),
            searchPaths: [Self.herdrBin]
        )
    }
}

// MARK: - Doubles

/// `HerdrEmbedSession` double for bring-up audits: counts starts/stops,
/// and can hold `start()` blocked until `stopBlocking()` releases it —
/// the FFI boot-window shape (stop is what unblocks a booting client).
final class CloseAuditStubSession: HerdrEmbedSession, @unchecked Sendable {
    private let lock = NSLock()
    private var startCallsCount = 0
    private var stopCallsCount = 0
    private var startEnteredFlag = false
    private var startReturnedFlag = false
    private let startSemaphore = DispatchSemaphore(value: 0)

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (_ detail: String?) -> Void)?

    /// When true, `start` blocks until `stopBlocking` releases it.
    var blockStartUntilStop = false

    var startCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCallsCount
    }

    var stopCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCallsCount
    }

    var startEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startEnteredFlag
    }

    var startReturned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startReturnedFlag
    }

    func start(config: HerdrEmbedSessionConfig) throws {
        lock.lock()
        startCallsCount += 1
        startEnteredFlag = true
        let shouldBlock = blockStartUntilStop
        lock.unlock()
        if shouldBlock {
            startSemaphore.wait()
        }
        lock.lock()
        startReturnedFlag = true
        lock.unlock()
    }

    func writeInput(_ data: Data) {}

    func setWinsize(cols: Int, rows: Int) {}

    var isRunning: Bool { true }

    func stopBlocking() {
        lock.lock()
        stopCallsCount += 1
        lock.unlock()
        startSemaphore.signal()
        onExit?(nil)
    }
}

/// Deterministic suspension inside transport prepare(): `wait()` parks
/// the caller (an establish task) until opened — by the test, or by task
/// cancellation (the cancellation-responsive shape every real await
/// should have).
private final class SuspensionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.open()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
