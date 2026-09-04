import Foundation
import SwiftData

@ModelActor
public actor SwiftDataHostKeyStore: HostKeyStoreProtocol {
    public func loadAll() async throws(PersistenceError) -> [HostKeyRecord] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredHostKeyRecord>())
            return try records.map(Self.domainRecord)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("load host keys")
        }
    }

    public func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord? {
        let identityKey = HostKeyIdentity(host: host, port: port).persistenceKey
        do {
            var descriptor = FetchDescriptor<StoredHostKeyRecord>(
                predicate: #Predicate { $0.identityKey == identityKey }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first.map(Self.domainRecord)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .operationFailed("lookup host key")
        }
    }

    public func save(_ record: HostKeyRecord) async throws(PersistenceError) {
        let identityKey = record.identity.persistenceKey
        do {
            var descriptor = FetchDescriptor<StoredHostKeyRecord>(
                predicate: #Predicate { $0.identityKey == identityKey }
            )
            descriptor.fetchLimit = 1
            if let stored = try modelContext.fetch(descriptor).first {
                stored.update(from: record)
            } else {
                modelContext.insert(StoredHostKeyRecord(record: record))
            }
            try modelContext.save()
        } catch {
            throw .operationFailed("save host key")
        }
    }

    private static func domainRecord(
        _ record: StoredHostKeyRecord
    ) throws(PersistenceError) -> HostKeyRecord {
        guard let trustState = HostKeyTrustState(rawValue: record.trustStateRawValue) else {
            throw .decodingFailed("HostKeyRecord")
        }
        return HostKeyRecord(
            host: record.host,
            port: record.port,
            algorithm: record.algorithm,
            publicKeyData: record.publicKeyData,
            trustState: trustState,
            firstSeenDate: record.firstSeenDate
        )
    }
}
