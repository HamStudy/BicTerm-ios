import BicTermCore
import SwiftTerm
import UIKit
import XCTest
@testable import BicTerm

/// Multi-line paste preview (t4): the intercept policy (LF/CR/CRLF),
/// the app-subclass `paste(_:)` override (captured-text interception vs
/// SwiftTerm's direct delivery), the immutable captured request, the
/// scene model's present/cancel/confirm lifecycle (generation-checked,
/// registry-routed delivery, inline send errors), and the cache wiring
/// that binds a session surface to its scene.
@MainActor
final class PastePreviewTests: XCTestCase {

    // MARK: - Policy

    func testPolicyRequiresPreviewForLF_CR_CRLF() {
        for text in ["line1\nline2", "line1\rline2", "line1\r\nline2", "trailing\n"] {
            XCTAssertTrue(TerminalPastePolicy.needsPreview(text), text.debugDescription)
        }
    }

    func testPolicyPassesSingleLineThrough() {
        for text in ["", "single line", "one two three", "no terminators at all"] {
            XCTAssertFalse(TerminalPastePolicy.needsPreview(text), text.debugDescription)
        }
    }

    func testPolicyLinesSplitEveryTerminatorOnce() {
        XCTAssertEqual(TerminalPastePolicy.lines(in: "a\nb"), ["a", "b"])
        XCTAssertEqual(TerminalPastePolicy.lines(in: "a\rb"), ["a", "b"])
        XCTAssertEqual(TerminalPastePolicy.lines(in: "a\r\nb"), ["a", "b"])
        XCTAssertEqual(TerminalPastePolicy.lines(in: "a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(TerminalPastePolicy.lines(in: "a\n"), ["a"])
    }

    func testPolicyFramedBytesApplyBracketingOnlyWhenRequested() {
        let text = "a\nb"
        XCTAssertEqual(
            TerminalPastePolicy.framedBytes(for: text, bracketed: false),
            Data(text.utf8)
        )
        XCTAssertEqual(
            TerminalPastePolicy.framedBytes(for: text, bracketed: true),
            Data(TerminalPastePolicy.bracketedPasteStart) + Data(text.utf8)
                + Data(TerminalPastePolicy.bracketedPasteEnd)
        )
    }

    // MARK: - View-level intercept (app subclass override)

    /// Records every byte delivery SwiftTerm's `paste(_:)` makes toward
    /// the session (the super path), so tests can prove the intercept
    /// path delivers NOTHING without confirmation.
    private final class RecordingDelegate: NSObject, TerminalViewDelegate {
        private(set) var sent: [Data] = []

        var sentJoined: Data { sent.reduce(Data(), +) }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func oscClipboardWriteRequest(source: TerminalView, request: ClipboardWriteRequest) {}
    }

    private func makeContainer() -> (view: TerminalContainerView, delegate: RecordingDelegate) {
        let options = TerminalOptions(
            cols: 80,
            rows: 24,
            cursorStyle: .steadyBlock,
            scrollback: TerminalScrollback.maxLines
        )
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let view = TerminalContainerView(frame: .zero, font: font, options: options)
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.addSubview(view)
        window.makeKeyAndVisible()
        return (view, delegate)
    }

    private func setPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    func testInterceptPresentsRequestForLF_CR_CRLFWhenBracketedOff() {
        for text in ["line1\nline2\n", "line1\rline2\r", "line1\r\nline2\r\n"] {
            let (view, delegate) = makeContainer()
            var presented: [TerminalPasteRequest] = []
            view.pastePreviewPresenter = { presented.append($0) }
            setPasteboard(text)

            view.paste(nil)

            XCTAssertEqual(presented.count, 1, text.debugDescription)
            XCTAssertEqual(presented.first?.text, text, text.debugDescription)
            XCTAssertTrue(delegate.sent.isEmpty, "intercepted paste must deliver zero bytes before confirmation")
        }
    }

    func testSingleLineFallsThroughToSuperDelivery() {
        let (view, delegate) = makeContainer()
        var presented: [TerminalPasteRequest] = []
        view.pastePreviewPresenter = { presented.append($0) }
        setPasteboard("single line")

        view.paste(nil)

        XCTAssertTrue(presented.isEmpty)
        XCTAssertEqual(delegate.sentJoined, Data("single line".utf8))
    }

    func testBracketedOnFallsThroughToSuperWithFraming() {
        let (view, delegate) = makeContainer()
        var presented: [TerminalPasteRequest] = []
        view.pastePreviewPresenter = { presented.append($0) }
        setPasteboard("a\nb")
        view.feed(byteArray: Array("\u{1B}[?2004h".utf8)[...])
        XCTAssertTrue(view.getTerminal().bracketedPasteMode, "DECSET 2004 must arm bracketed paste on the local terminal")

        view.paste(nil)

        XCTAssertTrue(presented.isEmpty, "bracketed paste must bypass the preview sheet")
        XCTAssertEqual(
            delegate.sentJoined,
            Data(TerminalPastePolicy.bracketedPasteStart) + Data("a\nb".utf8)
                + Data(TerminalPastePolicy.bracketedPasteEnd)
        )
    }

    func testNoPresenterKeepsSuperDeliveryUnchanged() {
        let (view, delegate) = makeContainer()
        XCTAssertNil(view.pastePreviewPresenter)
        setPasteboard("a\nb")

        view.paste(nil)

        XCTAssertEqual(delegate.sentJoined, Data("a\nb".utf8))
    }

    // MARK: - Scene model lifecycle

    private func makeConnection(name: String) throws -> Connection {
        try Connection(
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
    }

    private func makeModel(
        name: String = "paste-unit",
        factory: TerminalTransportFactory = ScriptedSessionTransportFactory(fallback: .succeed)
    ) throws -> (model: SessionSceneModel, store: SessionStore) {
        let store = SessionStore(
            transportFactory: factory,
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil }
        )
        let descriptor = store.openSession(for: try makeConnection(name: name))
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        return (model, store)
    }

    private func startAndWaitActive(_ model: SessionSceneModel) async -> Bool {
        await model.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.state == .active { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model.state == .active
    }

    func testPresentAndCancelPasteConfirmation() throws {
        let (model, _) = try makeModel()
        XCTAssertNil(model.pendingPasteRequest)
        XCTAssertNil(model.currentPasteRequest)

        let request = TerminalPasteRequest(text: "line1\nline2\n")
        model.presentPasteConfirmation(request)
        XCTAssertEqual(model.pendingPasteRequest, request)
        XCTAssertEqual(model.currentPasteRequest, request)

        model.cancelPasteConfirmation()
        XCTAssertNil(model.pendingPasteRequest)
        XCTAssertNil(model.currentPasteRequest)
    }

    func testSecondPasteReplacesPendingRequest() throws {
        let (model, _) = try makeModel()
        let first = TerminalPasteRequest(text: "one\ntwo\n")
        let second = TerminalPasteRequest(text: "three\nfour\n")
        model.presentPasteConfirmation(first)
        model.presentPasteConfirmation(second)
        XCTAssertEqual(model.pendingPasteRequest, second, "a second paste replaces, never queues")
    }

    func testConfirmSendsCapturedStringNotLaterPasteboard() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        let captured = "line1\nline2\n"
        model.presentPasteConfirmation(TerminalPasteRequest(text: captured))
        // The user copies something else while the sheet is open.
        setPasteboard("MUTATED-AFTER-INTERCEPT")

        await model.confirmPaste()

        let transport = try XCTUnwrap(factory.transport(named: "paste-unit"))
        let sent = await transport.sent
        XCTAssertEqual(sent, [Data(captured.utf8)], "confirm must deliver the ORIGINAL captured string")
        XCTAssertNil(model.pendingPasteRequest)
        XCTAssertNil(model.pasteErrorMessage)
    }

    func testConfirmResolvesBracketedFramingAtConfirmationTime() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, store) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        // Real cache wiring: the framer reads THIS surface's view.
        let attachment = store.viewCache.attachSurface(for: model.id, model: model)
        let view = attachment.surface.view

        let captured = "line1\nline2\n"
        model.presentPasteConfirmation(TerminalPasteRequest(text: captured))

        // DECSET 2004 flips ON while the sheet is open.
        view.feed(byteArray: Array("\u{1B}[?2004h".utf8)[...])
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)

        await model.confirmPaste()

        let transport = try XCTUnwrap(factory.transport(named: "paste-unit"))
        let sent = await transport.sent
        XCTAssertEqual(
            sent,
            [TerminalPastePolicy.framedBytes(for: captured, bracketed: true)],
            "framing must be resolved at confirmation time, not intercept time"
        )
    }

    func testDuplicateConfirmSendsExactlyOnce() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))

        // A double-tap races two confirms onto the main actor.
        async let first: Void = model.confirmPaste()
        async let second: Void = model.confirmPaste()
        _ = await (first, second)
        // A late third tap after the sheet is gone.
        await model.confirmPaste()

        let transport = try XCTUnwrap(factory.transport(named: "paste-unit"))
        let sent = await transport.sent
        XCTAssertEqual(sent.count, 1, "duplicate confirm must send exactly once")
    }

    func testStaleGenerationConfirmIsNoOp() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))
        // A new placement claims the surface (rebind): the generation
        // bumps without a detach clear — the pending request goes stale.
        model.surfaceAttached()
        XCTAssertNil(model.currentPasteRequest, "a stale request must not present")

        await model.confirmPaste()

        let transport = try XCTUnwrap(factory.transport(named: "paste-unit"))
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "a stale-generation confirm must send nothing")
        XCTAssertNil(model.pendingPasteRequest)
    }

    func testSurfaceDetachInvalidatesPendingRequest() throws {
        let (model, _) = try makeModel()
        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))
        model.surfaceDetached()
        XCTAssertNil(model.pendingPasteRequest)
        XCTAssertNil(model.currentPasteRequest)
    }

    func testBackgroundingInvalidatesPendingRequest() async throws {
        let (model, _) = try makeModel()
        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))
        await model.scenePhaseChanged(.background)
        XCTAssertNil(model.pendingPasteRequest)
    }

    func testReconnectInvalidatesPendingRequest() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)
        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))

        let transport = try XCTUnwrap(factory.transport(named: "paste-unit"))
        await transport.finishOutput()

        let deadline = Date().addingTimeInterval(5)
        while model.pendingPasteRequest != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.pendingPasteRequest, "a reconnect must invalidate the pending paste")
    }

    // MARK: - Send failure

    /// A transport whose `send` always throws, so the confirmed delivery
    /// fails while the session is still active.
    private actor ThrowingSendTransport: TerminalTransport {
        nonisolated let outputStream: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation

        init() {
            let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
            self.outputStream = stream
            self.continuation = continuation
        }

        var output: AsyncStream<Data> { outputStream }

        func connect(to connection: Connection, cols: Int, rows: Int) async throws(TransportError) {}

        func send(_ bytes: Data) async throws(TransportError) {
            throw .channelDenied
        }

        func resize(cols: Int, rows: Int) async {}

        func close() async {
            continuation.finish()
        }
    }

    private struct ThrowingSendFactory: TerminalTransportFactory {
        func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
            ThrowingSendTransport()
        }
    }

    func testSendFailureRetainsSheetWithInlineError() async throws {
        let (model, _) = try makeModel(factory: ThrowingSendFactory())
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        let request = TerminalPasteRequest(text: "a\nb\n")
        model.presentPasteConfirmation(request)

        await model.confirmPaste()

        XCTAssertEqual(model.pendingPasteRequest, request, "a failed delivery must retain the sheet")
        XCTAssertNotNil(model.pasteErrorMessage, "a failed delivery must surface an inline error")
        XCTAssertEqual(model.currentPasteRequest, request)

        model.cancelPasteConfirmation()
        XCTAssertNil(model.pendingPasteRequest)
        XCTAssertNil(model.pasteErrorMessage)
    }

    // MARK: - First responder restoration

    /// Mounts the surface's host view (terminal + accessory stack) in a
    /// key window so responder assertions are meaningful. The window is
    /// RETURNED — the caller must hold it for the test's duration: an
    /// unretained UIWindow deallocates on the first run-loop tick (any
    /// `await`), detaching the view and breaking responder assertions.
    private func mountInWindow(_ view: TerminalContainerView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.addSubview(view.superview ?? view)
        window.makeKeyAndVisible()
        return window
    }

    func testCancelRestoresTerminalFirstResponder() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, store) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)
        let attachment = store.viewCache.attachSurface(for: model.id, model: model)
        let view = attachment.surface.view
        let window = mountInWindow(view)
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.isFirstResponder)

        // The sheet's buttons take focus while it is open.
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(view.isFirstResponder)

        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))
        model.cancelPasteConfirmation()
        XCTAssertTrue(view.isFirstResponder, "cancel must restore first responder to the terminal")
    }

    func testConfirmedDeliveryRestoresTerminalFirstResponder() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, store) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)
        let attachment = store.viewCache.attachSurface(for: model.id, model: model)
        let view = attachment.surface.view
        let window = mountInWindow(view)
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())

        model.presentPasteConfirmation(TerminalPasteRequest(text: "a\nb\n"))
        await model.confirmPaste()
        XCTAssertTrue(view.isFirstResponder, "a confirmed delivery must restore first responder")
    }

    // MARK: - Cache wiring (end to end through the real surface)

    func testCacheWiredSurfaceInterceptsPasteIntoSceneState() throws {
        let (model, store) = try makeModel(name: "paste-wired")
        let attachment = store.viewCache.attachSurface(for: model.id, model: model)
        let view = attachment.surface.view
        XCTAssertNotNil(view.pastePreviewPresenter, "the cache must wire the presenter on session surfaces")

        setPasteboard("wired-one\nwired-two\n")
        view.paste(nil)

        let request = try XCTUnwrap(model.pendingPasteRequest)
        XCTAssertEqual(request.text, "wired-one\nwired-two\n")
        XCTAssertEqual(model.currentPasteRequest, request)
    }
}
