import XCTest

@testable import BicTerm

/// T20 release package: the acknowledgements screen must have real content
/// to render — the cargo-about-generated notices ride inside the app bundle.
final class AcknowledgementsTests: XCTestCase {
    func testBundleCarriesThirdPartyNoticesListingEveryHerdrCrate() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            "THIRD_PARTY_NOTICES.md must ship as an app resource"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        for crate in ["herdr-protocol", "herdr-client-core", "herdr-ios-ffi", "bincode", "serde", "unicode-ident"] {
            XCTAssertTrue(text.contains(crate), "notices must acknowledge \(crate)")
        }
        XCTAssertTrue(text.contains("Apache License, Version 2.0"), "the Apache-2.0 notice text must be present")
    }
}
