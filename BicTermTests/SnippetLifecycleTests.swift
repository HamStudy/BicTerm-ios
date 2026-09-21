import BicTermCore
import XCTest
@testable import BicTerm

/// Todo 7 lifecycle seam: connection deletion must remove scoped snippets
/// ONLY after the authoritative connection deletion succeeds. A failed
/// delete, and a connection the store quarantined on load (decode-failed
/// row, invisible to the model), must never trigger snippet cleanup.
@MainActor
final class SnippetLifecycleTests: XCTestCase {
    func testConnectionDeleteRemovesScopedSnippetsAfterAuthoritativeDelete() async throws {
        let snippetStore = InMemorySnippetStore()
        let connectionStore = WorkingConnectionStore()
        let model = ConnectionsModel(
            connectionStore: connectionStore,
            protocolDescriptors: [.ssh],
            descriptorProvider: { _ in .ssh },
            snippetStore: snippetStore
        )
        let connection = try fixtureConnection(name: "Snippet Host")
        try await connectionStore.save(connection)
        await model.reload()
        XCTAssertEqual(model.connections.count, 1)

        try await snippetStore.save(try Snippet(name: "Scoped", command: "echo scoped", connectionID: connection.id))
        try await snippetStore.save(try Snippet(name: "Global", command: "echo global"))
        try await snippetStore.save(try Snippet(name: "Other Scope", command: "echo other", connectionID: UUID()))

        await model.delete(connection)

        XCTAssertEqual(model.connections, [])
        XCTAssertNil(model.loadError)
        let remaining = try await snippetStore.loadSnippets()
        XCTAssertEqual(remaining.map(\.name), ["Global", "Other Scope"])
    }

    func testFailedConnectionDeletePreservesScopedSnippets() async throws {
        let snippetStore = InMemorySnippetStore()
        let connection = try fixtureConnection(name: "Stays")
        let connectionStore = FailingDeleteConnectionStore(connection: connection)
        let model = ConnectionsModel(
            connectionStore: connectionStore,
            protocolDescriptors: [.ssh],
            descriptorProvider: { _ in .ssh },
            snippetStore: snippetStore
        )
        try await snippetStore.save(try Snippet(name: "Scoped", command: "echo scoped", connectionID: connection.id))

        await model.reload()
        XCTAssertEqual(model.connections.count, 1)

        await model.delete(connection)

        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(model.connections.count, 1, "the connection must survive its failed deletion")
        let remaining = try await snippetStore.loadSnippets()
        XCTAssertEqual(remaining.map(\.name), ["Scoped"], "a failed connection delete must preserve scoped snippets")
    }

    /// A quarantined connection (decode-failed row) never appears in the
    /// model, so nothing in the load path may delete its scoped snippets.
    /// The core PersistenceTests pin the skip-on-load behavior on the real
    /// SwiftDataConfigurationStore; this double reproduces it.
    func testQuarantinedConnectionReadNeverTriggersSnippetCleanup() async throws {
        let snippetStore = InMemorySnippetStore()
        let quarantinedID = UUID()
        let connectionStore = QuarantiningConnectionStore(
            quarantined: try fixtureConnection(name: "Undecodable Row")
        )
        let model = ConnectionsModel(
            connectionStore: connectionStore,
            protocolDescriptors: [.ssh],
            descriptorProvider: { _ in .ssh },
            snippetStore: snippetStore
        )
        try await snippetStore.save(try Snippet(name: "Orphaned Scope", command: "echo x", connectionID: quarantinedID))
        try await snippetStore.save(try Snippet(name: "Global", command: "uptime"))

        await model.reload()

        XCTAssertEqual(model.connections, [], "the quarantined row is skipped on load")
        let remaining = try await snippetStore.loadSnippets()
        XCTAssertEqual(remaining.map(\.name), ["Orphaned Scope", "Global"])
    }

    /// App-service ownership: every access hands back the one process-wide
    /// store — the wiring must never regress to a per-access factory call.
    func testAppServicesExposesOneSharedSnippetStore() {
        let first = AppServices.shared.snippetStore
        let second = AppServices.shared.snippetStore
        XCTAssertTrue((first as! AnyObject) === (second as! AnyObject))
    }

    private func fixtureConnection(name: String) throws -> Connection {
        try Connection(name: name, type: .ssh, host: "example.com", port: 22, username: "alice")
    }
}

private actor WorkingConnectionStore: ConnectionStoreProtocol {
    private var storage: [UUID: Connection] = [:]

    func loadConnections() async throws(PersistenceError) -> [Connection] {
        storage.values.sorted { $0.name < $1.name }
    }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? { storage[id] }

    func save(_ connection: Connection) async throws(PersistenceError) {
        storage[connection.id] = connection
    }

    func deleteConnection(id: UUID) async throws(PersistenceError) {
        storage[id] = nil
    }
}

private actor FailingDeleteConnectionStore: ConnectionStoreProtocol {
    private let connection: Connection

    init(connection: Connection) {
        self.connection = connection
    }

    func loadConnections() async throws(PersistenceError) -> [Connection] { [connection] }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? {
        id == connection.id ? connection : nil
    }

    func save(_ connection: Connection) async throws(PersistenceError) {}

    func deleteConnection(id: UUID) async throws(PersistenceError) {
        throw .operationFailed("the test store rejected the delete")
    }
}

/// Holds a connection row whose payload would fail decode: load skips it,
/// exactly like SwiftDataConfigurationStore quarantines undecodable rows.
private actor QuarantiningConnectionStore: ConnectionStoreProtocol {
    private let quarantined: Connection

    init(quarantined: Connection) {
        self.quarantined = quarantined
    }

    func loadConnections() async throws(PersistenceError) -> [Connection] { [] }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? {
        id == quarantined.id ? quarantined : nil
    }

    func save(_ connection: Connection) async throws(PersistenceError) {}

    func deleteConnection(id: UUID) async throws(PersistenceError) {}
}
