import Foundation
import XCTest
@testable import BicTermCore

/// T10: the CoderNetEvent taxonomy contract (spec §8.7 + §15) — parse the
/// tagged bridge line, then prove the §15 discriminator: a 401 whose
/// validations name `resume_token` NEVER surfaces as `authRequired`, while a
/// genuine primary 401 marks exactly once.
final class CoderEventClassificationTests: XCTestCase {
    private let serverID = UUID()

    // MARK: - Wire contract

    func testTaggedBridgeLineParsesIntoTypedEvent() throws {
        let expected = CoderNetEvent(
            type: .networkPathChanged,
            source: .derp,
            httpStatus: nil,
            handle: 7,
            path: .relayed
        )
        let parsed = CoderNetEvent.parse(bridgeLine: expected.encodedBridgeLine())
        XCTAssertEqual(parsed, expected, "the tagged line must round-trip through the parser byte-for-byte")
    }

    func testParseCarriesHTTPStatusAndValidations() throws {
        let line = #"{"codernet_event":{"type":"authRequired","source":"coord","http_status":401,"validations":["resume_token"],"handle":3}}"#
        let event = try XCTUnwrap(CoderNetEvent.parse(bridgeLine: line))
        XCTAssertEqual(event.type, .authRequired)
        XCTAssertEqual(event.source, .coord)
        XCTAssertEqual(event.httpStatus, 401)
        XCTAssertEqual(event.validations, ["resume_token"])
        XCTAssertEqual(event.handle, 3)
        XCTAssertNil(event.path)
    }

    func testPlainDiagnosticLineIsNotAnEvent() {
        XCTAssertNil(CoderNetEvent.parse(bridgeLine: "dial: ssh proxy bound /tmp/x.sock"))
        XCTAssertNil(CoderNetEvent.parse(bridgeLine: ""))
        XCTAssertNil(CoderNetEvent.parse(bridgeLine: #"{"codernet_event":{"type":"futureNewType","source":"ssh"}}"#))
    }

    // MARK: - Disposition table

    func testDispositionIsTypeDrivenWithoutResumeTokenMarker() {
        let cases: [(CoderNetEvent, CoderEventDisposition)] = [
            (CoderNetEvent(type: .authRequired, source: .rest, httpStatus: 401), .authRequired),
            (CoderNetEvent(type: .authRequired, source: .coord, httpStatus: 401), .authRequired),
            (CoderNetEvent(type: .sshClosed, source: .ssh), .sessionReconnectRequired),
            (CoderNetEvent(type: .coordReconnecting, source: .coord), .consumeInternally),
            (CoderNetEvent(type: .networkPathChanged, source: .derp, path: .direct), .consumeInternally),
            (CoderNetEvent(type: .resumeRefreshed, source: .coord), .consumeInternally),
            (CoderNetEvent(type: .transientError, source: .rest, httpStatus: 503), .consumeInternally),
        ]
        for (event, expected) in cases {
            XCTAssertEqual(CoderEventClassifier.disposition(of: event), expected, "\(event)")
        }
    }

    // MARK: - Resume-token quarantine (spec §8.7 + §15 row 1)

    func testResumeTokenValidationQuarantinesAnyTaggedType() {
        // A mislabelled type must not matter: the validations marker decides.
        // The Go core classifies resume-token rejections internally; this
        // guard is the Swift-side belt that proves none can leak through.
        let quarantined: [CoderNetEvent] = [
            CoderNetEvent(type: .authRequired, source: .coord, httpStatus: 401, validations: ["resume_token"]),
            CoderNetEvent(type: .authRequired, source: .rest, httpStatus: 401, validations: ["resume_token"]),
            CoderNetEvent(type: .transientError, source: .coord, httpStatus: 401, validations: ["resume_token"]),
        ]
        for event in quarantined {
            XCTAssertEqual(
                CoderEventClassifier.disposition(of: event),
                .consumeInternally,
                "resume_token validation must never surface as authRequired: \(event)"
            )
        }
    }

    func testOtherValidationFieldsDoNotQuarantine() {
        let event = CoderNetEvent(type: .authRequired, source: .rest, httpStatus: 401, validations: ["session_token"])
        XCTAssertEqual(CoderEventClassifier.disposition(of: event), .authRequired)
    }

    // MARK: - Coordinator-level sequences (fake events → generation state)

    func testResumeToken401SequenceSurfacesNoAuthLoss() async {
        let authLosses = AuthLossRecorder()
        let generations = CoderCredentialGenerations()
        let (stream, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let coordinator = CoderLifecycleCoordinator(generations: generations, events: stream) { id in
            await authLosses.record(id)
        }
        await coordinator.register(CoderSessionRegistration(
            handle: 1, sceneID: "scene-a", serverID: serverID,
            credentialGenerationID: 1, usageReporter: nil
        ))
        await coordinator.start()

        continuation.yield(CoderNetEvent(type: .resumeRefreshed, source: .coord))
        continuation.yield(CoderNetEvent(
            type: .transientError, source: .coord, httpStatus: 401, validations: ["resume_token"], handle: 1
        ))
        continuation.yield(CoderNetEvent(
            type: .authRequired, source: .coord, httpStatus: 401, validations: ["resume_token"], handle: 1
        ))

        // Negative assertion: give the consumption loop a real window to
        // (wrongly) act, then prove nothing moved.
        try? await Task.sleep(for: .milliseconds(250))
        let generation = await generations.generation(for: serverID)
        XCTAssertEqual(generation.state, .active, "a resume-token-401 sequence must not mark the generation")
        let observedLosses = await authLosses.count()
        XCTAssertEqual(observedLosses, 0)
    }

    func testGenuineRest401MarksAuthRequiredExactlyOnce() async {
        let authLosses = AuthLossRecorder()
        let generations = CoderCredentialGenerations()
        let (stream, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let coordinator = CoderLifecycleCoordinator(generations: generations, events: stream) { id in
            await authLosses.record(id)
        }
        await coordinator.register(CoderSessionRegistration(
            handle: 9, sceneID: "scene-b", serverID: serverID,
            credentialGenerationID: 1, usageReporter: nil
        ))
        await coordinator.start()

        let genuine = CoderNetEvent(type: .authRequired, source: .rest, httpStatus: 401, handle: 9)
        continuation.yield(genuine)

        let marked = await waitForSuiteCondition(timeoutMilliseconds: 2000) {
            await generations.generation(for: self.serverID).state == .authRequired
        }
        XCTAssertTrue(marked, "a genuine REST 401 must mark the generation")

        // Duplicate delivery (SDK may repeat the observation): still one signal.
        continuation.yield(genuine)
        try? await Task.sleep(for: .milliseconds(200))
        let lossCount = await authLosses.count()
        let firstLoss = await authLosses.first()
        XCTAssertEqual(lossCount, 1, "authRequired surfaces exactly once per generation")
        XCTAssertEqual(firstLoss, serverID)
    }

    func testStaleHandleEventDoesNotCondemnReplacementGeneration() async {
        let authLosses = AuthLossRecorder()
        let generations = CoderCredentialGenerations()
        let (stream, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let coordinator = CoderLifecycleCoordinator(generations: generations, events: stream) { id in
            await authLosses.record(id)
        }
        await coordinator.register(CoderSessionRegistration(
            handle: 1, sceneID: "scene-c", serverID: serverID,
            credentialGenerationID: 1, usageReporter: nil
        ))
        await coordinator.start()

        continuation.yield(CoderNetEvent(type: .authRequired, source: .coord, httpStatus: 401, handle: 1))
        let marked = await waitForSuiteCondition(timeoutMilliseconds: 2000) {
            await generations.generation(for: self.serverID).state == .authRequired
        }
        XCTAssertTrue(marked)

        let replacement = await generations.installReplacement(for: serverID)
        XCTAssertEqual(replacement.id, 2)
        let markedLosses = await authLosses.count()
        XCTAssertEqual(markedLosses, 1)

        // A LATE auth observation from the pre-replacement handle must not
        // mark generation 2: the old session's death throes speak for the
        // credential it ran with, not the replacement.
        continuation.yield(CoderNetEvent(type: .authRequired, source: .coord, httpStatus: 401, handle: 1))
        try? await Task.sleep(for: .milliseconds(200))
        let current = await generations.generation(for: serverID)
        let lossesAfterStaleEvent = await authLosses.count()
        XCTAssertEqual(current, CoderCredentialGeneration(id: 2, state: .active))
        XCTAssertEqual(lossesAfterStaleEvent, 1, "replacement generation must not re-fire auth loss")
    }

    func testHandleLessAuthRequiredEventIsNotRouted() async {
        let authLosses = AuthLossRecorder()
        let generations = CoderCredentialGenerations()
        let (stream, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let coordinator = CoderLifecycleCoordinator(generations: generations, events: stream) { id in
            await authLosses.record(id)
        }
        await coordinator.register(CoderSessionRegistration(
            handle: 5, sceneID: "scene-d", serverID: serverID,
            credentialGenerationID: 1, usageReporter: nil
        ))
        await coordinator.start()

        continuation.yield(CoderNetEvent(type: .authRequired, source: .rest, httpStatus: 401))
        try? await Task.sleep(for: .milliseconds(200))
        let unroutedLosses = await authLosses.count()
        XCTAssertEqual(unroutedLosses, 0, "no routing anchor, no attribution")
    }
}

/// Thread-safe recorder for `onAuthLoss` deliveries.
private actor AuthLossRecorder {
    private var seen: [UUID] = []
    func record(_ serverID: UUID) { seen.append(serverID) }
    func count() -> Int { seen.count }
    func first() -> UUID? { seen.first }
}
