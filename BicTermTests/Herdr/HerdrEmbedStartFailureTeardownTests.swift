import BicTermCore
import XCTest

@testable import BicTerm

private let startFailureMarker = "embed start refused (test)"

/// Failure-B regression (on-device retry loop): a prepared transport whose
/// embed session FAILS TO START must be torn down like a prepare failure.
/// The catch around `session.start` used to set `.failed`, finish the
/// stream, and nil the session — but never tear down the prepared
/// coordinator, so its bridge listeners, carriers, and cwd pin survived,
/// and every retry collided with the orphaned listener
/// (`liveListenerExists`) run after run. Deterministic: the establish seam
/// injects fake carriers (no SSH, no fixtures), the home seam points the
/// pin + transport directory at repo-local scratch, and the session
/// factory seam injects a start-throwing session.
@MainActor
final class HerdrEmbedStartFailureTeardownTests: XCTestCase {
    /// Repository root via this file's path — the app-hosted test
    /// convention (sibling Herdr tests) for repo-local fixture paths.
    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var scratch: URL!
    private var cwdBefore: String!

    override func setUp() async throws {
        try await super.setUp()
        cwdBefore = FileManager.default.currentDirectoryPath
        // Repo-local scratch (gitignored `Fixtures/run/`), unique per run:
        // containment rule plus no parallel-test collisions. On a physical
        // device the build-machine path does not exist — fall back to the
        // app container's own tmp so the suite runs there too.
        let scratchBase: URL
        if FileManager.default.fileExists(atPath: Self.repoRoot.path) {
            scratchBase = Self.repoRoot
                .appendingPathComponent("Fixtures/run/herdr-start-failure-tests", isDirectory: true)
        } else {
            scratchBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("herdr-start-failure-tests", isDirectory: true)
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
        try await super.tearDown()
    }

    func testFailedEmbedStartTearsDownTransportAndRetryBindsCleanly() async throws {
        let connection = try Connection(
            name: "start-failure",
            type: .ssh,
            host: "127.0.0.1",
            port: 1,
            username: "fixture"
        )
        let session = StartThrowingSession()
        let runtime = HerdrEmbedRuntime(sessionFactory: { session })

        let first = makeCoordinator(connection: connection)
        let firstSocketFile = scratch
            .appendingPathComponent(first.socketPath(for: .forConnection(connection)))
        runtime.attachTransport(first)
        await runtime.startIfNeeded()

        guard case let .failed(message) = runtime.phase else {
            XCTFail("the throwing session start must fail the run, got \(runtime.phase)")
            return
        }
        XCTAssertTrue(
            message.contains(startFailureMarker),
            "the failure is the session's own, not a bridge error: \(message)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstSocketFile.path),
            "the failed start tore down its bridge listener (no orphaned socket)"
        )
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "the failed start released the cwd pin"
        )

        // The retry must bind cleanly: the first run's leaked listener is
        // exactly what produced liveListenerExists on device, run after run.
        let retry = makeCoordinator(connection: connection)
        let retrySocketFile = scratch
            .appendingPathComponent(retry.socketPath(for: .forConnection(connection)))
        runtime.attachTransport(retry)
        await runtime.startIfNeeded()

        guard case let .failed(retryMessage) = runtime.phase else {
            XCTFail("the retry must also fail at the session start, got \(runtime.phase)")
            return
        }
        XCTAssertTrue(
            retryMessage.contains(startFailureMarker),
            "the retry bound its bridges cleanly (no liveListenerExists): \(retryMessage)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: retrySocketFile.path),
            "the retry's own failure also tore its listener down"
        )
    }

    // MARK: - Helpers

    private func makeCoordinator(connection: Connection) -> HerdrEmbedTransportCoordinator {
        let coordinator = HerdrEmbedTransportCoordinator(
            connection: connection,
            hostKeyVerifier: nil
        )
        coordinator.homeDirectoryForTesting = scratch.path
        coordinator.establishForTesting = { link in
            HerdrEmbedTransportCoordinator.Established(
                link: link,
                carrier: NoopCarrier(),
                executablePath: "/usr/bin/herdr"
            )
        }
        return coordinator
    }
}

/// `HerdrEmbedSession` double whose start always fails — the embed boot
/// failure under test. Nothing else is ever reached.
private final class StartThrowingSession: HerdrEmbedSession, @unchecked Sendable {
    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (String?) -> Void)?

    func start(config: HerdrEmbedSessionConfig) throws {
        throw StartRefusedError()
    }

    func writeInput(_ data: Data) {}

    func setWinsize(cols: Int, rows: Int) {}

    var isRunning: Bool { false }

    func stopBlocking() {}
}

private struct StartRefusedError: Error, CustomStringConvertible {
    var description: String { startFailureMarker }
}

/// Carrier double: the bridge only touches it when a relay connects, and
/// nothing ever dials the test's bridge sockets.
private struct NoopCarrier: SSHExecCapableConnection {
    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        throw .channelDenied
    }

    func close() async {}
}
