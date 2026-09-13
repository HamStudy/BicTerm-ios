import Foundation
import XCTest
@testable import BicTermCore

/// T5 transport-injection proof at the CORE boundary: the bridge server
/// serves herdr's `bicterm-transport` host socket and relays local-socket
/// bytes to a fresh `remote-client-bridge` exec channel on the established
/// carrier — direct (12222) and jump-chained (12222 → 12223) — against the
/// prebuilt herdr 0.9.0 fixture servers. The local side of each test is a
/// plain POSIX UDS client standing in for the embedded Rust client (same
/// dial the embed crate performs); the E2E with the REAL embedded TUI
/// lives in the app suite (`HerdrEmbedTransportTests`).
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
        XCTAssertTrue(parsed.json.contains("\"server_version\":\"0.9.0\""), parsed.json)

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

    /// T6 regression (sever-one-machine): after the SSH carrier dies, the
    /// client's supervisor redials the still-listening bridge socket; the
    /// freshly accepted child's exec open fails and the child must be
    /// discarded WITHOUT NIOAsyncWriter's deinit trap — dropping an
    /// unrelayed child without `finish()` precondition-fails and kills the
    /// whole process (the embedded-client crash this test pins).
    func testRedialAgainstDeadCarrierDiscardsChildWithoutTrapping() async throws {
        try Self.requireFixture(serverPort: 12222)
        let probed = try await establishProbed(connection: try SSHTestFixture.makeConnection())
        let socketPath = try Self.bridgeSocketPath(profile: "redialdead0000000000000000000")

        let server = await makeServer(probed: probed, socketPath: socketPath)
        try await server.start()

        let live = try UnixStreamClient.connect(path: socketPath)
        try live.writeAll(Self.helloFrame)
        _ = try await live.readFirstFrame(
            containing: "endpoint.welcome.v1",
            timeout: .seconds(10)
        )
        live.close()

        await probed.carrier.close()

        let redial = try UnixStreamClient.connect(path: socketPath)
        defer { redial.close() }
        try redial.writeAll(Self.helloFrame)

        let lostEvent = await eventLog.firstCarrierLost(timeout: .seconds(10))
        XCTAssertNotNil(
            lostEvent,
            "the dead carrier surfaced as a typed carrierLost event, not a trap"
        )

        await server.stop()
        let stoppedEvent = await eventLog.firstStopped()
        let stopped = try XCTUnwrap(stoppedEvent, "stop receipt arrived after the redial cycle")
        XCTAssertTrue(stopped.isStopped, "stop receipt arrived (got \(stopped))")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "no leaked socket file after the redial cycle"
        )
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
            carrier: probed.carrier,
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

    private func establishProbed(
        connection: Connection
    ) async throws -> HerdrProbedCarrier {
        let connector = HerdrEndpointConnector(
            hostKeyVerifier: try await Self.makeTrustedVerifier(),
            authenticationKeyProvider: StaticKeyProvider(
                key: try await SSHTestFixture.loadFixtureEd25519Key()
            ),
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
            carrier: probed.carrier,
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
}
