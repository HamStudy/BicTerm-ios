import Foundation
import SwiftTerm
import SwiftUI
import UIKit

/// One session's live terminal surface: the SwiftTerm view plus the feed
/// task pumping the session's output stream into it. Owned by
/// ``TerminalViewCache``, not by the SwiftUI placement — detaching a
/// session (switching away, closing its window) keeps the feed running and
/// the scrollback accumulating; only eviction or session close destroys it.
final class TerminalSurface: NSObject, TerminalViewDelegate {
    let view: TerminalContainerView
    private var feedTask: Task<Void, Never>?
    private let sendBytes: @Sendable (Data) -> Void
    private let resizeTo: @Sendable (_ cols: Int, _ rows: Int) -> Void

    init(
        output: AsyncStream<Data>,
        send: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable (_ cols: Int, _ rows: Int) -> Void
    ) {
        self.sendBytes = send
        self.resizeTo = onResize

        let options = TerminalOptions(
            cols: 80,
            rows: 24,
            cursorStyle: .steadyBlock,
            scrollback: TerminalScrollback.maxLines
        )
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let view = TerminalContainerView(frame: .zero, font: font, options: options)
        self.view = view
        super.init()

        view.optionAsMetaKey = true
        view.nativeBackgroundColor = UIColor(red: 0x0D / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 0xE6 / 255, green: 0xED / 255, blue: 0xF3 / 255, alpha: 1)
        view.terminalDelegate = self
        view.accessibilityIdentifier = "terminalView"

        feedTask = Task { [weak view] in
            for await chunk in output {
                let slice = Array(chunk)[...]
                await MainActor.run {
                    view?.feed(byteArray: slice)
                }
            }
        }
    }

    /// Permanent teardown (session closed or cache eviction): stop the
    /// feed and release the view. The in-memory scrollback dies with it.
    func stop() {
        feedTask?.cancel()
        feedTask = nil
        view.terminalDelegate = nil
        view.updateUiClosed()
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendBytes(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        resizeTo(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Links open only after explicit user confirmation (v1: never).
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // Remote OSC 52 clipboard writes are denied (v1: copy-only).
    }
}

/// Strong LRU cache (cap 8) of live terminal surfaces keyed by session
/// descriptor ID — the buffer-preservation layer for detach-without-close:
///
/// - attach  = return the cached surface (or create it) and swap its view
///   into the calling hierarchy; recency moves to the front.
/// - detach  = the placement's view left the hierarchy; the entry STAYS,
///   the feed keeps running, the session keeps receiving output.
/// - evict   = capacity exceeded: the least-recently-attached surface is
///   stopped and dropped. The session survives; its scrollback does not —
///   re-attaching builds a fresh surface and flags the model so the scene
///   shows a one-line "scrollback released" notice.
/// - remove  = session closed: drop the entry unconditionally.
///
/// Attach/detach bookkeeping is generation-stamped: each attach bumps a
/// per-session counter, and a dismantle only reports the detach when no
/// NEWER attach has claimed the surface. This survives both SwiftUI's
/// dismantle ordering (which can run while the view is still in the
/// hierarchy) and a surface stolen by another window's attach.
@MainActor
final class TerminalViewCache {
    struct SurfaceAttachment {
        let surface: TerminalSurface
        let generation: UInt64
    }

    private struct Entry {
        let surface: TerminalSurface
        let onDetach: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var recencyOrder: [UUID] = []
    private var attachGenerations: [UUID: UInt64] = [:]
    private var evictedSessionIDs: Set<UUID> = []

    let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    var cachedCount: Int { entries.count }

    @discardableResult
    func attachSurface(for sessionID: UUID, model: SessionSceneModel) -> SurfaceAttachment {
        let generation = (attachGenerations[sessionID] ?? 0) &+ 1
        attachGenerations[sessionID] = generation

        if let entry = entries[sessionID] {
            touch(sessionID)
            model.surfaceAttached()
            return SurfaceAttachment(surface: entry.surface, generation: generation)
        }

        let wasEvicted = evictedSessionIDs.remove(sessionID) != nil
        let surface = TerminalSurface(
            output: model.beginOutputStream(),
            send: { model.send($0) },
            onResize: { cols, rows in model.resize(cols: cols, rows: rows) }
        )
        entries[sessionID] = Entry(
            surface: surface,
            onDetach: { [weak model] in model?.surfaceDetached() }
        )
        recencyOrder.append(sessionID)
        evictIfNeeded()
        if wasEvicted {
            model.markScrollbackReleased()
        }
        model.surfaceAttached()
        return SurfaceAttachment(surface: surface, generation: generation)
    }

    /// The placement that owned `generation` left the hierarchy. A newer
    /// attach has claimed the surface when the current generation differs
    /// — in that case the session is still attached and nothing is
    /// reported.
    func detachSurface(for sessionID: UUID, generation: UInt64) {
        guard let entry = entries[sessionID],
              attachGenerations[sessionID] == generation else { return }
        entry.onDetach()
    }

    /// Session close: drop the entry unconditionally. The evicted marker
    /// is set so a surface ever rebuilt for this ID reports released
    /// scrollback — the previous buffer was discarded either way.
    func removeSurface(for sessionID: UUID) {
        if let entry = entries.removeValue(forKey: sessionID) {
            entry.surface.stop()
            evictedSessionIDs.insert(sessionID)
        }
        recencyOrder.removeAll { $0 == sessionID }
    }

    private func touch(_ sessionID: UUID) {
        recencyOrder.removeAll { $0 == sessionID }
        recencyOrder.append(sessionID)
    }

    private func evictIfNeeded() {
        while recencyOrder.count > capacity, let lru = recencyOrder.first {
            recencyOrder.removeFirst()
            if let entry = entries.removeValue(forKey: lru) {
                entry.surface.stop()
            }
            evictedSessionIDs.insert(lru)
        }
    }
}

/// Cache-backed terminal surface for session scenes. `makeUIView` pulls
/// the session's live surface from the cache (creating it on first
/// attach); `dismantleUIView` detaches WITHOUT stopping the feed — the
/// session keeps running and its scrollback keeps accumulating while no
/// view is on screen.
struct SessionTerminalRepresentable: UIViewRepresentable {
    let cache: TerminalViewCache
    let model: SessionSceneModel

    final class Coordinator {
        let cache: TerminalViewCache
        let sessionID: UUID
        var attachGeneration: UInt64 = 0

        init(cache: TerminalViewCache, sessionID: UUID) {
            self.cache = cache
            self.sessionID = sessionID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cache: cache, sessionID: model.id)
    }

    func makeUIView(context: Context) -> TerminalContainerView {
        let attachment = cache.attachSurface(for: model.id, model: model)
        context.coordinator.attachGeneration = attachment.generation
        return attachment.surface.view
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalContainerView, coordinator: Coordinator) {
        coordinator.cache.detachSurface(
            for: coordinator.sessionID,
            generation: coordinator.attachGeneration
        )
    }
}
