import BicTermCore
import Foundation
import Observation

public typealias CoderClientFactory = @Sendable (any CoderTokenStoring) -> CoderClient

@MainActor
@Observable
public final class CoderServersModel {
    private let store: any CoderServerStoreProtocol
    private let connectionStore: any ConnectionStoreProtocol
    private let tokenStore: any CoderTokenStoring
    private let client: CoderClient

    public private(set) var servers: [CoderServer] = []
    public private(set) var isLoading = false
    public var loadError: String?

    public init(
        store: any CoderServerStoreProtocol,
        connectionStore: any ConnectionStoreProtocol,
        tokenStore: any CoderTokenStoring = KeychainCoderTokenStore(),
        makeClient: CoderClientFactory? = nil
    ) {
        self.store = store
        self.connectionStore = connectionStore
        self.tokenStore = tokenStore
        self.client = makeClient?(tokenStore) ?? CoderClient(tokenStore: tokenStore)
    }

    public var hasServers: Bool { !servers.isEmpty }

    public func reload() async {
        isLoading = true
        loadError = nil
        do {
            servers = try await store.loadCoderServers()
        } catch {
            loadError = "Couldn't load Coder servers: \(error.localizedDescription)"
        }
        isLoading = false
    }

    public func save(
        _ proposed: CoderServer,
        replacementToken: String?
    ) async -> Result<Void, CoderServerSaveError> {
        let durableOriginal: CoderServer?
        do {
            durableOriginal = try await store.coderServer(id: proposed.id)
        } catch {
            return .failure(.persistence(error, recovery: []))
        }

        let isEdit = durableOriginal != nil
        if isEdit, proposed.tokenKeychainTag != durableOriginal!.tokenKeychainTag {
            return .failure(.invalidEdit)
        }

        let oldToken: String?
        do {
            oldToken = try await tokenStore.token(for: proposed.tokenKeychainTag)
        } catch {
            return .failure(.tokenAccess(error))
        }

        let candidate: String
        if let replacementToken, !replacementToken.isEmpty {
            candidate = replacementToken
        } else if isEdit, let oldToken, !oldToken.isEmpty {
            candidate = oldToken
        } else {
            return .failure(.missingToken)
        }

        do {
            try await client.validateAndSaveToken(candidate, for: proposed)
        } catch {
            let recoveryFailures = await restoreTokenIfNeeded(
                keychainTag: proposed.tokenKeychainTag,
                expected: oldToken
            )
            return .failure(.validation(error, recovery: recoveryFailures))
        }

        do {
            try await store.save(proposed)
        } catch let primary {
            let recoveryFailures = await rollbackSave(
                proposed: proposed,
                durableOriginal: durableOriginal,
                oldToken: oldToken,
                replacementToken: replacementToken
            )
            return .failure(.persistence(primary, recovery: recoveryFailures))
        }

        if let index = servers.firstIndex(where: { $0.id == proposed.id }) {
            servers[index] = proposed
        } else {
            servers.append(proposed)
        }
        loadError = nil
        return .success(())
    }

    public func connectionsReferencing(serverID: UUID) async -> Result<[Connection], PersistenceError> {
        do {
            let all = try await connectionStore.loadConnections()
            return .success(all.filter { $0.coderRef?.serverID == serverID })
        } catch {
            return .failure(error)
        }
    }

    public func delete(_ server: CoderServer) async -> Result<Void, CoderServerDeleteError> {
        switch await connectionsReferencing(serverID: server.id) {
        case .success(let connections):
            guard connections.isEmpty else {
                return .failure(.referencedConnections(connections))
            }
            return await forceDelete(server)
        case .failure(let error):
            return .failure(.referenceCheckFailed(error))
        }
    }

    public func forceDelete(_ server: CoderServer) async -> Result<Void, CoderServerDeleteError> {
        let oldToken: String?
        do {
            oldToken = try await tokenStore.token(for: server.tokenKeychainTag)
        } catch {
            return .failure(.tokenAccess(error))
        }

        do {
            try await tokenStore.deleteToken(for: server.tokenKeychainTag)
        } catch let primary {
            let recoveryFailures = await restoreTokenIfNeeded(
                keychainTag: server.tokenKeychainTag,
                expected: oldToken
            )
            return .failure(.tokenRemoval(primary, recovery: recoveryFailures))
        }

        do {
            try await store.deleteCoderServer(id: server.id)
        } catch let primary {
            var recoveryFailures: [CoderRecoveryFailure] = []

            if let oldToken {
                do {
                    try await tokenStore.save(oldToken, for: server.tokenKeychainTag)
                } catch {
                    recoveryFailures.append(.tokenStore(error))
                }
            }

            do {
                try await store.save(server)
            } catch {
                recoveryFailures.append(.metadataStore(error))
            }

            return .failure(.persistence(primary, recovery: recoveryFailures))
        }

        servers.removeAll { $0.id == server.id }
        loadError = nil
        return .success(())
    }

    private func restoreTokenIfNeeded(
        keychainTag: String,
        expected oldToken: String?
    ) async -> [CoderRecoveryFailure] {
        var failures: [CoderRecoveryFailure] = []
        let currentToken: String?
        do {
            currentToken = try await tokenStore.token(for: keychainTag)
        } catch {
            failures.append(.tokenStore(error))
            currentToken = nil
        }

        guard currentToken != oldToken else {
            return failures
        }

        failures.append(contentsOf: await restoreToken(for: keychainTag, target: oldToken))
        return failures
    }

    private func restoreToken(
        for keychainTag: String,
        target: String?
    ) async -> [CoderRecoveryFailure] {
        var failures: [CoderRecoveryFailure] = []
        if let target {
            do {
                try await tokenStore.save(target, for: keychainTag)
            } catch {
                failures.append(.tokenStore(error))
            }
        } else {
            do {
                try await tokenStore.deleteToken(for: keychainTag)
            } catch {
                failures.append(.tokenStore(error))
            }
        }
        return failures
    }

    private func rollbackSave(
        proposed: CoderServer,
        durableOriginal: CoderServer?,
        oldToken: String?,
        replacementToken: String?
    ) async -> [CoderRecoveryFailure] {
        var failures: [CoderRecoveryFailure] = []

        if durableOriginal == nil {
            do {
                try await tokenStore.deleteToken(for: proposed.tokenKeychainTag)
            } catch {
                failures.append(.tokenStore(error))
            }
            do {
                try await store.deleteCoderServer(id: proposed.id)
            } catch {
                failures.append(.metadataStore(error))
            }
        } else if let replacementToken, !replacementToken.isEmpty {
            if let oldToken {
                do {
                    try await tokenStore.save(oldToken, for: proposed.tokenKeychainTag)
                } catch {
                    failures.append(.tokenStore(error))
                }
            } else {
                do {
                    try await tokenStore.deleteToken(for: proposed.tokenKeychainTag)
                } catch {
                    failures.append(.tokenStore(error))
                }
            }
            do {
                try await store.save(durableOriginal!)
            } catch {
                failures.append(.metadataStore(error))
            }
        } else {
            do {
                try await store.save(durableOriginal!)
            } catch {
                failures.append(.metadataStore(error))
            }
        }

        return failures
    }
}

public enum CoderRecoveryFailure: Error, Equatable, Sendable {
    case tokenStore(CoderTokenStoreError)
    case metadataStore(PersistenceError)
}

public enum CoderServerSaveError: Error, Equatable, Sendable {
    case missingToken
    case invalidEdit
    case tokenAccess(CoderTokenStoreError)
    case validation(CoderClientError, recovery: [CoderRecoveryFailure])
    case persistence(PersistenceError, recovery: [CoderRecoveryFailure])
}

public enum CoderServerDeleteError: Error, Equatable, Sendable {
    case referencedConnections([Connection])
    case referenceCheckFailed(PersistenceError)
    case tokenAccess(CoderTokenStoreError)
    case tokenRemoval(CoderTokenStoreError, recovery: [CoderRecoveryFailure])
    case persistence(PersistenceError, recovery: [CoderRecoveryFailure])
}

extension CoderServerSaveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Enter a Coder session token."
        case .invalidEdit:
            return "The server identity changed while editing. Try again."
        case .tokenAccess(let error):
            return "Couldn't read the saved token: \(error.localizedDescription)"
        case .validation(let error, _):
            return error.localizedDescription
        case .persistence(let error, let recovery):
            return "Couldn't save: \(error.localizedDescription)" + recoveryDescription(recovery)
        }
    }

    private func recoveryDescription(_ failures: [CoderRecoveryFailure]) -> String {
        failures.isEmpty ? "" : " Recovery also failed; durable state may be inconsistent."
    }
}

extension CoderServerDeleteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .referencedConnections:
            return "This server is used by saved connections. Delete those first, or confirm to remove the server anyway."
        case .referenceCheckFailed(let error):
            return "Couldn't check saved connections: \(error.localizedDescription)"
        case .tokenAccess(let error):
            return "Couldn't read the saved token: \(error.localizedDescription)"
        case .tokenRemoval(let error, let recovery):
            return "Couldn't remove the saved token: \(error.localizedDescription)" + recoveryDescription(recovery)
        case .persistence(let error, let recovery):
            return "Couldn't delete the server: \(error.localizedDescription)" + recoveryDescription(recovery)
        }
    }

    private func recoveryDescription(_ failures: [CoderRecoveryFailure]) -> String {
        failures.isEmpty ? "" : " Recovery also failed; durable state may be inconsistent."
    }
}
