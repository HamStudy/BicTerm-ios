import Foundation
import SwiftData

@ModelActor
public actor SwiftDataConfigurationStore: ConnectionStoreProtocol, CoderServerStoreProtocol {
    public func loadConnections() async throws(PersistenceError) -> [Connection] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredConnection>())
            return try records
                .map {
                    try PersistenceCodec.decode(
                        Connection.self,
                        from: $0.payload,
                        modelName: "Connection"
                    )
                }
                .sorted { $0.name < $1.name }
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load connections")
        }
    }

    public func connection(id: UUID) async throws(PersistenceError) -> Connection? {
        do {
            guard let record = try storedConnection(id: id) else { return nil }
            return try PersistenceCodec.decode(
                Connection.self,
                from: record.payload,
                modelName: "Connection"
            )
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load connection")
        }
    }

    public func save(_ connection: Connection) async throws(PersistenceError) {
        let payload = try PersistenceCodec.encode(connection, modelName: "Connection")
        do {
            if let record = try storedConnection(id: connection.id) {
                record.payload = payload
            } else {
                modelContext.insert(StoredConnection(id: connection.id, payload: payload))
            }
            try modelContext.save()
        } catch {
            throw .operationFailed("save connection")
        }
    }

    public func deleteConnection(id: UUID) async throws(PersistenceError) {
        do {
            guard let record = try storedConnection(id: id) else { return }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            throw .operationFailed("delete connection")
        }
    }

    public func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredCoderServer>())
            return try records
                .map {
                    try PersistenceCodec.decode(
                        CoderServer.self,
                        from: $0.payload,
                        modelName: "CoderServer"
                    )
                }
                .sorted { $0.name < $1.name }
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load Coder servers")
        }
    }

    public func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        do {
            guard let record = try storedCoderServer(id: id) else { return nil }
            return try PersistenceCodec.decode(
                CoderServer.self,
                from: record.payload,
                modelName: "CoderServer"
            )
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load Coder server")
        }
    }

    public func save(_ server: CoderServer) async throws(PersistenceError) {
        let payload = try PersistenceCodec.encode(server, modelName: "CoderServer")
        do {
            if let record = try storedCoderServer(id: server.id) {
                record.payload = payload
            } else {
                modelContext.insert(StoredCoderServer(id: server.id, payload: payload))
            }
            try modelContext.save()
        } catch {
            throw .operationFailed("save Coder server")
        }
    }

    public func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        do {
            guard let record = try storedCoderServer(id: id) else { return }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            throw .operationFailed("delete Coder server")
        }
    }

    private func storedConnection(id: UUID) throws -> StoredConnection? {
        var descriptor = FetchDescriptor<StoredConnection>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedCoderServer(id: UUID) throws -> StoredCoderServer? {
        var descriptor = FetchDescriptor<StoredCoderServer>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
