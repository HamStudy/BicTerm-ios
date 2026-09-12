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

/// Device-crash regression lock: evaluating a biometry policy (Face ID)
/// without NSFaceIDUsageDescription in the app's Info.plist makes iOS
/// TERMINATE the app on the spot — not a catchable error. Key generation
/// hits this twice over: GenerateKeySheet gates on LABiometricGate
/// (requiresBiometry defaults to true), and Secure Enclave P-256 keys are
/// minted with .biometryCurrentSet access control, which prompts Face ID
/// again at generation. The kill only fires with biometrics enrolled, so
/// simulator runs without enrolled Face ID never exercise it.
final class InfoPlistPrivacyTests: XCTestCase {
    func testAppBundleDeclaresFaceIDUsageDescription() throws {
        let value = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String,
            "NSFaceIDUsageDescription must ship in the app Info.plist — without it, iOS kills the app on the first Face ID evaluation"
        )
        XCTAssertFalse(
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "NSFaceIDUsageDescription must be a non-empty, user-facing explanation"
        )
    }
}
