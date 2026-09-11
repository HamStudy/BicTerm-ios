import Foundation

public protocol HostKeyStoreProtocol: Sendable {
    func loadAll() async throws(PersistenceError) -> [HostKeyRecord]
    func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord?
    func save(_ record: HostKeyRecord) async throws(PersistenceError)
    /// Removes the stored trust decision for one host:port (the per-host
    /// "forget" action — integration doc §15 security sweep). Idempotent:
    /// forgetting an unknown host succeeds.
    func forget(host: String, port: Int) async throws(PersistenceError)
}
