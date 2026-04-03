import Foundation
import SharedModels
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum NotificationBridgeMode: String, Codable, Sendable {
    case inactive
    case broker
    case fileRelay
}

public enum NotificationOutboxState: String, Codable, Sendable {
    case pending
    case delivered
    case failed
}

public struct NotificationBridgeSnapshot: Hashable, Codable, Sendable {
    public var mode: NotificationBridgeMode
    public var relayDescription: String?
    public var pendingCount: Int
    public var deliveredCount: Int
    public var failedCount: Int
    public var lastSubmissionAt: Date?
    public var lastErrorSummary: String?

    public init(
        mode: NotificationBridgeMode,
        relayDescription: String? = nil,
        pendingCount: Int = 0,
        deliveredCount: Int = 0,
        failedCount: Int = 0,
        lastSubmissionAt: Date? = nil,
        lastErrorSummary: String? = nil
    ) {
        self.mode = mode
        self.relayDescription = relayDescription
        self.pendingCount = pendingCount
        self.deliveredCount = deliveredCount
        self.failedCount = failedCount
        self.lastSubmissionAt = lastSubmissionAt
        self.lastErrorSummary = lastErrorSummary
    }

    public static let inactive = NotificationBridgeSnapshot(mode: .inactive)
}

public struct NotificationOutboxEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var blueprint: NotificationBlueprint
    public var state: NotificationOutboxState
    public var createdAt: Date
    public var attemptCount: Int
    public var lastAttemptAt: Date?
    public var submittedAt: Date?
    public var lastErrorSummary: String?

    public init(
        id: UUID = UUID(),
        blueprint: NotificationBlueprint,
        state: NotificationOutboxState = .pending,
        createdAt: Date = .now,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        submittedAt: Date? = nil,
        lastErrorSummary: String? = nil
    ) {
        self.id = id
        self.blueprint = blueprint
        self.state = state
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.submittedAt = submittedAt
        self.lastErrorSummary = lastErrorSummary
    }
}

public protocol NotificationBridgeSubmitting: Sendable {
    var mode: NotificationBridgeMode { get }
    var relayDescription: String { get }
    func submit(_ blueprint: NotificationBlueprint) async throws
}

public actor JSONNotificationOutboxStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = AppRuntimePaths.applicationSupport().notificationOutboxURL
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func enqueue(_ blueprint: NotificationBlueprint) async throws -> NotificationOutboxEntry {
        var entries = try loadEntries()
        let entry = NotificationOutboxEntry(blueprint: blueprint)
        entries.append(entry)
        try save(entries)
        return entry
    }

    public func pendingEntries() async throws -> [NotificationOutboxEntry] {
        try loadEntries().filter { $0.state == .pending || $0.state == .failed }
    }

    public func markDelivered(entryID: UUID) async throws {
        try update(entryID: entryID, state: .delivered, error: nil)
    }

    public func markFailed(entryID: UUID, error: String) async throws {
        try update(entryID: entryID, state: .failed, error: error)
    }

    public func snapshot(
        mode: NotificationBridgeMode,
        relayDescription: String?
    ) async -> NotificationBridgeSnapshot {
        guard let entries = try? loadEntries() else {
            return NotificationBridgeSnapshot(
                mode: mode,
                relayDescription: relayDescription,
                lastErrorSummary: "Notification outbox is unreadable."
            )
        }

        let delivered = entries.filter { $0.state == .delivered }
        let failed = entries.filter { $0.state == .failed }
        let pending = entries.filter { $0.state == .pending }

        return NotificationBridgeSnapshot(
            mode: mode,
            relayDescription: relayDescription,
            pendingCount: pending.count,
            deliveredCount: delivered.count,
            failedCount: failed.count,
            lastSubmissionAt: delivered.compactMap(\.submittedAt).max(),
            lastErrorSummary: failed.sorted(by: {
                ($0.lastAttemptAt ?? .distantPast) > ($1.lastAttemptAt ?? .distantPast)
            }).first?.lastErrorSummary
        )
    }

    private func update(entryID: UUID, state: NotificationOutboxState, error: String?) throws {
        var entries = try loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }

        entries[index].state = state
        entries[index].attemptCount += 1
        entries[index].lastAttemptAt = .now
        entries[index].lastErrorSummary = error
        if state == .delivered {
            entries[index].submittedAt = .now
        }
        try save(entries)
    }

    private func loadEntries() throws -> [NotificationOutboxEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode([NotificationOutboxEntry].self, from: data)
    }

    private func save(_ entries: [NotificationOutboxEntry]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
    }
}

public struct HTTPNotificationBridgeSubmitter: NotificationBridgeSubmitting {
    public let url: URL
    private let session: URLSession

    public var mode: NotificationBridgeMode { .broker }
    public var relayDescription: String { url.absoluteString }

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func submit(_ blueprint: NotificationBlueprint) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(blueprint)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NotificationBridgeError.submissionFailed("Notification broker rejected the request.")
        }
    }
}

public struct FileRelayNotificationSubmitter: NotificationBridgeSubmitting {
    public let directoryURL: URL
    private let encoder: JSONEncoder

    public var mode: NotificationBridgeMode { .fileRelay }
    public var relayDescription: String { directoryURL.path }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func submit(_ blueprint: NotificationBlueprint) async throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let fileURL = directoryURL.appending(path: "\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
        let data = try encoder.encode(blueprint)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum NotificationBridgeFactory {
    public static func makeDefaultSubmitter(
        configuration: NotificationBridgeSubmissionConfiguration = .fileRelay(
            AppRuntimePaths.applicationSupport().companionNotificationRelayDirectoryURL
        )
    ) -> (any NotificationBridgeSubmitting)? {
        switch configuration {
        case let .broker(brokerURL):
            return HTTPNotificationBridgeSubmitter(url: brokerURL)
        case let .fileRelay(directoryURL):
            return FileRelayNotificationSubmitter(directoryURL: directoryURL)
        }
    }
}

public actor BridgedNotificationCoordinator: NotificationCoordinator {
    private var currentSnapshot: NotificationSnapshot
    private let planner: SessionNotificationPlanner
    private let outbox: JSONNotificationOutboxStore
    private let bridgeSubmitter: (any NotificationBridgeSubmitting)?
    private let localDeliverer: (any NotificationDelivering)?

    public init(
        outbox: JSONNotificationOutboxStore = JSONNotificationOutboxStore(),
        bridgeSubmitter: (any NotificationBridgeSubmitting)? = NotificationBridgeFactory.makeDefaultSubmitter(),
        localDeliverer: (any NotificationDelivering)? = nil
    ) {
        self.currentSnapshot = NotificationSnapshot(authorization: .unknown)
        self.planner = SessionNotificationPlanner()
        self.outbox = outbox
        self.bridgeSubmitter = bridgeSubmitter
        self.localDeliverer = localDeliverer
    }

    public func snapshot() async -> NotificationSnapshot {
        var snapshot = currentSnapshot
        snapshot.bridge = await outbox.snapshot(
            mode: bridgeSubmitter?.mode ?? .inactive,
            relayDescription: bridgeSubmitter?.relayDescription
        )
        currentSnapshot = snapshot
        return snapshot
    }

    public func requestAuthorization() async -> NotificationAuthorizationState {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        currentSnapshot.authorization = granted == true ? .authorized : .denied
        #else
        currentSnapshot.authorization = .denied
        #endif
        return currentSnapshot.authorization
    }

    public func schedule(_ event: NotificationEvent) async throws {
        try await deliver(planner.blueprint(for: event))
    }

    public func scheduleCompletion(_ completion: CompletionNotification) async throws {
        let blueprint = NotificationBlueprint(
            title: "Coding On The Go",
            body: NotificationMessageBuilder.body(for: completion),
            threadIdentifier: completion.threadID ?? UUID().uuidString,
            categoryIdentifier: "session-completed",
            deliveryTier: .companionReliable
        )
        try await deliver(blueprint)
    }

    public func flushPending() async throws {
        guard let bridgeSubmitter else { return }
        let entries = try await outbox.pendingEntries()
        for entry in entries {
            do {
                try await bridgeSubmitter.submit(entry.blueprint)
                try await outbox.markDelivered(entryID: entry.id)
            } catch {
                try await outbox.markFailed(entryID: entry.id, error: error.localizedDescription)
            }
        }
        currentSnapshot.bridge = await outbox.snapshot(
            mode: bridgeSubmitter.mode,
            relayDescription: bridgeSubmitter.relayDescription
        )
    }

    private func deliver(_ blueprint: NotificationBlueprint) async throws {
        currentSnapshot.lastScheduledMessage = blueprint.body
        let entry = try await outbox.enqueue(blueprint)

        if let localDeliverer {
            try? await localDeliverer.deliver(blueprint)
        }

        guard let bridgeSubmitter else {
            currentSnapshot.bridge = await outbox.snapshot(mode: .inactive, relayDescription: nil)
            return
        }

        do {
            try await bridgeSubmitter.submit(blueprint)
            try await outbox.markDelivered(entryID: entry.id)
        } catch {
            try await outbox.markFailed(entryID: entry.id, error: error.localizedDescription)
            currentSnapshot.bridge = await outbox.snapshot(
                mode: bridgeSubmitter.mode,
                relayDescription: bridgeSubmitter.relayDescription
            )
            throw error
        }

        currentSnapshot.bridge = await outbox.snapshot(
            mode: bridgeSubmitter.mode,
            relayDescription: bridgeSubmitter.relayDescription
        )
    }
}

public enum NotificationBridgeError: LocalizedError {
    case submissionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .submissionFailed(message):
            message
        }
    }
}
