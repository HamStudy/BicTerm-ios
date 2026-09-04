import Foundation
import XCTest

final class ExtensionGuideIntegrityTests: XCTestCase {
    func testEveryBacktickedSymbolAndLocalLinkResolves() throws {
        let root = SSHTestFixture.repoRoot
        let guideURL = root.appendingPathComponent("Docs/ADDING-A-PROTOCOL.md")
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        let prose = removingFencedCode(from: guide)
        let swiftCorpus = try [
            root.appendingPathComponent("BicTermCore/Sources/BicTermCore"),
            root.appendingPathComponent("BicTermCore/Tests/BicTermCoreTests"),
        ].map(loadSwiftCorpus).joined(separator: "\n")

        let references = matches(
            pattern: #"(?<!`)`([^`\n]+)`(?!`)"#,
            in: prose,
            captureGroup: 1
        )
        XCTAssertFalse(references.isEmpty, "the guide must contain checked symbol references")

        let identifierPattern = try NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
        let unresolved = Set(references).filter { reference in
            let identifiers = identifierPattern.matches(
                in: reference,
                range: NSRange(reference.startIndex..., in: reference)
            ).compactMap { match -> String? in
                guard let range = Range(match.range, in: reference) else { return nil }
                return String(reference[range])
            }
            return identifiers.contains { identifier in
                swiftCorpus.range(
                    of: #"\b\#(NSRegularExpression.escapedPattern(for: identifier))\b"#,
                    options: .regularExpression
                ) == nil
            }
        }.sorted()
        XCTAssertTrue(
            unresolved.isEmpty,
            "backticked guide references missing from BicTermCore Swift sources: \(unresolved)"
        )

        let localLinks = matches(
            pattern: #"\[[^\]]+\]\((?!https?://)([^)#]+)(?:#[^)]+)?\)"#,
            in: guide,
            captureGroup: 1
        )
        XCTAssertFalse(localLinks.isEmpty, "the guide must link to the real implementation files")
        let missingLinks = Set(localLinks).filter { link in
            let destination = URL(fileURLWithPath: link, relativeTo: guideURL.deletingLastPathComponent())
                .standardizedFileURL
            return !FileManager.default.fileExists(atPath: destination.path)
        }.sorted()
        XCTAssertTrue(missingLinks.isEmpty, "guide links missing from the checkout: \(missingLinks)")
    }

    private func removingFencedCode(from markdown: String) -> String {
        var insideFence = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Substring? in
                if line.hasPrefix("```") {
                    insideFence.toggle()
                    return nil
                }
                return insideFence ? nil : line
            }
            .joined(separator: "\n")
    }

    private func loadSwiftCorpus(at root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            XCTFail("could not enumerate BicTermCore sources")
            return ""
        }

        var corpus = ""
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            corpus += try String(contentsOf: fileURL, encoding: .utf8)
            corpus.append("\n")
        }
        return corpus
    }

    private func matches(
        pattern: String,
        in text: String,
        captureGroup: Int
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("invalid integrity-check regex: \(pattern)")
            return []
        }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard
                match.numberOfRanges > captureGroup,
                let range = Range(match.range(at: captureGroup), in: text)
            else { return nil }
            return String(text[range])
        }
    }
}
