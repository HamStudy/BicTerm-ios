import Foundation
import XCTest
@testable import BicTermCore

/// T15 command-construction injection resistance. The fixed wrapper is
/// `exec '<path>' [--session '<name>'] remote-client-bridge` (herdr v0.9.0
/// `remote_bridge_command` shape); session names are validated against
/// herdr's OWN grammar (`session::validate_name`) BEFORE any quoting, and
/// the executable path is always passed through the one POSIX
/// single-quoting routine.
final class HerdrCommandBuilderTests: XCTestCase {
    // MARK: - Wrapper shape

    func testBuildsCanonicalWrapperWithoutSession() throws {
        let command = try HerdrCommandBuilder.bridgeCommand(
            executablePath: "/usr/local/bin/herdr",
            sessionName: nil
        )
        XCTAssertEqual(command, "exec '/usr/local/bin/herdr' remote-client-bridge")
    }

    func testBuildsCanonicalWrapperWithExplicitSession() throws {
        let command = try HerdrCommandBuilder.bridgeCommand(
            executablePath: "/usr/local/bin/herdr",
            sessionName: "work"
        )
        XCTAssertEqual(
            command,
            "exec '/usr/local/bin/herdr' --session 'work' remote-client-bridge"
        )
    }

    /// Upstream parity: herdr omits `--session` for the default session
    /// (`remote_session_command` only appends the flag when the name differs
    /// from `DEFAULT_SESSION_NAME`).
    func testDefaultSessionNameOmitsSessionFlag() throws {
        let command = try HerdrCommandBuilder.bridgeCommand(
            executablePath: "/usr/local/bin/herdr",
            sessionName: "default"
        )
        XCTAssertEqual(command, "exec '/usr/local/bin/herdr' remote-client-bridge")
    }

    // MARK: - Session-name grammar (herdr session::validate_name mirror)

    func testAcceptsSessionNamesWithinHerdrGrammar() throws {
        for name in ["work", "a", "dev-2", "main_session", "Proj.2026", String(repeating: "n", count: 64)] {
            let command = try HerdrCommandBuilder.bridgeCommand(
                executablePath: "/usr/local/bin/herdr",
                sessionName: name
            )
            XCTAssertEqual(
                command,
                "exec '/usr/local/bin/herdr' --session '\(name)' remote-client-bridge",
                "grammar-valid name '\(name)' must be accepted and single-quoted"
            )
        }
    }

    /// Table-driven injection vectors for the session NAME: each row must be
    /// REJECTED by the grammar check (before quoting is ever attempted).
    func testRejectsHostileSessionNames() {
        let vectors: [String] = [
            "",                                    // empty
            " ",                                   // space
            "two words",                           // interior space
            "it's",                                // single quote (quote-escape vector)
            "name\"quoted",                        // double quote
            "line\nbreak",                         // newline
            "tab\there",                           // tab
            "-rf",                                 // leading dash (flag-misbinding vector)
            "--session",                           // leading double dash
            "$(reboot)",                           // command substitution
            "`reboot`",                            // backtick substitution
            "a;b",                                 // statement separator
            "a|b",                                 // pipe
            "a>b",                                 // redirect
            "héllo",                               // non-ASCII (grammar is ASCII-only)
            "日本語",                                // UTF-8 multibyte
            String(repeating: "n", count: 65),     // over herdr's 64-byte cap
            ".",                                   // traversal
            "..",                                  // traversal
            "../escape",                           // traversal prefix
            "/abs/path",                           // path separator
            "name\\with\\backslash",               // backslash
            "name;rm -rf /",                       // compound injection
        ]
        for vector in vectors {
            XCTAssertThrowsError(
                try HerdrCommandBuilder.bridgeCommand(
                    executablePath: "/usr/local/bin/herdr",
                    sessionName: vector
                ),
                "session name \(vector.debugDescription) must be rejected before quoting"
            ) { error in
                guard case HerdrCommandBuilder.BuildError.invalidSessionName = error else {
                    XCTFail("expected invalidSessionName for \(vector.debugDescription), got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Executable-path quoting (trusted probe output, quoted anyway)

    /// The path is NOT grammar-checked (a probed path may legitimately
    /// contain spaces or quotes); it must round-trip the ONE centralized
    /// POSIX single-quoting routine instead.
    func testSafelyQuotesHostileExecutablePaths() throws {
        let vectors: [(input: String, expected: String)] = [
            // Plain path needs only wrapping.
            ("/usr/bin/herdr", "'/usr/bin/herdr'"),
            // Spaces stay inside one argument.
            ("/opt/herdr bin/herdr", "'/opt/herdr bin/herdr'"),
            // Upstream's own test vector: embedded single quote.
            ("/opt/herdr's/bin/herdr", "'/opt/herdr'\\''s/bin/herdr'"),
            // Substitution vectors are inert inside single quotes.
            ("/opt/$(reboot)/herdr", "'/opt/$(reboot)/herdr'"),
            ("/opt/`reboot`/herdr", "'/opt/`reboot`/herdr'"),
            // Newlines are inert inside single quotes.
            ("/opt/her\ndr", "'/opt/her\ndr'"),
            // Double quotes are inert.
            ("/opt/her\"dr", "'/opt/her\"dr'"),
            // UTF-8 path bytes are preserved verbatim.
            ("/opt/hérdr/bin", "'/opt/hérdr/bin'"),
            // Leading dash cannot become a flag: quoted word starts with '.
            ("-/bin/herdr", "'-/bin/herdr'"),
            // Semicolon/pipe/redirect stay literal.
            ("/opt/a;rm -rf /", "'/opt/a;rm -rf /'"),
            ("/opt/a|b", "'/opt/a|b'"),
            ("/opt/a>b", "'/opt/a>b'"),
            // Empty path degenerates to the empty single-quoted word.
            ("", "''"),
        ]
        for vector in vectors {
            let command = try HerdrCommandBuilder.bridgeCommand(
                executablePath: vector.input,
                sessionName: nil
            )
            XCTAssertEqual(
                command,
                "exec \(vector.expected) remote-client-bridge",
                "path \(vector.input.debugDescription) must quote to \(vector.expected.debugDescription)"
            )
        }
    }

    /// A NUL byte can never survive into a shell command string — it is the
    /// one byte POSIX quoting cannot neutralize (execve arguments are
    /// NUL-terminated C strings).
    func testRejectsNulByteInPath() {
        XCTAssertThrowsError(
            try HerdrCommandBuilder.bridgeCommand(
                executablePath: "/opt/he\0rdr",
                sessionName: nil
            )
        ) { error in
            guard case HerdrCommandBuilder.BuildError.unquotablePath = error else {
                XCTFail("expected unquotablePath, got \(error)")
                return
            }
        }
    }

    /// The quoting routine must be idempotent-safe: quoting is applied exactly
    /// once at the single construction site (this test pins the routine's
    /// output for the canonical escape, preventing double-escape drift).
    func testPosixSingleQuoteRoutineEscapesEmbeddedQuotesExactlyOnce() {
        XCTAssertEqual(
            HerdrCommandBuilder.posixSingleQuoted("a'b"),
            "'a'\\''b'"
        )
        XCTAssertEqual(
            HerdrCommandBuilder.posixSingleQuoted("'"),
            "''\\'''"
        )
        XCTAssertEqual(
            HerdrCommandBuilder.posixSingleQuoted(""),
            "''"
        )
    }
}
