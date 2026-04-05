import SharedModels

public enum ParallelAgentMode: String, CaseIterable, Codable, Sendable {
    case off
    case clientOrchestrated
    case protocolNative

    public var title: String {
        switch self {
        case .off:
            "Off"
        case .clientOrchestrated:
            "Client-orchestrated"
        case .protocolNative:
            "Protocol-native"
        }
    }
}

public enum ParallelAgentCapability: String, CaseIterable, Codable, Sendable {
    case unavailable
    case clientOrchestratedOnly
    case protocolNative

    public var title: String {
        switch self {
        case .unavailable:
            "Subagents unavailable"
        case .clientOrchestratedOnly:
            "Client-orchestrated only"
        case .protocolNative:
            "Protocol-native subagents available"
        }
    }
}

public struct ThreadFeatureState: Hashable, Sendable {
    public var threadID: String?
    public var routeLabel: String
    public var queuedPromptCount: Int
    public var isStreaming: Bool
    public var lastTurnSummary: String?
    public var parallelAgentMode: ParallelAgentMode
    public var parallelAgentCapability: ParallelAgentCapability
    public var activityFlags: [String]
    public var subagentStatusSummary: String?

    public init(
        threadID: String?,
        routeLabel: String,
        queuedPromptCount: Int,
        isStreaming: Bool,
        lastTurnSummary: String?,
        parallelAgentMode: ParallelAgentMode = .off,
        parallelAgentCapability: ParallelAgentCapability = .clientOrchestratedOnly,
        activityFlags: [String] = [],
        subagentStatusSummary: String? = nil
    ) {
        self.threadID = threadID
        self.routeLabel = routeLabel
        self.queuedPromptCount = queuedPromptCount
        self.isStreaming = isStreaming
        self.lastTurnSummary = lastTurnSummary
        self.parallelAgentMode = parallelAgentMode
        self.parallelAgentCapability = parallelAgentCapability
        self.activityFlags = activityFlags
        self.subagentStatusSummary = subagentStatusSummary
    }
}

public enum ThreadFeature {
    public static func restoreCandidate(
        sessions: [SessionRecord],
        machineID: MachineRecord.ID
    ) -> SessionRecord? {
        sessions
            .filter { $0.machineID == machineID }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            .first
    }
}
