import BicTermCore
import CryptoKit
import Foundation

enum KeyType: String, CaseIterable, Identifiable {
    case ed25519
    case secureEnclaveP256

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .secureEnclaveP256: "P-256 Secure Enclave"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .ed25519: true
        case .secureEnclaveP256: SecureEnclave.isAvailable
        }
    }
}

struct KeyListItem: Identifiable, Equatable {
    let metadata: KeyMetadata
    let createdDate: Date?

    var id: String { metadata.reference }

    var typeBadge: String {
        switch metadata.algorithm {
        case .ed25519: "ed25519"
        case .ecdsaP256: "Secure Enclave"
        }
    }

    var isSecureEnclave: Bool { metadata.algorithm == .ecdsaP256 }

    var authorizedKeysLine: String {
        "\(metadata.algorithm.rawValue) \(metadata.publicKeyBlob.base64EncodedString()) \(metadata.label)"
    }
}

@MainActor
@Observable
final class KeyStore {
    static let ed25519Service = "com.bicterm.keys.ed25519"
    static let secureEnclaveService = "com.bicterm.keys.secure-enclave"

    private let repository: KeychainKeyRepository
    private let secureEnclaveService: SecureEnclaveKeyService
    private let biometricGate: BiometricGate

    private(set) var keys: [KeyListItem] = []

    init(
        repository: KeychainKeyRepository = KeychainKeyRepository(),
        secureEnclaveService: SecureEnclaveKeyService = SecureEnclaveKeyService(),
        biometricGate: BiometricGate = BiometricGateFactory.make()
    ) {
        self.repository = repository
        self.secureEnclaveService = secureEnclaveService
        self.biometricGate = biometricGate
    }

    func refresh() {
        var items: [KeyListItem] = []
        for service in [Self.ed25519Service, Self.secureEnclaveService] {
            guard let serviceItems = try? KeychainItemQuery.listItems(service: service) else { continue }
            items.append(contentsOf: serviceItems.map {
                KeyListItem(metadata: $0.metadata, createdDate: $0.createdDate)
            })
        }
        keys = items.sorted { $0.metadata.label.localizedCaseInsensitiveCompare($1.metadata.label) == .orderedAscending }
    }

    func authorize(reason: String) async -> Bool {
        await biometricGate.authorize(reason: reason)
    }

    func generate(label: String, type: KeyType, requiresBiometry: Bool) async throws -> KeyMetadata {
        do {
            let metadata: KeyMetadata
            switch type {
            case .ed25519:
                metadata = try await repository.generateEd25519(label: label, requiresBiometry: requiresBiometry)
            case .secureEnclaveP256:
                metadata = try await secureEnclaveService.generate(label: label, requiresBiometry: requiresBiometry)
            }
            refresh()
            return metadata
        } catch {
            throw KeyStoreError.from(error)
        }
    }

    func importKey(_ data: Data, passphrase: Data?, label: String, requiresBiometry: Bool) async throws -> KeyMetadata {
        do {
            let metadata = try await repository.importOpenSSHPrivateKey(
                data,
                passphrase: passphrase,
                label: label,
                requiresBiometry: requiresBiometry
            )
            refresh()
            return metadata
        } catch {
            throw KeyStoreError.from(error)
        }
    }

    func delete(_ item: KeyListItem) throws {
        let service = item.isSecureEnclave ? Self.secureEnclaveService : Self.ed25519Service
        do {
            try KeychainItemQuery.deleteItem(service: service, reference: item.metadata.reference)
            refresh()
        } catch {
            throw KeyStoreError.from(error)
        }
    }

    func connectionsReferencing(_ item: KeyListItem) async -> [Connection] {
        guard let store = try? PersistenceStoreFactory.makeConfigurationStore() else { return [] }
        guard let connections = try? await store.loadConnections() else { return [] }
        return connections.filter { $0.customKeys?.contains(item.metadata.reference) == true }
    }
}

enum KeyStoreError: Error, Equatable {
    case emptyLabel
    case secureEnclaveUnavailable
    case authenticationUnavailable
    case actionFailed(String)
    case unsupportedKeyType(String)
    case invalidFormat
    case missingPassphrase
    case wrongPassphrase
    case biometricGateDenied

    static func from(_ error: Error) -> KeyStoreError {
        if let parserError = error as? OpenSSHPrivateKeyParserError {
            switch parserError {
            case .unsupportedKeyType(let type): return .unsupportedKeyType(type)
            case .invalidFormat: return .invalidFormat
            case .missingPassphrase: return .missingPassphrase
            case .wrongPassphrase: return .wrongPassphrase
            case .unsupportedCipher(let name), .unsupportedKDF(let name):
                return .actionFailed("Unsupported encryption: \(name)")
            }
        }
        if let repositoryError = error as? KeyRepositoryError {
            switch repositoryError {
            case .authenticationFailed: return .authenticationUnavailable
            default: return .actionFailed(String(describing: repositoryError))
            }
        }
        return .actionFailed(String(describing: error))
    }

    var message: String {
        switch self {
        case .emptyLabel: "Enter a name for the key."
        case .secureEnclaveUnavailable: "Secure Enclave is not available on this device."
        case .authenticationUnavailable: "Keychain authentication failed."
        case .actionFailed(let detail): "Couldn't complete the operation (\(detail))."
        case .unsupportedKeyType(let type):
            "Unsupported key type: \(type). BicTerm supports ed25519 keys only — generate a new ed25519 key instead."
        case .invalidFormat: "This doesn't look like an OpenSSH private key (expected “-----BEGIN OPENSSH PRIVATE KEY-----”)."
        case .missingPassphrase: "This key is encrypted — enter its passphrase."
        case .wrongPassphrase: "Incorrect passphrase. Try again."
        case .biometricGateDenied: "Biometric confirmation is required."
        }
    }
}
