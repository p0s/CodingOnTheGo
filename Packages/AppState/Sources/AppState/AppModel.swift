import CodexRPC
import CompanionHost
import CryptoKit
import Discovery
import FeatureComposer
import FeatureMachines
import FeatureThreads
import Foundation
import GitWorkspace
import HostBootstrap
import Notifications
import Observation
import OSLog
import Persistence
import RouteSelection
import Secrets
import SSHTransport
import SharedModels
import SyncEngine
import TailnetEmbedded
#if canImport(CFNetwork)
import CFNetwork
#endif
#if canImport(Network)
import Network
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private final class AsyncTimeoutCoordinator<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        operationTask = task
        lock.unlock()
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        timeoutTask = task
        lock.unlock()
    }

    func cancelOperation() {
        lock.lock()
        let task = operationTask
        lock.unlock()
        task?.cancel()
    }

    func complete(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
        let shouldResume: Bool
        let tasksToCancel: (Task<Void, Never>?, Task<Void, Never>?)
        lock.lock()
        if completed {
            shouldResume = false
            tasksToCancel = (nil, nil)
        } else {
            completed = true
            shouldResume = true
            tasksToCancel = (operationTask, timeoutTask)
        }
        lock.unlock()

        guard shouldResume else {
            return
        }

        tasksToCancel.0?.cancel()
        tasksToCancel.1?.cancel()
        continuation.resume(with: result)
    }
}

public enum ExternalTailnetAppState: String, Hashable, Sendable {
    case checking
    case notInstalled
    case installedUnavailable
    case installedReady
    case detectionUnavailable

    public var title: String {
        switch self {
        case .checking:
            "Checking install state"
        case .notInstalled:
            "Not installed"
        case .installedUnavailable:
            "Installed, route unavailable"
        case .installedReady:
            "Installed, route healthy"
        case .detectionUnavailable:
            "Detection unavailable"
        }
    }
}

public enum LocalNetworkScanStatus: Hashable, Sendable {
    case idle
    case scanning
    case found(totalMachineCount: Int, newMachineCount: Int)
    case noResults(proxyRisk: Bool)
}

public struct HostRuntimeTransportStatus: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case retrying
        case httpsFallback
        case loopbackFallback
        case threadRefreshFailed
    }

    public var kind: Kind
    public var label: String
    public var detail: String

    public init(kind: Kind, label: String, detail: String) {
        self.kind = kind
        self.label = label
        self.detail = detail
    }
}

public struct NearbyMachineResult: Identifiable, Hashable, Sendable {
    public var id: String
    public var machineID: MachineRecord.ID
    public var machineAlias: String
    public var hostname: String
    public var routeKind: MachineRouteKind
    public var source: DiscoverySource
    public var health: RouteHealthStatus
    public var isAlreadySaved: Bool

    public init(
        id: String,
        machineID: MachineRecord.ID,
        machineAlias: String,
        hostname: String,
        routeKind: MachineRouteKind,
        source: DiscoverySource,
        health: RouteHealthStatus,
        isAlreadySaved: Bool
    ) {
        self.id = id
        self.machineID = machineID
        self.machineAlias = machineAlias
        self.hostname = hostname
        self.routeKind = routeKind
        self.source = source
        self.health = health
        self.isAlreadySaved = isAlreadySaved
    }

    public var isHighConfidence: Bool {
        health == .healthy && source != .manualAdd
    }
}

private struct SessionExecutionSnapshot: Sendable {
    var runtime: CodexResolvedRuntime?
    var baselineConfig: CodexExecutionBaselineConfigSnapshot?
    var constraints: CodexExecutionConstraintsSnapshot?
    var support: CodexExecutionSupportSnapshot
}

private struct ResolvedThreadBindingContext: Sendable {
    var context: CodexResumedThreadContext
    var isLiveBinding: Bool

    var thread: CodexThreadSnapshot { context.thread }
    var cwd: String { context.cwd }
    var model: String? { context.model }
    var reasoningEffort: CodexReasoningEffort? { context.reasoningEffort }
    var executionProfile: CodexExecutionProfile? { context.executionProfile }
}

public struct MachineSetupStatus: Equatable, Sendable {
    public let hasDetectedRoute: Bool
    public let accountReady: Bool
    public let sshAccessReady: Bool
    public let trustReady: Bool
    public let completedStepCount: Int
    public let requiredStepCount: Int
    public let nextStepTitle: String?
    public let nextStepDetail: String?

    public init(
        hasDetectedRoute: Bool,
        accountReady: Bool,
        sshAccessReady: Bool,
        trustReady: Bool,
        completedStepCount: Int,
        requiredStepCount: Int,
        nextStepTitle: String?,
        nextStepDetail: String?
    ) {
        self.hasDetectedRoute = hasDetectedRoute
        self.accountReady = accountReady
        self.sshAccessReady = sshAccessReady
        self.trustReady = trustReady
        self.completedStepCount = completedStepCount
        self.requiredStepCount = requiredStepCount
        self.nextStepTitle = nextStepTitle
        self.nextStepDetail = nextStepDetail
    }

    public var isReady: Bool {
        completedStepCount >= requiredStepCount
    }
}

public enum SavedSSHKeyRecoveryAvailability: Equatable, Sendable {
    case none
    case directRecovery
    case candidateSearch(count: Int)
}

public struct ThreadWorkspaceRoutingResult: Sendable {
    public let sessionID: SessionRecord.ID
    public let threadID: String
    public let workspaceRoot: String

    public init(
        sessionID: SessionRecord.ID,
        threadID: String,
        workspaceRoot: String
    ) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.workspaceRoot = workspaceRoot
    }
}

struct ActiveThreadSummaryDigest: Equatable, Sendable {
    var threadID: String
    var updatedAt: Date
    var preview: String
    var status: CodexThreadRuntimeStatus
}

public protocol ExternalTailnetAppDetecting: Sendable {
    func isInstalled() async -> Bool?
}

public struct SystemExternalTailnetAppDetector: ExternalTailnetAppDetecting {
    public init() {}

    public func isInstalled() async -> Bool? {
        guard let url = URL(string: "tailscale://") else {
            return false
        }

        #if canImport(UIKit)
        return await MainActor.run {
            UIApplication.shared.canOpenURL(url)
        }
        #elseif canImport(AppKit)
        return await MainActor.run {
            NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        }
        #else
        return nil
        #endif
    }
}

public struct NetworkProxyDiagnosticSnapshot: Hashable, Sendable {
    public var systemProxyEnabled: Bool
    public var envProxyKeys: [String]
    public var localBypassConfigured: Bool
    public var lanBypassConfigured: Bool
    public var tailnetBypassConfigured: Bool
    public var shadowrocketLikelyActive: Bool

    public init(
        systemProxyEnabled: Bool,
        envProxyKeys: [String],
        localBypassConfigured: Bool,
        lanBypassConfigured: Bool,
        tailnetBypassConfigured: Bool,
        shadowrocketLikelyActive: Bool
    ) {
        self.systemProxyEnabled = systemProxyEnabled
        self.envProxyKeys = envProxyKeys
        self.localBypassConfigured = localBypassConfigured
        self.lanBypassConfigured = lanBypassConfigured
        self.tailnetBypassConfigured = tailnetBypassConfigured
        self.shadowrocketLikelyActive = shadowrocketLikelyActive
    }

    public var localhostRisk: Bool {
        proxyActive && !localBypassConfigured
    }

    public var discoveryRisk: Bool {
        proxyActive && !lanBypassConfigured
    }

    public var tailnetRisk: Bool {
        proxyActive && !tailnetBypassConfigured
    }

    public var proxyActive: Bool {
        systemProxyEnabled || !envProxyKeys.isEmpty || shadowrocketLikelyActive
    }

    public var statusLabel: String {
        if !proxyActive {
            return "Direct paths healthy"
        }
        if localhostRisk || discoveryRisk || tailnetRisk {
            return "Bypass needed"
        }
        return "Proxy active with bypass"
    }

    public var detail: String {
        if !proxyActive {
            return "No system proxy, env proxy, or third-party VPN/proxy local override was detected."
        }

        var segments: [String] = []
        if systemProxyEnabled {
            segments.append("System proxy settings are enabled.")
        }
        if !envProxyKeys.isEmpty {
            segments.append("Environment proxies are set via \(envProxyKeys.joined(separator: ", ")).")
        }
        if shadowrocketLikelyActive {
            segments.append("A local proxy/VPN app appears active.")
        }
        if localhostRisk || discoveryRisk || tailnetRisk {
            segments.append("Bypass localhost, .local, RFC1918 private ranges, 100.64.0.0/10, and *.ts.net traffic before validating LAN or tailnet routes.")
        } else {
            segments.append("Local, LAN, and tailnet bypass rules appear to be configured.")
        }
        return segments.joined(separator: " ")
    }

    public func statusLabel(for routeKind: MachineRouteKind?) -> String {
        if !proxyActive {
            return "Direct paths healthy"
        }
        if hasRelevantRisk(for: routeKind) {
            return "Bypass needed"
        }
        return "Proxy active with bypass"
    }

    public func detail(for routeKind: MachineRouteKind?) -> String {
        if !proxyActive {
            return detail
        }

        var segments: [String] = []
        if systemProxyEnabled {
            segments.append("System proxy settings are enabled.")
        }
        if !envProxyKeys.isEmpty {
            segments.append("Environment proxies are set via \(envProxyKeys.joined(separator: ", ")).")
        }
        if shadowrocketLikelyActive {
            segments.append("A local proxy/VPN app appears active.")
        }

        if hasRelevantRisk(for: routeKind) {
            switch routeKind {
            case .embeddedTailnet, .externalTailnet:
                segments.append("Tailnet traffic still needs an explicit bypass for 100.64.0.0/10 and *.ts.net before validating embedded or external tailnet routes.")
            case .localLAN, .manualSSH, .companionDirect:
                segments.append("The current LAN/manual route is bypassed correctly, but tailnet traffic still needs an explicit bypass for 100.64.0.0/10 and *.ts.net before tailnet validation.")
            case nil:
                segments.append("Bypass localhost, .local, RFC1918 private ranges, 100.64.0.0/10, and *.ts.net traffic before validating LAN or tailnet routes.")
            }
        } else {
            switch routeKind {
            case .embeddedTailnet, .externalTailnet:
                segments.append("Tailnet bypass rules appear to be configured for the current route.")
            case .localLAN, .manualSSH, .companionDirect:
                if tailnetRisk {
                    segments.append("Local and LAN bypass rules appear to be configured for the current route. Tailnet bypass still needs 100.64.0.0/10 and *.ts.net before tailnet validation.")
                } else {
                    segments.append("Local and LAN bypass rules appear to be configured for the current route.")
                }
            case nil:
                segments.append("Local, LAN, and tailnet bypass rules appear to be configured.")
            }
        }

        return segments.joined(separator: " ")
    }

    private func hasRelevantRisk(for routeKind: MachineRouteKind?) -> Bool {
        switch routeKind {
        case .embeddedTailnet, .externalTailnet:
            return tailnetRisk
        case .localLAN, .manualSSH, .companionDirect:
            return localhostRisk || discoveryRisk
        case nil:
            return localhostRisk || discoveryRisk || tailnetRisk
        }
    }

    public static func current() -> NetworkProxyDiagnosticSnapshot {
        current(
            environment: ProcessInfo.processInfo.environment,
            systemSettings: systemProxySettings()
        )
    }

    static func current(
        environment: [String: String],
        systemSettings: [String: Any]
    ) -> NetworkProxyDiagnosticSnapshot {
        let envProxyKeys = [
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy"
        ].filter { key in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !value.isEmpty
        }

        let noProxyList = (environment["NO_PROXY"] ?? environment["no_proxy"] ?? "")
            .lowercased()
        let exceptionPatterns = ((systemSettings["ExceptionsList"] as? [String]) ?? [])
            .map { $0.lowercased() }
        let excludeSimpleHosts = (systemSettings["ExcludeSimpleHostnames"] as? NSNumber)?.intValue == 1
        let systemProxyEnabled = [
            "HTTPEnable",
            "HTTPSEnable",
            "SOCKSEnable",
            "ProxyAutoConfigEnable"
        ].contains { key in
            (systemSettings[key] as? NSNumber)?.intValue == 1
        }

        func listContainsAny(_ haystack: String, patterns: [String]) -> Bool {
            patterns.contains { pattern in
                haystack.contains(pattern.lowercased())
            }
        }

        let envLocalBypass = listContainsAny(noProxyList, patterns: ["localhost", "127.0.0.1", "::1"])
        let envLANBypass = envLocalBypass && listContainsAny(noProxyList, patterns: [".local", "10.", "192.168.", "172.16.", "172.17.", "172.18.", "172.19.", "172.2", "172.30.", "172.31."])
        let envTailnetBypass = listContainsAny(noProxyList, patterns: [".ts.net", "ts.net", "100.64."])

        let systemLocalBypass = excludeSimpleHosts || exceptionPatterns.contains(where: {
            ["localhost", "127.0.0.1", "::1"].contains($0)
        })
        let systemLANBypass = systemLocalBypass || exceptionPatterns.contains(where: {
            $0.contains(".local") || $0.contains("10.") || $0.contains("192.168.") || $0.contains("172.")
        })
        let systemTailnetBypass = exceptionPatterns.contains(where: {
            $0.contains(".ts.net") || $0.contains("100.64.")
        })

        let shadowrocketLikelyActive = systemProxyEnabled && (systemSettings["SOCKSEnable"] as? NSNumber)?.intValue == 1

        return NetworkProxyDiagnosticSnapshot(
            systemProxyEnabled: systemProxyEnabled,
            envProxyKeys: envProxyKeys,
            localBypassConfigured: envLocalBypass || systemLocalBypass,
            lanBypassConfigured: envLANBypass || systemLANBypass,
            tailnetBypassConfigured: envTailnetBypass || systemTailnetBypass,
            shadowrocketLikelyActive: shadowrocketLikelyActive
        )
    }

    private static func systemProxySettings() -> [String: Any] {
        #if canImport(CFNetwork)
        if let unmanaged = CFNetworkCopySystemProxySettings() {
            return unmanaged.takeRetainedValue() as? [String: Any] ?? [:]
        }
        #endif
        return [:]
    }
}

@MainActor
@Observable
public final class AppModel {
    private struct EmbeddedTailnetBootstrapRequest: Equatable {
        struct Profile: Equatable {
            let id: TailnetProfile.ID
            let kind: TailnetProfileType
            let displayName: String
            let controlURL: URL
            let accountLabel: String
            let tailnetDNSName: String?
            let isActive: Bool
            let requiresExternalApp: Bool
        }

        let profiles: [Profile]
        let activeProfileID: TailnetProfile.ID?

        init(profiles: [TailnetProfile], activeProfileID: TailnetProfile.ID?) {
            self.profiles = profiles.map {
                Profile(
                    id: $0.id,
                    kind: $0.kind,
                    displayName: $0.displayName,
                    controlURL: $0.controlURL,
                    accountLabel: $0.accountLabel,
                    tailnetDNSName: $0.tailnetDNSName,
                    isActive: $0.isActive,
                    requiresExternalApp: $0.requiresExternalApp
                )
            }
            self.activeProfileID = activeProfileID
        }
    }

    private struct UITestLaunchAutomationResult: Codable {
        let status: String
        let detail: String
        let automationStage: String
        let machineAlias: String?
        let routeKind: String?
        let routeHost: String?
        let protocolKind: String?
        let threadID: String?
        let activeTurnID: String?
        let transportCheckPassed: Bool
        let transportCheckDetail: String?
        let transportModelCount: Int?
        let credentialReady: Bool
        let hostValidationReady: Bool
        let workspaceStatus: String
        let workspaceBranch: String?
        let workspaceFailureSummary: String?
        let selectedMachineID: String?
        let machineCount: Int
        let hostThreadCatalogCount: Int
        let assistantReplyCount: Int
        let assistantReply: String?
        let smokeTestSucceeded: Bool
        let tailnetAuthState: String?
        let tailnetPendingAuth: Bool
        let tailnetReachable: Bool
        let tailnetLastError: String?
        let dialPlanHost: String?
        let dialPlanPort: UInt16?
        let transcriptTail: [String]
        let timestamp: String
    }

    private struct CodexConnectionAutomationError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    private struct UnavailableSelectedThreadError: LocalizedError {
        let threadID: String?

        var errorDescription: String? {
            Self.message(for: threadID)
        }

        static func message(for threadID: String?) -> String {
            if let threadID,
               !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "The previous thread (\(threadID)) is no longer available. I didn’t start a new thread automatically. Open Projects & Threads to resume another thread or start a new one."
            }

            return "The previous thread is no longer available. I didn’t start a new thread automatically. Open Projects & Threads to resume another thread or start a new one."
        }
    }

    private struct SigningSensitiveHostReadinessError: LocalizedError {
        let detail: String

        var errorDescription: String? {
            "Host not ready for signing-sensitive work: \(detail)"
        }
    }

    @ObservationIgnored private static let logger = Logger(subsystem: "com.example.codingonthego.ios", category: "AppModel")
    @ObservationIgnored private static let automaticModelRefreshInterval: TimeInterval = 15 * 60
    @ObservationIgnored private static let sharedEmbeddedTailnetManager = EmbeddedTailnetNodeManager()
    @ObservationIgnored private let safeLaneClient = CodexSSHAppServerClient()
    @ObservationIgnored private let loopbackClient = CodexWebSocketClient()
    @ObservationIgnored private static let metadataStore = JSONMetadataStore()
    @ObservationIgnored private let sceneID: String
    @ObservationIgnored private let runtimeConfiguration: AppRuntimeConfiguration
    @ObservationIgnored private let syncCoordinator: any SyncCoordinator
    @ObservationIgnored private let notificationCoordinator: any NotificationCoordinator
    @ObservationIgnored private let secretVault: any SecretVault
    @ObservationIgnored private let discoveryCoordinator: DiscoveryCoordinator
    @ObservationIgnored private let externalTailnetAppDetector: any ExternalTailnetAppDetecting
    @ObservationIgnored private var preservesPreviewFixtures: Bool
    @ObservationIgnored private var embeddedTailnetManager: EmbeddedTailnetNodeManager { Self.sharedEmbeddedTailnetManager }
    @ObservationIgnored private var embeddedTailnetDialPlan: EmbeddedTailnetDialPlan?
    @ObservationIgnored private var stdioThreadID: String?
    @ObservationIgnored private var loopbackThreadID: String?
    @ObservationIgnored private var directEndpointThreadID: String?
    @ObservationIgnored private var automaticLoopbackUpgradePending = false
    @ObservationIgnored private var automaticLoopbackUpgradeTask: Task<Void, Never>?
    @ObservationIgnored private var loopbackRecoveryRetryTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var connectionAttemptStartedAt: Date?
    @ObservationIgnored private var connectionAttemptGeneration = 0
    @ObservationIgnored private var lastAutomaticLoopbackUpgradeAttemptAt: Date?
    @ObservationIgnored private var automaticLoopbackUpgradeSuppressedUntilReconnect = false
    @ObservationIgnored private var loopbackUpgradeInProgress = false
    @ObservationIgnored private var suppressNextWebsocketErrorAfterCompletedTurn = false
    @ObservationIgnored private var lastLoopbackUpgradeStandbyReason: String?
    @ObservationIgnored private var pendingTurnRequests: [PendingTurnRequest] = []
    @ObservationIgnored private var clientSubagentTasks: [ClientSubagentTask] = []
    @ObservationIgnored private var activeClientSubagentTaskID: UUID?
    @ObservationIgnored private var uiTestLaunchAutomationTask: Task<Void, Never>?
    @ObservationIgnored private var embeddedTailnetBootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightEmbeddedTailnetBootstrapRequest: EmbeddedTailnetBootstrapRequest?
    @ObservationIgnored private var lastCompletedEmbeddedTailnetBootstrapRequest: EmbeddedTailnetBootstrapRequest?
    @ObservationIgnored private var repoBrowserRefreshInFlight = false
    @ObservationIgnored private var refreshedHostThreadCatalogMachineIDs: Set<MachineRecord.ID> = []
    @ObservationIgnored private var localNetworkAccessPrimed = false
    @ObservationIgnored private var demoScenario: AppDemoScenario?
    @ObservationIgnored private var activeTranscriptSnapshot: CodexThreadSnapshot?
    @ObservationIgnored private var prefetchedTranscriptHistory: [SessionMessage] = []
    @ObservationIgnored private var revealedEarlierTranscriptMessageCount = 0
    @ObservationIgnored private var lastObservedActiveThreadSummary: ActiveThreadSummaryDigest?
    @ObservationIgnored private var activeThreadSummaryRefreshInFlight = false
    @ObservationIgnored private var streamingActivityMessageIDs: [String: UUID] = [:]
    @ObservationIgnored private var modelRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastSuccessfulModelRefreshAt: Date?
    @ObservationIgnored private var hasCompletedInitialRestore = false
    @ObservationIgnored private var pendingInitialPreferenceOverrides = PendingInitialPreferenceOverrides()
    private static let staleConnectingSessionTimeout: TimeInterval = 90
    #if canImport(Network)
    @ObservationIgnored private var nearbyRoutePathMonitor: NWPathMonitor?
    @ObservationIgnored private let nearbyRoutePathMonitorQueue = DispatchQueue(
        label: "com.example.codingonthego.nearby-route-path-monitor"
    )
    #endif
    private static let embeddedTailnetBootstrapPollInterval: Duration = .milliseconds(500)
    private static let embeddedTailnetBootstrapPollLimit = 180

    private struct PendingInitialPreferenceOverrides: Sendable {
        var didSetReasoningEffort = false
        var reasoningEffort: CodexReasoningEffort = .medium
        var didSetApprovalPolicy = false
        var approvalPolicy: String?
        var didSetSandboxMode = false
        var sandboxMode: CodexSandboxMode?
        var didSetPrivacyMode = false
        var privacyMode: AppPrivacyMode = .standard

        var hasAnyOverride: Bool {
            didSetReasoningEffort || didSetApprovalPolicy || didSetSandboxMode || didSetPrivacyMode
        }
    }

    private var persistenceCoordinator: AppStatePersistenceCoordinator {
        AppStatePersistenceCoordinator(
            metadataStore: Self.metadataStore,
            syncCoordinator: syncCoordinator,
            runtimeConfiguration: runtimeConfiguration,
            environment: ProcessInfo.processInfo.environment
        )
    }

    private var demoModeController: AppDemoModeController {
        AppDemoModeController(environment: ProcessInfo.processInfo.environment)
    }

    public var machines: [MachineRecord]
    public var selectedMachineID: MachineRecord.ID?
    public var recentSessions: [SessionRecord]
    public var hostThreadCatalog: [HostThreadCatalogEntry]
    public var tailnetProfiles: [TailnetProfile]
    public var transcript: [SessionMessage]
    public var hiddenTranscriptMessageCount: Int
    public var activeSessionID: SessionRecord.ID?
    public var activeExecutionProfileState: CodexExecutionProfileState?
    public var displayedTranscriptThreadID: String?
    public var connectionState: LiveConnectionState
    public var pendingPrompts: [String]
    public var activeTurnID: String?
    public var activeProtocolKind: CodexProtocolKind
    public var workspaceSummary: GitWorkspaceSummary?
    public var workspaceFailureSummary: String?
    public var worktrees: [GitWorktreeEntry]
    public var revertPreview: RevertPreview?
    public var composerState: ComposerFeatureState
    public var discoverySnapshot: DiscoverySnapshot?
    public var localNetworkScanStatus: LocalNetworkScanStatus
    public var nearbyDiscoveryResults: [NearbyMachineResult]
    public var localNetworkDiscoveryDebugLabel: String
    public var syncSnapshot: SyncSnapshot
    public var notificationSnapshot: NotificationSnapshot
    public var availableModels: [CodexModelDescriptor]
    public var selectedModel: String?
    public var selectedCollaborationMode: CodexCollaborationModeKind?
    public var selectedParallelAgentMode: ParallelAgentMode
    public var selectedReasoningEffort: CodexReasoningEffort
    public var preferredApprovalPolicy: String?
    public var preferredSandboxMode: CodexSandboxMode?
    public var privacyMode: AppPrivacyMode
    public var threadActivityFlags: [String]
    public var subagentActivitySummary: String?
    public var isRestoringActiveTranscript: Bool
    public var steerDraft: String
    public var pendingApprovalRequest: CodexApprovalRequest?
    public var pendingStructuredUserInputRequest: CodexStructuredUserInputRequest?
    public var embeddedTailnetStatus: EmbeddedTailnetStatus
    public var pendingTailnetAuthTicket: EmbeddedTailnetAuthTicket?
    public var runtimeCapabilityDiagnostics: HostCapabilityDiagnostics?
    public var networkProxyDiagnostics: NetworkProxyDiagnosticSnapshot
    public var connectionSetupNotice: String?
    public var pendingScannedHostKey: String?
    public var pendingScannedHostKeyRouteID: RouteRecord.ID?
    public var pendingScannedHostKeyFingerprint: String?
    public var generatedSSHTestPublicKey: String?
    public var revealedSSHLoginPublicKey: String?
    public var externalTailnetAppInstalled: Bool?
    var allowsNearbyNetworkRoutes: Bool?
    public var isRefreshingHostThreadCatalog: Bool
    public var lastHostThreadCatalogRefreshAt: Date?
    public var hostThreadCatalogErrorSummary: String?
    public var hostThreadCatalogDebugSummary: String?
    public var composerSendAttemptCount: Int
    public var isDemoModeEnabled: Bool
    public var hostRuntimeTransportStatus: HostRuntimeTransportStatus?

    public init(
        sceneID: String = UUID().uuidString,
        machines: [MachineRecord]? = nil,
        tailnetProfiles: [TailnetProfile]? = nil,
        recentSessions: [SessionRecord]? = nil,
        bootstrapSnapshot: MachineDirectorySnapshot? = nil,
        runtimeConfiguration: AppRuntimeConfiguration = .load(environment: ProcessInfo.processInfo.environment),
        syncCoordinator: (any SyncCoordinator)? = nil,
        notificationCoordinator: (any NotificationCoordinator)? = nil,
        secretVault: any SecretVault = SystemKeychainSecretVault(),
        discoveryCoordinator: DiscoveryCoordinator = DiscoveryCoordinator(),
        externalTailnetAppDetector: any ExternalTailnetAppDetecting = SystemExternalTailnetAppDetector(),
        startRuntimeServices: Bool = true
    ) {
        let demoModeEnabled = Self.shouldLaunchInDemoMode()
        let initialDemoScenario = demoModeEnabled ? AppDemoScenario.make(sceneID: sceneID) : nil
        let initialSnapshot = initialDemoScenario?.snapshot ?? Self.bootstrapSnapshot(
            sceneID: sceneID,
            machines: machines,
            tailnetProfiles: tailnetProfiles,
            recentSessions: recentSessions,
            bootstrapSnapshot: bootstrapSnapshot
        )
        let initialSelectedMachineID = initialSnapshot.preferences.preferredMachineID ?? initialSnapshot.machines.first?.id
        let initialProxyDiagnostics = NetworkProxyDiagnosticSnapshot.current()
        let initialSelectedMachineAlias = initialSnapshot.machines
            .first(where: { $0.id == initialSelectedMachineID })?
            .alias
            ?? "none"
        self.sceneID = sceneID
        self.machines = initialSnapshot.machines
        self.selectedMachineID = initialSelectedMachineID
        self.recentSessions = initialSnapshot.recentSessions
        self.hostThreadCatalog = initialSnapshot.hostThreadCatalog
        self.tailnetProfiles = initialSnapshot.tailnetProfiles
        self.transcript = []
        self.hiddenTranscriptMessageCount = 0
        self.activeSessionID = nil
        self.activeExecutionProfileState = nil
        self.displayedTranscriptThreadID = nil
        self.connectionState = .disconnected
        self.pendingPrompts = []
        self.activeTurnID = nil
        self.activeProtocolKind = .stdio
        self.workspaceSummary = nil
        self.workspaceFailureSummary = nil
        self.worktrees = []
        self.revertPreview = nil
        self.composerState = ComposerFeatureState()
        self.discoverySnapshot = nil
        self.localNetworkScanStatus = .idle
        self.nearbyDiscoveryResults = []
        self.localNetworkDiscoveryDebugLabel = "status=idle;machines=0;selected=none;proxyRisk=false"
        self.syncSnapshot = SyncSnapshot(status: .idle)
        self.notificationSnapshot = NotificationSnapshot(authorization: .unknown)
        self.availableModels = []
        self.selectedModel = nil
        self.selectedCollaborationMode = nil
        self.selectedParallelAgentMode = .off
        let initialReasoningEffort = CodexReasoningEffort(
            rawValue: initialSnapshot.preferences.preferredReasoningEffort ?? ""
        ) ?? .medium
        let initialPreferenceOverrides = Self.uiTestPreferenceOverrides(
            reasoningEffort: initialReasoningEffort,
            approvalPolicy: initialSnapshot.preferences.preferredApprovalPolicy,
            sandboxMode: initialSnapshot.preferences.preferredSandboxMode.flatMap(CodexSandboxMode.init(rawValue:))
        )
        self.selectedReasoningEffort = initialPreferenceOverrides.reasoningEffort
        self.preferredApprovalPolicy = initialPreferenceOverrides.approvalPolicy
        self.preferredSandboxMode = initialPreferenceOverrides.sandboxMode
        self.privacyMode = initialSnapshot.preferences.privacyMode
        self.threadActivityFlags = []
        self.subagentActivitySummary = nil
        self.isRestoringActiveTranscript = false
        self.steerDraft = ""
        self.pendingApprovalRequest = nil
        self.pendingStructuredUserInputRequest = nil
        self.embeddedTailnetStatus = Self.provisionalTailnetStatus(
            for: initialSnapshot.tailnetProfiles.first(where: \.isActive)
        )
        self.embeddedTailnetDialPlan = nil
        self.pendingTailnetAuthTicket = nil
        self.runtimeCapabilityDiagnostics = nil
        self.networkProxyDiagnostics = initialProxyDiagnostics
        self.localNetworkDiscoveryDebugLabel = "status=idle;machines=\(initialSnapshot.machines.count);selected=\(initialSelectedMachineAlias);proxyRisk=\(initialProxyDiagnostics.discoveryRisk)"
        self.pendingScannedHostKey = nil
        self.pendingScannedHostKeyRouteID = nil
        self.pendingScannedHostKeyFingerprint = nil
        self.generatedSSHTestPublicKey = nil
        self.revealedSSHLoginPublicKey = nil
        self.externalTailnetAppInstalled = nil
        self.allowsNearbyNetworkRoutes = nil
        self.isRefreshingHostThreadCatalog = false
        self.lastHostThreadCatalogRefreshAt = nil
        self.hostThreadCatalogErrorSummary = nil
        self.hostThreadCatalogDebugSummary = nil
        self.composerSendAttemptCount = 0
        self.isDemoModeEnabled = demoModeEnabled
        self.hostRuntimeTransportStatus = nil
        self.runtimeConfiguration = runtimeConfiguration
        self.syncCoordinator = syncCoordinator ?? SyncCoordinatorFactory.makeDefault(configuration: runtimeConfiguration)
        self.notificationCoordinator = notificationCoordinator ?? InMemoryNotificationCoordinator()
        self.secretVault = secretVault
        self.discoveryCoordinator = discoveryCoordinator
        self.externalTailnetAppDetector = externalTailnetAppDetector
        self.demoScenario = initialDemoScenario
        self.preservesPreviewFixtures = ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_PREVIEW_FIXTURE"] == "1"
            || initialSnapshot.machines.contains(where: \.isPreviewFixture)
            || initialSnapshot.tailnetProfiles.contains(where: \.isPreviewFixture)
        if let initialDemoScenario {
            applyDemoModeScenario(initialDemoScenario, restoreSelection: true)
        } else if startRuntimeServices,
                  !Self.shouldDeferRuntimeServicesForUITestReset() {
            startNearbyRoutePathMonitoring()
            scheduleEmbeddedTailnetBootstrap(
                profiles: initialSnapshot.tailnetProfiles,
                activeProfileID: initialSnapshot.tailnetProfiles.first(where: \.isActive)?.id,
                persist: false
            )
            Task {
                await self.refreshExternalTailnetAppAvailability()
            }
        }
        syncActiveExecutionProfileStateFromCurrentSession()
    }

    public var selectedMachine: MachineRecord? {
        guard let selectedMachineID else {
            return machines.first
        }

        return machines.first { $0.id == selectedMachineID } ?? machines.first
    }

    public var showsEmbeddedTailnetFeature: Bool {
        Self.embeddedTailnetFeatureAvailable
    }

    public var showsLoopbackUpgradeFeature: Bool {
        loopbackUpgradeFeatureAvailable || canReturnToSafeLane
    }

    public var showsLocalhostTestingControls: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
            || ProcessInfo.processInfo.environment["COTG_ENABLE_LOCALHOST_TESTING_TOOLS"] == "1"
    }

    public var hasHiddenTranscriptHistory: Bool {
        (!prefetchedTranscriptHistory.isEmpty || hiddenTranscriptMessageCount > 0) && !transcript.isEmpty
    }

    public var reconnectTranscriptPreview: String? {
        guard transcript.isEmpty else {
            return nil
        }
        guard case .connecting = connectionState else {
            return nil
        }

        let summary = activeSession?.lastTurn?.summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if summary?.isEmpty == false {
            return summary
        }

        guard let threadID = activeSession?.threadID else {
            return nil
        }

        let catalogPreview = hostThreadCatalog
            .first(where: { $0.id == threadID })?
            .preview
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogPreview?.isEmpty == false ? catalogPreview : nil
    }

    public var selectedMachineHostThreadCatalogProvenance: HostThreadCatalogProvenance? {
        let entries = selectedMachineHostThreadCatalogEntries
        guard !entries.isEmpty else {
            return nil
        }

        if entries.contains(where: { $0.provenance == .sqliteRepaired }) {
            return .sqliteRepaired
        }
        if case .connected = connectionState,
           !selectedMachineNeedsHostThreadCatalogRefresh,
           entries.contains(where: { $0.provenance == .liveAppServer }) {
            return .liveAppServer
        }
        return .cachedHostCatalog
    }

    public var selectedMachineHostThreadCatalogObservedAt: Date? {
        selectedMachineHostThreadCatalogEntries.map(\.observedAt).max()
    }

    private var runtimeSnapshot: RuntimePrioritySnapshot? {
        guard let machine = selectedMachine else {
            return nil
        }
        let diagnostics = runtimeCapabilityDiagnostics ?? baseCapabilityDiagnostics
        let companionRoute = machine.route(for: .companionDirect)
        let evaluations = routeEvaluations
        let sameLANReady = evaluations.first(where: { $0.route.kind == .localLAN })?.isEligible ?? false
        let externalReady = evaluations.first(where: { $0.route.kind == .externalTailnet })?.isEligible ?? false

        return RuntimePrioritySnapshot(
            machine: machine,
            embeddedTailnet: embeddedTailnetStatus,
            sameLANReady: sameLANReady,
            externalTailnetReady: externalReady,
            sshBootstrap: SSHBootstrapStatus(
                remoteLoginEnabled: diagnostics.remoteLoginEnabled,
                credentialsConfigured: diagnostics.authConfigured,
                hostKeyVerified: diagnostics.hostKeyTrusted
            ),
            hostBootstrap: HostBootstrapStatus(
                codexInstalled: diagnostics.codexInstalled,
                stdioAppServerReady: diagnostics.appServerAvailable,
                websocketReuseAvailable: diagnostics.websocketSupported
            ),
            codexTransport: CodexTransportStatus(
                stdioAvailable: diagnostics.appServerAvailable,
                websocketAvailable: diagnostics.websocketSupported
            ),
            companion: CompanionPresenceStatus(
                isInstalled: machine.capabilities.companionInstalled || companionRoute != nil,
                isReachable: companionRoute?.isReachable ?? false,
                supportsEnhancedHostMode: machine.capabilities.companionInstalled
                    || companionRoute?.companionEndpoint != nil
            )
        )
    }

    private var selectedMachineHostThreadCatalogEntries: [HostThreadCatalogEntry] {
        guard let selectedMachineID else {
            return []
        }
        return hostThreadCatalog.filter { $0.machineID == selectedMachineID }
    }

    public var connectionPlan: [ConnectionStep] {
        guard let runtimeSnapshot else {
            return []
        }

        return RuntimePriorityPlanner.plan(for: runtimeSnapshot)
            .filter { Self.embeddedTailnetFeatureAvailable || $0.lane != .embeddedTailnet }
            .filter { loopbackUpgradeFeatureAvailable || $0.lane != .sshForwardedLoopbackWebSocket }
    }

    public var routeEvaluations: [RouteEvaluation] {
        guard let machine = selectedMachine else {
            return []
        }

        return routeEvaluations(for: machine)
    }

    public var highlightedRoutes: [RouteRecord] {
        routeEvaluations.map(\.route)
    }

    public var recommendedRoute: RouteRecord? {
        routeEvaluations.first(where: \.isRecommended)?.route
    }

    public func routeEvaluations(for machine: MachineRecord) -> [RouteEvaluation] {
        let latestSession = recentSessions
            .filter { $0.machineID == machine.id }
            .max(by: { $0.lastOpenedAt < $1.lastOpenedAt })
        let activeRouteID = activeSession?.machineID == machine.id ? activeSession?.routeID : nil

        return RouteEvaluationPlanner.evaluateRoutes(
            for: machine,
            lastKnownRouteKind: latestSession?.lastKnownRouteKind,
            activeRouteID: activeRouteID,
            externalTailnetAppInstalled: externalTailnetAppInstalled,
            allowsNearbyNetworkRoutes: allowsNearbyNetworkRoutes
        )
    }

    public func recommendedRoute(for machine: MachineRecord) -> RouteRecord? {
        routeEvaluations(for: machine).first(where: \.isRecommended)?.route
    }

    private func defaultSessionSeedRoute(
        for machine: MachineRecord,
        explicitRouteID: RouteRecord.ID? = nil
    ) -> RouteRecord? {
        machine.route(id: explicitRouteID)
            ?? recommendedRoute(for: machine)
            ?? machine.preferredRoute
    }

    public func connectionSetupStatus(for machine: MachineRecord) -> MachineSetupStatus {
        let directEndpointReadiness = directWebSocketReadiness(for: machine)
        let route = directEndpointReadiness.isReady ? directEndpointReadiness.route : sshBootstrapRoute(for: machine)
        let hasDetectedRoute = !machine.routes.isEmpty
        let accountReady = directEndpointReadiness.isReady || sshUsername(for: machine, route: route) != nil
        let sshAccessReady = accountReady
            && (directEndpointReadiness.isReady
                || machine.credentialRef != nil
                || usesLocalhostTestingCredentialAutoload(for: machine))
        let trustReady = accountReady
            && (directEndpointReadiness.isReady || route.flatMap(hostValidationPolicy(for:)) != nil)

        let completedStepCount = [
            hasDetectedRoute,
            accountReady,
            sshAccessReady,
            trustReady,
        ]
        .filter { $0 }
        .count

        let nextStep: (title: String?, detail: String?) = {
            if !hasDetectedRoute {
                return (
                    "Find this Mac",
                    "Add a nearby or manual way to connect before this iPhone can reconnect."
                )
            }
            if !accountReady {
                return (
                    "Choose Mac account",
                    "Pick the macOS username this iPhone should use on \(machine.alias)."
                )
            }
            if !sshAccessReady {
                return (
                    "Set up SSH access",
                    missingSSHCredentialGuidance(for: machine, route: route)
                )
            }
            if !trustReady {
                return (
                    "Verify Mac fingerprint",
                    route.map { route in
                        if let guidance = selectedRouteScannedHostKeyGuidance,
                           selectedMachineID == machine.id {
                            return guidance
                        }
                        return "Trust the SSH fingerprint for \(route.label) before reconnecting."
                    } ?? "Trust the SSH fingerprint for the route you plan to use."
                )
            }
            return (nil, nil)
        }()

        return MachineSetupStatus(
            hasDetectedRoute: hasDetectedRoute,
            accountReady: accountReady,
            sshAccessReady: sshAccessReady,
            trustReady: trustReady,
            completedStepCount: completedStepCount,
            requiredStepCount: connectionSetupRequiredStepCount,
            nextStepTitle: nextStep.title,
            nextStepDetail: nextStep.detail
        )
    }

    public var machineTiles: [MachineTileModel] {
        machines.map(MachineDirectoryFeature.tile(for:))
    }

    public var activeSession: SessionRecord? {
        guard let machine = selectedMachine else {
            return nil
        }

        if let activeSessionID,
           let selectedSession = recentSessions.first(where: {
               $0.id == activeSessionID && $0.machineID == machine.id
           }) {
            return selectedSession
        }

        let machineSessions = recentSessions.filter { $0.machineID == machine.id }
        if let sceneMatch = machineSessions
            .filter({ $0.sceneID == sceneID })
            .max(by: { $0.lastOpenedAt < $1.lastOpenedAt }) {
            return sceneMatch
        }

        let latestOverall = machineSessions.max(by: { $0.lastOpenedAt < $1.lastOpenedAt })
        if let sharedSession = machineSessions
            .filter({ $0.sceneID == nil })
            .max(by: { $0.lastOpenedAt < $1.lastOpenedAt }),
           let latestOverall,
           sharedSession.lastOpenedAt >= latestOverall.lastOpenedAt {
            return sharedSession
        }

        return latestOverall
    }

    public var activeThreadModelLabel: String? {
        if Self.normalizedThreadID(activeSession?.threadID) != nil,
           let threadModel = Self.normalizedModelIdentifier(activeSession?.lastModel) {
            return threadModel
        }
        return Self.normalizedModelIdentifier(selectedModel)
    }

    private var hasActiveExecutionContext: Bool {
        guard let activeSession else {
            return false
        }

        return activeSession.threadID != nil
            || Self.normalizedWorkspaceRoot(activeSession.workspaceRoot) != nil
    }

    private var activeSessionRequiresExplicitThreadSelection: Bool {
        guard let activeSession else {
            return false
        }

        guard activeSession.threadID == nil else {
            return false
        }

        guard let unavailableThreadID = activeSession.unavailableSelectedThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        return !unavailableThreadID.isEmpty
    }

    private var activeUnavailableSelectedThreadID: String? {
        activeSession?.unavailableSelectedThreadID
    }

    public var activeApprovalPolicyLabel: String? {
        guard let authority = activeExecutionProfileState?.profile.approvalPolicy else {
            return hasActiveExecutionContext ? "Approvals: unknown" : nil
        }

        return Self.executionAuthorityLabel(
            prefix: "Approvals",
            authority: authority,
            unsupportedFallback: "unsupported",
            unknownFallback: "unknown"
        )
    }

    public var activeSandboxLabel: String? {
        guard let authority = activeExecutionProfileState?.profile.sandboxMode else {
            return hasActiveExecutionContext ? "Sandbox: unknown" : nil
        }

        return Self.executionAuthorityLabel(
            prefix: "Sandbox",
            authority: authority,
            unsupportedFallback: "unsupported",
            unknownFallback: "unknown"
        )
    }

    public var activeNetworkLabel: String? {
        guard let authority = activeExecutionProfileState?.profile.networkAccess else {
            return nil
        }

        guard let value = authority.effective else {
            return authority.status == .unknown ? "Network: unknown" : nil
        }

        return "Network: \(value ? "on" : "off")"
    }

    public var activeAuthorityStatusLabel: String? {
        guard let state = activeExecutionProfileState else {
            return hasActiveExecutionContext ? "Authority: unknown" : nil
        }

        let statuses: [CodexExecutionValueStatus] = [
            state.profile.approvalPolicy.status,
            state.profile.sandboxMode.status,
            state.profile.networkAccess.status,
            state.profile.writableRoots.status,
            state.profile.extraReadableRoots.status,
            state.profile.readAccess.status
        ]

        if statuses.contains(.unsupported) {
            return "Authority: unsupported"
        }
        if statuses.contains(.constrained) {
            return "Authority: constrained"
        }
        if statuses.contains(.requested) {
            return "Authority: requested"
        }
        if statuses.contains(.unknown) {
            return "Authority: unknown"
        }
        return "Authority: effective"
    }

    public var codexMacHandoffURL: URL? {
        Self.codexDesktopContinuationURL(threadID: resolveThreadID(preferredThreadID: nil))
    }

    public var codexMacThreadHandoffURL: URL? {
        guard let threadID = resolveThreadID(preferredThreadID: nil) else {
            return nil
        }

        return Self.codexThreadHandoffURL(threadID: threadID)
    }

    public var activeTailnetProfile: TailnetProfile? {
        tailnetProfiles.first(where: \.isActive)
            ?? tailnetProfiles.first(where: \.usesEmbeddedNode)
            ?? tailnetProfiles.first
    }

    public var threadFeatureState: ThreadFeatureState {
        ThreadFeatureState(
            threadID: activeSession?.threadID,
            routeLabel: routeEvaluations.first(where: \.isActive)?.route.kind.title
                ?? recommendedRoute?.kind.title
                ?? "No route",
            queuedPromptCount: pendingPrompts.count,
            isStreaming: activeTurnID != nil,
            lastTurnSummary: activeSession?.lastTurn?.summary,
            parallelAgentMode: selectedParallelAgentMode,
            parallelAgentCapability: supportsProtocolNativeParallelAgents ? .protocolNative : .clientOrchestratedOnly,
            activityFlags: threadActivityFlags,
            subagentStatusSummary: subagentActivitySummary
        )
    }

    public var shouldShowTranscriptRestorePlaceholder: Bool {
        guard !isDemoModeEnabled,
              isRestoringActiveTranscript,
              let activeThreadID = activeSession?.threadID else {
            return false
        }

        return displayedTranscriptThreadID != activeThreadID
    }

    public var reviewState: WorkspaceReviewState {
        WorkspaceReviewState(
            summary: workspaceSummary,
            preview: revertPreview,
            failureSummary: workspaceFailureSummary
        )
    }

    private static func humanizedWorkspaceFailureSummary(from detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Couldn't refresh the workspace from the Mac."
        }

        let normalized = trimmed.lowercased()
        if normalized.contains("not a git repository") {
            return "This folder is not a git repository, so workspace review is unavailable."
        }
        if normalized.contains("no such file or directory") {
            return "This folder is no longer available on the Mac."
        }
        if normalized.contains("safe lane") {
            return "Workspace review requires an SSH-backed session."
        }

        return "Couldn't refresh the workspace from the Mac."
    }

    public var capabilityReport: HostCapabilityReport {
        HostCapabilityProbe.assess(runtimeCapabilityDiagnostics ?? baseCapabilityDiagnostics)
    }

    public var connectionDebugStatusLabel: String {
        let machineAlias = selectedMachine?.alias ?? "none"
        let route = selectedBootstrapRoute
        let routeReadiness = selectedBootstrapRouteReadiness
        let endpoint = routeReadiness.endpoint
        let username = routeReadiness.username
        let candidateReady = routeReadiness.isReady
        let connectionLabel: String = switch connectionState {
        case .connected:
            "connected"
        case .connecting:
            "connecting"
        case .disconnected:
            "disconnected"
        case .failed:
            "failed"
        }
        let routeLabel = route.map { route in
            "\(route.kind.rawValue):\(route.health.rawValue):reachable=\(route.isReachable)"
        } ?? "none"
        let pendingHostKeyLabel = pendingScannedHostKey == nil ? "false" : "true"
        let pendingHostKeyRouteMatch = route.map { pendingScannedHostKeyRouteID == $0.id } ?? false
        let recommendedLabel = recommendedRoute.map { route in
            "\(route.kind.rawValue):\(route.health.rawValue)"
        } ?? "none"
        let activeThreadID = activeSession?.threadID ?? "none"
        let errorSummary: String = {
            if case let .failed(detail) = connectionState {
                return detail.replacingOccurrences(of: "\n", with: " ")
            }
            return "none"
        }()
        let tailnetErrorSummary = embeddedTailnetStatus.lastErrorSummary?
            .replacingOccurrences(of: "\n", with: " ")
            ?? "none"
        let activeTailnetProfile = tailnetProfiles.first(where: \.isActive)
        let tailnetAuthKeyPresent = Self.trimmedUITestEnvironmentValue("COTG_EMBEDDED_TAILNET_AUTH_KEY") != nil
        let tailnetProfileAuthRecorded = activeTailnetProfile?.lastAuthenticatedAt != nil

        return "connection=\(connectionLabel);machine=\(machineAlias);routes=\(selectedMachine?.routes.count ?? 0);route=\(routeLabel);recommended=\(recommendedLabel);endpoint=\(endpoint?.host ?? "none"):\(endpoint?.port ?? 0);username=\(username);credentialReady=\(routeReadiness.credentialReady);hostValidationReady=\(routeReadiness.hostValidationReady);pendingHostKey=\(pendingHostKeyLabel);pendingHostKeyRouteMatch=\(pendingHostKeyRouteMatch);candidateReady=\(candidateReady);nearbyRoutes=\(allowsNearbyNetworkRoutes.map(String.init) ?? "unknown");activeThread=\(activeThreadID);externalTailnetAppState=\(externalTailnetAppState.rawValue);tailnetNativeRuntime=\(Self.embeddedTailnetFeatureAvailable);tailnetAuthKeyPresent=\(tailnetAuthKeyPresent);tailnetProfileAuthRecorded=\(tailnetProfileAuthRecorded);tailnetAuth=\(embeddedTailnetStatus.authState.rawValue);tailnetReachable=\(embeddedTailnetStatus.isReachable);tailnetEndpointReady=\(embeddedTailnetDialPlan?.supportsNativeSSHTransport == true);tailnetError=\(tailnetErrorSummary);error=\(errorSummary)"
    }

    public var localNetworkDiscoveryStatusLabel: String {
        localNetworkDiscoveryDebugLabel
    }

    public var connectionFailureSummary: String? {
        guard case let .failed(detail) = connectionState else {
            return nil
        }

        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func presentConnectionSetupNotice(_ text: String) {
        connectionSetupNotice = text
        transcript.append(SessionMessage(role: .system, text: text))
    }

    public var connectionCandidateIsReady: Bool {
        selectedDirectWebSocketReadiness.isReady || selectedBootstrapRouteReadiness.isReady
    }

    public var connectionSetupRequiredStepCount: Int { 4 }

    public var connectionSetupAccountReady: Bool {
        guard selectedMachine != nil else {
            return false
        }

        if selectedDirectWebSocketReadiness.isReady {
            return true
        }

        return sshBootstrapUsername != "Required"
    }

    public var connectionSetupSSHAccessReady: Bool {
        guard let machine = selectedMachine,
              connectionSetupAccountReady else {
            return false
        }

        if selectedDirectWebSocketReadiness.isReady {
            return true
        }

        return machine.credentialRef != nil || usesLocalhostTestingCredentialAutoload(for: machine)
    }

    public var connectionSetupLoginReady: Bool {
        connectionSetupSSHAccessReady
    }

    public var connectionSetupTrustReady: Bool {
        if selectedDirectWebSocketReadiness.isReady {
            return true
        }

        switch sshTrustStatusLabel {
        case "Trusted", "Testing override":
            return true
        default:
            return false
        }
    }

    public var connectionSetupCompletedStepCount: Int {
        [
            selectedMachine?.routes.isEmpty == false,
            connectionSetupAccountReady,
            connectionSetupSSHAccessReady,
            connectionSetupTrustReady,
        ]
        .filter { $0 }
        .count
    }

    public var connectionCandidateStatusDetail: String {
        let directReadiness = selectedDirectWebSocketReadiness
        if let directRoute = directReadiness.route {
            if directReadiness.isReady {
                return routeConnectionReadinessDetail(for: directRoute)
            }
            if !directReadiness.endpointReady {
                return "\(directRoute.label) is saved, but its Codex app-server websocket endpoint is missing."
            }
            if !directReadiness.routeReachable,
               selectedBootstrapRouteReadiness.isReady,
               let fallbackRoute = selectedBootstrapRoute {
                return "\(directRoute.label) is unavailable right now. \(fallbackRoute.label) is ready as the SSH fallback for bootstrap and repair."
            }
        }

        let readiness = selectedBootstrapRouteReadiness

        guard let route = selectedBootstrapRoute else {
            if let directRoute = directReadiness.route {
                return "\(directRoute.label) is saved, but it is not reachable right now."
            }
            return "No healthy route is ready yet."
        }

        if connectionFailureSummary != nil {
            return "\(route.label) is saved, but it is still blocked. Fix the issue below before you rely on it."
        }

        if !readiness.routeEligible {
            if route.requiresNearbyNetworkTransport, allowsNearbyNetworkRoutes == false {
                return "\(route.label) is saved, but it only works while this iPhone is on the same Wi-Fi or nearby network as the Mac. Add a Tailscale or remote SSH fallback before leaving home."
            }

            return "\(route.label) is saved, but it is not available from the current network yet."
        }

        if !readiness.endpointReady {
            return "\(route.label) is saved, but the app still needs a reachable SSH endpoint for it."
        }

        if !readiness.usernameReady {
            return "Set the Mac account username for \(route.label) before reconnecting."
        }

        if !readiness.credentialReady,
           let machine = selectedMachine {
            return missingSSHCredentialGuidance(for: machine, route: route)
        }

        if !readiness.hostValidationReady {
            if let guidance = selectedRouteScannedHostKeyGuidance {
                return guidance
            }
            return "Scan and trust the SSH host key for \(route.label) before reconnecting."
        }

        return routeConnectionReadinessDetail(for: route)
    }

    public var needsLocalNetworkSettingsRepair: Bool {
        guard let summary = connectionFailureSummary else {
            return false
        }

        return summary.localizedCaseInsensitiveContains("allow local network access")
    }

    private var selectedBootstrapRouteReadiness: (
        endpoint: SSHBootstrapEndpoint?,
        endpointReady: Bool,
        username: String,
        usernameReady: Bool,
        credentialReady: Bool,
        hostValidationReady: Bool,
        routeEligible: Bool,
        isReady: Bool
    ) {
        let environment = ProcessInfo.processInfo.environment
        let route = selectedBootstrapRoute
        let routeEvaluation = route.flatMap { route in
            routeEvaluations.first(where: { $0.route.id == route.id })
        }
        let endpoint = route.flatMap { resolvedSSHBootstrapEndpoint(for: $0, environment: environment) }
        let username = selectedMachine.flatMap { sshUsername(for: $0, route: route) } ?? "none"
        let credentialReady: Bool = {
            guard let machine = selectedMachine else {
                return false
            }
            return machine.credentialRef != nil || usesLocalhostTestingCredentialAutoload(for: machine)
        }()
        let hostValidationReady = route.flatMap(hostValidationPolicy(for:)) != nil
        let endpointReady = endpoint != nil
        let usernameReady = username != "none"
        let routeEligible = routeEvaluation?.isEligible ?? false

        return (
            endpoint: endpoint,
            endpointReady: endpointReady,
            username: username,
            usernameReady: usernameReady,
            credentialReady: credentialReady,
            hostValidationReady: hostValidationReady,
            routeEligible: routeEligible,
            isReady: route != nil && routeEligible && endpointReady && usernameReady && credentialReady && hostValidationReady
        )
    }

    private var selectedDirectWebSocketReadiness: (
        route: RouteRecord?,
        endpointReady: Bool,
        routeReachable: Bool,
        isReady: Bool
    ) {
        guard let machine = selectedMachine else {
            return (nil, false, false, false)
        }

        return directWebSocketReadiness(for: machine)
    }

    private var selectedPrimaryConnectionRoute: RouteRecord? {
        if selectedDirectWebSocketReadiness.isReady {
            return selectedDirectWebSocketReadiness.route
        }

        return selectedBootstrapRoute
    }

    private func directWebSocketReadiness(
        for machine: MachineRecord
    ) -> (
        route: RouteRecord?,
        endpointReady: Bool,
        routeReachable: Bool,
        isReady: Bool
    ) {
        guard let route = machine.route(for: .companionDirect) else {
            return (nil, false, false, false)
        }

        let endpointReady = route.companionEndpoint != nil
        let routeReachable = route.isEligibleForTraffic

        return (
            route: route,
            endpointReady: endpointReady,
            routeReachable: routeReachable,
            isReady: endpointReady && routeReachable
        )
    }

    private func routeConnectionReadinessDetail(for route: RouteRecord) -> String {
        switch route.kind {
        case .embeddedTailnet, .externalTailnet:
            return "\(route.label) is ready for away-from-home reconnects."
        case .localLAN:
            return "\(route.label) is ready while you are on the same Wi-Fi as the Mac."
        case .manualSSH:
            return route.requiresNearbyNetworkTransport
                ? "\(route.label) is ready as a direct SSH fallback while you are on the same nearby network as the Mac."
                : "\(route.label) is ready as a direct SSH fallback."
        case .companionDirect:
            return "\(route.label) is ready as the primary Codex app-server websocket lane."
        }
    }

    public var protocolLabel: String {
        switch activeProtocolKind {
        case .stdio:
            "SSH safe lane"
        case .websocket:
            "Loopback websocket"
        case .directEndpoint:
            "Codex WebSocket"
        }
    }

    public var selectedMachineNeedsHostThreadCatalogRefresh: Bool {
        guard let selectedMachineID else {
            return false
        }

        return !refreshedHostThreadCatalogMachineIDs.contains(selectedMachineID)
    }

    public var isFastModeSelected: Bool {
        selectedCollaborationMode == nil
            && selectedReasoningEffort == fastestSupportedReasoningEffort(for: selectedModelDescriptor)
    }

    public var runModeLabel: String {
        switch selectedCollaborationMode {
        case .plan:
            "Plan"
        case .default:
            "Default"
        case nil:
            isFastModeSelected ? "Fast" : "Standard"
        }
    }

    public var selectedReasoningEffortLabel: String {
        Self.reasoningEffortDisplayName(selectedReasoningEffort)
    }

    public var availableReasoningEffortOptions: [CodexModelReasoningOption] {
        let options = selectedModelDescriptor?.supportedReasoningEfforts
        if let options, !options.isEmpty {
            return options.sorted { lhs, rhs in
                Self.reasoningEffortSortRank(lhs.effort) < Self.reasoningEffortSortRank(rhs.effort)
            }
        }

        return CodexReasoningEffort.allCases.map {
            CodexModelReasoningOption(
                effort: $0,
                description: Self.reasoningEffortDisplayName($0)
            )
        }
    }

    public var preferredApprovalPolicyLabel: String {
        Self.approvalPolicyDisplayName(preferredApprovalPolicy)
    }

    public var preferredSandboxModeLabel: String {
        Self.sandboxModeDisplayName(preferredSandboxMode)
    }

    public var parallelAgentModeLabel: String {
        selectedParallelAgentMode.title
    }

    public var parallelAgentCapabilityLabel: String {
        supportsProtocolNativeParallelAgents
            ? ParallelAgentCapability.protocolNative.title
            : ParallelAgentCapability.clientOrchestratedOnly.title
    }

    public var canSelectProtocolNativeParallelAgents: Bool {
        supportsProtocolNativeParallelAgents
    }

    public var showsExternalTailnetStatus: Bool {
        tailnetProfiles.contains(where: { $0.kind == .external })
            || selectedMachine?.routes.contains(where: { $0.kind == .externalTailnet }) == true
    }

    public var externalTailnetAppState: ExternalTailnetAppState {
        guard showsExternalTailnetStatus else {
            return .detectionUnavailable
        }

        guard let installed = externalTailnetAppInstalled else {
            return .checking
        }

        guard installed else {
            return .notInstalled
        }

        if routeEvaluations.contains(where: { $0.route.kind == .externalTailnet && $0.isEligible }) {
            return .installedReady
        }

        return .installedUnavailable
    }

    public var externalTailnetAppStatusLabel: String {
        externalTailnetAppState.title
    }

    public var networkProxyStatusLabel: String {
        networkProxyDiagnostics.statusLabel(for: selectedPrimaryConnectionRoute?.kind ?? recommendedRoute?.kind)
    }

    public var networkProxyDetail: String {
        networkProxyDiagnostics.detail(for: selectedPrimaryConnectionRoute?.kind ?? recommendedRoute?.kind)
    }

    public var embeddedTailnetTrafficReadinessLabel: String {
        switch embeddedTailnetStatus.authState {
        case .signedOut:
            return "Sign in required"
        case .authenticating:
            return "Authentication in progress"
        case .authenticated:
            return embeddedTailnetStatus.isReachable ? "Traffic-ready" : "Authenticated, waiting for SOCKS5 bootstrap"
        case .blocked:
            return "Blocked"
        }
    }

    public var embeddedTailnetTrafficReadinessDetail: String? {
        if networkProxyDiagnostics.tailnetRisk {
            return "A system proxy or VPN is active without an explicit tailnet bypass. Bypass localhost, private ranges, 100.64.0.0/10, and *.ts.net traffic before judging embedded tailnet health."
        }

        if let summary = embeddedTailnetStatus.lastErrorSummary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary
        }

        switch embeddedTailnetStatus.authState {
        case .signedOut:
            return "Sign in to authenticate the active embedded tailnet profile."
        case .authenticating:
            return "Complete the control-server login flow before the route can carry traffic."
        case .authenticated:
            return embeddedTailnetStatus.isReachable ? "The embedded route is ready to carry SSH traffic." : "The active profile is authenticated, but this build still lacks a live SOCKS5 bootstrap endpoint from the embedded native runtime."
        case .blocked:
            return "Resolve the embedded tailnet error before this route can be recommended."
        }
    }

    public var workspaceWarningText: String {
        WorkspaceReviewFeature.warningText(for: reviewState)
    }

    public var canAttemptLoopbackUpgrade: Bool {
        guard loopbackUpgradeFeatureAvailable,
              case .connected = connectionState,
              activeProtocolKind == .stdio,
              activeTurnID == nil,
              selectedMachine != nil,
              activeSession?.threadID != nil else {
            return false
        }

        return capabilityReport.canUseOptimizationLane
    }

    public var canReturnToSafeLane: Bool {
        guard case .connected = connectionState else {
            return false
        }

        return activeProtocolKind == .websocket
    }

    public var canInterruptTurn: Bool {
        activeTurnID != nil && resolveThreadID(preferredThreadID: nil) != nil
    }

    public var canSteerTurn: Bool {
        canInterruptTurn && !steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func setDemoModeEnabled(_ enabled: Bool) {
        let launchRequested = ProcessInfo.processInfo.environment[AppDemoScenario.launchEnvironmentKey] == "1"
        guard enabled != isDemoModeEnabled || (enabled && launchRequested && demoScenario == nil) else {
            return
        }

        Self.setStoredDemoModeEnabled(enabled)
        isDemoModeEnabled = enabled
        pendingTurnRequests.removeAll()
        resetClientSubagentPlan()
        activeTurnID = nil

        if enabled {
            let scenario = AppDemoScenario.make(sceneID: sceneID)
            demoScenario = scenario
            applyDemoModeScenario(scenario, restoreSelection: true)
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Reviewer demo mode is on. Live Macs, SSH, and tailnet routes stay untouched until you turn demo mode off."
                )
            )
        } else {
            demoScenario = nil
            connectionState = .disconnected
            transcript = []
            activeSessionID = nil
            displayedTranscriptThreadID = nil
            isRestoringActiveTranscript = false
            workspaceSummary = nil
            workspaceFailureSummary = nil
            worktrees = []
            revertPreview = nil
            composerState = ComposerFeatureState()
            syncSnapshot = SyncSnapshot(status: .idle)
            Task {
                let launchContext = await self.restorePersistedState()
                if let restoredID = launchContext.selectedMachineID {
                    self.select(machineID: restoredID)
                }
            }
        }
    }

    public func selectModel(_ descriptor: CodexModelDescriptor) {
        let preserveFastMode = isFastModeSelected
        selectedModel = descriptor.model
        selectedReasoningEffort = preserveFastMode
            ? fastestSupportedReasoningEffort(for: descriptor)
            : supportedReasoningEffort(selectedReasoningEffort, for: descriptor)
        if let machine = selectedMachine,
           let index = recentSessions.firstIndex(where: {
               $0.id == activeSession?.id && $0.machineID == machine.id
           }) {
            recentSessions[index].lastModel = descriptor.model
            recentSessions[index].lastReasoningEffort = Self.reasoningLevel(for: selectedReasoningEffort)
        }
        refreshComposerCapabilities()
        persistStateAsync()
    }

    public func selectReasoningEffort(_ effort: CodexReasoningEffort) {
        selectedReasoningEffort = supportedReasoningEffort(effort, for: selectedModelDescriptor)
        recordPendingInitialReasoningEffortOverride(selectedReasoningEffort)
        persistStateAsync()
    }

    public func setPreferredApprovalPolicy(_ policy: String?) {
        let normalized = Self.normalizedExecutionPreference(policy)
        guard preferredApprovalPolicy != normalized else {
            return
        }

        preferredApprovalPolicy = normalized
        recordPendingInitialApprovalPolicyOverride(normalized)
        syncActiveExecutionProfileWithPreferredDefaults()
        persistStateAsync()
    }

    public func setPreferredSandboxMode(_ mode: CodexSandboxMode?) {
        guard preferredSandboxMode != mode else {
            return
        }

        preferredSandboxMode = mode
        recordPendingInitialSandboxModeOverride(mode)
        syncActiveExecutionProfileWithPreferredDefaults()
        persistStateAsync()
    }

    public func setPrivacyMode(_ mode: AppPrivacyMode) {
        guard privacyMode != mode else {
            return
        }
        privacyMode = mode
        recordPendingInitialPrivacyModeOverride(mode)
        persistStateAsync()
    }

    public func selectFastMode() {
        selectedCollaborationMode = nil
        selectedReasoningEffort = fastestSupportedReasoningEffort(for: selectedModelDescriptor)
        persistStateAsync()
    }

    public func selectStandardMode() {
        selectedCollaborationMode = nil
        selectedReasoningEffort = selectedModelDescriptor?.defaultReasoningEffort ?? .medium
        persistStateAsync()
    }

    public func selectPlanMode() {
        selectedCollaborationMode = .plan
        selectedReasoningEffort = supportedReasoningEffort(selectedReasoningEffort, for: selectedModelDescriptor)
        persistStateAsync()
    }

    public func selectDefaultCollaborationMode() {
        selectedCollaborationMode = .default
        selectedReasoningEffort = supportedReasoningEffort(selectedReasoningEffort, for: selectedModelDescriptor)
        persistStateAsync()
    }

    public func selectParallelAgentMode(_ mode: ParallelAgentMode) {
        if mode == .protocolNative && !supportsProtocolNativeParallelAgents {
            selectedParallelAgentMode = .clientOrchestrated
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Protocol-native subagents are not available in this build. Staying on client-orchestrated parallel agents."
                )
            )
            return
        }

        selectedParallelAgentMode = mode
        switch mode {
        case .off:
            resetClientSubagentPlan()
            break
        case .clientOrchestrated:
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Parallel-agent mode is now client-orchestrated. Supply a bullet list to split work into tracked subtasks; the app will queue and summarize them because this transport does not expose native subagent controls."
                )
            )
        case .protocolNative:
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Protocol-native parallel agents are enabled."
                )
            )
        }
    }

    public var selectedBootstrapRoute: RouteRecord? {
        guard let machine = selectedMachine else {
            return nil
        }

        return sshBootstrapRoute(for: machine)
    }

    public var sshTrustStatusLabel: String {
        guard let route = selectedBootstrapRoute else {
            return "Unavailable"
        }

        if pendingScannedHostKeyRouteID == route.id, pendingScannedHostKey != nil {
            return "Review scanned key"
        }

        if route.trustState == .trusted, route.trustedOpenSSHPublicKey != nil {
            return "Trusted"
        }

        if route.trustState == .mismatch {
            return "Mismatch"
        }

        if usesLocalhostTestingHostValidationOverride(for: route) {
            return "Testing override"
        }

        return "Needs trust"
    }

    public var sshCredentialStatusLabel: String {
        if let credential = selectedMachine?.credentialRef {
            return credential.label
        }

        if let machine = selectedMachine,
           usesLocalhostTestingCredentialAutoload(for: machine) {
            return "Localhost test key available"
        }

        return "Missing"
    }

    public var storedTrustedHostKeyFingerprint: String? {
        selectedBootstrapRoute?.trustedOpenSSHPublicKey.flatMap(Self.hostKeyFingerprint)
    }

    public var selectedRouteScannedHostKeyGuidance: String? {
        guard let route = selectedBootstrapRoute,
              pendingScannedHostKeyRouteID == route.id,
              pendingScannedHostKey != nil else {
            return nil
        }

        if let fingerprint = pendingScannedHostKeyFingerprint {
            return "Review the scanned fingerprint \(fingerprint) for \(route.label). If it matches your Mac, tap Trust scanned key to finish connecting."
        }

        return "Review the scanned host key for \(route.label). If it matches your Mac, tap Trust scanned key to finish connecting."
    }

    public var sshBootstrapUsername: String {
        guard let machine = selectedMachine else {
            return "Unavailable"
        }

        if selectedBootstrapRouteRequiresExplicitUsername(for: machine) {
            return "Required"
        }

        return sshUsername(for: machine, route: selectedBootstrapRoute) ?? "Required"
    }

    public var canSavePasswordLogin: Bool {
        guard let machine = selectedMachine else {
            return false
        }

        if selectedBootstrapRouteRequiresExplicitUsername(for: machine) {
            return false
        }

        return sshUsername(for: machine, route: selectedBootstrapRoute) != nil
    }

    public var canGenerateSSHKeyLogin: Bool {
        guard let machine = selectedMachine else {
            return false
        }

        if selectedBootstrapRouteRequiresExplicitUsername(for: machine) {
            return false
        }

        return sshUsername(for: machine, route: selectedBootstrapRoute) != nil
    }

    public var canRevealSSHLoginPublicKey: Bool {
        selectedMachine?.credentialRef?.kind == .sshKey
    }

    public func hasRecoverableSavedSSHKeyForSelectedMachine() async -> Bool {
        await savedSSHKeyRecoveryAvailabilityForSelectedMachine() != .none
    }

    public func savedSSHKeyRecoveryAvailabilityForSelectedMachine() async -> SavedSSHKeyRecoveryAvailability {
        guard let machine = selectedMachine,
              let username = sshUsername(for: machine, route: selectedBootstrapRoute) else {
            return .none
        }

        return await savedSSHKeyRecoveryAvailability(for: machine, username: username)
    }

    public var canScanSelectedRouteHostKey: Bool {
        guard let machine = selectedMachine,
              selectedBootstrapRoute != nil else {
            return false
        }

        if selectedBootstrapRouteRequiresExplicitUsername(for: machine) {
            return false
        }

        return sshUsername(for: machine, route: selectedBootstrapRoute) != nil
    }

    public var sshBootstrapUsernameGuidance: String? {
        guard let machine = selectedMachine,
              let route = selectedBootstrapRoute,
              sshUsername(for: machine, route: route) == nil else {
            return nil
        }

        return missingSSHUsernameGuidance(for: route, action: "save credentials or scan host keys")
    }

    public var localhostTestKeyExists: Bool {
        localhostTestKeyData() != nil
    }

    public var canTrustScannedHostKey: Bool {
        guard let route = selectedBootstrapRoute else {
            return false
        }

        return pendingScannedHostKey != nil && pendingScannedHostKeyRouteID == route.id
    }

    public var canClearTrustedHostKey: Bool {
        selectedBootstrapRoute?.trustedOpenSSHPublicKey != nil
    }

    public var canForgetSelectedMachine: Bool {
        !isDemoModeEnabled && selectedMachine != nil
    }

    @discardableResult
    public func restorePersistedState() async -> RestoredLaunchContext {
        if isDemoModeEnabled {
            let scenario = demoScenario ?? AppDemoScenario.make(sceneID: sceneID)
            demoScenario = scenario
            applyDemoModeScenario(scenario, restoreSelection: true)
            completeInitialRestore()
            notificationSnapshot = await notificationCoordinator.snapshot()
            return RestoredLaunchContext(
                selectedMachineID: scenario.snapshot.preferences.preferredMachineID,
                selectedSessionID: restoredSession(from: scenario.snapshot)?.id,
                shouldRestoreDetail: true
            )
        }

        let coordinator = persistenceCoordinator
        let baseSnapshot: MachineDirectorySnapshot

        if let snapshot = try? await coordinator.loadSnapshot() {
            let allowPreviewFixtures = shouldPreservePreviewFixtures(in: snapshot)
            preservesPreviewFixtures = allowPreviewFixtures
            baseSnapshot = Self.sanitizedPersistedSnapshot(
                snapshot,
                allowPreviewFixtures: allowPreviewFixtures
            )
        } else {
            await persistState()
            let fallbackSnapshot = (try? await coordinator.loadSnapshot())
                ?? MachineDirectorySnapshot(
                    machines: machines,
                    tailnetProfiles: tailnetProfiles,
                    recentSessions: recentSessions,
                    hostThreadCatalog: hostThreadCatalog,
                    preferences: UserPreferencesSnapshot(
                        preferredMachineID: selectedMachineID,
                        preferredTailnetProfileID: tailnetProfiles.first(where: \.isActive)?.id
                    )
                )
            let allowPreviewFixtures = shouldPreservePreviewFixtures(in: fallbackSnapshot)
            preservesPreviewFixtures = allowPreviewFixtures
            baseSnapshot = Self.sanitizedPersistedSnapshot(
                fallbackSnapshot,
                allowPreviewFixtures: allowPreviewFixtures
            )
        }

        let resolvedSnapshot = Self.sanitizedPersistedSnapshot(
            (try? await syncCoordinator.stage(baseSnapshot)) ?? baseSnapshot,
            allowPreviewFixtures: preservesPreviewFixtures
        )
        if resolvedSnapshot != baseSnapshot {
            try? await coordinator.saveSnapshot(resolvedSnapshot)
        }

        let launchContext = applyPersistedSnapshot(resolvedSnapshot)
        resetRestoredRuntimeConnectionIfNeeded()
        reapplyPendingInitialPreferenceOverridesIfNeeded()
        await recoverSavedCredentialBindingsIfNeeded()

        syncSnapshot = await syncCoordinator.currentSnapshot()
        notificationSnapshot = await notificationCoordinator.snapshot()
        return launchContext
    }

    public func resetPersistedStateForUITests(
        seedPreviewFixture: Bool = false,
        seedLocalhostLANRoute: Bool = false,
        seedLocalhostManualRoute: Bool = false,
        seedEmbeddedTailnetRoute: Bool = false,
        seedAppStoreSessionFixture: Bool = false
    ) {
        let coordinator = persistenceCoordinator
        let url = coordinator.metadataStoreURL()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: coordinator.syncMirrorStoreURL())
        completeInitialRestore()

        let snapshot: MachineDirectorySnapshot
#if DEBUG
        if seedAppStoreSessionFixture {
            snapshot = Self.appStoreScreenshotSnapshot(sceneID: sceneID)
        } else if seedPreviewFixture {
            snapshot = Self.bootstrapSnapshot(
                sceneID: sceneID,
                machines: nil,
                tailnetProfiles: nil,
                recentSessions: nil,
                bootstrapSnapshot: .preview
            )
        } else if seedLocalhostLANRoute {
            snapshot = Self.bootstrapSnapshot(
                sceneID: sceneID,
                machines: [Self.localhostUITestLocalLANMachine()],
                tailnetProfiles: nil,
                recentSessions: nil,
                bootstrapSnapshot: nil
            )
        } else if seedLocalhostManualRoute {
            snapshot = Self.bootstrapSnapshot(
                sceneID: sceneID,
                machines: [Self.localhostUITestManualRouteMachine()],
                tailnetProfiles: Self.localhostUITestTailnetProfiles(),
                recentSessions: nil,
                bootstrapSnapshot: nil
            )
        } else if seedEmbeddedTailnetRoute {
            snapshot = Self.bootstrapSnapshot(
                sceneID: sceneID,
                machines: [Self.embeddedTailnetUITestMachine()],
                tailnetProfiles: Self.embeddedTailnetUITestProfiles(),
                recentSessions: nil,
                bootstrapSnapshot: nil
            )
        } else {
            snapshot = Self.bootstrapSnapshot(
                sceneID: sceneID,
                machines: nil,
                tailnetProfiles: nil,
                recentSessions: nil,
                bootstrapSnapshot: nil
            )
        }
#else
        snapshot = Self.bootstrapSnapshot(
            sceneID: sceneID,
            machines: nil,
            tailnetProfiles: nil,
            recentSessions: nil,
            bootstrapSnapshot: nil
        )
#endif

        machines = snapshot.machines
        selectedMachineID = snapshot.preferences.preferredMachineID ?? snapshot.machines.first?.id
        recentSessions = snapshot.recentSessions
        hostThreadCatalog = Self.cachedHostThreadCatalog(snapshot.hostThreadCatalog)
        tailnetProfiles = snapshot.tailnetProfiles
        preservesPreviewFixtures = seedPreviewFixture || seedAppStoreSessionFixture
        transcript = []
        activeSessionID = nil
        activeExecutionProfileState = nil
        displayedTranscriptThreadID = nil
        connectionState = .disconnected
        pendingPrompts = []
        activeTurnID = nil
        activeProtocolKind = .stdio
        workspaceSummary = nil
        workspaceFailureSummary = nil
        worktrees = []
        revertPreview = nil
        composerState = ComposerFeatureState()
        discoverySnapshot = nil
        localNetworkScanStatus = .idle
        nearbyDiscoveryResults = []
        localNetworkDiscoveryDebugLabel = "status=idle;machines=0;selected=none;proxyRisk=false"
        syncSnapshot = SyncSnapshot(status: .idle)
        notificationSnapshot = NotificationSnapshot(authorization: .unknown)
        availableModels = []
        selectedModel = nil
        selectedParallelAgentMode = .off
        selectedReasoningEffort = CodexReasoningEffort(
            rawValue: snapshot.preferences.preferredReasoningEffort ?? ""
        ) ?? .medium
        preferredApprovalPolicy = snapshot.preferences.preferredApprovalPolicy
        preferredSandboxMode = snapshot.preferences.preferredSandboxMode.flatMap(CodexSandboxMode.init(rawValue:))
        applyUITestPreferenceOverridesIfNeeded()
        isRestoringActiveTranscript = false
        steerDraft = ""
        pendingApprovalRequest = nil
        embeddedTailnetStatus = Self.provisionalTailnetStatus(
            for: tailnetProfiles.first(where: \.isActive)
        )
        embeddedTailnetDialPlan = nil
        embeddedTailnetBootstrapTask?.cancel()
        embeddedTailnetBootstrapTask = nil
        inFlightEmbeddedTailnetBootstrapRequest = nil
        lastCompletedEmbeddedTailnetBootstrapRequest = nil
        pendingTailnetAuthTicket = nil
        runtimeCapabilityDiagnostics = nil
        networkProxyDiagnostics = NetworkProxyDiagnosticSnapshot.current()
        connectionSetupNotice = nil
        localNetworkDiscoveryDebugLabel = "status=idle;machines=\(machines.count);selected=\(selectedMachine?.alias ?? "none");proxyRisk=\(networkProxyDiagnostics.discoveryRisk)"
        pendingScannedHostKey = nil
        pendingScannedHostKeyRouteID = nil
        pendingScannedHostKeyFingerprint = nil
        generatedSSHTestPublicKey = nil
        revealedSSHLoginPublicKey = nil
        isRefreshingHostThreadCatalog = false
        lastHostThreadCatalogRefreshAt = nil
        hostThreadCatalogErrorSummary = nil
        hostThreadCatalogDebugSummary = nil
        refreshedHostThreadCatalogMachineIDs.removeAll()
        stdioThreadID = nil
        loopbackThreadID = nil
        directEndpointThreadID = nil
        selectedCollaborationMode = nil
        threadActivityFlags = []
        subagentActivitySummary = nil
        pendingTurnRequests.removeAll()

#if DEBUG
        if seedAppStoreSessionFixture {
            applyAppStoreSessionFixture()
        }
#endif

        scheduleEmbeddedTailnetBootstrap(
            profiles: tailnetProfiles,
            activeProfileID: tailnetProfiles.first(where: \.isActive)?.id,
            persist: false
        )
        applyUITestPendingScannedHostKeySeedIfNeeded()
        applyUITestConnectionFailureSeedIfNeeded()
        applyUITestConnectingRestoreSeedIfNeeded()
        applyUITestPlanMessageSeedIfNeeded()
        applyUITestActivityBurstSeedIfNeeded()
        applyUITestAttachmentHistorySeedIfNeeded()
        applyUITestStructuredPromptSeedIfNeeded()
        applyUITestThreadlessSummarySeedIfNeeded()
        applyUITestBrowserOperationsSeedIfNeeded()
        applyUITestRecoverableSavedSSHKeySeedIfNeeded()
        syncActiveExecutionProfileStateFromCurrentSession()
    }

    public func select(machineID: MachineRecord.ID) {
        let normalizedMachineID = normalizedSelectedMachineID(preferred: machineID)
        if normalizedMachineID == selectedMachineID {
            return
        }

        selectedMachineID = normalizedMachineID
        if let machine = selectedMachine {
            activeSessionID = recentSessions[sessionIndex(for: machine)].id
        } else {
            activeSessionID = nil
        }
        syncActiveExecutionProfileStateFromCurrentSession()
        discoverySnapshot = nil
        localNetworkScanStatus = .idle
        nearbyDiscoveryResults = []
        localNetworkDiscoveryDebugLabel = "status=idle;machines=\(machines.count);selected=\(selectedMachine?.alias ?? "none");proxyRisk=\(networkProxyDiagnostics.discoveryRisk)"
        runtimeCapabilityDiagnostics = nil
        worktrees = []
        connectionSetupNotice = nil
        pendingScannedHostKey = nil
        pendingScannedHostKeyRouteID = nil
        pendingScannedHostKeyFingerprint = nil
        revealedSSHLoginPublicKey = nil
        refreshComposerCapabilities()
        if isDemoModeEnabled {
            applyDemoSessionPresentation(for: activeSession)
            return
        }
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
        Task {
            await refreshDiscoverySnapshot()
        }
    }

    @discardableResult
    public func scanLocalNetwork() -> Task<Void, Never> {
        if isDemoModeEnabled {
            localNetworkScanStatus = .found(totalMachineCount: machines.count, newMachineCount: 0)
            localNetworkDiscoveryDebugLabel = "status=demo;machines=\(machines.count);selected=\(selectedMachine?.alias ?? "none");proxyRisk=false"
            return Task {}
        }

        return Task {
            let wasPrimed = self.localNetworkAccessPrimed
            self.localNetworkAccessPrimed = true
            self.localNetworkScanStatus = .scanning
            self.localNetworkDiscoveryDebugLabel = self.makeLocalNetworkDiscoveryDebugLabel(
                status: "scanning",
                report: nil,
                reachabilitySummary: nil
            )
            var report = await refreshDiscoverySnapshot()
            if !wasPrimed, Self.discoveryReportIsEmpty(report) {
                // The first browse often just primes Local Network access or Bonjour state.
                try? await Task.sleep(for: .milliseconds(350))
                report = await refreshDiscoverySnapshot()
            }

            if Self.discoveryReportIsEmpty(report) {
                self.localNetworkScanStatus = .noResults(proxyRisk: self.networkProxyDiagnostics.discoveryRisk)
            } else {
                self.localNetworkScanStatus = .found(
                    totalMachineCount: self.machines.count,
                    newMachineCount: report.createdMachineIDs.count
                )
            }
            let reachabilitySummary = await self.localNetworkReachabilitySummaryIfNeeded(report: report)
            self.localNetworkDiscoveryDebugLabel = self.makeLocalNetworkDiscoveryDebugLabel(
                status: scanStatusDebugLabel,
                report: report,
                reachabilitySummary: reachabilitySummary
            )
        }
    }

    public func resumeSession(_ sessionID: SessionRecord.ID, reconnect: Bool = true) {
        guard let session = recentSessions.first(where: { $0.id == sessionID }) else {
            return
        }

        if isDemoModeEnabled {
            activateSession(session, reconnect: false)
            return
        }

        let canReuseActiveConnection = reconnect
            && session.threadID != nil
            && selectedMachineID == session.machineID
            && {
                if case .connected = connectionState {
                    return true
                }
                return false
            }()

        activateSession(session, reconnect: reconnect && !canReuseActiveConnection)

        if canReuseActiveConnection {
            beginRestoringActiveTranscript(for: session.threadID)
            Task {
                await switchActiveThreadOnCurrentConnection(session)
            }
        }
    }

    public func canRestoreSessionOnLaunch(_ sessionID: SessionRecord.ID) -> Bool {
        guard let session = recentSessions.first(where: { $0.id == sessionID }) else {
            return false
        }

        return Self.isRestorableLaunchSession(session)
    }

    public func refreshRepoBrowserSessions(limit: Int = 40, fetchAllPages: Bool = true) async {
        guard !isDemoModeEnabled else {
            isRefreshingHostThreadCatalog = false
            hostThreadCatalogErrorSummary = nil
            hostThreadCatalogDebugSummary = nil
            lastHostThreadCatalogRefreshAt = .now
            return
        }

        guard !repoBrowserRefreshInFlight,
              let machine = selectedMachine,
              case .connected = connectionState else {
            return
        }

        repoBrowserRefreshInFlight = true
        isRefreshingHostThreadCatalog = true
        hostThreadCatalogErrorSummary = nil
        hostThreadCatalogDebugSummary = nil
        defer {
            repoBrowserRefreshInFlight = false
            isRefreshingHostThreadCatalog = false
        }

        do {
            let threads: [CodexThreadSummary]
            let provenanceByThreadID: [String: HostThreadCatalogProvenance]
            let observedAt = Date.now
            if fetchAllPages {
                var collectedProvenanceByThreadID: [String: HostThreadCatalogProvenance] = [:]
                threads = try await Self.paginateThreadList { cursor in
                    let pageResult = try await preferredHostThreadCatalogPage(limit: limit, cursor: cursor)
                    collectedProvenanceByThreadID.merge(pageResult.provenanceByThreadID) { existing, incoming in
                        existing == .sqliteRepaired ? existing : incoming
                    }
                    return pageResult.page
                }
                provenanceByThreadID = collectedProvenanceByThreadID
            } else {
                let firstPage = try await preferredHostThreadCatalogPage(limit: limit, cursor: nil)
                threads = firstPage.page.threads
                provenanceByThreadID = firstPage.provenanceByThreadID
            }
            self.replaceHostThreadCatalogEntries(
                threads,
                machine: machine,
                provenanceByThreadID: provenanceByThreadID,
                observedAt: observedAt
            )

            let refreshedAt = Date.now
            refreshedHostThreadCatalogMachineIDs.insert(machine.id)
            lastHostThreadCatalogRefreshAt = refreshedAt
            hostThreadCatalogErrorSummary = nil
            hostThreadCatalogDebugSummary = await hostThreadCatalogDebugSummary(
                for: threads,
                limit: limit,
                machine: machine
            )

            if fetchAllPages,
               let activeThread = activeSession?.threadID,
               threads.contains(where: { $0.id == activeThread }) {
                await refreshCurrentThreadHistoryIfPossible()
            }
        } catch {
            hostThreadCatalogErrorSummary = error.localizedDescription
            hostThreadCatalogDebugSummary = nil
            Self.logger.warning("Repo browser refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func hostThreadCatalogDebugSummary(
        for threads: [CodexThreadSummary],
        limit: Int,
        machine: MachineRecord
    ) async -> String? {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1" else {
            return nil
        }

        switch activeProtocolKind {
        case .stdio:
            var fragments = [
                "liveCount=\(threads.count)"
            ]
            if let firstThreadID = threads.first?.id {
                fragments.append("firstThread=\(firstThreadID)")
                let projectedEntries = threads.compactMap { thread in
                    hostThreadCatalogEntry(from: thread, machineID: machine.id)
                }
                fragments.append("projectedCount=\(projectedEntries.count)")
                if let rejectedThread = threads.first(where: {
                    hostThreadCatalogEntry(from: $0, machineID: machine.id) == nil
                }) {
                    let rejectedCWD = rejectedThread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
                    fragments.append("rejectedThread=\(rejectedThread.id)")
                    fragments.append("rejectedCWD=\(rejectedCWD.isEmpty ? "empty" : rejectedCWD)")
                }
                return fragments.joined(separator: ";")
            }

            do {
                let stateStorePage = try await safeLaneClient.listThreadsFromStateStore(limit: min(limit, 5))
                fragments.append("stateCount=\(stateStorePage.threads.count)")
                if let stateStoreDebug = try? await safeLaneClient.debugStateStoreLocation() {
                    fragments.append(stateStoreDebug)
                }
            } catch {
                fragments.append("stateDebugError=\(error.localizedDescription)")
            }
            return fragments.joined(separator: ";")
        case .websocket, .directEndpoint:
            return "liveCount=\(threads.count)"
        }
    }

    private func preferredHostThreadCatalogPage(
        limit: Int,
        cursor: String?
    ) async throws -> AppHostThreadCatalogPageResult {
        switch activeProtocolKind {
        case .stdio:
            let livePage = try await safeLaneClient.listThreads(
                limit: limit,
                cursor: cursor,
                sortKey: "updated_at"
            )
            return try await repairedHostThreadCatalogPageIfNeeded(livePage)
        case .websocket, .directEndpoint:
            return try await fallbackHostThreadCatalogPage(limit: limit, cursor: cursor)
        }
    }

    private func repairedHostThreadCatalogPageIfNeeded(
        _ livePage: CodexThreadListPage
    ) async throws -> AppHostThreadCatalogPageResult {
        let unresolvedThreadIDs = Set(
            livePage.threads.compactMap { thread in
                Self.normalizedWorkspaceRoot(thread.cwd) == nil ? thread.id : nil
            }
        )
        guard !unresolvedThreadIDs.isEmpty else {
            return AppHostThreadCatalogPageResult(
                page: livePage,
                provenanceByThreadID: Dictionary(
                    uniqueKeysWithValues: livePage.threads.map { ($0.id, .liveAppServer) }
                )
            )
        }

        var cursor: String?
        var repairedWorkspaceRoots: [String: String] = [:]

        repeat {
            let stateStorePage = try await safeLaneClient.listThreadsFromStateStore(
                limit: max(livePage.threads.count, 50),
                cursor: cursor
            )
            repairedWorkspaceRoots.merge(
                AppHostThreadCatalogCoordinator.workspaceRootLookup(
                    for: stateStorePage.threads,
                    matching: unresolvedThreadIDs,
                    normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:)
                )
            ) { existing, _ in
                existing
            }
            cursor = stateStorePage.nextCursor
        } while cursor != nil && repairedWorkspaceRoots.count < unresolvedThreadIDs.count

        return AppHostThreadCatalogCoordinator.repairingMissingWorkspaceRoots(
            in: livePage,
            using: repairedWorkspaceRoots,
            normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:)
        )
    }

    private func fallbackHostThreadCatalogPage(
        limit: Int,
        cursor: String?
    ) async throws -> AppHostThreadCatalogPageResult {
        switch activeProtocolKind {
        case .stdio:
            throw CodexSSHError.notConnected
        case .websocket, .directEndpoint:
            let page = try await loopbackClient.listThreads(
                limit: limit,
                cursor: cursor,
                sortKey: "updated_at"
            )
            return AppHostThreadCatalogPageResult(
                page: page,
                provenanceByThreadID: Dictionary(
                    uniqueKeysWithValues: page.threads.map { ($0.id, .liveAppServer) }
                )
            )
        }
    }

    static func paginateThreadList(
        fetchPage: (String?) async throws -> CodexThreadListPage,
        onPage: (([CodexThreadSummary]) -> Void)? = nil
    ) async throws -> [CodexThreadSummary] {
        var collectedThreads: [CodexThreadSummary] = []
        var seenCursors = Set<String>()
        var cursor: String?

        repeat {
            let requestedCursor = cursor
            let page = try await fetchPage(requestedCursor)
            collectedThreads.append(contentsOf: page.threads)
            onPage?(collectedThreads)

            let nextCursor = normalizedPaginationCursor(page.nextCursor)
            if let nextCursor {
                let inserted = seenCursors.insert(nextCursor).inserted
                guard nextCursor != requestedCursor, inserted else {
                    throw CodexSSHError.invalidResponse(
                        "thread/list pagination returned a repeated cursor."
                    )
                }
            }

            cursor = nextCursor
        } while cursor != nil

        return collectedThreads
    }

    static func repairingMissingWorkspaceRoots(
        in livePage: CodexThreadListPage,
        using workspaceRootsByThreadID: [String: String]
    ) -> CodexThreadListPage {
        AppHostThreadCatalogCoordinator.repairingMissingWorkspaceRoots(
            in: livePage,
            using: workspaceRootsByThreadID,
            normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:)
        ).page
    }

    private static func workspaceRootLookup(
        for threads: [CodexThreadSummary],
        matching threadIDs: Set<String>
    ) -> [String: String] {
        AppHostThreadCatalogCoordinator.workspaceRootLookup(
            for: threads,
            matching: threadIDs,
            normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:)
        )
    }

    @discardableResult
    public func resumeHostThreadCatalogEntry(
        _ entry: HostThreadCatalogEntry,
        reconnect: Bool = true
    ) -> SessionRecord.ID? {
        guard let machine = machines.first(where: { $0.id == entry.machineID }) else {
            return nil
        }

        let seededExecutionProfileState = seededExecutionProfileState(for: machine.id)
        let sessionID: SessionRecord.ID
        if let existingSession = recentSessions.first(where: {
            $0.machineID == entry.machineID && $0.threadID == entry.id
        }) {
            sessionID = existingSession.id
            updateSessionFromHostThreadCatalog(
                entry,
                sessionID: existingSession.id,
                fallbackExecutionProfileState: seededExecutionProfileState
            )
        } else {
            let route = defaultSessionSeedRoute(for: machine)
            let threadDisplayTitle = entry.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let session = SessionRecord(
                sceneID: sceneID,
                machineID: entry.machineID,
                routeID: route?.id,
                threadID: entry.id,
                threadDisplayTitle: threadDisplayTitle?.isEmpty == false ? threadDisplayTitle : nil,
                workspaceRoot: entry.workspaceRoot,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: route?.kind,
                lastKnownBootstrap: route?.kind == .companionDirect ? .companionManaged : .standardSSH,
                lastTurn: RecentTurnMetadata(
                    turnID: "catalog-\(entry.id)",
                    summary: entry.name ?? entry.preview,
                    completedAt: entry.updatedAt
                ),
                lastOpenedAt: entry.updatedAt,
                transportState: .disconnected,
                executionProfileState: seededExecutionProfileState
            )
            recentSessions.append(session)
            sessionID = session.id
        }

        if selectedMachineID != entry.machineID {
            select(machineID: entry.machineID)
        }

        if let index = recentSessions.firstIndex(where: { $0.id == sessionID }) {
            recentSessions[index].isArchived = false
        }
        resumeSession(sessionID, reconnect: reconnect)
        return sessionID
    }

    @discardableResult
    public func prepareNewSession(
        machineID: MachineRecord.ID? = nil,
        workspaceRoot: String? = nil,
        routeID: RouteRecord.ID? = nil,
        reconnect: Bool = true
    ) -> SessionRecord.ID? {
        let targetMachineID = machineID ?? selectedMachineID
        guard let targetMachineID,
              let machine = machines.first(where: { $0.id == targetMachineID }) else {
            return nil
        }

        let resolvedWorkspace = Self.normalizedWorkspaceRoot(workspaceRoot)
        let selectedRoute = defaultSessionSeedRoute(
            for: machine,
            explicitRouteID: routeID
        )
        let reasoningLevel: ReasoningEffortLevel
        switch selectedReasoningEffort {
        case .none, .minimal, .low:
            reasoningLevel = .low
        case .medium:
            reasoningLevel = .medium
        case .high, .xhigh:
            reasoningLevel = .high
        }
        let executionProfileState = seededExecutionProfileState(for: machine.id)
        let session = SessionRecord(
            sceneID: sceneID,
            machineID: machine.id,
            routeID: selectedRoute?.id,
            threadID: nil,
            workspaceRoot: resolvedWorkspace,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: selectedRoute?.kind,
            lastKnownBootstrap: selectedRoute?.kind == .companionDirect ? .companionManaged : .standardSSH,
            lastModel: selectedModel,
            lastReasoningEffort: reasoningLevel,
            lastMode: Self.workspaceMode(for: resolvedWorkspace),
            lastOpenedAt: .now,
            transportState: .disconnected,
            executionProfileState: executionProfileState
        )

        recentSessions.append(session)
        transcript = []
        displayedTranscriptThreadID = nil
        isRestoringActiveTranscript = false
        connectionState = .disconnected
        activeTurnID = nil
        pendingApprovalRequest = nil
        pendingPrompts = []
        steerDraft = ""
        activateSession(session, reconnect: false)
        transcript.append(
            SessionMessage(
                role: .system,
                text: "Prepared a new Codex thread\(session.workspaceRoot.map { " in \($0)" } ?? "")."
            )
        )

        if reconnect {
            connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
        }

        return session.id
    }

    @discardableResult
    public func prepareNewSession(
        machineID: MachineRecord.ID? = nil,
        workspaceRoot: String? = nil,
        reconnect: Bool = true
    ) -> SessionRecord.ID? {
        prepareNewSession(
            machineID: machineID,
            workspaceRoot: workspaceRoot,
            routeID: nil,
            reconnect: reconnect
        )
    }

    public func startNewSession(
        machineID: MachineRecord.ID? = nil,
        workspaceRoot: String? = nil,
        reconnect: Bool = true
    ) {
        _ = prepareNewSession(
            machineID: machineID,
            workspaceRoot: workspaceRoot,
            reconnect: reconnect
        )
    }

    public func prepareCodexWorkspaceForSelectedMachineIfNeeded() {
        guard !isDemoModeEnabled,
              let machine = selectedMachine,
              activeSession?.threadID == nil,
              Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot) == nil else {
            return
        }

        let workspaceRoot = connectionBootstrapWorkspaceRoot()
        guard let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(workspaceRoot) else {
            return
        }

        let index = activeSessionIndex(for: machine)
        let route = defaultSessionSeedRoute(for: machine)
        recentSessions[index].sceneID = sceneID
        recentSessions[index].routeID = recentSessions[index].routeID ?? route?.id
        recentSessions[index].workspaceRoot = normalizedWorkspaceRoot
        recentSessions[index].lastMode = Self.workspaceMode(for: normalizedWorkspaceRoot)
        recentSessions[index].lastKnownRouteKind = recentSessions[index].lastKnownRouteKind ?? route?.kind
        recentSessions[index].lastOpenedAt = .now
        activeSessionID = recentSessions[index].id
        activeExecutionProfileState = recentSessions[index].executionProfileState

        transcript = []
        hiddenTranscriptMessageCount = 0
        activeTranscriptSnapshot = nil
        prefetchedTranscriptHistory = []
        revealedEarlierTranscriptMessageCount = 0
        displayedTranscriptThreadID = nil
        lastObservedActiveThreadSummary = nil
        activeTurnID = nil
        pendingApprovalRequest = nil
        isRestoringActiveTranscript = false
        workspaceSummary = nil
        workspaceFailureSummary = nil
        worktrees = []
        revertPreview = nil
        threadActivityFlags = []
        subagentActivitySummary = ClientOrchestratedSubagentPlanner.summary(for: clientSubagentTasks)
        syncActiveExecutionProfileWithPreferredDefaults()
        refreshComposerCapabilities()
        persistStateAsync()
    }

    public func setHostThreadArchived(
        _ entry: HostThreadCatalogEntry,
        archived: Bool
    ) {
        let sessionID: SessionRecord.ID
        if let existingSession = recentSessions.first(where: {
            $0.machineID == entry.machineID && $0.threadID == entry.id
        }) {
            sessionID = existingSession.id
            updateSessionFromHostThreadCatalog(entry, sessionID: existingSession.id)
        } else if let machine = machines.first(where: { $0.id == entry.machineID }) {
            let route = defaultSessionSeedRoute(for: machine)
            let threadDisplayTitle = entry.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let session = SessionRecord(
                sceneID: nil,
                machineID: entry.machineID,
                routeID: route?.id,
                threadID: entry.id,
                threadDisplayTitle: threadDisplayTitle?.isEmpty == false ? threadDisplayTitle : nil,
                workspaceRoot: entry.workspaceRoot,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: route?.kind,
                lastKnownBootstrap: route?.kind == .companionDirect ? .companionManaged : .standardSSH,
                lastModel: Self.normalizedModelIdentifier(entry.modelProvider),
                lastReasoningEffort: .medium,
                lastMode: Self.workspaceMode(for: entry.workspaceRoot),
                lastTurn: RecentTurnMetadata(
                    turnID: "catalog-\(entry.id)",
                    summary: entry.name ?? entry.preview,
                    completedAt: entry.updatedAt
                ),
                lastOpenedAt: entry.updatedAt
            )
            recentSessions.append(session)
            sessionID = session.id
        } else {
            return
        }

        guard let index = recentSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        recentSessions[index].isArchived = archived
        if !archived {
            recentSessions[index].sceneID = sceneID
            recentSessions[index].lastOpenedAt = .now
        }

        recentSessions.sort(by: { $0.lastOpenedAt > $1.lastOpenedAt })
        persistStateAsync()
    }

    public var canBrowseWorkspaceDirectories: Bool {
        if isDemoModeEnabled {
            return true
        }

        guard activeProtocolKind != .directEndpoint else {
            return false
        }

        guard case .connected = connectionState else {
            return false
        }

        return selectedMachine != nil
    }

    public func browseWorkspaceDirectories(
        at path: String?
    ) async throws -> WorkspaceDirectoryListing {
        if isDemoModeEnabled {
            return Self.demoWorkspaceDirectoryListing(at: path)
        }

        guard activeProtocolKind != .directEndpoint else {
            throw CodexSSHError.invalidRequest("Directory browsing requires an SSH-backed safe lane.")
        }

        guard case .connected = connectionState else {
            throw CodexSSHError.invalidRequest("Connect to the selected Mac before browsing folders.")
        }

        let currentPath = try await resolvedWorkspaceBrowsePath(for: path)
        let result = try await safeLaneClient.execute(
            command: Self.workspaceDirectoryListCommand(cwd: currentPath)
        )
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(
                result.errorOutput.isEmpty ? result.standardOutput : result.errorOutput
            )
        }

        return Self.parseWorkspaceDirectoryListing(result.standardOutput, currentPath: currentPath)
    }

    public func handleHandoffPayload(
        machineID: MachineRecord.ID,
        threadID: String?,
        protocolKind: CodexProtocolKind?,
        routeKind: MachineRouteKind?,
        workspaceRoot: String?
    ) {
        let matchedSession = recentSessions.first(where: { session in
            session.machineID == machineID
                && threadID != nil
                && session.threadID == threadID
        }) ?? recentSessions
            .filter { $0.machineID == machineID }
            .max(by: { $0.lastOpenedAt < $1.lastOpenedAt })

        guard let session = matchedSession else {
            select(machineID: machineID)
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Received a handoff for \(machineID.uuidString), but no saved session matched yet."
                )
            )
            return
        }

        var updatedSession = session
        updatedSession.threadID = threadID ?? updatedSession.threadID
        updatedSession.lastKnownProtocol = protocolKind ?? updatedSession.lastKnownProtocol
        updatedSession.lastKnownRouteKind = routeKind ?? updatedSession.lastKnownRouteKind
        if let workspaceRoot, !workspaceRoot.isEmpty {
            updatedSession.workspaceRoot = workspaceRoot
        }

        activateSession(updatedSession, reconnect: true)
        transcript.append(
            SessionMessage(
                role: .system,
                text: "Accepted the incoming handoff for \(selectedMachine?.alias ?? "the selected Mac")."
            )
        )
    }

    public func addManualRoute(
        label: String,
        address: String,
        kind: MachineRouteKind = .localLAN,
        usernameHint: String? = nil,
        port: UInt16? = nil,
        onComplete: (@MainActor @Sendable (MachineRecord.ID) -> Void)? = nil
    ) {
        Task {
            do {
                let route = try await discoveryCoordinator.makeManualRoute(
                    from: ManualRouteEntryDraft(
                        label: label,
                        address: address,
                        kind: kind,
                        usernameHint: usernameHint,
                        port: port
                    )
                )
                await MainActor.run {
                    let selectedMachineID: MachineRecord.ID
                    if let machine = self.selectedMachine,
                       let index = self.machines.firstIndex(where: { $0.id == machine.id }) {
                        self.machines[index].routes.append(route)
                        selectedMachineID = self.machines[index].id
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Added manual \(kind.title) route for \(self.machines[index].alias)."
                            )
                        )
                    } else {
                        let newMachine = Self.machineRecordForManualRoute(
                            route,
                            usernameHint: usernameHint
                        )
                        self.machines.append(newMachine)
                        self.selectedMachineID = newMachine.id
                        selectedMachineID = newMachine.id
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Added your first Mac with a \(kind.title.lowercased()) route."
                            )
                        )
                    }
                    persistStateAsync()
                    onComplete?(selectedMachineID)
                }
                _ = await refreshDiscoverySnapshot()
            } catch {
                await MainActor.run {
                    transcript.append(
                        SessionMessage(
                            role: .system,
                            text: error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    public func addManualMachine(
        machineLabel: String? = nil,
        address: String,
        kind: MachineRouteKind = .localLAN,
        usernameHint: String? = nil,
        port: UInt16? = nil,
        onComplete: (@MainActor @Sendable (MachineRecord.ID) -> Void)? = nil
    ) {
        Task {
            do {
                let route = try await discoveryCoordinator.makeManualRoute(
                    from: ManualRouteEntryDraft(
                        label: Self.manualMachineRouteLabel(for: kind),
                        address: address,
                        kind: kind,
                        usernameHint: usernameHint,
                        port: port
                    )
                )

                await MainActor.run {
                    var newMachine = Self.machineRecordForManualRoute(
                        route,
                        usernameHint: usernameHint
                    )
                    if let trimmedMachineLabel = machineLabel?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !trimmedMachineLabel.isEmpty {
                        newMachine.displayName = trimmedMachineLabel
                    }

                    self.machines.append(newMachine)
                    self.selectedMachineID = newMachine.id
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Added \(newMachine.alias) with a \(kind.title.lowercased()) route."
                        )
                    )
                    persistStateAsync()
                    onComplete?(newMachine.id)
                }
            } catch {
                await MainActor.run {
                    transcript.append(
                        SessionMessage(
                            role: .system,
                            text: error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    public func preferRoute(routeID: RouteRecord.ID) {
        guard let machine = selectedMachine,
              let machineIndex = machines.firstIndex(where: { $0.id == machine.id }),
              let routeIndex = machines[machineIndex].routes.firstIndex(where: { $0.id == routeID }) else {
            return
        }

        let route = machines[machineIndex].routes[routeIndex]
        machines[machineIndex].preferredRouteID = routeID
        for index in machines[machineIndex].routes.indices {
            machines[machineIndex].routes[index].isUserPinned = machines[machineIndex].routes[index].id == routeID
        }

        transcript.append(
            SessionMessage(
                role: .system,
                text: "Using \(route.label) as the preferred route for \(machine.alias)."
            )
        )
        persistStateAsync()
    }

    public func scanSelectedRouteHostKey() {
        connectionSetupNotice = nil
        guard let machine = selectedMachine,
              let route = selectedBootstrapRoute else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "No SSH-capable route is selected for host-key scanning."
                )
            )
            return
        }

        guard sshUsername(for: machine, route: route) != nil else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: missingSSHUsernameGuidance(for: route, action: "scan the host key")
                )
            )
            return
        }

        Task {
            do {
                let scannedKey = try await scanHostKey(for: machine, route: route)
                await MainActor.run {
                    self.recordScannedHostKey(scannedKey, routeID: route.id, machineID: machine.id)
                    if route.trustedOpenSSHPublicKey == scannedKey {
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "The scanned SSH host key already matches the trusted key for \(route.label)."
                            )
                        )
                    } else {
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Scanned the SSH host key for \(route.label). If the fingerprint matches your Mac, tap Trust scanned key to finish connecting."
                            )
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Host-key scan failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func trustScannedHostKey() {
        connectionSetupNotice = nil
        guard let machine = selectedMachine,
              let route = selectedBootstrapRoute,
              route.id == pendingScannedHostKeyRouteID,
              let scannedHostKey = pendingScannedHostKey else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Scan the current SSH route before trusting a host key."
                )
            )
            return
        }

        acceptTrustedHostKey(
            scannedHostKey,
            routeID: route.id,
            machineID: machine.id
        )
        transcript.append(
            SessionMessage(
                role: .system,
                text: "Trusted the scanned SSH host key for \(route.label)."
            )
        )
    }

    public func clearTrustedHostKey() {
        guard let machine = selectedMachine,
              let route = selectedBootstrapRoute else {
            return
        }

        updateRoute(routeID: route.id, machineID: machine.id) { updatedRoute in
            updatedRoute.trustState = .unknown
            updatedRoute.trustedOpenSSHPublicKey = nil
        }
        updateMachineFingerprint(machineID: machine.id)
        if pendingScannedHostKeyRouteID == route.id {
            pendingScannedHostKey = nil
            pendingScannedHostKeyRouteID = nil
            pendingScannedHostKeyFingerprint = nil
        }
        persistStateAsync()
        transcript.append(
            SessionMessage(
                role: .system,
                text: "Cleared the trusted SSH host key for \(route.label)."
            )
        )
    }

    public func forgetSelectedMachine() async {
        guard let machine = selectedMachine else {
            return
        }

        let removedMachineID = machine.id
        let removedCredential = machine.credentialRef
        let shouldRemoveCredential = removedCredential.map { credential in
            !machines.contains(where: { $0.id != removedMachineID && $0.credentialRef == credential })
        } ?? false

        if let removedCredential, shouldRemoveCredential {
            do {
                try await secretVault.remove(reference: removedCredential)
            } catch {
                Self.logger.warning(
                    "Failed removing saved credential while forgetting \(machine.alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let removedSessionIDs = Set(
            recentSessions
                .filter { $0.machineID == removedMachineID }
                .map(\.id)
        )

        machines.removeAll { $0.id == removedMachineID }
        recentSessions.removeAll { $0.machineID == removedMachineID }
        hostThreadCatalog.removeAll { $0.machineID == removedMachineID }
        refreshedHostThreadCatalogMachineIDs.remove(removedMachineID)

        selectedMachineID = machines.first?.id
        if let activeSessionID, removedSessionIDs.contains(activeSessionID) {
            self.activeSessionID = nil
        }
        if let selectedMachineID,
           let selectedMachine = machines.first(where: { $0.id == selectedMachineID }) {
            activeSessionID = recentSessions[sessionIndex(for: selectedMachine)].id
        } else {
            activeSessionID = nil
        }

        connectionState = .disconnected
        activeProtocolKind = .stdio
        syncKnownThreadIDs(threadID: nil, replaceAll: true)
        transcript = []
        hiddenTranscriptMessageCount = 0
        activeTranscriptSnapshot = nil
        prefetchedTranscriptHistory = []
        revealedEarlierTranscriptMessageCount = 0
        displayedTranscriptThreadID = nil
        isRestoringActiveTranscript = false
        workspaceSummary = nil
        workspaceFailureSummary = nil
        worktrees = []
        revertPreview = nil
        composerState = ComposerFeatureState()
        composerSendAttemptCount = 0
        pendingPrompts.removeAll()
        pendingTurnRequests.removeAll()
        activeTurnID = nil
        threadActivityFlags = []
        pendingApprovalRequest = nil
        resetClientSubagentPlan()
        discoverySnapshot = nil
        localNetworkScanStatus = .idle
        nearbyDiscoveryResults = []
        localNetworkDiscoveryDebugLabel = "status=idle;machines=\(machines.count);selected=\(selectedMachine?.alias ?? "none");proxyRisk=\(networkProxyDiagnostics.discoveryRisk)"
        runtimeCapabilityDiagnostics = nil
        hostThreadCatalogErrorSummary = nil
        hostThreadCatalogDebugSummary = nil
        isRefreshingHostThreadCatalog = false
        lastObservedActiveThreadSummary = nil
        pendingScannedHostKey = nil
        pendingScannedHostKeyRouteID = nil
        pendingScannedHostKeyFingerprint = nil
        generatedSSHTestPublicKey = nil
        revealedSSHLoginPublicKey = nil
        refreshComposerCapabilities()
        persistStateAsync()

        Task {
            try? await self.safeLaneClient.stopLocalPortForward()
            await self.loopbackClient.disconnect()
        }
    }

    public func generateSSHTestKeyIfMissing() {
        guard let machine = selectedMachine else {
            return
        }

        Task {
            let keyPath = localhostTestKeyPath()
            if FileManager.default.fileExists(atPath: keyPath) {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "The localhost testing key already exists. Load it to use the SSH safe lane."
                        )
                    )
                }
                return
            }

            do {
                let generated = try SSHGeneratedKeyMaterial.generateEd25519(comment: "cotg-localhost-test")
                try generated.privateKeySeed.write(to: URL(fileURLWithPath: keyPath), options: [.atomic])
                let credentialRef: CredentialRef
                if let existingCredential = machine.credentialRef {
                    credentialRef = existingCredential
                } else if let username = self.sshUsername(for: machine, route: self.selectedBootstrapRoute) {
                    credentialRef = testingCredentialReference(username: username)
                } else {
                    await MainActor.run {
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: self.missingSSHUsernameGuidance(
                                    for: self.selectedBootstrapRoute,
                                    action: "generate a localhost testing key"
                                )
                            )
                        )
                    }
                    return
                }
                try await self.secretVault.store(
                    SecretPayload(
                        reference: credentialRef,
                        value: generated.privateKeySeed
                    )
                )

                await MainActor.run {
                    self.assignCredential(credentialRef, to: machine.id, username: credentialRef.username)
                    self.generatedSSHTestPublicKey = generated.openSSHPublicKey
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Generated a clearly marked localhost testing key. Authorize its public key on the host before relying on it for SSH."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Testing key generation failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func loadLocalhostTestCredential() {
        guard let machine = selectedMachine else {
            return
        }

        Task {
            do {
                guard let keyData = localhostTestKeyData() else {
                    throw CodexSSHError.invalidRequest(
                        "The localhost testing key is unavailable in this app runtime."
                    )
                }
                guard let username = sshUsername(for: machine, route: selectedBootstrapRoute) else {
                    throw CodexSSHError.invalidRequest(
                        missingSSHUsernameGuidance(
                            for: selectedBootstrapRoute,
                            action: "load a localhost testing key"
                        )
                    )
                }
                let credentialRef = testingCredentialReference(username: username)
                try await secretVault.store(
                    SecretPayload(
                        reference: credentialRef,
                        value: keyData
                    )
                )

                await MainActor.run {
                    self.assignCredential(credentialRef, to: machine.id, username: credentialRef.username)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Loaded the clearly marked localhost testing key into secure storage for the SSH safe lane."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Localhost testing key load failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func savePasswordCredential(_ password: String) {
        guard let machine = selectedMachine else {
            return
        }

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Enter a password before saving SSH login credentials."
                )
            )
            return
        }

        guard let username = sshUsername(for: machine, route: selectedBootstrapRoute) else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: missingSSHUsernameGuidance(
                        for: selectedBootstrapRoute,
                        action: "save password-backed SSH login credentials"
                    )
                )
            )
            return
        }
        let credentialRef = savedCredentialReference(
            kind: .password,
            username: username,
            machine: machine
        )
        let previousCredentialRef = machine.credentialRef
        let previousUsername = machine.lastKnownUser

        setCredential(
            credentialRef,
            username: username,
            for: machine.id
        )

        Task {
            do {
                try await secretVault.store(
                    SecretPayload(
                        reference: credentialRef,
                        value: Data(trimmedPassword.utf8)
                    )
                )

                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Saved a password-backed SSH login for \(machine.alias)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.setCredential(
                        previousCredentialRef,
                        username: previousUsername,
                        for: machine.id
                    )
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Saving the SSH password failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func generateSSHKeyCredential() {
        connectionSetupNotice = nil
        guard let machine = selectedMachine else {
            return
        }

        guard let username = sshUsername(for: machine, route: selectedBootstrapRoute) else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: missingSSHUsernameGuidance(
                        for: selectedBootstrapRoute,
                        action: "generate an SSH key"
                    )
                )
            )
            return
        }

        let comment = sshKeyComment(for: machine, username: username)
        let credentialRef = savedCredentialReference(
            kind: .sshKey,
            username: username,
            machine: machine
        )
        let previousCredentialRef = machine.credentialRef
        let previousUsername = machine.lastKnownUser

        do {
            let generated = try SSHGeneratedKeyMaterial.generateEd25519(comment: comment)
            setCredential(
                credentialRef,
                username: username,
                for: machine.id
            )
            revealedSSHLoginPublicKey = generated.openSSHPublicKey

            Task {
                do {
                    try await secretVault.store(
                        SecretPayload(
                            reference: credentialRef,
                            value: generated.privateKeySeed
                        )
                    )
                    await MainActor.run {
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Generated a device SSH key for \(machine.alias). Add the public key to ~/.ssh/authorized_keys on the Mac before connecting."
                            )
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.setCredential(
                            previousCredentialRef,
                            username: previousUsername,
                            for: machine.id
                        )
                        self.revealedSSHLoginPublicKey = nil
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Generating the SSH key failed: \(error.localizedDescription)"
                            )
                        )
                    }
                }
            }
        } catch {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Generating the SSH key failed: \(error.localizedDescription)"
                )
            )
        }
    }

    public func saveSelectedBootstrapUsername(_ username: String) {
        guard let machine = selectedMachine,
              let route = selectedBootstrapRoute else {
            return
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Enter a username before saving SSH login details for \(route.label)."
                )
            )
            return
        }

        let existingCredential = machine.credentialRef
        let shouldClearCredential = existingCredential?.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(trimmedUsername) != .orderedSame
            && existingCredential != nil

        updateRoute(routeID: route.id, machineID: machine.id) { updatedRoute in
            updatedRoute.usernameHint = trimmedUsername
        }

        if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[machineIndex].lastKnownUser = trimmedUsername
            if shouldClearCredential {
                machines[machineIndex].credentialRef = nil
                revealedSSHLoginPublicKey = nil
            }
        }

        runtimeCapabilityDiagnostics = nil
        persistStateAsync()

        let message = shouldClearCredential
            ? "Updated username for \(route.label) to \(trimmedUsername) and cleared the saved SSH credential because it belonged to a different username."
            : "Updated username for \(route.label) to \(trimmedUsername)."
        transcript.append(SessionMessage(role: .system, text: message))
    }

    public func revealSSHLoginPublicKey() {
        guard let machine = selectedMachine,
              let credentialRef = machine.credentialRef,
              credentialRef.kind == .sshKey else {
            return
        }

        let comment = sshKeyComment(for: machine, username: credentialRef.username)
        Task {
            do {
                guard let payload = try await secretVault.load(reference: credentialRef) else {
                    throw CodexSSHError.invalidRequest("No SSH key is saved for this Mac on this iPhone.")
                }
                let publicKey = SSHGeneratedKeyMaterial.publicKeyString(
                    forEd25519Seed: payload.value,
                    comment: comment
                )
                await MainActor.run {
                    self.revealedSSHLoginPublicKey = publicKey
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Loading the SSH public key failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func recoverSavedSSHKeyLogin() {
        connectionSetupNotice = nil
        guard let machine = selectedMachine,
              let username = sshUsername(for: machine, route: selectedBootstrapRoute) else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: missingSSHUsernameGuidance(
                        for: selectedBootstrapRoute,
                        action: "recover the saved SSH key"
                    )
                )
            )
            return
        }

        Task {
            guard let recoveredReference = await recoverableSavedSSHKeyReference(
                for: machine,
                username: username
            ) else {
                let availability = await savedSSHKeyRecoveryAvailability(
                    for: machine,
                    username: username
                )

                guard availability != .none else {
                    await MainActor.run {
                        self.presentConnectionSetupNotice(
                            "No saved SSH key could be recovered for @\(username) on this device."
                        )
                    }
                    return
                }

                guard let route = self.selectedBootstrapRoute ?? self.sshBootstrapRoute(for: machine) else {
                    await MainActor.run {
                        self.presentConnectionSetupNotice(
                            "Saved SSH keys were found on this iPhone, but the route still needs a reachable SSH endpoint before they can be tried."
                        )
                    }
                    return
                }

                let environment = ProcessInfo.processInfo.environment
                guard let endpoint = self.resolvedSSHBootstrapEndpoint(for: route, environment: environment) else {
                    await MainActor.run {
                        self.presentConnectionSetupNotice(
                            "Saved SSH keys were found on this iPhone, but \(route.label) still needs a reachable SSH endpoint before they can be tried."
                        )
                    }
                    return
                }

                guard let hostValidation = self.hostValidationPolicy(for: route) else {
                    await MainActor.run {
                        self.presentConnectionSetupNotice(
                            "Saved SSH keys were found on this iPhone. Verify the Mac fingerprint first, then try the saved keys again."
                        )
                    }
                    return
                }

                do {
                    switch try await self.recoverWorkingSSHCredentialForConnection(
                        machine: machine,
                        route: route,
                        endpoint: endpoint,
                        username: username,
                        hostValidation: hostValidation,
                        cwd: self.connectionBootstrapWorkspaceRoot()
                    ) {
                    case .recovered:
                        return
                    case .notFound:
                        await MainActor.run {
                            self.presentConnectionSetupNotice(
                                "Saved SSH keys were found on this iPhone, but none of them could sign in as @\(username) on \(machine.alias). Create a new key or use password login."
                            )
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.presentConnectionSetupNotice(
                            "Trying the saved SSH keys failed: \(error.localizedDescription)"
                        )
                    }
                }
                return
            }

            await MainActor.run {
                self.connectionSetupNotice = nil
                self.assignCredential(recoveredReference, to: machine.id, username: recoveredReference.username)
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Recovered the saved device SSH key for \(machine.alias)."
                    )
                )
            }
        }
    }

    public func connectLocalLoopback() {
        connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
    }

    public func runUITestLaunchAutomationIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1" else {
            return
        }
        guard ProcessInfo.processInfo.environment["COTG_UI_TEST_AUTO_CONNECT_ON_LAUNCH"] == "1" else {
            return
        }
        guard uiTestLaunchAutomationTask == nil else {
            return
        }

        uiTestLaunchAutomationTask = Task { @MainActor [weak self] in
            await self?.performUITestLaunchAutomation()
        }
    }

    public func sceneDidBecomeActive() {
        guard !isDemoModeEnabled else {
            connectionState = .connected("Reviewer demo mode")
            activeProtocolKind = .stdio
            refreshComposerCapabilities()
            return
        }

        Task {
            await refreshExternalTailnetAppAvailability()
            await reconcilePersistedLocalStateIfNeeded()
        }
        refreshEmbeddedTailnetRuntimeStatus()
        networkProxyDiagnostics = NetworkProxyDiagnosticSnapshot.current()

        guard activeTurnID == nil else {
            return
        }

        switch connectionState {
        case .connected:
            refreshModelsIfNeeded()
            if !recoverPreferredLoopbackAfterRelaunchIfNeeded() {
                Task {
                    await refreshCurrentThreadHistoryIfPossible()
                }
            }
        case .disconnected, .failed:
            guard activeSession?.threadID != nil
                    || activeSessionRequiresExplicitThreadSelection else {
                return
            }
            connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
        case .connecting:
            restartStaleConnectingSessionIfNeeded(reason: "Restarting interrupted host reconnect after relaunch.")
        }
    }

    public func sceneDidEnterBackground() {
        guard !isDemoModeEnabled else {
            return
        }
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    public func connectSelectedMachine(
        preferLoopbackUpgrade: Bool,
        retryAlternativeOnRouteFailure: Bool = true
    ) {
        guard !isDemoModeEnabled else {
            activateDemoConnection()
            return
        }

        if case .connecting = connectionState {
            guard Self.shouldRestartStaleConnectingSession(
                activeTurnID: activeTurnID,
                connectionTaskActive: connectionTask != nil,
                connectionAttemptStartedAt: connectionAttemptStartedAt,
                now: Date()
            ) else {
                return
            }

            connectionTask?.cancel()
            connectionTask = nil
            connectionWatchdogTask?.cancel()
            connectionWatchdogTask = nil
            connectionAttemptStartedAt = nil
        }

        let recoveringFromFailedState: Bool
        if case .failed = connectionState {
            recoveringFromFailedState = true
        } else {
            recoveringFromFailedState = false
        }

        if recoveringFromFailedState {
            activeTurnID = nil
            finishAllLiveActivityMessages()
        }

        beginRestoringActiveTranscript(for: activeSession?.threadID)
        connectionState = .connecting
        activeProtocolKind = .stdio
        automaticLoopbackUpgradePending = false
        automaticLoopbackUpgradeTask = nil
        suppressNextWebsocketErrorAfterCompletedTurn = false
        loopbackRecoveryRetryTask?.cancel()
        loopbackRecoveryRetryTask = nil
        lastAutomaticLoopbackUpgradeAttemptAt = nil
        automaticLoopbackUpgradeSuppressedUntilReconnect = false
        loopbackUpgradeInProgress = false
        lastLoopbackUpgradeStandbyReason = nil
        updateSessionState(transportState: .connecting, lastErrorSummary: nil)

        connectionAttemptStartedAt = Date()
        connectionAttemptGeneration += 1
        let attemptGeneration = connectionAttemptGeneration
        connectionTask = Task {
            defer {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.connectionAttemptGeneration == attemptGeneration else {
                        return
                    }
                    self.connectionTask = nil
                    self.connectionWatchdogTask?.cancel()
                    self.connectionWatchdogTask = nil
                    self.connectionAttemptStartedAt = nil
                }
            }

            var attemptedRoute: (machineID: MachineRecord.ID, routeID: RouteRecord.ID)?
            var attemptedConnectionLabel = "connection"
            do {
                let bootstrapCwd = connectionBootstrapWorkspaceRoot()
                let threadWorkspaceRoot = resolvedWorkspaceRoot()
                let previousExecutionProfileState = activeSession?.executionProfileState
                let candidate = try await withConnectionStage("connection candidate") {
                    try await withAsyncTimeout(
                        .seconds(20),
                        errorMessage: "Connection candidate preparation timed out."
                    ) {
                        try await self.connectionCandidate(cwd: bootstrapCwd)
                    }
                }
                guard let candidate else {
                    let summary = await self.connectionFailureSummary()
                    Self.logger.error("No connection candidate available: \(summary, privacy: .public)")
                    await MainActor.run {
                        self.isRestoringActiveTranscript = false
                        self.connectionState = .failed(summary)
                        self.updateSessionState(
                            transportState: .failed,
                            lastErrorSummary: summary
                        )
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Connection failed: \(summary)"
                            )
                        )
                        self.scheduleSessionFailure(summary)
                    }
                    return
                }

                switch candidate {
                case let .safeLane(machineID, configuration, route, bootstrap):
                    attemptedConnectionLabel = "SSH fallback lane"
                    attemptedRoute = (machineID, route.id)
                    await primeLocalNetworkAccessIfNeeded(for: route)
                    Self.logger.log("Connecting safe lane via \(route.kind.rawValue, privacy: .public) to \(configuration.host, privacy: .public):\(configuration.port, privacy: .public)")
                    if preferLoopbackUpgrade && loopbackUpgradeFeatureAvailable {
                        do {
                            attemptedConnectionLabel = "SSH-forwarded Codex websocket lane"
                            loopbackUpgradeInProgress = true
                            defer { loopbackUpgradeInProgress = false }

                            try await withConnectionStage("loopback bootstrap") {
                                try await connectSafeLaneForLoopbackBootstrapWithTimeout(
                                    configuration: configuration,
                                    route: route
                                )
                            }
                            let loopbackCwd = threadWorkspaceRoot ?? bootstrapCwd
                            let upgradedSession = try await withConnectionStage("loopback websocket") {
                                try await prepareLoopbackUpgradeSession(cwd: loopbackCwd)
                            }
                            let executionProfileState = updatedExecutionProfileState(
                                from: previousExecutionProfileState,
                                snapshot: SessionExecutionSnapshot(
                                    runtime: previousExecutionProfileState?.profile.runtime,
                                    baselineConfig: previousExecutionProfileState?.baselineConfig,
                                    constraints: previousExecutionProfileState?.constraints,
                                    support: previousExecutionProfileState?.support ?? .init(serverRequestRouting: .supported)
                                ),
                                effectiveProfile: upgradedSession.resumedThread?.executionProfile ?? upgradedSession.thread.executionProfile,
                                requestedThreadOptions: requestedThreadExecutionOptions(
                                    session: activeSession,
                                    cwd: loopbackCwd,
                                    model: upgradedSession.thread.model,
                                    baselineConfig: previousExecutionProfileState?.baselineConfig
                                ),
                                overridesKind: .supported,
                                detectResumeMismatch: upgradedSession.resumedThread != nil
                            )
                            await MainActor.run {
                                self.applyAvailableModels(upgradedSession.models)
                                self.connectionState = .connected(upgradedSession.url.absoluteString)
                                self.activeProtocolKind = .websocket
                                self.applyLiveThreadSnapshot(upgradedSession.resumedThread?.thread)
                                self.markRouteConnectionSuccess(routeID: route.id, machineID: machineID)
                                self.automaticLoopbackUpgradePending = false
                                self.automaticLoopbackUpgradeTask = nil
                                self.lastLoopbackUpgradeStandbyReason = nil
                                self.hostRuntimeTransportStatus = nil
                                self.loopbackRecoveryRetryTask?.cancel()
                                self.loopbackRecoveryRetryTask = nil
                                self.upsertSession(
                                    threadID: upgradedSession.thread.id,
                                    routeID: route.id,
                                    workspaceRoot: upgradedSession.thread.cwd,
                                    lastKnownProtocol: .websocket,
                                    lastKnownRouteKind: route.kind,
                                    lastKnownBootstrap: .standardSSH,
                                    lastModel: upgradedSession.thread.model,
                                    reasoningEffort: upgradedSession.thread.reasoningEffort,
                                    executionProfileState: executionProfileState,
                                    bindProtocolThreadID: upgradedSession.resumedThread?.isLiveBinding ?? true
                                )
                                self.persistActiveExecutionProfileState(executionProfileState)
                                self.appendExecutionProfileChangeNoticeIfNeeded(
                                    previous: previousExecutionProfileState,
                                    current: executionProfileState
                                )
                                self.transcript.append(
                                    SessionMessage(
                                        role: .system,
                                        text: "Connected through the SSH-forwarded Codex websocket lane."
                                    )
                                )
                                self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
                                if (recoveringFromFailedState || self.shouldNotifyRouteRecovery(for: route)),
                                   let recoveredMachine = self.machines.first(where: { $0.id == machineID }) {
                                    self.scheduleNotification(.routeRecovered(machine: recoveredMachine))
                                }
                                self.beginPendingTurnRequestAfterReconnectIfPossible()
                            }
                            await refreshCapabilityDiagnosticsFromSafeLane()
                            await refreshRepoBrowserSessions(limit: 20, fetchAllPages: false)
                            return
                        } catch {
                            loopbackUpgradeInProgress = false
                            lastLoopbackUpgradeStandbyReason = error.localizedDescription
                            hostRuntimeTransportStatus = HostRuntimeTransportStatus(
                                kind: .loopbackFallback,
                                label: "SSH fallback",
                                detail: "Loopback listener degraded. Falling back to the SSH safe lane: \(error.localizedDescription)"
                            )
                            Self.logger.warning("Initial loopback websocket lane failed; falling back to SSH safe lane: \(error.localizedDescription, privacy: .public)")
                            transcript.append(
                                SessionMessage(
                                    role: .system,
                                    text: "Loopback listener degraded. Falling back to the SSH safe lane: \(error.localizedDescription)"
                                )
                            )
                        }
                    }
                    try await withConnectionStage("safe-lane bootstrap") {
                        try await connectSafeLaneWithTimeout(
                            configuration: configuration,
                            route: route
                        )
                    }

                    let models = try await withConnectionStage("model/list") {
                        try await safeLaneOperationWithTimeout(
                            .seconds(15),
                            errorMessage: "Model list timed out on the SSH fallback lane."
                        ) {
                            try await self.safeLaneClient.listModels()
                        }
                    }
                    let executionSnapshot = await captureExecutionSnapshot(for: .stdio)
                    let threadOptions = requestedThreadExecutionOptions(
                        session: activeSession,
                        cwd: threadWorkspaceRoot,
                        model: nil,
                        baselineConfig: executionSnapshot.baselineConfig
                    )
                    let hadSelectedThread = activeSession?.threadID != nil
                    let resumedThread = try await withConnectionStage("thread/resume") {
                        try await safeLaneOperationWithTimeout(
                            .seconds(25),
                            errorMessage: "Thread resume timed out on the SSH fallback lane."
                        ) {
                            try await self.resumeSafeLaneThreadIfPossible(options: threadOptions)
                        }
                    }
                    let unavailableSelectedThreadID = hadSelectedThread ? activeUnavailableSelectedThreadID : nil
                    let thread: CodexThreadContext? = if let resumedThread {
                        CodexThreadContext(
                            id: resumedThread.thread.id,
                            cwd: resumedThread.cwd,
                            model: resumedThread.model,
                            reasoningEffort: resumedThread.reasoningEffort,
                            executionProfile: resumedThread.executionProfile
                        )
                    } else {
                        nil
                    }
                    let shouldScheduleAutomaticLoopbackUpgrade = Self.shouldScheduleAutomaticLoopbackUpgrade(
                        preferLoopbackUpgrade: preferLoopbackUpgrade,
                        unavailableSelectedThreadID: unavailableSelectedThreadID,
                        hasBoundThread: thread != nil
                    )
                    let executionProfileState = updatedExecutionProfileState(
                        from: previousExecutionProfileState,
                        snapshot: executionSnapshot,
                        effectiveProfile: resumedThread?.executionProfile ?? thread?.executionProfile,
                        requestedThreadOptions: threadOptions,
                        overridesKind: .supported,
                        detectResumeMismatch: resumedThread != nil
                    )
                    await MainActor.run {
                        self.applyAvailableModels(models)
                        self.connectionState = .connected("stdio://\(configuration.host)")
                        self.activeProtocolKind = .stdio
                        self.applyLiveThreadSnapshot(resumedThread?.thread)
                        self.markRouteConnectionSuccess(routeID: route.id, machineID: machineID)
                        self.automaticLoopbackUpgradePending = shouldScheduleAutomaticLoopbackUpgrade
                        self.automaticLoopbackUpgradeTask = nil
                        if let thread {
                            self.upsertSession(
                                threadID: thread.id,
                                routeID: route.id,
                                workspaceRoot: thread.cwd,
                                lastKnownProtocol: .stdio,
                                lastKnownRouteKind: route.kind,
                                lastKnownBootstrap: bootstrap,
                                lastModel: thread.model,
                                reasoningEffort: thread.reasoningEffort,
                                executionProfileState: executionProfileState,
                                bindProtocolThreadID: resumedThread?.isLiveBinding ?? true
                            )
                        } else if !hadSelectedThread, unavailableSelectedThreadID == nil {
                            self.bindWorkspaceOnlySession(
                                routeID: route.id,
                                workspaceRoot: threadWorkspaceRoot ?? bootstrapCwd,
                                lastKnownProtocol: .stdio,
                                lastKnownRouteKind: route.kind,
                                lastKnownBootstrap: bootstrap,
                                executionProfileState: executionProfileState
                            )
                        }
                        self.persistActiveExecutionProfileState(executionProfileState)
                        self.appendExecutionProfileChangeNoticeIfNeeded(
                            previous: previousExecutionProfileState,
                            current: executionProfileState
                        )
                        let connectedMessage: String
                        if let unavailableSelectedThreadID {
                            connectedMessage = UnavailableSelectedThreadError.message(for: unavailableSelectedThreadID)
                        } else if thread == nil {
                            connectedMessage = "Connected to the SSH safe lane over stdio. Projects and threads are ready to browse."
                        } else {
                            connectedMessage = "Connected to the SSH safe lane over stdio."
                        }
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: connectedMessage
                            )
                        )
                        if let unavailableSelectedThreadID {
                            self.updateSessionState(
                                transportState: .connected,
                                lastErrorSummary: UnavailableSelectedThreadError.message(for: unavailableSelectedThreadID)
                            )
                        }
                        if (recoveringFromFailedState || self.shouldNotifyRouteRecovery(for: route)),
                           let recoveredMachine = self.machines.first(where: { $0.id == machineID }) {
                            self.scheduleNotification(.routeRecovered(machine: recoveredMachine))
                        }
                        self.beginPendingTurnRequestAfterReconnectIfPossible()
                    }

                    await performDeferredPostConnectWork(
                        cwd: thread?.cwd ?? bootstrapCwd,
                        preferLoopbackUpgrade: shouldScheduleAutomaticLoopbackUpgrade
                    )
                    await refreshRepoBrowserSessions(limit: 20, fetchAllPages: false)
                case let .directEndpoint(machineID, configuration, route, bootstrap):
                    attemptedConnectionLabel = "Codex websocket lane"
                    attemptedRoute = (machineID, route.id)
                    Self.logger.log("Connecting direct endpoint via \(route.kind.rawValue, privacy: .public) to \(configuration.url.absoluteString, privacy: .public)")
                    try await withConnectionStage("direct-endpoint connect") {
                        try await connectDirectEndpointWithTimeout(configuration: configuration)
                    }

                    let models = try await withConnectionStage("model/list") {
                        try await directEndpointOperationWithTimeout(
                            .seconds(15),
                            errorMessage: "Model list timed out on the Codex websocket endpoint."
                        ) {
                            try await self.loopbackClient.listModels()
                        }
                    }
                    let executionSnapshot = await captureExecutionSnapshot(
                        for: .directEndpoint,
                        runtimeFallback: previousExecutionProfileState?.profile.runtime
                    )
                    let threadOptions = requestedThreadExecutionOptions(
                        session: activeSession,
                        cwd: threadWorkspaceRoot,
                        model: nil,
                        baselineConfig: executionSnapshot.baselineConfig
                    )
                    let hadSelectedThread = activeSession?.threadID != nil
                    let resumedThread = try await withConnectionStage("thread/resume") {
                        try await directEndpointOperationWithTimeout(
                            .seconds(25),
                            errorMessage: "Thread resume timed out on the Codex websocket endpoint."
                        ) {
                            try await self.resumeDirectEndpointThreadIfPossible(options: threadOptions)
                        }
                    }
                    let unavailableSelectedThreadID = hadSelectedThread ? activeUnavailableSelectedThreadID : nil
                    let thread: CodexThreadContext? = if let resumedThread {
                        CodexThreadContext(
                            id: resumedThread.thread.id,
                            cwd: resumedThread.cwd,
                            model: resumedThread.model,
                            reasoningEffort: resumedThread.reasoningEffort,
                            executionProfile: resumedThread.executionProfile
                        )
                    } else {
                        nil
                    }
                    let executionProfileState = updatedExecutionProfileState(
                        from: previousExecutionProfileState,
                        snapshot: executionSnapshot,
                        effectiveProfile: resumedThread?.executionProfile ?? thread?.executionProfile,
                        requestedThreadOptions: threadOptions,
                        overridesKind: .supported,
                        detectResumeMismatch: resumedThread != nil
                    )
                    await MainActor.run {
                        self.applyAvailableModels(models)
                        self.connectionState = .connected(configuration.url.absoluteString)
                        self.activeProtocolKind = .directEndpoint
                        self.applyLiveThreadSnapshot(resumedThread?.thread)
                        self.markRouteConnectionSuccess(routeID: route.id, machineID: machineID)
                        self.automaticLoopbackUpgradePending = false
                        self.automaticLoopbackUpgradeTask = nil
                        if let thread {
                            self.upsertSession(
                                threadID: thread.id,
                                routeID: route.id,
                                workspaceRoot: thread.cwd,
                                lastKnownProtocol: .directEndpoint,
                                lastKnownRouteKind: route.kind,
                                lastKnownBootstrap: bootstrap,
                                lastModel: thread.model,
                                reasoningEffort: thread.reasoningEffort,
                                executionProfileState: executionProfileState,
                                bindProtocolThreadID: resumedThread?.isLiveBinding ?? true
                            )
                        } else if !hadSelectedThread, unavailableSelectedThreadID == nil {
                            self.bindWorkspaceOnlySession(
                                routeID: route.id,
                                workspaceRoot: threadWorkspaceRoot ?? bootstrapCwd,
                                lastKnownProtocol: .directEndpoint,
                                lastKnownRouteKind: route.kind,
                                lastKnownBootstrap: bootstrap,
                                executionProfileState: executionProfileState
                            )
                        }
                        self.persistActiveExecutionProfileState(executionProfileState)
                        self.appendExecutionProfileChangeNoticeIfNeeded(
                            previous: previousExecutionProfileState,
                            current: executionProfileState
                        )
                        let connectedMessage: String
                        if let unavailableSelectedThreadID {
                            connectedMessage = UnavailableSelectedThreadError.message(for: unavailableSelectedThreadID)
                        } else if thread == nil {
                            connectedMessage = "Connected to the Codex app-server websocket endpoint. Projects and threads are ready to browse."
                        } else {
                            connectedMessage = "Connected to the Codex app-server websocket endpoint."
                        }
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: connectedMessage
                            )
                        )
                        if let unavailableSelectedThreadID {
                            self.updateSessionState(
                                transportState: .connected,
                                lastErrorSummary: UnavailableSelectedThreadError.message(for: unavailableSelectedThreadID)
                            )
                        }
                        if (recoveringFromFailedState || self.shouldNotifyRouteRecovery(for: route)),
                           let recoveredMachine = self.machines.first(where: { $0.id == machineID }) {
                            self.scheduleNotification(.routeRecovered(machine: recoveredMachine))
                        }
                        self.beginPendingTurnRequestAfterReconnectIfPossible()
                    }

                    await refreshRepoBrowserSessions(limit: 20, fetchAllPages: false)
                    await refreshDiscoverySnapshot()
                    await MainActor.run {
                        self.runtimeCapabilityDiagnostics = nil
                    }
                }
            } catch let CodexSSHError.hostKeyMismatch(_, received) {
                await MainActor.run {
                    guard let machine = self.selectedMachine,
                          let route = self.selectedBootstrapRoute else {
                        self.connectionState = .failed("SSH host key mismatch.")
                        self.updateSessionState(
                            transportState: .failed,
                            lastErrorSummary: "SSH host key mismatch."
                        )
                        return
                    }

                    self.recordScannedHostKey(received, routeID: route.id, machineID: machine.id)
                    self.updateRoute(routeID: route.id, machineID: machine.id) { updatedRoute in
                        updatedRoute.trustState = .mismatch
                        updatedRoute.lastFailureAt = .now
                        updatedRoute.failureReasonCode = "ssh-host-key-mismatch"
                    }
                    self.persistStateAsync()

                    let fingerprint = Self.hostKeyFingerprint(received) ?? received
                    let detail = "SSH host key mismatch for \(route.label). Review the scanned fingerprint \(fingerprint) and trust it only if the host really changed."
                    self.isRestoringActiveTranscript = false
                    self.connectionState = .failed(detail)
                    self.updateSessionState(transportState: .failed, lastErrorSummary: detail)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: detail
                        )
                    )
                    self.scheduleSessionFailure(detail)
                }
            } catch {
                Self.logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    let detail = self.connectionFailureDetail(from: error)
                    if let attemptedRoute {
                        self.markRouteConnectionFailure(
                            routeID: attemptedRoute.routeID,
                            machineID: attemptedRoute.machineID,
                            reason: detail
                        )
                    }
                    if retryAlternativeOnRouteFailure,
                       let attemptedRoute,
                       self.hasAlternativeConnectionCandidate(afterFailing: attemptedRoute) {
                        self.isRestoringActiveTranscript = false
                        self.connectionState = .disconnected
                        self.updateSessionState(transportState: .disconnected, lastErrorSummary: detail)
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "\(attemptedConnectionLabel) failed: \(detail). Trying another saved route."
                            )
                        )
                        self.connectSelectedMachine(
                            preferLoopbackUpgrade: preferLoopbackUpgrade,
                            retryAlternativeOnRouteFailure: false
                        )
                        return
                    }
                    self.isRestoringActiveTranscript = false
                    self.connectionState = .failed(detail)
                    self.updateSessionState(transportState: .failed, lastErrorSummary: detail)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "\(attemptedConnectionLabel) failed: \(detail)"
                        )
                    )
                    self.scheduleSessionFailure(detail)
                }
            }
        }
        scheduleConnectionAttemptWatchdog(generation: attemptGeneration)
    }

    public func sendPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let modelOverride = activeThreadModelLabel
        sendTurnRequest(
            PendingTurnRequest(
                text: trimmed,
                attachments: [],
                summary: trimmed,
                model: modelOverride,
                effort: selectedReasoningEffort,
                collaborationMode: collaborationModePayload(modelOverride: modelOverride)
            )
        )
    }

    public func sendSmokeTestPrompt() {
        sendPrompt("Reply with COTG_APP_OK only.")
    }

    public func refreshModels() {
        refreshModels(force: true, announce: true)
    }

    public func refreshModelsIfNeeded() {
        refreshModels(force: false, announce: false)
    }

    private func refreshModels(force: Bool, announce: Bool) {
        if isDemoModeEnabled {
            guard force || shouldRefreshAvailableModels(force: force) else {
                return
            }
            applyAvailableModels(demoScenario?.availableModels ?? AppDemoScenario.make(sceneID: sceneID).availableModels)
            if announce {
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Demo mode refreshed the bundled model list."
                    )
                )
            }
            return
        }

        guard case .connected = connectionState else {
            if announce {
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Connect first to refresh available Codex models."
                    )
                )
            }
            return
        }
        guard shouldRefreshAvailableModels(force: force),
              modelRefreshTask == nil else {
            return
        }

        modelRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.refreshModelsFromActiveTransport(announce: announce)
            self.modelRefreshTask = nil
        }
    }

    private func refreshModelsFromActiveTransport(announce: Bool) async {
        do {
            let models = switch activeProtocolKind {
            case .stdio:
                try await safeLaneClient.listModels()
            case .websocket, .directEndpoint:
                try await loopbackClient.listModels()
            }

            applyAvailableModels(models)
            if announce {
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Refreshed the available Codex models."
                    )
                )
            }
        } catch {
            if announce {
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Model refresh failed: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func shouldRefreshAvailableModels(force: Bool, now: Date = Date()) -> Bool {
        if force || availableModels.isEmpty {
            return true
        }

        guard let lastSuccessfulModelRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastSuccessfulModelRefreshAt) >= Self.automaticModelRefreshInterval
    }

    public func refreshCapabilityDiagnostics() {
        if isDemoModeEnabled {
            runtimeCapabilityDiagnostics = baseCapabilityDiagnostics
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Demo mode uses bundled host capabilities. Turn it off to probe a real Mac."
                )
            )
            return
        }

        guard case .connected = connectionState else {
            runtimeCapabilityDiagnostics = nil
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Connect first to probe the host capabilities."
                )
            )
            return
        }

        guard activeProtocolKind != .directEndpoint else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Direct endpoint sessions use companion metadata only. Reconnect on the SSH safe lane to probe host capabilities."
                )
            )
            return
        }

        Task {
            await refreshCapabilityDiagnosticsFromSafeLane()
        }
    }

    public func interruptActiveTurn() {
        guard let threadID = resolveThreadID(preferredThreadID: nil),
              let activeTurnID else {
            return
        }

        Task {
            do {
                switch activeProtocolKind {
                case .stdio:
                    try await safeLaneClient.interruptTurn(threadID: threadID, turnID: activeTurnID)
                case .websocket, .directEndpoint:
                    try await loopbackClient.interruptTurn(threadID: threadID, turnID: activeTurnID)
                }

                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Interrupt requested for turn \(activeTurnID)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Interrupt failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func steerActiveTurn() {
        let trimmed = steerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let threadID = resolveThreadID(preferredThreadID: nil),
              let activeTurnID,
              !trimmed.isEmpty else {
            return
        }

        Task {
            do {
                switch activeProtocolKind {
                case .stdio:
                    _ = try await safeLaneClient.steerTurn(threadID: threadID, expectedTurnID: activeTurnID, text: trimmed)
                case .websocket, .directEndpoint:
                    _ = try await loopbackClient.steerTurn(threadID: threadID, expectedTurnID: activeTurnID, text: trimmed)
                }

                await MainActor.run {
                    self.transcript.append(SessionMessage(role: .user, text: "Steer: \(trimmed)"))
                    self.steerDraft = ""
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Steer failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func forkCurrentThread() {
        Task {
            do {
                let result = try await forkCurrentThreadNow()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Forked the active thread into \(result.threadID)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Thread fork failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func startNewThreadInWorktree(
        named name: String? = nil,
        branch: String? = nil
    ) {
        Task {
            do {
                let result = try await startNewThreadInWorktreeNow(named: name, branch: branch)
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Started a new worktree thread in \(result.workspaceRoot)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Starting a worktree thread failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func moveCurrentThreadToWorktree(
        named name: String? = nil,
        branch: String? = nil
    ) {
        Task {
            do {
                let result = try await moveCurrentThreadToWorktreeNow(named: name, branch: branch)
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Handed this thread off to \(result.workspaceRoot)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Moving this thread to a worktree failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func returnCurrentThreadToLocalCheckout() {
        Task {
            do {
                let result = try await returnCurrentThreadToLocalCheckoutNow()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Handed this thread back to \(result.workspaceRoot)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Returning this thread to Local failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func forkCurrentThreadToWorktree(
        named name: String? = nil,
        branch: String? = nil
    ) {
        Task {
            do {
                let result = try await forkCurrentThreadToWorktreeNow(named: name, branch: branch)
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Forked this thread into the worktree \(result.workspaceRoot)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Forking this thread to a worktree failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func forkCurrentThreadToLocalCheckout() {
        Task {
            do {
                let result = try await forkCurrentThreadToLocalCheckoutNow()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Forked this thread back to \(result.workspaceRoot)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Forking this thread back to Local failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func runWorkspaceReview() {
        guard let threadID = resolveThreadID(preferredThreadID: nil) else {
            return
        }

        Task {
            do {
                let review = try await AppWorkspaceReviewCoordinator.startInlineReview(
                    protocolKind: activeProtocolKind,
                    safeLaneStart: { [safeLaneClient] in
                        try await safeLaneClient.startReview(
                            threadID: threadID,
                            delivery: .inline,
                            target: .uncommittedChanges
                        )
                    },
                    liveStart: { [loopbackClient] in
                        try await loopbackClient.startReview(
                            threadID: threadID,
                            delivery: .inline,
                            target: .uncommittedChanges
                        )
                    }
                )

                await MainActor.run {
                    self.activeTurnID = review.turnID
                    self.setReviewThreadID(review.reviewThreadID)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Started an inline workspace review turn."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Workspace review failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func approvePendingRequest() {
        guard let request = pendingApprovalRequest else {
            return
        }

        resolvePendingApproval(request, decision: request.kind == .permissions ? .grantRequestedPermissions(scopeSession: false) : .accept)
    }

    public func denyPendingRequest() {
        guard let request = pendingApprovalRequest else {
            return
        }

        resolvePendingApproval(request, decision: request.kind == .permissions ? .denyPermissions : .decline)
    }

    public func sendComposerDraft() {
        composerSendAttemptCount += 1
        let trimmedDraft = composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerState.attachments
        let summary = summaryText(for: trimmedDraft, attachments: attachments)
        guard !summary.isEmpty else {
            return
        }

        sendTurnRequest(
            PendingTurnRequest(
                text: trimmedDraft.isEmpty ? nil : trimmedDraft,
                attachments: attachments,
                summary: summary,
                model: activeThreadModelLabel,
                effort: selectedReasoningEffort,
                collaborationMode: collaborationModePayload(modelOverride: activeThreadModelLabel)
            )
        )
        composerState.draft = ""
        composerState.attachments.removeAll()
    }

    public func refreshWorkspaceStatus() async throws {
        if isDemoModeEnabled {
            workspaceSummary = demoWorkspaceSummary(for: activeSession)
            workspaceFailureSummary = nil
            return
        }

        guard activeProtocolKind != .directEndpoint else {
            await MainActor.run {
                self.workspaceSummary = nil
                self.workspaceFailureSummary = "Workspace review requires an SSH-backed session."
            }
            throw CodexSSHError.invalidRequest("Workspace tools require an SSH-backed safe lane.")
        }

        guard let cwd = activeSession?.workspaceRoot else {
            await MainActor.run {
                self.workspaceSummary = nil
                self.workspaceFailureSummary = nil
            }
            return
        }

        do {
            let result = try await safeLaneClient.execute(command: GitWorkspaceCommandBuilder.statusCommand(cwd: cwd))
            guard result.exitStatus == 0 else {
                let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.workspaceSummary = nil
                    self.workspaceFailureSummary = Self.humanizedWorkspaceFailureSummary(from: detail)
                }
                throw CodexSSHError.invalidResponse(result.errorOutput)
            }
            let summary = GitStatusParser.parse(result.standardOutput)
            await MainActor.run {
                self.workspaceSummary = summary
                self.workspaceFailureSummary = nil
            }
        } catch {
            if !(error is CodexSSHError) {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.workspaceSummary = nil
                    self.workspaceFailureSummary = Self.humanizedWorkspaceFailureSummary(from: detail)
                }
            }
            throw error
        }

        try? await refreshWorktreeList()
    }

    public func refreshWorkspace() {
        Task {
            do {
                try await refreshWorkspaceStatus()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Workspace status refreshed from the host."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Workspace refresh failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func refreshWorktrees() {
        Task {
            do {
                try await refreshWorktreeList()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Worktree list refreshed from the host."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Worktree refresh failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func switchWorkspaceBranch(to branch: String) {
        runGitWorkspaceMutation(
            summary: "Switched to branch \(branch).",
            commandBuilder: { cwd in
                GitWorkspaceCommandBuilder.switchBranchCommand(cwd: cwd, branch: branch)
            }
        )
    }

    public func createWorkspaceBranch(named branch: String) {
        runGitWorkspaceMutation(
            summary: "Created and switched to branch \(branch).",
            commandBuilder: { cwd in
                GitWorkspaceCommandBuilder.createBranchCommand(cwd: cwd, branch: branch)
            }
        )
    }

    public func commitWorkspaceChanges(message: String) {
        runGitWorkspaceMutation(
            summary: "Created commit: \(message)",
            commandBuilder: { cwd in
                GitWorkspaceCommandBuilder.commitCommand(cwd: cwd, message: message)
            }
        )
    }

    public func createWorkspace(named name: String, branch: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Worktree creation needs a stable folder name."
                )
            )
            return
        }

        let branchName = (trimmedBranch?.isEmpty == false ? trimmedBranch : trimmedName) ?? trimmedName
        let worktreePath = defaultWorktreeParent().appendingPathComponent(trimmedName).path

        runGitWorkspaceMutation(
            summary: "Created worktree \(trimmedName) on branch \(branchName).",
            commandBuilder: { cwd in
                GitWorkspaceCommandBuilder.createWorktreeCommand(
                    cwd: cwd,
                    path: worktreePath,
                    branch: branchName
                )
            }
        )
    }

    public func startNewThreadInWorktreeNow(
        named name: String? = nil,
        branch: String? = nil
    ) async throws -> ThreadWorkspaceRoutingResult {
        try await prepareSSHSafeLaneForThreadRouting()
        try await restoreSafeLaneThreadRoutingAnchorIfNeeded()
        let context = try currentWorkspaceRoutingContext(requireThread: false, requireSSHSafeLane: true)
        let parentThreadID = resolvedActiveSessionRoutingThreadID(for: context.session)
            ?? resolveThreadID(preferredThreadID: nil)
        let targetWorkspaceRoot = try await createWorktreeForThreadRouting(
            sourceWorkspaceRoot: context.workspaceRoot,
            named: name,
            branch: branch
        )
        let startedThread = switch activeProtocolKind {
        case .stdio:
            try await safeLaneClient.startThread(cwd: targetWorkspaceRoot, model: selectedModel)
        case .websocket:
            try await loopbackClient.startThread(cwd: targetWorkspaceRoot, model: selectedModel)
        case .directEndpoint:
            throw CodexSSHError.invalidRequest("Worktree flows require the SSH safe lane.")
        }

        let session = await MainActor.run {
            self.appendThreadWorkspaceSession(
                threadID: startedThread.id,
                workspaceRoot: startedThread.cwd,
                parentThreadID: parentThreadID,
                parentLastTurnID: activeSession?.lastTurnID
            )
        }
        try await activateThreadWorkspaceSession(session, thread: startedThread)
        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(startedThread.cwd) ?? startedThread.cwd
        return ThreadWorkspaceRoutingResult(
            sessionID: session.id,
            threadID: startedThread.id,
            workspaceRoot: normalizedWorkspaceRoot
        )
    }

    public func moveCurrentThreadToWorktreeNow(
        named name: String? = nil,
        branch: String? = nil
    ) async throws -> ThreadWorkspaceRoutingResult {
        try await prepareSSHSafeLaneForThreadRouting()
        try await restoreSafeLaneThreadRoutingAnchorIfNeeded()
        let context = try currentWorkspaceRoutingContext(requireThread: true, requireSSHSafeLane: true)
        try await ensureWorkspaceCleanForThreadRouting()
        let targetWorkspaceRoot = try await createWorktreeForThreadRouting(
            sourceWorkspaceRoot: context.workspaceRoot,
            named: name,
            branch: branch
        )
        return try await handoffCurrentThreadNow(
            sourceThreadID: context.threadID,
            session: context.session,
            targetWorkspaceRoot: targetWorkspaceRoot
        )
    }

    public func returnCurrentThreadToLocalCheckoutNow() async throws -> ThreadWorkspaceRoutingResult {
        try await prepareSSHSafeLaneForThreadRouting()
        try await restoreSafeLaneThreadRoutingAnchorIfNeeded()
        let context = try currentWorkspaceRoutingContext(requireThread: true, requireSSHSafeLane: true)
        let localCheckoutPath = try await resolveLocalCheckoutPath(for: context.workspaceRoot)
        guard Self.normalizedWorkspaceRoot(localCheckoutPath) != Self.normalizedWorkspaceRoot(context.workspaceRoot) else {
            throw CodexSSHError.invalidRequest("This thread is already using the Local checkout.")
        }
        try await ensureWorkspaceCleanForThreadRouting()
        if let preferredLocalReturn = try? await resumeParentLocalThreadIfAvailable(
            currentContext: context,
            localCheckoutPath: localCheckoutPath
        ) {
            return preferredLocalReturn
        }
        do {
            return try await handoffCurrentThreadNow(
                sourceThreadID: context.threadID,
                session: context.session,
                targetWorkspaceRoot: localCheckoutPath
            )
        } catch {
            if let fallback = try? await resumeParentLocalThreadIfAvailable(
                currentContext: context,
                localCheckoutPath: localCheckoutPath
            ) {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Returned to the parent Local thread because the direct Local handoff target was not ready yet."
                        )
                    )
                }
                return fallback
            }
            if let freshLocalReturn = try? await returnToFreshLocalThreadIfNeeded(
                currentContext: context,
                localCheckoutPath: localCheckoutPath,
                triggeringError: error
            ) {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Returned to a fresh Local thread because the original Local parent did not have a resumable rollout yet."
                        )
                    )
                }
                return freshLocalReturn
            }
            throw error
        }
    }

    public func forkCurrentThreadNow() async throws -> ThreadWorkspaceRoutingResult {
        let context = try currentWorkspaceRoutingContext(requireThread: true, requireSSHSafeLane: false)
        return try await forkCurrentThreadNow(
            sourceThreadID: context.threadID,
            targetWorkspaceRoot: context.workspaceRoot,
            parentThreadID: context.threadID,
            parentLastTurnID: context.session.lastTurnID
        )
    }

    public func forkCurrentThreadToWorktreeNow(
        named name: String? = nil,
        branch: String? = nil
    ) async throws -> ThreadWorkspaceRoutingResult {
        try await prepareSSHSafeLaneForThreadRouting()
        try await restoreSafeLaneThreadRoutingAnchorIfNeeded()
        let context = try currentWorkspaceRoutingContext(requireThread: true, requireSSHSafeLane: true)
        try await ensureWorkspaceCleanForThreadRouting()
        let targetWorkspaceRoot = try await createWorktreeForThreadRouting(
            sourceWorkspaceRoot: context.workspaceRoot,
            named: name,
            branch: branch
        )
        return try await forkCurrentThreadNow(
            sourceThreadID: context.threadID,
            targetWorkspaceRoot: targetWorkspaceRoot,
            parentThreadID: context.threadID,
            parentLastTurnID: context.session.lastTurnID
        )
    }

    public func forkCurrentThreadToLocalCheckoutNow() async throws -> ThreadWorkspaceRoutingResult {
        try await prepareSSHSafeLaneForThreadRouting()
        try await restoreSafeLaneThreadRoutingAnchorIfNeeded()
        let context = try currentWorkspaceRoutingContext(requireThread: true, requireSSHSafeLane: true)
        let localCheckoutPath = try await resolveLocalCheckoutPath(for: context.workspaceRoot)
        guard Self.normalizedWorkspaceRoot(localCheckoutPath) != Self.normalizedWorkspaceRoot(context.workspaceRoot) else {
            throw CodexSSHError.invalidRequest("This thread is already using the Local checkout.")
        }
        try await ensureWorkspaceCleanForThreadRouting()
        return try await forkCurrentThreadNow(
            sourceThreadID: context.threadID,
            targetWorkspaceRoot: localCheckoutPath,
            parentThreadID: context.threadID,
            parentLastTurnID: context.session.lastTurnID
        )
    }

    public func previewRevert(for path: String) {
        guard activeProtocolKind != .directEndpoint else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Revert previews require the SSH safe lane because the direct Codex websocket endpoint does not expose host shell access."
                )
            )
            return
        }

        guard let cwd = activeSession?.workspaceRoot else {
            return
        }

        Task {
            do {
                let result = try await safeLaneClient.execute(
                    command: GitWorkspaceCommandBuilder.diffPreviewCommand(cwd: cwd, path: path)
                )
                await MainActor.run {
                    self.revertPreview = RevertPreview(path: path, diff: result.standardOutput)
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Failed to load revert preview for \(path): \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func applyRevert(for path: String) {
        guard activeProtocolKind != .directEndpoint else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Explicit reverts require the SSH safe lane because the direct Codex websocket endpoint does not expose host shell access."
                )
            )
            return
        }

        guard let cwd = activeSession?.workspaceRoot else {
            return
        }

        transcript.append(
            SessionMessage(
                role: .system,
                text: "Applying explicit workspace revert for \(path)."
            )
        )

        Task {
            do {
                let result = try await safeLaneClient.execute(
                    command: GitWorkspaceCommandBuilder.revertCommand(cwd: cwd, path: path)
                )
                guard result.exitStatus == 0 else {
                    throw CodexSSHError.invalidResponse(result.errorOutput)
                }
                try await refreshWorkspaceStatus()
                await MainActor.run {
                    self.revertPreview = nil
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Workspace revert failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func addPhotoAttachment(named name: String, data: Data? = nil, suggestedFilename: String? = nil) {
        composerState.attachments.append(
            ComposerAttachment(
                kind: .photo,
                displayName: name,
                suggestedFilename: suggestedFilename ?? name,
                payload: data
            )
        )
    }

    public func appendVoiceTranscript(_ text: String) {
        let separator = composerState.draft.isEmpty ? "" : "\n"
        composerState.draft += "\(separator)\(text)"
    }

    public func requestNotificationAuthorization() {
        Task {
            let authorization = await notificationCoordinator.requestAuthorization()
            let snapshot = await notificationCoordinator.snapshot()
            await MainActor.run {
                self.notificationSnapshot = snapshot
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: authorization == .authorized
                            ? "Notification permission is enabled for long-running session completions."
                            : "Notification permission was not granted. Completion alerts stay local to the app."
                    )
                )
            }
        }
    }

    public func activateTailnetProfile(_ profileID: TailnetProfile.ID) {
        Task {
            do {
                let runtime = try await embeddedTailnetManager.activate(profileID: profileID)
                await MainActor.run {
                    self.applyTailnetRuntimeUpdate(runtime)
                    if let profile = runtime.profiles.first(where: { $0.id == profileID }) {
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: profile.kind == .embedded
                                    ? "Activated embedded tailnet profile \(profile.displayName)."
                                    : "Selected external tailnet profile \(profile.displayName)."
                            )
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Tailnet activation failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func beginEmbeddedTailnetAuthentication(_ profileID: TailnetProfile.ID) {
        beginEmbeddedTailnetAuthentication(profileID, onPrepared: nil)
    }

    public func beginEmbeddedTailnetAuthentication(
        _ profileID: TailnetProfile.ID,
        onPrepared: (@MainActor @Sendable (EmbeddedTailnetAuthTicket?) -> Void)?
    ) {
        Task {
            do {
                let runtime = try await embeddedTailnetManager.beginAuthentication(profileID: profileID)
                await MainActor.run {
                    self.applyTailnetRuntimeUpdate(runtime)
                    let ticket = runtime.authSession?.ticket
                    let summary: String
                    if let ticket {
                        summary = "Open \(ticket.authURL.absoluteString) to authenticate \(runtime.profiles.first(where: { $0.id == profileID })?.displayName ?? "the embedded tailnet profile")."
                    } else {
                        summary = "Embedded tailnet login is waiting for user action."
                    }
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: summary
                        )
                    )
                    onPrepared?(ticket)
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Embedded tailnet login could not start: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func refreshEmbeddedTailnetRuntimeStatus() {
        Task {
            let runtime = await embeddedTailnetManager.snapshot()
            await MainActor.run {
                self.applyTailnetRuntimeUpdate(runtime, persist: false)
            }
            await reconcilePersistedLocalStateIfNeeded()
        }
    }

    public func completeEmbeddedTailnetAuthentication(_ profileID: TailnetProfile.ID) {
        Task {
            do {
                let runtime = try await embeddedTailnetManager.completeAuthentication(profileID: profileID)
                await MainActor.run {
                    self.applyTailnetRuntimeUpdate(runtime)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Embedded tailnet authentication is ready for the active profile."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Embedded tailnet authentication failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func resetEmbeddedTailnetAuthentication(_ profileID: TailnetProfile.ID) {
        Task {
            do {
                let runtime = try await embeddedTailnetManager.resetAuthentication(profileID: profileID)
                await MainActor.run {
                    self.applyTailnetRuntimeUpdate(runtime)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Embedded tailnet sign-in was reset for the selected profile."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Embedded tailnet reset failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func deleteTailnetProfile(_ profileID: TailnetProfile.ID) {
        Task {
            do {
                let deletedName = tailnetProfiles.first(where: { $0.id == profileID })?.displayName ?? "the selected profile"
                let runtime = try await embeddedTailnetManager.deleteProfile(profileID: profileID)
                await MainActor.run {
                    self.applyTailnetRuntimeUpdate(runtime)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Deleted tailnet profile \(deletedName)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Tailnet profile deletion failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func addTailnetProfile(
        displayName: String,
        kind: TailnetProfileType,
        controlURLString: String,
        accountLabel: String
    ) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedControlURL = controlURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let controlURL = URL(string: trimmedControlURL),
              TailnetControlURLValidator.isSupported(controlURL) else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Tailnet profiles require an HTTPS control URL."
                )
            )
            return
        }

        Task {
            do {
                let runtime = try await embeddedTailnetManager.saveProfile(
                    TailnetProfileDraft(
                        kind: kind,
                        displayName: trimmedName.isEmpty ? "Custom tailnet" : trimmedName,
                        controlURL: controlURL,
                        accountLabel: trimmedAccountLabel
                    )
                )
                await MainActor.run {
                    self.applyTailnetRuntimeUpdate(runtime)
                    let savedName = runtime.profiles.last?.displayName ?? (trimmedName.isEmpty ? "Custom tailnet" : trimmedName)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Saved \(kind == .embedded ? "embedded" : "external") tailnet profile \(savedName)."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Tailnet profile save failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    public func openCurrentThreadInCodexOnHost() {
        guard let threadID = resolveThreadID(preferredThreadID: nil) else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Open in Codex on Mac requires an active thread first."
                )
            )
            return
        }

        openCodexHandoffURLOnHost(
            "codex://threads/\(threadID)",
            successSummary: "Requested Codex Mac handoff for thread \(threadID)."
        )
    }

    public func continueOnMac() {
        if resolveThreadID(preferredThreadID: nil) != nil {
            openCurrentThreadInCodexOnHost()
            return
        }

        guard activeSession?.workspaceRoot != nil else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Continue on Mac requires a current workspace or thread first."
                )
            )
            return
        }

        openNewCodexThreadOnHost()
    }

    public func openNewCodexThreadOnHost() {
        openCodexHandoffURLOnHost(
            "codex://new",
            successSummary: "Requested a new Codex Mac thread on the host."
        )
    }

    public func revealCurrentWorkspaceInFinderOnHost() {
        guard let workspaceRoot = Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot) else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Reveal in Finder requires a current workspace first."
                )
            )
            return
        }

        let workspaceName = Self.workspaceDisplayName(for: workspaceRoot)
        runHostShellCommandOnSafeLane(
            Self.revealWorkspaceInFinderCommand(workspaceRoot: workspaceRoot),
            pendingSummary: "Requesting Finder reveal for \(workspaceName) on the Mac.",
            successSummary: "Revealed \(workspaceName) in Finder on the Mac.",
            failureSummary: { error in
                "Reveal in Finder failed: \(error.localizedDescription)"
            }
        )
    }

    public func wakeMacDisplayOnHost() {
        let machineName = selectedMachine?.alias ?? selectedMachine?.displayName ?? "the Mac"
        runHostShellCommandOnSafeLane(
            Self.wakeDisplayCommand,
            pendingSummary: "Requesting a display wake signal for \(machineName).",
            successSummary: "Asked \(machineName) to wake its display.",
            failureSummary: { error in
                "Wake display failed: \(error.localizedDescription)"
            }
        )
    }

    public func upgradeToLoopback() {
        guard let cwd = activeSession?.workspaceRoot else {
            return
        }

        automaticLoopbackUpgradeSuppressedUntilReconnect = false
        Task {
            await attemptLoopbackUpgrade(cwd: cwd)
        }
    }

    public func stopLoopbackListener() {
        automaticLoopbackUpgradeSuppressedUntilReconnect = true
        lastAutomaticLoopbackUpgradeAttemptAt = Date()
        if activeProtocolKind == .websocket {
            fallbackToSafeLane(
                summary: "Returned to the SSH safe lane. Stopping the loopback listener in the background."
            )
        }

        Task {
            do {
                try await safeLaneClient.stopLocalPortForward()
                try await safeLaneClient.stopLoopbackListener()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Loopback listener stopped on the host."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Loopback listener stop failed on the host: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func beginLiveTurn(text: String, preferredThreadID: String? = nil) {
        beginLiveTurn(
            request: PendingTurnRequest(
                text: text,
                attachments: [],
                summary: text
            ),
            preferredThreadID: preferredThreadID
        )
    }

    private func beginLiveTurn(request: PendingTurnRequest, preferredThreadID: String? = nil) {
        activeTurnID = "pending"
        hostRuntimeTransportStatus = nil
        updateTranscriptMessageDeliveryState(messageID: request.transcriptMessageID, to: .sending)
        markClientSubagentTask(request.clientSubagentTaskID, as: .running)
        if let task = clientSubagentTasks.first(where: { $0.id == request.clientSubagentTaskID }) {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Starting client-orchestrated subtask \(task.ordinal)/\(clientSubagentTasks.count): \(task.title)"
                )
            )
        }

        Task {
            do {
                let hadConcreteThreadBeforeTurn = Self.normalizedThreadID(self.activeSession?.threadID) != nil
                let initialThreadID = try await self.ensureLiveThreadID(preferredThreadID: preferredThreadID)
                self.automaticLoopbackUpgradePending = Self.shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
                    hadConcreteThreadBeforeTurn: hadConcreteThreadBeforeTurn,
                    preferLoopbackUpgrade: self.shouldAutoUpgradeLoopback,
                    unavailableSelectedThreadID: self.activeUnavailableSelectedThreadID,
                    threadID: self.activeSession?.threadID
                ) || self.automaticLoopbackUpgradePending
                if let upgradeCwd = self.activeSession?.workspaceRoot ?? self.resolvedWorkspaceRoot() {
                    await self.maybeAttemptAutomaticLoopbackUpgrade(cwd: upgradeCwd)
                }
                await self.attemptSigningSensitiveLoopbackUpgradeIfNeeded(for: request)
                try await self.ensureSigningSensitiveHostReadinessIfNeeded(for: request)
                let threadID = Self.turnStartThreadID(
                    preferredThreadID: preferredThreadID,
                    boundProtocolThreadID: self.boundProtocolThreadID(preferredThreadID: preferredThreadID),
                    activeSessionThreadID: self.activeSession?.threadID,
                    initialThreadID: initialThreadID
                )
                let input = try await self.turnInput(for: request)
                let modelOverride = request.model ?? self.activeThreadModelLabel
                let collaborationMode = request.collaborationMode
                    ?? self.collaborationModePayload(modelOverride: modelOverride)
                let turnOptions = self.requestedTurnExecutionOptions(
                    session: self.activeSession,
                    model: modelOverride,
                    effort: request.effort ?? self.selectedReasoningEffort,
                    collaborationMode: collaborationMode
                )
                let turn: CodexTurnContext
                switch activeProtocolKind {
                case .stdio:
                    turn = try await safeLaneClient.startTurn(
                        threadID: threadID,
                        input: input,
                        options: turnOptions
                    )
                case .websocket:
                    if shouldForceLoopbackTurnFailureForUITests {
                        throw CodexWebSocketError.invalidResponse("Forced loopback websocket failure for UI testing.")
                    }
                    turn = try await loopbackClient.startTurn(
                        threadID: threadID,
                        input: input,
                        options: turnOptions
                    )
                case .directEndpoint:
                    turn = try await loopbackClient.startTurn(
                        threadID: threadID,
                        input: input,
                        options: turnOptions
                    )
                }

                await MainActor.run {
                    self.activeTurnID = turn.id
                    self.applyRequestedTurnExecutionProfileState(turnOptions)
                    self.updateTranscriptMessageDeliveryState(messageID: request.transcriptMessageID, to: nil)
                    self.updateSessionQueue()
                }
            } catch {
                await MainActor.run {
                    self.activeTurnID = nil
                    self.markClientSubagentTask(
                        request.clientSubagentTaskID,
                        as: .failed,
                        resultSummary: error.localizedDescription
                    )
                    if let unavailableSelectedThreadError = error as? UnavailableSelectedThreadError {
                        self.updateTranscriptMessageDeliveryState(messageID: request.transcriptMessageID, to: .failed)
                        self.updateSessionState(
                            transportState: .connected,
                            lastErrorSummary: unavailableSelectedThreadError.localizedDescription
                        )
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: unavailableSelectedThreadError.localizedDescription
                            )
                        )
                        Task {
                            await self.refreshRepoBrowserSessions(limit: 20, fetchAllPages: false)
                        }
                    } else if let readinessError = error as? SigningSensitiveHostReadinessError {
                        self.surfaceSigningSensitiveHostReadinessFailure(
                            for: request,
                            detail: readinessError.detail
                        )
                    } else if self.activeProtocolKind == .websocket {
                        self.markPreferredLaneDisconnectedAfterLoopbackFailure(
                            summary: "Loopback websocket failed. Reconnecting the preferred Codex websocket lane.",
                            detail: error.localizedDescription
                        )
                        if request.requiresSigningSensitiveHostReadiness {
                            self.surfaceSigningSensitiveHostReadinessFailure(
                                for: request,
                                detail: Self.signingSensitiveLoopbackFailureDetail(error.localizedDescription)
                            )
                        } else {
                            let queuedRequest = self.appendOrUpdateLocalUserTranscriptMessage(
                                for: request,
                                deliveryState: .queued
                            )
                            self.enqueuePendingTurnRequests([queuedRequest])
                            self.transcript.append(
                                SessionMessage(
                                    role: .system,
                                    text: "Reconnecting the Codex websocket lane before sending."
                                )
                            )
                            self.connectSelectedMachine(preferLoopbackUpgrade: self.shouldAutoUpgradeLoopback)
                        }
                    } else {
                        self.updateTranscriptMessageDeliveryState(messageID: request.transcriptMessageID, to: .failed)
                        self.connectionState = .failed(error.localizedDescription)
                        self.updateSessionState(transportState: .failed, lastErrorSummary: error.localizedDescription)
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Failed to start turn: \(error.localizedDescription)"
                            )
                        )
                        self.scheduleSessionFailure(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func ensureLiveThreadID(preferredThreadID: String?) async throws -> String {
        if let threadID = boundProtocolThreadID(preferredThreadID: preferredThreadID) {
            return threadID
        }

        if let sessionThreadID = activeSession?.threadID {
            let existingProfileState = activeSession?.executionProfileState
            let threadOptions = requestedThreadExecutionOptions(
                session: activeSession,
                cwd: resolvedWorkspaceRoot(),
                model: nil,
                baselineConfig: existingProfileState?.baselineConfig
            )

            do {
                let resumed = try await resumeThreadOnActiveConnection(
                    threadID: sessionThreadID,
                    options: threadOptions,
                    allowSnapshotFallback: false
                )
                let updatedExecutionState = updatedExecutionProfileState(
                    from: existingProfileState,
                    snapshot: SessionExecutionSnapshot(
                        runtime: resumed.executionProfile?.runtime ?? existingProfileState?.profile.runtime,
                        baselineConfig: existingProfileState?.baselineConfig,
                        constraints: existingProfileState?.constraints,
                        support: existingProfileState?.support ?? .init(serverRequestRouting: .supported)
                    ),
                    effectiveProfile: resumed.executionProfile ?? existingProfileState?.profile,
                    requestedThreadOptions: threadOptions,
                    overridesKind: .supported,
                    detectResumeMismatch: true
                )

                await MainActor.run {
                    self.upsertSession(
                        threadID: resumed.thread.id,
                        routeID: self.activeSession?.routeID ?? self.selectedBootstrapRoute?.id,
                        workspaceRoot: resumed.cwd,
                        lastKnownProtocol: self.activeProtocolKind,
                        lastKnownRouteKind: self.activeSession?.lastKnownRouteKind ?? self.selectedBootstrapRoute?.kind,
                        lastKnownBootstrap: self.activeSession?.lastKnownBootstrap
                            ?? (self.selectedBootstrapRoute?.kind == .companionDirect ? .companionManaged : .standardSSH),
                        lastModel: resumed.model,
                        reasoningEffort: resumed.reasoningEffort,
                        executionProfileState: updatedExecutionState,
                        bindProtocolThreadID: true
                    )
                    self.applyLiveThreadSnapshot(resumed.thread)
                    self.persistActiveExecutionProfileState(updatedExecutionState)
                    self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
                }

                return resumed.thread.id
            } catch {
                if shouldTreatResumeErrorAsUnavailableSelectedThread(error) {
                    await MainActor.run {
                        self.recoverFromUnavailableSelectedThread()
                    }
                    throw UnavailableSelectedThreadError(threadID: sessionThreadID)
                } else {
                    throw error
                }
            }
        }

        if let unavailableThreadID = activeUnavailableSelectedThreadID,
           activeSessionRequiresExplicitThreadSelection {
            throw UnavailableSelectedThreadError(threadID: unavailableThreadID)
        }

        guard let cwd = resolvedWorkspaceRoot() else {
            throw CodexConnectionAutomationError("No active \(protocolLabel.lowercased()) thread is ready yet. Reconnect first.")
        }

        let modelOverride = Self.normalizedModelIdentifier(activeSession?.lastModel)
        let existingProfileState = activeSession?.executionProfileState
        let threadOptions = requestedThreadExecutionOptions(
            session: activeSession,
            cwd: cwd,
            model: modelOverride,
            baselineConfig: existingProfileState?.baselineConfig
        )
        let thread: CodexThreadContext
        switch activeProtocolKind {
        case .stdio:
            thread = try await safeLaneClient.startThread(options: threadOptions)
        case .websocket, .directEndpoint:
            thread = try await loopbackClient.startThread(options: threadOptions)
        }

        let updatedExecutionState = updatedExecutionProfileState(
            from: existingProfileState,
            snapshot: SessionExecutionSnapshot(
                runtime: existingProfileState?.profile.runtime,
                baselineConfig: existingProfileState?.baselineConfig,
                constraints: existingProfileState?.constraints,
                support: existingProfileState?.support ?? .init(serverRequestRouting: .supported)
            ),
            effectiveProfile: thread.executionProfile,
            requestedThreadOptions: threadOptions,
            overridesKind: .supported
        )

        await MainActor.run {
            self.upsertSession(
                threadID: thread.id,
                routeID: self.activeSession?.routeID ?? self.selectedBootstrapRoute?.id,
                workspaceRoot: thread.cwd,
                lastKnownProtocol: self.activeProtocolKind,
                lastKnownRouteKind: self.activeSession?.lastKnownRouteKind ?? self.selectedBootstrapRoute?.kind,
                lastKnownBootstrap: self.activeSession?.lastKnownBootstrap
                    ?? (self.selectedBootstrapRoute?.kind == .companionDirect ? .companionManaged : .standardSSH),
                lastModel: thread.model,
                reasoningEffort: thread.reasoningEffort,
                executionProfileState: updatedExecutionState
            )
            self.persistActiveExecutionProfileState(updatedExecutionState)
            self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
        }

        return thread.id
    }

    private func handle(event: CodexLiveEvent, source: CodexProtocolKind) {
        switch event {
        case let .configWarning(summary):
            if recordHostRuntimeTransportStatus(from: summary) {
                return
            }
            transcript.append(SessionMessage(role: .system, text: Self.hostRuntimeNoticeText(summary)))
        case let .threadStarted(threadID):
            // `thread/started` does not include a workspace root, so rebinding an
            // already-selected session here can corrupt continuation. Explicit
            // start/resume/fork RPC responses own the durable thread binding.
            if Self.shouldBindServerStartedThreadEvent(
                activeSessionThreadID: activeSession?.threadID,
                existingProtocolThreadID: boundProtocolThreadID(preferredThreadID: nil)
            ) {
                syncKnownThreadIDs(threadID: threadID, protocolKind: source)
            }
        case let .turnStarted(turnID):
            suppressNextWebsocketErrorAfterCompletedTurn = false
            activeTurnID = turnID
            hostRuntimeTransportStatus = nil
            updateSessionState(transportState: .connected, lastErrorSummary: nil)
        case let .turnCompleted(turnID):
            suppressNextWebsocketErrorAfterCompletedTurn = source == .websocket
            activeTurnID = nil
            hostRuntimeTransportStatus = nil
            finalizeAssistantMessage()
            finishAllLiveActivityMessages()
            let assistantText = transcript.last(where: { $0.role == .assistant })?.text ?? "Turn complete"
            markClientSubagentTask(activeClientSubagentTaskID, as: .completed, resultSummary: assistantText)
            updateLastTurn(turnID: turnID, summary: assistantText)
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Turn \(turnID) completed."
                )
            )
            Task {
                if let session = activeSession {
                    try? await notificationCoordinator.schedule(
                        .sessionCompleted(session: session, summary: assistantText)
                    )
                }
                let notificationSnapshot = await notificationCoordinator.snapshot()
                await MainActor.run {
                    self.notificationSnapshot = notificationSnapshot
                }
            }
            Task {
                await refreshCurrentThreadHistoryIfPossible()
            }
            if let upgradeCwd = activeSession?.workspaceRoot ?? resolvedWorkspaceRoot() {
                Task {
                    await self.maybeAttemptAutomaticLoopbackUpgrade(cwd: upgradeCwd)
                }
            }
            if let nextRequest = dequeuePendingTurn(),
               resolveThreadID(preferredThreadID: nil) != nil {
                updateSessionQueue()
                beginLiveTurn(request: nextRequest)
            }
        case let .agentMessageDelta(delta):
            appendAssistantDelta(delta)
        case let .agentMessageCompleted(message):
            appendAssistantCompletion(message)
        case let .activity(activity):
            handleLiveActivity(activity)
        case let .approvalRequested(request):
            pendingApprovalRequest = request
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: request.reason ?? request.summary
                )
            )
        case let .structuredUserInputRequested(request):
            pendingStructuredUserInputRequest = request
            transcript.append(
                SessionMessage(
                    role: .system,
                    kind: .userInputPrompt,
                    text: Self.structuredPromptSummaryText(request.prompt),
                    structuredPrompt: request.prompt
                )
            )
        case let .serverRequestUnsupported(request):
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "The host runtime requested \(request.method), which this client does not support yet. The session stayed connected, but that capability is unavailable here."
                )
            )
        case let .error(message):
            if source == .websocket {
                if Self.shouldSuppressWebsocketErrorAfterCompletedTurn(
                    source: source,
                    suppressNext: suppressNextWebsocketErrorAfterCompletedTurn
                ) {
                    suppressNextWebsocketErrorAfterCompletedTurn = false
                    activeTurnID = nil
                    finishAllLiveActivityMessages()
                    updateSessionState(transportState: .connected, lastErrorSummary: nil)
                    lastLoopbackUpgradeStandbyReason = message
                    Self.logger.log("Ignoring websocket error immediately after completed turn: \(message, privacy: .public)")
                    return
                }
                if Self.shouldFallbackFromWebsocketError(
                    protocolKind: activeProtocolKind,
                    loopbackUpgradeInProgress: loopbackUpgradeInProgress,
                    activeTurnID: activeTurnID,
                    message: message
                ) {
                    markPreferredLaneDisconnectedAfterLoopbackFailure(
                        summary: "Loopback listener degraded. Reconnecting the preferred Codex websocket lane.",
                        detail: message
                    )
                    connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
                } else {
                    if Self.isBenignWebsocketCancellationMessage(message) {
                        activeTurnID = nil
                        finishAllLiveActivityMessages()
                        updateSessionState(transportState: .connected, lastErrorSummary: nil)
                    }
                    lastLoopbackUpgradeStandbyReason = message
                    Self.logger.log("Ignoring non-fatal websocket runtime message: \(message, privacy: .public)")
                    return
                }
            } else {
                connectionState = .failed(message)
                updateSessionState(transportState: .failed, lastErrorSummary: message)
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Transport error: \(message)"
                    )
                )
                scheduleSessionFailure(message)
            }
            activeTurnID = nil
            hostRuntimeTransportStatus = nil
            finishAllLiveActivityMessages()
            markClientSubagentTask(activeClientSubagentTaskID, as: .failed, resultSummary: message)
        }
    }

    @discardableResult
    private func recordHostRuntimeTransportStatus(from summary: String) -> Bool {
        guard let status = Self.hostRuntimeTransportStatus(from: summary) else {
            return false
        }

        hostRuntimeTransportStatus = status
        removeHostRuntimeTransportNoticeMessages()
        return true
    }

    private func removeHostRuntimeTransportNoticeMessages() {
        transcript.removeAll { message in
            message.role == .system
                && message.kind == .standard
                && Self.hostRuntimeTransportStatus(from: message.text) != nil
        }
    }

    private func handleLiveActivity(_ activity: CodexLiveActivityEvent) {
        guard shouldApplyLiveActivity(activity) else {
            return
        }

        if let turnID = activity.turnID,
           activeTurnID == nil,
           Self.activityKindImpliesActiveTurn(activity.kind) {
            activeTurnID = turnID
        }

        updateSessionState(transportState: .connected, lastErrorSummary: nil)

        if let text = activity.text,
           !text.isEmpty,
           let messageKind = Self.sessionMessageKind(for: activity.kind) {
            appendLiveActivityText(text, kind: messageKind, activity: activity)
        }

        if activity.kind == .itemCompleted,
           let itemID = activity.itemID {
            finishLiveActivityMessages(matchingItemID: itemID)
        }

        if activity.shouldRefreshThread {
            Task {
                await refreshCurrentThreadHistoryIfPossible()
            }
        }
    }

    private func shouldApplyLiveActivity(_ activity: CodexLiveActivityEvent) -> Bool {
        guard let eventThreadID = activity.threadID else {
            return activeTurnID != nil
        }

        guard let currentThreadID = resolveThreadID(preferredThreadID: nil) else {
            return true
        }

        return eventThreadID == currentThreadID
    }

    private static func activityKindImpliesActiveTurn(_ kind: CodexLiveActivityEvent.Kind) -> Bool {
        switch kind {
        case .planDelta, .reasoningDelta, .commandExecutionOutputDelta, .fileChangeOutputDelta:
            return true
        case .threadStatusChanged, .tokenUsageUpdated, .itemStarted, .itemCompleted, .fileChangePatchUpdated,
             .turnDiffUpdated, .turnPlanUpdated, .rawResponseItemCompleted:
            return false
        }
    }

    private static func sessionMessageKind(for kind: CodexLiveActivityEvent.Kind) -> SessionMessage.Kind? {
        switch kind {
        case .planDelta, .turnPlanUpdated:
            return .plan
        case .reasoningDelta:
            return .reasoning
        case .commandExecutionOutputDelta:
            return .commandExecution
        case .fileChangeOutputDelta, .fileChangePatchUpdated, .turnDiffUpdated:
            return .fileChange
        case .threadStatusChanged, .tokenUsageUpdated, .itemStarted, .itemCompleted, .rawResponseItemCompleted:
            return nil
        }
    }

    private func appendLiveActivityText(
        _ text: String,
        kind: SessionMessage.Kind,
        activity: CodexLiveActivityEvent
    ) {
        let key = Self.liveActivityMessageKey(for: activity, kind: kind)
        if let key,
           let messageID = streamingActivityMessageIDs[key],
           let index = transcript.firstIndex(where: { $0.id == messageID }) {
            transcript[index].text += text
            transcript[index].isStreaming = true
            return
        }

        let message = SessionMessage(
            role: .system,
            kind: kind,
            text: text,
            isStreaming: activity.itemID != nil
        )
        transcript.append(message)
        if let key {
            streamingActivityMessageIDs[key] = message.id
        }
    }

    private static func liveActivityMessageKey(
        for activity: CodexLiveActivityEvent,
        kind: SessionMessage.Kind
    ) -> String? {
        guard let itemID = activity.itemID else {
            return nil
        }

        return [
            activity.threadID ?? "",
            activity.turnID ?? "",
            itemID,
            kind.rawValue
        ].joined(separator: "::")
    }

    private func finishLiveActivityMessages(matchingItemID itemID: String) {
        let matchingKeys = streamingActivityMessageIDs.keys.filter { key in
            key.contains("::\(itemID)::")
        }

        for key in matchingKeys {
            guard let messageID = streamingActivityMessageIDs.removeValue(forKey: key),
                  let index = transcript.firstIndex(where: { $0.id == messageID }) else {
                continue
            }
            transcript[index].isStreaming = false
        }
    }

    private func finishAllLiveActivityMessages() {
        let messageIDs = Set(streamingActivityMessageIDs.values)
        streamingActivityMessageIDs.removeAll()
        for index in transcript.indices where messageIDs.contains(transcript[index].id) {
            transcript[index].isStreaming = false
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if let lastIndex = transcript.indices.last,
           transcript[lastIndex].role == .assistant,
           transcript[lastIndex].isStreaming {
            transcript[lastIndex].text += delta
        } else {
            transcript.append(
                SessionMessage(
                    role: .assistant,
                    text: delta,
                    isStreaming: true
                )
            )
        }
    }

    private func appendAssistantCompletion(_ text: String) {
        if let lastIndex = transcript.indices.last,
           transcript[lastIndex].role == .assistant,
           transcript[lastIndex].isStreaming {
            transcript[lastIndex].text = text
            transcript[lastIndex].isStreaming = false
        } else {
            transcript.append(SessionMessage(role: .assistant, text: text))
        }
    }

    private func finalizeAssistantMessage() {
        guard let lastIndex = transcript.indices.last,
              transcript[lastIndex].role == .assistant else {
            return
        }

        transcript[lastIndex].isStreaming = false
    }

    private func captureExecutionSnapshot(
        for protocolKind: CodexProtocolKind,
        runtimeFallback: CodexResolvedRuntime? = nil
    ) async -> SessionExecutionSnapshot {
        var support = activeSession?.executionProfileState?.support ?? .init()
        support.serverRequestRouting = .supported

        let runtime: CodexResolvedRuntime? = switch protocolKind {
        case .stdio:
            await safeLaneClient.runtimeDescriptor()
                ?? runtimeFallback
                ?? runtimeCapabilityDiagnostics?.resolvedRuntime
                ?? activeSession?.executionProfileState?.profile.runtime
        case .websocket, .directEndpoint:
            runtimeFallback
                ?? runtimeCapabilityDiagnostics?.resolvedRuntime
                ?? activeSession?.executionProfileState?.profile.runtime
        }

        let baselineConfig: CodexExecutionBaselineConfigSnapshot?
        do {
            switch protocolKind {
            case .stdio:
                baselineConfig = try await safeLaneClient.readConfig()
            case .websocket, .directEndpoint:
                baselineConfig = try await loopbackClient.readConfig()
            }
            support.configRead = .supported
        } catch {
            baselineConfig = activeSession?.executionProfileState?.baselineConfig
        }

        let constraints: CodexExecutionConstraintsSnapshot?
        do {
            switch protocolKind {
            case .stdio:
                constraints = try await safeLaneClient.readConfigRequirements()
            case .websocket, .directEndpoint:
                constraints = try await loopbackClient.readConfigRequirements()
            }
            support.configRequirementsRead = .supported
        } catch {
            constraints = activeSession?.executionProfileState?.constraints
        }

        return SessionExecutionSnapshot(
            runtime: runtime,
            baselineConfig: baselineConfig,
            constraints: constraints,
            support: support
        )
    }

    func requestedThreadExecutionOptions(
        session: SessionRecord?,
        cwd: String?,
        model: String?,
        baselineConfig: CodexExecutionBaselineConfigSnapshot?
    ) -> CodexThreadExecutionOptions {
        var options = CodexExecutionProfileCoordinator.requestedThreadExecutionOptions(
            from: session,
            baseline: baselineConfig
        )
        if let preferredApprovalPolicy {
            options.approvalPolicy = preferredApprovalPolicy
        }
        if let preferredSandboxMode {
            options.sandboxMode = preferredSandboxMode
        }
        options.cwd = cwd
        options.model = model
        return options
    }

    func requestedTurnExecutionOptions(
        session: SessionRecord?,
        model: String?,
        effort: CodexReasoningEffort?,
        collaborationMode: CodexCollaborationMode?
    ) -> CodexTurnExecutionOptions {
        var options = CodexTurnExecutionOptions(
            model: model,
            effort: effort,
            collaborationMode: collaborationMode
        )

        if let preferredApprovalPolicy {
            options.approvalPolicy = preferredApprovalPolicy
        } else if let session {
            options.approvalPolicy = session.executionProfileState?.profile.approvalPolicy.requested
                ?? session.executionProfileState?.profile.approvalPolicy.effective
                ?? session.executionProfileState?.baselineConfig?.approvalPolicy
        }
        if let preferredSandboxPolicy = preferredTurnSandboxPolicy(fallbackWorkspaceRoot: session?.workspaceRoot) {
            options.sandboxPolicy = preferredSandboxPolicy
        } else if let session {
            options.sandboxPolicy = turnSandboxPolicy(
                from: session.executionProfileState,
                fallbackWorkspaceRoot: session.workspaceRoot
            )
        }

        return options
    }

    private func preferredTurnSandboxPolicy(fallbackWorkspaceRoot: String?) -> CodexSandboxPolicy? {
        switch preferredSandboxMode {
        case .dangerFullAccess:
            return .dangerFullAccess
        case .readOnly:
            return .readOnly(readAccess: .fullAccess, networkAccess: false)
        case .workspaceWrite:
            return .workspaceWrite(
                writableRoots: fallbackWorkspaceRoot.map { [$0] } ?? [],
                readAccess: .fullAccess,
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        case nil:
            return nil
        }
    }

    private func turnSandboxPolicy(
        from state: CodexExecutionProfileState?,
        fallbackWorkspaceRoot: String?
    ) -> CodexSandboxPolicy? {
        guard let state else {
            return nil
        }

        let sandboxMode = state.profile.sandboxMode.requested
            ?? state.profile.sandboxMode.effective
            ?? state.baselineConfig?.sandboxMode
        let networkAccess = state.profile.networkAccess.effective
            ?? state.baselineConfig?.networkAccess
            ?? false
        let readAccess = sandboxReadAccess(
            kind: state.profile.readAccess.effective ?? state.baselineConfig?.readAccess,
            readableRoots: state.profile.extraReadableRoots.effective
                ?? state.baselineConfig?.extraReadableRoots
                ?? []
        )

        switch sandboxMode {
        case "danger-full-access":
            return .dangerFullAccess
        case "read-only":
            return .readOnly(
                readAccess: readAccess,
                networkAccess: networkAccess
            )
        case "workspace-write":
            var writableRoots = state.profile.writableRoots.effective
                ?? state.baselineConfig?.writableRoots
                ?? []
            if writableRoots.isEmpty, let fallbackWorkspaceRoot {
                writableRoots = [fallbackWorkspaceRoot]
            }
            return .workspaceWrite(
                writableRoots: writableRoots,
                readAccess: readAccess,
                networkAccess: networkAccess,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        case "externalSandbox":
            return .externalSandbox(networkEnabled: state.profile.networkAccess.effective)
        default:
            return nil
        }
    }

    private func sandboxReadAccess(
        kind: CodexReadAccessKind?,
        readableRoots: [String]
    ) -> CodexSandboxReadAccess {
        switch kind ?? .unknown {
        case .restricted:
            return .restricted(includePlatformDefaults: true, readableRoots: readableRoots)
        case .fullAccess:
            return .fullAccess
        case .unknown, .unsupported:
            return readableRoots.isEmpty
                ? .fullAccess
                : .restricted(includePlatformDefaults: true, readableRoots: readableRoots)
        }
    }

    private func requestedThreadOverridesDiffer(
        requested: CodexThreadExecutionOptions,
        effectiveProfile: CodexExecutionProfile?
    ) -> Bool {
        if let approvalPolicy = requested.approvalPolicy,
           effectiveProfile?.approvalPolicy.effective != approvalPolicy {
            return true
        }

        if let sandboxMode = requested.sandboxMode?.rawValue,
           effectiveProfile?.sandboxMode.effective != sandboxMode {
            return true
        }

        return false
    }

    private func updatedExecutionProfileState(
        from existing: CodexExecutionProfileState?,
        snapshot: SessionExecutionSnapshot,
        effectiveProfile: CodexExecutionProfile?,
        requestedThreadOptions: CodexThreadExecutionOptions? = nil,
        overridesKind: CodexExecutionSupportState = .unknown,
        detectResumeMismatch: Bool = false
    ) -> CodexExecutionProfileState {
        var support = snapshot.support
        if let requestedThreadOptions,
           requestedThreadOptions.approvalPolicy != nil || requestedThreadOptions.sandboxMode != nil {
            if detectResumeMismatch {
                support.threadResumeOverrides = overridesKind
            } else {
                support.threadStartOverrides = overridesKind
            }
        }

        let requestedOverrideSupport: CodexExecutionSupportState? = if requestedThreadOptions == nil {
            nil
        } else if detectResumeMismatch {
            support.threadResumeOverrides
        } else {
            support.threadStartOverrides
        }

        var state = CodexExecutionProfileCoordinator.updateProfileState(
            existing: existing,
            runtime: snapshot.runtime,
            baseline: snapshot.baselineConfig,
            constraints: snapshot.constraints,
            support: support,
            effectiveProfile: effectiveProfile,
            requestedOverride: requestedThreadOptions.map(CodexRequestedExecutionOverride.init(threadOptions:)),
            requestedOverrideSupport: requestedOverrideSupport
        )

        if detectResumeMismatch,
           let requestedThreadOptions,
           requestedThreadOverridesDiffer(requested: requestedThreadOptions, effectiveProfile: effectiveProfile) {
            state = CodexExecutionProfileCoordinator.markResumeOverrideUnsupported(
                existing: state,
                effectiveProfile: effectiveProfile
            )
        }

        return state
    }

    @MainActor
    private func syncActiveExecutionProfileWithPreferredDefaults() {
        guard hasActiveExecutionContext,
              preferredApprovalPolicy != nil || preferredSandboxMode != nil else {
            return
        }

        let previousState = activeSession?.executionProfileState
        var existingState = previousState ?? .init()
        existingState.profile.approvalPolicy.requested = preferredApprovalPolicy
        existingState.profile.sandboxMode.requested = preferredSandboxMode?.rawValue

        let updatedState = CodexExecutionProfileCoordinator.updateProfileState(
            existing: existingState,
            runtime: existingState.profile.runtime,
            baseline: existingState.baselineConfig,
            constraints: existingState.constraints,
            support: existingState.support,
            effectiveProfile: existingState.profile,
            requestedOverride: CodexRequestedExecutionOverride(
                approvalPolicy: preferredApprovalPolicy,
                sandboxMode: preferredSandboxMode?.rawValue
            ),
            requestedOverrideSupport: .unknown
        )

        persistActiveExecutionProfileState(updatedState)
    }

    @MainActor
    func applyRequestedTurnExecutionProfileState(_ options: CodexTurnExecutionOptions) {
        let requestedOverride = CodexRequestedExecutionOverride(turnOptions: options)
        guard requestedOverride.hasOverride else {
            return
        }

        let previousState = activeSession?.executionProfileState
        var support = previousState?.support ?? .init()
        if support.turnStartOverrides != .unsupported {
            support.turnStartOverrides = .supported
        }

        var effectiveProfile = previousState?.profile
        if let requestedApproval = requestedOverride.approvalPolicy,
           effectiveProfile?.approvalPolicy.effective != requestedApproval {
            effectiveProfile?.approvalPolicy.effective = nil
        }
        if let requestedSandbox = requestedOverride.sandboxMode,
           effectiveProfile?.sandboxMode.effective != requestedSandbox {
            effectiveProfile?.sandboxMode.effective = nil
        }

        let updatedState = CodexExecutionProfileCoordinator.updateProfileState(
            existing: previousState,
            runtime: previousState?.profile.runtime,
            baseline: previousState?.baselineConfig,
            constraints: previousState?.constraints,
            support: support,
            effectiveProfile: effectiveProfile,
            requestedOverride: requestedOverride,
            requestedOverrideSupport: support.turnStartOverrides
        )

        persistActiveExecutionProfileState(updatedState)
    }

    private func persistActiveExecutionProfileState(_ state: CodexExecutionProfileState?) {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)
        recentSessions[index].executionProfileState = state
        activeSessionID = recentSessions[index].id
        activeExecutionProfileState = state

        if let runtime = state?.profile.runtime {
            if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[machineIndex].capabilities.resolvedRuntime = runtime
                machines[machineIndex].capabilities.codexInstalled = true
                machines[machineIndex].capabilities.supportsAppServer = true
                machines[machineIndex].capabilities.codexVersion = runtime.version ?? machines[machineIndex].capabilities.codexVersion
                if runtime.provenance == .appBundle || runtime.provenance == .otherAppBundle {
                    machines[machineIndex].capabilities.codexAppInstalled = true
                }
            }

            var diagnostics = runtimeCapabilityDiagnostics ?? baseCapabilityDiagnostics
            diagnostics.resolvedRuntime = runtime
            diagnostics.codexInstalled = true
            diagnostics.codexVersion = runtime.version ?? diagnostics.codexVersion
            runtimeCapabilityDiagnostics = diagnostics
        }

        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    private func appendExecutionProfileChangeNoticeIfNeeded(
        previous: CodexExecutionProfileState?,
        current: CodexExecutionProfileState?
    ) {
        guard CodexExecutionProfileCoordinator.effectiveProfileChanged(previous: previous, current: current) else {
            return
        }

        let previousSummary = Self.executionProfileSummaryText(previous)
        let currentSummary = Self.executionProfileSummaryText(current)
        guard previousSummary != currentSummary else {
            return
        }

        transcript.append(
            SessionMessage(
                role: .system,
                text: "Execution profile changed from \(previousSummary) to \(currentSummary)."
            )
        )
    }

    private static func executionProfileSummaryText(_ state: CodexExecutionProfileState?) -> String {
        guard let state else {
            return "unknown authority"
        }

        let approval = executionAuthoritySummaryText(
            state.profile.approvalPolicy,
            unsupportedFallback: "unsupported approvals",
            unknownFallback: "unknown approvals"
        )
        let sandbox = executionAuthoritySummaryText(
            state.profile.sandboxMode,
            unsupportedFallback: "unsupported sandbox",
            unknownFallback: "unknown sandbox"
        )
        let network = state.profile.networkAccess.effective.map { $0 ? "network on" : "network off" } ?? "network unknown"
        return "\(approval), \(sandbox), \(network)"
    }

    private static func executionAuthorityLabel(
        prefix: String,
        authority: CodexExecutionAuthority<String>,
        unsupportedFallback: String,
        unknownFallback: String
    ) -> String {
        "\(prefix): \(executionAuthoritySummaryText(authority, unsupportedFallback: unsupportedFallback, unknownFallback: unknownFallback))"
    }

    private func syncActiveExecutionProfileStateFromCurrentSession() {
        activeExecutionProfileState = activeSession?.executionProfileState
    }

    private static func executionAuthoritySummaryText(
        _ authority: CodexExecutionAuthority<String>,
        unsupportedFallback: String,
        unknownFallback: String
    ) -> String {
        if let effective = authority.effective {
            if let requested = authority.requested,
               requested != effective,
               authority.status == .requested
                || authority.status == .constrained
                || authority.status == .unsupported {
                return "\(effective) (requested \(requested))"
            }

            return effective
        }

        if let requested = authority.requested,
           authority.status == .requested {
            return "requested \(requested)"
        }

        return authority.status == .unsupported ? unsupportedFallback : unknownFallback
    }

    private func upsertSession(
        threadID: String,
        routeID: RouteRecord.ID? = nil,
        workspaceRoot: String? = nil,
        lastKnownProtocol: CodexProtocolKind,
        lastKnownRouteKind: MachineRouteKind?,
        lastKnownBootstrap: BootstrapStrategy,
        lastModel: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil,
        executionProfileState: CodexExecutionProfileState? = nil,
        parentThreadID: String? = nil,
        parentLastTurnID: String? = nil,
        bindProtocolThreadID: Bool = true
    ) {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)
        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(workspaceRoot)

        recentSessions[index].threadID = threadID
        recentSessions[index].unavailableSelectedThreadID = nil
        recentSessions[index].sceneID = sceneID
        recentSessions[index].routeID = routeID ?? recentSessions[index].routeID ?? machine.preferredRoute?.id
        if let workspaceRoot = normalizedWorkspaceRoot {
            recentSessions[index].workspaceRoot = workspaceRoot
        }
        recentSessions[index].lastKnownProtocol = lastKnownProtocol
        recentSessions[index].lastKnownRouteKind = lastKnownRouteKind
        recentSessions[index].lastKnownBootstrap = lastKnownBootstrap
        recentSessions[index].lastMode = Self.workspaceMode(
            for: normalizedWorkspaceRoot ?? recentSessions[index].workspaceRoot
        )
        if let parentThreadID {
            recentSessions[index].parentThreadID = parentThreadID
        }
        if let parentLastTurnID {
            recentSessions[index].parentLastTurnID = parentLastTurnID
        }
        if let normalizedModel = Self.normalizedModelIdentifier(lastModel) {
            recentSessions[index].lastModel = normalizedModel
            if availableModels.contains(where: { $0.model == normalizedModel }) {
                selectedModel = normalizedModel
            }
        }
        if let reasoningEffort {
            let descriptor = Self.normalizedModelIdentifier(recentSessions[index].lastModel)
                .flatMap { model in availableModels.first(where: { $0.model == model }) }
                ?? selectedModelDescriptor
            selectedReasoningEffort = supportedReasoningEffort(reasoningEffort, for: descriptor)
            recentSessions[index].lastReasoningEffort = Self.reasoningLevel(for: selectedReasoningEffort)
        }
        if let executionProfileState {
            recentSessions[index].executionProfileState = executionProfileState
        }
        recentSessions[index].isArchived = false
        recentSessions[index].transportState = .connected
        recentSessions[index].lastErrorSummary = nil
        recentSessions[index].lastOpenedAt = .now
        activeSessionID = recentSessions[index].id
        activeExecutionProfileState = recentSessions[index].executionProfileState
        syncKnownThreadIDs(
            threadID: bindProtocolThreadID ? threadID : nil,
            protocolKind: lastKnownProtocol
        )
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    private func bindWorkspaceOnlySession(
        routeID: RouteRecord.ID?,
        workspaceRoot: String?,
        lastKnownProtocol: CodexProtocolKind,
        lastKnownRouteKind: MachineRouteKind?,
        lastKnownBootstrap: BootstrapStrategy,
        executionProfileState: CodexExecutionProfileState?
    ) {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)
        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(workspaceRoot)
        recentSessions[index].sceneID = sceneID
        recentSessions[index].routeID = routeID ?? recentSessions[index].routeID ?? machine.preferredRoute?.id
        recentSessions[index].threadID = nil
        recentSessions[index].unavailableSelectedThreadID = nil
        if let normalizedWorkspaceRoot {
            recentSessions[index].workspaceRoot = normalizedWorkspaceRoot
        }
        recentSessions[index].lastKnownProtocol = lastKnownProtocol
        recentSessions[index].lastKnownRouteKind = lastKnownRouteKind
        recentSessions[index].lastKnownBootstrap = lastKnownBootstrap
        recentSessions[index].lastMode = Self.workspaceMode(
            for: normalizedWorkspaceRoot ?? recentSessions[index].workspaceRoot
        )
        if let executionProfileState {
            recentSessions[index].executionProfileState = executionProfileState
        }
        recentSessions[index].isArchived = false
        recentSessions[index].transportState = .connected
        recentSessions[index].lastErrorSummary = nil
        recentSessions[index].lastOpenedAt = .now
        activeSessionID = recentSessions[index].id
        activeExecutionProfileState = recentSessions[index].executionProfileState
        syncKnownThreadIDs(threadID: nil, replaceAll: true)
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    private func seededExecutionProfileState(for machineID: MachineRecord.ID) -> CodexExecutionProfileState? {
        if let activeSession, activeSession.machineID == machineID,
           let executionProfileState = activeSession.executionProfileState {
            return executionProfileState
        }

        return recentSessions
            .filter { $0.machineID == machineID }
            .sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt })
            .compactMap(\.executionProfileState)
            .first
    }

    private func markRouteConnectionSuccess(
        routeID: RouteRecord.ID,
        machineID: MachineRecord.ID
    ) {
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              let routeIndex = machines[machineIndex].routes.firstIndex(where: { $0.id == routeID }) else {
            return
        }

        machines[machineIndex].lastConnectedAt = .now
        machines[machineIndex].lastSuccessfulRouteID = routeID
        machines[machineIndex].preferredRouteID = routeID
        machines[machineIndex].routes[routeIndex].health = .healthy
        machines[machineIndex].routes[routeIndex].lastCheckedAt = .now
        machines[machineIndex].routes[routeIndex].lastSuccessAt = .now
        machines[machineIndex].routes[routeIndex].lastFailureAt = nil
        machines[machineIndex].routes[routeIndex].failureReasonCode = nil
    }

    private func activateSession(
        _ session: SessionRecord,
        reconnect: Bool,
        bindProtocolThreadID: Bool = false
    ) {
        guard let machine = machines.first(where: { $0.id == session.machineID }) else {
            return
        }

        var session = session
        session.workspaceRoot = Self.normalizedWorkspaceRoot(session.workspaceRoot)
        session.lastMode = Self.workspaceMode(for: session.workspaceRoot)
        selectedMachineID = machine.id
        let index = activationIndex(for: session, machine: machine)
        let existingParentThreadID = recentSessions.indices.contains(index) ? recentSessions[index].parentThreadID : nil
        let existingParentLastTurnID = recentSessions.indices.contains(index) ? recentSessions[index].parentLastTurnID : nil
        recentSessions[index] = session
        recentSessions[index].sceneID = sceneID
        recentSessions[index].lastOpenedAt = .now
        recentSessions[index].isArchived = false
        recentSessions[index].parentThreadID = session.parentThreadID ?? existingParentThreadID
        recentSessions[index].parentLastTurnID = session.parentLastTurnID ?? existingParentLastTurnID
        activeSessionID = recentSessions[index].id
        activeExecutionProfileState = recentSessions[index].executionProfileState

        pendingPrompts = session.queuedPrompts
        activeProtocolKind = session.lastKnownProtocol
        if bindProtocolThreadID {
            syncKnownThreadIDs(threadID: session.threadID, protocolKind: session.lastKnownProtocol)
        } else {
            syncKnownThreadIDs(threadID: nil, replaceAll: true)
        }
        syncActiveExecutionProfileWithPreferredDefaults()
        refreshComposerCapabilities()
        if isDemoModeEnabled {
            applyDemoSessionPresentation(for: recentSessions[index])
            return
        }
        // Session selection changes must survive abrupt app resets while a host-backed
        // thread resume or reconnect is still in flight.
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()

        if reconnect,
           session.threadID != nil,
           connectionState != .connecting {
            beginRestoringActiveTranscript(for: session.threadID)
            connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
        }
    }

    private func syncKnownThreadIDs(
        threadID: String?,
        protocolKind: CodexProtocolKind? = nil,
        replaceAll: Bool = false
    ) {
        guard !replaceAll else {
            stdioThreadID = threadID
            loopbackThreadID = threadID
            directEndpointThreadID = threadID
            return
        }

        switch protocolKind ?? activeProtocolKind {
        case .stdio:
            stdioThreadID = threadID
        case .websocket:
            loopbackThreadID = threadID
        case .directEndpoint:
            directEndpointThreadID = threadID
        }
    }

    private func replaceHostThreadCatalogEntries(
        _ threads: [CodexThreadSummary],
        machine: MachineRecord,
        provenanceByThreadID: [String: HostThreadCatalogProvenance] = [:],
        observedAt: Date = .now
    ) {
        let routeID = activeSession?.routeID ?? selectedBootstrapRoute?.id ?? machine.preferredRoute?.id
        let routeKind = activeSession.flatMap { machine.route(id: $0.routeID)?.kind }
            ?? selectedBootstrapRoute?.kind
            ?? machine.preferredRoute?.kind
        let bootstrap = activeSession?.lastKnownBootstrap
            ?? (routeKind == .companionDirect ? .companionManaged : .standardSSH)
        let replacement = AppHostThreadCatalogCoordinator.replacingEntries(
            threads,
            machine: machine,
            hostThreadCatalog: hostThreadCatalog,
            recentSessions: recentSessions,
            activeProtocolKind: activeProtocolKind,
            routeID: routeID,
            routeKind: routeKind,
            bootstrap: bootstrap,
            normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:),
            workspaceMode: Self.workspaceMode(for:),
            provenanceByThreadID: provenanceByThreadID,
            observedAt: observedAt
        )
        hostThreadCatalog = replacement.hostThreadCatalog
        recentSessions = replacement.recentSessions
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    private func syncSessionsFromHostThreadCatalog(
        _ entries: [HostThreadCatalogEntry],
        machine: MachineRecord
    ) {
        replaceHostThreadCatalogEntries(entries.map {
            CodexThreadSummary(
                id: $0.id,
                cwd: $0.workspaceRoot,
                preview: $0.preview,
                modelProvider: $0.modelProvider,
                name: $0.name,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                status: .idle
            )
        }, machine: machine, provenanceByThreadID: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.provenance) }), observedAt: entries.map(\.observedAt).max() ?? .now)
    }

    private func updateSessionFromHostThreadCatalog(
        _ entry: HostThreadCatalogEntry,
        sessionID: SessionRecord.ID,
        fallbackExecutionProfileState: CodexExecutionProfileState? = nil
    ) {
        guard let machine = machines.first(where: { $0.id == entry.machineID }),
              let index = recentSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        let routeKind = recentSessions[index].lastKnownRouteKind
            ?? machine.preferredRoute?.kind
        let bootstrap = recentSessions[index].lastKnownBootstrap
        recentSessions[index] = AppHostThreadCatalogCoordinator.updatingSession(
            recentSessions[index],
            with: entry,
            routeKind: routeKind,
            bootstrap: bootstrap,
            workspaceMode: Self.workspaceMode(for:)
        )
        recentSessions[index].executionProfileState = recentSessions[index].executionProfileState
            ?? fallbackExecutionProfileState
    }

    private func upsertHostThreadCatalogEntry(_ entry: HostThreadCatalogEntry) {
        hostThreadCatalog = AppHostThreadCatalogCoordinator.upsertingEntry(
            entry,
            into: hostThreadCatalog
        )
        persistStateAsync()
    }

    private func hostThreadCatalogEntry(
        from summary: CodexThreadSummary,
        machineID: MachineRecord.ID
    ) -> HostThreadCatalogEntry? {
        AppHostThreadCatalogCoordinator.entry(
            from: summary,
            machineID: machineID,
            recentSessions: recentSessions,
            hostThreadCatalog: hostThreadCatalog,
            normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:)
        )
    }

    private func hostThreadCatalogEntry(
        fromPersistedSession session: SessionRecord
    ) -> HostThreadCatalogEntry? {
        AppHostThreadCatalogCoordinator.entry(
            fromPersistedSession: session,
            normalizeWorkspaceRoot: Self.normalizedWorkspaceRoot(_:)
        )
    }

    private func updateSessionState(
        transportState: SessionTransportState,
        lastErrorSummary: String?
    ) {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)

        recentSessions[index].transportState = transportState
        recentSessions[index].lastErrorSummary = lastErrorSummary
        recentSessions[index].lastOpenedAt = .now
        persistStateAsync()
    }

    private func refreshWorktreeList() async throws {
        guard activeProtocolKind != .directEndpoint else {
            throw CodexSSHError.invalidRequest("Worktree tools require an SSH-backed safe lane.")
        }

        guard let cwd = activeSession?.workspaceRoot else {
            return
        }

        let result = try await safeLaneClient.execute(command: GitWorkspaceCommandBuilder.worktreeListCommand(cwd: cwd))
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(result.errorOutput.isEmpty ? result.standardOutput : result.errorOutput)
        }

        let entries = GitWorktreeParser.parse(result.standardOutput).map { entry in
            GitWorktreeEntry(
                path: Self.normalizedWorkspaceRoot(entry.path) ?? entry.path,
                branch: entry.branch,
                head: entry.head,
                isLocked: entry.isLocked,
                isPrunable: entry.isPrunable
            )
        }
        await MainActor.run {
            self.worktrees = entries
        }
    }

    private func runGitWorkspaceMutation(
        summary: String,
        commandBuilder: @escaping @Sendable (String) -> String
    ) {
        guard activeProtocolKind != .directEndpoint else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "This workspace action requires the SSH safe lane."
                )
            )
            return
        }

        guard let cwd = activeSession?.workspaceRoot else {
            return
        }

        Task {
            do {
                let result = try await safeLaneClient.execute(command: commandBuilder(cwd))
                guard result.exitStatus == 0 else {
                    throw CodexSSHError.invalidResponse(result.errorOutput.isEmpty ? result.standardOutput : result.errorOutput)
                }

                try await refreshWorkspaceStatus()
                try? await refreshWorktreeList()
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: summary
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Workspace action failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func updateSessionQueue() {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)

        recentSessions[index].queuedPrompts = pendingPrompts
        persistStateAsync()
    }

    private func updateLastTurn(turnID: String, summary: String) {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)

        recentSessions[index].lastTurn = RecentTurnMetadata(
            turnID: turnID,
            summary: summary,
            completedAt: .now
        )
        persistStateAsync()
    }

    private func connectSafeLaneWithEmbeddedRetry(
        configuration: CodexSSHConfiguration,
        route: RouteRecord
    ) async throws {
        try await connectSSHClientWithEmbeddedRetry(
            safeLaneClient,
            configuration: configuration,
            route: route,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    self?.handle(event: event, source: .stdio)
                }
            }
        )
    }

    private func connectSafeLaneWithTimeout(
        configuration: CodexSSHConfiguration,
        route: RouteRecord
    ) async throws {
        try await safeLaneOperationWithTimeout(
            .seconds(25),
            errorMessage: "SSH fallback lane timed out while connecting to \(route.label)."
        ) {
            try await self.connectSafeLaneWithEmbeddedRetry(
                configuration: configuration,
                route: route
            )
        }
    }

    private func connectSafeLaneForLoopbackBootstrapWithTimeout(
        configuration: CodexSSHConfiguration,
        route: RouteRecord
    ) async throws {
        try await safeLaneOperationWithTimeout(
            .seconds(25),
            errorMessage: "SSH-forwarded Codex websocket lane timed out while opening \(route.label)."
        ) {
            try await self.safeLaneClient.connectForLoopbackBootstrap(configuration: configuration)
        }
    }

    private func safeLaneOperationWithTimeout<T: Sendable>(
        _ timeout: Duration,
        errorMessage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withAsyncTimeout(
                timeout,
                errorMessage: errorMessage,
                operation: operation
            )
        } catch {
            await safeLaneClient.disconnect()
            throw error
        }
    }

    private func directEndpointOperationWithTimeout<T: Sendable>(
        _ timeout: Duration,
        errorMessage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withAsyncTimeout(
                timeout,
                errorMessage: errorMessage,
                operation: operation
            )
        } catch {
            await loopbackClient.disconnect()
            throw error
        }
    }

    private func connectDirectEndpointWithTimeout(
        configuration: CodexLiveConfiguration
    ) async throws {
        try await directEndpointOperationWithTimeout(
            .seconds(15),
            errorMessage: "Codex websocket endpoint timed out while connecting."
        ) {
            try await self.loopbackClient.connect(configuration: configuration) { [weak self] event in
                Task { @MainActor in
                    self?.handle(event: event, source: .directEndpoint)
                }
            }
        }
    }

    private func connectSSHClientWithEmbeddedRetry(
        _ client: CodexSSHAppServerClient,
        configuration: CodexSSHConfiguration,
        route: RouteRecord,
        onEvent: @escaping @Sendable (CodexLiveEvent) -> Void
    ) async throws {
        do {
            try await client.connect(configuration: configuration, onEvent: onEvent)
        } catch {
            guard route.kind == .embeddedTailnet,
                  shouldRetryEmbeddedTailnetConnection(after: error) else {
                throw error
            }

            Self.logger.log("Retrying embedded safe-lane connection after transient bootstrap failure.")
            try await Task.sleep(for: .milliseconds(750))
            try await client.connect(configuration: configuration, onEvent: onEvent)
        }
    }

    private func shouldRetryEmbeddedTailnetConnection(after error: Error) -> Bool {
        let summary = error.localizedDescription.lowercased()
        return summary.contains("authenticationcompletionhandler.authenticationerror")
            || summary.contains("nioconnectionerror")
            || summary.contains("endedchannel")
            || summary.contains("connection reset")
    }

    private func withConnectionStage<T>(
        _ stage: String,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw ConnectionStageError(stage: stage, underlying: error)
        }
    }

    private func performDeferredPostConnectWork(
        cwd: String,
        preferLoopbackUpgrade: Bool
    ) async {
        try? await Task.sleep(for: .milliseconds(750))

        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(30) {
            if activeTurnID == nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard activeProtocolKind == .stdio,
              case .connected = connectionState else {
            return
        }

        guard preferLoopbackUpgrade,
              activeTurnID == nil,
              activeProtocolKind == .stdio,
              case .connected = connectionState else {
            await performDeferredPostConnectDiagnostics()
            return
        }

        try? await Task.sleep(for: .milliseconds(350))
        guard activeTurnID == nil,
              activeProtocolKind == .stdio,
              case .connected = connectionState else {
            await performDeferredPostConnectDiagnostics()
            return
        }
        await maybeAttemptAutomaticLoopbackUpgrade(cwd: cwd)
        await performDeferredPostConnectDiagnostics()
    }

    private func performDeferredPostConnectDiagnostics() async {
        await refreshDiscoverySnapshot()
        await refreshCapabilityDiagnosticsFromSafeLane()
        do {
            try await refreshWorkspaceStatus()
        } catch {
            Self.logger.warning("Workspace refresh failed after connect: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Workspace refresh failed after connect: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func applyPersistedSnapshot(_ snapshot: MachineDirectorySnapshot) -> RestoredLaunchContext {
        machines = snapshot.machines
        tailnetProfiles = snapshot.tailnetProfiles
        recentSessions = snapshot.recentSessions.map(Self.sanitizedPersistedRuntimeSession)
        hostThreadCatalog = Self.cachedHostThreadCatalog(snapshot.hostThreadCatalog)
        worktrees = []
        let restoredSessionIndex = restoredSessionIndex(from: snapshot)
        if let restoredSessionIndex,
           recentSessions[restoredSessionIndex].sceneID != sceneID,
           recentSessions[restoredSessionIndex].sceneID != nil {
            recentSessions[restoredSessionIndex].sceneID = sceneID
        }
        let restoredSession = restoredSessionIndex.map { recentSessions[$0] }
        activeSessionID = restoredSession?.id
        selectedMachineID = normalizedSelectedMachineID(preferred: restoredMachineID(from: snapshot))
        if let restoredSession,
           let restoredThreadID = restoredSession.threadID,
           !hostThreadCatalog.contains(where: {
               $0.machineID == restoredSession.machineID && $0.id == restoredThreadID
           }),
           let entry = hostThreadCatalogEntry(fromPersistedSession: restoredSession) {
            upsertHostThreadCatalogEntry(entry)
        }
        pendingPrompts = restoredSession?.queuedPrompts ?? []
        activeProtocolKind = restoredSession?.lastKnownProtocol
            ?? snapshot.preferences.preferredProtocol
            ?? .stdio
        selectedReasoningEffort = CodexReasoningEffort(
            rawValue: snapshot.preferences.preferredReasoningEffort ?? ""
        ) ?? .medium
        preferredApprovalPolicy = snapshot.preferences.preferredApprovalPolicy
        preferredSandboxMode = snapshot.preferences.preferredSandboxMode.flatMap(CodexSandboxMode.init(rawValue:))
        applyUITestPreferenceOverridesIfNeeded()
        syncActiveExecutionProfileWithPreferredDefaults()
        privacyMode = snapshot.preferences.privacyMode
        embeddedTailnetStatus = Self.provisionalTailnetStatus(
            for: snapshot.tailnetProfiles.first(where: \.isActive)
        )
        pendingTailnetAuthTicket = nil

        scheduleEmbeddedTailnetBootstrap(
            profiles: snapshot.tailnetProfiles,
            activeProfileID: snapshot.preferences.preferredTailnetProfileID,
            persist: false
        )
        applyUITestPendingScannedHostKeySeedIfNeeded()
        applyUITestConnectionFailureSeedIfNeeded()
        applyUITestPlanMessageSeedIfNeeded()
        applyUITestActivityBurstSeedIfNeeded()
        applyUITestAttachmentHistorySeedIfNeeded()
        applyUITestStructuredPromptSeedIfNeeded()
        applyUITestThreadlessSummarySeedIfNeeded()
        applyUITestBrowserOperationsSeedIfNeeded()
        applyUITestRecoverableSavedSSHKeySeedIfNeeded()

        return RestoredLaunchContext(
            selectedMachineID: selectedMachineID,
            selectedSessionID: restoredSession?.id,
            shouldRestoreDetail: snapshot.preferences.restoreLastSessionOnLaunch && restoredSession != nil
        )
    }

    private func resetRestoredRuntimeConnectionIfNeeded() {
        guard case .connecting = connectionState,
              activeTurnID == nil else {
            return
        }

        connectionTask?.cancel()
        connectionTask = nil
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        connectionAttemptStartedAt = nil
        isRestoringActiveTranscript = false
        connectionState = .disconnected
        updateSessionState(transportState: .disconnected, lastErrorSummary: nil)
    }

    private func applyTailnetRuntimeUpdate(
        _ runtime: EmbeddedTailnetRuntimeSnapshot,
        persist: Bool = true
    ) {
        let previousMachines = machines
        tailnetProfiles = runtime.profiles
        embeddedTailnetStatus = runtime.status
        embeddedTailnetDialPlan = runtime.dialPlan
        pendingTailnetAuthTicket = runtime.authSession?.ticket

        machines = TailnetRoutePublisher.applying(runtime, to: machines)
        reconcilePendingScannedHostKeyRouteBinding(previousMachines: previousMachines)
        selectedMachineID = normalizedSelectedMachineID(preferred: selectedMachineID)
        applyUITestPendingScannedHostKeySeedIfNeeded()
        applyUITestConnectionFailureSeedIfNeeded()
        applyUITestPlanMessageSeedIfNeeded()
        applyUITestActivityBurstSeedIfNeeded()
        applyUITestAttachmentHistorySeedIfNeeded()
        applyUITestStructuredPromptSeedIfNeeded()
        applyUITestThreadlessSummarySeedIfNeeded()
        applyUITestBrowserOperationsSeedIfNeeded()
        applyUITestRecoverableSavedSSHKeySeedIfNeeded()

        if persist {
            persistStateAsync()
        }
    }

    private func scheduleEmbeddedTailnetBootstrap(
        profiles: [TailnetProfile],
        activeProfileID: TailnetProfile.ID?,
        persist: Bool
    ) {
        let request = EmbeddedTailnetBootstrapRequest(
            profiles: profiles,
            activeProfileID: activeProfileID
        )

        if inFlightEmbeddedTailnetBootstrapRequest == request {
            return
        }

        if lastCompletedEmbeddedTailnetBootstrapRequest == request {
            return
        }

        embeddedTailnetBootstrapTask?.cancel()
        inFlightEmbeddedTailnetBootstrapRequest = request
        embeddedTailnetBootstrapTask = Task { [weak self] in
            guard let self else {
                return
            }

            var runtime = await self.embeddedTailnetManager.bootstrap(
                profiles: profiles,
                activeProfileID: activeProfileID
            )
            var shouldKeepPolling = await self.applyEmbeddedTailnetBootstrapRuntime(
                runtime,
                request: request,
                persist: persist
            )
            var pollCount = 0

            while shouldKeepPolling,
                  pollCount < Self.embeddedTailnetBootstrapPollLimit,
                  !Task.isCancelled {
                pollCount += 1
                try? await Task.sleep(for: Self.embeddedTailnetBootstrapPollInterval)
                runtime = await self.embeddedTailnetManager.snapshot()
                shouldKeepPolling = await self.applyEmbeddedTailnetBootstrapRuntime(
                    runtime,
                    request: request,
                    persist: false
                )
            }

            await self.finishEmbeddedTailnetBootstrap(
                request: request,
                completed: !shouldKeepPolling
            )
        }
    }

    private func applyEmbeddedTailnetBootstrapRuntime(
        _ runtime: EmbeddedTailnetRuntimeSnapshot,
        request: EmbeddedTailnetBootstrapRequest,
        persist: Bool
    ) async -> Bool {
        await MainActor.run {
            guard self.inFlightEmbeddedTailnetBootstrapRequest == request else {
                return false
            }

            self.applyTailnetRuntimeUpdate(runtime, persist: persist)
            return Self.shouldContinueEmbeddedTailnetBootstrapPolling(runtime)
        }
    }

    private func finishEmbeddedTailnetBootstrap(
        request: EmbeddedTailnetBootstrapRequest,
        completed: Bool
    ) async {
        await MainActor.run {
            guard self.inFlightEmbeddedTailnetBootstrapRequest == request else {
                return
            }

            self.inFlightEmbeddedTailnetBootstrapRequest = nil
            if completed {
                self.lastCompletedEmbeddedTailnetBootstrapRequest = request
            }
            self.embeddedTailnetBootstrapTask = nil
        }
    }

    private static func shouldContinueEmbeddedTailnetBootstrapPolling(
        _ runtime: EmbeddedTailnetRuntimeSnapshot
    ) -> Bool {
        guard runtime.activeProfile?.kind == .embedded else {
            return false
        }

        guard runtime.dialPlan?.supportsNativeSSHTransport != true else {
            return false
        }

        switch runtime.status.authState {
        case .signedOut, .authenticated:
            return true
        case .authenticating, .blocked:
            return false
        }
    }

    private static func provisionalTailnetStatus(for profile: TailnetProfile?) -> EmbeddedTailnetStatus {
        let health: EmbeddedTailnetRuntimeHealth
        if let profile {
            health = EmbeddedTailnetRuntimeHealth(
                state: profile.kind == .external ? .degraded : .needsRuntimeIntegration,
                lastCheckedAt: .now,
                failureReasonCode: profile.kind == .external
                    ? "external-tailnet-reachability-unverified"
                    : "embedded-tailnet-runtime-unavailable"
            )
        } else {
            health = EmbeddedTailnetRuntimeHealth(state: .idle)
        }

        return TailnetHealthMonitor.status(
            for: profile,
            authSession: nil,
            health: health
        )
    }

    private func persistStateAsync() {
        guard !isDemoModeEnabled else {
            return
        }
        Task {
            await persistState()
        }
    }

    private func applyUITestPreferenceOverridesIfNeeded() {
        let overrides = Self.uiTestPreferenceOverrides(
            reasoningEffort: selectedReasoningEffort,
            approvalPolicy: preferredApprovalPolicy,
            sandboxMode: preferredSandboxMode
        )
        selectedReasoningEffort = supportedReasoningEffort(overrides.reasoningEffort, for: selectedModelDescriptor)
        preferredApprovalPolicy = overrides.approvalPolicy
        preferredSandboxMode = overrides.sandboxMode
    }

    private func recordPendingInitialReasoningEffortOverride(_ effort: CodexReasoningEffort) {
        guard !hasCompletedInitialRestore else {
            return
        }

        pendingInitialPreferenceOverrides.didSetReasoningEffort = true
        pendingInitialPreferenceOverrides.reasoningEffort = effort
    }

    private func recordPendingInitialApprovalPolicyOverride(_ policy: String?) {
        guard !hasCompletedInitialRestore else {
            return
        }

        pendingInitialPreferenceOverrides.didSetApprovalPolicy = true
        pendingInitialPreferenceOverrides.approvalPolicy = policy
    }

    private func recordPendingInitialSandboxModeOverride(_ mode: CodexSandboxMode?) {
        guard !hasCompletedInitialRestore else {
            return
        }

        pendingInitialPreferenceOverrides.didSetSandboxMode = true
        pendingInitialPreferenceOverrides.sandboxMode = mode
    }

    private func recordPendingInitialPrivacyModeOverride(_ mode: AppPrivacyMode) {
        guard !hasCompletedInitialRestore else {
            return
        }

        pendingInitialPreferenceOverrides.didSetPrivacyMode = true
        pendingInitialPreferenceOverrides.privacyMode = mode
    }

    private func reapplyPendingInitialPreferenceOverridesIfNeeded() {
        let overrides = pendingInitialPreferenceOverrides
        completeInitialRestore()
        guard overrides.hasAnyOverride else {
            return
        }

        if overrides.didSetReasoningEffort {
            selectedReasoningEffort = supportedReasoningEffort(overrides.reasoningEffort, for: selectedModelDescriptor)
        }
        if overrides.didSetApprovalPolicy {
            preferredApprovalPolicy = overrides.approvalPolicy
        }
        if overrides.didSetSandboxMode {
            preferredSandboxMode = overrides.sandboxMode
        }
        if overrides.didSetPrivacyMode {
            privacyMode = overrides.privacyMode
        }
        if overrides.didSetApprovalPolicy || overrides.didSetSandboxMode {
            syncActiveExecutionProfileWithPreferredDefaults()
        }
        persistStateAsync()
    }

    private func completeInitialRestore() {
        hasCompletedInitialRestore = true
        pendingInitialPreferenceOverrides = PendingInitialPreferenceOverrides()
    }

    private static func uiTestPreferenceOverrides(
        reasoningEffort: CodexReasoningEffort,
        approvalPolicy: String?,
        sandboxMode: CodexSandboxMode?
    ) -> (reasoningEffort: CodexReasoningEffort, approvalPolicy: String?, sandboxMode: CodexSandboxMode?) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UI_TESTING"] == "1" else {
            return (reasoningEffort, approvalPolicy, sandboxMode)
        }

        let overriddenReasoningEffort = environment["COTG_UI_TEST_PREFERRED_REASONING_EFFORT"]
            .flatMap(CodexReasoningEffort.init(rawValue:))
            ?? reasoningEffort
        let overriddenApprovalPolicy = environment.keys.contains("COTG_UI_TEST_PREFERRED_APPROVAL_POLICY")
            ? Self.normalizedExecutionPreference(environment["COTG_UI_TEST_PREFERRED_APPROVAL_POLICY"])
            : approvalPolicy
        let overriddenSandboxMode = environment.keys.contains("COTG_UI_TEST_PREFERRED_SANDBOX_MODE")
            ? environment["COTG_UI_TEST_PREFERRED_SANDBOX_MODE"].flatMap(CodexSandboxMode.init(rawValue:))
            : sandboxMode

        return (
            overriddenReasoningEffort,
            overriddenApprovalPolicy,
            overriddenSandboxMode
        )
    }

    private func persistStateSynchronouslyForLifecycle() {
        guard !isDemoModeEnabled else {
            return
        }
        let snapshot = sanitizedPersistedSnapshot(
            MachineDirectorySnapshot(
                machines: machines,
                tailnetProfiles: tailnetProfiles,
                recentSessions: recentSessions,
                hostThreadCatalog: Self.deduplicatedHostThreadCatalog(hostThreadCatalog),
                preferences: UserPreferencesSnapshot(
                    preferredMachineID: selectedMachineID,
                    preferredTailnetProfileID: activeTailnetProfile?.id,
                    restoreLastSessionOnLaunch: true,
                    preferredBootstrap: .standardSSH,
                    preferredProtocol: activeProtocolKind,
                    preferredReasoningEffort: selectedReasoningEffort.rawValue,
                    preferredApprovalPolicy: preferredApprovalPolicy,
                    preferredSandboxMode: preferredSandboxMode?.rawValue,
                    privacyMode: privacyMode
                )
            )
        )

        do {
            _ = try persistenceCoordinator.mergeAndSaveSnapshotSynchronously(snapshot)
        } catch {
            Self.logger.error("Lifecycle persistence flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistState() async {
        guard !isDemoModeEnabled else {
            return
        }
        let snapshot = MachineDirectorySnapshot(
            machines: machines,
            tailnetProfiles: tailnetProfiles,
            recentSessions: recentSessions,
            hostThreadCatalog: Self.deduplicatedHostThreadCatalog(hostThreadCatalog),
            preferences: UserPreferencesSnapshot(
                preferredMachineID: selectedMachineID,
                preferredTailnetProfileID: activeTailnetProfile?.id,
                restoreLastSessionOnLaunch: true,
                preferredBootstrap: .standardSSH,
                preferredProtocol: activeProtocolKind,
                preferredReasoningEffort: selectedReasoningEffort.rawValue,
                preferredApprovalPolicy: preferredApprovalPolicy,
                preferredSandboxMode: preferredSandboxMode?.rawValue,
                privacyMode: privacyMode
            )
        )

        do {
            let persistResult = try await persistenceCoordinator.mergeAndStage(snapshot)
            let syncedSnapshot = sanitizedPersistedSnapshot(persistResult.snapshot)
            let validMachineIDs = Set(syncedSnapshot.machines.map(\.id))

            machines = syncedSnapshot.machines
            tailnetProfiles = syncedSnapshot.tailnetProfiles
            recentSessions = syncedSnapshot.recentSessions
            hostThreadCatalog = Self.runtimeHostThreadCatalog(
                currentEntries: hostThreadCatalog,
                persistedEntries: syncedSnapshot.hostThreadCatalog,
                validMachineIDs: validMachineIDs
            )
            if let preferredMachineID = syncedSnapshot.preferences.preferredMachineID,
               syncedSnapshot.machines.contains(where: { $0.id == preferredMachineID }) {
                selectedMachineID = preferredMachineID
            } else if let selectedMachineID,
                      !syncedSnapshot.machines.contains(where: { $0.id == selectedMachineID }) {
                self.selectedMachineID = syncedSnapshot.machines.first?.id
            }
            await MainActor.run {
                self.syncSnapshot = persistResult.syncSnapshot
            }
        } catch {
            await MainActor.run {
                self.syncSnapshot = SyncSnapshot(
                    status: .blocked,
                    blocker: SyncBlocker(
                        reason: error.localizedDescription,
                        remediation: "Review the local metadata path and CloudKit setup."
                    )
                )
            }
        }
    }

    func reconcilePersistedLocalStateIfNeeded() async {
        guard !isDemoModeEnabled else {
            return
        }

        guard let snapshot = try? await persistenceCoordinator.loadSnapshot() else {
            return
        }

        let sanitized = sanitizedPersistedSnapshot(snapshot)
        await MainActor.run {
            self.mergePersistedLocalStateIfNeeded(from: sanitized)
        }
        await recoverSavedCredentialBindingsIfNeeded()
    }

    private func mergePersistedLocalStateIfNeeded(from snapshot: MachineDirectorySnapshot) {
        let mergeResult = AppMachineDirectoryCoordinator.mergePersistedLocalState(
            liveMachines: machines,
            selectedMachineID: selectedMachineID,
            snapshot: snapshot,
            isUITesting: ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
            hostKeyFingerprint: Self.hostKeyFingerprint(_:)
        )
        machines = mergeResult.machines
        selectedMachineID = mergeResult.selectedMachineID
        let didMergeThreadState = mergePersistedSessionStateIfNeeded(from: snapshot)

        if mergeResult.didChange || didMergeThreadState {
            persistStateAsync()
        }
    }

    private func mergePersistedSessionStateIfNeeded(
        from snapshot: MachineDirectorySnapshot
    ) -> Bool {
        let validMachineIDs = Set(machines.map(\.id))
        let persistedSessions = snapshot.recentSessions.filter { validMachineIDs.contains($0.machineID) }
        let persistedHostThreadCatalog = snapshot.hostThreadCatalog.filter { validMachineIDs.contains($0.machineID) }
        var didChange = false

        if !persistedSessions.isEmpty {
            let existingSessionIDs = Set(recentSessions.map(\.id))
            let appendedSessions = persistedSessions.filter { !existingSessionIDs.contains($0.id) }
            if !appendedSessions.isEmpty {
                recentSessions.append(contentsOf: appendedSessions)
                recentSessions.sort(by: { $0.lastOpenedAt > $1.lastOpenedAt })
                didChange = true
            }
        }

        let mergedHostThreadCatalog = Self.runtimeHostThreadCatalog(
            currentEntries: hostThreadCatalog,
            persistedEntries: persistedHostThreadCatalog,
            validMachineIDs: validMachineIDs
        )
        if mergedHostThreadCatalog != hostThreadCatalog {
            hostThreadCatalog = mergedHostThreadCatalog
            didChange = true
        }

        guard activeSessionID == nil else {
            return didChange
        }

        let mergedSnapshot = MachineDirectorySnapshot(
            machines: machines,
            tailnetProfiles: tailnetProfiles,
            recentSessions: recentSessions,
            hostThreadCatalog: hostThreadCatalog,
            preferences: snapshot.preferences
        )

        if let snapshotRestoredSession = restoredSession(from: snapshot),
           let restoredSession = recentSessions.first(where: { $0.id == snapshotRestoredSession.id }) {
            if let entry = hostThreadCatalogEntry(fromPersistedSession: restoredSession),
               !hostThreadCatalog.contains(where: {
                   $0.machineID == restoredSession.machineID && $0.id == restoredSession.threadID
               }) {
                hostThreadCatalog = Self.deduplicatedHostThreadCatalog(
                    hostThreadCatalog + [entry.asCachedCatalog()]
                )
                didChange = true
            }
            resumeSession(restoredSession.id, reconnect: false)
            return true
        }

        if let restoredMachineID = restoredMachineID(from: mergedSnapshot),
           restoredMachineID != selectedMachineID {
            selectedMachineID = restoredMachineID
            didChange = true
        }

        return didChange
    }

    private func persistedMachineMatch(
        for machine: MachineRecord,
        persistedMachinesByID: [MachineRecord.ID: MachineRecord],
        snapshot: MachineDirectorySnapshot
    ) -> MachineRecord? {
        AppMachineDirectoryCoordinator.persistedMachineMatch(
            for: machine,
            persistedMachinesByID: persistedMachinesByID,
            snapshot: snapshot
        )
    }

    private func normalizedSelectedMachineID(
        preferred preferredMachineID: MachineRecord.ID?
    ) -> MachineRecord.ID? {
        AppMachineDirectoryCoordinator.normalizedSelectedMachineID(
            preferred: preferredMachineID,
            machines: machines,
            currentSelection: selectedMachineID
        )
    }

    private static func routeIdentityMatches(_ lhs: RouteRecord, _ rhs: RouteRecord) -> Bool {
        AppMachineDirectoryCoordinator.routeIdentityMatches(lhs, rhs)
    }

    private static func machineIdentityMatches(_ lhs: MachineRecord, _ rhs: MachineRecord) -> Bool {
        AppMachineDirectoryCoordinator.machineIdentityMatches(lhs, rhs)
    }

    private static func mergedMachinesPreservingLocalRoutes(
        current: [MachineRecord],
        refreshed: [MachineRecord]
    ) -> [MachineRecord] {
        AppMachineDirectoryCoordinator.mergedMachinesPreservingLocalRoutes(
            current: current,
            refreshed: refreshed
        )
    }

    private static func mergedMachinePreservingLocalRoutes(
        current: MachineRecord,
        refreshed: MachineRecord
    ) -> MachineRecord {
        AppMachineDirectoryCoordinator.mergedMachinePreservingLocalRoutes(
            current: current,
            refreshed: refreshed
        )
    }

    private static func isLocalhostTestingFixture(_ machine: MachineRecord) -> Bool {
        AppMachineDirectoryCoordinator.isLocalhostTestingFixture(machine)
    }

    private static func isLocalhostTestingCredentialReference(_ credentialRef: CredentialRef) -> Bool {
        AppMachineDirectoryCoordinator.isLocalhostTestingCredentialReference(credentialRef)
    }

    private static func normalizedRouteAddress(_ route: RouteRecord) -> String? {
        [
            route.magicDNSName,
            route.hostname,
            route.ipAddress
        ]
        .compactMap(nonEmptyTrimmed)
        .map { $0.lowercased() }
        .first
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func metadataStoreURL() -> URL {
        persistenceCoordinator.metadataStoreURL()
    }

    private func syncMirrorStoreURL() -> URL {
        persistenceCoordinator.syncMirrorStoreURL()
    }

    private func isolatedUITestStoreDirectoryURL() -> URL? {
        let metadataURL = persistenceCoordinator.metadataStoreURL()
        let runtimeURL = runtimeConfiguration.paths.metadataStoreURL
        guard metadataURL != runtimeURL else {
            return nil
        }
        return metadataURL.deletingLastPathComponent()
    }

    private func sessionIndex(for machine: MachineRecord) -> Int {
        let machineSessionIndices = recentSessions.indices.filter { recentSessions[$0].machineID == machine.id }

        if let index = machineSessionIndices
            .filter({ recentSessions[$0].sceneID == sceneID })
            .max(by: { recentSessions[$0].lastOpenedAt < recentSessions[$1].lastOpenedAt }) {
            return index
        }

        let latestOverallIndex = machineSessionIndices
            .max(by: { recentSessions[$0].lastOpenedAt < recentSessions[$1].lastOpenedAt })
        let latestSharedIndex = machineSessionIndices
            .filter { recentSessions[$0].sceneID == nil }
            .max(by: { recentSessions[$0].lastOpenedAt < recentSessions[$1].lastOpenedAt })

        if let latestSharedIndex,
           let latestOverallIndex,
           recentSessions[latestSharedIndex].lastOpenedAt >= recentSessions[latestOverallIndex].lastOpenedAt {
            recentSessions[latestSharedIndex].sceneID = sceneID
            return latestSharedIndex
        }

        if let latestOverallIndex {
            recentSessions[latestOverallIndex].sceneID = sceneID
            return latestOverallIndex
        }

        let route = defaultSessionSeedRoute(for: machine)
        recentSessions.append(
            SessionRecord(
                sceneID: sceneID,
                machineID: machine.id,
                routeID: route?.id,
                threadID: nil,
                workspaceRoot: nil,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: route?.kind,
                lastKnownBootstrap: route?.kind == .companionDirect ? .companionManaged : .standardSSH,
                transportState: .disconnected,
                lastOpenedAt: .now
            )
        )
        return recentSessions.endIndex - 1
    }

    private func activationIndex(for session: SessionRecord, machine _: MachineRecord) -> Int {
        if let existingIndex = recentSessions.firstIndex(where: { $0.id == session.id }) {
            return existingIndex
        }

        recentSessions.append(session)
        return recentSessions.endIndex - 1
    }

    private func activeSessionIndex(for machine: MachineRecord) -> Int {
        if let activeSessionID,
           let existingIndex = recentSessions.firstIndex(where: {
               $0.id == activeSessionID && $0.machineID == machine.id
           }) {
            return existingIndex
        }

        return sessionIndex(for: machine)
    }

    private func restoredMachineID(from snapshot: MachineDirectorySnapshot) -> MachineRecord.ID? {
        if let preferredMachineID = snapshot.preferences.preferredMachineID,
           snapshot.machines.contains(where: { $0.id == preferredMachineID }) {
            return preferredMachineID
        }

        if let recentMachineID = restoredSession(from: snapshot)?.machineID,
           snapshot.machines.contains(where: { $0.id == recentMachineID }) {
            return recentMachineID
        }

        return snapshot.machines.first?.id
    }

    private func restoredSession(from snapshot: MachineDirectorySnapshot) -> SessionRecord? {
        restoredSessionIndex(from: snapshot).map { snapshot.recentSessions[$0] }
    }

    private func restoredSessionIndex(from snapshot: MachineDirectorySnapshot) -> Int? {
        let sceneScopedSessions = snapshot.recentSessions.enumerated()
            .filter { Self.isRestorableLaunchSession($0.element) }
            .filter { $0.element.sceneID == sceneID }
            .sorted(by: { $0.element.lastOpenedAt > $1.element.lastOpenedAt })

        if let session = sceneScopedSessions.first {
            return session.offset
        }

        let sharedSessions = snapshot.recentSessions.enumerated()
            .filter { Self.isRestorableLaunchSession($0.element) }
            .filter { $0.element.sceneID == nil }
            .sorted(by: { $0.element.lastOpenedAt > $1.element.lastOpenedAt })

        if let session = sharedSessions.first {
            return session.offset
        }

        return snapshot.recentSessions.enumerated()
            .filter { Self.isRestorableLaunchSession($0.element) }
            .sorted(by: { $0.element.lastOpenedAt > $1.element.lastOpenedAt })
            .first?
            .offset
    }

    private static func sanitizedPersistedRuntimeSession(_ session: SessionRecord) -> SessionRecord {
        guard session.transportState == .connecting else {
            return session
        }

        var session = session
        session.transportState = .disconnected
        session.lastErrorSummary = nil
        return session
    }

    private static func isRestorableLaunchSession(_ session: SessionRecord) -> Bool {
        guard !session.isArchived else {
            return false
        }

        if normalizedThreadID(session.threadID) != nil
            || !session.queuedPrompts.isEmpty
            || trimmedSessionValue(session.unavailableSelectedThreadID) != nil {
            return true
        }

        return session.transportState == .connected
            && normalizedWorkspaceRoot(session.workspaceRoot) != nil
    }

    private static func trimmedSessionValue(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    @discardableResult
    private func refreshDiscoverySnapshot() async -> DiscoveryScanReport {
        localNetworkAccessPrimed = true
        var baseMachines = await MainActor.run { self.machines }
        var report = await discoveryCoordinator.scanAndMerge(into: baseMachines)

        while true {
            let refreshState = await MainActor.run {
                (
                    tailnetProfiles: self.tailnetProfiles,
                    recentSessions: self.recentSessions,
                    hostThreadCatalog: self.hostThreadCatalog,
                    selectedMachineID: self.selectedMachineID,
                    preferredTailnetProfileID: self.activeTailnetProfile?.id,
                    discoveryRisk: self.networkProxyDiagnostics.discoveryRisk
                )
            }

            let refreshedMachines = sanitizedPersistedSnapshot(
                MachineDirectorySnapshot(
                    machines: report.machines,
                    tailnetProfiles: refreshState.tailnetProfiles,
                    recentSessions: refreshState.recentSessions,
                    hostThreadCatalog: refreshState.hostThreadCatalog,
                    preferences: UserPreferencesSnapshot(
                        preferredMachineID: refreshState.selectedMachineID,
                        preferredTailnetProfileID: refreshState.preferredTailnetProfileID
                    )
                )
            ).machines
            let mergedMachines = Self.mergedMachinesPreservingLocalRoutes(
                current: baseMachines,
                refreshed: refreshedMachines
            )

            let preferredMachineID = refreshState.selectedMachineID
                ?? report.createdMachineIDs.first
                ?? report.updatedMachineIDs.first
                ?? mergedMachines.first?.id
            let refreshedMachine = preferredMachineID.flatMap { machineID in
                mergedMachines.first(where: { $0.id == machineID })
            }
            let snapshot: DiscoverySnapshot?
            let nearbyResults = Self.makeNearbyMachineResults(
                from: report.samples,
                machines: mergedMachines,
                existingMachineIDs: Set(baseMachines.map(\.id))
            )
            if let refreshedMachine {
                let publishedRoutes = refreshedMachine.routes
                    .filter(\.publishedByCompanion)
                    .map { PublishedRoute(kind: $0.kind, address: $0.address, health: $0.health) }
                let manualRoutes = refreshedMachine.routes.filter { $0.kind == .manualSSH }
                var refreshedSnapshot = await discoveryCoordinator.snapshot(
                    for: refreshedMachine,
                    manualRoutes: manualRoutes,
                    publishedRoutes: publishedRoutes,
                    discoveredSamples: report.samples
                )
                if report.samples.isEmpty, refreshState.discoveryRisk {
                    refreshedSnapshot.notes.append("Local discovery may be blocked by an active system proxy or VPN. Bypass .local and private-network traffic before treating this as a product failure.")
                }
                snapshot = refreshedSnapshot
            } else {
                snapshot = nil
            }

            let latestMachines = await MainActor.run { () -> [MachineRecord]? in
                guard self.machines == baseMachines else {
                    return self.machines
                }

                self.machines = mergedMachines
                let currentSelectedMachineID = self.selectedMachineID
                let resolvedMachineID = currentSelectedMachineID
                    ?? report.createdMachineIDs.first
                    ?? report.updatedMachineIDs.first
                    ?? mergedMachines.first?.id
                if let resolvedMachineID,
                   mergedMachines.contains(where: { $0.id == resolvedMachineID }) {
                    self.selectedMachineID = resolvedMachineID
                } else if let currentSelectedMachineID,
                          !mergedMachines.contains(where: { $0.id == currentSelectedMachineID }) {
                    self.selectedMachineID = mergedMachines.first?.id
                }
                self.discoverySnapshot = snapshot
                self.nearbyDiscoveryResults = nearbyResults
                return nil
            }

            guard let latestMachines else {
                await recoverSavedCredentialBindingsIfNeeded()
                return report
            }

            baseMachines = latestMachines
            report = await discoveryCoordinator.mergeSamples(report.samples, into: latestMachines)
        }
    }

    private func primeLocalNetworkAccessIfNeeded(for route: RouteRecord) async {
        guard route.kind == .manualSSH || route.kind == .localLAN else {
            return
        }
        guard !localNetworkAccessPrimed else {
            return
        }

        await refreshDiscoverySnapshot()
    }

    private var scanStatusDebugLabel: String {
        switch localNetworkScanStatus {
        case .idle:
            return "idle"
        case .scanning:
            return "scanning"
        case .found:
            return "found"
        case .noResults:
            return "noResults"
        }
    }

    private func makeLocalNetworkDiscoveryDebugLabel(
        status: String,
        report: DiscoveryScanReport?,
        reachabilitySummary: String?
    ) -> String {
        let selectedAlias = selectedMachine?.alias ?? "none"
        let sampleSummary = report?.samples.prefix(4).map { sample in
            let host = sample.hostname.replacingOccurrences(of: ";", with: "_")
            return "\(sample.source.rawValue)@\(host):\(sample.port):\(sample.health.rawValue)"
        }.joined(separator: ",") ?? "none"
        let createdCount = report?.createdMachineIDs.count ?? 0
        let updatedCount = report?.updatedMachineIDs.count ?? 0
        let sampleCount = report?.samples.count ?? 0
        let reachability = reachabilitySummary ?? "not-run"

        return "status=\(status);machines=\(machines.count);selected=\(selectedAlias);proxyRisk=\(networkProxyDiagnostics.discoveryRisk);samples=\(sampleCount);created=\(createdCount);updated=\(updatedCount);sampleSummary=\(sampleSummary);reachability=\(reachability)"
    }

    private static func discoveryReportIsEmpty(_ report: DiscoveryScanReport) -> Bool {
        report.createdMachineIDs.isEmpty
            && report.updatedMachineIDs.isEmpty
            && report.samples.isEmpty
    }

    private static func makeNearbyMachineResults(
        from samples: [DiscoveryRouteSample],
        machines: [MachineRecord],
        existingMachineIDs: Set<MachineRecord.ID>
    ) -> [NearbyMachineResult] {
        samples.compactMap { sample in
            guard let machine = matchedMachine(for: sample, in: machines) else {
                return nil
            }

            return NearbyMachineResult(
                id: machine.id.uuidString,
                machineID: machine.id,
                machineAlias: machine.alias,
                hostname: sample.hostname,
                routeKind: sample.kind,
                source: sample.source,
                health: sample.health,
                isAlreadySaved: existingMachineIDs.contains(machine.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isHighConfidence != rhs.isHighConfidence {
                return lhs.isHighConfidence && !rhs.isHighConfidence
            }
            if lhs.isAlreadySaved != rhs.isAlreadySaved {
                return lhs.isAlreadySaved && !rhs.isAlreadySaved
            }
            return lhs.machineAlias.localizedCaseInsensitiveCompare(rhs.machineAlias) == .orderedAscending
        }
    }

    private static func matchedMachine(
        for sample: DiscoveryRouteSample,
        in machines: [MachineRecord]
    ) -> MachineRecord? {
        if let machineID = sample.machineID,
           let directMatch = machines.first(where: { $0.id == machineID }) {
            return directMatch
        }

        if let fingerprint = sample.fingerprint,
           let fingerprintMatch = machines.first(where: { $0.stableHostFingerprint == fingerprint }) {
            return fingerprintMatch
        }

        let sampleMatchTokens = Set(
            [sample.hostname, sample.ipAddress]
                .compactMap { value in
                    value?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )
        return machines.first { machine in
            machine.routes.contains { route in
                guard route.kind == sample.kind else {
                    return false
                }

                let candidates = [
                    route.hostname,
                    route.ipAddress,
                    route.magicDNSName,
                    route.address
                ]

                return candidates.contains { candidate in
                    guard let normalizedCandidate = candidate?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                          !normalizedCandidate.isEmpty else {
                        return false
                    }
                    return sampleMatchTokens.contains(normalizedCandidate)
                }
            }
        }
    }

    private func localNetworkReachabilitySummaryIfNeeded(report: DiscoveryScanReport) async -> String? {
        guard report.samples.isEmpty,
              ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              let host = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        let port = Int(ProcessInfo.processInfo.environment["COTG_TEST_SSH_PORT"] ?? "") ?? 22
        let probe = NetworkTCPRouteProbe()
        let reachable = await probe.probe(
            host: host,
            port: port,
            timeout: .seconds(2)
        )
        let sanitizedHost = host.replacingOccurrences(of: ";", with: "_")
        return "\(sanitizedHost):\(port):\(reachable ? "reachable" : "unreachable")"
    }

    public func refreshVisibleActiveThreadIfNeeded() async {
        guard !isDemoModeEnabled,
              !activeThreadSummaryRefreshInFlight,
              case .connected = connectionState,
              let threadID = resolveThreadID(preferredThreadID: nil) else {
            return
        }

        activeThreadSummaryRefreshInFlight = true
        defer { activeThreadSummaryRefreshInFlight = false }

        do {
            if let upgradeCwd = activeSession?.workspaceRoot ?? resolvedWorkspaceRoot() {
                await maybeRetryPreferredLoopbackUpgradeForVisibleThread(cwd: upgradeCwd)
            }

            let summarySnapshot = try await readThreadSnapshot(threadID: threadID, includeTurns: false)
            let latestSummary = summarySnapshot.summary
            if Self.shouldUseVisibleActiveThreadSummaryGate(protocolKind: activeProtocolKind) {
                guard Self.shouldRefreshVisibleActiveThread(
                    baseline: lastObservedActiveThreadSummary,
                    latest: latestSummary,
                    expectedThreadID: threadID
                ) else {
                    return
                }
            }

            let fullSnapshot = try await readThreadSnapshot(threadID: threadID, includeTurns: true)
            applyLiveThreadSnapshot(fullSnapshot)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.debug("Visible active thread refresh skipped after summary probe error: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func visibleActiveThreadRefreshInterval() -> Duration {
        if let overrideMilliseconds = ProcessInfo.processInfo.environment["COTG_ACTIVE_THREAD_SYNC_INTERVAL_MS"]
            .flatMap(Int.init),
           overrideMilliseconds > 0 {
            return .milliseconds(overrideMilliseconds)
        }

        if activeTurnID != nil {
            return .milliseconds(700)
        }

        if activeProtocolKind == .websocket {
            // Desktop-started turns may not emit cross-client delta events to this resumed
            // websocket, so keep the visible Codex screen close to the Mac app with fast reads.
            return .milliseconds(700)
        }

        if isRestoringActiveTranscript || transcript.isEmpty {
            return .seconds(1)
        }

        return .seconds(2)
    }

    public func visibleActiveThreadRefreshLoopKey(
        sceneIsActive: Bool,
        browserIsVisible: Bool
    ) -> String {
        guard sceneIsActive,
              !browserIsVisible,
              !isDemoModeEnabled,
              case .connected = connectionState,
              let threadID = activeSession?.threadID else {
            return "inactive"
        }

        return "\(threadID)::\(activeProtocolKind.rawValue)::\(activeTurnID == nil ? "idle" : "streaming")"
    }

    private func refreshCurrentThreadHistoryIfPossible() async {
        guard let threadID = resolveThreadID(preferredThreadID: nil) else {
            return
        }

        await MainActor.run {
            self.beginRestoringActiveTranscript(for: threadID)
        }

        do {
            let snapshot = switch activeProtocolKind {
            case .stdio:
                try await safeLaneClient.readThread(threadID: threadID, includeTurns: true)
            case .websocket, .directEndpoint:
                try await loopbackClient.readThread(threadID: threadID, includeTurns: true)
            }

            await MainActor.run {
                self.applyLiveThreadSnapshot(snapshot)
            }
        } catch {
            await MainActor.run {
                self.isRestoringActiveTranscript = false
                let summary = "Thread refresh failed: \(error.localizedDescription)"
                if !self.recordHostRuntimeTransportStatus(from: summary) {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: summary
                        )
                    )
                }
            }
        }
    }

    private func readThreadSnapshot(
        threadID: String,
        includeTurns: Bool
    ) async throws -> CodexThreadSnapshot {
        switch activeProtocolKind {
        case .stdio:
            return try await safeLaneClient.readThread(threadID: threadID, includeTurns: includeTurns)
        case .websocket, .directEndpoint:
            return try await loopbackClient.readThread(threadID: threadID, includeTurns: includeTurns)
        }
    }

    static func activeThreadSummaryDigest(from summary: CodexThreadSummary) -> ActiveThreadSummaryDigest {
        ActiveThreadSummaryDigest(
            threadID: summary.id,
            updatedAt: summary.updatedAt,
            preview: summary.preview.trimmingCharacters(in: .whitespacesAndNewlines),
            status: summary.status
        )
    }

    static func shouldRefreshVisibleActiveThread(
        baseline: ActiveThreadSummaryDigest?,
        latest: CodexThreadSummary,
        expectedThreadID: String
    ) -> Bool {
        guard latest.id == expectedThreadID else {
            return false
        }

        let latestDigest = activeThreadSummaryDigest(from: latest)
        guard let baseline else {
            return true
        }

        return baseline != latestDigest
    }

    static func shouldUseVisibleActiveThreadSummaryGate(protocolKind: CodexProtocolKind) -> Bool {
        switch protocolKind {
        case .stdio, .websocket:
            // JSONL fallback and resumed websocket sessions can expose fresh turns while the
            // state-store summary remains stale or notLoaded, so they must verify the full thread.
            return false
        case .directEndpoint:
            return true
        }
    }

    static func shouldFallbackFromWebsocketError(
        protocolKind: CodexProtocolKind,
        loopbackUpgradeInProgress: Bool,
        activeTurnID: String? = nil,
        message: String = ""
    ) -> Bool {
        if isNonFatalWebsocketRuntimeMessage(message) {
            return false
        }

        return !(loopbackUpgradeInProgress && protocolKind == .stdio)
    }

    static func shouldSuppressWebsocketErrorAfterCompletedTurn(
        source: CodexProtocolKind,
        suppressNext: Bool
    ) -> Bool {
        source == .websocket && suppressNext
    }

    static func isNonFatalWebsocketRuntimeMessage(_ message: String) -> Bool {
        isBenignWebsocketCancellationMessage(message)
            || message.lowercased().contains("timeout waiting for child process to exit")
    }

    static func isBenignWebsocketCancellationMessage(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("cancel")
            || normalizedMessage.contains("urlerrordomain error -999")
            || normalizedMessage.contains("nsurlerrordomain error -999")
            || normalizedMessage.contains("code=-999")
    }

    static func shouldRetryLoopbackUpgradeWithFreshListener(after error: Error) -> Bool {
        let detail = error.localizedDescription.lowercased()
        return detail.contains("channelpipelineerror")
            || detail.contains("channelerror")
            || detail.contains("connection reset")
            || detail.contains("connection refused")
            || detail.contains("network connection was lost")
            || detail.contains("websocket initialize")
            || detail.contains("socket")
            || detail.contains("niossh")
    }

    static func shouldScheduleLoopbackRecoveryRetry(
        summary: String,
        shouldAutoUpgrade: Bool,
        isSuppressedUntilReconnect: Bool,
        protocolKind: CodexProtocolKind,
        isConnected: Bool,
        hasSelectedMachine: Bool,
        threadID: String?,
        activeTurnID: String?,
        loopbackUpgradeFeatureAvailable: Bool
    ) -> Bool {
        guard shouldAutoUpgrade,
              !isSuppressedUntilReconnect,
              isLoopbackFallbackNotice(summary),
              protocolKind == .stdio,
              isConnected,
              hasSelectedMachine,
              threadID != nil,
              activeTurnID == nil,
              loopbackUpgradeFeatureAvailable else {
            return false
        }

        return true
    }

    static func loopbackRecoveryRetryDelayMilliseconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let rawValue = environment["COTG_LOOPBACK_RECOVERY_RETRY_DELAY_MS"],
              let milliseconds = Int(rawValue) else {
            return 30_000
        }

        return max(0, milliseconds)
    }

    private func scheduleLoopbackRecoveryRetry(cwd: String?) {
        guard loopbackRecoveryRetryTask == nil else {
            return
        }

        let retryCwd = cwd ?? connectionBootstrapWorkspaceRoot()
        let delayMilliseconds = Self.loopbackRecoveryRetryDelayMilliseconds()
        loopbackRecoveryRetryTask = Task { @MainActor [weak self] in
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            guard let self, !Task.isCancelled else {
                return
            }

            self.loopbackRecoveryRetryTask = nil
            let isConnected: Bool
            if case .connected = self.connectionState {
                isConnected = true
            } else {
                isConnected = false
            }

            guard Self.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: self.shouldAutoUpgradeLoopback,
                isSuppressedUntilReconnect: self.automaticLoopbackUpgradeSuppressedUntilReconnect,
                protocolKind: self.activeProtocolKind,
                isConnected: isConnected,
                hasSelectedMachine: self.selectedMachine != nil,
                threadID: self.activeSession?.threadID,
                activeTurnID: self.activeTurnID,
                loopbackUpgradeFeatureAvailable: self.loopbackUpgradeFeatureAvailable,
                canUseOptimizationLane: self.capabilityReport.canUseOptimizationLane,
                lastAttemptAt: self.lastAutomaticLoopbackUpgradeAttemptAt,
                now: Date()
            ) else {
                return
            }

            self.automaticLoopbackUpgradePending = true
            await self.maybeAttemptAutomaticLoopbackUpgrade(cwd: retryCwd)
        }
    }

    private func maybeRetryPreferredLoopbackUpgradeForVisibleThread(cwd: String) async {
        let isConnected: Bool
        if case .connected = connectionState {
            isConnected = true
        } else {
            isConnected = false
        }

        guard Self.shouldRetryPreferredLoopbackUpgrade(
            shouldAutoUpgrade: shouldAutoUpgradeLoopback,
            isSuppressedUntilReconnect: automaticLoopbackUpgradeSuppressedUntilReconnect,
            protocolKind: activeProtocolKind,
            isConnected: isConnected,
            hasSelectedMachine: selectedMachine != nil,
            threadID: activeSession?.threadID,
            activeTurnID: activeTurnID,
            loopbackUpgradeFeatureAvailable: loopbackUpgradeFeatureAvailable,
            canUseOptimizationLane: capabilityReport.canUseOptimizationLane,
            lastAttemptAt: lastAutomaticLoopbackUpgradeAttemptAt,
            now: Date()
        ) else {
            return
        }

        lastAutomaticLoopbackUpgradeAttemptAt = Date()
        automaticLoopbackUpgradePending = true
        await maybeAttemptAutomaticLoopbackUpgrade(cwd: cwd)
    }

    @discardableResult
    private func recoverPreferredLoopbackAfterRelaunchIfNeeded() -> Bool {
        let isConnected: Bool
        if case .connected = connectionState {
            isConnected = true
        } else {
            isConnected = false
        }

        guard Self.shouldRecoverPreferredLoopbackAfterRelaunch(
            shouldAutoUpgrade: shouldAutoUpgradeLoopback,
            isSuppressedUntilReconnect: automaticLoopbackUpgradeSuppressedUntilReconnect,
            protocolKind: activeProtocolKind,
            isConnected: isConnected,
            hasSelectedMachine: selectedMachine != nil,
            threadID: activeSession?.threadID,
            activeTurnID: activeTurnID,
            loopbackUpgradeFeatureAvailable: loopbackUpgradeFeatureAvailable
        ) else {
            return false
        }

        let cwd = activeSession?.workspaceRoot ?? resolvedWorkspaceRoot() ?? connectionBootstrapWorkspaceRoot()
        automaticLoopbackUpgradePending = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.maybeAttemptAutomaticLoopbackUpgrade(cwd: cwd)
            if self.activeProtocolKind == .stdio {
                await self.refreshCurrentThreadHistoryIfPossible()
            }
        }
        return true
    }

    private func switchActiveThreadOnCurrentConnection(_ session: SessionRecord) async {
        guard let threadID = session.threadID else {
            return
        }

        await MainActor.run {
            self.beginRestoringActiveTranscript(for: threadID)
        }

        do {
            let previousExecutionProfileState = session.executionProfileState
            let requestedOptions = requestedThreadExecutionOptions(
                session: session,
                cwd: session.workspaceRoot,
                model: nil,
                baselineConfig: session.executionProfileState?.baselineConfig
            )
            let resumed = try await resumeThreadWithSnapshotFallback(
                threadID: threadID,
                options: requestedOptions,
                protocolKind: activeProtocolKind
            )
            let executionProfileState = updatedExecutionProfileState(
                from: previousExecutionProfileState,
                snapshot: SessionExecutionSnapshot(
                    runtime: previousExecutionProfileState?.profile.runtime,
                    baselineConfig: previousExecutionProfileState?.baselineConfig,
                    constraints: previousExecutionProfileState?.constraints,
                    support: previousExecutionProfileState?.support ?? .init(serverRequestRouting: .supported)
                ),
                effectiveProfile: resumed.executionProfile,
                requestedThreadOptions: requestedOptions,
                overridesKind: .supported,
                detectResumeMismatch: true
            )

            await MainActor.run {
                self.applyLiveThreadSnapshot(resumed.thread)
                self.upsertSession(
                    threadID: resumed.thread.id,
                    routeID: session.routeID,
                    workspaceRoot: resumed.cwd,
                    lastKnownProtocol: self.activeProtocolKind,
                    lastKnownRouteKind: session.lastKnownRouteKind,
                    lastKnownBootstrap: session.lastKnownBootstrap,
                    lastModel: resumed.model,
                    reasoningEffort: resumed.reasoningEffort,
                    executionProfileState: executionProfileState,
                    bindProtocolThreadID: resumed.isLiveBinding
                )
                self.persistActiveExecutionProfileState(executionProfileState)
                self.appendExecutionProfileChangeNoticeIfNeeded(
                    previous: previousExecutionProfileState,
                    current: executionProfileState
                )
                self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
            }
            await performDeferredPostConnectWork(
                cwd: resumed.cwd,
                preferLoopbackUpgrade: shouldAutoUpgradeLoopback
            )
        } catch {
            if shouldTreatResumeErrorAsUnavailableSelectedThread(error) {
                recoverFromUnavailableSelectedThread()
                await refreshRepoBrowserSessions(limit: 20, fetchAllPages: false)
                let unavailableMessage = UnavailableSelectedThreadError.message(for: activeUnavailableSelectedThreadID)
                await MainActor.run {
                    self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: unavailableMessage
                        )
                    )
                    self.updateSessionState(
                        transportState: .connected,
                        lastErrorSummary: unavailableMessage
                    )
                }
                return
            }

            await MainActor.run {
                self.isRestoringActiveTranscript = false
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Thread resume failed: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func prepareLoopbackUpgradeSession(cwd: String) async throws -> LoopbackUpgradeSession {
        _ = try await withAsyncTimeout(
            .seconds(10),
            errorMessage: "Loopback listener start timed out."
        ) {
            try await self.safeLaneClient.startLoopbackListener()
        }
        guard try await waitForLoopbackListenerReadiness() else {
            throw CodexWebSocketError.invalidResponse("Loopback listener did not become healthy in time.")
        }

        do {
            return try await withAsyncTimeout(
                .seconds(75),
                errorMessage: "Loopback websocket upgrade did not finish in time."
            ) {
                try await self.establishLoopbackSession(cwd: cwd)
            }
        } catch {
            guard Self.shouldRetryLoopbackUpgradeWithFreshListener(after: error) else {
                throw error
            }

            Self.logger.warning("Restarting loopback listener after upgrade transport failure: \(error.localizedDescription, privacy: .public)")
            try? await safeLaneClient.stopLoopbackListener()
            _ = try await withAsyncTimeout(
                .seconds(10),
                errorMessage: "Loopback listener restart timed out."
            ) {
                try await self.safeLaneClient.startLoopbackListener()
            }
            guard try await waitForLoopbackListenerReadiness() else {
                throw CodexWebSocketError.invalidResponse("Loopback listener did not become healthy after restart.")
            }
            return try await withAsyncTimeout(
                .seconds(75),
                errorMessage: "Loopback websocket upgrade did not finish after listener restart."
            ) {
                try await self.establishLoopbackSession(cwd: cwd)
            }
        }
    }

    private func attemptLoopbackUpgrade(cwd: String) async {
        guard activeProtocolKind == .stdio,
              selectedMachine != nil,
              activeSession?.threadID != nil else {
            return
        }

        loopbackUpgradeInProgress = true
        defer { loopbackUpgradeInProgress = false }
        lastAutomaticLoopbackUpgradeAttemptAt = Date()
        do {
            Self.logger.log("Loopback upgrade requested for cwd: \(cwd, privacy: .public)")
            let upgradedSession = try await prepareLoopbackUpgradeSession(cwd: cwd)
            let previousExecutionProfileState = activeSession?.executionProfileState
            let upgradedExecutionProfileState = updatedExecutionProfileState(
                from: previousExecutionProfileState,
                snapshot: SessionExecutionSnapshot(
                    runtime: previousExecutionProfileState?.profile.runtime,
                    baselineConfig: previousExecutionProfileState?.baselineConfig,
                    constraints: previousExecutionProfileState?.constraints,
                    support: previousExecutionProfileState?.support ?? .init(serverRequestRouting: .supported)
                ),
                effectiveProfile: upgradedSession.resumedThread?.executionProfile ?? upgradedSession.thread.executionProfile,
                requestedThreadOptions: requestedThreadExecutionOptions(
                    session: activeSession,
                    cwd: cwd,
                    model: upgradedSession.thread.model,
                    baselineConfig: previousExecutionProfileState?.baselineConfig
                ),
                overridesKind: .supported,
                detectResumeMismatch: upgradedSession.resumedThread != nil
            )
            await MainActor.run {
                self.lastLoopbackUpgradeStandbyReason = nil
                self.hostRuntimeTransportStatus = nil
                self.loopbackRecoveryRetryTask?.cancel()
                self.loopbackRecoveryRetryTask = nil
                self.applyAvailableModels(upgradedSession.models)
                self.activeProtocolKind = .websocket
                self.connectionState = .connected(upgradedSession.url.absoluteString)
                self.applyLiveThreadSnapshot(upgradedSession.resumedThread?.thread)
                self.upsertSession(
                    threadID: upgradedSession.thread.id,
                    routeID: self.activeSession?.routeID ?? self.selectedBootstrapRoute?.id,
                    workspaceRoot: cwd,
                    lastKnownProtocol: .websocket,
                    lastKnownRouteKind: self.activeSession.flatMap { self.selectedMachine?.route(id: $0.routeID)?.kind } ?? self.selectedBootstrapRoute?.kind,
                    lastKnownBootstrap: .standardSSH,
                    lastModel: upgradedSession.thread.model,
                    reasoningEffort: upgradedSession.thread.reasoningEffort,
                    executionProfileState: upgradedExecutionProfileState,
                    bindProtocolThreadID: upgradedSession.resumedThread?.isLiveBinding ?? true
                )
                self.persistActiveExecutionProfileState(upgradedExecutionProfileState)
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Upgraded to the loopback websocket optimization lane."
                    )
                )
                self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
            }
            Self.logger.log("Loopback upgrade succeeded.")
            await refreshCapabilityDiagnosticsFromSafeLane()
        } catch {
            Self.logger.error("Loopback upgrade failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.lastLoopbackUpgradeStandbyReason = error.localizedDescription
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Loopback upgrade stayed on standby: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func maybeAttemptAutomaticLoopbackUpgrade(cwd: String) async {
        if let task = automaticLoopbackUpgradeTask {
            await task.value
            return
        }

        guard Self.shouldAttemptAutomaticLoopbackUpgrade(
            pending: automaticLoopbackUpgradePending,
            protocolKind: activeProtocolKind,
            isConnected: {
                if case .connected = connectionState {
                    return true
                }
                return false
            }(),
            hasSelectedMachine: selectedMachine != nil,
            threadID: activeSession?.threadID
        ) else {
            return
        }

        automaticLoopbackUpgradePending = false
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.attemptLoopbackUpgrade(cwd: cwd)
            self.automaticLoopbackUpgradeTask = nil
        }
        automaticLoopbackUpgradeTask = task
        await task.value
    }

    private func attemptSigningSensitiveLoopbackUpgradeIfNeeded(for request: PendingTurnRequest) async {
        let isConnected: Bool
        if case .connected = connectionState {
            isConnected = true
        } else {
            isConnected = false
        }

        guard Self.shouldAttemptSigningSensitiveLoopbackUpgrade(
            requiresSigningSensitiveHostReadiness: request.requiresSigningSensitiveHostReadiness,
            preferLoopbackUpgrade: shouldAutoUpgradeLoopback,
            protocolKind: activeProtocolKind,
            isConnected: isConnected,
            hasSelectedMachine: selectedMachine != nil,
            threadID: activeSession?.threadID
        ) else {
            return
        }

        guard let upgradeCwd = activeSession?.workspaceRoot ?? resolvedWorkspaceRoot() else {
            return
        }

        automaticLoopbackUpgradePending = true
        await maybeAttemptAutomaticLoopbackUpgrade(cwd: upgradeCwd)
    }

    private func ensureSigningSensitiveHostReadinessIfNeeded(for request: PendingTurnRequest) async throws {
        guard request.requiresSigningSensitiveHostReadiness else {
            return
        }

        if let detail = Self.signingSensitiveTurnLaneFailureDetail(
                protocolKind: activeProtocolKind,
                lastLoopbackUpgradeStandbyReason: lastLoopbackUpgradeStandbyReason
        ) {
            throw SigningSensitiveHostReadinessError(detail: detail)
        }

        do {
            let result = try await safeLaneClient.execute(
                command: Self.signingSensitiveHostReadinessProbeCommand(
                    includeUploadAuth: request.requiresUploadAuthReadiness
                )
            )
            guard result.exitStatus == 0 else {
                throw SigningSensitiveHostReadinessError(
                    detail: Self.signingSensitiveHostReadinessProbeFailureDetail(
                        result,
                        includeUploadAuth: request.requiresUploadAuthReadiness
                    )
                )
            }
        } catch let error as SigningSensitiveHostReadinessError {
            throw error
        } catch {
            throw SigningSensitiveHostReadinessError(
                detail: "Host readiness preflight could not run: \(error.localizedDescription)"
            )
        }
    }

    private func surfaceSigningSensitiveHostReadinessFailure(
        for request: PendingTurnRequest,
        detail: String
    ) {
        let summary = SigningSensitiveHostReadinessError(detail: detail).localizedDescription
        updateTranscriptMessageDeliveryState(messageID: request.transcriptMessageID, to: .failed)
        updateSessionState(transportState: .connected, lastErrorSummary: summary)
        transcript.append(
            SessionMessage(
                role: .system,
                text: summary
            )
        )
    }

    private func scheduleConnectionAttemptWatchdog(generation: Int) {
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.staleConnectingSessionTimeout))
            } catch {
                return
            }

            guard let self,
                  self.connectionAttemptGeneration == generation else {
                return
            }

            self.restartStaleConnectingSessionIfNeeded(
                reason: "Restarting stalled host reconnect after timeout."
            )
        }
    }

    private func withAsyncTimeout<T: Sendable>(
        _ timeout: Duration,
        errorMessage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let coordinator = AsyncTimeoutCoordinator<T>()
        return try await withCheckedThrowingContinuation { continuation in
            let operationTask = Task {
                do {
                    let value = try await operation()
                    coordinator.complete(.success(value), continuation: continuation)
                } catch {
                    coordinator.complete(.failure(error), continuation: continuation)
                }
            }
            coordinator.setOperationTask(operationTask)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                coordinator.cancelOperation()
                coordinator.complete(
                    .failure(CodexWebSocketError.invalidResponse(errorMessage)),
                    continuation: continuation
                )
            }
            coordinator.setTimeoutTask(timeoutTask)
        }
    }

    private func waitForLoopbackListenerReadiness(
        port: Int = 9494,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(250)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if try await safeLaneClient.loopbackListenerIsHealthy(port: port) {
                Self.logger.log("Loopback listener is healthy on port \(port, privacy: .public).")
                return true
            }

            try await Task.sleep(for: pollInterval)
        }

        Self.logger.warning("Loopback listener did not become healthy on port \(port, privacy: .public) before timeout.")
        return false
    }

    private func establishLoopbackSession(cwd: String) async throws -> LoopbackUpgradeSession {
        var lastError: Error?

        for attempt in 1...4 {
            Self.logger.log("Loopback websocket attempt \(attempt, privacy: .public) starting.")

            do {
                let url = try await withAsyncTimeout(
                    .seconds(5),
                    errorMessage: "Loopback local port forward did not start in time."
                ) {
                    try await self.safeLaneClient.startLocalPortForward()
                }
                Self.logger.log("Loopback port forward ready at \(url.absoluteString, privacy: .public).")

                try await withAsyncTimeout(
                    .seconds(5),
                    errorMessage: "Loopback websocket initialize did not complete in time."
                ) {
                    try await self.loopbackClient.connect(
                        configuration: CodexLiveConfiguration(
                            url: url,
                            cwd: cwd,
                            clientInfo: CodexRPCClientInfo(
                                name: "Coding On The Go",
                                version: "0.1"
                            )
                        ),
                        onEvent: { [weak self] event in
                            Task { @MainActor in
                                self?.handle(event: event, source: .websocket)
                            }
                        }
                    )
                }

                let models = try await withAsyncTimeout(
                    .seconds(5),
                    errorMessage: "Loopback model/list did not complete in time."
                ) {
                    try await self.loopbackClient.listModels()
                }
                let startModelOverride = Self.normalizedModelIdentifier(selectedModel)
                    ?? Self.normalizedModelIdentifier(activeSession?.lastModel)
                    ?? models.first(where: \.isDefault)?.model
                    ?? models.first?.model
                let expectedThreadID = activeSession?.threadID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resumedThread = try await withAsyncTimeout(
                    .seconds(30),
                    errorMessage: "Loopback thread/resume did not complete in time."
                ) {
                    try await self.resumeLoopbackThreadIfPossible(
                        options: self.requestedThreadExecutionOptions(
                            session: self.activeSession,
                            cwd: cwd,
                            model: nil,
                            baselineConfig: self.activeSession?.executionProfileState?.baselineConfig
                        )
                    )
                }
                if let errorMessage = Self.loopbackUpgradeResumeMismatchMessage(
                    expectedThreadID: expectedThreadID,
                    resumedThreadID: resumedThread?.thread.id
                ) {
                    throw CodexWebSocketError.invalidResponse(errorMessage)
                }
                if resumedThread == nil, activeSessionRequiresExplicitThreadSelection {
                    throw UnavailableSelectedThreadError(threadID: activeUnavailableSelectedThreadID)
                }
                let thread = if let resumedThread {
                    CodexThreadContext(
                        id: resumedThread.thread.id,
                        cwd: resumedThread.cwd,
                        model: resumedThread.model,
                        reasoningEffort: resumedThread.reasoningEffort,
                        executionProfile: resumedThread.executionProfile
                    )
                } else {
                    try await withAsyncTimeout(
                        .seconds(5),
                        errorMessage: "Loopback thread/start did not complete in time."
                    ) {
                        try await self.loopbackClient.startThread(
                            options: self.requestedThreadExecutionOptions(
                                session: self.activeSession,
                                cwd: cwd,
                                model: startModelOverride,
                                baselineConfig: self.activeSession?.executionProfileState?.baselineConfig
                            )
                        )
                    }
                }

                return LoopbackUpgradeSession(
                    url: url,
                    models: models,
                    resumedThread: resumedThread,
                    thread: thread
                )
            } catch {
                lastError = error
                Self.logger.warning("Loopback websocket attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await loopbackClient.disconnect()
                try? await safeLaneClient.stopLocalPortForward()
                if attempt < 4 {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        throw lastError ?? CodexWebSocketError.invalidResponse("Loopback websocket session did not initialize.")
    }

    private func connectionCandidate(cwd: String) async throws -> ConnectionCandidate? {
        try await AppConnectionPlanner.connectionCandidate(
            selectedMachine: selectedMachine,
            cwd: cwd,
            sshCandidate: { [self] machine, cwd in
                try await sshSafeLaneCandidate(for: machine, cwd: cwd)
            },
            directEndpointCandidate: { [self] machine, cwd in
                directWebSocketCandidate(for: machine, cwd: cwd)
            }
        )
    }

    private func sshSafeLaneCandidate(for machine: MachineRecord, cwd: String) async throws -> ConnectionCandidate? {
        let environment = ProcessInfo.processInfo.environment
        let route = sshBootstrapRoute(for: machine)
        guard let route,
              let endpoint = resolvedSSHBootstrapEndpoint(for: route, environment: environment),
              let username = sshUsername(for: machine, route: route) else {
            return nil
        }
        guard let hostValidation = try await prepareSSHHostValidationPolicyForConnection(
            for: machine,
            route: route,
            scannedKeyProvider: { [self] in
                try await scanHostKey(for: machine, route: route)
            }
        ) else {
            return nil
        }

        let authentication: SSHAuthenticationMaterial
        if let configured = await configuredSSHAuthenticationMaterial(for: machine) {
            authentication = configured
        } else {
            switch try await recoverWorkingSSHCredentialForConnection(
                machine: machine,
                route: route,
                endpoint: endpoint,
                username: username,
                hostValidation: hostValidation,
                cwd: cwd
            ) {
            case let .recovered(recovered):
                authentication = recovered
            case .notFound:
                return nil
            }
        }

        return AppConnectionPlanner.makeSafeLaneCandidate(
            machineID: machine.id,
            endpoint: endpoint,
            route: route,
            username: username,
            authentication: authentication,
            hostValidation: hostValidation,
            proxy: resolvedSSHProxyConfiguration(for: route),
            cwd: cwd,
            codexHome: configuredTestCodexHome(from: environment)
        )
    }

    private func directWebSocketCandidate(for machine: MachineRecord, cwd: String) -> ConnectionCandidate? {
        guard let route = machine.route(for: .companionDirect),
              route.isEligibleForTraffic,
              let endpoint = route.companionEndpoint else {
            return nil
        }

        return AppConnectionPlanner.makeDirectEndpointCandidate(
            machineID: machine.id,
            endpoint: endpoint,
            route: route,
            cwd: cwd,
            bootstrap: directEndpointBootstrap(for: route)
        )
    }

    private func directEndpointBootstrap(for route: RouteRecord) -> BootstrapStrategy {
        route.publishedByCompanion || route.discoverySource == .companionAdvertisement
            ? .companionManaged
            : .codexAppServerWebSocket
    }

    private func hasAlternativeConnectionCandidate(
        afterFailing attemptedRoute: (machineID: MachineRecord.ID, routeID: RouteRecord.ID)
    ) -> Bool {
        guard selectedMachineID == attemptedRoute.machineID else {
            return false
        }

        if let route = selectedDirectWebSocketReadiness.route,
           selectedDirectWebSocketReadiness.isReady,
           route.id != attemptedRoute.routeID {
            return true
        }

        if let route = selectedBootstrapRoute,
           selectedBootstrapRouteReadiness.isReady,
           route.id != attemptedRoute.routeID {
            return true
        }

        return false
    }

    private func sshBootstrapRoute(for machine: MachineRecord) -> RouteRecord? {
        let sessionRouteContext = hasActiveExecutionContext ? activeSession : nil
        return RouteEvaluationPlanner.sshBootstrapRoute(
            for: machine,
            lastKnownRouteKind: sessionRouteContext?.lastKnownRouteKind,
            activeRouteID: sessionRouteContext?.routeID,
            externalTailnetAppInstalled: externalTailnetAppInstalled,
            allowsNearbyNetworkRoutes: allowsNearbyNetworkRoutes
        )
    }

    private func startNearbyRoutePathMonitoring() {
        #if canImport(Network)
        guard nearbyRoutePathMonitor == nil else {
            return
        }

        let monitor = NWPathMonitor()
        nearbyRoutePathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let allowsNearbyRoutes = Self.allowsNearbyRoutes(for: path)
            Task { @MainActor [weak self] in
                self?.allowsNearbyNetworkRoutes = allowsNearbyRoutes
            }
        }
        monitor.start(queue: nearbyRoutePathMonitorQueue)
        #endif
    }

    #if canImport(Network)
    nonisolated private static func allowsNearbyRoutes(for path: NWPath) -> Bool {
        guard path.status == .satisfied else {
            return false
        }

        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return true
        }

        if path.usesInterfaceType(.cellular) {
            return false
        }

        return false
    }
    #endif

    private func resolvedWorkspaceRoot() -> String? {
        Self.normalizedWorkspaceRoot(runtimeConfiguration.workspaceRootOverride)
            ?? Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot)
    }

    public var browserWorkspaceRootHint: String? {
        preferredBootstrapWorkspaceRoot()
    }

    private func connectionBootstrapWorkspaceRoot() -> String {
        preferredBootstrapWorkspaceRoot() ?? "."
    }

    private func preferredBootstrapWorkspaceRoot() -> String? {
        return Self.normalizedWorkspaceRoot(runtimeConfiguration.workspaceRootOverride)
            ?? Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot)
            ?? Self.normalizedWorkspaceRoot(runtimeConfiguration.bootstrapWorkspaceRoot)
            ?? catalogWorkspaceRoot(for: selectedMachineID)
    }

    private func catalogWorkspaceRoot(for machineID: MachineRecord.ID?) -> String? {
        guard let machineID else {
            return nil
        }

        return hostThreadCatalog
            .filter { $0.machineID == machineID }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first?
            .workspaceRoot
    }

    private func resolveThreadID(preferredThreadID: String?) -> String? {
        if let preferredThreadID = Self.normalizedThreadID(preferredThreadID) {
            return preferredThreadID
        }

        let protocolThreadID: String? = switch activeProtocolKind {
        case .stdio:
            stdioThreadID
        case .directEndpoint:
            directEndpointThreadID ?? stdioThreadID
        case .websocket:
            loopbackThreadID ?? stdioThreadID
        }

        return Self.normalizedThreadID(activeSession?.threadID)
            ?? Self.normalizedThreadID(protocolThreadID)
    }

    func boundProtocolThreadID(preferredThreadID: String?) -> String? {
        if let preferredThreadID {
            return preferredThreadID
        }

        return switch activeProtocolKind {
        case .stdio:
            stdioThreadID
        case .directEndpoint:
            directEndpointThreadID ?? stdioThreadID
        case .websocket:
            loopbackThreadID ?? stdioThreadID
        }
    }

    func requiresLiveThreadBindingBeforeTurnStart(preferredThreadID: String?) -> Bool {
        boundProtocolThreadID(preferredThreadID: preferredThreadID) == nil
            && activeSession?.threadID != nil
    }

    private func applyAvailableModels(_ models: [CodexModelDescriptor]) {
        let preserveFastMode = isFastModeSelected
        availableModels = models
        lastSuccessfulModelRefreshAt = Date()

        guard !models.isEmpty else {
            selectedModel = nil
            return
        }

        if let selectedModel,
           models.contains(where: { $0.model == selectedModel }) {
            selectedReasoningEffort = preserveFastMode
                ? fastestSupportedReasoningEffort(for: selectedModelDescriptor)
                : supportedReasoningEffort(selectedReasoningEffort, for: selectedModelDescriptor)
            refreshComposerCapabilities()
            return
        }

        let preferred = models.first(where: \.isDefault) ?? models.first
        selectedModel = preferred?.model
        if let preferred {
            selectedReasoningEffort = preserveFastMode
                ? fastestSupportedReasoningEffort(for: preferred)
                : preferred.defaultReasoningEffort
        }
        refreshComposerCapabilities()
    }

    static func pendingApprovalRequestToPreserve(
        current: CodexApprovalRequest?,
        snapshot: CodexThreadSnapshot?
    ) -> CodexApprovalRequest? {
        guard let current,
              let snapshot,
              current.threadID == snapshot.id else {
            return nil
        }

        let threadStillWaitsOnApproval: Bool
        if case let .active(activeFlags) = snapshot.status {
            threadStillWaitsOnApproval = activeFlags.contains("waitingOnApproval")
        } else {
            threadStillWaitsOnApproval = false
        }

        if let turnID = current.turnID {
            if turnID == snapshot.activeTurnID || threadStillWaitsOnApproval {
                return current
            }
            return nil
        }

        guard threadStillWaitsOnApproval else {
            return nil
        }

        return current
    }

    private func applyLiveThreadSnapshot(_ snapshot: CodexThreadSnapshot?) {
        let pendingApprovalRequestToPreserve = Self.pendingApprovalRequestToPreserve(
            current: pendingApprovalRequest,
            snapshot: snapshot
        )
        pendingApprovalRequest = nil

        guard let snapshot else {
            let activeThreadID = activeSession?.threadID
            let canPreserveVisibleTranscript = {
                guard case .connecting = connectionState else {
                    return false
                }
                guard !transcript.isEmpty, let activeThreadID else {
                    return false
                }
                return displayedTranscriptThreadID == nil || activeThreadID == displayedTranscriptThreadID
            }()

            activeTranscriptSnapshot = nil
            prefetchedTranscriptHistory = []
            hiddenTranscriptMessageCount = 0
            lastObservedActiveThreadSummary = nil

            if canPreserveVisibleTranscript {
                if displayedTranscriptThreadID == nil {
                    displayedTranscriptThreadID = activeThreadID
                }
                activeTurnID = nil
                threadActivityFlags = []
                subagentActivitySummary = ClientOrchestratedSubagentPlanner.summary(for: clientSubagentTasks)
                isRestoringActiveTranscript = true
                return
            }

            transcript = []
            displayedTranscriptThreadID = nil
            activeTurnID = nil
            threadActivityFlags = []
            subagentActivitySummary = ClientOrchestratedSubagentPlanner.summary(for: clientSubagentTasks)
            revealedEarlierTranscriptMessageCount = 0
            isRestoringActiveTranscript = false
            return
        }

        if displayedTranscriptThreadID != snapshot.id {
            revealedEarlierTranscriptMessageCount = 0
        }

        activeTranscriptSnapshot = snapshot
        lastObservedActiveThreadSummary = Self.activeThreadSummaryDigest(from: snapshot.summary)
        prefetchedTranscriptHistory = []
        let transcriptPresentation = Self.visibleSessionMessages(
            existing: transcript,
            displayedThreadID: displayedTranscriptThreadID,
            snapshot: snapshot,
            revealedEarlierMessageCount: revealedEarlierTranscriptMessageCount
        )
        transcript = transcriptPresentation.messages
        hiddenTranscriptMessageCount = transcriptPresentation.hiddenMessageCount
        displayedTranscriptThreadID = snapshot.id
        activeTurnID = snapshot.activeTurnID
        if hostRuntimeTransportStatus?.kind == .threadRefreshFailed {
            hostRuntimeTransportStatus = nil
        }
        pendingApprovalRequest = pendingApprovalRequestToPreserve
        threadActivityFlags = activityFlags(from: snapshot)
        subagentActivitySummary = ClientOrchestratedSubagentPlanner.summary(for: clientSubagentTasks)
            ?? subagentSummary(from: snapshot)
        isRestoringActiveTranscript = false

        if let latestTurnID = snapshot.latestTurnID,
           let latestSummary = latestAssistantSummary(from: snapshot) {
            updateLastTurn(turnID: latestTurnID, summary: latestSummary)
        }

        if let machineID = selectedMachine?.id,
           let entry = hostThreadCatalogEntry(from: snapshot.summary, machineID: machineID) {
            upsertHostThreadCatalogEntry(entry)
        }
        schedulePendingTurnDrainAfterIdleSnapshotIfNeeded()
    }

    private func schedulePendingTurnDrainAfterIdleSnapshotIfNeeded() {
        rebuildPendingTurnRequestsFromPersistedQueueIfNeeded()
        guard activeTurnID == nil,
              !pendingTurnRequests.isEmpty else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  self.activeTurnID == nil else {
                return
            }
            self.beginPendingTurnRequestAfterReconnectIfPossible()
        }
    }

    public func revealEarlierTranscriptHistory() {
        guard hiddenTranscriptMessageCount > 0 else {
            return
        }

        if !prefetchedTranscriptHistory.isEmpty {
            let chunkSize = min(Self.transcriptHistoryRevealStep, prefetchedTranscriptHistory.count)
            let revealedChunk = Array(prefetchedTranscriptHistory.suffix(chunkSize))
            prefetchedTranscriptHistory.removeLast(chunkSize)
            transcript = revealedChunk + transcript
            hiddenTranscriptMessageCount = prefetchedTranscriptHistory.count
            return
        }

        guard let snapshot = activeTranscriptSnapshot else {
            return
        }

        revealedEarlierTranscriptMessageCount += Self.transcriptHistoryRevealStep
        let transcriptPresentation = Self.visibleSessionMessages(
            existing: transcript,
            displayedThreadID: displayedTranscriptThreadID,
            snapshot: snapshot,
            revealedEarlierMessageCount: revealedEarlierTranscriptMessageCount
        )
        transcript = transcriptPresentation.messages
        hiddenTranscriptMessageCount = transcriptPresentation.hiddenMessageCount
        displayedTranscriptThreadID = snapshot.id
    }

    private var baseCapabilityDiagnostics: HostCapabilityDiagnostics {
        guard let machine = selectedMachine else {
            return HostCapabilityDiagnostics(
                sshReachable: false,
                remoteLoginEnabled: false,
                codexInstalled: false,
                appServerAvailable: false,
                websocketSupported: false,
                authConfigured: false,
                hostKeyTrusted: false
            )
        }

        let route = sshBootstrapRoute(for: machine)
        let hostKeyTrusted: Bool
        if let route {
            hostKeyTrusted = (route.trustState == .trusted && route.trustedOpenSSHPublicKey != nil)
                || usesLocalhostTestingHostValidationOverride(for: route)
        } else {
            hostKeyTrusted = false
        }

        return HostCapabilityDiagnostics(
            sshReachable: route?.isReachable ?? false,
            remoteLoginEnabled: machine.capabilities.remoteLoginEnabled,
            codexInstalled: machine.capabilities.codexInstalled,
            appServerAvailable: machine.capabilities.codexInstalled,
            websocketSupported: machine.capabilities.websocketAppServerSupported,
            authConfigured: machine.credentialRef != nil
                || usesLocalhostTestingCredentialAutoload(for: machine),
            hostKeyTrusted: hostKeyTrusted
        )
    }

    private func refreshCapabilityDiagnosticsFromSafeLane() async {
        let diagnostics = await HostCapabilityRuntimeProbe.collect(
            base: baseCapabilityDiagnostics,
            using: SafeLaneCapabilityRunner(client: safeLaneClient)
        )

        await MainActor.run {
            self.runtimeCapabilityDiagnostics = diagnostics
            if let runtime = diagnostics.resolvedRuntime,
               let machine = self.selectedMachine,
               let machineIndex = self.machines.firstIndex(where: { $0.id == machine.id }) {
                self.machines[machineIndex].capabilities.resolvedRuntime = runtime
                self.machines[machineIndex].capabilities.codexInstalled = true
                self.machines[machineIndex].capabilities.codexVersion = runtime.version ?? self.machines[machineIndex].capabilities.codexVersion
            }
            self.transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Refreshed host capability diagnostics from the SSH safe lane."
                )
            )
        }
    }

    private func setReviewThreadID(_ reviewThreadID: String) {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)

        recentSessions[index].reviewThreadID = reviewThreadID
        persistStateAsync()
    }

    private func resolvePendingApproval(_ request: CodexApprovalRequest, decision: CodexApprovalDecision) {
        Task {
            do {
                switch activeProtocolKind {
                case .stdio:
                    try await safeLaneClient.resolveApproval(request, decision: decision)
                case .websocket, .directEndpoint:
                    try await loopbackClient.resolveApproval(request, decision: decision)
                }

                await MainActor.run {
                    if case let .grantRequestedPermissions(scopeSession) = decision,
                       scopeSession,
                       let requestedPermissions = request.requestedPermissions,
                       let existingState = self.activeSession?.executionProfileState {
                        let mergedState = CodexExecutionProfileCoordinator.mergeSessionPermissionGrant(
                            into: existingState,
                            permissions: requestedPermissions
                        )
                        self.persistActiveExecutionProfileState(mergedState)
                    }
                    self.pendingApprovalRequest = nil
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Resolved the pending \(request.kind.rawValue) approval request."
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: "Approval resolution failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func fallbackToSafeLane(summary: String, detail: String? = nil) {
        let fallbackWorkspaceRoot = browserWorkspaceRootHint
        Task {
            try? await safeLaneClient.stopLocalPortForward()
            await loopbackClient.disconnect()
        }
        Self.logger.log("Returning to the SSH safe lane. Detail: \(detail ?? "none", privacy: .public)")
        activeProtocolKind = .stdio
        automaticLoopbackUpgradePending = false
        automaticLoopbackUpgradeTask = nil
        suppressNextWebsocketErrorAfterCompletedTurn = false
        connectionState = .connected("stdio://\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"] ?? "localhost")")
        directEndpointThreadID = nil

        let fallbackThreadID = Self.safeLaneFallbackThreadID(
            activeSessionThreadID: activeSession?.threadID,
            stdioThreadID: stdioThreadID
        )
        let shouldScheduleRecoveryRetry = Self.shouldScheduleLoopbackRecoveryRetry(
            summary: summary,
            shouldAutoUpgrade: shouldAutoUpgradeLoopback,
            isSuppressedUntilReconnect: automaticLoopbackUpgradeSuppressedUntilReconnect,
            protocolKind: activeProtocolKind,
            isConnected: true,
            hasSelectedMachine: selectedMachine != nil,
            threadID: fallbackThreadID,
            activeTurnID: activeTurnID,
            loopbackUpgradeFeatureAvailable: loopbackUpgradeFeatureAvailable
        )
        if let threadID = fallbackThreadID {
            upsertSession(
                threadID: threadID,
                routeID: activeSession?.routeID ?? selectedBootstrapRoute?.id,
                workspaceRoot: fallbackWorkspaceRoot,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: activeSession.flatMap { selectedMachine?.route(id: $0.routeID)?.kind } ?? selectedBootstrapRoute?.kind,
                lastKnownBootstrap: .standardSSH,
                lastModel: activeSession?.lastModel,
                executionProfileState: activeSession?.executionProfileState
            )
        } else if let fallbackWorkspaceRoot,
                  let machine = selectedMachine {
            let index = activeSessionIndex(for: machine)
            recentSessions[index].sceneID = sceneID
            recentSessions[index].threadID = nil
            recentSessions[index].routeID = recentSessions[index].routeID ?? selectedBootstrapRoute?.id ?? machine.preferredRoute?.id
            recentSessions[index].workspaceRoot = fallbackWorkspaceRoot
            recentSessions[index].lastKnownProtocol = .stdio
            recentSessions[index].lastKnownRouteKind = recentSessions[index].lastKnownRouteKind ?? selectedBootstrapRoute?.kind ?? machine.preferredRoute?.kind
            recentSessions[index].lastKnownBootstrap = .standardSSH
            recentSessions[index].executionProfileState = recentSessions[index].executionProfileState ?? activeSession?.executionProfileState
            recentSessions[index].lastMode = Self.workspaceMode(for: fallbackWorkspaceRoot)
            recentSessions[index].transportState = .connected
            recentSessions[index].lastOpenedAt = .now
            activeSessionID = recentSessions[index].id
            persistStateSynchronouslyForLifecycle()
            persistStateAsync()
        }

        updateSessionState(transportState: .connected, lastErrorSummary: detail)
        if !recordHostRuntimeTransportStatus(from: summary) {
            transcript.append(SessionMessage(role: .system, text: summary))
        }
        scheduleRouteRecoveredNotification()
        beginPendingTurnRequestAfterReconnectIfPossible()
        if shouldScheduleRecoveryRetry {
            scheduleLoopbackRecoveryRetry(cwd: fallbackWorkspaceRoot ?? resolvedWorkspaceRoot())
        }
        Task {
            await refreshRepoBrowserSessions(limit: 20, fetchAllPages: false)
        }
    }

    private func markPreferredLaneDisconnectedAfterLoopbackFailure(summary: String, detail: String?) {
        Task {
            try? await safeLaneClient.stopLocalPortForward()
            await loopbackClient.disconnect()
        }
        Self.logger.log("Loopback websocket disconnected. Detail: \(detail ?? "none", privacy: .public)")
        activeProtocolKind = .stdio
        automaticLoopbackUpgradePending = false
        automaticLoopbackUpgradeTask = nil
        suppressNextWebsocketErrorAfterCompletedTurn = false
        loopbackRecoveryRetryTask?.cancel()
        loopbackRecoveryRetryTask = nil
        activeTurnID = nil
        finishAllLiveActivityMessages()
        connectionState = .disconnected
        updateSessionState(transportState: .disconnected, lastErrorSummary: detail)
        if !recordHostRuntimeTransportStatus(from: summary) {
            transcript.append(SessionMessage(role: .system, text: summary))
        }
    }

    private func scheduleNotification(_ event: NotificationEvent) {
        Task {
            try? await notificationCoordinator.schedule(event)
            let snapshot = await notificationCoordinator.snapshot()
            await MainActor.run {
                self.notificationSnapshot = snapshot
            }
        }
    }

    private func scheduleSessionFailure(_ reason: String) {
        guard let session = activeSession else {
            return
        }

        scheduleNotification(.sessionFailed(session: session, reason: reason))
    }

    private func scheduleRouteRecoveredNotification() {
        guard let machine = selectedMachine else {
            return
        }

        scheduleNotification(.routeRecovered(machine: machine))
    }

    private func shouldNotifyRouteRecovery(for route: RouteRecord) -> Bool {
        guard let lastFailureAt = route.lastFailureAt else {
            return false
        }

        return (route.lastSuccessAt ?? .distantPast) <= lastFailureAt
    }

    private static var embeddedTailnetFeatureAvailable: Bool {
        EmbeddedTailnetRuntimeFactory.hasNativeRuntime
    }

    private var loopbackUpgradeFeatureAvailable: Bool {
        let baseDiagnostics = baseCapabilityDiagnostics
        if runtimeCapabilityDiagnostics?.websocketSupported == true
            || baseDiagnostics.websocketSupported
            || activeSession?.lastKnownProtocol == .websocket {
            return true
        }

        // Runtime diagnostics can be stale or absent after relaunch. Prefer an
        // SSH-forwarded websocket probe on Codex-capable hosts instead of
        // falling straight back to raw stdio, which can wedge on large output.
        return baseDiagnostics.codexInstalled && baseDiagnostics.appServerAvailable
    }

    private static func bootstrapSnapshot(
        sceneID: String,
        machines: [MachineRecord]?,
        tailnetProfiles: [TailnetProfile]?,
        recentSessions: [SessionRecord]?,
        bootstrapSnapshot: MachineDirectorySnapshot?
    ) -> MachineDirectorySnapshot {
        if let bootstrapSnapshot {
            return bootstrapSnapshot
        }

        let machines = machines ?? []
        let tailnetProfiles = tailnetProfiles ?? []
        let recentSessions = recentSessions ?? defaultRecentSessions(for: machines, sceneID: sceneID)
        let hostThreadCatalog = defaultHostThreadCatalog(for: machines)

        return MachineDirectorySnapshot(
            machines: machines,
            tailnetProfiles: tailnetProfiles,
            recentSessions: recentSessions,
            hostThreadCatalog: hostThreadCatalog,
            preferences: UserPreferencesSnapshot(
                preferredMachineID: machines.first?.id,
                preferredTailnetProfileID: tailnetProfiles.first(where: \.isActive)?.id,
                restoreLastSessionOnLaunch: true,
                preferredBootstrap: .standardSSH,
                preferredProtocol: .stdio,
                preferredReasoningEffort: CodexReasoningEffort.medium.rawValue
            )
        )
    }

    private static func defaultRecentSessions(
        for machines: [MachineRecord],
        sceneID: String
    ) -> [SessionRecord] {
        machines.enumerated().map { index, machine in
            let previewWorkspaceRoot = previewWorkspaceRoot(for: machine)
            let route = RouteEvaluationPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: machine.lastSuccessfulRoute?.kind
            ) ?? machine.preferredRoute
            return SessionRecord(
                sceneID: sceneID,
                machineID: machine.id,
                routeID: route?.id,
                threadID: machine.isPreviewFixture ? "thread-preview-\(index + 1)" : nil,
                workspaceRoot: previewWorkspaceRoot,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: route?.kind,
                lastKnownBootstrap: route?.kind == .companionDirect ? .companionManaged : .standardSSH,
                lastModel: machine.isPreviewFixture ? "gpt-5.4" : nil,
                lastTurn: previewWorkspaceRoot.map { workspaceRoot in
                    RecentTurnMetadata(
                        turnID: "turn-preview-\(index + 1)",
                        summary: "Resume \(workspaceRoot.split(separator: "/").last.map(String.init) ?? "session")",
                        completedAt: .now
                    )
                },
                transportState: .disconnected,
                lastOpenedAt: .now
            )
        }
    }

    private static func defaultHostThreadCatalog(for machines: [MachineRecord]) -> [HostThreadCatalogEntry] {
        machines.enumerated().compactMap { index, machine in
            guard machine.isPreviewFixture,
                  let workspaceRoot = previewWorkspaceRoot(for: machine) else {
                return nil
            }

            return HostThreadCatalogEntry(
                id: "thread-preview-\(index + 1)",
                machineID: machine.id,
                workspaceRoot: workspaceRoot,
                name: index == 0 ? "Fix Codex client UX" : "Inspect infrastructure queue",
                preview: index == 0
                    ? "Finish the Project and Thread browser so it matches the Mac Codex client."
                    : "Review queue health and identify the next blocking jobs.",
                modelProvider: "openai",
                createdAt: .now,
                updatedAt: .now.addingTimeInterval(TimeInterval(-index * 600))
            )
        }
    }

    #if DEBUG
    private static func appStoreScreenshotSnapshot(sceneID: String) -> MachineDirectorySnapshot {
        let preview = MachineDirectorySnapshot.preview
        let primaryThread = preview.hostThreadCatalog.first(where: { $0.machineID == MachineRecord.preview.id })

        let seededSession = SessionRecord(
            sceneID: sceneID,
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.route(for: .manualSSH)?.id ?? MachineRecord.preview.preferredRoute?.id,
            threadID: primaryThread?.id,
            workspaceRoot: primaryThread?.workspaceRoot ?? "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .manualSSH,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastTurn: RecentTurnMetadata(
                turnID: "turn-app-store-preview",
                summary: "Refine the iPhone-first Codex surface",
                completedAt: .now
            ),
            transportState: .connected,
            lastOpenedAt: .now
        )

        return MachineDirectorySnapshot(
            machines: preview.machines,
            tailnetProfiles: preview.tailnetProfiles,
            recentSessions: [seededSession],
            hostThreadCatalog: preview.hostThreadCatalog,
            preferences: UserPreferencesSnapshot(
                preferredMachineID: MachineRecord.preview.id,
                preferredTailnetProfileID: preview.preferences.preferredTailnetProfileID,
                restoreLastSessionOnLaunch: true,
                preferredBootstrap: .standardSSH,
                preferredProtocol: .stdio,
                preferredReasoningEffort: CodexReasoningEffort.medium.rawValue
            )
        )
    }

    private func applyAppStoreSessionFixture() {
        guard let session = recentSessions.first else {
            return
        }

        select(machineID: session.machineID)
        syncKnownThreadIDs(threadID: session.threadID, replaceAll: true)
        activeSessionID = session.id
        activeExecutionProfileState = session.executionProfileState
        displayedTranscriptThreadID = session.threadID
        isRestoringActiveTranscript = false
        connectionState = .connected("SSH safe lane")
        activeProtocolKind = .stdio
        selectedParallelAgentMode = .off
        selectedReasoningEffort = .medium
        selectedModel = "gpt-5.4"
        availableModels = [
            CodexModelDescriptor(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                description: "Balanced default for App Store screenshot fixtures",
                isDefault: true,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [
                    .init(effort: .low, description: "Fast"),
                    .init(effort: .medium, description: "Balanced"),
                    .init(effort: .high, description: "Deep")
                ]
            ),
            CodexModelDescriptor(
                id: "gpt-5.5",
                model: "gpt-5.5",
                displayName: "GPT-5.5",
                description: "Frontier model for complex coding, research, and real-world work",
                isDefault: false,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [
                    .init(effort: .low, description: "Fast"),
                    .init(effort: .medium, description: "Balanced"),
                    .init(effort: .high, description: "Deep"),
                    .init(effort: .xhigh, description: "Extra deep")
                ],
                supportsPersonality: true
            )
        ]
        transcript = [
            SessionMessage(
                role: .system,
                text: "Connected to p over the SSH safe lane."
            ),
            SessionMessage(
                role: .user,
                text: "Tighten the iPhone transcript chrome, make New thread easier to find, and keep advanced controls secondary."
            ),
            SessionMessage(
                role: .assistant,
                kind: .commentary,
                text: "Thinking about the first iPhone pass."
            ),
            SessionMessage(
                role: .system,
                kind: .toolCall,
                text: "Exploring SessionWorkspaceCard.swift"
            ),
            SessionMessage(
                role: .system,
                kind: .fileChange,
                text: "Updated SessionWorkspaceCard.swift • modified"
            ),
            SessionMessage(
                role: .assistant,
                text: "I compressed the header, added Project and Thread search, promoted New thread alongside recent threads, and moved lower-frequency tools into Add. The remaining pass is the App Store screenshot set and final device polish."
            )
        ]
        if ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_LONG_TRANSCRIPT"] == "1" {
            revealedEarlierTranscriptMessageCount = 0
            let seededTranscript = transcript + Self.longTranscriptFixtureMessages()
            if seededTranscript.count > Self.recentTranscriptMessageLimit {
                prefetchedTranscriptHistory = Array(
                    seededTranscript.dropLast(Self.recentTranscriptMessageLimit)
                )
                transcript = Array(
                    seededTranscript.suffix(Self.recentTranscriptMessageLimit)
                )
                hiddenTranscriptMessageCount = prefetchedTranscriptHistory.count
            } else {
                prefetchedTranscriptHistory = []
                transcript = seededTranscript
                hiddenTranscriptMessageCount = 0
            }
        } else {
            prefetchedTranscriptHistory = []
            hiddenTranscriptMessageCount = 0
            revealedEarlierTranscriptMessageCount = 0
        }
        workspaceSummary = GitWorkspaceSummary(
            branch: "main",
            upstream: "origin/main",
            aheadCount: 1,
            changes: [
                WorkspaceFileChange(
                    path: "apps/ios/CodingOnTheGo/Sources/App/CodexRootView.swift",
                    staged: .modified,
                    unstaged: .unchanged
                ),
                WorkspaceFileChange(
                    path: "apps/ios/CodingOnTheGo/Sources/App/CodexSessionBrowserView.swift",
                    staged: .unchanged,
                    unstaged: .modified
                ),
                WorkspaceFileChange(
                    path: "apps/ios/CodingOnTheGo/Sources/App/ComposerToolsCard.swift",
                    staged: .unchanged,
                    unstaged: .modified
                )
            ]
        )
        workspaceFailureSummary = nil
        composerState = ComposerFeatureState(
            draft: "Summarize the remaining screenshot gaps before submission.",
            attachments: [
                ComposerAttachment(
                    kind: .photo,
                    displayName: "iphone-browser.png",
                    suggestedFilename: "iphone-browser.png"
                )
            ],
            canAttachPhotos: true,
            voiceInputAvailability: .available
        )
    }
    #endif

    private static func longTranscriptFixtureMessages() -> [SessionMessage] {
        [
            SessionMessage(role: .user, text: "Audit the setup card first."),
            SessionMessage(role: .assistant, text: "I separated one-time setup from route troubleshooting so the first connect path is easier to follow."),
            SessionMessage(role: .user, text: "Keep later reconnects focused on what changed."),
            SessionMessage(role: .assistant, text: "The current route status now explains whether you are on the same Wi-Fi, away from home, or missing remote access."),
            SessionMessage(role: .user, text: "Do not overload the main screen with debug text."),
            SessionMessage(role: .assistant, text: "The default cards now stay plain-language and the detailed diagnostics live under the secondary disclosure."),
            SessionMessage(role: .user, text: "Make the browser denser on phone."),
            SessionMessage(role: .assistant, text: "I tightened project cards, reduced duplicate machine chrome, and kept the project actions close to the active thread."),
            SessionMessage(role: .user, text: "What is still missing before the reconnect polish?"),
            SessionMessage(role: .assistant, text: "The remaining pass is staged transcript hydration, compact older message previews, and proving the thread lifecycle on the real phone."),
            SessionMessage(role: .user, text: "Do not let long answers take over the screen."),
            SessionMessage(role: .assistant, text: "Long historical messages now default to a compact preview so the latest working state stays visible."),
            SessionMessage(role: .user, text: "Tighten the browser rows and keep the machine label secondary."),
            SessionMessage(role: .assistant, text: "I reduced duplicate machine metadata and made New thread a first-class action per project."),
            SessionMessage(role: .user, text: "Make the composer feel more native on iPhone."),
            SessionMessage(role: .assistant, text: "The composer is now multiline, keeps voice visible, and moves lower-frequency actions into Add."),
            SessionMessage(role: .user, text: "What still needs device polish?"),
            SessionMessage(role: .assistant, text: "The remaining work is transcript density, jump-to-latest behavior, and physical-device validation on the connected iPhone."),
            SessionMessage(role: .user, text: "Keep the app calm and compact."),
            SessionMessage(role: .assistant, text: "I tightened the card spacing, compressed the header chrome, and reduced oversized pale surfaces across Codex."),
            SessionMessage(role: .user, text: "Do not let the transcript get lost while reconnecting."),
            SessionMessage(role: .assistant, text: "The reconnect path now keeps visible transcript history until a fuller thread snapshot replaces it.")
        ]
    }

    private static func activityBurstFixtureMessages() -> [SessionMessage] {
        [
            SessionMessage(role: .system, kind: .toolCall, text: "Refreshing host thread catalog"),
            SessionMessage(role: .system, kind: .commandExecution, text: "codex thread list • completed"),
            SessionMessage(role: .system, kind: .toolCall, text: "Inspecting workspace summary"),
            SessionMessage(role: .system, kind: .fileChange, text: "Updated SessionWorkspaceCard.swift • modified"),
            SessionMessage(role: .system, kind: .commandExecution, text: "swift test --filter TranscriptRows • passed"),
            SessionMessage(role: .system, kind: .toolCall, text: "Preparing physical iPhone proof on test-iphone")
        ]
    }

    private static func attachmentHistoryFixtureMessages() -> [SessionMessage] {
        [
            SessionMessage(
                role: .user,
                text: "Keep these artifacts with the thread history.",
                attachments: [
                    SessionMessageAttachment(
                        kind: .photo,
                        displayName: "browser-audit.png",
                        suggestedFilename: "browser-audit.png"
                    ),
                    SessionMessageAttachment(
                        kind: .voiceMemo,
                        displayName: "route-summary.m4a",
                        suggestedFilename: "route-summary.m4a"
                    )
                ]
            ),
            SessionMessage(
                role: .assistant,
                text: "Both attachments now stay visible in the transcript history instead of disappearing after send."
            )
        ]
    }

    private static func browserOperationsFixtureThreads(
        machineID: MachineRecord.ID,
        workspaceRoot: String
    ) -> [HostThreadCatalogEntry] {
        let now = Date()
        let fixtures: [(id: String, name: String, preview: String, ageMinutes: Int)] = [
            ("browser-active-thread", "Polish browser density", "Keep the active thread easy to reach on phone.", 0),
            ("browser-thread-2", "Fix settings continuity copy", "Shorten the Mac handoff labels in Settings.", 4),
            ("browser-thread-3", "Audit transcript grouping on phone", "Check whether grouped tool bursts stay compact on iPhone.", 8),
            ("browser-thread-4", "Verify attachment chips after reconnect", "Make sure attachment chips still render after a host refresh.", 12),
            ("browser-thread-5", "Tighten Mac handoff menu labels", "Keep Mac continuity actions short and explicit.", 16),
            ("browser-thread-6", "Document browser operation gaps", "List what still needs browser-level action depth.", 20)
        ]

        return fixtures.map { fixture in
            let updatedAt = Calendar.current.date(byAdding: .minute, value: -fixture.ageMinutes, to: now) ?? now
            let createdAt = Calendar.current.date(byAdding: .minute, value: -(fixture.ageMinutes + 3), to: now) ?? updatedAt
            return HostThreadCatalogEntry(
                id: fixture.id,
                machineID: machineID,
                workspaceRoot: workspaceRoot,
                name: fixture.name,
                preview: fixture.preview,
                modelProvider: "gpt-5.4",
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static func previewWorkspaceRoot(for machine: MachineRecord) -> String? {
        guard machine.isPreviewFixture else {
            return nil
        }

        switch machine.alias.lowercased() {
        case "example-mac":
            return "/workspace/coding-on-the-go"
        case "c":
            return "/workspace/infrastructure"
        default:
            return "/workspace/\(machine.alias.lowercased())"
        }
    }

    private static func machineRecordForManualRoute(
        _ route: RouteRecord,
        usernameHint: String?
    ) -> MachineRecord {
        let machineID = UUID()
        var route = route
        route.machineID = machineID

        let hostname = route.hostname ?? route.ipAddress ?? route.address
        let displayName = inferredMachineDisplayName(from: hostname)

        return MachineRecord(
            id: machineID,
            displayName: displayName,
            hostname: hostname,
            lastKnownUser: usernameHint?.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredRouteID: route.id,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: false,
                codexInstalled: false,
                supportsWebsocketListen: false
            )
        )
    }

    private static func manualMachineRouteLabel(for kind: MachineRouteKind) -> String {
        switch kind {
        case .localLAN:
            return "Same Wi-Fi"
        case .manualSSH:
            return "Direct SSH"
        case .externalTailnet:
            return "Tailscale"
        case .embeddedTailnet:
            return "Embedded Tailscale"
        case .companionDirect:
            return "Companion"
        }
    }

    private static let uiTestExternalTailnetProfileID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let uiTestEmbeddedTailnetProfileID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private static func trimmedUITestEnvironmentValue(_ key: String) -> String? {
        let trimmed = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func shouldDeferRuntimeServicesForUITestReset() -> Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
            && ProcessInfo.processInfo.environment["COTG_UI_TEST_RESET_ON_LAUNCH"] == "1"
    }

    private func applyUITestPendingScannedHostKeySeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_PENDING_SCANNED_HOST_KEY"] == "1",
              let route = selectedBootstrapRoute else {
            return
        }

        let scannedKey = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_PENDING_SCANNED_HOST_KEY")
            ?? "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUITestPendingTrustKey cotg-ui-test"
        pendingScannedHostKey = scannedKey
        pendingScannedHostKeyRouteID = route.id
        pendingScannedHostKeyFingerprint = Self.hostKeyFingerprint(scannedKey)
    }

    func reconcilePendingScannedHostKeyRouteBinding(previousMachines: [MachineRecord]) {
        guard pendingScannedHostKey != nil else {
            clearPendingScannedHostKeyState()
            return
        }
        guard let pendingRouteID = pendingScannedHostKeyRouteID else {
            clearPendingScannedHostKeyState()
            return
        }
        if machines.contains(where: { machine in
            machine.routes.contains(where: { $0.id == pendingRouteID })
        }) {
            return
        }

        guard let previousBinding = previousMachines.lazy.compactMap({ machine in
            machine.route(id: pendingRouteID).map { route in
                (machineID: machine.id, route: route)
            }
        }).first else {
            clearPendingScannedHostKeyState()
            return
        }

        guard let updatedMachine = machines.first(where: { $0.id == previousBinding.machineID }),
              let replacementRoute = replacementRoute(
                forPendingScannedHostKey: previousBinding.route,
                in: updatedMachine
              ) else {
            clearPendingScannedHostKeyState()
            return
        }

        pendingScannedHostKeyRouteID = replacementRoute.id
    }

    private func replacementRoute(
        forPendingScannedHostKey previousRoute: RouteRecord,
        in machine: MachineRecord
    ) -> RouteRecord? {
        let candidates = machine.routes.filter { $0.kind == previousRoute.kind }
        guard !candidates.isEmpty else {
            return nil
        }

        let previousHosts = routeMatchTokens(for: previousRoute)
        if let exactMatch = candidates.first(where: { candidate in
            candidate.tailnetProfileID == previousRoute.tailnetProfileID
                && !routeMatchTokens(for: candidate).isDisjoint(with: previousHosts)
        }) {
            return exactMatch
        }

        if let profileMatch = candidates.first(where: {
            $0.tailnetProfileID == previousRoute.tailnetProfileID
                && previousRoute.tailnetProfileID != nil
        }) {
            return profileMatch
        }

        if let hostMatch = candidates.first(where: {
            !routeMatchTokens(for: $0).isDisjoint(with: previousHosts)
        }) {
            return hostMatch
        }

        return candidates.count == 1 ? candidates.first : nil
    }

    private func routeMatchTokens(for route: RouteRecord) -> Set<String> {
        Set(
            [route.hostname, route.ipAddress, route.magicDNSName]
                .compactMap { value in
                    value?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )
    }

    private func clearPendingScannedHostKeyState() {
        pendingScannedHostKey = nil
        pendingScannedHostKeyRouteID = nil
        pendingScannedHostKeyFingerprint = nil
    }

    private func applyUITestConnectionFailureSeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_CONNECTION_FAILURE"] == "1" else {
            return
        }

        let detail = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_CONNECTION_FAILURE_DETAIL")
            ?? "The selected route failed before the Codex thread could resume."
        connectionState = .failed(detail)
    }

    private func applyUITestConnectingRestoreSeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_CONNECTING_RESTORE"] == "1" else {
            return
        }

        connectionState = .connecting
        isRestoringActiveTranscript = true
        transcript = []
    }

    private func applyUITestPlanMessageSeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_PLAN_MESSAGE"] == "1" else {
            return
        }

        let planText = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_PLAN_MESSAGE")
            ?? """
            1. Group recent activity into a compact cluster.
            2. Render plan summaries as dedicated plan cards.
            3. Revalidate the transcript flow on the physical iPhone.
            """

        if !transcript.contains(where: { $0.kind == .plan && $0.text == planText }) {
            transcript.append(
                SessionMessage(
                    role: .system,
                    kind: .plan,
                    text: planText
                )
            )
        }
        selectedCollaborationMode = .plan
    }

    private func applyUITestActivityBurstSeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_ACTIVITY_BURST"] == "1" else {
            return
        }

        let burstMessages = Self.activityBurstFixtureMessages()
        guard !burstMessages.isEmpty else {
            return
        }

        let alreadySeeded = burstMessages.allSatisfy { seededMessage in
            transcript.contains(where: { existingMessage in
                existingMessage.kind == seededMessage.kind && existingMessage.text == seededMessage.text
            })
        }
        guard !alreadySeeded else {
            return
        }

        transcript.append(contentsOf: burstMessages)
    }

    private func applyUITestAttachmentHistorySeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_ATTACHMENT_HISTORY"] == "1" else {
            return
        }

        let fixtureMessages = Self.attachmentHistoryFixtureMessages()
        guard !fixtureMessages.isEmpty else {
            return
        }

        let alreadySeeded = fixtureMessages.allSatisfy { fixtureMessage in
            transcript.contains(where: { existingMessage in
                existingMessage.role == fixtureMessage.role
                    && existingMessage.text == fixtureMessage.text
                    && existingMessage.attachments == fixtureMessage.attachments
            })
        }
        guard !alreadySeeded else {
            return
        }

        transcript.append(contentsOf: fixtureMessages)
    }

    private func applyUITestStructuredPromptSeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_STRUCTURED_PROMPT"] == "1" else {
            return
        }

        let questionText = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_STRUCTURED_PROMPT_QUESTION")
            ?? "Which implementation path should we take next?"
        let optionLabels = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_STRUCTURED_PROMPT_OPTIONS")?
            .components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? [
                "Structured plan questions",
                "History catch-up improvements",
                "Browser thread actions"
            ]
        let requestID = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_STRUCTURED_PROMPT_ID")
            ?? "ui-test-structured-prompt"

        let prompt = SessionStructuredPrompt(
            requestID: requestID,
            questions: [
                SessionStructuredQuestion(
                    id: "next-step",
                    prompt: questionText,
                    options: optionLabels.map { SessionStructuredOption(label: $0) }
                )
            ]
        )
        let summaryText = ([questionText] + optionLabels.map { "- \($0)" }).joined(separator: "\n")

        if !transcript.contains(where: {
            $0.kind == .userInputPrompt && $0.structuredPrompt?.requestID == requestID
        }) {
            transcript.append(
                SessionMessage(
                    role: .system,
                    kind: .userInputPrompt,
                    text: summaryText,
                    structuredPrompt: prompt
                )
            )
        }
        selectedCollaborationMode = .plan
    }

    private func applyUITestThreadlessSummarySeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_THREADLESS_SESSION_SUMMARY"] == "1",
              let sessionIndex = recentSessions.indices.first else {
            return
        }

        let summary = Self.trimmedUITestEnvironmentValue("COTG_UI_TEST_THREADLESS_SESSION_SUMMARY")
            ?? "I need one line of context on what you want repeated."

        recentSessions[sessionIndex].threadID = nil
        recentSessions[sessionIndex].lastTurn = RecentTurnMetadata(
            turnID: "turn-threadless-summary-seed",
            summary: summary,
            completedAt: .now
        )
        activeSessionID = recentSessions[sessionIndex].id
        activeExecutionProfileState = recentSessions[sessionIndex].executionProfileState
        selectedMachineID = recentSessions[sessionIndex].machineID
        connectionState = .connected("Seeded workspace-only session")
        activeProtocolKind = .stdio
        syncKnownThreadIDs(threadID: nil, replaceAll: true)
        applyLiveThreadSnapshot(nil)
    }

    private func applyUITestBrowserOperationsSeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_BROWSER_OPERATIONS"] == "1" else {
            return
        }

        guard let sessionIndex = recentSessions.indices.first else {
            return
        }

        let session = recentSessions[sessionIndex]
        guard let machine = machines.first(where: { $0.id == session.machineID }) else {
            return
        }

        let workspaceRoot = Self.normalizedWorkspaceRoot(
            session.workspaceRoot
                ?? hostThreadCatalog.first?.workspaceRoot
                ?? Self.previewWorkspaceRoot(for: machine)
        ) ?? "/workspace/coding-on-the-go"
        let fixtureThreads = Self.browserOperationsFixtureThreads(
            machineID: machine.id,
            workspaceRoot: workspaceRoot
        )

        recentSessions[sessionIndex].threadID = fixtureThreads[0].id
        recentSessions[sessionIndex].workspaceRoot = workspaceRoot
        recentSessions[sessionIndex].lastMode = .local
        recentSessions[sessionIndex].isArchived = false
        if recentSessions[sessionIndex].routeID == nil {
            recentSessions[sessionIndex].routeID = machine.preferredRouteID ?? machine.routes.first?.id
        }

        hostThreadCatalog = Self.deduplicatedHostThreadCatalog(fixtureThreads)
        selectedMachineID = machine.id
        activeSessionID = recentSessions[sessionIndex].id
        displayedTranscriptThreadID = fixtureThreads[0].id
        syncKnownThreadIDs(threadID: fixtureThreads[0].id, replaceAll: true)
        connectionState = .connected("SSH safe lane")
        activeProtocolKind = .stdio
    }

    private func applyUITestRecoverableSavedSSHKeySeedIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_RECOVERABLE_SSH_KEY"] == "1",
              let machine = selectedMachine,
              let username = sshUsername(for: machine, route: selectedBootstrapRoute) else {
            return
        }

        if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[machineIndex].credentialRef = nil
            machines[machineIndex].lastKnownUser = username
        }

        let legacyReference = legacySavedCredentialReference(
            kind: .sshKey,
            username: username,
            machineID: machine.id
        )
        let keyData = localhostTestKeyData() ?? Data(repeating: 7, count: 32)

        Task {
            try? await secretVault.store(
                SecretPayload(
                    reference: legacyReference,
                    value: keyData
                )
            )

            if ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_MULTIPLE_SAVED_SSH_KEYS"] == "1" {
                let secondaryReference = CredentialRef(
                    kind: .sshKey,
                    keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
                    label: "SSH private key",
                    username: "other-user",
                    storageScope: .localKeychain
                )
                try? await secretVault.store(
                    SecretPayload(
                        reference: secondaryReference,
                        value: Data(repeating: 9, count: 32)
                    )
                )
            }
        }
    }

    public func useStructuredPromptAnswers(
        _ prompt: SessionStructuredPrompt,
        selectedOptionsByQuestionID: [String: [String]],
        typedAnswersByQuestionID: [String: String]
    ) {
        let answersByQuestionID = Self.structuredAnswersByQuestionID(
            prompt,
            selectedOptionsByQuestionID: selectedOptionsByQuestionID,
            typedAnswersByQuestionID: typedAnswersByQuestionID
        )
        guard !answersByQuestionID.isEmpty else {
            return
        }

        if let pendingRequest = pendingStructuredUserInputRequest,
           pendingRequest.prompt.requestID == prompt.requestID {
            Task {
                do {
                    switch activeProtocolKind {
                    case .stdio:
                        try await safeLaneClient.resolveStructuredUserInput(
                            pendingRequest,
                            answersByQuestionID: answersByQuestionID
                        )
                    case .websocket, .directEndpoint:
                        try await loopbackClient.resolveStructuredUserInput(
                            pendingRequest,
                            answersByQuestionID: answersByQuestionID
                        )
                    }

                    await MainActor.run {
                        self.pendingStructuredUserInputRequest = nil
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Submitted the requested structured input."
                            )
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.transcript.append(
                            SessionMessage(
                                role: .system,
                                text: "Structured input submission failed: \(error.localizedDescription)"
                            )
                        )
                    }
                }
            }
            return
        }

        let response = prompt.questions.compactMap { question -> String? in
            let selectedOptions = answersByQuestionID[question.id] ?? []

            var answerParts: [String] = []
            if !selectedOptions.isEmpty {
                answerParts.append(selectedOptions.joined(separator: "\n"))
            }

            guard !answerParts.isEmpty else {
                return nil
            }

            return "\(question.prompt)\n\(answerParts.joined(separator: "\n"))"
        }.joined(separator: "\n\n")

        guard !response.isEmpty else {
            return
        }

        let separator = composerState.draft.isEmpty ? "" : "\n\n"
        composerState.draft += "\(separator)\(response)"
        selectDefaultCollaborationMode()
    }

    private static func structuredAnswersByQuestionID(
        _ prompt: SessionStructuredPrompt,
        selectedOptionsByQuestionID: [String: [String]],
        typedAnswersByQuestionID: [String: String]
    ) -> [String: [String]] {
        prompt.questions.reduce(into: [String: [String]]()) { partialResult, question in
            let selectedOptions = selectedOptionsByQuestionID[question.id] ?? []
            let typedAnswer = typedAnswersByQuestionID[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var answers = selectedOptions
            if let typedAnswer, !typedAnswer.isEmpty {
                answers.append(typedAnswer)
            }

            if !answers.isEmpty {
                partialResult[question.id] = answers
            }
        }
    }

    private static func structuredPromptSummaryText(_ prompt: SessionStructuredPrompt) -> String {
        prompt.questions.map { question in
            let options = question.options.map(\.label)
            let optionSummary = options.isEmpty ? nil : options.map { "- \($0)" }.joined(separator: "\n")
            return [question.prompt, optionSummary]
                .compactMap { value in
                    guard let value, !value.isEmpty else {
                        return nil
                    }
                    return value
                }
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func uiTestSSHHostKeyOverride() -> String? {
        trimmedUITestEnvironmentValue("COTG_TEST_SSH_HOST_KEY")
    }

    private static func uiTestSSHHostOverride() -> String? {
        if let resolvedHost = trimmedUITestEnvironmentValue("COTG_TEST_SSH_HOST_RESOLVED") {
            return resolvedHost
        }

        if let hostFilePath = trimmedUITestEnvironmentValue("COTG_TEST_SSH_HOST_FILE"),
           let fileValue = try? String(contentsOfFile: hostFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fileValue.isEmpty {
            return fileValue
        }

        return trimmedUITestEnvironmentValue("COTG_TEST_SSH_HOST")
    }

    private static func uiTestPreferredRouteKind() -> MachineRouteKind? {
        guard let rawValue = trimmedUITestEnvironmentValue("COTG_TEST_PREFERRED_ROUTE_KIND") else {
            return nil
        }

        return MachineRouteKind(rawValue: rawValue)
    }

    private static func uiTestDefaultSSHHost() -> String {
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
            || ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            return "localhost"
        }

        return "example-mac.local"
    }

    private static func localhostUITestManualRouteMachine() -> MachineRecord {
        let usernameHint = ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manualHost = uiTestSSHHostOverride() ?? uiTestDefaultSSHHost()
        let externalTailnetDNSName = trimmedUITestEnvironmentValue("COTG_TEST_EXTERNAL_TAILNET_DNS_NAME")
        let port = UInt16(ProcessInfo.processInfo.environment["COTG_TEST_SSH_PORT"] ?? "22") ?? 22
        let trustedHostKey = uiTestSSHHostKeyOverride()
        let trustState: RouteTrustState = trustedHostKey == nil ? .unknown : .trusted

        var machine = machineRecordForManualRoute(
            RouteRecord(
                kind: .manualSSH,
                label: "Local SSH",
                hostname: manualHost,
                sshPort: port,
                usernameHint: usernameHint?.isEmpty == false ? usernameHint : nil,
                health: .healthy,
                lastCheckedAt: .now,
                isRecommended: true,
                isUserPinned: true,
                discoverySource: .manual,
                trustState: trustState,
                trustedOpenSSHPublicKey: trustedHostKey
            ),
            usernameHint: usernameHint
        )
        machine.displayName = "Local SSH"
        machine.notes = AppMachineDirectoryCoordinator.localhostTestingFixtureNote

        guard let externalTailnetDNSName else {
            return machine
        }

        let externalRoute = RouteRecord(
            machineID: machine.id,
            kind: .externalTailnet,
            label: "Tailnet SSH",
            magicDNSName: externalTailnetDNSName,
            sshPort: port,
            usernameHint: usernameHint?.isEmpty == false ? usernameHint : nil,
            tailnetProfileID: uiTestExternalTailnetProfileID,
            requiresExternalApp: true,
            health: .healthy,
            lastCheckedAt: .now,
            isUserPinned: true,
            discoverySource: .tailnetProfile,
            trustState: trustState,
            trustedOpenSSHPublicKey: trustedHostKey
        )
        machine.routes.append(externalRoute)

        if uiTestPreferredRouteKind() == .externalTailnet {
            machine.preferredRouteID = externalRoute.id
            for index in machine.routes.indices {
                machine.routes[index].isUserPinned = machine.routes[index].id == externalRoute.id
            }
        }

        return machine
    }

    private static func localhostUITestLocalLANMachine() -> MachineRecord {
        let usernameHint = ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lanHost = uiTestSSHHostOverride() ?? uiTestDefaultSSHHost()
        let port = UInt16(ProcessInfo.processInfo.environment["COTG_TEST_SSH_PORT"] ?? "22") ?? 22
        let trustedHostKey = uiTestSSHHostKeyOverride()
        let trustState: RouteTrustState = trustedHostKey == nil ? .unknown : .trusted

        var machine = machineRecordForManualRoute(
            RouteRecord(
                kind: .localLAN,
                label: "Same LAN",
                hostname: lanHost,
                sshPort: port,
                usernameHint: usernameHint?.isEmpty == false ? usernameHint : nil,
                health: .healthy,
                lastCheckedAt: .now,
                isRecommended: true,
                isUserPinned: true,
                discoverySource: .bonjour,
                trustState: trustState,
                trustedOpenSSHPublicKey: trustedHostKey
            ),
            usernameHint: usernameHint
        )
        machine.displayName = "Same LAN"
        return machine
    }

    private static func localhostUITestTailnetProfiles() -> [TailnetProfile] {
        guard let externalTailnetDNSName = trimmedUITestEnvironmentValue("COTG_TEST_EXTERNAL_TAILNET_DNS_NAME") else {
            return []
        }

        let accountLabel = trimmedUITestEnvironmentValue("COTG_TEST_TAILNET_ACCOUNT_LABEL")
            ?? "tailnet-user@example.com"

        return [
            TailnetProfile(
                id: uiTestExternalTailnetProfileID,
                kind: .external,
                displayName: "External Tailnet",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: accountLabel,
                tailnetDNSName: externalTailnetDNSName,
                isActive: true,
                lastActivatedAt: .now,
                lastAuthenticatedAt: .now,
                supportsCustomControlServer: true,
                requiresExternalApp: true
            )
        ]
    }

    private static func embeddedTailnetUITestMachine() -> MachineRecord {
        let hostname = trimmedUITestEnvironmentValue("COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST")
            ?? "example-mac.example.ts.net"
        let usernameHint = ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trustedHostKey = uiTestSSHHostKeyOverride()
        let trustState: RouteTrustState = trustedHostKey == nil ? .unknown : .trusted
        let route = RouteRecord(
            kind: .embeddedTailnet,
            label: "Embedded Tailscale",
            hostname: hostname,
            magicDNSName: hostname,
            usernameHint: usernameHint?.isEmpty == false ? usernameHint : nil,
            tailnetProfileID: uiTestEmbeddedTailnetProfileID,
            health: .unavailable,
            lastCheckedAt: .now,
            isRecommended: false,
            isUserPinned: true,
            discoverySource: .tailnetProfile,
            trustState: trustState,
            trustedOpenSSHPublicKey: trustedHostKey
        )

        return machineRecordForManualRoute(
            route,
            usernameHint: usernameHint
        )
    }

    private static func embeddedTailnetUITestProfiles() -> [TailnetProfile] {
        let targetHost = trimmedUITestEnvironmentValue("COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST")
            ?? "example-mac.example.ts.net"
        let accountLabel = trimmedUITestEnvironmentValue("COTG_TEST_TAILNET_ACCOUNT_LABEL")
            ?? "tailnet-user@example.com"
        let hasAuthKey = trimmedUITestEnvironmentValue("COTG_EMBEDDED_TAILNET_AUTH_KEY") != nil

        return [
            TailnetProfile(
                id: uiTestEmbeddedTailnetProfileID,
                kind: .embedded,
                displayName: "Embedded Tailnet",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: accountLabel,
                tailnetDNSName: targetHost,
                isActive: true,
                lastActivatedAt: .now,
                lastAuthenticatedAt: hasAuthKey ? .now : nil,
                supportsCustomControlServer: true,
                requiresExternalApp: false
            )
        ]
    }

    private static func inferredMachineDisplayName(from hostname: String) -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "My Mac"
        }

        let primaryComponent = trimmed
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let primaryComponent, !primaryComponent.isEmpty {
            return primaryComponent
        }

        return "My Mac"
    }

    private func sanitizedPersistedSnapshot(_ snapshot: MachineDirectorySnapshot) -> MachineDirectorySnapshot {
        Self.sanitizedPersistedSnapshot(
            snapshot,
            allowPreviewFixtures: preservesPreviewFixtures
        )
    }

    private func shouldPreservePreviewFixtures(in snapshot: MachineDirectorySnapshot) -> Bool {
        preservesPreviewFixtures
            || snapshot.machines.contains(where: \.isPreviewFixture)
            || snapshot.tailnetProfiles.contains(where: \.isPreviewFixture)
    }

    private static func sanitizedPersistedSnapshot(
        _ snapshot: MachineDirectorySnapshot,
        allowPreviewFixtures: Bool = false
    ) -> MachineDirectorySnapshot {
        let allowUITestFixtures = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let tailnetProfiles = snapshot.tailnetProfiles.filter { profile in
            if allowPreviewFixtures {
                return true
            }

            if !embeddedTailnetFeatureAvailable, profile.kind == .embedded {
                return false
            }

            return !profile.isPreviewFixture
        }

        let machines = snapshot.machines
            .filter { machine in
                if !allowPreviewFixtures && machine.isPreviewFixture {
                    return false
                }

                if !allowUITestFixtures && isLocalhostTestingFixture(machine) {
                    return false
                }

                return true
            }
            .map { sanitizedPersistedMachine($0, allowPreviewFixtures: allowPreviewFixtures) }
        let cleanedMachines = deduplicatedTailnetProfileRoutes(
            in: machines,
            tailnetProfiles: tailnetProfiles
        )
        let persistedMachines = cleanedMachines.filter { !$0.routes.isEmpty }
        let validMachineIDs = Set(persistedMachines.map(\.id))
        let validTailnetProfileIDs = Set(tailnetProfiles.map(\.id))
        let recentSessions = snapshot.recentSessions.filter { validMachineIDs.contains($0.machineID) }
        let hostThreadCatalog = cachedHostThreadCatalog(
            snapshot.hostThreadCatalog.filter { validMachineIDs.contains($0.machineID) }
        )
        let preferredMachineID = snapshot.preferences.preferredMachineID.flatMap { validMachineIDs.contains($0) ? $0 : nil }
        let preferredTailnetProfileID = snapshot.preferences.preferredTailnetProfileID.flatMap {
            validTailnetProfileIDs.contains($0) ? $0 : nil
        }

        return MachineDirectorySnapshot(
            machines: persistedMachines,
            tailnetProfiles: tailnetProfiles,
            recentSessions: recentSessions,
            hostThreadCatalog: hostThreadCatalog,
            preferences: UserPreferencesSnapshot(
                preferredMachineID: preferredMachineID,
                preferredTailnetProfileID: preferredTailnetProfileID,
                restoreLastSessionOnLaunch: snapshot.preferences.restoreLastSessionOnLaunch,
                preferredBootstrap: snapshot.preferences.preferredBootstrap,
                preferredProtocol: snapshot.preferences.preferredProtocol,
                preferredReasoningEffort: snapshot.preferences.preferredReasoningEffort,
                preferredApprovalPolicy: snapshot.preferences.preferredApprovalPolicy,
                preferredSandboxMode: snapshot.preferences.preferredSandboxMode,
                privacyMode: snapshot.preferences.privacyMode
            )
        )
    }

    private static func deduplicatedTailnetProfileRoutes(
        in machines: [MachineRecord],
        tailnetProfiles: [TailnetProfile]
    ) -> [MachineRecord] {
        tailnetProfiles.reduce(machines) { partialMachines, profile in
            deduplicatedTailnetProfileRoutes(in: partialMachines, profile: profile)
        }
    }

    private static func deduplicatedTailnetProfileRoutes(
        in machines: [MachineRecord],
        profile: TailnetProfile
    ) -> [MachineRecord] {
        let targetMachineIDs = targetMachineIDs(for: profile, machines: machines)
        let routeKind: MachineRouteKind = profile.kind == .embedded ? .embeddedTailnet : .externalTailnet

        return machines.map { machine in
            guard !targetMachineIDs.contains(machine.id) else {
                return machine
            }

            let removedRouteIDs = Set(
                machine.routes
                    .filter {
                        $0.kind == routeKind
                            && $0.tailnetProfileID == profile.id
                            && $0.discoverySource == .tailnetProfile
                    }
                    .map(\.id)
            )
            guard !removedRouteIDs.isEmpty else {
                return machine
            }

            var updated = machine
            updated.routes.removeAll { removedRouteIDs.contains($0.id) }
            if let preferredRouteID = updated.preferredRouteID,
               removedRouteIDs.contains(preferredRouteID) {
                updated.preferredRouteID = updated.preferredRoute?.id
            }
            if let lastSuccessfulRouteID = updated.lastSuccessfulRouteID,
               removedRouteIDs.contains(lastSuccessfulRouteID) {
                updated.lastSuccessfulRouteID = nil
            }
            return updated
        }
    }

    private static func targetMachineIDs(
        for profile: TailnetProfile,
        machines: [MachineRecord]
    ) -> Set<MachineRecord.ID> {
        let exactHosts = Set([profile.tailnetDNSName].compactMap(normalizedTailnetHost))
        let exactHostnameMatches = machines.filter { machine in
            if let normalizedHostname = normalizedTailnetHost(machine.hostname) {
                return exactHosts.contains(normalizedHostname)
            }
            return false
        }
        if !exactHostnameMatches.isEmpty {
            return Set(exactHostnameMatches.map(\.id))
        }

        let exactRouteMatches = machines.filter { machine in
            machine.routes.contains { route in
                [route.hostname, route.ipAddress, route.magicDNSName]
                    .compactMap(normalizedTailnetHost)
                    .contains { exactHosts.contains($0) }
            }
        }
        if !exactRouteMatches.isEmpty {
            return Set(exactRouteMatches.map(\.id))
        }

        let hostLabels = Set(exactHosts.map(hostLabel(for:)))
        let labelMatches = machines.filter { machine in
            hostLabels.contains(hostLabel(for: machine.hostname))
        }
        if labelMatches.count == 1 {
            return Set(labelMatches.map(\.id))
        }

        if machines.count == 1, let onlyMachine = machines.first {
            return [onlyMachine.id]
        }

        return []
    }

    private static func normalizedTailnetHost(_ host: String?) -> String? {
        guard let host = host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func hostLabel(for host: String) -> String {
        host.split(separator: ".").first.map(String.init) ?? host
    }

    private static func deduplicatedHostThreadCatalog(
        _ entries: [HostThreadCatalogEntry]
    ) -> [HostThreadCatalogEntry] {
        var merged: [String: HostThreadCatalogEntry] = [:]

        for entry in entries {
            let key = "\(entry.machineID.uuidString)::\(entry.id)"
            if let existing = merged[key] {
                merged[key] = existing.merged(with: entry)
            } else {
                merged[key] = entry
            }
        }

        return merged.values.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    private static func cachedHostThreadCatalog(
        _ entries: [HostThreadCatalogEntry]
    ) -> [HostThreadCatalogEntry] {
        deduplicatedHostThreadCatalog(entries.map { $0.asCachedCatalog() })
    }

    private static func runtimeHostThreadCatalog(
        currentEntries: [HostThreadCatalogEntry],
        persistedEntries: [HostThreadCatalogEntry],
        validMachineIDs: Set<MachineRecord.ID>
    ) -> [HostThreadCatalogEntry] {
        let filteredCurrentEntries = currentEntries.filter { validMachineIDs.contains($0.machineID) }
        let cachedPersistedEntries = persistedEntries
            .filter { validMachineIDs.contains($0.machineID) }
            .map { $0.asCachedCatalog() }

        var mergedEntries: [String: HostThreadCatalogEntry] = Dictionary(
            uniqueKeysWithValues: filteredCurrentEntries.map { (hostThreadCatalogKey(for: $0), $0) }
        )

        for entry in cachedPersistedEntries {
            let key = hostThreadCatalogKey(for: entry)
            guard let currentEntry = mergedEntries[key] else {
                mergedEntries[key] = entry
                continue
            }

            var mergedEntry = currentEntry.merged(with: entry)
            if currentEntry.provenance != .cachedHostCatalog {
                mergedEntry.provenance = currentEntry.provenance
            }
            mergedEntries[key] = mergedEntry
        }

        return mergedEntries.values.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    private static func hostThreadCatalogKey(for entry: HostThreadCatalogEntry) -> String {
        "\(entry.machineID.uuidString)::\(entry.id)"
    }

    private static func sanitizedPersistedMachine(
        _ machine: MachineRecord,
        allowPreviewFixtures: Bool = false
    ) -> MachineRecord {
        guard embeddedTailnetFeatureAvailable == false, allowPreviewFixtures == false else {
            return machine
        }

        let removedRouteIDs = Set(
            machine.routes
                .filter { $0.kind == .embeddedTailnet }
                .map(\.id)
        )
        guard !removedRouteIDs.isEmpty else {
            return machine
        }

        var machine = machine
        machine.routes.removeAll { removedRouteIDs.contains($0.id) }
        if let preferredRouteID = machine.preferredRouteID,
           removedRouteIDs.contains(preferredRouteID) {
            machine.preferredRouteID = nil
        }
        if let lastSuccessfulRouteID = machine.lastSuccessfulRouteID,
           removedRouteIDs.contains(lastSuccessfulRouteID) {
            machine.lastSuccessfulRouteID = nil
        }
        return machine
    }

    private static func normalizedWorkspaceRoot(_ workspaceRoot: String?) -> String? {
        guard let workspaceRoot = workspaceRoot?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceRoot.isEmpty,
              workspaceRoot != "/" else {
            return nil
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let standardizedPath = workspaceURL.standardizedFileURL.path
        let resolvedPath = URL(fileURLWithPath: standardizedPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .path

        if resolvedPath.isEmpty || resolvedPath == "/" {
            return standardizedPath == "/" ? nil : standardizedPath
        }

        return resolvedPath
    }

    private static func workspaceMode(for workspaceRoot: String?) -> WorkspaceMode {
        guard let workspaceRoot = normalizedWorkspaceRoot(workspaceRoot) else {
            return .local
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let parentDirectory = workspaceURL.deletingLastPathComponent().lastPathComponent
        return parentDirectory.hasSuffix("-worktrees") ? .worktree : .local
    }

    private static func normalizedPaginationCursor(_ cursor: String?) -> String? {
        guard let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cursor.isEmpty else {
            return nil
        }

        return cursor
    }

    private struct LoopbackUpgradeSession {
        let url: URL
        let models: [CodexModelDescriptor]
        let resumedThread: ResolvedThreadBindingContext?
        let thread: CodexThreadContext
    }

    private struct WorkspaceRoutingContext {
        let machine: MachineRecord
        let session: SessionRecord
        let workspaceRoot: String
        let threadID: String
    }

    private var currentReasoningLevel: ReasoningEffortLevel {
        Self.reasoningLevel(for: selectedReasoningEffort)
    }

    private static func reasoningLevel(for effort: CodexReasoningEffort) -> ReasoningEffortLevel {
        switch effort {
        case .none, .minimal, .low:
            return .low
        case .medium:
            return .medium
        case .high, .xhigh:
            return .high
        }
    }

    private func defaultWorktreeParent() -> URL {
        let workspaceRoot = resolvedWorkspaceRoot() ?? connectionBootstrapWorkspaceRoot()
        return defaultWorktreeParent(for: workspaceRoot)
    }

    private func defaultWorktreeParent(for workspaceRoot: String) -> URL {
        if let override = ProcessInfo.processInfo.environment["COTG_WORKTREE_ROOT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let repoName = workspaceURL.lastPathComponent
        if workspaceURL.path.contains("/CodingOnTheGo-worktrees/"),
           let parent = workspaceURL.deletingLastPathComponent().path.split(separator: "/").last,
           parent == "CodingOnTheGo-worktrees" {
            return workspaceURL.deletingLastPathComponent()
        }

        return workspaceURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoName)-worktrees", isDirectory: true)
    }

    private func currentWorkspaceRoutingContext(
        requireThread: Bool,
        requireSSHSafeLane: Bool
    ) throws -> WorkspaceRoutingContext {
        guard case .connected = connectionState else {
            throw CodexSSHError.invalidRequest("Connect to the selected Mac before changing Local / Worktree routing.")
        }
        guard let machine = selectedMachine else {
            throw CodexSSHError.invalidRequest("Select a Mac before changing Local / Worktree routing.")
        }
        guard let session = activeSession else {
            throw CodexSSHError.invalidRequest("Open a Project and Thread before changing Local / Worktree routing.")
        }
        if requireSSHSafeLane, activeProtocolKind == .directEndpoint {
            throw CodexSSHError.invalidRequest("Worktree flows require the SSH safe lane.")
        }

        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(session.workspaceRoot)
            ?? Self.normalizedWorkspaceRoot(resolvedWorkspaceRoot())
        guard let workspaceRoot = normalizedWorkspaceRoot else {
            throw CodexSSHError.invalidRequest("Resume or start a thread in a real project workspace first.")
        }

        guard let resolvedThreadID = requireThread
            ? resolvedActiveSessionRoutingThreadID(for: session) ?? resolveThreadID(preferredThreadID: nil)
            : "" else {
            throw CodexSSHError.invalidRequest("Open a live thread before moving or forking it.")
        }

        return WorkspaceRoutingContext(
            machine: machine,
            session: session,
            workspaceRoot: workspaceRoot,
            threadID: resolvedThreadID
        )
    }

    private func resolvedActiveSessionRoutingThreadID(for session: SessionRecord) -> String? {
        if let sessionThreadID = session.threadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionThreadID.isEmpty {
            return sessionThreadID
        }

        return nil
    }

    private func prepareSSHSafeLaneForThreadRouting() async throws {
        switch activeProtocolKind {
        case .stdio:
            return
        case .websocket:
            await MainActor.run {
                fallbackToSafeLane(
                    summary: "Returned to the SSH safe lane for Local / Worktree routing."
                )
            }
        case .directEndpoint:
            throw CodexSSHError.invalidRequest("Worktree flows require the SSH safe lane.")
        }
    }

    private func restoreSafeLaneThreadRoutingAnchorIfNeeded() async throws {
        guard activeProtocolKind == .stdio,
              let session = activeSession,
              let workspaceRoot = Self.normalizedWorkspaceRoot(session.workspaceRoot)
                ?? Self.normalizedWorkspaceRoot(resolvedWorkspaceRoot()) else {
            return
        }

        let threads = try await Self.paginateThreadList { cursor in
            try await preferredHostThreadCatalogPage(limit: 40, cursor: cursor).page
        }
        let matchingThreads = threads.filter { thread in
            let normalizedThreadWorkspaceRoot = Self.normalizedWorkspaceRoot(thread.cwd)
                ?? thread.cwd
            return normalizedThreadWorkspaceRoot == workspaceRoot
        }
        guard !matchingThreads.isEmpty else {
            return
        }
        if let stdioThreadID,
           matchingThreads.contains(where: { $0.id == stdioThreadID }) {
            return
        }
        guard let recoveredThread = matchingThreads.first else {
            return
        }

        await MainActor.run {
            self.upsertSession(
                threadID: recoveredThread.id,
                routeID: session.routeID,
                workspaceRoot: recoveredThread.cwd,
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: session.lastKnownRouteKind,
                lastKnownBootstrap: session.lastKnownBootstrap,
                lastModel: recoveredThread.modelProvider,
                parentThreadID: session.parentThreadID,
                parentLastTurnID: session.parentLastTurnID
            )
        }
    }

    private func ensureWorkspaceCleanForThreadRouting() async throws {
        if let failureSummary = workspaceFailureSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !failureSummary.isEmpty {
            throw CodexSSHError.invalidRequest(failureSummary)
        }

        if let summary = workspaceSummary {
            guard workspaceSummaryHasNoPendingChanges(summary) else {
                throw CodexSSHError.invalidRequest("Clean the workspace first or start a new worktree thread instead.")
            }
            return
        }

        try await refreshWorkspaceStatus()

        if let failureSummary = workspaceFailureSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !failureSummary.isEmpty {
            throw CodexSSHError.invalidRequest(failureSummary)
        }
        guard let summary = workspaceSummary else {
            throw CodexSSHError.invalidRequest("Refresh workspace status before moving this thread between Local and Worktree.")
        }
        guard workspaceSummaryHasNoPendingChanges(summary) else {
            throw CodexSSHError.invalidRequest("Clean the workspace first or start a new worktree thread instead.")
        }
    }

    private func workspaceSummaryHasNoPendingChanges(_ summary: GitWorkspaceSummary) -> Bool {
        summary.stagedCount == 0
            && summary.modifiedCount == 0
            && summary.untrackedCount == 0
    }

    private func createWorktreeForThreadRouting(
        sourceWorkspaceRoot: String,
        named name: String?,
        branch: String?
    ) async throws -> String {
        let resolvedName = sanitizedWorktreeName(name)
        let finalName = resolvedName.isEmpty ? autogeneratedWorktreeName(for: sourceWorkspaceRoot) : resolvedName
        let resolvedBranch = sanitizedBranchName(branch)
        let finalBranch = resolvedBranch.isEmpty ? finalName : resolvedBranch
        let worktreePath = defaultWorktreeParent(for: sourceWorkspaceRoot)
            .appendingPathComponent(finalName, isDirectory: true)
            .path

        let result = try await safeLaneClient.execute(
            command: GitWorkspaceCommandBuilder.createWorktreeCommand(
                cwd: sourceWorkspaceRoot,
                path: worktreePath,
                branch: finalBranch
            )
        )
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(result.errorOutput.isEmpty ? result.standardOutput : result.errorOutput)
        }

        try? await refreshWorktreeList()
        return worktreePath
    }

    private func resolveLocalCheckoutPath(for workspaceRoot: String) async throws -> String {
        if Self.workspaceMode(for: workspaceRoot) == .local {
            return workspaceRoot
        }

        if worktrees.isEmpty {
            try? await refreshWorktreeList()
        }
        if let localCheckout = worktrees.first(where: {
            Self.workspaceMode(for: $0.path) == .local
        })?.path {
            return localCheckout
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let parentURL = workspaceURL.deletingLastPathComponent()
        let parentName = parentURL.lastPathComponent
        if parentName.hasSuffix("-worktrees") {
            let repoName = String(parentName.dropLast("-worktrees".count))
            return parentURL
                .deletingLastPathComponent()
                .appendingPathComponent(repoName, isDirectory: true)
                .path
        }

        throw CodexSSHError.invalidRequest("Could not resolve the Local checkout for this worktree.")
    }

    private func sanitizedWorktreeName(_ rawValue: String?) -> String {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let filtered = normalized.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(filtered)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(48))
    }

    private func sanitizedBranchName(_ rawValue: String?) -> String {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let filtered = normalized.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                return character
            }
            return "-"
        }
        let collapsed = String(filtered)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(64))
    }

    private func autogeneratedWorktreeName(for workspaceRoot: String) -> String {
        let repoName = sanitizedWorktreeName(URL(fileURLWithPath: workspaceRoot, isDirectory: true).lastPathComponent)
        let prefix = repoName.isEmpty ? "codex" : repoName
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(6)
        return "\(prefix)-\(suffix)"
    }

    private func resumeThreadOnActiveConnection(
        threadID: String,
        options: CodexThreadExecutionOptions,
        allowSnapshotFallback: Bool = true
    ) async throws -> ResolvedThreadBindingContext {
        try await resumeThreadWithSnapshotFallback(
            threadID: threadID,
            options: options,
            protocolKind: activeProtocolKind,
            allowSnapshotFallback: allowSnapshotFallback
        )
    }

    private func startThreadOnActiveConnection(
        options: CodexThreadExecutionOptions
    ) async throws -> CodexThreadContext {
        switch activeProtocolKind {
        case .stdio:
            return try await safeLaneClient.startThread(options: options)
        case .websocket, .directEndpoint:
            return try await loopbackClient.startThread(options: options)
        }
    }

    @MainActor
    private func appendThreadWorkspaceSession(
        threadID: String,
        workspaceRoot: String,
        parentThreadID: String? = nil,
        parentLastTurnID: String? = nil
    ) -> SessionRecord {
        let machine = selectedMachine ?? machines.first
        let machineID = machine?.id ?? activeSession?.machineID ?? recentSessions.first?.machineID ?? UUID()
        let routeKind = activeSession.flatMap { session in
            machine?.route(id: session.routeID)?.kind ?? session.lastKnownRouteKind
        }
            ?? selectedBootstrapRoute?.kind
            ?? machine?.preferredRoute?.kind
        let bootstrap = activeSession?.lastKnownBootstrap
            ?? (activeProtocolKind == .directEndpoint ? .companionManaged : .standardSSH)
        let session = SessionRecord(
            sceneID: sceneID,
            machineID: machineID,
            routeID: activeSession?.routeID ?? selectedBootstrapRoute?.id ?? machine?.preferredRoute?.id,
            threadID: threadID,
            workspaceRoot: Self.normalizedWorkspaceRoot(workspaceRoot),
            lastKnownProtocol: activeProtocolKind,
            lastKnownRouteKind: routeKind,
            lastKnownBootstrap: bootstrap,
            lastModel: Self.normalizedModelIdentifier(activeSession?.lastModel) ?? Self.normalizedModelIdentifier(selectedModel),
            lastReasoningEffort: currentReasoningLevel,
            lastMode: Self.workspaceMode(for: workspaceRoot),
            lastOpenedAt: .now,
            transportState: .connected,
            parentThreadID: parentThreadID,
            parentLastTurnID: parentLastTurnID,
            executionProfileState: activeSession?.executionProfileState
        )
        recentSessions.append(session)
        recentSessions.sort(by: { $0.lastOpenedAt > $1.lastOpenedAt })
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
        return session
    }

    private func activateThreadWorkspaceSession(
        _ session: SessionRecord
    ) async throws {
        let requestedOptions = requestedThreadExecutionOptions(
            session: session,
            cwd: session.workspaceRoot,
            model: nil,
            baselineConfig: session.executionProfileState?.baselineConfig
        )
        let resumedThread = try await resumeThreadOnActiveConnection(
            threadID: session.threadID ?? "",
            options: requestedOptions
        )
        try await applyThreadWorkspaceRebind(
            resumedThread,
            session: session,
            requestedThreadOptions: requestedOptions
        )
    }

    private func applyThreadWorkspaceRebind(
        _ resumedThread: ResolvedThreadBindingContext,
        session: SessionRecord,
        requestedThreadOptions: CodexThreadExecutionOptions
    ) async throws {
        let previousExecutionProfileState = session.executionProfileState ?? activeSession?.executionProfileState
        let executionProfileState = updatedExecutionProfileState(
            from: previousExecutionProfileState,
            snapshot: SessionExecutionSnapshot(
                runtime: resumedThread.executionProfile?.runtime ?? previousExecutionProfileState?.profile.runtime,
                baselineConfig: previousExecutionProfileState?.baselineConfig,
                constraints: previousExecutionProfileState?.constraints,
                support: previousExecutionProfileState?.support ?? .init(serverRequestRouting: .supported)
            ),
            effectiveProfile: resumedThread.executionProfile ?? previousExecutionProfileState?.profile,
            requestedThreadOptions: requestedThreadOptions,
            overridesKind: .supported,
            detectResumeMismatch: true
        )
        await MainActor.run {
            self.bindThreadWorkspaceSession(
                session,
                threadID: resumedThread.thread.id,
                workspaceRoot: resumedThread.cwd,
                protocolKind: self.activeProtocolKind,
                routeID: session.routeID,
                lastKnownRouteKind: session.lastKnownRouteKind,
                lastKnownBootstrap: session.lastKnownBootstrap,
                lastModel: resumedThread.model,
                reasoningEffort: resumedThread.reasoningEffort,
                parentThreadID: session.parentThreadID,
                parentLastTurnID: session.parentLastTurnID,
                bindProtocolThreadID: resumedThread.isLiveBinding
            )
            self.applyLiveThreadSnapshot(resumedThread.thread)
            self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
            self.persistActiveExecutionProfileState(executionProfileState)
            self.appendExecutionProfileChangeNoticeIfNeeded(
                previous: previousExecutionProfileState,
                current: executionProfileState
            )
        }
        try? await refreshWorkspaceStatus()
        await refreshRepoBrowserSessions()
    }

    private func activateThreadWorkspaceSession(
        _ session: SessionRecord,
        thread: CodexThreadContext
    ) async throws {
        let previousExecutionProfileState = session.executionProfileState ?? activeSession?.executionProfileState
        let requestedThreadOptions = requestedThreadExecutionOptions(
            session: session,
            cwd: thread.cwd,
            model: Self.normalizedModelIdentifier(thread.model)
                ?? Self.normalizedModelIdentifier(session.lastModel)
                ?? Self.normalizedModelIdentifier(selectedModel),
            baselineConfig: previousExecutionProfileState?.baselineConfig
        )
        let executionProfileState = updatedExecutionProfileState(
            from: previousExecutionProfileState,
            snapshot: SessionExecutionSnapshot(
                runtime: thread.executionProfile?.runtime ?? previousExecutionProfileState?.profile.runtime,
                baselineConfig: previousExecutionProfileState?.baselineConfig,
                constraints: previousExecutionProfileState?.constraints,
                support: previousExecutionProfileState?.support ?? .init(serverRequestRouting: .supported)
            ),
            effectiveProfile: thread.executionProfile ?? previousExecutionProfileState?.profile,
            requestedThreadOptions: requestedThreadOptions,
            overridesKind: .supported
        )
        await MainActor.run {
            self.bindThreadWorkspaceSession(
                session,
                threadID: thread.id,
                workspaceRoot: thread.cwd,
                protocolKind: self.activeProtocolKind,
                routeID: session.routeID,
                lastKnownRouteKind: session.lastKnownRouteKind,
                lastKnownBootstrap: session.lastKnownBootstrap,
                lastModel: thread.model,
                reasoningEffort: thread.reasoningEffort,
                parentThreadID: session.parentThreadID,
                parentLastTurnID: session.parentLastTurnID
            )
            self.applyLiveThreadSnapshot(nil)
            self.displayedTranscriptThreadID = thread.id
            self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
            self.persistActiveExecutionProfileState(executionProfileState)
            self.appendExecutionProfileChangeNoticeIfNeeded(
                previous: previousExecutionProfileState,
                current: executionProfileState
            )
        }
        try? await refreshWorkspaceStatus()
        await refreshRepoBrowserSessions()
    }

    @MainActor
    private func bindThreadWorkspaceSession(
        _ session: SessionRecord,
        threadID: String,
        workspaceRoot: String,
        protocolKind: CodexProtocolKind,
        routeID: RouteRecord.ID?,
        lastKnownRouteKind: MachineRouteKind?,
        lastKnownBootstrap: BootstrapStrategy,
        lastModel: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil,
        parentThreadID: String?,
        parentLastTurnID: String?,
        bindProtocolThreadID: Bool = true
    ) {
        let machine = machines.first(where: { $0.id == session.machineID }) ?? selectedMachine ?? machines.first
        let index: Int
        if let existingIndex = recentSessions.firstIndex(where: { $0.id == session.id }) {
            index = existingIndex
        } else {
            recentSessions.append(session)
            index = recentSessions.endIndex - 1
        }

        let existingParentThreadID = recentSessions[index].parentThreadID
        let existingParentLastTurnID = recentSessions[index].parentLastTurnID
        recentSessions[index] = session
        recentSessions[index].sceneID = sceneID
        recentSessions[index].routeID = routeID ?? recentSessions[index].routeID ?? machine?.preferredRoute?.id
        recentSessions[index].threadID = threadID
        recentSessions[index].workspaceRoot = Self.normalizedWorkspaceRoot(workspaceRoot)
        recentSessions[index].lastKnownProtocol = protocolKind
        recentSessions[index].lastKnownRouteKind = lastKnownRouteKind
        recentSessions[index].lastKnownBootstrap = lastKnownBootstrap
        recentSessions[index].lastMode = Self.workspaceMode(for: workspaceRoot)
        if let normalizedModel = Self.normalizedModelIdentifier(lastModel) {
            recentSessions[index].lastModel = normalizedModel
            if availableModels.contains(where: { $0.model == normalizedModel }) {
                selectedModel = normalizedModel
            }
        }
        if let reasoningEffort {
            let descriptor = Self.normalizedModelIdentifier(recentSessions[index].lastModel)
                .flatMap { model in availableModels.first(where: { $0.model == model }) }
                ?? selectedModelDescriptor
            selectedReasoningEffort = supportedReasoningEffort(reasoningEffort, for: descriptor)
            recentSessions[index].lastReasoningEffort = Self.reasoningLevel(for: selectedReasoningEffort)
        }
        recentSessions[index].lastOpenedAt = .now
        recentSessions[index].isArchived = false
        recentSessions[index].transportState = .connected
        recentSessions[index].parentThreadID = parentThreadID ?? session.parentThreadID ?? existingParentThreadID
        recentSessions[index].parentLastTurnID = parentLastTurnID ?? session.parentLastTurnID ?? existingParentLastTurnID
        recentSessions.sort(by: { $0.lastOpenedAt > $1.lastOpenedAt })
        let boundSessionIndex = recentSessions.firstIndex(where: { $0.id == session.id }) ?? index
        selectedMachineID = recentSessions[boundSessionIndex].machineID
        activeSessionID = recentSessions[boundSessionIndex].id
        activeExecutionProfileState = recentSessions[boundSessionIndex].executionProfileState
        if pendingTurnRequests.isEmpty {
            pendingPrompts = recentSessions[boundSessionIndex].queuedPrompts
        } else {
            pendingPrompts = pendingTurnRequests.map(\.summary)
            recentSessions[boundSessionIndex].queuedPrompts = pendingPrompts
        }
        activeProtocolKind = protocolKind
        syncKnownThreadIDs(
            threadID: bindProtocolThreadID ? threadID : nil,
            protocolKind: protocolKind
        )
        refreshComposerCapabilities()
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    private func forkCurrentThreadNow(
        sourceThreadID: String,
        targetWorkspaceRoot: String,
        parentThreadID: String,
        parentLastTurnID: String?
    ) async throws -> ThreadWorkspaceRoutingResult {
        let fallbackThreadID = threadRoutingFallbackSourceThreadID(
            for: activeSession,
            failingThreadID: sourceThreadID
        )
        let forkedThread = try await forkThreadForRouting(
            sourceThreadID: sourceThreadID,
            fallbackThreadID: fallbackThreadID,
            targetWorkspaceRoot: targetWorkspaceRoot
        )
        let resolvedForkedThread = try await resolvedRoutingThreadContext(
            threadContext: forkedThread,
            preferredWorkspaceRoot: targetWorkspaceRoot,
            fallbackModel: Self.normalizedModelIdentifier(forkedThread.model)
                ?? Self.normalizedModelIdentifier(selectedModel)
        )

        let session = await MainActor.run {
            self.appendThreadWorkspaceSession(
                threadID: resolvedForkedThread.id,
                workspaceRoot: resolvedForkedThread.cwd,
                parentThreadID: parentThreadID,
                parentLastTurnID: parentLastTurnID
            )
        }
        try await activateThreadWorkspaceSession(session, thread: resolvedForkedThread)
        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(resolvedForkedThread.cwd) ?? resolvedForkedThread.cwd
        return ThreadWorkspaceRoutingResult(
            sessionID: session.id,
            threadID: resolvedForkedThread.id,
            workspaceRoot: normalizedWorkspaceRoot
        )
    }

    private func handoffCurrentThreadNow(
        sourceThreadID: String,
        session: SessionRecord,
        targetWorkspaceRoot: String
    ) async throws -> ThreadWorkspaceRoutingResult {
        let handoffThread = try await forkThreadForRouting(
            sourceThreadID: sourceThreadID,
            fallbackThreadID: threadRoutingFallbackSourceThreadID(
                for: session,
                failingThreadID: sourceThreadID
            ),
            targetWorkspaceRoot: targetWorkspaceRoot
        )
        let resolvedHandoffThread = try await resolvedRoutingThreadContext(
            threadContext: handoffThread,
            preferredWorkspaceRoot: targetWorkspaceRoot,
            fallbackModel: Self.normalizedModelIdentifier(handoffThread.model)
                ?? Self.normalizedModelIdentifier(session.lastModel)
                ?? Self.normalizedModelIdentifier(selectedModel)
        )

        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(resolvedHandoffThread.cwd) ?? resolvedHandoffThread.cwd
        let reboundSession = SessionRecord(
            id: session.id,
            sceneID: session.sceneID,
            machineID: session.machineID,
            routeID: session.routeID,
            transportMode: session.transportMode,
            threadID: resolvedHandoffThread.id,
            reviewThreadID: session.reviewThreadID,
            workspaceRoot: normalizedWorkspaceRoot,
            lastKnownProtocol: activeProtocolKind,
            lastKnownRouteKind: session.lastKnownRouteKind,
            lastKnownBootstrap: session.lastKnownBootstrap,
            lastModel: Self.normalizedModelIdentifier(resolvedHandoffThread.model)
                ?? Self.normalizedModelIdentifier(session.lastModel)
                ?? Self.normalizedModelIdentifier(selectedModel),
            lastReasoningEffort: currentReasoningLevel,
            lastMode: Self.workspaceMode(for: normalizedWorkspaceRoot),
            lastTurnID: session.lastTurnID,
            lastTurn: session.lastTurn,
            lastOpenedAt: .now,
            resumeStrategy: session.resumeStrategy,
            uiStateBlob: session.uiStateBlob,
            transportState: .connected,
            queuedPrompts: session.queuedPrompts,
            lastErrorSummary: nil,
            parentThreadID: sourceThreadID,
            parentLastTurnID: session.lastTurnID,
            isArchived: false,
            executionProfileState: session.executionProfileState
        )
        try await activateThreadWorkspaceSession(
            reboundSession,
            thread: CodexThreadContext(
                id: resolvedHandoffThread.id,
                cwd: normalizedWorkspaceRoot,
                model: resolvedHandoffThread.model,
                reasoningEffort: resolvedHandoffThread.reasoningEffort,
                executionProfile: resolvedHandoffThread.executionProfile
            )
        )
        return ThreadWorkspaceRoutingResult(
            sessionID: session.id,
            threadID: resolvedHandoffThread.id,
            workspaceRoot: normalizedWorkspaceRoot
        )
    }

    private func resolvedRoutingThreadContext(
        threadContext: CodexThreadContext,
        preferredWorkspaceRoot: String,
        fallbackModel: String?
    ) async throws -> CodexThreadContext {
        let normalizedPreferredWorkspaceRoot = Self.normalizedWorkspaceRoot(preferredWorkspaceRoot) ?? preferredWorkspaceRoot
        var lastResolvedContext = CodexThreadContext(
            id: threadContext.id,
            cwd: Self.normalizedWorkspaceRoot(threadContext.cwd) ?? normalizedPreferredWorkspaceRoot,
            model: Self.normalizedModelIdentifier(threadContext.model)
                ?? Self.normalizedModelIdentifier(fallbackModel),
            reasoningEffort: threadContext.reasoningEffort,
            executionProfile: threadContext.executionProfile
        )
        let maxAttempts = 10

        for attempt in 0..<maxAttempts {
            do {
                let resumed = try await resumeThreadOnActiveConnection(
                    threadID: threadContext.id,
                    options: requestedThreadExecutionOptions(
                        session: activeSession,
                        cwd: normalizedPreferredWorkspaceRoot,
                        model: nil,
                        baselineConfig: activeSession?.executionProfileState?.baselineConfig
                    )
                )
                let resumedWorkspaceRoot = Self.normalizedWorkspaceRoot(resumed.cwd) ?? normalizedPreferredWorkspaceRoot
                lastResolvedContext = CodexThreadContext(
                    id: resumed.thread.id,
                    cwd: resumedWorkspaceRoot,
                    model: Self.normalizedModelIdentifier(resumed.model)
                        ?? Self.normalizedModelIdentifier(threadContext.model)
                        ?? Self.normalizedModelIdentifier(fallbackModel),
                    reasoningEffort: resumed.reasoningEffort ?? threadContext.reasoningEffort,
                    executionProfile: resumed.executionProfile ?? threadContext.executionProfile
                )
                if resumedWorkspaceRoot == normalizedPreferredWorkspaceRoot {
                    return lastResolvedContext
                }
            } catch {
                if !shouldTreatRoutingResumeErrorAsTransient(error) || attempt == maxAttempts - 1 {
                    throw error
                }
            }

            if let catalogResolvedContext = try await routingThreadContextFromHostCatalog(
                threadID: threadContext.id,
                preferredWorkspaceRoot: normalizedPreferredWorkspaceRoot,
                fallbackModel: fallbackModel
            ) {
                return catalogResolvedContext
            }

            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        if lastResolvedContext.cwd != normalizedPreferredWorkspaceRoot {
            lastResolvedContext = CodexThreadContext(
                id: lastResolvedContext.id,
                cwd: normalizedPreferredWorkspaceRoot,
                model: Self.normalizedModelIdentifier(lastResolvedContext.model)
                    ?? Self.normalizedModelIdentifier(fallbackModel),
                reasoningEffort: lastResolvedContext.reasoningEffort,
                executionProfile: lastResolvedContext.executionProfile
            )
        }
        return lastResolvedContext
    }

    private func routingThreadContextFromHostCatalog(
        threadID: String,
        preferredWorkspaceRoot: String,
        fallbackModel: String?
    ) async throws -> CodexThreadContext? {
        let normalizedPreferredWorkspaceRoot = Self.normalizedWorkspaceRoot(preferredWorkspaceRoot) ?? preferredWorkspaceRoot
        let threads = try await Self.paginateThreadList { cursor in
            try await preferredHostThreadCatalogPage(limit: 40, cursor: cursor).page
        }
        let normalizedThreads = threads.map { thread in
            (
                thread: thread,
                workspaceRoot: Self.normalizedWorkspaceRoot(thread.cwd) ?? thread.cwd
            )
        }
        if let matchingThread = normalizedThreads.first(where: {
            $0.thread.id == threadID && $0.workspaceRoot == normalizedPreferredWorkspaceRoot
        }) {
            return CodexThreadContext(
                id: matchingThread.thread.id,
                cwd: matchingThread.workspaceRoot,
                model: Self.normalizedModelIdentifier(matchingThread.thread.modelProvider)
                    ?? Self.normalizedModelIdentifier(fallbackModel)
            )
        }
        return nil
    }

    private func shouldTreatRoutingResumeErrorAsTransient(_ error: Error) -> Bool {
        if shouldTreatResumeErrorAsMissingThread(error) {
            return true
        }

        let detail = error.localizedDescription.lowercased()
        return detail.contains("missing thread/resume result")
            || detail.contains("endedchannel")
            || detail.contains("connection reset")
            || detail.contains("connection was invalidated")
            || detail.contains("broken pipe")
            || detail.contains("timed out")
            || detail.contains("temporarily unavailable")
            || detail.contains("transport endpoint is not connected")
            || detail.contains("socket is closed")
            || detail.contains("resource temporarily unavailable")
            || detail.contains("connection closed")
            || detail.contains("eof")
            || detail.contains("reset by peer")
            || detail.contains("network is down")
            || detail.contains("host is down")
            || detail.contains("not ready")
            || detail.contains("unavailable")
            || detail.contains("failed to write framed request")
            || detail.contains("failed to read framed response")
            || detail.contains("couldn't be completed")
            || detail.contains("the operation couldn")
    }

    private func shouldAttemptThreadSnapshotFallback(after error: Error) -> Bool {
        guard !shouldTreatResumeErrorAsMissingThread(error) else {
            return false
        }

        return shouldTreatRoutingResumeErrorAsTransient(error)
    }

    private func readThreadSnapshotAsResumedContext(
        threadID: String,
        options: CodexThreadExecutionOptions,
        protocolKind: CodexProtocolKind
    ) async throws -> ResolvedThreadBindingContext {
        let snapshot: CodexThreadSnapshot
        do {
            snapshot = try await withAsyncTimeout(
                .seconds(30),
                errorMessage: "Thread read timed out."
            ) {
                switch protocolKind {
                case .stdio:
                    try await self.safeLaneClient.readThread(threadID: threadID, includeTurns: true)
                case .websocket, .directEndpoint:
                    try await self.loopbackClient.readThread(threadID: threadID, includeTurns: true)
                }
            }
        } catch {
            if let cachedContext = cachedThreadSnapshotAsResumedContext(
                threadID: threadID,
                options: options
            ) {
                Self.logger.warning("Using cached thread snapshot after resume fallback failed: \(error.localizedDescription, privacy: .public)")
                return cachedContext
            }

            snapshot = try await withAsyncTimeout(
                .seconds(10),
                errorMessage: "Thread summary read timed out."
            ) {
                switch protocolKind {
                case .stdio:
                    try await self.safeLaneClient.readThread(threadID: threadID, includeTurns: false)
                case .websocket, .directEndpoint:
                    try await self.loopbackClient.readThread(threadID: threadID, includeTurns: false)
                }
            }
        }

        return resolvedThreadBindingContext(
            threadID: threadID,
            snapshot: snapshot,
            options: options
        )
    }

    private func cachedThreadSnapshotAsResumedContext(
        threadID: String,
        options: CodexThreadExecutionOptions
    ) -> ResolvedThreadBindingContext? {
        guard let snapshot = activeTranscriptSnapshot,
              snapshot.id == threadID else {
            return nil
        }

        return resolvedThreadBindingContext(
            threadID: threadID,
            snapshot: snapshot,
            options: options
        )
    }

    private func resolvedThreadBindingContext(
        threadID: String,
        snapshot: CodexThreadSnapshot,
        options: CodexThreadExecutionOptions
    ) -> ResolvedThreadBindingContext {
        let resolvedWorkspaceRoot = Self.normalizedWorkspaceRoot(snapshot.cwd)
            ?? Self.normalizedWorkspaceRoot(options.cwd)
            ?? Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot)
            ?? connectionBootstrapWorkspaceRoot()

        return ResolvedThreadBindingContext(
            context: CodexResumedThreadContext(
                thread: snapshot,
                cwd: resolvedWorkspaceRoot,
                model: Self.normalizedModelIdentifier(options.model)
                    ?? Self.normalizedModelIdentifier(activeSession?.lastModel),
                executionProfile: activeSession?.executionProfileState?.profile
            ),
            isLiveBinding: false
        )
    }

    private func resumeThreadWithSnapshotFallback(
        threadID: String,
        options: CodexThreadExecutionOptions,
        protocolKind: CodexProtocolKind,
        allowSnapshotFallback: Bool = true
    ) async throws -> ResolvedThreadBindingContext {
        do {
            let context = try await withAsyncTimeout(
                .seconds(15),
                errorMessage: "Thread resume timed out."
            ) {
                switch protocolKind {
                case .stdio:
                    try await self.safeLaneClient.resumeThread(threadID: threadID, options: options)
                case .websocket, .directEndpoint:
                    try await self.loopbackClient.resumeThread(threadID: threadID, options: options)
                }
            }
            if let errorMessage = Self.requestedThreadResumeMismatchMessage(
                expectedThreadID: threadID,
                resumedThreadID: context.thread.id
            ) {
                throw CodexSSHError.invalidResponse(errorMessage)
            }
            return ResolvedThreadBindingContext(context: context, isLiveBinding: true)
        } catch {
            guard allowSnapshotFallback,
                  shouldAttemptThreadSnapshotFallback(after: error) else {
                throw error
            }

            let snapshotContext = try await readThreadSnapshotAsResumedContext(
                threadID: threadID,
                options: options,
                protocolKind: protocolKind
            )
            if let errorMessage = Self.requestedThreadResumeMismatchMessage(
                expectedThreadID: threadID,
                resumedThreadID: snapshotContext.thread.id
            ) {
                throw CodexSSHError.invalidResponse(errorMessage)
            }
            return snapshotContext
        }
    }

    private func resumeParentLocalThreadIfAvailable(
        currentContext: WorkspaceRoutingContext,
        localCheckoutPath: String
    ) async throws -> ThreadWorkspaceRoutingResult? {
        guard let parentThreadID = currentContext.session.parentThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !parentThreadID.isEmpty,
              parentThreadID != currentContext.threadID else {
            return nil
        }

        let resumedParent = try await resumeThreadOnActiveConnection(
            threadID: parentThreadID,
            options: requestedThreadExecutionOptions(
                session: currentContext.session,
                cwd: localCheckoutPath,
                model: nil,
                baselineConfig: currentContext.session.executionProfileState?.baselineConfig
            )
        )
        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(resumedParent.cwd)
            ?? Self.normalizedWorkspaceRoot(localCheckoutPath)
            ?? localCheckoutPath
        let reboundSession = await MainActor.run {
            if let existingLocalSession = self.recentSessions.first(where: { session in
                session.id != currentContext.session.id
                    && session.machineID == currentContext.session.machineID
                    && session.threadID == resumedParent.thread.id
                    && Self.normalizedWorkspaceRoot(session.workspaceRoot) == normalizedWorkspaceRoot
                    && !session.isArchived
            }) {
                return SessionRecord(
                    id: existingLocalSession.id,
                    sceneID: self.sceneID,
                    machineID: existingLocalSession.machineID,
                    routeID: currentContext.session.routeID ?? existingLocalSession.routeID,
                    transportMode: currentContext.session.transportMode,
                    threadID: resumedParent.thread.id,
                    reviewThreadID: existingLocalSession.reviewThreadID,
                    workspaceRoot: normalizedWorkspaceRoot,
                    lastKnownProtocol: self.activeProtocolKind,
                    lastKnownRouteKind: currentContext.session.lastKnownRouteKind ?? existingLocalSession.lastKnownRouteKind,
                    lastKnownBootstrap: currentContext.session.lastKnownBootstrap,
                    lastModel: Self.normalizedModelIdentifier(resumedParent.model)
                        ?? Self.normalizedModelIdentifier(existingLocalSession.lastModel)
                        ?? Self.normalizedModelIdentifier(currentContext.session.lastModel)
                        ?? Self.normalizedModelIdentifier(self.selectedModel),
                    lastReasoningEffort: self.currentReasoningLevel,
                    lastMode: Self.workspaceMode(for: normalizedWorkspaceRoot),
                    lastTurnID: existingLocalSession.lastTurnID,
                    lastTurn: existingLocalSession.lastTurn,
                    lastOpenedAt: .now,
                    resumeStrategy: currentContext.session.resumeStrategy,
                    uiStateBlob: existingLocalSession.uiStateBlob,
                    transportState: .connected,
                    queuedPrompts: existingLocalSession.queuedPrompts,
                    lastErrorSummary: nil,
                    parentThreadID: currentContext.threadID,
                    parentLastTurnID: currentContext.session.lastTurnID,
                    isArchived: false,
                    executionProfileState: currentContext.session.executionProfileState ?? existingLocalSession.executionProfileState
                )
            }

            return SessionRecord(
                id: currentContext.session.id,
                sceneID: currentContext.session.sceneID,
                machineID: currentContext.session.machineID,
                routeID: currentContext.session.routeID,
                transportMode: currentContext.session.transportMode,
                threadID: resumedParent.thread.id,
                reviewThreadID: currentContext.session.reviewThreadID,
                workspaceRoot: normalizedWorkspaceRoot,
                lastKnownProtocol: activeProtocolKind,
                lastKnownRouteKind: currentContext.session.lastKnownRouteKind,
                lastKnownBootstrap: currentContext.session.lastKnownBootstrap,
                lastModel: Self.normalizedModelIdentifier(resumedParent.model)
                    ?? Self.normalizedModelIdentifier(currentContext.session.lastModel)
                    ?? Self.normalizedModelIdentifier(selectedModel),
                lastReasoningEffort: currentReasoningLevel,
                lastMode: Self.workspaceMode(for: normalizedWorkspaceRoot),
                lastTurnID: currentContext.session.parentLastTurnID,
                lastTurn: currentContext.session.lastTurn,
                lastOpenedAt: .now,
                resumeStrategy: currentContext.session.resumeStrategy,
                uiStateBlob: currentContext.session.uiStateBlob,
                transportState: .connected,
                queuedPrompts: currentContext.session.queuedPrompts,
                lastErrorSummary: nil,
                parentThreadID: currentContext.threadID,
                parentLastTurnID: currentContext.session.lastTurnID,
                isArchived: false,
                executionProfileState: currentContext.session.executionProfileState
            )
        }
        try await applyThreadWorkspaceRebind(
            resumedParent,
            session: reboundSession,
            requestedThreadOptions: requestedThreadExecutionOptions(
                session: reboundSession,
                cwd: reboundSession.workspaceRoot,
                model: Self.normalizedModelIdentifier(resumedParent.model)
                    ?? Self.normalizedModelIdentifier(reboundSession.lastModel),
                baselineConfig: reboundSession.executionProfileState?.baselineConfig
            )
        )
        return ThreadWorkspaceRoutingResult(
            sessionID: reboundSession.id,
            threadID: resumedParent.thread.id,
            workspaceRoot: normalizedWorkspaceRoot
        )
    }

    private func returnToFreshLocalThreadIfNeeded(
        currentContext: WorkspaceRoutingContext,
        localCheckoutPath: String,
        triggeringError: Error
    ) async throws -> ThreadWorkspaceRoutingResult? {
        guard currentContext.session.parentThreadID != nil,
              currentContext.session.parentLastTurnID == nil,
              shouldTreatResumeErrorAsMissingThread(triggeringError)
                || shouldTreatRoutingResumeErrorAsTransient(triggeringError) else {
            return nil
        }

        let startedLocalThread = try await startThreadOnActiveConnection(
            options: requestedThreadExecutionOptions(
                session: currentContext.session,
                cwd: localCheckoutPath,
                model: Self.normalizedModelIdentifier(selectedModel)
                    ?? Self.normalizedModelIdentifier(currentContext.session.lastModel),
                baselineConfig: currentContext.session.executionProfileState?.baselineConfig
            )
        )
        let normalizedWorkspaceRoot = Self.normalizedWorkspaceRoot(startedLocalThread.cwd)
            ?? Self.normalizedWorkspaceRoot(localCheckoutPath)
            ?? localCheckoutPath
        let reboundSession = await MainActor.run {
            if let existingLocalSession = self.recentSessions.first(where: { session in
                session.id != currentContext.session.id
                    && session.machineID == currentContext.session.machineID
                    && Self.normalizedWorkspaceRoot(session.workspaceRoot) == normalizedWorkspaceRoot
                    && session.lastMode == .local
                    && !session.isArchived
            }) {
                return SessionRecord(
                    id: existingLocalSession.id,
                    sceneID: self.sceneID,
                    machineID: existingLocalSession.machineID,
                    routeID: currentContext.session.routeID ?? existingLocalSession.routeID,
                    transportMode: currentContext.session.transportMode,
                    threadID: startedLocalThread.id,
                    reviewThreadID: existingLocalSession.reviewThreadID,
                    workspaceRoot: normalizedWorkspaceRoot,
                    lastKnownProtocol: self.activeProtocolKind,
                    lastKnownRouteKind: currentContext.session.lastKnownRouteKind ?? existingLocalSession.lastKnownRouteKind,
                    lastKnownBootstrap: currentContext.session.lastKnownBootstrap,
                    lastModel: Self.normalizedModelIdentifier(startedLocalThread.model)
                        ?? Self.normalizedModelIdentifier(self.selectedModel)
                        ?? Self.normalizedModelIdentifier(existingLocalSession.lastModel)
                        ?? Self.normalizedModelIdentifier(currentContext.session.lastModel),
                    lastReasoningEffort: self.currentReasoningLevel,
                    lastMode: .local,
                    lastTurnID: existingLocalSession.lastTurnID,
                    lastTurn: existingLocalSession.lastTurn,
                    lastOpenedAt: .now,
                    resumeStrategy: currentContext.session.resumeStrategy,
                    uiStateBlob: existingLocalSession.uiStateBlob,
                    transportState: .connected,
                    queuedPrompts: existingLocalSession.queuedPrompts,
                    lastErrorSummary: nil,
                    parentThreadID: currentContext.threadID,
                    parentLastTurnID: currentContext.session.lastTurnID,
                    isArchived: false,
                    executionProfileState: currentContext.session.executionProfileState ?? existingLocalSession.executionProfileState
                )
            }

            return SessionRecord(
                id: currentContext.session.id,
                sceneID: currentContext.session.sceneID,
                machineID: currentContext.session.machineID,
                routeID: currentContext.session.routeID,
                transportMode: currentContext.session.transportMode,
                threadID: startedLocalThread.id,
                reviewThreadID: currentContext.session.reviewThreadID,
                workspaceRoot: normalizedWorkspaceRoot,
                lastKnownProtocol: activeProtocolKind,
                lastKnownRouteKind: currentContext.session.lastKnownRouteKind,
                lastKnownBootstrap: currentContext.session.lastKnownBootstrap,
                lastModel: Self.normalizedModelIdentifier(startedLocalThread.model)
                    ?? Self.normalizedModelIdentifier(selectedModel)
                    ?? Self.normalizedModelIdentifier(currentContext.session.lastModel),
                lastReasoningEffort: currentReasoningLevel,
                lastMode: .local,
                lastTurnID: nil,
                lastTurn: nil,
                lastOpenedAt: .now,
                resumeStrategy: currentContext.session.resumeStrategy,
                uiStateBlob: currentContext.session.uiStateBlob,
                transportState: .connected,
                queuedPrompts: currentContext.session.queuedPrompts,
                lastErrorSummary: nil,
                parentThreadID: currentContext.threadID,
                parentLastTurnID: currentContext.session.lastTurnID,
                isArchived: false,
                executionProfileState: currentContext.session.executionProfileState
            )
        }
        try await activateThreadWorkspaceSession(reboundSession, thread: startedLocalThread)
        return ThreadWorkspaceRoutingResult(
            sessionID: reboundSession.id,
            threadID: startedLocalThread.id,
            workspaceRoot: normalizedWorkspaceRoot
        )
    }

    private func resolvedWorkspaceBrowsePath(for requestedPath: String?) async throws -> String {
        if let requestedPath = Self.normalizedWorkspaceRoot(requestedPath) {
            return requestedPath
        }

        if let workspaceRoot = Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot) {
            return workspaceRoot
        }

        let result = try await safeLaneClient.execute(
            command: "printf %s \"$HOME\""
        )
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(
                result.errorOutput.isEmpty ? result.standardOutput : result.errorOutput
            )
        }

        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func forkThreadForRouting(
        sourceThreadID: String,
        fallbackThreadID: String?,
        targetWorkspaceRoot: String
    ) async throws -> CodexThreadContext {
        do {
            return try await forkThreadForRouting(
                sourceThreadID: sourceThreadID,
                targetWorkspaceRoot: targetWorkspaceRoot
            )
        } catch {
            let directFallbackThreadID = fallbackThreadID != sourceThreadID ? fallbackThreadID : nil
            let workspaceFallbackThreadID = try? await workspaceRoutingFallbackSourceThreadID(
                targetWorkspaceRoot: targetWorkspaceRoot,
                failingThreadID: sourceThreadID
            )
            let retryThreadID = directFallbackThreadID ?? workspaceFallbackThreadID
            guard shouldTreatResumeErrorAsMissingThread(error),
                  let retryThreadID,
                  retryThreadID != sourceThreadID else {
                throw error
            }

            await MainActor.run {
                self.transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Routing retried from the parent thread because the current worktree thread was not ready on the active transport yet."
                    )
                )
            }
            return try await forkThreadForRouting(
                sourceThreadID: retryThreadID,
                targetWorkspaceRoot: targetWorkspaceRoot
            )
        }
    }

    private func forkThreadForRouting(
        sourceThreadID: String,
        targetWorkspaceRoot: String
    ) async throws -> CodexThreadContext {
        switch activeProtocolKind {
        case .stdio:
            return try await safeLaneClient.forkThread(
                threadID: sourceThreadID,
                cwd: targetWorkspaceRoot,
                model: activeThreadModelLabel
            )
        case .websocket, .directEndpoint:
            return try await loopbackClient.forkThread(
                threadID: sourceThreadID,
                cwd: targetWorkspaceRoot,
                model: activeThreadModelLabel
            )
        }
    }

    private func threadRoutingFallbackSourceThreadID(
        for session: SessionRecord?,
        failingThreadID: String
    ) -> String? {
        guard let session else {
            return alternateRoutingFallbackSourceThreadID(failingThreadID: failingThreadID)
        }

        let parentThreadID = session.parentThreadID
            .flatMap { threadID in
                let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            ?? alternateRoutingFallbackSourceThreadID(failingThreadID: failingThreadID)
        guard let parentThreadID else {
            return nil
        }

        let parentLastTurnID = recentSessions.first(where: { $0.threadID == parentThreadID })?.lastTurnID
            ?? session.parentLastTurnID
        guard parentLastTurnID != nil else {
            return nil
        }
        guard session.lastTurnID == nil || session.lastTurnID == parentLastTurnID else {
            return nil
        }
        guard session.threadID == failingThreadID || resolveThreadID(preferredThreadID: nil) == failingThreadID else {
            return nil
        }
        return parentThreadID
    }

    private func alternateRoutingFallbackSourceThreadID(
        failingThreadID: String
    ) -> String? {
        let candidates: [String?] = switch activeProtocolKind {
        case .stdio:
            [loopbackThreadID, directEndpointThreadID]
        case .websocket:
            [stdioThreadID, directEndpointThreadID]
        case .directEndpoint:
            [stdioThreadID, loopbackThreadID]
        }

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && $0 != failingThreadID })
    }

    private func workspaceRoutingFallbackSourceThreadID(
        targetWorkspaceRoot: String,
        failingThreadID: String
    ) async throws -> String? {
        let normalizedTargetWorkspaceRoot = Self.normalizedWorkspaceRoot(targetWorkspaceRoot)
            ?? targetWorkspaceRoot
        let threads = try await Self.paginateThreadList { cursor in
            try await preferredHostThreadCatalogPage(limit: 40, cursor: cursor).page
        }
        return threads.first(where: { thread in
            let normalizedThreadWorkspaceRoot = Self.normalizedWorkspaceRoot(thread.cwd)
                ?? thread.cwd
            return normalizedThreadWorkspaceRoot == normalizedTargetWorkspaceRoot
                && thread.id != failingThreadID
        })?.id
    }

    private static func workspaceDirectoryListCommand(cwd: String) -> String {
        """
        cd \(shellQuote(cwd)) && pwd && printf '\\n__COTG_CURRENT__\\t' && if [ -d .git ]; then printf 'repo'; else printf 'dir'; fi && printf '\\n__COTG_LIST__\\n' && for entry in .* *; do [ "$entry" = "." ] && continue; [ "$entry" = ".." ] && continue; [ -d "$entry" ] || continue; if [ -d "$entry/.git" ]; then printf 'repo\\t%s\\n' "$entry"; else printf 'dir\\t%s\\n' "$entry"; fi; done
        """
    }

    private static func parseWorkspaceDirectoryListing(
        _ output: String,
        currentPath fallbackPath: String
    ) -> WorkspaceDirectoryListing {
        let components = output.components(separatedBy: "\n__COTG_LIST__\n")
        let headerLines = components.first?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        let currentPath = headerLines
            .lazy
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("__COTG_CURRENT__\t") else {
                    return nil
                }
                return trimmed
            }
            .first
            ?? fallbackPath
        let isCurrentPathGitRepository = headerLines.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "__COTG_CURRENT__\trepo"
        }
        let listingBody = components.count > 1 ? components[1] : ""
        let entries = listingBody
            .split(separator: "\n")
            .compactMap { line -> WorkspaceDirectoryEntry? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return nil
                }

                let kind = String(parts[0])
                let name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    return nil
                }

                return WorkspaceDirectoryEntry(
                    name: name,
                    path: (currentPath as NSString).appendingPathComponent(name),
                    isGitRepository: kind == "repo"
                )
            }
            .sorted {
                if $0.isGitRepository != $1.isGitRepository {
                    return $0.isGitRepository && !$1.isGitRepository
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        let parentCandidate = (currentPath as NSString).deletingLastPathComponent
        let parentPath: String?
        if currentPath == "/" || parentCandidate.isEmpty || parentCandidate == currentPath {
            parentPath = nil
        } else {
            parentPath = parentCandidate
        }

        return WorkspaceDirectoryListing(
            currentPath: currentPath,
            parentPath: parentPath,
            isCurrentPathGitRepository: isCurrentPathGitRepository,
            entries: entries
        )
    }

    private static func demoWorkspaceDirectoryListing(
        at path: String?
    ) -> WorkspaceDirectoryListing {
        let currentPath = normalizedWorkspaceRoot(path) ?? "/workspace"
        let entries: [WorkspaceDirectoryEntry]
        let isCurrentPathGitRepository: Bool
        switch currentPath {
        case "/workspace":
            isCurrentPathGitRepository = false
            entries = [
                WorkspaceDirectoryEntry(name: "coding-on-the-go", path: "/workspace/coding-on-the-go", isGitRepository: true),
                WorkspaceDirectoryEntry(name: "infrastructure", path: "/workspace/infrastructure", isGitRepository: true),
                WorkspaceDirectoryEntry(name: "release-notes", path: "/workspace/release-notes", isGitRepository: true)
            ]
        case "/workspace/coding-on-the-go",
             "/workspace/infrastructure",
             "/workspace/release-notes":
            isCurrentPathGitRepository = true
            entries = []
        default:
            isCurrentPathGitRepository = false
            entries = []
        }

        let parentCandidate = (currentPath as NSString).deletingLastPathComponent
        let parentPath = currentPath == "/workspace" || parentCandidate == currentPath || parentCandidate.isEmpty ? nil : parentCandidate
        return WorkspaceDirectoryListing(
            currentPath: currentPath,
            parentPath: parentPath,
            isCurrentPathGitRepository: isCurrentPathGitRepository,
            entries: entries
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func shouldAutoUpgradeLoopback(environment: [String: String]) -> Bool {
        if environment["COTG_DISABLE_AUTO_UPGRADE"] == "1" {
            return false
        }
        if environment["COTG_ENABLE_AUTO_UPGRADE"] == "1" {
            return true
        }
        if environment["UI_TESTING"] == "1" || environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        return true
    }

    static func hostRuntimeNoticeText(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHostRuntimeReconnectNotice(trimmed) else {
            return summary
        }
        return "Mac-side Codex retry: \(trimmed)"
    }

    static func hostRuntimeTransportStatus(from summary: String) -> HostRuntimeTransportStatus? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("mac-side codex retry:")
            || lowercased.hasPrefix("reconnecting") {
            return HostRuntimeTransportStatus(
                kind: .retrying,
                label: "Mac Codex retry",
                detail: trimmed
            )
        }

        if lowercased.contains("falling back from websockets to https")
            || (
                lowercased.contains("websocket")
                    && lowercased.contains("https")
                    && lowercased.contains("fallback")
            )
            || lowercased.contains("timeout waiting for child process to exit") {
            return HostRuntimeTransportStatus(
                kind: .httpsFallback,
                label: "Mac Codex on HTTPS",
                detail: trimmed
            )
        }

        if isLoopbackFallbackNotice(trimmed) {
            return HostRuntimeTransportStatus(
                kind: .loopbackFallback,
                label: "SSH fallback",
                detail: trimmed
            )
        }

        if lowercased.hasPrefix("thread refresh failed:")
            || lowercased.contains("niocore.channelerror") {
            return HostRuntimeTransportStatus(
                kind: .threadRefreshFailed,
                label: "Thread sync retry",
                detail: trimmed
            )
        }

        return nil
    }

    static func isLoopbackFallbackNotice(_ summary: String) -> Bool {
        let lowercased = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowercased.contains("loopback") else {
            return false
        }

        return lowercased.contains("degraded")
            || lowercased.contains("failed")
            || lowercased.contains("falling back")
    }

    private static func isHostRuntimeReconnectNotice(_ summary: String) -> Bool {
        let lowercased = summary.lowercased()
        guard !lowercased.hasPrefix("mac-side codex retry:") else {
            return false
        }
        return lowercased.hasPrefix("reconnecting")
    }

    static func shouldRecoverPreferredLoopbackAfterRelaunch(
        shouldAutoUpgrade: Bool,
        isSuppressedUntilReconnect: Bool,
        protocolKind: CodexProtocolKind,
        isConnected: Bool,
        hasSelectedMachine: Bool,
        threadID: String?,
        activeTurnID: String?,
        loopbackUpgradeFeatureAvailable: Bool
    ) -> Bool {
        shouldAutoUpgrade
            && !isSuppressedUntilReconnect
            && protocolKind == .stdio
            && isConnected
            && hasSelectedMachine
            && normalizedThreadID(threadID) != nil
            && normalizedThreadID(activeTurnID) == nil
            && loopbackUpgradeFeatureAvailable
    }

    static func shouldScheduleAutomaticLoopbackUpgrade(
        preferLoopbackUpgrade: Bool,
        unavailableSelectedThreadID: String?,
        hasBoundThread: Bool
    ) -> Bool {
        preferLoopbackUpgrade
            && unavailableSelectedThreadID == nil
            && hasBoundThread
    }

    static func shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
        hadConcreteThreadBeforeTurn: Bool,
        preferLoopbackUpgrade: Bool,
        unavailableSelectedThreadID: String?,
        threadID: String?
    ) -> Bool {
        guard !hadConcreteThreadBeforeTurn else {
            return false
        }

        return shouldScheduleAutomaticLoopbackUpgrade(
            preferLoopbackUpgrade: preferLoopbackUpgrade,
            unavailableSelectedThreadID: unavailableSelectedThreadID,
            hasBoundThread: normalizedThreadID(threadID) != nil
        )
    }

    nonisolated static func isSigningSensitiveTurnText(_ text: String?) -> Bool {
        guard let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }

        let hasShellSigningProbe = normalized.contains("security find-identity")
            || normalized.contains("/usr/bin/codesign")
            || (normalized.contains("codesign") && normalized.contains("shell command"))
        let hasXcodeArchiveCommand = normalized.contains("xcodebuild")
            && (
                normalized.contains(" archive")
                    || normalized.contains(" -archivepath")
                    || normalized.contains("exportarchive")
                    || normalized.contains(" -exportarchive")
            )
        let hasReleaseUploadIntent = (
            normalized.contains("upload")
                || normalized.contains("submit")
                || normalized.contains("attach")
        ) && (
            normalized.contains("testflight")
                || normalized.contains("app store connect")
                || normalized.contains("app store")
        )
        let hasSigningAssetIntent = (
            normalized.contains("provisioning profile")
                || normalized.contains("apple development")
                || normalized.contains("apple distribution")
                || normalized.contains("iphone distribution")
        ) && (
            normalized.contains("sign")
                || normalized.contains("archive")
                || normalized.contains("export")
                || normalized.contains("build")
        )

        return hasShellSigningProbe
            || hasXcodeArchiveCommand
            || hasReleaseUploadIntent
            || hasSigningAssetIntent
            || isUploadAuthSensitiveTurnText(text)
    }

    nonisolated static func isUploadAuthSensitiveTurnText(_ text: String?) -> Bool {
        guard let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }

        let hasAscProbe = normalized.contains("asc auth")
            || normalized.contains("asc apps")
            || normalized.contains("asc builds upload")
        let hasReleaseUploadIntent = (
            normalized.contains("upload")
                || normalized.contains("submit")
        ) && (
            normalized.contains("testflight")
                || normalized.contains("app store connect")
                || normalized.contains("app store")
        )

        return hasAscProbe || hasReleaseUploadIntent
    }

    static func signingSensitiveHostReadinessProbeCommand(includeUploadAuth: Bool) -> String {
        let uploadProbe: String
        if includeUploadAuth {
            uploadProbe = """
            ASC_AUTH_LOG="$TMPDIR/asc-auth.err"
            ASC_API_LOG="$TMPDIR/asc-api.err"
            if ! command -v asc >/dev/null 2>&1; then
              fail ASC_MISSING 30
            fi
            run_with_timeout 20 asc auth token --confirm >/dev/null 2>"$ASC_AUTH_LOG"
            ASC_AUTH_STATUS=$?
            if [ "$ASC_AUTH_STATUS" -ne 0 ]; then
              cat "$ASC_AUTH_LOG" >&2
              if [ "$ASC_AUTH_STATUS" -eq 124 ]; then
                fail ASC_AUTH_TIMEOUT 33
              fi
              fail ASC_AUTH_FAILED 31
            fi
            run_with_timeout 20 asc apps list --limit 1 --output json >/dev/null 2>"$ASC_API_LOG"
            ASC_API_STATUS=$?
            if [ "$ASC_API_STATUS" -ne 0 ]; then
              cat "$ASC_API_LOG" >&2
              if [ "$ASC_API_STATUS" -eq 124 ]; then
                fail ASC_API_TIMEOUT 34
              fi
              fail ASC_API_FAILED 32
            fi
            printf '__COTG_ASC_AUTH_OK__\\n'
            """
        } else {
            uploadProbe = "printf '__COTG_ASC_AUTH_SKIPPED__\\n'"
        }

        let innerScript = """
        set -u
        fail() {
          printf '__COTG_PREFLIGHT_%s__\\n' "$1" >&2
          if [ -n "${COTG_STATUS_FILE:-}" ]; then
            printf '%s' "$2" >"$COTG_STATUS_FILE"
          fi
          exit "$2"
        }
        run_with_timeout() {
          seconds="$1"
          shift
          timeout_flag="$TMPDIR/timeout-$RANDOM"
          "$@" &
          command_pid=$!
          (
            sleep "$seconds"
            if kill "$command_pid" >/dev/null 2>&1; then
              printf '1' >"$timeout_flag"
            fi
          ) &
          watchdog_pid=$!
          wait "$command_pid"
          command_status=$?
          kill "$watchdog_pid" >/dev/null 2>&1 || true
          wait "$watchdog_pid" >/dev/null 2>&1 || true
          if [ -f "$timeout_flag" ]; then
            return 124
          fi
          return "$command_status"
        }
        TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR"' EXIT
        printf '__COTG_DEFAULT_KEYCHAIN__\\n'
        security default-keychain || fail DEFAULT_KEYCHAIN_FAILED 11
        printf '__COTG_KEYCHAINS__\\n'
        security list-keychains -d user || fail LIST_KEYCHAINS_FAILED 12
        printf '__COTG_IDENTITIES__\\n'
        IDENTITIES="$(security find-identity -v -p codesigning)" || fail FIND_IDENTITY_FAILED 13
        printf '%s\\n' "$IDENTITIES"
        IDENTITY="$(printf '%s\\n' "$IDENTITIES" | /usr/bin/awk '/Apple Development/ { print $2; exit }')"
        if [ -z "$IDENTITY" ]; then
          fail NO_SIGNING_IDENTITY 14
        fi
        cp /bin/ls "$TMPDIR/ls" || fail CODESIGN_COPY_FAILED 15
        run_with_timeout 20 /usr/bin/codesign --force --sign "$IDENTITY" "$TMPDIR/ls" >"$TMPDIR/codesign.out" 2>"$TMPDIR/codesign.err"
        CODESIGN_STATUS=$?
        if [ "$CODESIGN_STATUS" -ne 0 ]; then
          cat "$TMPDIR/codesign.out" >&2
          cat "$TMPDIR/codesign.err" >&2
          if [ "$CODESIGN_STATUS" -eq 124 ]; then
            fail CODESIGN_PROBE_TIMEOUT 17
          fi
          fail CODESIGN_PROBE_FAILED 16
        fi
        printf '__COTG_CODESIGN_OK__\\n'
        \(uploadProbe)
        printf '__COTG_PREFLIGHT_OK__\\n'
        if [ -n "${COTG_STATUS_FILE:-}" ]; then
          printf '0' >"$COTG_STATUS_FILE"
        fi
        """

        let outerScript = """
        set -u
        fail() {
          printf '__COTG_PREFLIGHT_%s__\\n' "$1" >&2
          exit "$2"
        }
        TMPDIR="$(mktemp -d)"
        LABEL=""
        cleanup() {
          if [ -n "$LABEL" ]; then
            launchctl remove "$LABEL" >/dev/null 2>&1 || true
          fi
          rm -rf "$TMPDIR"
        }
        trap cleanup EXIT
        COTG_UID="$(id -u)"
        COTG_HOME="$HOME"
        printf '__COTG_PREFLIGHT_BEGIN__\\n'
        printf 'uid=%s\\n' "$COTG_UID"
        printf 'home=%s\\n' "$COTG_HOME"
        if ! launchctl print "gui/$COTG_UID" >/dev/null 2>&1; then
          fail GUI_UNAVAILABLE 10
        fi
        printf '__COTG_GUI_SESSION_OK__\\n'
        printf '__COTG_LAUNCHCTL_SUBMIT_BEGIN__\\n'
        GUI_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
        STATUS_FILE="$TMPDIR/status"
        OUT_FILE="$TMPDIR/preflight.out"
        ERR_FILE="$TMPDIR/preflight.err"
        INNER_SCRIPT=\(shellQuote(innerScript))
        LABEL="cotg.signing-preflight.$(date +%s).$RANDOM.$RANDOM"
        if ! launchctl submit -l "$LABEL" -o "$OUT_FILE" -e "$ERR_FILE" -- /usr/bin/env COTG_STATUS_FILE="$STATUS_FILE" HOME="$COTG_HOME" PATH="$GUI_PATH" /bin/bash -lc "$INNER_SCRIPT"; then
          fail GUI_SUBMIT_FAILED 18
        fi
        DEADLINE=$((SECONDS + 45))
        while [ "$SECONDS" -lt "$DEADLINE" ]; do
          if [ -f "$STATUS_FILE" ]; then
            break
          fi
          sleep 1
        done
        if [ -f "$OUT_FILE" ]; then
          cat "$OUT_FILE"
        fi
        if [ -f "$ERR_FILE" ]; then
          cat "$ERR_FILE" >&2
        fi
        if [ ! -f "$STATUS_FILE" ]; then
          fail GUI_PREFLIGHT_TIMEOUT 19
        fi
        STATUS="$(cat "$STATUS_FILE")"
        case "$STATUS" in
          ''|*[!0-9]*)
            fail GUI_PREFLIGHT_BAD_STATUS 20
            ;;
        esac
        if [ "$STATUS" -ne 0 ]; then
          exit "$STATUS"
        fi
        """

        return "bash -lc \(shellQuote(outerScript))"
    }

    static func signingSensitiveHostReadinessProbeFailureDetail(
        _ result: SSHRemoteCommandResult,
        includeUploadAuth: Bool
    ) -> String {
        let combined = [result.standardOutput, result.errorOutput]
            .joined(separator: "\n")
        let tail = combined
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(8)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func detail(_ summary: String) -> String {
            tail.isEmpty ? summary : "\(summary): \(tail)"
        }

        if combined.contains("__COTG_PREFLIGHT_GUI_UNAVAILABLE__") {
            return detail("GUI session unsupported: launchctl gui/<uid> is unavailable")
        }
        if combined.contains("__COTG_PREFLIGHT_GUI_SUBMIT_FAILED__") {
            return detail("GUI session unsupported: launchctl could not submit the signing preflight")
        }
        if combined.contains("__COTG_PREFLIGHT_GUI_PREFLIGHT_TIMEOUT__") {
            return detail("GUI session unsupported: signing preflight did not finish from the GUI launch lane")
        }
        if combined.contains("__COTG_PREFLIGHT_NO_SIGNING_IDENTITY__") {
            return detail("Signing not ready: no Apple Development signing identity was visible")
        }
        if combined.contains("__COTG_PREFLIGHT_CODESIGN_PROBE_FAILED__") {
            return detail("Signing not ready: codesign probe failed")
        }
        if combined.contains("__COTG_PREFLIGHT_CODESIGN_PROBE_TIMEOUT__") {
            return detail("Signing not ready: codesign probe timed out waiting for keychain access")
        }
        if combined.contains("__COTG_PREFLIGHT_ASC_MISSING__") {
            return detail("Upload auth not ready: asc is not installed or not on PATH")
        }
        if combined.contains("__COTG_PREFLIGHT_ASC_AUTH_TIMEOUT__") {
            return detail("Upload auth not ready: asc auth timed out waiting for keychain or account access")
        }
        if combined.contains("__COTG_PREFLIGHT_ASC_AUTH_FAILED__")
            || combined.localizedCaseInsensitiveContains("credentials not found") {
            return detail("Upload auth not ready: asc could not load credentials for the active profile")
        }
        if combined.contains("__COTG_PREFLIGHT_ASC_API_TIMEOUT__") {
            return detail("Upload auth not ready: asc App Store Connect check timed out")
        }
        if combined.contains("__COTG_PREFLIGHT_ASC_API_FAILED__") {
            return detail("Upload auth not ready: asc credentials could not access App Store Connect")
        }

        let phase = includeUploadAuth ? "signing/upload-auth" : "signing"
        return detail("Host \(phase) readiness preflight failed with exit status \(result.exitStatus)")
    }

    nonisolated static func signingSensitiveTurnLaneFailureDetail(
        protocolKind: CodexProtocolKind,
        lastLoopbackUpgradeStandbyReason: String?
    ) -> String? {
        guard protocolKind != .websocket else {
            return nil
        }

        if let standbyReason = lastLoopbackUpgradeStandbyReason?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !standbyReason.isEmpty {
            return "Loopback upgrade stayed on standby: \(standbyReason)"
        }

        return "Loopback not upgraded to the GUI-session websocket lane."
    }

    nonisolated static func signingSensitiveLoopbackFailureDetail(_ errorDescription: String) -> String {
        "Loopback websocket failed before the signing-sensitive turn could start: \(errorDescription)"
    }

    static func shouldAttemptAutomaticLoopbackUpgrade(
        pending: Bool,
        protocolKind: CodexProtocolKind,
        isConnected: Bool,
        hasSelectedMachine: Bool,
        threadID: String?
    ) -> Bool {
        pending
            && protocolKind == .stdio
            && isConnected
            && hasSelectedMachine
            && threadID != nil
    }

    static func shouldRetryPreferredLoopbackUpgrade(
        shouldAutoUpgrade: Bool,
        isSuppressedUntilReconnect: Bool,
        protocolKind: CodexProtocolKind,
        isConnected: Bool,
        hasSelectedMachine: Bool,
        threadID: String?,
        activeTurnID: String?,
        loopbackUpgradeFeatureAvailable: Bool,
        canUseOptimizationLane: Bool,
        lastAttemptAt: Date?,
        now: Date,
        minimumRetryInterval: TimeInterval = 30
    ) -> Bool {
        guard shouldAutoUpgrade,
              !isSuppressedUntilReconnect,
              protocolKind == .stdio,
              isConnected,
              hasSelectedMachine,
              threadID != nil,
              activeTurnID == nil,
              loopbackUpgradeFeatureAvailable,
              canUseOptimizationLane else {
            return false
        }

        guard let lastAttemptAt else {
            return true
        }

        return now.timeIntervalSince(lastAttemptAt) >= minimumRetryInterval
    }

    static func shouldAttemptSigningSensitiveLoopbackUpgrade(
        requiresSigningSensitiveHostReadiness: Bool,
        preferLoopbackUpgrade: Bool,
        protocolKind: CodexProtocolKind,
        isConnected: Bool,
        hasSelectedMachine: Bool,
        threadID: String?
    ) -> Bool {
        requiresSigningSensitiveHostReadiness
            && preferLoopbackUpgrade
            && shouldAttemptAutomaticLoopbackUpgrade(
                pending: true,
                protocolKind: protocolKind,
                isConnected: isConnected,
                hasSelectedMachine: hasSelectedMachine,
                threadID: threadID
            )
    }

    static func loopbackUpgradeResumeMismatchMessage(
        expectedThreadID: String?,
        resumedThreadID: String?
    ) -> String? {
        guard let expectedThreadID = expectedThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedThreadID.isEmpty else {
            return nil
        }

        guard let resumedThreadID = resumedThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !resumedThreadID.isEmpty else {
            return "Loopback websocket could not resume the active thread. Staying on the SSH safe lane."
        }

        guard resumedThreadID == expectedThreadID else {
            return "Loopback websocket resumed a different thread. Staying on the SSH safe lane."
        }

        return nil
    }

    static func requestedThreadResumeMismatchMessage(
        expectedThreadID: String?,
        resumedThreadID: String?
    ) -> String? {
        exactThreadResumeMismatchMessage(
            expectedThreadID: expectedThreadID,
            resumedThreadID: resumedThreadID,
            transportLabel: "Requested thread resume",
            fallbackAction: "I didn’t switch to a different thread automatically."
        )
    }

    private static func exactThreadResumeMismatchMessage(
        expectedThreadID: String?,
        resumedThreadID: String?,
        transportLabel: String,
        fallbackAction: String
    ) -> String? {
        guard let expectedThreadID = expectedThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedThreadID.isEmpty else {
            return nil
        }

        guard let resumedThreadID = resumedThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !resumedThreadID.isEmpty else {
            return "\(transportLabel) could not resume the requested thread. \(fallbackAction)"
        }

        guard resumedThreadID == expectedThreadID else {
            return "\(transportLabel) resumed a different thread. \(fallbackAction)"
        }

        return nil
    }

    private var shouldAutoUpgradeLoopback: Bool {
        Self.shouldAutoUpgradeLoopback(environment: ProcessInfo.processInfo.environment)
    }

    private var shouldForceLoopbackTurnFailureForUITests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["UI_TESTING"] == "1"
            && environment["COTG_UI_TEST_FORCE_LOOPBACK_FAILURE_ON_NEXT_TURN"] == "1"
    }

    internal static func codexDesktopContinuationURL(threadID: String?) -> URL? {
        if let threadID, !threadID.isEmpty {
            return codexThreadHandoffURL(threadID: threadID)
        }

        return URL(string: "codex://new")
    }

    internal static func codexThreadHandoffURL(threadID: String) -> URL? {
        URL(string: "codex://threads/\(threadID)")
    }

    internal static func revealWorkspaceInFinderCommand(workspaceRoot: String) -> String {
        "open -R \(shellQuote(workspaceRoot))"
    }

    internal static var wakeDisplayCommand: String {
        "caffeinate -u -t 2 >/dev/null 2>&1 &"
    }

    internal static func workspaceDisplayName(for workspaceRoot: String) -> String {
        URL(fileURLWithPath: workspaceRoot, isDirectory: true).lastPathComponent
    }

    private func openCodexHandoffURLOnHost(_ url: String, successSummary: String) {
        runHostShellCommandOnSafeLane(
            "open \(shellQuote(url))",
            pendingSummary: nil,
            successSummary: successSummary,
            failureSummary: { error in
                "Codex Mac handoff failed: \(self.codexHandoffRemediation(for: error))"
            }
        )
    }

    private func runHostShellCommandOnSafeLane(
        _ command: String,
        pendingSummary: String?,
        successSummary: String,
        failureSummary: @escaping (Error) -> String
    ) {
        guard activeProtocolKind != .directEndpoint else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Desktop Mac actions require an SSH-backed safe lane because the direct Codex websocket endpoint does not expose host shell control."
                )
            )
            return
        }

        guard case .connected = connectionState else {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Desktop Mac actions require an active SSH safe lane. Connect to the selected Mac first."
                )
            )
            return
        }

        if let pendingSummary {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: pendingSummary
                )
            )
        }

        Task {
            do {
                let result = try await safeLaneClient.execute(command: command)
                guard result.exitStatus == 0 else {
                    throw CodexSSHError.invalidResponse(result.errorOutput.isEmpty ? result.standardOutput : result.errorOutput)
                }

                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: successSummary
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.transcript.append(
                        SessionMessage(
                            role: .system,
                            text: failureSummary(error)
                        )
                    )
                }
            }
        }
    }

    private func codexHandoffRemediation(for error: Error) -> String {
        let summary = error.localizedDescription

        if summary.contains("No application knows how to open URL codex://"),
           summary.contains("kLSExecutableIncorrectFormat") {
            return "The host does not have a compatible Codex Mac app installed for codex:// deeplinks."
        }

        if summary.contains("No application knows how to open URL codex://")
            || summary.contains("Unable to find application named") {
            return "Install the Codex Mac app on the host to enable handoff."
        }

        return summary
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func localhostTestKeyPath() -> String {
        ProcessInfo.processInfo.environment["COTG_TEST_SSH_RAW_KEY_PATH"] ?? "/tmp/cotg_app_test_key.raw"
    }

    private func localhostTestKeyData() -> Data? {
        let environment = ProcessInfo.processInfo.environment
        if let inlineBase64 = environment["COTG_TEST_SSH_RAW_KEY_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !inlineBase64.isEmpty,
           let inlineData = Data(base64Encoded: inlineBase64) {
            return inlineData
        }

        return try? Data(contentsOf: URL(fileURLWithPath: localhostTestKeyPath()))
    }

    private func sshUsername(for machine: MachineRecord, route: RouteRecord?) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let route,
           usesLocalhostTestingHostValidationOverride(for: route),
           let override = environment["COTG_TEST_SSH_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }

        if let hint = route?.usernameHint?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint
        }

        if route?.kind == .manualSSH {
            return nil
        }

        if let lastKnown = machine.lastKnownUser?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !lastKnown.isEmpty {
            return lastKnown
        }

        if let credentialUser = machine.credentialRef?.username
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !credentialUser.isEmpty {
            return credentialUser
        }

        return nil
    }

    private func selectedBootstrapRouteRequiresExplicitUsername(for machine: MachineRecord) -> Bool {
        guard let route = sshBootstrapRoute(for: machine),
              route.kind == .manualSSH else {
            return false
        }

        let trimmedUsername = route.usernameHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedUsername.isEmpty
    }

    private func missingSSHUsernameGuidance(for route: RouteRecord?, action: String) -> String {
        let label = route?.label ?? "this SSH route"
        if route?.kind == .manualSSH {
            return "Add a username to \(label) before you \(action)."
        }

        return "Add a username for \(label) before you \(action)."
    }

    private func missingSSHCredentialGuidance(
        for machine: MachineRecord,
        route: RouteRecord?,
        action: String? = nil
    ) -> String {
        let accountLabel: String = {
            if let username = sshUsername(for: machine, route: route) {
                return "@\(username)"
            }
            return route?.label ?? machine.alias
        }()
        let reinstallHint: String = {
            guard route?.trustState == .trusted else {
                return ""
            }
            return " If you reinstalled the app, the previous saved login may no longer be available on this iPhone."
        }()

        if let action {
            return "No login is stored on this iPhone for \(accountLabel). Generate a device SSH key or save a password login before you \(action).\(reinstallHint)"
        }

        return "No login is stored on this iPhone for \(accountLabel). Generate a device SSH key or save a password login.\(reinstallHint)"
    }

    private func sshKeyComment(for machine: MachineRecord, username: String) -> String {
        let alias = machine.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if alias.isEmpty {
            return "coding-on-the-go-\(username)"
        }

        return "\(username)@\(alias)-iphone"
    }

    private func testingCredentialReference(username: String) -> CredentialRef {
        CredentialRef(
            kind: .sshKey,
            keychainAccount: "cotg.testing.localhost.\(username)",
            label: "Localhost testing key",
            username: username,
            storageScope: .thisDeviceOnlyKeychain
        )
    }

    private func legacyCredentialAccountPrefix(for kind: CredentialKind) -> String {
        switch kind {
        case .sshKey:
            return "com.example.codingonthego.shared.sshkey"
        case .password:
            return "com.example.codingonthego.shared.password"
        case .token:
            return "com.example.codingonthego.shared.token"
        case .companionMutualAuth:
            return "com.example.codingonthego.shared.companion"
        }
    }

    private func hostBoundCredentialAccountPrefix(for kind: CredentialKind) -> String {
        switch kind {
        case .sshKey:
            return "com.example.codingonthego.shared.hostbound.sshkey"
        case .password:
            return "com.example.codingonthego.shared.hostbound.password"
        case .token:
            return "com.example.codingonthego.shared.hostbound.token"
        case .companionMutualAuth:
            return "com.example.codingonthego.shared.hostbound.companion"
        }
    }

    private func savedCredentialLabel(for kind: CredentialKind) -> String {
        switch kind {
        case .sshKey:
            return "SSH private key"
        case .password:
            return "Mac account password"
        case .token:
            return "Token"
        case .companionMutualAuth:
            return "Companion trust"
        }
    }

    private func credentialBindingFingerprint(for machine: MachineRecord) -> String? {
        if let fingerprint = Self.nonEmptyTrimmed(machine.stableHostFingerprint) {
            return fingerprint
        }

        let trustedKey = machine.routes
            .first(where: { $0.trustState == .trusted && $0.trustedOpenSSHPublicKey != nil })?
            .trustedOpenSSHPublicKey
        return trustedKey.flatMap(Self.hostKeyFingerprint)
    }

    private func hostBoundCredentialReference(
        kind: CredentialKind,
        username: String,
        fingerprint: String
    ) -> CredentialRef {
        let identitySeed = "\(kind.rawValue)|\(fingerprint.lowercased())|\(username.lowercased())"
        let suffix = SHA256.hash(data: Data(identitySeed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return CredentialRef(
            kind: kind,
            keychainAccount: "\(hostBoundCredentialAccountPrefix(for: kind)).\(suffix)",
            label: savedCredentialLabel(for: kind),
            username: username,
            storageScope: .localKeychain
        )
    }

    private func legacySavedCredentialReference(
        kind: CredentialKind,
        username: String,
        machineID: MachineRecord.ID
    ) -> CredentialRef {
        let suffix = machineID.uuidString.lowercased()

        return CredentialRef(
            kind: kind,
            keychainAccount: "\(legacyCredentialAccountPrefix(for: kind)).\(suffix)",
            label: savedCredentialLabel(for: kind),
            username: username,
            storageScope: .localKeychain
        )
    }

    private func savedCredentialReference(
        kind: CredentialKind,
        username: String,
        machine: MachineRecord
    ) -> CredentialRef {
        if let fingerprint = credentialBindingFingerprint(for: machine) {
            return hostBoundCredentialReference(
                kind: kind,
                username: username,
                fingerprint: fingerprint
            )
        }

        return legacySavedCredentialReference(
            kind: kind,
            username: username,
            machineID: machine.id
        )
    }

    private func assignCredential(
        _ credentialRef: CredentialRef,
        to machineID: MachineRecord.ID,
        username: String
    ) {
        setCredential(credentialRef, username: username, for: machineID)
    }

    private func setCredential(
        _ credentialRef: CredentialRef?,
        username: String?,
        for machineID: MachineRecord.ID
    ) {
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineID }) else {
            return
        }

        machines[machineIndex].credentialRef = credentialRef
        if let username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            machines[machineIndex].lastKnownUser = username
        }
        if credentialRef != nil {
            connectionSetupNotice = nil
        }
        runtimeCapabilityDiagnostics = nil
        persistStateAsync()
    }

    private enum CredentialRecoveryResult {
        case none
        case recovered(CredentialRef, username: String)
        case clearDanglingCredential
    }

    private enum SSHCredentialProbeResult {
        case recovered(SSHAuthenticationMaterial)
        case notFound
    }

    private func recoverSavedCredentialBindingsIfNeeded() async {
        let environment = ProcessInfo.processInfo.environment
        if environment["UI_TESTING"] == "1",
           environment["COTG_DISABLE_SAVED_CREDENTIAL_BINDING_RECOVERY"] == "1" {
            return
        }

        var didChange = false

        for machineIndex in machines.indices {
            let machine = machines[machineIndex]
            switch await recoveredCredentialBinding(for: machine) {
            case .none:
                continue
            case let .recovered(credentialRef, username):
                if machines[machineIndex].credentialRef != credentialRef {
                    machines[machineIndex].credentialRef = credentialRef
                    didChange = true
                }
                if Self.nonEmptyTrimmed(machines[machineIndex].lastKnownUser) != username {
                    machines[machineIndex].lastKnownUser = username
                    didChange = true
                }
            case .clearDanglingCredential:
                if machines[machineIndex].credentialRef != nil {
                    machines[machineIndex].credentialRef = nil
                    didChange = true
                }
            }
        }

        if didChange {
            runtimeCapabilityDiagnostics = nil
            persistStateAsync()
        }
    }

    private func recoveredCredentialBinding(for machine: MachineRecord) async -> CredentialRecoveryResult {
        let existingCredential = machine.credentialRef
        let recoveryUsername = recoveryUsername(for: machine)
        let preferredKinds = orderedCredentialRecoveryKinds(for: machine, username: recoveryUsername)

        if let existingCredential,
           existingCredential.kind == .sshKey || existingCredential.kind == .password,
           let payload = try? await secretVault.load(reference: existingCredential) {
            let migrated = await migrateRecoveredCredentialIfNeeded(
                sourceReference: existingCredential,
                payload: payload.value,
                machine: machine,
                username: existingCredential.username
            )
            if migrated != existingCredential
                || Self.nonEmptyTrimmed(machine.lastKnownUser) != existingCredential.username {
                return .recovered(migrated, username: existingCredential.username)
            }
            return .none
        }

        guard let recoveryUsername else {
            if let existingCredential,
               Self.isLocalhostTestingCredentialReference(existingCredential) {
                return .recovered(existingCredential, username: existingCredential.username)
            }
            if let existingCredential,
               existingCredential.kind == .sshKey || existingCredential.kind == .password {
                return .clearDanglingCredential
            }
            return .none
        }

        for kind in preferredKinds {
            let preferredReference = savedCredentialReference(
                kind: kind,
                username: recoveryUsername,
                machine: machine
            )
            if let payload = try? await secretVault.load(reference: preferredReference) {
                let migrated = await migrateRecoveredCredentialIfNeeded(
                    sourceReference: preferredReference,
                    payload: payload.value,
                    machine: machine,
                    username: recoveryUsername
                )
                return .recovered(migrated, username: recoveryUsername)
            }
        }

        for kind in preferredKinds {
            let legacyMatches = await legacyCredentialMatches(for: kind, username: recoveryUsername)

            guard legacyMatches.count == 1 else {
                continue
            }

            let legacyMatch = legacyMatches[0]
            let legacyReference = CredentialRef(
                kind: kind,
                keychainAccount: legacyMatch.keychainAccount,
                label: savedCredentialLabel(for: kind),
                username: legacyMatch.username.isEmpty ? recoveryUsername : legacyMatch.username,
                storageScope: legacyMatch.storageScope
            )

            guard let payload = try? await secretVault.load(reference: legacyReference) else {
                continue
            }

            let migrated = await migrateRecoveredCredentialIfNeeded(
                sourceReference: legacyReference,
                payload: payload.value,
                machine: machine,
                username: legacyReference.username
            )
            return .recovered(migrated, username: legacyReference.username)
        }

        if let existingCredential,
           Self.isLocalhostTestingCredentialReference(existingCredential) {
            return .recovered(existingCredential, username: existingCredential.username)
        }

        if let existingCredential,
           existingCredential.kind == .sshKey || existingCredential.kind == .password {
            return .clearDanglingCredential
        }

        return .none
    }

    private func recoveryUsername(for machine: MachineRecord) -> String? {
        if let username = Self.nonEmptyTrimmed(
            sshUsername(for: machine, route: sshBootstrapRoute(for: machine))
        ) {
            return username
        }

        return Self.nonEmptyTrimmed(machine.credentialRef?.username)
    }

    private func orderedCredentialRecoveryKinds(
        for machine: MachineRecord,
        username: String?
    ) -> [CredentialKind] {
        var kinds: [CredentialKind] = []

        if let existingKind = machine.credentialRef?.kind,
           existingKind == .sshKey || existingKind == .password {
            kinds.append(existingKind)
        }

        if username != nil {
            if !kinds.contains(.sshKey) {
                kinds.append(.sshKey)
            }
            if !kinds.contains(.password) {
                kinds.append(.password)
            }
        }

        return kinds
    }

    private func migrateRecoveredCredentialIfNeeded(
        sourceReference: CredentialRef,
        payload: Data,
        machine: MachineRecord,
        username: String
    ) async -> CredentialRef {
        let preferredReference = savedCredentialReference(
            kind: sourceReference.kind,
            username: username,
            machine: machine
        )
        guard preferredReference.keychainAccount != sourceReference.keychainAccount else {
            return sourceReference
        }

        do {
            try await secretVault.store(
                SecretPayload(
                    reference: preferredReference,
                    value: payload
                )
            )
            return preferredReference
        } catch {
            return sourceReference
        }
    }

    private func recoverWorkingSSHCredentialForConnection(
        machine: MachineRecord,
        route: RouteRecord,
        endpoint: SSHBootstrapEndpoint,
        username: String,
        hostValidation: SSHHostValidationPolicy,
        cwd: String
    ) async throws -> SSHCredentialProbeResult {
        let candidateReferences = await savedSSHKeyCandidateReferences(
            for: machine,
            username: username
        )

        guard !candidateReferences.isEmpty else {
            return .notFound
        }

        for candidateReference in candidateReferences {
            let recoveredUsername = candidateReference.username.isEmpty ? username : candidateReference.username
            guard let payload = try? await secretVault.load(reference: candidateReference) else {
                continue
            }

            do {
                try await probeSSHCredential(
                    payload.value,
                    endpoint: endpoint,
                    route: route,
                    username: recoveredUsername,
                    hostValidation: hostValidation,
                    cwd: cwd
                )

                let migratedReference = await migrateRecoveredCredentialIfNeeded(
                    sourceReference: candidateReference,
                    payload: payload.value,
                    machine: machine,
                    username: recoveredUsername
                )
                assignCredential(migratedReference, to: machine.id, username: recoveredUsername)
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: "Recovered the saved device SSH key for \(machine.alias)."
                    )
                )
                return .recovered(.ed25519Seed(payload.value))
            } catch {
                guard shouldTreatSSHCredentialProbeFailureAsAuthRejection(error) else {
                    throw error
                }
            }
        }

        return .notFound
    }

    private func probeSSHCredential(
        _ keyData: Data,
        endpoint: SSHBootstrapEndpoint,
        route: RouteRecord,
        username: String,
        hostValidation: SSHHostValidationPolicy,
        cwd: String
    ) async throws {
        let probeClient = CodexSSHAppServerClient()
        defer {
            Task {
                await probeClient.disconnect()
            }
        }

        let configuration = CodexSSHConfiguration(
            host: endpoint.host,
            port: endpoint.port,
            proxy: resolvedSSHProxyConfiguration(for: route),
            username: username,
            authentication: .ed25519Seed(keyData),
            hostValidation: hostValidation,
            cwd: cwd,
            codexHome: connectionCodexHome(),
            clientInfo: connectionClientInfo()
        )

        try await connectSSHClientWithEmbeddedRetry(
            probeClient,
            configuration: configuration,
            route: route,
            onEvent: { _ in }
        )
    }

    private func shouldTreatSSHCredentialProbeFailureAsAuthRejection(_ error: Error) -> Bool {
        let summary = error.localizedDescription.lowercased()

        if summary.contains("host key mismatch")
            || summary.contains("connection refused")
            || summary.contains("timed out")
            || summary.contains("connection reset")
            || summary.contains("no route to host")
            || summary.contains("network is unreachable")
            || summary.contains("proxy")
            || summary.contains("local network") {
            return false
        }

        return summary.contains("authentication")
            || summary.contains("public-key")
            || summary.contains("permission denied")
            || summary.contains("endedchannel")
    }

    private func hasRecoverableSavedSSHKeyHint(
        for machine: MachineRecord,
        username: String
    ) async -> Bool {
        await savedSSHKeyRecoveryAvailability(for: machine, username: username) != .none
    }

    private func shouldForceUITestRecoverableSavedSSHKeyHint(
        for machine: MachineRecord,
        username: String
    ) -> Bool {
        forcedUITestSavedSSHKeyRecoveryAvailability(
            for: machine,
            username: username
        ) == .directRecovery
    }

    private func forcedUITestSavedSSHKeyRecoveryAvailability(
        for machine: MachineRecord,
        username: String
    ) -> SavedSSHKeyRecoveryAvailability? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UI_TESTING"] == "1",
              machine.credentialRef == nil,
              !username.isEmpty else {
            return nil
        }

        if environment["COTG_UI_TEST_SEED_MULTIPLE_SAVED_SSH_KEYS"] == "1" {
            return .candidateSearch(count: 2)
        }

        if environment["COTG_UI_TEST_SEED_RECOVERABLE_SSH_KEY"] == "1" {
            return .directRecovery
        }

        return nil
    }

    private func recoverableSavedSSHKeyReference(
        for machine: MachineRecord,
        username: String
    ) async -> CredentialRef? {
        guard machine.credentialRef?.kind != .sshKey else {
            return nil
        }

        let preferredReference = savedCredentialReference(
            kind: .sshKey,
            username: username,
            machine: machine
        )
        if let payload = try? await secretVault.load(reference: preferredReference) {
            return await migrateRecoveredCredentialIfNeeded(
                sourceReference: preferredReference,
                payload: payload.value,
                machine: machine,
                username: username
            )
        }

        let legacyMatches = await legacyCredentialMatches(for: .sshKey, username: username)
        guard legacyMatches.count == 1 else {
            return nil
        }

        let legacyMatch = legacyMatches[0]
        let recoveredUsername = legacyMatch.username.isEmpty ? username : legacyMatch.username
        let legacyReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: legacyMatch.keychainAccount,
            label: savedCredentialLabel(for: .sshKey),
            username: recoveredUsername,
            storageScope: legacyMatch.storageScope
        )

        guard let payload = try? await secretVault.load(reference: legacyReference) else {
            return nil
        }

        return await migrateRecoveredCredentialIfNeeded(
            sourceReference: legacyReference,
            payload: payload.value,
            machine: machine,
            username: recoveredUsername
        )
    }

    private func savedSSHKeyRecoveryAvailability(
        for machine: MachineRecord,
        username: String
    ) async -> SavedSSHKeyRecoveryAvailability {
        guard machine.credentialRef?.kind != .sshKey else {
            return .none
        }

        if let forcedAvailability = forcedUITestSavedSSHKeyRecoveryAvailability(
            for: machine,
            username: username
        ) {
            return forcedAvailability
        }

        if await recoverableSavedSSHKeyReference(for: machine, username: username) != nil {
            return .directRecovery
        }

        let candidateCount = await savedSSHKeyCandidateReferences(
            for: machine,
            username: username
        ).count
        guard candidateCount > 0 else {
            return .none
        }

        return .candidateSearch(count: candidateCount)
    }

    private func savedSSHKeyCandidateReferences(
        for machine: MachineRecord,
        username: String
    ) async -> [CredentialRef] {
        guard machine.credentialRef?.kind != .sshKey else {
            return []
        }

        var references: [CredentialRef] = []

        let preferredReference = savedCredentialReference(
            kind: .sshKey,
            username: username,
            machine: machine
        )
        if (try? await secretVault.load(reference: preferredReference)) != nil {
            references.append(preferredReference)
        }

        let savedMatches = await savedCredentialMatches(for: .sshKey, username: username)
        for match in savedMatches {
            let candidateReference = credentialReference(
                for: match,
                kind: .sshKey,
                fallbackUsername: username
            )

            guard !references.contains(candidateReference),
                  (try? await secretVault.load(reference: candidateReference)) != nil else {
                continue
            }

            references.append(candidateReference)
        }

        return references
    }

    private func savedCredentialMatches(
        for kind: CredentialKind,
        username: String
    ) async -> [SecretReferenceMatch] {
        let legacyMatches = await credentialMatches(
            accountPrefix: legacyCredentialAccountPrefix(for: kind),
            kind: kind,
            username: username
        )

        guard kind == .sshKey else {
            return legacyMatches
        }

        let hostBoundMatches = await credentialMatches(
            accountPrefix: hostBoundCredentialAccountPrefix(for: kind),
            kind: kind,
            username: username
        )
        let normalizedUsername = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return Array(Set(legacyMatches).union(hostBoundMatches)).sorted { lhs, rhs in
            let lhsExactUsername = lhs.username
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalizedUsername
            let rhsExactUsername = rhs.username
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalizedUsername
            if lhsExactUsername != rhsExactUsername {
                return lhsExactUsername && !rhsExactUsername
            }

            let hostBoundPrefix = "\(hostBoundCredentialAccountPrefix(for: kind))."
            let lhsHostBound = lhs.keychainAccount.hasPrefix(hostBoundPrefix)
            let rhsHostBound = rhs.keychainAccount.hasPrefix(hostBoundPrefix)
            if lhsHostBound != rhsHostBound {
                return lhsHostBound && !rhsHostBound
            }

            return lhs.keychainAccount < rhs.keychainAccount
        }
    }

    private func credentialMatches(
        accountPrefix: String,
        kind: CredentialKind,
        username: String
    ) async -> [SecretReferenceMatch] {
        let fullPrefix = "\(accountPrefix)."
        let exactMatches = (try? await secretVault.findReferences(
            accountPrefix: fullPrefix,
            username: username
        )) ?? []

        guard kind == .sshKey else {
            return exactMatches
        }

        let allMatches = (try? await secretVault.findReferences(
            accountPrefix: fullPrefix,
            username: nil
        )) ?? []
        if exactMatches.isEmpty {
            return allMatches
        }

        return Array(Set(exactMatches).union(allMatches))
    }

    private func credentialReference(
        for match: SecretReferenceMatch,
        kind: CredentialKind,
        fallbackUsername: String
    ) -> CredentialRef {
        CredentialRef(
            kind: kind,
            keychainAccount: match.keychainAccount,
            label: savedCredentialLabel(for: kind),
            username: match.username.isEmpty ? fallbackUsername : match.username,
            storageScope: match.storageScope
        )
    }

    private func legacyCredentialMatches(
        for kind: CredentialKind,
        username: String
    ) async -> [SecretReferenceMatch] {
        await credentialMatches(
            accountPrefix: legacyCredentialAccountPrefix(for: kind),
            kind: kind,
            username: username
        )
    }

    private func updateRoute(
        routeID: RouteRecord.ID,
        machineID: MachineRecord.ID,
        mutate: (inout RouteRecord) -> Void
    ) {
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              let routeIndex = machines[machineIndex].routes.firstIndex(where: { $0.id == routeID }) else {
            return
        }

        mutate(&machines[machineIndex].routes[routeIndex])
    }

    private func updateMachineFingerprint(machineID: MachineRecord.ID) {
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineID }) else {
            return
        }

        let trustedKey = machines[machineIndex].routes
            .first(where: { $0.trustState == .trusted && $0.trustedOpenSSHPublicKey != nil })?
            .trustedOpenSSHPublicKey
        machines[machineIndex].stableHostFingerprint = trustedKey.flatMap(Self.hostKeyFingerprint)
    }

    private func usesLocalhostTestingHostValidationOverride(for route: RouteRecord) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let directRouteHosts = [
            route.hostname,
            route.ipAddress,
            route.magicDNSName
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let matchesLocalhostRoute = directRouteHosts.contains(where: { host in
            host == "localhost" || host == "127.0.0.1" || host == "::1"
        })

        let normalizedHostOverride = Self.uiTestSSHHostOverride()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let matchesExplicitTestHost = normalizedHostOverride.map { override in
            directRouteHosts.contains(override)
        } ?? false

        guard matchesLocalhostRoute || matchesExplicitTestHost else {
            return false
        }

        if environment["COTG_TEST_SSH_HOST"] != nil,
           FileManager.default.fileExists(atPath: localhostTestKeyPath()) {
            return true
        }

        return environment["UI_TESTING"] == "1" || environment["XCTestConfigurationFilePath"] != nil
    }

    private func usesLocalhostTestingCredentialAutoload(for machine: MachineRecord) -> Bool {
        guard localhostTestKeyData() != nil else {
            return false
        }

        let environment = ProcessInfo.processInfo.environment
        if environment["COTG_DISABLE_LOCALHOST_TESTING_CREDENTIAL_AUTOLOAD"] == "1" {
            return false
        }
        guard environment["UI_TESTING"] == "1" || environment["XCTestConfigurationFilePath"] != nil else {
            return false
        }

        guard let route = sshBootstrapRoute(for: machine) else {
            return false
        }

        if usesLocalhostTestingHostValidationOverride(for: route) {
            return true
        }

        guard route.kind == .externalTailnet else {
            if route.kind != .embeddedTailnet {
                return false
            }

            let expectedDNSName = ProcessInfo.processInfo.environment["COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let expectedDNSName, !expectedDNSName.isEmpty else {
                return false
            }

            let routeHosts = [
                route.hostname,
                route.ipAddress,
                route.magicDNSName
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

            return routeHosts.contains(expectedDNSName)
        }

        let expectedDNSName = ProcessInfo.processInfo.environment["COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let expectedDNSName, !expectedDNSName.isEmpty else {
            return false
        }

        let routeHosts = [
            route.hostname,
            route.ipAddress,
            route.magicDNSName
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        return routeHosts.contains(expectedDNSName)
    }

    private func hostValidationPolicy(for route: RouteRecord) -> SSHHostValidationPolicy? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["COTG_TEST_SSH_HOST_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return .exactOpenSSHPublicKey(override)
        }

        if let trustedKey = route.trustedOpenSSHPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trustedKey.isEmpty,
           route.trustState == .trusted {
            return .exactOpenSSHPublicKey(trustedKey)
        }

        if usesLocalhostTestingHostValidationOverride(for: route) {
            return .acceptAllForTesting
        }

        return nil
    }

    func prepareSSHHostValidationPolicyForConnection(
        for machine: MachineRecord,
        route: RouteRecord,
        scannedKeyProvider: @escaping @Sendable () async throws -> String
    ) async throws -> SSHHostValidationPolicy? {
        if let existing = hostValidationPolicy(for: route) {
            return existing
        }

        guard sshUsername(for: machine, route: route) != nil else {
            return nil
        }

        let scannedHostKey = try await scannedKeyProvider()
        try acceptFirstUseHostKey(scannedHostKey, for: route, machine: machine)
        return .exactOpenSSHPublicKey(scannedHostKey)
    }

    private func acceptFirstUseHostKey(
        _ scannedHostKey: String,
        for route: RouteRecord,
        machine: MachineRecord
    ) throws {
        let fingerprint = Self.hostKeyFingerprint(scannedHostKey) ?? scannedHostKey
        let trustedFingerprint = machine.stableHostFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let trustedFingerprint,
           !trustedFingerprint.isEmpty,
           trustedFingerprint != fingerprint {
            recordScannedHostKey(scannedHostKey, routeID: route.id, machineID: machine.id)
            updateRoute(routeID: route.id, machineID: machine.id) { updatedRoute in
                updatedRoute.trustState = .mismatch
                updatedRoute.lastFailureAt = .now
                updatedRoute.failureReasonCode = "ssh-host-key-mismatch"
            }

            throw CodexSSHError.invalidRequest(
                "The SSH fingerprint \(fingerprint) for \(route.label) does not match the fingerprint already trusted for \(machine.alias). Review it before continuing."
            )
        }

        acceptTrustedHostKey(
            scannedHostKey,
            routeID: route.id,
            machineID: machine.id
        )
        transcript.append(
            SessionMessage(
                role: .system,
                text: "First-time SSH trust for \(route.label): \(fingerprint). Future host-key changes will be blocked."
            )
        )
    }

    private func configuredSSHAuthenticationMaterial(for machine: MachineRecord) async -> SSHAuthenticationMaterial? {
        if let credentialRef = machine.credentialRef {
            switch credentialRef.kind {
            case .sshKey:
                if let keyData = await sshKeyMaterial(for: machine) {
                    return .ed25519Seed(keyData)
                }
            case .password:
                if let payload = try? await secretVault.load(reference: credentialRef),
                   let password = String(data: payload.value, encoding: .utf8),
                   !password.isEmpty {
                    return .password(password)
                }
            case .token, .companionMutualAuth:
                return nil
            }
        }

        guard let keyData = await sshKeyMaterial(for: machine) else {
            return nil
        }

        return .ed25519Seed(keyData)
    }

    private func refreshExternalTailnetAppAvailability() async {
        externalTailnetAppInstalled = await externalTailnetAppDetector.isInstalled()
    }

    func connectionFailureSummary() async -> String {
        guard let machine = selectedMachine else {
            return "No machine is selected."
        }

        if let route = sshBootstrapRoute(for: machine) {
            let environment = ProcessInfo.processInfo.environment
            if route.kind == .localLAN && networkProxyDiagnostics.discoveryRisk {
                return "Local discovery is likely being distorted by a system proxy or VPN. Bypass .local and private-network traffic before retrying."
            }

            if route.kind == .embeddedTailnet,
               (resolvedSSHBootstrapEndpoint(for: route, environment: environment) == nil
                    || resolvedSSHProxyConfiguration(for: route) == nil) {
                return "Embedded Tailscale is configured, but this build still lacks a live embedded SOCKS5 bootstrap path. Use This Route on a LAN/manual SSH path, or add one below Route diagnostics."
            }

            if route.kind == .externalTailnet, externalTailnetAppInstalled == false {
                return "Install the external Tailscale app on this device or switch to LAN/manual SSH."
            }

            if resolvedSSHBootstrapEndpoint(for: route, environment: environment) == nil {
                return "No SSH host is configured for \(route.label)."
            }

            if sshUsername(for: machine, route: route) == nil {
                return missingSSHUsernameGuidance(for: route, action: "connect over SSH")
            }

            if hostValidationPolicy(for: route) == nil {
                if let trustGuidance = selectedRouteScannedHostKeyGuidance,
                   pendingScannedHostKeyRouteID == route.id {
                    return trustGuidance
                }
                return "Scan and trust the SSH host key for \(route.label) before connecting."
            }

            let authenticationReady = await configuredSSHAuthenticationMaterial(for: machine) != nil
            if !authenticationReady {
                if let username = sshUsername(for: machine, route: route),
                   await hasRecoverableSavedSSHKeyHint(for: machine, username: username) {
                    return "Saved device SSH keys were found on this iPhone. Tap Connect to recover the working key, or save a new login."
                }
                if showsLocalhostTestingControls, localhostTestKeyExists {
                    return "Load the clearly marked localhost testing key before connecting over SSH."
                }
                return missingSSHCredentialGuidance(
                    for: machine,
                    route: route,
                    action: "connect over SSH"
                )
            }

            if let proxyAdvisory = embeddedTailnetProxyAdvisory(
                for: route,
                hostValidationReady: hostValidationPolicy(for: route) != nil,
                authenticationReady: authenticationReady
            ) {
                return proxyAdvisory
            }

            return "The selected SSH route is not ready yet."
        }

        if machine.route(for: .companionDirect) != nil {
            return "The Codex websocket endpoint is saved but not currently reachable."
        }

        return "No usable live route is configured for the selected machine."
    }

    func embeddedTailnetProxyAdvisory(
        for route: RouteRecord,
        hostValidationReady: Bool,
        authenticationReady: Bool
    ) -> String? {
        guard route.kind == .embeddedTailnet,
              networkProxyDiagnostics.tailnetRisk,
              hostValidationReady,
              authenticationReady else {
            return nil
        }

        return "Embedded Tailscale may be blocked by a system proxy or VPN. Bypass localhost, private ranges, 100.64.0.0/10, and *.ts.net traffic before retrying."
    }

    private func connectionClientInfo() -> CodexRPCClientInfo {
        CodexRPCClientInfo(
            name: "Coding On The Go",
            version: "0.1"
        )
    }

    private func connectionCodexHome() -> String? {
        configuredTestCodexHome(from: ProcessInfo.processInfo.environment)
    }

    private func configuredTestCodexHome(from environment: [String: String]) -> String? {
        guard let value = environment["COTG_TEST_CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func resolvedSSHBootstrapEndpoint(
        for route: RouteRecord,
        environment: [String: String]
    ) -> SSHBootstrapEndpoint? {
        SSHBootstrapEndpointResolver.resolve(
            route: route,
            dialPlan: matchingTailnetDialPlan(for: route),
            environment: environment
        )
    }

    func resolvedSSHProxyConfiguration(for route: RouteRecord) -> SSHProxyConfiguration? {
        SSHProxyConfigurationResolver.resolve(
            route: route,
            dialPlan: matchingTailnetDialPlan(for: route)
        )
    }

    private func matchingTailnetDialPlan(for route: RouteRecord) -> EmbeddedTailnetDialPlan? {
        guard let plan = embeddedTailnetDialPlan,
              plan.routeKind == route.kind else {
            return nil
        }

        if let routeProfileID = route.tailnetProfileID {
            return plan.profileID == routeProfileID ? plan : nil
        }

        return plan
    }

    private func scanningAuthentication(for machine: MachineRecord) async -> SSHAuthenticationMaterial {
        if let configured = await configuredSSHAuthenticationMaterial(for: machine) {
            return configured
        }

        return .password("cotg-host-key-scan")
    }

    private func scanningConfiguration(
        for machine: MachineRecord,
        route: RouteRecord
    ) async throws -> CodexSSHConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = resolvedSSHBootstrapEndpoint(for: route, environment: environment) else {
            throw CodexSSHError.invalidRequest("No SSH host is configured for \(route.label).")
        }
        guard let username = sshUsername(for: machine, route: route) else {
            throw CodexSSHError.invalidRequest(
                missingSSHUsernameGuidance(for: route, action: "scan the host key")
            )
        }

        return CodexSSHConfiguration(
            host: endpoint.host,
            port: endpoint.port,
            proxy: resolvedSSHProxyConfiguration(for: route),
            username: username,
            authentication: await scanningAuthentication(for: machine),
            hostValidation: .capturePresentedHostKey,
            cwd: connectionBootstrapWorkspaceRoot(),
            codexHome: connectionCodexHome(),
            clientInfo: connectionClientInfo()
        )
    }

    private func recordScannedHostKey(
        _ scannedKey: String,
        routeID: RouteRecord.ID,
        machineID: MachineRecord.ID
    ) {
        pendingScannedHostKey = scannedKey
        pendingScannedHostKeyRouteID = routeID
        pendingScannedHostKeyFingerprint = Self.hostKeyFingerprint(scannedKey)

        updateRoute(routeID: routeID, machineID: machineID) { route in
            route.lastCheckedAt = .now
            if let trustedKey = route.trustedOpenSSHPublicKey, trustedKey != scannedKey {
                route.trustState = .mismatch
            } else if route.trustedOpenSSHPublicKey == scannedKey {
                route.trustState = .trusted
            } else {
                route.trustState = .unknown
            }
        }
        updateMachineFingerprint(machineID: machineID)
        persistStateAsync()
    }

    func acceptTrustedHostKey(
        _ scannedHostKey: String,
        routeID: RouteRecord.ID,
        machineID: MachineRecord.ID
    ) {
        updateRoute(routeID: routeID, machineID: machineID) { updatedRoute in
            updatedRoute.trustState = .trusted
            updatedRoute.trustedOpenSSHPublicKey = scannedHostKey
            updatedRoute.lastCheckedAt = .now
        }
        updateMachineFingerprint(machineID: machineID)
        if pendingScannedHostKeyRouteID == routeID {
            pendingScannedHostKey = nil
            pendingScannedHostKeyRouteID = nil
            pendingScannedHostKeyFingerprint = nil
        }
        persistStateAsync()
    }

    func markRouteConnectionFailure(
        routeID: RouteRecord.ID,
        machineID: MachineRecord.ID,
        reason: String
    ) {
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              let routeIndex = machines[machineIndex].routes.firstIndex(where: { $0.id == routeID }) else {
            return
        }

        machines[machineIndex].routes[routeIndex].health = .degraded
        machines[machineIndex].routes[routeIndex].lastCheckedAt = .now
        machines[machineIndex].routes[routeIndex].lastFailureAt = .now
        machines[machineIndex].routes[routeIndex].failureReasonCode = routeFailureReasonCode(for: reason)

        if machines[machineIndex].preferredRouteID == routeID,
           !machines[machineIndex].routes[routeIndex].isEligibleForTraffic {
            machines[machineIndex].preferredRouteID = machines[machineIndex].preferredRoute?.id
        }

        persistStateAsync()
    }

    private func routeFailureReasonCode(for reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("host key mismatch") {
            return "ssh-host-key-mismatch"
        }
        if normalized.contains("local network") {
            return "ssh-local-network-blocked"
        }
        if normalized.contains("authenticationerror")
            || normalized.contains("endedchannel")
            || normalized.contains("handshake") {
            return "ssh-handshake-ended"
        }
        return "ssh-connect-failed"
    }

    private func scanHostKey(
        for machine: MachineRecord,
        route: RouteRecord
    ) async throws -> String {
        let configuration = try await scanningConfiguration(for: machine, route: route)

        for attempt in 1...3 {
            let scanner = CodexSSHAppServerClient()
            defer {
                Task {
                    await scanner.disconnect()
                }
            }

            do {
                try await scanner.connect(configuration: configuration, onEvent: { _ in })
                throw CodexSSHError.invalidResponse(
                    "Host-key scan unexpectedly completed without surfacing a host key for \(route.label)."
                )
            } catch let CodexSSHError.capturedHostKey(received) {
                return received
            } catch let CodexSSHError.hostKeyMismatch(_, received) {
                return received
            } catch {
                guard route.kind == .embeddedTailnet,
                      shouldRetryEmbeddedTailnetConnection(after: error),
                      attempt < 3 else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        throw CodexSSHError.invalidResponse("Host-key scan exhausted all retry attempts for \(route.label).")
    }

    private static func hostKeyFingerprint(_ openSSHPublicKey: String) -> String? {
        let components = openSSHPublicKey.split(whereSeparator: \.isWhitespace)
        let payload = components.count >= 2 ? String(components[1]) : openSSHPublicKey
        let fingerprintData = Data(base64Encoded: payload) ?? Data(openSSHPublicKey.utf8)
        let digest = Data(SHA256.hash(data: fingerprintData))
        return "SHA256:\(digest.base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }

    private func sendTurnRequest(_ request: PendingTurnRequest) {
        if isDemoModeEnabled {
            sendDemoTurnRequest(request)
            return
        }

        let queuedRequests: [PendingTurnRequest]
        if let plan = plannedClientSubagentRequests(for: request) {
            clientSubagentTasks = plan.tasks
            activeClientSubagentTaskID = nil
            refreshClientSubagentSummary()
            transcript.append(Self.userTranscriptMessage(for: request))
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Queued \(plan.requests.count) client-orchestrated subtasks from the supplied bullet list. They will run serially on this transport."
                )
            )
            queuedRequests = plan.requests
        } else {
            resetClientSubagentPlan()
            queuedRequests = [request]
        }

        pinVisibleTranscriptToActiveThreadIfPossible()

        prepareHostBackedSessionForConnectedSendIfPossible()

        if case .connected = connectionState,
           activeSession?.threadID != nil || activeSession?.workspaceRoot != nil {
            if activeTurnID != nil {
                let visibleQueuedRequests = queuedRequests.map {
                    appendOrUpdateLocalUserTranscriptMessage(for: $0, deliveryState: .queued)
                }
                enqueuePendingTurnRequests(visibleQueuedRequests)
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: queuedRequests.count == 1
                            ? "Queued behind the active live turn."
                            : "Queued \(queuedRequests.count) turns behind the active live turn."
                    )
                )
            } else {
                if let first = queuedRequests.first {
                    if queuedRequests.count > 1 {
                        let trailingQueuedRequests = Array(queuedRequests.dropFirst()).map {
                            appendOrUpdateLocalUserTranscriptMessage(for: $0, deliveryState: .queued)
                        }
                        enqueuePendingTurnRequests(trailingQueuedRequests)
                    }
                    let visibleFirstRequest = appendOrUpdateLocalUserTranscriptMessage(
                        for: first,
                        deliveryState: .sending
                    )
                    beginLiveTurn(request: visibleFirstRequest, preferredThreadID: activeSession?.threadID)
                }
            }
        } else if shouldQueuePendingTurnRequestsWhileReconnecting {
            activeTurnID = nil
            finishAllLiveActivityMessages()
            let visibleQueuedRequests = queuedRequests.map {
                appendOrUpdateLocalUserTranscriptMessage(for: $0, deliveryState: .queued)
            }
            enqueuePendingTurnRequests(visibleQueuedRequests)
            if case .connecting = connectionState {
                restartStaleConnectingSessionIfNeeded(reason: "Restarting stalled host reconnect before sending.")
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: queuedRequests.count == 1
                            ? "Waiting for the selected route to reconnect before sending."
                            : "Queued \(queuedRequests.count) turns while the selected route reconnects."
                    )
                )
            } else {
                transcript.append(
                    SessionMessage(
                        role: .system,
                        text: queuedRequests.count == 1
                            ? "Reconnecting to continue this thread before sending."
                            : "Queued \(queuedRequests.count) turns and started reconnecting to continue this thread."
                    )
                )
                connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
            }
        } else {
            _ = appendOrUpdateLocalUserTranscriptMessage(for: request, deliveryState: .failed)
            transcript.append(
                SessionMessage(
                    role: .assistant,
                    text: "Connect to a saved route before sending a prompt."
                )
            )
        }
    }

    private func pinVisibleTranscriptToActiveThreadIfPossible() {
        guard displayedTranscriptThreadID == nil,
              !transcript.isEmpty,
              let activeThreadID = activeSession?.threadID else {
            return
        }

        displayedTranscriptThreadID = activeThreadID
        isRestoringActiveTranscript = false
    }

    private func appendOrUpdateLocalUserTranscriptMessage(
        for request: PendingTurnRequest,
        deliveryState: SessionMessage.DeliveryState
    ) -> PendingTurnRequest {
        guard request.showsAsUserMessage else {
            return request
        }

        var updatedRequest = request
        if let messageID = updatedRequest.transcriptMessageID {
            updateTranscriptMessageDeliveryState(messageID: messageID, to: deliveryState)
            return updatedRequest
        }

        // Keep the local transcript honest until the host-backed turn actually starts.
        let message = Self.userTranscriptMessage(for: updatedRequest, deliveryState: deliveryState)
        updatedRequest.transcriptMessageID = message.id
        transcript.append(message)
        pinVisibleTranscriptToActiveThreadIfPossible()
        return updatedRequest
    }

    private func updateTranscriptMessageDeliveryState(
        messageID: UUID?,
        to deliveryState: SessionMessage.DeliveryState?
    ) {
        guard let messageID,
              let messageIndex = transcript.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        transcript[messageIndex].deliveryState = deliveryState
    }

    private func prepareHostBackedSessionForConnectedSendIfPossible() {
        guard case .connected = connectionState,
              let machineID = selectedMachineID,
              activeSession?.threadID == nil,
              Self.normalizedWorkspaceRoot(activeSession?.workspaceRoot) == nil else {
            return
        }

        let bootstrapWorkspaceRoot = connectionBootstrapWorkspaceRoot()
        guard bootstrapWorkspaceRoot != "." else {
            return
        }

        _ = prepareNewSession(
            machineID: machineID,
            workspaceRoot: bootstrapWorkspaceRoot,
            reconnect: false
        )
    }

    private var shouldQueuePendingTurnRequestsWhileReconnecting: Bool {
        guard activeSession != nil, selectedMachine != nil else {
            return false
        }

        if case .connected = connectionState {
            return false
        }

        return true
    }

    @discardableResult
    private func restartStaleConnectingSessionIfNeeded(reason: String) -> Bool {
        guard case .connecting = connectionState else {
            return false
        }
        guard Self.shouldRestartStaleConnectingSession(
            activeTurnID: activeTurnID,
            connectionTaskActive: connectionTask != nil,
            connectionAttemptStartedAt: connectionAttemptStartedAt,
            now: Date()
        ) else {
            return false
        }
        guard activeSession?.threadID != nil || activeSession?.workspaceRoot != nil else {
            return false
        }

        connectionTask?.cancel()
        connectionTask = nil
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        connectionAttemptStartedAt = nil
        activeTurnID = nil
        finishAllLiveActivityMessages()
        isRestoringActiveTranscript = false
        connectionState = .disconnected
        updateSessionState(transportState: .disconnected, lastErrorSummary: reason)
        transcript.append(SessionMessage(role: .system, text: reason))
        connectSelectedMachine(preferLoopbackUpgrade: shouldAutoUpgradeLoopback)
        return true
    }

    static func shouldRestartStaleConnectingSession(
        activeTurnID: String?,
        connectionTaskActive: Bool,
        connectionAttemptStartedAt: Date?,
        now: Date,
        timeout: TimeInterval = 90
    ) -> Bool {
        guard activeTurnID == nil else {
            return false
        }
        guard connectionTaskActive else {
            return true
        }
        guard let connectionAttemptStartedAt else {
            return true
        }
        return now.timeIntervalSince(connectionAttemptStartedAt) >= timeout
    }

    private func enqueuePendingTurnRequests(_ requests: [PendingTurnRequest]) {
        guard !requests.isEmpty else {
            return
        }

        pendingTurnRequests.append(contentsOf: requests)
        pendingPrompts.append(contentsOf: requests.map(\.summary))
        updateSessionQueue()
    }

    private func beginPendingTurnRequestAfterReconnectIfPossible() {
        rebuildPendingTurnRequestsFromPersistedQueueIfNeeded()
        guard case .connected = connectionState,
              activeTurnID == nil,
              !activeSessionRequiresExplicitThreadSelection,
              resolveThreadID(preferredThreadID: nil) != nil || activeSession?.workspaceRoot != nil,
              let nextRequest = dequeuePendingTurn() else {
            return
        }

        updateSessionQueue()
        beginLiveTurn(request: nextRequest)
    }

    private func rebuildPendingTurnRequestsFromPersistedQueueIfNeeded() {
        guard pendingTurnRequests.isEmpty else {
            return
        }

        let queuedSummaries = pendingPrompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !queuedSummaries.isEmpty else {
            return
        }

        let modelOverride = activeThreadModelLabel
        pendingTurnRequests = queuedSummaries.map { summary in
            PendingTurnRequest(
                text: summary,
                attachments: [],
                summary: summary,
                model: modelOverride,
                effort: selectedReasoningEffort,
                collaborationMode: collaborationModePayload(modelOverride: modelOverride)
            )
        }
    }

    private func turnInput(for request: PendingTurnRequest) async throws -> [CodexUserInput] {
        var input: [CodexUserInput] = []
        if let text = request.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input.append(.text(text))
        }

        for attachment in request.attachments {
            switch attachment.kind {
            case .photo:
                guard let payload = attachment.payload else {
                    input.append(.text("Photo attachment selected: \(attachment.displayName)"))
                    continue
                }
                guard activeProtocolKind != .directEndpoint else {
                    input.append(
                        .text(
                            "Photo attachment selected: \(attachment.displayName). Reconnect over an SSH-backed lane to stage image files."
                        )
                    )
                    continue
                }
                let staged = try await safeLaneClient.stageAttachment(
                    data: payload,
                    suggestedFilename: attachment.suggestedFilename ?? attachment.displayName
                )
                input.append(.localImage(path: staged.remotePath))
            case .voiceMemo:
                let description = attachment.displayName.isEmpty ? "Voice memo attachment" : attachment.displayName
                input.append(.text("Voice memo attached: \(description)"))
            }
        }

        if input.isEmpty {
            throw CodexSSHError.invalidRequest("No turn input is available.")
        }
        return input
    }

    private static func userTranscriptMessage(for request: PendingTurnRequest) -> SessionMessage {
        userTranscriptMessage(for: request, deliveryState: nil)
    }

    private static func userTranscriptMessage(
        for request: PendingTurnRequest,
        deliveryState: SessionMessage.DeliveryState?
    ) -> SessionMessage {
        let normalizedText = request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayText: String
        if !normalizedText.isEmpty {
            displayText = normalizedText
        } else if request.attachments.count == 1 {
            displayText = "Shared 1 attachment."
        } else if !request.attachments.isEmpty {
            displayText = "Shared \(request.attachments.count) attachments."
        } else {
            displayText = request.summary
        }

        return SessionMessage(
            role: .user,
            text: displayText,
            attachments: request.attachments.map(SessionMessageAttachment.init(composerAttachment:)),
            deliveryState: deliveryState
        )
    }

    private func dequeuePendingTurn() -> PendingTurnRequest? {
        guard !pendingTurnRequests.isEmpty else {
            return nil
        }
        let request = pendingTurnRequests.removeFirst()
        if !pendingPrompts.isEmpty {
            pendingPrompts.removeFirst()
        }
        return request
    }

    private func plannedClientSubagentRequests(
        for request: PendingTurnRequest
    ) -> (tasks: [ClientSubagentTask], requests: [PendingTurnRequest])? {
        guard selectedParallelAgentMode == .clientOrchestrated,
              let text = request.text,
              let plan = ClientOrchestratedSubagentPlanner.makePlan(from: text) else {
            return nil
        }

        let requests = plan.tasks.enumerated().map { index, task in
            PendingTurnRequest(
                text: task.prompt,
                attachments: index == 0 ? request.attachments : [],
                summary: "[Subtask \(task.ordinal)/\(plan.tasks.count)] \(task.title)",
                model: request.model,
                effort: request.effort,
                collaborationMode: request.collaborationMode,
                showsAsUserMessage: false,
                clientSubagentTaskID: task.id
            )
        }

        return (plan.tasks, requests)
    }

    private func markClientSubagentTask(
        _ taskID: UUID?,
        as status: ClientSubagentTaskStatus,
        resultSummary: String? = nil
    ) {
        guard let taskID,
              let index = clientSubagentTasks.firstIndex(where: { $0.id == taskID }) else {
            if status == .completed || status == .failed {
                activeClientSubagentTaskID = nil
            }
            return
        }

        clientSubagentTasks[index].status = status
        if let resultSummary, !resultSummary.isEmpty {
            clientSubagentTasks[index].resultSummary = resultSummary
        }

        activeClientSubagentTaskID = status == .running ? taskID : nil
        refreshClientSubagentSummary()
    }

    private func refreshClientSubagentSummary() {
        if let summary = ClientOrchestratedSubagentPlanner.summary(for: clientSubagentTasks) {
            subagentActivitySummary = summary
        } else if activeTurnID == nil {
            subagentActivitySummary = nil
        }
    }

    private func resetClientSubagentPlan() {
        clientSubagentTasks = []
        activeClientSubagentTaskID = nil
        if activeTurnID == nil {
            subagentActivitySummary = nil
        }
    }

    private func summaryText(for draft: String, attachments: [ComposerAttachment]) -> String {
        let attachmentSummary = attachments
            .map(\.displayName)
            .joined(separator: ", ")

        switch (draft.isEmpty, attachmentSummary.isEmpty) {
        case (false, false):
            return "\(draft)\n\nAttachments: \(attachmentSummary)"
        case (false, true):
            return draft
        case (true, false):
            return "Attachments: \(attachmentSummary)"
        case (true, true):
            return ""
        }
    }

    private func refreshComposerCapabilities() {
        guard let machine = selectedMachine else {
            return
        }

        let selectedDescriptor = availableModels.first { $0.model == selectedModel }
        composerState.voiceInputAvailability = machine.capabilities.supportsVoiceInput ? .available : .unavailable
        composerState.canAttachPhotos = machine.capabilities.supportsAttachments
            && (selectedDescriptor?.supportsImageInputs ?? true)
    }

    private static func shouldLaunchInDemoMode() -> Bool {
        AppDemoModeController(
            environment: ProcessInfo.processInfo.environment
        ).shouldLaunchInDemoMode()
    }

    private static func setStoredDemoModeEnabled(_ enabled: Bool) {
        AppDemoModeController(
            environment: ProcessInfo.processInfo.environment
        ).setStoredDemoModeEnabled(enabled)
    }

    private func applyDemoModeScenario(_ scenario: AppDemoScenario, restoreSelection: Bool) {
        demoScenario = scenario
        machines = scenario.snapshot.machines
        tailnetProfiles = scenario.snapshot.tailnetProfiles
        hostThreadCatalog = Self.deduplicatedHostThreadCatalog(
            scenario.snapshot.hostThreadCatalog.sorted(by: { $0.updatedAt > $1.updatedAt })
        )
        recentSessions = scenario.snapshot.recentSessions.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt })
        selectedMachineID = if restoreSelection,
                               let selectedMachineID,
                               machines.contains(where: { $0.id == selectedMachineID }) {
            selectedMachineID
        } else {
            scenario.snapshot.preferences.preferredMachineID ?? machines.first?.id
        }
        syncSnapshot = scenario.syncSnapshot
        connectionState = .connected("Reviewer demo mode")
        activeProtocolKind = scenario.snapshot.preferences.preferredProtocol ?? .stdio
        privacyMode = scenario.snapshot.preferences.privacyMode
        selectedModel = activeSession?.lastModel
            ?? scenario.availableModels.first(where: \.isDefault)?.model
            ?? scenario.availableModels.first?.model
        availableModels = scenario.availableModels
        selectedParallelAgentMode = .off
        selectedReasoningEffort = CodexReasoningEffort(
            rawValue: scenario.snapshot.preferences.preferredReasoningEffort ?? ""
        ) ?? selectedModelDescriptor?.defaultReasoningEffort ?? .medium
        preferredApprovalPolicy = scenario.snapshot.preferences.preferredApprovalPolicy
        preferredSandboxMode = scenario.snapshot.preferences.preferredSandboxMode.flatMap(CodexSandboxMode.init(rawValue:))
        selectedCollaborationMode = .default
        pendingPrompts = activeSession?.queuedPrompts ?? []
        workspaceSummary = demoWorkspaceSummary(for: activeSession)
        workspaceFailureSummary = nil
        worktrees = []
        revertPreview = nil
        runtimeCapabilityDiagnostics = baseCapabilityDiagnostics
        externalTailnetAppInstalled = false
        embeddedTailnetStatus = Self.provisionalTailnetStatus(for: nil)
        pendingTailnetAuthTicket = nil
        localNetworkScanStatus = .idle
        nearbyDiscoveryResults = []
        localNetworkDiscoveryDebugLabel = "status=demo;machines=\(machines.count);selected=\(selectedMachine?.alias ?? "none");proxyRisk=false"
        hostThreadCatalogErrorSummary = nil
        hostThreadCatalogDebugSummary = nil
        isRefreshingHostThreadCatalog = false
        lastHostThreadCatalogRefreshAt = .now
        activeTurnID = nil
        threadActivityFlags = []
        subagentActivitySummary = nil
        pendingApprovalRequest = nil
        pendingTurnRequests.removeAll()
        syncKnownThreadIDs(threadID: activeSession?.threadID, replaceAll: true)
        composerState = ComposerFeatureState(
            draft: scenario.recommendedComposerDraft,
            attachments: [],
            canAttachPhotos: true,
            voiceInputAvailability: .available
        )
        refreshComposerCapabilities()
        applyDemoSessionPresentation(for: activeSession)
    }

    private func activateDemoConnection() {
        guard isDemoModeEnabled else {
            return
        }
        if selectedMachineID == nil {
            selectedMachineID = demoScenario?.snapshot.preferences.preferredMachineID ?? machines.first?.id
        }
        connectionState = .connected("Reviewer demo mode")
        activeProtocolKind = .stdio
        updateSessionState(transportState: .connected, lastErrorSummary: nil)
        applyDemoSessionPresentation(for: activeSession)
        if transcript.isEmpty {
            transcript.append(
                SessionMessage(
                    role: .system,
                    text: "Reviewer demo mode is ready. Browse a project, open a thread, and send from the composer without using a live Mac."
                )
            )
        }
    }

    private func applyDemoSessionPresentation(for session: SessionRecord?) {
        activeSessionID = session?.id
        pendingApprovalRequest = nil
        activeTurnID = nil
        threadActivityFlags = []
        subagentActivitySummary = nil
        isRestoringActiveTranscript = false
        connectionState = .connected("Reviewer demo mode")
        activeProtocolKind = session?.lastKnownProtocol ?? .stdio
        syncKnownThreadIDs(threadID: session?.threadID, replaceAll: true)
        workspaceSummary = demoWorkspaceSummary(for: session)
        workspaceFailureSummary = nil
        if let threadID = session?.threadID,
           let state = demoScenario?.threadStatesByID[threadID] {
            transcript = state.transcript
            displayedTranscriptThreadID = threadID
        } else {
            transcript = [
                SessionMessage(
                    role: .system,
                    text: session?.workspaceRoot.map { "Demo thread ready in \($0)." }
                        ?? "Reviewer demo mode is ready. Start typing to create a demo thread."
                )
            ]
            displayedTranscriptThreadID = nil
        }
        composerState.draft = ""
        composerState.attachments.removeAll()
        refreshComposerCapabilities()
    }

    private func beginRestoringActiveTranscript(for threadID: String?) {
        guard !isDemoModeEnabled else {
            isRestoringActiveTranscript = false
            return
        }

        if let threadID,
           let displayedTranscriptThreadID,
           displayedTranscriptThreadID != threadID {
            transcript = []
            hiddenTranscriptMessageCount = 0
            activeTranscriptSnapshot = nil
            revealedEarlierTranscriptMessageCount = 0
        }

        isRestoringActiveTranscript = threadID != nil
    }

    private func demoWorkspaceSummary(for session: SessionRecord?) -> GitWorkspaceSummary? {
        guard let threadID = session?.threadID else {
            return nil
        }
        return demoScenario?.threadStatesByID[threadID]?.workspaceSummary
    }

    private func sendDemoTurnRequest(_ request: PendingTurnRequest) {
        guard isDemoModeEnabled else {
            return
        }
        guard let machine = selectedMachine ?? machines.first else {
            transcript.append(SessionMessage(role: .system, text: "Reviewer demo mode could not find the bundled demo Mac."))
            return
        }

        if selectedMachineID == nil {
            selectedMachineID = machine.id
        }

        if activeSession == nil {
            _ = prepareNewSession(
                machineID: machine.id,
                workspaceRoot: demoScenario?.snapshot.hostThreadCatalog.first?.workspaceRoot,
                reconnect: false
            )
        }

        let sessionIndex = activeSessionIndex(for: machine)
        if recentSessions[sessionIndex].threadID == nil {
            let newThreadID = "demo-thread-\(UUID().uuidString.lowercased())"
            let workspaceRoot = Self.normalizedWorkspaceRoot(
                recentSessions[sessionIndex].workspaceRoot
                    ?? demoScenario?.snapshot.hostThreadCatalog.first?.workspaceRoot
                    ?? "/workspace/coding-on-the-go"
            )!
            let now = Date.now
            let state = AppDemoThreadState(
                entry: HostThreadCatalogEntry(
                    id: newThreadID,
                    machineID: machine.id,
                    workspaceRoot: workspaceRoot,
                    name: "New demo thread",
                    preview: "A reviewer-created demo thread.",
                    modelProvider: selectedModel ?? "openai",
                    createdAt: now,
                    updatedAt: now
                ),
                transcript: [
                    SessionMessage(role: .system, text: "Prepared a new demo thread in \(workspaceRoot).")
                ],
                workspaceSummary: GitWorkspaceSummary(branch: "main", upstream: "origin/main")
            )
            recentSessions[sessionIndex].threadID = newThreadID
            recentSessions[sessionIndex].workspaceRoot = workspaceRoot
            recentSessions[sessionIndex].lastTurn = nil
            syncKnownThreadIDs(threadID: newThreadID, replaceAll: true)
            upsertDemoThreadState(state)
        }

        let threadID = recentSessions[sessionIndex].threadID ?? "demo-thread-missing"
        var state = demoScenario?.threadStatesByID[threadID]
            ?? AppDemoThreadState(
                entry: HostThreadCatalogEntry(
                    id: threadID,
                    machineID: machine.id,
                    workspaceRoot: recentSessions[sessionIndex].workspaceRoot ?? "/workspace/coding-on-the-go",
                    name: "Demo thread",
                    preview: request.summary,
                    modelProvider: selectedModel ?? "openai",
                    createdAt: .now,
                    updatedAt: .now
                ),
                transcript: [],
                workspaceSummary: GitWorkspaceSummary(branch: "main", upstream: "origin/main")
            )

        if request.showsAsUserMessage {
            state.transcript.append(Self.userTranscriptMessage(for: request))
        }
        let reply = demoAssistantReply(for: request, threadID: threadID, workspaceRoot: state.entry.workspaceRoot)
        state.transcript.append(SessionMessage(role: .assistant, text: reply))
        state.entry.preview = reply
        state.entry.modelProvider = selectedModel ?? state.entry.modelProvider
        state.entry.updatedAt = .now
        upsertDemoThreadState(state)

        recentSessions[sessionIndex].sceneID = sceneID
        recentSessions[sessionIndex].lastModel = selectedModel
        recentSessions[sessionIndex].lastKnownProtocol = .stdio
        recentSessions[sessionIndex].lastKnownRouteKind = .manualSSH
        recentSessions[sessionIndex].lastKnownBootstrap = .standardSSH
        recentSessions[sessionIndex].transportState = .connected
        recentSessions[sessionIndex].lastOpenedAt = state.entry.updatedAt
        recentSessions[sessionIndex].lastTurnID = "demo-turn-\(UUID().uuidString.lowercased())"
        recentSessions[sessionIndex].lastTurn = RecentTurnMetadata(
            turnID: recentSessions[sessionIndex].lastTurnID ?? "demo-turn",
            summary: reply,
            completedAt: state.entry.updatedAt
        )
        pendingPrompts.removeAll()
        composerState.attachments.removeAll()
        transcript = state.transcript
        workspaceSummary = state.workspaceSummary
        workspaceFailureSummary = nil
        connectionState = .connected("Reviewer demo mode")
        activeProtocolKind = .stdio
        refreshComposerCapabilities()
    }

    private func upsertDemoThreadState(_ state: AppDemoThreadState) {
        guard var scenario = demoScenario else {
            return
        }

        scenario.threadStatesByID[state.entry.id] = state
        if let index = scenario.snapshot.hostThreadCatalog.firstIndex(where: { $0.id == state.entry.id }) {
            scenario.snapshot.hostThreadCatalog[index] = state.entry
        } else {
            scenario.snapshot.hostThreadCatalog.append(state.entry)
        }
        scenario.snapshot.hostThreadCatalog.sort(by: { $0.updatedAt > $1.updatedAt })
        scenario.snapshot.recentSessions = recentSessions
        demoScenario = scenario
        hostThreadCatalog = Self.deduplicatedHostThreadCatalog(scenario.snapshot.hostThreadCatalog)
    }

    private func demoAssistantReply(
        for request: PendingTurnRequest,
        threadID: String,
        workspaceRoot: String
    ) -> String {
        AppDemoModeController.assistantReply(
            promptSummary: request.summary,
            attachmentCount: request.attachments.count,
            threadID: threadID,
            workspaceRoot: workspaceRoot
        )
    }

    private func resumeSafeLaneThreadIfPossible(
        options: CodexThreadExecutionOptions
    ) async throws -> ResolvedThreadBindingContext? {
        let threadID = Self.resumableThreadID(
            boundProtocolThreadID: stdioThreadID,
            activeSessionThreadID: activeSession?.threadID,
            requiresExplicitThreadSelection: activeSessionRequiresExplicitThreadSelection
        )
        guard let threadID else {
            return nil
        }

        do {
            return try await resumeThreadWithSnapshotFallback(
                threadID: threadID,
                options: options,
                protocolKind: .stdio
            )
        } catch {
            if shouldTreatResumeErrorAsUnavailableSelectedThread(error) {
                recoverFromUnavailableSelectedThread()
                return nil
            }
            throw error
        }
    }

    private func resumeDirectEndpointThreadIfPossible(
        options: CodexThreadExecutionOptions
    ) async throws -> ResolvedThreadBindingContext? {
        guard let threadID = Self.resumableThreadID(
            boundProtocolThreadID: nil,
            activeSessionThreadID: activeSession?.threadID,
            requiresExplicitThreadSelection: activeSessionRequiresExplicitThreadSelection
        ) else {
            return nil
        }

        do {
            return try await resumeThreadWithSnapshotFallback(
                threadID: threadID,
                options: options,
                protocolKind: .directEndpoint
            )
        } catch {
            if shouldTreatResumeErrorAsUnavailableSelectedThread(error) {
                recoverFromUnavailableSelectedThread()
                return nil
            }
            throw error
        }
    }

    private func resumeLoopbackThreadIfPossible(
        options: CodexThreadExecutionOptions
    ) async throws -> ResolvedThreadBindingContext? {
        guard let threadID = Self.resumableThreadID(
            boundProtocolThreadID: stdioThreadID,
            activeSessionThreadID: activeSession?.threadID,
            requiresExplicitThreadSelection: activeSessionRequiresExplicitThreadSelection
        ) else {
            return nil
        }

        do {
            return try await resumeThreadWithSnapshotFallback(
                threadID: threadID,
                options: options,
                protocolKind: .websocket
            )
        } catch {
            if shouldTreatResumeErrorAsUnavailableSelectedThread(error) {
                recoverFromUnavailableSelectedThread()
                return nil
            }
            throw error
        }
    }

    static func resumableThreadID(
        boundProtocolThreadID: String?,
        activeSessionThreadID: String?,
        requiresExplicitThreadSelection: Bool
    ) -> String? {
        if requiresExplicitThreadSelection {
            return nil
        }

        if let activeSessionThreadID = normalizedThreadID(activeSessionThreadID) {
            return activeSessionThreadID
        }

        return normalizedThreadID(boundProtocolThreadID)
    }

    static func safeLaneFallbackThreadID(
        activeSessionThreadID: String?,
        stdioThreadID: String?
    ) -> String? {
        normalizedThreadID(activeSessionThreadID) ?? normalizedThreadID(stdioThreadID)
    }

    static func turnStartThreadID(
        preferredThreadID: String?,
        boundProtocolThreadID: String?,
        activeSessionThreadID: String?,
        initialThreadID: String
    ) -> String {
        normalizedThreadID(preferredThreadID)
            ?? normalizedThreadID(activeSessionThreadID)
            ?? normalizedThreadID(boundProtocolThreadID)
            ?? initialThreadID
    }

    static func shouldBindServerStartedThreadEvent(
        activeSessionThreadID: String?,
        existingProtocolThreadID: String?
    ) -> Bool {
        normalizedThreadID(activeSessionThreadID) == nil
            && normalizedThreadID(existingProtocolThreadID) == nil
    }

    private static func normalizedThreadID(_ threadID: String?) -> String? {
        guard let threadID = threadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty else {
            return nil
        }

        return threadID
    }

    private static func normalizedModelIdentifier(_ model: String?) -> String? {
        guard let model = model?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            return nil
        }

        switch model.lowercased() {
        case "openai", "unknown":
            return nil
        default:
            return model
        }
    }

    private func shouldTreatResumeErrorAsMissingThread(_ error: Error) -> Bool {
        let detail = error.localizedDescription.lowercased()
        return detail.contains("no rollout found for thread id")
            || detail.contains("thread not found")
            || detail.contains("no thread found")
            || detail.contains("invalid thread id")
    }

    private func shouldTreatResumeErrorAsUnavailableSelectedThread(_ error: Error) -> Bool {
        if shouldTreatResumeErrorAsMissingThread(error) {
            return true
        }

        let detail = error.localizedDescription.lowercased()
        return detail.contains("requested thread resume could not resume the requested thread")
            || detail.contains("requested thread resume resumed a different thread")
            || detail.contains("loopback websocket could not resume the active thread")
            || detail.contains("loopback websocket resumed a different thread")
    }

    private func recoverFromUnavailableSelectedThread() {
        guard let machine = selectedMachine else {
            return
        }

        let index = activeSessionIndex(for: machine)
        let unavailableThreadID = recentSessions[index].threadID
        recentSessions[index].threadID = nil
        recentSessions[index].unavailableSelectedThreadID = unavailableThreadID
        recentSessions[index].transportState = .disconnected
        recentSessions[index].lastErrorSummary = UnavailableSelectedThreadError.message(for: unavailableThreadID)
        if let unavailableThreadID {
            hostThreadCatalog.removeAll {
                $0.machineID == machine.id && $0.id == unavailableThreadID
            }
        }
        syncKnownThreadIDs(threadID: nil, replaceAll: true)
        applyLiveThreadSnapshot(nil)
        persistStateSynchronouslyForLifecycle()
        persistStateAsync()
    }

    struct TranscriptPresentation {
        let messages: [SessionMessage]
        let hiddenMessageCount: Int
        let totalMessageCount: Int

        var hasEarlierHistory: Bool { hiddenMessageCount > 0 }
    }

    private static let recentTranscriptMessageLimit = 6
    private static let transcriptHistoryRevealStep = 6

    static func sessionMessages(from snapshot: CodexThreadSnapshot, recentLimit: Int? = nil) -> [SessionMessage] {
        if let recentLimit, recentLimit > 0 {
            return recentTranscriptPresentation(from: snapshot, recentLimit: recentLimit).messages
        }

        var messages: [SessionMessage] = []

        for turn in snapshot.turns {
            var previousAssistantPhase: CodexThreadMessagePhase?

            for item in turn.items {
                switch item {
                case let .userMessage(text):
                    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    messages.append(SessionMessage(role: .user, text: normalized))
                    previousAssistantPhase = nil
                case let .assistantMessage(text, phase):
                    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    let isStreaming = turn.isInProgress
                    let kind: SessionMessage.Kind = if phase == .commentary {
                        .commentary
                    } else {
                        .standard
                    }
                    if let lastIndex = messages.indices.last,
                       messages[lastIndex].role == .assistant,
                       messages[lastIndex].isStreaming == isStreaming,
                       messages[lastIndex].kind == kind,
                       previousAssistantPhase == phase {
                        messages[lastIndex].text += normalized
                    } else {
                        messages.append(
                            SessionMessage(
                                role: .assistant,
                                kind: kind,
                                text: normalized,
                                isStreaming: isStreaming
                            )
                        )
                    }
                    previousAssistantPhase = phase
                case let .reasoning(summary):
                    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    messages.append(SessionMessage(role: .system, kind: .reasoning, text: normalized))
                    previousAssistantPhase = nil
                case let .plan(summary):
                    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    messages.append(SessionMessage(role: .system, kind: .plan, text: normalized))
                    previousAssistantPhase = nil
                case let .commandExecution(summary, status):
                    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = [normalized, normalizedStatus]
                        .filter { !$0.isEmpty }
                        .joined(separator: " • ")
                    guard !detail.isEmpty else { continue }
                    messages.append(SessionMessage(role: .system, kind: .commandExecution, text: detail))
                    previousAssistantPhase = nil
                case let .fileChange(summary, status):
                    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = [normalized, normalizedStatus]
                        .filter { !$0.isEmpty }
                        .joined(separator: " • ")
                    guard !detail.isEmpty else { continue }
                    messages.append(SessionMessage(role: .system, kind: .fileChange, text: detail))
                    previousAssistantPhase = nil
                case let .toolCall(summary):
                    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    messages.append(SessionMessage(role: .system, kind: .toolCall, text: normalized))
                    previousAssistantPhase = nil
                case let .other(summary):
                    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    guard Self.hostRuntimeTransportStatus(from: normalized) == nil else { continue }
                    messages.append(SessionMessage(role: .system, kind: .other, text: normalized))
                    previousAssistantPhase = nil
                }
            }
        }

        return messages
    }

    static func visibleSessionMessages(
        existing: [SessionMessage],
        displayedThreadID: String?,
        snapshot: CodexThreadSnapshot,
        revealedEarlierMessageCount: Int = 0
    ) -> TranscriptPresentation {
        let filteredExisting = transcriptWithoutHostRuntimeTransportNotices(existing)
        let requestedRecentLimit = recentTranscriptMessageLimit + max(0, revealedEarlierMessageCount)
        let snapshotPresentation = recentTranscriptPresentation(
            from: snapshot,
            recentLimit: max(recentTranscriptMessageLimit, requestedRecentLimit)
        )
        let isSameDisplayedThread = displayedThreadID == snapshot.id
        let shouldPreserveExistingTranscript = snapshot.activeTurnID != nil
            && isSameDisplayedThread
            && !filteredExisting.isEmpty
            && snapshotPresentation.messages.count < filteredExisting.count

        if snapshot.turns.isEmpty, isSameDisplayedThread, !filteredExisting.isEmpty {
            return TranscriptPresentation(
                messages: filteredExisting,
                hiddenMessageCount: 0,
                totalMessageCount: filteredExisting.count
            )
        }

        if shouldPreserveExistingTranscript {
            let mergedMessages = mergeRunningThreadCatchUp(
                existing: filteredExisting,
                latest: snapshotPresentation.messages
            )
            let hydratedMessages = mergeExistingMessageMetadata(
                existing: filteredExisting,
                latest: mergedMessages
            )
            return TranscriptPresentation(
                messages: hydratedMessages,
                hiddenMessageCount: max(0, snapshotPresentation.totalMessageCount - hydratedMessages.count),
                totalMessageCount: snapshotPresentation.totalMessageCount
            )
        }

        let hydratedMessages = mergeExistingMessageMetadata(
            existing: filteredExisting,
            latest: snapshotPresentation.messages
        )

        return TranscriptPresentation(
            messages: hydratedMessages,
            hiddenMessageCount: snapshotPresentation.hiddenMessageCount,
            totalMessageCount: snapshotPresentation.totalMessageCount
        )
    }

    private static func transcriptWithoutHostRuntimeTransportNotices(_ messages: [SessionMessage]) -> [SessionMessage] {
        messages.filter { message in
            !(message.role == .system && hostRuntimeTransportStatus(from: message.text) != nil)
        }
    }

    private static func recentTranscriptPresentation(
        from snapshot: CodexThreadSnapshot,
        recentLimit: Int
    ) -> TranscriptPresentation {
        let allMessages = sessionMessages(from: snapshot)
        guard recentLimit > 0 else {
            return TranscriptPresentation(
                messages: allMessages,
                hiddenMessageCount: 0,
                totalMessageCount: allMessages.count
            )
        }

        let visibleMessages = allMessages.count > recentLimit
            ? Array(allMessages.suffix(recentLimit))
            : allMessages

        return TranscriptPresentation(
            messages: visibleMessages,
            hiddenMessageCount: max(0, allMessages.count - visibleMessages.count),
            totalMessageCount: allMessages.count
        )
    }

    // Running-thread snapshots can temporarily report only the newest tail. Replace the
    // overlapping suffix in the visible transcript instead of dropping older visible context.
    private static func mergeRunningThreadCatchUp(
        existing: [SessionMessage],
        latest: [SessionMessage]
    ) -> [SessionMessage] {
        guard !existing.isEmpty else {
            return latest
        }
        guard !latest.isEmpty else {
            return existing
        }

        let maxOverlap = min(existing.count, latest.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let existingSuffix = existing.suffix(overlap)
            let latestPrefix = latest.prefix(overlap)
            let matches = zip(existingSuffix, latestPrefix).allSatisfy { lhs, rhs in
                sessionMessagesMatchForCatchUp(lhs, rhs)
            }
            if matches {
                return Array(existing.dropLast(overlap)) + latest
            }
        }

        return existing.count >= latest.count ? existing : latest
    }

    private static func mergeExistingMessageMetadata(
        existing: [SessionMessage],
        latest: [SessionMessage]
    ) -> [SessionMessage] {
        guard !existing.isEmpty, !latest.isEmpty else {
            return latest
        }

        var existingIndex = existing.startIndex
        return latest.map { latestMessage in
            var mergedMessage = latestMessage

            while existingIndex < existing.endIndex,
                  !sessionMessagesMatchForMetadataCarryForward(existing[existingIndex], latestMessage) {
                existingIndex = existing.index(after: existingIndex)
            }

            if existingIndex < existing.endIndex {
                let existingMessage = existing[existingIndex]
                mergedMessage.id = existingMessage.id
                mergedMessage.createdAt = existingMessage.createdAt
                if mergedMessage.deliveryState == nil {
                    mergedMessage.deliveryState = existingMessage.deliveryState
                }
                if mergedMessage.attachments.isEmpty && !existingMessage.attachments.isEmpty {
                    mergedMessage.attachments = existingMessage.attachments
                }
                existingIndex = existing.index(after: existingIndex)
            }

            return mergedMessage
        }
    }

    private static func sessionMessagesMatchForCatchUp(
        _ lhs: SessionMessage,
        _ rhs: SessionMessage
    ) -> Bool {
        guard lhs.role == rhs.role,
              lhs.kind == rhs.kind,
              lhs.structuredPrompt?.requestID == rhs.structuredPrompt?.requestID else {
            return false
        }

        if lhs.text == rhs.text {
            return true
        }

        guard lhs.role == .assistant,
              lhs.isStreaming || rhs.isStreaming else {
            return false
        }

        return lhs.text.contains(rhs.text) || rhs.text.contains(lhs.text)
    }

    private static func sessionMessagesMatchForMetadataCarryForward(
        _ lhs: SessionMessage,
        _ rhs: SessionMessage
    ) -> Bool {
        lhs.role == rhs.role
            && lhs.kind == rhs.kind
            && lhs.text == rhs.text
            && lhs.structuredPrompt?.requestID == rhs.structuredPrompt?.requestID
    }

    private func latestAssistantSummary(from snapshot: CodexThreadSnapshot) -> String? {
        for turn in snapshot.turns.reversed() {
            for item in turn.items.reversed() {
                if case let .assistantMessage(text, phase) = item, phase != .commentary {
                    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalized.isEmpty {
                        return normalized
                    }
                }
            }
        }

        return nil
    }

    private func activityFlags(from snapshot: CodexThreadSnapshot) -> [String] {
        guard case let .active(activeFlags) = snapshot.summary.status else {
            return []
        }

        return activeFlags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func subagentSummary(from snapshot: CodexThreadSnapshot) -> String? {
        let activityHints = activityFlags(from: snapshot)
        let toolCalls = snapshot.turns
            .flatMap(\.items)
            .compactMap { item -> String? in
                guard case let .toolCall(name) = item else {
                    return nil
                }
                let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized
            }
        let agentCalls = Array(
            Set(
                toolCalls.filter { tool in
                    let normalized = tool.lowercased()
                    return normalized.contains("agent")
                        || normalized.contains("spawn_agent")
                        || normalized.contains("send_input")
                        || normalized.contains("wait_agent")
                }
            )
        ).sorted()

        if !agentCalls.isEmpty {
            return "Parallel agent activity: \(agentCalls.joined(separator: ", "))"
        }

        if let hint = activityHints.first(where: { $0.lowercased().contains("agent") || $0.lowercased().contains("parallel") }) {
            return "Parallel agent activity: \(hint)"
        }

        return nil
    }

    private func sshKeyMaterial(for machine: MachineRecord?) async -> Data? {
        guard let machine else {
            return nil
        }

        if usesLocalhostTestingCredentialAutoload(for: machine) {
            guard let username = sshUsername(for: machine, route: sshBootstrapRoute(for: machine)) else {
                return nil
            }
            let testingCredential = testingCredentialReference(
                username: username
            )

            if let keyData = localhostTestKeyData() {
                if machine.credentialRef != testingCredential {
                    assignCredential(testingCredential, to: machine.id, username: testingCredential.username)
                }

                try? await secretVault.store(
                    SecretPayload(
                        reference: testingCredential,
                        value: keyData
                    )
                )

                return keyData
            }

            if let payload = try? await secretVault.load(reference: testingCredential) {
                return payload.value
            }

            return nil
        }

        if let credentialRef = machine.credentialRef,
           let payload = try? await secretVault.load(reference: credentialRef) {
            return payload.value
        }

        if let credentialRef = machine.credentialRef,
           credentialRef.kind != .sshKey {
            return nil
        }

        return nil
    }

    private func connectionFailureDetail(from error: Error) -> String {
        let detail = normalizedConnectionFailureDetail(error)
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1" else {
            return detail
        }

        return "\(detail) [\(debugConnectionContext())]"
    }

    private func normalizedConnectionFailureDetail(_ error: Error) -> String {
        if isLANPermissionOrProxyFailure(error) {
            return "The iPhone blocked this LAN SSH route before SSH started. Allow Local Network access for Coding On The Go and bypass private-network traffic in any active proxy or VPN, then retry."
        }

        if isTailnetHandshakeFailure(error) {
            switch selectedBootstrapRoute?.kind {
            case .externalTailnet:
                return "The standalone Tailscale route opened, but the iPhone never reached the Mac's SSH service. Reconnect the external Tailscale app or use the embedded route, then retry."
            case .embeddedTailnet:
                return "Embedded Tailscale opened, but the Mac never completed the SSH handshake. Refresh the embedded route and retry."
            case .none, .localLAN, .manualSSH, .companionDirect:
                break
            }
        }

        return error.localizedDescription
    }

    private func isLANPermissionOrProxyFailure(_ error: Error) -> Bool {
        guard let route = selectedBootstrapRoute,
              route.kind == .manualSSH || route.kind == .localLAN else {
            return false
        }

        let detail = error.localizedDescription.lowercased()
        return detail.contains("operation not permitted")
            || detail.contains("nioconnectionerror error 1")
    }

    private func isTailnetHandshakeFailure(_ error: Error) -> Bool {
        let detail = error.localizedDescription.lowercased()
        return detail.contains("authenticationerror error 1")
            || detail.contains("endedchannel")
    }

    private func debugConnectionContext() -> String {
        let environment = ProcessInfo.processInfo.environment
        let machine = selectedMachine
        let route = machine.flatMap(sshBootstrapRoute(for:))
        let endpoint = route.flatMap { resolvedSSHBootstrapEndpoint(for: $0, environment: environment) }
        let rawKey = localhostTestKeyData() != nil ? "yes" : "no"
        let credential = machine?.credentialRef?.keychainAccount ?? "nil"
        let routeKind = route?.kind.rawValue ?? "nil"
        let routeHost = endpoint?.host ?? route?.hostname ?? route?.ipAddress ?? route?.magicDNSName ?? "nil"
        let routePort = endpoint?.port ?? route?.sshPort ?? 0
        let proxy = route.flatMap(resolvedSSHProxyConfiguration(for:))
        let proxyHost = proxy?.host ?? "nil"
        let proxyPort = proxy?.port ?? 0
        let testHost = environment["COTG_TEST_SSH_HOST"] ?? "nil"
        let testUser = environment["COTG_TEST_SSH_USER"] ?? "nil"
        let username = machine.flatMap { sshUsername(for: $0, route: route) } ?? "nil"
        return "route=\(routeKind) host=\(routeHost):\(routePort) proxy=\(proxyHost):\(proxyPort) user=\(username) rawKey=\(rawKey) credential=\(credential) testHost=\(testHost) testUser=\(testUser)"
    }

    private func performUITestLaunchAutomation() async {
        defer { uiTestLaunchAutomationTask = nil }

        if selectedMachineID == nil, let firstMachine = machines.first {
            select(machineID: firstMachine.id)
        }

        refreshEmbeddedTailnetRuntimeStatus()
        let timeout = uiTestLaunchAutomationTimeout
        let resultFileName = uiTestLaunchAutomationResultFileName
        var automationStage = "launch_started"
        var transportCheckPassed = false
        var transportCheckDetail: String?
        var transportModelCount: Int?
        writeUITestLaunchAutomationResult(
            makeUITestLaunchAutomationResult(
                status: "started",
                detail: "Launch automation started.",
                smokeTestSucceeded: false,
                automationStage: automationStage,
                transportCheckPassed: transportCheckPassed,
                transportCheckDetail: transportCheckDetail,
                transportModelCount: transportModelCount
            ),
            fileName: resultFileName
        )

        do {
            try await prepareUITestEmbeddedTailnetIfNeeded(timeout: timeout)
            automationStage = "tailnet_prepared"
            try await waitForUITestConnectionCandidate(timeout: timeout)
            automationStage = "candidate_ready"
            connectLocalLoopback()
            automationStage = "connect_requested"
            try await waitForUITestConnectionReady(timeout: timeout)
            automationStage = "connection_ready"

            if activeProtocolKind == .stdio {
                let models = try await safeLaneClient.listModels()
                transportCheckPassed = true
                transportModelCount = models.count
                transportCheckDetail = "model/list succeeded."
            } else {
                transportCheckPassed = true
                transportCheckDetail = "Smoke test is running on the \(activeProtocolKind.rawValue) transport."
            }

            try await ensureUITestLaunchAutomationThread()
            automationStage = "transport_verified"
            try await waitForUITestWorkspaceStatus(timeout: min(timeout, .seconds(15)))
            automationStage = "workspace_verified"

            var smokeSucceeded = false
            if uiTestShouldRunSmokeTestOnLaunch {
                sendSmokeTestPrompt()
                automationStage = "smoke_prompt_sent"
                smokeSucceeded = try await waitForUITestSmokeTest(timeout: timeout)
                automationStage = "smoke_completed"
            }

            let result = makeUITestLaunchAutomationResult(
                status: "success",
                detail: smokeSucceeded || !uiTestShouldRunSmokeTestOnLaunch
                    ? "Connected and completed the launch automation flow."
                    : "Connected without a smoke test marker.",
                smokeTestSucceeded: smokeSucceeded,
                automationStage: automationStage,
                transportCheckPassed: transportCheckPassed,
                transportCheckDetail: transportCheckDetail,
                transportModelCount: transportModelCount
            )
            writeUITestLaunchAutomationResult(result, fileName: resultFileName)
            Self.logger.log("COTG_UI_TEST_AUTOMATION_SUCCESS \(result.detail, privacy: .public)")
        } catch {
            let detail = error.localizedDescription
            let result = makeUITestLaunchAutomationResult(
                status: "failed",
                detail: detail,
                smokeTestSucceeded: false,
                automationStage: automationStage,
                transportCheckPassed: transportCheckPassed,
                transportCheckDetail: transportCheckDetail ?? detail,
                transportModelCount: transportModelCount
            )
            writeUITestLaunchAutomationResult(result, fileName: resultFileName)
            Self.logger.error("COTG_UI_TEST_AUTOMATION_FAILED \(detail, privacy: .public)")
        }
    }

    private var uiTestShouldRunSmokeTestOnLaunch: Bool {
        ProcessInfo.processInfo.environment["COTG_UI_TEST_AUTO_SMOKE_TEST_ON_LAUNCH"] != "0"
    }

    private var uiTestLaunchAutomationTimeout: Duration {
        let rawValue = ProcessInfo.processInfo.environment["COTG_UI_TEST_AUTO_TIMEOUT_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = rawValue.flatMap(Double.init) ?? 90
        return .seconds(seconds)
    }

    private var uiTestLaunchAutomationResultFileName: String {
        let rawValue = ProcessInfo.processInfo.environment["COTG_UI_TEST_AUTOMATION_RESULT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue?.isEmpty == false ? rawValue! : "ui-test-automation-result.json"
    }

    private func ensureUITestLaunchAutomationThread() async throws {
        guard activeSession?.threadID == nil else {
            return
        }

        let cwd = connectionBootstrapWorkspaceRoot()
        let modelOverride = selectedModel
            ?? availableModels.first(where: \.isDefault)?.model
            ?? availableModels.first?.model
        let thread: CodexThreadContext
        switch activeProtocolKind {
        case .stdio:
            thread = try await safeLaneClient.startThread(cwd: cwd, model: modelOverride)
        case .websocket, .directEndpoint:
            thread = try await loopbackClient.startThread(cwd: cwd, model: modelOverride)
        }

        await MainActor.run {
            self.upsertSession(
                threadID: thread.id,
                routeID: self.activeSession?.routeID ?? self.selectedBootstrapRoute?.id,
                workspaceRoot: thread.cwd,
                lastKnownProtocol: self.activeProtocolKind,
                lastKnownRouteKind: self.activeSession?.lastKnownRouteKind ?? self.selectedBootstrapRoute?.kind,
                lastKnownBootstrap: self.activeSession?.lastKnownBootstrap
                    ?? (self.selectedBootstrapRoute?.kind == .companionDirect ? .companionManaged : .standardSSH),
                lastModel: thread.model,
                reasoningEffort: thread.reasoningEffort
            )
            self.updateSessionState(transportState: .connected, lastErrorSummary: nil)
        }
    }

    private func waitForUITestConnectionCandidate(timeout: Duration) async throws {
        let start = ContinuousClock.now
        let cwd = connectionBootstrapWorkspaceRoot()

        while start.duration(to: .now) < timeout {
            if try await connectionCandidate(cwd: cwd) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        let summary = await connectionFailureSummary()
        throw CodexConnectionAutomationError(summary)
    }

    private func prepareUITestEmbeddedTailnetIfNeeded(timeout: Duration) async throws {
        guard ProcessInfo.processInfo.environment["COTG_EMBEDDED_TAILNET_AUTH_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false else {
            return
        }
        guard tailnetProfiles.contains(where: { $0.isActive && $0.kind == .embedded }) else {
            return
        }

        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            let runtime = await embeddedTailnetManager.snapshot()
            applyTailnetRuntimeUpdate(runtime, persist: false)
            if embeddedTailnetDialPlan?.supportsNativeSSHTransport == true {
                return
            }
            if embeddedTailnetStatus.authState == .blocked,
               let summary = embeddedTailnetStatus.lastErrorSummary,
               !summary.isEmpty {
                throw CodexConnectionAutomationError(summary)
            }
            if embeddedTailnetStatus.authState == .authenticating,
               let ticket = pendingTailnetAuthTicket {
                throw CodexConnectionAutomationError(
                    "Embedded tailnet still requires interactive login at \(ticket.authURL.absoluteString)."
                )
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        let summary = embeddedTailnetStatus.lastErrorSummary
            ?? "Embedded tailnet did not publish a SOCKS5 bootstrap endpoint."
        throw CodexConnectionAutomationError(summary)
    }

    private func waitForUITestConnectionReady(timeout: Duration) async throws {
        let start = ContinuousClock.now

        while start.duration(to: .now) < timeout {
            switch connectionState {
            case .connected:
                return
            case .failed(let detail):
                throw CodexConnectionAutomationError(detail)
            case .connecting, .disconnected:
                break
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        throw CodexConnectionAutomationError("Timed out waiting for the SSH safe lane to connect.")
    }

    private func waitForUITestSmokeTest(timeout: Duration) async throws -> Bool {
        let start = ContinuousClock.now

        while start.duration(to: .now) < timeout {
            if let latestAssistant = transcript.last(where: \.countsAsAssistantReply)?.text,
               latestAssistant.contains("COTG_APP_OK") {
                return true
            }

            if case .failed(let detail) = connectionState {
                throw CodexConnectionAutomationError(detail)
            }

            try await Task.sleep(for: .milliseconds(300))
        }

        throw CodexConnectionAutomationError("Timed out waiting for the smoke test reply.")
    }

    private func waitForUITestWorkspaceStatus(timeout: Duration) async throws {
        guard resolvedWorkspaceRoot() != nil else {
            return
        }

        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            if workspaceSummary != nil || workspaceFailureSummary != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw CodexConnectionAutomationError("Timed out waiting for workspace status.")
    }

    private func makeUITestLaunchAutomationResult(
        status: String,
        detail: String,
        smokeTestSucceeded: Bool,
        automationStage: String,
        transportCheckPassed: Bool,
        transportCheckDetail: String?,
        transportModelCount: Int?
    ) -> UITestLaunchAutomationResult {
        let route = selectedMachine.flatMap(sshBootstrapRoute(for:))
        let environment = ProcessInfo.processInfo.environment
        let endpoint = route.flatMap { resolvedSSHBootstrapEndpoint(for: $0, environment: environment) }
        let assistantReply = transcript.last(where: \.countsAsAssistantReply)?.text
        let credentialReady = selectedMachine.flatMap { machine in
            machine.credentialRef != nil || usesLocalhostTestingCredentialAutoload(for: machine)
        } ?? false
        let hostValidationReady = route.flatMap(hostValidationPolicy(for:)) != nil
        let workspaceStatus: String = {
            if workspaceSummary != nil {
                return "summary"
            }
            if workspaceFailureSummary != nil {
                return "failure"
            }
            if resolvedWorkspaceRoot() != nil {
                return "pending"
            }
            return "unavailable"
        }()
        return UITestLaunchAutomationResult(
            status: status,
            detail: detail,
            automationStage: automationStage,
            machineAlias: selectedMachine?.alias,
            routeKind: route?.kind.rawValue,
            routeHost: endpoint?.host ?? route?.hostname ?? route?.ipAddress ?? route?.magicDNSName,
            protocolKind: activeProtocolKind.rawValue,
            threadID: activeSession?.threadID,
            activeTurnID: activeTurnID,
            transportCheckPassed: transportCheckPassed,
            transportCheckDetail: transportCheckDetail,
            transportModelCount: transportModelCount,
            credentialReady: credentialReady,
            hostValidationReady: hostValidationReady,
            workspaceStatus: workspaceStatus,
            workspaceBranch: workspaceSummary?.branch,
            workspaceFailureSummary: workspaceFailureSummary,
            selectedMachineID: selectedMachineID?.uuidString,
            machineCount: machines.count,
            hostThreadCatalogCount: hostThreadCatalog.count,
            assistantReplyCount: transcript.filter(\.countsAsAssistantReply).count,
            assistantReply: assistantReply,
            smokeTestSucceeded: smokeTestSucceeded,
            tailnetAuthState: embeddedTailnetStatus.authState.rawValue,
            tailnetPendingAuth: pendingTailnetAuthTicket != nil,
            tailnetReachable: embeddedTailnetStatus.isReachable,
            tailnetLastError: embeddedTailnetStatus.lastErrorSummary,
            dialPlanHost: embeddedTailnetDialPlan?.socksProxyHost,
            dialPlanPort: embeddedTailnetDialPlan?.socksProxyPort,
            transcriptTail: Array(transcript.suffix(6).map { "\($0.role.rawValue): \($0.text)" }),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func writeUITestLaunchAutomationResult(
        _ result: UITestLaunchAutomationResult,
        fileName: String
    ) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let destinationURL = documentsURL.appendingPathComponent(fileName)
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to write UI test automation result: \(error.localizedDescription, privacy: .public)")
        }
    }

    func collaborationModePayload(modelOverride: String?) -> CodexCollaborationMode? {
        let resolvedModel = modelOverride
            ?? selectedModel
            ?? availableModels.first(where: \.isDefault)?.model
            ?? availableModels.first?.model
        guard let resolvedModel else {
            return nil
        }

        let developerInstructions = parallelAgentDeveloperInstructions
        guard selectedCollaborationMode != nil || developerInstructions != nil else {
            return nil
        }

        return CodexCollaborationMode(
            mode: selectedCollaborationMode ?? .default,
            model: resolvedModel,
            reasoningEffort: selectedReasoningEffort,
            developerInstructions: developerInstructions
        )
    }

    var parallelAgentDeveloperInstructions: String? {
        guard selectedParallelAgentMode == .clientOrchestrated else {
            return nil
        }

        return "Client-orchestrated parallel-agent mode is enabled. Break the work into focused subagent-sized steps when useful, keep the main thread in control, and summarize subagent results clearly. Native subagent controls are not exposed by this transport."
    }

    private var supportsProtocolNativeParallelAgents: Bool {
        false
    }

    private var selectedModelDescriptor: CodexModelDescriptor? {
        if let selectedModel {
            return availableModels.first(where: { $0.model == selectedModel })
        }

        return availableModels.first(where: \.isDefault) ?? availableModels.first
    }

    private static func normalizedExecutionPreference(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func reasoningEffortSortRank(_ effort: CodexReasoningEffort) -> Int {
        switch effort {
        case .none:
            return 0
        case .minimal:
            return 1
        case .low:
            return 2
        case .medium:
            return 3
        case .high:
            return 4
        case .xhigh:
            return 5
        }
    }

    public static func reasoningEffortDisplayName(_ effort: CodexReasoningEffort) -> String {
        switch effort {
        case .none:
            return "None"
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "X-High"
        }
    }

    public static func approvalPolicyDisplayName(_ policy: String?) -> String {
        switch normalizedExecutionPreference(policy) {
        case nil:
            return "Host config"
        case "never":
            return "Never"
        case "on-request":
            return "On request"
        default:
            return policy ?? "Host config"
        }
    }

    public static func sandboxModeDisplayName(_ mode: CodexSandboxMode?) -> String {
        switch mode {
        case nil:
            return "Host config"
        case .readOnly:
            return "Read only"
        case .workspaceWrite:
            return "Workspace write"
        case .dangerFullAccess:
            return "Full access"
        }
    }

    private func fastestSupportedReasoningEffort(for descriptor: CodexModelDescriptor?) -> CodexReasoningEffort {
        let ordered: [CodexReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]
        guard let descriptor else {
            return .low
        }

        let supported = Set(descriptor.supportedReasoningEfforts.map(\.effort))
        return ordered.first(where: supported.contains) ?? descriptor.defaultReasoningEffort
    }

    private func supportedReasoningEffort(
        _ effort: CodexReasoningEffort,
        for descriptor: CodexModelDescriptor?
    ) -> CodexReasoningEffort {
        guard let descriptor else {
            return effort
        }

        if descriptor.supportedReasoningEfforts.contains(where: { $0.effort == effort }) {
            return effort
        }

        return descriptor.defaultReasoningEffort
    }
}

private struct ConnectionStageError: LocalizedError {
    let stage: String
    let underlying: Error

    var errorDescription: String? {
        "\(stage) failed: \(underlying.localizedDescription)"
    }
}

private struct PendingTurnRequest: Hashable, Sendable {
    var text: String?
    var attachments: [ComposerAttachment]
    var summary: String
    var model: String?
    var effort: CodexReasoningEffort?
    var collaborationMode: CodexCollaborationMode?
    var showsAsUserMessage: Bool
    var clientSubagentTaskID: UUID?
    var transcriptMessageID: UUID?
    var requiresSigningSensitiveHostReadiness: Bool {
        AppModel.isSigningSensitiveTurnText(text)
            || AppModel.isSigningSensitiveTurnText(summary)
    }
    var requiresUploadAuthReadiness: Bool {
        AppModel.isUploadAuthSensitiveTurnText(text)
            || AppModel.isUploadAuthSensitiveTurnText(summary)
    }

    init(
        text: String?,
        attachments: [ComposerAttachment],
        summary: String,
        model: String? = nil,
        effort: CodexReasoningEffort? = nil,
        collaborationMode: CodexCollaborationMode? = nil,
        showsAsUserMessage: Bool = true,
        clientSubagentTaskID: UUID? = nil,
        transcriptMessageID: UUID? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.summary = summary
        self.model = model
        self.effort = effort
        self.collaborationMode = collaborationMode
        self.showsAsUserMessage = showsAsUserMessage
        self.clientSubagentTaskID = clientSubagentTaskID
        self.transcriptMessageID = transcriptMessageID
    }
}

enum ConnectionCandidate: Sendable {
    case safeLane(
        machineID: MachineRecord.ID,
        configuration: CodexSSHConfiguration,
        route: RouteRecord,
        bootstrap: BootstrapStrategy
    )
    case directEndpoint(
        machineID: MachineRecord.ID,
        configuration: CodexLiveConfiguration,
        route: RouteRecord,
        bootstrap: BootstrapStrategy
    )
}

struct SSHBootstrapEndpoint: Hashable, Sendable {
    var host: String
    var port: UInt16
}

enum SSHProxyConfigurationResolver {
    static func resolve(
        route: RouteRecord,
        dialPlan: EmbeddedTailnetDialPlan?
    ) -> SSHProxyConfiguration? {
        guard route.kind == .embeddedTailnet,
              let dialPlan,
              dialPlan.supportsNativeSSHTransport,
              let host = dialPlan.socksProxyHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        return SSHProxyConfiguration(
            host: host,
            port: dialPlan.socksProxyPort ?? 1055,
            username: dialPlan.socksProxyUsername,
            password: dialPlan.socksProxyPassword
        )
    }
}

enum SSHBootstrapEndpointResolver {
    static func resolve(
        route: RouteRecord,
        dialPlan: EmbeddedTailnetDialPlan?,
        environment: [String: String]
    ) -> SSHBootstrapEndpoint? {
        switch route.kind {
        case .embeddedTailnet:
            guard let dialPlan, dialPlan.supportsNativeSSHTransport else {
                return nil
            }

            if let preferredHost = (dialPlan.preferredHost ?? dialPlan.magicDNSName)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !preferredHost.isEmpty {
                return SSHBootstrapEndpoint(
                    host: preferredHost,
                    port: route.sshPort
                )
            }

            return nil
        case .externalTailnet, .localLAN, .manualSSH, .companionDirect:
            break
        }

        if let host = (route.hostname ?? route.ipAddress ?? route.magicDNSName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return SSHBootstrapEndpoint(host: host, port: route.sshPort)
        }

        return nil
    }
}

private struct SafeLaneCapabilityRunner: HostCapabilityCommandRunning {
    let client: CodexSSHAppServerClient

    func run(command: String) async throws -> HostCapabilityCommandResult {
        let result = try await client.execute(command: command)
        return HostCapabilityCommandResult(
            exitStatus: Int32(result.exitStatus),
            standardOutput: result.standardOutput,
            errorOutput: result.errorOutput
        )
    }
}

public struct RestoredLaunchContext: Sendable {
    public var selectedMachineID: MachineRecord.ID?
    public var selectedSessionID: SessionRecord.ID?
    public var shouldRestoreDetail: Bool

    public init(
        selectedMachineID: MachineRecord.ID?,
        selectedSessionID: SessionRecord.ID? = nil,
        shouldRestoreDetail: Bool
    ) {
        self.selectedMachineID = selectedMachineID
        self.selectedSessionID = selectedSessionID
        self.shouldRestoreDetail = shouldRestoreDetail
    }
}

public enum LiveConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(String)
    case failed(String)
}

public enum SessionMessageAttachmentKind: String, Sendable {
    case photo
    case voiceMemo

    init(composerKind: ComposerAttachmentKind) {
        switch composerKind {
        case .photo:
            self = .photo
        case .voiceMemo:
            self = .voiceMemo
        }
    }
}

public struct SessionMessageAttachment: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: SessionMessageAttachmentKind
    public var displayName: String
    public var suggestedFilename: String?

    public init(
        id: UUID = UUID(),
        kind: SessionMessageAttachmentKind,
        displayName: String,
        suggestedFilename: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.suggestedFilename = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(composerAttachment: ComposerAttachment) {
        self.init(
            id: composerAttachment.id,
            kind: SessionMessageAttachmentKind(composerKind: composerAttachment.kind),
            displayName: composerAttachment.displayName,
            suggestedFilename: composerAttachment.suggestedFilename
        )
    }
}

public struct SessionMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public enum Kind: String, Sendable {
        case standard
        case commentary
        case reasoning
        case plan
        case userInputPrompt
        case commandExecution
        case fileChange
        case toolCall
        case other
    }

    public enum DeliveryState: String, Sendable {
        case sending
        case queued
        case failed
    }

    public var id: UUID
    public var role: Role
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    public var isStreaming: Bool
    public var attachments: [SessionMessageAttachment]
    public var structuredPrompt: SessionStructuredPrompt?
    public var deliveryState: DeliveryState?

    public init(
        id: UUID = UUID(),
        role: Role,
        kind: Kind = .standard,
        text: String,
        createdAt: Date = .now,
        isStreaming: Bool = false,
        attachments: [SessionMessageAttachment] = [],
        structuredPrompt: SessionStructuredPrompt? = nil,
        deliveryState: DeliveryState? = nil
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.structuredPrompt = structuredPrompt
        self.deliveryState = deliveryState
    }

    public var countsAsAssistantReply: Bool {
        role == .assistant && !isStreaming && kind == .standard
    }
}

private extension MachineRecord {
    var isPreviewFixture: Bool {
        stableHostFingerprint?.contains("preview-fingerprint") == true
            || credentialRef?.keychainAccount.hasPrefix("cotg.preview.") == true
    }
}

private extension TailnetProfile {
    var isPreviewFixture: Bool {
        if let host = controlURL.host?.lowercased(), host == "headscale.example.com" {
            return true
        }

        if let tailnetDNSName, ["example.ts.net", "studio.ts.net"].contains(tailnetDNSName.lowercased()) {
            return true
        }

        return false
    }
}
