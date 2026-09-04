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
    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey
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

    public func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        do {
            return try await keychainRepository.authenticationPrivateKey(with: reference, reason: reason)
        } catch KeyRepositoryError.keyNotFound {
            return try await secureEnclaveService.authenticationPrivateKey(with: reference, reason: reason)
        }
    }
}
