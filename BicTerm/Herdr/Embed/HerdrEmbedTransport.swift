#if HERDR_EMBED
import BicTermCore
import Foundation
import Observation

/// One machine in the embedded client's endpoint catalog (plan herdr-embed
/// T5): the profile the Rust client dials through
/// `{HERDR_EMBED_TRANSPORT_DIR}/{profile id}.sock`. v1 maps the single
/// Mode-A connection; the type is the herd seam — T6 seeds N machines into
/// the same catalog, each profile id backed by its own bridge socket.
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

/// Typed failure of one embedded-transport bring-up.
enum HerdrEmbedTransportFailure: Error {
    case connector(HerdrEndpointConnectorError)
    case bridge(HerdrEmbedBridgeError)
}

/// Drives the embedded client's SSH transport (plan herdr-embed T5): one
/// Mode-A ``Connection`` → TOFU-gated establish + probe (the SAME
/// ``HerdrEndpointConnector`` flow the native workspace rides) →
/// ``HerdrEmbedBridgeServer`` listening at the client's expected socket
/// path. The coordinator owns the cwd pin (relative bridge socket paths)
/// and restores it at teardown.
@MainActor
@Observable
final class HerdrEmbedTransportCoordinator {
    struct TrustPrompt: Identifiable {
        let id = UUID()
        let challenge: HerdrHostTrustChallenge
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Byte-flow + lifecycle lines surfaced to the runtime (evidence log).
    private(set) var eventLines: [String] = []

    private(set) var trustPrompt: TrustPrompt?
    private var queuedTrustPrompts: [TrustPrompt] = []

    private let connection: Connection
    private let connectorFactory: (@Sendable () async -> HerdrEndpointConnector)?
    private let providedVerifier: HostKeyVerifier?
    private let searchPaths: [String]

    private var server: HerdrEmbedBridgeServer?
    private var previousCWD: String?

    init(
        connection: Connection,
        hostKeyVerifier: HostKeyVerifier?,
        searchPaths: [String] = HerdrProbe.defaultSearchPaths
    ) {
        self.connection = connection
        self.providedVerifier = hostKeyVerifier
        self.searchPaths = searchPaths
        self.connectorFactory = nil
    }

    init(connection: Connection, connector: @escaping @Sendable () async -> HerdrEndpointConnector) {
        self.connection = connection
        self.connectorFactory = connector
        self.providedVerifier = nil
        self.searchPaths = HerdrProbe.defaultSearchPaths
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
            searchPaths: resolvedPaths,
            approveHostKey: { [weak self] challenge in
                await self?.approve(challenge) ?? false
            }
        )
    }

    /// Establishes the carrier, starts the bridge listener, seeds the
    /// client catalog, and applies the transport environment. Returns the
    /// LOCAL endpoint socket path the embed crate should point at (no
    /// local server exists in the embed scenario — the client treats it as
    /// an unavailable Local and federates the seeded machine).
    func prepare() async throws(HerdrEmbedTransportFailure) -> String {
        let machine = HerdrEmbedMachine(
            profileID: HerdrEmbedMachine.profileID(for: connection.id),
            label: connection.name,
            target: "\(connection.username)@\(connection.host):\(connection.port)",
            sessionName: connection.herdrSessionName ?? "default"
        )

        let connector = await makeConnector()
        let probed: HerdrProbedCarrier
        do {
            probed = try await connector.establishProbed(connection)
        } catch let error as HerdrEndpointConnectorError {
            throw .connector(error)
        } catch {
            throw .connector(.sshEstablish(.channelDenied))
        }

        // Pin the cwd BEFORE the bind: the socket path is relative (the
        // container's absolute paths exceed sun_path) and NIO resolves it
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

        let bridge = HerdrEmbedBridgeServer(
            socketPath: Self.socketPath(machine: machine),
            carrier: probed.carrier,
            executablePath: probed.executablePath,
            sessionName: connection.herdrSessionName
        )
        let eventSink = EventSink()
        eventSink.onLine = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.eventLines.append(line)
            }
        }
        await bridge.setOnEvent(eventSink.handle)
        do {
            try await bridge.start()
        } catch let error as HerdrEmbedBridgeError {
            await probed.carrier.close()
            throw .bridge(error)
        } catch {
            await probed.carrier.close()
            throw .bridge(.bindFailed(path: Self.socketPath(machine: machine), reason: "\(error)"))
        }

        let support = URL.applicationSupportDirectory
            .appendingPathComponent("herdr-embed", isDirectory: true)
        let stateHome = support.appendingPathComponent("state-home", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: stateHome,
            withIntermediateDirectories: true
        )
        do {
            try HerdrEmbedClientCatalog.seed(
                machines: [machine],
                selectedProfileID: machine.profileID,
                stateHome: stateHome
            )
        } catch {
            await bridge.stop()
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

        server = bridge
        return "\(HerdrEmbedClientCatalog.transportDirectoryName)/local.sock"
    }

    /// Idempotent: stops the bridge (which closes the carrier and unlinks
    /// the socket) and restores the process cwd.
    func teardown() async {
        guard let bridge = server else { return }
        server = nil
        await bridge.stop()
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
/// MainActor-observed lines.
private final class EventSink: @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?

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
        onLine?(line)
    }
}
#endif
