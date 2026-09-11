import BicTermCore
import Foundation

/// Deterministic herdr endpoint identity for one SSH connection (doc §3.5:
/// stable profile identity, not a label). The forget action and any future
/// production connect path MUST derive this together so cached per-host
/// metadata clears for exactly the host being forgotten.
enum HerdrHostIdentity {
    static func endpointRawValue(connection: Connection) -> String {
        "ssh://\(connection.username)@\(connection.host):\(connection.port)"
    }

    static func endpoint(connection: Connection) -> HerdrEndpointID {
        HerdrEndpointID(rawValue: endpointRawValue(connection: connection))
    }
}

/// Per-host "forget" action (integration doc §15 security sweep; mirrors the
/// Coder server delete flow's confirm-then-clear shape). Clears every local
/// remnant of one host while KEEPING the connection entry itself:
///
/// - the TOFU known-host record for the destination and each jump hop
///   (next connect re-prompts on the fingerprint),
/// - stored password credential references not shared with another
///   connection (SSH keys are the user's own material and are never touched),
/// - restorable terminal/herdr session snapshots for that host,
/// - the herdr per-endpoint clipboard opt-in.
///
/// Nothing here touches remote state: the host's processes and sessions
/// survive; only this device forgets it trusted/remembered the host.
@MainActor
final class HerdrHostForgetService {
    struct Dependencies {
        var hostKeyStore: any HostKeyStoreProtocol
        var passwordStore: any PasswordStoring
        var connectionStore: any ConnectionStoreProtocol
        var clipboardSettings: HerdrClipboardSettings
        var deleteRestorableSessions: (_ host: String, _ port: Int) async -> Int

        @MainActor
        static func live(
            hostKeyStore: (any HostKeyStoreProtocol)? = nil,
            passwordStore: (any PasswordStoring)? = nil,
            connectionStore: (any ConnectionStoreProtocol)? = nil,
            clipboardDefaults: UserDefaults = .standard,
            sessionStore: SessionStore
        ) -> Dependencies {
            Dependencies(
                hostKeyStore: hostKeyStore
                    ?? sessionStore.activeHostKeyStore
                    ?? SessionStore.defaultHostKeyStoreForLiveUse(),
                passwordStore: passwordStore ?? AppServices.shared.passwordStore,
                connectionStore: connectionStore ?? AppServices.shared.connectionStore,
                clipboardSettings: HerdrClipboardSettings(defaults: clipboardDefaults),
                deleteRestorableSessions: { host, port in
                    await sessionStore.forgetRestorableSessions(host: host, port: port)
                }
            )
        }
    }

    struct Outcome: Equatable {
        var hostKeysForgotten: Int
        var passwordsRemoved: Int
        var restorableSessionsRemoved: Int
        var clipboardSettingRemoved: Bool
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func forget(connection: Connection) async -> Outcome {
        let hostIdentities = [(connection.host, connection.port)]
            + connection.jumpChain.map { ($0.host, $0.port) }

        var hostKeysForgotten = 0
        for (host, port) in hostIdentities {
            let hadRecord = ((try? await dependencies.hostKeyStore.lookup(host: host, port: port)).flatMap { $0 }) != nil
            try? await dependencies.hostKeyStore.forget(host: host, port: port)
            if hadRecord { hostKeysForgotten += 1 }
        }

        var passwordsRemoved = 0
        let tags = ConnectionsModel.passwordTags(in: connection)
        let others = (try? await dependencies.connectionStore.loadConnections()) ?? []
        let stillReferenced = Set(
            others
                .filter { $0.id != connection.id }
                .flatMap(ConnectionsModel.passwordTags(in:))
        )
        for tag in tags where !stillReferenced.contains(tag) {
            try? await dependencies.passwordStore.deletePassword(for: tag)
            passwordsRemoved += 1
        }

        let restorableSessionsRemoved = await dependencies.deleteRestorableSessions(
            connection.host, connection.port
        )

        let endpoint = HerdrHostIdentity.endpoint(connection: connection)
        let settings = dependencies.clipboardSettings
        let hadSetting = settings.autoCopyRemoteClipboard(for: endpoint)
        settings.forgetEndpoint(endpoint)

        return Outcome(
            hostKeysForgotten: hostKeysForgotten,
            passwordsRemoved: passwordsRemoved,
            restorableSessionsRemoved: restorableSessionsRemoved,
            clipboardSettingRemoved: hadSetting
        )
    }
}
