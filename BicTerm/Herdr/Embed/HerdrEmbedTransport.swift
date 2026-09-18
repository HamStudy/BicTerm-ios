import BicTermCore
import Foundation
import NIOSSH
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
    /// It lives under the container's `tmp/` — the data-container ROOT is
    /// not writable on device (EPERM; the simulator does not enforce
    /// this) — and each bring-up namespaces its sockets under
    /// `tmp/herdr-embed-transport/<8-hex token>/<32-hex>.sock` (~72
    /// bytes, still well under sun_path).
    static let transportDirectoryRelativePath = "tmp/herdr-embed-transport"

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
            ["version": 1, "selected_profile": selectedProfileID ?? NSNull()],
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

    /// Stage B install consent, queued exactly like ``TrustPrompt``: the
    /// payload is the connector's ``HerdrInstallConsent`` and the decision
    /// resumes the awaiting machine's establish.
    struct InstallPrompt: Identifiable {
        let id = UUID()
        let consent: HerdrInstallConsent
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Byte-flow + lifecycle lines surfaced to the runtime (evidence log);
    /// each line is prefixed with its machine's label.
    private(set) var eventLines: [String] = []
    /// Bring-up failures only (establish or bridge bind), one line per
    /// failed machine — the subset of eventLines a user must see; the
    /// full log stays on eventLines for diagnostics.
    private(set) var failureLines: [String] = []

    private(set) var trustPrompt: TrustPrompt?
    private var queuedTrustPrompts: [TrustPrompt] = []
    private(set) var installPrompt: InstallPrompt?
    private var queuedInstallPrompts: [InstallPrompt] = []

    private let links: [HerdrEmbedMachineLink]
    /// Profile the client should select at boot (the herd's persisted
    /// machine choice); nil = first catalog machine.
    private let preferredSelection: String?
    /// Herd coordinators seed the machine catalog (the client's sidebar
    /// federates Local + machines). Mode A does not: its client attaches
    /// to the one machine's bridge as its Local endpoint — upstream
    /// `herdr --remote` behavior — so the catalog stays empty.
    private(set) var seedsCatalog: Bool
    private let connectorFactory: (@Sendable () async -> HerdrEndpointConnector)?
    private let providedVerifier: HostKeyVerifier?
    private let authenticationKeyProvider: (@Sendable () async -> any SSHAuthenticationKeyProvider)?
    /// Test seam for the key-offer pool: production resolves the offer
    /// from the real Keychain-backed default; fixture tests inject the
    /// fixture key's metadata so the offer isn't empty in a Keychain-less
    /// process.
    private let providedMetadataProvider: (any SSHKeyMetadataProviding)?
    private let searchPaths: [String]

    private var servers: [HerdrEmbedBridgeServer] = []
    private var carriers: [String: any SSHExecCapableConnection] = [:]
    /// Per-bring-up namespace under the transport base directory: this
    /// run's bridge sockets live at
    /// `tmp/herdr-embed-transport/<token>/<profile id>.sock`. The token
    /// makes every bring-up's paths UNIQUE, so a previous run's teardown —
    /// whose bridge stops close listeners and unlink socket files while a
    /// newer run is already sweeping, binding, and dialing — can never
    /// collide with the newer run on the same machine paths (the device
    /// bug: the reopened herd's machine dialed a socket the old run was
    /// mid-unlinking, failed ConnectionRefused then ENOENT, and landed in
    /// herdr's "needs attention" state). Stale token directories from
    /// crashed runs are never reused and age out with the container tmp/.
    private let transportToken = HerdrEmbedTransportCoordinator.makeTransportToken()
    /// Per-bring-up authentication-key resolution: each key reference is
    /// read from its provider at most ONCE, with concurrent first-reads
    /// coalesced onto the single in-flight read. A herd's machines
    /// establish their SSH carriers one at a time (``establishAll``
    /// serializes them), and each establish
    /// resolves its connection's keys through the Keychain — for a
    /// BIOMETRY-PROTECTED key that read is a Face ID evaluation, and iOS
    /// runs one evaluation at a time: the losing machine's concurrent
    /// read failed and it was dropped from the bring-up (no bridge
    /// socket; the client's dial then failed ENOENT and the machine
    /// landed in herdr's terminal "needs attention" state — the reported
    /// device bug, one machine working and the other always failing,
    /// alternating). One resolution per key also means ONE biometric
    /// prompt per herd open instead of one per machine.
    private let keyResolution = KeyResolutionCache()
    /// Per-machine establish tasks of the in-flight prepare() — cancelled
    /// when the bring-up is cancelled so their awaits unwind.
    private var establishTasks: [Task<Result<Established, HerdrEmbedTransportFailure>, Never>] = []
    /// Set by the cancellation handler while prepare() is in flight; every
    /// post-suspension resume in prepare() checks it and unwinds.
    private var prepareCancelled = false

    /// Test seam (deterministic early-failure regression tests): replaces
    /// the per-machine establish step so a test can hand the coordinator
    /// carriers with observable lifetimes — no SSH, no fixtures.
    /// Production paths leave it nil (the connector path runs).
    var establishForTesting: (@Sendable (HerdrEmbedMachineLink) async -> Established)?

    /// Test seam (deterministic early-failure regression tests): overrides
    /// the home directory the cwd pin and the transport directory derive
    /// from (production: the app home). A nonexistent directory fails the
    /// pin; a transport-directory name occupied by a regular file fails
    /// the mkdir — both deterministically, before any bind.
    var homeDirectoryForTesting: String?

    /// Stage B seam: the remote installer offered on the missing-binary
    /// probe outcome. Production resolves the composition root's
    /// installer (``AppServices/herdrRemoteInstaller``); tests inject a
    /// seam-backed installer so no test touches the network.
    var remoteInstallerForTesting: HerdrRemoteInstaller?

    init(
        connection: Connection,
        hostKeyVerifier: HostKeyVerifier?,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = [Self.link(for: connection)]
        self.preferredSelection = nil
        self.seedsCatalog = false
        self.providedVerifier = hostKeyVerifier
        self.searchPaths = searchPaths
        self.connectorFactory = nil
        self.authenticationKeyProvider = nil
        self.providedMetadataProvider = nil
    }

    /// Trust-prompt-coverable bring-up with an injected authentication
    /// key (the fixture path in tests: the app process holds no Keychain
    /// entry for fixture keys, and TOFU challenges must reach this
    /// coordinator's prompt queue, not a factory closure's answer).
    init(
        connection: Connection,
        hostKeyVerifier: HostKeyVerifier?,
        authenticationKeyProvider: @escaping @Sendable () async -> any SSHAuthenticationKeyProvider,
        metadataProvider: (any SSHKeyMetadataProviding)? = nil,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = [Self.link(for: connection)]
        self.preferredSelection = nil
        self.seedsCatalog = false
        self.providedVerifier = hostKeyVerifier
        self.searchPaths = searchPaths
        self.authenticationKeyProvider = authenticationKeyProvider
        self.providedMetadataProvider = metadataProvider
        self.connectorFactory = nil
    }

    init(connection: Connection, connector: @escaping @Sendable () async -> HerdrEndpointConnector) {
        self.links = [Self.link(for: connection)]
        self.preferredSelection = nil
        self.seedsCatalog = false
        self.connectorFactory = connector
        self.providedVerifier = nil
        self.authenticationKeyProvider = nil
        self.providedMetadataProvider = nil
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
        metadataProvider: (any SSHKeyMetadataProviding)? = nil,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.links = machines
        self.preferredSelection = preferredSelection
        self.seedsCatalog = true
        self.providedVerifier = hostKeyVerifier
        self.authenticationKeyProvider = authenticationKeyProvider
        self.providedMetadataProvider = metadataProvider
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
        self.seedsCatalog = true
        self.providedVerifier = hostKeyVerifier
        self.authenticationKeyProvider = nil
        self.providedMetadataProvider = nil
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
        self.seedsCatalog = true
        self.connectorFactory = connector
        self.providedVerifier = nil
        self.authenticationKeyProvider = nil
        self.providedMetadataProvider = nil
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
        keyProvider = keyResolution.wrapping(keyProvider)
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
            metadataProvider: providedMetadataProvider ?? DefaultSSHKeyMetadataProvider(),
            searchPaths: resolvedPaths,
            approveHostKey: { [weak self] challenge in
                await self?.approve(challenge) ?? false
            },
            installer: remoteInstallerForTesting ?? AppServices.shared.herdrRemoteInstaller,
            approveInstall: { [weak self] consent in
                await self?.approveInstall(consent) ?? false
            }
        )
    }

    /// Establishes every machine's carrier (sequentially, one machine's
    /// handshake at a time — see ``establishAll()``), starts one bridge
    /// listener per success,
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
        // against the process cwd on its own event-loop threads. The pin
        // is OWNED (HerdrEmbedTransportWorkspace): a superseded
        // coordinator's teardown cannot un-pin it under these binds.
        do {
            try pinCWD()
        } catch {
            // The established carriers are still unbridged and neither
            // `servers` nor `carriers` knows them — runtime teardown
            // cannot recover them, so this unwind is their only closer.
            // The pin never happened, so its release inside the unwind
            // is a no-op.
            await unwindBringUp(established: established, started: [])
            throw error
        }
        let transportDirectoryURL = URL(
            fileURLWithPath: homeDirectory,
            isDirectory: true
        )
        .appendingPathComponent(transportDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: transportDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            // Never let a directory-creation failure fall through to the
            // binds — it would surface as a misleading bind ENOENT. The
            // established carriers are still unbridged (runtime teardown
            // cannot recover them): the unwind closes them and releases
            // the pin this bring-up just took.
            await unwindBringUp(established: established, started: [])
            throw .bridge(.bindFailed(
                path: transportDirectoryURL.path,
                reason: "creating the transport directory failed: \(error)"
            ))
        }

        var started: [(link: HerdrEmbedMachineLink, bridge: HerdrEmbedBridgeServer)] = []
        var bridgeFailure: HerdrEmbedTransportFailure?
        for item in established {
            if isPrepareCancelled() {
                await unwindBringUp(established: established, started: started)
                throw .cancelled
            }
            let bridge = HerdrEmbedBridgeServer(
                socketPath: socketPath(for: item.link.machine),
                carrier: item.carrier,
                executablePath: item.executablePath,
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
                carriers[item.link.machine.profileID] = item.carrier
            } catch let error as HerdrEmbedBridgeError {
                await item.carrier.close()
                if bridgeFailure == nil { bridgeFailure = .bridge(error) }
                failureLines.append("\(item.link.machine.label): bridge bind failed — \(error)")
            } catch {
                await item.carrier.close()
                if bridgeFailure == nil {
                    bridgeFailure = .bridge(.bindFailed(
                        path: socketPath(for: item.link.machine),
                        reason: "\(error)"
                    ))
                }
                failureLines.append("\(item.link.machine.label): bridge bind failed — \(error)")
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
            // Herd: every link is seeded — machines whose bring-up failed
            // stay in the catalog so the client's own sidebar renders
            // their state. Mode A: an empty seed clears any stale herd
            // catalog from a previous open; the client attaches to the
            // machine's bridge as its Local endpoint and never federates.
            try HerdrEmbedClientCatalog.seed(
                machines: seedsCatalog ? links.map(\.machine) : [],
                selectedProfileID: seedsCatalog
                    ? preferredSelection ?? links.first?.machine.profileID
                    : nil,
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
            transportDirectory: transportDirectory,
            stateHome: stateHome
        )

        if seedsCatalog {
            return "\(transportDirectory)/local.sock"
        }
        return socketPath(for: started[0].link.machine)
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
    /// unlinks the sockets), removes this bring-up's token directory, and
    /// restores the process cwd.
    func teardown() async {
        let bridges = servers
        servers.removeAll()
        carriers.removeAll()
        for bridge in bridges {
            await bridge.stop()
        }
        removeTransportDirectory()
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

    /// Install consents queue exactly like TOFU challenges (stage B): one
    /// decision at a time, per machine, per attempt — never persisted.
    func resolveInstallPrompt(_ approved: Bool) {
        guard let prompt = installPrompt else { return }
        installPrompt = queuedInstallPrompts.isEmpty ? nil : queuedInstallPrompts.removeFirst()
        prompt.continuation.resume(returning: approved)
    }

    private func approveInstall(_ consent: HerdrInstallConsent) async -> Bool {
        await withCheckedContinuation { continuation in
            let prompt = InstallPrompt(consent: consent, continuation: continuation)
            if installPrompt == nil {
                installPrompt = prompt
            } else {
                queuedInstallPrompts.append(prompt)
            }
        }
    }

    /// This bring-up's transport directory (relative to the pinned cwd):
    /// the base directory plus this run's unique token.
    var transportDirectory: String {
        "\(HerdrEmbedClientCatalog.transportDirectoryRelativePath)/\(transportToken)"
    }

    /// This bring-up's bridge socket path for one machine.
    func socketPath(for machine: HerdrEmbedMachine) -> String {
        "\(transportDirectory)/\(machine.profileID).sock"
    }

    private static func makeTransportToken() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(8))
    }

    // MARK: - Establish

    /// One machine's established carrier: the probed SSH connection plus
    /// the remote herdr executable the bridge command should exec.
    /// `prepare()` owns these from `establishAll()` until each is either
    /// handed to a started bridge or closed by an unwind.
    struct Established {
        let link: HerdrEmbedMachineLink
        let carrier: any SSHExecCapableConnection
        let executablePath: String
    }

    /// One carrier per machine, SEQUENTIALLY in catalog order; failures
    /// are recorded per machine and never block the others. Returns the
    /// first failure for the total-failure path (its connector case
    /// carries T5's typed mapping).
    ///
    /// Why serial (not the native herd's concurrent Task-per-link shape):
    /// a herd's machines share ONE resolved key instance
    /// (``keyResolution``, aa4f75b), so concurrent handshakes sign
    /// through one shared LAContext / Secure Enclave path — and on
    /// device the SE does not tolerate two concurrent signatures: the
    /// losing establish threw a non-`SSHTransportError` that
    /// `establishOne`'s catch-all swallowed to `.channelDenied` (device
    /// evidence: `.sisyphus/evidence/device-container/herd-diagnostic.txt`
    /// — BOTH concurrent establishes failed; the simulator has no SE, so
    /// the race never reproduces there). One handshake at a time means
    /// one signature at a time; the loser-gets-no-socket failure mode
    /// cannot occur. Each machine still gets its own task so the F2
    /// cancellation contract (cancel the in-flight establish so its
    /// awaits unwind) is unchanged.
    private func establishAll() async -> ([Established], HerdrEmbedTransportFailure?) {
        var established: [Established] = []
        var firstFailure: HerdrEmbedTransportFailure?
        for link in links {
            let task = Task { @MainActor in
                await self.establishOne(link)
            }
            establishTasks = [task]
            switch await task.value {
            case let .success(item):
                established.append(item)
            case let .failure(failure):
                if firstFailure == nil { firstFailure = failure }
                eventLines.append(
                    "\(link.machine.label): bring-up failed — \(Self.describe(failure))"
                )
                failureLines.append(
                    "\(link.machine.label): \(Self.describe(failure))"
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
    /// awaits unwind), and brings every undecided TOFU continuation and
    /// install consent down with the bring-up so nothing parks the
    /// coordinator forever.
    private func handlePrepareCancellation() {
        prepareCancelled = true
        for task in establishTasks {
            task.cancel()
        }
        resolvePendingTrustPromptsAsDeclined()
        resolvePendingInstallPromptsAsDeclined()
    }

    private func resolvePendingTrustPromptsAsDeclined() {
        let pending = [trustPrompt].compactMap { $0 } + queuedTrustPrompts
        trustPrompt = nil
        queuedTrustPrompts.removeAll()
        for prompt in pending {
            prompt.continuation.resume(returning: false)
        }
    }

    private func resolvePendingInstallPromptsAsDeclined() {
        let pending = [installPrompt].compactMap { $0 } + queuedInstallPrompts
        installPrompt = nil
        queuedInstallPrompts.removeAll()
        for prompt in pending {
            prompt.continuation.resume(returning: false)
        }
    }

    /// Unwinds a prepare() that cannot proceed — cancelled, or failed
    /// before bridge startup (cwd pin, transport-directory creation):
    /// stops the bridges it started (each stop closes its carrier and
    /// unlinks the UDS listener), closes the carriers of
    /// established-but-unbridged machines, removes this bring-up's token
    /// directory, and restores the pinned cwd.
    private func unwindBringUp(
        established: [Established],
        started: [(link: HerdrEmbedMachineLink, bridge: HerdrEmbedBridgeServer)]
    ) async {
        let bridged = Set(started.map { $0.link.machine.profileID })
        for item in established where !bridged.contains(item.link.machine.profileID) {
            await item.carrier.close()
        }
        for (_, bridge) in started {
            await bridge.stop()
        }
        servers.removeAll()
        carriers.removeAll()
        removeTransportDirectory()
        restoreCWD()
    }

    /// Best-effort removal of this bring-up's token directory — the
    /// bridge stops already unlinked the socket files, so this clears the
    /// (unique, never-reused) directory itself. A crashed run's leftover
    /// directory is harmless and ages out with the container tmp/.
    private func removeTransportDirectory() {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: transportDirectory, isDirectory: true)
        )
    }

    private func establishOne(
        _ link: HerdrEmbedMachineLink
    ) async -> Result<Established, HerdrEmbedTransportFailure> {
        if let establishForTesting {
            return .success(await establishForTesting(link))
        }
        let connector = await makeConnector()
        do {
            // Stage B: the missing-binary probe outcome proposes the
            // pinned install through this coordinator's prompt queue
            // before the carrier closes; without the installer seam the
            // variant is exactly establishProbed. The installer's
            // milestone lines surface on eventLines (the device-diagnostic
            // evidence log) prefixed with the machine's label — the
            // callback arrives off the main actor, so each line hops;
            // best-effort ordering is fine for an evidence log and the
            // install never blocks on the hop.
            let label = link.machine.label
            let probed = try await connector.establishProbedOfferingInstall(
                link.connection,
                installProgress: { [weak self] line in
                    Task { @MainActor [weak self] in
                        self?.eventLines.append("\(label): install: \(line)")
                    }
                }
            )
            return .success(Established(
                link: link,
                carrier: probed.carrier,
                executablePath: probed.executablePath
            ))
        } catch let error as HerdrEndpointConnectorError {
            return .failure(.connector(error))
        } catch {
            SSHEstablishDiagnostics.shared.record(
                "machine \(link.machine.label) establish failed with a non-connector error",
                error: error
            )
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

    /// Home the cwd pin and the transport directory both derive from.
    /// The test seam can point both at one controlled directory; the
    /// pin and the mkdir must agree on it (the pin is what makes the
    /// relative socket paths resolve).
    private var homeDirectory: String {
        homeDirectoryForTesting ?? NSHomeDirectory()
    }

    /// Pins the process cwd to the app home for the relative bridge
    /// socket paths. Typed failure: a bring-up that cannot pin must not
    /// proceed to relative binds (they would fail with a misleading
    /// ENOENT).
    private func pinCWD() throws(HerdrEmbedTransportFailure) {
        do {
            try HerdrEmbedTransportWorkspace.pinCWD(
                homeDirectory: homeDirectory,
                owner: self
            )
        } catch {
            throw .bridge(.bindFailed(
                path: HerdrEmbedClientCatalog.transportDirectoryRelativePath,
                reason: "pinning the transport cwd failed: \(error)"
            ))
        }
    }

    /// Releases the pin this coordinator holds. Ownership-aware: a
    /// superseded coordinator's release leaves a newer bring-up's pin
    /// (and the cwd) untouched; the current owner's release restores the
    /// pre-pin cwd.
    private func restoreCWD() {
        HerdrEmbedTransportWorkspace.releaseCWD(owner: self)
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

/// Coalesces authentication-key reads for one bring-up (see the
/// coordinator's `keyResolution`): the first read for a reference goes to
/// the underlying provider, concurrent readers of the same reference
/// await that one in-flight read, and later reads return the resolved
/// key. The resolved `NIOSSHPrivateKey` is an opaque signing handle
/// that already lives in memory for each connection's lifetime; sharing
/// one instance across this bring-up's connections is the same exposure
/// class, and it is what turns N concurrent biometric evaluations (one
/// per machine) into ONE.
private actor KeyResolutionCache {
    private var resolved: [String: NIOSSHPrivateKey] = [:]
    private var inFlight: [String: Task<NIOSSHPrivateKey, any Error>] = [:]

    nonisolated func wrapping(
        _ underlying: any SSHAuthenticationKeyProvider
    ) -> any SSHAuthenticationKeyProvider {
        CoalescedKeyProvider(cache: self, underlying: underlying)
    }

    func key(
        for reference: String,
        reason: String,
        underlying: any SSHAuthenticationKeyProvider
    ) async throws -> NIOSSHPrivateKey {
        if let key = resolved[reference] {
            return key
        }
        if let task = inFlight[reference] {
            return try await task.value
        }
        let task = Task {
            try await underlying.authenticationPrivateKey(with: reference, reason: reason)
        }
        inFlight[reference] = task
        do {
            let key = try await task.value
            resolved[reference] = key
            inFlight[reference] = nil
            return key
        } catch {
            inFlight[reference] = nil
            throw error
        }
    }
}

private struct CoalescedKeyProvider: SSHAuthenticationKeyProvider {
    let cache: KeyResolutionCache
    let underlying: any SSHAuthenticationKeyProvider

    func authenticationPrivateKey(
        with reference: String,
        reason: String
    ) async throws -> NIOSSHPrivateKey {
        try await cache.key(for: reference, reason: reason, underlying: underlying)
    }
}
