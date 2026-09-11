import XCTest

@testable import BicTerm

/// T20 log-redaction audit (integration doc §15 "Clipboard/terminal
/// content never appears in logs"): scans every app-target source file for
/// logging calls (`print`, `NSLog`, `os_log`, `Logger` methods) whose line
/// also names secret-bearing content. The rule is REMOVE the log, never
/// redact it — a line that fails this audit is a bug, not a finding to
/// annotate around.
///
/// The audit covers shipped targets (BicTerm app, BicTermCore sources,
/// HerdrClientCore) — not test bundles, whose fixtures and echoes are
/// process-local DEBUG state rather than device logs.
final class LogRedactionAuditTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let scannedDirectories = [
        "BicTerm",
        "BicTermCore/Sources/BicTermCore",
        "HerdrClientCore",
    ]

    private static let loggingCallPattern =
        try! NSRegularExpression(
            pattern: #"(print\(|NSLog\(|os_log\(|logger\.(info|debug|warning|error|notice|trace|log)\(|log\.(info|debug|warning|error|notice|trace|log)\()"#
        )

    private static let secretContentPattern =
        try! NSRegularExpression(
            pattern: #"password|passwd|passphrase|\btoken\b|secret|credential|clipboard|pasteboard|hostkey|private.?key|terminal content|pane content|cell content|osc52|frame bytes"#,
            options: [.caseInsensitive]
        )

    func testAppSourcesNeverLogSecretBearingContent() throws {
        let violations = try Self.scan()
        XCTAssertTrue(
            violations.isEmpty,
            "logging calls that name secret-bearing content must be removed, not redacted:\n"
                + violations.joined(separator: "\n")
        )
    }

    private static func scan() throws -> [String] {
        var violations: [String] = []
        let fm = FileManager.default
        for directory in scannedDirectories {
            guard let walker = fm.enumerator(at: repoRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let contents = try String(contentsOf: url, encoding: .utf8)
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    let text = String(line)
                    let range = NSRange(text.startIndex..., in: text)
                    guard loggingCallPattern.firstMatch(in: text, range: range) != nil else { continue }
                    guard secretContentPattern.firstMatch(in: text, range: range) != nil else { continue }
                    violations.append("\(url.path):\(index + 1): \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return violations
    }
}
