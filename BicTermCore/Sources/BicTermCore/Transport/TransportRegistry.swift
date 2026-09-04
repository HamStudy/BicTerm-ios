import Foundation

/// Produces fresh transports, one per (re)connection attempt. Resolution
/// is keyed by the connection's protocol id: a factory for a DIFFERENT
/// protocol than `connection.type` must throw
/// ``TransportError/protocolUnavailable`` rather than silently downgrade.
public protocol TerminalTransportFactory: Sendable {
    func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport
}

/// Protocol id → factory registry. `Connection.type` resolves through it
/// (`rawValue` matches ``ProtocolDescriptor/id``). An unknown or
/// not-yet-implemented protocol id in persisted data resolves to a typed
/// ``TransportError/protocolUnavailable`` — never a crash, never a silent
/// SSH fallback.
///
/// Usage (T15 extension guide): to add a protocol, register a descriptor
/// and a factory, and prove the conformer against
/// `TransportConformanceSuite`:
///
/// ```swift
/// var registry = TransportRegistry()
/// registry.register(.ssh, factory: sshFactory)
/// let registry: any TerminalTransportFactory = registry
/// let sessionRegistry = SessionRegistry(transportFactory: registry, ...)
/// ```
public struct TransportRegistry: Sendable {
    private var factories: [String: any TerminalTransportFactory]
    private var descriptorTable: [String: ProtocolDescriptor]

    public init() {
        factories = [:]
        descriptorTable = [:]
    }

    public mutating func register(
        _ descriptor: ProtocolDescriptor,
        factory: any TerminalTransportFactory
    ) {
        descriptorTable[descriptor.id] = descriptor
        factories[descriptor.id] = factory
    }

    /// The capabilities of a registered protocol, or nil when the id is
    /// unknown to this build (e.g. persisted by a newer app version).
    public func descriptor(forProtocolID id: String) -> ProtocolDescriptor? {
        descriptorTable[id]
    }

    public var registeredProtocolIDs: [String] {
        descriptorTable.keys.sorted()
    }
}

extension TransportRegistry: TerminalTransportFactory {
    public func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        let protocolID = connection.type.rawValue
        guard let factory = factories[protocolID] else {
            throw .protocolUnavailable(protocolID: protocolID)
        }
        return try factory.makeTransport(for: connection)
    }
}
