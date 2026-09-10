import Foundation
import HerdrCore

/// Actor-isolated endpoint client over the HerdrCore C ABI (integration doc
/// §3.2: protocol parsing and state mutation stay on one serial executor).
///
/// The caller owns transport I/O: inbound bytes go through ``receive(_:)``,
/// complete outbound frames come out of ``drainOutbound()`` as opaque data,
/// and nothing on the Swift side interprets the wire protocol.
public actor HerdrClient {
    // Exclusive access is guaranteed at deinit (last reference); the ABI
    // confines the handle to this actor's serial executor otherwise.
    nonisolated(unsafe) private var handle: UnsafeMutablePointer<herdr_client>?

    /// Static library provenance, e.g. "0.9.0".
    public nonisolated static var coreVersion: String {
        String(cString: herdr_core_version())
    }

    /// Live allocations handed to Swift and not yet returned (diagnostic;
    /// zero across a balanced create/destroy cycle).
    public nonisolated static var liveFFIAllocations: UInt64 {
        herdr_debug_live_allocations()
    }

    public init(config: HerdrClientConfig) throws(HerdrClientError) {
        var error = HerdrResult(code: -1, detail: nil)
        let raw = config.withFFI { ffi in herdr_client_create(ffi, &error) }
        guard let raw else {
            throw HerdrClientError.from(error)
        }
        handle = raw
    }

    deinit {
        if let handle {
            herdr_client_destroy(handle)
        }
    }

    public var phase: HerdrPhase {
        HerdrPhase(rawValueOrUnknown: handle.map(herdr_client_phase) ?? .max)
    }

    /// Bytes buffered while a complete inbound frame is still pending.
    public var pendingInbound: UInt64 {
        handle.map(herdr_client_pending_inbound) ?? .max
    }

    /// Feeds opaque transport bytes (stdout of `remote-client-bridge`) to the
    /// Rust decoder. Chunk boundaries are irrelevant to the decoder.
    public func receive(_ data: Data) throws(HerdrClientError) {
        guard let handle else { throw .clientFailed("client already destroyed") }
        let result = data.withUnsafeBytes { raw in
            herdr_client_receive(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if result.code != HERDR_CODE_OK { throw HerdrClientError.from(result) }
    }

    /// Drains every complete outbound frame in FIFO order. The frames are
    /// opaque, length-prefixed protocol data — write them to the transport
    /// unchanged.
    public func drainOutbound() throws(HerdrClientError) -> [Data] {
        guard let handle else { throw .clientFailed("client already destroyed") }
        var frames: [Data] = []
        while true {
            var error = HerdrResult(code: -1, detail: nil)
            let bytes = herdr_client_drain_outbound(handle, &error)
            if error.code != HERDR_CODE_OK { throw HerdrClientError.from(error) }
            guard bytes.len > 0, let data = bytes.data else { return frames }
            defer { herdr_bytes_free(bytes) }
            frames.append(Data(bytes: data, count: bytes.len))
        }
    }

    /// Latest accepted shell snapshot as immutable Swift value, decoded from
    /// the stable `shell.snapshot.v1` JSON carrier produced by the Rust core.
    public func snapshot() throws(HerdrClientError) -> HerdrShellSnapshot? {
        guard let data = try snapshotData() else { return nil }
        do {
            return try JSONDecoder().decode(HerdrShellSnapshot.self, from: data)
        } catch {
            throw .protocolViolation("snapshot JSON did not decode: \(error)")
        }
    }

    /// Latest committed pane surface as stable JSON (render input for the
    /// surface provider layer; opaque to this framework).
    public func surfaceJSON() throws(HerdrClientError) -> Data? {
        try jsonData(herdr_client_surface)
    }

    private func snapshotData() throws(HerdrClientError) -> Data? {
        try jsonData(herdr_client_snapshot)
    }

    private func jsonData(
        _ access: (UnsafeMutablePointer<herdr_client>, UnsafeMutablePointer<HerdrResult>) -> herdr_bytes
    ) throws(HerdrClientError) -> Data? {
        guard let handle else { throw .clientFailed("client already destroyed") }
        var error = HerdrResult(code: -1, detail: nil)
        let bytes = access(handle, &error)
        if error.code != HERDR_CODE_OK { throw HerdrClientError.from(error) }
        guard bytes.len > 0, let data = bytes.data else { return nil }
        defer { herdr_bytes_free(bytes) }
        return Data(bytes: data, count: bytes.len)
    }

    /// Commits plain text to a pane (IME-committed text only, never marked
    /// composition).
    public func sendText(_ text: String, to paneID: String) throws(HerdrClientError) {
        try send(.textCommit(text), paneID: paneID)
    }

    /// Sends a clipboard paste payload to a pane.
    public func sendPaste(_ text: String, to paneID: String) throws(HerdrClientError) {
        try send(.paste(text), paneID: paneID)
    }

    /// Sends one semantic key event to a pane.
    public func sendKey(_ key: HerdrKeyInput, to paneID: String) throws(HerdrClientError) {
        try send(.key(key), paneID: paneID)
    }

    private func send(_ payload: Input, paneID: String) throws(HerdrClientError) {
        guard let handle else { throw .clientFailed("client already destroyed") }
        var result = HerdrResult(code: -1, detail: nil)
        payload.withCInput(paneID: paneID) { input in
            result = herdr_client_send_input(handle, input)
        }
        if result.code != HERDR_CODE_OK { throw HerdrClientError.from(result) }
    }

    /// Releases the client and its queues; buffers already handed out belong
    /// to Swift and stay valid until freed.
    ///
    /// Nonisolated on purpose: after this call the instance must not be used
    /// again, mirroring the FFI single-owner rule (exactly one destroy, after
    /// the last in-flight call). The actor's deinit provides the same release
    /// if this is never called explicitly.
    public nonisolated func destroy() {
        if let handle {
            herdr_client_destroy(handle)
            self.handle = nil
        }
    }
}

private enum Input {
    case textCommit(String)
    case paste(String)
    case key(HerdrKeyInput)

    func withCInput(paneID: String, _ body: (UnsafePointer<herdr_input>) -> Void) {
        var text: String?
        var key = herdr_key()
        let kind: UInt8
        switch self {
        case .textCommit(let value):
            kind = UInt8(HERDR_INPUT_TEXT_COMMIT)
            text = value
        case .paste(let value):
            kind = UInt8(HERDR_INPUT_PASTE)
            text = value
        case .key(let input):
            kind = UInt8(HERDR_INPUT_KEY)
            key = input.ffi
        }
        paneID.utf8CString.withUnsafeBufferPointer { paneBuffer in
            // SAFETY (Swift): rebinds the NUL-terminated UTF-8 buffer to
            // CChar for the call's duration; the Rust side copies it.
            let paneID = paneBuffer.baseAddress!.withMemoryRebound(
                to: CChar.self, capacity: paneBuffer.count
            ) { $0 }
            guard let text else {
                var input = herdr_input(kind: kind, pane_id: paneID, text: nil, key: key)
                withUnsafePointer(to: &input, body)
                return
            }
            text.utf8CString.withUnsafeBufferPointer { textBuffer in
                let textPtr = textBuffer.baseAddress!.withMemoryRebound(
                    to: CChar.self, capacity: textBuffer.count
                ) { $0 }
                var input = herdr_input(kind: kind, pane_id: paneID, text: textPtr, key: key)
                withUnsafePointer(to: &input, body)
            }
        }
    }
}

private extension HerdrKeyInput {
    var ffi: herdr_key {
        herdr_key(
            code: code.ffiCode,
            codepoint: code.ffiCodepoint,
            modifiers: modifiers,
            kind: kind.rawValue,
            repeat_count: repeatCount,
            shifted_codepoint: shiftedCodepoint?.value ?? 0
        )
    }
}

private extension HerdrKeyCode {
    var ffiCode: UInt32 {
        switch self {
        case .backspace: return UInt32(HERDR_KEY_BACKSPACE)
        case .enter: return UInt32(HERDR_KEY_ENTER)
        case .left: return UInt32(HERDR_KEY_LEFT)
        case .right: return UInt32(HERDR_KEY_RIGHT)
        case .up: return UInt32(HERDR_KEY_UP)
        case .down: return UInt32(HERDR_KEY_DOWN)
        case .home: return UInt32(HERDR_KEY_HOME)
        case .end: return UInt32(HERDR_KEY_END)
        case .pageUp: return UInt32(HERDR_KEY_PAGE_UP)
        case .pageDown: return UInt32(HERDR_KEY_PAGE_DOWN)
        case .tab: return UInt32(HERDR_KEY_TAB)
        case .backTab: return UInt32(HERDR_KEY_BACK_TAB)
        case .delete: return UInt32(HERDR_KEY_DELETE)
        case .insert: return UInt32(HERDR_KEY_INSERT)
        case .esc: return UInt32(HERDR_KEY_ESC)
        case .null: return UInt32(HERDR_KEY_NULL)
        case .char: return UInt32(HERDR_KEY_CHAR)
        case .function: return UInt32(HERDR_KEY_FUNCTION)
        }
    }

    var ffiCodepoint: UInt32 {
        switch self {
        case .char(let scalar): return scalar.value
        case .function(let number): return UInt32(number)
        default: return 0
        }
    }
}

private extension HerdrClientConfig {
    func withFFI<T>(_ body: (UnsafePointer<herdr_client_config>) -> T) -> T {
        withUnsafePointer(to: ffi, body)
    }
}
