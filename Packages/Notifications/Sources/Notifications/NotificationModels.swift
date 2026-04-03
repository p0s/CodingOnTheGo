import Foundation
import SharedModels

#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#endif

public enum NotificationDeliveryTier: String, Codable, CaseIterable, Sendable {
    case local
    case bestEffortZeroInstall
    case companionReliable
}

public enum NotificationEvent: Hashable, Sendable {
    case sessionCompleted(session: SessionRecord, summary: String)
    case sessionFailed(session: SessionRecord, reason: String)
    case routeRecovered(machine: MachineRecord)
}

public struct NotificationBlueprint: Hashable, Codable, Sendable {
    public var title: String
    public var body: String
    public var threadIdentifier: String
    public var categoryIdentifier: String
    public var deliveryTier: NotificationDeliveryTier

    public init(
        title: String,
        body: String,
        threadIdentifier: String,
        categoryIdentifier: String,
        deliveryTier: NotificationDeliveryTier
    ) {
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.deliveryTier = deliveryTier
    }
}

public protocol NotificationDelivering: Sendable {
    func deliver(_ blueprint: NotificationBlueprint) async throws
}

public struct SessionNotificationPlanner: Sendable {
    public init() {}

    public func blueprint(for event: NotificationEvent) -> NotificationBlueprint {
        switch event {
        case let .sessionCompleted(session, summary):
            NotificationBlueprint(
                title: session.workspaceRoot.map { "Session finished: \($0)" } ?? "Session finished",
                body: summary,
                threadIdentifier: notificationThreadIdentifier(for: session),
                categoryIdentifier: "session-completed",
                deliveryTier: .local
            )
        case let .sessionFailed(session, reason):
            NotificationBlueprint(
                title: session.workspaceRoot.map { "Session failed: \($0)" } ?? "Session failed",
                body: reason,
                threadIdentifier: notificationThreadIdentifier(for: session),
                categoryIdentifier: "session-failed",
                deliveryTier: .bestEffortZeroInstall
            )
        case let .routeRecovered(machine):
            NotificationBlueprint(
                title: "Route recovered: \(machine.alias)",
                body: machine.preferredRoute?.label ?? machine.hostname,
                threadIdentifier: machine.id.uuidString,
                categoryIdentifier: "route-recovered",
                deliveryTier: .companionReliable
            )
        }
    }

    private func notificationThreadIdentifier(for session: SessionRecord) -> String {
        session.threadID ?? session.id.uuidString
    }
}

public actor NotificationSessionDispatcher {
    private let deliverer: NotificationDelivering
    private let planner: SessionNotificationPlanner

    public init(deliverer: NotificationDelivering, planner: SessionNotificationPlanner = SessionNotificationPlanner()) {
        self.deliverer = deliverer
        self.planner = planner
    }

    public func handle(_ event: NotificationEvent) async throws {
        try await deliverer.deliver(planner.blueprint(for: event))
    }
}

#if canImport(UserNotifications)
public final class UserNotificationCenterAdapter: NotificationDelivering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func deliver(_ blueprint: NotificationBlueprint) async throws {
        let content = UNMutableNotificationContent()
        content.title = blueprint.title
        content.body = blueprint.body
        content.threadIdentifier = blueprint.threadIdentifier
        content.categoryIdentifier = blueprint.categoryIdentifier

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif
