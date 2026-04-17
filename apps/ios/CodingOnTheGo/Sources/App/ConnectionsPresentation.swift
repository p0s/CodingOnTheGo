import AppState
import RouteSelection
import SharedModels

enum MachineDirectoryOverallState: Equatable {
    case ready
    case needsSetup
    case unavailable

    var title: String {
        switch self {
        case .ready:
            "Ready"
        case .needsSetup:
            "Needs setup"
        case .unavailable:
            "Unavailable"
        }
    }
}

enum MachinePrimaryActionKind: Equatable {
    case finishSetup
    case connect
    case openCodex
    case resume

    var title: String {
        switch self {
        case .finishSetup:
            "Finish setup"
        case .connect:
            "Connect"
        case .openCodex:
            "Open Codex"
        case .resume:
            "Resume"
        }
    }
}

@MainActor
struct MachineConnectionPresentation {
    let machine: MachineRecord
    let routeEvaluations: [RouteEvaluation]
    let bestRoute: RouteRecord?
    let setupStatus: MachineSetupStatus
    let overallState: MachineDirectoryOverallState
    let primaryAction: MachinePrimaryActionKind
    let nextSetupTitle: String?
    let nextSetupDetail: String?
    let nearbyResult: NearbyMachineResult?

    init(machine: MachineRecord, model: AppModel, nearbyResult: NearbyMachineResult? = nil) {
        self.machine = machine
        self.routeEvaluations = model.routeEvaluations(for: machine)
        self.bestRoute = model.recommendedRoute(for: machine)
            ?? routeEvaluations.first(where: \.isEligible)?.route
            ?? machine.preferredRoute
        self.setupStatus = model.connectionSetupStatus(for: machine)
        self.nearbyResult = nearbyResult

        if !setupStatus.hasDetectedRoute {
            self.overallState = .needsSetup
            self.nextSetupTitle = setupStatus.nextStepTitle
            self.nextSetupDetail = setupStatus.nextStepDetail
        } else if !setupStatus.accountReady {
            self.overallState = .needsSetup
            self.nextSetupTitle = setupStatus.nextStepTitle
            self.nextSetupDetail = setupStatus.nextStepDetail
        } else if !setupStatus.sshAccessReady {
            self.overallState = .needsSetup
            self.nextSetupTitle = setupStatus.nextStepTitle
            self.nextSetupDetail = setupStatus.nextStepDetail
        } else if !setupStatus.trustReady {
            self.overallState = .needsSetup
            self.nextSetupTitle = setupStatus.nextStepTitle
            self.nextSetupDetail = setupStatus.nextStepDetail
        } else if routeEvaluations.contains(where: \.isEligible) {
            self.overallState = .ready
            self.nextSetupTitle = nil
            self.nextSetupDetail = nil
        } else {
            self.overallState = .unavailable
            self.nextSetupTitle = nil
            self.nextSetupDetail = nil
        }

        let hasRecentSession = model.recentSessions.contains { session in
            session.machineID == machine.id && session.threadID != nil
        }
        let isConnectedMachine = model.selectedMachineID == machine.id && {
            if case .connected = model.connectionState {
                return true
            }
            return false
        }()

        switch overallState {
        case .needsSetup:
            self.primaryAction = .finishSetup
        case .ready:
            if isConnectedMachine {
                self.primaryAction = .openCodex
            } else if hasRecentSession {
                self.primaryAction = .resume
            } else {
                self.primaryAction = .connect
            }
        case .unavailable:
            self.primaryAction = hasRecentSession ? .resume : .connect
        }
    }

    var savedWaysToConnectLabel: String {
        "\(machine.routes.count) saved \(machine.routes.count == 1 ? "way" : "ways")"
    }

    var bestRouteLabel: String {
        bestRoute?.label ?? "No route yet"
    }

    var bestRouteDetail: String {
        guard let bestRoute else {
            return "Add a way to connect."
        }

        if let evaluation = routeEvaluations.first(where: { $0.route.id == bestRoute.id }) {
            if evaluation.isEligible {
                return "Best now"
            }
            if evaluation.isReachable {
                return "Saved fallback"
            }
        }

        return "Unavailable"
    }

    var summaryDetail: String {
        if let nextSetupTitle, let nextSetupDetail {
            return "\(nextSetupTitle). \(nextSetupDetail)"
        }

        switch overallState {
        case .ready:
            return "\(bestRouteLabel) is ready right now."
        case .unavailable:
            return "\(bestRouteLabel) is saved, but it is not available from the current network."
        case .needsSetup:
            return "Finish setup on this iPhone before reconnecting."
        }
    }

    var nearbyBadgeTitle: String? {
        guard let nearbyResult else {
            return nil
        }

        return nearbyResult.isAlreadySaved ? "Nearby now" : "Nearby"
    }
}
