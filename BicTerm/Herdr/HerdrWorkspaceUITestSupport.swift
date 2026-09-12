#if DEBUG
import BicTermCore
import Foundation
import HerdrClientCore
import UIKit

/// DEBUG launch-argument contract for the herdr workspace UI tests:
///
///   --uitest-herdr-replay         open a replay-backed herdr workspace
///   --uitest-herdr-mode <mode>    `workspace` (default), `gen99`,
///                                 `input` (full presentation fence — the
///                                 input lane unfreezes), `clipboard`,
///                                 `lifecycle` (fence + re-attach source),
///                                 or `probe-missing` (preflight probe
///                                 diagnostic screen, no connection)
///   --uitest-herdr-live           live-endpoint E2E (todo 6): echo strips
///                                 on, NO replay bootstrap; the connect flow
///                                 probes the pinned fixture binary
///   --uitest-herdr-probe-missing  with --uitest-herdr-live: probe search
///                                 paths point nowhere, forcing the
///                                 no-herdr probe diagnostic
///   --uitest-herdr-untrusted      with --uitest-herdr-live: herdr connects
///                                 through a FRESH in-memory host-key store,
///                                 so the TOFU prompt always surfaces
///   --uitest-herdr-double-connect with --uitest-herdr-live: the first herdr
///                                 connect is fired TWICE in one turn — the
///                                 double-tap XCUI cannot deliver reliably
///                                 (swipe actions close within ~1s) — for
///                                 the in-flight guard idempotency test
///   HERDR_FIXTURE_DIR (env)       absolute fixture dir (committed frames)
///   HERDR_UI_TEST_PASTEBOARD (env) seed string written to the system
///                                 pasteboard BY THE APP at boot, so the
///                                 gesture read that follows is an
///                                 own-origin read and never raises the
///                                 SpringBoard paste prompt (a
///                                 runner-seeded pasteboard is cross-app
///                                 and blocks the main thread on the
///                                 prompt — see the cmd+v chord test for
///                                 the deliberate prompt path)
///
/// Compiles out of Release; the app's Release builds contain no replay
/// entry point (audited like the other --uitest seams).
enum HerdrWorkspaceUITest {
    static var isEnabled: Bool {
        wantsReplayBootstrap || liveConnectEnabled
    }

    static var wantsReplayBootstrap: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-replay")
    }

    static var liveConnectEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-live")
    }

    static var untrustedStoreRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-untrusted")
    }

    static var doubleConnectRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-double-connect")
    }

    static var probeSearchPathsForLiveConnect: [String]? {
        guard liveConnectEnabled else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--uitest-herdr-probe-missing") {
            return ["/nonexistent-bicterm-ui/herdr"]
        }
        let binary = repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr").path
        return FileManager.default.fileExists(atPath: binary) ? [binary] : nil
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var mode: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--uitest-herdr-mode"),
              index + 1 < arguments.count else {
            return "workspace"
        }
        return arguments[index + 1]
    }

    /// Number of replay chunks the current mode feeds; the workspace view
    /// shows `herdr-replay-ready` once the model has applied that many.
    @MainActor static private(set) var currentScriptChunkCount: Int?

    /// Hardware-key injector for the replay scene, armed from
    /// `--uitest-hwkeys`. Herdr mode has no terminal tail with a go-marker,
    /// so the workspace view calls `startNow()` once the script is applied.
    @MainActor static var keyInjector: TestHardwareKeyInjector?

    /// Mirror of the model's input echo, kept in sync by the workspace view
    /// so injector `await:echo:` steps can observe retargets without
    /// walking SwiftUI's accessibility tree.
    @MainActor static var currentInputEcho: String?

    private static var hwkeysSpec: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--uitest-hwkeys"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var fixtureDirectory: String? {
        ProcessInfo.processInfo.environment["HERDR_FIXTURE_DIR"]
    }

    static var vendorGoldenDirectory: String? {
        ProcessInfo.processInfo.environment["HERDR_VENDOR_GOLDEN_DIR"]
    }

    private static func load(from directory: String?, _ name: String) -> Data {
        guard let directory else { return Data() }
        return (try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("\(name).bin"))) ?? Data()
    }

    /// Writes the UI test's pasteboard seed from inside the app: an
    /// own-origin string the later gesture reads without the system paste
    /// prompt a cross-app (runner-written) seed would raise. Bypasses
    /// ``HerdrPasteboard`` on purpose — the seed is scaffolding, and the
    /// stats assertions must still observe r:0 w:0 before the gesture.
    @MainActor
    private static func seedPasteboardIfRequested() {
        guard let seed = ProcessInfo.processInfo.environment["HERDR_UI_TEST_PASTEBOARD"] else { return }
        UIPasteboard.general.string = seed
    }

    /// Builds the replay script for the requested mode and connects a fresh
    /// model. Returns the endpoint label to show in the chrome.
    @MainActor
    static func connectReplay(model: HerdrSessionModel) -> String {
        guard let directory = fixtureDirectory else { return "replay" }
        keyInjector = TestHardwareKeyInjector(spec: hwkeysSpec)
        // Deterministic privacy state: every replay launch starts with the
        // auto-copy opt-in OFF for the endpoint it is about to use.
        for raw in [
            "replay-2x2", "replay-gen99", "replay-input", "replay-clipboard",
            "replay-lifecycle", "replay-probe-missing",
        ] {
            HerdrClipboardSettings().setAutoCopyRemoteClipboard(false, for: HerdrEndpointID(rawValue: raw))
        }
        seedPasteboardIfRequested()

        if mode == "gen99" {
            let transport = HerdrReplayTransport(
                script: [load(from: directory, "welcome-gen99")],
                holdOpen: false
            )
            currentScriptChunkCount = 1
            model.connect(endpoint: HerdrEndpointID(rawValue: "replay-gen99"), transport: transport)
            return "replay gen99"
        }

        if mode == "probe-missing" {
            // Preflight probe failure (doc §6.1/§11): no bridge channel ever
            // opens; the probe diagnostic screen renders instead.
            let result = HerdrProbe.Result(
                host: "fixture-no-herdr",
                rawOS: "Linux",
                rawArch: "aarch64",
                foundPath: nil,
                version: nil,
                endpointGeneration: nil,
                capabilities: []
            )
            model.failProbe(endpoint: HerdrEndpointID(rawValue: "replay-probe-missing"), result: result)
            currentScriptChunkCount = 0
            return "replay probe-missing"
        }

        if mode == "lifecycle" {
            // Full presentation fence plus a re-attach source: every
            // reconnect builds a fresh transport scripted with the fence
            // again and a revision-2 snapshot tail — the authoritative
            // "output continued" state a persistent server would hand a
            // re-attaching client. The INITIAL script must stay at the
            // fence alone: the rev2 snapshot restarts the activation
            // transaction, and mid-typing input would bounce StaleTarget.
            let endpoint = HerdrEndpointID(rawValue: "replay-lifecycle")
            let source = HerdrReconnectSource {
                HerdrReplayTransport(script: fenceScript(directory: directory) + [
                    load(from: directory, "snapshot-2x2-rev2"),
                ])
            }
            let transport = HerdrReplayTransport(script: fenceScript(directory: directory))
            currentScriptChunkCount = 8
            model.connect(endpoint: endpoint, transport: transport, reconnectSource: source)
            return "replay lifecycle"
        }

        if mode == "clipboard" {
            // The full input fence plus one OSC 52 server clipboard frame:
            // the remote-copy banner must be up once the script exhausts.
            // Replay rides the live inbound pump, so the FFI's
            // takeClipboard routes the frame to remoteClipboardArrived.
            let transport = HerdrReplayTransport(script: [
                load(from: vendorGoldenDirectory, "server-20"),
                load(from: directory, "snapshot-2x2"),
                load(from: directory, "surface-ack-2x2"),
                load(from: directory, "surface-2x2"),
                load(from: directory, "surface-sync-ack-2x2"),
                load(from: directory, "snapshot-2x2"),
                load(from: directory, "surface-2x2"),
                load(from: directory, "presentation-ready-2x2"),
                load(from: directory, "clipboard-osc52-hello"),
            ])
            currentScriptChunkCount = 9
            model.connect(endpoint: HerdrEndpointID(rawValue: "replay-clipboard"), transport: transport)
            return "replay clipboard"
        }

        if mode == "input" {
            // The full presentation fence: both surface-set acks, the
            // evidence resend, and the ready control. After the ready chunk
            // applies, the FFI input lane accepts sends.
            let transport = HerdrReplayTransport(script: fenceScript(directory: directory))
            currentScriptChunkCount = 8
            model.connect(endpoint: HerdrEndpointID(rawValue: "replay-input"), transport: transport)
            return "replay input"
        }

        let transport = HerdrReplayTransport(script: [
            load(from: vendorGoldenDirectory, "server-20"),
            load(from: directory, "snapshot-2x2"),
            load(from: directory, "surface-ack-2x2"),
            load(from: directory, "surface-2x2"),
        ])
        currentScriptChunkCount = 4
        model.connect(endpoint: HerdrEndpointID(rawValue: "replay-2x2"), transport: transport)
        return "replay 2x2"
    }

    /// The full presentation-fence script (T17 learnings: two surface
    /// commits + the re-sent evidence pair + the ready control — 8 chunks).
    private static func fenceScript(directory: String) -> [Data] {
        [
            load(from: vendorGoldenDirectory, "server-20"),
            load(from: directory, "snapshot-2x2"),
            load(from: directory, "surface-ack-2x2"),
            load(from: directory, "surface-2x2"),
            load(from: directory, "surface-sync-ack-2x2"),
            load(from: directory, "snapshot-2x2"),
            load(from: directory, "surface-2x2"),
            load(from: directory, "presentation-ready-2x2"),
        ]
    }

    /// Live-endpoint E2E: arms the `--uitest-hwkeys` injector for a freshly
    /// opened live workspace and starts it only once the endpoint is online
    /// with a committed surface — earlier `insertText` would be dropped by
    /// the input gate (`.offline`/`.frozen`) instead of queued.
    @MainActor
    static func startLiveInjectionWhenReady(
        model: HerdrSessionModel,
        endpoint: HerdrEndpointID
    ) {
        guard liveConnectEnabled, keyInjector == nil else { return }
        let injector = TestHardwareKeyInjector(spec: hwkeysSpec)
        guard let injector else { return }
        keyInjector = injector
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let state = model.endpoints[endpoint],
                   state.phase == .online, state.surface != nil {
                    injector.startNow()
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Herd live E2E: same start condition as
    /// ``startLiveInjectionWhenReady(model:endpoint:)`` but keyed to the
    /// model's SELECTED endpoint, so the spec's first text token lands on
    /// the machine the herd restored as selected. Later tokens can gate on
    /// `await:echo:chip:<label>` — selection switches record into the same
    /// echo surface the injector polls. The settle window keeps the first
    /// text token out of the FFI's presentation-fence freeze (input opens
    /// with the ready control, well after the first online+surface
    /// observation).
    @MainActor
    static func startHerdInjectionWhenReady(model: HerdrSessionModel) {
        guard liveConnectEnabled, keyInjector == nil else { return }
        let injector = TestHardwareKeyInjector(spec: hwkeysSpec)
        guard let injector else { return }
        keyInjector = injector
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            var settledSince: Date?
            while Date() < deadline {
                if let id = model.selectedEndpointID,
                   let state = model.endpoints[id],
                   state.phase == .online, state.surface != nil {
                    if let since = settledSince, Date().timeIntervalSince(since) >= 3.5 {
                        injector.startNow()
                        return
                    }
                    if settledSince == nil { settledSince = Date() }
                } else {
                    settledSince = nil
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
#endif
