import Foundation
import XCTest
@testable import BicTermCore

/// Ownership semantics of the shared cwd pin
/// (``HerdrEmbedTransportWorkspace``): the process cwd is global and
/// bring-ups overlap (a stale stop unwinding while the next coordinator
/// has already pinned), so a SUPERSEDED owner's release must not un-pin
/// the cwd under a live bring-up — the defect behind the embedded
/// bridge's `bindFailed(... ENOENT ...)` startup failure on relative
/// socket paths. Hermetic: scratch directories under `Fixtures/run`, cwd
/// restored by the pin itself.
final class HerdrEmbedTransportWorkspaceTests: XCTestCase {
    private var scratch: URL!
    private var originalCWD: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalCWD = FileManager.default.currentDirectoryPath
        let directory = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/run/herdr-cwd-pin-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        scratch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        addTeardownBlock { [scratch] in
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    override func tearDown() {
        // Belt and braces: the pin's own release restores the cwd, but a
        // failed assertion must not leak the chdir into other tests.
        chdir(originalCWD)
        super.tearDown()
    }

    func testSupersededReleaseDoesNotUnpinLiveBringUpCWD() throws {
        let first = CoordinatorToken()
        let second = CoordinatorToken()

        try HerdrEmbedTransportWorkspace.pinCWD(homeDirectory: scratch.path, owner: first)
        // The newer bring-up re-pins the same home and takes ownership.
        try HerdrEmbedTransportWorkspace.pinCWD(homeDirectory: scratch.path, owner: second)
        // The first coordinator's teardown (e.g. a stale stop that
        // grabbed it after the takeover) releases its pin.
        HerdrEmbedTransportWorkspace.releaseCWD(owner: first)

        XCTAssertEqual(
            FileManager.default.currentDirectoryPath,
            scratch.path,
            "a superseded owner's release must leave the live bring-up's pin"
        )

        HerdrEmbedTransportWorkspace.releaseCWD(owner: second)
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath,
            originalCWD,
            "the final owner's release restores the pre-pin cwd"
        )
    }

    func testReleaseWithoutPinIsANoOp() throws {
        let neverPinned = CoordinatorToken()
        HerdrEmbedTransportWorkspace.releaseCWD(owner: neverPinned)
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath,
            originalCWD,
            "releasing a pin that was never taken must not move the cwd"
        )
    }

    func testPinFailureIsTypedAndLeavesCWDUnchanged() throws {
        let token = CoordinatorToken()
        let nonexistent = scratch.appendingPathComponent("missing-home").path
        XCTAssertThrowsError(
            try HerdrEmbedTransportWorkspace.pinCWD(
                homeDirectory: nonexistent, owner: token
            )
        ) { error in
            guard case let .pinFailed(target, errno) = error as? HerdrEmbedTransportWorkspace.PinFailure else {
                return XCTFail("expected pinFailed, got \(error)")
            }
            XCTAssertEqual(target, nonexistent)
            XCTAssertEqual(errno, ENOENT)
        }
        XCTAssertEqual(
            FileManager.default.currentDirectoryPath,
            originalCWD,
            "a failed pin must not move the cwd"
        )
    }
}

/// Stand-in for the coordinator identity the pin is keyed on.
private final class CoordinatorToken {}
