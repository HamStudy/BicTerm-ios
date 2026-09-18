import Foundation

/// Preflight probe over a short-lived non-PTY exec channel (integration doc
/// §6.1/§11): detects the remote OS/arch, searches a documented bounded set
/// of paths for an existing `herdr` executable, and queries the installed
/// binary's client status for its version, endpoint protocol generation, and
/// capabilities.
///
/// Boundary (doc §11, permanent): the probe is read-only. It never installs,
/// updates, replaces, or elevates anything on the remote. An incompatible
/// herdr stays a diagnostic screen plus a documentation link; a missing
/// binary has exactly one remediation path, outside this file: the separate,
/// consent-gated ``HerdrRemoteInstaller`` the connector's install-offering
/// variants run after an explicit per-attempt user approval — never the
/// probe itself.
public enum HerdrProbe {
    /// Structured outcome of one probe run. Everything except `host` is
    /// optional: each field is whatever the remote actually reported, so an
    /// unparseable or hostile answer degrades to `nil` and the result reads
    /// as incompatible (fail-closed) rather than guessing.
    public struct Result: Sendable, Equatable {
        public let host: String
        /// Raw `uname -s` / `uname -m` values, kept for the diagnostic screen.
        public let rawOS: String?
        public let rawArch: String?
        /// Normalized platform (`linux`/`macos`, `x86_64`/`aarch64`); nil when
        /// upstream's supported-platform table does not recognize the pair.
        public let platformOS: String?
        public let platformArch: String?
        public let foundPath: String?
        public let version: String?
        public let endpointGeneration: UInt32?
        public let capabilities: [String]

        public init(
            host: String,
            rawOS: String?,
            rawArch: String?,
            foundPath: String?,
            version: String?,
            endpointGeneration: UInt32?,
            capabilities: [String]
        ) {
            self.host = host
            self.rawOS = rawOS
            self.rawArch = rawArch
            self.foundPath = foundPath
            self.version = version
            self.endpointGeneration = endpointGeneration
            self.capabilities = capabilities
            let pair = HerdrProbe.normalize(rawOS: rawOS, rawArch: rawArch)
            (platformOS, platformArch) = (pair?.os, pair?.arch)
        }

        /// The endpoint generation this app's protocol core implements —
        /// mirrors `ENDPOINT_PROTOCOL_GENERATION` in the vendored
        /// herdr-protocol crate (generation 1); the Rust handshake is the
        /// authoritative enforcer, this is display/probe-side data.
        public static let requiredGeneration: UInt32 = 1

        public var isCompatible: Bool {
            platformOS != nil
                && platformArch != nil
                && foundPath != nil
                && endpointGeneration == Self.requiredGeneration
        }
    }

    public enum ProbeError: Error, Equatable {
        case hostileSearchPath(String)
        case execChannelFailed
    }

    /// Bounded candidate list mirroring upstream's
    /// `known_remote_binary_candidate_script` (remote/attach.rs), minus the
    /// version-parameterized mise install paths (those resolve through
    /// `command -v herdr`'s PATH lookup, which runs first) and minus the
    /// NixOS per-user profile path `/etc/profiles/per-user/$USER/bin/herdr`
    /// — ``validatedSearchPaths`` only expands `$HOME`/`USER` as a PREFIX,
    /// and a default the client-side validator rejects would fail every
    /// default-path connect before any remote exec. A herdr in that
    /// profile is still found through the PATH lookup above.
    public static let defaultSearchPaths: [String] = [
        "$HOME/.local/bin/herdr",
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        "/home/linuxbrew/.linuxbrew/bin/herdr",
        "$HOME/.nix-profile/bin/herdr",
        "/nix/var/nix/profiles/default/bin/herdr",
        "/run/current-system/sw/bin/herdr",
    ]

    /// Prefix marking every machine-readable probe line; distinct from any
    /// herdr or uname output.
    static let marker = "bpo:"

    static let statusQueryByteCap = 4096

    /// Builds the probe shell command. The ONLY variable parts are the
    /// search paths, and ``validatedSearchPaths(_:)`` confines them to a
    /// grammar with no shell metacharacters — quoting decisions in the
    /// emitted script rely on that guarantee (doc §5 injection resistance).
    public static func command(searchPaths: [String] = defaultSearchPaths) throws(ProbeError) -> String {
        let paths = try validatedSearchPaths(searchPaths)
        let candidates = paths.map { path in
            path.contains("$")
                ? "\"\(path)\""
                : HerdrCommandBuilder.posixSingleQuoted(path)
        }.joined(separator: " ")
        return """
        printf '\(marker)os=%s\\n' "$(uname -s)"
        printf '\(marker)arch=%s\\n' "$(uname -m)"
        p=''
        c=$(command -v herdr 2>/dev/null) || c=''
        if [ -n "$c" ] && [ -x "$c" ]; then p="$c"; fi
        if [ -z "$p" ]; then
          for cand in \(candidates); do
            if [ -x "$cand" ]; then p="$cand"; break; fi
          done
        fi
        printf '\(marker)path=%s\\n' "$p"
        if [ -n "$p" ]; then
          "$p" status client --json 2>/dev/null | head -c \(statusQueryByteCap) | sed -e 's/^/\(marker)status=/'
        fi
        """
    }

    /// Search paths must be pure filesystem references (optionally prefixed
    /// with the exact `$HOME`/`$USER` markers, expanded remotely): no
    /// quotes, spaces, globs, or command-substitution bytes can survive.
    static func validatedSearchPaths(_ paths: [String]) throws(ProbeError) -> [String] {
        var validated: [String] = []
        for path in paths {
            let remainder: Substring
            if path.hasPrefix("$HOME") || path.hasPrefix("$USER") {
                remainder = path.dropFirst(5)
            } else {
                remainder = path[...]
                if remainder.contains("$") { throw ProbeError.hostileSearchPath(path) }
            }
            guard remainder.allSatisfy({ $0.isSafeProbePathByte }) else {
                throw ProbeError.hostileSearchPath(path)
            }
            validated.append(path)
        }
        return validated
    }

    /// Parses bounded probe output into a structured result. Unknown,
    /// duplicated, or malformed lines are ignored; a `status` payload that
    /// does not decode as the client-status JSON leaves version/generation
    /// nil (fail-closed compatibility).
    public static func parse(host: String, output: String) -> Result {
        let maxLines = 64
        var rawOS: String?
        var rawArch: String?
        var foundPath: String?
        var statusJSON: String?

        // `split(whereSeparator: \.isNewline)`: a CRLF is ONE grapheme
        // cluster in Swift, so splitting on the "\n" Character alone never
        // separates CRLF-terminated lines.
        var lines = output.split(whereSeparator: \.isNewline).makeIterator()
        var scanned = 0
        while scanned < maxLines, let line = lines.next() {
            scanned += 1
            let text = line.isCarriageReturnTerminated ? String(line.dropLast()) : String(line)
            guard text.hasPrefix(marker) else { continue }
            let body = String(text.dropFirst(marker.count))
            if body.hasPrefix("os=") {
                rawOS = rawOS ?? nonEmpty(body.dropFirst(3))
            } else if body.hasPrefix("arch=") {
                rawArch = rawArch ?? nonEmpty(body.dropFirst(5))
            } else if body.hasPrefix("path=") {
                foundPath = foundPath ?? nonEmpty(body.dropFirst(5))
            } else if body.hasPrefix("status=") {
                statusJSON = (statusJSON ?? "") + String(body.dropFirst(7))
            }
        }

        var version: String?
        var generation: UInt32?
        var capabilities: [String] = []
        if let statusJSON,
           let data = statusJSON.data(using: .utf8),
           let status = try? JSONDecoder().decode(ClientStatus.self, from: data) {
            version = status.version
            generation = status.endpointProtocolGeneration
            capabilities = status.endpointCapabilities
        }
        return Result(
            host: host,
            rawOS: rawOS,
            rawArch: rawArch,
            foundPath: foundPath,
            version: version,
            endpointGeneration: generation,
            capabilities: capabilities
        )
    }

    /// Runs the probe on one ESTABLISHED exec-capable connection (direct or
    /// jump-chained): opens a short-lived non-PTY exec channel, reads its
    /// bounded stdout, drains stderr (an exec channel whose stderr nobody
    /// reads eventually stalls — see ``SSHExecSession``), and closes the
    /// channel. The probe command is non-interactive and bounded
    /// server-side (fixed candidate list, one status query capped by
    /// ``statusQueryByteCap``), so the channel ends on its own like every
    /// other fixture exec round-trip.
    public static func run(
        on transport: any SSHExecCapableConnection,
        host: String,
        searchPaths: [String] = defaultSearchPaths
    ) async throws(ProbeError) -> Result {
        let probeCommand = try command(searchPaths: searchPaths)
        let session: SSHExecSession
        do {
            session = try await transport.openExecChannel(command: probeCommand)
        } catch {
            // The typed contract carries no payload; capture the real
            // reason for the device diagnostic before the collapse.
            SSHEstablishDiagnostics.shared.record("herdr probe exec channel open", error: error)
            throw .execChannelFailed
        }
        async let stdout = readBounded(session.stdout, cap: 16 * 1024)
        async let stderr = readBounded(session.stderr, cap: 1024)
        let output = await stdout
        _ = await stderr
        _ = await session.termination()
        await session.close()
        return parse(host: host, output: String(decoding: output, as: UTF8.self))
    }

    private static func readBounded(
        _ stream: SSHExecByteStream, cap: Int
    ) async -> Data {
        var data = Data()
        for await chunk in stream {
            data.append(chunk)
            if data.count >= cap { break }
        }
        return data
    }

    static func normalize(rawOS: String?, rawArch: String?) -> (os: String, arch: String)? {
        let os: String
        switch rawOS?.trimmingCharacters(in: .whitespaces) {
        case "Linux": os = "linux"
        case "Darwin": os = "macos"
        default: return nil
        }
        let arch: String
        switch rawArch?.trimmingCharacters(in: .whitespaces) {
        case "x86_64", "amd64": arch = "x86_64"
        case "aarch64", "arm64": arch = "aarch64"
        default: return nil
        }
        return (os, arch)
    }

    private static func nonEmpty(_ value: Substring) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Wire shape of `herdr status client --json` (upstream cli/status.rs
/// `ClientStatusJson`); unknown fields are ignored.
private struct ClientStatus: Decodable {
    let version: String
    let endpointProtocolGeneration: UInt32
    let endpointCapabilities: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case endpointProtocolGeneration = "endpoint_protocol_generation"
        case endpointCapabilities = "endpoint_capabilities"
    }
}

private extension Character {
    /// Probe search-path grammar: path separators, POSIX portable filename
    /// characters, and the dash — nothing any POSIX shell reinterprets.
    var isSafeProbePathByte: Bool {
        self == "/" || self == "-" || self == "." || self == "_"
            || isLetter || isNumber
    }
}

private extension Substring {
    var isCarriageReturnTerminated: Bool {
        last == "\r"
    }
}
