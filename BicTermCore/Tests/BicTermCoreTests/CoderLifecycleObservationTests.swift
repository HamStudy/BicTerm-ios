import Foundation
import XCTest
@testable import BicTermCore

final class CoderLifecycleObservationTests: XCTestCase {
    func testNetworkPathObservationRoutesDirectAndRelayedToTheirActiveScenes() async {
        // Given
        let directServerID = UUID()
        let relayedServerID = UUID()
        let observations = PathObservationRecorder()
        let (events, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let coordinator = CoderLifecycleCoordinator(
            events: events,
            onSessionEvent: { event, registration in
                await observations.apply(event, sceneID: registration.sceneID)
            }
        )
        await coordinator.register(CoderSessionRegistration(
            handle: 11,
            sceneID: "scene-direct",
            serverID: directServerID,
            credentialGenerationID: 1,
            usageReporter: nil
        ))
        await coordinator.register(CoderSessionRegistration(
            handle: 22,
            sceneID: "scene-relayed",
            serverID: relayedServerID,
            credentialGenerationID: 1,
            usageReporter: nil
        ))
        await coordinator.start()

        // When
        continuation.yield(CoderNetEvent(
            type: .networkPathChanged,
            source: .derp,
            handle: 11,
            path: .direct
        ))
        continuation.yield(CoderNetEvent(
            type: .networkPathChanged,
            source: .derp,
            handle: 22,
            path: .relayed
        ))

        // Then
        let observed = await waitForSuiteCondition {
            await observations.count() == 2
        }
        let directPath = await observations.path(forScene: "scene-direct")
        let relayedPath = await observations.path(forScene: "scene-relayed")
        XCTAssertTrue(observed)
        XCTAssertEqual(directPath, .direct)
        XCTAssertEqual(relayedPath, .relayed)
        continuation.finish()
    }

    func testNetworkPathObservationIgnoresStaleGenerationAndAcceptsReplacementSession() async {
        // Given
        let serverID = UUID()
        let generations = CoderCredentialGenerations()
        let observations = PathObservationRecorder()
        let (events, continuation) = AsyncStream<CoderNetEvent>.makeStream()
        let coordinator = CoderLifecycleCoordinator(
            generations: generations,
            events: events,
            onSessionEvent: { event, registration in
                await observations.apply(event, sceneID: registration.sceneID)
            }
        )
        await coordinator.register(CoderSessionRegistration(
            handle: 31,
            sceneID: "scene-stale",
            serverID: serverID,
            credentialGenerationID: 1,
            usageReporter: nil
        ))
        let replacement = await generations.installReplacement(for: serverID)
        await coordinator.register(CoderSessionRegistration(
            handle: 32,
            sceneID: "scene-replacement",
            serverID: serverID,
            credentialGenerationID: replacement.id,
            usageReporter: nil
        ))
        await coordinator.start()

        // When
        continuation.yield(CoderNetEvent(
            type: .networkPathChanged,
            source: .derp,
            handle: 31,
            path: .direct
        ))
        continuation.yield(CoderNetEvent(
            type: .networkPathChanged,
            source: .derp,
            handle: 32,
            path: .relayed
        ))

        // Then
        let observed = await waitForSuiteCondition {
            await observations.count() == 1
        }
        let stalePath = await observations.path(forScene: "scene-stale")
        let replacementPath = await observations.path(forScene: "scene-replacement")
        XCTAssertTrue(observed)
        XCTAssertNil(stalePath)
        XCTAssertEqual(replacementPath, .relayed)
        continuation.finish()
    }
}

private actor PathObservationRecorder {
    private var paths: [String: CoderNetPathKind] = [:]

    func apply(_ event: CoderNetEvent, sceneID: String) {
        guard event.type == .networkPathChanged, let path = event.path else { return }
        paths[sceneID] = path
    }

    func count() -> Int {
        paths.count
    }

    func path(forScene sceneID: String) -> CoderNetPathKind? {
        paths[sceneID]
    }
}
