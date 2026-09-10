import BicTermCore
import Foundation
import HerdrClientCore

/// One semantic input event bound for the FFI, pane target resolved at
/// enqueue time on the main actor so a stale pane id can never be queued
/// behind a later surface.
enum HerdrInputEvent: Sendable, Equatable {
    case text(String, paneID: String)
    case key(HerdrKeyInput, paneID: String)
    case resize(cols: UInt32, rows: UInt32)

    var paneID: String? {
        switch self {
        case .text(_, let paneID), .key(_, let paneID): paneID
        case .resize: nil
        }
    }
}

extension HerdrSessionModel {
    // MARK: - Input API (main actor, called by the workspace views)

    /// IME-committed text only; composition stays local until commit.
    func sendText(_ text: String, endpoint id: HerdrEndpointID) {
        guard !text.isEmpty else { return }
        enqueueInput(endpoint: id) { paneID in .text(text, paneID: paneID) }
    }

    func sendKey(_ key: HerdrKeyInput, endpoint id: HerdrEndpointID) {
        enqueueInput(endpoint: id) { paneID in .key(key, paneID: paneID) }
    }

    /// Tap-to-focus: retargets the input lane at a pane on the committed
    /// surface. Panes not on the surface are ignored.
    func setInputTarget(paneID: String, endpoint id: HerdrEndpointID) {
        guard let state = endpoints[id],
              state.surface?.panes.contains(where: { $0.paneID == paneID }) == true,
              state.inputTargetOverride != paneID else { return }
        endpoints[id]?.inputTargetOverride = paneID
        #if DEBUG
        debugRecordEcho("target(\(paneID))")
        #endif
    }

    /// Spatial focus navigation (ctrl+shift+arrows): moves the input target
    /// to the nearest pane center in the given direction.
    func moveInputTarget(_ direction: HerdrFocusDirection, endpoint id: HerdrEndpointID) {
        guard let state = endpoints[id], let surface = state.surface,
              let current = state.inputTargetPaneID,
              let next = surface.paneNeighbor(of: current, direction: direction),
              next != current else { return }
        endpoints[id]?.inputTargetOverride = next
        #if DEBUG
        debugRecordEcho("target(\(next))")
        #endif
    }

    /// The gate every input event passes: inert without a runtime, `.offline`
    /// unless the endpoint is online, `.frozen` until a surface commits
    /// (the fence keeps the FFI input lane closed till then — an early event
    /// that slips through comes back as `.inputFrozen` and is surfaced too).
    private func enqueueInput(endpoint id: HerdrEndpointID, _ make: (String) -> HerdrInputEvent) {
        guard let runtime = runtimes[id] else { return }
        guard let state = endpoints[id], state.phase == .online else {
            noteAtGate(.offline, endpoint: id)
            return
        }
        guard state.surface != nil, let paneID = state.inputTargetPaneID else {
            noteAtGate(.frozen, endpoint: id)
            return
        }
        runtime.inputContinuation.yield(make(paneID))
    }

    private func noteAtGate(_ note: HerdrInputNote, endpoint id: HerdrEndpointID) {
        endpoints[id]?.inputNote = note
        #if DEBUG
        debugRecordEcho(Self.echoLine(for: note))
        #endif
    }

    // MARK: - Input lane (off-main consumer; FFI stays on its actor)

    /// Serial consumer of the per-runtime input stream: applies each event
    /// to the FFI in order, records the outcome on the main actor, and kicks
    /// the single outbound writer after every queued frame. Errors surface
    /// as typed notes; nothing is retried and nothing is reordered.
    nonisolated static func runInputLane(
        model: HerdrSessionModel?,
        client: HerdrClient,
        endpoint id: HerdrEndpointID,
        generation: UInt,
        events: AsyncStream<HerdrInputEvent>,
        kick: AsyncStream<Void>.Continuation
    ) async {
        for await event in events {
            let outcome = await applyInputEvent(event, to: client)
            await model?.recordInputOutcome(outcome, event: event, endpoint: id, generation: generation)
            if case .success = outcome {
                kick.yield(())
            }
        }
    }

    private nonisolated static func applyInputEvent(
        _ event: HerdrInputEvent,
        to client: HerdrClient
    ) async -> Result<Void, HerdrClientError> {
        do {
            switch event {
            case .text(let text, let paneID):
                try await client.sendText(text, to: paneID)
            case .key(let key, let paneID):
                try await client.sendKey(key, to: paneID)
            case .resize(let cols, let rows):
                try await client.resize(cols: cols, rows: rows)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func recordInputOutcome(
        _ outcome: Result<Void, HerdrClientError>,
        event: HerdrInputEvent,
        endpoint id: HerdrEndpointID,
        generation: UInt
    ) {
        guard isActive(endpoint: id, generation: generation) else { return }
        switch outcome {
        case .success:
            #if DEBUG
            debugRecordEcho(Self.echoLine(for: event))
            #endif
        case .failure(let error):
            let note: HerdrInputNote
            switch error {
            case .inputFrozen:
                note = .frozen
            case .inputStaleTarget:
                note = .staleTarget(event.paneID ?? "unknown")
            case .inputWriteFailed(let detail):
                note = .writeFailed(detail)
            case .notOnline:
                note = .offline
            default:
                note = .writeFailed(Self.detail(of: error))
            }
            endpoints[id]?.inputNote = note
            #if DEBUG
            debugRecordEcho(Self.echoLine(for: note))
            #endif
        }
    }

    // MARK: - DEBUG input echo (test surface)

    #if DEBUG
    func debugRecordEcho(_ line: String) {
        debugInputEcho.append(line)
    }

    static func echoLine(for event: HerdrInputEvent) -> String {
        switch event {
        case .text(let text, let paneID):
            "text(\"\(text)\"→\(paneID))"
        case .key(let key, let paneID):
            "key(\(echoDescriptor(for: key))→\(paneID))"
        case .resize(let cols, let rows):
            "resize(\(cols)x\(rows))"
        }
    }

    static func echoLine(for note: HerdrInputNote) -> String {
        switch note {
        case .offline: "offline"
        case .frozen: "frozen"
        case .staleTarget(let paneID): "staleTarget(\(paneID))"
        case .writeFailed(let detail): "writeFailed(\(detail))"
        }
    }

    static func echoDescriptor(for key: HerdrKeyInput) -> String {
        var parts: [String] = []
        if key.modifiers & 2 != 0 { parts.append("ctrl") }
        if key.modifiers & 4 != 0 { parts.append("alt") }
        if key.modifiers & 1 != 0 { parts.append("shift") }
        if key.modifiers & 8 != 0 { parts.append("super") }
        let base: String
        switch key.code {
        case .backspace: base = "backspace"
        case .enter: base = "enter"
        case .left: base = "left"
        case .right: base = "right"
        case .up: base = "up"
        case .down: base = "down"
        case .home: base = "home"
        case .end: base = "end"
        case .pageUp: base = "pageup"
        case .pageDown: base = "pagedown"
        case .tab: base = "tab"
        case .backTab: base = "backtab"
        case .delete: base = "delete"
        case .insert: base = "insert"
        case .esc: base = "esc"
        case .null: base = "null"
        case .char(let scalar): base = String(scalar)
        case .function(let number): base = "f\(number)"
        }
        parts.append(base)
        return parts.joined(separator: "+")
    }
    #endif
}
