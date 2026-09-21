import BicTermCore
import Foundation
import XCTest

@testable import BicTerm

/// Device-only diagnostic for the reported herd bug: a fresh two-machine
/// herd where exactly one machine lands in herdr's "needs attention"
/// state on first connect, 100% of the time, not always the same machine.
/// The device client log shows the losing machine's dial failing with
/// ENOENT — its bridge socket never existed, meaning its SSH ESTABLISH
/// failed during the transport bring-up. The establish failure reason
/// lives in the coordinator's in-memory event lines, which no log
/// captures — this diagnostic drives the user's real herd through the
/// production connector path and dumps those lines to a pullable file.
///
/// GATED: runs only when the marker file
/// `<App Support>/herdr-embed-herd-diagnostic.enabled` exists (push it
/// with `xcrun devicectl device copy to` before the run, remove it
/// after) so ordinary device test runs never touch the user's real
/// machines. RECORD-ONLY: every step prints one `HERD-DIAG:` line and
/// the full dump lands in `<App Support>/herdr-embed/herd-diagnostic.txt`.
@MainActor
final class HerdrEmbedHerdDeviceDiagnosticTests: XCTestCase {
    private var recorded = 0

    func testDriveUsersHerdThroughProductionConnectorAndDumpEstablishOutcome() async throws {
        let support = URL.applicationSupportDirectory
        let marker = support.appendingPathComponent("herdr-embed-herd-diagnostic.enabled")
        // One-shot, content-gated: the marker must contain exactly
        // "enabled", and the run consumes it (rewrites "consumed"), so an
        // ordinary device test pass never touches the user's real
        // machines and a stale marker cannot re-arm itself.
        guard
            (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) == "enabled"
        else {
            throw XCTSkip(
                "DIAGNOSTIC TOOL, opt-in by design — arms only when a marker file containing "
                    + "exactly \"enabled\" sits at <App Support>/herdr-embed-herd-diagnostic.enabled "
                    + "(push with: xcrun devicectl device copy to --device <id> --domain-type "
                    + "appDataContainer --domain-identifier com.bicterm.app --source <file> "
                    + "--destination \"Library/Application Support/herdr-embed-herd-diagnostic.enabled\"; "
                    + "the run consumes it). It drives the user's REAL herd through the production "
                    + "connector and dumps establish diagnostics — it must never run unattended."
            )
        }
        try? "consumed".write(to: marker, atomically: true, encoding: .utf8)

        var lines: [String] = []
        defer {
            lines.append("recorded=\(recorded)")
            try? lines.joined(separator: "\n")
                .write(
                    to: support.appendingPathComponent("herdr-embed/herd-diagnostic.txt"),
                    atomically: true,
                    encoding: .utf8
                )
        }

        // The user's herds, exactly as the workspace center loads them.
        let herds = (try? await AppServices.shared.herdStore.loadHerds()) ?? []
        lines.append("herds loaded: \(herds.map { "\($0.name)=\($0.machines.count) machines" })")
        guard let herd = herds.first(where: { $0.machines.count >= 2 }) else {
            record("herd", "no two-machine herd on this device")
            return
        }

        let descriptor = HerdDescriptor(
            herdID: herd.id,
            herdName: herd.name,
            machines: herd.machines.map { machine in
                HerdMachineDescriptor(
                    endpointID: HerdDescriptor.endpointID(
                        herdID: herd.id, connectionID: machine.connectionID
                    ),
                    connectionID: machine.connectionID,
                    label: machine.label ?? "machine",
                    sessionName: machine.sessionName
                )
            }
        )
        let links = await HerdrEmbedHerdSeeder.links(for: descriptor)
        lines.append("links resolved: \(links.map { "\($0.machine.label) -> \($0.machine.target)" })")
        guard links.count >= 2 else {
            record("links", "fewer than two machines resolved to connections")
            return
        }

        // The production connector shape, verbatim from the workspace
        // view: ONE shared store-backed verifier (the user's trusted
        // host keys), the DEFAULT Keychain key pool, and the default
        // probe search paths.
        let verifier = HostKeyVerifier(
            store: await SessionStore.defaultHostKeyStoreForLiveUse()
        )
        // Fresh capture: every establish-path swallow point (SSHTransport's
        // channel-open collapse, the auth cascade's key/password resolution
        // failures, the connector's catch-alls) records the FULL underlying
        // error chain here — the typed `.channelDenied` the event lines
        // show is otherwise a dead end.
        SSHEstablishDiagnostics.shared.removeAll()

        for link in links {
            let coordinator = HerdrEmbedTransportCoordinator(
                machines: [link],
                preferredSelection: nil,
                hostKeyVerifier: verifier,
                searchPaths: HerdrProbe.defaultSearchPaths
            )
            lines.append("== machine \(link.machine.label) -> \(link.machine.target) ==")
            let beforeCount = SSHEstablishDiagnostics.shared.snapshot().count
            do {
                _ = try await coordinator.prepare()
            } catch {
                lines.append("prepare: FAILED \(error)")
            }
            lines.append("eventLines:")
            lines.append(contentsOf: coordinator.eventLines)
            let diagnostics = SSHEstablishDiagnostics.shared.snapshot().dropFirst(beforeCount)
            lines.append("establishDiagnostics: \(diagnostics.count) captured")
            lines.append(contentsOf: diagnostics)
            record("prepare", "event lines captured (see herd-diagnostic.txt)")

            await coordinator.teardown()
        }
        record("teardown", "completed")
    }

    // MARK: - Helpers

    private func record(_ name: String, _ result: String) {
        print("HERD-DIAG: \(name) = \(result)")
        fflush(stdout)
        recorded += 1
    }
}
