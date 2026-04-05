import SharedModels
import XCTest
@testable import FeatureThreads

final class FeatureThreadsTests: XCTestCase {
    func testClientSubagentPlannerBuildsPlanFromBulletList() {
        let plan = ClientOrchestratedSubagentPlanner.makePlan(
            from: """
            - Audit the route planner
            - Verify the SSH fallback path
            - Summarize remaining risks
            """
        )

        XCTAssertEqual(plan?.tasks.count, 3)
        XCTAssertEqual(plan?.tasks.first?.ordinal, 1)
        XCTAssertTrue(plan?.tasks.first?.prompt.contains("Client-orchestrated subtask 1 of 3") == true)
    }

    func testClientSubagentPlannerIgnoresSingleParagraphPrompt() {
        let plan = ClientOrchestratedSubagentPlanner.makePlan(
            from: "Investigate the reconnect issue and report back."
        )

        XCTAssertNil(plan)
    }

    func testClientSubagentSummaryTracksQueuedAndRunningWork() {
        let tasks = [
            ClientSubagentTask(ordinal: 1, title: "Audit", prompt: "Audit", status: .completed),
            ClientSubagentTask(ordinal: 2, title: "Fix", prompt: "Fix", status: .running),
            ClientSubagentTask(ordinal: 3, title: "Verify", prompt: "Verify", status: .queued)
        ]

        XCTAssertEqual(
            ClientOrchestratedSubagentPlanner.summary(for: tasks),
            "Running subtask 2/3: Fix · 1 completed, 1 queued"
        )
    }

    func testRestoreCandidatePicksMostRecentSession() {
        let machineID = MachineRecord.preview.id
        let older = SessionRecord(
            machineID: machineID,
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .distantPast
        )
        let newer = SessionRecord(
            machineID: machineID,
            threadID: "thread-1",
            lastKnownProtocol: .websocket,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now
        )

        let restored = ThreadFeature.restoreCandidate(sessions: [older, newer], machineID: machineID)
        XCTAssertEqual(restored?.threadID, "thread-1")
    }
}
