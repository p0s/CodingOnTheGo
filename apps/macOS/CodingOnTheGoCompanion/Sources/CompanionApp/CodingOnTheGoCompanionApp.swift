import CompanionHost
import SharedModels
import SwiftUI

@main
struct CodingOnTheGoCompanionApp: App {
    @State private var model = CompanionAppModel(
        runtimeConfiguration: AppRuntimeConfiguration.load(
            environment: ProcessInfo.processInfo.environment
        )
    )

    var body: some Scene {
        WindowGroup {
            CompanionDashboardView(model: model)
                .frame(minWidth: 780, minHeight: 520)
        }
    }
}
