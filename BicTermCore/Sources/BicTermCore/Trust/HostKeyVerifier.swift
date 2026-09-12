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
    private let store: any HostKeyStoreProtocol
    private let now: @Sendable () -> Date
    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: any HostKeyStoreProtocol) {
        self.store = store
        self.now = { Date() }
    }

    init(
        store: any HostKeyStoreProtocol,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
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
