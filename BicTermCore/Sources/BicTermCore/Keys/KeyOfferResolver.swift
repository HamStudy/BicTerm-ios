import Foundation

public struct KeyOfferRequest: Sendable {
    public let offersKeys: Bool
    public let customKeys: [String]?
    public let hardwareKeysEnabledByDefault: Bool

    public init(offersKeys: Bool, customKeys: [String]?, hardwareKeysEnabledByDefault: Bool) {
        self.offersKeys = offersKeys
        self.customKeys = customKeys
        self.hardwareKeysEnabledByDefault = hardwareKeysEnabledByDefault
    }
}

/// Resolves references without accessing key material or connection preferences.
public struct KeyOfferResolver: Sendable {
    public init() {}

    public func resolve(_ request: KeyOfferRequest, keys: [KeyMetadata]) -> [String] {
        let canonicalKeys = canonicalKeyMetadata(keys)
        let requestedReferences = request.customKeys.map { Set($0) }
        let result = canonicalKeys.filter { key in
            guard request.offersKeys, key.enabledByDefault else { return false }
            if let requestedReferences {
                return requestedReferences.contains(key.reference)
            }
            return key.algorithm != .ecdsaP256 || request.hardwareKeysEnabledByDefault
        }.map(\.reference)
        return result
    }
}

/// First metadata record wins, before sorting or applying eligibility filters.
func canonicalKeyMetadata(_ keys: [KeyMetadata]) -> [KeyMetadata] {
    var seen = Set<String>()
    return keys.filter { seen.insert($0.reference).inserted }.sorted { lhs, rhs in
        let order = lhs.label.caseInsensitiveCompare(rhs.label)
        return order == .orderedSame ? lhs.reference < rhs.reference : order == .orderedAscending
    }
}
