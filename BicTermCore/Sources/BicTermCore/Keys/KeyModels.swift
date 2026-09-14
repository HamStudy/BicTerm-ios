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
    public let enabledByDefault: Bool

    public init(
        reference: String,
        label: String,
        algorithm: KeyAlgorithm,
        fingerprint: String,
        publicKeyBlob: Data,
        requiresBiometry: Bool,
        enabledByDefault: Bool = true
    ) {
        self.reference = reference
        self.label = label
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.publicKeyBlob = publicKeyBlob
        self.requiresBiometry = requiresBiometry
        self.enabledByDefault = enabledByDefault
    }

    private enum CodingKeys: String, CodingKey {
        case reference, label, algorithm, fingerprint, publicKeyBlob, requiresBiometry, enabledByDefault
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try container.decode(String.self, forKey: .reference)
        label = try container.decode(String.self, forKey: .label)
        algorithm = try container.decode(KeyAlgorithm.self, forKey: .algorithm)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        publicKeyBlob = try container.decode(Data.self, forKey: .publicKeyBlob)
        requiresBiometry = try container.decode(Bool.self, forKey: .requiresBiometry)
        enabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true
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
