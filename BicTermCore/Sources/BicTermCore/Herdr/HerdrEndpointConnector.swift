import Foundation

/// Everything the TOFU approval surface needs to present ONE host-key
/// challenge: mirrors `SessionStore.HostTrustChallenge` (the terminal
/// sessions' trust-prompt payload) so the app reuses the same prompt
/// surface for herdr endpoints. Public key only — never secret material.
public struct HerdrHostTrustChallenge: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let algorithm: String
    public let fingerprint: String
    public let publicKeyData: Data

    public init(
        host: String,
        port: Int,
        algorithm: String,
        fingerprint: String,
        publicKeyData: Data
    ) {
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.publicKeyData = publicKeyData
    }
}

/// Everything the install-consent surface needs to present ONE
/// missing-binary install proposal (stage B): the host, the pinned
/// release target that would be installed, and the install dir the
/// binary would land in. Public facts only — never secret material.
public struct HerdrInstallConsent: Equatable, Sendable {
    public let host: String
    public let target: HerdrReleasePins.Target
    public let installDir: String

    init(host: String, target: HerdrReleasePins.Target, installDir: String) {
        self.host = host
        self.target = target
        self.installDir = installDir
    }

    /// The pinned release version that would be installed.
    public var version: String { HerdrReleasePins.version }

    /// The remote destination the binary would be committed to.
    public var destinationPath: String { installDir + "/herdr" }
}

/// Typed failure of one ``HerdrEndpointConnector/connect(_:)`` attempt. The
/// app layer maps each case onto its herdr surfaces: `sshEstablish` with
/// `.authenticationFailed`/`.authRequired` → `HerdrDiagnostic` `.authLost`,
/// every other `sshEstablish`/`probeFailed`/`bridgeChannelFailed` payload →
/// `.transportLost`; `incompatibleEndpoint` → the endpoint's probe state
/// (`HerdrSessionLifecycle.failProbe`) with `diagnosticDetail` as the
/// off-version/unknown-version wording; `trustDeclined`,
/// `installDeclined`, and `invalidSessionName` are user-facing
/// cancellations/configuration errors, not diagnostic screens.
public enum HerdrEndpointConnectorError: Error, Equatable, Sendable {
    /// SSH establish failed before any probe ran (reachability, auth,
    /// changed host key, trust-store anomaly). Carries the typed transport
    /// error, including the failing hop's identity for jump chains.
    case sshEstablish(SSHTransportError)
    /// The user declined the TOFU host-key prompt. Carries the declined
    /// challenge; nothing was trusted.
    case trustDeclined(HerdrHostTrustChallenge)
    /// The user declined the missing-binary install proposal. Carries the
    /// declined consent; nothing was installed and the carrier is closed.
    case installDeclined(HerdrInstallConsent)
    /// The probe's exec channel failed before producing a result.
    case probeFailed(HerdrProbe.ProbeError)
    /// The probe completed but the endpoint cannot serve this app. Carries
    /// the full probe result (for `HerdrSessionLifecycle.failProbe`) and
    /// the user-facing diagnostic detail string. NO bridge exec ran.
    case incompatibleEndpoint(result: HerdrProbe.Result, diagnosticDetail: String)
    /// The probe was compatible but the bridge exec channel failed to open.
    case bridgeChannelFailed(SSHTransportError)
    /// The user-approved install of the pinned herdr binary failed on the
    /// live connection. Carries the typed installer failure; the carrier
    /// is closed and bring-up aborts with a typed diagnostic (never a
    /// crash or a silent swallow).
    case installFailed(HerdrRemoteInstallerError)
    /// The connection's herdr session name failed herdr's own grammar —
    /// rejected locally, before any network I/O.
    case invalidSessionName(String)
}

/// Connects one ``Connection`` to a ready-to-speak ``HerdrSSHTransport``
/// (integration doc §6.1): SSH establish → read-only ``HerdrProbe`` → only
/// on a compatible probe, the `remote-client-bridge` exec channel.
///
/// CONNECTION-PER-CONSUMER (CoderSSHGW fix): every channel consumer —
/// probe, install, re-probe, bridge — establishes its OWN channel-less
/// connection (direct via ``SSHTransport/connectExecOnly(to:)``, jump
/// chains through the jump pipeline) and closes it when done. Gateways
/// like CoderSSHGW permit ONE session-channel open per connection
/// LIFETIME, and exec channels are session-type channels on the wire
/// (RFC 4254), so a shared connection cannot carry two consumers; the
/// old establish's unconsumed PTY session burned the one slot before the
/// probe's exec could open. Hop handling (per-hop host-key verification,
/// per-hop credentials, ≤5 hops) stays transparent to the caller.
///
/// TOFU host-key trust (doc §4): when establish surfaces the typed
/// `.requiresTrust` payload, the injected user-approval callback receives
/// the challenge (same surface as terminal sessions). Approval persists
/// through the production ``HostKeyVerifier`` and retries establish ONCE;
/// a second trust demand or a declined callback fails typed. Changed keys
/// are hard rejections, never prompted.
///
/// ORDERING INVARIANT (permanent): the probe completes BEFORE the bridge
/// exec channel opens and before any HerdrClient construction — the bridge
/// step is unreachable until the probe's `isCompatible` gate passes, and
/// this connector never constructs a HerdrClient. An incompatible probe is
/// ``HerdrEndpointConnectorError/incompatibleEndpoint(result:diagnosticDetail:)``
/// with no bridge exec (doc §11 read-only boundary).
/// Result of ``HerdrEndpointConnector/establishProbed(_:)``: the probe that
/// passed, the remote herdr executable the bridge command should exec, and
/// a factory that establishes a FRESH channel-less connection per call
/// (same trust-retry semantics as the probe's establish). The caller owns
/// each resolved connection's lifetime from the factory call on.
public struct HerdrProbedCarrier: Sendable {
    /// Establishes a FRESH channel-less exec-capable connection (direct
    /// or jump-chained) on each call, with the same trust-retry semantics
    /// as the probe's establish. Throws the connector's typed errors
    /// (`.sshEstablish`, `.trustDeclined`).
    public let carrierFactory: @Sendable () async throws(HerdrEndpointConnectorError) -> any SSHExecCapableConnection
    public let probe: HerdrProbe.Result
    /// Absolute path of the remote herdr binary the probe verified.
    public let executablePath: String

    init(
        carrierFactory: @escaping @Sendable () async throws(HerdrEndpointConnectorError) -> any SSHExecCapableConnection,
        probe: HerdrProbe.Result,
        executablePath: String
    ) {
        self.carrierFactory = carrierFactory
        self.probe = probe
        self.executablePath = executablePath
    }
}

public struct HerdrEndpointConnector: Sendable {
    public typealias HostKeyApproval = @Sendable (HerdrHostTrustChallenge) async -> Bool
    public typealias InstallApproval = @Sendable (HerdrInstallConsent) async -> Bool

    private let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    private let passwordStore: any PasswordStoring
    private let passwordPrompt: (any SSHPasswordPrompting)?
    private let hardwareKeysEnabledByDefault: @Sendable () -> Bool
    private let keyOfferResolver: KeyOfferResolver
    private let metadataProvider: any SSHKeyMetadataProviding
    private let searchPaths: [String]
    private let approveHostKey: HostKeyApproval
    /// Stage B seams: when both are injected, the install-offering
    /// variants propose the pinned install on the missing-binary probe
    /// outcome. Nil (every pre-stage-B caller) never offers — the
    /// missing-binary outcome stays ``HerdrEndpointConnectorError/incompatibleEndpoint(result:diagnosticDetail:)``.
    private let installer: HerdrRemoteInstaller?
    private let approveInstall: InstallApproval?
    private let installDir: String

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider(),
        passwordStore: any PasswordStoring = KeychainPasswordStore(),
        passwordPrompt: (any SSHPasswordPrompting)? = nil,
        hardwareKeysEnabledByDefault: @escaping @Sendable () -> Bool = { true },
        keyOfferResolver: KeyOfferResolver = KeyOfferResolver(),
        metadataProvider: any SSHKeyMetadataProviding = DefaultSSHKeyMetadataProvider(),
        searchPaths: [String] = HerdrProbe.defaultSearchPaths,
        approveHostKey: @escaping HostKeyApproval,
        installer: HerdrRemoteInstaller? = nil,
        approveInstall: InstallApproval? = nil,
        installDir: String = HerdrRemoteInstaller.defaultInstallDir
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.passwordStore = passwordStore
        self.passwordPrompt = passwordPrompt
        self.hardwareKeysEnabledByDefault = hardwareKeysEnabledByDefault
        self.keyOfferResolver = keyOfferResolver
        self.metadataProvider = metadataProvider
        self.searchPaths = searchPaths
        self.approveHostKey = approveHostKey
        self.installer = installer
        self.approveInstall = approveInstall
        self.installDir = installDir
    }

    public func connect(
        _ connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> HerdrSSHTransport {
        let probed = try await establishProbed(connection)
        return try await Self.makeBridge(probed: probed, connection: connection)
    }

    /// ``connect(_:)`` with the stage-B install proposal wired in: a probe
    /// that fails SOLELY because no herdr binary exists on an
    /// otherwise-supported host asks the injected approval once, and on
    /// approval installs the pinned binary over the installer's own fresh
    /// per-step connections and re-probes over another before the bridge
    /// opens. Without the
    /// installer/approval seams injected this is exactly
    /// ``connect(_:)``. `installProgress` is forwarded verbatim to the
    /// installer's milestone stream.
    public func connectOfferingInstall(
        _ connection: Connection,
        installProgress: HerdrInstallProgress? = nil
    ) async throws(HerdrEndpointConnectorError) -> HerdrSSHTransport {
        let probed = try await establishProbedOfferingInstall(
            connection,
            installProgress: installProgress
        )
        return try await Self.makeBridge(probed: probed, connection: connection)
    }

    private static func makeBridge(
        probed: HerdrProbedCarrier,
        connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> HerdrSSHTransport {
        // BRIDGE connection: the factory's fresh channel-less establish;
        // the bridge exec is this connection's only session channel.
        let carrier = try await probed.carrierFactory()
        do {
            return try await HerdrSSHTransport(
                transport: carrier,
                executablePath: probed.executablePath,
                sessionName: connection.herdrSessionName
            )
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? SSHTransportError {
                await carrier.close()
                throw .bridgeChannelFailed(error)
            } else {
                // HerdrCommandBuilder.BuildError — unreachable: the session
                // name passed the same grammar check at entry.
                await carrier.close()
                throw .invalidSessionName(connection.herdrSessionName ?? "")
            }
        }
    }

    /// Establish + probe WITHOUT opening the bridge channel (plan
    /// herdr-embed T5): runs the read-only probe on its OWN channel-less
    /// connection (closed before returning) and hands back the probe
    /// result plus a ``HerdrProbedCarrier/carrierFactory`` the caller
    /// resolves once per connection it wants — the embed transport opens
    /// `remote-client-bridge` exec channels on the resolved connection.
    /// Same ordering invariant as ``connect(_:)`` — the probe gate runs
    /// before any caller can open a bridge exec on a factory connection.
    public func establishProbed(
        _ connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> HerdrProbedCarrier {
        let probe = try await probeOnce(connection)
        guard probe.isCompatible, let executablePath = probe.foundPath else {
            throw .incompatibleEndpoint(
                result: probe,
                diagnosticDetail: Self.diagnosticDetail(for: probe)
            )
        }
        return HerdrProbedCarrier(
            carrierFactory: makeCarrierFactory(for: connection),
            probe: probe,
            executablePath: executablePath
        )
    }

    /// ``establishProbed(_:)`` with the stage-B install proposal wired in:
    /// a probe that fails SOLELY because no herdr binary exists on the
    /// host (foundPath nil, platform otherwise supported) asks the
    /// injected approval once, and on approval runs the injected
    /// installer over its own FRESH per-step connections (resolved from
    /// the same carrier factory the bridge uses) and re-probes over
    /// another — bring-up then continues through the normal
    /// compatibility gate.
    /// Decline aborts typed and quiet
    /// (``HerdrEndpointConnectorError/installDeclined``); an install
    /// failure aborts typed (``installFailed``). The trigger is STRICT:
    /// a present-but-incompatible herdr never proposes (no upgrade or
    /// replace flows — the existing `.incompatibleEndpoint` path), and
    /// without the installer/approval seams injected this is exactly
    /// ``establishProbed(_:)``. `installProgress` is forwarded verbatim
    /// to the installer's milestone stream.
    public func establishProbedOfferingInstall(
        _ connection: Connection,
        installProgress: HerdrInstallProgress? = nil
    ) async throws(HerdrEndpointConnectorError) -> HerdrProbedCarrier {
        let probe = try await probeOnce(connection)
        if probe.isCompatible, let executablePath = probe.foundPath {
            return HerdrProbedCarrier(
                carrierFactory: makeCarrierFactory(for: connection),
                probe: probe,
                executablePath: executablePath
            )
        }
        guard let installer, let approveInstall,
              probe.foundPath == nil,
              let platformOS = probe.platformOS,
              let platformArch = probe.platformArch,
              let target = HerdrReleasePins.target(os: platformOS, arch: platformArch)
        else {
            throw .incompatibleEndpoint(
                result: probe,
                diagnosticDetail: Self.diagnosticDetail(for: probe)
            )
        }
        let consent = HerdrInstallConsent(
            host: connection.host,
            target: target,
            installDir: installDir
        )
        guard await approveInstall(consent) else {
            throw .installDeclined(consent)
        }
        // INSTALL connections: the installer resolves the shared carrier
        // factory once per exec step (prepare/upload/commit) and closes
        // each connection itself — the connector opens no install
        // connection of its own.
        do {
            _ = try await installer.install(
                using: makeCarrierFactory(for: connection),
                probe: probe,
                installDir: installDir,
                progress: installProgress
            )
        } catch {
            // Force cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; do-block error type is exactly HerdrRemoteInstallerError.
            let error = error as! HerdrRemoteInstallerError
            throw .installFailed(error)
        }
        // RE-PROBE connection: fresh establish + probe + close.
        let reprobe = try await probeOnce(connection)
        guard reprobe.isCompatible, let executablePath = reprobe.foundPath else {
            throw .incompatibleEndpoint(
                result: reprobe,
                diagnosticDetail: Self.diagnosticDetail(for: reprobe)
            )
        }
        return HerdrProbedCarrier(
            carrierFactory: makeCarrierFactory(for: connection),
            probe: reprobe,
            executablePath: executablePath
        )
    }

    /// The ``HerdrProbedCarrier/carrierFactory`` every probed return hands
    /// back: one construction site, so every consumer's connection gets
    /// the same establish (trust-retry included).
    private func makeCarrierFactory(
        for connection: Connection
    ) -> @Sendable () async throws(HerdrEndpointConnectorError) -> any SSHExecCapableConnection {
        { try await establish(connection) }
    }

    /// One probe round-trip on its OWN channel-less connection: establish
    /// (with the shared trust-retry), run the read-only ``HerdrProbe``
    /// (its exec is the connection's only session channel), close the
    /// connection, and return the probe result. The probe-error paths
    /// close the connection exactly like the completed path — no probe
    /// result exists to key an install off.
    private func probeOnce(
        _ connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> HerdrProbe.Result {
        if let sessionName = connection.herdrSessionName,
           !HerdrCommandBuilder.isValidSessionName(sessionName) {
            throw .invalidSessionName(sessionName)
        }

        let carrier = try await establish(connection)

        do {
            let probe = try await HerdrProbe.run(
                on: carrier,
                host: connection.host,
                searchPaths: searchPaths
            )
            await carrier.close()
            return probe
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? HerdrProbe.ProbeError {
                await carrier.close()
                throw .probeFailed(error)
            } else {
                await carrier.close()
                throw .probeFailed(.execChannelFailed)
            }
        }
    }

    // MARK: - Establish

    private func establish(
        _ connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> any SSHExecCapableConnection {
        if connection.jumpChain.isEmpty {
            let transport = SSHTransport(
                hostKeyVerifier: hostKeyVerifier,
                authenticationKeyProvider: authenticationKeyProvider,
                passwordStore: passwordStore,
                passwordPrompt: passwordPrompt,
                hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
                keyOfferResolver: keyOfferResolver,
                metadataProvider: metadataProvider
            )
            do {
                try await transport.connectExecOnly(to: connection)
            } catch {
                // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
                if let error = error as? SSHTransportError {
                    try await handleTrustDemand(
                        error,
                        host: connection.host,
                        port: connection.port
                    )
                    do {
                        try await transport.connectExecOnly(to: connection)
                    } catch {
                        // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
                        if let error = error as? SSHTransportError {
                            throw .sshEstablish(error)
                        } else {
                            SSHEstablishDiagnostics.shared.record(
                                "direct establish retry failed with a non-SSH error",
                                error: error
                            )
                            throw .sshEstablish(.channelDenied)
                        }
                    }
                } else {
                    SSHEstablishDiagnostics.shared.record(
                        "direct establish failed with a non-SSH error",
                        error: error
                    )
                    throw .sshEstablish(.channelDenied)
                }
            }
            return transport
        }

        let builder = JumpChainBuilder(
            hostKeyVerifier: hostKeyVerifier,
            authenticationKeyProvider: authenticationKeyProvider,
            passwordStore: passwordStore,
            passwordPrompt: passwordPrompt,
            hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
            keyOfferResolver: keyOfferResolver,
            metadataProvider: metadataProvider
        )
        do {
            return try await builder.buildExecConnection(connection: connection)
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? JumpError {
                guard case let .hopFailed(_, host, port, underlying) = error else {
                    SSHEstablishDiagnostics.shared.record(
                        "jump chain failed with a non-hop error",
                        error: error
                    )
                    throw .sshEstablish(.channelDenied)
                }
                try await handleTrustDemand(underlying, host: host, port: port)
                do {
                    return try await builder.buildExecConnection(connection: connection)
                } catch {
                    throw .sshEstablish(Self.transportError(from: error))
                }
            } else {
                throw .sshEstablish(Self.transportError(from: error))
            }
        }
    }

    /// One trust demand → one approval round-trip → one retry (driven by
    /// the callers). Throws the typed outcome of a declined or untrustable
    /// key; returns only when establish should be retried.
    private func handleTrustDemand(
        _ error: SSHTransportError,
        host: String,
        port: Int
    ) async throws(HerdrEndpointConnectorError) {
        guard case let .requiresTrust(fingerprint, algorithm, publicKeyData) = error else {
            throw .sshEstablish(error)
        }
        // The verifier just wrote its first-seen record for exactly the
        // endpoint that failed verification: this hop's (host, port).
        let challenge = HerdrHostTrustChallenge(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint,
            publicKeyData: publicKeyData
        )
        guard await approveHostKey(challenge) else {
            throw .trustDeclined(challenge)
        }
        do {
            try await hostKeyVerifier.trust(
                host: challenge.host,
                port: challenge.port,
                key: publicKeyData,
                algorithm: algorithm
            )
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? HostKeyTrustError {
                throw .sshEstablish(Self.transportError(from: error))
            } else {
                throw .sshEstablish(.unreachable)
            }
        }
    }

    /// The typed transport error behind a builder failure: a hop's own
    /// error when attributed, a chain-shape refusal otherwise.
    private static func transportError(from error: Error) -> SSHTransportError {
        if let jumpError = error as? JumpError,
           case let .hopFailed(_, _, _, underlying) = jumpError {
            return underlying
        }
        if let error = error as? SSHTransportError {
            return error
        }
        SSHEstablishDiagnostics.shared.record(
            "jump establish failed with an unattributed error",
            error: error
        )
        return .channelDenied
    }

    private static func transportError(from error: HostKeyTrustError) -> SSHTransportError {
        switch error {
        case let .rejected(.hostKeyChanged(host, port, oldFingerprint, newFingerprint)):
            .hostKeyChanged(
                host: host,
                port: port,
                oldFingerprint: oldFingerprint,
                newFingerprint: newFingerprint
            )
        case .persistence:
            .unreachable
        }
    }

    // MARK: - Probe diagnostic wording

    /// User-facing detail for an incompatible probe result, mirroring the
    /// `HerdrDiagnostic.incompatibleGeneration` vocabulary: the
    /// missing/unknown-version/off-version/unsupported-platform cases, each
    /// stating the app's requirement (herdr 0.9+, endpoint protocol
    /// generation 1) and never auto-remediating (doc §11).
    public static func diagnosticDetail(for result: HerdrProbe.Result) -> String {
        let requiredGeneration = HerdrProbe.Result.requiredGeneration
        guard let path = result.foundPath else {
            return "No herdr executable was found on \(result.host). "
                + "Install herdr 0.9 or newer on the host, or allow the pinned 0.9.1 install "
                + "when BicTerm offers it during connect."
        }
        if result.platformOS == nil || result.platformArch == nil {
            let platform = [result.rawOS, result.rawArch]
                .compactMap { $0 }
                .joined(separator: " ")
            let platformSuffix = platform.isEmpty ? "" : " (\(platform))"
            return "herdr was found at \(path) but the remote platform\(platformSuffix) "
                + "is not supported by this app's herdr core."
        }
        guard let version = result.version, let generation = result.endpointGeneration else {
            return "herdr was found at \(path) but did not report its version. "
                + "This app requires herdr 0.9 or newer (endpoint protocol generation \(requiredGeneration))."
        }
        return "herdr \(version) at \(path) speaks endpoint protocol generation \(generation); "
            + "this app requires generation \(requiredGeneration). "
            + "Upgrade herdr on the host to 0.9 or newer."
    }

    /// User-facing detail for a failed install attempt (stage B): one
    /// sentence per typed installer failure, public facts only. The app
    /// layer surfaces this through the same failConnect diagnostic path
    /// as ``HerdrEndpointConnectorError/probeFailed(_:)``.
    public static func installDiagnosticDetail(for error: HerdrRemoteInstallerError) -> String {
        switch error {
        case let .unsupportedPlatform(os, arch):
            "the host platform \(os ?? "unknown") \(arch ?? "unknown") has no pinned herdr release"
        case let .herdrAlreadyPresent(path):
            "an existing herdr was found at \(path); this app never replaces or upgrades it"
        case let .invalidInstallDir(dir):
            "refused an unsafe herdr install directory: \(dir)"
        case let .downloadFailed(detail):
            "downloading the pinned herdr release failed: \(detail)"
        case let .checksumMismatch(target, expected, _):
            "the downloaded herdr \(target.rawValue) did not match its sha256 pin \(expected)"
        case let .remotePrepareFailed(detail):
            "preparing the remote install directory failed: \(detail)"
        case let .uploadFailed(detail):
            "uploading the herdr binary to the host failed: \(detail)"
        case let .commitFailed(detail):
            "committing the herdr install on the host failed: \(detail)"
        }
    }
}
