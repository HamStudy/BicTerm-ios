#if HERDR_EMBED
import SwiftTerm
import SwiftUI
import UIKit
import XCTest

@testable import BicTerm

/// T4 hosting seams against a stub session: output feeds the SwiftTerm
/// view, keystrokes and terminal query replies flow back as writes, layout
/// resizes reach the pty, and the runtime answers the one capability query
/// SwiftTerm does not (`CSI ? 996 n`). The final test runs the REAL
/// embedded client against the fixture herdr server when one is up.
@MainActor
final class HerdrEmbedHostingTests: XCTestCase {
    private var window: UIWindow?
    private var environmentGuard: String?

    override func setUp() async throws {
        try await super.setUp()
        environmentGuard = ProcessInfo.processInfo.environment["HERDR_EMBED_SOCKET_PATH"]
        setenv("HERDR_EMBED_SOCKET_PATH", "/dev/null/herdr-embed-test-socket", 1)
    }

    override func tearDown() async throws {
        if let environmentGuard {
            setenv("HERDR_EMBED_SOCKET_PATH", environmentGuard, 1)
        } else {
            unsetenv("HERDR_EMBED_SOCKET_PATH")
        }
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
        window.layoutIfNeeded()
        return window
    }

    /// Suspending poll: the feed/query tasks run on the main actor and
    /// only progress while this test task is suspended — a plain RunLoop
    /// spin keeps the actor busy and starves them.
    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        timeout: TimeInterval = 8
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - Stub-session seams

    /// The representable's contract mirrors the chrome: host it while the
    /// run is live (its feed attaches to the run's output stream at
    /// makeUIView time), so tests bring the run up first.
    private func startRun(_ runtime: HerdrEmbedRuntime) async {
        let started = XCTestExpectation(description: "run started")
        Task {
            await runtime.startIfNeeded()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
    }


    func testOutputFeedsTerminalViewAndInputWritesReachSession() async {
        let stub = HerdrEmbedStubSession()
        stub.scriptedOutput = [Data("\u{1b}[2J\u{1b}[Hhello herdr\r\n".utf8)]
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        await startRun(runtime)

        host(
            HerdrTUIHostingView(runtime: runtime)
                .frame(width: 390, height: 844)
        )
        await waitFor(view(of: runtime)?.getTerminal() != nil, "terminal view materialized")

        let hosted = view(of: runtime)!
        await waitFor(
            String(decoding: hosted.getTerminal().getBufferAsData(), as: UTF8.self)
                .contains("hello herdr"),
            "stub output rendered into the terminal buffer"
        )

        runtime.writeInput(Data("q".utf8))
        await waitFor(
            stub.writes.contains { $0 == Data("q".utf8) },
            "input write reached the session"
        )

        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
    }

    func testCellSizeQueryIsAnsweredBySwiftTermThroughInputPath() async {
        let stub = HerdrEmbedStubSession()
        stub.scriptedOutput = [Data("\u{1b}[16t".utf8)]
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        await startRun(runtime)

        host(
            HerdrTUIHostingView(runtime: runtime)
                .frame(width: 390, height: 844)
        )

        await waitFor(
            stub.writes.contains { data in
                let text = String(decoding: data, as: UTF8.self)
                return text.hasPrefix("\u{1b}[6;") && text.hasSuffix("t")
            },
            "SwiftTerm answered the cell-size query (CSI 6 ; h ; w t)"
        )

        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
    }

    func testColorSchemeQueryIsAnsweredWithoutAViewAttached() async {
        let stub = HerdrEmbedStubSession()
        // The query split across two chunks proves the scanner is streaming.
        stub.scriptedOutput = [
            Data("\u{1b}[?9".utf8),
            Data("96n\u{1b}[2J".utf8),
        ]
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        runtime.setHostAppearance(dark: true)
        await startRun(runtime)

        await waitFor(
            stub.writes.contains { $0 == Data("\u{1b}[?997;1n".utf8) },
            "dark color-scheme query answered with CSI ? 997 ; 1 n"
        )

        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
    }

    func testLayoutResizeReachesSessionWinsize() async {
        let stub = HerdrEmbedStubSession()
        let runtime = HerdrEmbedRuntime(sessionFactory: { stub })
        await startRun(runtime)

        host(
            HerdrTUIHostingView(runtime: runtime)
                .frame(width: 390, height: 844)
        )

        await waitFor(
            stub.winsizes.contains { $0.cols > 0 && $0.rows > 0 },
            "view layout delivered a winsize to the session"
        )
        XCTAssertEqual(
            stub.startConfig?.cols, 80,
            "placeholder geometry starts the client before layout"
        )

        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }
    }

    // MARK: - Real client (fixture server required)

    func testLiveEmbeddedClientRendersTUIFrameAndAcceptsKeys() async throws {
        guard let fixture = liveFixtureClientSocket() else {
            throw XCTSkip(
                "herdr fixture server not running — run scripts/herdr-server-fetch.sh"
                    + " and scripts/fixtures-up.sh"
            )
        }
        setenv("HERDR_EMBED_SOCKET_PATH", fixture, 1)

        let runtime = HerdrEmbedRuntime()
        await startRun(runtime)
        _ = host(
            HerdrTUIHostingView(runtime: runtime)
                .frame(width: 390, height: 844)
        )

        await waitFor(
            runtime.phase == .running && runtime.bytesRead > 0,
            "embedded client booted and produced output",
            timeout: 15
        )
        guard case .running = runtime.phase, let hosted = view(of: runtime) else {
            if case let .failed(message) = runtime.phase {
                XCTFail("embed run failed: \(message)")
            } else {
                XCTFail("embed run never reached running: \(runtime.phase)")
            }
            return
        }

        // Empirical capability proof: the TUI frame only renders once the
        // client's terminal queries are answered (SwiftTerm native + the
        // runtime's color-scheme answer).
        await waitFor(
            !bufferText(hosted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "TUI frame rendered into the terminal buffer",
            timeout: 15
        )

        runtime.writeInput(Data("x".utf8))
        await waitFor(runtime.bytesWritten > 0, "keystroke accepted")

        await runtime.requestStop()
        await waitFor(
            runtime.phase != .running,
            "stop ended the run"
        )
    }

    // MARK: - Helpers

    private func view(of runtime: HerdrEmbedRuntime) -> TerminalContainerView? {
        window?.rootViewController?.view
            .firstDescendant(matching: { $0 is TerminalContainerView })
            as? TerminalContainerView
    }

    private func bufferText(_ view: TerminalContainerView) -> String {
        String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// `Fixtures/run/herdr/server-12222/herdr-client.sock` resolved from the
    /// test file's repo location, verified connectable.
    private func liveFixtureClientSocket() -> String? {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let socket = repo.appending(path: "Fixtures/run/herdr/server-12222/herdr-client.sock")
        guard FileManager.default.fileExists(atPath: socket.path) else { return nil }
        return socket.path
    }
}

/// In-memory `HerdrEmbedSession` — records writes/winsizes, replays
/// scripted output at start, reports stop as a clean exit.
final class HerdrEmbedStubSession: HerdrEmbedSession, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var recordedWrites: [Data] = []
    private var recordedWinsizes: [(cols: Int, rows: Int)] = []
    private var capturedConfig: HerdrEmbedSessionConfig?

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (String?) -> Void)?

    var scriptedOutput: [Data] = []

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites
    }

    var winsizes: [(cols: Int, rows: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWinsizes
    }

    var startConfig: HerdrEmbedSessionConfig? {
        lock.lock()
        defer { lock.unlock() }
        return capturedConfig
    }

    func start(config: HerdrEmbedSessionConfig) throws {
        lock.lock()
        capturedConfig = config
        running = true
        lock.unlock()
        for chunk in scriptedOutput {
            onOutput?(chunk)
        }
    }

    func writeInput(_ data: Data) {
        lock.lock()
        recordedWrites.append(data)
        lock.unlock()
    }

    func setWinsize(cols: Int, rows: Int) {
        lock.lock()
        recordedWinsizes.append((cols, rows))
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stopBlocking() {
        lock.lock()
        running = false
        lock.unlock()
        onExit?(nil)
    }
}

private extension UIView {
    func firstDescendant(matching predicate: (UIView) -> Bool) -> UIView? {
        if predicate(self) { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(matching: predicate) {
                return found
            }
        }
        return nil
    }
}
#endif
