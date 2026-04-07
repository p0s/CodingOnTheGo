import Foundation
import SharedModels

public enum TailnetAuthState: String, Codable, Sendable {
    case signedOut
    case authenticating
    case authenticated
    case blocked
}

public enum EmbeddedTailnetAuthenticationPhase: String, Codable, Sendable {
    case pendingUserAction
    case authenticated
    case failed
}

public enum EmbeddedTailnetRuntimeHealthState: String, Codable, Sendable {
    case idle
    case pendingAuth
    case ready
    case degraded
    case needsRuntimeIntegration
}

public struct TailnetControlPlaneConfiguration: Hashable, Codable, Sendable {
    public var activeProfileID: TailnetProfile.ID?
    public var controlURL: URL
    public var supportsCustomControlServer: Bool

    public init(
        activeProfileID: TailnetProfile.ID? = nil,
        controlURL: URL,
        supportsCustomControlServer: Bool = true
    ) {
        self.activeProfileID = activeProfileID
        self.controlURL = controlURL
        self.supportsCustomControlServer = supportsCustomControlServer
    }
}

public struct EmbeddedTailnetAuthSession: Hashable, Codable, Sendable {
    public var profileID: TailnetProfile.ID
    public var phase: EmbeddedTailnetAuthenticationPhase
    public var ticket: EmbeddedTailnetAuthTicket?
    public var lastUpdatedAt: Date
    public var lastErrorSummary: String?

    public init(
        profileID: TailnetProfile.ID,
        phase: EmbeddedTailnetAuthenticationPhase,
        ticket: EmbeddedTailnetAuthTicket? = nil,
        lastUpdatedAt: Date = .now,
        lastErrorSummary: String? = nil
    ) {
        self.profileID = profileID
        self.phase = phase
        self.ticket = ticket
        self.lastUpdatedAt = lastUpdatedAt
        self.lastErrorSummary = lastErrorSummary
    }
}

public struct EmbeddedTailnetRuntimeHealth: Hashable, Codable, Sendable {
    public var state: EmbeddedTailnetRuntimeHealthState
    public var latencyMs: Int?
    public var lastCheckedAt: Date?
    public var failureReasonCode: String?
    public var lastErrorSummary: String?

    public init(
        state: EmbeddedTailnetRuntimeHealthState,
        latencyMs: Int? = nil,
        lastCheckedAt: Date? = nil,
        failureReasonCode: String? = nil,
        lastErrorSummary: String? = nil
    ) {
        self.state = state
        self.latencyMs = latencyMs
        self.lastCheckedAt = lastCheckedAt
        self.failureReasonCode = failureReasonCode
        self.lastErrorSummary = lastErrorSummary
    }

    public var isReachable: Bool {
        state == .ready
    }
}

public struct EmbeddedTailnetDialPlan: Hashable, Codable, Sendable {
    public var profileID: TailnetProfile.ID
    public var routeKind: MachineRouteKind
    public var preferredHost: String?
    public var magicDNSName: String?
    public var requiresExternalApp: Bool
    public var socksProxyHost: String?
    public var socksProxyPort: UInt16?
    public var socksProxyUsername: String?
    public var socksProxyPassword: String?
    public var supportsNativeSSHTransport: Bool

    public init(
        profileID: TailnetProfile.ID,
        routeKind: MachineRouteKind,
        preferredHost: String? = nil,
        magicDNSName: String? = nil,
        requiresExternalApp: Bool,
        socksProxyHost: String? = nil,
        socksProxyPort: UInt16? = nil,
        socksProxyUsername: String? = nil,
        socksProxyPassword: String? = nil,
        supportsNativeSSHTransport: Bool = false
    ) {
        self.profileID = profileID
        self.routeKind = routeKind
        self.preferredHost = preferredHost
        self.magicDNSName = magicDNSName
        self.requiresExternalApp = requiresExternalApp
        self.socksProxyHost = socksProxyHost
        self.socksProxyPort = socksProxyPort
        self.socksProxyUsername = socksProxyUsername
        self.socksProxyPassword = socksProxyPassword
        self.supportsNativeSSHTransport = supportsNativeSSHTransport
    }
}

public struct EmbeddedTailnetStatus: Hashable, Sendable {
    public var isInstalled: Bool
    public var authState: TailnetAuthState
    public var isReachable: Bool
    public var controlURL: URL?
    public var lastErrorSummary: String?

    public init(
        isInstalled: Bool,
        authState: TailnetAuthState,
        isReachable: Bool,
        controlURL: URL? = nil,
        lastErrorSummary: String? = nil
    ) {
        self.isInstalled = isInstalled
        self.authState = authState
        self.isReachable = isReachable
        self.controlURL = controlURL
        self.lastErrorSummary = lastErrorSummary
    }

    public var readyForConnection: Bool {
        isInstalled && authState == .authenticated && isReachable
    }
}

public struct EmbeddedTailnetRuntimeSnapshot: Hashable, Sendable {
    public var profiles: [TailnetProfile]
    public var activeProfileID: TailnetProfile.ID?
    public var authSession: EmbeddedTailnetAuthSession?
    public var health: EmbeddedTailnetRuntimeHealth
    public var status: EmbeddedTailnetStatus
    public var dialPlan: EmbeddedTailnetDialPlan?

    public init(
        profiles: [TailnetProfile],
        activeProfileID: TailnetProfile.ID?,
        authSession: EmbeddedTailnetAuthSession?,
        health: EmbeddedTailnetRuntimeHealth,
        status: EmbeddedTailnetStatus,
        dialPlan: EmbeddedTailnetDialPlan?
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.authSession = authSession
        self.health = health
        self.status = status
        self.dialPlan = dialPlan
    }

    public var activeProfile: TailnetProfile? {
        profiles.first(where: { $0.id == activeProfileID })
            ?? profiles.first(where: \.isActive)
    }
}

public enum TailnetControlURLValidator {
    public static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            return false
        }

        return scheme == "https"
    }
}
