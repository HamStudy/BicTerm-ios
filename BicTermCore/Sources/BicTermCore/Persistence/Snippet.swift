import Foundation

public enum SnippetValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyCommand
}

/// A reusable terminal command snippet. Global snippets (`connectionID`
/// nil) are available in every session; scoped snippets belong to one
/// connection and are removed when that connection is deleted.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Trimmed at creation; never empty.
    public let name: String
    /// Exact command bytes; never empty or whitespace-only.
    public let command: String
    /// Owning connection; nil = global.
    public let connectionID: UUID?
    /// Store-assigned creation order. Queries sort by
    /// (creationSequence, name); the store assigns the sequence on insert
    /// and preserves it on update.
    public let creationSequence: Int

    /// Creates a snippet. The store assigns `creationSequence` on first
    /// save; the value here is a placeholder.
    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        connectionID: UUID? = nil
    ) throws(SnippetValidationError) {
        try self.init(
            id: id,
            name: name,
            command: command,
            connectionID: connectionID,
            creationSequence: 0
        )
    }

    /// Full-field init (validating): decode path and store resequencing.
    init(
        id: UUID,
        name: String,
        command: String,
        connectionID: UUID?,
        creationSequence: Int
    ) throws(SnippetValidationError) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw .emptyName }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyCommand
        }
        self.id = id
        self.name = trimmedName
        self.command = command
        self.connectionID = connectionID
        self.creationSequence = creationSequence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            command: try container.decode(String.self, forKey: .command),
            connectionID: try container.decodeIfPresent(UUID.self, forKey: .connectionID),
            creationSequence: try container.decodeIfPresent(Int.self, forKey: .creationSequence) ?? 0
        )
    }

    /// The same snippet under a different creation sequence — store
    /// resequencing. The receiver is already valid, so validation is not
    /// repeated.
    func withCreationSequence(_ creationSequence: Int) -> Snippet {
        Snippet(copying: self, creationSequence: creationSequence)
    }

    private init(copying source: Snippet, creationSequence: Int) {
        self.id = source.id
        self.name = source.name
        self.command = source.command
        self.connectionID = source.connectionID
        self.creationSequence = creationSequence
    }

    /// Deterministic presentation order: creation sequence, then name.
    static func deterministicallyOrdered(_ snippets: [Snippet]) -> [Snippet] {
        snippets.sorted {
            ($0.creationSequence, $0.name) < ($1.creationSequence, $1.name)
        }
    }
}
