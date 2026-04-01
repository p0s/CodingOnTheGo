import Foundation

public enum TailnetProfileType: String, Codable, CaseIterable, Sendable {
    case embedded
    case external
}

public struct TailnetProfileDraft: Hashable, Codable, Sendable {
    public var kind: TailnetProfileType
    public var displayName: String
    public var controlURL: URL
    public var accountLabel: String
    public var tailnetDNSName: String?

    public init(
        kind: TailnetProfileType,
        displayName: String,
        controlURL: URL,
        accountLabel: String,
        tailnetDNSName: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.controlURL = controlURL
        self.accountLabel = accountLabel
        self.tailnetDNSName = tailnetDNSName
    }
}

public struct TailnetProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: TailnetProfileType
    public var displayName: String
    public var controlURL: URL
    public var accountLabel: String
    public var tailnetDNSName: String?
    public var isActive: Bool
    public var lastActivatedAt: Date?
    public var lastAuthenticatedAt: Date?
    public var supportsCustomControlServer: Bool
    public var requiresExternalApp: Bool

    public init(
        id: UUID = UUID(),
        kind: TailnetProfileType,
        displayName: String,
        controlURL: URL,
        accountLabel: String,
        tailnetDNSName: String? = nil,
        isActive: Bool = false,
        lastActivatedAt: Date? = nil,
        lastAuthenticatedAt: Date? = nil,
        supportsCustomControlServer: Bool = true,
        requiresExternalApp: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.controlURL = controlURL
        self.accountLabel = accountLabel
        self.tailnetDNSName = tailnetDNSName
        self.isActive = isActive
        self.lastActivatedAt = lastActivatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
        self.supportsCustomControlServer = supportsCustomControlServer
        self.requiresExternalApp = requiresExternalApp
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: TailnetProfileType,
        controlURL: URL,
        accountLabel: String,
        tailnetDNSName: String? = nil,
        usesEmbeddedNode: Bool,
        lastAuthenticatedAt: Date? = nil
    ) {
        self.init(
            id: id,
            kind: usesEmbeddedNode ? .embedded : kind,
            displayName: displayName,
            controlURL: controlURL,
            accountLabel: accountLabel,
            tailnetDNSName: tailnetDNSName,
            isActive: usesEmbeddedNode,
            lastActivatedAt: usesEmbeddedNode ? lastAuthenticatedAt : nil,
            lastAuthenticatedAt: lastAuthenticatedAt,
            supportsCustomControlServer: true,
            requiresExternalApp: kind == .external
        )
    }

    public var usesEmbeddedNode: Bool {
        kind == .embedded
    }
}

public enum SecretStorageScope: String, Codable, Sendable {
    case synchronizableKeychain
    case localKeychain
    case thisDeviceOnlyKeychain
}

public enum CredentialKind: String, Codable, CaseIterable, Sendable {
    case sshKey
    case password
    case token
    case companionMutualAuth
}

public struct CredentialRef: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: CredentialKind
    public var keychainAccount: String
    public var label: String
    public var username: String
    public var storageScope: SecretStorageScope
    public var lastValidatedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: CredentialKind,
        keychainAccount: String,
        label: String,
        username: String,
        storageScope: SecretStorageScope,
        lastValidatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.keychainAccount = keychainAccount
        self.label = label
        self.username = username
        self.storageScope = storageScope
        self.lastValidatedAt = lastValidatedAt
    }

    public var isSynchronizable: Bool {
        storageScope == .synchronizableKeychain
    }
}

public enum SessionTransportMode: String, Codable, CaseIterable, Sendable {
    case sshStdio
    case sshWsTunnel
    case companionDirect
}

public enum ReasoningEffortLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public enum WorkspaceMode: String, Codable, CaseIterable, Sendable {
    case local
    case worktree
}

public enum SessionTransportState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

public enum ResumeStrategy: String, Codable, CaseIterable, Sendable {
    case resumeThread
    case startNewTurn
    case requireUserConfirmation
}

public struct RecentTurnMetadata: Hashable, Codable, Sendable {
    public var turnID: String
    public var summary: String
    public var completedAt: Date

    public init(turnID: String, summary: String, completedAt: Date) {
        self.turnID = turnID
        self.summary = summary
        self.completedAt = completedAt
    }
}

public struct SessionRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var sceneID: String?
    public var machineID: MachineRecord.ID
    public var routeID: RouteRecord.ID?
    public var transportMode: SessionTransportMode
    public var threadID: String?
    public var threadDisplayTitle: String?
    public var unavailableSelectedThreadID: String?
    public var reviewThreadID: String?
    public var workspaceRoot: String?
    public var lastKnownProtocol: CodexProtocolKind
    public var lastKnownRouteKind: MachineRouteKind?
    public var lastKnownBootstrap: BootstrapStrategy
    public var lastModel: String?
    public var lastReasoningEffort: ReasoningEffortLevel
    public var lastMode: WorkspaceMode
    public var lastTurnID: String?
    public var lastTurn: RecentTurnMetadata?
    public var lastOpenedAt: Date
    public var resumeStrategy: ResumeStrategy
    public var uiStateBlob: Data?
    public var transportState: SessionTransportState
    public var queuedPrompts: [String]
    public var lastErrorSummary: String?
    public var parentThreadID: String?
    public var parentLastTurnID: String?
    public var isArchived: Bool
    public var executionProfileState: CodexExecutionProfileState?

    private enum CodingKeys: String, CodingKey {
        case id
        case sceneID
        case machineID
        case routeID
        case transportMode
        case threadID
        case threadDisplayTitle
        case unavailableSelectedThreadID
        case reviewThreadID
        case workspaceRoot
        case lastKnownProtocol
        case lastKnownRouteKind
        case lastKnownBootstrap
        case lastModel
        case lastReasoningEffort
        case lastMode
        case lastTurnID
        case lastTurn
        case lastOpenedAt
        case resumeStrategy
        case uiStateBlob
        case transportState
        case queuedPrompts
        case lastErrorSummary
        case parentThreadID
        case parentLastTurnID
        case isArchived
        case executionProfileState
    }

    public init(
        id: UUID = UUID(),
        sceneID: String? = nil,
        machineID: MachineRecord.ID,
        routeID: RouteRecord.ID? = nil,
        transportMode: SessionTransportMode = .sshStdio,
        threadID: String? = nil,
        threadDisplayTitle: String? = nil,
        unavailableSelectedThreadID: String? = nil,
        reviewThreadID: String? = nil,
        workspaceRoot: String? = nil,
        lastKnownProtocol: CodexProtocolKind,
        lastKnownRouteKind: MachineRouteKind? = nil,
        lastKnownBootstrap: BootstrapStrategy,
        lastModel: String? = nil,
        lastReasoningEffort: ReasoningEffortLevel = .medium,
        lastMode: WorkspaceMode = .worktree,
        lastTurnID: String? = nil,
        lastTurn: RecentTurnMetadata? = nil,
        lastOpenedAt: Date,
        resumeStrategy: ResumeStrategy = .resumeThread,
        uiStateBlob: Data? = nil,
        transportState: SessionTransportState = .disconnected,
        queuedPrompts: [String] = [],
        lastErrorSummary: String? = nil,
        parentThreadID: String? = nil,
        parentLastTurnID: String? = nil,
        isArchived: Bool = false,
        executionProfileState: CodexExecutionProfileState? = nil
    ) {
        self.id = id
        self.sceneID = sceneID
        self.machineID = machineID
        self.routeID = routeID
        self.transportMode = transportMode
        self.threadID = threadID
        self.threadDisplayTitle = threadDisplayTitle
        self.unavailableSelectedThreadID = unavailableSelectedThreadID
        self.reviewThreadID = reviewThreadID
        self.workspaceRoot = workspaceRoot
        self.lastKnownProtocol = lastKnownProtocol
        self.lastKnownRouteKind = lastKnownRouteKind
        self.lastKnownBootstrap = lastKnownBootstrap
        self.lastModel = lastModel
        self.lastReasoningEffort = lastReasoningEffort
        self.lastMode = lastMode
        self.lastTurnID = lastTurnID
        self.lastTurn = lastTurn
        self.lastOpenedAt = lastOpenedAt
        self.resumeStrategy = resumeStrategy
        self.uiStateBlob = uiStateBlob
        self.transportState = transportState
        self.queuedPrompts = queuedPrompts
        self.lastErrorSummary = lastErrorSummary
        self.parentThreadID = parentThreadID
        self.parentLastTurnID = parentLastTurnID
        self.isArchived = isArchived
        self.executionProfileState = executionProfileState
    }

    public init(
        id: UUID = UUID(),
        sceneID: String? = nil,
        machineID: MachineRecord.ID,
        routeID: RouteRecord.ID? = nil,
        transportMode: SessionTransportMode = .sshStdio,
        threadID: String? = nil,
        threadDisplayTitle: String? = nil,
        unavailableSelectedThreadID: String? = nil,
        reviewThreadID: String? = nil,
        workspaceRoot: String? = nil,
        lastKnownProtocol: CodexProtocolKind,
        lastKnownRouteKind: MachineRouteKind? = nil,
        lastKnownBootstrap: BootstrapStrategy,
        lastModel: String? = nil,
        lastReasoningEffort: ReasoningEffortLevel = .medium,
        lastMode: WorkspaceMode = .worktree,
        lastTurnID: String? = nil,
        lastTurn: RecentTurnMetadata? = nil,
        transportState: SessionTransportState,
        lastOpenedAt: Date,
        resumeStrategy: ResumeStrategy = .resumeThread,
        uiStateBlob: Data? = nil,
        queuedPrompts: [String] = [],
        lastErrorSummary: String? = nil
    ) {
        self.init(
            id: id,
            sceneID: sceneID,
            machineID: machineID,
            routeID: routeID,
            transportMode: transportMode,
            threadID: threadID,
            threadDisplayTitle: threadDisplayTitle,
            unavailableSelectedThreadID: unavailableSelectedThreadID,
            reviewThreadID: reviewThreadID,
            workspaceRoot: workspaceRoot,
            lastKnownProtocol: lastKnownProtocol,
            lastKnownRouteKind: lastKnownRouteKind,
            lastKnownBootstrap: lastKnownBootstrap,
            lastModel: lastModel,
            lastReasoningEffort: lastReasoningEffort,
            lastMode: lastMode,
            lastTurnID: lastTurnID,
            lastTurn: lastTurn,
            lastOpenedAt: lastOpenedAt,
            resumeStrategy: resumeStrategy,
            uiStateBlob: uiStateBlob,
            transportState: transportState,
            queuedPrompts: queuedPrompts,
            lastErrorSummary: lastErrorSummary
        )
    }

    public init(
        id: UUID = UUID(),
        sceneID: String? = nil,
        machineID: MachineRecord.ID,
        routeID: RouteRecord.ID? = nil,
        transportMode: SessionTransportMode = .sshStdio,
        threadID: String? = nil,
        threadDisplayTitle: String? = nil,
        unavailableSelectedThreadID: String? = nil,
        reviewThreadID: String? = nil,
        workspaceRoot: String? = nil,
        lastKnownProtocol: CodexProtocolKind,
        lastKnownRouteKind: MachineRouteKind? = nil,
        lastKnownBootstrap: BootstrapStrategy,
        lastModel: String? = nil,
        lastReasoningEffort: ReasoningEffortLevel = .medium,
        lastMode: WorkspaceMode = .worktree,
        lastTurnID: String? = nil,
        lastOpenedAt: Date,
        resumeStrategy: ResumeStrategy = .resumeThread,
        uiStateBlob: Data? = nil
    ) {
        self.init(
            id: id,
            sceneID: sceneID,
            machineID: machineID,
            routeID: routeID,
            transportMode: transportMode,
            threadID: threadID,
            threadDisplayTitle: threadDisplayTitle,
            unavailableSelectedThreadID: unavailableSelectedThreadID,
            reviewThreadID: reviewThreadID,
            workspaceRoot: workspaceRoot,
            lastKnownProtocol: lastKnownProtocol,
            lastKnownRouteKind: lastKnownRouteKind,
            lastKnownBootstrap: lastKnownBootstrap,
            lastModel: lastModel,
            lastReasoningEffort: lastReasoningEffort,
            lastMode: lastMode,
            lastTurnID: lastTurnID,
            lastTurn: nil,
            lastOpenedAt: lastOpenedAt,
            resumeStrategy: resumeStrategy,
            uiStateBlob: uiStateBlob,
            transportState: .disconnected,
            queuedPrompts: [],
            lastErrorSummary: nil
        )
    }

    public init(
        id: UUID = UUID(),
        machineID: MachineRecord.ID,
        routeID: RouteRecord.ID? = nil,
        transportMode: SessionTransportMode = .sshStdio,
        threadID: String? = nil,
        threadDisplayTitle: String? = nil,
        unavailableSelectedThreadID: String? = nil,
        reviewThreadID: String? = nil,
        workspaceRoot: String? = nil,
        lastKnownProtocol: CodexProtocolKind,
        lastKnownRouteKind: MachineRouteKind? = nil,
        lastKnownBootstrap: BootstrapStrategy,
        lastModel: String? = nil,
        lastReasoningEffort: ReasoningEffortLevel = .medium,
        lastMode: WorkspaceMode = .worktree,
        lastTurnID: String? = nil,
        lastOpenedAt: Date,
        resumeStrategy: ResumeStrategy = .resumeThread,
        uiStateBlob: Data? = nil
    ) {
        self.init(
            id: id,
            sceneID: nil,
            machineID: machineID,
            routeID: routeID,
            transportMode: transportMode,
            threadID: threadID,
            threadDisplayTitle: threadDisplayTitle,
            unavailableSelectedThreadID: unavailableSelectedThreadID,
            reviewThreadID: reviewThreadID,
            workspaceRoot: workspaceRoot,
            lastKnownProtocol: lastKnownProtocol,
            lastKnownRouteKind: lastKnownRouteKind,
            lastKnownBootstrap: lastKnownBootstrap,
            lastModel: lastModel,
            lastReasoningEffort: lastReasoningEffort,
            lastMode: lastMode,
            lastTurnID: lastTurnID,
            lastTurn: nil,
            lastOpenedAt: lastOpenedAt,
            resumeStrategy: resumeStrategy,
            uiStateBlob: uiStateBlob,
            transportState: .disconnected,
            queuedPrompts: [],
            lastErrorSummary: nil
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sceneID = try container.decodeIfPresent(String.self, forKey: .sceneID)
        machineID = try container.decode(MachineRecord.ID.self, forKey: .machineID)
        routeID = try container.decodeIfPresent(RouteRecord.ID.self, forKey: .routeID)
        transportMode = try container.decode(SessionTransportMode.self, forKey: .transportMode)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        threadDisplayTitle = try container.decodeIfPresent(String.self, forKey: .threadDisplayTitle)
        unavailableSelectedThreadID = try container.decodeIfPresent(String.self, forKey: .unavailableSelectedThreadID)
        reviewThreadID = try container.decodeIfPresent(String.self, forKey: .reviewThreadID)
        workspaceRoot = try container.decodeIfPresent(String.self, forKey: .workspaceRoot)
        lastKnownProtocol = try container.decode(CodexProtocolKind.self, forKey: .lastKnownProtocol)
        lastKnownRouteKind = try container.decodeIfPresent(MachineRouteKind.self, forKey: .lastKnownRouteKind)
        lastKnownBootstrap = try container.decode(BootstrapStrategy.self, forKey: .lastKnownBootstrap)
        lastModel = try container.decodeIfPresent(String.self, forKey: .lastModel)
        lastReasoningEffort = try container.decodeIfPresent(ReasoningEffortLevel.self, forKey: .lastReasoningEffort) ?? .medium
        lastMode = try container.decodeIfPresent(WorkspaceMode.self, forKey: .lastMode) ?? .worktree
        lastTurnID = try container.decodeIfPresent(String.self, forKey: .lastTurnID)
        lastTurn = try container.decodeIfPresent(RecentTurnMetadata.self, forKey: .lastTurn)
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
        resumeStrategy = try container.decodeIfPresent(ResumeStrategy.self, forKey: .resumeStrategy) ?? .resumeThread
        uiStateBlob = try container.decodeIfPresent(Data.self, forKey: .uiStateBlob)
        transportState = try container.decodeIfPresent(SessionTransportState.self, forKey: .transportState) ?? .disconnected
        queuedPrompts = try container.decodeIfPresent([String].self, forKey: .queuedPrompts) ?? []
        lastErrorSummary = try container.decodeIfPresent(String.self, forKey: .lastErrorSummary)
        parentThreadID = try container.decodeIfPresent(String.self, forKey: .parentThreadID)
        parentLastTurnID = try container.decodeIfPresent(String.self, forKey: .parentLastTurnID)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        executionProfileState = try container.decodeIfPresent(CodexExecutionProfileState.self, forKey: .executionProfileState)
    }
}
