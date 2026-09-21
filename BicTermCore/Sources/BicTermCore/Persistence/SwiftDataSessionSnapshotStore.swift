import Foundation
import SwiftData

@ModelActor
public actor SwiftDataSessionSnapshotStore: SessionSnapshotStoreProtocol {
    public func loadSnapshots() async throws(PersistenceError) -> [SessionSnapshot] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredSessionSnapshot>())
            return try records
                .map {
                    try PersistenceCodec.decode(
                        SessionSnapshot.self,
                        from: $0.payload,
                        modelName: "SessionSnapshot"
                    )
                }
                .sorted { $0.createdAt < $1.createdAt }
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load session snapshots")
            }
        }
    }

    public func snapshot(sceneID: String) async throws(PersistenceError) -> SessionSnapshot? {
        do {
            guard let record = try storedSnapshot(sceneID: sceneID) else { return nil }
            return try PersistenceCodec.decode(
                SessionSnapshot.self,
                from: record.payload,
                modelName: "SessionSnapshot"
            )
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load session snapshot")
            }
        }
    }

    public func save(_ snapshot: SessionSnapshot) async throws(PersistenceError) {
        let payload = try PersistenceCodec.encode(snapshot, modelName: "SessionSnapshot")
        do {
            if let record = try storedSnapshot(sceneID: snapshot.sceneID) {
                record.payload = payload
            } else {
                modelContext.insert(
                    StoredSessionSnapshot(sceneID: snapshot.sceneID, payload: payload)
                )
            }
            try modelContext.save()
        } catch {
            throw .operationFailed("save session snapshot")
        }
    }

    public func deleteSnapshot(sceneID: String) async throws(PersistenceError) {
        do {
            guard let record = try storedSnapshot(sceneID: sceneID) else { return }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            throw .operationFailed("delete session snapshot")
        }
    }

    private func storedSnapshot(sceneID: String) throws -> StoredSessionSnapshot? {
        var descriptor = FetchDescriptor<StoredSessionSnapshot>(
            predicate: #Predicate { $0.sceneID == sceneID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
