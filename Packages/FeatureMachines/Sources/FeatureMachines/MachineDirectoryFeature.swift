import Discovery
import SharedModels

public struct MachineTileModel: Hashable, Sendable {
    public var alias: String
    public var subtitle: String
    public var routeSummary: String

    public init(alias: String, subtitle: String, routeSummary: String) {
        self.alias = alias
        self.subtitle = subtitle
        self.routeSummary = routeSummary
    }
}

public enum MachineDirectoryFeature {
    public static func tile(for machine: MachineRecord) -> MachineTileModel {
        MachineTileModel(
            alias: machine.alias,
            subtitle: machine.hostname,
            routeSummary: routeSummary(for: machine)
        )
    }

    public static func routeSummary(for machine: MachineRecord) -> String {
        let recommended = machine.preferredRoute?.kind.title ?? "No route"
        let healthy = machine.routes.filter(\.isReachable).count
        return "\(recommended) · \(healthy) reachable"
    }

    public static func manualRouteHint(for draft: ManualRouteEntryDraft) -> String {
        "\(draft.kind.title) via \(draft.address)"
    }
}
