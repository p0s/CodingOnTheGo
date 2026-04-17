import AppState
import CodexRPC
import SharedModels
import SwiftUI

struct SettingsRootView: View {
    @AppStorage("cotg.experimental.showAllReposAcrossMacs") private var showsAllReposAcrossMacs = false
    @AppStorage("cotg.codex.browserPresentationStyle") private var browserPresentationStyle = CodexBrowserPresentationStyle.sheet.rawValue

    let model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Browser") {
                    Toggle("Show projects across all Macs", isOn: $showsAllReposAcrossMacs)
                        .accessibilityIdentifier("show-all-repos-toggle")
                    Text("Off by default. Codex stays scoped to the current Mac unless you explicitly opt into the experimental cross-Mac browser.")
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)

                    if AppDeviceCopy.isPhone {
                        Picker("iPhone browser style", selection: $browserPresentationStyle) {
                            ForEach(CodexBrowserPresentationStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .accessibilityIdentifier("browser-presentation-picker")
                        Text("Controls whether the project and thread browser opens as a full-height sheet or a drawer on iPhone.")
                            .font(.footnote)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    }
                }

                Section("Notifications and sync") {
                    settingsRow("Notifications permission", value: notificationAuthorizationLabel)

                    if model.notificationSnapshot.authorization != .authorized {
                        Button("Enable Notifications") {
                            model.requestNotificationAuthorization()
                        }
                    }
                    settingsRow("Sync status", value: syncStatusLabel)
                    if let blocker = model.syncSnapshot.blocker {
                        Text(blocker.reason)
                            .font(.footnote)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    }
                }

                Section("Privacy") {
                    Picker(
                        "Storage mode",
                        selection: Binding(
                            get: { model.privacyMode },
                            set: { model.setPrivacyMode($0) }
                        )
                    ) {
                        ForEach(AppPrivacyMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("settings-privacy-mode-picker")

                    Text(model.privacyMode.summary)
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }

                Section("Connection defaults") {
                    settingsRow("Protocol", value: model.protocolLabel)
                    settingsRow("Best route now", value: model.recommendedRoute?.label ?? "Checking")
                    settingsRow("Proxy or VPN", value: proxyRoutingLabel)
                    Text(model.networkProxyDetail)
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }

                Section("Review and demo") {
                    Toggle(
                        "Reviewer demo mode",
                        isOn: Binding(
                            get: { model.isDemoModeEnabled },
                            set: { model.setDemoModeEnabled($0) }
                        )
                    )
                    .accessibilityIdentifier("settings-demo-mode-toggle")

                    Text("Temporarily replaces live Macs, Projects, Threads, and transcript history with bundled demo data so reviewers can exercise the real app shell without SSH, tailnet, or a reachable host.")
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }

                Section("Codex defaults") {
                    advancedMenuRow(
                        title: "Reasoning",
                        value: model.selectedReasoningEffortLabel,
                        accessibilityIdentifier: "settings-reasoning-menu"
                    ) {
                        ForEach(model.availableReasoningEffortOptions, id: \.effort) { option in
                            Button(AppModel.reasoningEffortDisplayName(option.effort)) {
                                model.selectReasoningEffort(option.effort)
                            }
                        }
                    }

                    advancedMenuRow(
                        title: "Approvals",
                        value: model.preferredApprovalPolicyLabel,
                        accessibilityIdentifier: "settings-approval-policy-menu"
                    ) {
                        Button("Host config") {
                            model.setPreferredApprovalPolicy(nil)
                        }
                        Button("Never") {
                            model.setPreferredApprovalPolicy("never")
                        }
                        Button("On request") {
                            model.setPreferredApprovalPolicy("on-request")
                        }
                    }

                    advancedMenuRow(
                        title: "Sandbox",
                        value: model.preferredSandboxModeLabel,
                        accessibilityIdentifier: "settings-sandbox-mode-menu"
                    ) {
                        Button("Host config") {
                            model.setPreferredSandboxMode(nil)
                        }
                        Button("Read only") {
                            model.setPreferredSandboxMode(.readOnly)
                        }
                        Button("Workspace write") {
                            model.setPreferredSandboxMode(.workspaceWrite)
                        }
                        Button("Full access") {
                            model.setPreferredSandboxMode(.dangerFullAccess)
                        }
                    }

                    Text("These defaults apply to threads started or resumed from iPhone/iPad. The host can still clamp them, and the live Codex header remains the source of truth for the effective authority.")
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)

                    advancedMenuRow(
                        title: "Run mode",
                        value: model.runModeLabel,
                        accessibilityIdentifier: "settings-collaboration-mode-menu"
                    ) {
                        Button("Fast") {
                            model.selectFastMode()
                        }
                        Button("Standard") {
                            model.selectStandardMode()
                        }
                        Button("Plan") {
                            model.selectPlanMode()
                        }
                        Button("Default") {
                            model.selectDefaultCollaborationMode()
                        }
                    }

                    advancedMenuRow(
                        title: "Parallel agents",
                        value: model.parallelAgentModeLabel,
                        accessibilityIdentifier: "settings-parallel-agent-menu"
                    ) {
                        Button("Off") {
                            model.selectParallelAgentMode(.off)
                        }
                        Button("Client-orchestrated") {
                            model.selectParallelAgentMode(.clientOrchestrated)
                        }
                        Button("Protocol-native") {
                            model.selectParallelAgentMode(.protocolNative)
                        }
                        .disabled(!model.canSelectProtocolNativeParallelAgents)
                    }

                    if !model.availableModels.isEmpty {
                        advancedMenuRow(
                            title: "Model",
                            value: model.selectedModel ?? "Auto",
                            accessibilityIdentifier: "settings-model-menu"
                        ) {
                            ForEach(model.availableModels) { descriptor in
                                Button(descriptor.displayName) {
                                    model.selectModel(descriptor)
                                }
                            }
                        }
                    }

                    Button("Refresh available models") {
                        model.refreshModels()
                    }
                    .accessibilityIdentifier("settings-refresh-models-button")

                    Text(model.parallelAgentCapabilityLabel)
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }

                if model.activeSession?.threadID != nil || model.activeSession?.workspaceRoot != nil {
                    Section("Desktop continuity") {
                        Button("Continue on Mac") {
                            model.continueOnMac()
                        }
                        .accessibilityIdentifier("settings-continue-on-mac-button")

                        Button("Start new Mac thread here") {
                            model.openNewCodexThreadOnHost()
                        }
                        .disabled(model.activeSession?.workspaceRoot == nil)
                        .accessibilityIdentifier("settings-start-new-mac-thread-button")

                        Button("Reveal current workspace in Finder") {
                            model.revealCurrentWorkspaceInFinderOnHost()
                        }
                        .disabled(model.activeSession?.workspaceRoot == nil)
                        .accessibilityIdentifier("settings-reveal-current-workspace-button")

                        Button("Wake Mac display") {
                            model.wakeMacDisplayOnHost()
                        }
                        .accessibilityIdentifier("settings-wake-mac-display-button")

                        if let handoffURL = model.codexMacThreadHandoffURL {
                            ShareLink(item: handoffURL) {
                                Label("Share current thread link", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("settings-share-current-thread-button")
                        }
                    }

                    if model.activeSession?.threadID != nil {
                        Section("Thread actions") {
                            Button("Fork current thread") {
                                model.forkCurrentThread()
                            }
                            .accessibilityIdentifier("settings-fork-thread-button")
                        }
                    }
                }

                Section("App") {
                    settingsRow("Version", value: appVersionLabel)
                }

                Section("Support") {
                    ProductSupportButtonRow(
                        privacyAccessibilityIdentifier: "settings-privacy-link",
                        supportAccessibilityIdentifier: "settings-support-link"
                    )
                }
            }
            .navigationTitle("Settings")
            .safeAreaPadding(.bottom, 20)
        }
        .background(shellBackground)
        .onAppear {
            model.refreshModelsIfNeeded()
        }
    }

    private var notificationAuthorizationLabel: String {
        switch model.notificationSnapshot.authorization {
        case .unknown:
            return "Not asked"
        case .denied:
            return "Off"
        case .authorized:
            return "On"
        @unknown default:
            return "Unknown"
        }
    }

    private var syncStatusLabel: String {
        if model.syncSnapshot.blocker != nil {
            return "Needs attention"
        }

        switch model.syncSnapshot.status {
        case .idle:
            return "Ready"
        case .syncing:
            return "Syncing"
        case .blocked:
            return "Needs attention"
        @unknown default:
            return model.syncSnapshot.status.rawValue.capitalized
        }
    }

    private var proxyRoutingLabel: String {
        model.networkProxyStatusLabel == "Direct paths healthy" ? "Ready" : "Check rules"
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty && version != build:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return "Unknown"
        }
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func advancedMenuRow<MenuContent: View>(
        title: String,
        value: String,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
