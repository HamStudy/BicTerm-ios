import BicTermCore
import CryptoKit
import LocalAuthentication
import NIOSSH
import Security
import XCTest

@testable import BicTerm

/// Investigation experiment (TEST-ONLY, no production changes): the
/// device-only herd establish race (fixed by a844adf's sequential
/// `establishAll`) is hypothesized to be two concurrent NIOSSH handshakes
/// signing through ONE shared resolved Secure Enclave key instance / ONE
/// LAContext — KeyResolutionCache coalesces the key READ, but the SIGN
/// happens per-connection inside the handshake. The SPM core bundle
/// cannot exercise SE keys (no Data Protection Keychain entitlement —
/// SecureEnclaveKeyTests skips there), but this app-hosted bundle
/// inherits the app's entitlements, so the emulated simulator SE may be
/// exercisable here for the first time.
///
/// Shape under test (the pre-a844adf concurrent bring-up): TWO
/// `HerdrEndpointConnector.establishProbed` calls fired concurrently, one
/// per fixture sshd (12222/12223), both authenticating through ONE
/// resolved `NIOSSHPrivateKey` instance wrapping the SE key + its
/// LAContext — exactly what KeyResolutionCache handed every machine.
///
/// GATED: every test skips with a precise message when this environment
/// cannot run it (no emulated SE, no DP-keychain entitlement, no enrolled
/// biometry, fixtures down). On a physical device the fixture-dependent
/// tests skip (no repo checkout) while the SE gate test runs for real.
@MainActor
final class HerdrSecureEnclaveConcurrentEstablishTests: XCTestCase {
    /// Repository root via this file's path — the app-hosted test
    /// convention (sibling Herdr tests) for repo-local fixture paths.
    private nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Deterministic probe stand-in (T19 shim): the probe's
    /// `status client --json` query answers with a fixed compatible
    /// client status, so establishProbed succeeds without the fetched
    /// herdr server binary.
    private nonisolated static let probeShimPath = repoRoot
        .appendingPathComponent("Fixtures/herdr/fake-herdr-status").path

    private static let iterations = 20

    private var scratch: URL!
    private var cwdBefore: String!
    private var savedStateHome: String?

    override func setUp() async throws {
        try await super.setUp()
        cwdBefore = FileManager.default.currentDirectoryPath
        savedStateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        // Repo-local scratch on the simulator host (containment rule); on
        // a physical device the build-machine path does not exist, so the
        // scratch falls back to the app container's own tmp.
        let scratchBase: URL
        if FileManager.default.fileExists(atPath: Self.repoRoot.path) {
            scratchBase = Self.repoRoot
                .appendingPathComponent(
                    "Fixtures/run/herdr-se-concurrent-establish-tests", isDirectory: true
                )
        } else {
            scratchBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("herdr-se-concurrent-establish-tests", isDirectory: true)
        }
        scratch = scratchBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { [scratch] in
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    override func tearDown() async throws {
        // Process-global state (cwd, env) must not leak into sibling tests.
        chdir(cwdBefore)
        restoreEnv("XDG_STATE_HOME", value: savedStateHome)
        try await super.tearDown()
    }

    // MARK: - Experiment step 1: the gate

    /// Can THIS bundle generate + sign with a real Secure Enclave P-256
    /// key through BicTermCore's SecureEnclaveKeyService? The SPM core
    /// bundle cannot (no Data Protection Keychain entitlement); the
    /// app-hosted bundle inherits the app's entitlements. A green run
    /// here unlocks every other test in this class; a skip names the
    /// exact blocker.
    func testSecureEnclaveGenerateAndSignInAppHostedBundle() async throws {
        let service = try requireSecureEnclaveKeychain()
        let metadata = try await service.generate(
            label: "SE app-hosted gate",
            requiresBiometry: false
        )
        let message = Data("se-app-hosted-gate".utf8)
        let signature = try await service.sign(
            data: message,
            with: metadata.reference,
            reason: "Gate: sign with a Secure Enclave key"
        )
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: SSHWireFormat.ecdsaP256RawPublicKey(from: metadata.publicKeyBlob)
        )
        XCTAssertTrue(
            publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: signature.rawRepresentation),
                for: message
            ),
            "the Secure Enclave signature verifies against the generated public key"
        )
    }

    // MARK: - Experiment step 2c: the pre-fix concurrent shape

    /// The exact pre-a844adf concurrent shape with a REAL (emulated) SE
    /// key: two concurrent establishes, one per fixture port, both
    /// signing through ONE shared resolved key instance (one LAContext).
    /// Any failure dumps the full SSHEstablishDiagnostics chain — the
    /// device bug collapsed to `.channelDenied` with the real error
    /// swallowed, so the capture is the whole point.
    func testTwoConcurrentEstablishesSharingOneSecureEnclaveKeyLooped() async throws {
        let context = try await makeSecureEnclaveFixtureContext(biometric: false)
        let provider = SharedResolvedKeyProvider(key: context.resolvedKey)
        let metadataProvider = SingleKeyMetadataProvider(metadata: context.metadata)
        let machineA = try Connection(
            name: "se-race-a",
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            customKeys: [context.metadata.reference]
        )
        let machineB = try Connection(
            name: "se-race-b",
            type: .ssh,
            host: "127.0.0.1",
            port: 12223,
            username: Self.fixtureUsername,
            customKeys: [context.metadata.reference]
        )

        for iteration in 0..<Self.iterations {
            SSHEstablishDiagnostics.shared.removeAll()
            let connectorA = makeConnector(context: context, provider: provider, metadataProvider: metadataProvider)
            let connectorB = makeConnector(context: context, provider: provider, metadataProvider: metadataProvider)

            async let probedA = connectorA.establishProbed(machineA)
            async let probedB = connectorB.establishProbed(machineB)

            do {
                let probedA = try await probedA
                let probedB = try await probedB
                let carrierA = try await probedA.carrierFactory()
                let carrierB = try await probedB.carrierFactory()
                await carrierA.close()
                await carrierB.close()
            } catch {
                let diagnostics = SSHEstablishDiagnostics.shared.snapshot()
                XCTFail(
                    "iteration \(iteration): concurrent SE establish failed: "
                        + "\(String(reflecting: error))\n"
                        + "establishDiagnostics:\n"
                        + (diagnostics.isEmpty
                            ? "(nothing captured)" : diagnostics.joined(separator: "\n"))
                )
                return
            }
        }
    }

    // MARK: - Experiment step 3 (Branch A proof / permanent regression)

    /// The SAME two-machine SE scenario through the production bring-up
    /// (`HerdrEmbedTransportCoordinator.prepare()`, sequential
    /// post-a844adf, ONE shared resolved SE key instance via
    /// KeyResolutionCache): BOTH machines must establish and bridge. Green
    /// here next to a red concurrent loop is the local proof that the
    /// sequential fix kills the race; green next to a green loop is the
    /// entitlement-gated regression net for future device triage.
    func testSequentialPrepareWithSecureEnclaveKeyBringsBothMachinesUp() async throws {
        let context = try await makeSecureEnclaveFixtureContext(biometric: false)
        let provider = SharedResolvedKeyProvider(key: context.resolvedKey)
        let linkA = try makeLink(label: "se-a", port: 12222, reference: context.metadata.reference)
        let linkB = try makeLink(label: "se-b", port: 12223, reference: context.metadata.reference)
        let coordinator = HerdrEmbedTransportCoordinator(
            machines: [linkA, linkB],
            preferredSelection: nil,
            hostKeyVerifier: context.verifier,
            authenticationKeyProvider: { provider },
            metadataProvider: SingleKeyMetadataProvider(metadata: context.metadata),
            searchPaths: [Self.probeShimPath]
        )
        coordinator.homeDirectoryForTesting = scratch.path
        SSHEstablishDiagnostics.shared.removeAll()

        do {
            _ = try await coordinator.prepare()
        } catch {
            let diagnostics = SSHEstablishDiagnostics.shared.snapshot()
            XCTFail(
                "sequential prepare failed: \(error)\n"
                    + "eventLines:\n\(coordinator.eventLines.joined(separator: "\n"))\n"
                    + "establishDiagnostics:\n"
                    + (diagnostics.isEmpty
                        ? "(nothing captured)" : diagnostics.joined(separator: "\n"))
            )
            await coordinator.teardown()
            return
        }

        let failures = coordinator.eventLines.filter { $0.contains("bring-up failed") }
        XCTAssertTrue(
            failures.isEmpty,
            "no machine may fail under the sequential establish: \(coordinator.eventLines)"
        )
        for link in [linkA, linkB] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: socketFile(for: link, coordinator: coordinator).path
                ),
                "machine \(link.machine.label)'s bridge socket was bound"
            )
        }

        await coordinator.teardown()
    }

    // MARK: - Experiment step 2d: the LAContext single-use probe

    /// Cheap variant probing the LAContext single-use hypothesis: a
    /// BIOMETRY-protected SE key (simulator Face ID) resolved ONCE, then
    /// the same concurrent two-establish loop signing through it. On
    /// device the second concurrent evaluation is the hypothesized loser;
    /// the simulator's emulated SE may be lenient — either outcome is
    /// evidence.
    func testBiometricSecureEnclaveKeyTwoConcurrentEstablishesLooped() async throws {
        let context = try await makeSecureEnclaveFixtureContext(biometric: true)
        let provider = SharedResolvedKeyProvider(key: context.resolvedKey)
        let metadataProvider = SingleKeyMetadataProvider(metadata: context.metadata)
        let machineA = try Connection(
            name: "se-bio-race-a",
            type: .ssh,
            host: "127.0.0.1",
            port: 12222,
            username: Self.fixtureUsername,
            customKeys: [context.metadata.reference]
        )
        let machineB = try Connection(
            name: "se-bio-race-b",
            type: .ssh,
            host: "127.0.0.1",
            port: 12223,
            username: Self.fixtureUsername,
            customKeys: [context.metadata.reference]
        )

        for iteration in 0..<Self.iterations {
            SSHEstablishDiagnostics.shared.removeAll()
            let connectorA = makeConnector(context: context, provider: provider, metadataProvider: metadataProvider)
            let connectorB = makeConnector(context: context, provider: provider, metadataProvider: metadataProvider)

            async let probedA = connectorA.establishProbed(machineA)
            async let probedB = connectorB.establishProbed(machineB)

            do {
                let probedA = try await probedA
                let probedB = try await probedB
                let carrierA = try await probedA.carrierFactory()
                let carrierB = try await probedB.carrierFactory()
                await carrierA.close()
                await carrierB.close()
            } catch {
                let diagnostics = SSHEstablishDiagnostics.shared.snapshot()
                XCTFail(
                    "iteration \(iteration): concurrent BIOMETRIC SE establish failed: "
                        + "\(String(reflecting: error))\n"
                        + "establishDiagnostics:\n"
                        + (diagnostics.isEmpty
                            ? "(nothing captured)" : diagnostics.joined(separator: "\n"))
                )
                return
            }
        }
    }

    // MARK: - Setup helpers

    private struct SEFixtureContext {
        let metadata: KeyMetadata
        let resolvedKey: NIOSSHPrivateKey
        let verifier: HostKeyVerifier
    }

    /// Gates + one SE key + fixture enrollment + ONE resolved key
    /// instance + a verifier trusting both fixture host keys.
    private func makeSecureEnclaveFixtureContext(biometric: Bool) async throws -> SEFixtureContext {
        try requireFixtures()
        let service = try requireSecureEnclaveKeychain()
        if biometric {
            let context = LAContext()
            var evaluationError: NSError?
            try XCTSkipUnless(
                context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError),
                "no biometry enrolled in this simulator — the LAContext single-use variant "
                    + "cannot run (enroll with: xcrun simctl biometry <udid> enroll)"
            )
        }
        let metadata = try await service.generate(
            label: biometric ? "SE biometric concurrent repro" : "SE concurrent repro",
            requiresBiometry: biometric
        )
        try enrollSEPublicKey(metadata)
        // The KeyResolutionCache shape: the key resolves ONCE; every
        // machine signs through this ONE instance (one LAContext) for the
        // whole bring-up.
        let resolvedKey = try await service.authenticationPrivateKey(
            with: metadata.reference,
            reason: "herd establish race repro"
        )
        let verifier = try await makeTrustedVerifier()
        return SEFixtureContext(metadata: metadata, resolvedKey: resolvedKey, verifier: verifier)
    }

    /// The experiment's first gate: SE key storage needs the Data
    /// Protection Keychain. The SPM core bundle lacks the entitlement
    /// (SecureEnclaveKeyTests skips there); this app-hosted bundle
    /// inherits the app's entitlements. Skips with the precise blocker
    /// when the sandbox refuses.
    private func requireSecureEnclaveKeychain() throws -> SecureEnclaveKeyService {
        try XCTSkipUnless(
            SecureEnclave.isAvailable,
            "SecureEnclave.isAvailable == false in this environment"
        )
        let service = "com.bicterm.tests.se-race.\(UUID().uuidString)"
        let preflight: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "preflight",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data("preflight".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(preflight as CFDictionary, nil)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
        if status == errSecMissingEntitlement {
            throw XCTSkip(
                "app-hosted simulator test bundle lacks the Data Protection Keychain entitlement "
                    + "(SecItemAdd returned errSecMissingEntitlement) — Secure Enclave key storage "
                    + "cannot run here; SE paths stay device-only"
            )
        }
        guard status == errSecSuccess else {
            throw KeyRepositoryError.keychain(status)
        }
        let keyService = SecureEnclaveKeyService(keychainService: service)
        addTeardownBlock { [service] in
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
        return keyService
    }

    private func requireFixtures() throws {
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.repoRoot.appendingPathComponent("Fixtures/sshd/hop1_config").path),
            "fixture checkout not present (physical device run) — fixture-dependent SE tests are simulator-host only"
        )
        try XCTSkipUnless(
            fm.fileExists(atPath: Self.repoRoot.appendingPathComponent("Fixtures/run/hop1.pid").path)
                && fm.fileExists(atPath: Self.repoRoot.appendingPathComponent("Fixtures/run/hop2.pid").path),
            "fixture sshds not running — run scripts/fixtures-up.sh first"
        )
    }

    /// Appends the SE public key to BOTH fixture authorized_keys files
    /// (sshd re-reads them per auth — no restart needed). Registers a
    /// teardown restoring the pre-enrollment bytes exactly.
    private func enrollSEPublicKey(_ metadata: KeyMetadata) throws {
        let line = "\(metadata.algorithm.rawValue) "
            + "\(metadata.publicKeyBlob.base64EncodedString()) bicterm-se-race-test\n"
        for name in ["authorized_keys_hop1", "authorized_keys_hop2"] {
            let url = Self.repoRoot.appendingPathComponent("Fixtures/sshd/\(name)")
            let original = try String(contentsOf: url, encoding: .utf8)
            if original.contains(metadata.publicKeyBlob.base64EncodedString()) { continue }
            try (original + line).write(to: url, atomically: true, encoding: .utf8)
            addTeardownBlock { [original] in
                try? original.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Pre-trusts BOTH fixture endpoints (127.0.0.1:12222/12223) so no
    /// establish prompts (the approval closure declines, mirroring the
    /// core concurrent test).
    private func makeTrustedVerifier() async throws -> HostKeyVerifier {
        let verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        for (port, hostKeyFile) in [(12222, "hop1_host_ed25519.pub"), (12223, "hop2_host_ed25519.pub")] {
            let line = try String(
                contentsOf: Self.repoRoot.appendingPathComponent("Fixtures/sshd/host_keys/\(hostKeyFile)"),
                encoding: .utf8
            )
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
                throw NSError(domain: "HerdrSecureEnclaveConcurrentEstablishTests", code: 1)
            }
            try await verifier.trust(host: "127.0.0.1", port: port, key: blob, algorithm: String(parts[0]))
        }
        return verifier
    }

    private func makeConnector(
        context: SEFixtureContext,
        provider: SharedResolvedKeyProvider,
        metadataProvider: SingleKeyMetadataProvider
    ) -> HerdrEndpointConnector {
        HerdrEndpointConnector(
            hostKeyVerifier: context.verifier,
            authenticationKeyProvider: provider,
            metadataProvider: metadataProvider,
            searchPaths: [Self.probeShimPath],
            approveHostKey: { _ in false }
        )
    }

    private func makeLink(label: String, port: Int, reference: String) throws -> HerdrEmbedMachineLink {
        let connection = try Connection(
            name: label,
            type: .ssh,
            host: "127.0.0.1",
            port: port,
            username: Self.fixtureUsername,
            customKeys: [reference]
        )
        return HerdrEmbedMachineLink(
            machine: HerdrEmbedMachine.forConnection(connection),
            connection: connection,
            bridgeSessionName: connection.herdrSessionName
        )
    }

    private func socketFile(
        for link: HerdrEmbedMachineLink,
        coordinator: HerdrEmbedTransportCoordinator
    ) -> URL {
        scratch.appendingPathComponent(coordinator.socketPath(for: link.machine))
    }

    private func restoreEnv(_ name: String, value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    private nonisolated static var fixtureUsername: String {
        for candidate in [
            ProcessInfo.processInfo.environment["USER"],
            ProcessInfo.processInfo.environment["LOGNAME"],
            NSUserName(),
        ] where candidate != nil && !candidate!.isEmpty {
            return candidate!
        }
        return "richard"
    }
}

/// The KeyResolutionCache shape: one resolved `NIOSSHPrivateKey` instance
/// handed to every connection. The resolved instance wraps the SE key and
/// its LAContext; the SIGN happens per-connection inside the handshake.
private struct SharedResolvedKeyProvider: SSHAuthenticationKeyProvider {
    let key: NIOSSHPrivateKey

    func authenticationPrivateKey(
        with reference: String,
        reason: String
    ) async throws -> NIOSSHPrivateKey {
        key
    }
}

/// Pool-model seam listing exactly the generated SE key so the
/// connection's `customKeys` offer resolves to it.
private struct SingleKeyMetadataProvider: SSHKeyMetadataProviding {
    let metadata: KeyMetadata

    func availableKeys() async throws -> [KeyMetadata] { [metadata] }
}
