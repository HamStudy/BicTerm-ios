import BicTermCore
import XCTest
@testable import BicTerm

/// Behavioral coverage for the key-import seam the UI drives: the biometric
/// opt-in flag must reach the repository (never hardcoded), passphrases map to
/// friendly typed errors, and unsupported DSA material is rejected by typed
/// policy. Runs in the app host so the real Data Protection Keychain is used.
@MainActor
final class KeyStoreImportTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let passphraseFixture = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519_passphrase")
    private static let dssHeaderFixture = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-dss_header")

    private var keyStore: KeyStore!
    private var repository: KeychainKeyRepository!
    private var importedReferences: [String] = []

    override func setUp() {
        super.setUp()
        repository = KeychainKeyRepository(
            keychainService: "com.bicterm.tests.keys.import.\(UUID().uuidString)"
        )
        keyStore = KeyStore(repository: repository)
    }

    override func tearDown() async throws {
        for reference in importedReferences {
            try? await repository.delete(reference: reference)
        }
        importedReferences.removeAll()
        try await super.tearDown()
    }

    private func fixtureData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func testImportWithBiometricOptInStoresProtectedMetadata() async throws {
        let metadata = try await keyStore.importKey(
            fixtureData(Self.passphraseFixture),
            passphrase: Data("testpass".utf8),
            label: "unit-biometric-import",
            requiresBiometry: true
        )
        importedReferences.append(metadata.reference)

        XCTAssertTrue(metadata.requiresBiometry, "Opt-in flag must reach the repository store")

        let persisted = try await repository.list()
        XCTAssertTrue(
            persisted.contains { $0.reference == metadata.reference && $0.requiresBiometry },
            "Biometric protection must persist in Keychain metadata"
        )
    }

    func testImportWithoutBiometricsStoresUnprotectedMetadata() async throws {
        let metadata = try await keyStore.importKey(
            fixtureData(Self.passphraseFixture),
            passphrase: Data("testpass".utf8),
            label: "unit-plain-import",
            requiresBiometry: false
        )
        importedReferences.append(metadata.reference)

        XCTAssertFalse(metadata.requiresBiometry)
    }

    func testWrongPassphraseSurfacesTypedFriendlyError() async throws {
        do {
            _ = try await keyStore.importKey(
                fixtureData(Self.passphraseFixture),
                passphrase: Data("wrong-passphrase".utf8),
                label: "unit-wrong-pass",
                requiresBiometry: false
            )
            XCTFail("A wrong passphrase must not import")
        } catch let error as KeyStoreError {
            XCTAssertEqual(error, .wrongPassphrase)
            XCTAssertTrue(error.message.contains("passphrase"), "Message must stay user-facing")
        }
    }

    func testDSAHeaderFixtureIsRejectedByTypedPolicy() async throws {
        do {
            _ = try await keyStore.importKey(
                fixtureData(Self.dssHeaderFixture),
                passphrase: nil,
                label: "unit-dsa",
                requiresBiometry: false
            )
            XCTFail("DSA material must never import")
        } catch let error as KeyStoreError {
            XCTAssertEqual(error, .unsupportedKeyType("ssh-dss"))
            let persisted = try await repository.list()
            XCTAssertTrue(persisted.isEmpty, "No key may be created from DSA material")
        }
    }
}
