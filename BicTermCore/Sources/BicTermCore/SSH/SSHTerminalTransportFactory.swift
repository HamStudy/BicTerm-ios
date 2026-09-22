import Foundation

/// Default SSH ``TerminalTransportFactory``: every `makeTransport(for:)`
/// produces a FRESH transport (new TCP connection, handshake, and auth per
/// reconnect attempt). Direct connections yield a T7 `SSHTransport`;
/// connections with a jump chain yield a ``JumpTerminalTransport`` that
/// chains via T9's `JumpChainBuilder` at connect time. A non-SSH
/// connection is rejected with a typed
/// ``TransportError/protocolUnavailable`` — never silently dialed.
public struct SSHSessionTransportFactory: TerminalTransportFactory {
    private let hostKeyVerifier: HostKeyVerifier
    private let authenticationKeyProvider: any SSHAuthenticationKeyProvider
    private let passwordStore: any PasswordStoring
    private let passwordPrompt: (any SSHPasswordPrompting)?
    private let hardwareKeysEnabledByDefault: @Sendable () -> Bool
    private let keyOfferResolver: KeyOfferResolver
    private let metadataProvider: any SSHKeyMetadataProviding

    public init(
        hostKeyVerifier: HostKeyVerifier,
        authenticationKeyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider(),
        passwordStore: any PasswordStoring = KeychainPasswordStore(),
        passwordPrompt: (any SSHPasswordPrompting)? = nil,
        hardwareKeysEnabledByDefault: @escaping @Sendable () -> Bool = { true },
        keyOfferResolver: KeyOfferResolver = KeyOfferResolver(),
        metadataProvider: any SSHKeyMetadataProviding = DefaultSSHKeyMetadataProvider()
    ) {
        self.hostKeyVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.passwordStore = passwordStore
        self.passwordPrompt = passwordPrompt
        self.hardwareKeysEnabledByDefault = hardwareKeysEnabledByDefault
        self.keyOfferResolver = keyOfferResolver
        self.metadataProvider = metadataProvider
    }

    public func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        guard connection.type == .ssh else {
            throw .protocolUnavailable(protocolID: connection.type.rawValue)
        }
        // One key-resolution scope per constructed transport = per connect
        // action: every handshake of ONE connect (direct, or every hop +
        // destination of a jump chain) shares a single underlying key
        // resolution — one biometric evaluation per connect intent. The
        // factory itself is long-lived (SessionStore holds it across
        // reconnects), so the scope is created HERE, per transport, and the
        // transport invalidates it when its connect settles (success or
        // failure): a reconnect is a fresh makeTransport = fresh scope =
        // fresh evaluation.
        let connectKeyScope = ConnectScopedKeyResolution()
        let scopedKeyProvider = connectKeyScope.wrapping(authenticationKeyProvider)
        if connection.jumpChain.isEmpty {
            return SSHTransport(
                hostKeyVerifier: hostKeyVerifier,
                authenticationKeyProvider: scopedKeyProvider,
                passwordStore: passwordStore,
                passwordPrompt: passwordPrompt,
                hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
                keyOfferResolver: keyOfferResolver,
                metadataProvider: metadataProvider,
                connectKeyScope: connectKeyScope
            )
        }
        return JumpTerminalTransport(
            builder: JumpChainBuilder(
                hostKeyVerifier: hostKeyVerifier,
                authenticationKeyProvider: scopedKeyProvider,
                passwordStore: passwordStore,
                passwordPrompt: passwordPrompt,
                hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
                keyOfferResolver: keyOfferResolver,
                metadataProvider: metadataProvider
            ),
            connectKeyScope: connectKeyScope
        )
    }
}
