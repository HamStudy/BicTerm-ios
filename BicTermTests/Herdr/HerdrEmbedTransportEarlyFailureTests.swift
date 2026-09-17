import BicTermCore
import XCTest

@testable import BicTerm

/// P1 regression (final-review blocker): carriers established by
/// `establishAll()` leaked when `prepare()` failed BEFORE bridge startup —
/// at `pinCWD()` or at the transport-directory mkdir. Neither `servers` nor
/// `carriers` is populated at that point, so the runtime's
/// `teardownTransport` cannot recover them; `prepare()` itself must close
/// them through `unwindBringUp(established:started:)` and leave the cwd
/// ownership correct (a failed pin never moved it; a failed mkdir
/// releases the pin the bring-up just took).
///
/// Deterministic by construction — no SSH, no fixtures: the establish seam
/// injects carriers with observable `close()` receipts, and the
/// home-directory seam points the pin + mkdir at a controlled directory
/// (nonexistent → pin failure; transport-directory name occupied by a
/// regular file → mkdir failure).
@MainActor
final class HerdrEmbedTransportEarlyFailureTests: XCTestCase {
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
        // Repo-local scratch on the simulator host (containment rule); on
        // a physical device the build-machine path does not exist, so the
        // scratch falls back to the app container's own tmp.
        let scratchBase: URL
        if FileManager.default.fileExists(atPath: Self.repoRoot.path) {
            scratchBase = Self.repoRoot
                .appendingPathComponent("Fixtures/run/herdr-early-failure-tests", isDirectory: true)
        } else {
            scratchBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("herdr-early-failure-tests", isDirectory: true)
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

    func testPinFailureClosesEstablishedCarrierAndLeavesCWDUnchanged() async throws {
        let (coordinator, carriers) = makeCoordinator(machineCount: 1)
        // A home that does not exist: chdir fails, so the pin fails typed
        // before any bind.
        coordinator.homeDirectoryForTesting =
            scratch.appendingPathComponent("missing-home").path

        await assertEarlyFailure(
            coordinator: coordinator,
            carriers: carriers,
            expectedPath: HerdrEmbedClientCatalog.transportDirectoryRelativePath,
            reasonContains: "pinning the transport cwd failed"
        )
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "a failed pin never moved the cwd"
        )
    }

    func testTransportDirectoryCreationFailureClosesEveryEstablishedCarrierAndRestoresCWD() async throws {
        // Two machines: the unwind must close EVERY established carrier,
        // not just the first.
        let (coordinator, carriers) = makeCoordinator(machineCount: 2)
        // The transport directory lives under the container's tmp/ (the
        // data-container ROOT is not writable on device — EPERM). The
        // tmp/herdr-embed-transport path occupied by a regular FILE: the
        // mkdir fails typed instead of falling through to the binds.
        // createFile does not create intermediates, so tmp/ comes first.
        let blocker = scratch.appendingPathComponent("tmp/herdr-embed-transport")
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(atPath: blocker.path, contents: nil),
            "test precondition: the transport-directory blocker file exists"
        )
        coordinator.homeDirectoryForTesting = scratch.path

        await assertEarlyFailure(
            coordinator: coordinator,
            carriers: carriers,
            expectedPath: blocker.path,
            reasonContains: "creating the transport directory failed"
        )
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath, cwdBefore,
            "the pinned cwd was restored by the unwind"
        )
    }

    // MARK: - Helpers

    private func makeCoordinator(
        machineCount: Int
    ) -> (coordinator: HerdrEmbedTransportCoordinator, carriers: [CloseCountingCarrier]) {
        var carriers: [CloseCountingCarrier] = []
        var links: [HerdrEmbedMachineLink] = []
        for index in 0..<machineCount {
            let connection = try! Connection(
                name: "early-failure-\(index)",
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
        return (coordinator, carriers)
    }

    private func assertEarlyFailure(
        coordinator: HerdrEmbedTransportCoordinator,
        carriers: [CloseCountingCarrier],
        expectedPath: String,
        reasonContains needle: String,
        line: UInt = #line
    ) async {
        do {
            _ = try await coordinator.prepare()
            XCTFail("prepare() must fail on the early-failure path", line: line)
        } catch let failure as HerdrEmbedTransportFailure {
            guard case let .bridge(.bindFailed(path, reason)) = failure else {
                XCTFail("expected typed .bridge(.bindFailed), got \(failure)", line: line)
                return
            }
            XCTAssertEqual(path, expectedPath, line: line)
            XCTAssertTrue(
                reason.contains(needle),
                "reason carried the underlying failure: \(reason)",
                line: line
            )
        } catch {
            XCTFail("expected HerdrEmbedTransportFailure, got \(error)", line: line)
        }
        for (index, carrier) in carriers.enumerated() {
            let closeCount = await carrier.closeCount
            XCTAssertEqual(
                closeCount, 1,
                "established carrier \(index) closed exactly once by the unwind",
                line: line
            )
        }
    }
}

/// `SSHExecCapableConnection` double: counts `close()` receipts — the
/// leak signal. No exec channel is ever opened on the early-failure paths.
private actor CloseCountingCarrier: SSHExecCapableConnection {
    private(set) var closeCount = 0

    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        throw .channelDenied
    }

    func close() async {
        closeCount += 1
    }
}
