import Foundation

public enum CoderClientError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case unexpectedStatusCode(Int)
    case invalidURL
    case tlsFailure
    case networkFailure
    case malformedResponse
    case tokenStorageFailure
    case requestCancelled

    public var requiresReauthentication: Bool {
        self == .unauthorized
    }
}

extension CoderClientError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Coder authentication expired or was rejected. Reauthenticate to continue."
        case .forbidden:
            "The Coder account is not permitted to list these workspaces."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Coder rate-limited the request. Retry after \(retryAfter) seconds."
            } else {
                "Coder rate-limited the request."
            }
        case let .serverError(statusCode):
            "Coder returned a server error (HTTP \(statusCode))."
        case let .unexpectedStatusCode(statusCode):
            "Coder returned an unexpected response (HTTP \(statusCode))."
        case .invalidURL:
            "The Coder server URL is invalid."
        case .tlsFailure:
            "The Coder server failed system TLS trust validation."
        case .networkFailure:
            "The Coder server could not be reached."
        case .malformedResponse:
            "Coder returned a malformed workspace response."
        case .tokenStorageFailure:
            "The Coder token could not be accessed securely."
        case .requestCancelled:
            "The Coder request was cancelled."
        }
    }

    public var description: String {
        errorDescription ?? "Coder request failed."
    }

    public var debugDescription: String {
        switch self {
        case .unauthorized: "CoderClientError.unauthorized"
        case .forbidden: "CoderClientError.forbidden"
        case let .rateLimited(retryAfter):
            "CoderClientError.rateLimited(retryAfter: \(String(describing: retryAfter)))"
        case let .serverError(statusCode):
            "CoderClientError.serverError(statusCode: \(statusCode))"
        case let .unexpectedStatusCode(statusCode):
            "CoderClientError.unexpectedStatusCode(\(statusCode))"
        case .invalidURL: "CoderClientError.invalidURL"
        case .tlsFailure: "CoderClientError.tlsFailure"
        case .networkFailure: "CoderClientError.networkFailure"
        case .malformedResponse: "CoderClientError.malformedResponse"
        case .tokenStorageFailure: "CoderClientError.tokenStorageFailure"
        case .requestCancelled: "CoderClientError.requestCancelled"
        }
    }
}
