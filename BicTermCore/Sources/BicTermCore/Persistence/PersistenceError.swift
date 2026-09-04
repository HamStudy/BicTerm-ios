import Foundation

public enum PersistenceError: Error, Equatable, Sendable {
    case initializationFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case operationFailed(String)
}

extension PersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .initializationFailed(reason):
            "Unable to initialize persistence: \(reason)"
        case let .encodingFailed(model):
            "Unable to encode \(model)"
        case let .decodingFailed(model):
            "Unable to decode \(model)"
        case let .operationFailed(operation):
            "Persistence operation failed: \(operation)"
        }
    }
}
