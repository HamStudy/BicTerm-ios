import Foundation

public struct CoderHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func value(forHeaderField field: String) -> String? {
        headers.first { key, _ in
            key.compare(field, options: .caseInsensitive) == .orderedSame
        }?.value
    }
}

extension CoderHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "CoderHTTPResponse(statusCode: \(statusCode), headerCount: \(headers.count), bodyBytes: \(body.count))"
    }

    public var debugDescription: String {
        description
    }
}

public enum CoderRequestLoadingError: Error, Equatable, Sendable {
    case invalidURL
    case tlsFailure
    case networkFailure
    case invalidResponse
    case cancelled
}

public protocol CoderRequestLoading: Sendable {
    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse
}

/// Production URL loader. `URLSession.shared` uses the platform's system trust
/// policy; BicTerm installs no delegate, trust override, pin, or custom CA.
public struct SystemCoderRequestLoader: CoderRequestLoading {
    public init() {}

    public func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw CoderRequestLoadingError.invalidResponse
            }

            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key] = String(describing: value)
            }
            return CoderHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
        } catch let error as CoderRequestLoadingError {
            throw error
        } catch let error as URLError {
            throw Self.map(error.code)
        } catch {
            throw .networkFailure
        }
    }

    private static func map(_ code: URLError.Code) -> CoderRequestLoadingError {
        switch code {
        case .badURL, .unsupportedURL:
            .invalidURL
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            .tlsFailure
        case .cancelled:
            .cancelled
        default:
            .networkFailure
        }
    }
}

public enum CoderRetrySleepingError: Error, Equatable, Sendable {
    case cancelled
}

public protocol CoderRetrySleeping: Sendable {
    func sleep(for delay: TimeInterval) async throws(CoderRetrySleepingError)
}

public struct SystemCoderRetrySleeper: CoderRetrySleeping {
    public init() {}

    public func sleep(for delay: TimeInterval) async throws(CoderRetrySleepingError) {
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            throw .cancelled
        }
    }
}
