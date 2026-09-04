import Foundation
import XCTest
@testable import BicTermCore

final class HostKeyVerifierTests: XCTestCase {
    private let host = "ssh.example.com"
    private let port = 22
    private let algorithm = "ssh-ed25519"
    private let firstSeenDate = Date(timeIntervalSince1970: 1_725_000_000)

    func testUnknownHostRequiresExplicitTrust() async throws {
        let store = InMemoryHostKeyStore()
        let expectedDate = firstSeenDate
        let verifier = HostKeyVerifier(store: store, now: { expectedDate })

        let verdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: algorithm
        )

        guard case let .requiresTrust(fingerprint, returnedAlgorithm, publicKeyData) = verdict else {
            return XCTFail("Unknown host key must require explicit trust")
        }
        XCTAssertEqual(fingerprint, fingerprintA)
        XCTAssertFalse(fingerprint.contains("="))
        XCTAssertEqual(returnedAlgorithm, algorithm)
        XCTAssertEqual(publicKeyData, keyA)

        let pendingRecord = try await store.lookup(host: host, port: port)
        XCTAssertEqual(pendingRecord?.trustState, .firstSeen)
        XCTAssertEqual(pendingRecord?.firstSeenDate, firstSeenDate)

        let repeatedVerdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: algorithm
        )
        guard case .requiresTrust = repeatedVerdict else {
            return XCTFail("A first-seen key must remain untrusted until trust() is called")
        }
    }

    func testExplicitlyTrustedMatchingKeyIsTrusted() async throws {
        let store = InMemoryHostKeyStore()
        let expectedDate = firstSeenDate
        let verifier = HostKeyVerifier(store: store, now: { expectedDate })
        _ = try await verifier.verify(host: host, port: port, key: keyA, algorithm: algorithm)

        try await verifier.trust(host: host, port: port, key: keyA, algorithm: algorithm)

        let verdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: algorithm
        )
        XCTAssertEqual(verdict, .trusted)
        let trustedRecord = try await store.lookup(host: host, port: port)
        XCTAssertEqual(trustedRecord?.trustState, .trusted)
        XCTAssertEqual(trustedRecord?.firstSeenDate, firstSeenDate)
    }

    func testChangedHostKeyIsRejected() async throws {
        let store = InMemoryHostKeyStore()
        let verifier = HostKeyVerifier(store: store)
        try await verifier.trust(host: host, port: port, key: keyA, algorithm: algorithm)

        let verdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyB,
            algorithm: algorithm
        )
        let expectedReason = HostKeyRejectionReason.hostKeyChanged(
            host: host,
            port: port,
            oldFingerprint: fingerprintA,
            newFingerprint: fingerprintB
        )
        guard case let .rejected(reason) = verdict else {
            return XCTFail("A changed host key must be rejected")
        }
        XCTAssertEqual(reason, expectedReason)
        XCTAssertTrue(reason.localizedDescription.contains(host))
        XCTAssertTrue(reason.localizedDescription.contains(String(port)))
        XCTAssertTrue(reason.localizedDescription.contains(fingerprintA))
        XCTAssertTrue(reason.localizedDescription.contains(fingerprintB))
        print("changed-key-rejection: \(reason.localizedDescription)")
    }

    func testDifferentPortRequiresSeparateTrust() async throws {
        let store = InMemoryHostKeyStore()
        let verifier = HostKeyVerifier(store: store)
        try await verifier.trust(host: host, port: port, key: keyA, algorithm: algorithm)

        let alternatePortVerdict = try await verifier.verify(
            host: host,
            port: 2222,
            key: keyA,
            algorithm: algorithm
        )

        guard case .requiresTrust = alternatePortVerdict else {
            return XCTFail("The same host on a different port must require separate trust")
        }
        let standardPortVerdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: algorithm
        )
        XCTAssertEqual(standardPortVerdict, .trusted)
    }

    func testAlgorithmMismatchIsRejected() async throws {
        let store = InMemoryHostKeyStore()
        let verifier = HostKeyVerifier(store: store)
        try await verifier.trust(host: host, port: port, key: keyA, algorithm: algorithm)

        let verdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: "ecdsa-sha2-nistp256"
        )

        XCTAssertEqual(
            verdict,
            .rejected(
                .hostKeyChanged(
                    host: host,
                    port: port,
                    oldFingerprint: fingerprintA,
                    newFingerprint: fingerprintA
                )
            )
        )
    }

    func testChangedKeyCannotReplaceTrustedRecord() async throws {
        let store = InMemoryHostKeyStore()
        let verifier = HostKeyVerifier(store: store)
        try await verifier.trust(host: host, port: port, key: keyA, algorithm: algorithm)
        let expectedReason = HostKeyRejectionReason.hostKeyChanged(
            host: host,
            port: port,
            oldFingerprint: fingerprintA,
            newFingerprint: fingerprintB
        )

        do {
            try await verifier.trust(host: host, port: port, key: keyB, algorithm: algorithm)
            XCTFail("trust() must not replace a changed host key")
        } catch let error as HostKeyTrustError {
            XCTAssertEqual(error, .rejected(expectedReason))
        }

        let storedRecord = try await store.lookup(host: host, port: port)
        XCTAssertEqual(storedRecord?.publicKeyData, keyA)
        XCTAssertEqual(storedRecord?.trustState, .trusted)
        let changedVerdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyB,
            algorithm: algorithm
        )
        XCTAssertEqual(changedVerdict, .rejected(expectedReason))
    }

    func testSwiftDataStorePersistsExplicitTrust() async throws {
        let store = try PersistenceStoreFactory.makeHostKeyStore(inMemoryOnly: true)
        let verifier = HostKeyVerifier(store: store)

        let initialVerdict = try await verifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: algorithm
        )
        guard case .requiresTrust = initialVerdict else {
            return XCTFail("The real store must preserve the first-seen flow")
        }
        let pendingRecord = try await store.lookup(host: host, port: port)
        XCTAssertEqual(pendingRecord?.trustState, .firstSeen)

        try await verifier.trust(host: host, port: port, key: keyA, algorithm: algorithm)
        let reloadedVerifier = HostKeyVerifier(store: store)

        let persistedVerdict = try await reloadedVerifier.verify(
            host: host,
            port: port,
            key: keyA,
            algorithm: algorithm
        )
        XCTAssertEqual(persistedVerdict, .trusted)
    }

    func testTrustSourceHasNoBypass() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let trustDirectory = packageRoot.appendingPathComponent("Sources/BicTermCore/Trust")
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: trustDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let source = try sourceURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        let bypassPattern = try NSRegularExpression(
            pattern: #"(?i)\b(?:acceptAnyway|force|trustAlways|allowUnknown)\b"#
        )
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        XCTAssertEqual(bypassPattern.numberOfMatches(in: source, range: sourceRange), 0)

        let publicTrustPattern = try NSRegularExpression(
            pattern: #"(?m)^\s*public\s+func\s+trust\s*\("#
        )
        XCTAssertEqual(publicTrustPattern.numberOfMatches(in: source, range: sourceRange), 1)
        print("bypass-audit: PASS; public-trust-function-count=1; forbidden-patterns-absent")
    }

    private var keyA: Data {
        Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIHFcpLR7cwsdJb3tgRBocxaGvMmTqB8kO8H9GF+h4EUX"
        )!
    }

    private var keyB: Data {
        Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIANfEz2hpfIm10JT8FPYm5OiSKwVyGdu622i9UkwyoHk"
        )!
    }

    private var fingerprintA: String {
        "SHA256:+r0XE2pE/ZCcOeGWrisHbWLLrEFKapNtuqH9LUZ7QqU"
    }

    private var fingerprintB: String {
        "SHA256:R9XaxtlJKgrJE0AbFdKibF9+X1cPt0yWTzvTWUvh1r4"
    }
}

private actor InMemoryHostKeyStore: HostKeyStoreProtocol {
    private var records: [HostKeyIdentity: HostKeyRecord] = [:]

    func loadAll() async throws(PersistenceError) -> [HostKeyRecord] {
        Array(records.values)
    }

    func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord? {
        records[HostKeyIdentity(host: host, port: port)]
    }

    func save(_ record: HostKeyRecord) async throws(PersistenceError) {
        records[record.identity] = record
    }
}
