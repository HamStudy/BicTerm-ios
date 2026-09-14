import XCTest

@testable import BicTerm

/// T6 catalog seeding semantics: the herd edit a user makes must be
/// reflected in what the embedded client reads on the NEXT open — the
/// catalog is rewritten atomically per seed, so a removed machine is gone
/// and an added one appears; the seeded selection follows the herd's
/// choice. (Live re-seed of a running client is deliberately out of scope
/// in v1 — see plan herdr-embed T6.)
@MainActor
final class HerdEmbedCatalogTests: XCTestCase {
    private var stateHome: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("herd-embed-catalog-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        stateHome = base
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateHome)
    }

    private func machine(_ label: String, id: String = UUID().uuidString) -> HerdrEmbedMachine {
        HerdrEmbedMachine(
            profileID: id,
            label: label,
            target: "user@\(label).example:22",
            sessionName: "default"
        )
    }

    private func seededProfileIDs() throws -> [String] {
        let file = stateHome.appendingPathComponent("herdr/client/endpoints.json")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ssh = try XCTUnwrap(object["ssh"] as? [[String: Any]])
        return ssh.compactMap { $0["id"] as? String }
    }

    private func seededSelection() throws -> String? {
        let file = stateHome.appendingPathComponent("herdr/client/endpoint-selection.json")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object["selected_profile"] as? String
    }

    func testReseedingReplacesTheCatalogSoHerdEditsReflectOnNextOpen() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        let beta = machine("beta", id: "profile-beta")

        try HerdrEmbedClientCatalog.seed(
            machines: [alpha, beta],
            selectedProfileID: "profile-alpha",
            stateHome: stateHome
        )
        XCTAssertEqual(Set(try seededProfileIDs()), ["profile-alpha", "profile-beta"])
        XCTAssertEqual(try seededSelection(), "profile-alpha")

        let gamma = machine("gamma", id: "profile-gamma")
        try HerdrEmbedClientCatalog.seed(
            machines: [beta, gamma],
            selectedProfileID: "profile-gamma",
            stateHome: stateHome
        )
        let ids = Set(try seededProfileIDs())
        XCTAssertEqual(ids, ["profile-beta", "profile-gamma"])
        XCTAssertFalse(
            ids.contains("profile-alpha"),
            "a machine removed from the herd is gone from the catalog on re-seed"
        )
        XCTAssertEqual(
            try seededSelection(), "profile-gamma",
            "the seeded selection follows the herd's persisted machine choice"
        )
    }

    func testSeedMarksEveryMachineEnabledWithCatalogTargets() throws {
        let alpha = machine("alpha", id: "profile-alpha")
        try HerdrEmbedClientCatalog.seed(
            machines: [alpha],
            selectedProfileID: nil,
            stateHome: stateHome
        )
        let file = stateHome.appendingPathComponent("herdr/client/endpoints.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any]
        )
        let entry = try XCTUnwrap(
            (object["ssh"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["target"] as? String, "user@alpha.example:22")
        XCTAssertEqual(entry["session"] as? String, "default")
        XCTAssertEqual(try seededSelection(), "")
    }
}
