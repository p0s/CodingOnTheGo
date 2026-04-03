import XCTest
@testable import Notifications
import SharedModels

final class NotificationsTests: XCTestCase {
    private let sampleWorkspaceRoot = "/workspace/coding-on-the-go"

    func testPlannerBuildsCompletionBlueprintFromSession() {
        let session = SessionRecord(
            machineID: MachineRecord.preview.id,
            routeID: nil,
            threadID: "thread-123",
            workspaceRoot: sampleWorkspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now
        )

        let blueprint = SessionNotificationPlanner().blueprint(
            for: .sessionCompleted(session: session, summary: "Turn completed")
        )

        XCTAssertEqual(blueprint.title, "Session finished: \(sampleWorkspaceRoot)")
        XCTAssertEqual(blueprint.body, "Turn completed")
        XCTAssertEqual(blueprint.threadIdentifier, "thread-123")
        XCTAssertEqual(blueprint.categoryIdentifier, "session-completed")
        XCTAssertEqual(blueprint.deliveryTier, .local)
    }

    func testCoordinatorDeliversPlannedBlueprint() async throws {
        let session = SessionRecord(
            machineID: MachineRecord.preview.id,
            routeID: nil,
            threadID: nil,
            workspaceRoot: sampleWorkspaceRoot,
            lastKnownProtocol: .websocket,
            lastKnownBootstrap: .companionManaged,
            lastOpenedAt: .now
        )
        let deliverer = FakeDeliverer()
        let coordinator = NotificationSessionDispatcher(deliverer: deliverer)

        try await coordinator.handle(.sessionFailed(session: session, reason: "SSH unavailable"))

        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertEqual(deliverer.delivered.first?.categoryIdentifier, "session-failed")
        XCTAssertEqual(deliverer.delivered.first?.body, "SSH unavailable")
    }

    func testOutboxPersistsDeliveredEntriesForFileRelayBridge() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        let outboxURL = root.appending(path: "outbox.json")
        let relayDirectory = root.appending(path: "relay")
        let coordinator = BridgedNotificationCoordinator(
            outbox: JSONNotificationOutboxStore(url: outboxURL),
            bridgeSubmitter: FileRelayNotificationSubmitter(directoryURL: relayDirectory),
            localDeliverer: nil
        )

        let completion = CompletionNotification(
            machineAlias: "example-mac",
            threadID: "thread-456",
            summary: "Applied workspace revert"
        )

        try await coordinator.scheduleCompletion(completion)
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(snapshot.bridge.mode, .fileRelay)
        XCTAssertEqual(snapshot.bridge.pendingCount, 0)
        XCTAssertEqual(snapshot.bridge.deliveredCount, 1)

        let relayFiles = try FileManager.default.contentsOfDirectory(atPath: relayDirectory.path)
        XCTAssertEqual(relayFiles.count, 1)
    }

    func testOutboxMarksFailedBrokerSubmission() async throws {
        let outboxURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(UUID().uuidString)-outbox.json")
        let coordinator = BridgedNotificationCoordinator(
            outbox: JSONNotificationOutboxStore(url: outboxURL),
            bridgeSubmitter: FailingBridgeSubmitter(),
            localDeliverer: nil
        )

        do {
            try await coordinator.scheduleCompletion(
                CompletionNotification(machineAlias: "example-mac", summary: "Will fail")
            )
            XCTFail("Expected broker submission failure.")
        } catch {
            let snapshot = await coordinator.snapshot()
            XCTAssertEqual(snapshot.bridge.failedCount, 1)
            XCTAssertEqual(snapshot.bridge.pendingCount, 0)
            XCTAssertEqual(snapshot.bridge.mode, .broker)
        }
    }
}

private final class FakeDeliverer: NotificationDelivering, @unchecked Sendable {
    var delivered: [NotificationBlueprint] = []

    func deliver(_ blueprint: NotificationBlueprint) async throws {
        delivered.append(blueprint)
    }
}

private struct FailingBridgeSubmitter: NotificationBridgeSubmitting {
    let mode: NotificationBridgeMode = .broker
    let relayDescription = "https://broker.invalid"

    func submit(_ blueprint: NotificationBlueprint) async throws {
        _ = blueprint
        throw NotificationBridgeError.submissionFailed("Broker unavailable")
    }
}
