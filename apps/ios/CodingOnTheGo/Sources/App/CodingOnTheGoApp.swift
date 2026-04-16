import AppState
import Notifications
import SharedModels
import SyncEngine
import SwiftUI

@main
@MainActor
struct CodingOnTheGoApp: App {
    var body: some Scene {
        WindowGroup {
            WindowRootView(launchMachineID: nil)
        }

        WindowGroup("Machine Session", id: CodingOnTheGoRouting.machineWindowGroupID, for: String.self) { machineID in
            WindowRootView(
                launchMachineID: UUID(uuidString: machineID.wrappedValue)
            )
        } defaultValue: {
            ""
        }
    }
}

@MainActor
private struct WindowRootView: View {
    @SceneStorage("cotg.sceneID") private var sceneID = UUID().uuidString
    let launchMachineID: UUID?

    var body: some View {
        WindowContentView(sceneID: sceneID, launchMachineID: launchMachineID)
    }
}

@MainActor
private struct WindowContentView: View {
    let sceneID: String
    let launchMachineID: UUID?
    private let runtimeConfiguration: AppRuntimeConfiguration
    @State private var model: AppModel

    init(sceneID: String, launchMachineID: UUID?) {
        self.sceneID = sceneID
        self.launchMachineID = launchMachineID
        let runtimeConfiguration = AppRuntimeConfiguration.load(
            environment: ProcessInfo.processInfo.environment
        )
        self.runtimeConfiguration = runtimeConfiguration
        _model = State(
            initialValue: AppModel(
                sceneID: sceneID,
                runtimeConfiguration: runtimeConfiguration,
                syncCoordinator: SyncCoordinatorFactory.makeDefault(configuration: runtimeConfiguration),
                notificationCoordinator: BridgedNotificationCoordinator(
                    outbox: JSONNotificationOutboxStore(url: runtimeConfiguration.paths.notificationOutboxURL),
                    bridgeSubmitter: NotificationBridgeFactory.makeDefaultSubmitter(
                        configuration: runtimeConfiguration.notificationBridgeSubmission
                    ),
                    localDeliverer: UserNotificationCenterAdapter()
                )
            )
        )
    }

    var body: some View {
        AppRootView(model: model, launchMachineID: launchMachineID)
    }
}
