import CompanionHost
import CodexRPC
import Foundation
import HostBootstrap
import SharedModels
import SSHTransport
import TailnetEmbedded

public enum ConnectionLane: String, CaseIterable, Identifiable, Sendable {
    case embeddedTailnet
    case sameLAN
    case sshBootstrap
    case stdioAppServer
    case sshForwardedLoopbackWebSocket
    case codexWebSocketEndpoint
    case manualRescue

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .embeddedTailnet:
            "Embedded Tailscale"
        case .sameLAN:
            "Same-LAN Route"
        case .sshBootstrap:
            "SSH Bootstrap"
        case .stdioAppServer:
            "stdio App Server"
        case .sshForwardedLoopbackWebSocket:
            "SSH-Forwarded WebSocket"
        case .codexWebSocketEndpoint:
            "Codex WebSocket"
        case .manualRescue:
            "Manual Rescue"
        }
    }
}

public enum ConnectionStepReadiness: String, Sendable {
    case ready
    case standby
    case blocked
}

public struct ConnectionStep: Identifiable, Hashable, Sendable {
    public var lane: ConnectionLane
    public var route: MachineRouteKind?
    public var bootstrap: BootstrapStrategy?
    public var protocolKind: CodexProtocolKind?
    public var readiness: ConnectionStepReadiness
    public var summary: String

    public init(
        lane: ConnectionLane,
        route: MachineRouteKind? = nil,
        bootstrap: BootstrapStrategy? = nil,
        protocolKind: CodexProtocolKind? = nil,
        readiness: ConnectionStepReadiness,
        summary: String
    ) {
        self.lane = lane
        self.route = route
        self.bootstrap = bootstrap
        self.protocolKind = protocolKind
        self.readiness = readiness
        self.summary = summary
    }

    public var id: ConnectionLane { lane }
}

public struct RuntimePrioritySnapshot: Hashable, Sendable {
    public var machine: MachineRecord
    public var embeddedTailnet: EmbeddedTailnetStatus
    public var sameLANReady: Bool
    public var externalTailnetReady: Bool
    public var sshBootstrap: SSHBootstrapStatus
    public var hostBootstrap: HostBootstrapStatus
    public var codexTransport: CodexTransportStatus
    public var companion: CompanionPresenceStatus

    public init(
        machine: MachineRecord,
        embeddedTailnet: EmbeddedTailnetStatus,
        sameLANReady: Bool,
        externalTailnetReady: Bool,
        sshBootstrap: SSHBootstrapStatus,
        hostBootstrap: HostBootstrapStatus,
        codexTransport: CodexTransportStatus,
        companion: CompanionPresenceStatus
    ) {
        self.machine = machine
        self.embeddedTailnet = embeddedTailnet
        self.sameLANReady = sameLANReady
        self.externalTailnetReady = externalTailnetReady
        self.sshBootstrap = sshBootstrap
        self.hostBootstrap = hostBootstrap
        self.codexTransport = codexTransport
        self.companion = companion
    }

    #if DEBUG
    public static func preview(machine: MachineRecord) -> Self {
        let embeddedRoute = machine.route(for: .embeddedTailnet)
        let lanRoute = machine.route(for: .localLAN)
        let directEndpointRoute = machine.route(for: .companionDirect)
        let bootstrapRoute = machine.preferredRoute

        return Self(
            machine: machine,
            embeddedTailnet: EmbeddedTailnetStatus(
                isInstalled: embeddedRoute != nil,
                authState: embeddedRoute == nil ? .signedOut : .authenticated,
                isReachable: embeddedRoute?.isReachable ?? false,
                controlURL: URL(string: "https://controlplane.tailscale.com")
            ),
            sameLANReady: lanRoute?.isReachable ?? false,
            externalTailnetReady: machine.route(for: .externalTailnet)?.isReachable ?? false,
            sshBootstrap: SSHBootstrapStatus(
                remoteLoginEnabled: machine.capabilities.remoteLoginEnabled,
                credentialsConfigured: machine.credentialRef != nil,
                hostKeyVerified: bootstrapRoute?.isReachable ?? false
            ),
            hostBootstrap: HostBootstrapStatus(
                codexInstalled: machine.capabilities.codexInstalled,
                stdioAppServerReady: machine.capabilities.remoteLoginEnabled && machine.capabilities.codexInstalled,
                websocketReuseAvailable: machine.capabilities.websocketAppServerSupported
            ),
            codexTransport: CodexTransportStatus(
                stdioAvailable: machine.capabilities.codexInstalled,
                websocketAvailable: machine.capabilities.websocketAppServerSupported
            ),
            companion: CompanionPresenceStatus(
                isInstalled: machine.capabilities.companionInstalled,
                isReachable: directEndpointRoute?.isReachable ?? false,
                supportsEnhancedHostMode: machine.capabilities.companionInstalled
            )
        )
    }
    #endif
}

public enum RuntimePriorityPlanner {
    public static func plan(for snapshot: RuntimePrioritySnapshot) -> [ConnectionStep] {
        // Hard cutover contract: a reachable Codex app-server websocket owns the
        // live lane. SSH remains bootstrap, repair, and fallback.
        let preferredFallbackRouteKind = RouteEvaluationPlanner.sshBootstrapRoute(
            for: snapshot.machine,
            lastKnownRouteKind: snapshot.machine.lastSuccessfulRoute?.kind
        )?.kind ?? snapshot.machine.routes.first(where: { $0.kind != .companionDirect })?.kind
        let directEndpointRoute = snapshot.machine.route(for: .companionDirect)
        let directEndpointReady = directEndpointRoute?.isReachable == true && directEndpointRoute?.companionEndpoint != nil
        let directEndpointBootstrap: BootstrapStrategy = directEndpointRoute?.publishedByCompanion == true
            || directEndpointRoute?.discoverySource == .companionAdvertisement
            ? .companionManaged
            : .codexAppServerWebSocket
        let embeddedReady = snapshot.embeddedTailnet.readyForConnection
        let lanReady = snapshot.sameLANReady
        let externalReady = snapshot.externalTailnetReady
        let sshReady = snapshot.sshBootstrap.readyForBootstrap
        let stdioReady = sshReady && snapshot.hostBootstrap.codexInstalled && snapshot.hostBootstrap.stdioAppServerReady && snapshot.codexTransport.stdioAvailable
        let websocketReady = stdioReady && snapshot.hostBootstrap.websocketReuseAvailable && snapshot.codexTransport.websocketAvailable

        return [
            ConnectionStep(
                lane: .codexWebSocketEndpoint,
                route: .companionDirect,
                bootstrap: directEndpointBootstrap,
                protocolKind: .directEndpoint,
                readiness: directEndpointReady ? .ready : .blocked,
                summary: directEndpointReady ? "Primary live mirror lane is a reachable Codex app-server websocket endpoint." : "No reachable Codex app-server websocket endpoint is saved."
            ),
            ConnectionStep(
                lane: .embeddedTailnet,
                route: .embeddedTailnet,
                bootstrap: .standardSSH,
                protocolKind: .stdio,
                readiness: embeddedReady ? (directEndpointReady ? .standby : .ready) : .blocked,
                summary: embeddedReady ? "SSH fallback route is healthy for bootstrap and repair." : "Requires an authenticated embedded tailnet route."
            ),
            ConnectionStep(
                lane: .sameLAN,
                route: .localLAN,
                bootstrap: .standardSSH,
                protocolKind: .stdio,
                readiness: lanReady ? (directEndpointReady || embeddedReady || externalReady ? .standby : .ready) : .blocked,
                summary: lanReady ? "Same-LAN SSH fallback can reach \(snapshot.machine.alias) on the current network." : "No same-LAN route is currently reachable."
            ),
            ConnectionStep(
                lane: .sshBootstrap,
                route: preferredFallbackRouteKind ?? .manualSSH,
                bootstrap: .standardSSH,
                readiness: sshReady ? (directEndpointReady ? .standby : .ready) : .blocked,
                summary: sshReady ? "SSH bootstrap is available for setup, repair, and fallback." : "SSH bootstrap still needs Remote Login, credentials, or host verification."
            ),
            ConnectionStep(
                lane: .sshForwardedLoopbackWebSocket,
                route: preferredFallbackRouteKind,
                bootstrap: .standardSSH,
                protocolKind: .websocket,
                readiness: websocketReady ? (directEndpointReady ? .standby : .ready) : .blocked,
                summary: websocketReady ? "SSH-forwarded Codex websocket is available when no direct websocket endpoint is reachable." : "Loopback websocket upgrade is not healthy or not supported."
            ),
            ConnectionStep(
                lane: .stdioAppServer,
                route: preferredFallbackRouteKind,
                bootstrap: .standardSSH,
                protocolKind: .stdio,
                readiness: stdioReady ? (directEndpointReady || websocketReady ? .standby : .ready) : .blocked,
                summary: stdioReady ? "SSH stdio fallback is available for repair and compatibility." : "Codex app-server stdio is not ready yet."
            ),
            ConnectionStep(
                lane: .manualRescue,
                bootstrap: .manual,
                protocolKind: .directEndpoint,
                readiness: .standby,
                summary: "Advanced-only fallback for direct endpoints and recovery."
            )
        ]
    }
}

public enum ReconnectPlanner {
    public static func recommendedRoute(
        for machine: MachineRecord,
        lastKnownRouteKind: MachineRouteKind?
    ) -> RouteRecord? {
        RouteEvaluationPlanner.recommendedRoute(
            for: machine,
            lastKnownRouteKind: lastKnownRouteKind
        ) ?? machine.routes.first(where: \.isReachable) ?? machine.routes.first
    }
}
