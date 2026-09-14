import Foundation
import XCTest
@testable import BicTermCore

final class KeyOfferResolverTests: XCTestCase {
    private func key(
        _ reference: String,
        label: String? = nil,
        enabled: Bool = true,
        algorithm: KeyAlgorithm = .ed25519
    ) -> KeyMetadata {
        KeyMetadata(
            reference: reference,
            label: label ?? reference,
            algorithm: algorithm,
            fingerprint: "synthetic-\(reference)",
            publicKeyBlob: Data(reference.utf8),
            requiresBiometry: algorithm == .ecdsaP256,
            enabledByDefault: enabled
        )
    }

    private func resolve(
        _ keys: [KeyMetadata],
        offersKeys: Bool = true,
        customKeys: [String]? = nil,
        hardwareKeysEnabledByDefault: Bool = true
    ) -> [String] {
        KeyOfferResolver().resolve(
            KeyOfferRequest(
                offersKeys: offersKeys,
                customKeys: customKeys,
                hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault
            ),
            keys: keys
        )
    }

    func testKeysOffReturnsEmptyForInheritedAndCustomLists() {
        XCTAssertEqual(resolve([key("a")], offersKeys: false), [])
        XCTAssertEqual(resolve([key("a")], offersKeys: false, customKeys: ["a"]), [])
    }

    func testInheritedPoolIncludesOnlyEnabledKeysInCanonicalOrder() {
        XCTAssertEqual(resolve([key("z"), key("disabled", enabled: false), key("a")]), ["a", "z"])
    }

    func testStaleCustomReferenceIsDropped() {
        XCTAssertEqual(resolve([key("a")], customKeys: ["stale", "a"]), ["a"])
    }

    func testDisabledCustomKeyIsDropped() {
        XCTAssertEqual(resolve([key("a", enabled: false)], customKeys: ["a"]), [])
    }

    func testDuplicateCustomReferencesAreDeduplicated() {
        XCTAssertEqual(resolve([key("a")], customKeys: ["a", "a", "a"]), ["a"])
    }

    func testReverseOrderCustomListUsesCanonicalMetadataOrder() {
        let keys = [key("first", label: "Alpha"), key("last", label: "zulu")]
        XCTAssertEqual(resolve(keys, customKeys: ["last", "first"]), ["first", "last"])
    }

    func testEmptyCustomListDoesNotInheritPool() {
        XCTAssertEqual(resolve([key("a")], customKeys: []), [])
    }

    func testDuplicateMetadataReferencesKeepFirstBeforeSortingAndFiltering() {
        let keys = [
            key("z", label: "Zulu"), key("z", label: "Aardvark"),
            key("a", label: "Alpha"),
            key("disabled", enabled: false), key("disabled", enabled: true)
        ]
        XCTAssertEqual(resolve(keys), ["a", "z"])
        XCTAssertEqual(resolve(keys, customKeys: ["z", "disabled", "a"]), ["a", "z"])
    }

    func testCaseInsensitiveEqualLabelsTieBreakByReference() {
        let keys = [key("z", label: "SAME"), key("a", label: "same"), key("m", label: "Same")]
        XCTAssertEqual(resolve(keys), ["a", "m", "z"])
        XCTAssertEqual(resolve(keys, customKeys: ["z", "m", "a"]), ["a", "m", "z"])
    }

    func testHardwareGateAppliesOnlyToInheritedPool() {
        let keys = [key("hardware", algorithm: .ecdsaP256), key("software")]
        XCTAssertEqual(resolve(keys, hardwareKeysEnabledByDefault: false), ["software"])
        XCTAssertEqual(resolve(keys), ["hardware", "software"])
        XCTAssertEqual(
            resolve(keys, customKeys: ["hardware"], hardwareKeysEnabledByDefault: false),
            ["hardware"]
        )
    }

    func testEightEnabledKeysAreAllOfferedWithoutCap() {
        let references = (1...8).map { "key-\($0)" }
        let keys = references.reversed().map { key($0) }
        XCTAssertEqual(resolve(keys), references)
        XCTAssertEqual(resolve(keys, customKeys: Array(references.reversed())), references)
    }
}
