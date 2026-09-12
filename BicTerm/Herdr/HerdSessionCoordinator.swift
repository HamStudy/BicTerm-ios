import BicTermCore
import Foundation
import Observation

/// Herd mode coordinator (herdr-support plan todo 8): opening a herd opens
/// ONE workspace whose model carries one endpoint per machine, then
/// connects every machine in the background — one connector pass per herd
/// (deduped while in flight), per-endpoint failure isolation (a failed or
/// attention-needing machine never blocks the others), and selection that
/// drives the model's `selectedEndpointID` (the surface-interest pointer)
/// with the last-selected machine persisted per herd.
@MainActor
@Observable
final class HerdSessionCoordinator {
    typealias MachineDescriptor = HerdMachineDescriptor

    struct TrustPrompt: Identifiable {
        let id = UUID()
        let challenge: HerdrHostTrustChallenge
        let continuation: CheckedContinuation<Bool, Never>
    }

    typealias MachineConnect = @Sendable (
        _ connection: Connection,
        _ hostKeyVerifier: HostKeyVerifier?
    ) async throws(HerdrEndpointConnectorError) -> any HerdrByteTransport

    typealias ConnectionLookup = @Sendable (_ id: UUID) async -> Connection?

    private let center: HerdrWorkspaceCenter
    private let connectMachineSeam: MachineConnect?
    private let lookupConnection: ConnectionLookup
    private let defaults: UserDefaults

    private var inFlightHerds: Set<UUID> = []
    private var selections: [UUID: HerdrEndpointID] = [:]
    var trustPrompt: TrustPrompt?

    #if DEBUG
    private(set) var debugConnectAttempts = 0
    #endif

    init(
        center: HerdrWorkspaceCenter = .shared,
        defaults: UserDefaults = .standard,
        connectMachine: MachineConnect? = nil,
        lookupConnection: @escaping ConnectionLookup = HerdSessionCoordinator.liveLookup()
    ) {
        self.center = center
        self.defaults = defaults
        self.lookupConnection = lookupConnection
        self.connectMachineSeam = connectMachine
    }

    private var connectMachine: MachineConnect {
        connectMachineSeam ?? Self.liveConnector(
            approve: { [weak self] challenge in
                await self?.approve(challenge) ?? false
            }
        )
    }


    // MARK: - Open

    /// Re-entrant opens of the same herd yield ONE connect pass: the guard
    /// holds until every machine attempt has settled (connected, failed, or
    /// orphaned-skipped).
    func open(
        _ herd: Herd,
        hostKeyVerifier: HostKeyVerifier?,
        present: @escaping (UUID) -> Void
    ) {
        guard !inFlightHerds.contains(herd.id) else { return }
        inFlightHerds.insert(herd.id)

        Task { @MainActor in
            var machines: [HerdMachineDescriptor] = []
            var resolvable: [(machine: HerdMachine, connection: Connection)] = []
            for machine in herd.machines {
                let connection = await lookupConnection(machine.connectionID)
                machines.append(HerdMachineDescriptor(
                    endpointID: HerdDescriptor.endpointID(
                        herdID: herd.id, connectionID: machine.connectionID
                    ),
                    connectionID: machine.connectionID,
                    label: machine.label ?? connection?.name ?? "Missing connection",
                    sessionName: machine.sessionName
                ))
                if let connection {
                    resolvable.append((machine, connection))
                }
            }

            let descriptor = HerdDescriptor(
                herdID: herd.id, herdName: herd.name, machines: machines
            )
            let sessionID = center.openHerd(descriptor)
            guard let entry = center.entry(id: sessionID) else {
                inFlightHerds.remove(herd.id)
                return
            }
            let model = entry.model
            let restored = descriptor.restoredSelection(defaults: defaults)
            model.selectedEndpointID = restored?.endpointID
            if let endpoint = restored?.endpointID {
                selections[herd.id] = endpoint
            }
            // Connectable machines read Connecting from the moment the
            // workspace opens; only orphaned machines (no resolvable
            // connection) render Offline with no endpoint state at all.
            for item in resolvable {
                let endpointID = HerdDescriptor.endpointID(
                    herdID: herd.id, connectionID: item.machine.connectionID
                )
                if model.endpoints[endpointID] == nil {
                    model.endpoints[endpointID] = HerdrEndpointState()
                }
            }
            present(sessionID)

            #if DEBUG
            if HerdrWorkspaceUITest.liveConnectEnabled {
                HerdrWorkspaceUITest.startHerdInjectionWhenReady(model: model)
            }
            #endif

            let machineTasks = resolvable.map { item in
                Task { @MainActor in
                    await self.connectOne(
                        machine: item.machine,
                        connection: item.connection,
                        endpointID: HerdDescriptor.endpointID(
                            herdID: herd.id, connectionID: item.machine.connectionID
                        ),
                        herdID: herd.id,
                        model: model,
                        hostKeyVerifier: hostKeyVerifier
                    )
                }
            }
            for task in machineTasks {
                await task.value
            }
            inFlightHerds.remove(herd.id)

        }
    }

    private func connectOne(
        machine: HerdMachine,
        connection: Connection,
        endpointID: HerdrEndpointID,
        herdID: UUID,
        model: HerdrSessionModel,
        hostKeyVerifier: HostKeyVerifier?
    ) async {
        #if DEBUG
        debugConnectAttempts += 1
        #endif
        do {
            let endpointConnection = try Self.connection(
                connection, sessionName: machine.sessionName
            )
            let transport = try await connectMachine(endpointConnection, hostKeyVerifier)
            // Per-endpoint runtime with its own budgets (the model's T19
            // machinery): connect() hands this endpoint its own client,
            // watchdog, and reconnect bookkeeping.
            model.connect(endpoint: endpointID, transport: transport)
            // connect() points selection at the endpoint it just wired;
            // the herd's chosen machine stays the selected one.
            model.selectedEndpointID = selections[herdID]
        } catch let error as HerdrEndpointConnectorError {
            presentFailure(error, endpointID: endpointID, model: model)
        } catch {
            presentFailure(
                .sshEstablish(.channelDenied), endpointID: endpointID, model: model
            )
        }
    }

    private func presentFailure(
        _ error: HerdrEndpointConnectorError,
        endpointID: HerdrEndpointID,
        model: HerdrSessionModel
    ) {
        switch error {
        case .trustDeclined:
            return
        case let .invalidSessionName(name):
            model.failConnect(
                endpoint: endpointID,
                diagnostic: .simple(
                    .transportLost,
                    detail: "The Remote Session name “\(name)” isn’t valid for herdr."
                )
            )
        case let .incompatibleEndpoint(result, _):
            model.failProbe(endpoint: endpointID, result: result)
        case let .probeFailed(cause):
            model.failConnect(
                endpoint: endpointID,
                diagnostic: .simple(.transportLost, detail: Self.probeDetail(of: cause))
            )
        case let .sshEstablish(cause), let .bridgeChannelFailed(cause):
            model.failConnect(
                endpoint: endpointID,
                diagnostic: Self.diagnostic(for: cause)
            )
        }
    }

    // MARK: - Selection

    /// User-driven machine switch: updates surface interest immediately and
    /// persists the choice as this herd's last-selected machine.
    func select(_ machine: MachineDescriptor, in model: HerdrSessionModel) {
        guard let herd = center.entries.first(where: { $0.model === model })?.herd
        else { return }
        selections[herd.herdID] = machine.endpointID
        herd.apply(machine, in: model, defaults: defaults)
    }


    /// The machine's herd-local session name fully overrides whatever the
    /// underlying connection carries; nil falls back to the connection's.
    static func connection(_ connection: Connection, sessionName: String?) throws -> Connection {
        guard let sessionName, !sessionName.isEmpty else { return connection }
        var values = connection.protocolOptions.values
        values[ProtocolOptions.herdrSessionKey] = .string(sessionName)
        let options = try ProtocolOptions(values)
        return try Connection(
            id: connection.id,
            name: connection.name,
            type: connection.type,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            keyReference: connection.keyReference,
            authMethod: connection.authMethod,
            jumpChain: connection.jumpChain,
            protocolOptions: options
        )
    }

    // MARK: - Trust prompt

    func resolveTrustPrompt(_ approved: Bool) {
        guard let prompt = trustPrompt else { return }
        trustPrompt = nil
        prompt.continuation.resume(returning: approved)
    }

    private func approve(_ challenge: HerdrHostTrustChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            trustPrompt = TrustPrompt(challenge: challenge, continuation: continuation)
        }
    }

    // MARK: - Failure mapping (T4 error-enum contract, per machine)

    private static func diagnostic(for cause: SSHTransportError) -> HerdrDiagnostic {
        switch cause {
        case .authenticationFailed, .authRequired:
            .simple(.authLost, detail: cause.localizedDescription)
        default:
            .simple(.transportLost, detail: cause.localizedDescription)
        }
    }

    private static func probeDetail(of cause: HerdrProbe.ProbeError) -> String {
        switch cause {
        case .execChannelFailed:
            "the herdr probe channel could not open on the host"
        case let .hostileSearchPath(path):
            "refused an unsafe herdr search path: \(path)"
        }
    }

    // MARK: - Live wiring

    static func liveLookup() -> ConnectionLookup {
        { id in
            try? await AppServices.shared.connectionStore.connection(id: id)
        }
    }

    static func liveConnector(
        approve: @escaping @Sendable (HerdrHostTrustChallenge) async -> Bool
    ) -> MachineConnect {
        let searchPaths = liveSearchPaths()
        return { connection, hostKeyVerifier in
            let verifier: HostKeyVerifier
            #if DEBUG
            if HerdrWorkspaceUITest.untrustedStoreRequested {
                verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
            } else if let hostKeyVerifier {
                verifier = hostKeyVerifier
            } else {
                verifier = HostKeyVerifier(
                    store: await SessionStore.defaultHostKeyStoreForLiveUse()
                )
            }
            #else
            if let hostKeyVerifier {
                verifier = hostKeyVerifier
            } else {
                verifier = HostKeyVerifier(
                    store: await SessionStore.defaultHostKeyStoreForLiveUse()
                )
            }
            #endif
            let connector = HerdrEndpointConnector(
                hostKeyVerifier: verifier,
                searchPaths: searchPaths,
                approveHostKey: approve
            )
            return try await connector.connect(connection)
        }
    }

    private static func liveSearchPaths() -> [String] {
        #if DEBUG
        if let override = HerdrWorkspaceUITest.probeSearchPathsForLiveConnect {
            return override
        }
        #endif
        return HerdrProbe.defaultSearchPaths
    }
}

