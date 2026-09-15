import BicTermCore
import Foundation

struct HopDraft: Identifiable, Equatable {
    let id = UUID()
    var host = ""
    var port = "22"
    var username = ""
    var offersKeys = true
    var customKeys: [String]?
    var passwordTag: String?
    var removePasswordOnSave = false
    /// Unsaved editor input — written to the Keychain only at connection-save
    /// time, never persisted with the model.
    var passwordInput = ""
    /// Verified by a local store probe, not inferred from the persisted tag.
    /// Drives the "Saved on this device" badge without prefilling the field.
    var hasSavedPassword = false
    var passwordEntryMissing = false
    var passwordWasProbed = false

    init() {}

    init(hop: Hop, keyLabel: String?) {
        host = hop.host
        port = String(hop.port)
        username = hop.username
        offersKeys = hop.offersKeys
        customKeys = hop.customKeys
        passwordTag = hop.passwordTag
    }

    var portValue: Int? { HopPort.parse(port) }

    mutating func stagePasswordRemoval() {
        removePasswordOnSave = true
        passwordTag = nil
        passwordInput = ""
        hasSavedPassword = false
        passwordEntryMissing = false
    }

    static func makePasswordTag() -> String {
        "bicterm.pwd.\(UUID().uuidString)"
    }

    var credentialSatisfied: Bool {
        true
    }

    var isComplete: Bool {
        ConnectionFieldValidation.isValidHostname(host)
            && HopPort.isValid(port)
            && ConnectionFieldValidation.isValidUsername(username)
            && credentialSatisfied
    }

    func makeHop() -> Hop? {
        guard let portValue else { return nil }
        return Hop(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            username: username,
            offersKeys: offersKeys,
            customKeys: customKeys,
            passwordTag: passwordTag
        )
    }
}

/// Editable mirror of `BicTermCore.Connection` bound to the editor's text
/// fields. UI validation mirrors the model invariants exactly: max 5 hops
/// (`Connection.maximumJumpChainLength`), cycle-free jump chain, and the
/// model's typed init remains the last line of defense at save time.
struct ConnectionDraft: Equatable {
    var id = UUID()
    var name = ""
    var protocolID = ProtocolDescriptor.ssh.id
    var host = ""
    var port = "22"
    var username = ""
    var offersKeys = true
    var customKeys: [String]?
    var passwordTag: String?
    var removePasswordOnSave = false
    /// Unsaved editor input — Keychain-only on save, never persisted.
    var passwordInput = ""
    var hasSavedPassword = false
    var passwordEntryMissing = false
    var hops: [HopDraft] = []
    var agentForwarding = false
    /// Herdr mode A (herdr-support plan todo 5): master switch persisted as
    /// the `herdrEnabled` protocol option.
    var herdrEnabled = false
    /// Optional remote herdr session name (`herdrSession` option); only
    /// persisted while ``herdrEnabled`` is on — the toggle is the sole
    /// authority for whether herdr applies at all.
    var herdrSessionName = ""

    init() {}

    init(connection: Connection, keyLabel: String?) {
        id = connection.id
        name = connection.name
        protocolID = connection.type.rawValue
        host = connection.host
        port = String(connection.port)
        username = connection.username
        offersKeys = connection.offersKeys
        customKeys = connection.customKeys
        passwordTag = connection.passwordTag
        hops = connection.jumpChain.map { HopDraft(hop: $0, keyLabel: nil) }
        agentForwarding = connection.protocolOptions["agentForwarding"]?.boolValue == true
        herdrEnabled = connection.herdrEnabled
        herdrSessionName = connection.herdrSessionName ?? ""
    }

    /// Duplicate-as-new: copies every editable value from `connection` —
    /// including the password Keychain tag, which the copy SHARES with the
    /// source (a retype overwrites in place for both; no entry is rewritten
    /// or re-created here) — but mints a fresh id and takes the
    /// caller-provided copy name, so saving inserts a new connection
    /// instead of overwriting the source.
    init(duplicating connection: Connection, name: String, keyLabel: String?) {
        self.init(connection: connection, keyLabel: keyLabel)
        id = UUID()
        self.name = name
    }

    var nameError: String? {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Name is required" : nil
    }

    var hostError: String? {
        ConnectionFieldValidation.hostnameError(host)
    }

    var portError: String? {
        HopPort.errorDescription(port, field: "Port")
    }

    var usernameError: String? {
        ConnectionFieldValidation.usernameError(username)
    }

    var keyError: String? {
        nil
    }

    /// Mirrors herdr's own session-name grammar (`HerdrCommandBuilder.isValidSessionName`)
    /// so a bad name surfaces in the editor instead of at connect time. Empty
    /// means "no session" and stays valid.
    var herdrSessionError: String? {
        guard herdrEnabled, !herdrSessionName.isEmpty else { return nil }
        let trimmed = herdrSessionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return HerdrCommandBuilder.isValidSessionName(trimmed)
            ? nil
            : "Session names use letters, numbers, dots, underscores, and hyphens, and start with a letter or number"
    }

    var passwordError: String? {
        return nil
    }

    mutating func stagePasswordRemoval() {
        removePasswordOnSave = true
        passwordTag = nil
        passwordInput = ""
        hasSavedPassword = false
        passwordEntryMissing = false
    }

    var hopErrors: [Int: String] {
        var errors: [Int: String] = [:]
        for (index, hop) in hops.enumerated() {
            if hop.host.trimmingCharacters(in: .whitespaces).isEmpty {
                errors[index] = "Hop host is required"
            } else if !ConnectionFieldValidation.isValidHostname(hop.host) {
                errors[index] = "Invalid hop hostname"
            } else if !HopPort.isValid(hop.port) {
                errors[index] = "Invalid hop port"
            } else if !ConnectionFieldValidation.isValidUsername(hop.username) {
                errors[index] = "Hop username is required"
            }
        }
        return errors
    }

    /// Cycle detection over `[hops..., destination]` keyed by
    /// `(lowercased host, port)` — the same rule the T9 jump builder
    /// applies at connect time; the UI refuses to persist such a chain.
    var hasCycle: Bool {
        var seen = Set<String>()
        for entry in hops {
            guard let key = cycleKey(host: entry.host, port: entry.port) else { continue }
            if !seen.insert(key).inserted { return true }
        }
        guard let destinationKey = cycleKey(host: host, port: port) else { return false }
        return seen.contains(destinationKey)
    }

    private func cycleKey(host: String, port: String) -> String? {
        guard ConnectionFieldValidation.isValidHostname(host),
              let portValue = HopPort.parse(port)
        else { return nil }
        return "\(host.trimmingCharacters(in: .whitespaces).lowercased()):\(portValue)"
    }

    var hopLimitReached: Bool {
        hops.count >= Connection.maximumJumpChainLength
    }

    var isValid: Bool {
        ConnectionType(rawValue: protocolID) != nil
            && nameError == nil
            && hostError == nil
            && portError == nil
            && usernameError == nil
            && keyError == nil
            && passwordError == nil
            && herdrSessionError == nil
            && hopErrors.isEmpty
            && !hasCycle
            && hops.count <= Connection.maximumJumpChainLength
    }

    func makeConnection() throws -> Connection {
        guard let type = ConnectionType(rawValue: protocolID) else {
            throw ConnectionDraftValidationError.unknownProtocol(protocolID)
        }
        guard nameError == nil,
              hostError == nil,
              portError == nil,
              usernameError == nil,
              keyError == nil,
              passwordError == nil,
              herdrSessionError == nil,
              !hasCycle,
              hops.count <= Connection.maximumJumpChainLength
        else {
            throw ConnectionDraftValidationError.invalidConnection
        }
        guard let destinationPort = HopPort.parse(port) else {
            throw ConnectionDraftValidationError.invalidConnection
        }
        var jumpChain: [Hop] = []
        for (index, hop) in hops.enumerated() {
            guard hop.isComplete, let value = hop.makeHop() else {
                throw ConnectionDraftValidationError.invalidHop(index: index + 1)
            }
            jumpChain.append(value)
        }
        var optionValues: [String: ProtocolOptionValue] = [:]
        if agentForwarding {
            optionValues["agentForwarding"] = .bool(true)
        }
        if herdrEnabled {
            optionValues[ProtocolOptions.herdrEnabledKey] = .bool(true)
            let trimmedSession = herdrSessionName.trimmingCharacters(in: .whitespaces)
            if !trimmedSession.isEmpty {
                optionValues[ProtocolOptions.herdrSessionKey] = .string(trimmedSession)
            }
        }
        var options = ProtocolOptions()
        if !optionValues.isEmpty {
            options = try ProtocolOptions(optionValues)
        }
        return try Connection(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            type: type,
            host: host.trimmingCharacters(in: .whitespaces),
            port: destinationPort,
            username: username.trimmingCharacters(in: .whitespaces),
            offersKeys: offersKeys,
            customKeys: customKeys,
            passwordTag: passwordTag,
            jumpChain: jumpChain,
            protocolOptions: options
        )
    }
}

enum ConnectionDraftValidationError: LocalizedError, Equatable {
    case unknownProtocol(String)
    case invalidConnection
    case invalidHop(index: Int)

    var errorDescription: String? {
        switch self {
        case let .unknownProtocol(protocolID):
            "Protocol \"\(protocolID)\" is not recognized. Choose an available protocol before saving."
        case .invalidConnection:
            "Complete the required connection fields and resolve any jump-chain errors."
        case let .invalidHop(index):
            "Hop \(index) is incomplete or invalid. Review its host, port, username, and key."
        }
    }
}

enum HopPort {
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else { return nil }
        return (1...65_535).contains(value) ? value : nil
    }

    static func isValid(_ text: String) -> Bool {
        parse(text) != nil
    }

    static func errorDescription(_ text: String, field: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "\(field) is required" }
        guard Int(trimmed) != nil else { return "\(field) must be a number" }
        guard parse(trimmed) != nil else { return "\(field) must be 1–65535" }
        return nil
    }
}

/// RFC 1123 hostname / IPv4 / IPv6-literal validation shared by the
/// connection editor and per-hop sheets. Underscores and other symbols are
/// rejected so typos surface inline instead of at connect time.
enum ConnectionFieldValidation {
    static func hostnameError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Host is required" }
        if isValidHostname(trimmed) { return nil }
        return "Invalid hostname"
    }

    static func usernameError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Username is required" }
        if trimmed.contains(where: \.isWhitespace) { return "Username cannot contain spaces" }
        return nil
    }

    static func isValidUsername(_ text: String) -> Bool {
        usernameError(text) == nil
    }

    static func isValidHostname(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        if isValidIPv4(trimmed) || isValidIPv6Literal(trimmed) { return true }
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard label.count <= 63, label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    private static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard part.count <= 3, let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func isValidIPv6Literal(_ text: String) -> Bool {
        guard text.contains(":") else { return false }
        let groups = text.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count <= 8 else { return false }
        return groups.allSatisfy { group in
            group.isEmpty || (group.count <= 4 && group.allSatisfy { $0.isHexDigit })
        }
    }
}
