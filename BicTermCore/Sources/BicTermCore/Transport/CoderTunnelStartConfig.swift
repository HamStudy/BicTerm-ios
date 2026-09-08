import Foundation

/// Serializer for the tunnel bridge's session-start config JSON: the exact
/// snake_case wire shape the Go core parses at session allocation. Unknown-
/// to-Go fields (the credential generation) are observability for Swift-side
/// tests — the Go core tolerates extra keys.
enum CoderTunnelStartConfig {
    static func json(
        endpoint: CoderAgentEndpoint,
        socketDir: String,
        credentialGeneration: UInt64
    ) -> String {
        struct StartConfig: Encodable {
            let serverURL: String
            let sessionToken: String
            let agentID: String
            let relayOnly: Bool
            let socketDir: String
            let credentialGeneration: UInt64

            enum CodingKeys: String, CodingKey {
                case serverURL = "server_url"
                case sessionToken = "session_token"
                case agentID = "agent_id"
                case relayOnly = "relay_only"
                case socketDir = "socket_dir"
                case credentialGeneration = "credential_generation"
            }
        }
        let config = StartConfig(
            serverURL: endpoint.serverURL.absoluteString,
            sessionToken: endpoint.sessionToken,
            agentID: endpoint.agentID.uuidString.lowercased(),
            relayOnly: false,
            socketDir: socketDir,
            credentialGeneration: credentialGeneration
        )
        // The type has no fallible members; encoding cannot fail.
        return String(decoding: (try? JSONEncoder().encode(config)) ?? Data(), as: UTF8.self)
    }
}
