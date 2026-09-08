import Foundation

/// Capability record for a remote-session protocol. Registered alongside
/// the protocol's factory in ``TransportRegistry``; drives UI hints
/// (server-component install prompts), feature gating (agent forwarding,
/// jump chains) and resume behavior WITHOUT the session layer importing
/// any protocol internals.
public struct ProtocolDescriptor: Equatable, Sendable {
    /// Stable wire/persistence id: matches `Connection.type.rawValue`
    /// (`"ssh"`, future `"et"`/`"mosh"`/`"coder"`).
    public let id: String
    public let displayName: String
    public let supportsAgentForwarding: Bool
    public let supportsJumpChain: Bool
    public let supportsRoamingResume: Bool
    /// ET/mosh need remote binaries installed; drives future UI hints.
    public let requiresServerComponent: Bool
    public let defaultPort: Int
    /// OpenSSH-style algorithm names the protocol accepts for auth keys.
    public let keyAlgorithmsAccepted: [String]
    public let resumeStrategy: ResumeStrategy

    /// Whether this build ships the AGPL CoderNet tailnet tunnel core.
    /// Injected from the build flavor (`CODER_TUNNEL` compilation condition)
    /// at registration time — never hardcoded here: AppStore configurations
    /// exclude the Go core from the binary and MUST report `false` so coder
    /// connections fall back to the direct-SSH path. Defaults to `false` so
    /// a call site that forgets the flag cannot silently claim support.
    public let supportsTailnetTunnel: Bool

    public init(
        id: String,
        displayName: String,
        supportsAgentForwarding: Bool,
        supportsJumpChain: Bool,
        supportsRoamingResume: Bool,
        requiresServerComponent: Bool,
        defaultPort: Int,
        keyAlgorithmsAccepted: [String],
        resumeStrategy: ResumeStrategy,
        supportsTailnetTunnel: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsAgentForwarding = supportsAgentForwarding
        self.supportsJumpChain = supportsJumpChain
        self.supportsRoamingResume = supportsRoamingResume
        self.requiresServerComponent = requiresServerComponent
        self.defaultPort = defaultPort
        self.keyAlgorithmsAccepted = keyAlgorithmsAccepted
        self.resumeStrategy = resumeStrategy
        self.supportsTailnetTunnel = supportsTailnetTunnel
    }
}

extension ProtocolDescriptor {
    /// The v1 protocol. Capabilities mirror what the SSH layer actually
    /// implements: T8 agent forwarding, T9 jump chains, key auth via
    /// ed25519 (Keychain) and P-256 (Secure Enclave / software).
    public static let ssh = ProtocolDescriptor(
        id: "ssh",
        displayName: "SSH",
        supportsAgentForwarding: true,
        supportsJumpChain: true,
        supportsRoamingResume: false,
        requiresServerComponent: false,
        defaultPort: 22,
        keyAlgorithmsAccepted: ["ssh-ed25519", "ecdsa-sha2-nistp256"],
        resumeStrategy: .rehandshake,
        supportsTailnetTunnel: false
    )

    /// Coder workspaces via the REST API + agent connection. The tunnel
    /// capability is a parameter, not a constant: default (open-source)
    /// builds pass `true`, AppStore builds pass `false` and fall back to
    /// direct SSH against the workspace's routable address.
    public static func coder(supportsTailnetTunnel: Bool) -> ProtocolDescriptor {
        ProtocolDescriptor(
            id: "coder",
            displayName: "Coder",
            supportsAgentForwarding: false,
            supportsJumpChain: false,
            supportsRoamingResume: false,
            requiresServerComponent: true,
            defaultPort: 443,
            keyAlgorithmsAccepted: ["ssh-ed25519"],
            resumeStrategy: .rehandshake,
            supportsTailnetTunnel: supportsTailnetTunnel
        )
    }
}
