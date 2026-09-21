import Foundation

/// At-most-once snippet store bootstrap: the first consumer to arrive
/// creates the process-wide store; every later (and concurrent) consumer
/// receives the SAME instance. Bootstrapping per window instead would open
/// duplicate containers over one store file, whose writes would not be
/// visible to each other.
public final class SnippetStoreBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private var madeStore: (any SnippetStoreProtocol)?
    private let makeStore: @Sendable () -> any SnippetStoreProtocol

    /// - Parameter makeStore: evaluated at most once, under the bootstrap
    ///   lock.
    public init(makeStore: @escaping @Sendable () -> any SnippetStoreProtocol) {
        self.makeStore = makeStore
    }

    /// Production chain, mirroring the app's other stores: the on-disk
    /// SwiftData store, then an in-memory SwiftData store, then a
    /// session-only in-memory fallback.
    public static func live() -> SnippetStoreBootstrap {
        SnippetStoreBootstrap {
            if let store = try? PersistenceStoreFactory.makeSnippetStore() {
                return store
            }
            if let store = try? PersistenceStoreFactory.makeSnippetStore(inMemoryOnly: true) {
                return store
            }
            return InMemorySnippetStore()
        }
    }

    /// The shared store instance.
    public func store() -> any SnippetStoreProtocol {
        lock.withLock {
            if let madeStore { return madeStore }
            let store = makeStore()
            madeStore = store
            return store
        }
    }
}

/// Last-resort snippet persistence when SwiftData cannot initialize, and
/// the deterministic in-memory double for app-layer lifecycle tests.
/// Mirrors the SwiftData store's policies exactly: duplicate names are
/// rejected within a scope, creation sequences are store-assigned and
/// preserved on update, and queries return deterministic order.
public actor InMemorySnippetStore: SnippetStoreProtocol {
    private var snippets: [Snippet] = []

    public init() {}

    public func loadSnippets() async throws(PersistenceError) -> [Snippet] {
        Snippet.deterministicallyOrdered(snippets)
    }

    public func snippet(id: UUID) async throws(PersistenceError) -> Snippet? {
        snippets.first { $0.id == id }
    }

    public func snippets(connectionID: UUID) async throws(PersistenceError) -> [Snippet] {
        Snippet.deterministicallyOrdered(snippets.filter {
            $0.connectionID == nil || $0.connectionID == connectionID
        })
    }

    public func save(_ snippet: Snippet) async throws(PersistenceError) {
        if snippets.contains(where: {
            $0.id != snippet.id
                && $0.connectionID == snippet.connectionID
                && $0.name == snippet.name
        }) {
            throw .duplicateSnippetName(snippet.name)
        }
        let sequence: Int
        if let current = snippets.first(where: { $0.id == snippet.id }) {
            sequence = current.creationSequence
        } else {
            sequence = (snippets.map(\.creationSequence).max() ?? 0) + 1
        }
        let persisted = snippet.withCreationSequence(sequence)
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = persisted
        } else {
            snippets.append(persisted)
        }
    }

    public func deleteSnippet(id: UUID) async throws(PersistenceError) {
        snippets.removeAll { $0.id == id }
    }

    public func deleteSnippets(connectionID: UUID) async throws(PersistenceError) {
        snippets.removeAll { $0.connectionID == connectionID }
    }
}
