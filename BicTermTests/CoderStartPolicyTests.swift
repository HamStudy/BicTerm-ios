import BicTermCore
import Foundation
import XCTest
@testable import BicTerm

@MainActor
final class CoderStartPolicyTests: XCTestCase {
    func testRunningWorkspaceRequiresSelectionWhenMultipleAgentsHaveNoSavedID() throws {
        // Given
        let agents = try JSONDecoder().decode(
            [CoderWorkspaceAgent].self,
            from: Data(#"[{"id":"44444444-4444-4444-8444-444444444444","name":"main","status":"connected"},{"id":"55555555-5555-4555-8555-555555555555","name":"sidecar","status":"connected"}]"#.utf8)
        )

        // When
        let resolution = CoderStartFlowView.agentReResolution(
            savedAgentID: nil,
            connectedAgents: agents
        )

        // Then
        guard case .actionRequired(_, _, let candidates) = resolution else {
            XCTFail("A running workspace with multiple agents must require an explicit selection")
            return
        }
        XCTAssertEqual(candidates.map(\.id), agents.map(\.id))
        XCTAssertEqual(candidates.map(\.name), ["main", "sidecar"])
    }
}
