import Foundation
@testable import BicTermCore

enum TestModels {
    static let connectionID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    static let coderServerID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    static let workspaceID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    static let createdAt = Date(timeIntervalSince1970: 1_725_000_000)
    static let tokenFixture = "coder-session-token-fixture-secret-123456"

    static func hop(_ index: Int = 1) -> Hop {
        Hop(
            host: "hop\(index).example.com",
            port: 2200 + index,
            username: "hop-user-\(index)",
            keyReference: "keychain://keys/hop-\(index)"
        )
    }

    static func protocolOptions() throws -> ProtocolOptions {
        try ProtocolOptions([
            "keepaliveInterval": .int(30),
            "compression": .bool(true),
            "terminalType": .string("xterm-256color"),
        ])
    }

    static func connection(
        id: UUID = connectionID,
        type: ConnectionType = .coder,
        jumpChain: [Hop] = [hop(1), hop(2)]
    ) throws -> Connection {
        try Connection(
            id: id,
            name: "Fixture Connection",
            type: type,
            host: "workspace.example.com",
            port: 22,
            username: "fixture-user",
            keyReference: "keychain://keys/main",
            jumpChain: jumpChain,
            protocolOptions: protocolOptions(),
            coderRef: CoderReference(serverID: coderServerID, workspaceID: workspaceID)
        )
    }

    static func coderServer(id: UUID = coderServerID) throws -> CoderServer {
        try CoderServer(
            id: id,
            name: "Fixture Coder",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: "keychain://coder/fixture"
        )
    }

    static func hostKey(port: Int, byte: UInt8) -> HostKeyRecord {
        HostKeyRecord(
            host: "ssh.example.com",
            port: port,
            algorithm: "ssh-ed25519",
            publicKeyData: Data(repeating: byte, count: 32),
            trustState: .trusted,
            firstSeenDate: createdAt
        )
    }

    static func snapshot(
        connectionID: UUID = connectionID,
        sceneID: String = "scene-fixture"
    ) -> SessionSnapshot {
        SessionSnapshot(
            connectionID: connectionID,
            sceneID: sceneID,
            state: .reconnectRequired,
            createdAt: createdAt
        )
    }
}

enum SecretAbsenceAssertions {
    struct Finding: Equatable {
        let path: String
        let reason: String
    }

    static func fixturePrivateKeyData(filePath: StaticString = #filePath) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return try Data(
            contentsOf: repositoryRoot
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("keys")
                .appendingPathComponent("bicterm-fixture-ed25519")
        )
    }

    static func findings(
        in encodedValues: [Data],
        privateKeyData: Data
    ) throws -> [Finding] {
        let privateKeyText = String(decoding: privateKeyData, as: UTF8.self)
        var findings: [Finding] = []

        for (index, data) in encodedValues.enumerated() {
            let object = try JSONSerialization.jsonObject(with: data)
            inspect(
                object,
                path: "$[\(index)]",
                privateKeyData: privateKeyData,
                privateKeyText: privateKeyText,
                findings: &findings
            )
        }

        return findings
    }

    private static func inspect(
        _ value: Any,
        path: String,
        privateKeyData: Data,
        privateKeyText: String,
        findings: inout [Finding]
    ) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                inspect(
                    child,
                    path: "\(path).\(key)",
                    privateKeyData: privateKeyData,
                    privateKeyText: privateKeyText,
                    findings: &findings
                )
            }
            return
        }

        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                inspect(
                    child,
                    path: "\(path)[\(index)]",
                    privateKeyData: privateKeyData,
                    privateKeyText: privateKeyText,
                    findings: &findings
                )
            }
            return
        }

        guard let string = value as? String else { return }

        if string.contains(privateKeyText) {
            findings.append(Finding(path: path, reason: "private-key text"))
        }

        if let decoded = Data(base64Encoded: string), decoded.range(of: privateKeyData) != nil {
            findings.append(Finding(path: path, reason: "base64 private-key data"))
        }

        let tokenPatterns = [
            #"(?i)\b(?:coder|ghp|github_pat|sk_live)[-_][A-Za-z0-9_-]{12,}\b"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
        ]
        if tokenPatterns.contains(where: { string.range(of: $0, options: .regularExpression) != nil }) {
            findings.append(Finding(path: path, reason: "token-shaped string"))
        }
    }
}
