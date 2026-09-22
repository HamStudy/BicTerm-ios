import Foundation
import NIOCore
import NIOEmbedded
import XCTest
@testable import BicTermCore

/// `SharedExecCarrierPool` — the shared-first exec-carrier policy: exec
/// consumers ride ONE lazily-dialed shared SSH connection by default, and
/// the pool falls back to a DEDICATED per-lease connection only after a
/// channel-budget gateway (Coder-style: one session channel per
/// connection LIFETIME) denies the shared carrier's channel open — and
/// then stays sticky-dedicated. Hermetic: lock-confined fakes conforming
/// to ``SSHExecCapableConnection`` returning real ``SSHExecSession``
/// instances on `EmbeddedChannel` (the repo's NIOEmbedded-in-tests
/// pattern); no fixtures, no live SSH.
final class SharedExecCarrierPoolTests: XCTestCase {
    // MARK: (a) Shared-first

    func testGrantingGatewayRidesOneSharedDialAcrossSequentialLeases() async throws {
        let dialLog = DialLog()
        addTeardownBlock { dialLog.finishChannels() }
        let pool = SharedExecCarrierPool(dial: { dialLog.nextCarrier() })

        let first = try await pool.lease()
        let second = try await pool.lease()
        XCTAssertEqual(dialLog.count, 1, "both leases rode ONE lazily-dialed shared carrier")

        _ = try await first.openExecChannel(command: "probe-one")
        _ = try await second.openExecChannel(command: "probe-two")
        XCTAssertEqual(dialLog.count, 1, "opens on the established shared carrier never dial")
        XCTAssertEqual(
            dialLog.carriers[0].openCommands,
            ["probe-one", "probe-two"],
            "both channel opens rode the shared carrier"
        )

        // Shared-mode lease close is a RELEASE: the shared carrier
        // survives between consumers.
        await first.close()
        await second.close()
        XCTAssertEqual(
            dialLog.carriers[0].closeCount, 0,
            "a shared-mode lease close must not close the shared carrier"
        )

        await pool.close()
        XCTAssertEqual(dialLog.carriers[0].closeCount, 1, "pool.close() closes the shared carrier")
    }

    // MARK: (b) Denial → dedicated, sticky

    func testBudgetGatewayDenialFallsBackToDedicatedAndSticks() async throws {
        // Every carrier permits exactly ONE session channel per lifetime
        // (the CoderSSHGW shape).
        let dialLog = DialLog(carrierBudget: 1)
        addTeardownBlock { dialLog.finishChannels() }
        let pool = SharedExecCarrierPool(dial: { dialLog.nextCarrier() })

        // Lease 1: shared era — budget slot #1.
        let first = try await pool.lease()
        _ = try await first.openExecChannel(command: "probe-one")
        XCTAssertEqual(dialLog.count, 1)
        XCTAssertEqual(dialLog.carriers[0].openCommands, ["probe-one"])

        // Lease 2: the gateway's LIFETIME budget refuses the shared
        // carrier's second open — the pool retires the shared carrier,
        // goes sticky-dedicated, and hands lease 2 its OWN connection.
        let second = try await pool.lease()
        _ = try await second.openExecChannel(command: "probe-two")
        XCTAssertEqual(dialLog.count, 2, "the denial dialed a dedicated carrier")
        XCTAssertEqual(
            dialLog.carriers[0].openCommands,
            ["probe-one", "probe-two"],
            "the denied open was still ATTEMPTED on the shared carrier first"
        )
        XCTAssertEqual(dialLog.carriers[0].closeCount, 1, "the denial retired the shared carrier")
        XCTAssertEqual(
            dialLog.carriers[1].openCommands,
            ["probe-two"],
            "the retried open rode the dedicated carrier"
        )

        // Lease 3: sticky — a dedicated carrier is dialed directly at
        // lease time; the retired shared carrier is never touched again.
        let third = try await pool.lease()
        XCTAssertEqual(dialLog.count, 3, "sticky mode dials dedicated at lease time")
        _ = try await third.openExecChannel(command: "probe-three")
        XCTAssertEqual(dialLog.carriers[2].openCommands, ["probe-three"])
        XCTAssertEqual(
            dialLog.carriers[0].openCommands.count, 2,
            "the retired shared carrier saw no further opens"
        )

        // Owner-close contract: every lease closes EXACTLY what it owns.
        await first.close()
        XCTAssertEqual(
            dialLog.carriers[0].closeCount, 1,
            "shared-mode close releases only (the carrier was already retired by the fallback)"
        )
        await second.close()
        XCTAssertEqual(dialLog.carriers[1].closeCount, 1, "lease 2 closed its dedicated carrier")
        await third.close()
        XCTAssertEqual(dialLog.carriers[2].closeCount, 1, "lease 3 closed its dedicated carrier")
    }

    // MARK: (c) Dead-shared recovery

    func testDeadSharedCarrierIsRedialedOnceAndRetrySucceeds() async throws {
        let dialLog = DialLog()
        addTeardownBlock { dialLog.finishChannels() }
        let pool = SharedExecCarrierPool(dial: { dialLog.nextCarrier() })

        let lease = try await pool.lease()
        XCTAssertEqual(dialLog.count, 1)
        // The shared carrier goes stale: its open fails with a
        // NON-denial error (a dead link, not a budget refusal).
        dialLog.carriers[0].failNextOpen(with: .unreachable)

        _ = try await lease.openExecChannel(command: "revive")
        XCTAssertEqual(dialLog.count, 2, "the dead shared carrier was redialed exactly once")
        XCTAssertEqual(dialLog.carriers[0].closeCount, 1, "the stale shared carrier was closed")
        XCTAssertEqual(
            dialLog.carriers[1].openCommands,
            ["revive"],
            "the retried open rode the redialed shared carrier"
        )

        // The replacement IS the shared carrier (a non-denial error
        // never flips sticky): a fresh lease opens on it without another
        // dial.
        let follower = try await pool.lease()
        _ = try await follower.openExecChannel(command: "still-shared")
        XCTAssertEqual(dialLog.count, 2)
        XCTAssertEqual(dialLog.carriers[1].openCommands, ["revive", "still-shared"])

        await lease.close()
        await follower.close()
        await pool.close()
        XCTAssertEqual(dialLog.carriers[1].closeCount, 1)
    }

    // MARK: (d) Pool close

    func testPoolCloseClosesSharedCarrierAndRefusesFurtherLeases() async throws {
        let dialLog = DialLog()
        addTeardownBlock { dialLog.finishChannels() }
        let pool = SharedExecCarrierPool(dial: { dialLog.nextCarrier() })

        let lease = try await pool.lease()
        XCTAssertEqual(dialLog.count, 1)

        await pool.close()
        XCTAssertEqual(
            dialLog.carriers[0].closeCount, 1,
            "pool.close() closed the established shared carrier"
        )

        // Idempotent: a second close adds nothing.
        await pool.close()
        XCTAssertEqual(dialLog.carriers[0].closeCount, 1)

        // Post-close leases fail typed (the repo's used-after-close case).
        do {
            _ = try await pool.lease()
            XCTFail("lease after pool close must fail typed")
        } catch let error as TransportError {
            XCTAssertEqual(error, .channelDenied)
        }

        // An already-issued shared-mode lease still releases cleanly.
        await lease.close()
        XCTAssertEqual(dialLog.carriers[0].closeCount, 1)
    }

    // MARK: (e) Concurrent dial dedupe

    func testConcurrentLeasesAndOpensDedupeTheSharedDial() async throws {
        let dialLog = DialLog()
        addTeardownBlock { dialLog.finishChannels() }
        let pool = SharedExecCarrierPool(dial: { dialLog.nextCarrier() })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let lease = try await pool.lease()
                    _ = try await lease.openExecChannel(command: "concurrent-\(index)")
                    await lease.close()
                }
            }
            for try await _ in group { }
        }

        XCTAssertEqual(
            dialLog.count, 1,
            "all concurrent leases+opens rode ONE shared dial (single in-flight establish)"
        )
        XCTAssertEqual(
            dialLog.carriers[0].openCommands.count, 8,
            "every open rode the shared carrier"
        )
        XCTAssertEqual(
            dialLog.carriers[0].closeCount, 0,
            "shared-mode closes release only"
        )
        await pool.close()
        XCTAssertEqual(dialLog.carriers[0].closeCount, 1)
    }
}

/// Records every carrier the pool's `dial` closure produced. Each carrier
/// gets the same configurable lifetime session-channel budget, so a
/// budget of 1 models a Coder-style gateway on EVERY dialed connection.
private final class DialLog: @unchecked Sendable {
    private let lock = NSLock()
    private let carrierBudget: Int
    private var dialed: [StubCarrier] = []

    init(carrierBudget: Int = .max) {
        self.carrierBudget = carrierBudget
    }

    func nextCarrier() -> StubCarrier {
        let carrier = StubCarrier(channelBudget: carrierBudget)
        lock.lock()
        dialed.append(carrier)
        lock.unlock()
        return carrier
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return dialed.count
    }

    var carriers: [StubCarrier] {
        lock.lock()
        defer { lock.unlock() }
        return dialed
    }

    func finishChannels() {
        for carrier in carriers {
            carrier.finishChannels()
        }
    }
}

/// Lock-confined carrier double: records every open ATTEMPT (command
/// list), counts closes, denies opens beyond its lifetime budget with
/// typed `.channelDenied`, and can inject one-shot NON-denial failures
/// (the dead-link shape). Successful opens return real ``SSHExecSession``
/// instances on `EmbeddedChannel` so leases hold genuine session objects.
private final class StubCarrier: SSHExecCapableConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var closes = 0
    private var injectedFailures: [TransportError] = []
    private var channels: [EmbeddedChannel] = []
    private let channelBudget: Int

    init(channelBudget: Int = .max) {
        self.channelBudget = channelBudget
    }

    func openExecChannel(command: String) async throws(TransportError) -> SSHExecSession {
        // NSLock is unavailable from async contexts; the lock-confined
        // decision lives in the sync helper (the SSHExecSession pattern).
        switch decideOpen(command: command) {
        case let .success(session):
            return session
        case let .failure(error):
            throw error
        }
    }

    private enum OpenOutcome {
        case success(SSHExecSession)
        case failure(TransportError)
    }

    private func decideOpen(command: String) -> OpenOutcome {
        lock.lock()
        defer { lock.unlock() }
        commands.append(command)
        if !injectedFailures.isEmpty {
            return .failure(injectedFailures.removeFirst())
        }
        guard commands.count <= channelBudget else {
            return .failure(.channelDenied)
        }
        let core = ExecChannelCore()
        let handler = ExecChannelHandler(core: core)
        let channel = EmbeddedChannel(loop: EmbeddedEventLoop())
        core.attach(channel: channel)
        channels.append(channel)
        return .success(SSHExecSession(channel: channel, handler: handler, core: core))
    }

    func close() async {
        recordClose()
    }

    private func recordClose() {
        lock.lock()
        defer { lock.unlock() }
        closes += 1
    }

    // MARK: Test surface

    var openCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    func failNextOpen(with error: TransportError) {
        lock.lock()
        defer { lock.unlock() }
        injectedFailures.append(error)
    }

    func finishChannels() {
        lock.lock()
        let pending = channels
        channels = []
        lock.unlock()
        for channel in pending {
            _ = try? channel.finish()
        }
    }
}
