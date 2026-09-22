import Foundation

/// Typed failure of one ``HerdrRemoteInstaller/install(using:probe:installDir:progress:)``
/// attempt. Diagnostic payloads carry public facts only (platform names,
/// remote paths, exit statuses) — never secret material.
public enum HerdrRemoteInstallerError: Error, Equatable, Sendable {
    /// The probe's platform is not in the pinned release table. Carries the
    /// best platform identity the probe reported (normalized, else raw).
    case unsupportedPlatform(os: String?, arch: String?)
    /// The probe found an existing herdr on the host. Replacement and
    /// upgrade are out of scope by design (the probe's read-only boundary,
    /// doc §11): an incompatible-but-present binary stays a diagnostic.
    case herdrAlreadyPresent(path: String)
    /// The install dir failed the client-side path grammar (the same
    /// injection-resistant grammar the probe enforces on search paths).
    case invalidInstallDir(String)
    /// The pinned binary could not be fetched (network, HTTP status, or an
    /// unusable pinned URL).
    case downloadFailed(String)
    /// The binary's SHA-256 does not match the committed pin; the upload
    /// was refused before any remote exec ran.
    case checksumMismatch(target: HerdrReleasePins.Target, expected: String, actual: String)
    /// The remote prepare step failed (non-zero exit, channel failure, or
    /// no parseable tmp/dest paths).
    case remotePrepareFailed(String)
    /// The upload step (stdin → `tee`) failed.
    case uploadFailed(String)
    /// The remote commit step (chmod + mv) failed.
    case commitFailed(String)
}

/// Short human-readable install milestone lines (fetch/verify/prepare/
/// upload/commit), delivered in order. Purely informational.
public typealias HerdrInstallProgress = @Sendable (String) -> Void

/// Establishes one FRESH exec-capable connection per call. Deliberately a
/// generic (untyped) throwing closure rather than one typed over
/// ``HerdrRemoteInstallerError``: the caller's establish failures are
/// not installer-domain failures, so the installer maps them onto the
/// failing step's typed case instead of forcing the caller into this error
/// domain. The installer wraps the factory in a ``SharedExecCarrierPool``
/// as its dial: the exec steps share ONE connection by default, and the
/// factory is re-resolved per connection only when a channel-budget
/// gateway's denial flips the pool to dedicated fallbacks.
public typealias HerdrInstallConnectionFactory = @Sendable () async throws -> any SSHExecCapableConnection

/// Result of one successful remote install.
public struct HerdrRemoteInstallOutcome: Sendable, Equatable {
    /// Remote-reported absolute destination path of the committed binary
    /// (the prepare step's `dest`, after the commit `mv`).
    public let destinationPath: String
    /// The pinned release target that was installed.
    public let target: HerdrReleasePins.Target

    init(destinationPath: String, target: HerdrReleasePins.Target) {
        self.destinationPath = destinationPath
        self.target = target
    }
}

/// Installs the pinned herdr release binary on a remote host, mirroring
/// upstream herdr's own desktop install mechanism (remote/attach.rs
/// `install_herdr`) exactly:
///
/// 1. **prepare** — a `/bin/sh -s` script (upstream's `sh_output` posture:
///    script on the channel's stdin) that resolves `dest` under the install
///    dir, `mkdir -p`s its parent, picks a `$$`-suffixed tmp path, and
///    prints `tmp\0dest\0` on stdout;
/// 2. **upload** — the binary streamed over a fresh exec channel's stdin
///    into `tee '<tmp>'` (upstream's `remote_install_stream_command`; SSH
///    EOF terminates `tee`);
/// 3. **commit** — a `/bin/sh -s` script that `chmod 755`s the tmp file
///    and `mv`s it into place (upstream's
///    `remote_install_commit_script`).
///
/// SHARED-FIRST CARRIERS: the installer wraps the injected
/// ``HerdrInstallConnectionFactory`` in a ``SharedExecCarrierPool`` for
/// the whole install — the three exec steps ride ONE lazily-dialed
/// shared connection by default (one key evaluation per connect
/// intent), and a channel-budget gateway's denial of the shared
/// carrier's channel open flips the pool sticky-dedicated so every later
/// step dials its OWN connection (the Coder-era per-step shape,
/// recovered exactly where the budget gateway requires it). Install
/// success is preserved on both paths; the pool is closed at every exit
/// of ``install(using:probe:installDir:progress:)``.
///
/// Scope (stage A): the MISSING-binary case only — the caller passes a
/// ``HerdrProbe.Result`` whose `foundPath` is nil; a probe that found any
/// existing herdr is refused with
/// ``HerdrRemoteInstallerError/herdrAlreadyPresent(path:)`` (the probe
/// never replaces; an incompatible-but-present binary stays a diagnostic).
/// The default install dir is ``HerdrProbe``'s first candidate search path,
/// so a re-probe finds the installed binary immediately.
///
/// The binary comes from the injected ``HerdrBinaryProvider`` and is
/// verified against the committed pin BEFORE any remote exec runs — a
/// checksum mismatch refuses the upload outright. The remote side only
/// ever runs this app-controlled prepare/tee/chmod/mv sequence: no sudo,
/// no package managers, no `curl | sh` shape.
public struct HerdrRemoteInstaller: Sendable {
    /// Default install dir — upstream's `RemoteHerdr::for_platform`
    /// install suffix and install.sh's `HERDR_INSTALL_DIR` default. This
    /// is ``HerdrProbe``'s first candidate search path, so a re-probe
    /// finds the installed binary immediately.
    public static let defaultInstallDir = "$HOME/.local/bin"

    /// Upload chunk size: keeps each channel write bounded while the
    /// session's flow-control gate paces the SSH window between chunks.
    private static let uploadChunkBytes = 256 * 1024

    /// Bounded exec-channel read caps (probe pattern): prepare prints two
    /// short paths; scripts and `tee` are silent on stderr in the happy
    /// path.
    private static let prepareStdoutCap = 4096
    private static let stderrCap = 1024

    private let binaryProvider: any HerdrBinaryProvider

    public init(binaryProvider: any HerdrBinaryProvider) {
        self.binaryProvider = binaryProvider
    }

    /// Installs the pinned herdr release binary on the remote host, keyed
    /// off `probe`'s normalized platform. The three exec steps (prepare,
    /// upload, commit) lease the installer's internal
    /// ``SharedExecCarrierPool`` — they share ONE connection by default,
    /// and a budget-gateway denial flips the pool to per-step dedicated
    /// connections. The pool is closed on every success and failure path
    /// of this method, no connection leaks.
    ///
    /// - Parameters:
    ///   - factory: establishes a FRESH exec-capable connection (direct or
    ///     jump-chained) per call — the pool's dial. Resolved lazily for
    ///     the shared carrier and once per dedicated fallback; the pool
    ///     owns and closes each resolved connection. A thrown error maps
    ///     onto the failing step's typed case.
    ///   - probe: the preflight probe result for the same host. Must be a
    ///     missing-binary result (`foundPath == nil`).
    ///   - installDir: directory the `herdr` binary is installed into
    ///     (the destination is `<installDir>/herdr`). Defaults to
    ///     ``defaultInstallDir``; an explicit override mirrors upstream
    ///     install.sh's `HERDR_INSTALL_DIR`. Must pass the probe's
    ///     path grammar — `$HOME`/`$USER` prefixes expand remotely.
    ///   - progress: optional sink for short milestone lines.
    /// - Returns: the remote-reported destination path and the pinned
    ///   target that was installed.
    public func install(
        using factory: @escaping HerdrInstallConnectionFactory,
        probe: HerdrProbe.Result,
        installDir: String = HerdrRemoteInstaller.defaultInstallDir,
        progress: HerdrInstallProgress? = nil
    ) async throws(HerdrRemoteInstallerError) -> HerdrRemoteInstallOutcome {
        if let existing = probe.foundPath {
            throw .herdrAlreadyPresent(path: existing)
        }
        guard let target = HerdrReleasePins.target(
            os: probe.platformOS ?? "",
            arch: probe.platformArch ?? ""
        ) else {
            throw .unsupportedPlatform(
                os: probe.platformOS ?? probe.rawOS,
                arch: probe.platformArch ?? probe.rawArch
            )
        }
        let asset = HerdrReleasePins.asset(for: target)
        // Fail fast on a hostile install dir — before any fetch or exec.
        _ = try Self.validatedInstallDir(installDir)

        progress?("fetching herdr \(HerdrReleasePins.version) for \(target.rawValue)")
        let binary = try await binaryProvider.binary(for: target)

        progress?("verifying sha256 against the release pin")
        let actualSHA = HerdrReleasePins.sha256Hex(binary)
        guard actualSHA == asset.sha256 else {
            throw .checksumMismatch(target: target, expected: asset.sha256, actual: actualSHA)
        }

        // The install's exec-connection source: shared-first, dedicated
        // on a budget-gateway denial. Closed at every exit below.
        let pool = SharedExecCarrierPool(dial: factory)
        do {
            let outcome = try await runInstallSteps(
                pool: pool,
                target: target,
                binary: binary,
                installDir: installDir,
                progress: progress
            )
            await pool.close()
            return outcome
        } catch {
            await pool.close()
            // Force cast: swift-frontend 6.4 SILGen assertion on catch-as
            // in typed-throws funcs; do-block error type is exactly
            // HerdrRemoteInstallerError.
            throw error as! HerdrRemoteInstallerError
        }
    }

    /// The prepare/upload/commit sequence over the install's pool. The
    /// pool's close-at-every-exit lives in
    /// ``install(using:probe:installDir:progress:)``.
    private func runInstallSteps(
        pool: SharedExecCarrierPool,
        target: HerdrReleasePins.Target,
        binary: Data,
        installDir: String,
        progress: HerdrInstallProgress?
    ) async throws(HerdrRemoteInstallerError) -> HerdrRemoteInstallOutcome {
        progress?("preparing the remote install directory")
        let prepare = try await Self.runScript(
            Self.prepareScript(installDir: installDir),
            pool: pool,
            failure: { .remotePrepareFailed($0) }
        )
        guard case .exited(status: 0) = prepare.termination else {
            throw .remotePrepareFailed(
                Self.failureDetail(
                    "remote install preparation failed",
                    stderr: prepare.stderr,
                    termination: prepare.termination
                )
            )
        }
        guard let paths = Self.parseInstallPaths(prepare.stdout) else {
            throw .remotePrepareFailed("remote install preparation did not return destination paths")
        }

        progress?("uploading the binary (\(binary.count) bytes)")
        try await Self.uploadBinary(binary, toTmpPath: paths.tmpPath, pool: pool)

        progress?("committing the install")
        let commit = try await Self.runScript(
            Self.commitScript(tmpPath: paths.tmpPath, destPath: paths.destPath),
            pool: pool,
            failure: { .commitFailed($0) }
        )
        guard case .exited(status: 0) = commit.termination else {
            throw .commitFailed(
                Self.failureDetail(
                    "remote install commit failed",
                    stderr: commit.stderr,
                    termination: commit.termination
                )
            )
        }

        progress?("installed herdr \(HerdrReleasePins.version) at \(paths.destPath)")
        return HerdrRemoteInstallOutcome(destinationPath: paths.destPath, target: target)
    }

    // MARK: - Script construction (upstream mirrors)

    /// Mirror of upstream `remote_install_prepare_script` (attach.rs): the
    /// ONLY variable part is the install dir, embedded in a double-quoted
    /// `dest=` exactly the way upstream embeds its install suffix — a
    /// `$HOME` prefix expands remotely, a literal path stays literal (the
    /// client-side grammar guarantees no other shell metacharacters).
    static func prepareScript(installDir: String) throws(HerdrRemoteInstallerError) -> String {
        let dir = try validatedInstallDir(installDir)
        // + "\n": a multiline literal drops the break before its closing
        // delimiter; upstream's script ends with a newline.
        return """
        set -eu
        dest="\(dir)/herdr"
        dir="${dest%/*}"
        mkdir -p "$dir"
        tmp="${dest}.tmp.$$"
        printf '%s\\0%s\\0' "$tmp" "$dest"
        """ + "\n"
    }

    /// Mirror of upstream `remote_install_commit_script` (attach.rs):
    /// `chmod 755` + `mv`, both paths POSIX-single-quoted.
    static func commitScript(tmpPath: String, destPath: String) -> String {
        let tmp = HerdrCommandBuilder.posixSingleQuoted(tmpPath)
        let dest = HerdrCommandBuilder.posixSingleQuoted(destPath)
        return "set -eu\nchmod 755 \(tmp)\nmv \(tmp) \(dest)\n"
    }

    /// Mirror of upstream `remote_install_stream_command` (attach.rs): the
    /// upload target — `tee` with the tmp path POSIX-single-quoted, never
    /// a `sh -c` wrapper.
    static func streamCommand(tmpPath: String) -> String {
        "tee " + HerdrCommandBuilder.posixSingleQuoted(tmpPath)
    }

    /// Mirror of upstream `parse_remote_install_paths` (attach.rs): the
    /// prepare step's stdout is `<tmp>\0<dest>\0`; both parts must be
    /// non-empty valid UTF-8. Embedded newlines are path bytes, not
    /// separators.
    static func parseInstallPaths(_ stdout: Data) -> (tmpPath: String, destPath: String)? {
        let parts = stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let tmpPath = String(data: Data(parts[0]), encoding: .utf8),
              let destPath = String(data: Data(parts[1]), encoding: .utf8),
              !tmpPath.isEmpty, !destPath.isEmpty
        else { return nil }
        return (tmpPath, destPath)
    }

    /// The install dir joins the prepare script, so it must pass the same
    /// client-side grammar the probe enforces on its search paths (doc §5
    /// injection resistance): a pure filesystem reference, optionally
    /// prefixed with the exact `$HOME`/`$USER` markers that expand remotely.
    static func validatedInstallDir(_ installDir: String) throws(HerdrRemoteInstallerError) -> String {
        guard !installDir.isEmpty,
              (try? HerdrProbe.validatedSearchPaths([installDir])) != nil
        else { throw .invalidInstallDir(installDir) }
        return installDir
    }

    // MARK: - Exec-channel steps

    private struct ScriptOutcome: Sendable {
        let stdout: Data
        let stderr: Data
        let termination: SSHExecTermination
    }

    /// Runs one `/bin/sh -s` script over a fresh exec channel on a LEASE
    /// of the install's ``SharedExecCarrierPool`` — upstream's `sh_output`
    /// posture: the script arrives on the channel's stdin, SSH EOF closes
    /// it, stdout/stderr are read bounded, and the exit status comes from
    /// ``SSHExecSession/termination()``. The lease is closed when the
    /// step ends (release-only in the pool's shared era; owner-close of the
    /// lease's dedicated carrier after a budget-gateway fallback), on
    /// every success and failure path. Lease and channel-open and stdin
    /// failures map onto the caller's typed case through `failure`.
    private static func runScript(
        _ script: String,
        pool: SharedExecCarrierPool,
        failure: @Sendable (String) -> HerdrRemoteInstallerError
    ) async throws(HerdrRemoteInstallerError) -> ScriptOutcome {
        let connection: any SSHExecCapableConnection
        do {
            connection = try await pool.lease()
        } catch {
            throw failure("failed to establish the install connection: \(error)")
        }
        let session: SSHExecSession
        do {
            session = try await connection.openExecChannel(command: "/bin/sh -s")
        } catch {
            await connection.close()
            throw failure("failed to open the script exec channel")
        }
        do {
            async let stderr = readBounded(session.stderr, cap: stderrCap)
            do {
                try await session.write(Data(script.utf8))
                try await session.closeWrite()
            } catch {
                throw failure("failed to feed the script to the remote shell")
            }
            let stdout = await readBounded(session.stdout, cap: prepareStdoutCap)
            let termination = await session.termination()
            let stderrData = await stderr
            await session.close()
            await connection.close()
            return ScriptOutcome(stdout: stdout, stderr: stderrData, termination: termination)
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let mapped = error as? HerdrRemoteInstallerError {
                await session.close()
                await connection.close()
                throw mapped
            } else {
                await session.close()
                await connection.close()
                throw failure("unexpected non-typed error: \(error)")
            }
        }
    }

    /// Streams `binary` into `tee '<tmp>'` over a fresh exec channel on a
    /// LEASE of the install's ``SharedExecCarrierPool`` — upstream's
    /// upload step: chunked writes paced by the session's flow-control
    /// gate, SSH EOF to terminate `tee`, stderr drained concurrently (an
    /// exec channel whose stderr nobody reads eventually stalls — see
    /// ``SSHExecSession``). The lease is closed when the step ends
    /// (release-only in the pool's shared era; owner-close of the lease's
    /// dedicated carrier after a budget-gateway fallback), on every
    /// success and failure path.
    private static func uploadBinary(
        _ binary: Data,
        toTmpPath tmpPath: String,
        pool: SharedExecCarrierPool
    ) async throws(HerdrRemoteInstallerError) -> Void {
        let connection: any SSHExecCapableConnection
        do {
            connection = try await pool.lease()
        } catch {
            throw .uploadFailed("failed to establish the install connection: \(error)")
        }
        let session: SSHExecSession
        do {
            session = try await connection.openExecChannel(command: streamCommand(tmpPath: tmpPath))
        } catch {
            await connection.close()
            throw .uploadFailed("failed to open the upload exec channel")
        }
        do {
            async let stderr = readBounded(session.stderr, cap: stderrCap)
            do {
                var offset = 0
                while offset < binary.count {
                    let end = min(offset + uploadChunkBytes, binary.count)
                    try await session.write(binary.subdata(in: offset..<end))
                    offset = end
                }
                try await session.closeWrite()
            } catch {
                throw HerdrRemoteInstallerError.uploadFailed("failed to stream the binary to the remote tee")
            }
            let termination = await session.termination()
            let stderrData = await stderr
            await session.close()
            await connection.close()
            guard case .exited(status: 0) = termination else {
                throw HerdrRemoteInstallerError.uploadFailed(
                    Self.failureDetail(
                        "remote install exited unsuccessfully",
                        stderr: stderrData,
                        termination: termination
                    )
                )
            }
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let mapped = error as? HerdrRemoteInstallerError {
                await session.close()
                await connection.close()
                throw mapped
            } else {
                await session.close()
                await connection.close()
                throw HerdrRemoteInstallerError.uploadFailed("unexpected non-typed error: \(error)")
            }
        }
    }

    /// Mirror of upstream `command_failed` (attach.rs): the trimmed stderr
    /// line when the remote said anything, otherwise the exit status.
    private static func failureDetail(
        _ context: String,
        stderr: Data,
        termination: SSHExecTermination
    ) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch termination {
        case .exited(let status):
            return text.isEmpty ? "\(context): exit status \(status)" : "\(context): \(text)"
        case .failed:
            return "\(context): the channel failed without an exit status"
        case .closedLocally:
            return "\(context): the channel was closed locally before the remote exited"
        }
    }

    private static func readBounded(_ stream: SSHExecByteStream, cap: Int) async -> Data {
        var data = Data()
        for await chunk in stream {
            data.append(chunk)
            if data.count >= cap { break }
        }
        return data
    }
}
