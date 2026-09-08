import Foundation
import XCTest
@testable import BicTermCore

/// Phase-2 G7 (task 7) capability plumbing: the `coder` protocol descriptor
/// carries an explicit tailnet-tunnel flag injected by the build flavor, and
/// the `CoderTunneling` contract is provably free of the AGPL Go core —
/// this file compiles against BicTermCore only, with no `CoderNet` module
/// anywhere on its search path.
final class CoderTunnelDescriptorTests: XCTestCase {
    /// Given: the app built WITH the tunnel (default Debug/Release flavor)
    /// When: the coder descriptor is created for that flavor
    /// Then: it reports tailnet-tunnel support with the v1 Coder surface
    func testCoderDescriptorReportsTunnelSupportWhenFlavorShipsTunnel() {
        let descriptor = ProtocolDescriptor.coder(supportsTailnetTunnel: true)
        XCTAssertTrue(descriptor.supportsTailnetTunnel)
        XCTAssertEqual(descriptor.id, "coder")
        XCTAssertEqual(descriptor.displayName, "Coder")
        XCTAssertTrue(descriptor.requiresServerComponent)
        XCTAssertFalse(descriptor.supportsAgentForwarding)
        XCTAssertFalse(descriptor.supportsJumpChain)
        XCTAssertFalse(descriptor.supportsRoamingResume)
        XCTAssertEqual(descriptor.defaultPort, 443)
        XCTAssertEqual(descriptor.keyAlgorithmsAccepted, ["ssh-ed25519"])
        XCTAssertEqual(descriptor.resumeStrategy, .rehandshake)
    }

    /// Given: the AppStore flavor, which excludes the AGPL Go core entirely
    /// When: the coder descriptor is created for that flavor
    /// Then: tunnel support reports false so connections fall back to
    ///       the direct-SSH path — the flavor flag must NOT be hardcoded
    func testCoderDescriptorReportsNoTunnelSupportInAppStoreFlavor() {
        let descriptor = ProtocolDescriptor.coder(supportsTailnetTunnel: false)
        XCTAssertFalse(descriptor.supportsTailnetTunnel)
        XCTAssertNotEqual(
            descriptor,
            ProtocolDescriptor.coder(supportsTailnetTunnel: true),
            "the flavor flag must change descriptor identity — hardcoding it would mask an AppStore leak"
        )
    }

    /// SSH never gains tunnel support; the default must stay off so legacy
    /// call sites that omit the parameter cannot silently claim it.
    func testSSHAndDefaultDescriptorsNeverClaimTunnelSupport() {
        XCTAssertFalse(ProtocolDescriptor.ssh.supportsTailnetTunnel)
        let defaulted = ProtocolDescriptor(
            id: "mosh",
            displayName: "Mosh",
            supportsAgentForwarding: false,
            supportsJumpChain: false,
            supportsRoamingResume: true,
            requiresServerComponent: true,
            defaultPort: 60001,
            keyAlgorithmsAccepted: [],
            resumeStrategy: .nativeRoaming
        )
        XCTAssertFalse(defaulted.supportsTailnetTunnel)
    }

    // MARK: - CoderTunneling contract (dependency inversion proof)

    /// Given/When/Then: the full handle lifecycle runs through the `any
    /// CoderTunneling` existential implemented by a pure-Swift fake — the
    /// protocol is the boundary the real `CoderNetTunnel` (CoderTunnel
    /// framework target) will conform to.
    func testTunnelHandleLifecycleThroughExistential() async throws {
        let tunnel: any CoderTunneling = FakeCoderTunnel()

        XCTAssertFalse(tunnel.version().isEmpty, "version() mirrors CoderNetVersion()")

        let first = try await tunnel.start(configJSON: #"{"server_url":"https://coder.example"}"#)
        let second = try await tunnel.start(configJSON: #"{"server_url":"https://coder.example"}"#)
        XCTAssertNotEqual(first, second, "each start allocates a fresh handle")
        XCTAssertGreaterThan(first, 0, "handle 0 is the bridge's rejection sentinel")

        // T5 stub semantics: dial returns stream metadata as a string
        // (empty until T9 wires the byte channel).
        _ = try await tunnel.dialSSH(handle: first)

        tunnel.rebind(handle: first)
        tunnel.close(handle: first)
        tunnel.close(handle: first)
        tunnel.close(handle: second)
    }

    /// Given: a config the bridge cannot accept
    /// When: start is attempted
    /// Then: the typed rejection surfaces — never a sentinel handle escape
    func testStartRejectsConfigTheBridgeRefuses() async {
        let tunnel: any CoderTunneling = FakeCoderTunnel()
        do {
            _ = try await tunnel.start(configJSON: "")
            XCTFail("empty config must throw the typed rejection")
        } catch let error as CoderTunnelError {
            XCTAssertEqual(error, .startRejected)
        }
    }
}

/// Minimal in-memory conformer proving the contract needs no Go core. Handle
/// rules mirror the T5 C ABI: sequential handles from 1, 0 = rejection,
/// `close` is idempotent, unknown-handle semantics are the bridge's concern.
private final class FakeCoderTunnel: CoderTunneling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextHandle = 1
    private var open: Set<Int> = []

    func version() -> String { "fake-tunnel/1.0" }

    func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        guard !configJSON.isEmpty else { throw CoderTunnelError.startRejected }
        return lock.withLock {
            let handle = nextHandle
            nextHandle += 1
            open.insert(handle)
            return handle
        }
    }

    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String { "" }

    func rebind(handle: Int) {}

    func close(handle: Int) {
        lock.withLock { open.remove(handle) }
    }
}
