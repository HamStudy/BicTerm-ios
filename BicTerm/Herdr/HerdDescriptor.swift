import BicTermCore
import Foundation

/// One machine of an open herd, as the workspace chrome sees it: endpoint
/// identity plus display data resolved from the herd definition and its
/// connection at open time.
struct HerdMachineDescriptor: Identifiable, Sendable, Equatable {
    let endpointID: HerdrEndpointID
    let connectionID: UUID
    let label: String
    let sessionName: String?

    var id: String { endpointID.rawValue }
}

/// The machine catalog of one open herd workspace: one model carries one
/// endpoint per machine behind a single surface-interest selection.
struct HerdDescriptor: Sendable, Equatable {
    let herdID: UUID
    let herdName: String
    let machines: [HerdMachineDescriptor]

    static func endpointID(herdID: UUID, connectionID: UUID) -> HerdrEndpointID {
        HerdrEndpointID(
            rawValue: "herd/\(herdID.uuidString)/machine/\(connectionID.uuidString)"
        )
    }

    static func selectionKey(herdID: UUID) -> String {
        "herd.selectedMachine.\(herdID.uuidString)"
    }

    /// Selection application shared by every presentation surface (the
    /// iPhone cover's coordinator, iPad herd windows): point the model's
    /// surface interest at the machine and persist the herd's choice.
    @MainActor
    func apply(
        _ machine: HerdMachineDescriptor,
        in model: HerdrSessionModel,
        defaults: UserDefaults = .standard
    ) {
        model.selectedEndpointID = machine.endpointID
        defaults.set(
            machine.connectionID.uuidString,
            forKey: Self.selectionKey(herdID: herdID)
        )
        #if DEBUG
        model.debugRecordEcho("chip:\(machine.label)")
        #endif
    }

    /// The machine persisted as this herd's last selection, else the first.
    func restoredSelection(defaults: UserDefaults) -> HerdMachineDescriptor? {
        let persisted = defaults
            .string(forKey: Self.selectionKey(herdID: herdID))
            .flatMap(UUID.init(uuidString:))
        if let persisted,
           let machine = machines.first(where: { $0.connectionID == persisted }) {
            return machine
        }
        return machines.first
    }
}
