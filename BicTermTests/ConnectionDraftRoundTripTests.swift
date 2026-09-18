import BicTermCore
import XCTest
@testable import BicTerm

final class ConnectionDraftRoundTripTests: XCTestCase {
    func testLegacyDecodeNormalizationConnection() throws {
        for method in ["publickey", "password"] {
            for key in ["legacy-key", ""] {
                let json = """
                {"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","name":"Legacy","type":"ssh",
                 "host":"example.com","port":22,"username":"user",
                 "keyReference":"\(key)","authMethod":"\(method)",
                 "jumpChain":[],"protocolOptions":{}}
                """
                let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
                XCTAssertEqual(connection.offersKeys, method == "publickey")
                XCTAssertEqual(connection.customKeys, method == "publickey" ? (key.isEmpty ? [] : [key]) : nil)
                XCTAssertEqual(connection.passwordTag, method == "password" && !key.isEmpty ? key : nil)
                XCTAssertEqual(try ConnectionDraft(connection: connection, keyLabel: nil).makeConnection(), connection)
            }
        }
    }

    func testLegacyDecodeNormalizationHop() throws {
        for method in ["publickey", "password"] {
            for key in ["legacy-key", ""] {
                let json = """
                {"host":"jump.example.com","port":22,"username":"jump",
                 "keyReference":"\(key)","authMethod":"\(method)"}
                """
                let hop = try JSONDecoder().decode(Hop.self, from: Data(json.utf8))
                XCTAssertEqual(hop.offersKeys, method == "publickey")
                XCTAssertEqual(hop.customKeys, method == "publickey" ? (key.isEmpty ? [] : [key]) : nil)
                XCTAssertEqual(hop.passwordTag, method == "password" && !key.isEmpty ? key : nil)
                XCTAssertEqual(try XCTUnwrap(HopDraft(hop: hop, keyLabel: nil).makeHop()), hop)
            }
        }
    }

    func testPublicInitEmptyPasswordTagNormalizesToNil() throws {
        let hop = Hop(host: "jump.example.com", port: 22, username: "jump", passwordTag: "")
        let connection = try Connection(
            name: "Empty tag", type: .ssh, host: "example.com", port: 22, username: "user",
            passwordTag: "", jumpChain: [hop]
        )
        XCTAssertNil(hop.passwordTag)
        XCTAssertNil(connection.passwordTag)
        let hopJSON = """
        {"host":"jump.example.com","port":22,"username":"jump","passwordTag":""}
        """
        let connectionJSON = """
        {"id":"\(connection.id)","name":"Empty tag","type":"ssh",
         "host":"example.com","port":22,"username":"user","passwordTag":"",
         "jumpChain":[\(hopJSON)],"protocolOptions":{}}
        """
        XCTAssertEqual(try JSONDecoder().decode(Hop.self, from: Data(hopJSON.utf8)), hop)
        XCTAssertEqual(try JSONDecoder().decode(Connection.self, from: Data(connectionJSON.utf8)), connection)
    }

    func testDraftConversionPreservesIndependentState() throws {
        for offersKeys in [false, true] {
            for customKeys: [String]? in [nil, [], ["key-a", "key-b"]] {
                for passwordTag: String? in [nil, "password-tag"] {
                    let hop = Hop(host: "jump.example.com", port: 2222, username: "jump",
                                  offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag)
                    let connection = try Connection(
                        name: "Independent", type: .ssh, host: "example.com", port: 22, username: "user",
                        offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag,
                        jumpChain: [hop]
                    )
                    var draft = ConnectionDraft(connection: connection, keyLabel: nil)
                    draft.offersKeys.toggle()
                    draft.hops[0].offersKeys.toggle()
                    let toggled = try draft.makeConnection()
                    XCTAssertEqual(toggled.offersKeys, !offersKeys)
                    XCTAssertEqual(toggled.customKeys, customKeys)
                    XCTAssertEqual(toggled.passwordTag, passwordTag)
                    XCTAssertEqual(toggled.jumpChain[0].offersKeys, !offersKeys)
                    XCTAssertEqual(toggled.jumpChain[0].customKeys, customKeys)
                    XCTAssertEqual(toggled.jumpChain[0].passwordTag, passwordTag)
                    draft.offersKeys.toggle()
                    draft.hops[0].offersKeys.toggle()
                    XCTAssertEqual(try draft.makeConnection(), connection)
                    XCTAssertEqual(try ConnectionDraft(connection: draft.makeConnection(), keyLabel: nil).makeConnection(), connection)
                    XCTAssertEqual(try XCTUnwrap(HopDraft(hop: hop, keyLabel: nil).makeHop()), hop)
                }
            }
        }
    }

    func testConnectionDraftPreservesTwelveCredentialCombinations() throws {
        for offersKeys in [false, true] {
            for customKeys: [String]? in [nil, [], ["key-a", "key-b"]] {
                for passwordTag: String? in [nil, "password-tag"] {
                    let hop = Hop(host: "jump.example.com", port: 2222, username: "jump",
                                  offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag)
                    let connection = try Connection(
                        name: "Round trip", type: .ssh, host: "example.com", port: 22, username: "user",
                        offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag,
                        jumpChain: [hop]
                    )
                    let draft = ConnectionDraft(connection: connection, keyLabel: nil)
                    XCTAssertTrue(draft.isValid)
                    XCTAssertEqual(try draft.makeConnection(), connection)
                }
            }
        }
    }

    func testHopDraftPreservesTwelveCredentialCombinations() throws {
        for offersKeys in [false, true] {
            for customKeys: [String]? in [nil, [], ["key-a", "key-b"]] {
                for passwordTag: String? in [nil, "password-tag"] {
                    let hop = Hop(host: "jump.example.com", port: 2222, username: "jump",
                                  offersKeys: offersKeys, customKeys: customKeys, passwordTag: passwordTag)
                    let draft = HopDraft(hop: hop, keyLabel: nil)
                    XCTAssertTrue(draft.isComplete)
                    XCTAssertEqual(try XCTUnwrap(draft.makeHop()), hop)
                }
            }
        }
    }

    /// The startup command survives the draft round-trip, including when
    /// herdr is on: the editor hides the field in that case, but hiding must
    /// not silently delete the stored value.
    func testStartupCommandSurvivesDraftRoundTripEvenWithHerdrEnabled() throws {
        let connection = try Connection(
            name: "Startup", type: .ssh, host: "example.com", port: 22, username: "user",
            customKeys: ["key-a"],
            protocolOptions: try ProtocolOptions([ProtocolOptions.herdrEnabledKey: .bool(true)]),
            startupCommand: "tmux new-session -A -s main"
        )

        let draft = ConnectionDraft(connection: connection, keyLabel: nil)
        XCTAssertEqual(draft.startupCommand, "tmux new-session -A -s main")
        XCTAssertTrue(draft.herdrEnabled)

        let remade = try draft.makeConnection()
        XCTAssertEqual(remade, connection)
        XCTAssertEqual(
            remade.startupCommand, "tmux new-session -A -s main",
            "a herdr-hidden startup command must be preserved, not deleted"
        )
    }

    func testBlankAndWhitespaceStartupCommandsNormalizeToNil() throws {
        for blank in ["", "   ", " \t\n "] {
            var draft = ConnectionDraft(connection: try Connection(
                name: "Blank", type: .ssh, host: "example.com", port: 22, username: "user",
                customKeys: ["key-a"]
            ), keyLabel: nil)
            draft.startupCommand = blank
            XCTAssertNil(
                try draft.makeConnection().startupCommand,
                "blank \(blank.debugDescription) must save as nil"
            )
        }
    }
}
