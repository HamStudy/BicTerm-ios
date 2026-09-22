import CryptoKit
import Foundation
import NIOSSH
import XCTest
@testable import BicTermCore

/// T5 transport-injection proof at the CORE boundary: the bridge server
/// serves herdr's `bicterm-transport` host socket and relays local-socket
/// bytes to a `remote-client-bridge` exec channel — direct (12222) and
/// jump-chained (12222 → 12223) — against the prebuilt herdr 0.9.1
/// fixture servers. The local side of each test is a plain POSIX UDS
/// client standing in for the embedded Rust client (same dial the embed
/// crate performs); the E2E with the REAL embedded TUI lives in the app
/// suite (`HerdrEmbedTransportTests`).
///
/// Carrier contract (shared-first): the server wraps its factory in a
/// ``SharedExecCarrierPool``, so sequential relays ride ONE shared SSH
/// connection; a channel-budget gateway's denial of the shared carrier's
/// open flips the pool sticky-dedicated, and every later relay dials its
/// OWN connection (the Coder-era per-relay shape, recovered exactly
/// where the budget gateway requires it).
///
/// Teardown receipts are asserted, not assumed: every relay reports its
/// byte counts, stop() unlinks the socket path, and the second stop() is
/// a no-op.
final class HerdrEmbedBridgeServerTests: XCTestCase {
    private var eventLog: EventLog!

    override func setUp() async throws {
        try await super.setUp()
        eventLog = EventLog()
    }

    override func tearDown() async throws {
        eventLog = nil
        try await super.tearDown()
    }

    func testDirectCarrierServesHandshakeThroughBridgeSocket() async throws {
        try Self.requireFixture(serverPort: 12222)
        let probed = try await establishProbed(connection: try SSHTestFixture.makeConnection())
        let socketPath = try Self.bridgeSocketPath(profile: "direct12222aaaaaaaaaaaaaaaaaaaa")

        let server = await makeServer(probed: probed, socketPath: socketPath)
        try await server.start()

        let client = try UnixStreamClient.connect(path: socketPath)
        defer { client.close() }
        try client.writeAll(Self.helloFrame)

        let welcome = try await client.readFirstFrame(
            containing: "endpoint.welcome.v1",
            timeout: .seconds(10)
        )
        let parsed = try HerdrServerFixtureHandshakeTests.parseWelcome(frame: welcome)
        XCTAssertTrue(parsed.json.contains("\"generation\":1"), parsed.json)

        client.close()

        let relayEndEvent = await eventLog.firstRelayEnd(timeout: .seconds(10))
        let relayEnd = try XCTUnwrap(relayEndEvent, "relay end receipt with byte counts arrived")
        XCTAssertGreaterThan(relayEnd.bytesUp, 0, "client→remote bytes flowed")
        XCTAssertGreaterThan(relayEnd.bytesDown, 0, "remote→client bytes flowed")

        await server.stop()
        let stoppedEvent = await eventLog.firstStopped()
        let stopped = try XCTUnwrap(stoppedEvent, "stop receipt arrived")
        // NIO's listener-channel close may unlink the socket file before
        // stop()'s own sweep; the hard requirement is: receipt + no file.
        XCTAssertTrue(
            stopped.isStopped,
            "stop receipt arrived (got \(stopped))"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "no leaked socket file after stop"
        )

        await server.stop()
        let secondStop = await eventLog.allEvents()
        XCTAssertEqual(
            secondStop.filter(\.isStopped).count,
            1,
            "second stop() is a no-op"
        )
    }

    func testJumpChainedCarrierServesBridgeOnFinalHop() async throws {
        try Self.requireFixture(serverPort: 12223)
        let probed = try await establishProbed(
            connection: try JumpFixture.twoHopConnection()
        )
        XCTAssertEqual(probed.probe.host, "127.0.0.1")

        let socketPath = try Self.bridgeSocketPath(profile: "jump12223aaaaaaaaaaaaaaaaaaaaa")

        let server = await makeServer(probed: probed, socketPath: socketPath)
        try await server.start()

        let client = try UnixStreamClient.connect(path: socketPath)
        defer { client.close() }
        try client.writeAll(Self.helloFrame)

        let welcome = try await client.readFirstFrame(
            containing: "endpoint.welcome.v1",
            timeout: .seconds(15)
        )
        let parsed = try HerdrServerFixtureHandshakeTests.parseWelcome(frame: welcome)
        XCTAssertTrue(parsed.json.contains("\"server_version\":\"0.9.1\""), parsed.json)

        await server.stop()
        let stoppedEvent = await eventLog.firstStopped()
        let stopped = try XCTUnwrap(stoppedEvent, "stop receipt arrived")
        XCTAssertTrue(stopped.isStopped, "stop receipt arrived (got \(stopped))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStaleSocketFileIsSweptButLiveListenerIsRefused() async throws {
        try Self.requireFixture(serverPort: 12222)
        let probed = try await establishProbed(connection: try SSHTestFixture.makeConnection())

        // Live listener: bind one of our own first.
        let livePath = try Self.bridgeSocketPath(profile: "livelistentest0000000000000000")
        let live = await makeServer(probed: probed, socketPath: livePath)
        try await live.start()
        addTeardownBlock { await live.stop() }

        let refused = await Self.refusesToReplaceLiveListener(at: livePath, probed: probed)
        XCTAssertTrue(
            refused,
            "a live listener must be refused with the typed error, not replaced"
        )

        // Stale leftover (file, no listener) is swept and rebound.
        livePath.withCString { cString in
            _ = unlink(cString)
        }
        let stale = try Self.bridgeSocketPath(profile: "stalesweep00000000000000000000")
        FileManager.default.createFile(atPath: stale, contents: nil)
        let reuser = await makeServer(probed: probed, socketPath: stale)
        try await reuser.start()
        await reuser.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
    }

    /// Budget-fallback proof against the CoderSSHGW emulation fixture
    /// (``LoopbackPasswordSSHServer(.lifetimeTotal(1))``: ONE session
    /// channel open per connection LIFETIME, the strict-gateway shape).
    /// Two sequential local dials: the FIRST relay rides the pool's
    /// shared carrier (its exec is that connection's only lifetime slot);
    /// the SECOND relay's exec open on the shared carrier is DENIED, so
    /// the pool retires it, flips sticky-dedicated, and dials the relay
    /// its OWN connection — the relay still opens and round-trips. Two
    /// dials and two SSH connections total: the Coder guarantee (one
    /// session channel per connection lifetime, never a second exec on
    /// a spent carrier) is preserved by the FALLBACK, not by dialing
    /// dedicated up front.
    func testSequentialDialsAgainstLifetimeBudgetOneFallBackToDedicatedOnDenial() async throws {
        let (key, acceptedBlob) = try Self.makeClientKeyStatic()
        let server = LoopbackPasswordSSHServer(
            username: Self.lifetimeUsername,
            password: "unused-password",
            keyAuthentication: .acceptedPublicKeys([acceptedBlob]),
            sessionChannelPolicy: .lifetimeTotal(1)
        )
        let port = try await server.start(port: 0)
        addTeardownBlock { await server.stop() }
        // The canned exec reply — the same shape every relay drains.
        server.execResponse = "hello-from-lifetime-1\n"

        // Dial-counting factory: pins WHICH relay triggered a dial (the
        // shared establish at relay 1, the dedicated fallback at relay 2).
        let dialCount = AtomicCounter()
        let countingFactory: @Sendable () async throws -> any SSHExecCapableConnection = {
            await dialCount.increment()
            return try await Self.makeExecOnlyLoopbackConnection(
                port: port,
                key: key,
                server: server
            )
        }

        let socketPath = try Self.bridgeSocketPath(profile: "cgwtwodials0000000000000000000")
        let log = eventLog!
        let bridge = HerdrEmbedBridgeServer(
            socketPath: socketPath,
            connectionFactory: countingFactory,
            executablePath: "/usr/bin/herdr",
            sessionName: nil
        )
        await bridge.setOnEvent { log.record($0) }
        try await bridge.start()
        addTeardownBlock { await bridge.stop() }

        // FIRST DIAL: rides the pool's shared carrier — the bridge's
        // exec-open is this connection's ONLY session channel (budget
        // slot #1), and the shared-mode lease close at relay end is a
        // RELEASE (the carrier survives for the next relay).
        let firstClient = try UnixStreamClient.connect(path: socketPath)
        try firstClient.writeAll(Data("ping\n".utf8))
        let firstBytes: Data
        do {
            firstBytes = try await firstClient.readUntil(
                needle: "hello-from-lifetime-1",
                timeout: .seconds(10)
            )
        } catch {
            // If the read fails because the bridge closed, surface the
            // typed factory / exec-open failure (the most likely cause
            // under a tight lifetime budget) so the assertion message
            // names the actual reason — the raw "bridge closed after 0
            // bytes" alone leaves the failure mode ambiguous.
            if let lost = await log.waitForCarrierLost(timeout: .milliseconds(50)) {
                XCTFail("first dial saw bridge close; carrierLost: \(lost)")
            }
            throw error
        }
        XCTAssertTrue(
            firstBytes.contains(Data("hello-from-lifetime-1".utf8)),
            "first relay saw the canned reply"
        )
        firstClient.close()
        let firstRelayEnd = await log.firstRelayEnd(timeout: .seconds(10))
        XCTAssertNotNil(firstRelayEnd, "first relay ended with a typed receipt")

        // Wait for the first relay's tail (session close + release-only
        // lease close) before the second dial, so the dial-count
        // assertion cannot conflate an in-flight shared establish with
        // the fallback dial.
        let dialsAfterFirst = await dialCount.value
        XCTAssertEqual(
            dialsAfterFirst, 1,
            "the first relay rode the pool's ONE shared dial"
        )

        // SECOND DIAL: the shared carrier's lifetime budget refuses the
        // exec open — the pool retires the carrier, flips
        // sticky-dedicated, and dials this relay its OWN connection; the
        // bridge exec opens as that connection's only session channel
        // (budget slot #1 of the new connection) and the canned reply
        // round-trips.
        let secondClient = try UnixStreamClient.connect(path: socketPath)
        defer { secondClient.close() }
        try secondClient.writeAll(Data("ping\n".utf8))
        let secondBytes = try await secondClient.readUntil(needle: "hello-from-lifetime-1", timeout: .seconds(10))
        XCTAssertTrue(
            secondBytes.contains(Data("hello-from-lifetime-1".utf8)),
            "second relay saw the canned reply on its dedicated fallback connection"
        )
        secondClient.close()

        // The load-bearing assertion (budget-fallback design proof): the
        // second dial succeeded only because the denial moved it onto a
        // FRESH dedicated connection — two SSH connections, two exec
        // channels, each as its connection's ONLY session channel under
        // a `.lifetimeTotal(1)` budget. A regression that re-opens on the
        // spent shared carrier would be refused as
        // `NIOSSHError.channelSetupRejected` and the second relay would
        // fail instead of round-tripping.
        try await Self.waitForConnectionCount(server: server, expected: 2, timeout: .seconds(5))
        XCTAssertEqual(
            server.authenticatedConnectionCount, 2,
            "the denial fallback resolved the second relay a dedicated connection"
        )
        let dials = await dialCount.value
        XCTAssertEqual(
            dials, 2,
            "exactly two dials: the shared establish and the denial's dedicated fallback"
        )

        // Each successful relay also produces a `.relayEnded` receipt —
        // waited (the relay tail races an immediate assertion; the
        // cleanup awaits session/carrier close AFTER the local channel
        // close).
        let relayEndCount = await log.waitForRelayEndCount(2, timeout: .seconds(5))
        XCTAssertEqual(
            relayEndCount, 2,
            "two relayEnded receipts, one per dial"
        )
    }

    /// SHARED-FIRST (the efficient default): two sequential dials ride ONE
    /// shared carrier — the first relay's dial establishes the pool's
    /// shared connection, its release-only lease close at relay end keeps
    /// that carrier alive, and the second relay's exec opens on it without
    /// another dial (the pre-pool shape dialed per relay: 2 dials). Both
    /// relays round-trip the real herdr welcome frame.
    func testSequentialRelaysShareOneCarrierConnection() async throws {
        try Self.requireFixture(serverPort: 12222)
        let probed = try await establishProbed(connection: try SSHTestFixture.makeConnection())
        let socketPath = try Self.bridgeSocketPath(profile: "twodialstest00000000000000000000")

        // Dial-counting factory: the shared-carrier proof's witness.
        let dialCount = AtomicCounter()
        let countingFactory: @Sendable () async throws -> any SSHExecCapableConnection = {
            await dialCount.increment()
            return try await probed.carrierFactory()
        }
        let server = HerdrEmbedBridgeServer(
            socketPath: socketPath,
            connectionFactory: countingFactory,
            executablePath: probed.executablePath,
            sessionName: nil
        )
        let log = eventLog!
        await server.setOnEvent { log.record($0) }
        try await server.start()

        // First dial: establishes the shared carrier, opens the bridge
        // exec on it, relays the hello+welcome, the client closes, the
        // relay ends with a release-only lease close (the carrier
        // survives).
        let firstClient = try UnixStreamClient.connect(path: socketPath)
        try firstClient.writeAll(Self.helloFrame)
        _ = try await firstClient.readFirstFrame(
            containing: "endpoint.welcome.v1",
            timeout: .seconds(10)
        )
        firstClient.close()
        let firstRelayEnd = await log.firstRelayEnd(timeout: .seconds(10))
        let first = try XCTUnwrap(firstRelayEnd, "first relay end receipt")
        XCTAssertGreaterThan(first.bytesUp, 0)
        XCTAssertGreaterThan(first.bytesDown, 0)

        // Second dial AFTER the first fully ended: rides the SAME shared
        // carrier — no new dial, the bridge exec opens as a sibling
        // session channel, and the welcome frame round-trips again.
        let secondClient = try UnixStreamClient.connect(path: socketPath)
        defer { secondClient.close() }
        try secondClient.writeAll(Self.helloFrame)
        _ = try await secondClient.readFirstFrame(
            containing: "endpoint.welcome.v1",
            timeout: .seconds(10)
        )
        secondClient.close()

        // Two relayEnd events: one per dial. Waited (the relay tail
        // races the assertion — the cleanup awaits session/carrier
        // close AFTER the local channel close).
        let relayEndCount = await log.waitForRelayEndCount(2, timeout: .seconds(5))
        XCTAssertEqual(
            relayEndCount, 2,
            "two sequential dials produced two relayEnded receipts"
        )
        let dials = await dialCount.value
        XCTAssertEqual(
            dials, 1,
            "both sequential relays rode ONE shared carrier (the pre-pool shape dialed once per relay)"
        )

        await server.stop()
        let stoppedEvent = await log.firstStopped()
        let stopped = try XCTUnwrap(stoppedEvent, "stop receipt arrived after both dials")
        XCTAssertTrue(stopped.isStopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    /// Listener robustness: one dial whose factory throws must fail the
    /// relay (typed carrierLost event) WITHOUT stopping the listener —
    /// a subsequent successful dial still works. The client's supervisor
    /// redial is the recovery mechanism; the listener never crashes on
    /// a bad factory call.
    func testFactoryFailureOnOneDialFailsThatRelayOnlyAndListenerSurvives() async throws {
        try Self.requireFixture(serverPort: 12222)
        let probed = try await establishProbed(connection: try SSHTestFixture.makeConnection())
        let socketPath = try Self.bridgeSocketPath(profile: "factoryfail00000000000000000000")

        let factoryFailures = AtomicCounter()
        let flaky = FlakyCarrierFactory(
            underlying: probed.carrierFactory,
            failFirstN: 1,
            onFail: { await factoryFailures.increment() }
        )

        let server = HerdrEmbedBridgeServer(
            socketPath: socketPath,
            connectionFactory: flaky.call,
            executablePath: probed.executablePath,
            sessionName: nil
        )
        let log = eventLog!
        await server.setOnEvent { log.record($0) }
        try await server.start()

        // First dial: factory throws (failFirstN=1). The relay fails
        // typed, the listener survives, the local child is discarded.
        let failingClient = try UnixStreamClient.connect(path: socketPath)
        defer { failingClient.close() }
        let lost = await eventLog.firstCarrierLost(timeout: .seconds(5))
        XCTAssertNotNil(
            lost,
            "a factory-throwing dial surfaced as a typed carrierLost event"
        )
        let count = await factoryFailures.value
        XCTAssertEqual(count, 1, "the factory was called once and refused")

        // Subsequent dial: factory succeeds (NoopCounter drains); the
        // bridge relay round-trips the hello+welcome as normal.
        let goodClient = try UnixStreamClient.connect(path: socketPath)
        defer { goodClient.close() }
        try goodClient.writeAll(Self.helloFrame)
        _ = try await goodClient.readFirstFrame(
            containing: "endpoint.welcome.v1",
            timeout: .seconds(10)
        )
        goodClient.close()
        let firstRelayEnd = await eventLog.firstRelayEnd(timeout: .seconds(10))
        XCTAssertNotNil(
            firstRelayEnd,
            "the post-failure dial's relay round-tripped and ended"
        )

        await server.stop()
        let stoppedEvent = await eventLog.firstStopped()
        let stopped = try XCTUnwrap(stoppedEvent, "stop receipt arrived")
        XCTAssertTrue(stopped.isStopped)
    }

    /// Split out of the test body: an inline `do/catch` around the typed
    /// start error crashes the SIL verifier (LinearLifetimeChecker, the
    /// same Swift 6.x family documented on JumpChainBuilder).
    private static func refusesToReplaceLiveListener(
        at path: String,
        probed: HerdrProbedCarrier
    ) async -> Bool {
        let contender = HerdrEmbedBridgeServer(
            socketPath: path,
            connectionFactory: probed.carrierFactory,
            executablePath: probed.executablePath,
            sessionName: nil
        )
        do {
            try await contender.start()
            await contender.stop()
            return false
        } catch let error as HerdrEmbedBridgeError {
            return error == .liveListenerExists(path: path)
        } catch {
            return false
        }
    }

    // MARK: - Fixtures

    private static let herdrFixtureBin = "Fixtures/run/herdr/herdr"

    private static func fixtureIsUp(serverPort: Int) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: SSHTestFixture.repoRoot.appendingPathComponent(herdrFixtureBin).path)
            && fm.fileExists(
                atPath: SSHTestFixture.repoRoot
                    .appendingPathComponent("Fixtures/run/herdr/server-\(serverPort)/herdr-client.sock")
                    .path
            )
    }

    private static func requireFixture(serverPort: Int) throws {
        try XCTSkipUnless(
            fixtureIsUp(serverPort: serverPort),
            "herdr fixture not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
        )
    }

    /// Establishes + probes, returns the ``HerdrProbedCarrier``; the
    /// tests resolve the factory per-relay (each dial gets a fresh
    /// channel-less connection — the unit-5 per-relay design).
    private func establishProbed(
        connection: Connection
    ) async throws -> HerdrProbedCarrier {
        let connector = HerdrEndpointConnector(
            hostKeyVerifier: try await Self.makeTrustedVerifier(),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
            metadataProvider: FixtureKeyMetadataProvider(),
            searchPaths: [
                SSHTestFixture.repoRoot.appendingPathComponent(Self.herdrFixtureBin).path
            ],
            approveHostKey: { _ in false }
        )
        return try await connector.establishProbed(connection)
    }

    private static func makeTrustedVerifier() async throws -> HostKeyVerifier {
        if Self.hop2FixtureUp() {
            return try await JumpFixture.makeVerifier(trustingHop2: true)
        }
        return try await SSHTestFixture.makeVerifier()
    }

    private static func hop2FixtureUp() -> Bool {
        FileManager.default.fileExists(
            atPath: SSHTestFixture.repoRoot
                .appendingPathComponent("Fixtures/run/herdr/server-12223/herdr-client.sock")
                .path
        )
    }

    private func makeServer(
        probed: HerdrProbedCarrier,
        socketPath: String
    ) async -> HerdrEmbedBridgeServer {
        let server = HerdrEmbedBridgeServer(
            socketPath: socketPath,
            connectionFactory: probed.carrierFactory,
            executablePath: probed.executablePath,
            sessionName: nil
        )
        let log = eventLog!
        await server.setOnEvent { log.record($0) }
        return server
    }

    private static func bridgeSocketPath(profile: String) throws -> String {
        let directory = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/herdr-bridge")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let path = directory.appendingPathComponent("\(profile).sock").path
        precondition(
            path.utf8.count < 100,
            "bridge socket path must fit sockaddr_un.sun_path: \(path)"
        )
        return path
    }

    /// The generation-1 `endpoint.hello.v1` frame the real codec emits
    /// (provenance: `HerdrServerFixtureHandshakeTests.helloFrame`).
    private static let helloFrame = HerdrServerFixtureHandshakeTests.helloFrame
}

// MARK: - Event capture

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HerdrEmbedBridgeEvent] = []

    func record(_ event: HerdrEmbedBridgeEvent) {
        lock.withLock { events.append(event) }
    }

    func allEvents() -> [HerdrEmbedBridgeEvent] {
        lock.withLock { events }
    }

    func firstStopped() async -> HerdrEmbedBridgeEvent? {
        await firstMatch(where: \.isStopped)
    }

    func firstCarrierLost(timeout: Duration) async -> String? {
        let match: HerdrEmbedBridgeEvent? = await firstMatch(
            where: { if case .carrierLost = $0 { return true } else { return false } },
            timeout: timeout
        )
        guard case let .carrierLost(reason) = match else { return nil }
        return reason
    }

    func firstRelayEnd(timeout: Duration) async -> (clean: Bool, bytesUp: Int, bytesDown: Int)? {
        let match: HerdrEmbedBridgeEvent? = await firstMatch(
            where: { if case .relayEnded = $0 { return true } else { return false } },
            timeout: timeout
        )
        guard case let .relayEnded(clean, bytesUp, bytesDown) = match else { return nil }
        return (clean, bytesUp, bytesDown)
    }

    /// Waits for the count of `.relayEnded` events to reach `expected`.
    /// The relay tasks' cleanup (await session.close / carrier.close)
    /// continues asynchronously after the local channel close — without
    /// a wait, an immediately-following assertion races the tail and
    /// reads a stale count. Polled on the same locked snapshot as
    /// `allEvents`.
    func waitForRelayEndCount(
        _ expected: Int,
        timeout: Duration
    ) async -> Int {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            let count = lock.withLock {
                events.filter {
                    if case .relayEnded = $0 { return true } else { return false }
                }.count
            }
            if count >= expected { return count }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock {
            events.filter {
                if case .relayEnded = $0 { return true } else { return false }
            }.count
        }
    }

    /// Short-timeout poll for the first `.carrierLost` event — used by
    /// tests that need to assert the bridge factory DID NOT throw on a
    /// healthy path. Returns the reason if a carrierLost fires within
    /// the timeout, nil otherwise.
    func waitForCarrierLost(timeout: Duration) async -> String? {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let found = lock.withLock({ events.first(where: {
                if case .carrierLost = $0 { return true } else { return false } }
            ) }) {
                guard case let .carrierLost(reason) = found else { return nil }
                return reason
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func firstMatch(
        where predicate: (HerdrEmbedBridgeEvent) -> Bool
    ) async -> HerdrEmbedBridgeEvent? {
        await firstMatch(where: predicate, timeout: .seconds(5))
    }

    private func firstMatch(
        where predicate: (HerdrEmbedBridgeEvent) -> Bool,
        timeout: Duration
    ) async -> HerdrEmbedBridgeEvent? {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let found = lock.withLock({ events.first(where: predicate) }) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock { events.first(where: predicate) }
    }
}

// MARK: - POSIX local-stream stand-in for the embedded client

/// Blocking unix-domain client with a receive timeout — the same dial
/// herdr's `bicterm-transport` performs against
/// `{HERDR_EMBED_TRANSPORT_DIR}/{profile id}.sock`.
private final class UnixStreamClient {
    private let fd: Int32

    static func connect(path: String) throws -> UnixStreamClient {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "UnixStreamClient", code: 1)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "UnixStreamClient", code: 2) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    fd,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw NSError(
                domain: "UnixStreamClient",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "connect errno \(errno)"]
            )
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return UnixStreamClient(fd: fd)
    }

    private init(fd: Int32) {
        self.fd = fd
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if wrote <= 0 { throw NSError(domain: "UnixStreamClient", code: 4) }
                sent += wrote
            }
        }
    }

    /// Reads until a complete `[u32 LE length][payload]` frame whose
    /// payload contains `needle` arrives.
    func readFirstFrame(containing needle: String, timeout: Duration) async throws -> Data {
        let deadline = ContinuousClock().now + timeout
        var buffer = Data()
        while ContinuousClock().now < deadline {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let read = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if read > 0 {
                buffer.append(contentsOf: chunk[0..<read])
            }
            if read == 0 {
                throw NSError(
                    domain: "UnixStreamClient",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "bridge closed after \(buffer.count) bytes"]
                )
            }
            while let frame = HerdrServerFixtureHandshakeTests.firstCompleteFrame(in: buffer) {
                if String(decoding: frame, as: UTF8.self).contains(needle) {
                    return frame
                }
                buffer.removeFirst(4 + frame.count)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "UnixStreamClient",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "timed out after \(buffer.count) bytes"]
        )
    }

    func close() {
        Darwin.close(fd)
    }

    /// Reads raw bytes until `needle` appears in the buffer or the timeout
    /// elapses. The loopback server's exec reply is NOT length-framed
    /// (the herdr fixture's welcome IS, but for the lifetime-budget relay
    /// proof we drive the bridge against the loopback server and want
    /// the raw canned reply without framing) — so this helper exists in
    /// addition to `readFirstFrame`.
    func readUntil(needle: String, timeout: Duration) async throws -> Data {
        let deadline = ContinuousClock().now + timeout
        var buffer = Data()
        while ContinuousClock().now < deadline {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let read = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if read > 0 {
                buffer.append(contentsOf: chunk[0..<read])
            }
            if buffer.range(of: Data(needle.utf8)) != nil {
                return buffer
            }
            if read == 0 {
                throw NSError(
                    domain: "UnixStreamClient",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "bridge closed after \(buffer.count) bytes"]
                )
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "UnixStreamClient",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "timed out after \(buffer.count) bytes"]
        )
    }
}

// MARK: - Lifetime-budget helpers

extension HerdrEmbedBridgeServerTests {
    fileprivate static let lifetimeUsername = "lifetime-bridge-user"

    /// Fresh software ed25519 key plus the blob the loopback server must
    /// accept for it (matches the connector lifetime-budget suite's
    /// `makeClientKey` shape). STATIC so the test can call it from
    /// inside `@Sendable` closures without capturing `self`.
    fileprivate static func makeClientKeyStatic() throws -> (key: NIOSSHPrivateKey, acceptedBlob: Data) {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let components = String(openSSHPublicKey: key.publicKey)
            .split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            throw NSError(domain: "HerdrEmbedBridgeServerTests", code: 1)
        }
        return (key, blob)
    }

    /// Bridges connect through a factory that does a fresh
    /// ``SSHTransport/connectExecOnly(to:)`` per call (no probe — the
    /// test wires directly to the loopback server, so each relay's
    /// connection is provably the only thing touching the budget).
    /// STATIC + takes `server` explicitly so the closure capturing it
    /// satisfies `@Sendable` (XCTestCase is not Sendable).
    fileprivate static func makeExecOnlyLoopbackConnection(
        port: Int,
        key: NIOSSHPrivateKey,
        server: LoopbackPasswordSSHServer
    ) async throws -> any SSHExecCapableConnection {
        let verifier = try await pretrustingVerifierForLoopback(server: server, port: port)
        let transport = SSHTransport(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: StaticKeyProvider(key: key),
            passwordStore: InMemoryPasswordStore([:]),
            // The default `DefaultSSHKeyMetadataProvider` returns no
            // metadata in tests (no Keychain-backed defaults); without
            // explicit metadata the `KeyOfferResolver` filter empties
            // the offer list and the cascade offers nothing — server
            // rejects → `.authenticationFailed`. Inject the fixture
            // provider so "fixture-ed25519" is offered.
            metadataProvider: FixtureKeyMetadataProvider()
        )
        let connection = try Connection(
            name: "lifetime-bridge", type: .ssh,
            host: "127.0.0.1", port: port,
            username: lifetimeUsername,
            customKeys: ["fixture-ed25519"]
        )
        try await transport.connectExecOnly(to: connection)
        return transport
    }

    fileprivate static func pretrustingVerifierForLoopback(
        server: LoopbackPasswordSSHServer,
        port: Int
    ) async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: EphemeralHostKeyStore())
        // The server's host key is a stable property of the instance
        // (set at init or via the explicit `hostKey` arg) — `hostKeyOpenSSH`
        // is the `algorithm base64-blob` authorized_keys format.
        let components = server.hostKeyOpenSSH.split(separator: " ", maxSplits: 1)
        let blob = try XCTUnwrap(Data(base64Encoded: String(components[1])))
        try await verifier.trust(
            host: "127.0.0.1",
            port: port,
            key: blob,
            algorithm: String(components[0])
        )
        return verifier
    }

    /// Polls `authenticatedConnectionCount` until it reaches `expected`
    /// or the timeout elapses — the first dial must tear its connection
    /// down before `authenticatedConnectionCount` advances to the second,
    /// otherwise the lifetime-budget assertion (== 2 across two dials)
    /// would conflate "two connections alive" with "two connections
    /// total".
    fileprivate static func waitForConnectionCount(
        server: LoopbackPasswordSSHServer,
        expected: Int,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if server.authenticatedConnectionCount == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let count = server.authenticatedConnectionCount
        XCTAssertEqual(
            count, expected,
            "waiting for authenticatedConnectionCount == \(expected) (got \(count))"
        )
    }
}

/// Reads the loopback server's `hostKeyOpenSSH` via a probe connection —
/// the standard pattern across the connector lifetime-budget tests. The
/// probe is a throwaway exec-only SSHTransport that opens no session
/// channel (it just walks the handshake so the server publishes its key).
// (ServerKeyProbe removed: the loopback server's host key is a stable
// property of the instance — `hostKeyOpenSSH` reads from the constructed
// `hostKey`, no probe connection needed. The test passes the server into
// `pretrustingVerifierForLoopback(server:port:)` instead.)

// MARK: - Factory-failure helpers

/// Factory wrapper that throws for the first N calls, then delegates to
/// the underlying factory. Drives the listener-robustness test: one
/// bad dial must not stop the listener; the next dial still resolves.
/// CLASS (not struct) so the captured `self` survives the @Sendable
/// closure's value-capture (struct mutations would fail strict
/// concurrency: `self` is immutable inside an async method on a struct
/// captured by another closure).
private final class FlakyCarrierFactory: @unchecked Sendable {
    private let underlying: @Sendable () async throws -> any SSHExecCapableConnection
    private let failFirstN: Int
    private let onFail: @Sendable () async -> Void
    private let lock = NSLock()
    private var calls = 0

    init(
        underlying: @escaping @Sendable () async throws -> any SSHExecCapableConnection,
        failFirstN: Int,
        onFail: @escaping @Sendable () async -> Void
    ) {
        self.underlying = underlying
        self.failFirstN = max(0, failFirstN)
        self.onFail = onFail
    }

    func call() async throws -> any SSHExecCapableConnection {
        let callIndex: Int = lock.withLock {
            let current = calls
            calls += 1
            return current
        }
        if callIndex < failFirstN {
            await onFail()
            throw NSError(
                domain: "FlakyCarrierFactory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "flaky factory refused dial #\(callIndex)"]
            )
        }
        return try await underlying()
    }
}

/// Lock-confined counter — the bridge server's factory calls are
/// concurrent across relays (not strictly, here, but a counter is the
/// simplest deterministic witness for "the factory was called exactly
/// once before the failure dial").
private actor AtomicCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
