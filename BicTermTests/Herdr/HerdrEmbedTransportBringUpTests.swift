import BicTermCore
import XCTest

@testable import BicTerm

/// Success-path bring-up proofs for the embedded herdr transport (the
/// "basics of starting and using herdr" at the coordinator level, no SSH
/// and no fixtures): `prepare()` pins the cwd, creates the transport
/// directory under the home's `tmp/` (the data-container ROOT is not
/// writable on device — EPERM — so the `tmp/` prefix is the regression
/// guard for the reported container-root `bindFailed`), binds one bridge
/// socket per machine (Mode A = 1, herd = N), seeds the client catalog,
/// and applies the transport environment; a client can then DIAL each
/// relative socket path (the embed crate's dial shape — the reported
/// "couldn't connect to the existing one" failure mode); `teardown()`
/// unlinks every socket, closes every carrier exactly once, and restores
/// the cwd, so a later bring-up binds cleanly (the reported
/// `liveListenerExists`-on-retry failure mode).
@MainActor
final class HerdrEmbedTransportBringUpTests: XCTestCase {
    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var scratch: URL!
    private var cwdBefore: String!
    private var savedTransportDir: String?
    private var savedStateHome: String?

    override func setUp() async throws {
        try await super.setUp()
        cwdBefore = FileManager.default.currentDirectoryPath
        // applyEnvironment() sets process-global env; save and restore so
        // a bring-up never leaks into sibling tests.
        savedTransportDir = getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) }
        savedStateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        // Repo-local scratch on the simulator host (containment rule); on
        // a physical device the build-machine path does not exist, so the
        // scratch falls back to the app container's own tmp — which is
        // exactly the filesystem shape production uses.
        let scratchBase: URL
        if FileManager.default.fileExists(atPath: Self.repoRoot.path) {
            scratchBase = Self.repoRoot
                .appendingPathComponent("Fixtures/run/herdr-bringup-tests", isDirectory: true)
        } else {
            scratchBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("herdr-bringup-tests", isDirectory: true)
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
        chdir(cwdBefore)
        restoreEnv("HERDR_EMBED_TRANSPORT_DIR", value: savedTransportDir)
        restoreEnv("XDG_STATE_HOME", value: savedStateHome)
        try await super.tearDown()
    }

    /// The SPEC, not the production constant: the transport directory must
    /// live under the home's tmp/ because the data-container ROOT is not
    /// writable on device (EPERM). Hardcoded here on purpose — deriving
    /// expectations from `transportDirectoryRelativePath` would make the
    /// test tautological (a regression dropping the tmp/ prefix would
    /// change production and expectation in lockstep and stay green).
    private static let specifiedTransportDirectory = "tmp/herdr-embed-transport"

    /// Structural SPEC for one bring-up's transport paths (aa4f75b):
    /// `<specifiedTransportDirectory>/<8-lowercase-hex token>/<leaf>` —
    /// the tmp/ prefix is the container-root EPERM guard; the token
    /// segment is the per-bring-up socket namespace that keeps a reopened
    /// herd's binds from colliding with a superseded run's teardown. The
    /// token is random per bring-up, so expectations match the SHAPE —
    /// never a hardcoded token.
    private static func matchesTokenizedPath(_ path: String, leaf: String) -> Bool {
        let pattern = "^"
            + NSRegularExpression.escapedPattern(for: specifiedTransportDirectory)
            + "/[0-9a-f]{8}/"
            + NSRegularExpression.escapedPattern(for: leaf)
            + "$"
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    func testPrepareBindsPerMachineSocketsSeedsCatalogAndTeardownUnlinks() async throws {
        let (coordinator, carriers, links) = makeCoordinator(machineCount: 2)
        coordinator.homeDirectoryForTesting = scratch.path

        let localPath = try await coordinator.prepare()
        XCTAssertTrue(
            Self.matchesTokenizedPath(localPath, leaf: "local.sock"),
            "the client endpoint path is local.sock under tmp/herdr-embed-transport/<token>: \(localPath)"
        )

        // The pinned cwd is the scratch home while the run is alive.
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, scratch.path,
            "prepare() pinned the cwd to the home the relative binds resolve against"
        )

        // One live socket per machine, under
        // <home>/tmp/herdr-embed-transport/<token>/ — the tmp/ prefix is
        // the guard against the container-root EPERM regression (the
        // reported bindFailed at the data-container root), and the token
        // segment is this bring-up's socket namespace (aa4f75b).
        for link in links {
            let relativeSocket = coordinator.socketPath(for: link.machine)
            XCTAssertTrue(
                Self.matchesTokenizedPath(relativeSocket, leaf: "\(link.machine.profileID).sock"),
                "machine socket keeps the tmp/ + token layout: \(relativeSocket)"
            )
            let socket = scratch.appendingPathComponent(relativeSocket)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: socket.path),
                "bridge socket bound at \(socket.path)"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
            XCTAssertEqual(
                attributes[.posixPermissions] as? Int, 0o600,
                "bridge socket carries the uds-forward.py 0600 contract"
            )

            // The client dial: connect(2) against the RELATIVE path — the
            // same dial the embedded client performs. The stub carrier
            // refuses the exec open (typed carrierLost), but the
            // bind/listen/accept contract is what "starting herdr" needs.
            let fd = try Self.connectSocket(path: relativeSocket)
            Darwin.close(fd)
        }

        // Transport environment applied: the client resolves THIS
        // bring-up's tokenized directory, and the catalog landed in the
        // state home.
        XCTAssertEqual(
            getenv("HERDR_EMBED_TRANSPORT_DIR").map { String(cString: $0) },
            coordinator.transportDirectory
        )
        let stateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        XCTAssertNotNil(stateHome, "XDG_STATE_HOME applied for the client catalog")
        let catalogURL = URL(fileURLWithPath: try XCTUnwrap(stateHome))
            .appendingPathComponent("herdr/client/endpoints.json")
        let catalog = try String(contentsOf: catalogURL, encoding: .utf8)
        for link in links {
            XCTAssertTrue(
                catalog.contains(link.machine.profileID),
                "catalog seeds machine \(link.machine.profileID)"
            )
        }

        await coordinator.teardown()
        for link in links {
            let socket = scratch.appendingPathComponent(
                coordinator.socketPath(for: link.machine)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: socket.path),
                "teardown unlinked \(socket.lastPathComponent)"
            )
        }
        for (index, carrier) in carriers.enumerated() {
            let closeCount = await carrier.closeCount
            XCTAssertEqual(
                closeCount, 1,
                "carrier \(index) closed exactly once across the run"
            )
        }
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "teardown restored the pre-pin cwd"
        )
    }

    /// The reported retry failure (`liveListenerExists` on the second
    /// open): a full prepare → teardown → prepare cycle must rebind the
    /// same per-machine sockets cleanly — no orphaned listener, no stale
    /// file blocking the second bring-up.
    func testPrepareTeardownReprepareBindsCleanly() async throws {
        let (coordinator, _, links) = makeCoordinator(machineCount: 1)
        coordinator.homeDirectoryForTesting = scratch.path

        _ = try await coordinator.prepare()
        await coordinator.teardown()
        _ = try await coordinator.prepare()

        let socket = scratch.appendingPathComponent(
            coordinator.socketPath(for: links[0].machine)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socket.path),
            "the second bring-up rebound the machine socket"
        )
        await coordinator.teardown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertEqual(FileManager.default.currentDirectoryPath, cwdBefore)
    }

    /// Mode A (a lone connection, no herd) is the client's remote mode:
    /// prepare() points the client socket AT the machine's bridge — Local
    /// IS the machine, as in upstream `herdr --remote` — and seeds an
    /// EMPTY catalog so the sidebar never shows the machine duplicated
    /// next to Local.
    func testModeAAttachesBridgeAsLocalAndSeedsEmptyCatalog() async throws {
        let connection = try! Connection(
            name: "mode-a",
            type: .ssh,
            host: "127.0.0.1",
            port: 1,
            username: "fixture"
        )
        let coordinator = HerdrEmbedTransportCoordinator(
            connection: connection,
            hostKeyVerifier: nil
        )
        coordinator.homeDirectoryForTesting = scratch.path
        let carrier = CloseCountingCarrier()
        coordinator.establishForTesting = { link in
            HerdrEmbedTransportCoordinator.Established(
                link: link,
                carrier: carrier,
                executablePath: "/usr/bin/herdr"
            )
        }

        let profileID = HerdrEmbedMachine.forConnection(connection).profileID
        let localPath = try await coordinator.prepare()
        XCTAssertTrue(
            Self.matchesTokenizedPath(localPath, leaf: "\(profileID).sock"),
            "Mode A attaches the client to the machine bridge as its Local endpoint, token-namespaced: \(localPath)"
        )

        let stateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        let clientDirectory = URL(fileURLWithPath: try XCTUnwrap(stateHome))
            .appendingPathComponent("herdr/client")
        let catalog = try String(
            contentsOf: clientDirectory.appendingPathComponent("endpoints.json"),
            encoding: .utf8
        )
        XCTAssertTrue(catalog.contains("\"ssh\""))
        XCTAssertFalse(
            catalog.contains(profileID),
            "Mode A seeds no machine entries — the bridge is Local"
        )
        let selection = try String(
            contentsOf: clientDirectory.appendingPathComponent("endpoint-selection.json"),
            encoding: .utf8
        )
        XCTAssertTrue(
            selection.contains("null"),
            "Mode A writes a null selection, not an empty profile id"
        )

        await coordinator.teardown()
        let closeCount = await carrier.closeCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(FileManager.default.currentDirectoryPath, cwdBefore)
    }

    /// The production path, unseamed: no home-directory override, so
    /// prepare() pins the REAL app home and binds under its tmp/. On the
    /// simulator this is indistinguishable from any writable directory;
    /// on a DEVICE it exercises the sandboxed container exactly as the
    /// app does — the reported container-root EPERM regression cannot
    /// pass this test on device.
    func testPrepareWithRealAppHomeBindsUnderContainerTmp() async throws {
        let (coordinator, carriers, links) = makeCoordinator(machineCount: 1)

        _ = try await coordinator.prepare()

        let relativeSocket = coordinator.socketPath(for: links[0].machine)
        XCTAssertTrue(
            Self.matchesTokenizedPath(relativeSocket, leaf: "\(links[0].machine.profileID).sock"),
            "machine socket keeps the tmp/ + token layout: \(relativeSocket)"
        )
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let socket = home.appendingPathComponent(relativeSocket)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socket.path),
            "bridge socket bound under the real app home's tmp/ at \(socket.path)"
        )
        let fd = try Self.connectSocket(path: relativeSocket)
        Darwin.close(fd)

        await coordinator.teardown()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socket.path),
            "teardown unlinked the real-home socket"
        )
        let closeCount = await carriers[0].closeCount
        XCTAssertEqual(closeCount, 1, "carrier closed exactly once")
        XCTAssertEqual(FileManager.default.currentDirectoryPath, cwdBefore)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        machineCount: Int
    ) -> (
        coordinator: HerdrEmbedTransportCoordinator,
        carriers: [CloseCountingCarrier],
        links: [HerdrEmbedMachineLink]
    ) {
        var carriers: [CloseCountingCarrier] = []
        var links: [HerdrEmbedMachineLink] = []
        for index in 0..<machineCount {
            let connection = try! Connection(
                name: "bring-up-\(index)",
                type: .ssh,
                host: "127.0.0.1",
                port: 1,
                username: "fixture"
            )
            carriers.append(CloseCountingCarrier())
            links.append(HerdrEmbedMachineLink(
                machine: HerdrEmbedMachine.forConnection(connection),
                connection: connection,
                bridgeSessionName: nil
            ))
        }
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: links,
            hostKeyVerifier: nil
        )
        let carrierByProfile: [String: CloseCountingCarrier] = {
            var map: [String: CloseCountingCarrier] = [:]
            for (link, carrier) in zip(links, carriers) {
                map[link.machine.profileID] = carrier
            }
            return map
        }()
        coordinator.establishForTesting = { link in
            guard let carrier = carrierByProfile[link.machine.profileID] else {
                preconditionFailure("unknown machine: \(link.machine.profileID)")
            }
            return HerdrEmbedTransportCoordinator.Established(
                link: link,
                carrier: carrier,
                executablePath: "/usr/bin/herdr"
            )
        }
        return (coordinator, carriers, links)
    }

    private func restoreEnv(_ name: String, value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    /// Minimal POSIX connect(2) against a (relative) unix socket path —
    /// the same dial the embedded client performs.
    private static func connectSocket(path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "connectSocket", code: 1)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "connectSocket", code: 2) }
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
                domain: "connectSocket",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "connect errno \(connectErrno)"]
            )
        }
        return fd
    }
}

/// `SSHExecCapableConnection` double: counts `close()` receipts (the leak
/// signal) and refuses exec opens — no relay ever runs on this bring-up
/// path; the bind/listen/dial contract is what is under test.
private actor CloseCountingCarrier: SSHExecCapableConnection {
    private(set) var closeCount = 0

    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        throw .channelDenied
    }

    func close() async {
        closeCount += 1
    }
}
