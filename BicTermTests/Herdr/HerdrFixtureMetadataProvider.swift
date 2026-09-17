import BicTermCore
import Foundation

/// Pool-model test seam for the fixture ed25519 key: the app-hosted test
/// process has no Keychain entries, so the default metadata provider
/// resolves an EMPTY offer pool and fixture auth fails before any packet
/// matters. Lists the fixture key reference the fixture connections
/// (`customKeys: ["fixture-ed25519"]`) offer; the companion per-suite key
/// providers resolve the reference to the parsed fixture key bytes.
struct FixtureHerdrKeyMetadataProvider: SSHKeyMetadataProviding {
    func availableKeys() async throws -> [KeyMetadata] {
        [
            KeyMetadata(
                reference: "fixture-ed25519",
                label: "fixture-ed25519",
                algorithm: .ed25519,
                fingerprint: "fixture",
                publicKeyBlob: Data(),
                requiresBiometry: false
            )
        ]
    }
}
