import BicTermCore
import Foundation
import Observation

/// Live herdr workspace sessions keyed by window/session id — the herdr
/// counterpart of the SSH side's SessionStore. T16 opens replay-backed
/// sessions; T19's endpoint profiles will open real SSH-backed ones through
/// the same registry so every herdr window keeps its own model and scene
/// identity (integration doc §3.5: selection/focus is per scene).
@MainActor
@Observable
final class HerdrWorkspaceCenter {
    static let shared = HerdrWorkspaceCenter()

    struct Entry: Identifiable {
        let id: UUID
        let label: String
        let model: HerdrSessionModel
        let herd: HerdDescriptor?
        /// HERDR_EMBED Mode A (plan herdr-embed T5): the connection whose
        /// SSH carrier backs the embedded client's bridge transport. Nil on
        /// the legacy fixture/harness path and on herd entries (T6).
        let embedConnection: Connection?

        init(
            id: UUID,
            label: String,
            model: HerdrSessionModel,
            herd: HerdDescriptor? = nil,
            embedConnection: Connection? = nil
        ) {
            self.id = id
            self.label = label
            self.model = model
            self.herd = herd
            self.embedConnection = embedConnection
        }
    }

    private(set) var entries: [Entry] = []

    func open(connect: (HerdrSessionModel) -> String) -> UUID {
        let id = UUID()
        let model = HerdrSessionModel()
        let label = connect(model)
        entries.append(Entry(id: id, label: label, model: model))
        return id
    }

    /// Mode A embedded workspace (plan herdr-embed T5): the connection
    /// rides the entry so the embed runtime can establish its SSH bridge.
    func openEmbed(connection: Connection) -> UUID {
        let id = UUID()
        let model = HerdrSessionModel()
        entries.append(
            Entry(id: id, label: connection.name, model: model, embedConnection: connection)
        )
        return id
    }

    /// Herd workspace: one model shared by every machine endpoint, plus the
    /// machine catalog the chrome renders its switcher from.
    func openHerd(_ herd: HerdDescriptor) -> UUID {
        let id = UUID()
        let model = HerdrSessionModel()
        entries.append(Entry(id: id, label: herd.herdName, model: model, herd: herd))
        return id
    }

    func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    func close(id: UUID) async {
        if let entry = entries.first(where: { $0.id == id }) {
            await entry.model.disconnectAll()
        }
        entries.removeAll { $0.id == id }
    }
}
