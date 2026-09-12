import Foundation

public enum ConnectionValidationError: Error, Equatable, Sendable {
    case jumpChainTooLong(maximum: Int, actual: Int)
}

public enum ProtocolOptionsValidationError: Error, Equatable, Sendable {
    case secretBearingKeyNotAllowed(String)
}
