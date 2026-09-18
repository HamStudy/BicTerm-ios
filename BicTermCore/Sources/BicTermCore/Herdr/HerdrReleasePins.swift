import CryptoKit
import Foundation

/// The herdr release this app pins for remote installation, recorded as
/// compile-time constants (BicTermCore is SPM — constants, not bundle
/// resources).
///
/// Source of truth: the `0.9.0` entry of the `releases` map in
/// <https://herdr.dev/latest.json> — upstream's stable update manifest
/// (`STABLE_UPDATE_MANIFEST_URL`, remote/attach.rs) — fetched once at pin
/// time. The macos-aarch64 pin is byte-identical to the committed fixture
/// lockfile `Fixtures/herdr/server-0.9.0.sha256` (same artifact family), so
/// the offline fixture round-trip installs exactly the pinned bytes.
///
/// Bumping the pin is a deliberate, reviewed act: update `version`, the
/// four asset entries, and the fixture lockfile together.
public enum HerdrReleasePins {
    /// Pinned herdr version (no `v` prefix — the manifest's map key).
    public static let version = "0.9.0"

    /// One pinned release asset: download URL + SHA-256 (lowercase hex).
    public struct Asset: Sendable, Equatable {
        public let url: String
        public let sha256: String

        init(url: String, sha256: String) {
            self.url = url
            self.sha256 = sha256
        }
    }

    /// Upstream release asset keys (`<os>-<arch>` in the manifest).
    public enum Target: String, Sendable, CaseIterable, Equatable {
        case linuxX86_64 = "linux-x86_64"
        case linuxAarch64 = "linux-aarch64"
        case macosX86_64 = "macos-x86_64"
        case macosAarch64 = "macos-aarch64"
    }

    /// The four v0.9.0 release pins (URL + sha256 per target).
    public static func asset(for target: Target) -> Asset {
        switch target {
        case .linuxX86_64:
            Asset(
                url: "https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-linux-x86_64",
                sha256: "4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f"
            )
        case .linuxAarch64:
            Asset(
                url: "https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-linux-aarch64",
                sha256: "9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2"
            )
        case .macosX86_64:
            Asset(
                url: "https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-macos-x86_64",
                sha256: "d0c920b2a126a74809fa1491411c9a097a44786cac9c2ca51b818a995581cf16"
            )
        case .macosAarch64:
            Asset(
                url: "https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-macos-aarch64",
                sha256: "32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17"
            )
        }
    }

    /// Maps ``HerdrProbe``'s normalized platform pair (`linux`/`macos` ×
    /// `x86_64`/`aarch64`) onto a release target; nil when the pair is not
    /// in the pinned table — callers fail closed, never guess.
    public static func target(os: String, arch: String) -> Target? {
        switch (os, arch) {
        case ("linux", "x86_64"): .linuxX86_64
        case ("linux", "aarch64"): .linuxAarch64
        case ("macos", "x86_64"): .macosX86_64
        case ("macos", "aarch64"): .macosAarch64
        default: nil
        }
    }

    /// Lowercase hex SHA-256 digest — the one checksum spelling used by the
    /// pins, the upstream manifest, and the fixture lockfile.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }
}
