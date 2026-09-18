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

/// Typed failure of one ``HerdrEndpointConnector/connect(_:)`` attempt. The
/// app layer maps each case onto its herdr surfaces: `sshEstablish` with
/// `.authenticationFailed`/`.authRequired` → `HerdrDiagnostic` `.authLost`,
/// every other `sshEstablish`/`probeFailed`/`bridgeChannelFailed` payload →
/// `.transportLost`; `incompatibleEndpoint` → the endpoint's probe state
/// (`HerdrSessionLifecycle.failProbe`) with `diagnosticDetail` as the
/// off-version/unknown-version wording; `trustDeclined` and
/// `invalidSessionName` are user-facing cancellations/configuration errors,
/// not diagnostic screens.
public enum HerdrEndpointConnectorError: Error, Equatable, Sendable {
    /// SSH establish failed before any probe ran (reachability, auth,
    /// changed host key, trust-store anomaly). Carries the typed transport
    /// error, including the failing hop's identity for jump chains.
    case sshEstablish(SSHTransportError)
    /// The user declined the TOFU host-key prompt. Carries the declined
    /// challenge; nothing was trusted.
    case trustDeclined(HerdrHostTrustChallenge)
    /// The probe's exec channel failed before producing a result.
    case probeFailed(HerdrProbe.ProbeError)
    /// The probe completed but the endpoint cannot serve this app. Carries
    /// the full probe result (for `HerdrSessionLifecycle.failProbe`) and
    /// the user-facing diagnostic detail string. NO bridge exec ran.
    case incompatibleEndpoint(result: HerdrProbe.Result, diagnosticDetail: String)
    /// The probe was compatible but the bridge exec channel failed to open.
    case bridgeChannelFailed(SSHTransportError)
    /// The connection's herdr session name failed herdr's own grammar —
    /// rejected locally, before any network I/O.
    case invalidSessionName(String)
}

/// Connects one ``Connection`` to a ready-to-speak ``HerdrSSHTransport``
/// (integration doc §6.1): SSH establish → read-only ``HerdrProbe`` → only
/// on a compatible probe, the `remote-client-bridge` exec channel.
///
/// Establish reuses the SessionStore/HerdrProbe pattern — direct
/// connections dial through ``SSHTransport``, jump-chained connections
/// through the jump pipeline — so hop handling (per-hop host-key
/// verification, per-hop credentials, ≤5 hops) stays transparent to the
/// caller: the probe and bridge exec channels ride the ONE established
/// connection (§3.5 shared-connection shape).
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
/// Result of ``HerdrEndpointConnector/establishProbed(_:)``: an ESTABLISHED
/// SSH carrier whose probe passed, with the remote herdr executable the
/// bridge command should exec. The carrier is NOT yet bound to any exec
/// channel — the embed transport (plan herdr-embed T5) keeps it alive and
/// opens one fresh `remote-client-bridge` exec channel per local bridge
/// connection on it.
public struct HerdrProbedCarrier: Sendable {
    /// Established exec-capable connection (direct or jump-chained). The
    /// caller owns its lifetime from here on.
    public let carrier: any SSHExecCapableConnection
    public let probe: HerdrProbe.Result
    /// Absolute path of the remote herdr binary the probe verified.
    public let executablePath: String

    init(
        carrier: any SSHExecCapableConnection,
        probe: HerdrProbe.Result,
        executablePath: String
    ) {
        self.carrier = carrier
        self.probe = probe
        self.executablePath = executablePath
    }
}

public struct HerdrEndpointConnector: Sendable {
    public typealias HostKeyApproval = @Sendable (HerdrHostTrustChallenge) async -> Bool

    /// Nominal PTY dimensions for the direct establish's session channel
    /// (the established pattern; herdr never uses that shell — its probe
    /// and bridge ride their own exec channels).
    private static let establishCols = 80
    private static let establishRows = 24

    private let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    private let passwordStore: any PasswordStoring
    private let hardwareKeysEnabledByDefault: @Sendable () -> Bool
    private let keyOfferResolver: KeyOfferResolver
    private let metadataProvider: any SSHKeyMetadataProviding
    private let searchPaths: [String]
    private let approveHostKey: HostKeyApproval

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider(),
        passwordStore: any PasswordStoring = KeychainPasswordStore(),
        hardwareKeysEnabledByDefault: @escaping @Sendable () -> Bool = { true },
        keyOfferResolver: KeyOfferResolver = KeyOfferResolver(),
        metadataProvider: any SSHKeyMetadataProviding = DefaultSSHKeyMetadataProvider(),
        searchPaths: [String] = HerdrProbe.defaultSearchPaths,
        approveHostKey: @escaping HostKeyApproval
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.passwordStore = passwordStore
        self.hardwareKeysEnabledByDefault = hardwareKeysEnabledByDefault
        self.keyOfferResolver = keyOfferResolver
        self.metadataProvider = metadataProvider
        self.searchPaths = searchPaths
        self.approveHostKey = approveHostKey
    }

    public func connect(
        _ connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> HerdrSSHTransport {
        let probed = try await establishProbed(connection)
        do {
            return try await HerdrSSHTransport(
                transport: probed.carrier,
                executablePath: probed.executablePath,
                sessionName: connection.herdrSessionName
            )
        } catch let error as SSHTransportError {
            await probed.carrier.close()
            throw .bridgeChannelFailed(error)
        } catch {
            // HerdrCommandBuilder.BuildError — unreachable: the session
            // name passed the same grammar check at entry.
            await probed.carrier.close()
            throw .invalidSessionName(connection.herdrSessionName ?? "")
        }
    }

    /// Establish + probe WITHOUT opening the bridge channel (plan
    /// herdr-embed T5): hands back the live carrier so the embed transport
    /// can open `remote-client-bridge` exec channels on demand, one per
    /// local bridge connection, while keeping ONE established connection
    /// for the whole embed session (§3.5 shared-connection shape). Same
    /// ordering invariant as ``connect(_:)`` — the probe gate runs before
    /// any caller can open a bridge exec on the returned carrier.
    public func establishProbed(
        _ connection: Connection
    ) async throws(HerdrEndpointConnectorError) -> HerdrProbedCarrier {
        if let sessionName = connection.herdrSessionName,
           !HerdrCommandBuilder.isValidSessionName(sessionName) {
            throw .invalidSessionName(sessionName)
        }

        let carrier = try await establish(connection)

        let probe: HerdrProbe.Result
        do {
            probe = try await HerdrProbe.run(
                on: carrier,
                host: connection.host,
                searchPaths: searchPaths
            )
        } catch let error as HerdrProbe.ProbeError {
            await carrier.close()
            throw .probeFailed(error)
        } catch {
            await carrier.close()
            throw .probeFailed(.execChannelFailed)
        }
        guard probe.isCompatible, let executablePath = probe.foundPath else {
            await carrier.close()
            throw .incompatibleEndpoint(
                result: probe,
                diagnosticDetail: Self.diagnosticDetail(for: probe)
            )
        }
        return HerdrProbedCarrier(carrier: carrier, probe: probe, executablePath: executablePath)
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
                hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
                keyOfferResolver: keyOfferResolver,
                metadataProvider: metadataProvider
            )
            do {
                try await transport.connect(
                    to: connection,
                    cols: Self.establishCols,
                    rows: Self.establishRows
                )
            } catch let error as SSHTransportError {
                try await handleTrustDemand(
                    error,
                    host: connection.host,
                    port: connection.port
                )
                do {
                    try await transport.connect(
                        to: connection,
                        cols: Self.establishCols,
                        rows: Self.establishRows
                    )
                } catch let error as SSHTransportError {
                    throw .sshEstablish(error)
                } catch {
                    SSHEstablishDiagnostics.shared.record(
                        "direct establish retry failed with a non-SSH error",
                        error: error
                    )
                    throw .sshEstablish(.channelDenied)
                }
            } catch {
                SSHEstablishDiagnostics.shared.record(
                    "direct establish failed with a non-SSH error",
                    error: error
                )
                throw .sshEstablish(.channelDenied)
            }
            return transport
        }

        let builder = JumpChainBuilder(
            hostKeyVerifier: hostKeyVerifier,
            authenticationKeyProvider: authenticationKeyProvider,
            passwordStore: passwordStore,
            hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
            keyOfferResolver: keyOfferResolver,
            metadataProvider: metadataProvider
        )
        do {
            return try await builder.buildExecConnection(connection: connection)
        } catch let error as JumpError {
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
        } catch {
            throw .sshEstablish(Self.transportError(from: error))
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
        } catch let error as HostKeyTrustError {
            throw .sshEstablish(Self.transportError(from: error))
        } catch {
            throw .sshEstablish(.unreachable)
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
                + "Install herdr 0.9 or newer on the host; this app never installs or updates it."
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
}
