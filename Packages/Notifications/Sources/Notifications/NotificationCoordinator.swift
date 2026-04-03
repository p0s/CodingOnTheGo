import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum NotificationAuthorizationState: String, Sendable {
    case unknown
    case denied
    case authorized
}

public struct CompletionNotification: Hashable, Sendable {
    public var machineAlias: String
    public var threadID: String?
    public var summary: String

    public init(machineAlias: String, threadID: String? = nil, summary: String) {
        self.machineAlias = machineAlias
        self.threadID = threadID
        self.summary = summary
    }
}

public struct NotificationSnapshot: Hashable, Sendable {
    public var authorization: NotificationAuthorizationState
    public var lastScheduledMessage: String?
    public var bridge: NotificationBridgeSnapshot

    public init(
        authorization: NotificationAuthorizationState,
        lastScheduledMessage: String? = nil,
        bridge: NotificationBridgeSnapshot = .inactive
    ) {
        self.authorization = authorization
        self.lastScheduledMessage = lastScheduledMessage
        self.bridge = bridge
    }
}

public protocol NotificationCoordinator: Sendable {
    func snapshot() async -> NotificationSnapshot
    func requestAuthorization() async -> NotificationAuthorizationState
    func schedule(_ event: NotificationEvent) async throws
    func scheduleCompletion(_ completion: CompletionNotification) async throws
}

public actor InMemoryNotificationCoordinator: NotificationCoordinator {
    private var currentSnapshot = NotificationSnapshot(authorization: .authorized)
    private let planner = SessionNotificationPlanner()

    public init() {}

    public func snapshot() async -> NotificationSnapshot {
        currentSnapshot
    }

    public func requestAuthorization() async -> NotificationAuthorizationState {
        currentSnapshot.authorization
    }

    public func schedule(_ event: NotificationEvent) async throws {
        currentSnapshot.lastScheduledMessage = planner.blueprint(for: event).body
    }

    public func scheduleCompletion(_ completion: CompletionNotification) async throws {
        currentSnapshot.lastScheduledMessage = NotificationMessageBuilder.body(for: completion)
    }
}

public actor LocalNotificationCoordinator: NotificationCoordinator {
    private var currentSnapshot = NotificationSnapshot(authorization: .unknown)
    private let planner = SessionNotificationPlanner()

    public init() {}

    public func snapshot() async -> NotificationSnapshot {
        currentSnapshot
    }

    public func requestAuthorization() async -> NotificationAuthorizationState {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        currentSnapshot.authorization = granted == true ? .authorized : .denied
        return currentSnapshot.authorization
        #else
        currentSnapshot.authorization = .denied
        return currentSnapshot.authorization
        #endif
    }

    public func schedule(_ event: NotificationEvent) async throws {
        let blueprint = planner.blueprint(for: event)
        currentSnapshot.lastScheduledMessage = blueprint.body
        #if canImport(UserNotifications)
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
        try await UNUserNotificationCenter.current().add(request)
        #endif
    }

    public func scheduleCompletion(_ completion: CompletionNotification) async throws {
        let message = NotificationMessageBuilder.body(for: completion)
        currentSnapshot.lastScheduledMessage = message
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = "Coding On The Go"
        content.body = message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
        #endif
    }
}

public enum NotificationMessageBuilder {
    public static func body(for completion: CompletionNotification) -> String {
        if let threadID = completion.threadID {
            return "\(completion.machineAlias) finished thread \(threadID): \(completion.summary)"
        }

        return "\(completion.machineAlias) completed a session: \(completion.summary)"
    }
}
