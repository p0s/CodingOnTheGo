import Foundation
import SharedModels

public struct UserPreferencesSnapshot: Hashable, Codable, Sendable {
    public var preferredMachineID: MachineRecord.ID?
    public var preferredTailnetProfileID: TailnetProfile.ID?
    public var restoreLastSessionOnLaunch: Bool
    public var preferredBootstrap: BootstrapStrategy?
    public var preferredProtocol: CodexProtocolKind?
    public var preferredReasoningEffort: String?
    public var preferredApprovalPolicy: String?
    public var preferredSandboxMode: String?
    public var privacyMode: AppPrivacyMode

    public init(
        preferredMachineID: MachineRecord.ID? = nil,
        preferredTailnetProfileID: TailnetProfile.ID? = nil,
        restoreLastSessionOnLaunch: Bool = true,
        preferredBootstrap: BootstrapStrategy? = nil,
        preferredProtocol: CodexProtocolKind? = nil,
        preferredReasoningEffort: String? = nil,
        preferredApprovalPolicy: String? = nil,
        preferredSandboxMode: String? = nil,
        privacyMode: AppPrivacyMode = .standard
    ) {
        self.preferredMachineID = preferredMachineID
        self.preferredTailnetProfileID = preferredTailnetProfileID
        self.restoreLastSessionOnLaunch = restoreLastSessionOnLaunch
        self.preferredBootstrap = preferredBootstrap
        self.preferredProtocol = preferredProtocol
        self.preferredReasoningEffort = preferredReasoningEffort
        self.preferredApprovalPolicy = preferredApprovalPolicy
        self.preferredSandboxMode = preferredSandboxMode
        self.privacyMode = privacyMode
    }
}

public struct MachineDirectorySnapshot: Hashable, Codable, Sendable {
    public var machines: [MachineRecord]
    public var tailnetProfiles: [TailnetProfile]
    public var recentSessions: [SessionRecord]
    public var hostThreadCatalog: [HostThreadCatalogEntry]
    public var preferences: UserPreferencesSnapshot

    public init(
        machines: [MachineRecord],
        tailnetProfiles: [TailnetProfile],
        recentSessions: [SessionRecord],
        hostThreadCatalog: [HostThreadCatalogEntry] = [],
        preferences: UserPreferencesSnapshot
    ) {
        self.machines = machines
        self.tailnetProfiles = tailnetProfiles
        self.recentSessions = recentSessions
        self.hostThreadCatalog = hostThreadCatalog
        self.preferences = preferences
    }

    public static let empty = MachineDirectorySnapshot(
        machines: [],
        tailnetProfiles: [],
        recentSessions: [],
        hostThreadCatalog: [],
        preferences: UserPreferencesSnapshot(
            preferredMachineID: nil,
            preferredTailnetProfileID: nil,
            restoreLastSessionOnLaunch: true,
            preferredBootstrap: .standardSSH,
            preferredProtocol: .stdio
        )
    )

    #if DEBUG
    public static let preview = MachineDirectorySnapshot(
        machines: MachineRecord.previewMachines,
        tailnetProfiles: [
            TailnetProfile(
                kind: .embedded,
                displayName: "Primary Tailnet",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer",
                tailnetDNSName: "example.ts.net",
                lastAuthenticatedAt: .now
            ),
            TailnetProfile(
                kind: .external,
                displayName: "Studio Tailnet",
                controlURL: URL(string: "https://headscale.example.com")!,
                accountLabel: "developer",
                tailnetDNSName: "studio.ts.net",
                lastAuthenticatedAt: .now,
                requiresExternalApp: true
            )
        ],
        recentSessions: [
            SessionRecord(
                machineID: MachineRecord.preview.id,
                routeID: MachineRecord.preview.route(for: .localLAN)?.id,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: .localLAN,
                lastKnownBootstrap: .standardSSH,
                transportState: .connected,
                lastOpenedAt: .now
            )
        ],
        hostThreadCatalog: [
            HostThreadCatalogEntry(
                id: "thread-preview-1",
                machineID: MachineRecord.preview.id,
                workspaceRoot: "/workspace/coding-on-the-go",
                name: "Fix Codex client UX",
                preview: "Tighten the Project and Thread browser so it matches the Mac Codex mental model.",
                modelProvider: "openai",
                createdAt: .now,
                updatedAt: .now
            ),
            HostThreadCatalogEntry(
                id: "thread-preview-2",
                machineID: MachineRecord.secondaryPreview.id,
                workspaceRoot: "/workspace/infrastructure",
                name: "Inspect queue health",
                preview: "Review the latest queue status and identify blocked jobs.",
                modelProvider: "openai",
                createdAt: .now,
                updatedAt: .now.addingTimeInterval(-3_600)
            )
        ],
        preferences: UserPreferencesSnapshot(
            preferredMachineID: MachineRecord.preview.id,
            restoreLastSessionOnLaunch: true,
            preferredBootstrap: .standardSSH,
            preferredProtocol: .stdio
        )
    )
    #endif
}
