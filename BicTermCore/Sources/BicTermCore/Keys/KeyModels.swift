import Foundation
import Security

public enum KeyAlgorithm: String, Codable, Sendable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
}

public struct KeyMetadata: Codable, Equatable, Sendable {
    public let reference: String
    public let label: String
    public let algorithm: KeyAlgorithm
    public let fingerprint: String
    public let publicKeyBlob: Data
    public let requiresBiometry: Bool

    public init(
        reference: String,
        label: String,
        algorithm: KeyAlgorithm,
        fingerprint: String,
        publicKeyBlob: Data,
        requiresBiometry: Bool
    ) {
        self.reference = reference
        self.label = label
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.publicKeyBlob = publicKeyBlob
        self.requiresBiometry = requiresBiometry
    }
}

public struct KeySignature: Equatable, Sendable {
    public let algorithm: KeyAlgorithm
    public let rawRepresentation: Data

    public init(algorithm: KeyAlgorithm, rawRepresentation: Data) {
        self.algorithm = algorithm
        self.rawRepresentation = rawRepresentation
    }
}

public enum KeyRepositoryError: Error, Equatable, Sendable {
    case duplicateReference
    case keyNotFound
    case authenticationFailed
    case invalidStoredKey
    case keychain(OSStatus)
}
