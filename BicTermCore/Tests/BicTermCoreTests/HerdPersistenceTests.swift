import Foundation
import XCTest
@testable import BicTermCore

final class HerdPersistenceTests: XCTestCase {
    func testHerdStoreSavesLoadsUpdatesAndDeletesHerds() async throws {
        let store = try PersistenceStoreFactory.makeHerdStore(inMemoryOnly: true)
        let original = try HerdFixtures.herd()
        try await store.save(original)

        let loadedOriginal = try await store.herd(id: original.id)
        XCTAssertEqual(loadedOriginal, original)

        let updated = try Herd(
            id: original.id,
            name: "Updated Herd",
            machines: [original.machines[0]]
        )
        try await store.save(updated)
        let loadedHerds = try await store.loadHerds()
        XCTAssertEqual(loadedHerds, [updated])

        try await store.deleteHerd(id: original.id)
        let deletedHerd = try await store.herd(id: original.id)
        let remainingHerds = try await store.loadHerds()
        XCTAssertNil(deletedHerd)
        XCTAssertEqual(remainingHerds, [])
    }

    /// The herd store lives in its own container; a fresh schema must open
    /// and report zero herds without migration.
    func testFreshHerdStoreOpensWithZeroHerds() async throws {
        let store = try PersistenceStoreFactory.makeHerdStore(inMemoryOnly: true)

        let herds = try await store.loadHerds()
        let missing = try await store.herd(id: UUID())

        XCTAssertEqual(herds, [])
        XCTAssertNil(missing)
    }

    func testLoadHerdsQuarantinesUndecodableRows() async throws {
        let store = try PersistenceStoreFactory.makeHerdStore(inMemoryOnly: true)
        let good = try HerdFixtures.herd()
        try await store.save(good)

        let retiredID = UUID()
        let retiredPayload = Data("""
        {"id":"\(retiredID.uuidString)","name":"Retired","machines":\
        [{"connectionID":"not-a-uuid"}]}
        """.utf8)
        try await store.seedRawHerdPayload(id: retiredID, payload: retiredPayload)
        try await store.seedRawHerdPayload(id: UUID(), payload: Data("not json".utf8))

        let loaded = try await store.loadHerds()

        XCTAssertEqual(loaded, [good])
    }

    func testHerdValidationRejectsEmptyAndWhitespaceOnlyNames() throws {
        XCTAssertThrowsError(try Herd(name: "")) { error in
            XCTAssertEqual(error as? HerdValidationError, .emptyName)
        }
        for blankName in [" ", "\t", "\n"] {
            XCTAssertThrowsError(try Herd(name: blankName)) { error in
                XCTAssertEqual(error as? HerdValidationError, .emptyName)
            }
        }
    }

    func testHerdValidationRejectsDuplicateConnectionIDs() throws {
        let connectionID = TestModels.connectionID
        let machines = [
            try HerdFixtures.machine(connectionID: connectionID),
            try HerdFixtures.machine(connectionID: UUID()),
            try HerdFixtures.machine(connectionID: connectionID, label: "duplicate"),
        ]

        XCTAssertThrowsError(try Herd(name: "Duplicate Herd", machines: machines)) { error in
            XCTAssertEqual(
                error as? HerdValidationError,
                .duplicateConnectionID(connectionID)
            )
        }
    }

    func testHerdValidationRejectsOversizeAndNewlineSessionNames() throws {
        let oversize = String(repeating: "s", count: HerdMachine.maximumSessionNameLength + 1)
        XCTAssertThrowsError(
            try HerdFixtures.machine(sessionName: oversize)
        ) { error in
            XCTAssertEqual(
                error as? HerdValidationError,
                .sessionNameTooLong(
                    maximum: HerdMachine.maximumSessionNameLength,
                    actual: oversize.count
                )
            )
        }

        for invalidSessionName in ["two\nlines", "carriage\rreturn"] {
            XCTAssertThrowsError(
                try HerdFixtures.machine(sessionName: invalidSessionName)
            ) { error in
                XCTAssertEqual(error as? HerdValidationError, .sessionNameContainsNewlines)
            }
        }

        let boundary = String(repeating: "s", count: HerdMachine.maximumSessionNameLength)
        let accepted = try HerdFixtures.machine(sessionName: boundary)
        XCTAssertEqual(accepted.sessionName, boundary)
    }

    /// Validation also runs on decode: payloads that violate herd invariants
    /// fail decoding so the store can quarantine them.
    func testDecodingHerdPayloadAppliesValidation() throws {
        let oversize = String(repeating: "s", count: HerdMachine.maximumSessionNameLength + 1)
        let payload = Data("""
        {"id":"\(TestModels.connectionID.uuidString)","name":"Legacy",\
        "machines":[{"connectionID":"\(TestModels.connectionID.uuidString)",\
        "sessionName":"\(oversize)"}]}
        """.utf8)

        XCTAssertThrowsError(
            try PersistenceCodec.decode(Herd.self, from: payload, modelName: "Herd")
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .decodingFailed("Herd"))
        }
    }

    func testHerdRoundTripsThroughJSONPayload() throws {
        let herd = try HerdFixtures.herd()
        let machine = try HerdFixtures.machine()

        let herdData = try JSONEncoder().encode(herd)
        let machineData = try JSONEncoder().encode(machine)

        XCTAssertEqual(try JSONDecoder().decode(Herd.self, from: herdData), herd)
        XCTAssertEqual(
            try JSONDecoder().decode(HerdMachine.self, from: machineData),
            machine
        )
    }

    func testHerdAndHerdMachineConformToEquatableAndSendable() throws {
        let herd = HerdFixtures.requireSendable(HerdFixtures.requireEquatable(
            try HerdFixtures.herd()
        ))
        let machine = HerdFixtures.requireSendable(HerdFixtures.requireEquatable(
            try HerdFixtures.machine()
        ))

        let differentHerd = try Herd(
            id: herd.id,
            name: herd.name,
            machines: [machine]
        )
        XCTAssertEqual(herd, herd)
        XCTAssertNotEqual(herd, differentHerd)
        XCTAssertNotEqual(
            machine,
            try HerdFixtures.machine(label: "Different")
        )
    }
}

private enum HerdFixtures {
    static let secondConnectionID = UUID(
        uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    )!

    static func machine(
        connectionID: UUID = TestModels.connectionID,
        label: String? = nil,
        sessionName: String? = nil
    ) throws -> HerdMachine {
        try HerdMachine(
            connectionID: connectionID,
            label: label,
            sessionName: sessionName
        )
    }

    static func herd(
        id: UUID = TestModels.connectionID,
        name: String = "Fixture Herd",
        machines: [HerdMachine]? = nil
    ) throws -> Herd {
        try Herd(
            id: id,
            name: name,
            machines: machines ?? [
                try machine(),
                try machine(
                    connectionID: secondConnectionID,
                    label: "Edge Node",
                    sessionName: "edge-session"
                ),
            ]
        )
    }

    /// Compile-time witnesses: the generic constraints only compile when the
    /// argument conforms to the named protocol.
    static func requireEquatable<T: Equatable>(_ value: T) -> T { value }
    static func requireSendable<T: Sendable>(_ value: T) -> T { value }
}

private extension SwiftDataHerdStore {
    /// Inserts a row whose payload never went through `Herd` encoding,
    /// standing in for data written by an older or incompatible build.
    func seedRawHerdPayload(id: UUID, payload: Data) throws {
        modelContext.insert(StoredHerd(id: id, payload: payload))
        try modelContext.save()
    }
}
