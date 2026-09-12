import Foundation
import SwiftData

@ModelActor
public actor SwiftDataHerdStore: HerdStoreProtocol {
    public func loadHerds() async throws(PersistenceError) -> [Herd] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredHerd>())
            var herds: [Herd] = []
            herds.reserveCapacity(records.count)
            for record in records {
                if let herd = try decodeSkippingQuarantined(record.payload) {
                    herds.append(herd)
                }
            }
            return herds.sorted { $0.name < $1.name }
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load herds")
        }
    }

    /// Quarantine: same policy as the configuration store — payloads that
    /// fail decode are skipped on load, never a wholesale store failure.
    private func decodeSkippingQuarantined(_ payload: Data) throws(PersistenceError) -> Herd? {
        do {
            return try PersistenceCodec.decode(
                Herd.self,
                from: payload,
                modelName: "Herd"
            )
        } catch let error as PersistenceError {
            if case .decodingFailed = error { return nil }
            throw error
        }
    }

    public func herd(id: UUID) async throws(PersistenceError) -> Herd? {
        do {
            guard let record = try storedHerd(id: id) else { return nil }
            return try PersistenceCodec.decode(
                Herd.self,
                from: record.payload,
                modelName: "Herd"
            )
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load herd")
        }
    }

    public func save(_ herd: Herd) async throws(PersistenceError) {
        let payload = try PersistenceCodec.encode(herd, modelName: "Herd")
        do {
            if let record = try storedHerd(id: herd.id) {
                record.payload = payload
            } else {
                modelContext.insert(StoredHerd(id: herd.id, payload: payload))
            }
            try modelContext.save()
        } catch {
            throw .operationFailed("save herd")
        }
    }

    public func deleteHerd(id: UUID) async throws(PersistenceError) {
        do {
            guard let record = try storedHerd(id: id) else { return }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            throw .operationFailed("delete herd")
        }
    }

    private func storedHerd(id: UUID) throws -> StoredHerd? {
        var descriptor = FetchDescriptor<StoredHerd>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
