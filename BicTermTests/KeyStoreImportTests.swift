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

    func testSetEnabledRoutesEd25519MetadataUpdate() async throws {
        let metadata = try await keyStore.importKey(
            fixtureData(Self.passphraseFixture),
            passphrase: Data("testpass".utf8),
            label: "unit-toggle-route",
            requiresBiometry: false
        )
        importedReferences.append(metadata.reference)

        try await keyStore.setEnabled(false, item: item(metadata))

        let persisted = try await repository.list()
        XCTAssertEqual(
            persisted.first { $0.reference == metadata.reference }?.enabledByDefault,
            false
        )
    }

    func testSetEnabledRoutesSecureEnclaveMetadataUpdate() async throws {
        let service = "com.bicterm.tests.keys.secure-toggle.\(UUID().uuidString)"
        let secureService = SecureEnclaveKeyService(keychainService: service)
        let store = KeyStore(repository: repository, secureEnclaveService: secureService)
        let metadata = KeyMetadata(
            reference: UUID().uuidString,
            label: "unit-secure-toggle-route",
            algorithm: .ecdsaP256,
            fingerprint: "SHA256:secure-route",
            publicKeyBlob: Data(repeating: 1, count: 65),
            requiresBiometry: true
        )
        try KeychainItemQuery.addItem(service: service, metadata: metadata)
        defer { try? KeychainItemQuery.deleteItem(service: service, reference: metadata.reference) }

        try await store.setEnabled(false, item: item(metadata))

        let persisted = try KeychainItemQuery.listItems(service: service)
        XCTAssertEqual(persisted.first?.metadata.enabledByDefault, false)
    }

    func testHopOnlyCustomKeysSelectionIsCounted() throws {
        let key = metadata(reference: "selected")
        let connection = try connection(
            destinationCustomKeys: nil,
            hops: [Hop(host: "hop", port: 22, username: "user", customKeys: [key.reference])]
        )

        XCTAssertEqual(
            keyStore.connectionsReferencing(item(key), in: [connection]).map(\.id),
            [connection.id]
        )
    }

    func testHopOnlyDefaultOfferIsCounted() throws {
        let key = metadata(reference: "default")
        let connection = try connection(
            destinationOffersKeys: false,
            hops: [Hop(host: "hop", port: 22, username: "user")]
        )

        XCTAssertEqual(defaultOfferIDs(for: key, connections: [connection]), [connection.id])
    }

    func testDuplicateDestinationAndHopReferencesCountParentOnce() throws {
        let key = metadata(reference: "duplicate")
        let custom = try connection(
            destinationCustomKeys: [key.reference],
            hops: [Hop(host: "hop", port: 22, username: "user", customKeys: [key.reference])]
        )
        let inherited = try connection(
            hops: [Hop(host: "hop", port: 22, username: "user")]
        )

        XCTAssertEqual(keyStore.connectionsReferencing(item(key), in: [custom]).count, 1)
        XCTAssertEqual(defaultOfferIDs(for: key, connections: [inherited]), [inherited.id])
    }

    func testDestinationKeysOffExcludedFromDefaultOfferCount() throws {
        let key = metadata(reference: "destination-off")
        let connection = try connection(destinationOffersKeys: false)

        XCTAssertTrue(defaultOfferIDs(for: key, connections: [connection]).isEmpty)
    }

    func testHopKeysOffExcludedFromDefaultOfferCount() throws {
        let key = metadata(reference: "hop-off")
        let connection = try connection(
            destinationOffersKeys: false,
            hops: [Hop(host: "hop", port: 22, username: "user", offersKeys: false)]
        )

        XCTAssertTrue(defaultOfferIDs(for: key, connections: [connection]).isEmpty)
    }

    func testDestinationCustomizedExcludedFromDefaultOfferCount() throws {
        let key = metadata(reference: "destination-custom")
        let connection = try connection(destinationCustomKeys: [key.reference])

        XCTAssertTrue(defaultOfferIDs(for: key, connections: [connection]).isEmpty)
    }

    func testHopCustomizedExcludedFromDefaultOfferCount() throws {
        let key = metadata(reference: "hop-custom")
        let connection = try connection(
            destinationOffersKeys: false,
            hops: [Hop(host: "hop", port: 22, username: "user", customKeys: [key.reference])]
        )

        XCTAssertTrue(defaultOfferIDs(for: key, connections: [connection]).isEmpty)
    }

    private func metadata(reference: String) -> KeyMetadata {
        KeyMetadata(
            reference: reference,
            label: reference,
            algorithm: .ed25519,
            fingerprint: "SHA256:\(reference)",
            publicKeyBlob: Data(reference.utf8),
            requiresBiometry: false
        )
    }

    private func item(_ metadata: KeyMetadata) -> KeyListItem {
        KeyListItem(metadata: metadata, createdDate: nil)
    }

    private func connection(
        destinationOffersKeys: Bool = true,
        destinationCustomKeys: [String]? = nil,
        hops: [Hop] = []
    ) throws -> Connection {
        try Connection(
            name: UUID().uuidString,
            type: .ssh,
            host: "destination",
            port: 22,
            username: "user",
            offersKeys: destinationOffersKeys,
            customKeys: destinationCustomKeys,
            jumpChain: hops
        )
    }

    private func defaultOfferIDs(
        for metadata: KeyMetadata,
        connections: [Connection],
        hardwareKeysEnabledByDefault: Bool = true
    ) -> [UUID] {
        keyStore.connectionsOfferingByDefault(
            item(metadata),
            hardwareKeysEnabledByDefault: hardwareKeysEnabledByDefault,
            in: connections,
            keys: [metadata]
        ).map(\.id)
    }
}
