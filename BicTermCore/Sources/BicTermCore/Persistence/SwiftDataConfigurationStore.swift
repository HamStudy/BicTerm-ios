import Foundation
import SwiftData

@ModelActor
public actor SwiftDataConfigurationStore: ConnectionStoreProtocol {
    public func loadConnections() async throws(PersistenceError) -> [Connection] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredConnection>())
            var connections: [Connection] = []
            connections.reserveCapacity(records.count)
            for record in records {
                if let connection = try decodeSkippingQuarantined(record.payload) {
                    connections.append(connection)
                }
            }
            return connections.sorted { $0.name < $1.name }
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load connections")
            }
        }
    }

    /// Quarantine: rows written by removed features (a protocol this build
    /// no longer ships) fail decode. Skip the row; never fail the whole
    /// store over them. Other persistence failures still propagate.
    private func decodeSkippingQuarantined(_ payload: Data) throws(PersistenceError) -> Connection? {
        do {
            return try PersistenceCodec.decode(
                Connection.self,
                from: payload,
                modelName: "Connection"
            )
        } catch {
            // Force cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; do-block error type is exactly PersistenceError.
            let error = error as! PersistenceError
            if case .decodingFailed = error { return nil }
            throw error
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
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load connection")
            }
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

    private func storedConnection(id: UUID) throws -> StoredConnection? {
        var descriptor = FetchDescriptor<StoredConnection>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
