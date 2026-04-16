import AppState
import SwiftUI
import TailnetEmbedded
#if canImport(UIKit)
import UIKit
#endif

private enum AppShellTab: String, CaseIterable {
    case codex
    case connections
    case settings

    var title: String {
        switch self {
        case .codex:
            "Codex"
        case .connections:
            "Connections"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            "bubble.left.and.bubble.right"
        case .connections:
            "dot.radiowaves.left.and.right"
        case .settings:
            "gearshape"
        }
    }
}

@MainActor
struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("cotg.selectedMachineID") private var storedSelectedMachineID = ""
    @SceneStorage("cotg.selectedSessionID") private var storedSelectedSessionID = ""
    @SceneStorage("cotg.selectedShellTab") private var storedSelectedShellTab = AppShellTab.codex.rawValue
    @State private var hasPerformedInitialBootstrap = false

    let model: AppModel
    let launchMachineID: UUID?

    var body: some View {
        Group {
            if ExternalTailnetSSHReproRootView.isEnabled {
                ExternalTailnetSSHReproRootView()
            } else if EmbeddedTailnetSSHReproRootView.isEnabled {
                EmbeddedTailnetSSHReproRootView()
            } else if EmbeddedTailnetReproRootView.isEnabled {
                EmbeddedTailnetReproRootView()
            } else {
                AppShellView(
                    model: model,
                    selectedTab: selectedTabBinding
                )
            }
        }
        .background(shellBackground)
        .task {
            guard !hasPerformedInitialBootstrap else {
                return
            }
            hasPerformedInitialBootstrap = true

#if canImport(UIKit)
            if shouldDisableIdleTimerForUITesting {
                UIApplication.shared.isIdleTimerDisabled = true
            }
#endif
            if let requestedUITestShellTab {
                storedSelectedShellTab = requestedUITestShellTab.rawValue
            }
            guard !ExternalTailnetSSHReproRootView.isEnabled else {
                return
            }
            guard !EmbeddedTailnetReproRootView.isEnabled else {
                return
            }
            guard !EmbeddedTailnetSSHReproRootView.isEnabled else {
                return
            }

            if shouldResetPersistedStateForUITests {
                model.resetPersistedStateForUITests(
                    seedPreviewFixture: shouldSeedPreviewFixtureForUITests,
                    seedLocalhostLANRoute: shouldSeedLocalhostLANRouteForUITests,
                    seedLocalhostManualRoute: shouldSeedLocalhostManualRouteForUITests,
                    seedEmbeddedTailnetRoute: shouldSeedEmbeddedTailnetRouteForUITests,
                    seedAppStoreSessionFixture: shouldSeedAppStoreSessionFixtureForUITests
                )
                model.runUITestLaunchAutomationIfNeeded()
                storedSelectedMachineID = ""
                storedSelectedSessionID = ""
                storedSelectedShellTab = requestedUITestShellTab?.rawValue ?? AppShellTab.codex.rawValue
                return
            }

            let launchContext = await model.restorePersistedState()
            let storedSceneMachineID = UUID(uuidString: storedSelectedMachineID).flatMap { candidate in
                model.machines.contains(where: { $0.id == candidate }) ? candidate : nil
            }
            let storedSceneSessionID = UUID(uuidString: storedSelectedSessionID).flatMap { candidate in
                model.canRestoreSessionOnLaunch(candidate) ? candidate : nil
            }
            let restoredSessionID = storedSceneSessionID
                ?? launchContext.selectedSessionID.flatMap { candidate in
                    model.recentSessions.contains(where: { $0.id == candidate }) ? candidate : nil
                }
            let restoredID = launchMachineID
                ?? storedSceneMachineID
                ?? launchContext.selectedMachineID
            if let restoredSessionID,
               let session = model.recentSessions.first(where: { $0.id == restoredSessionID }) {
                storedSelectedMachineID = session.machineID.uuidString
                storedSelectedSessionID = restoredSessionID.uuidString
                model.resumeSession(restoredSessionID, reconnect: false)
            } else if let restoredID {
                storedSelectedMachineID = restoredID.uuidString
                model.select(machineID: restoredID)
            }
            if let requestedUITestShellTab {
                storedSelectedShellTab = requestedUITestShellTab.rawValue
            }
            if scenePhase != .background,
               ProcessInfo.processInfo.environment["UI_TESTING"] != "1" {
                model.sceneDidBecomeActive()
            }
            model.runUITestLaunchAutomationIfNeeded()
        }
        .onChange(of: model.selectedMachineID) { _, newValue in
            storedSelectedMachineID = newValue?.uuidString ?? ""
            if newValue == nil {
                storedSelectedSessionID = ""
            }
        }
        .onChange(of: model.activeSession?.id) { _, newValue in
            storedSelectedSessionID = newValue?.uuidString ?? ""
        }
        .onChange(of: scenePhase) { _, newValue in
#if canImport(UIKit)
            if shouldDisableIdleTimerForUITesting {
                UIApplication.shared.isIdleTimerDisabled = (newValue == .active)
            }
#endif
            guard !ExternalTailnetSSHReproRootView.isEnabled else {
                return
            }
            guard !EmbeddedTailnetReproRootView.isEnabled else {
                return
            }
            guard !EmbeddedTailnetSSHReproRootView.isEnabled else {
                return
            }
            switch newValue {
            case .active:
                guard ProcessInfo.processInfo.environment["UI_TESTING"] != "1" else {
                    return
                }
                model.sceneDidBecomeActive()
            case .background:
                model.sceneDidEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onContinueUserActivity(CodingOnTheGoRouting.handoffActivityType) { activity in
            guard let payload = CodingOnTheGoRouting.payload(from: activity) else {
                return
            }

            storedSelectedMachineID = payload.machineID.uuidString
            storedSelectedSessionID = ""
            storedSelectedShellTab = AppShellTab.codex.rawValue
            model.handleHandoffPayload(
                machineID: payload.machineID,
                threadID: payload.threadID,
                protocolKind: payload.protocolKind,
                routeKind: payload.routeKind,
                workspaceRoot: payload.workspaceRoot
            )
        }
    }

    private var shouldDisableIdleTimerForUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }

    private var selectedTabBinding: Binding<AppShellTab> {
        Binding(
            get: {
                AppShellTab(rawValue: storedSelectedShellTab) ?? .codex
            },
            set: {
                storedSelectedShellTab = $0.rawValue
                if $0 == .codex {
                    model.prepareCodexWorkspaceForSelectedMachineIfNeeded()
                }
            }
        )
    }

    private var shouldResetPersistedStateForUITests: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
            && ProcessInfo.processInfo.environment["COTG_UI_TEST_RESET_ON_LAUNCH"] == "1"
    }

    private var shouldSeedPreviewFixtureForUITests: Bool {
        ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_PREVIEW_FIXTURE"] == "1"
    }

    private var shouldSeedLocalhostLANRouteForUITests: Bool {
        ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_LOCALHOST_LAN_ROUTE"] == "1"
    }

    private var shouldSeedLocalhostManualRouteForUITests: Bool {
        ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_LOCALHOST_MANUAL_ROUTE"] == "1"
    }

    private var shouldSeedEmbeddedTailnetRouteForUITests: Bool {
        ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_EMBEDDED_TAILNET_ROUTE"] == "1"
    }

    private var shouldSeedAppStoreSessionFixtureForUITests: Bool {
        ProcessInfo.processInfo.environment["COTG_UI_TEST_SEED_APP_STORE_SESSION_FIXTURE"] == "1"
    }

    private var requestedUITestShellTab: AppShellTab? {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              let rawValue = ProcessInfo.processInfo.environment["COTG_UI_TEST_SELECTED_TAB"] else {
            return nil
        }

        return AppShellTab(rawValue: rawValue)
    }
}

@MainActor
private struct AppShellView: View {
    let model: AppModel
    @Binding var selectedTab: AppShellTab
    @State private var codexBrowserOpenRequest = 0

    var body: some View {
        baseTabView
    }

    private var baseTabView: some View {
        TabView(selection: $selectedTab) {
            CodexRootView(
                model: model,
                isActiveTab: selectedTab == .codex,
                browserOpenRequestToken: codexBrowserOpenRequest,
                bottomAccessoryClearance: 0,
                onOpenConnections: { requestTabSelection(.connections) },
                onOpenSettings: { requestTabSelection(.settings) }
            )
            .tabItem {
                Label(AppShellTab.codex.title, systemImage: AppShellTab.codex.systemImage)
            }
            .tag(AppShellTab.codex)

            ConnectionsRootView(
                model: model,
                bottomAccessoryClearance: 0,
                onOpenCodex: {
                    requestTabSelection(.codex)
                }
            )
            .tabItem {
                Label(AppShellTab.connections.title, systemImage: AppShellTab.connections.systemImage)
            }
            .tag(AppShellTab.connections)

            SettingsRootView(model: model)
                .tabItem {
                    Label(AppShellTab.settings.title, systemImage: AppShellTab.settings.systemImage)
                }
                .tag(AppShellTab.settings)
        }
    }

    private func requestTabSelection(_ tab: AppShellTab, forceOpenBrowser: Bool = false) {
        if tab == .codex {
            model.prepareCodexWorkspaceForSelectedMachineIfNeeded()
        }

        selectedTab = tab

        // Delay only the browser-open request so the destination Codex view can finish mounting first.
        Task { @MainActor in
            guard forceOpenBrowser, tab == .codex else {
                return
            }

            await Task.yield()
            codexBrowserOpenRequest += 1
        }
    }
}

@MainActor
private struct ExternalTailnetSSHReproRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasStarted = false
    @State private var statusLine = "Preparing external tailnet SSH repro…"
    @State private var reportPath = ""
    @State private var harness: ExternalTailnetSSHReproHarness?

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COTG_EXTERNAL_TAILNET_SSH_REPRO"] == "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("External Tailnet SSH Repro")
                .font(.title2.weight(.semibold))
            Text(statusLine)
                .font(.body.monospaced())
                .textSelection(.enabled)
            if !reportPath.isEmpty {
                Text("Report: \(reportPath)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task {
            guard !hasStarted else {
                return
            }
            hasStarted = true
            await startHarness()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard let harness else {
                return
            }
            Task {
                await harness.recordLifecycle("scenePhase=\(String(describing: newValue))")
            }
        }
    }

    private func startHarness() async {
        let environment = ProcessInfo.processInfo.environment
        guard let targetHost = environment["COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !targetHost.isEmpty else {
            statusLine = "Missing COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"
            return
        }
        guard let sshUser = environment["COTG_TEST_SSH_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sshUser.isEmpty else {
            statusLine = "Missing COTG_TEST_SSH_USER"
            return
        }
        guard let hostKey = environment["COTG_TEST_SSH_HOST_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostKey.isEmpty else {
            statusLine = "Missing COTG_TEST_SSH_HOST_KEY"
            return
        }
        guard let rawKeyBase64 = environment["COTG_TEST_SSH_RAW_KEY_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let rawKey = Data(base64Encoded: rawKeyBase64) else {
            statusLine = "Missing or invalid COTG_TEST_SSH_RAW_KEY_BASE64"
            return
        }

        let fileManager = FileManager.default
        let appSupportURL = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("ExternalTailnetSSHRepro", isDirectory: true)
        try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let reportFileName = environment["COTG_EXTERNAL_TAILNET_SSH_REPRO_REPORT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? environment["COTG_EXTERNAL_TAILNET_SSH_REPRO_REPORT_FILE"]!
            : "external-tailnet-ssh-repro-report.json"
        let reportURL = appSupportURL.appendingPathComponent(reportFileName)

        reportPath = reportURL.path
        statusLine = "Running external tailnet SSH repro…"

        let harness = ExternalTailnetSSHReproHarness(
            configuration: ExternalTailnetSSHReproConfiguration(
                displayName: environment["COTG_EXTERNAL_TAILNET_REPRO_HOSTNAME"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? "cotg-external-ssh-repro",
                tailnetDNSName: targetHost,
                sshUsername: sshUser,
                sshHostKey: hostKey,
                sshRawKeySeed: rawKey,
                cwd: environment["COTG_WORKSPACE_ROOT"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? NSHomeDirectory(),
                codexHome: environment["COTG_TEST_CODEX_HOME"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                reportPath: reportURL.path
            )
        )
        self.harness = harness
        await harness.recordLifecycle("scenePhase=\(String(describing: scenePhase))")

        let report = await harness.run()
        if report.status == "succeeded" {
            statusLine = "SSH repro succeeded for \(report.tailnetDNSName) seedBytes=\(report.seedByteCount)"
        } else {
            statusLine = report.finalError ?? "SSH repro failed."
        }
    }
}

@MainActor
private struct EmbeddedTailnetSSHReproRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasStarted = false
    @State private var statusLine = "Preparing embedded tailnet SSH repro…"
    @State private var reportPath = ""
    @State private var harness: EmbeddedTailnetSSHReproHarness?

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COTG_EMBEDDED_TAILNET_SSH_REPRO"] == "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Embedded Tailnet SSH Repro")
                .font(.title2.weight(.semibold))
            Text(statusLine)
                .font(.body.monospaced())
                .textSelection(.enabled)
            if !reportPath.isEmpty {
                Text("Report: \(reportPath)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task {
            guard !hasStarted else {
                return
            }
            hasStarted = true
            await startHarness()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard let harness else {
                return
            }
            Task {
                await harness.recordLifecycle("scenePhase=\(String(describing: newValue))")
            }
        }
    }

    private func startHarness() async {
        let environment = ProcessInfo.processInfo.environment
        guard let controlURLString = environment["COTG_EMBEDDED_TAILNET_REPRO_CONTROL_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let controlURL = URL(string: controlURLString),
              !controlURLString.isEmpty else {
            statusLine = "Missing COTG_EMBEDDED_TAILNET_REPRO_CONTROL_URL"
            return
        }
        guard let targetHost = environment["COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !targetHost.isEmpty else {
            statusLine = "Missing COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST"
            return
        }
        guard let sshUser = environment["COTG_TEST_SSH_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sshUser.isEmpty else {
            statusLine = "Missing COTG_TEST_SSH_USER"
            return
        }
        guard let hostKey = environment["COTG_TEST_SSH_HOST_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostKey.isEmpty else {
            statusLine = "Missing COTG_TEST_SSH_HOST_KEY"
            return
        }
        guard let rawKeyBase64 = environment["COTG_TEST_SSH_RAW_KEY_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let rawKey = Data(base64Encoded: rawKeyBase64) else {
            statusLine = "Missing or invalid COTG_TEST_SSH_RAW_KEY_BASE64"
            return
        }

        let fileManager = FileManager.default
        let appSupportURL = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("EmbeddedTailnetSSHRepro", isDirectory: true)
        try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let reportFileName = environment["COTG_EMBEDDED_TAILNET_SSH_REPRO_REPORT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? environment["COTG_EMBEDDED_TAILNET_SSH_REPRO_REPORT_FILE"]!
            : "embedded-tailnet-ssh-repro-report.json"
        let reportURL = appSupportURL.appendingPathComponent(reportFileName)

        reportPath = reportURL.path
        statusLine = "Running embedded tailnet SSH repro…"

        let harness = EmbeddedTailnetSSHReproHarness(
            configuration: EmbeddedTailnetSSHReproConfiguration(
                displayName: environment["COTG_EMBEDDED_TAILNET_REPRO_HOSTNAME"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? "cotg-embedded-ssh-repro",
                controlURL: controlURL,
                tailnetDNSName: targetHost,
                sshUsername: sshUser,
                sshHostKey: hostKey,
                sshRawKeySeed: rawKey,
                cwd: environment["COTG_WORKSPACE_ROOT"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? NSHomeDirectory(),
                codexHome: environment["COTG_TEST_CODEX_HOME"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                reportPath: reportURL.path
            )
        )
        self.harness = harness
        await harness.recordLifecycle("scenePhase=\(String(describing: scenePhase))")

        let report = await harness.run()
        if report.status == "succeeded" {
            statusLine = "SSH repro succeeded with proxy \(report.dialPlanHost ?? "<nil>"):\(report.dialPlanPort.map(String.init) ?? "<nil>")"
        } else {
            statusLine = report.finalError ?? "SSH repro failed."
        }
    }
}

@MainActor
private struct EmbeddedTailnetReproRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasStarted = false
    @State private var statusLine = "Preparing embedded-tailnet repro harness…"
    @State private var reportPath = ""
    @State private var tailscaleLogPath = ""
    @State private var harness: EmbeddedTailnetReproHarness?

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COTG_EMBEDDED_TAILNET_REPRO"] == "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Embedded Tailnet Repro")
                .font(.title2.weight(.semibold))
            Text(statusLine)
                .font(.body.monospaced())
                .textSelection(.enabled)
            if !reportPath.isEmpty {
                Text("Report: \(reportPath)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            if !tailscaleLogPath.isEmpty {
                Text("Tailscale log: \(tailscaleLogPath)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task {
            guard !hasStarted else {
                return
            }
            hasStarted = true
            await startHarness()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard let harness else {
                return
            }
            Task {
                await harness.recordLifecycle("scenePhase=\(String(describing: newValue))")
            }
        }
    }

    private func startHarness() async {
        let environment = ProcessInfo.processInfo.environment
        let authKey = environment["COTG_EMBEDDED_TAILNET_AUTH_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard authKey.hasPrefix("tskey-") else {
            statusLine = "Missing COTG_EMBEDDED_TAILNET_AUTH_KEY"
            return
        }

        let fileManager = FileManager.default
        let appSupportURL = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("EmbeddedTailnetRepro", isDirectory: true)
        try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let reportFileName = environment["COTG_EMBEDDED_TAILNET_REPRO_REPORT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? environment["COTG_EMBEDDED_TAILNET_REPRO_REPORT_FILE"]!
            : "embedded-tailnet-repro-report.json"
        let reportURL = appSupportURL.appendingPathComponent(reportFileName)
        let tailscaleLogURL = appSupportURL.appendingPathComponent(
            reportFileName.replacingOccurrences(of: ".json", with: ".tailscale.log")
        )
        let storageURL = appSupportURL.appendingPathComponent("tsnet-node", isDirectory: true)

        reportPath = reportURL.path
        tailscaleLogPath = tailscaleLogURL.path
        statusLine = "Running minimal repro harness…"

        let configuration = EmbeddedTailnetReproConfiguration(
            hostName: environment["COTG_EMBEDDED_TAILNET_REPRO_HOSTNAME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "cotg-repro-node",
            controlURL: environment["COTG_EMBEDDED_TAILNET_REPRO_CONTROL_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "https://controlplane.tailscale.com",
            authKey: authKey,
            storagePath: storageURL.path,
            reportPath: reportURL.path,
            tailscaleLogPath: tailscaleLogURL.path,
            runtimeLabel: [
                UIDevice.current.model,
                UIDevice.current.systemName,
                UIDevice.current.systemVersion
            ].joined(separator: " | "),
            timeoutSeconds: Double(
                environment["COTG_EMBEDDED_TAILNET_REPRO_TIMEOUT_SECONDS"] ?? "120"
            ) ?? 120,
            pollIntervalMilliseconds: UInt64(
                environment["COTG_EMBEDDED_TAILNET_REPRO_POLL_MS"] ?? "500"
            ) ?? 500
        )

        let harness = EmbeddedTailnetReproHarness(configuration: configuration)
        self.harness = harness
        await harness.recordLifecycle("scenePhase=\(String(describing: scenePhase))")
        let report = await harness.run()
        statusLine = [
            "status=\(report.status)",
            "backend=\(report.finalBackendState ?? "<nil>")",
            "loopback=\(report.loopbackAddress ?? "<nil>")",
            "error=\(report.finalError ?? "<nil>")"
        ].joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
