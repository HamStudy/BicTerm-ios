import Foundation
import SwiftData

@ModelActor
public actor SwiftDataSnippetStore: SnippetStoreProtocol {
    public func loadSnippets() async throws(PersistenceError) -> [Snippet] {
        do {
            return Snippet.deterministicallyOrdered(try decodedSnippets())
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load snippets")
            }
        }
    }

    public func snippet(id: UUID) async throws(PersistenceError) -> Snippet? {
        do {
            guard let record = try storedSnippet(id: id) else { return nil }
            return try decodeSkippingQuarantined(record.payload)
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load snippet")
            }
        }
    }

    public func snippets(connectionID: UUID) async throws(PersistenceError) -> [Snippet] {
        do {
            let visible = try decodedSnippets().filter {
                $0.connectionID == nil || $0.connectionID == connectionID
            }
            return Snippet.deterministicallyOrdered(visible)
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load snippets for connection")
            }
        }
    }

    public func save(_ snippet: Snippet) async throws(PersistenceError) {
        do {
            let existing = try decodedSnippets()
            if existing.contains(where: {
                $0.id != snippet.id
                    && $0.connectionID == snippet.connectionID
                    && $0.name == snippet.name
            }) {
                throw PersistenceError.duplicateSnippetName(snippet.name)
            }
            let sequence: Int
            if let current = existing.first(where: { $0.id == snippet.id }) {
                sequence = current.creationSequence
            } else {
                sequence = (existing.map(\.creationSequence).max() ?? 0) + 1
            }
            let persisted = snippet.withCreationSequence(sequence)
            let payload = try PersistenceCodec.encode(persisted, modelName: "Snippet")
            if let record = try storedSnippet(id: snippet.id) {
                record.payload = payload
            } else {
                modelContext.insert(StoredSnippet(id: persisted.id, payload: payload))
            }
            try modelContext.save()
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("save snippet")
            }
        }
    }

    public func deleteSnippet(id: UUID) async throws(PersistenceError) {
        do {
            guard let record = try storedSnippet(id: id) else { return }
            modelContext.delete(record)
            try modelContext.save()
        } catch {
            throw .operationFailed("delete snippet")
        }
    }

    public func deleteSnippets(connectionID: UUID) async throws(PersistenceError) {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredSnippet>())
            var matched = false
            for record in records {
                guard let snippet = try decodeSkippingQuarantined(record.payload),
                      snippet.connectionID == connectionID else { continue }
                modelContext.delete(record)
                matched = true
            }
            if matched { try modelContext.save() }
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("delete connection snippets")
            }
        }
    }

    /// Quarantine: same policy as the configuration and herd stores —
    /// payloads that fail decode are skipped on load, never a wholesale
    /// store failure.
    private func decodeSkippingQuarantined(_ payload: Data) throws(PersistenceError) -> Snippet? {
        do {
            return try PersistenceCodec.decode(Snippet.self, from: payload, modelName: "Snippet")
        } catch {
            // Force cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; do-block error type is exactly PersistenceError.
            let error = error as! PersistenceError
            if case .decodingFailed = error { return nil }
            throw error
        }
    }

    private func decodedSnippets() throws(PersistenceError) -> [Snippet] {
        do {
            let records = try modelContext.fetch(FetchDescriptor<StoredSnippet>())
            var snippets: [Snippet] = []
            snippets.reserveCapacity(records.count)
            for record in records {
                if let snippet = try decodeSkippingQuarantined(record.payload) {
                    snippets.append(snippet)
                }
            }
            return snippets
        } catch {
            // Conditional cast: swift-frontend 6.4 SILGen assertion on catch-as in typed-throws funcs; preserves the typed-vs-fallback clause split.
            if let error = error as? PersistenceError {
                throw error
            } else {
                throw .operationFailed("load snippets")
            }
        }
    }

    private func storedSnippet(id: UUID) throws -> StoredSnippet? {
        var descriptor = FetchDescriptor<StoredSnippet>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
