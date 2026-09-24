import Foundation
import NIOSSH

/// Resolves the opaque private key used for SSH public-key authentication.
///
/// Implementations must NOT expose or export key material; the returned
/// ``NIOSSHPrivateKey`` is an opaque signing handle (Keychain ed25519 or
/// Secure Enclave P-256) consumed directly by NIOSSH.
public protocol SSHAuthenticationKeyProvider: Sendable {
    /// - parameters:
    ///   - reference: Opaque key reference from `Connection.keyReference`.
    ///   - reason: User-facing reason string for any authentication prompt.
    ///   - biometricContext: The connect action's shared biometric context
    ///     when this resolution belongs to one (terminal connect, jump
    ///     build, herdr bring-up, herd open) — the ONE LAContext whose
    ///     single evaluation every key operation of that action reuses.
    ///     Nil (agent signing, key-management UI, direct service use)
    ///     keeps the pre-existing behavior of a fresh LAContext per
    ///     operation.
    func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext?
    ) async throws -> NIOSSHPrivateKey
}

public extension SSHAuthenticationKeyProvider {
    /// Convenience for callers with no connect scope to offer.
    func authenticationPrivateKey(
        with reference: String,
        reason: String
    ) async throws -> NIOSSHPrivateKey {
        try await authenticationPrivateKey(with: reference, reason: reason, biometricContext: nil)
    }
}

/// Default provider: looks the reference up in the ed25519 Keychain
/// repository first, falling through to the Secure Enclave service when the
/// reference is unknown there. Any other error (including user cancellation
/// of a biometric prompt) propagates.
public struct DefaultSSHAuthenticationKeyProvider: SSHAuthenticationKeyProvider {
    private let keychainRepository: KeychainKeyRepository
    private let secureEnclaveService: SecureEnclaveKeyService

    public init() {
        self.keychainRepository = KeychainKeyRepository()
        self.secureEnclaveService = SecureEnclaveKeyService()
    }

    public func authenticationPrivateKey(
        with reference: String,
        reason: String,
        biometricContext: ConnectScopedBiometricContext?
    ) async throws -> NIOSSHPrivateKey {
        do {
            return try await keychainRepository.authenticationPrivateKey(
                with: reference, reason: reason, biometricContext: biometricContext
            )
        } catch KeyRepositoryError.keyNotFound {
            return try await secureEnclaveService.authenticationPrivateKey(
                with: reference, reason: reason, biometricContext: biometricContext
            )
        }
    }
}
