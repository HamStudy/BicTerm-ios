import Foundation
import XCTest
@testable import BicTermCore

/// T3 live proof: a REAL `remote-client-bridge` handshake through the fixture
/// sshd (127.0.0.1:12222) against the prebuilt herdr 0.9.0 fixture server.
///
/// Prerequisites (skips with a clear reason otherwise): `scripts/fixtures-up.sh`
/// with the herdr fixture servers running — fetch the pinned binary first with
/// `scripts/herdr-server-fetch.sh`. The fixture sshd `SetEnv HERDR_SOCKET_PATH`
/// resolves the bridge to `Fixtures/run/herdr/server-12222`, exactly the fixed
/// command shape production code builds (``HerdrCommandBuilder`` — no env
/// prefix is possible in that command string).
///
/// Protocol provenance (integration doc §4 + vendored codec): the client
/// handshake is `ClientMessage.endpoint.hello.v1` carrying an
/// `EndpointClientHello` JSON (generation 1, the four v1 codecs,
/// direct_graphics off); the server answers `endpoint.welcome.v1`. The hello
/// bytes below were produced by the REAL extracted codec
/// (`herdr_protocol::write_message`, see `.scratch/hello-frame/`) from the
/// same field values `herdr-ios-ffi/src/factory.rs` sends (80x24, 10x20
/// cells, no pixel mouse, no capture) — byte-identical protocol input.
///
/// Wire shape (bincode 2 `config::standard()`): `[u32 LE payload length]`
/// then payload = enum tag (varint: single byte ≤250, or 251/252/253 +
/// little-endian u16/u32/u64) + length-prefixed strings, each length using
/// the same varint scheme.
final class HerdrServerFixtureHandshakeTests: XCTestCase {
    private var transport: SSHTransport?

    override func tearDown() async throws {
        if let transport {
            await transport.close()
        }
        transport = nil
        try await super.tearDown()
    }

    /// The generation-1 client hello frame (388 bytes; see class docs).
    static let helloFrame = Data(
        hex: "800100001411656e64706f696e742e68656c6c6f2e7631fb6a017b2267656e65726174696f6e223a312c2263656c6c5f77696474685f7078223a31302c2263656c6c5f6865696768745f7078223a32302c22737572666163655f73697a65223a7b22636f6c73223a38302c22726f7773223a32347d2c22706978656c5f6d6f757365223a66616c73652c226469726563745f6772617068696373223a66616c73652c22656e64706f696e745f6b657962696e64696e6773223a66616c73652c226d6f7573655f63617074757265223a66616c73652c22737572666163655f616374697665223a747275652c22736e617073686f745f636f64656373223a5b227368656c6c2e736e617073686f742e7631225d2c22737572666163655f636f64656373223a5b227368656c6c2e737572666163652e7631225d2c22696e7075745f636f64656373223a5b227368656c6c2e696e7075742e73656d616e7469632e7631225d2c22626c6f625f636f64656373223a5b227368656c6c2e626c6f622e7631225d7d"
    )

    /// Runs the fixed bridge command over the fixture sshd, performs the
    /// endpoint handshake, and asserts the server's welcome proves BOTH
    /// direction flowed: the welcome only exists as a response to a valid
    /// client hello, and it carries the capabilities saved-machine support
    /// requires (surface_interest, health_check).
    func testBridgeHandshakeDeliversWelcomeFromFixtureServer() async throws {
        let repoRoot = SSHTestFixture.repoRoot
        let clientSocket = repoRoot.appendingPathComponent("Fixtures/run/herdr/server-12222/herdr-client.sock")
        let binary = repoRoot.appendingPathComponent("Fixtures/run/herdr/herdr")
        let fm = FileManager.default
        try XCTSkipUnless(
            fm.fileExists(atPath: binary.path) && fm.fileExists(atPath: clientSocket.path),
            "herdr fixture server not running — run scripts/herdr-server-fetch.sh and scripts/fixtures-up.sh"
        )

        let key = try await SSHTestFixture.loadFixtureEd25519Key()
        let sshTransport = SSHTransport(
            hostKeyVerifier: try await SSHTestFixture.makeVerifier(),
            authenticationKeyProvider: StaticKeyProvider(key: key)
        )
        try await sshTransport.connect(to: SSHTestFixture.makeConnection(), cols: 80, rows: 24)
        transport = sshTransport

        let bridge = try await HerdrSSHTransport(
            transport: sshTransport,
            executablePath: binary.path
        )

        try await bridge.write(Self.helloFrame)

        let sink = SSHOutputSink()
        let inboundTask = Task { [bridge] in
            do {
                for try await chunk in bridge.inboundBytes() {
                    await sink.append(chunk)
                }
            } catch {
                // Inbound overflow surfaces as a test failure below: the
                // sink snapshot will not contain a complete frame.
            }
            await sink.markFinished()
        }
        defer { inboundTask.cancel() }

        var firstFrame: Data?
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline {
            if let frame = Self.firstCompleteFrame(in: await sink.snapshot()) {
                firstFrame = frame
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let totalInbound = await sink.snapshot().count
        let frame = try XCTUnwrap(firstFrame, "no protocol frame arrived; bridge produced \(totalInbound) bytes")
        let welcome = try Self.parseWelcome(frame: frame)

        print("T3 bridge proof: \(totalInbound) inbound bytes, first frame \(frame.count) bytes")
        print("T3 bridge proof: kind=\(welcome.kind)")
        print("T3 bridge proof: json=\(welcome.json)")

        XCTAssertEqual(welcome.kind, "endpoint.welcome.v1")
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(welcome.json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["generation"] as? Int, 1)
        XCTAssertEqual(decoded["server_version"] as? String, "0.9.0")
        let capabilities = try XCTUnwrap(decoded["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains("surface_interest"), "missing surface_interest in \(capabilities)")
        XCTAssertTrue(capabilities.contains("health_check"), "missing health_check in \(capabilities)")

        await bridge.close()
        let termination = await bridge.termination()
        XCTAssertEqual(termination, .closedLocally, "clean local close after handshake")
    }
}

// MARK: - Minimal bincode-2 wire reader (exactly what this frame needs)

private enum WireReaderError: Error, Equatable {
    case truncated
    case unexpectedLengthPrefix(UInt8)
}

private struct WireReader {
    let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func byte() throws -> UInt8 {
        guard index < bytes.count else { throw WireReaderError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func rawBytes(_ count: Int) throws -> [UInt8] {
        guard index + count <= bytes.count else { throw WireReaderError.truncated }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    /// bincode-2 `config::standard()` integer: ≤250 single byte, else a width
    /// tag (251 u16 / 252 u32 / 253 u64) + little-endian payload.
    mutating func varint() throws -> UInt64 {
        let first = try byte()
        switch first {
        case 0...250: return UInt64(first)
        case 251: return try readLE(2)
        case 252: return try readLE(4)
        case 253: return try readLE(8)
        default: throw WireReaderError.unexpectedLengthPrefix(first)
        }
    }

    private mutating func readLE(_ width: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for (position, byte) in try rawBytes(width).enumerated() {
            value |= UInt64(byte) << (8 * position)
        }
        return value
    }

    mutating func string() throws -> String {
        let length = try varint()
        guard length <= UInt64(UInt32.max) else { throw WireReaderError.truncated }
        return String(decoding: try rawBytes(Int(length)), as: UTF8.self)
    }
}

extension HerdrServerFixtureHandshakeTests {
    /// Splits `[u32 LE length][payload]` and returns the first full payload.
    static func firstCompleteFrame(in data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let header = [UInt8](data.prefix(4))
        let length = UInt32(header[0])
            | UInt32(header[1]) << 8
            | UInt32(header[2]) << 16
            | UInt32(header[3]) << 24
        let frameEnd = 4 + Int(length)
        guard length > 0, data.count >= frameEnd else { return nil }
        return data.subdata(in: 4..<frameEnd)
    }

    static func parseWelcome(frame: Data) throws -> (kind: String, json: String) {
        var reader = WireReader(frame)
        _ = try reader.varint() // enum tag: ServerMessage endpoint-control variant
        return (kind: try reader.string(), json: try reader.string())
    }
}

private extension Data {
    init(hex string: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.count / 2)
        var current: UInt8?
        for character in string {
            guard let digit = character.hexDigitValue.map(UInt8.init) else { continue }
            if let high = current {
                bytes.append(high << 4 | digit)
                current = nil
            } else {
                current = digit
            }
        }
        self = Data(bytes)
    }
}
