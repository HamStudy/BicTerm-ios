import BicTermCore
import XCTest

@testable import BicTerm

/// Doc §11 boundary, revised for the deliberate install path (stage C):
/// the app never runs or suggests an ad-hoc installation command — no
/// privilege elevation, no package managers, no pipe-to-shell installers,
/// no destructive remote shapes — not in code, not in string literals,
/// not in comments. The ONE deliberate exception is the consent-gated
/// ``HerdrRemoteInstaller`` (stage A), which puts the pinned,
/// sha256-verified herdr release on a host the user already authenticated
/// to through its own prepare/tee/chmod 755/mv sequence. That sequence is
/// confined to the installer's own file, and the installer family is
/// reachable only from the connector's install-offering variants, its
/// binary-provider seam, the composition root, and the embed bring-up
/// path — never from probe, bridge, or SSH transport code. The probe
/// itself stays strictly read-only.
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

    /// The ONE file scanned with its comment lines stripped: the
    /// installer's own doc comments name the forbidden vocabulary to
    /// document what it does NOT do ("no sudo, no package managers, no
    /// `curl | sh` shape"). Stripping `//`-prefixed lines keeps its code
    /// and string literals fully covered while allowing that abstinence
    /// prose; every other file is scanned raw, comments included.
    private static let installerFileName = "HerdrRemoteInstaller.swift"

    /// Installation-command shapes and privilege elevation: any match is a
    /// boundary violation. `curl … | sh` covers the pipe-to-shell
    /// installer family including `wget`/`bash`/`zsh` variants.
    private static let forbiddenPatterns: [(label: String, pattern: String)] = [
        ("apt install", #"\bapt(?:-get)?\s+install\b"#),
        ("apk add", #"\bapk\s+add\b"#),
        ("brew install", #"\bbrew\s+(?:un)?install\b"#),
        ("pip install", #"\bpip3?\s+install\b"#),
        ("npm install", #"\bnpm\s+(?:un)?install\b"#),
        ("yum install", #"\byum\s+install\b"#),
        ("dnf install", #"\bdnf\s+install\b"#),
        ("zypper install", #"\bzypper\s+install\b"#),
        ("pacman install", #"\bpacman\s+-S\b"#),
        ("sudo", #"\bsudo\b"#),
        ("su", #"\bsu\b"#),
        ("doas", #"\bdoas\b"#),
        ("pipe-to-shell installer", #"\b(?:curl|wget)\b[^\n]*\|\s*(?:ba|z|s)?sh\b"#),
        ("rm -rf", #"\brm\s+-rf\b"#),
        ("update_install_command execution", #"\bupdate_install_command\b"#),
    ]

    /// The deliberate remote-install sequence's distinctive vocabulary
    /// (upstream attach.rs prepare/tee/chmod 755/mv model). It is expected
    /// in the installer's own file and NOWHERE else.
    private static let deliberateSequenceMarkers: [(label: String, pattern: String)] = [
        ("chmod 755 commit step", #"\bchmod\s+755\b"#),
        ("tee upload step", #"\btee\b"#),
        ("/bin/sh -s script channel", #"/bin/sh\s+-s\b"#),
    ]

    /// Files allowed to reference the installer family
    /// (`HerdrRemoteInstaller` / `HerdrRemoteInstallerError` /
    /// `HerdrRemoteInstallOutcome`) in code: the installer itself, its
    /// binary-provider seam, the connector's install-offering variants,
    /// the composition root, and the embed bring-up path that constructs
    /// the connector. Probe, bridge, SSH transport, and HerdrClientCore
    /// code must never name it. Exact set equality — a new reference or a
    /// stale entry both fail until this list is consciously amended.
    private static let installerReachabilityAllowlist: Set<String> = [
        "BicTermCore/Sources/BicTermCore/Herdr/HerdrRemoteInstaller.swift",
        "BicTermCore/Sources/BicTermCore/Herdr/HerdrBinaryProvider.swift",
        "BicTermCore/Sources/BicTermCore/Herdr/HerdrEndpointConnector.swift",
        "BicTerm/Connections/AppServices.swift",
        "BicTerm/Herdr/Embed/HerdrEmbedTransport.swift",
    ]

    /// Removes `//`-prefixed lines (doc comments included) so the
    /// installer's abstinence prose can name the forbidden vocabulary
    /// without exempting its code from the scan.
    private static func commentStripped(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func swiftSources(under root: String) throws -> [(relativePath: String, source: String)] {
        let rootURL = repoRoot.appendingPathComponent(root)
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [(relativePath: String, source: String)] = []
        while let url = enumerator?.nextObject() as? URL {
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard regular, url.pathExtension == "swift" else { continue }
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    func testNoInstallOrUpdateCommandAppearsAnywhereInAppSources() throws {
        var violations: [String] = []
        var scannedFiles = 0

        for root in Self.scannedRoots {
            for file in try Self.swiftSources(under: root) {
                scannedFiles += 1
                // The installer's own file is scanned with its comment
                // lines stripped (see `installerFileName`); everything
                // else is scanned raw, comments included.
                let source = file.relativePath.hasSuffix(Self.installerFileName)
                    ? Self.commentStripped(file.source)
                    : file.source
                for (label, pattern) in Self.forbiddenPatterns {
                    guard let range = source.range(of: pattern, options: .regularExpression) else {
                        continue
                    }
                    let line = source[..<range.lowerBound].suffix(120)
                    violations.append(
                        "\(file.relativePath): \(label) → …\(line.trimmingCharacters(in: .whitespacesAndNewlines))"
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

    /// The deliberate install path earns its vocabulary exemption: the
    /// prepare/tee/chmod 755 sequence must exist in the installer's own
    /// file, and its distinctive markers must appear NOWHERE else in the
    /// scanned sources — the sequence cannot be copied into a coordinator,
    /// the bridge, or any other component.
    func testDeliberateInstallSequenceIsConfinedToTheRemoteInstaller() throws {
        var strangerFiles: [String] = []
        var scannedFiles = 0

        for root in Self.scannedRoots {
            for file in try Self.swiftSources(under: root) {
                scannedFiles += 1
                let isInstallerFile = file.relativePath.hasSuffix(Self.installerFileName)
                for (label, pattern) in Self.deliberateSequenceMarkers {
                    let found = file.source.range(of: pattern, options: .regularExpression) != nil
                    if found && !isInstallerFile {
                        strangerFiles.append("\(file.relativePath): \(label)")
                    }
                    if isInstallerFile {
                        XCTAssertTrue(
                            found,
                            "the deliberate install sequence lost its '\(label)' — the installer file must keep the prepare/tee/chmod 755/mv shape"
                        )
                    }
                }
            }
        }

        XCTAssertGreaterThan(scannedFiles, 50, "the scan must actually reach the app sources")
        XCTAssertTrue(
            strangerFiles.isEmpty,
            "the deliberate install sequence appeared outside the installer:\n"
                + strangerFiles.joined(separator: "\n")
        )
    }

    /// Reachability discipline: the installer family is referenced in
    /// code only by the allowlist above. A new reference from probe,
    /// bridge, transport, or view code fails this test until the
    /// allowlist is deliberately amended; a dropped reference fails it
    /// too, so the list cannot rot into a rubber stamp.
    func testHerdrRemoteInstallerIsReachableOnlyFromTheInstallPath() throws {
        var referencingFiles: Set<String> = []

        for root in Self.scannedRoots {
            for file in try Self.swiftSources(under: root) {
                // Comment lines are stripped: doc mentions (e.g. the
                // probe's boundary note pointing at the installer) are
                // not code references.
                let code = Self.commentStripped(file.source)
                if code.contains("HerdrRemoteInstall") {
                    referencingFiles.insert(file.relativePath)
                }
            }
        }

        XCTAssertEqual(
            referencingFiles,
            Self.installerReachabilityAllowlist,
            "the HerdrRemoteInstaller family must be referenced in code only by: "
                + Self.installerReachabilityAllowlist.sorted().joined(separator: ", ")
                + " — actual referencing files: "
                + referencingFiles.sorted().joined(separator: ", ")
        )
    }

    /// The herdr-side helper that builds remote commands must keep routing
    /// through the single quoting routine — the probe's path search and
    /// the bridge command are read-only remote commands, and neither may
    /// grow install vocabulary (the installer's script sequence is the
    /// only other remote command the app runs, and it lives in its own
    /// file).
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

        for command in [bridge, probe] {
            for (label, pattern) in Self.forbiddenPatterns {
                XCTAssertNil(
                    command.range(of: pattern, options: .regularExpression),
                    "the remote command vocabulary grew a forbidden '\(label)' shape"
                )
            }
        }
    }
}
