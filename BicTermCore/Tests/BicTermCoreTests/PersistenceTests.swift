import Foundation
import XCTest
@testable import BicTermCore

final class PersistenceTests: XCTestCase {
    func testConnectionStoreSavesLoadsUpdatesAndDeletesDTOs() async throws {
        let store = try PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true)
        let original = try TestModels.connection()
        try await store.save(original)

        let loadedOriginal = try await store.connection(id: original.id)
        XCTAssertEqual(loadedOriginal, original)

        let updated = try Connection(
            id: original.id,
            name: "Updated Connection",
            type: original.type,
            host: original.host,
            port: original.port,
            username: original.username,
            keyReference: original.keyReference,
            jumpChain: original.jumpChain,
            protocolOptions: original.protocolOptions,
            coderRef: original.coderRef
        )
        try await store.save(updated)
        let loadedConnections = try await store.loadConnections()
        XCTAssertEqual(loadedConnections, [updated])

        try await store.deleteConnection(id: original.id)
        let deletedConnection = try await store.connection(id: original.id)
        XCTAssertNil(deletedConnection)
    }

    func testCoderServerStoreSavesLoadsUpdatesAndDeletesDTOs() async throws {
        let store = try PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true)
        let original = try TestModels.coderServer()
        try await store.save(original)

        let loadedOriginal = try await store.coderServer(id: original.id)
        XCTAssertEqual(loadedOriginal, original)

        let updated = try CoderServer(
            id: original.id,
            name: "Updated Coder",
            baseURL: original.baseURL,
            tokenKeychainTag: original.tokenKeychainTag
        )
        try await store.save(updated)
        let loadedServers = try await store.loadCoderServers()
        XCTAssertEqual(loadedServers, [updated])

        try await store.deleteCoderServer(id: original.id)
        let deletedServer = try await store.coderServer(id: original.id)
        XCTAssertNil(deletedServer)
    }

    func testHostKeyIdentityIncludesPort() async throws {
        let store = try PersistenceStoreFactory.makeHostKeyStore(inMemoryOnly: true)
        let standardPort = TestModels.hostKey(port: 22, byte: 0x11)
        let alternatePort = TestModels.hostKey(port: 2222, byte: 0x22)

        try await store.save(standardPort)
        try await store.save(alternatePort)

        let standardLookup = try await store.lookup(host: standardPort.host, port: 22)
        let alternateLookup = try await store.lookup(host: standardPort.host, port: 2222)
        let records = try await store.loadAll()
        XCTAssertEqual(standardLookup, standardPort)
        XCTAssertEqual(alternateLookup, alternatePort)
        XCTAssertEqual(records.count, 2)
    }

    func testHostKeySaveUpsertsMatchingHostAndPort() async throws {
        let store = try PersistenceStoreFactory.makeHostKeyStore(inMemoryOnly: true)
        let first = TestModels.hostKey(port: 22, byte: 0x11)
        let replacement = TestModels.hostKey(port: 22, byte: 0x33)

        try await store.save(first)
        try await store.save(replacement)

        let loaded = try await store.lookup(host: first.host, port: first.port)
        let records = try await store.loadAll()
        XCTAssertEqual(loaded, replacement)
        XCTAssertEqual(records.count, 1)
    }

    func testSnapshotsArePersistedAndUpsertedPerSceneID() async throws {
        let store = try PersistenceStoreFactory.makeSessionSnapshotStore(inMemoryOnly: true)
        let sceneA = TestModels.snapshot(sceneID: "scene-a")
        let sceneB = TestModels.snapshot(
            connectionID: UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!,
            sceneID: "scene-b"
        )

        try await store.save(sceneA)
        try await store.save(sceneB)

        let replacement = SessionSnapshot(
            connectionID: sceneB.connectionID,
            sceneID: sceneA.sceneID,
            state: .reconnectRequired,
            createdAt: TestModels.createdAt.addingTimeInterval(60)
        )
        try await store.save(replacement)

        let loadedSceneA = try await store.snapshot(sceneID: "scene-a")
        let loadedSceneB = try await store.snapshot(sceneID: "scene-b")
        let snapshots = try await store.loadSnapshots()
        XCTAssertEqual(loadedSceneA, replacement)
        XCTAssertEqual(loadedSceneB, sceneB)
        XCTAssertEqual(snapshots.count, 2)
    }

    func testDeletingSnapshotDoesNotAffectOtherScenes() async throws {
        let store = try PersistenceStoreFactory.makeSessionSnapshotStore(inMemoryOnly: true)
        let sceneA = TestModels.snapshot(sceneID: "scene-a")
        let sceneB = TestModels.snapshot(sceneID: "scene-b")
        try await store.save(sceneA)
        try await store.save(sceneB)

        try await store.deleteSnapshot(sceneID: sceneA.sceneID)

        let deletedScene = try await store.snapshot(sceneID: sceneA.sceneID)
        let remainingScene = try await store.snapshot(sceneID: sceneB.sceneID)
        XCTAssertNil(deletedScene)
        XCTAssertEqual(remainingScene, sceneB)
    }
}
