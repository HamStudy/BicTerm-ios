import Foundation
import XCTest

@testable import BicTermCore

/// T19 preflight probe: command construction (injection resistance),
/// parser vectors, and live round-trips against the fixture sshd —
/// including the deterministic missing case (the fixture sshd's exec PATH
/// excludes every herdr location; overridden search paths point nowhere)
/// and the found+compatible case through the repo-local fake shim.
final class HerdrProbeTests: XCTestCase {
    private var transport: SSHTransport?

    override func tearDown() async throws {
        if let transport {
            await transport.close()
        }
        transport = nil
        try await super.tearDown()
    }

    private func makeFixtureTransport() async throws -> SSHTransport {
        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let transport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        try await transport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        self.transport = transport
        return transport
    }

    // MARK: - Command construction

    func testCommandEmbedsTheBoundedSearchListAndStatusQuery() throws {
        let command = try HerdrProbe.command(searchPaths: ["/opt/example/bin/herdr"])
        XCTAssertTrue(command.contains("uname -s"))
        XCTAssertTrue(command.contains("uname -m"))
        XCTAssertTrue(command.contains("command -v herdr"))
        XCTAssertTrue(command.contains("'/opt/example/bin/herdr'"))
        XCTAssertTrue(command.contains("status client --json"))
        XCTAssertTrue(command.contains("head -c \(HerdrProbe.statusQueryByteCap)"))
    }

    func testHomePrefixedSearchPathsStayExpandableOnTheRemote() throws {
        let command = try HerdrProbe.command(searchPaths: ["$HOME/.local/bin/herdr"])
        XCTAssertTrue(
            command.contains("\"$HOME/.local/bin/herdr\""),
            "$HOME must expand remotely (double-quoted), not be literalized"
        )
    }

    func testHostileSearchPathsAreRejectedBeforeAnyQuoting() {
        for hostile in [
            "$(rm -rf ~)/herdr", "`id`", "/opt/x y/herdr", "/opt/herdr';id'",
            "herdr\";curl", "/tmp/x|sh", "/opt/$ORIGIN/herdr",
        ] {
            XCTAssertThrowsError(
                try HerdrProbe.command(searchPaths: [hostile])
            ) { error in
                XCTAssertEqual(
                    error as? HerdrProbe.ProbeError, .hostileSearchPath(hostile),
                    "hostile path \(hostile) must be rejected, not quoted"
                )
            }
        }
    }

    /// F3-A guard: the production default list must sit entirely inside
    /// the validator's grammar — a default entry the CLIENT-side validator
    /// rejects (e.g. `$USER` mid-path) fails every default-path production
    /// connect before any remote exec, while every test that passes
    /// explicit paths stays green.
    func testDefaultSearchPathsAllPassTheHostilePathValidator() throws {
        let validated = try HerdrProbe.validatedSearchPaths(HerdrProbe.defaultSearchPaths)
        XCTAssertEqual(validated, HerdrProbe.defaultSearchPaths)
        XCTAssertNoThrow(try HerdrProbe.command(searchPaths: HerdrProbe.defaultSearchPaths))
    }

    // MARK: - Parser vectors

    private func compatibleStatusJSON(path: String) -> String {
        "{\"version\":\"0.9.0\",\"channel\":\"stable\",\"protocol\":22,"
            + "\"endpoint_protocol_generation\":1,"
            + "\"endpoint_capabilities\":[\"surface_interest\"],"
            + "\"binary\":\"\(path)\",\"session\":null}"
    }

    func testParseMissingHerdrYieldsIncompatibleResultWithPlatform() throws {
        let result = HerdrProbe.parse(
            host: "no-herdr.example",
            output: "bpo:os=Linux\nbpo:arch=aarch64\nbpo:path=\n"
        )
        XCTAssertEqual(result.host, "no-herdr.example")
        XCTAssertEqual(result.platformOS, "linux")
        XCTAssertEqual(result.platformArch, "aarch64")
        XCTAssertNil(result.foundPath)
        XCTAssertNil(result.version)
        XCTAssertNil(result.endpointGeneration)
        XCTAssertFalse(result.isCompatible, "no herdr found must fail closed")
    }

    func testParseFoundCompatibleHerdr() throws {
        let output = """
        bpo:os=Darwin
        bpo:arch=arm64
        bpo:path=/opt/homebrew/bin/herdr
        bpo:status=\(compatibleStatusJSON(path: "/opt/homebrew/bin/herdr"))
        """
        let result = HerdrProbe.parse(host: "mac.example", output: output)
        XCTAssertEqual(result.platformOS, "macos")
        XCTAssertEqual(result.platformArch, "aarch64")
        XCTAssertEqual(result.foundPath, "/opt/homebrew/bin/herdr")
        XCTAssertEqual(result.version, "0.9.0")
        XCTAssertEqual(result.endpointGeneration, 1)
        XCTAssertEqual(result.capabilities, ["surface_interest"])
        XCTAssertTrue(result.isCompatible)
    }

    func testParseFoundButWrongGenerationIsIncompatible() throws {
        let json = compatibleStatusJSON(path: "/usr/local/bin/herdr")
            .replacingOccurrences(of: "\"endpoint_protocol_generation\":1", with: "\"endpoint_protocol_generation\":99")
        let result = HerdrProbe.parse(
            host: "gen99.example",
            output: "bpo:os=Linux\nbpo:arch=x86_64\nbpo:path=/usr/local/bin/herdr\nbpo:status=\(json)\n"
        )
        XCTAssertEqual(result.foundPath, "/usr/local/bin/herdr")
        XCTAssertEqual(result.endpointGeneration, 99)
        XCTAssertFalse(result.isCompatible, "generation 99 must be incompatible with generation 1")
    }

    func testParseUnknownPlatformFailsClosedEvenWhenHerdrIsFound() throws {
        let result = HerdrProbe.parse(
            host: "bsd.example",
            output: "bpo:os=FreeBSD\nbpo:arch=amd64\nbpo:path=/usr/local/bin/herdr\n"
        )
        XCTAssertEqual(result.rawOS, "FreeBSD")
        XCTAssertNil(result.platformOS)
        XCTAssertFalse(result.isCompatible)
    }

    func testParseUnparseableStatusLeavesGenerationUnknownAndIncompatible() throws {
        let result = HerdrProbe.parse(
            host: "garbage.example",
            output: "bpo:os=Linux\nbpo:arch=aarch64\nbpo:path=/x/herdr\nbpo:status={not json\n"
        )
        XCTAssertEqual(result.foundPath, "/x/herdr")
        XCTAssertNil(result.endpointGeneration)
        XCTAssertFalse(result.isCompatible)
    }

    func testParseIgnoresUnmarkedAndHostileLines() throws {
        let result = HerdrProbe.parse(
            host: "noise.example",
            output: """
            some ssh banner
            bpo:os=Linux
            bpo:arch=aarch64
            MOTD: welcome to bpo:path=/should-be-ignored
            bpo:path=/real/herdr
            """
        )
        XCTAssertEqual(result.foundPath, "/real/herdr")
        XCTAssertEqual(result.platformOS, "linux")
    }

    func testParseCarriageReturnLines() throws {
        let result = HerdrProbe.parse(
            host: "crlf.example",
            output: "bpo:os=Linux\r\nbpo:arch=aarch64\r\nbpo:path=\r\n"
        )
        XCTAssertEqual(result.platformOS, "linux")
        XCTAssertEqual(result.platformArch, "aarch64")
    }

    // MARK: - Live fixture round-trips (fixture sshd on 12222)

    /// The missing case is deterministic against the fixture sshd: its exec
    /// PATH excludes every herdr location (verified: `command -v herdr`
    /// fails there), and the overridden search paths point nowhere. NOTE:
    /// this holds while the fixture host's herdr installs stay outside the
    /// sshd exec PATH — ~/.local/bin and /opt/homebrew/bin are NOT on it.
    func testLiveProbeAgainstFixtureHostWithoutHerdrInSearchPaths() async throws {
        let transport = try await makeFixtureTransport()
        let result = try await HerdrProbe.run(
            on: transport,
            host: "fixture-no-herdr",
            searchPaths: ["/nonexistent-bicterm-probe/herdr"]
        )
        XCTAssertEqual(result.platformOS, "macos", "the fixture sshd runs on the macOS host")
        XCTAssertNotNil(result.platformArch)
        XCTAssertNil(result.foundPath)
        XCTAssertNil(result.endpointGeneration)
        XCTAssertFalse(result.isCompatible)
    }

    func testLiveProbeFindsTheFakeShimAndReportsCompatible() async throws {
        let transport = try await makeFixtureTransport()
        let shim = SSHTestFixture.repoRoot
            .appendingPathComponent("Fixtures/herdr/fake-herdr-status").path
        let result = try await HerdrProbe.run(
            on: transport,
            host: "fixture-fake-herdr",
            searchPaths: [shim]
        )
        XCTAssertEqual(result.foundPath, shim)
        XCTAssertEqual(result.version, "0.9.0-fixture")
        XCTAssertEqual(result.endpointGeneration, 1)
        XCTAssertTrue(result.capabilities.contains("surface_interest"))
        XCTAssertTrue(result.isCompatible)
    }
}
