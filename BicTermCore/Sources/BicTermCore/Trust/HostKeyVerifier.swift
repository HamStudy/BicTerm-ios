import Foundation

public enum HostKeyVerdict: Equatable, Sendable {
    case trusted
    case requiresTrust(
        fingerprint: String,
        algorithm: String,
        publicKeyData: Data
    )
    case rejected(HostKeyRejectionReason)
}

public enum HostKeyRejectionReason: Error, Equatable, Sendable {
    case hostKeyChanged(
        host: String,
        port: Int,
        oldFingerprint: String,
        newFingerprint: String
    )
}

extension HostKeyRejectionReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .hostKeyChanged(host, port, oldFingerprint, newFingerprint):
            "Host key changed for \(host):\(port) from \(oldFingerprint) to \(newFingerprint)."
        }
    }
}

public enum HostKeyTrustError: Error, Equatable, Sendable {
    case rejected(HostKeyRejectionReason)
    case persistence(PersistenceError)
}

extension HostKeyTrustError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .rejected(reason):
            reason.localizedDescription
        case let .persistence(error):
            error.localizedDescription
        }
    }
}

public actor HostKeyVerifier {
    /// Trust policy chosen at construction. `.coderTunnelTrust` is
    /// enum-separate from `.tofu` on purpose: it is reachable ONLY through
    /// ``coderTunnel()`` (or an explicit `trustPolicy:` argument in-module),
    /// so ordinary SSH profiles built via `init(store:)` can never select it.
    public enum TrustPolicy: Equatable, Sendable {
        /// Trust-on-first-use backed by the persistent host-key store.
        case tofu
        /// Coder workspace sessions (spec §10.5/§11.2): the agent's built-in
        /// SSH server is reached only through the already-authorized tailnet
        /// transport, which is the access boundary. The SDK's stock policy
        /// accepts the agent's (ephemeral, rotation-prone) host key
        /// unconditionally; this mode mirrors that. It is NOT a claim of
        /// protection against a malicious Coder control plane, and it never
        /// reads from or writes to the persistent host-key store.
        case coderTunnelTrust
    }

    /// The policy this verifier enforces. Public so wiring layers (and the
    /// trust-isolation tests) can assert which boundary a transport uses.
    public nonisolated let trustPolicy: TrustPolicy

    private let store: any HostKeyStoreProtocol
    private let now: @Sendable () -> Date
    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: any HostKeyStoreProtocol) {
        self.store = store
        self.trustPolicy = .tofu
        self.now = { Date() }
    }

    /// Coder-tunnel construction point — store-free by contract: the coder
    /// trust policy never touches on-disk trust state at all.
    public static func coderTunnel() -> HostKeyVerifier {
        HostKeyVerifier(store: NullHostKeyStore(), trustPolicy: .coderTunnelTrust)
    }

    init(
        store: any HostKeyStoreProtocol,
        trustPolicy: TrustPolicy = .tofu,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.trustPolicy = trustPolicy
        self.now = now
    }

    public func verify(
        host: String,
        port: Int,
        key: Data,
        algorithm: String
    ) async throws(PersistenceError) -> HostKeyVerdict {
        await enterOperation()
        defer { leaveOperation() }

        if trustPolicy == .coderTunnelTrust {
            return .trusted
        }

        let fingerprint = OpenSSHFingerprint.sha256(publicKeyBlob: key)
        guard let record = try await store.lookup(host: host, port: port) else {
            try await store.save(
                HostKeyRecord(
                    host: host,
                    port: port,
                    algorithm: algorithm,
                    publicKeyData: key,
                    trustState: .firstSeen,
                    firstSeenDate: now()
                )
            )
            return .requiresTrust(
                fingerprint: fingerprint,
                algorithm: algorithm,
                publicKeyData: key
            )
        }

        guard record.algorithm == algorithm, record.publicKeyData == key else {
            return .rejected(changedKeyReason(record: record, key: key))
        }

        switch record.trustState {
        case .trusted:
            return .trusted
        case .firstSeen:
            return .requiresTrust(
                fingerprint: fingerprint,
                algorithm: algorithm,
                publicKeyData: key
            )
        }
    }

    public func trust(
        host: String,
        port: Int,
        key: Data,
        algorithm: String
    ) async throws(HostKeyTrustError) {
        await enterOperation()
        defer { leaveOperation() }

        // Coder-tunnel sessions never prompt and never persist: trust() wiring
        // from the TOFU prompt reaching a coder verifier is a no-op, not a
        // silent write of an agent's ephemeral key into the permanent store.
        if trustPolicy == .coderTunnelTrust {
            return
        }

        let existingRecord: HostKeyRecord?
        do {
            existingRecord = try await store.lookup(host: host, port: port)
        } catch let error {
            throw .persistence(error)
        }

        if let existingRecord {
            guard existingRecord.algorithm == algorithm, existingRecord.publicKeyData == key else {
                throw .rejected(changedKeyReason(record: existingRecord, key: key))
            }
            guard existingRecord.trustState != .trusted else {
                return
            }
        }

        let trustedRecord = HostKeyRecord(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: key,
            trustState: .trusted,
            firstSeenDate: existingRecord?.firstSeenDate ?? now()
        )
        do {
            try await store.save(trustedRecord)
        } catch let error {
            throw .persistence(error)
        }
    }

    private func changedKeyReason(record: HostKeyRecord, key: Data) -> HostKeyRejectionReason {
        .hostKeyChanged(
            host: record.host,
            port: record.port,
            oldFingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: record.publicKeyData),
            newFingerprint: OpenSSHFingerprint.sha256(publicKeyBlob: key)
        )
    }

    private func enterOperation() async {
        if !operationIsActive {
            operationIsActive = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func leaveOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }

        operationWaiters.removeFirst().resume()
    }
}

/// Backing store for ``HostKeyVerifier/coderTunnel()``. The coder-tunnel
/// policy short-circuits before any store call, so these are never invoked;
/// they exist only to satisfy the protocol. Kept empty-by-construction rather
/// than trapping: a stray call must fail soft, never crash a session.
private struct NullHostKeyStore: HostKeyStoreProtocol {
    func loadAll() async throws(PersistenceError) -> [HostKeyRecord] { [] }
    func lookup(host: String, port: Int) async throws(PersistenceError) -> HostKeyRecord? { nil }
    func save(_ record: HostKeyRecord) async throws(PersistenceError) {}
}
