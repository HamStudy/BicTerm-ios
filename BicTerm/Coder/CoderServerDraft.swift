import BicTermCore
import Foundation

struct CoderServerDraft: Equatable {
    static let defaultPort = 443

    var name = ""
    var urlString = ""
    var token = ""

    private(set) var existingID: UUID?
    private let draftID: UUID

    init(server: CoderServer? = nil) {
        name = server?.name ?? ""
        urlString = server?.baseURL.absoluteString ?? ""
        existingID = server?.id
        draftID = UUID()
    }

    var isExisting: Bool { existingID != nil }
    var requiresToken: Bool { !isExisting }

    var nameError: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Name is required." : nil
    }

    var urlError: String? {
        switch validateAddress() {
        case .success:
            return nil
        case .failure(.httpNotAllowed):
            return "HTTP is not allowed. Use HTTPS."
        case .failure(.unsupportedScheme):
            return "Use HTTPS only."
        case .failure(.missingHost):
            return "Enter a host name or address."
        case .failure(.embeddedCredentials):
            return "URL credentials are not allowed."
        case .failure(.invalidPort):
            return "Enter a valid port number."
        case .failure(.malformedAddress):
            return "Enter a valid web address."
        }
    }

    var resolvedURL: URL? {
        guard case .success(let url) = validateAddress() else { return nil }
        return url
    }

    var tokenKeychainTag: String {
        "com.bicterm.coder.server.\(existingID?.uuidString ?? draftID.uuidString)"
    }

    func makeServer() throws(CoderServerValidationError) -> CoderServer {
        guard let url = resolvedURL else {
            throw .hostRequired
        }
        return try CoderServer(
            id: existingID ?? draftID,
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: url,
            tokenKeychainTag: tokenKeychainTag
        )
    }

    var isComplete: Bool {
        nameError == nil && urlError == nil && (!requiresToken || !token.isEmpty)
    }
}

private extension CoderServerDraft {
    enum AddressValidationIssue: Error {
        case httpNotAllowed
        case unsupportedScheme
        case missingHost
        case embeddedCredentials
        case invalidPort
        case malformedAddress
    }

    func validateAddress() -> Result<URL, AddressValidationIssue> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.missingHost)
        }

        if trimmed.lowercased().hasPrefix("http://") {
            return .failure(.httpNotAllowed)
        }

        var candidate = trimmed
        if let schemeRange = candidate.range(of: "://") {
            let scheme = candidate[..<schemeRange.lowerBound].lowercased()
            guard scheme == "https" else {
                return .failure(.unsupportedScheme)
            }
        } else {
            candidate = "https://\(candidate)"
        }

        if candidate.contains("@") {
            return .failure(.embeddedCredentials)
        }

        let hostPattern = /^https:\/\/([^\/?#:@]+|\[[^\]]+\])(:\d+)?\/?$/
        guard candidate.wholeMatch(of: hostPattern) != nil else {
            return .failure(.malformedAddress)
        }

        if let portMatch = candidate.wholeMatch(
            of: /^https:\/\/(?:[^\/?#:@]+|\[[^\]]+\]):(\d+)\/?$/
        ) {
            guard let port = Int(portMatch.1), (1...65535).contains(port) else {
                return .failure(.invalidPort)
            }
        }

        guard let url = URL(string: candidate) else {
            return .failure(.malformedAddress)
        }

        guard let host = url.host, !host.isEmpty else {
            return .failure(.missingHost)
        }

        return .success(url)
    }
}
