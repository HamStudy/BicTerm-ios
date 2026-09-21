import Foundation
import XCTest
@testable import BicTermCore

final class SnippetStoreTests: XCTestCase {
    // MARK: - Model validation

    func testSnippetValidationRejectsEmptyAndWhitespaceNames() throws {
        for blank in ["", " ", "\t", "\n", " \t\n "] {
            XCTAssertThrowsError(try Snippet(name: blank, command: "echo hi")) { error in
                XCTAssertEqual(error as? SnippetValidationError, .emptyName)
            }
        }
    }

    func testSnippetValidationRejectsEmptyAndWhitespaceCommands() throws {
        for blank in ["", " ", "\t", "\n"] {
            XCTAssertThrowsError(try Snippet(name: "Valid Name", command: blank)) { error in
                XCTAssertEqual(error as? SnippetValidationError, .emptyCommand)
            }
        }
    }

    func testSnippetNameIsTrimmedAndCommandPreservedExactly() throws {
        let snippet = try Snippet(name: "  deploy prod  \n", command: "echo deploy")
        XCTAssertEqual(snippet.name, "deploy prod")
        // The command is stored exactly as given (only whitespace-ONLY
        // commands are rejected): Insert/Run send these exact bytes.
        let exact = try Snippet(name: "Exact", command: " echo --flag value ")
        XCTAssertEqual(exact.command, " echo --flag value ")
    }

    func testSnippetRoundTripsThroughJSONPayload() throws {
        let scoped = try Snippet(
            name: "Round Trip",
            command: "echo round-trip",
            connectionID: TestModels.connectionID
        )
        let scopedData = try JSONEncoder().encode(scoped)
        XCTAssertEqual(try JSONDecoder().decode(Snippet.self, from: scopedData), scoped)

        let global = try Snippet(name: "Global", command: "uptime")
        let globalData = try JSONEncoder().encode(global)
        let decoded = try JSONDecoder().decode(Snippet.self, from: globalData)
        XCTAssertEqual(decoded, global)
        XCTAssertNil(decoded.connectionID)
    }

    // MARK: - Store policy (SwiftData store and in-memory fallback)

    func testFreshStoreOpensWithZeroSnippets() async throws {
        for factory in makeStoreFactories() {
            let store = try factory.make()
            let loaded = try await store.loadSnippets()
            XCTAssertEqual(loaded, [])
            let missing = try await store.snippet(id: UUID())
            XCTAssertNil(missing)
        }
    }

    func testCRUDRoundTrip() async throws {
        for factory in makeStoreFactories() {
            let store = try factory.make()
            let original = try Snippet(
                name: "Deploy",
                command: "kubectl rollout restart deploy/web",
                connectionID: TestModels.connectionID
            )
            try await store.save(original)

            let loaded = try await store.snippet(id: original.id)
            XCTAssertEqual(loaded?.name, "Deploy")
            XCTAssertEqual(loaded?.command, "kubectl rollout restart deploy/web")
            XCTAssertEqual(loaded?.connectionID, TestModels.connectionID)

            let updated = try Snippet(
                id: original.id,
                name: "Deploy",
                command: "kubectl rollout status deploy/web",
                connectionID: TestModels.connectionID
            )
            try await store.save(updated)
            let afterUpdate = try await store.snippet(id: original.id)
            XCTAssertEqual(afterUpdate?.command, "kubectl rollout status deploy/web")
            let afterUpdateAll = try await store.loadSnippets()
            XCTAssertEqual(afterUpdateAll.count, 1, "update must upsert, not insert")

            try await store.deleteSnippet(id: original.id)
            let deleted = try await store.snippet(id: original.id)
            XCTAssertNil(deleted)
            let afterDelete = try await store.loadSnippets()
            XCTAssertEqual(afterDelete, [])
        }
    }

    func testDuplicateNamesRejectedWithinScopeButAllowedAcrossScopes() async throws {
        for factory in makeStoreFactories() {
            let store = try factory.make()
            let otherConnection = UUID()
            try await store.save(try Snippet(
                name: "Deploy",
                command: "echo one",
                connectionID: TestModels.connectionID
            ))

            // Same name, same scope, different snippet: rejected.
            let duplicate = try Snippet(
                name: "Deploy",
                command: "echo two",
                connectionID: TestModels.connectionID
            )
            do {
                try await store.save(duplicate)
                XCTFail("expected duplicateSnippetName rejection for \(factory.label) store")
            } catch let error as PersistenceError {
                XCTAssertEqual(error, .duplicateSnippetName("Deploy"))
            }

            // Same name in a different scope (global, or another
            // connection): allowed.
            try await store.save(try Snippet(name: "Deploy", command: "echo global"))
            try await store.save(try Snippet(
                name: "Deploy",
                command: "echo other",
                connectionID: otherConnection
            ))
            // Names compare exactly after trimming: case differences are
            // distinct names.
            let caseVariant = try Snippet(
                name: "deploy",
                command: "echo lowercase",
                connectionID: TestModels.connectionID
            )
            try await store.save(caseVariant)
            let all = try await store.loadSnippets()
            XCTAssertEqual(all.count, 4)

            // Renaming an existing snippet onto another snippet's name in
            // the same scope: rejected.
            let renamed = try Snippet(
                id: caseVariant.id,
                name: "Deploy",
                command: "echo lowercase",
                connectionID: TestModels.connectionID
            )
            do {
                try await store.save(renamed)
                XCTFail("expected duplicateSnippetName rejection for \(factory.label) store")
            } catch let error as PersistenceError {
                XCTAssertEqual(error, .duplicateSnippetName("Deploy"))
            }
        }
    }

    func testUpdatePreservesCreationSequenceAndAllowsRename() async throws {
        for factory in makeStoreFactories() {
            let store = try factory.make()
            let first = try Snippet(name: "First", command: "echo first")
            let second = try Snippet(name: "Second", command: "echo second")
            try await store.save(first)
            try await store.save(second)

            let loadedFirst = try await store.snippet(id: first.id)
            XCTAssertEqual(loadedFirst?.creationSequence, 1, "\(factory.label) store must assign sequences from 1")

            // Renaming (or editing) does not reorder: the sequence is
            // preserved on update.
            let renamed = try Snippet(id: first.id, name: "First (edited)", command: "echo edited")
            try await store.save(renamed)
            let order = try await store.loadSnippets()
            XCTAssertEqual(order.map(\.name), ["First (edited)", "Second"])
            XCTAssertEqual(order.map(\.creationSequence), [1, 2])
        }
    }

    func testOrderingIsCreationSequenceThenName() throws {
        // Pure ordering rule: creation sequence first, name as the tiebreak.
        let early = try Snippet(id: UUID(), name: "zeta", command: "z", connectionID: nil, creationSequence: 1)
        let late = try Snippet(id: UUID(), name: "alpha", command: "a", connectionID: nil, creationSequence: 2)
        XCTAssertEqual(Snippet.deterministicallyOrdered([late, early]).map(\.name), ["zeta", "alpha"])

        let tieBeta = try Snippet(id: UUID(), name: "beta", command: "b", connectionID: nil, creationSequence: 5)
        let tieAlpha = try Snippet(id: UUID(), name: "alpha", command: "a", connectionID: nil, creationSequence: 5)
        XCTAssertEqual(Snippet.deterministicallyOrdered([tieBeta, tieAlpha]).map(\.name), ["alpha", "beta"])
    }

    func testGlobalPlusScopedQueryVisibility() async throws {
        for factory in makeStoreFactories() {
            let store = try factory.make()
            let connectionA = TestModels.connectionID
            let connectionB = UUID()
            try await store.save(try Snippet(name: "Global Uptime", command: "uptime"))
            try await store.save(try Snippet(name: "A Logs", command: "journalctl -f", connectionID: connectionA))
            try await store.save(try Snippet(name: "A Restart", command: "systemctl restart app", connectionID: connectionA))
            try await store.save(try Snippet(name: "B Only", command: "docker ps", connectionID: connectionB))

            let forA = try await store.snippets(connectionID: connectionA)
            XCTAssertEqual(forA.map(\.name), ["Global Uptime", "A Logs", "A Restart"])
            let forB = try await store.snippets(connectionID: connectionB)
            XCTAssertEqual(forB.map(\.name), ["Global Uptime", "B Only"])
            let all = try await store.loadSnippets()
            XCTAssertEqual(all.map(\.name), ["Global Uptime", "A Logs", "A Restart", "B Only"])
        }
    }

    func testDeleteSnippetsRemovesOnlyTheConnectionScope() async throws {
        for factory in makeStoreFactories() {
            let store = try factory.make()
            let connectionA = TestModels.connectionID
            try await store.save(try Snippet(name: "Global", command: "uptime"))
            try await store.save(try Snippet(name: "A One", command: "echo 1", connectionID: connectionA))
            try await store.save(try Snippet(name: "A Two", command: "echo 2", connectionID: connectionA))
            try await store.save(try Snippet(name: "B One", command: "echo 3", connectionID: UUID()))

            try await store.deleteSnippets(connectionID: connectionA)

            let remaining = try await store.loadSnippets()
            XCTAssertEqual(remaining.map(\.name), ["Global", "B One"])

            // Deleting an unknown scope is a no-op.
            try await store.deleteSnippets(connectionID: UUID())
            let afterNoop = try await store.loadSnippets()
            XCTAssertEqual(afterNoop.count, 2)
        }
    }

    // MARK: - SwiftData-specific behavior

    /// On-disk persistence: a second, independent store instance over the
    /// same file reloads the same rows in the same deterministic order.
    func testSnippetsPersistAndReloadAcrossStoreInstances() async throws {
        let directory = try makeScratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snippets.store")

        let first = try PersistenceStoreFactory.makeSnippetStore(storeURL: storeURL)
        try await first.save(try Snippet(name: "Global Uptime", command: "uptime"))
        try await first.save(try Snippet(
            name: "Tail Logs",
            command: "tail -f /var/log/app.log",
            connectionID: TestModels.connectionID
        ))

        let second = try PersistenceStoreFactory.makeSnippetStore(storeURL: storeURL)
        let reloaded = try await second.loadSnippets()
        XCTAssertEqual(reloaded.map(\.name), ["Global Uptime", "Tail Logs"])
        XCTAssertEqual(reloaded.map(\.creationSequence), [1, 2])
        let visible = try await second.snippets(connectionID: TestModels.connectionID)
        XCTAssertEqual(visible.map(\.name), ["Global Uptime", "Tail Logs"])
    }

    /// Rows written by an incompatible build must be skipped on load —
    /// never a wholesale store failure (same policy as the configuration
    /// and herd stores).
    func testLoadSnippetsQuarantinesUndecodableRows() async throws {
        let store = try PersistenceStoreFactory.makeSnippetStore(inMemoryOnly: true)
        let good = try Snippet(name: "Good", command: "echo good")
        try await store.save(good)

        try await store.seedRawSnippetPayload(id: UUID(), payload: Data("not json".utf8))

        let loaded = try await store.loadSnippets()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, good.id)
        XCTAssertEqual(loaded.first?.name, "Good")
    }

    /// A store URL that cannot host a SQLite file fails with the typed,
    /// retryable initialization error — and the failure never disturbs
    /// existing data.
    func testStoreOpenFailureIsRetryableAndPreservesData() async throws {
        let directory = try makeScratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let healthyURL = directory.appendingPathComponent("healthy.store")
        let healthy = try PersistenceStoreFactory.makeSnippetStore(storeURL: healthyURL)
        try await healthy.save(try Snippet(name: "Survivor", command: "echo survived"))

        // An existing directory cannot host the SQLite store file.
        let badURL = directory.appendingPathComponent("unwritable.store", isDirectory: true)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try PersistenceStoreFactory.makeSnippetStore(storeURL: badURL)) { error in
            XCTAssertEqual(error as? PersistenceError, .initializationFailed("BicTermSnippets"))
        }

        // Retryable: opening the healthy URL again succeeds, and the data
        // survived the failed attempt untouched.
        let reopened = try PersistenceStoreFactory.makeSnippetStore(storeURL: healthyURL)
        let reloaded = try await reopened.loadSnippets()
        XCTAssertEqual(reloaded.map(\.name), ["Survivor"])
    }

    // MARK: - Bootstrap

    /// Two simultaneous store consumers must receive ONE store: the
    /// bootstrap evaluates its factory at most once, under its lock.
    func testConcurrentBootstrapHandsEveryConsumerTheSameStore() async {
        let counter = FactoryInvocationCounter()
        let bootstrap = SnippetStoreBootstrap {
            counter.increment()
            return InMemorySnippetStore()
        }

        let stores = await withTaskGroup(of: (any SnippetStoreProtocol).self) { group in
            group.addTask { bootstrap.store() }
            group.addTask { bootstrap.store() }
            var collected: [any SnippetStoreProtocol] = []
            for await store in group { collected.append(store) }
            return collected
        }

        XCTAssertEqual(stores.count, 2)
        XCTAssertTrue(
            (stores[0] as! AnyObject) === (stores[1] as! AnyObject),
            "both consumers must receive the same store instance"
        )
        XCTAssertEqual(counter.value, 1, "the store factory must run exactly once")

        // The shared instance is observable through shared state: a save
        // through one consumer's handle is visible through the other's.
        try? await stores[0].save(Snippet(name: "Shared", command: "echo shared"))
        let visible = try? await stores[1].loadSnippets()
        XCTAssertEqual(visible?.map(\.name), ["Shared"])
    }

    // MARK: - Fixtures

    private func makeStoreFactories() -> [(label: String, make: () throws -> any SnippetStoreProtocol)] {
        [
            ("SwiftData", { try PersistenceStoreFactory.makeSnippetStore(inMemoryOnly: true) }),
            ("InMemory", { InMemorySnippetStore() }),
        ]
    }

    /// Repo-local scratch directory for on-disk store tests (`.scratch/` is
    /// gitignored; the caller removes the directory when done).
    private func makeScratchStoreDirectory() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // BicTermCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BicTermCore
            .deletingLastPathComponent() // repository root
        let directory = repoRoot
            .appendingPathComponent(".scratch/t7/test-stores/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension SwiftDataSnippetStore {
    /// Inserts a row whose payload never went through `Snippet` encoding,
    /// standing in for data written by an incompatible build.
    func seedRawSnippetPayload(id: UUID, payload: Data) throws {
        modelContext.insert(StoredSnippet(id: id, payload: payload))
        try modelContext.save()
    }
}

/// Lock-guarded invocation counter for the bootstrap factory closure
/// (the closure is synchronous, so an actor will not do).
private final class FactoryInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0

    func increment() {
        lock.withLock { invocations += 1 }
    }

    var value: Int {
        lock.withLock { invocations }
    }
}
