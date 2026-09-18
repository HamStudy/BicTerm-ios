import Foundation
import XCTest
@testable import BicTermCore

/// Per-connection startup command: persistence through the StoredConnection
/// payload codec, legacy payloads written before the key existed, blank
/// normalization, and wrong-typed junk (strict, matching passwordTag: the
/// row fails decode and the store quarantines it — never a crash).
final class ConnectionStartupCommandTests: XCTestCase {
    private func makeConnection(startupCommand: String? = nil) throws -> Connection {
        try Connection(
            name: "startup-fixture",
            type: .ssh,
            host: "workspace.example.com",
            port: 22,
            username: "fixture-user",
            customKeys: ["keychain://keys/main"],
            startupCommand: startupCommand
        )
    }

    // MARK: - Persistence round-trip (StoredConnection payload codec)

    func testStartupCommandRoundTripsThroughStoredConnectionPayload() throws {
        let connection = try makeConnection(startupCommand: "tmux new-session -A -s main")

        let payload = try PersistenceCodec.encode(connection, modelName: "Connection")
        let stored = StoredConnection(id: connection.id, payload: payload)
        let decoded = try PersistenceCodec.decode(
            Connection.self,
            from: stored.payload,
            modelName: "Connection"
        )

        XCTAssertEqual(decoded.startupCommand, "tmux new-session -A -s main")
        XCTAssertEqual(decoded, connection)
    }

    func testUnsetStartupCommandStaysAbsentFromThePayload() throws {
        let connection = try makeConnection()

        let payload = try PersistenceCodec.encode(connection, modelName: "Connection")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertNil(json["startupCommand"], "an unset command must not be written into the payload")

        let decoded = try PersistenceCodec.decode(
            Connection.self,
            from: payload,
            modelName: "Connection"
        )
        XCTAssertNil(decoded.startupCommand)
    }

    // MARK: - Legacy payloads (key absent)

    func testLegacyPayloadWithoutStartupCommandDecodesAsNil() throws {
        let legacyJSON = """
        {"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","name":"Legacy","type":"ssh",
         "host":"example.com","port":22,"username":"user",
         "offersKeys":true,"customKeys":["legacy-key"],
         "jumpChain":[],"protocolOptions":{}}
        """

        let decoded = try PersistenceCodec.decode(
            Connection.self,
            from: Data(legacyJSON.utf8),
            modelName: "Connection"
        )

        XCTAssertNil(decoded.startupCommand, "payloads written before the key existed must decode")
        XCTAssertEqual(decoded.name, "Legacy")
    }

    // MARK: - Blank normalization

    func testBlankStartupCommandNormalizesToNil() throws {
        let viaInit = try makeConnection(startupCommand: "")
        XCTAssertNil(viaInit.startupCommand, "init normalizes a blank command to nil")

        let blankJSON = """
        {"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","name":"Blank","type":"ssh",
         "host":"example.com","port":22,"username":"user",
         "offersKeys":true,"jumpChain":[],"protocolOptions":{},
         "startupCommand":""}
        """
        let viaDecode = try PersistenceCodec.decode(
            Connection.self,
            from: Data(blankJSON.utf8),
            modelName: "Connection"
        )
        XCTAssertNil(viaDecode.startupCommand, "decode normalizes a persisted blank to nil")
    }

    // MARK: - Wrong-typed junk fails the row, never crashes (matches passwordTag)

    func testWrongTypedStartupCommandFailsDecodeAndIsQuarantinedOnLoad() async throws {
        let junkJSON = """
        {"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","name":"Junk","type":"ssh",
         "host":"example.com","port":22,"username":"user",
         "offersKeys":true,"jumpChain":[],"protocolOptions":{},
         "startupCommand":42}
        """

        XCTAssertThrowsError(
            try PersistenceCodec.decode(
                Connection.self,
                from: Data(junkJSON.utf8),
                modelName: "Connection"
            ),
            "wrong-typed startupCommand must throw a typed decode failure"
        ) { error in
            guard let persistenceError = error as? PersistenceError,
                  case .decodingFailed = persistenceError else {
                return XCTFail("expected PersistenceError.decodingFailed, got \(error)")
            }
        }

        // Store level: the poisoned row is quarantined (skipped) on load
        // while good rows still surface — never a wholesale store failure.
        let store = try PersistenceStoreFactory.makeConfigurationStore(inMemoryOnly: true)
        let good = try makeConnection(startupCommand: "tmux attach")
        try await store.save(good)
        try await store.seedRawConnectionPayload(
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            payload: Data(junkJSON.utf8)
        )

        let loaded = try await store.loadConnections()
        XCTAssertEqual(loaded, [good])
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
