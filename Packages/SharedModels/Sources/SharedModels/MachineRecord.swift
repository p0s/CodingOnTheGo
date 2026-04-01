import Foundation

public struct MachineRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var platform: MachinePlatform
    public var stableHostFingerprint: String?
    public var lastKnownUser: String?
    public var lastConnectedAt: Date?
    public var preferredRouteID: RouteRecord.ID?
    public var lastSuccessfulRouteID: RouteRecord.ID?
    public var capabilitySnapshotID: UUID?
    public var credentialRef: CredentialRef?
    public var notes: String?
    public var isPinned: Bool
    public var sortRank: Int
    public var routes: [RouteRecord]
    public var capabilities: HostCapabilitySnapshot

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        platform: MachinePlatform = .macOS,
        stableHostFingerprint: String? = nil,
        lastKnownUser: String? = nil,
        lastConnectedAt: Date? = nil,
        preferredRouteID: RouteRecord.ID? = nil,
        lastSuccessfulRouteID: RouteRecord.ID? = nil,
        capabilitySnapshotID: UUID? = nil,
        credentialRef: CredentialRef? = nil,
        notes: String? = nil,
        isPinned: Bool = false,
        sortRank: Int = 0,
        routes: [RouteRecord],
        capabilities: HostCapabilitySnapshot
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.platform = platform
        self.stableHostFingerprint = stableHostFingerprint
        self.lastKnownUser = lastKnownUser
        self.lastConnectedAt = lastConnectedAt
        self.preferredRouteID = preferredRouteID
        self.lastSuccessfulRouteID = lastSuccessfulRouteID
        self.capabilitySnapshotID = capabilitySnapshotID
        self.credentialRef = credentialRef
        self.notes = notes
        self.isPinned = isPinned
        self.sortRank = sortRank
        self.routes = routes
        self.capabilities = capabilities
    }
}

public enum MachinePlatform: String, Codable, CaseIterable, Sendable {
    case macOS
}

public extension MachineRecord {
    var alias: String {
        displayName
    }

    var preferredRoute: RouteRecord? {
        if let preferredRouteID,
           let route = routes.first(where: { $0.id == preferredRouteID }),
           route.isEligibleForTraffic {
            return route
        }

        if let userPinned = routes.first(where: { $0.isUserPinned && $0.isEligibleForTraffic }) {
            return userPinned
        }

        if let lastGood = lastSuccessfulRoute, lastGood.isEligibleForTraffic {
            return lastGood
        }

        if let recommended = routes.first(where: { $0.isRecommended && $0.isEligibleForTraffic }) {
            return recommended
        }

        return routes.first(where: \.isEligibleForTraffic)
            ?? routes.first(where: { $0.health.isReachable })
            ?? routes.first
    }

    var lastSuccessfulRoute: RouteRecord? {
        guard let lastSuccessfulRouteID else {
            return nil
        }

        return routes.first { $0.id == lastSuccessfulRouteID }
    }

    func route(id: RouteRecord.ID?) -> RouteRecord? {
        guard let id else {
            return nil
        }

        return routes.first { $0.id == id }
    }

    func route(for kind: MachineRouteKind) -> RouteRecord? {
        routes.first { $0.kind == kind }
    }
}

public struct RouteRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var machineID: MachineRecord.ID?
    public var kind: MachineRouteKind
    public var label: String
    public var hostname: String?
    public var ipAddress: String?
    public var magicDNSName: String?
    public var sshPort: UInt16
    public var usernameHint: String?
    public var companionEndpoint: URL?
    public var tailnetProfileID: UUID?
    public var requiresExternalApp: Bool
    public var health: RouteHealthStatus
    public var lastLatencyMs: Int?
    public var lastCheckedAt: Date?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var failureReasonCode: String?
    public var isRecommended: Bool
    public var isUserPinned: Bool
    public var publishedByCompanion: Bool
    public var discoverySource: RouteDiscoverySource
    public var trustState: RouteTrustState
    public var trustedOpenSSHPublicKey: String?

    public init(
        id: UUID = UUID(),
        machineID: MachineRecord.ID? = nil,
        kind: MachineRouteKind,
        label: String,
        hostname: String? = nil,
        ipAddress: String? = nil,
        magicDNSName: String? = nil,
        sshPort: UInt16 = 22,
        usernameHint: String? = nil,
        companionEndpoint: URL? = nil,
        tailnetProfileID: UUID? = nil,
        requiresExternalApp: Bool = false,
        health: RouteHealthStatus,
        lastLatencyMs: Int? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        failureReasonCode: String? = nil,
        isRecommended: Bool = false,
        isUserPinned: Bool = false,
        publishedByCompanion: Bool = false,
        discoverySource: RouteDiscoverySource = .manual,
        trustState: RouteTrustState = .unknown,
        trustedOpenSSHPublicKey: String? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.kind = kind
        self.label = label
        self.hostname = hostname
        self.ipAddress = ipAddress
        self.magicDNSName = magicDNSName
        self.sshPort = sshPort
        self.usernameHint = usernameHint
        self.companionEndpoint = companionEndpoint
        self.tailnetProfileID = tailnetProfileID
        self.requiresExternalApp = requiresExternalApp
        self.health = health
        self.lastLatencyMs = lastLatencyMs
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.failureReasonCode = failureReasonCode
        self.isRecommended = isRecommended
        self.isUserPinned = isUserPinned
        self.publishedByCompanion = publishedByCompanion
        self.discoverySource = discoverySource
        self.trustState = trustState
        self.trustedOpenSSHPublicKey = trustedOpenSSHPublicKey
    }

}

public extension RouteRecord {
    var address: String {
        if let companionEndpoint {
            return companionEndpoint.absoluteString
        }

        if let magicDNSName {
            return magicDNSName
        }

        if let ipAddress {
            return ipAddress
        }

        return hostname ?? label
    }

    var isReachable: Bool {
        health.isReachable
    }

    var isEligibleForTraffic: Bool {
        health.isEligibleForTraffic
    }

    var requiresNearbyNetworkTransport: Bool {
        switch kind {
        case .localLAN:
            return true
        case .manualSSH:
            if let hostname, hostname.lowercased().hasSuffix(".local") {
                return true
            }
            if let ipAddress, isNearbyOnlyHostAddress(ipAddress) {
                return true
            }
            return false
        case .companionDirect:
            guard let host = companionEndpoint?.host?.lowercased() else {
                return false
            }
            return host == "localhost"
                || host.hasSuffix(".local")
                || isNearbyOnlyHostAddress(host)
        case .embeddedTailnet, .externalTailnet:
            return false
        }
    }
}

public enum MachineRouteKind: String, Codable, CaseIterable, Sendable {
    case embeddedTailnet
    case externalTailnet
    case localLAN
    case manualSSH
    case companionDirect
}

public extension MachineRouteKind {
    static var sameLAN: Self { .localLAN }

    static var manual: Self { .manualSSH }

    var title: String {
        switch self {
        case .embeddedTailnet:
            "Embedded Tailscale"
        case .externalTailnet:
            "External Tailscale"
        case .localLAN:
            "Local"
        case .manualSSH:
            "Manual SSH"
        case .companionDirect:
            "Codex WebSocket"
        }
    }

    var shortTitle: String {
        switch self {
        case .embeddedTailnet, .externalTailnet:
            "Tailscale"
        case .localLAN:
            "Same Wi-Fi"
        case .manualSSH:
            "Manual SSH"
        case .companionDirect:
            "WebSocket"
        }
    }
}

public enum RouteDiscoverySource: String, Codable, CaseIterable, Sendable {
    case manual
    case bonjour
    case cachedProbe
    case companionAdvertisement
    case tailnetProfile
    case imported
}

public enum RouteTrustState: String, Codable, CaseIterable, Sendable {
    case unknown
    case trusted
    case mismatch
}

public enum RouteHealthStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case degraded
    case unavailable
}

public extension RouteHealthStatus {
    var isReachable: Bool {
        self != .unavailable
    }

    var isEligibleForTraffic: Bool {
        self == .healthy
    }
}

private func isNearbyOnlyHostAddress(_ rawValue: String) -> Bool {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else {
        return false
    }

    if value == "localhost" || value == "::1" || value.hasPrefix("fe80:") {
        return true
    }

    if value.hasPrefix("10.")
        || value.hasPrefix("127.")
        || value.hasPrefix("169.254.")
        || value.hasPrefix("192.168.") {
        return true
    }

    let octets = value.split(separator: ".")
    if octets.count == 4,
       octets[0] == "172",
       let secondOctet = Int(octets[1]),
       (16...31).contains(secondOctet) {
        return true
    }

    return false
}

public enum BootstrapStrategy: String, Codable, CaseIterable, Sendable {
    case standardSSH
    case companionManaged
    case codexAppServerWebSocket
    case manual
}

public enum CodexProtocolKind: String, Codable, CaseIterable, Sendable {
    case stdio
    case websocket
    case directEndpoint
}

public struct HostCapabilitySnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var machineID: MachineRecord.ID?
    public var capturedAt: Date
    public var remoteLoginEnabled: Bool
    public var codexInstalled: Bool
    public var supportsAppServer: Bool
    public var supportsWebsocketListen: Bool
    public var supportsReview: Bool
    public var supportsThreadFork: Bool
    public var supportsApprovals: Bool
    public var supportsCommandExec: Bool
    public var supportsFSAPI: Bool
    public var supportsImageInputs: Bool
    public var supportsVoiceInput: Bool
    public var supportsAttachments: Bool
    public var gitVersion: String?
    public var codexVersion: String?
    public var companionVersion: String?
    public var companionState: String?
    public var codexAppInstalled: Bool
    public var hostOSVersion: String?
    public var resolvedRuntime: CodexResolvedRuntime?

    public init(
        id: UUID = UUID(),
        machineID: MachineRecord.ID? = nil,
        capturedAt: Date = .now,
        remoteLoginEnabled: Bool,
        codexInstalled: Bool,
        supportsAppServer: Bool = true,
        supportsWebsocketListen: Bool,
        supportsReview: Bool = true,
        supportsThreadFork: Bool = true,
        supportsApprovals: Bool = true,
        supportsCommandExec: Bool = true,
        supportsFSAPI: Bool = true,
        supportsImageInputs: Bool = true,
        supportsVoiceInput: Bool = true,
        supportsAttachments: Bool = true,
        gitVersion: String? = nil,
        codexVersion: String? = nil,
        companionVersion: String? = nil,
        companionState: String? = nil,
        codexAppInstalled: Bool = false,
        hostOSVersion: String? = nil,
        resolvedRuntime: CodexResolvedRuntime? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.capturedAt = capturedAt
        self.remoteLoginEnabled = remoteLoginEnabled
        self.codexInstalled = codexInstalled
        self.supportsAppServer = supportsAppServer
        self.supportsWebsocketListen = supportsWebsocketListen
        self.supportsReview = supportsReview
        self.supportsThreadFork = supportsThreadFork
        self.supportsApprovals = supportsApprovals
        self.supportsCommandExec = supportsCommandExec
        self.supportsFSAPI = supportsFSAPI
        self.supportsImageInputs = supportsImageInputs
        self.supportsVoiceInput = supportsVoiceInput
        self.supportsAttachments = supportsAttachments
        self.gitVersion = gitVersion
        self.codexVersion = codexVersion
        self.companionVersion = companionVersion
        self.companionState = companionState
        self.codexAppInstalled = codexAppInstalled
        self.hostOSVersion = hostOSVersion
        self.resolvedRuntime = resolvedRuntime
    }
}

public extension HostCapabilitySnapshot {
    var websocketAppServerSupported: Bool {
        supportsWebsocketListen
    }

    var companionInstalled: Bool {
        companionVersion != nil || companionState != nil
    }
}

public extension MachineRecord {
    #if DEBUG
    static let preview = {
        let machineID = UUID()
        let embeddedRouteID = UUID()
        let lanRouteID = UUID()
        let manualRouteID = UUID()

        return MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            stableHostFingerprint: "SHA256:p-preview-fingerprint",
            lastKnownUser: "developer",
            lastConnectedAt: .now,
            preferredRouteID: embeddedRouteID,
            lastSuccessfulRouteID: lanRouteID,
            capabilitySnapshotID: UUID(),
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "cotg.preview.p",
                label: "Primary SSH key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain,
                lastValidatedAt: .now
            ),
            notes: "Primary development Mac.",
            isPinned: true,
            sortRank: 0,
            routes: [
                RouteRecord(
                    id: embeddedRouteID,
                    machineID: machineID,
                    kind: .embeddedTailnet,
                    label: "Embedded tailnet",
                    ipAddress: "100.94.10.8",
                    usernameHint: "developer",
                    tailnetProfileID: MachineDirectorySeed.primaryTailnetID,
                    health: .healthy,
                    lastLatencyMs: 42,
                    lastCheckedAt: .now,
                    lastSuccessAt: .now,
                    isRecommended: true,
                    publishedByCompanion: false,
                    discoverySource: .tailnetProfile,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: lanRouteID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Desk LAN",
                    hostname: "example-mac.local",
                    ipAddress: "192.168.1.24",
                    usernameHint: "developer",
                    health: .healthy,
                    lastLatencyMs: 4,
                    lastCheckedAt: .now,
                    lastSuccessAt: .now.addingTimeInterval(-7200),
                    publishedByCompanion: true,
                    discoverySource: .bonjour,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: manualRouteID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Manual SSH",
                    hostname: "localhost",
                    ipAddress: "127.0.0.1",
                    usernameHint: "developer",
                    health: .healthy,
                    lastLatencyMs: 2,
                    lastCheckedAt: .now,
                    lastSuccessAt: .now,
                    isUserPinned: true,
                    publishedByCompanion: false,
                    discoverySource: .manual,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                gitVersion: "2.47.0",
                codexVersion: "1.2.0",
                codexAppInstalled: true,
                hostOSVersion: "macOS 15.4"
            )
        )
    }()

    static let secondaryPreview = {
        let machineID = UUID()
        let externalRouteID = UUID()
        let companionRouteID = UUID()

        return MachineRecord(
            id: machineID,
            displayName: "c",
            hostname: "c.local",
            stableHostFingerprint: "SHA256:c-preview-fingerprint",
            lastKnownUser: "developer",
            lastConnectedAt: .now.addingTimeInterval(-86_400),
            preferredRouteID: externalRouteID,
            lastSuccessfulRouteID: companionRouteID,
            capabilitySnapshotID: UUID(),
            credentialRef: CredentialRef(
                kind: .companionMutualAuth,
                keychainAccount: "cotg.preview.c",
                label: "Companion trust",
                username: "developer",
                storageScope: .synchronizableKeychain,
                lastValidatedAt: .now
            ),
            notes: "Secondary development Mac.",
            isPinned: false,
            sortRank: 1,
            routes: [
                RouteRecord(
                    id: externalRouteID,
                    machineID: machineID,
                    kind: .externalTailnet,
                    label: "External Tailscale",
                    magicDNSName: "c.tail123.ts.net",
                    usernameHint: "developer",
                    requiresExternalApp: true,
                    health: .degraded,
                    lastLatencyMs: 67,
                    lastCheckedAt: .now,
                    lastFailureAt: .now.addingTimeInterval(-1800),
                    failureReasonCode: "external-tailnet-not-reachable",
                    isRecommended: true,
                    publishedByCompanion: false,
                    discoverySource: .imported,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: companionRouteID,
                    machineID: machineID,
                    kind: .companionDirect,
                    label: "Codex websocket",
                    companionEndpoint: URL(string: "ws://127.0.0.1:9494"),
                    health: .healthy,
                    lastLatencyMs: 18,
                    lastCheckedAt: .now,
                    lastSuccessAt: .now.addingTimeInterval(-180),
                    publishedByCompanion: true,
                    discoverySource: .companionAdvertisement,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                supportsVoiceInput: true,
                supportsAttachments: true,
                companionVersion: "0.1",
                companionState: "passive-enhanced",
                codexAppInstalled: true,
                hostOSVersion: "macOS 15.4"
            )
        )
    }()

    static let previewMachines = [preview, secondaryPreview]
    #endif
}

#if DEBUG
public enum MachineDirectorySeed {
    public static let primaryTailnetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    public static let externalTailnetID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
}
#endif
