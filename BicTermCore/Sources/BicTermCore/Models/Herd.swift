import Foundation

public enum HerdValidationError: Error, Equatable, Sendable {
    case emptyName
    case duplicateConnectionID(UUID)
    case sessionNameTooLong(maximum: Int, actual: Int)
    case sessionNameContainsNewlines
}

/// One machine in a herd: a reference to an existing SSH connection plus
/// herd-local display overrides. The connection itself lives in the
/// configuration store; deleting it leaves an orphan machine the herd UI
/// renders as "Missing connection".
public struct HerdMachine: Codable, Equatable, Sendable {
    public static let maximumSessionNameLength = 64

    public let connectionID: UUID
    /// Optional display label overriding the connection's name in herd chrome.
    public let label: String?
    /// Optional herdr session name for this machine's endpoint.
    public let sessionName: String?

    public init(
        connectionID: UUID,
        label: String? = nil,
        sessionName: String? = nil
    ) throws(HerdValidationError) {
        if let sessionName {
            guard sessionName.count <= Self.maximumSessionNameLength else {
                throw .sessionNameTooLong(
                    maximum: Self.maximumSessionNameLength,
                    actual: sessionName.count
                )
            }
            guard !sessionName.contains(where: { $0.isNewline }) else {
                throw .sessionNameContainsNewlines
            }
        }

        self.connectionID = connectionID
        self.label = label
        self.sessionName = sessionName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            connectionID: container.decode(UUID.self, forKey: .connectionID),
            label: container.decodeIfPresent(String.self, forKey: .label),
            sessionName: container.decodeIfPresent(String.self, forKey: .sessionName)
        )
    }
}

/// A named herd of existing SSH connections opened together in one herdr
/// workspace with a machine switcher.
public struct Herd: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let machines: [HerdMachine]

    public init(
        id: UUID = UUID(),
        name: String,
        machines: [HerdMachine] = []
    ) throws(HerdValidationError) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyName
        }

        var seenConnectionIDs = Set<UUID>()
        for machine in machines where !seenConnectionIDs.insert(machine.connectionID).inserted {
            throw .duplicateConnectionID(machine.connectionID)
        }

        self.id = id
        self.name = name
        self.machines = machines
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            machines: container.decode([HerdMachine].self, forKey: .machines)
        )
    }
}
