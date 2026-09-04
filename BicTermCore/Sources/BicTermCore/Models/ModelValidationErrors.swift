import Foundation

public enum ConnectionValidationError: Error, Equatable, Sendable {
    case jumpChainTooLong(maximum: Int, actual: Int)
}

public enum CoderServerValidationError: Error, Equatable, Sendable {
    case httpsRequired
    case hostRequired
    case embeddedCredentialsNotAllowed
}

public enum ProtocolOptionsValidationError: Error, Equatable, Sendable {
    case secretBearingKeyNotAllowed(String)
}
