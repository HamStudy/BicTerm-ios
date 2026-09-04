import Foundation

public protocol HostKeyStoreProtocol: Sendable {
    func loadAll() async throws(PersistenceError) -> [HostKeyRecord]
    func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord?
    func save(_ record: HostKeyRecord) async throws(PersistenceError)
}
