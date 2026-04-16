import AppState
import Foundation
import SharedModels

enum CodingOnTheGoRouting {
    static let machineWindowGroupID = "cotg.machine.session"
    static let handoffActivityType = "com.example.codingonthego.thread"

    @MainActor
    static func configure(_ activity: NSUserActivity, model: AppModel) {
        activity.isEligibleForHandoff = true
        activity.title = model.selectedMachine.map { "Resume \($0.alias)" } ?? "Resume Coding On The Go thread"
        activity.targetContentIdentifier = model.activeSession?.threadID
        if let selectedMachineID = model.selectedMachineID {
            activity.userInfo = HandoffPayload(
                machineID: selectedMachineID,
                threadID: model.activeSession?.threadID,
                routeKind: model.activeSession?.lastKnownRouteKind,
                protocolKind: model.activeSession?.lastKnownProtocol,
                workspaceRoot: model.activeSession?.workspaceRoot
            ).userInfo
        } else {
            activity.userInfo = nil
        }
    }

    static func payload(from activity: NSUserActivity) -> HandoffPayload? {
        guard let userInfo = activity.userInfo else {
            return nil
        }
        return HandoffPayload(userInfo: userInfo)
    }
}

struct HandoffPayload: Hashable {
    var machineID: MachineRecord.ID
    var threadID: String?
    var routeKind: MachineRouteKind?
    var protocolKind: CodexProtocolKind?
    var workspaceRoot: String?

    init(
        machineID: MachineRecord.ID,
        threadID: String?,
        routeKind: MachineRouteKind?,
        protocolKind: CodexProtocolKind?,
        workspaceRoot: String?
    ) {
        self.machineID = machineID
        self.threadID = threadID
        self.routeKind = routeKind
        self.protocolKind = protocolKind
        self.workspaceRoot = workspaceRoot
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let machineIDString = userInfo[HandoffPayloadKey.machineID.rawValue] as? String,
              let machineID = UUID(uuidString: machineIDString) else {
            return nil
        }

        self.init(
            machineID: machineID,
            threadID: userInfo[HandoffPayloadKey.threadID.rawValue] as? String,
            routeKind: (userInfo[HandoffPayloadKey.routeKind.rawValue] as? String)
                .flatMap(MachineRouteKind.init(rawValue:)),
            protocolKind: (userInfo[HandoffPayloadKey.protocolKind.rawValue] as? String)
                .flatMap(CodexProtocolKind.init(rawValue:)),
            workspaceRoot: userInfo[HandoffPayloadKey.workspaceRoot.rawValue] as? String
        )
    }

    var userInfo: [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            HandoffPayloadKey.machineID.rawValue: machineID.uuidString
        ]

        if let threadID {
            userInfo[HandoffPayloadKey.threadID.rawValue] = threadID
        }
        if let routeKind {
            userInfo[HandoffPayloadKey.routeKind.rawValue] = routeKind.rawValue
        }
        if let protocolKind {
            userInfo[HandoffPayloadKey.protocolKind.rawValue] = protocolKind.rawValue
        }
        if let workspaceRoot {
            userInfo[HandoffPayloadKey.workspaceRoot.rawValue] = workspaceRoot
        }

        return userInfo
    }
}

private enum HandoffPayloadKey: String {
    case machineID
    case threadID
    case routeKind
    case protocolKind
    case workspaceRoot
}
