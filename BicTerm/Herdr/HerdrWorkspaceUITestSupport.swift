#if DEBUG
import BicTermCore
import Foundation
import HerdrClientCore

/// DEBUG launch-argument contract for the herdr workspace UI tests:
///
///   --uitest-herdr-replay         open a replay-backed herdr workspace
///   --uitest-herdr-mode <mode>    `workspace` (default) or `gen99`
///   HERDR_FIXTURE_DIR (env)       absolute fixture dir (committed frames)
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

    /// Builds the replay script for the requested mode and connects a fresh
    /// model. Returns the endpoint label to show in the chrome.
    @MainActor
    static func connectReplay(model: HerdrSessionModel) -> String {
        guard let directory = fixtureDirectory else { return "replay" }

        if mode == "gen99" {
            let transport = HerdrReplayTransport(
                script: [load(from: directory, "welcome-gen99")],
                holdOpen: false
            )
            model.connect(endpoint: HerdrEndpointID(rawValue: "replay-gen99"), transport: transport)
            return "replay gen-99"
        }

        let transport = HerdrReplayTransport(script: [
            load(from: vendorGoldenDirectory, "server-20"),
            load(from: directory, "snapshot-2x2"),
            load(from: directory, "surface-ack-2x2"),
            load(from: directory, "surface-2x2"),
        ])
        model.connect(endpoint: HerdrEndpointID(rawValue: "replay-2x2"), transport: transport)
        return "replay 2x2"
    }
}
#endif
