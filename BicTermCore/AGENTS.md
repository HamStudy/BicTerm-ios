# BicTermCore: SwiftPM Core Package

## OVERVIEW
Platform-agnostic SSH/transport/session logic for the app; one library product (`BicTermCore`), iOS 18+, Swift 6 strict concurrency, built on vendored swift-nio-ssh + swift-nio (NIOCore/NIOPosix).

## STRUCTURE
```
BicTermCore/
├── Package.swift                    # manifest; deps: ../Vendor/swift-nio-ssh, swift-nio 2.102.0 (exact)
└── Sources/
    ├── CBcryptPBKDF/                # C target, bcrypt PBKDF for OpenSSH key decryption
    └── BicTermCore/
        ├── SSH/          # NIO SSH transport, exec channels, direct-tcpip, UDS
        │   ├── Agent/    # in-app agent: codec, authorization service, forwarding bridge
        │   └── Jump/     # ProxyJump chain builder + jump pipeline transports
        ├── Transport/    # TerminalTransport protocol, descriptors, registry; the extension seam
        ├── Sessions/     # SessionRegistry, SessionState, SessionTransport
        ├── Keys/         # Keychain repo, OpenSSH parser/decryption, Secure Enclave P-256, password store
        ├── Trust/        # HostKeyVerifier (TOFU host-key trust)
        ├── Models/       # Connection, Hop, HostKeyRecord, SessionSnapshot, validation
        ├── Persistence/  # SwiftData stores (config, host keys, snapshots) + protocols
        └── Herdr/        # herdr byte/SSH transports, command builder, probe
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| SSH connection/transport | `SSH/SSHTransport.swift` + `SSHTransport+*.swift` | DirectTCPIP, Exec, UDS extensions |
| ProxyJump chains | `SSH/Jump/` | up to 5 hops, per-hop host-key verification |
| Agent codec + authz | `SSH/Agent/SSHAgentCodec.swift`, `AgentAuthorizationService.swift` | per-request authorization model |
| Transport seam | `Transport/TerminalTransport.swift` | SSH is one conformer; ET/mosh could be added |
| Transport registration | `Transport/TransportRegistry.swift` | protocol descriptors |
| Session registry/reconnect | `Sessions/SessionRegistry.swift` | state in `SessionState.swift` |
| TOFU verification | `Trust/HostKeyVerifier.swift` | prompt first connect, reject changed keys |
| Key storage | `Keys/KeychainKeyRepository.swift`, `SecureEnclaveKeyService.swift` | ed25519 Keychain, P-256 Secure Enclave |
| OpenSSH key parsing | `Keys/OpenSSHPrivateKeyParser.swift` + `OpenSSHKeyDecryption.swift` | bcrypt PBKDF via CBcryptPBKDF |
| SwiftData persistence | `Persistence/SwiftData*Store.swift` | protocols in `PersistenceStoreProtocols.swift` |
| Tests | `Tests/BicTermCoreTests/` | unit + integration, incl. `SecretAbsenceAssertions.swift` |

## CONVENTIONS
- Everything here must stay testable without a UI host; that is what the no-SwiftUI/UIKit rule means in practice for this package.
- Tests run via root harness (`scripts/test-core.sh`); integration tests need sshd fixtures up (ports 12222/12223).
- NIOEmbedded used in tests for in-memory channels (`Tests/` deps).
- New transports conform to `TerminalTransport` and register in `TransportRegistry`; never special-case SSH in session layers. Conformance suites in `Tests/.../Transport/` prove this.

## ANTI-PATTERNS (THIS PACKAGE)
- No RSA keys, no keyboard-interactive auth: don't add a client for either; NIOSSH has none, this is by design.
- Never block NIO event-loop threads: async/await boundaries at channel handlers, no semaphores/locks on loop threads.
- Never log secrets (keys, passwords, passphrases); `SecretAbsenceAssertions.swift` enforces in tests.
- No Foundation networking / URLSession sockets here; all I/O goes through NIO channels.
- Don't reimplement the herdr protocol codec in Swift; `Herdr/` only adapts transports and builds commands.

## NOTES
- `DebugPasswordServer.swift` (in `SSH/`) is a test/debug server handler, not production auth.
- Herdr tests use committed-frame replay (no live server); see root NOTES for the zig blocker.
- Ignore `.build/` when surveying; it holds SPM checkouts, not source.
