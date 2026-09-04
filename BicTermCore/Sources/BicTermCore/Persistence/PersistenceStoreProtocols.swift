import Foundation

public protocol ConnectionStoreProtocol: Sendable {
    func loadConnections() async throws(PersistenceError) -> [Connection]
    func connection(id: UUID) async throws(PersistenceError) -> Connection?
    func save(_ connection: Connection) async throws(PersistenceError)
    func deleteConnection(id: UUID) async throws(PersistenceError)
}

public protocol CoderServerStoreProtocol: Sendable {
    func loadCoderServers() async throws(PersistenceError) -> [CoderServer]
    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer?
    func save(_ server: CoderServer) async throws(PersistenceError)
    func deleteCoderServer(id: UUID) async throws(PersistenceError)
}

public protocol SessionSnapshotStoreProtocol: Sendable {
    func loadSnapshots() async throws(PersistenceError) -> [SessionSnapshot]
    func snapshot(sceneID: String) async throws(PersistenceError) -> SessionSnapshot?
    func save(_ snapshot: SessionSnapshot) async throws(PersistenceError)
    func deleteSnapshot(sceneID: String) async throws(PersistenceError)
}
