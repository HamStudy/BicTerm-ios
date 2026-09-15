import BicTermCore
import Foundation
import Observation

/// One machine in the embedded client's endpoint catalog (plan herdr-embed
/// T5): the profile the Rust client dials through
/// `{HERDR_EMBED_TRANSPORT_DIR}/{profile id}.sock`. T6 seeds N machines
/// into the same catalog, each profile id backed by its own bridge socket.
struct HerdrEmbedMachine: Equatable, Sendable {
    let profileID: String
    let label: String
    let target: String
    let sessionName: String

    static func profileID(for connectionID: UUID) -> String {
        connectionID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// Catalog entry derived from a connection (Mode A and each herd
    /// machine use the same derivation).
    static func forConnection(_ connection: Connection) -> HerdrEmbedMachine {
        HerdrEmbedMachine(
            profileID: profileID(for: connection.id),
            label: connection.name,
            target: "\(connection.username)@\(connection.host):\(connection.port)",
            sessionName: connection.herdrSessionName ?? "default"
        )
    }
}

/// One herd machine's transport link (plan herdr-embed T6): the catalog
/// entry plus the connection that backs it. `connection` carries the
/// herd-local session-name override (applied at link-build time the same
/// way `HerdSessionCoordinator.connection(_:sessionName:)` applies it for
/// the native path), so the probe and the bridge both see it.
struct HerdrEmbedMachineLink: Equatable, Sendable {
    let machine: HerdrEmbedMachine
    let connection: Connection
    /// Session name for the bridge command; nil = herdr's default (mirrors
    /// the connection's raw `herdrSessionName` semantics from T5).
    let bridgeSessionName: String?
}

/// Seeds the embedded client's saved-endpoint catalog and transport
/// environment: herdr's client reads `endpoints.json` +
/// `endpoint-selection.json` from `{XDG_STATE_HOME}/herdr/client/` and, with
/// the `bicterm-transport` build, dials every enabled SSH profile through
/// the host bridge socket instead of an `ssh` subprocess.
enum HerdrEmbedClientCatalog {
    /// `sockaddr_un.sun_path` holds 104 bytes on Darwin and the app
    /// container's absolute paths exceed that, so the transport directory
    /// is a SHORT RELATIVE path resolved against the pinned process cwd
    /// (both the Swift listener and the in-process Rust client share it).
    static let transportDirectoryName = "herdr-embed-transport"

    /// Re-seeding semantics (T6): the file set is rewritten atomically per
    /// open — machines added/removed in the herd editor are reflected on
    /// the NEXT open of that herd; a live embedded instance is NOT
    /// re-seeded mid-run (v1 single-instance rule).
    static func seed(
        machines: [HerdrEmbedMachine],
        selectedProfileID: String?,
        stateHome: URL
    ) throws {
        let clientDirectory = stateHome
            .appendingPathComponent("herdr/client", isDirectory: true)
        try FileManager.default.createDirectory(
            at: clientDirectory,
            withIntermediateDirectories: true
        )
        var catalog: [String: Any] = [
            "version": 1,
            "ssh": machines.map { machine in
                [
                    "id": machine.profileID,
                    "label": machine.label,
                    "target": machine.target,
                    "session": machine.sessionName,
                    "enabled": true,
                ]
            },
        ]
        if let selectedProfileID {
            catalog["selected_profile"] = selectedProfileID
        }
        try writeJSON(
            catalog,
            to: clientDirectory.appendingPathComponent("endpoints.json")
        )
        try writeJSON(
            ["version": 1, "selected_profile": selectedProfileID ?? ""],
            to: clientDirectory.appendingPathComponent("endpoint-selection.json")
        )
    }

    static func applyEnvironment(transportDirectory: String, stateHome: URL) {
        setenv("HERDR_EMBED_TRANSPORT_DIR", transportDirectory, 1)
        setenv("XDG_STATE_HOME", stateHome.path(percentEncoded: false), 1)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}

/// Resolves an open herd into transport links (plan herdr-embed T6): one
/// connection lookup per machine, with the machine's herd-local session
/// name applied the same way the native herd path applies it
/// (`HerdSessionCoordinator.connection(_:sessionName:)`), so the probe and
/// the bridge both see the override. Machines whose connection no longer
/// resolves are skipped (the client catalog reflects the rest).
enum HerdrEmbedHerdSeeder {
    @MainActor
    static func links(
        for herd: HerdDescriptor,
        lookup: HerdSessionCoordinator.ConnectionLookup = HerdSessionCoordinator.liveLookup()
    ) async -> [HerdrEmbedMachineLink] {
        var links: [HerdrEmbedMachineLink] = []
        for machine in herd.machines {
            guard let connection = await lookup(machine.connectionID) else { continue }
            let effective = (try? HerdSessionCoordinator.connection(
                connection, sessionName: machine.sessionName
            )) ?? connection
            links.append(HerdrEmbedMachineLink(
                machine: HerdrEmbedMachine(
                    profileID: HerdrEmbedMachine.profileID(for: effective.id),
                    label: machine.label,
                    target: "\(effective.username)@\(effective.host):\(effective.port)",
                    sessionName: effective.herdrSessionName ?? "default"
                ),
                connection: effective,
                bridgeSessionName: effective.herdrSessionName
            ))
        }
        return links
    }
}

/// Typed failure of one embedded-transport bring-up. `.cancelled` is the
/// cooperative-cancellation outcome: the runtime stopped the bring-up and
/// `prepare()` unwound its bridges, carriers, and pinned cwd.
enum HerdrEmbedTransportFailure: Error {
    case connector(HerdrEndpointConnectorError)
    case bridge(HerdrEmbedBridgeError)
    case cancelled
}

/// Drives the embedded client's SSH transport (plan herdr-embed T5/T6):
/// N machines (Mode A = 1; a herd = one link per machine) → TOFU-gated
/// establish + probe per machine (the SAME ``HerdrEndpointConnector`` flow
/// the native workspace rides) → one ``HerdrEmbedBridgeServer`` listening
/// at each machine's expected socket path → the client catalog seeded with
/// every machine. Bring-up failure isolation mirrors the native herd: one
/// dead machine never blocks the others (it stays in the catalog and the
/// client renders its own dial-failure state); only a TOTAL failure
/// surfaces as a transport error. The coordinator owns the cwd pin
/// (relative bridge socket paths) and restores it at teardown.
@MainActor
@Observable
final class HerdrEmbedTransportCoordinator {
    struct TrustPrompt: Identifiable {
        let id = UUID()
        let challenge: HerdrHostTrustChallenge
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Byte-flow + lifecycle lines surfaced to the runtime (evidence log);
    /// each line is prefixed with its machine's label.
    private(set) var eventLines: [String] = []

    private(set) var trustPrompt: TrustPrompt?
    private var queuedTrustPrompts: [TrustPrompt] = []

    private let links: [HerdrEmbedMachineLink]
    /// Profile the client should select at boot (the herd's persisted
    /// machine choice); nil = first catalog machine.
    private let preferredSelection: String?
    private let connectorFactory: (@Sendable () async -> HerdrEndpointConnector)?
    private let providedVerifier: HostKeyVerifier?
    private let authenticationKeyProvider: (@Sendable () async -> any SSHAuthenticationKeyProvider)?
    private let searchPaths: [String]

    private var servers: [HerdrEmbedBridgeServer] = []
    private var carriers: [String: any SSHExecCapableConnection] = [:]
    private var previousCWD: String?
    /// Per-machine establish tasks of the in-flight prepare() — cancelled
    /// when the bring-up is cancelled so their awaits unwind.
    private var establishTasks: [Task<Result<HerdrProbedCarrier, HerdrEmbedTransportFailure>, Never>] = []
    /// Set by the cancellation handler while prepare() is in flight; every
    /// post-suspension resume in prepare() checks it and unwinds.
    private var prepareCancelled = false

    init(
        connection: Connection,
        hostKeyVerifier: HostKeyVerifier?,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = [Self.link(for: connection)]
        self.preferredSelection = nil
        self.providedVerifier = hostKeyVerifier
        self.searchPaths = searchPaths
        self.connectorFactory = nil
        self.authenticationKeyProvider = nil
    }

    /// Trust-prompt-coverable bring-up with an injected authentication
    /// key (the fixture path in tests: the app process holds no Keychain
    /// entry for fixture keys, and TOFU challenges must reach this
    /// coordinator's prompt queue, not a factory closure's answer).
    init(
        connection: Connection,
        hostKeyVerifier: HostKeyVerifier?,
        authenticationKeyProvider: @escaping @Sendable () async -> any SSHAuthenticationKeyProvider,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = [Self.link(for: connection)]
        self.preferredSelection = nil
        self.providedVerifier = hostKeyVerifier
        self.searchPaths = searchPaths
        self.authenticationKeyProvider = authenticationKeyProvider
        self.connectorFactory = nil
    }

    init(connection: Connection, connector: @escaping @Sendable () async -> HerdrEndpointConnector) {
        self.links = [Self.link(for: connection)]
        self.preferredSelection = nil
        self.connectorFactory = connector
        self.providedVerifier = nil
        self.authenticationKeyProvider = nil
        self.searchPaths = HerdrProbe.defaultSearchPaths
    }

    /// Herd bring-up (plan herdr-embed T6): one link per machine, each with
    /// its own SSH connection (jump chains included), TOFU pass, bridge
    /// socket, and catalog entry. The key-provider variant is the fixture
    /// path in tests (see the single-connection variant above).
    init(
        machines: [HerdrEmbedMachineLink],
        preferredSelection: String? = nil,
        hostKeyVerifier: HostKeyVerifier?,
        authenticationKeyProvider: @escaping @Sendable () async -> any SSHAuthenticationKeyProvider,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = machines
        self.preferredSelection = preferredSelection
        self.providedVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.searchPaths = searchPaths
        self.connectorFactory = nil
    }

    init(
        machines: [HerdrEmbedMachineLink],
        preferredSelection: String? = nil,
        hostKeyVerifier: HostKeyVerifier?,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = machines
        self.preferredSelection = preferredSelection
        self.providedVerifier = hostKeyVerifier
        self.authenticationKeyProvider = nil
        self.searchPaths = searchPaths
        self.connectorFactory = nil
    }

    init(
        machines: [HerdrEmbedMachineLink],
        preferredSelection: String? = nil,
        connector: @escaping @Sendable () async -> HerdrEndpointConnector
    ) {
        self.links = machines
        self.preferredSelection = preferredSelection
        self.connectorFactory = connector
        self.providedVerifier = nil
        self.authenticationKeyProvider = nil
        self.searchPaths = HerdrProbe.defaultSearchPaths
    }

    private static func link(for connection: Connection) -> HerdrEmbedMachineLink {
        HerdrEmbedMachineLink(
            machine: HerdrEmbedMachine.forConnection(connection),
            connection: connection,
            bridgeSessionName: connection.herdrSessionName
        )
    }

    /// Built per attempt (not captured in init — the approval closure
    /// routes back into this MainActor coordinator).
    private func makeConnector() async -> HerdrEndpointConnector {
        if let connectorFactory {
            return await connectorFactory()
        }
        var verifier: HostKeyVerifier
        if let providedVerifier {
            verifier = providedVerifier
        } else {
            verifier = HostKeyVerifier(
                store: await SessionStore.defaultHostKeyStoreForLiveUse()
            )
        }
        var keyProvider: any SSHAuthenticationKeyProvider = DefaultSSHAuthenticationKeyProvider()
        if let authenticationKeyProvider {
            keyProvider = await authenticationKeyProvider()
        }
        var resolvedPaths = searchPaths
        #if DEBUG
        if HerdrWorkspaceUITest.untrustedStoreRequested {
            verifier = HostKeyVerifier(store: InMemoryHostKeyStoreFallback())
        }
        if let override = HerdrWorkspaceUITest.probeSearchPathsForLiveConnect {
            resolvedPaths = override
        }
        #endif
        return HerdrEndpointConnector(
            hostKeyVerifier: verifier,
            authenticationKeyProvider: keyProvider,
            searchPaths: resolvedPaths,
            approveHostKey: { [weak self] challenge in
                await self?.approve(challenge) ?? false
            }
        )
    }

    /// Establishes every machine's carrier (concurrently — challenges queue
    /// one decision at a time), starts one bridge listener per success,
    /// seeds the client catalog with ALL machines, and applies the
    /// transport environment. Returns the LOCAL endpoint socket path the
    /// embed crate should point at (no local server exists in the embed
    /// scenario — the client treats it as an unavailable Local and
    /// federates the seeded machines).
    ///
    /// Cancellation-aware (the F2 close-during-bringup fix): when the
    /// bring-up task is cancelled, the pending TOFU continuations are
    /// resumed declined, the establish tasks cancelled, and every
    /// post-suspension resume unwinds — closing the bridge channels and
    /// UDS listeners it had started, the established carriers, and the
    /// pinned cwd — then throws `.cancelled`. No coordinator state (or
    /// continuation) outlives the cancelled bring-up.
    func prepare() async throws(HerdrEmbedTransportFailure) -> String {
        prepareCancelled = false
        let (established, establishFailure) = await withTaskCancellationHandler {
            await establishAll()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.handlePrepareCancellation()
            }
        }

        if isPrepareCancelled() {
            await unwindBringUp(established: established, started: [])
            throw .cancelled
        }

        // Pin the cwd BEFORE the binds: socket paths are relative (the
        // container's absolute paths exceed sun_path) and NIO resolves them
        // against the process cwd on its own event-loop threads.
        pinCWDIfNeeded()
        let transportDirectory = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            HerdrEmbedClientCatalog.transportDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: transportDirectory,
            withIntermediateDirectories: true
        )

        var started: [(link: HerdrEmbedMachineLink, bridge: HerdrEmbedBridgeServer)] = []
        var bridgeFailure: HerdrEmbedTransportFailure?
        for item in established {
            if isPrepareCancelled() {
                await unwindBringUp(established: established, started: started)
                throw .cancelled
            }
            let bridge = HerdrEmbedBridgeServer(
                socketPath: Self.socketPath(machine: item.link.machine),
                carrier: item.probed.carrier,
                executablePath: item.probed.executablePath,
                sessionName: item.link.bridgeSessionName
            )
            let eventSink = EventSink(label: item.link.machine.label) { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.eventLines.append(line)
                }
            }
            await bridge.setOnEvent(eventSink.handle)
            do {
                try await bridge.start()
                started.append((item.link, bridge))
                carriers[item.link.machine.profileID] = item.probed.carrier
            } catch let error as HerdrEmbedBridgeError {
                await item.probed.carrier.close()
                if bridgeFailure == nil { bridgeFailure = .bridge(error) }
            } catch {
                await item.probed.carrier.close()
                if bridgeFailure == nil {
                    bridgeFailure = .bridge(.bindFailed(
                        path: Self.socketPath(machine: item.link.machine),
                        reason: "\(error)"
                    ))
                }
            }
        }
        guard !started.isEmpty else {
            restoreCWD()
            // Total failure: the first ESTABLISH failure wins (T5 maps
            // trustDeclined/invalidSessionName from the connector case);
            // bridge failures only when establish succeeded but no bind did.
            throw establishFailure ?? bridgeFailure ?? .bridge(.bindFailed(
                path: "transport", reason: "no machine could be established"
            ))
        }
        if isPrepareCancelled() {
            await unwindBringUp(established: established, started: started)
            throw .cancelled
        }
        servers = started.map(\.bridge)

        let support = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed", isDirectory: true)
        let stateHome = support.appendingPathComponent("state-home", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: stateHome,
            withIntermediateDirectories: true
        )
        do {
            // Every link is seeded — machines whose bring-up failed stay in
            // the catalog so the client's own sidebar renders their state.
            try HerdrEmbedClientCatalog.seed(
                machines: links.map(\.machine),
                selectedProfileID: preferredSelection ?? links.first?.machine.profileID,
                stateHome: stateHome
            )
        } catch {
            for (_, bridge) in started {
                await bridge.stop()
            }
            servers.removeAll()
            carriers.removeAll()
            restoreCWD()
            throw .bridge(.bindFailed(
                path: "client catalog",
                reason: "seeding the machine catalog failed: \(error)"
            ))
        }
        HerdrEmbedClientCatalog.applyEnvironment(
            transportDirectory: HerdrEmbedClientCatalog.transportDirectoryName,
            stateHome: stateHome
        )

        return "\(HerdrEmbedClientCatalog.transportDirectoryName)/local.sock"
    }

    /// Server-death analog for one machine (E2E seam + debugging): closes
    /// the machine's SSH carrier — the bridge stays listening, its relays
    /// cascade, and the client renders the machine's own unhealthy state
    /// while the other machines keep flowing.
    func severMachineTransport(profileID: String) async {
        guard let carrier = carriers.removeValue(forKey: profileID) else { return }
        eventLines.append("sever requested for \(profileID)")
        await carrier.close()
    }

    /// Idempotent: stops every bridge (which closes the carriers and
    /// unlinks the sockets) and restores the process cwd.
    func teardown() async {
        let bridges = servers
        servers.removeAll()
        carriers.removeAll()
        for bridge in bridges {
            await bridge.stop()
        }
        restoreCWD()
    }

    func resolveTrustPrompt(_ approved: Bool) {
        guard let prompt = trustPrompt else { return }
        trustPrompt = queuedTrustPrompts.isEmpty ? nil : queuedTrustPrompts.removeFirst()
        prompt.continuation.resume(returning: approved)
    }

    private func approve(_ challenge: HerdrHostTrustChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            let prompt = TrustPrompt(challenge: challenge, continuation: continuation)
            if trustPrompt == nil {
                trustPrompt = prompt
            } else {
                queuedTrustPrompts.append(prompt)
            }
        }
    }

    static func socketPath(machine: HerdrEmbedMachine) -> String {
        "\(HerdrEmbedClientCatalog.transportDirectoryName)/\(machine.profileID).sock"
    }

    // MARK: - Establish

    private struct Established {
        let link: HerdrEmbedMachineLink
        let probed: HerdrProbedCarrier
    }

    /// One carrier per machine, concurrently (the native herd's
    /// machineTasks shape); failures are recorded per machine and never
    /// block the others. Returns the first failure for the total-failure
    /// path (its connector case carries T5's typed mapping).
    private func establishAll() async -> ([Established], HerdrEmbedTransportFailure?) {
        let tasks = links.map { link in
            Task { @MainActor in
                await self.establishOne(link)
            }
        }
        establishTasks = tasks
        var established: [Established] = []
        var firstFailure: HerdrEmbedTransportFailure?
        for (task, link) in zip(tasks, links) {
            switch await task.value {
            case let .success(probed):
                established.append(Established(link: link, probed: probed))
            case let .failure(failure):
                if firstFailure == nil { firstFailure = failure }
                eventLines.append(
                    "\(link.machine.label): bring-up failed — \(Self.describe(failure))"
                )
            }
        }
        establishTasks = []
        return (established, firstFailure)
    }

    // MARK: - Bring-up cancellation (F2)

    private func isPrepareCancelled() -> Bool {
        prepareCancelled || Task.isCancelled
    }

    /// Runs on the MainActor hop from the cancellation handler: marks the
    /// prepare flag, cancels the per-machine establish tasks (their own
    /// awaits unwind), and brings every undecided TOFU continuation down
    /// with the bring-up so nothing parks the coordinator forever.
    private func handlePrepareCancellation() {
        prepareCancelled = true
        for task in establishTasks {
            task.cancel()
        }
        resolvePendingTrustPromptsAsDeclined()
    }

    private func resolvePendingTrustPromptsAsDeclined() {
        let pending = [trustPrompt].compactMap { $0 } + queuedTrustPrompts
        trustPrompt = nil
        queuedTrustPrompts.removeAll()
        for prompt in pending {
            prompt.continuation.resume(returning: false)
        }
    }

    /// Unwinds a cancelled prepare(): stops the bridges it started (each
    /// stop closes its carrier and unlinks the UDS listener), closes the
    /// carriers of established-but-unbridged machines, and restores the
    /// pinned cwd.
    private func unwindBringUp(
        established: [Established],
        started: [(link: HerdrEmbedMachineLink, bridge: HerdrEmbedBridgeServer)]
    ) async {
        let bridged = Set(started.map { $0.link.machine.profileID })
        for item in established where !bridged.contains(item.link.machine.profileID) {
            await item.probed.carrier.close()
        }
        for (_, bridge) in started {
            await bridge.stop()
        }
        servers.removeAll()
        carriers.removeAll()
        restoreCWD()
    }

    private func establishOne(
        _ link: HerdrEmbedMachineLink
    ) async -> Result<HerdrProbedCarrier, HerdrEmbedTransportFailure> {
        let connector = await makeConnector()
        do {
            return .success(try await connector.establishProbed(link.connection))
        } catch let error as HerdrEndpointConnectorError {
            return .failure(.connector(error))
        } catch {
            return .failure(.connector(.sshEstablish(.channelDenied)))
        }
    }

    private static func describe(_ failure: HerdrEmbedTransportFailure) -> String {
        switch failure {
        case let .connector(error): "connector: \(error)"
        case let .bridge(error): "bridge: \(error)"
        case .cancelled: "cancelled"
        }
    }

    // MARK: - cwd pin

    private func pinCWDIfNeeded() {
        guard previousCWD == nil else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let current = FileManager.default.currentDirectoryPath
        guard chdir(home.path) == 0 else { return }
        previousCWD = current
    }

    private func restoreCWD() {
        guard let previousCWD else { return }
        self.previousCWD = nil
        chdir(previousCWD)
    }
}

/// Event sink bridging the actor's arbitrary-executor callbacks into
/// MainActor-observed lines, prefixed with the machine's label so
/// multi-machine evidence lines attribute themselves.
private final class EventSink: @unchecked Sendable {
    private let label: String
    private let emit: @Sendable (String) -> Void

    init(label: String, emit: @escaping @Sendable (String) -> Void) {
        self.label = label
        self.emit = emit
    }

    func handle(_ event: HerdrEmbedBridgeEvent) {
        let line: String
        switch event {
        case let .listening(path):
            line = "bridge listening \(path)"
        case .relayOpened:
            line = "bridge relay opened"
        case let .relayEnded(clean, bytesUp, bytesDown):
            line = "bridge relay ended clean=\(clean) up=\(bytesUp) down=\(bytesDown)"
        case let .carrierLost(reason):
            line = "bridge carrier lost: \(reason)"
        case let .stopped(unlinked, relaysTornDown):
            line = "bridge stopped unlinked=\(unlinked) relays=\(relaysTornDown)"
        }
        emit("\(label): \(line)")
    }
}
