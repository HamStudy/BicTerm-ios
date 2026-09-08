import Foundation
import XCTest
@testable import BicTermCore

// The Go core is linked into THIS test target (Package.swift binaryTarget on
// the built xcframework) — never into BicTermCore sources, which stay pure.
import CoderNet

/// Live CoderTransport conformance against the T6 fixture: the REAL Go
/// bridge drives DialAgent → agent SSH stream → per-session UDS, and the
/// conformer runs the shared ``TransportConformanceSuite`` end to end
/// through it. Requires `scripts/coder-dev-up.sh` (server on 127.0.0.1:7080,
/// workspace bicterm-host running with its agent connected).
///
/// Scope split with CoderTransportTests (hermetic): the typed resume-failure
/// injection is proven there; the live class proves the real network path —
/// connect, I/O, resize, suspend/resume — plus the spec §9 address metadata
/// emitted over the bridge's log channel.
final class CoderTransportConformanceTests: XCTestCase {
    private struct FixtureContext: Sendable {
        let connection: Connection
        let agentID: UUID
        let server: CoderServer
        let resolver: CoderWorkspaceResolver
    }

    private actor FixtureContextCache {
        static let shared = FixtureContextCache()
        private var context: FixtureContext?
        func cached() -> FixtureContext? { context }
        func store(_ context: FixtureContext) { self.context = context }
    }

    private var collectors: [Task<Void, Never>] = []

    /// Short repo-local socket root handed to the bridge via its start config
    /// (Go snapshots the process environment at startup, so an env var set
    /// from Swift never reaches it): Darwin's 104-byte sun_path rules out
    /// the simulator container tmp directly (Docs/SECURITY.md).
    private static let liveSocketDir = SSHTestFixture.repoRoot
        .appendingPathComponent("Fixtures/run/cs")
        .path

    override class func setUp() {
        super.setUp()
        CoderNetLogBuffer.shared.installCallback()
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: liveSocketDir),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for collector in collectors { collector.cancel() }
        collectors = []
        try await super.tearDown()
    }

    // MARK: - Fixture plumbing

    private func fixtureContext() async throws -> FixtureContext {
        if let cached = await FixtureContextCache.shared.cached() { return cached }

        let envFile = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-dev.env")
        guard FileManager.default.fileExists(atPath: envFile.path) else {
            throw XCTSkip("coder dev fixture not provisioned — run scripts/coder-dev-up.sh")
        }
        let values = try parseEnvFile(at: envFile)
        guard let rawURL = values["CODER_URL"], let serverURL = URL(string: rawURL),
              let token = values["CODER_SESSION_TOKEN"], !token.isEmpty
        else {
            throw XCTSkip("coder-dev.env lacks CODER_URL/CODER_SESSION_TOKEN — re-run scripts/coder-dev-up.sh")
        }

        let server = try CoderServer(
            name: "dev-fixture",
            baseURL: serverURL,
            tokenKeychainTag: "coder-conformance-live"
        )
        let tokenStore = LiveTokenStore(tokens: ["coder-conformance-live": token])
        let resolver = CoderWorkspaceResolver(
            serverStore: LiveServerStore(server: server),
            tokenStore: tokenStore
        )

        // Discover the fixture workspace's live identity once per class run:
        // the transport under test resolves again internally.
        let client = CoderClient(tokenStore: tokenStore)
        let workspaces = try await client.workspaces(for: server)
        guard let workspace = workspaces.first(where: { $0.name == "bicterm-host" }) else {
            throw XCTSkip("bicterm-host workspace absent — re-run scripts/coder-dev-up.sh")
        }
        guard workspace.state == .running,
              let agent = workspace.agents.first(where: \.isConnected)
        else {
            throw XCTSkip("bicterm-host has no running build with a connected agent")
        }

        let connection = try Connection(
            name: "coder-bicterm-host",
            type: .coder,
            host: serverURL.host ?? "coder.invalid",
            port: serverURL.port ?? 443,
            username: "coder",
            keyReference: "none",
            coderRef: CoderReference(serverID: server.id, workspaceID: workspace.id)
        )
        let context = FixtureContext(
            connection: connection,
            agentID: agent.id,
            server: server,
            resolver: resolver
        )
        await FixtureContextCache.shared.store(context)
        return context
    }

    private func parseEnvFile(at url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }

    // MARK: - Suite hooks

    private let quiesceCommand =
        "stty -echo; unsetopt zle; PROMPT=''; precmd_functions=(); preexec_functions=(); printf '__REA''DY__\\n'\n"

    private func makeSuite() async throws -> TransportConformanceSuite {
        let sink = TransportTestSink()
        return TransportConformanceSuite(
            descriptor: .coder(supportsTailnetTunnel: true),
            expectedResumeStrategy: .nativeRoaming,
            expectedConnectFailure: .unreachable,
            makeTransport: {
                let context = try await self.fixtureContext()
                return CoderTransport(resolver: context.resolver, tunnel: LiveCoderNetBridge(), socketBaseDirectory: Self.liveSocketDir)
            },
            connectWorking: { transport in
                let context = try await self.fixtureContext()
                try await transport.connect(to: context.connection, cols: 80, rows: 24)
                let sink = sink
                let stream = await transport.output
                self.collectors.append(Task {
                    for await chunk in stream { await sink.append(chunk) }
                    await sink.markFinished()
                })
                try await transport.send(Data(self.quiesceCommand.utf8))
                let ready = await waitForSuiteCondition(timeoutMilliseconds: 20000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains("__READY__")
                }
                if !ready {
                    let collected = await sink.snapshot()
                    XCTFail(
                        "workspace shell did not reach ready marker; collected \(collected.count) bytes: "
                            + String(decoding: collected.suffix(400), as: UTF8.self)
                    )
                }
                await sink.reset()
            },
            roundTrip: { transport, marker in
                try await transport.send(Data("printf '\(marker)\\n'\n".utf8))
                return await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains(marker)
                }
            },
            verifyResize: { transport, cols, rows in
                await sink.reset()
                try await transport.send(Data("stty size\n".utf8))
                return await waitForSuiteCondition(timeoutMilliseconds: 8000) {
                    await String(decoding: sink.snapshot(), as: UTF8.self).contains("\(rows) \(cols)")
                }
            },
            outputFinished: { await sink.isFinished },
            makeFailingTransport: {
                // Same server identity, dead endpoint: resolution must clear
                // the store + workspace lookup and die at the REST layer,
                // surfacing the mapped .unreachable.
                let context = try await self.fixtureContext()
                let deadServer = try CoderServer(
                    id: context.server.id,
                    name: "dead-fixture",
                    baseURL: URL(string: "http://127.0.0.1:9")!,
                    tokenKeychainTag: context.server.tokenKeychainTag
                )
                let resolver = CoderWorkspaceResolver(
                    serverStore: LiveServerStore(server: deadServer),
                    tokenStore: LiveTokenStore(tokens: [context.server.tokenKeychainTag: "unused"])
                )
                return CoderTransport(resolver: resolver, tunnel: LiveCoderNetBridge(), socketBaseDirectory: Self.liveSocketDir)
            },
            connectFailing: { transport in
                let context = try await self.fixtureContext()
                try await transport.connect(to: context.connection, cols: 80, rows: 24)
            },
            expectedResumeFailure: nil,
            makeResumeFailingTransport: nil,
            observeRoamingResume: { transport in
                guard let coder = transport as? CoderTransport else {
                    return RoamingResumeObservation(
                        connectAttempts: -1,
                        authenticationAttempts: -1,
                        resumeAttempts: -1
                    )
                }
                return await coder.roamingObservation
            }
        )
    }

    func testConnectSucceedsAndOutputStreamIsLive() async throws {
        try await makeSuite().runConnectSucceedsAndOutputStreamIsLive()
    }

    func testInputOutputRoundTrip() async throws {
        try await makeSuite().runInputOutputRoundTrip()
    }

    func testResizeIsObserved() async throws {
        try await makeSuite().runResizeIsObserved()
    }

    func testSuspendResumeFollowsDeclaredStrategy() async throws {
        try await makeSuite().runSuspendResumeFollowsDeclaredStrategy()
    }

    func testCloseIsTerminalIdempotentAndFinishesOutput() async throws {
        try await makeSuite().runCloseIsTerminalIdempotentAndFinishesOutput()
    }

    func testSendBeforeConnectThrowsTypedChannelDenied() async throws {
        try await makeSuite().runSendBeforeConnectThrowsTypedChannelDenied()
    }

    func testConnectFailureSurfacesTypedTransportError() async throws {
        try await makeSuite().runConnectFailureSurfacesTypedTransportError()
    }

    /// The headline proof: shell bytes traverse dev server → coordination →
    /// DERP/direct → agent SSH → bridge UDS → NIOSSH → the output stream.
    func testLiveTunnelPrintfBictermOK() async throws {
        let context = try await fixtureContext()
        let transport = CoderTransport(resolver: context.resolver, tunnel: LiveCoderNetBridge(), socketBaseDirectory: Self.liveSocketDir)
        try await transport.connect(to: context.connection, cols: 80, rows: 24)
        let sink = TransportTestSink()
        let stream = await transport.output
        collectors.append(Task {
            for await chunk in stream { await sink.append(chunk) }
            await sink.markFinished()
        })
        try await transport.send(Data(quiesceCommand.utf8))
        let ready = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
            await String(decoding: sink.snapshot(), as: UTF8.self).contains("__READY__")
        }
        XCTAssertTrue(ready, "workspace shell did not reach ready marker")
        await sink.reset()

        try await transport.send(Data("printf bicterm-ok\n".utf8))
        let printed = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
            await String(decoding: sink.snapshot(), as: UTF8.self).contains("bicterm-ok")
        }
        XCTAssertTrue(printed, "printf bicterm-ok must echo through the live tunnel")
        await transport.close()
    }

    /// Spec §9: the bridge emits the agent's virtual IPv6 address over the
    /// log channel at dial time; it must equal the UUID-prefix math applied
    /// to the fixture agent's real UUID.
    func testAgentAddressMetadataMatchesServicePrefixMath() async throws {
        let context = try await fixtureContext()
        coderNetLogBuffer.reset()
        let transport = CoderTransport(resolver: context.resolver, tunnel: LiveCoderNetBridge(), socketBaseDirectory: Self.liveSocketDir)
        try await transport.connect(to: context.connection, cols: 80, rows: 24)

        let expected = Self.expectedServiceAddress(for: context.agentID)
        let observed = await waitForSuiteCondition(timeoutMilliseconds: 5000) {
            coderNetLogBuffer.snapshot().contains("agent_ipv6=" + expected)
        }
        let captured = coderNetLogBuffer.snapshot()
        XCTAssertTrue(
            observed,
            "bridge log must report agent_ipv6=\(expected); got: \(captured)"
        )
        await transport.close()
    }

    /// Formats the expected fd7a:115c:a1e0::/48 mapping for an agent UUID —
    /// hex regrouping only; the mapping itself is implemented and proven in
    /// the Go core (CoderNet/bridge_test.go).
    private static func expectedServiceAddress(for agentID: UUID) -> String {
        var uuidBytes = agentID.uuid
        let hex = withUnsafeBytes(of: &uuidBytes) { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
        let suffix = String(hex.dropFirst(12))
        let groups = stride(from: 0, to: suffix.count, by: 4).map { offset in
            let start = suffix.index(suffix.startIndex, offsetBy: offset)
            let end = suffix.index(start, offsetBy: 4)
            return String(suffix[start..<end])
        }
        return (["fd7a", "115c", "a1e0"] + groups).joined(separator: ":")
    }
}

/// Production-shaped CoderTunneling conformer over the C ABI, compiled into
/// the TEST target. Duplication of the CoderTunnel framework's 25-line FFI
/// adapter is deliberate: the framework target stays untouched (T7 owns it)
/// and the test bundle proves the protocol boundary needs no framework.
private struct LiveCoderNetBridge: CoderTunneling {
    init() {}

    func version() -> String {
        guard let raw = CoderNetVersion() else { return "" }
        defer { CoderNetFreeString(raw) }
        return String(cString: raw)
    }

    func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        let rawHandle = configJSON.withCString { ptr in
            CoderNetStart(UnsafeMutablePointer(mutating: ptr))
        }
        guard rawHandle != 0 else { throw .startRejected }
        return Int(rawHandle)
    }

    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String {
        guard let converted = Int32(exactly: handle) else { return "" }
        guard let raw = CoderNetDialSSH(converted) else { return "" }
        defer { CoderNetFreeString(raw) }
        return String(cString: raw)
    }

    func rebind(handle: Int) {
        guard let converted = Int32(exactly: handle) else { return }
        CoderNetRebind(converted)
    }

    func close(handle: Int) {
        guard let converted = Int32(exactly: handle) else { return }
        CoderNetClose(converted)
    }
}

/// Synchronous capture of the bridge's log channel; Go emits from arbitrary
/// threads, so the buffer is lock-guarded and never touches async state.
private final class CoderNetLogBuffer: @unchecked Sendable {
    static let shared = CoderNetLogBuffer()

    private let lock = NSLock()
    private var lines: [String] = []
    private var callbackInstalled = false

    /// Registers the bridge's log callback exactly once per process; the C
    /// side keeps whatever pointer it got first, so repeat installs would be
    /// invisible AND racy.
    func installCallback() {
        lock.lock()
        defer { lock.unlock() }
        guard !callbackInstalled else { return }
        callbackInstalled = true
        CoderNetSetLogCallback { level, message in
            guard let message else { return }
            CoderNetLogBuffer.shared.append("[\(level)] \(String(cString: message))")
        }
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func reset() {
        lock.lock()
        lines = []
        lock.unlock()
    }
}

private let coderNetLogBuffer = CoderNetLogBuffer.shared

/// Minimal store conformers for the live resolver: one server, one token,
/// read-only — the fixture credentials never touch Keychain or SwiftData.
private actor LiveServerStore: CoderServerStoreProtocol {
    let server: CoderServer

    init(server: CoderServer) {
        self.server = server
    }

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        [server]
    }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        server.id == id ? server : nil
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {}
    func deleteCoderServer(id: UUID) async throws(PersistenceError) {}
}

private actor LiveTokenStore: CoderTokenStoring {
    private var tokens: [String: String]

    init(tokens: [String: String]) {
        self.tokens = tokens
    }

    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        tokens[keychainTag]
    }

    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        tokens[keychainTag] = token
    }

    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
        tokens[keychainTag] = nil
    }
}
