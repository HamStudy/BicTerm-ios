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
            carrier: StubExecCarrier(),
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
}

/// Never reaches a relay: start() fails before the listener accepts.
private struct StubExecCarrier: SSHExecCapableConnection {
    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        throw .channelDenied
    }

    func close() async {}
}
