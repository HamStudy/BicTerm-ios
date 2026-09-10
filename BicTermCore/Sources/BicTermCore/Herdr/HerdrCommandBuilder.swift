import Foundation

/// Constructs the fixed remote command that starts herdr's
/// `remote-client-bridge` over a non-PTY SSH exec channel (integration doc
/// §5, mirroring herdr v0.9.0 `remote_bridge_command`):
///
/// ```
/// exec '<path>' [--session '<name>'] remote-client-bridge
/// ```
///
/// Both variable parts are treated as hostile input:
/// - The session NAME is validated against herdr's own accepted grammar
///   (`session::validate_name`: 1–64 ASCII bytes from `[A-Za-z0-9._-]`,
///   excluding `.`/`..`) BEFORE any quoting, with one deliberate
///   hardening: the first byte must be alphanumeric, so a name can never
///   begin with a dash and misbind as herdr's own flag.
/// - The executable PATH comes from a trusted probe but is passed through
///   the one centralized POSIX single-quoting routine anyway, so spaces,
///   quotes, `$()`, backticks and newlines are inert. A NUL byte is the
///   single byte POSIX quoting cannot neutralize and is rejected.
public enum HerdrCommandBuilder {
    public enum BuildError: Error, Equatable {
        /// Session name failed the herdr grammar (or the first-byte rule).
        case invalidSessionName
        /// Path contains a byte that cannot be quoted safely (NUL).
        case unquotablePath
    }

    /// herdr's own session-name byte cap (`MAX_SESSION_NAME_LEN`).
    private static let maxSessionNameBytes = 64

    /// `exec`-prefix + quoted path (+ `--session` + quoted name) + fixed
    /// subcommand. The `--session` flag is omitted for `nil` and for
    /// herdr's default session name — upstream `remote_session_command`
    /// only appends it for non-default names.
    public static func bridgeCommand(
        executablePath: String,
        sessionName: String?
    ) throws(BuildError) -> String {
        guard !executablePath.contains("\0") else { throw .unquotablePath }
        var command = "exec " + posixSingleQuoted(executablePath)
        if let sessionName, sessionName != "default" {
            guard isValidSessionName(sessionName) else { throw .invalidSessionName }
            command += " --session " + posixSingleQuoted(sessionName)
        }
        command += " remote-client-bridge"
        return command
    }

    /// The ONE POSIX-shell single-quoting routine (herdr's `shell_quote`
    /// escape shape): wrap in `'…'`, turning each embedded `'` into `'\''`.
    /// Safe for every byte except NUL: inside single quotes the shell
    /// performs no expansion, substitution, splitting or globbing.
    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Grammar mirror of herdr v0.9.0 `session::validate_name`, plus the
    /// leading-dash hardening described in the type overview.
    public static func isValidSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxSessionNameBytes else { return false }
        guard let first = name.utf8.first, first.isASCIIAlphanumericByte else { return false }
        return name.utf8.allSatisfy { byte in
            byte.isASCIIAlphanumericByte || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
}

private extension UInt8 {
    var isASCIIAlphanumericByte: Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(self)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(self)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self)
    }
}
