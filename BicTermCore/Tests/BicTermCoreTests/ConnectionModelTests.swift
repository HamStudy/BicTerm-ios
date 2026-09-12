import Foundation
import XCTest
@testable import BicTermCore

final class ConnectionModelTests: XCTestCase {
    func testConnectionRoundTripsEveryField() throws {
        let value = try TestModels.connection()

        let decoded = try roundTrip(value)

        XCTAssertEqual(decoded, value)
    }

    func testConnectionTypeRoundTrips() throws {
        XCTAssertEqual(try roundTrip(ConnectionType.ssh), .ssh)
        XCTAssertEqual(try roundTrip(ConnectionType.uppercaseEcho), .uppercaseEcho)
    }

    func testHopRoundTrips() throws {
        let value = TestModels.hop()

        XCTAssertEqual(try roundTrip(value), value)
    }

    func testProtocolOptionsRoundTripPreservesEveryValueKind() throws {
        let value = try TestModels.protocolOptions()

        let decoded = try roundTrip(value)

        XCTAssertEqual(decoded["terminalType"], .string("xterm-256color"))
        XCTAssertEqual(decoded["keepaliveInterval"], .int(30))
        XCTAssertEqual(decoded["compression"], .bool(true))
    }

    func testHostKeyRecordRoundTrips() throws {
        let value = TestModels.hostKey(port: 22, byte: 0x11)

        XCTAssertEqual(try roundTrip(value), value)
    }

    func testConnectionAcceptsExactlyFiveHops() throws {
        let hops = (1...5).map(TestModels.hop)

        let connection = try TestModels.connection(jumpChain: hops)

        XCTAssertEqual(connection.jumpChain.count, 5)
    }

    func testConnectionRejectsSixHopsWithTypedError() throws {
        let hops = (1...6).map(TestModels.hop)

        XCTAssertThrowsError(try TestModels.connection(jumpChain: hops)) { error in
            XCTAssertEqual(
                error as? ConnectionValidationError,
                .jumpChainTooLong(maximum: 5, actual: 6)
            )
        }
    }

    func testConnectionDecodeRejectsSixHops() throws {
        let encoded = try JSONEncoder().encode(TestModels.connection())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var hops = try XCTUnwrap(object["jumpChain"] as? [Any])
        hops.append(try XCTUnwrap(hops.first))
        hops.append(try XCTUnwrap(hops.first))
        hops.append(try XCTUnwrap(hops.first))
        hops.append(try XCTUnwrap(hops.first))
        object["jumpChain"] = hops
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(Connection.self, from: malformed)) { error in
            XCTAssertEqual(
                error as? ConnectionValidationError,
                .jumpChainTooLong(maximum: 5, actual: 6)
            )
        }
    }

    func testProtocolOptionsRejectSecretBearingKeys() {
        XCTAssertThrowsError(try ProtocolOptions(["password": .string("not-even-a-real-secret")])) { error in
            XCTAssertEqual(
                error as? ProtocolOptionsValidationError,
                .secretBearingKeyNotAllowed("password")
            )
        }
    }

    func testDomainValuesAreSendable() throws {
        requireSendable(try TestModels.connection())
        requireSendable(TestModels.hop())
        requireSendable(TestModels.hostKey(port: 22, byte: 0x22))
        requireSendable(TestModels.snapshot())
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func requireSendable<Value: Sendable>(_: Value) {}
}
