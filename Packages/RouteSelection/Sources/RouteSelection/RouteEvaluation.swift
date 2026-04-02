import SharedModels

public struct RouteEvaluation: Identifiable, Hashable, Sendable {
    public var route: RouteRecord
    public var isConfigured: Bool
    public var isAuthenticated: Bool
    public var isConnected: Bool
    public var isReachable: Bool
    public var isEligible: Bool
    public var isRecommended: Bool
    public var isActive: Bool
    public var isLastGood: Bool

    public init(
        route: RouteRecord,
        isConfigured: Bool,
        isAuthenticated: Bool,
        isConnected: Bool,
        isReachable: Bool,
        isEligible: Bool,
        isRecommended: Bool,
        isActive: Bool,
        isLastGood: Bool
    ) {
        self.route = route
        self.isConfigured = isConfigured
        self.isAuthenticated = isAuthenticated
        self.isConnected = isConnected
        self.isReachable = isReachable
        self.isEligible = isEligible
        self.isRecommended = isRecommended
        self.isActive = isActive
        self.isLastGood = isLastGood
    }

    public var id: RouteRecord.ID { route.id }
}

public enum RouteEvaluationPlanner {
    public static func evaluateRoutes(
        for machine: MachineRecord,
        lastKnownRouteKind: MachineRouteKind? = nil,
        activeRouteID: RouteRecord.ID? = nil,
        externalTailnetAppInstalled: Bool? = nil,
        allowsNearbyNetworkRoutes: Bool? = nil
    ) -> [RouteEvaluation] {
        var evaluations = machine.routes.map { route in
            let configured = route.isConfigured
            let authenticated = routeAuthenticationState(
                for: route,
                externalTailnetAppInstalled: externalTailnetAppInstalled
            )
            let active = route.id == activeRouteID
            let lastGood = route.id == machine.lastSuccessfulRouteID || (machine.lastSuccessfulRouteID == nil && route.kind == lastKnownRouteKind)
            let reachable = routeReachabilityState(
                for: route,
                externalTailnetAppInstalled: externalTailnetAppInstalled,
                allowsNearbyNetworkRoutes: allowsNearbyNetworkRoutes
            )
            let eligible = configured && authenticated && route.isEligibleForTraffic && reachable

            return RouteEvaluation(
                route: route,
                isConfigured: configured,
                isAuthenticated: authenticated,
                isConnected: active && eligible,
                isReachable: reachable,
                isEligible: eligible,
                isRecommended: false,
                isActive: active,
                isLastGood: lastGood
            )
        }

        let recommendedID = evaluations
            .sorted(by: areInRecommendedOrder)
            .first(where: \.isEligible)?
            .route
            .id

        for index in evaluations.indices {
            evaluations[index].isRecommended = evaluations[index].route.id == recommendedID
        }

        return evaluations.sorted(by: areInRecommendedOrder)
    }

    public static func recommendedRoute(
        for machine: MachineRecord,
        lastKnownRouteKind: MachineRouteKind?,
        externalTailnetAppInstalled: Bool? = nil,
        allowsNearbyNetworkRoutes: Bool? = nil
    ) -> RouteRecord? {
        evaluateRoutes(
            for: machine,
            lastKnownRouteKind: lastKnownRouteKind,
            activeRouteID: nil,
            externalTailnetAppInstalled: externalTailnetAppInstalled,
            allowsNearbyNetworkRoutes: allowsNearbyNetworkRoutes
        )
        .first(where: \.isRecommended)?
        .route
    }

    public static func sshBootstrapRoute(
        for machine: MachineRecord,
        lastKnownRouteKind: MachineRouteKind?,
        activeRouteID: RouteRecord.ID? = nil,
        externalTailnetAppInstalled: Bool? = nil,
        allowsNearbyNetworkRoutes: Bool? = nil
    ) -> RouteRecord? {
        let sshCapable = evaluateRoutes(
            for: machine,
            lastKnownRouteKind: lastKnownRouteKind,
            activeRouteID: activeRouteID,
            externalTailnetAppInstalled: externalTailnetAppInstalled,
            allowsNearbyNetworkRoutes: allowsNearbyNetworkRoutes
        )
        .filter { $0.route.kind != .companionDirect }

        if let activeRouteID,
           let activeRoute = sshCapable.first(where: { $0.route.id == activeRouteID }),
           shouldRespectStickySelection(activeRoute) {
            return activeRoute.route
        }

        if let lastKnownRouteKind,
           let lastKnownRoute = sshCapable.first(where: {
               $0.route.kind == lastKnownRouteKind && ($0.isEligible || $0.isReachable)
           }),
           shouldRespectStickySelection(lastKnownRoute) {
            return lastKnownRoute.route
        }

        if let preferredRouteID = machine.preferredRouteID,
           let preferredRoute = sshCapable.first(where: { $0.route.id == preferredRouteID }),
           shouldRespectStickySelection(preferredRoute) {
            return preferredRoute.route
        }

        return sshCapable.first(where: \.isEligible)?.route
            ?? sshCapable.first(where: \.isReachable)?.route
            ?? sshCapable.first?.route
    }

    private static func routeAuthenticationState(
        for route: RouteRecord,
        externalTailnetAppInstalled: Bool?
    ) -> Bool {
        switch route.kind {
        case .embeddedTailnet:
            route.tailnetProfileID != nil && route.health.isEligibleForTraffic
        case .externalTailnet:
            route.requiresExternalApp
                && externalTailnetAppInstalled != false
                && route.health.isEligibleForTraffic
        case .localLAN, .manualSSH:
            true
        case .companionDirect:
            route.companionEndpoint != nil
        }
    }

    private static func routeReachabilityState(
        for route: RouteRecord,
        externalTailnetAppInstalled: Bool?,
        allowsNearbyNetworkRoutes: Bool?
    ) -> Bool {
        guard route.health.isReachable else {
            return false
        }

        if route.requiresNearbyNetworkTransport, allowsNearbyNetworkRoutes == false {
            return false
        }

        if route.kind == .externalTailnet, externalTailnetAppInstalled == false {
            return false
        }

        return true
    }

    private static func areInRecommendedOrder(lhs: RouteEvaluation, rhs: RouteEvaluation) -> Bool {
        if lhs.isEligible != rhs.isEligible {
            return lhs.isEligible && !rhs.isEligible
        }
        if lhs.isLastGood != rhs.isLastGood {
            return lhs.isLastGood && !rhs.isLastGood
        }
        if lhs.isReachable != rhs.isReachable {
            return lhs.isReachable && !rhs.isReachable
        }
        if lhs.route.kind.recommendationPriority != rhs.route.kind.recommendationPriority {
            return lhs.route.kind.recommendationPriority < rhs.route.kind.recommendationPriority
        }
        if lhs.route.isUserPinned != rhs.route.isUserPinned {
            return lhs.route.isUserPinned && !rhs.route.isUserPinned
        }
        if lhs.route.lastCheckedAt != rhs.route.lastCheckedAt {
            return (lhs.route.lastCheckedAt ?? .distantPast) > (rhs.route.lastCheckedAt ?? .distantPast)
        }
        return lhs.route.label < rhs.route.label
    }

    private static func shouldRespectStickySelection(_ evaluation: RouteEvaluation) -> Bool {
        guard evaluation.isEligible || evaluation.isReachable else {
            return false
        }

        let lastFailureAt = evaluation.route.lastFailureAt ?? .distantPast
        let lastSuccessAt = evaluation.route.lastSuccessAt ?? .distantPast
        return lastFailureAt <= lastSuccessAt
    }
}

private extension RouteRecord {
    var isConfigured: Bool {
        switch kind {
        case .embeddedTailnet, .externalTailnet:
            return tailnetProfileID != nil || magicDNSName != nil || hostname != nil
        case .localLAN, .manualSSH:
            return hostname != nil || ipAddress != nil
        case .companionDirect:
            return companionEndpoint != nil
        }
    }
}

private extension MachineRouteKind {
    var recommendationPriority: Int {
        switch self {
        case .companionDirect:
            0
        case .localLAN:
            1
        case .embeddedTailnet:
            2
        case .manualSSH:
            3
        case .externalTailnet:
            4
        }
    }
}
