import BicTermCore
import CoderNet
import Foundation

private let coderNetEventChannel = AsyncStream<CoderNetEvent>.makeStream()

private func coderNetLogCallback(_: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message,
          let event = CoderNetEvent.parse(bridgeLine: String(cString: message)) else { return }
    coderNetEventChannel.continuation.yield(event)
}

/// Production ``CoderTunneling`` conformer: the ONLY Swift file that links
/// the CoderNet Go core (AGPL-3.0, coder/coder v2 + fork graph). It lives in
/// the `CoderTunnel` framework target so the AppStore build configuration —
/// which excludes this target — ships zero AGPL-derived symbols.
///
/// Session state lives behind the Go bridge's handle table; this type adapts
/// both tunnel calls and the bridge's process-wide event callback.
public struct CoderNetTunnel: CoderTunneling {
    /// The sole Swift event stream fed by the Go bridge's existing callback.
    /// ``CoderLifecycleCoordinator`` remains its only production consumer.
    public static let events: AsyncStream<CoderNetEvent> = {
        CoderNetSetLogCallback(coderNetLogCallback)
        return coderNetEventChannel.stream
    }()

    public init() {}

    public func version() -> String {
        guard let raw = CoderNetVersion() else { return "" }
        defer { CoderNetFreeString(raw) }
        return String(cString: raw)
    }

    public func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        // The cgo-generated header types the parameter as mutable `char *`,
        // but the Go side only copies it (C.GoString) — `mutating:` bridges
        // the header's const-correctness gap without an allocation.
        let rawHandle = configJSON.withCString { ptr in
            CoderNetStart(UnsafeMutablePointer(mutating: ptr))
        }
        guard rawHandle != 0 else { throw .startRejected }
        return Int(rawHandle)
    }

    public func dialSSH(handle: Int) async throws(CoderTunnelError) -> String {
        guard let raw = CoderNetDialSSH(cHandle(from: handle)) else { return "" }
        defer { CoderNetFreeString(raw) }
        return String(cString: raw)
    }

    public func rebind(handle: Int) {
        CoderNetRebind(cHandle(from: handle))
    }

    public func close(handle: Int) {
        CoderNetClose(cHandle(from: handle))
    }

    /// The bridge allocates handles as sequential C `int`s from 1, so every
    /// real handle converts exactly; an unconvertible value is a fabricated
    /// caller contract violation, and truncating it would alias a live session.
    private func cHandle(from handle: Int) -> Int32 {
        guard let converted = Int32(exactly: handle) else {
            preconditionFailure("CoderTunnel handle \(handle) is not representable as C int")
        }
        return converted
    }
}
