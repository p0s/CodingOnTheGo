import Foundation
import SharedModels
#if canImport(Network)
import Network
#endif
#if canImport(TailscaleKit)
import TailscaleKit
#endif

public struct EmbeddedTailnetAuthTicket: Hashable, Codable, Sendable {
    public var profileID: TailnetProfile.ID
    public var authURL: URL
    public var displayedCode: String
    public var issuedAt: Date

    public init(
        profileID: TailnetProfile.ID,
        authURL: URL,
        displayedCode: String,
        issuedAt: Date = .now
    ) {
        self.profileID = profileID
        self.authURL = authURL
        self.displayedCode = displayedCode
        self.issuedAt = issuedAt
    }
}

public enum EmbeddedTailnetManagerError: LocalizedError {
    case missingProfile
    case unsupportedControlURL
    case noActiveProfile

    public var errorDescription: String? {
        switch self {
        case .missingProfile:
            "The requested tailnet profile is no longer available."
        case .unsupportedControlURL:
            "Use an HTTPS control URL for embedded tailnet profiles."
        case .noActiveProfile:
            "Select an embedded tailnet profile before starting authentication."
        }
    }
}

public struct TailnetProfileStoreSnapshot: Hashable, Sendable {
    public var profiles: [TailnetProfile]
    public var activeProfileID: TailnetProfile.ID?

    public init(profiles: [TailnetProfile], activeProfileID: TailnetProfile.ID?) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    public var activeProfile: TailnetProfile? {
        profiles.first(where: { $0.id == activeProfileID })
            ?? profiles.first(where: \.isActive)
    }
}

public protocol TailnetProfileStoring: Sendable {
    func bootstrap(profiles: [TailnetProfile], activeProfileID: TailnetProfile.ID?) async
    func snapshot() async -> TailnetProfileStoreSnapshot
    func save(draft: TailnetProfileDraft) async throws -> TailnetProfileStoreSnapshot
    func activate(profileID: TailnetProfile.ID) async throws -> TailnetProfileStoreSnapshot
    func markAuthenticated(profileID: TailnetProfile.ID, tailnetDNSName: String?) async throws -> TailnetProfileStoreSnapshot
    func resetAuthentication(profileID: TailnetProfile.ID) async throws -> TailnetProfileStoreSnapshot
    func delete(profileID: TailnetProfile.ID) async throws -> TailnetProfileStoreSnapshot
    func signOutActiveProfile() async throws -> TailnetProfileStoreSnapshot
}

public protocol EmbeddedTailnetAuthCoordinating: Sendable {
    func currentSession() async -> EmbeddedTailnetAuthSession?
    func prepareAuthentication(for profile: TailnetProfile) async throws -> EmbeddedTailnetAuthSession
    func markAuthenticated(profile: TailnetProfile) async -> EmbeddedTailnetAuthSession
    func clearSession(for profileID: TailnetProfile.ID?) async
}

public protocol EmbeddedTailnetDialerAdapting: Sendable {
    func runtimeHealth(
        for profile: TailnetProfile?,
        authSession: EmbeddedTailnetAuthSession?
    ) async -> EmbeddedTailnetRuntimeHealth

    func dialPlan(
        for profile: TailnetProfile?,
        health: EmbeddedTailnetRuntimeHealth
    ) async -> EmbeddedTailnetDialPlan?
}

public struct EmbeddedTailnetNativeTransportEndpoint: Hashable, Codable, Sendable {
    public var socksProxyHost: String
    public var socksProxyPort: UInt16
    public var socksProxyUsername: String?
    public var socksProxyPassword: String?
    public var preferredHost: String?

    public init(
        socksProxyHost: String,
        socksProxyPort: UInt16,
        socksProxyUsername: String? = nil,
        socksProxyPassword: String? = nil,
        preferredHost: String? = nil
    ) {
        self.socksProxyHost = socksProxyHost
        self.socksProxyPort = socksProxyPort
        self.socksProxyUsername = socksProxyUsername
        self.socksProxyPassword = socksProxyPassword
        self.preferredHost = preferredHost
    }
}

public protocol EmbeddedTailnetNativeTransportEndpointProviding: Sendable {
    func endpoint(for profile: TailnetProfile) async -> EmbeddedTailnetNativeTransportEndpoint?
}

enum EmbeddedTailnetLoopbackCredentialResolver {
    static let socksUsername = "tsnet"

    static func proxyAuthentication(
        from proxyCredential: String
    ) -> (username: String, password: String?) {
        let trimmed = proxyCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            username: socksUsername,
            password: trimmed.isEmpty ? nil : trimmed
        )
    }
}

private enum EmbeddedTailnetEnvironment {
    static func firstNonEmptyValue(
        for keys: [String],
        in environment: [String: String]
    ) -> String? {
        keys
            .compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    static func profileScopedValue(
        suffix: String,
        profileID: TailnetProfile.ID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let profileKey = profileID.uuidString
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()
        return firstNonEmptyValue(
            for: [
                "COTG_EMBEDDED_TAILNET_\(profileKey)_\(suffix)",
                "COTG_EMBEDDED_TAILNET_\(suffix)"
            ],
            in: environment
        )
    }
}

// Testing-only provider for package tests and local fixture injection.
public struct EnvironmentEmbeddedTailnetNativeTransportEndpointProvider: EmbeddedTailnetNativeTransportEndpointProviding {
    public init() {}

    public func endpoint(for profile: TailnetProfile) async -> EmbeddedTailnetNativeTransportEndpoint? {
        let environment = ProcessInfo.processInfo.environment

        guard let host = EmbeddedTailnetEnvironment.profileScopedValue(
            suffix: "SSH_PROXY_HOST",
            profileID: profile.id,
            environment: environment
        ) else {
            return nil
        }

        let port = EmbeddedTailnetEnvironment.profileScopedValue(
            suffix: "SSH_PROXY_PORT",
            profileID: profile.id,
            environment: environment
        )
            .flatMap(UInt16.init)
            ?? 22

        let preferredHost = EmbeddedTailnetEnvironment.profileScopedValue(
            suffix: "PREFERRED_HOST",
            profileID: profile.id,
            environment: environment
        )
            ?? profile.tailnetDNSName

        return EmbeddedTailnetNativeTransportEndpoint(
            socksProxyHost: host,
            socksProxyPort: port,
            preferredHost: preferredHost
        )
    }
}

private enum EmbeddedTailnetNativeTransportEndpointReflector {
    static func endpoint(
        from backendStatus: Any,
        preferredHost: String?
    ) -> EmbeddedTailnetNativeTransportEndpoint? {
        let strings = flattenedStrings(from: backendStatus)

        guard let proxyAddress = strings.first(where: { candidate in
            let key = candidate.key.lowercased()
            return key.contains("sock") && key.contains("proxy") && candidate.value.contains(":")
        })?.value,
        let parsedAddress = parsedHostPort(from: proxyAddress) else {
            return nil
        }

        let username = strings.first(where: { candidate in
            let key = candidate.key.lowercased()
            return key.contains("sock") && key.contains("user")
        })?.value

        let password = strings.first(where: { candidate in
            let key = candidate.key.lowercased()
            return key.contains("sock") && (key.contains("pass") || key.contains("credential"))
        })?.value

        return EmbeddedTailnetNativeTransportEndpoint(
            socksProxyHost: parsedAddress.host,
            socksProxyPort: parsedAddress.port,
            socksProxyUsername: username,
            socksProxyPassword: password,
            preferredHost: preferredHost
        )
    }

    private static func flattenedStrings(from value: Any, prefix: String = "") -> [(key: String, value: String)] {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return []
            }
            return [(prefix, trimmed)]
        }

        let mirror = Mirror(reflecting: value)
        guard !mirror.children.isEmpty else {
            return []
        }

        return mirror.children.flatMap { child in
            let label = child.label ?? prefix
            let composed = prefix.isEmpty ? label : "\(prefix).\(label)"
            return flattenedStrings(from: child.value, prefix: composed)
        }
    }

    private static func parsedHostPort(from rawValue: String) -> (host: String, port: UInt16)? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("["),
           let closingBracket = trimmed.firstIndex(of: "]"),
           trimmed.index(after: closingBracket) < trimmed.endIndex,
           trimmed[trimmed.index(after: closingBracket)] == ":" {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let portStart = trimmed.index(closingBracket, offsetBy: 2)
            guard let port = UInt16(trimmed[portStart...]) else {
                return nil
            }
            return (host, port)
        }

        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2,
              let port = UInt16(parts.last ?? "") else {
            return nil
        }

        let host = parts.dropLast().joined(separator: ":")
        guard !host.isEmpty else {
            return nil
        }

        return (host, port)
    }
}

public struct TailnetReachabilityTarget: Hashable, Codable, Sendable {
    public var host: String
    public var port: UInt16
    public var timeoutSeconds: TimeInterval

    public init(host: String, port: UInt16, timeoutSeconds: TimeInterval = 2.0) {
        self.host = host
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum TailnetReachabilityProbeState: String, Codable, Sendable {
    case reachable
    case unreachable
    case unsupported
}

public struct TailnetReachabilityProbeResult: Hashable, Codable, Sendable {
    public var state: TailnetReachabilityProbeState
    public var latencyMs: Int?
    public var lastCheckedAt: Date
    public var failureReasonCode: String?
    public var lastErrorSummary: String?

    public init(
        state: TailnetReachabilityProbeState,
        latencyMs: Int? = nil,
        lastCheckedAt: Date = .now,
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
        state == .reachable
    }
}

public protocol TailnetReachabilityProbing: Sendable {
    func probe(_ target: TailnetReachabilityTarget) async -> TailnetReachabilityProbeResult
}

public enum TailnetHealthMonitor {
    public static func status(
        for profile: TailnetProfile?,
        authSession: EmbeddedTailnetAuthSession?,
        health: EmbeddedTailnetRuntimeHealth
    ) -> EmbeddedTailnetStatus {
        guard let profile else {
            return EmbeddedTailnetStatus(
                isInstalled: true,
                authState: .signedOut,
                isReachable: false,
                controlURL: nil,
                lastErrorSummary: authSession?.lastErrorSummary ?? health.lastErrorSummary
            )
        }

        let lastErrorSummary = authSession?.lastErrorSummary ?? health.lastErrorSummary
        let authState: TailnetAuthState

        if authSession?.phase == .failed {
            authState = .blocked
        } else if profile.kind == .external {
            authState = profile.isActive ? .authenticated : .signedOut
        } else if authSession?.profileID == profile.id,
                  authSession?.phase == .pendingUserAction {
            authState = .authenticating
        } else if profile.lastAuthenticatedAt != nil {
            authState = .authenticated
        } else {
            authState = .signedOut
        }

        return EmbeddedTailnetStatus(
            isInstalled: profile.usesEmbeddedNode,
            authState: authState,
            isReachable: health.isReachable,
            controlURL: profile.controlURL,
            lastErrorSummary: lastErrorSummary
        )
    }
}

public enum TailnetReachabilityHealthMerger {
    public static func mergedHealth(
        baseHealth: EmbeddedTailnetRuntimeHealth,
        probeResult: TailnetReachabilityProbeResult?,
        profile: TailnetProfile?
    ) -> EmbeddedTailnetRuntimeHealth {
        guard let profile, profile.kind == .external else {
            return baseHealth
        }

        guard let probeResult else {
            return baseHealth
        }

        switch probeResult.state {
        case .reachable:
            return EmbeddedTailnetRuntimeHealth(
                state: .ready,
                latencyMs: probeResult.latencyMs,
                lastCheckedAt: probeResult.lastCheckedAt,
                failureReasonCode: nil,
                lastErrorSummary: nil
            )
        case .unsupported:
            return EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                latencyMs: probeResult.latencyMs ?? baseHealth.latencyMs,
                lastCheckedAt: probeResult.lastCheckedAt,
                failureReasonCode: probeResult.failureReasonCode ?? baseHealth.failureReasonCode ?? "external-tailnet-probe-unavailable",
                lastErrorSummary: probeResult.lastErrorSummary ?? baseHealth.lastErrorSummary ?? "External tailnet reachability is unverified on this build."
            )
        case .unreachable:
            return EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                latencyMs: probeResult.latencyMs ?? baseHealth.latencyMs,
                lastCheckedAt: probeResult.lastCheckedAt,
                failureReasonCode: probeResult.failureReasonCode ?? baseHealth.failureReasonCode ?? "external-tailnet-reachability-failed",
                lastErrorSummary: probeResult.lastErrorSummary ?? baseHealth.lastErrorSummary ?? "External tailnet reachability probe failed."
            )
        }
    }
}

public actor InMemoryTailnetProfileStore: TailnetProfileStoring {
    private var storedProfiles: [TailnetProfile] = []
    private var activeProfileID: TailnetProfile.ID?

    public init() {}

    public func bootstrap(profiles: [TailnetProfile], activeProfileID: TailnetProfile.ID?) async {
        storedProfiles = profiles
        self.activeProfileID = activeProfileID ?? profiles.first(where: \.isActive)?.id
    }

    public func snapshot() async -> TailnetProfileStoreSnapshot {
        TailnetProfileStoreSnapshot(
            profiles: storedProfiles,
            activeProfileID: resolvedActiveProfileID()
        )
    }

    public func save(draft: TailnetProfileDraft) async throws -> TailnetProfileStoreSnapshot {
        guard TailnetControlURLValidator.isSupported(draft.controlURL) else {
            throw EmbeddedTailnetManagerError.unsupportedControlURL
        }

        let isFirstEmbeddedProfile = draft.kind == .embedded
            && storedProfiles.first(where: \.usesEmbeddedNode) == nil
        let profile = TailnetProfile(
            kind: draft.kind,
            displayName: draft.displayName,
            controlURL: draft.controlURL,
            accountLabel: draft.accountLabel,
            tailnetDNSName: draft.tailnetDNSName,
            isActive: isFirstEmbeddedProfile,
            lastActivatedAt: isFirstEmbeddedProfile ? .now : nil,
            lastAuthenticatedAt: nil,
            supportsCustomControlServer: true,
            requiresExternalApp: draft.kind == .external
        )
        storedProfiles.append(profile)
        if isFirstEmbeddedProfile {
            activeProfileID = profile.id
        }
        return await snapshot()
    }

    public func activate(profileID: TailnetProfile.ID) async throws -> TailnetProfileStoreSnapshot {
        guard storedProfiles.contains(where: { $0.id == profileID }) else {
            throw EmbeddedTailnetManagerError.missingProfile
        }

        activeProfileID = profileID
        storedProfiles = storedProfiles.map { profile in
            var updated = profile
            updated.isActive = profile.id == profileID
            if updated.isActive {
                updated.lastActivatedAt = .now
            }
            return updated
        }
        return await snapshot()
    }

    public func markAuthenticated(profileID: TailnetProfile.ID, tailnetDNSName: String?) async throws -> TailnetProfileStoreSnapshot {
        guard storedProfiles.contains(where: { $0.id == profileID }) else {
            throw EmbeddedTailnetManagerError.missingProfile
        }

        activeProfileID = profileID
        storedProfiles = storedProfiles.map { profile in
            var updated = profile
            let isTarget = profile.id == profileID
            updated.isActive = isTarget
            if isTarget {
                updated.lastActivatedAt = .now
                updated.lastAuthenticatedAt = .now
                if let tailnetDNSName, !tailnetDNSName.isEmpty {
                    updated.tailnetDNSName = tailnetDNSName
                }
            }
            return updated
        }
        return await snapshot()
    }

    public func signOutActiveProfile() async throws -> TailnetProfileStoreSnapshot {
        guard let activeProfileID = resolvedActiveProfileID() else {
            throw EmbeddedTailnetManagerError.noActiveProfile
        }

        return try await resetAuthentication(profileID: activeProfileID)
    }

    public func resetAuthentication(profileID: TailnetProfile.ID) async throws -> TailnetProfileStoreSnapshot {
        guard storedProfiles.contains(where: { $0.id == profileID }) else {
            throw EmbeddedTailnetManagerError.missingProfile
        }

        storedProfiles = storedProfiles.map { profile in
            guard profile.id == profileID else {
                return profile
            }

            var updated = profile
            updated.lastAuthenticatedAt = nil
            return updated
        }
        return await snapshot()
    }

    public func delete(profileID: TailnetProfile.ID) async throws -> TailnetProfileStoreSnapshot {
        guard storedProfiles.contains(where: { $0.id == profileID }) else {
            throw EmbeddedTailnetManagerError.missingProfile
        }

        storedProfiles.removeAll { $0.id == profileID }
        if activeProfileID == profileID {
            activeProfileID = nil
        }
        storedProfiles = storedProfiles.map { profile in
            var updated = profile
            if activeProfileID == nil {
                updated.isActive = false
            }
            return updated
        }
        return await snapshot()
    }

    private func resolvedActiveProfileID() -> TailnetProfile.ID? {
        activeProfileID ?? storedProfiles.first(where: \.isActive)?.id
    }
}

public actor SyntheticEmbeddedTailnetAuthCoordinator: EmbeddedTailnetAuthCoordinating {
    private var authSession: EmbeddedTailnetAuthSession?

    public init() {}

    public func currentSession() async -> EmbeddedTailnetAuthSession? {
        authSession
    }

    public func prepareAuthentication(for profile: TailnetProfile) async throws -> EmbeddedTailnetAuthSession {
        guard TailnetControlURLValidator.isSupported(profile.controlURL) else {
            throw EmbeddedTailnetManagerError.unsupportedControlURL
        }

        let ticket = EmbeddedTailnetAuthTicket(
            profileID: profile.id,
            authURL: profile.controlURL.appending(path: "/admin"),
            displayedCode: String(profile.id.uuidString.prefix(6)).uppercased()
        )
        let session = EmbeddedTailnetAuthSession(
            profileID: profile.id,
            phase: .pendingUserAction,
            ticket: ticket
        )
        authSession = session
        return session
    }

    public func markAuthenticated(profile: TailnetProfile) async -> EmbeddedTailnetAuthSession {
        let session = EmbeddedTailnetAuthSession(
            profileID: profile.id,
            phase: .authenticated,
            ticket: nil
        )
        authSession = session
        return session
    }

    public func clearSession(for profileID: TailnetProfile.ID?) async {
        guard let profileID else {
            authSession = nil
            return
        }

        if authSession?.profileID == profileID {
            authSession = nil
        }
    }
}

public enum EmbeddedTailnetRuntimeFactory {
    public static var hasNativeRuntime: Bool {
        #if canImport(TailscaleKit)
        nativeRuntimeEnabled
        #else
        false
        #endif
    }

    public static var authCoordinator: any EmbeddedTailnetAuthCoordinating {
        #if canImport(TailscaleKit)
        if nativeRuntimeEnabled {
            return TailscaleKitEmbeddedTailnetCoordinator.shared
        }
        #else
        #endif
        return SyntheticEmbeddedTailnetAuthCoordinator()
    }

    public static var dialerAdapter: any EmbeddedTailnetDialerAdapting {
        #if canImport(TailscaleKit)
        if nativeRuntimeEnabled {
            return TailscaleKitEmbeddedTailnetCoordinator.shared
        }
        #else
        #endif
        return DeferredEmbeddedTailnetDialerAdapter()
    }

    public static var reachabilityProbe: any TailnetReachabilityProbing {
        #if canImport(Network)
        return AppleTailnetReachabilityProbe()
        #else
        return FallbackTailnetReachabilityProbe()
        #endif
    }

    private static var nativeRuntimeEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["COTG_DISABLE_NATIVE_EMBEDDED_TAILNET_RUNTIME"] == "1" {
            return false
        }
        if isXCTestProcess(environment: environment) {
            return explicitlyEnablesNativeRuntime(environment: environment)
        }
        return true
    }

    private static func isXCTestProcess(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func explicitlyEnablesNativeRuntime(environment: [String: String]) -> Bool {
        if environment["COTG_ENABLE_NATIVE_EMBEDDED_TAILNET_RUNTIME"] == "1"
            || environment["COTG_EMBEDDED_TAILNET_REPRO"] == "1"
            || environment["COTG_EMBEDDED_TAILNET_SSH_REPRO"] == "1" {
            return true
        }

        return environment["COTG_EMBEDDED_TAILNET_AUTH_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }
}

#if canImport(Network)
public struct AppleTailnetReachabilityProbe: TailnetReachabilityProbing {
    public init() {}

    public func probe(_ target: TailnetReachabilityTarget) async -> TailnetReachabilityProbeResult {
        guard !target.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TailnetReachabilityProbeResult(
                state: .unreachable,
                lastCheckedAt: .now,
                failureReasonCode: "external-tailnet-target-missing",
                lastErrorSummary: "No tailnet hostname is available for reachability probing."
            )
        }

        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            return TailnetReachabilityProbeResult(
                state: .unsupported,
                lastCheckedAt: .now,
                failureReasonCode: "external-tailnet-port-invalid",
                lastErrorSummary: "The SSH port could not be represented as a Network.framework endpoint."
            )
        }

        let start = DispatchTime.now()
        return await withCheckedContinuation { continuation in
            final class Resolution: @unchecked Sendable {
                var finished = false
                let lock = NSLock()

                func finish(
                    _ result: TailnetReachabilityProbeResult,
                    continuation: CheckedContinuation<TailnetReachabilityProbeResult, Never>
                ) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !finished else {
                        return
                    }
                    finished = true
                    continuation.resume(returning: result)
                }
            }

            let resolution = Resolution()
            let queue = DispatchQueue(label: "CodingOnTheGo.TailnetReachabilityProbe")
            let connection = NWConnection(
                host: NWEndpoint.Host(target.host),
                port: port,
                using: .tcp
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    let result = TailnetReachabilityProbeResult(
                        state: .reachable,
                        latencyMs: Int(elapsed / 1_000_000),
                        lastCheckedAt: .now
                    )
                    resolution.finish(result, continuation: continuation)
                    connection.cancel()
                case let .failed(error):
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    let result = TailnetReachabilityProbeResult(
                        state: .unreachable,
                        latencyMs: Int(elapsed / 1_000_000),
                        lastCheckedAt: .now,
                        failureReasonCode: "external-tailnet-unreachable",
                        lastErrorSummary: error.localizedDescription
                    )
                    resolution.finish(result, continuation: continuation)
                    connection.cancel()
                case .cancelled:
                    let result = TailnetReachabilityProbeResult(
                        state: .unreachable,
                        lastCheckedAt: .now,
                        failureReasonCode: "external-tailnet-probe-cancelled",
                        lastErrorSummary: "The reachability probe was cancelled before it connected."
                    )
                    resolution.finish(result, continuation: continuation)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + target.timeoutSeconds) {
                let result = TailnetReachabilityProbeResult(
                    state: .unreachable,
                    lastCheckedAt: .now,
                    failureReasonCode: "external-tailnet-probe-timeout",
                    lastErrorSummary: "The reachability probe timed out after \(target.timeoutSeconds) seconds."
                )
                resolution.finish(result, continuation: continuation)
                connection.cancel()
            }

            connection.start(queue: queue)
        }
    }
}
#else
public struct FallbackTailnetReachabilityProbe: TailnetReachabilityProbing {
    public init() {}

    public func probe(_ target: TailnetReachabilityTarget) async -> TailnetReachabilityProbeResult {
        TailnetReachabilityProbeResult(
            state: .unsupported,
            lastCheckedAt: .now,
            failureReasonCode: "external-tailnet-probe-unavailable",
            lastErrorSummary: "External tailnet reachability probing is unavailable on this build."
        )
    }
}
#endif

#if canImport(TailscaleKit)
public actor TailscaleKitEmbeddedTailnetCoordinator: EmbeddedTailnetAuthCoordinating, EmbeddedTailnetDialerAdapting {
    public static let shared = TailscaleKitEmbeddedTailnetCoordinator()

    private final class RuntimeContext: @unchecked Sendable {
        let profileID: TailnetProfile.ID
        let controlURL: URL
        let node: TailscaleNode
        let client: LocalAPIClient
        var transportEndpoint: EmbeddedTailnetNativeTransportEndpoint?
        var lastTransportEndpointError: String?

        init(
            profileID: TailnetProfile.ID,
            controlURL: URL,
            node: TailscaleNode,
            client: LocalAPIClient,
            transportEndpoint: EmbeddedTailnetNativeTransportEndpoint? = nil,
            lastTransportEndpointError: String? = nil
        ) {
            self.profileID = profileID
            self.controlURL = controlURL
            self.node = node
            self.client = client
            self.transportEndpoint = transportEndpoint
            self.lastTransportEndpointError = lastTransportEndpointError
        }
    }

    private var authSession: EmbeddedTailnetAuthSession?
    private var contexts: [TailnetProfile.ID: RuntimeContext] = [:]
    private var contextTasks: [TailnetProfile.ID: Task<RuntimeContext, Error>] = [:]

    public init() {}

    public func currentSession() async -> EmbeddedTailnetAuthSession? {
        authSession
    }

    public func prepareAuthentication(for profile: TailnetProfile) async throws -> EmbeddedTailnetAuthSession {
        guard TailnetControlURLValidator.isSupported(profile.controlURL) else {
            throw EmbeddedTailnetManagerError.unsupportedControlURL
        }

        let client = try await runtimeContext(for: profile).client
        try await client.startLoginInteractive()
        let status = try await client.backendStatus()
        _ = await refreshTransportEndpoint(for: profile, backendStatus: status)
        let authURL = URL(string: status.AuthURL)
            ?? profile.controlURL

        let session = EmbeddedTailnetAuthSession(
            profileID: profile.id,
            phase: .pendingUserAction,
            ticket: EmbeddedTailnetAuthTicket(
                profileID: profile.id,
                authURL: authURL,
                displayedCode: String(profile.id.uuidString.prefix(6)).uppercased()
            ),
            lastErrorSummary: status.Health?.joined(separator: " • ")
        )
        authSession = session
        return session
    }

    public func markAuthenticated(profile: TailnetProfile) async -> EmbeddedTailnetAuthSession {
        let session = EmbeddedTailnetAuthSession(
            profileID: profile.id,
            phase: .authenticated,
            ticket: nil
        )
        authSession = session
        return session
    }

    public func clearSession(for profileID: TailnetProfile.ID?) async {
        guard let profileID else {
            authSession = nil
            return
        }

        if authSession?.profileID == profileID {
            authSession = nil
        }
    }

    public func runtimeHealth(
        for profile: TailnetProfile?,
        authSession: EmbeddedTailnetAuthSession?
    ) async -> EmbeddedTailnetRuntimeHealth {
        guard let profile else {
            return EmbeddedTailnetRuntimeHealth(state: .idle)
        }

        if profile.kind == .external {
            return EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                lastCheckedAt: .now,
                failureReasonCode: "external-tailnet-reachability-unverified",
                lastErrorSummary: "External tailnet reachability still needs a system-network probe."
            )
        }

        do {
            let context = try await runtimeContext(for: profile)
            let status = try await context.client.backendStatus()
            let transportEndpoint = await refreshTransportEndpoint(
                for: profile,
                backendStatus: status,
                context: context
            )
            let joinedHealth = status.Health?.joined(separator: " • ")
            if !status.AuthURL.isEmpty {
                return EmbeddedTailnetRuntimeHealth(
                    state: .pendingAuth,
                    lastCheckedAt: .now,
                    failureReasonCode: "tailnet-auth-pending",
                    lastErrorSummary: authSession?.lastErrorSummary ?? joinedHealth ?? "Open the embedded tailnet login URL to continue."
                )
            }

            if status.BackendState == "Running" || status.SelfStatus?.Online == true {
                if let transportEndpoint {
                    return EmbeddedTailnetRuntimeHealth(
                        state: .ready,
                        latencyMs: transportEndpoint.socksProxyPort == 22 ? nil : 0,
                        lastCheckedAt: .now,
                        lastErrorSummary: joinedHealth
                    )
                }

                return EmbeddedTailnetRuntimeHealth(
                    state: .degraded,
                    lastCheckedAt: .now,
                    failureReasonCode: "embedded-tailnet-transport-pending",
                    lastErrorSummary: context.lastTransportEndpointError
                        ?? "Embedded tailnet is authenticated, but the native runtime has not published a SOCKS5 bootstrap endpoint yet."
                )
            }

            return EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                lastCheckedAt: .now,
                failureReasonCode: "embedded-tailnet-not-running",
                lastErrorSummary: joinedHealth ?? "Embedded tailnet is installed but not running yet."
            )
        } catch {
            return EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                lastCheckedAt: .now,
                failureReasonCode: "embedded-tailnet-runtime-error",
                lastErrorSummary: error.localizedDescription
            )
        }
    }

    public func dialPlan(
        for profile: TailnetProfile?,
        health: EmbeddedTailnetRuntimeHealth
    ) async -> EmbeddedTailnetDialPlan? {
        guard let profile else {
            return nil
        }

        let routeKind: MachineRouteKind = profile.kind == .embedded ? .embeddedTailnet : .externalTailnet
        let transportEndpoint = contexts[profile.id]?.transportEndpoint
        return EmbeddedTailnetDialPlan(
            profileID: profile.id,
            routeKind: routeKind,
            preferredHost: transportEndpoint?.preferredHost ?? profile.tailnetDNSName,
            magicDNSName: profile.tailnetDNSName,
            requiresExternalApp: profile.requiresExternalApp,
            socksProxyHost: transportEndpoint?.socksProxyHost,
            socksProxyPort: transportEndpoint?.socksProxyPort,
            socksProxyUsername: transportEndpoint?.socksProxyUsername,
            socksProxyPassword: transportEndpoint?.socksProxyPassword,
            supportsNativeSSHTransport: transportEndpoint != nil
        )
    }

    private func runtimeContext(for profile: TailnetProfile) async throws -> RuntimeContext {
        if let existing = contexts[profile.id],
           existing.controlURL == profile.controlURL {
            return existing
        }

        if let existing = contexts[profile.id] {
            try? await existing.node.close()
            contexts[profile.id] = nil
        }

        if let task = contextTasks[profile.id] {
            let context = try await task.value
            if context.controlURL == profile.controlURL {
                contexts[profile.id] = context
                return context
            }

            try? await context.node.close()
            contextTasks[profile.id] = nil
        }

        let task = Task<RuntimeContext, Error> {
            let dataDirectory = try dataDirectory(for: profile)
            let configuration = Configuration(
                hostName: profile.displayName,
                path: dataDirectory.path,
                authKey: configuredAuthKey(for: profile),
                controlURL: profile.controlURL.absoluteString,
                ephemeral: false
            )
            let node = try TailscaleNode(config: configuration, logger: nil)
            try await node.up()
            let client = LocalAPIClient(localNode: node, logger: nil)
            return RuntimeContext(
                profileID: profile.id,
                controlURL: profile.controlURL,
                node: node,
                client: client
            )
        }

        contextTasks[profile.id] = task

        do {
            let context = try await task.value
            contextTasks[profile.id] = nil
            contexts[profile.id] = context
            return context
        } catch {
            contextTasks[profile.id] = nil
            throw error
        }
    }

    private func refreshTransportEndpoint(
        for profile: TailnetProfile,
        backendStatus: Any,
        context: RuntimeContext? = nil
    ) async -> EmbeddedTailnetNativeTransportEndpoint? {
        let resolvedContext = if let context {
            context
        } else {
            contexts[profile.id]
        }
        if let cachedEndpoint = resolvedContext?.transportEndpoint {
            return cachedEndpoint
        }
        let preferredHost = configuredPreferredHost(for: profile)
        let endpoint: EmbeddedTailnetNativeTransportEndpoint?
        do {
            endpoint = try await loopbackTransportEndpoint(for: profile, context: resolvedContext)
                ?? EmbeddedTailnetNativeTransportEndpointReflector.endpoint(
                    from: backendStatus,
                    preferredHost: preferredHost
                )
        } catch {
            resolvedContext?.lastTransportEndpointError = Self.runtimeErrorSummary(error)
            endpoint = EmbeddedTailnetNativeTransportEndpointReflector.endpoint(
                from: backendStatus,
                preferredHost: preferredHost
            )
        }
        if endpoint != nil {
            resolvedContext?.lastTransportEndpointError = nil
        }
        resolvedContext?.transportEndpoint = endpoint
        return endpoint
    }

    private func configuredAuthKey(for profile: TailnetProfile) -> String? {
        EmbeddedTailnetEnvironment.profileScopedValue(
            suffix: "AUTH_KEY",
            profileID: profile.id
        )
    }

    private func configuredPreferredHost(for profile: TailnetProfile) -> String? {
        EmbeddedTailnetEnvironment.profileScopedValue(
            suffix: "PREFERRED_HOST",
            profileID: profile.id
        ) ?? profile.tailnetDNSName
    }

    private func loopbackTransportEndpoint(
        for profile: TailnetProfile,
        context: RuntimeContext?
    ) async throws -> EmbeddedTailnetNativeTransportEndpoint? {
        guard let context else {
            return nil
        }

        let loopback = try await context.node.loopback()
        guard let proxyAddress = Self.parsedHostPort(from: loopback.address) else {
            return nil
        }
        let authentication = EmbeddedTailnetLoopbackCredentialResolver.proxyAuthentication(
            from: loopback.proxyCredential
        )

        return EmbeddedTailnetNativeTransportEndpoint(
            socksProxyHost: proxyAddress.host,
            socksProxyPort: proxyAddress.port,
            socksProxyUsername: authentication.username,
            socksProxyPassword: authentication.password,
            preferredHost: configuredPreferredHost(for: profile)
        )
    }

    private static func runtimeErrorSummary(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        let description = error.localizedDescription
        if !description.isEmpty {
            return description
        }

        return String(describing: error)
    }

    private static func parsedHostPort(from rawValue: String) -> (host: String, port: UInt16)? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("["),
           let closingBracket = trimmed.firstIndex(of: "]"),
           trimmed.index(after: closingBracket) < trimmed.endIndex,
           trimmed[trimmed.index(after: closingBracket)] == ":" {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let portStart = trimmed.index(closingBracket, offsetBy: 2)
            guard let port = UInt16(trimmed[portStart...]) else {
                return nil
            }
            return (host, port)
        }

        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2,
              let port = UInt16(parts.last ?? "") else {
            return nil
        }

        let host = parts.dropLast().joined(separator: ":")
        guard !host.isEmpty else {
            return nil
        }

        return (host, port)
    }

    private func dataDirectory(for profile: TailnetProfile) throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory
            .appending(path: "CodingOnTheGo")
            .appending(path: "Tailnets")
            .appending(path: profile.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif

public struct DeferredEmbeddedTailnetDialerAdapter: EmbeddedTailnetDialerAdapting {
    private let transportEndpointProvider: (any EmbeddedTailnetNativeTransportEndpointProviding)?

    public init(
        transportEndpointProvider: (any EmbeddedTailnetNativeTransportEndpointProviding)? = nil
    ) {
        self.transportEndpointProvider = transportEndpointProvider
    }

    public func runtimeHealth(
        for profile: TailnetProfile?,
        authSession: EmbeddedTailnetAuthSession?
    ) async -> EmbeddedTailnetRuntimeHealth {
        guard let profile else {
            return EmbeddedTailnetRuntimeHealth(state: .idle)
        }

        if profile.kind == .external {
            return EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                lastCheckedAt: .now,
                failureReasonCode: "external-tailnet-reachability-unverified",
                lastErrorSummary: "External tailnet reachability still needs a system-network probe."
            )
        }

        if authSession?.profileID == profile.id,
           authSession?.phase == .pendingUserAction {
            return EmbeddedTailnetRuntimeHealth(
                state: .pendingAuth,
                lastCheckedAt: .now,
                failureReasonCode: "tailnet-auth-pending"
            )
        }

        if profile.lastAuthenticatedAt != nil {
            if let transportEndpointProvider,
               await transportEndpointProvider.endpoint(for: profile) != nil {
                return EmbeddedTailnetRuntimeHealth(
                    state: .ready,
                    lastCheckedAt: .now
                )
            }

            return EmbeddedTailnetRuntimeHealth(
                state: .needsRuntimeIntegration,
                lastCheckedAt: .now,
                failureReasonCode: "embedded-tailnet-runtime-unavailable",
                lastErrorSummary: "Embedded tailnet auth is recorded, but no SDK-backed runtime adapter is installed in this build."
            )
        }

        return EmbeddedTailnetRuntimeHealth(
            state: .idle,
            lastCheckedAt: .now,
            failureReasonCode: "tailnet-auth-required"
        )
    }

    public func dialPlan(
        for profile: TailnetProfile?,
        health: EmbeddedTailnetRuntimeHealth
    ) async -> EmbeddedTailnetDialPlan? {
        guard let profile else {
            return nil
        }

        let routeKind: MachineRouteKind = profile.kind == .embedded ? .embeddedTailnet : .externalTailnet
        let transportEndpoint: EmbeddedTailnetNativeTransportEndpoint? = if let transportEndpointProvider {
            await transportEndpointProvider.endpoint(for: profile)
        } else {
            nil
        }
        return EmbeddedTailnetDialPlan(
            profileID: profile.id,
            routeKind: routeKind,
            preferredHost: transportEndpoint?.preferredHost ?? profile.tailnetDNSName,
            magicDNSName: profile.tailnetDNSName,
            requiresExternalApp: profile.requiresExternalApp,
            socksProxyHost: transportEndpoint?.socksProxyHost,
            socksProxyPort: transportEndpoint?.socksProxyPort,
            socksProxyUsername: transportEndpoint?.socksProxyUsername,
            socksProxyPassword: transportEndpoint?.socksProxyPassword,
            supportsNativeSSHTransport: transportEndpoint != nil
        )
    }
}

public actor EmbeddedTailnetNodeManager {
    private let profileStore: any TailnetProfileStoring
    private let authCoordinator: any EmbeddedTailnetAuthCoordinating
    private let dialerAdapter: any EmbeddedTailnetDialerAdapting
    private let reachabilityProbe: any TailnetReachabilityProbing

    public init(
        profileStore: any TailnetProfileStoring = InMemoryTailnetProfileStore(),
        authCoordinator: any EmbeddedTailnetAuthCoordinating = EmbeddedTailnetRuntimeFactory.authCoordinator,
        dialerAdapter: any EmbeddedTailnetDialerAdapting = EmbeddedTailnetRuntimeFactory.dialerAdapter,
        reachabilityProbe: any TailnetReachabilityProbing = EmbeddedTailnetRuntimeFactory.reachabilityProbe
    ) {
        self.profileStore = profileStore
        self.authCoordinator = authCoordinator
        self.dialerAdapter = dialerAdapter
        self.reachabilityProbe = reachabilityProbe
    }

    public func bootstrap(
        profiles: [TailnetProfile],
        activeProfileID: TailnetProfile.ID?
    ) async -> EmbeddedTailnetRuntimeSnapshot {
        await profileStore.bootstrap(profiles: profiles, activeProfileID: activeProfileID)
        return await snapshot()
    }

    public func saveProfile(_ draft: TailnetProfileDraft) async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.save(draft: draft)
        return await snapshot(from: profileSnapshot)
    }

    public func activate(profileID: TailnetProfile.ID) async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.activate(profileID: profileID)
        let authSession = await authCoordinator.currentSession()
        if authSession?.profileID != profileSnapshot.activeProfileID {
            await authCoordinator.clearSession(for: nil)
        }
        return await snapshot(from: profileSnapshot)
    }

    public func beginAuthentication(profileID: TailnetProfile.ID) async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.activate(profileID: profileID)
        guard let profile = profileSnapshot.profiles.first(where: { $0.id == profileID }) else {
            throw EmbeddedTailnetManagerError.missingProfile
        }

        let authSession = try await authCoordinator.prepareAuthentication(for: profile)
        return await snapshot(from: profileSnapshot, authSessionOverride: authSession)
    }

    public func completeAuthentication(
        profileID: TailnetProfile.ID,
        tailnetDNSName: String? = nil
    ) async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.markAuthenticated(
            profileID: profileID,
            tailnetDNSName: tailnetDNSName
        )
        guard let profile = profileSnapshot.activeProfile else {
            throw EmbeddedTailnetManagerError.noActiveProfile
        }
        let authSession = await authCoordinator.markAuthenticated(profile: profile)
        return await snapshot(from: profileSnapshot, authSessionOverride: authSession)
    }

    public func signOutActiveProfile() async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.signOutActiveProfile()
        await authCoordinator.clearSession(for: profileSnapshot.activeProfileID)
        return await snapshot(from: profileSnapshot, authSessionOverride: nil)
    }

    public func resetAuthentication(profileID: TailnetProfile.ID) async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.resetAuthentication(profileID: profileID)
        await authCoordinator.clearSession(for: profileID)
        return await snapshot(from: profileSnapshot, authSessionOverride: nil)
    }

    public func deleteProfile(profileID: TailnetProfile.ID) async throws -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = try await profileStore.delete(profileID: profileID)
        await authCoordinator.clearSession(for: profileID)
        return await snapshot(from: profileSnapshot, authSessionOverride: nil)
    }

    public func snapshot() async -> EmbeddedTailnetRuntimeSnapshot {
        let profileSnapshot = await profileStore.snapshot()
        return await snapshot(from: profileSnapshot)
    }

    public func profiles() async -> [TailnetProfile] {
        let snapshot = await profileStore.snapshot()
        return snapshot.profiles
    }

    public func status() async -> EmbeddedTailnetStatus {
        let runtimeSnapshot = await snapshot()
        return runtimeSnapshot.status
    }

    public var activeProfile: TailnetProfile? {
        get async {
            let snapshot = await profileStore.snapshot()
            return snapshot.activeProfile
        }
    }

    public func publishedRoute(
        machineID: MachineRecord.ID,
        hostname: String
    ) async -> RouteRecord? {
        let runtimeSnapshot = await snapshot()
        return TailnetRoutePublisher.route(
            machineID: machineID,
            hostname: hostname,
            snapshot: runtimeSnapshot
        )
    }

    private func snapshot(
        from profileSnapshot: TailnetProfileStoreSnapshot,
        authSessionOverride: EmbeddedTailnetAuthSession? = nil
    ) async -> EmbeddedTailnetRuntimeSnapshot {
        var resolvedProfileSnapshot = profileSnapshot
        var authSession = if let authSessionOverride {
            authSessionOverride
        } else {
            await authCoordinator.currentSession()
        }
        var activeProfile = resolvedProfileSnapshot.activeProfile
        var baseHealth = await dialerAdapter.runtimeHealth(for: activeProfile, authSession: authSession)

        if let pendingProfile = activeProfile,
           pendingProfile.kind == .embedded,
           authSession?.profileID == pendingProfile.id,
           authSession?.phase == .pendingUserAction,
           baseHealth.state != .pendingAuth {
            if let authenticatedProfileSnapshot = try? await profileStore.markAuthenticated(
                profileID: pendingProfile.id,
                tailnetDNSName: pendingProfile.tailnetDNSName
            ) {
                resolvedProfileSnapshot = authenticatedProfileSnapshot
                activeProfile = resolvedProfileSnapshot.activeProfile
                if let activeProfile {
                    authSession = await authCoordinator.markAuthenticated(profile: activeProfile)
                    baseHealth = await dialerAdapter.runtimeHealth(for: activeProfile, authSession: authSession)
                }
            }
        }

        let probeResult = await externalReachabilityProbeResult(
            for: activeProfile,
            baseHealth: baseHealth
        )
        let health = TailnetReachabilityHealthMerger.mergedHealth(
            baseHealth: baseHealth,
            probeResult: probeResult,
            profile: activeProfile
        )
        let status = TailnetHealthMonitor.status(
            for: activeProfile,
            authSession: authSession,
            health: health
        )
        let dialPlan = await dialerAdapter.dialPlan(for: activeProfile, health: health)

        return EmbeddedTailnetRuntimeSnapshot(
            profiles: resolvedProfileSnapshot.profiles,
            activeProfileID: resolvedProfileSnapshot.activeProfileID,
            authSession: authSession,
            health: health,
            status: status,
            dialPlan: dialPlan
        )
    }

    private func externalReachabilityProbeResult(
        for profile: TailnetProfile?,
        baseHealth: EmbeddedTailnetRuntimeHealth
    ) async -> TailnetReachabilityProbeResult? {
        guard let profile,
              profile.kind == .external else {
            return nil
        }

        guard baseHealth.state != .pendingAuth else {
            return nil
        }

        guard let host = profile.tailnetDNSName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return TailnetReachabilityProbeResult(
                state: .unreachable,
                lastCheckedAt: .now,
                failureReasonCode: "external-tailnet-target-missing",
                lastErrorSummary: "Add a tailnet DNS name before testing external tailnet reachability."
            )
        }

        let target = TailnetReachabilityTarget(host: host, port: 22)
        return await reachabilityProbe.probe(target)
    }
}

public enum TailnetRoutePublisher {
    public static func applying(
        _ snapshot: EmbeddedTailnetRuntimeSnapshot,
        to machines: [MachineRecord]
    ) -> [MachineRecord] {
        guard let plan = snapshot.dialPlan,
              let profile = snapshot.activeProfile else {
            return machines
        }

        let targetMachineIDs = routeTargetMachineIDs(for: plan, profile: profile, machines: machines)
        return machines.map { machine in
            applying(
                snapshot,
                to: machine,
                shouldPublishRoute: targetMachineIDs.contains(machine.id)
            )
        }
    }

    public static func route(
        machineID: MachineRecord.ID,
        hostname: String,
        snapshot: EmbeddedTailnetRuntimeSnapshot
    ) -> RouteRecord? {
        guard let plan = snapshot.dialPlan,
              let profile = snapshot.activeProfile else {
            return nil
        }

        return RouteRecord(
            machineID: machineID,
            kind: plan.routeKind,
            label: profile.displayName,
            hostname: plan.preferredHost ?? hostname,
            magicDNSName: plan.magicDNSName,
            tailnetProfileID: profile.id,
            requiresExternalApp: plan.requiresExternalApp,
            health: routeHealth(for: snapshot.health, plan: plan),
            lastLatencyMs: snapshot.health.latencyMs,
            lastCheckedAt: snapshot.health.lastCheckedAt,
            lastSuccessAt: routeHealth(for: snapshot.health, plan: plan).isEligibleForTraffic ? snapshot.health.lastCheckedAt : nil,
            lastFailureAt: routeHealth(for: snapshot.health, plan: plan).isEligibleForTraffic ? nil : snapshot.health.lastCheckedAt,
            failureReasonCode: failureReasonCode(for: snapshot.health, plan: plan),
            isRecommended: profile.isActive && routeHealth(for: snapshot.health, plan: plan).isEligibleForTraffic,
            isUserPinned: false,
            publishedByCompanion: false,
            discoverySource: .tailnetProfile,
            trustState: .unknown
        )
    }

    public static func applying(
        _ snapshot: EmbeddedTailnetRuntimeSnapshot,
        to machine: MachineRecord
    ) -> MachineRecord {
        applying(snapshot, to: machine, shouldPublishRoute: true)
    }

    private static func applying(
        _ snapshot: EmbeddedTailnetRuntimeSnapshot,
        to machine: MachineRecord,
        shouldPublishRoute: Bool
    ) -> MachineRecord {
        var updated = machine

        if !shouldPublishRoute,
           let publishedRouteKind = snapshot.dialPlan?.routeKind,
           let publishedProfileID = snapshot.activeProfile?.id {
            let removedRouteIDs = Set(
                updated.routes
                    .filter { $0.kind == publishedRouteKind && $0.tailnetProfileID == publishedProfileID }
                    .map(\.id)
            )
            if !removedRouteIDs.isEmpty {
                updated.routes.removeAll { removedRouteIDs.contains($0.id) }
                if let preferredRouteID = updated.preferredRouteID,
                   removedRouteIDs.contains(preferredRouteID) {
                    updated.preferredRouteID = updated.preferredRoute?.id
                }
                if let lastSuccessfulRouteID = updated.lastSuccessfulRouteID,
                   removedRouteIDs.contains(lastSuccessfulRouteID) {
                    updated.lastSuccessfulRouteID = nil
                }
            }
            return updated
        }

        if let route = route(machineID: machine.id, hostname: machine.hostname, snapshot: snapshot) {
            if let routeIndex = updated.routes.firstIndex(where: {
                $0.kind == route.kind && $0.tailnetProfileID == route.tailnetProfileID
            }) {
                let existing = updated.routes[routeIndex]
                updated.routes[routeIndex] = RouteRecord(
                    id: existing.id,
                    machineID: updated.id,
                    kind: route.kind,
                    label: route.label,
                    hostname: route.hostname,
                    ipAddress: route.ipAddress,
                    magicDNSName: route.magicDNSName,
                    sshPort: route.sshPort,
                    usernameHint: route.usernameHint ?? existing.usernameHint,
                    companionEndpoint: route.companionEndpoint,
                    tailnetProfileID: route.tailnetProfileID,
                    requiresExternalApp: route.requiresExternalApp,
                    health: route.health,
                    lastLatencyMs: route.lastLatencyMs,
                    lastCheckedAt: route.lastCheckedAt,
                    lastSuccessAt: route.lastSuccessAt,
                    lastFailureAt: route.lastFailureAt,
                    failureReasonCode: route.failureReasonCode,
                    isRecommended: route.isRecommended,
                    isUserPinned: existing.isUserPinned,
                    publishedByCompanion: route.publishedByCompanion,
                    discoverySource: route.discoverySource,
                    trustState: existing.trustState,
                    trustedOpenSSHPublicKey: existing.trustedOpenSSHPublicKey
                )
            } else {
                updated.routes.insert(route, at: 0)
            }

            let mergedRoute = updated.routes.first(where: {
                $0.kind == route.kind && $0.tailnetProfileID == route.tailnetProfileID
            })
            let currentPreferred = updated.route(id: updated.preferredRouteID)
            if currentPreferred?.isUserPinned != true,
               currentPreferred?.isEligibleForTraffic != true,
               mergedRoute?.isEligibleForTraffic == true {
                updated.preferredRouteID = mergedRoute?.id
            }
        }

        return updated
    }

    private static func routeTargetMachineIDs(
        for plan: EmbeddedTailnetDialPlan,
        profile: TailnetProfile,
        machines: [MachineRecord]
    ) -> Set<MachineRecord.ID> {
        let exactHosts = Set(
            [plan.preferredHost, plan.magicDNSName, profile.tailnetDNSName]
                .compactMap(normalizedHost)
        )
        let hostLabels = Set(exactHosts.map(hostLabel))

        let exactHostnameMatches = machines.filter { machine in
            if let normalizedHostname = normalizedHost(machine.hostname) {
                return exactHosts.contains(normalizedHostname)
            }
            return false
        }
        if !exactHostnameMatches.isEmpty {
            return Set(exactHostnameMatches.map(\.id))
        }

        let exactRouteMatches = machines.filter { machine in
            machineMatchesExactHost(machine, exactHosts: exactHosts)
        }
        if !exactRouteMatches.isEmpty {
            return Set(exactRouteMatches.map(\.id))
        }

        let existingPublishedMatches = machines.filter { machine in
            machine.routes.contains {
                $0.kind == plan.routeKind
                    && $0.tailnetProfileID == profile.id
                    && $0.discoverySource == .tailnetProfile
            }
        }
        if !existingPublishedMatches.isEmpty {
            return Set(existingPublishedMatches.map(\.id))
        }

        let labelMatches = machines.filter { machine in
            hostLabels.contains(hostLabel(machine.hostname))
        }
        if labelMatches.count == 1 {
            return Set(labelMatches.map(\.id))
        }

        if machines.count == 1, let onlyMachine = machines.first {
            return [onlyMachine.id]
        }

        return []
    }

    private static func machineMatchesExactHost(
        _ machine: MachineRecord,
        exactHosts: Set<String>
    ) -> Bool {
        if let normalizedHostname = normalizedHost(machine.hostname),
           exactHosts.contains(normalizedHostname) {
            return true
        }

        return machine.routes.contains { route in
            [route.hostname, route.ipAddress, route.magicDNSName]
                .compactMap(normalizedHost)
                .contains { exactHosts.contains($0) }
        }
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host = host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func hostLabel(_ host: String) -> String {
        host.split(separator: ".").first.map(String.init) ?? host
    }

    private static func routeHealth(
        for health: EmbeddedTailnetRuntimeHealth,
        plan: EmbeddedTailnetDialPlan
    ) -> RouteHealthStatus {
        if plan.routeKind == .embeddedTailnet && !plan.supportsNativeSSHTransport {
            return .unavailable
        }

        return switch health.state {
        case .ready:
            .healthy
        case .degraded:
            .degraded
        case .idle, .pendingAuth, .needsRuntimeIntegration:
            .unavailable
        }
    }

    private static func failureReasonCode(
        for health: EmbeddedTailnetRuntimeHealth,
        plan: EmbeddedTailnetDialPlan
    ) -> String? {
        if plan.routeKind == .embeddedTailnet && !plan.supportsNativeSSHTransport {
            return "embedded-tailnet-ssh-transport-unwired"
        }

        return health.failureReasonCode
    }
}
