import Foundation

public protocol ConnectionStoreProtocol: Sendable {
    func loadConnections() async throws(PersistenceError) -> [Connection]
    func connection(id: UUID) async throws(PersistenceError) -> Connection?
    func save(_ connection: Connection) async throws(PersistenceError)
    func deleteConnection(id: UUID) async throws(PersistenceError)
}

public protocol SessionSnapshotStoreProtocol: Sendable {
    func loadSnapshots() async throws(PersistenceError) -> [SessionSnapshot]
    func snapshot(sceneID: String) async throws(PersistenceError) -> SessionSnapshot?
    func save(_ snapshot: SessionSnapshot) async throws(PersistenceError)
    func deleteSnapshot(sceneID: String) async throws(PersistenceError)
}

public protocol HerdStoreProtocol: Sendable {
    func loadHerds() async throws(PersistenceError) -> [Herd]
    func herd(id: UUID) async throws(PersistenceError) -> Herd?
    func save(_ herd: Herd) async throws(PersistenceError)
    func deleteHerd(id: UUID) async throws(PersistenceError)
}

public protocol SnippetStoreProtocol: Sendable {
    /// Every snippet, in deterministic order (creation sequence, then name).
    func loadSnippets() async throws(PersistenceError) -> [Snippet]
    func snippet(id: UUID) async throws(PersistenceError) -> Snippet?
    /// Global plus connection-scoped snippets visible to one connection,
    /// in deterministic order.
    func snippets(connectionID: UUID) async throws(PersistenceError) -> [Snippet]
    /// Saves (inserts or updates by id). Rejects a duplicate name within
    /// the snippet's scope; assigns the creation sequence on insert and
    /// preserves it on update.
    func save(_ snippet: Snippet) async throws(PersistenceError)
    func deleteSnippet(id: UUID) async throws(PersistenceError)
    /// Removes every snippet scoped to one connection — lifecycle cleanup
    /// after that connection's authoritative deletion succeeded.
    func deleteSnippets(connectionID: UUID) async throws(PersistenceError)
}
