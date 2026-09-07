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
