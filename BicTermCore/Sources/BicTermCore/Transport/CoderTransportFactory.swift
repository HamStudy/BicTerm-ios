import Foundation

/// T10 dependency bundle threading Coder session lifecycle services into
/// ``CoderTransport``: event-coordinator reporting, the credential-generation
/// tracker (spec §4.3), and the usage-heartbeat factory (spec §14.3). All
/// three are optional in the aggregate so hermetic tests and AppStore-flavor
/// paths behave exactly as before when no lifecycle wiring is supplied.
public struct CoderSessionLifecycleDependencies: Sendable {
    public let reporting: (any CoderSessionReporting)?
    public let generations: CoderCredentialGenerations?
    public let makeUsageReporter: @Sendable () -> any CoderUsageReporting

    public init(
        reporting: (any CoderSessionReporting)? = nil,
        generations: CoderCredentialGenerations? = nil,
        makeUsageReporter: @escaping @Sendable () -> any CoderUsageReporting = { UsageHeartbeat() }
    ) {
        self.reporting = reporting
        self.generations = generations
        self.makeUsageReporter = makeUsageReporter
    }
}

/// Produces fresh ``CoderTransport`` instances for coder-typed connections.
/// The tunnel conformer arrives via closure so this module never names the
/// CoderTunnel framework; AppStore flavors simply never register the factory
/// and keep the registry's typed ``TransportError/protocolUnavailable``.
public struct CoderTransportFactory: TerminalTransportFactory {
    private let resolver: CoderWorkspaceResolver
    private let socketBaseDirectory: String
    private let lifecycle: CoderSessionLifecycleDependencies?
    private let makeTunnel: @Sendable () -> any CoderTunneling

    public init(
        resolver: CoderWorkspaceResolver,
        socketBaseDirectory: String,
        lifecycle: CoderSessionLifecycleDependencies? = nil,
        tunnelFactory: @escaping @Sendable () -> any CoderTunneling
    ) {
        self.resolver = resolver
        self.socketBaseDirectory = socketBaseDirectory
        self.lifecycle = lifecycle
        self.makeTunnel = tunnelFactory
    }

    public func makeTransport(for connection: Connection) throws(TransportError) -> any TerminalTransport {
        guard connection.type == .coder else {
            throw .protocolUnavailable(protocolID: connection.type.rawValue)
        }
        return CoderTransport(
            resolver: resolver,
            tunnel: makeTunnel(),
            socketBaseDirectory: socketBaseDirectory,
            lifecycle: lifecycle
        )
    }
}
