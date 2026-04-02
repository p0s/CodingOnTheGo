import Foundation
import SharedModels

public enum CapabilityCheckState: String, Sendable {
    case ready
    case warning
    case blocked
}

public enum CapabilityCheckID: String, Hashable, Sendable {
    case sshReachability
    case remoteLogin
    case sshAuthentication
    case hostKeyTrust
    case codexCLI
    case appServer
    case webSocketUpgrade
    case git
    case codexMacHandoff
}

public enum CapabilityReasonCode: String, Hashable, Sendable {
    case sshReachable
    case sshUnreachable
    case remoteLoginEnabled
    case remoteLoginDisabled
    case authenticationConfigured
    case authenticationMissing
    case hostKeyTrusted
    case hostKeyUntrusted
    case awaitingTrustedSSH
    case codexInstalled
    case codexMissing
    case appServerAvailable
    case appServerUnavailable
    case websocketUpgradeAvailable
    case websocketUpgradeUnavailable
    case gitAvailable
    case gitUnavailable
    case codexMacAppInstalled
    case codexMacAppUnavailable
}

public struct CapabilityCheck: Hashable, Sendable {
    public var id: CapabilityCheckID
    public var title: String
    public var state: CapabilityCheckState
    public var reasonCode: CapabilityReasonCode
    public var detail: String?

    public init(
        id: CapabilityCheckID,
        title: String,
        state: CapabilityCheckState,
        reasonCode: CapabilityReasonCode,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.reasonCode = reasonCode
        self.detail = detail
    }
}

public struct HostCapabilityDiagnostics: Hashable, Sendable {
    public var sshReachable: Bool
    public var remoteLoginEnabled: Bool
    public var codexInstalled: Bool
    public var appServerAvailable: Bool
    public var websocketSupported: Bool
    public var authConfigured: Bool
    public var hostKeyTrusted: Bool
    public var gitAvailable: Bool
    public var gitVersion: String?
    public var codexVersion: String?
    public var codexMacAppInstalled: Bool
    public var localNetworkHostName: String?
    public var localNetworkAddress: String?
    public var externalTailnetAppInstalledOnHost: Bool
    public var externalTailnetRunningOnHost: Bool
    public var externalTailnetDNSName: String?
    public var externalTailnetIPAddress: String?
    public var companionAppInstalled: Bool
    public var resolvedRuntime: CodexResolvedRuntime?

    public init(
        sshReachable: Bool,
        remoteLoginEnabled: Bool,
        codexInstalled: Bool,
        appServerAvailable: Bool,
        websocketSupported: Bool,
        authConfigured: Bool,
        hostKeyTrusted: Bool,
        gitAvailable: Bool = false,
        gitVersion: String? = nil,
        codexVersion: String? = nil,
        codexMacAppInstalled: Bool = false,
        localNetworkHostName: String? = nil,
        localNetworkAddress: String? = nil,
        externalTailnetAppInstalledOnHost: Bool = false,
        externalTailnetRunningOnHost: Bool = false,
        externalTailnetDNSName: String? = nil,
        externalTailnetIPAddress: String? = nil,
        companionAppInstalled: Bool = false,
        resolvedRuntime: CodexResolvedRuntime? = nil
    ) {
        self.sshReachable = sshReachable
        self.remoteLoginEnabled = remoteLoginEnabled
        self.codexInstalled = codexInstalled
        self.appServerAvailable = appServerAvailable
        self.websocketSupported = websocketSupported
        self.authConfigured = authConfigured
        self.hostKeyTrusted = hostKeyTrusted
        self.gitAvailable = gitAvailable
        self.gitVersion = gitVersion
        self.codexVersion = codexVersion
        self.codexMacAppInstalled = codexMacAppInstalled
        self.localNetworkHostName = localNetworkHostName
        self.localNetworkAddress = localNetworkAddress
        self.externalTailnetAppInstalledOnHost = externalTailnetAppInstalledOnHost
        self.externalTailnetRunningOnHost = externalTailnetRunningOnHost
        self.externalTailnetDNSName = externalTailnetDNSName
        self.externalTailnetIPAddress = externalTailnetIPAddress
        self.companionAppInstalled = companionAppInstalled
        self.resolvedRuntime = resolvedRuntime
    }
}

public struct HostCapabilityCommandResult: Hashable, Sendable {
    public var exitStatus: Int32
    public var standardOutput: String
    public var errorOutput: String

    public init(exitStatus: Int32, standardOutput: String = "", errorOutput: String = "") {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.errorOutput = errorOutput
    }
}

public protocol HostCapabilityCommandRunning: Sendable {
    func run(command: String) async throws -> HostCapabilityCommandResult
}

public struct HostCapabilityReport: Hashable, Sendable {
    public var checks: [CapabilityCheck]

    public init(checks: [CapabilityCheck]) {
        self.checks = checks
    }

    public var isSafeLaneReady: Bool {
        checks.allSatisfy {
            $0.state == .ready || [
                .webSocketUpgrade,
                .git,
                .codexMacHandoff
            ].contains($0.id)
        }
    }

    public var canUseOptimizationLane: Bool {
        checks.first(where: { $0.id == .webSocketUpgrade })?.state == .ready
    }

    public func check(_ id: CapabilityCheckID) -> CapabilityCheck? {
        checks.first(where: { $0.id == id })
    }
}

// The probe owns structured facts and stable reason codes only.
// User-facing copy is formatted separately so runtime logic does not depend on prose strings.
public enum HostCapabilityCheckFormatter {
    public static func summary(for check: CapabilityCheck) -> String {
        switch check.reasonCode {
        case .sshReachable:
            return "SSH is reachable on the selected route."
        case .sshUnreachable:
            return "The selected route cannot reach the SSH port."
        case .remoteLoginEnabled:
            return "Remote Login is enabled."
        case .remoteLoginDisabled:
            return "Remote Login appears to be off."
        case .authenticationConfigured:
            return "The client has a usable SSH credential."
        case .authenticationMissing:
            return "No working SSH credential is configured yet."
        case .hostKeyTrusted:
            return "The host key is trusted."
        case .hostKeyUntrusted:
            return "The host key has not been trusted or no longer matches."
        case .awaitingTrustedSSH:
            switch check.id {
            case .codexCLI:
                return "Complete SSH trust and authentication before probing Codex on the host."
            case .appServer:
                return "Connect with trusted SSH credentials before probing codex app-server on the host."
            case .git:
                return "Connect first to probe Git and unlock workspace tooling."
            case .codexMacHandoff:
                return "Connect first to probe whether the Codex Mac app is available for handoff."
            default:
                return "Complete SSH trust and authentication before probing the host runtime."
            }
        case .codexInstalled:
            return check.detail ?? "Codex is installed on the host."
        case .codexMissing:
            return "Codex is missing from the remote host."
        case .appServerAvailable:
            return "codex app-server is available for the safe lane."
        case .appServerUnavailable:
            return "codex app-server is unavailable or too old."
        case .websocketUpgradeAvailable:
            return "Loopback websocket mode can be attempted as an optimization."
        case .websocketUpgradeUnavailable:
            return "The host can stay on stdio; websocket upgrade is unavailable."
        case .gitAvailable:
            return check.detail ?? "Git is available for workspace tools."
        case .gitUnavailable:
            return "Git is unavailable, so review and revert tools will stay limited."
        case .codexMacAppInstalled:
            return "The Codex Mac app is installed for thread handoff."
        case .codexMacAppUnavailable:
            return "Codex Mac app handoff is unavailable on the host."
        }
    }

    public static func remediation(for check: CapabilityCheck) -> String? {
        switch check.reasonCode {
        case .sshReachable,
             .remoteLoginEnabled,
             .authenticationConfigured,
             .hostKeyTrusted,
             .codexInstalled,
             .appServerAvailable,
             .websocketUpgradeAvailable,
             .gitAvailable,
             .codexMacAppInstalled:
            return nil
        case .sshUnreachable:
            return "Try another route or confirm that Remote Login is enabled on the Mac."
        case .remoteLoginDisabled:
            return "On the Mac, open System Settings -> General -> Sharing -> turn on Remote Login."
        case .authenticationMissing:
            return "Import or generate a key, or provide a password-backed login path."
        case .hostKeyUntrusted:
            return "Review the SSH fingerprint and re-trust the host before connecting."
        case .awaitingTrustedSSH:
            return "Trust the host key and save a working SSH credential before judging the host runtime."
        case .codexMissing:
            return "Install Codex on the Mac before attempting a session."
        case .appServerUnavailable:
            return "Update Codex so codex app-server is present."
        case .websocketUpgradeUnavailable:
            return "No action required. The safe SSH stdio lane remains valid."
        case .gitUnavailable:
            return "Install Git on the Mac to enable workspace status, diff, and revert features."
        case .codexMacAppUnavailable:
            return "Install the Codex Mac app on the Mac if you want direct handoff from the mobile session."
        }
    }
}

public enum HostCapabilityProbe {
    public static func assess(_ diagnostics: HostCapabilityDiagnostics) -> HostCapabilityReport {
        let canProbeHost = diagnostics.sshReachable
            && diagnostics.remoteLoginEnabled
            && diagnostics.authConfigured
            && diagnostics.hostKeyTrusted

        let sshCheck = CapabilityCheck(
            id: .sshReachability,
            title: "SSH Reachability",
            state: diagnostics.sshReachable ? .ready : .blocked,
            reasonCode: diagnostics.sshReachable ? .sshReachable : .sshUnreachable
        )

        let remoteLoginCheck = CapabilityCheck(
            id: .remoteLogin,
            title: "Remote Login",
            state: diagnostics.remoteLoginEnabled ? .ready : .blocked,
            reasonCode: diagnostics.remoteLoginEnabled ? .remoteLoginEnabled : .remoteLoginDisabled
        )

        let authCheck = CapabilityCheck(
            id: .sshAuthentication,
            title: "SSH Authentication",
            state: diagnostics.authConfigured ? .ready : .blocked,
            reasonCode: diagnostics.authConfigured ? .authenticationConfigured : .authenticationMissing
        )

        let trustCheck = CapabilityCheck(
            id: .hostKeyTrust,
            title: "Host Key Trust",
            state: diagnostics.hostKeyTrusted ? .ready : .blocked,
            reasonCode: diagnostics.hostKeyTrusted ? .hostKeyTrusted : .hostKeyUntrusted
        )

        let codexCheck = CapabilityCheck(
            id: .codexCLI,
            title: "Codex CLI",
            state: !canProbeHost ? .warning : (diagnostics.codexInstalled ? .ready : .blocked),
            reasonCode: !canProbeHost ? .awaitingTrustedSSH : (diagnostics.codexInstalled ? .codexInstalled : .codexMissing),
            detail: hostRuntimeDetail(for: diagnostics)
        )

        let appServerCheck = CapabilityCheck(
            id: .appServer,
            title: "App Server",
            state: !canProbeHost ? .warning : (diagnostics.appServerAvailable ? .ready : .blocked),
            reasonCode: !canProbeHost ? .awaitingTrustedSSH : (diagnostics.appServerAvailable ? .appServerAvailable : .appServerUnavailable)
        )

        let websocketCheck = CapabilityCheck(
            id: .webSocketUpgrade,
            title: "WebSocket Upgrade",
            state: diagnostics.websocketSupported ? .ready : .warning,
            reasonCode: diagnostics.websocketSupported ? .websocketUpgradeAvailable : .websocketUpgradeUnavailable
        )

        let gitCheck = CapabilityCheck(
            id: .git,
            title: "Git",
            state: !canProbeHost ? .warning : (diagnostics.gitAvailable ? .ready : .warning),
            reasonCode: !canProbeHost ? .awaitingTrustedSSH : (diagnostics.gitAvailable ? .gitAvailable : .gitUnavailable),
            detail: diagnostics.gitVersion
        )

        let codexMacCheck = CapabilityCheck(
            id: .codexMacHandoff,
            title: "Codex Mac Handoff",
            state: !canProbeHost ? .warning : (diagnostics.codexMacAppInstalled ? .ready : .warning),
            reasonCode: !canProbeHost ? .awaitingTrustedSSH : (diagnostics.codexMacAppInstalled ? .codexMacAppInstalled : .codexMacAppUnavailable)
        )

        return HostCapabilityReport(
            checks: [
                sshCheck,
                remoteLoginCheck,
                authCheck,
                trustCheck,
                codexCheck,
                appServerCheck,
                websocketCheck,
                gitCheck,
                codexMacCheck
            ]
        )
    }
}

public enum HostCapabilityRuntimeProbe {
    public static func collect(
        base: HostCapabilityDiagnostics,
        using runner: any HostCapabilityCommandRunning
    ) async -> HostCapabilityDiagnostics {
        var diagnostics = base
        let shellPathPrefix = "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; "

        if let runtimeResult = try? await runner.run(command: CodexRuntimeDiscovery.summaryCommand()),
           runtimeResult.exitStatus == 0,
           let discovered = CodexRuntimeDiscovery.parseSummary(runtimeResult.standardOutput) {
            diagnostics.codexInstalled = true
            diagnostics.codexVersion = discovered.runtime.version
            diagnostics.appServerAvailable = discovered.appServerAvailable
            diagnostics.websocketSupported = discovered.websocketSupported
            diagnostics.resolvedRuntime = discovered.runtime
        } else {
            diagnostics.codexInstalled = false
            diagnostics.codexVersion = nil
            diagnostics.appServerAvailable = false
            diagnostics.websocketSupported = false
            diagnostics.resolvedRuntime = nil
        }

        if let gitResult = try? await runner.run(command: "bash -lc '\(shellPathPrefix)git --version'"),
           gitResult.exitStatus == 0 {
            diagnostics.gitAvailable = true
            diagnostics.gitVersion = firstNonEmptyLine(in: gitResult.standardOutput)
        } else {
            diagnostics.gitAvailable = false
            diagnostics.gitVersion = nil
        }

        if let handoffResult = try? await runner.run(command: "bash -lc 'open -Ra Codex'") {
            diagnostics.codexMacAppInstalled = handoffResult.exitStatus == 0
        }

        if let hostNameResult = try? await runner.run(
            command: "bash -lc 'scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null'"
        ) {
            diagnostics.localNetworkHostName = normalizedHostName(from: hostNameResult)
        }

        if let lanAddressResult = try? await runner.run(
            command: "bash -lc 'for iface in en0 en1 bridge0; do ip=$(ipconfig getifaddr \"$iface\" 2>/dev/null || true); if [[ -n \"$ip\" ]]; then echo \"$ip\"; break; fi; done'"
        ) {
            diagnostics.localNetworkAddress = firstNonEmptyLine(in: lanAddressResult.standardOutput)
        }

        if let tailscalePresenceResult = try? await runner.run(command: "bash -lc 'open -Ra Tailscale'") {
            diagnostics.externalTailnetAppInstalledOnHost = tailscalePresenceResult.exitStatus == 0
        }

        if let tailscaleStatusResult = try? await runner.run(
            command: "bash -lc 'if command -v tailscale >/dev/null 2>&1; then tailscale status --json; elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json; else exit 1; fi'"
        ), tailscaleStatusResult.exitStatus == 0,
           let tailscaleStatus = decodeTailscaleStatus(from: tailscaleStatusResult.standardOutput) {
            diagnostics.externalTailnetRunningOnHost = tailscaleStatus.selfNode?.online ?? false
            diagnostics.externalTailnetDNSName = normalizedTailnetDNSName(tailscaleStatus.selfNode?.dnsName)
            diagnostics.externalTailnetIPAddress = tailscaleStatus.selfNode?.tailscaleIPs?.first(where: \.isIPv4Address)
        }

        if let companionResult = try? await runner.run(command: "bash -lc 'open -Ra \"Coding On The Go Companion\"'") {
            diagnostics.companionAppInstalled = companionResult.exitStatus == 0
        }

        return diagnostics
    }

    private static func firstNonEmptyLine(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func normalizedHostName(from result: HostCapabilityCommandResult) -> String? {
        guard result.exitStatus == 0,
              let hostName = firstNonEmptyLine(in: result.standardOutput) else {
            return nil
        }

        let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedTailnetDNSName(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeTailscaleStatus(from output: String) -> TailscaleStatusEnvelope? {
        guard let data = output.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(TailscaleStatusEnvelope.self, from: data)
    }

}

private func hostRuntimeDetail(for diagnostics: HostCapabilityDiagnostics) -> String? {
    guard let runtime = diagnostics.resolvedRuntime else {
        return diagnostics.codexVersion.map { "\($0) is installed on the host." }
    }

    let version = runtime.version ?? "Codex runtime"
    return "\(version) at \(runtime.binaryPath) (\(runtime.provenance.rawValue))."
}

private struct TailscaleStatusEnvelope: Decodable {
    var selfNode: SelfNode?

    private enum CodingKeys: String, CodingKey {
        case selfNode = "Self"
    }

    struct SelfNode: Decodable {
        var dnsName: String?
        var tailscaleIPs: [String]?
        var online: Bool?

        private enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
            case tailscaleIPs = "TailscaleIPs"
            case online = "Online"
        }
    }
}

private extension String {
    var isIPv4Address: Bool {
        split(separator: ".").count == 4 && split(separator: ".").allSatisfy { segment in
            Int(segment).map { (0 ... 255).contains($0) } ?? false
        }
    }
}
