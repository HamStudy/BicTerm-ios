import BicTermCore
import Foundation
import Observation

/// Mode A connect flow (herdr-support plan todo 6): opens one herdr
/// workspace for one herdr-enabled connection — ``HerdrEndpointConnector``
/// establishes SSH, runs the read-only probe, and opens the bridge; only a
/// ready transport reaches ``HerdrWorkspaceCenter``. An in-flight guard
/// keyed by connection id makes repeated taps yield exactly one attempt and
/// one workspace entry.
///
/// TOFU host-key challenges surface through the SAME approval view terminal
/// sessions use (``HostTrustPromptView``), bridged from the connector's
/// approval callback via a continuation; trust persists through the shared
/// production verifier, so terminal sessions and herdr endpoints agree on
/// one trust store.
@MainActor
@Observable
final class HerdrConnectCoordinator {
    struct TrustPrompt: Identifiable {
        let challenge: HerdrHostTrustChallenge
        let continuation: CheckedContinuation<Bool, Never>
        var id: String { "\(challenge.host):\(challenge.port)-\(challenge.fingerprint)" }
    }

    /// Awaiting TOFU decision; presented as a ``HostTrustPromptView`` sheet.
    var trustPrompt: TrustPrompt?

    /// Connect-time configuration error that never reaches a diagnostic
    /// screen (invalid remote session name).
    var connectError: String?

    private var inFlight: Set<UUID> = []

    #if DEBUG
    /// UI-test surface (idempotency assertion): herdr connect attempts
    /// started through this coordinator.
    private(set) var debugAttemptCount = 0
    #endif

    func handleConnect(
        _ connection: Connection,
        hostKeyVerifier: HostKeyVerifier?,
        present: @escaping (UUID) -> Void
    ) {
        guard !inFlight.contains(connection.id) else { return }
        inFlight.insert(connection.id)
        #if DEBUG
        debugAttemptCount += 1
        #endif

        let endpointID = HerdrEndpointID(rawValue: "connection/\(connection.id.uuidString)")
        let connector = makeConnector(hostKeyVerifier: hostKeyVerifier)

        Task { @MainActor in
            defer { inFlight.remove(connection.id) }
            do {
                let transport = try await connector.connect(connection)
                let sessionID = HerdrWorkspaceCenter.shared.open { model in
                    model.connect(endpoint: endpointID, transport: transport)
                    return connection.name
                }
                #if DEBUG
                if let entry = HerdrWorkspaceCenter.shared.entry(id: sessionID) {
                    HerdrWorkspaceUITest.startLiveInjectionWhenReady(
                        model: entry.model,
                        endpoint: endpointID
                    )
                }
                #endif
                present(sessionID)
            } catch let error as HerdrEndpointConnectorError {
                presentFailure(
                    error,
                    endpointID: endpointID,
                    connectionName: connection.name,
                    present: present
                )
            } catch {
                // connect(_:) is fully typed; an untyped throw here is a
                // programming error — surface it as a typed transport loss.
                presentFailure(
                    .sshEstablish(.channelDenied),
                    endpointID: endpointID,
                    connectionName: connection.name,
                    present: present
                )
            }
        }
    }

    /// Resolves the presented trust prompt: Trust persists through the
    /// connector's own approval path; Cancel fails the attempt typed.
    func resolveTrustPrompt(_ approved: Bool) {
        guard let prompt = trustPrompt else { return }
        trustPrompt = nil
        prompt.continuation.resume(returning: approved)
    }

    // MARK: - Failure mapping (error-enum contract, T4)

    private func presentFailure(
        _ error: HerdrEndpointConnectorError,
        endpointID: HerdrEndpointID,
        connectionName: String,
        present: @escaping (UUID) -> Void
    ) {
        switch error {
        case .trustDeclined:
            // User cancellation: no workspace, no diagnostic.
            return
        case let .invalidSessionName(name):
            connectError =
                "The Remote Session name “\(name)” isn’t valid for herdr. "
                + "Use letters, numbers, dots, underscores, and hyphens, starting with a letter or number."
            return
        case let .incompatibleEndpoint(result, _):
            let sessionID = HerdrWorkspaceCenter.shared.open { model in
                model.failProbe(endpoint: endpointID, result: result)
                return connectionName
            }
            present(sessionID)
        case let .probeFailed(cause):
            failConnect(
                endpointID: endpointID,
                connectionName: connectionName,
                diagnostic: .simple(.transportLost, detail: Self.probeDetail(of: cause)),
                present: present
            )
        case let .sshEstablish(cause), let .bridgeChannelFailed(cause):
            failConnect(
                endpointID: endpointID,
                connectionName: connectionName,
                diagnostic: Self.diagnostic(for: cause),
                present: present
            )
        }
    }

    private func failConnect(
        endpointID: HerdrEndpointID,
        connectionName: String,
        diagnostic: HerdrDiagnostic,
        present: @escaping (UUID) -> Void
    ) {
        let sessionID = HerdrWorkspaceCenter.shared.open { model in
            model.failConnect(endpoint: endpointID, diagnostic: diagnostic)
            return connectionName
        }
        present(sessionID)
    }

    /// Presents the TOFU prompt and suspends the connector's approval
    /// callback until the user decides. Cancel (or a lost decision) never
    /// trusts.
    private func approve(_ challenge: HerdrHostTrustChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            trustPrompt = TrustPrompt(challenge: challenge, continuation: continuation)
        }
    }

    /// `sshEstablish`/`bridgeChannelFailed` → `HerdrDiagnostic` kinds, exactly
    /// as documented on ``HerdrEndpointConnectorError``: auth failures are
    /// `.authLost` (re-auth is a user action, never retried); everything else
    /// is `.transportLost`.
    private static func diagnostic(for cause: SSHTransportError) -> HerdrDiagnostic {
        switch cause {
        case .authenticationFailed, .authRequired:
            .simple(.authLost, detail: cause.localizedDescription)
        default:
            .simple(.transportLost, detail: cause.localizedDescription)
        }
    }

    private static func probeDetail(of cause: HerdrProbe.ProbeError) -> String {
        switch cause {
        case .execChannelFailed:
            "the herdr probe channel could not open on the host"
        case let .hostileSearchPath(path):
            "refused an unsafe herdr search path: \(path)"
        }
    }

    // MARK: - Connector construction

    private func makeConnector(hostKeyVerifier: HostKeyVerifier?) -> HerdrEndpointConnector {
        var verifier = hostKeyVerifier
            ?? HostKeyVerifier(store: SessionStore.defaultHostKeyStoreForLiveUse())
        #if DEBUG
        if HerdrWorkspaceUITest.untrustedStoreRequested {
            verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        }
        #endif
        return HerdrEndpointConnector(
            hostKeyVerifier: verifier,
            searchPaths: searchPaths(),
            approveHostKey: { [weak self] challenge in
                await self?.approve(challenge) ?? false
            }
        )
    }

    private func searchPaths() -> [String] {
        #if DEBUG
        if let override = HerdrWorkspaceUITest.probeSearchPathsForLiveConnect {
            return override
        }
        #endif
        return HerdrProbe.defaultSearchPaths
    }
}
