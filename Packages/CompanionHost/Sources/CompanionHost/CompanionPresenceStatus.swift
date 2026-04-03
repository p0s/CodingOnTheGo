import Foundation
import Notifications
import SharedModels

public struct CompanionPresenceStatus: Hashable, Codable, Sendable {
    public var isInstalled: Bool
    public var isReachable: Bool
    public var supportsEnhancedHostMode: Bool

    public init(
        isInstalled: Bool,
        isReachable: Bool,
        supportsEnhancedHostMode: Bool
    ) {
        self.isInstalled = isInstalled
        self.isReachable = isReachable
        self.supportsEnhancedHostMode = supportsEnhancedHostMode
    }

    public var readyForEnhancedMode: Bool {
        isInstalled && isReachable && supportsEnhancedHostMode
    }
}

public enum SharedListenerState: String, Codable, Sendable {
    case stopped
    case warming
    case ready
    case degraded
}

public struct PublishedRoute: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: MachineRouteKind
    public var address: String
    public var health: RouteHealthStatus

    public init(
        id: UUID = UUID(),
        kind: MachineRouteKind,
        address: String,
        health: RouteHealthStatus
    ) {
        self.id = id
        self.kind = kind
        self.address = address
        self.health = health
    }
}

public struct CompanionCapabilitySummary: Hashable, Codable, Sendable {
    public var canPublishRoutes: Bool
    public var canWarmSharedListener: Bool
    public var canExposeDirectEndpoint: Bool
    public var canBridgeNotifications: Bool

    public init(
        canPublishRoutes: Bool,
        canWarmSharedListener: Bool,
        canExposeDirectEndpoint: Bool,
        canBridgeNotifications: Bool
    ) {
        self.canPublishRoutes = canPublishRoutes
        self.canWarmSharedListener = canWarmSharedListener
        self.canExposeDirectEndpoint = canExposeDirectEndpoint
        self.canBridgeNotifications = canBridgeNotifications
    }
}

public struct CompanionHostSnapshot: Hashable, Codable, Sendable {
    public var hostDisplayName: String
    public var presence: CompanionPresenceStatus
    public var publishedRoutes: [PublishedRoute]
    public var sharedListenerState: SharedListenerState
    public var capabilities: CompanionCapabilitySummary
    public var directEndpoint: URL?
    public var publication: CompanionPublicationStatus
    public var notificationBridge: NotificationBridgeSnapshot
    public var listenerCheckedAt: Date
    public var listenerStatusNote: String?

    public init(
        hostDisplayName: String,
        presence: CompanionPresenceStatus,
        publishedRoutes: [PublishedRoute],
        sharedListenerState: SharedListenerState,
        capabilities: CompanionCapabilitySummary,
        directEndpoint: URL? = nil,
        publication: CompanionPublicationStatus = .idle,
        notificationBridge: NotificationBridgeSnapshot = .inactive,
        listenerCheckedAt: Date = .now,
        listenerStatusNote: String? = nil
    ) {
        self.hostDisplayName = hostDisplayName
        self.presence = presence
        self.publishedRoutes = publishedRoutes
        self.sharedListenerState = sharedListenerState
        self.capabilities = capabilities
        self.directEndpoint = directEndpoint
        self.publication = publication
        self.notificationBridge = notificationBridge
        self.listenerCheckedAt = listenerCheckedAt
        self.listenerStatusNote = listenerStatusNote
    }

    #if DEBUG
    public static let preview = CompanionHostSnapshot(
        hostDisplayName: "example-mac",
        presence: CompanionPresenceStatus(
            isInstalled: true,
            isReachable: true,
            supportsEnhancedHostMode: true
        ),
        publishedRoutes: [
            PublishedRoute(
                kind: .localLAN,
                address: "192.168.1.24",
                health: .healthy
            )
        ],
        sharedListenerState: .ready,
        capabilities: CompanionCapabilitySummary(
            canPublishRoutes: true,
            canWarmSharedListener: true,
            canExposeDirectEndpoint: false,
            canBridgeNotifications: true
        ),
        publication: CompanionPublicationStatus(
            metadataPath: AppRuntimePaths.applicationSupport().metadataStoreURL.path,
            syncMirrorPath: AppRuntimePaths.applicationSupport().syncMirrorURL.path,
            publishedRouteCount: 1,
            lastPublishedAt: .now,
            note: "Companion metadata is published into the shared machine directory."
        ),
        notificationBridge: NotificationBridgeSnapshot(
            mode: .fileRelay,
            relayDescription: AppRuntimePaths.applicationSupport().companionNotificationRelayDirectoryURL.path,
            pendingCount: 0,
            deliveredCount: 1,
            failedCount: 0,
            lastSubmissionAt: .now,
            lastErrorSummary: nil
        ),
        listenerStatusNote: "Managed loopback listener is healthy on the host."
    )
    #endif

    public static let empty = CompanionHostSnapshot(
        hostDisplayName: ProcessInfo.processInfo.hostName,
        presence: CompanionPresenceStatus(
            isInstalled: false,
            isReachable: false,
            supportsEnhancedHostMode: false
        ),
        publishedRoutes: [],
        sharedListenerState: .stopped,
        capabilities: CompanionCapabilitySummary(
            canPublishRoutes: false,
            canWarmSharedListener: false,
            canExposeDirectEndpoint: false,
            canBridgeNotifications: false
        ),
        publication: .idle,
        notificationBridge: .inactive,
        listenerStatusNote: "Companion state has not been refreshed yet."
    )
}

public struct CompanionPublicationStatus: Hashable, Codable, Sendable {
    public var metadataPath: String
    public var syncMirrorPath: String
    public var publishedMachineID: MachineRecord.ID?
    public var publishedRouteCount: Int
    public var lastPublishedAt: Date?
    public var note: String

    public init(
        metadataPath: String,
        syncMirrorPath: String,
        publishedMachineID: MachineRecord.ID? = nil,
        publishedRouteCount: Int = 0,
        lastPublishedAt: Date? = nil,
        note: String
    ) {
        self.metadataPath = metadataPath
        self.syncMirrorPath = syncMirrorPath
        self.publishedMachineID = publishedMachineID
        self.publishedRouteCount = publishedRouteCount
        self.lastPublishedAt = lastPublishedAt
        self.note = note
    }

    public static let idle = CompanionPublicationStatus(
        metadataPath: AppRuntimePaths.applicationSupport().metadataStoreURL.path,
        syncMirrorPath: AppRuntimePaths.applicationSupport().syncMirrorURL.path,
        note: "Companion publication has not run yet."
    )
}

public struct CompanionRouteHealthCounts: Hashable, Codable, Sendable {
    public var healthy: Int
    public var degraded: Int
    public var unavailable: Int

    public init(healthy: Int, degraded: Int, unavailable: Int) {
        self.healthy = healthy
        self.degraded = degraded
        self.unavailable = unavailable
    }
}

public enum CompanionReadinessState: String, Codable, Sendable {
    case ready
    case warmable
    case attentionNeeded
}

public struct CompanionHostRecommendation: Hashable, Codable, Sendable {
    public var state: CompanionReadinessState
    public var title: String
    public var detail: String
    public var routeKind: MachineRouteKind?

    public init(
        state: CompanionReadinessState,
        title: String,
        detail: String,
        routeKind: MachineRouteKind?
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.routeKind = routeKind
    }
}

public extension CompanionHostSnapshot {
    var routeHealthCounts: CompanionRouteHealthCounts {
        CompanionRouteHealthCounts(
            healthy: publishedRoutes.filter { $0.health == .healthy }.count,
            degraded: publishedRoutes.filter { $0.health == .degraded }.count,
            unavailable: publishedRoutes.filter { $0.health == .unavailable }.count
        )
    }

    var recommendedPublishedRoute: PublishedRoute? {
        publishedRoutes.sorted(by: { score(for: $0) > score(for: $1) }).first
    }

    var recommendation: CompanionHostRecommendation {
        guard presence.readyForEnhancedMode else {
            if capabilities.canWarmSharedListener {
                return CompanionHostRecommendation(
                    state: .warmable,
                    title: "Warm the shared listener",
                    detail: "Codex is installed, but the shared listener is not ready yet.",
                    routeKind: recommendedPublishedRoute?.kind
                )
            }

            return CompanionHostRecommendation(
                state: .attentionNeeded,
                title: "Companion needs attention",
                detail: "Install the companion and publish a healthy route before enhanced mode can take over.",
                routeKind: recommendedPublishedRoute?.kind
            )
        }

        switch sharedListenerState {
        case .warming:
            return CompanionHostRecommendation(
                state: .warmable,
                title: "Listener is warming",
                detail: "Presence and route publication are healthy. Keep using the SSH safe lane until the shared listener finishes starting.",
                routeKind: recommendedPublishedRoute?.kind
            )
        case .degraded:
            return CompanionHostRecommendation(
                state: .attentionNeeded,
                title: "Listener needs attention",
                detail: "Presence is available, but the managed shared listener is degraded. Stay on the SSH safe lane until the companion recovers.",
                routeKind: recommendedPublishedRoute?.kind
            )
        case .ready, .stopped:
            break
        }

        if let route = recommendedPublishedRoute {
            let directEndpointReady = capabilities.canExposeDirectEndpoint && directEndpoint != nil
            return CompanionHostRecommendation(
                state: .ready,
                title: directEndpointReady && sharedListenerState == .ready
                    ? "Enhanced mode is ready"
                    : "Presence and route publishing are ready",
                detail: directEndpointReady
                    ? "Use \(route.kind.title.lowercased()) via \(route.address). The companion can keep the shared listener warm for faster reconnect."
                    : "Use \(route.kind.title.lowercased()) via \(route.address). The companion can publish routes and warm the shared listener, but the SSH safe lane remains the active transport.",
                routeKind: route.kind
            )
        }

        return CompanionHostRecommendation(
            state: .attentionNeeded,
            title: "No published route",
            detail: "The companion is installed, but no healthy route is currently available.",
            routeKind: nil
        )
    }

    var routeSummary: String {
        let counts = routeHealthCounts
        return "\(counts.healthy) healthy, \(counts.degraded) degraded, \(counts.unavailable) unavailable"
    }

    var listenerSummary: String {
        if let listenerStatusNote,
           !listenerStatusNote.isEmpty {
            return listenerStatusNote
        }

        return switch sharedListenerState {
        case .ready:
            "Managed shared listener is ready."
        case .warming:
            "Managed shared listener is warming."
        case .degraded:
            "Managed shared listener is degraded."
        case .stopped:
            "Managed shared listener is stopped."
        }
    }

    private func score(for route: PublishedRoute) -> Int {
        let healthScore: Int
        switch route.health {
        case .healthy:
            healthScore = 3
        case .degraded:
            healthScore = 2
        case .unavailable:
            healthScore = 1
        }

        let kindScore: Int
        switch route.kind {
        case .embeddedTailnet:
            kindScore = 4
        case .localLAN:
            kindScore = 3
        case .manualSSH:
            kindScore = 2
        case .externalTailnet:
            kindScore = 1
        case .companionDirect:
            kindScore = 0
        }

        return healthScore * 10 + kindScore
    }
}
