import CompanionHost
import Foundation
import Observation
import SharedModels
#if canImport(ServiceManagement)
import ServiceManagement
#endif

@MainActor
@Observable
final class CompanionAppModel {
    @ObservationIgnored private let controller: CompanionServiceController
    @ObservationIgnored private let loginItemController: any CompanionLoginItemControlling

    var snapshot: CompanionHostSnapshot = .empty
    var loginItemStatus: CompanionLoginItemStatus = .unsupported("Launch-at-login is unavailable in this build.")
    var errorMessage: String?
    var actionState: CompanionActionState = .refreshing
    var statusEvents: [CompanionStatusEvent] = []
    var lastUpdatedAt: Date?

    init(
        runtimeConfiguration: AppRuntimeConfiguration = .localOnly(),
        controller: CompanionServiceController? = nil,
        loginItemController: any CompanionLoginItemControlling = SMAppServiceLoginItemController()
    ) {
        self.controller = controller ?? CompanionServiceController(runtimeConfiguration: runtimeConfiguration)
        self.loginItemController = loginItemController
        refresh()
    }

    func refresh() {
        actionState = .refreshing
        Task {
            let snapshot = await controller.refreshSnapshot()
            await MainActor.run {
                self.apply(snapshot, summary: "Refreshed companion state.")
            }
        }
    }

    func startSharedListener() {
        actionState = .startingListener
        Task {
            do {
                let snapshot = try await controller.startSharedListener()
                await MainActor.run {
                    self.apply(snapshot, summary: "Started the shared listener.")
                }
            } catch {
                await MainActor.run {
                    self.actionState = .failed
                    self.errorMessage = error.localizedDescription
                    self.recordEvent(
                        level: .error,
                        summary: "Start listener failed.",
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }

    func stopSharedListener() {
        actionState = .stoppingListener
        Task {
            do {
                let snapshot = try await controller.stopSharedListener()
                await MainActor.run {
                    self.apply(snapshot, summary: "Stopped the shared listener.")
                }
            } catch {
                await MainActor.run {
                    self.actionState = .failed
                    self.errorMessage = error.localizedDescription
                    self.recordEvent(
                        level: .error,
                        summary: "Stop listener failed.",
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }

    func enableLaunchAtLogin() {
        actionState = .updatingLoginItem
        do {
            loginItemStatus = try loginItemController.enable()
            errorMessage = nil
            actionState = .idle
            recordEvent(level: .info, summary: "Enabled launch at login.", detail: loginItemStatus.detail)
        } catch {
            actionState = .failed
            errorMessage = error.localizedDescription
            recordEvent(level: .error, summary: "Enable launch at login failed.", detail: error.localizedDescription)
        }
    }

    func disableLaunchAtLogin() {
        actionState = .updatingLoginItem
        do {
            loginItemStatus = try loginItemController.disable()
            errorMessage = nil
            actionState = .idle
            recordEvent(level: .info, summary: "Disabled launch at login.", detail: loginItemStatus.detail)
        } catch {
            actionState = .failed
            errorMessage = error.localizedDescription
            recordEvent(level: .error, summary: "Disable launch at login failed.", detail: error.localizedDescription)
        }
    }

    func openCodexMac() {
        actionState = .launchingCodex
        Task {
            do {
                try await controller.openCodexMac()
                await MainActor.run {
                    self.errorMessage = nil
                    self.actionState = .idle
                    self.recordEvent(
                        level: .info,
                        summary: "Opened Codex Mac.",
                        detail: "Requested the local Codex Mac app to foreground."
                    )
                }
            } catch {
                await MainActor.run {
                    self.actionState = .failed
                    self.errorMessage = error.localizedDescription
                    self.recordEvent(
                        level: .error,
                        summary: "Open Codex Mac failed.",
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }

    var isBusy: Bool {
        switch actionState {
        case .idle, .failed:
            false
        case .refreshing, .startingListener, .stoppingListener, .updatingLoginItem, .launchingCodex:
            true
        }
    }

    var actionSummary: String {
        switch actionState {
        case .idle:
            "Idle"
        case .refreshing:
            "Refreshing presence and route state"
        case .startingListener:
            "Starting the shared listener"
        case .stoppingListener:
            "Stopping the shared listener"
        case .updatingLoginItem:
            "Updating launch-at-login"
        case .launchingCodex:
            "Opening Codex Mac"
        case .failed:
            "Action failed"
        }
    }

    var statusSummary: String {
        "\(snapshot.presence.readyForEnhancedMode ? "Enhanced mode ready" : "Needs attention") · \(snapshot.listenerSummary)"
    }

    private func apply(_ newSnapshot: CompanionHostSnapshot, summary: String) {
        let previous = snapshot
        snapshot = newSnapshot
        loginItemStatus = loginItemController.currentStatus()
        errorMessage = nil
        actionState = .idle
        lastUpdatedAt = .now
        recordEvent(level: .info, summary: summary, detail: transitionDetail(from: previous, to: newSnapshot))
    }

    private func transitionDetail(from previous: CompanionHostSnapshot, to current: CompanionHostSnapshot) -> String {
        var parts: [String] = []

        if previous.sharedListenerState != current.sharedListenerState {
            parts.append("Listener \(previous.sharedListenerState.rawValue) -> \(current.sharedListenerState.rawValue)")
        }

        if previous.presence.readyForEnhancedMode != current.presence.readyForEnhancedMode {
            parts.append(current.presence.readyForEnhancedMode ? "Enhanced mode is now ready" : "Enhanced mode needs attention")
        }

        if previous.directEndpoint != current.directEndpoint {
            parts.append(current.directEndpoint == nil ? "Direct endpoint unpublished" : "Direct endpoint published")
        }

        if previous.publishedRoutes.count != current.publishedRoutes.count {
            parts.append("Published routes: \(previous.publishedRoutes.count) -> \(current.publishedRoutes.count)")
        }

        if previous.publication.lastPublishedAt != current.publication.lastPublishedAt {
            parts.append("Metadata publication refreshed")
        }

        if previous.notificationBridge.pendingCount != current.notificationBridge.pendingCount
            || previous.notificationBridge.deliveredCount != current.notificationBridge.deliveredCount {
            parts.append(
                "Notification bridge pending \(previous.notificationBridge.pendingCount) -> \(current.notificationBridge.pendingCount), delivered \(previous.notificationBridge.deliveredCount) -> \(current.notificationBridge.deliveredCount)"
            )
        }

        return parts.isEmpty ? current.recommendation.detail : parts.joined(separator: " • ")
    }

    private func recordEvent(level: CompanionEventLevel, summary: String, detail: String) {
        statusEvents.insert(
            CompanionStatusEvent(level: level, summary: summary, detail: detail),
            at: 0
        )
        if statusEvents.count > 8 {
            statusEvents.removeLast(statusEvents.count - 8)
        }
    }
}

enum CompanionActionState: String {
    case idle
    case refreshing
    case startingListener
    case stoppingListener
    case updatingLoginItem
    case launchingCodex
    case failed
}

enum CompanionEventLevel {
    case info
    case error
}

struct CompanionStatusEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: CompanionEventLevel
    let summary: String
    let detail: String
}

enum CompanionLoginItemStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval(String)
    case unsupported(String)

    var label: String {
        switch self {
        case .enabled:
            "Enabled"
        case .disabled:
            "Disabled"
        case .requiresApproval:
            "Needs approval"
        case .unsupported:
            "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            "The companion is registered to launch when you sign in."
        case .disabled:
            "The companion is not registered to launch at login."
        case let .requiresApproval(detail), let .unsupported(detail):
            detail
        }
    }

    var canEnable: Bool {
        switch self {
        case .disabled, .requiresApproval:
            true
        case .enabled, .unsupported:
            false
        }
    }

    var canDisable: Bool {
        self == .enabled
    }
}

protocol CompanionLoginItemControlling {
    func currentStatus() -> CompanionLoginItemStatus
    func enable() throws -> CompanionLoginItemStatus
    func disable() throws -> CompanionLoginItemStatus
}

struct SMAppServiceLoginItemController: CompanionLoginItemControlling {
    func currentStatus() -> CompanionLoginItemStatus {
        #if canImport(ServiceManagement)
        status(for: SMAppService.mainApp.status)
        #else
        .unsupported("Launch-at-login requires ServiceManagement on macOS.")
        #endif
    }

    func enable() throws -> CompanionLoginItemStatus {
        #if canImport(ServiceManagement)
        do {
            try SMAppService.mainApp.register()
            return currentStatus()
        } catch {
            throw CompanionLoginItemError(message: error.localizedDescription)
        }
        #else
        throw CompanionLoginItemError(message: "Launch-at-login requires ServiceManagement on macOS.")
        #endif
    }

    func disable() throws -> CompanionLoginItemStatus {
        #if canImport(ServiceManagement)
        do {
            try SMAppService.mainApp.unregister()
            return currentStatus()
        } catch {
            throw CompanionLoginItemError(message: error.localizedDescription)
        }
        #else
        throw CompanionLoginItemError(message: "Launch-at-login requires ServiceManagement on macOS.")
        #endif
    }

    #if canImport(ServiceManagement)
    private func status(for status: SMAppService.Status) -> CompanionLoginItemStatus {
        switch status {
        case .enabled:
            .enabled
        case .notRegistered:
            .disabled
        case .requiresApproval:
            .requiresApproval("Approve the login item in System Settings > General > Login Items after installing a signed companion build.")
        case .notFound:
            .unsupported("Launch-at-login needs a signed app bundle. Build and sign the companion app before enabling it.")
        @unknown default:
            .unsupported("Launch-at-login reported an unknown ServiceManagement status.")
        }
    }
    #endif
}

struct CompanionLoginItemError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
