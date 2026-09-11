import BicTermCore
import Foundation
import NIOSSH

#if DEBUG
/// Walks UP from this source file until the directory containing the
/// committed `Fixtures/` tree is found (the repository root), bounded to
/// a few levels. `#filePath` is `/repo/BicTerm/Terminal/<file>.swift`,
/// so exactly three deletions are expected; the search keeps resolution
/// correct if the file moves.
enum FixturePaths {
    static let hop1HostKeyURL = repoRoot
        .appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub")

    static let fixtureEd25519KeyURL = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519")

    private static var repoRoot: URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Fixtures/sshd/host_keys/hop1_host_ed25519.pub").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        // Not found in this checkout; surface the bad path in the thrown
        // read error instead of guessing.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// Fixture-file backed authentication: loads the committed ed25519 key
/// (obviously fake, Fixtures/keys/) via the T3 parser.
struct FixtureFileKeyProvider: SSHAuthenticationKeyProvider {
    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        let parsed = try await OpenSSHPrivateKeyParser().parse(
            Data(contentsOf: FixturePaths.fixtureEd25519KeyURL)
        )
        return NIOSSHPrivateKey(ed25519Key: parsed.privateKey)
    }
}

/// Resolves an IMPORTED ed25519 key by its user-visible label via the same
/// Keychain service (`com.bicterm.keys.ed25519`) that `KeyStore` writes to.
/// Used by `TerminalPreviewController` when `-uitest-key-ref <label>` is set,
/// to prove end-to-end that a Keychain-IMPORTED key authenticates the real
/// fixture sshd (not just lists in the UI). Throws when the label is absent
/// so the controller lands in `.failed` — never silently falls back to
/// `FixtureFileKeyProvider` (that fallback would defeat the proof).
struct KeychainLabelKeyProvider: SSHAuthenticationKeyProvider {
    let label: String
    private let repository = KeychainKeyRepository()

    func authenticationPrivateKey(with reference: String, reason: String) async throws -> NIOSSHPrivateKey {
        let imports = try await repository.list()
        guard let match = imports.first(where: { $0.label == label }) else {
            throw KeyRepositoryError.keyNotFound
        }
        return try await repository.authenticationPrivateKey(with: match.reference, reason: reason)
    }
}

actor InMemoryOnlyHostKeyStore: HostKeyStoreProtocol {
    private var record: HostKeyRecord?

    func loadAll() throws(PersistenceError) -> [HostKeyRecord] {
        if let record { [record] } else { [] }
    }

    func lookup(host: String, port: Int) throws(PersistenceError) -> HostKeyRecord? {
        guard let record, record.host == host, record.port == port else { return nil }
        return record
    }

    func save(_ newRecord: HostKeyRecord) throws(PersistenceError) {
        record = newRecord
    }

    func forget(host: String, port: Int) throws(PersistenceError) {
        if record?.host == host, record?.port == port {
            record = nil
        }
    }
}
#endif
