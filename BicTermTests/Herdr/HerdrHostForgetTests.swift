import BicTermCore
import XCTest

@testable import BicTerm

/// T20 per-host forget: one host's local remnants clear while the
/// connection entry, shared credentials, and other hosts' state survive.
@MainActor
final class HerdrHostForgetTests: XCTestCase {
    private final class MemoryHostKeyStore: HostKeyStoreProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: HostKeyRecord] = [:]

        func loadAll() throws(PersistenceError) -> [HostKeyRecord] {
            lock.lock()
            defer { lock.unlock() }
            return Array(records.values)
        }

        func lookup(host: String, port: Int) throws(PersistenceError) -> HostKeyRecord? {
            lock.lock()
            defer { lock.unlock() }
            return records["\(host):\(port)"]
        }

        func save(_ record: HostKeyRecord) throws(PersistenceError) {
            lock.lock()
            defer { lock.unlock() }
            records["\(record.host):\(record.port)"] = record
        }

        func forget(host: String, port: Int) throws(PersistenceError) {
            lock.lock()
            defer { lock.unlock() }
            records["\(host):\(port)"] = nil
        }
    }

    private final class MemoryPasswordStore: PasswordStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: String] = [:]

        func password(for keychainTag: String) throws(PasswordStoreError) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return entries[keychainTag]
        }

        func save(_ password: String, for keychainTag: String) throws(PasswordStoreError) {
            lock.lock()
            defer { lock.unlock() }
            entries[keychainTag] = password
        }

        func deletePassword(for keychainTag: String) throws(PasswordStoreError) {
            lock.lock()
            defer { lock.unlock() }
            entries[keychainTag] = nil
        }
    }

    private final class MemoryConnectionStore: ConnectionStoreProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [Connection]

        init(_ connections: [Connection]) {
            self.connections = connections
        }

        func loadConnections() throws(PersistenceError) -> [Connection] {
            lock.lock()
            defer { lock.unlock() }
            return connections
        }

        func connection(id: UUID) throws(PersistenceError) -> Connection? {
            lock.lock()
            defer { lock.unlock() }
            return connections.first { $0.id == id }
        }

        func save(_ connection: Connection) throws(PersistenceError) {
            lock.lock()
            defer { lock.unlock() }
            connections.removeAll { $0.id == connection.id }
            connections.append(connection)
        }

        func deleteConnection(id: UUID) throws(PersistenceError) {
            lock.lock()
            defer { lock.unlock() }
            connections.removeAll { $0.id == id }
        }
    }

    private func ephemeralDefaults() throws -> UserDefaults {
        let name = "forget-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func passwordConnection(
        name: String, host: String, tag: String, jumpTag: String? = nil
    ) throws -> Connection {
        var chain: [Hop] = []
        if let jumpTag {
            chain = [Hop(host: "jump.example.com", port: 22, username: "jump", keyReference: jumpTag, authMethod: .password)]
        }
        return try Connection(
            name: name,
            type: .ssh,
            host: host,
            port: 22,
            username: "alice",
            keyReference: tag,
            authMethod: .password,
            jumpChain: chain
        )
    }

    func testForgetClearsTrustPasswordsSessionsAndHerdrSettingsForOneHost() async throws {
        let keyStore = MemoryHostKeyStore()
        try await keyStore.save(HostKeyRecord(
            host: "web.example.com", port: 22, algorithm: "ssh-ed25519",
            publicKeyData: Data([1, 2, 3]), trustState: .trusted, firstSeenDate: Date()
        ))
        try await keyStore.save(HostKeyRecord(
            host: "other.example.com", port: 22, algorithm: "ssh-ed25519",
            publicKeyData: Data([9, 9]), trustState: .trusted, firstSeenDate: Date()
        ))

        let passwordStore = MemoryPasswordStore()
        try await passwordStore.save("pw-web", for: "tag-web")
        try await passwordStore.save("pw-other", for: "tag-other")

        let connection = try passwordConnection(name: "Web", host: "web.example.com", tag: "tag-web")
        let other = try passwordConnection(name: "Other", host: "other.example.com", tag: "tag-other")
        let connectionStore = MemoryConnectionStore([connection, other])

        let defaults = try ephemeralDefaults()
        let settings = HerdrClipboardSettings(defaults: defaults)
        let endpoint = HerdrHostIdentity.endpoint(connection: connection)
        settings.setAutoCopyRemoteClipboard(true, for: endpoint)

        var deletedSessionHosts: [(String, Int)] = []
        let service = HerdrHostForgetService(dependencies: .init(
            hostKeyStore: keyStore,
            passwordStore: passwordStore,
            connectionStore: connectionStore,
            clipboardSettings: settings,
            deleteRestorableSessions: { host, port in
                deletedSessionHosts.append((host, port))
                return 2
            }
        ))

        let outcome = await service.forget(connection: connection)

        XCTAssertEqual(outcome.hostKeysForgotten, 1)
        XCTAssertEqual(outcome.passwordsRemoved, 1)
        XCTAssertEqual(outcome.restorableSessionsRemoved, 2)
        XCTAssertTrue(outcome.clipboardSettingRemoved)
        XCTAssertEqual(deletedSessionHosts.count, 1)
        XCTAssertEqual(deletedSessionHosts.first?.0, "web.example.com")
        XCTAssertEqual(deletedSessionHosts.first?.1, 22)

        let webKey = try await keyStore.lookup(host: "web.example.com", port: 22)
        XCTAssertNil(webKey, "the forgotten host's TOFU record is gone")
        let otherKey = try await keyStore.lookup(host: "other.example.com", port: 22)
        XCTAssertNotNil(otherKey, "other hosts keep their trust")

        await XCTAssertNilAsync(try await passwordStore.password(for: "tag-web"))
        await XCTAssertEqualAsync(try await passwordStore.password(for: "tag-other") ?? "", "pw-other")
        XCTAssertFalse(
            settings.autoCopyRemoteClipboard(for: endpoint),
            "the herdr opt-in resets to the privacy default"
        )
        let remaining = try connectionStore.loadConnections()
        XCTAssertEqual(remaining.count, 2, "connection entries are kept")
    }

    func testForgetKeepsPasswordsStillReferencedByAnotherConnection() async throws {
        let passwordStore = MemoryPasswordStore()
        try await passwordStore.save("shared", for: "shared-tag")

        let first = try passwordConnection(name: "One", host: "web.example.com", tag: "shared-tag")
        let second = try passwordConnection(name: "Two", host: "web.example.com", tag: "shared-tag")
        let connectionStore = MemoryConnectionStore([first, second])

        let service = HerdrHostForgetService(dependencies: .init(
            hostKeyStore: MemoryHostKeyStore(),
            passwordStore: passwordStore,
            connectionStore: connectionStore,
            clipboardSettings: HerdrClipboardSettings(defaults: try ephemeralDefaults()),
            deleteRestorableSessions: { _, _ in 0 }
        ))

        let outcome = await service.forget(connection: first)
        XCTAssertEqual(outcome.passwordsRemoved, 0, "a tag another connection still uses survives")
        await XCTAssertEqualAsync(try await passwordStore.password(for: "shared-tag") ?? "", "shared")
    }

    func testForgetClearsJumpHopTrustToo() async throws {
        let keyStore = MemoryHostKeyStore()
        try await keyStore.save(HostKeyRecord(
            host: "jump.example.com", port: 22, algorithm: "ssh-ed25519",
            publicKeyData: Data([4, 5]), trustState: .trusted, firstSeenDate: Date()
        ))

        let connection = try passwordConnection(
            name: "Chained", host: "web.example.com", tag: "t", jumpTag: "jt"
        )
        let service = HerdrHostForgetService(dependencies: .init(
            hostKeyStore: keyStore,
            passwordStore: MemoryPasswordStore(),
            connectionStore: MemoryConnectionStore([connection]),
            clipboardSettings: HerdrClipboardSettings(defaults: try ephemeralDefaults()),
            deleteRestorableSessions: { _, _ in 0 }
        ))

        let outcome = await service.forget(connection: connection)
        XCTAssertEqual(outcome.hostKeysForgotten, 1, "the jump hop's trust clears with the host")
        let hopKey = try await keyStore.lookup(host: "jump.example.com", port: 22)
        XCTAssertNil(hopKey)
    }

    func testEndpointIdentityIsStableAndHostQualified() throws {
        let connection = try passwordConnection(name: "X", host: "web.example.com", tag: "t")
        XCTAssertEqual(
            HerdrHostIdentity.endpointRawValue(connection: connection),
            "ssh://alice@web.example.com:22"
        )
        let renamed = try Connection(
            name: "Renamed", type: connection.type, host: connection.host,
            port: connection.port, username: connection.username,
            keyReference: "t", jumpChain: []
        )
        XCTAssertEqual(
            HerdrHostIdentity.endpointRawValue(connection: renamed),
            HerdrHostIdentity.endpointRawValue(connection: connection),
            "labels change without changing profile identity (doc §3.5)"
        )
    }
}

/// XCTAssertAsync twins: bind the awaited value before the autoclosure.
@MainActor
private func XCTAssertNilAsync(
    _ value: String?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    XCTAssertNil(value, file: file, line: line)
}

@MainActor
private func XCTAssertEqualAsync(
    _ value: String?,
    _ expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    XCTAssertEqual(value, expected, file: file, line: line)
}
