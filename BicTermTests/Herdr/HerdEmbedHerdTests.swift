import BicTermCore
import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit
import XCTest

@testable import BicTerm

/// T6 herds through the REAL client, end to end against BOTH prebuilt
/// herdr 0.9.0 fixture servers: a herd seeds the embedded client's
/// machine catalog (one bridge socket per machine — direct 12222 and
/// jump-chained 12222 → 12223), the client's own sidebar lists every
/// machine, machine selection rides a real SGR mouse click through the
/// SwiftTerm input path, severing one machine's carrier leaves the other
/// flowing, and opening a second herd closes the first cleanly with fully
/// isolated sockets and catalog.
@MainActor
final class HerdrEmbedHerdTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    // MARK: - Multi-machine herd through the real client

    func testHerdSeedsBothMachinesIntoRealClientSidebarAndInputFlows() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let (runtime, coordinator) = try await startHerdRuntime(
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")]
        )

        let hosted = try await hostAndWaitForRender(runtime)

        // The client dials every saved machine at boot: both bridges see
        // a relay (both machines ONLINE through our SSH stack).
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("alpha: bridge relay opened") },
            "the client connected machine alpha through its own bridge",
            timeout: 20
        )
        await waitFor(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge relay opened") },
            "the client connected machine beta through its own bridge",
            timeout: 20
        )

        for label in ["alpha", "beta"] {
            XCTAssertTrue(
                bufferContains(hosted, label),
                "the real client's sidebar lists machine \(label)"
            )
        }

        // Machine selection through the client's OWN surface: a real SGR
        // click on each machine's sidebar row (the same delegate path a
        // touch takes).
        for label in ["alpha", "beta"] {
            let cell = try XCTUnwrap(
                locate(hosted, label: label),
                "machine row for \(label) present in the terminal buffer"
            )
            click(hosted, col: cell.col, row: cell.row)
        }

        // Input routes to the selected machine: a keystroke through the
        // hosting view's input path is accepted while the herd runs.
        let writtenBefore = runtime.bytesWritten
        runtime.writeInput(Data("x".utf8))
        await waitFor(
            runtime.bytesWritten > writtenBefore,
            "keystroke accepted by the embedded client with a machine selected"
        )

        try await teardownHerd(
            runtime: runtime,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    func testSeveringOneMachineLeavesTheOtherFlowing() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let alpha = try makeDirectMachine(label: "alpha")
        let beta = try makeJumpMachine(label: "beta")
        let (runtime, coordinator) = try await startHerdRuntime(
            machines: [alpha, beta]
        )
        let hosted = try await hostAndWaitForRender(runtime)

        await coordinator.severMachineTransport(profileID: alpha.machine.profileID)

        await waitFor(
            coordinator.eventLines.contains {
                $0.hasPrefix("alpha: bridge carrier lost")
            },
            "severing machine alpha surfaced through its bridge",
            timeout: 15
        )
        XCTAssertEqual(
            runtime.phase, .running,
            "the embedded client keeps running with one machine down"
        )
        await waitFor(
            bufferContains(hosted, "beta"),
            "the healthy machine stays rendered in the client",
            timeout: 15
        )
        XCTAssertFalse(
            coordinator.eventLines.contains { $0.hasPrefix("beta: bridge carrier lost") },
            "machine beta's transport was never touched"
        )

        let writtenBefore = runtime.bytesWritten
        runtime.writeInput(Data("j".utf8))
        await waitFor(
            runtime.bytesWritten > writtenBefore,
            "input still accepted while the other machine is down"
        )

        try await teardownHerd(
            runtime: runtime,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    func testOpeningSecondHerdClosesFirstAndIsolatesSocketsAndCatalog() async throws {
        try requireBothFixtures()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let first = try makeDirectMachine(label: "one")
        let second = try makeJumpMachine(label: "two")

        let parsed = try await parseFixtureKey()
        let ownerOne = UUID()
        let (runtime, _) = try await startHerdRuntime(
            machines: [first], ownerID: ownerOne, key: parsed
        )
        guard case .running = runtime.phase else {
            XCTFail("first herd never reached running: \(runtime.phase)")
            return
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile(for: first)),
            "herd one's machine socket exists while its run is live"
        )

        // Opening herd B closes herd A cleanly (v1: one embedded TUI per
        // process) and swaps the catalog + sockets wholesale.
        let coordinatorTwo = HerdrEmbedTransportCoordinator(
            machines: [second],
            connector: fixtureConnectorFactory(key: parsed)
        )
        runtime.attachTransport(coordinatorTwo)
        await runtime.startIfNeeded(ownerID: UUID())

        guard case .running = runtime.phase else {
            XCTFail("second herd never reached running: \(runtime.phase)")
            return
        }
        await waitFor(
            !FileManager.default.fileExists(atPath: socketFile(for: first)),
            "herd one's socket was cleaned up when its run closed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile(for: second)),
            "herd two's machine socket exists for its own run"
        )
        let catalog = try String(
            contentsOf: catalogFile(),
            encoding: .utf8
        )
        XCTAssertTrue(catalog.contains("two"))
        XCTAssertFalse(
            catalog.contains("one"),
            "the client catalog holds only the open herd's machines"
        )

        _ = try await hostAndWaitForRender(runtime)
        runtime.writeInput(Data("x".utf8))
        await waitFor(runtime.bytesWritten > 0, "keystroke accepted in the second herd")

        try await teardownHerd(
            runtime: runtime,
            machines: [try makeDirectMachine(label: "alpha"), try makeJumpMachine(label: "beta")],
            cwdBeforeStart: cwdBeforeStart
        )
    }

    // MARK: - Herd bring-up plumbing

    private func makeDirectMachine(label: String) throws -> HerdrEmbedMachineLink {
        link(for: try makeDirectConnection(label: label))
    }

    private func makeJumpMachine(label: String) throws -> HerdrEmbedMachineLink {
        let hop = Hop(
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519"
        )
        let connection = try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12223,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519",
            jumpChain: [hop]
        )
        return link(for: connection)
    }

    private func link(for connection: Connection) -> HerdrEmbedMachineLink {
        HerdrEmbedMachineLink(
            machine: HerdrEmbedMachine.forConnection(connection),
            connection: connection,
            bridgeSessionName: connection.herdrSessionName
        )
    }

    private func makeDirectConnection(label: String = "alpha") throws -> Connection {
        try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519"
        )
    }

    private func parseFixtureKey() async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: Self.repoRoot.appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519"))
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }

    private func fixtureConnectorFactory(key: NIOSSHPrivateKey) -> @Sendable () async -> HerdrEndpointConnector {
        let verifierTask = Task { [self] in
            try await makeAllEndpointsTrustedVerifier()
        }
        let herdrBin = Self.herdrBin
        return {
            HerdrEndpointConnector(
                hostKeyVerifier: (try? await verifierTask.value)
                    ?? HostKeyVerifier(store: InMemoryHostKeyStoreFallback()),
                authenticationKeyProvider: FixtureHerdKeyProvider(key: key),
                searchPaths: [herdrBin],
                approveHostKey: { _ in true }
            )
        }
    }

    /// Herd machines connect concurrently, so every endpoint of every
    /// machine (hop + destination) is pre-trusted; TOFU prompting itself
    /// is covered by the connector/coordinator test suites.
    private func makeAllEndpointsTrustedVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let endpoints = [(String("127.0.0.1"), 12222), (String("127.0.0.1"), 12223)]
        for (host, port) in endpoints {
            let keyPath = port == 12223
                ? "Fixtures/sshd/host_keys/hop2_host_ed25519.pub"
                : "Fixtures/sshd/host_keys/hop1_host_ed25519.pub"
            let keyURL = Self.repoRoot.appendingPathComponent(keyPath)
            let line = try String(contentsOf: keyURL, encoding: .utf8)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
                throw NSError(domain: "HerdrEmbedHerdTests", code: 1)
            }
            try await verifier.trust(host: host, port: port, key: blob, algorithm: String(parts[0]))
        }
        return verifier
    }

    private func startHerdRuntime(
        machines: [HerdrEmbedMachineLink],
        ownerID: UUID? = nil,
        key: NIOSSHPrivateKey? = nil
    ) async throws -> (HerdrEmbedRuntime, HerdrEmbedTransportCoordinator) {
        let parsedKey: NIOSSHPrivateKey
        if let key {
            parsedKey = key
        } else {
            parsedKey = try await parseFixtureKey()
        }
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: machines,
            connector: fixtureConnectorFactory(key: parsedKey)
        )

        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)
        addTeardownBlock { @MainActor in
            await runtime.requestStop()
        }

        let previous = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        let statePrevious = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        addTeardownBlock { @MainActor in
            if let previous {
                setenv("HERDR_EMBED_TRANSPORT_DIR", previous, 1)
            } else {
                unsetenv("HERDR_EMBED_TRANSPORT_DIR")
            }
            if let statePrevious {
                setenv("XDG_STATE_HOME", statePrevious, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }

        await runtime.startIfNeeded(ownerID: ownerID)
        if case let .failed(message) = runtime.phase {
            XCTFail("herd transport bring-up failed: \(message)")
        }
        return (runtime, coordinator)
    }

    /// Teardown receipts: the run stops, every machine socket is unlinked,
    /// and the process cwd is restored.
    private func teardownHerd(
        runtime: HerdrEmbedRuntime,
        machines: [HerdrEmbedMachineLink],
        cwdBeforeStart: String
    ) async throws {
        await runtime.requestStop()
        await waitFor(
            runtime.phase != .running,
            "requestStop ended the herd run",
            timeout: 25
        )
        for machine in machines {
            await waitFor(
                !FileManager.default.fileExists(atPath: socketFile(for: machine)),
                "machine \(machine.machine.label)'s bridge socket removed at teardown",
                timeout: 10
            )
        }
        await waitFor(
            FileManager.default.currentDirectoryPath == cwdBeforeStart,
            "process cwd restored after teardown",
            timeout: 10
        )
    }

    // MARK: - Client-surface helpers

    private func hostAndWaitForRender(
        _ runtime: HerdrEmbedRuntime,
        timeout: TimeInterval = 30
    ) async throws -> TerminalContainerView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(
            rootView: HerdrTUIHostingView(runtime: runtime).frame(width: 390, height: 844)
        )
        window.makeKeyAndVisible()
        self.window = window
        window.layoutIfNeeded()

        await waitFor(
            runtime.phase == .running && runtime.bytesRead > 0,
            "embedded client booted over the herd bridges and produced output",
            timeout: timeout
        )
        guard case .running = runtime.phase else {
            var stderr = ""
            if let text = Self.clientStderrTail() { stderr = "\nclient stderr tail:\n\(text)" }
            let failure = runtime.failureDiagnostic.map { "\($0.kind): \($0.detail)" } ?? "\(runtime.phase)"
            XCTFail("herd run never reached running: \(failure)\(stderr)")
            throw XCTSkip("unreachable")
        }

        let hosted = try XCTUnwrap(
            window.rootViewController?.view
                .firstDescendant(matching: { $0 is TerminalContainerView }) as? TerminalContainerView
        )
        await waitFor(
            !Self.bufferText(hosted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "TUI frame rendered into the terminal buffer",
            timeout: 20
        )
        Self.dumpDiagnostics(runtime: runtime, view: hosted)
        return hosted
    }

    /// Terminal grid + transport event lines into a host-readable file —
    /// the dup2 window swallows assert messages, so this dump is the
    /// ground truth for what the client actually drew and dialed.
    private static func dumpDiagnostics(
        runtime: HerdrEmbedRuntime,
        view: TerminalContainerView
    ) {
        let terminal = view.getTerminal()
        var lines = [
            "phase=\(runtime.phase) bytesRead=\(runtime.bytesRead)"
                + " bytesWritten=\(runtime.bytesWritten)",
            "cols=\(terminal.cols) rows=\(terminal.rows)"
                + " cwd=\(FileManager.default.currentDirectoryPath)",
        ]
        lines.append(contentsOf: runtime.transportLines)
        lines.append("--- active buffer ---")
        lines.append(bufferText(view))
        lines.append("--- normal-screen rows ---")
        for row in 0..<terminal.rows {
            let text = terminal.getLine(row: row)?.translateToString() ?? ""
            lines.append("\(row)|\(text)")
        }
        let url = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/t6-buffer-dump.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func bufferContains(_ view: TerminalContainerView, _ needle: String) -> Bool {
        Self.bufferText(view).contains(needle)
    }

    /// First (col, row) of a label in the terminal buffer — the machine's
    /// sidebar row.
    private func locate(
        _ view: TerminalContainerView,
        label: String
    ) -> (col: Int, row: Int)? {
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString()
            if let range = text.range(of: label) {
                let col = text.distance(from: text.startIndex, to: range.lowerBound)
                return (col, row)
            }
        }
        return nil
    }

    /// SGR mouse click through the terminal's own reporting path (press +
    /// release), the same byte path a real touch takes.
    private func click(_ view: TerminalContainerView, col: Int, row: Int) {
        let terminal = view.getTerminal()
        let cell = view.cellSizeInPixels(source: terminal) ?? (width: 10, height: 20)
        terminal.sendEvent(
            buttonFlags: 0,
            x: col,
            y: row,
            pixelX: col * cell.width,
            pixelY: row * cell.height
        )
        terminal.sendEvent(
            buttonFlags: 3,
            x: col,
            y: row,
            pixelX: col * cell.width,
            pixelY: row * cell.height
        )
    }

    // MARK: - Fixture plumbing

    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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

    private func requireBothFixtures() throws {
        let fm = FileManager.default
        for port in [12222, 12223] {
            try XCTSkipUnless(
                fm.fileExists(atPath: Self.herdrBin)
                    && fm.fileExists(
                        atPath: Self.repoRoot
                            .appendingPathComponent("Fixtures/run/herdr/server-\(port)/herdr-client.sock")
                            .path
                    ),
                "herdr fixture on \(port) not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
            )
        }
    }

    private func socketFile(for machine: HerdrEmbedMachineLink) -> String {
        NSHomeDirectory()
            + "/\(HerdrEmbedClientCatalog.transportDirectoryName)/\(machine.machine.profileID).sock"
    }

    private func catalogFile() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/state-home/herdr/client/endpoints.json")
    }

    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        timeout: TimeInterval = 12
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    private static func bufferText(_ view: TerminalContainerView) -> String {
        String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private static func clientStderrTail() -> String? {
        let url = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed/client-stderr.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.suffix(2000))
    }
}

/// Supplies the fixture ed25519 key regardless of the Keychain reference
/// (the app-hosted test process has no Keychain entry for it).
private struct FixtureHerdKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        key
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
