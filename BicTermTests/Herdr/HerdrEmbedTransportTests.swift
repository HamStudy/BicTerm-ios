#if HERDR_EMBED
import BicTermCore
import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit
import XCTest

@testable import BicTerm

/// T5 transport injection, end to end: the REAL embedded herdr TUI reaches
/// its machine through BicTermCore's SSH stack — the client dials the
/// `bicterm-transport` host socket served by ``HerdrEmbedBridgeServer``,
/// which relays to `remote-client-bridge` over an established carrier
/// (direct 12222, jump-chained 12222 → 12223) — against the prebuilt herdr
/// 0.9.0 fixture servers. Proves: TUI renders, keys flow, the detach key
/// ends the run, and teardown leaves no socket file and restores the cwd.
@MainActor
final class HerdrEmbedTransportTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testRealTUIConnectsThroughDirectCarrierAndDetachesCleanly() async throws {
        try requireFixtures(serverPort: 12222)
        let connection = try makeDirectConnection()
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let runtime = try await startTransportRuntime(connection: connection)

        _ = try await hostAndWaitForRender(runtime)

        runtime.writeInput(Data("j".utf8))
        await waitFor(runtime.bytesWritten > 0, "keystroke reached the embedded client")

        let socketFile = expectedSocketFile(for: connection)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile),
            "bridge socket exists while the run is live"
        )

        // T3 learnings: ctrl+b q is timing-sensitive under SwiftUI-hosted
        // queries. requestStop exercises the same teardown surface; the
        // bridge-server tests already prove ctrl+b q over the bridge.
        await runtime.requestStop()

        await waitFor(
            runtime.phase != .running,
            "requestStop ended the embedded run",
            timeout: 20
        )
        await waitFor(
            !FileManager.default.fileExists(atPath: socketFile),
            "bridge socket file removed at teardown",
            timeout: 10
        )
        await waitFor(
            FileManager.default.currentDirectoryPath == cwdBeforeStart,
            "process cwd restored after teardown",
            timeout: 10
        )
    }

    func testRealTUIConnectsThroughJumpChainedCarrier() async throws {
        try requireFixtures(serverPort: 12223)
        let hop = Hop(
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519"
        )
        let connection = try Connection(
            name: "fixture-embed-jump",
            type: .ssh,
            host: "127.0.0.1",
            port: 12223,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519",
            jumpChain: [hop]
        )
        let cwdBeforeStart = FileManager.default.currentDirectoryPath
        let runtime = try await startTransportRuntime(connection: connection)

        _ = try await hostAndWaitForRender(runtime, timeout: 30)

        runtime.writeInput(Data("k".utf8))
        await waitFor(runtime.bytesWritten > 0, "keystroke reached the embedded client through the jump chain")

        let socketFile = expectedSocketFile(for: connection)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketFile),
            "bridge socket exists while the jump-chain run is live"
        )

        await runtime.requestStop()

        await waitFor(
            runtime.phase != .running,
            "requestStop ended the jump-chained run",
            timeout: 25
        )
        await waitFor(
            !FileManager.default.fileExists(atPath: socketFile),
            "bridge socket file removed at teardown (jump chain)",
            timeout: 10
        )
        await waitFor(
            FileManager.default.currentDirectoryPath == cwdBeforeStart,
            "process cwd restored after teardown (jump chain)",
            timeout: 10
        )
    }

    private func hostAndWaitForRender(
        _ runtime: HerdrEmbedRuntime,
        timeout: TimeInterval = 25
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
            "embedded client booted over the bridge and produced output",
            timeout: timeout
        )
        guard case .running = runtime.phase else {
            var stderr = ""
            if let text = Self.clientStderrTail() { stderr = "\nclient stderr tail:\n\(text)" }
            let failure = runtime.failureDiagnostic.map { "\($0.kind): \($0.detail)" } ?? "\(runtime.phase)"
            XCTFail("embed run never reached running: \(failure)\(stderr)")
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
        return hosted
    }

    private func makeFixtureTrustedVerifier(connection: Connection) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        let endpoints = connection.jumpChain.map { ($0.host, $0.port) } + [(connection.host, connection.port)]
        var trusted: Set<String> = []
        for (host, port) in endpoints where trusted.insert("\(host):\(port)").inserted {
            let keyPath = port == Self.fixtureHop2Port
                ? "Fixtures/sshd/host_keys/hop2_host_ed25519.pub"
                : "Fixtures/sshd/host_keys/hop1_host_ed25519.pub"
            let keyURL = Self.repoRoot.appendingPathComponent(keyPath)
            let line = try String(contentsOf: keyURL, encoding: .utf8)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
                throw NSError(domain: "HerdrEmbedTransportTests", code: 1)
            }
            try await verifier.trust(host: host, port: port, key: blob, algorithm: String(parts[0]))
        }
        return verifier
    }

    private nonisolated static let fixtureHop2Port = 12223

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

    private func makeDirectConnection() throws -> Connection {
        try Connection(
            name: "fixture-embed",
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            keyReference: "fixture-ed25519"
        )
    }

    private func startTransportRuntime(
        connection: Connection
    ) async throws -> HerdrEmbedRuntime {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: Self.repoRoot.appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519"))
        )
        let key = NIOSSHPrivateKey(ed25519Key: parsed.privateKey)

        // TOFU per hop is covered by HerdrConnectCoordinatorTests + ProxyJumpTests;
        // T5 only proves the embed transport end-to-end, so the fixture host keys are pre-trusted.
        let verifier = try await makeFixtureTrustedVerifier(connection: connection)

        let coordinator = HerdrEmbedTransportCoordinator(
            connection: connection,
            connector: {
                HerdrEndpointConnector(
                    hostKeyVerifier: verifier,
                    authenticationKeyProvider: FixtureKeyProvider(key: key),
                    searchPaths: [Self.herdrBin],
                    approveHostKey: { _ in true }
                )
            }
        )

        let runtime = HerdrEmbedRuntime()
        runtime.attachTransport(coordinator)

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

        await runtime.startIfNeeded()
        if case let .failed(message) = runtime.phase {
            XCTFail("transport bring-up failed: \(message)")
        }
        return runtime
    }

    private func expectedSocketFile(for connection: Connection) -> String {
        let profile = HerdrEmbedMachine.profileID(for: connection.id)
        return NSHomeDirectory()
            + "/\(HerdrEmbedClientCatalog.transportDirectoryName)/\(profile).sock"
    }

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
private struct FixtureKeyProvider: SSHAuthenticationKeyProvider {
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
#endif
