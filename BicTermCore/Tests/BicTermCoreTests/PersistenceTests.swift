import Foundation
import XCTest
@testable import BicTermCore

final class PersistenceTests: XCTestCase {
    func testLegacyCredentialMigrationForConnectionsAndHops() throws {
        let fixtures: [(String, Bool, [String]?, String?)] = [
            (#""keyReference":"legacy-key""#, true, ["legacy-key"], nil),
            (#""keyReference":"legacy-key","authMethod":"publickey""#, true, ["legacy-key"], nil),
            (#""keyReference":"","authMethod":"publickey""#, true, [], nil),
            (#""keyReference":"legacy-password","authMethod":"password""#, false, nil, "legacy-password"),
            (#""keyReference":"","authMethod":"password""#, false, nil, nil),
        ]
        for (credentials, offersKeys, customKeys, passwordTag) in fixtures {
            let hopJSON = """
            {"host":"jump.example.com","port":22,"username":"jump",\(credentials)}
            """
            let connectionJSON = """
            {"id":"\(TestModels.connectionID)","name":"Legacy","type":"ssh",
             "host":"example.com","port":22,"username":"user",\(credentials),
             "jumpChain":[\(hopJSON)],"protocolOptions":{}}
            """
            let hop = try JSONDecoder().decode(Hop.self, from: Data(hopJSON.utf8))
            let connection = try JSONDecoder().decode(Connection.self, from: Data(connectionJSON.utf8))
            XCTAssertEqual(hop.offersKeys, offersKeys)
            XCTAssertEqual(hop.customKeys, customKeys)
            XCTAssertEqual(hop.passwordTag, passwordTag)
            XCTAssertEqual(connection.offersKeys, offersKeys)
            XCTAssertEqual(connection.customKeys, customKeys)
            XCTAssertEqual(connection.passwordTag, passwordTag)
            XCTAssertEqual(connection.jumpChain, [hop])
            try assertNewShapeRoundTrip(hop)
            try assertNewShapeRoundTrip(connection)
        }
    }

    func testNewCredentialShapeRoundTripsEveryCombination() throws {
        for offersKeys in [false, true] {
            for customKeys: [String]? in [nil, [], ["key-a", "key-b"]] {
                for passwordTag: String? in [nil, "password-tag"] {
                    let hop = Hop(host: "jump.example.com", port: 22, username: "jump",
                                  offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag)
                    let connection = try Connection(
                        name: "New", type: .ssh, host: "example.com", port: 22, username: "user",
                        offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag,
                        jumpChain: [hop]
                    )
                    try assertNewShapeRoundTrip(hop)
                    try assertNewShapeRoundTrip(connection)
                }
            }
        }
    }

    func testAnyNewCredentialFieldTakesPrecedenceOverLegacyFields() throws {
        for field in ["offersKeys", "customKeys", "passwordTag"] {
            let credentials = "\"\(field)\":null,\"keyReference\":\"old\",\"authMethod\":\"password\""
            let hopJSON = """
            {"host":"jump.example.com","port":22,"username":"jump",\(credentials)}
            """
            let connectionJSON = """
            {"id":"\(TestModels.connectionID)","name":"New","type":"ssh",
             "host":"example.com","port":22,"username":"user",\(credentials),
             "jumpChain":[],"protocolOptions":{}}
            """
            let hop = try JSONDecoder().decode(Hop.self, from: Data(hopJSON.utf8))
            let connection = try JSONDecoder().decode(Connection.self, from: Data(connectionJSON.utf8))
            XCTAssertTrue(hop.offersKeys)
            XCTAssertNil(hop.customKeys)
            XCTAssertNil(hop.passwordTag)
            XCTAssertTrue(connection.offersKeys)
            XCTAssertNil(connection.customKeys)
            XCTAssertNil(connection.passwordTag)
        }
    }

    private func assertNewShapeRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: data), value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["offersKeys"])
        XCTAssertNil(json["keyReference"])
        XCTAssertNil(json["authMethod"])
        for hop in json["jumpChain"] as? [[String: Any]] ?? [] {
            XCTAssertNotNil(hop["offersKeys"])
            XCTAssertNil(hop["keyReference"])
            XCTAssertNil(hop["authMethod"])
        }
    }

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
            offersKeys: original.offersKeys,
            customKeys: original.customKeys,
            passwordTag: original.passwordTag,
            jumpChain: original.jumpChain,
            protocolOptions: original.protocolOptions
        )
        try await store.save(updated)
        let loadedConnections = try await store.loadConnections()
        XCTAssertEqual(loadedConnections, [updated])

        try await store.deleteConnection(id: original.id)
        let deletedConnection = try await store.connection(id: original.id)
        XCTAssertNil(deletedConnection)
    }

    /// Rows written by removed features (a protocol id this build no longer
    /// ships, or an unparseable payload) must be skipped on load — never a
    /// wholesale store failure.
    func testLoadConnectionsQuarantinesUndecodableRows() async throws {
        let store = try PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true)
        let good = try TestModels.connection()
        try await store.save(good)

        let retiredID = UUID()
        let retiredPayload = Data("""
        {"id":"\(retiredID.uuidString)","name":"Retired","type":"retired-protocol",\
        "host":"retired.example.com","port":22,"username":"u","keyReference":"k",\
        "jumpChain":[],"protocolOptions":{}}
        """.utf8)
        try await store.seedRawConnectionPayload(id: retiredID, payload: retiredPayload)
        try await store.seedRawConnectionPayload(id: UUID(), payload: Data("not json".utf8))

        let loaded = try await store.loadConnections()

        XCTAssertEqual(loaded, [good])
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

private extension SwiftDataConfigurationStore {
    /// Inserts a row whose payload never went through `Connection` encoding,
    /// standing in for data written by a build with features this one lacks.
    func seedRawConnectionPayload(id: UUID, payload: Data) throws {
        modelContext.insert(StoredConnection(id: id, payload: payload))
        try modelContext.save()
    }
}
