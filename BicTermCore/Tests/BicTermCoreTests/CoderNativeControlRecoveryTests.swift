import CoderNet
import Foundation
import XCTest
@testable import BicTermCore

final class CoderNativeControlRecoveryTests: XCTestCase {
    func testNativeControlRecoveryPreservesStreamWithoutReplay() async throws {
        nativeControlLogs.reset()
        CoderNetSetLogCallback(captureNativeControlLog)
        defer { CoderNetSetLogCallback(nil) }
        struct Proxy: Decodable { let url: URL; let mode: String }
        struct Ledger: Decodable {
            struct Attempt: Decodable { let resume_present: Bool; let injected: Bool; let status: Int? }
            let attempts: [Attempt]
        }
        let base = SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-acceptance/g12-control")
        let proxy = try JSONDecoder().decode(Proxy.self, from: Data(contentsOf: base.appendingPathComponent("proxy.json")))
        let fixture = try await CoderNativeFixture.load(name: "g12-control", serverURLOverride: proxy.url)
        let transport = fixture.transport()
        let sink = TransportTestSink()
        let output = await transport.output
        let collector = Task { for await bytes in output { await sink.append(bytes) } }
        let counter = "g12-counter-\(UUID().uuidString)"
        let sentinelPath = base.appendingPathComponent("terminal-sentinels.json")
        var sentinels = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: sentinelPath))) ?? []
        sentinels.append(counter)
        let sentinelBytes = try JSONEncoder().encode(sentinels)
        XCTAssertTrue(FileManager.default.createFile(atPath: sentinelPath.path, contents: sentinelBytes, attributes: [.posixPermissions: 0o600]))
        do {
            try await transport.connect(to: fixture.connection(), cols: 80, rows: 24)
            try await transport.send(Data("n=0; if [ -f \(counter) ]; then n=$(cat \(counter)); fi; n=$((n+1)); printf '%s' \"$n\" > \(counter); printf '\\nG12-COUNT:%s\\n' \"$n\"\n".utf8))
            let executed = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                await String(decoding: sink.snapshot(), as: UTF8.self).contains("G12-COUNT:1")
            }
            XCTAssertTrue(executed)
            try Data().write(to: base.appendingPathComponent("reset-request"), options: .atomic)
            let recovered = await waitForSuiteCondition(timeoutMilliseconds: 30000) {
                guard let bytes = try? Data(contentsOf: base.appendingPathComponent("control-ledger.json")),
                      let ledger = try? JSONDecoder().decode(Ledger.self, from: bytes) else { return false }
                if proxy.mode == "resume" {
                    guard let rejected = ledger.attempts.firstIndex(where: { $0.injected && $0.status == 401 }) else { return false }
                    return ledger.attempts.dropFirst(rejected + 1).contains { !$0.resume_present && $0.status == 101 }
                }
                return ledger.attempts.filter { $0.status == 101 }.count >= 2
            }
            XCTAssertTrue(recovered, "Control reconnect must complete; invalid resume credentials must be omitted on retry")
            try await transport.send(Data("printf '\\nG12-CHECK:%s\\n' \"$(cat \(counter))\"\n".utf8))
            let unchanged = await waitForSuiteCondition(timeoutMilliseconds: 15000) {
                await String(decoding: sink.snapshot(), as: UTF8.self).contains("G12-CHECK:1")
            }
            XCTAssertTrue(unchanged, "The original remote execution counter must remain one after recovery")
            let establishments = await transport.sessionEstablishments
            XCTAssertEqual(establishments, 1)
            print("NATIVE_CONTROL \(proxy.mode) recovered; command counter remains one; SSH establishment count=\(establishments)")
        } catch {
            await transport.close()
            collector.cancel()
            throw error
        }
        await transport.close()
        collector.cancel()
        let diagnostics = nativeControlLogs.snapshot().joined(separator: "\n")
        XCTAssertFalse(diagnostics.isEmpty, "The audit must observe real bridge diagnostics")
        XCTAssertFalse(diagnostics.contains(counter), "Terminal data must not enter bridge diagnostics")
        try Data(diagnostics.utf8).write(to: SSHTestFixture.repoRoot.appendingPathComponent(".sisyphus/evidence/phase2-g12-b-control-\(proxy.mode)-bridge.log"))
    }
}

private let nativeControlLogs = NativeControlLogCapture()

private func captureNativeControlLog(_: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    nativeControlLogs.append(String(cString: message))
}

private final class NativeControlLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func reset() { lock.lock(); defer { lock.unlock() }; lines = [] }
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
