import Foundation
import XCTest
@testable import BicTermCore

/// Regression tests for the embedded bridge's RELATIVE socket paths (the
/// `tmp/herdr-embed-transport/<profile>.sock` shape the app pins the
/// process cwd for): a bring-up whose cwd is NOT pinned must fail with the
/// REAL filesystem reason for the socket directory, never the downstream
/// `bind(2)` ENOENT that hides it (the reported
/// `bindFailed(... "No such file or directory" ... errno: 2)` startup
/// failure). Hermetic — no fixtures, a stub carrier, no live relays.
final class HerdrEmbedBridgeRelativePathTests: XCTestCase {
    private static let profile = "relparentfail0000000000000000"
    private static let socketPath = "tmp/herdr-embed-transport/\(profile).sock"

    func testUncreatableRelativeParentSurfacesDirectoryFailureNotBindENOENT() async throws {
        // The observed failure state: the cwd is NOT the pinned app home,
        // so the relative transport directory cannot be created. A
        // repo-local READ-ONLY scratch stands in for the device's
        // read-only unpinned cwd — chdir("/") no longer works for this
        // (macOS /tmp is writable, which would both succeed and write
        // outside the repository). The bridge must say the REAL
        // filesystem reason, not a bind ENOENT.
        let original = FileManager.default.currentDirectoryPath
        defer { chdir(original) }
        let scratch = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-bridge-relative-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        defer {
            // Restore writability BEFORE removal — the read-only mode is
            // the failure injection under test.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scratch.path
            )
            try? FileManager.default.removeItem(at: scratch)
        }
        XCTAssertEqual(
            chdir(scratch.path), 0,
            "the test process must be able to chdir into the scratch"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: scratch.path
        )

        let server = HerdrEmbedBridgeServer(
            socketPath: Self.socketPath,
            connectionFactory: { StubExecCarrier() },
            executablePath: "/usr/bin/true",
            sessionName: nil
        )
        do {
            try await server.start()
            XCTFail("start() must fail when the socket directory cannot exist")
        } catch let error as HerdrEmbedBridgeError {
            guard case let .bindFailed(path, reason) = error else {
                return XCTFail("expected bindFailed, got \(error)")
            }
            XCTAssertEqual(path, Self.socketPath)
            XCTAssertFalse(
                reason.contains("No such file or directory"),
                "the directory-creation failure must surface its real reason, "
                    + "not the downstream bind ENOENT: \(reason)"
            )
        }
        await server.stop()
    }

    /// The SUCCESS path the failure test above guards the boundary of —
    /// and the reported `liveListenerExists`/`couldn't connect` startup
    /// failures' happy shape: with the cwd pinned to a writable home, the
    /// bridge binds the RELATIVE `tmp/herdr-embed-transport/<profile>.sock`,
    /// a client dials that same relative path (the exact dial the embedded
    /// Rust client performs against `HERDR_EMBED_TRANSPORT_DIR`), and
    /// stop() unlinks the socket and leaves no file behind. The stub
    /// carrier refuses the exec open, so the accepted relay ends as a
    /// typed carrierLost — the bind/listen/dial contract is what this
    /// pins, not the relay.
    func testRelativePathBridgeBindsAndClientConnectsUnderPinnedCWD() async throws {
        let cwdBefore = FileManager.default.currentDirectoryPath
        let scratch = try makeScratchHome()
        let owner = try pinCWDForTest(scratch: scratch)

        let socketPath = "tmp/herdr-embed-transport/relbindok0000000000000000000.sock"
        let server = HerdrEmbedBridgeServer(
            socketPath: socketPath,
            connectionFactory: { StubExecCarrier() },
            executablePath: "/usr/bin/true",
            sessionName: nil
        )
        let events = EventLog()
        await server.setOnEvent { events.record($0) }
        try await server.start()

        // The socket materialized under the PINNED home's tmp/ — never at
        // the home root (the device EPERM regression shape).
        let expectedFile = scratch
            .appendingPathComponent(socketPath, isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedFile.path),
            "bridge socket exists at the pinned home's \(socketPath)"
        )
        let listening = await events.sawListening(path: socketPath)
        XCTAssertTrue(
            listening,
            "listening receipt carries the relative path"
        )

        // The client dial: connect(2) against the RELATIVE path resolves
        // against the same pinned cwd (the embed crate's dial shape).
        let clientFD = try Self.connectRelative(path: socketPath)
        XCTAssertGreaterThanOrEqual(clientFD, 0, "relative-path dial succeeded")
        Darwin.close(clientFD)

        await server.stop()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expectedFile.path),
            "stop() unlinked the socket"
        )
        let stopped = await events.sawStopped()
        XCTAssertTrue(
            stopped,
            "stop receipt arrived"
        )

        HerdrEmbedTransportWorkspace.releaseCWD(owner: owner)
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "the pin release restored the pre-test cwd"
        )
    }

    /// The reported `liveListenerExists(path: "tmp/herdr-embed-transport/
    /// <hex>.sock")` refusal, under the RELATIVE path shape it was
    /// reported in: a stale leftover file is swept and rebound, but a
    /// LIVE listener on the same relative path is refused with the typed
    /// error carrying that relative path — never silently replaced.
    func testRelativePathStaleSocketSweptAndLiveListenerRefused() async throws {
        let scratch = try makeScratchHome()
        let owner = try pinCWDForTest(scratch: scratch)
        defer { HerdrEmbedTransportWorkspace.releaseCWD(owner: owner) }

        let socketPath = "tmp/herdr-embed-transport/relstalelive000000000000000.sock"
        // Stale leftover (a regular file where the socket will bind — no
        // listener): swept, and the bind succeeds.
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent(
                "tmp/herdr-embed-transport", isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: scratch.appendingPathComponent(socketPath).path,
                contents: nil
            ),
            "test precondition: the stale leftover file exists"
        )

        let server = HerdrEmbedBridgeServer(
            socketPath: socketPath,
            connectionFactory: { StubExecCarrier() },
            executablePath: "/usr/bin/true",
            sessionName: nil
        )
        try await server.start()
        defer { Task { await server.stop() } }

        // A second bring-up on the same LIVE path is refused typed, with
        // the relative path the client would report.
        let refusal = await Self.startRefusal(at: socketPath)
        XCTAssertEqual(
            refusal, .liveListenerExists(path: socketPath),
            "a live listener on the relative path is refused typed"
        )

        await server.stop()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(socketPath).path
            ),
            "stop() unlinked the relative socket"
        )
    }

    // MARK: - Helpers

    /// Repo-local hermetic scratch home (gitignored `Fixtures/run/`),
    /// unique per test — the containment-rule-compliant stand-in for the
    /// app container home the production pin targets.
    private func makeScratchHome() throws -> URL {
        let scratch = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-bridge-relative-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        addTeardownBlock { [scratch] in
            try? FileManager.default.removeItem(at: scratch)
        }
        return scratch
    }

    /// Pins the process cwd to the scratch home through the PRODUCTION
    /// pin (the owned `HerdrEmbedTransportWorkspace` seam), capturing the
    /// pre-pin cwd for the restoration assertion. The caller releases
    /// with the returned owner (or the tearDown backstop chdir does).
    private func pinCWDForTest(scratch: URL) throws -> PinOwner {
        let owner = PinOwner()
        try HerdrEmbedTransportWorkspace.pinCWD(
            homeDirectory: scratch.path,
            owner: owner
        )
        addTeardownBlock { [owner] in
            HerdrEmbedTransportWorkspace.releaseCWD(owner: owner)
        }
        return owner
    }

    /// Minimal POSIX connect(2) against a (relative) unix socket path —
    /// the same dial the embedded client performs. Returns the connected
    /// fd; the caller closes it.
    private static func connectRelative(path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "connectRelative", code: 1)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "connectRelative", code: 2) }
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
            let connectErrno = errno
            Darwin.close(fd)
            throw NSError(
                domain: "connectRelative",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "connect errno \(connectErrno)"]
            )
        }
        return fd
    }

    /// Split out of the test body (the typed-error do/catch SIL verifier
    /// crash documented on HerdrEmbedBridgeServerTests).
    private static func startRefusal(at path: String) async -> HerdrEmbedBridgeError? {
        let contender = HerdrEmbedBridgeServer(
            socketPath: path,
            connectionFactory: { StubExecCarrier() },
            executablePath: "/usr/bin/true",
            sessionName: nil
        )
        do {
            try await contender.start()
            await contender.stop()
            return nil
        } catch let error as HerdrEmbedBridgeError {
            return error
        } catch {
            return nil
        }
    }
}

/// Identity token for the workspace pin (ObjectIdentifier-keyed).
private final class PinOwner: @unchecked Sendable {}

/// Minimal event capture for the relative-path lifecycle assertions.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HerdrEmbedBridgeEvent] = []

    func record(_ event: HerdrEmbedBridgeEvent) {
        lock.withLock { events.append(event) }
    }

    func sawListening(path: String) async -> Bool {
        await poll {
            self.lock.withLock {
                self.events.contains(.listening(socketPath: path))
            }
        }
    }

    func sawStopped() async -> Bool {
        await poll {
            self.lock.withLock {
                self.events.contains(where: \.isStopped)
            }
        }
    }

    private func poll(_ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}

/// Never reaches a relay: start() fails before the listener accepts.
private struct StubExecCarrier: SSHExecCapableConnection {
    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        throw .channelDenied
    }

    func close() async {}
}
