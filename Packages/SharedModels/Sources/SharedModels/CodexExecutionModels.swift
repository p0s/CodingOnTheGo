import Foundation

public enum CodexRuntimeBinaryProvenance: String, Codable, CaseIterable, Sendable {
    case appBundle
    case otherAppBundle
    case pathFallback
    case unknown
}

public struct CodexResolvedRuntime: Hashable, Codable, Sendable {
    public var binaryPath: String
    public var version: String?
    public var provenance: CodexRuntimeBinaryProvenance
    public var appBundlePath: String?
    public var detectedAt: Date

    public init(
        binaryPath: String,
        version: String? = nil,
        provenance: CodexRuntimeBinaryProvenance,
        appBundlePath: String? = nil,
        detectedAt: Date = .now
    ) {
        self.binaryPath = binaryPath
        self.version = version
        self.provenance = provenance
        self.appBundlePath = appBundlePath
        self.detectedAt = detectedAt
    }
}

public enum CodexExecutionValueStatus: String, Codable, CaseIterable, Sendable {
    case requested
    case effective
    case constrained
    case unknown
    case unsupported
}

public enum CodexExecutionSupportState: String, Codable, CaseIterable, Sendable {
    case supported
    case unsupported
    case unknown
}

public enum CodexReadAccessKind: String, Codable, CaseIterable, Sendable {
    case fullAccess
    case restricted
    case unknown
    case unsupported
}

public struct CodexExecutionAuthority<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public var requested: Value?
    public var effective: Value?
    public var status: CodexExecutionValueStatus
    public var detail: String?

    public init(
        requested: Value? = nil,
        effective: Value? = nil,
        status: CodexExecutionValueStatus = .unknown,
        detail: String? = nil
    ) {
        self.requested = requested
        self.effective = effective
        self.status = status
        self.detail = detail
    }
}

public struct CodexExecutionBaselineConfigSnapshot: Hashable, Codable, Sendable {
    public var approvalPolicy: String?
    public var sandboxMode: String?
    public var writableRoots: [String]
    public var extraReadableRoots: [String]
    public var readAccess: CodexReadAccessKind?
    public var networkAccess: Bool?
    public var capturedAt: Date

    public init(
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil,
        writableRoots: [String] = [],
        extraReadableRoots: [String] = [],
        readAccess: CodexReadAccessKind? = nil,
        networkAccess: Bool? = nil,
        capturedAt: Date = .now
    ) {
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.writableRoots = writableRoots
        self.extraReadableRoots = extraReadableRoots
        self.readAccess = readAccess
        self.networkAccess = networkAccess
        self.capturedAt = capturedAt
    }
}

public struct CodexExecutionConstraintsSnapshot: Hashable, Codable, Sendable {
    public var allowedApprovalPolicies: [String]?
    public var allowedSandboxModes: [String]?
    public var allowedWebSearchModes: [String]?
    public var featureRequirements: [String: Bool]?
    public var enforceResidency: String?
    public var capturedAt: Date

    public init(
        allowedApprovalPolicies: [String]? = nil,
        allowedSandboxModes: [String]? = nil,
        allowedWebSearchModes: [String]? = nil,
        featureRequirements: [String: Bool]? = nil,
        enforceResidency: String? = nil,
        capturedAt: Date = .now
    ) {
        self.allowedApprovalPolicies = allowedApprovalPolicies
        self.allowedSandboxModes = allowedSandboxModes
        self.allowedWebSearchModes = allowedWebSearchModes
        self.featureRequirements = featureRequirements
        self.enforceResidency = enforceResidency
        self.capturedAt = capturedAt
    }
}

public struct CodexExecutionSupportSnapshot: Hashable, Codable, Sendable {
    public var configRead: CodexExecutionSupportState
    public var configRequirementsRead: CodexExecutionSupportState
    public var threadStartOverrides: CodexExecutionSupportState
    public var threadResumeOverrides: CodexExecutionSupportState
    public var turnStartOverrides: CodexExecutionSupportState
    public var serverRequestRouting: CodexExecutionSupportState

    public init(
        configRead: CodexExecutionSupportState = .unknown,
        configRequirementsRead: CodexExecutionSupportState = .unknown,
        threadStartOverrides: CodexExecutionSupportState = .unknown,
        threadResumeOverrides: CodexExecutionSupportState = .unknown,
        turnStartOverrides: CodexExecutionSupportState = .unknown,
        serverRequestRouting: CodexExecutionSupportState = .unknown
    ) {
        self.configRead = configRead
        self.configRequirementsRead = configRequirementsRead
        self.threadStartOverrides = threadStartOverrides
        self.threadResumeOverrides = threadResumeOverrides
        self.turnStartOverrides = turnStartOverrides
        self.serverRequestRouting = serverRequestRouting
    }
}

public struct CodexExecutionProfile: Hashable, Codable, Sendable {
    public var approvalPolicy: CodexExecutionAuthority<String>
    public var sandboxMode: CodexExecutionAuthority<String>
    public var writableRoots: CodexExecutionAuthority<[String]>
    public var extraReadableRoots: CodexExecutionAuthority<[String]>
    public var readAccess: CodexExecutionAuthority<CodexReadAccessKind>
    public var networkAccess: CodexExecutionAuthority<Bool>
    public var runtime: CodexResolvedRuntime?
    public var capturedAt: Date

    public init(
        approvalPolicy: CodexExecutionAuthority<String> = .init(),
        sandboxMode: CodexExecutionAuthority<String> = .init(),
        writableRoots: CodexExecutionAuthority<[String]> = .init(),
        extraReadableRoots: CodexExecutionAuthority<[String]> = .init(),
        readAccess: CodexExecutionAuthority<CodexReadAccessKind> = .init(),
        networkAccess: CodexExecutionAuthority<Bool> = .init(),
        runtime: CodexResolvedRuntime? = nil,
        capturedAt: Date = .now
    ) {
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.writableRoots = writableRoots
        self.extraReadableRoots = extraReadableRoots
        self.readAccess = readAccess
        self.networkAccess = networkAccess
        self.runtime = runtime
        self.capturedAt = capturedAt
    }
}

public struct CodexExecutionProfileState: Hashable, Codable, Sendable {
    public var baselineConfig: CodexExecutionBaselineConfigSnapshot?
    public var constraints: CodexExecutionConstraintsSnapshot?
    public var support: CodexExecutionSupportSnapshot
    public var profile: CodexExecutionProfile
    public var lastUpdatedAt: Date

    public init(
        baselineConfig: CodexExecutionBaselineConfigSnapshot? = nil,
        constraints: CodexExecutionConstraintsSnapshot? = nil,
        support: CodexExecutionSupportSnapshot = .init(),
        profile: CodexExecutionProfile = .init(),
        lastUpdatedAt: Date = .now
    ) {
        self.baselineConfig = baselineConfig
        self.constraints = constraints
        self.support = support
        self.profile = profile
        self.lastUpdatedAt = lastUpdatedAt
    }
}
