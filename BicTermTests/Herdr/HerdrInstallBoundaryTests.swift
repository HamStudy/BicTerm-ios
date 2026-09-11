import BicTermCore
import XCTest

@testable import BicTerm

/// Doc §11 boundary, enforced as a test: the app never ships, embeds, or
/// suggests an installation command for Herdr (or anything else) — not in
/// code, not in string literals, not in comments. Herdr is installed and
/// maintained on the host, outside the app; a missing/incompatible herdr is
/// a diagnostic screen plus a documentation link, permanently.
///
/// The scan covers every Swift source of the app and its local packages
/// (BicTerm, BicTermCore/Sources, HerdrClientCore); fixture scripts and
/// test sources are out of scope (fixtures run on the host side of tests,
/// test sources are not shipped).
final class HerdrInstallBoundaryTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let scannedRoots = [
        "BicTerm",
        "BicTermCore/Sources",
        "HerdrClientCore",
    ]

    /// Installation-command shapes and privilege elevation: any match is a
    /// boundary violation. `curl … | sh` covers the pipe-to-shell installer
    /// family including `bash`/`zsh` variants.
    private static let forbiddenPatterns: [(label: String, pattern: String)] = [
        ("apt install", #"\bapt(?:-get)?\s+install\b"#),
        ("brew install", #"\bbrew\s+(?:un)?install\b"#),
        ("pip install", #"\bpip3?\s+install\b"#),
        ("npm install", #"\bnpm\s+(?:un)?install\b"#),
        ("yum install", #"\byum\s+install\b"#),
        ("dnf install", #"\bdnf\s+install\b"#),
        ("zypper install", #"\bzypper\s+install\b"#),
        ("pacman install", #"\bpacman\s+-S\b"#),
        ("sudo", #"\bsudo\b"#),
        ("pipe-to-shell installer", #"\bcurl\b[^\n]*\|\s*(?:ba|z|s)?sh\b"#),
        ("update_install_command execution", #"\bupdate_install_command\b"#),
    ]

    func testNoInstallOrUpdateCommandAppearsAnywhereInAppSources() throws {
        var violations: [String] = []
        var scannedFiles = 0

        for root in Self.scannedRoots {
            let rootURL = Self.repoRoot.appendingPathComponent(root)
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                guard regular, url.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                scannedFiles += 1
                for (label, pattern) in Self.forbiddenPatterns {
                    guard let range = source.range(of: pattern, options: .regularExpression) else {
                        continue
                    }
                    let line = source[..<range.lowerBound].suffix(120)
                    violations.append(
                        "\(root)/\(url.lastPathComponent): \(label) → …\(line.trimmingCharacters(in: .whitespacesAndNewlines))"
                    )
                }
            }
        }

        XCTAssertGreaterThan(scannedFiles, 50, "the scan must actually reach the app sources")
        XCTAssertTrue(
            violations.isEmpty,
            "doc §11 violation — install/update commands in app sources:\n"
                + violations.joined(separator: "\n")
        )
    }

    /// The herdr-side helper that builds remote commands must keep routing
    /// through the single quoting routine — the probe's path search and the
    /// bridge command are the only remote commands the app ever runs, and
    /// neither may grow package-manager verbs.
    func testHerdrRemoteCommandVocabularyStaysProbeAndBridge() throws {
        let bridge = try HerdrCommandBuilder.bridgeCommand(
            executablePath: "/usr/local/bin/herdr", sessionName: nil
        )
        XCTAssertEqual(bridge, "exec '/usr/local/bin/herdr' remote-client-bridge")

        let probe = try HerdrProbe.command(
            searchPaths: ["/opt/homebrew/bin/herdr"]
        )
        XCTAssertFalse(probe.contains("install"))
        XCTAssertFalse(probe.contains("sudo"))
        XCTAssertTrue(probe.contains("status client --json"), "the probe's only herdr invocation is the read-only status query")
    }
}
