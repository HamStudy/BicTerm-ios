import Foundation
import XCTest
@testable import BicTermCore

/// Herdr connection options (herdr-support plan todo 1): typed accessors
/// over protocolOptions keys `herdrEnabled`/`herdrSession`, including
/// persistence through the StoredConnection payload codec, legacy
/// connections written before the keys existed, and wrong-typed junk.
final class ConnectionHerdrOptionsTests: XCTestCase {
    private func makeConnection(
        options: () throws -> ProtocolOptions = ProtocolOptions.init
    ) throws -> Connection {
        try Connection(
            name: "herdr-option-fixture",
            type: .ssh,
            host: "workspace.example.com",
            port: 22,
            username: "fixture-user",
            keyReference: "keychain://keys/main",
            protocolOptions: options()
        )
    }

    // MARK: - Persistence round-trip (StoredConnection payload codec)

    func testHerdrOptionsRoundTripThroughStoredConnectionPayload() throws {
        let connection = try makeConnection {
            try ProtocolOptions([
                ProtocolOptions.herdrEnabledKey: .bool(true),
                ProtocolOptions.herdrSessionKey: .string("work"),
            ])
        }

        let payload = try PersistenceCodec.encode(connection, modelName: "Connection")
        let stored = StoredConnection(id: connection.id, payload: payload)
        let decoded = try PersistenceCodec.decode(
            Connection.self,
            from: stored.payload,
            modelName: "Connection"
        )

        XCTAssertTrue(decoded.herdrEnabled)
        XCTAssertEqual(decoded.herdrSessionName, "work")
    }

    func testDisabledHerdrOptionsRoundTripThroughStoredConnectionPayload() throws {
        let connection = try makeConnection {
            try ProtocolOptions([
                ProtocolOptions.herdrEnabledKey: .bool(false),
                ProtocolOptions.herdrSessionKey: .string(""),
            ])
        }

        let decoded = try PersistenceCodec.decode(
            Connection.self,
            from: PersistenceCodec.encode(connection, modelName: "Connection"),
            modelName: "Connection"
        )

        XCTAssertFalse(decoded.herdrEnabled)
        XCTAssertNil(decoded.herdrSessionName)
    }

    // MARK: - Legacy connections (keys absent)

    func testLegacyConnectionWithoutHerdrKeysUsesDefaults() throws {
        let legacy = try makeConnection {
            try ProtocolOptions([
                "keepaliveInterval": .int(30),
                "compression": .bool(true),
            ])
        }

        XCTAssertFalse(legacy.herdrEnabled)
        XCTAssertNil(legacy.herdrSessionName)
    }

    func testConnectionWithEmptyOptionsUsesDefaults() throws {
        let bare = try makeConnection()

        XCTAssertFalse(bare.herdrEnabled)
        XCTAssertNil(bare.herdrSessionName)
    }

    // MARK: - Wrong-typed values read as unset

    func testWrongTypedHerdrEnabledValuesReadAsDisabled() throws {
        for value in [ProtocolOptionValue.string("true"), .int(1), .string("yes")] {
            let connection = try makeConnection {
                try ProtocolOptions([ProtocolOptions.herdrEnabledKey: value])
            }
            XCTAssertFalse(
                connection.herdrEnabled,
                "wrong-typed herdrEnabled \(value) must read as disabled"
            )
        }
    }

    func testWrongTypedHerdrSessionValuesReadAsUnset() throws {
        for value in [ProtocolOptionValue.int(5), .bool(true)] {
            let connection = try makeConnection {
                try ProtocolOptions([ProtocolOptions.herdrSessionKey: value])
            }
            XCTAssertNil(
                connection.herdrSessionName,
                "wrong-typed herdrSession \(value) must read as unset"
            )
        }
    }

    // MARK: - Session-name trimming

    func testHerdrSessionNameIsTrimmed() throws {
        let connection = try makeConnection {
            try ProtocolOptions([ProtocolOptions.herdrSessionKey: .string("  padded \n")])
        }

        XCTAssertEqual(connection.herdrSessionName, "padded")
    }

    func testBlankHerdrSessionNameReadsAsUnset() throws {
        for blank in ["", "   ", "\t\n "] {
            let connection = try makeConnection {
                try ProtocolOptions([ProtocolOptions.herdrSessionKey: .string(blank)])
            }
            XCTAssertNil(connection.herdrSessionName, "blank \(blank.debugDescription) must read as nil")
        }
    }
}
