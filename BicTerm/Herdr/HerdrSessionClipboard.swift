import Foundation

/// Remote-clipboard intake and copy actions (integration doc §8.3): OSC 52
/// server writes arrive on the inbound pump and are held for an explicit
/// "Copy from remote" gesture — or applied immediately only when the user
/// opted in per endpoint. Content is never logged; echo lines carry byte
/// counts only.
extension HerdrSessionModel {
    /// Called from the inbound pump after a chunk whose server clipboard
    /// frame the FFI decoded, base64-validated, and capped.
    func remoteClipboardArrived(endpoint id: HerdrEndpointID, generation: UInt, data: Data) {
        guard isActive(endpoint: id, generation: generation) else { return }
        #if DEBUG
        debugRecordEcho("remoteClipboard(\(data.count)B)")
        #endif
        if clipboardSettings.autoCopyRemoteClipboard(for: id),
           let text = String(data: data, encoding: .utf8) {
            HerdrPasteboard.writeText(text)
            endpoints[id]?.pendingRemoteClipboard = nil
            #if DEBUG
            debugRecordEcho("autoCopyRemote(\(data.count)B)")
            #endif
        } else {
            endpoints[id]?.pendingRemoteClipboard = HerdrRemoteClipboard(
                data: data, receivedAt: Date()
            )
        }
    }

    /// Non-fatal drop surfaced by receive (oversized or malformed server
    /// clipboard frame): the session stays Online; only the note shows.
    func noteClipboardDropped(endpoint id: HerdrEndpointID, generation: UInt, detail: String) {
        guard isActive(endpoint: id, generation: generation) else { return }
        endpoints[id]?.inputNote = .clipboardDropped(detail)
        #if DEBUG
        debugRecordEcho("clipboardDropped")
        #endif
    }

    /// The explicit "Copy from remote" action: the only path besides the
    /// per-endpoint opt-in that lets server clipboard bytes reach the
    /// system pasteboard.
    func copyRemoteClipboardToPasteboard(endpoint id: HerdrEndpointID) {
        guard let pending = endpoints[id]?.pendingRemoteClipboard,
              let text = pending.text else { return }
        HerdrPasteboard.writeText(text)
        endpoints[id]?.pendingRemoteClipboard = nil
        #if DEBUG
        debugRecordEcho("copyRemote(\(pending.byteCount)B)")
        #endif
    }

    /// Per-endpoint opt-in. Enabling it while a write is pending applies
    /// that write immediately — the enabling gesture is the consent.
    func setAutoCopyRemoteClipboard(_ enabled: Bool, endpoint id: HerdrEndpointID) {
        clipboardSettings.setAutoCopyRemoteClipboard(enabled, for: id)
        guard enabled,
              let pending = endpoints[id]?.pendingRemoteClipboard,
              let text = pending.text else { return }
        HerdrPasteboard.writeText(text)
        endpoints[id]?.pendingRemoteClipboard = nil
        #if DEBUG
        debugRecordEcho("autoCopyRemote(\(pending.byteCount)B)")
        #endif
    }

    func autoCopyRemoteClipboard(forEndpoint id: HerdrEndpointID) -> Bool {
        clipboardSettings.autoCopyRemoteClipboard(for: id)
    }
}
