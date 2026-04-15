import Foundation
import HostBootstrap
import SharedModels

public enum ConnectionFallbackSuggestionKind: String, Hashable, Sendable {
    case sameLAN
    case externalTailnet
    case manualSSH
    case companionHint
}

public struct ConnectionFallbackSuggestion: Identifiable, Hashable, Sendable {
    public var kind: ConnectionFallbackSuggestionKind
    public var title: String
    public var detail: String
    public var actionTitle: String?

    public init(
        kind: ConnectionFallbackSuggestionKind,
        title: String,
        detail: String,
        actionTitle: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
    }

    public var id: ConnectionFallbackSuggestionKind { kind }

    public var accessibilityIdentifier: String {
        "connection-fallback-suggestion-\(kind.rawValue)"
    }
}

public extension AppModel {
    var connectionFallbackSuggestions: [ConnectionFallbackSuggestion] {
        guard !isDemoModeEnabled,
              let machine = selectedMachine,
              let diagnostics = runtimeCapabilityDiagnostics else {
            return []
        }

        var suggestions: [ConnectionFallbackSuggestion] = []

        if machine.route(for: .localLAN) == nil,
           let localAddress = detectedLocalRouteAddress(from: diagnostics) {
            suggestions.append(
                ConnectionFallbackSuggestion(
                    kind: .sameLAN,
                    title: "Add same-Wi-Fi fallback",
                    detail: "This Mac reports \(localAddress) as its local-network identity. Save it now so desk-side reconnects do not depend on tailnet state.",
                    actionTitle: "Add route"
                )
            )
        }

        if machine.route(for: .externalTailnet) == nil,
           let tailnetAddress = detectedTailnetRouteAddress(from: diagnostics) {
            let detail: String
            let actionTitle: String?
            if externalTailnetAppInstalled == false {
                detail = "This Mac reports \(tailnetAddress) over Tailscale. Install the Tailscale app on this device, then save it as a fallback route."
                actionTitle = nil
            } else if diagnostics.externalTailnetRunningOnHost {
                detail = "This Mac reports \(tailnetAddress) over Tailscale. Save it now so you have a private-network fallback away from the current route."
                actionTitle = "Add route"
            } else {
                detail = "This Mac has Tailscale installed and exposes \(tailnetAddress), but it is not currently online. Save it now and validate it when the host tailnet comes back."
                actionTitle = "Add route"
            }

            suggestions.append(
                ConnectionFallbackSuggestion(
                    kind: .externalTailnet,
                    title: "Add Tailscale fallback",
                    detail: detail,
                    actionTitle: actionTitle
                )
            )
        }

        if machine.route(for: .manualSSH) == nil,
           let currentRoute = currentConnectionFallbackSourceRoute(for: machine),
           currentRoute.kind == .localLAN {
            let rescueAddress = currentRoute.address
            suggestions.append(
                ConnectionFallbackSuggestion(
                    kind: .manualSSH,
                    title: "Save manual SSH rescue route",
                    detail: "Keep \(rescueAddress) as an explicit SSH fallback for recovery, host-key repair, or direct reconnects when discovery changes.",
                    actionTitle: "Save fallback"
                )
            )
        }

        if diagnostics.companionAppInstalled,
           machine.route(for: .companionDirect) == nil {
            suggestions.append(
                ConnectionFallbackSuggestion(
                    kind: .companionHint,
                    title: "Companion detected on the Mac",
                    detail: "Coding On The Go Companion is installed on this Mac. Starting it later can publish reconnect metadata and unlock enhanced host mode."
                )
            )
        }

        return suggestions
    }

    func applyConnectionFallbackSuggestion(_ suggestion: ConnectionFallbackSuggestion) {
        guard let machine = selectedMachine else {
            return
        }

        switch suggestion.kind {
        case .sameLAN:
            guard let address = runtimeCapabilityDiagnostics.flatMap({ detectedLocalRouteAddress(from: $0) }) else {
                return
            }
            addManualRoute(
                label: "Same Wi-Fi",
                address: address,
                kind: .localLAN,
                usernameHint: machine.lastKnownUser,
                port: 22
            )
        case .externalTailnet:
            guard externalTailnetAppInstalled != false,
                  let address = runtimeCapabilityDiagnostics.flatMap({ detectedTailnetRouteAddress(from: $0) }) else {
                return
            }
            addManualRoute(
                label: "External Tailscale",
                address: address,
                kind: .externalTailnet,
                usernameHint: machine.lastKnownUser,
                port: 22
            )
        case .manualSSH:
            guard let currentRoute = currentConnectionFallbackSourceRoute(for: machine),
                  currentRoute.kind == .localLAN else {
                return
            }
            addManualRoute(
                label: "Manual SSH",
                address: currentRoute.address,
                kind: .manualSSH,
                usernameHint: currentRoute.usernameHint ?? machine.lastKnownUser,
                port: currentRoute.sshPort
            )
        case .companionHint:
            return
        }
    }

    var hasConnectionFallbackSuggestions: Bool {
        !connectionFallbackSuggestions.isEmpty
    }

    func currentConnectionFallbackSourceRoute(for machine: MachineRecord) -> RouteRecord? {
        if let activeRouteID = activeSession?.routeID,
           let activeRoute = machine.route(id: activeRouteID) {
            return activeRoute
        }

        return selectedBootstrapRoute
    }

    func detectedLocalRouteAddress(from diagnostics: HostCapabilityDiagnostics) -> String? {
        if let hostName = diagnostics.localNetworkHostName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostName.isEmpty {
            return hostName.hasSuffix(".local") ? hostName : "\(hostName).local"
        }

        if let address = diagnostics.localNetworkAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return address
        }

        return nil
    }

    func detectedTailnetRouteAddress(from diagnostics: HostCapabilityDiagnostics) -> String? {
        if let dnsName = diagnostics.externalTailnetDNSName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dnsName.isEmpty {
            return dnsName
        }

        if let address = diagnostics.externalTailnetIPAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return address
        }

        return nil
    }
}
