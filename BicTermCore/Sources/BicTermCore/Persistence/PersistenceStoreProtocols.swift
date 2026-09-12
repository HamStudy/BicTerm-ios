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
