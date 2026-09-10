#if DEBUG
import BicTermCore
import Foundation
import HerdrClientCore
import UIKit

/// DEBUG launch-argument contract for the herdr workspace UI tests:
///
///   --uitest-herdr-replay         open a replay-backed herdr workspace
///   --uitest-herdr-mode <mode>    `workspace` (default), `gen99`, or
///                                 `input` (full presentation fence — the
///                                 input lane unfreezes)
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
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-replay")
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
        for raw in ["replay-2x2", "replay-gen99", "replay-input", "replay-clipboard"] {
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
            return "replay gen-99"
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
            let transport = HerdrReplayTransport(script: [
                load(from: vendorGoldenDirectory, "server-20"),
                load(from: directory, "snapshot-2x2"),
                load(from: directory, "surface-ack-2x2"),
                load(from: directory, "surface-2x2"),
                load(from: directory, "surface-sync-ack-2x2"),
                load(from: directory, "snapshot-2x2"),
                load(from: directory, "surface-2x2"),
                load(from: directory, "presentation-ready-2x2"),
            ])
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
}
#endif
