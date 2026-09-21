import Foundation
import SwiftData

@Model
final class StoredConnection {
    @Attribute(.unique) var id: UUID
    var payload: Data

    init(id: UUID, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@Model
final class StoredHostKeyRecord {
    @Attribute(.unique) var identityKey: String
    var host: String
    var port: Int
    var algorithm: String
    var publicKeyData: Data
    var trustStateRawValue: String
    var firstSeenDate: Date

    init(record: HostKeyRecord) {
        identityKey = record.identity.persistenceKey
        host = record.host
        port = record.port
        algorithm = record.algorithm
        publicKeyData = record.publicKeyData
        trustStateRawValue = record.trustState.rawValue
        firstSeenDate = record.firstSeenDate
    }

    func update(from record: HostKeyRecord) {
        host = record.host
        port = record.port
        algorithm = record.algorithm
        publicKeyData = record.publicKeyData
        trustStateRawValue = record.trustState.rawValue
        firstSeenDate = record.firstSeenDate
    }
}

@Model
final class StoredSessionSnapshot {
    @Attribute(.unique) var sceneID: String
    var payload: Data

    init(sceneID: String, payload: Data) {
        self.sceneID = sceneID
        self.payload = payload
    }
}

@Model
final class StoredHerd {
    @Attribute(.unique) var id: UUID
    var payload: Data

    init(id: UUID, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@Model
final class StoredSnippet {
    @Attribute(.unique) var id: UUID
    var payload: Data

    init(id: UUID, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

enum PersistenceCodec {
    static func encode<Value: Encodable>(
        _ value: Value,
        modelName: String
    ) throws(PersistenceError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .encodingFailed(modelName)
        }
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        modelName: String
    ) throws(PersistenceError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .decodingFailed(modelName)
        }
    }
}
