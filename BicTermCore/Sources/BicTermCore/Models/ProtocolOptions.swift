import Foundation

public enum ProtocolOptionValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

public struct ProtocolOptions: Codable, Equatable, Sendable {
    private static let forbiddenKeyFragments = [
        "password",
        "passphrase",
        "privatekey",
        "secret",
        "token",
    ]

    private let storage: [String: ProtocolOptionValue]

    /// Per-connection herdr toggle (herdr-support plan todo 1): `true` means
    /// connects to this machine open a single-endpoint herdr workspace.
    public static let herdrEnabledKey = "herdrEnabled"

    /// Optional remote herdr session name for a herdr-enabled connection.
    /// The value is an unvalidated string here; the herdr layers enforce
    /// herdr's own session-name grammar before any remote command runs.
    public static let herdrSessionKey = "herdrSession"

    public init() {
        storage = [:]
    }

    public init(
        _ values: [String: ProtocolOptionValue]
    ) throws(ProtocolOptionsValidationError) {
        for key in values.keys {
            let normalizedKey = key
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            if Self.forbiddenKeyFragments.contains(where: normalizedKey.contains) {
                throw .secretBearingKeyNotAllowed(key)
            }
        }
        storage = values
    }

    public var values: [String: ProtocolOptionValue] {
        storage
    }

    public subscript(key: String) -> ProtocolOptionValue? {
        storage[key]
    }

    /// Herdr mode toggle (``herdrEnabledKey``). A wrong-typed value reads as
    /// unset (`false`) — persisted junk never enables herdr by accident.
    public var herdrEnabled: Bool {
        self[Self.herdrEnabledKey]?.boolValue ?? false
    }

    /// Remote herdr session name (``herdrSessionKey``): trimmed, with empty
    /// and wrong-typed values reading as unset (`nil`).
    public var herdrSessionName: String? {
        guard let raw = self[Self.herdrSessionKey]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([String: ProtocolOptionValue].self)
        try self.init(values)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}
