import Foundation
import XCTest
@testable import BicTermCore

final class SessionRestorationTests: XCTestCase {
    func testTerminatedSessionRestoresAsReconnectRequired() throws {
        let snapshot = TestModels.snapshot()

        let restored = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(restored.state, .reconnectRequired)
    }

    func testSnapshotRoundTripsAllRestorationMetadata() throws {
        let snapshot = TestModels.snapshot()

        let restored = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(restored, snapshot)
    }

    func testSnapshotContainsNoSecrets() throws {
        let privateKey = try SecretAbsenceAssertions.fixturePrivateKeyData()
        let connection = try TestModels.connection()
        let snapshot = TestModels.snapshot()
        let encoded = [
            try JSONEncoder().encode(connection),
            try JSONEncoder().encode(snapshot),
        ]

        let findings = try SecretAbsenceAssertions.findings(
            in: encoded,
            privateKeyData: privateKey
        )

        XCTAssertEqual(findings, [], "Encoded restoration state leaked secrets: \(findings)")
    }

    func testSecretScannerDetectsPrivateKeyAndTokenPositiveControl() throws {
        let privateKey = try SecretAbsenceAssertions.fixturePrivateKeyData()
        let privateKeyText = String(decoding: privateKey, as: UTF8.self)
        let deliberatelyUnsafeObject: [String: Any] = [
            "nested": ["privateKey": privateKeyText],
            "credential": TestModels.tokenFixture,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: deliberatelyUnsafeObject)

        let findings = try SecretAbsenceAssertions.findings(
            in: [encoded],
            privateKeyData: privateKey
        )

        XCTAssertTrue(findings.contains { $0.reason == "private-key text" })
        XCTAssertTrue(findings.contains { $0.reason == "token-shaped string" })
    }
}
