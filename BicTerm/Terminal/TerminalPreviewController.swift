import BicTermCore
import CryptoKit
import Foundation
import NIOSSH
import SwiftUI
import UIKit

#if DEBUG
/// UITEST-only harness connecting a real `TerminalRepresentable` to the
/// loopback fixture sshd (hop1, 127.0.0.1:12222) through the T11
/// `SSHSessionTransportFactory`. Gated by the `-uitest-terminal-preview`
/// launch argument; T14 replaces this with real scene wiring.
@MainActor
final class TerminalPreviewController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var dims: String = "80x24"
    @Published private(set) var tail: String = ""

    private(set) var viewOutput: AsyncStream<Data>
    private var viewOutputContinuation: AsyncStream<Data>.Continuation!
    private var transport: (any TerminalTransport)?
    private var pumpTask: Task<Void, Never>?
    private var tailBytes = Data()
    private var sessionNumber: Int = 0
    /// Test-supplied session id. The test runner allocates a fresh id
    /// every test (`-uitest-session-id N`) and we validate against it
    /// inside `run()` so an in-flight `run()` from a stale app process
    /// can't overwrite the new test's phase/tail.
    private var requestedSessionID: Int = 0

    init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        viewOutput = stream
        viewOutputContinuation = continuation
    }

    deinit {
        viewOutputContinuation.finish()
        pumpTask?.cancel()
        // Best-effort transport close — `transport.close()` is async but
        // deinit can't await. The transport itself handles Task-based
        // teardown; this just kicks it off.
        Task { [transport] in await transport?.close() }
    }

    /// Begin (or re-begin) a fresh SSH session. If the previous
    /// session is still in a non-idle phase (e.g. the prior test left
    /// `cat -v` running on the remote PTY), close it before reconnecting
    /// so we never share a transport across tests.
    func start() {
        if phase != .idle {
            Task { [weak self] in
                await self?.close()
                await MainActor.run { self?.start() }
            }
            return
        }
        // Honour the test's session id (if any) so a stale run() task
        // from a previous test instance cannot clobber the new session's
        // sessionNumber. The two are the same numeric sequence; the
        // session id guards against an in-flight close() from a prior
        // test that completes after we incremented.
        if let requested = Self.launchArgumentInt(after: "-uitest-session-id") {
            requestedSessionID = requested
        }
        sessionNumber += 1
        phase = .connecting
        Task { await self.run() }
    }

    /// Tear down the current SSH session synchronously (best-effort
    /// on the async transport close). Safe to call repeatedly.
    func close() async {
        sessionNumber += 1  // invalidate any in-flight run() task
        viewOutputContinuation.finish()
        pumpTask?.cancel()
        pumpTask = nil
        await transport?.close()
        transport = nil
        viewOutputContinuation = nil
        phase = .idle
        tailBytes.removeAll(keepingCapacity: true)
        tail = ""
        // Update dims so a stale read after close doesn't show a
        // prior session's value (the testRotation asserts the dims
        // label changes after rotation).
        dims = "0x0"
    }

    private func run() async {
        let mySession = sessionNumber
        let mySessionID = requestedSessionID
        do {
            // The test runner may have launched the prior app's
            // instance and is just about to terminate it; if its SSH
            // session is still alive (e.g. waiting on the remote PTY),
            // our `connect()` would queue behind the prior MaxStartups
            // slot. Tear down the prior transport first to release the
            // slot.
            if let prior = transport {
                await prior.close()
                transport = nil
            }

            let connection = try Self.fixtureConnection()
            let factory = SSHSessionTransportFactory(
                hostKeyVerifier: try await Self.preTrustingVerifier(),
                authenticationKeyProvider: Self.authenticationKeyProvider()
            )
            let transport = try factory.makeTransport(for: connection)
            try await transport.connect(to: connection, cols: 80, rows: 24)
            // A newer session may have started while we were connecting.
            // Close ours and bail.
            guard sessionNumber == mySession, mySessionID == requestedSessionID || mySessionID == 0 else {
                await transport.close()
                return
            }
            self.transport = transport

            let remoteOutput = await transport.output
            pumpTask = Task { [weak self] in
                for await chunk in remoteOutput {
                    guard let self,
                          self.sessionNumber == mySession,
                          mySessionID == self.requestedSessionID || mySessionID == 0 else { return }
                    await self.handle(chunk)
                }
                guard let self,
                      self.sessionNumber == mySession,
                      mySessionID == self.requestedSessionID || mySessionID == 0 else { return }
                await self.remoteClosed()
            }

            // Quiesce zsh (learnings: stty -echo alone does not stop ZLE
            // echo) and signal readiness from the REMOTE side, so the UI
            // test knows the pty is live and quiet. Each directive on
            // its own line so the shell executes them as separate
            // commands — `stty -echo` MUST land before any subsequent
            // command or the kernel keeps echoing the test's bytes.
            try await sendLine("stty -echo")
            try await sendLine("unsetopt zle 2>/dev/null || set +o emacs")
            try await sendLine("PROMPT=''")
            try await sendLine("precmd_functions=()")
            try await sendLine("preexec_functions=()")
            try await sendLine("printf '__READY__\\n'")
            guard await waitUntilTail(contains: "__READY__", timeout: 20) else {
                if sessionNumber == mySession, mySessionID == requestedSessionID || mySessionID == 0 {
                    phase = .failed("ready marker not observed on the remote pty")
                }
                return
            }
            if sessionNumber == mySession, mySessionID == requestedSessionID || mySessionID == 0 {
                phase = .ready
            }

            if let command = Self.launchArgumentValue(after: "-uitest-command") {
                try await sendLine(command)
            }
        } catch {
            if sessionNumber == mySession, mySessionID == requestedSessionID || mySessionID == 0 {
                phase = .failed(String(describing: error))
            }
        }
    }

    // MARK: - TerminalRepresentable callbacks

    nonisolated func send(_ data: Data) {
        Task { @MainActor in
            try? await self.transport?.send(data)
        }
    }

    nonisolated func resize(cols: Int, rows: Int) {
        Task { @MainActor in
            self.dims = "\(cols)x\(rows)"
            await self.transport?.resize(cols: cols, rows: rows)
        }
    }

    // MARK: - Output plumbing

    private func handle(_ chunk: Data) {
        tailBytes.append(chunk)
        if tailBytes.count > 32_768 {
            tailBytes.removeFirst(tailBytes.count - 32_768)
        }
        tail = String(decoding: tailBytes, as: UTF8.self)
        viewOutputContinuation.yield(chunk)
    }

    private func remoteClosed() {
        viewOutputContinuation.finish()
    }

    private func sendLine(_ line: String) async throws {
        try await transport?.send(Data((line + "\n").utf8))
    }

    private func waitUntilTail(contains marker: String, timeout seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if tail.contains(marker) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return tail.contains(marker)
    }

    // MARK: - Fixture wiring

    private static func fixtureConnection() throws -> Connection {
        try Connection(
            name: "uitest-hop1",
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: fixtureUsername,
            keyReference: "fixture-ed25519"
        )
    }

    /// The fixture sshd runs as the host user that owns the checkout; the
    /// simulator app process resolves NSUserName() to "" (same gap the
    /// core tests work around), so derive the name from `#filePath`.
    private static var fixtureUsername: String {
        for candidate in [ProcessInfo.processInfo.environment["USER"],
                          ProcessInfo.processInfo.environment["LOGNAME"]] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        let components = URL(fileURLWithPath: #filePath).pathComponents
        if components.count > 3, components[0] == "/", components[1] == "Users" {
            return components[2]
        }
        return NSUserName()
    }

    private static func preTrustingVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryOnlyHostKeyStore())
        let pubLine = try String(contentsOf: FixturePaths.hop1HostKeyURL, encoding: .utf8)
        let parts = pubLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw NSError(domain: "TerminalPreview", code: 1)
        }
        try await verifier.trust(host: "127.0.0.1", port: 12222, key: blob, algorithm: String(parts[0]))
        return verifier
    }

    private static func launchArgumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func launchArgumentInt(after flag: String) -> Int? {
        guard let raw = launchArgumentValue(after: flag) else { return nil }
        return Int(raw)
    }

    /// `-uitest-key-ref <label>` swaps the default file-based provider for one
    /// that resolves an IMPORTED Keychain key by its user-visible label. When
    /// the flag is absent the original `FixtureFileKeyProvider` is returned
    /// unchanged — the default no-flag path is preserved verbatim.
    private static func authenticationKeyProvider() -> any SSHAuthenticationKeyProvider {
        if let label = launchArgumentValue(after: "-uitest-key-ref") {
            return KeychainLabelKeyProvider(label: label)
        }
        return FixtureFileKeyProvider()
    }
}

/// Walks UP from this source file until the directory containing the
/// committed `Fixtures/` tree is found (the repository root), bounded to
/// a few levels. `#filePath` is `/repo/BicTerm/Terminal/<file>.swift`,
/// so exactly three deletions are expected; the search keeps resolution
/// correct if the file moves.
enum FixturePaths {
    static let hop1HostKeyURL = repoRoot
        .appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")

    static let fixtureEd25519KeyURL = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519")

    private static var repoRoot: URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        // Not found in this checkout; surface the bad path in the thrown
        // read error instead of guessing.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// Fixture-file backed authentication: loads the committed ed25519 key
/// (obviously fake, Fixtures/keys/) via the T3 parser.
struct FixtureFileKeyProvider: SSHAuthenticationKeyProvider {
    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: FixturePaths.fixtureEd25519KeyURL)
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }
}

/// Resolves an IMPORTED ed25519 key by its user-visible label via the same
/// Keychain service (`com.bicterm.keys.ed25519`) that `KeyStore` writes to.
/// Used by `TerminalPreviewController` when `-uitest-key-ref <label>` is set,
/// to prove end-to-end that a Keychain-IMPORTED key authenticates the real
/// fixture sshd (not just lists in the UI). Throws when the label is absent
/// so the controller lands in `.failed` — never silently falls back to
/// `FixtureFileKeyProvider` (that fallback would defeat the proof).
struct KeychainLabelKeyProvider: SSHAuthenticationKeyProvider {
    let label: String
    private let repository = KeychainKeyRepository()

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        let imports = try await repository.list()
        guard let match = imports.first(where: { $0.label == label }) else {
            throw KeyRepositoryError.keyNotFound
        }
        return try await repository.authenticationPrivateKey(with: match.reference, reason: reason)
    }
}

actor InMemoryOnlyHostKeyStore: HostKeyStoreProtocol {
    private var record: HostKeyRecord?

    func loadAll() throws(PersistenceError) -> [HostKeyRecord] {
        if let record { [record] } else { [] }
    }

    func lookup(host: String, port: Int) throws(PersistenceError) -> HostKeyRecord? {
        guard let record, record.host == host, record.port == port else { return nil }
        return record
    }

    func save(_ newRecord: HostKeyRecord) throws(PersistenceError) {
        record = newRecord
    }
}
#endif
