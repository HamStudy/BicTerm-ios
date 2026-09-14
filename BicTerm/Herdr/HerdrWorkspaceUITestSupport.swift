#if DEBUG
import BicTermCore
import Foundation
import HerdrClientCore

/// DEBUG launch-argument and hardware-key contract for the embedded herdr
/// TUI host. With the native herdr workspace UI retired (plan herdr-embed
/// task 7), the only herdr UI-test surface left is the embedded TUI itself
/// (`--uitest-herdr-embed`) and the live-connector probes Mode A's TOFU
/// path uses (`--uitest-herdr-live`, `--uitest-herdr-untrusted`,
/// `--uitest-herdr-probe-missing`). The replay/live-bootstrap fields and
/// the herdr input-field injection path are gone with the native UI; what
/// remains is the slice the embed transport coordinator and the herd
/// injector still consume.
///
/// Compiles out of Release; the app's Release builds contain no herdr
/// test-only entry point (audited like the other --uitest seams).
enum HerdrWorkspaceUITest {
    static var liveConnectEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-live")
    }

    static var untrustedStoreRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-herdr-untrusted")
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

    /// Hardware-key injector armed from `--uitest-hwkeys`, used by the herd
    /// live E2E once the embed runtime's selected machine is online with a
    /// committed surface. Embed transport tests build it the same way.
    @MainActor static var keyInjector: TestHardwareKeyInjector?

    private static var hwkeysSpec: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--uitest-hwkeys"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Herd live E2E: armed for the model's SELECTED endpoint so the spec's
    /// first token lands on the machine the herd restored as selected.
    /// The settle window keeps the first text token out of the embed
    /// runtime's capability-query freeze (input opens with the ready
    /// control, well after the first online+surface observation).
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
