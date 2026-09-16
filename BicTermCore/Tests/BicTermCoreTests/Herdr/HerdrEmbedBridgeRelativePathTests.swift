import Foundation
import XCTest
@testable import BicTermCore

/// Regression tests for the embedded bridge's RELATIVE socket paths (the
/// `herdr-embed-transport/<profile>.sock` shape the app pins the process
/// cwd for): a bring-up whose cwd is NOT pinned must fail with the REAL
/// filesystem reason for the socket directory, never the downstream
/// `bind(2)` ENOENT that hides it (the reported
/// `bindFailed(... "No such file or directory" ... errno: 2)` startup
/// failure). Hermetic — no fixtures, a stub carrier, no live relays.
final class HerdrEmbedBridgeRelativePathTests: XCTestCase {
    private static let profile = "relparentfail0000000000000000"
    private static let socketPath = "herdr-embed-transport/\(profile).sock"

    func testUncreatableRelativeParentSurfacesDirectoryFailureNotBindENOENT() async throws {
        // The observed failure state: the cwd is NOT the pinned app home,
        // so the relative transport directory cannot be created ("/" is
        // read-only on iOS). The bridge must say THAT, not a bind ENOENT.
        let original = FileManager.default.currentDirectoryPath
        defer { chdir(original) }
        XCTAssertEqual(chdir("/"), 0, "the test process must be able to chdir to /")

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
