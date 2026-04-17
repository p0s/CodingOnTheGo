import AppState
import RouteSelection
import SharedModels
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ConnectionScreenView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let model: AppModel
    let bottomAccessoryClearance: CGFloat
    var onOpenCodex: () -> Void = {}
    var onForgetSavedMachine: (() -> Void)? = nil
    @State private var isTechnicalDetailsExpanded = false
    @State private var setupScrollRequest = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let machine = model.selectedMachine {
                        ConnectionOverviewContent(
                            model: model,
                            machine: machine,
                            onOpenCodex: onOpenCodex,
                            onContinueSetup: {
                                setupScrollRequest += 1
                            },
                            onForgetSavedMachine: onForgetSavedMachine,
                            isTechnicalDetailsExpanded: $isTechnicalDetailsExpanded
                        )
                    } else {
                        EmptyConnectionStateView(model: model)
                    }
                }
                .padding(24)
                .padding(.bottom, bottomContentPadding)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .onChange(of: setupScrollRequest) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(ConnectionOverviewSection.setup, anchor: .top)
                }
            }
        }
        .background(shellBackground)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if showsCompactTrustActionBar {
                    CompactConnectionTrustActionBar(model: model)
                }

                if compactTabBarSpacerHeight > 0 {
                    Color.clear
                        .frame(height: compactTabBarSpacerHeight)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            statusProbe
        }
    }

    private var bottomContentPadding: CGFloat {
        32 + max(0, bottomAccessoryClearance)
    }

    private var compactTabBarSpacerHeight: CGFloat {
        horizontalSizeClass == .compact ? 92 : 0
    }

    private var showsCompactTrustActionBar: Bool {
        horizontalSizeClass == .compact
            && model.connectionSetupAccountReady
            && !model.connectionSetupTrustReady
            && (model.canScanSelectedRouteHostKey || model.canTrustScannedHostKey)
    }

    private var statusProbe: some View {
        statusProbeLabel(model.connectionDebugStatusLabel)
    }
}

private enum ConnectionOverviewSection: Hashable {
    case setup
}

private struct ConnectionOverviewContent: View {
    let model: AppModel
    let machine: MachineRecord
    let onOpenCodex: () -> Void
    let onContinueSetup: () -> Void
    let onForgetSavedMachine: (() -> Void)?
    @Binding var isTechnicalDetailsExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isDemoModeEnabled {
                AppInlineNotice(
                    title: "Reviewer demo mode",
                    detail: "This screen is using bundled demo machine and route data. Live SSH, discovery, and tailnet diagnostics are paused until demo mode is turned off in Settings.",
                    tint: .blue,
                    icon: "sparkles.rectangle.stack"
                )
            }

            ConnectionSummaryCard(
                model: model,
                machine: machine,
                recentSessions: recentThreadSessions,
                onOpenCodex: onOpenCodex,
                onContinueSetup: onContinueSetup
            )

            VStack(alignment: .leading, spacing: 14) {
                ConnectionSetupCard(
                    model: model,
                    machine: machine,
                    onOpenTechnicalDetails: { isTechnicalDetailsExpanded = true }
                )
                .id(ConnectionOverviewSection.setup)
                ConnectionRoutesCard(
                    model: model,
                    machine: machine,
                    onOpenCodex: onOpenCodex,
                    onOpenTechnicalDetails: { isTechnicalDetailsExpanded = true }
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connection-plan-card")

            if !recentThreadSessions.isEmpty {
                DisclosureGroup("Recent threads") {
                    RecentSessionsCard(
                        model: model,
                        sessions: recentThreadSessions,
                        onOpenCodex: onOpenCodex
                    )
                    .padding(.top, 12)
                }
                .tint(.accentColor)
            }

            DisclosureGroup("Troubleshoot & technical details", isExpanded: $isTechnicalDetailsExpanded) {
                if model.isDemoModeEnabled {
                    AppInlineNotice(
                        title: "Live route tools paused",
                        detail: "Turn off reviewer demo mode in Settings before scanning host keys, editing routes, or using tailnet/bootstrap tooling.",
                        tint: .blue,
                        icon: "pause.circle"
                    )
                    .padding(.top, 12)
                } else {
                    ConnectionTechnicalDetailsContent(model: model, machine: machine)
                        .environment(\.forgetSavedMachineAction, onForgetSavedMachine)
                        .padding(.top, 12)
                }
            }
            .controlSize(.small)
            .tint(.accentColor)
        }
    }

    private var recentSessions: [SessionRecord] {
        model.recentSessions
            .filter { $0.machineID == machine.id }
            .sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt })
    }

    private var recentThreadSessions: [SessionRecord] {
        recentSessions.filter { $0.threadID != nil }
    }
}

private struct ConnectionTechnicalDetailsContent: View {
    let model: AppModel
    let machine: MachineRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SupportStatusCard(model: model)
            CapabilityChecklistCard(report: model.capabilityReport)
            SSHBootstrapCard(model: model)
            RouteDiagnosticsCard(model: model, machine: machine)
            ForgetSavedMachineCard(model: model, machine: machine)
        }
    }
}

private struct ConnectionSummaryCard: View {
    let model: AppModel
    let machine: MachineRecord
    let recentSessions: [SessionRecord]
    let onOpenCodex: () -> Void
    let onContinueSetup: () -> Void

    var body: some View {
        let presentation = MachineConnectionPresentation(machine: machine, model: model)

        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader("Summary", subtitle: machine.hostname) {
                AppMetadataChip(title: presentation.overallState.title, tint: statusTint(for: presentation.overallState))
            }

            Text(machine.alias)
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                AppMetadataChip(title: "Best route", tint: .secondary)
                Text(presentation.bestRouteLabel)
                    .font(.subheadline.weight(.medium))
                AppMetadataChip(title: presentation.savedWaysToConnectLabel, tint: .secondary)
            }

            Text(presentation.summaryDetail)
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            summaryActionRow(for: presentation)
        }
        .appSurface(.secondary, padding: 16, cornerRadius: 20)
    }

    @ViewBuilder
    private func summaryActionRow(for presentation: MachineConnectionPresentation) -> some View {
        switch presentation.primaryAction {
        case .finishSetup:
            Button(presentation.nextSetupTitle ?? presentation.primaryAction.title) {
                onContinueSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("connections-summary-finish-setup-button")
        case .connect:
            Button("Connect") {
                model.connectLocalLoopback()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("connect-live-button")
        case .openCodex:
            Button("Open Codex") {
                onOpenCodex()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("open-codex-from-connections-button")
        case .resume:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    resumeButton
                    openCodexSecondaryButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    resumeButton
                    openCodexSecondaryButton
                }
            }
        }
    }

    private var resumeButton: some View {
        Button("Resume") {
            if let session = recentSessions.first {
                model.resumeSession(session.id)
            }
            onOpenCodex()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityIdentifier("connections-summary-resume-button")
    }

    private var openCodexSecondaryButton: some View {
        Button("Open Codex") {
            onOpenCodex()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("open-codex-from-connections-button")
    }

    private func statusTint(for state: MachineDirectoryOverallState) -> Color {
        switch state {
        case .ready:
            .green
        case .needsSetup:
            .orange
        case .unavailable:
            .secondary
        }
    }
}

private struct ForgetSavedMachineActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private extension EnvironmentValues {
    var forgetSavedMachineAction: (() -> Void)? {
        get { self[ForgetSavedMachineActionKey.self] }
        set { self[ForgetSavedMachineActionKey.self] = newValue }
    }
}

private struct ForgetSavedMachineCard: View {
    @Environment(\.forgetSavedMachineAction) private var forgetSavedMachineAction
    let model: AppModel
    let machine: MachineRecord
    @State private var showsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved connection")
                .font(.headline)

            Text("Forget \(machine.alias) on this \(AppDeviceCopy.thisDevice). This removes saved routes, trusted host keys, and the saved SSH login binding for this Mac from the app.")
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                showsConfirmation = true
            } label: {
                Text("Forget this Mac")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canForgetSelectedMachine)
            .accessibilityIdentifier("forget-machine-button")
        }
        .appSurface(.secondary, padding: 14, cornerRadius: 18)
        .alert("Forget this Mac?", isPresented: $showsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Mac", role: .destructive) {
                Task {
                    await model.forgetSelectedMachine()
                    forgetSavedMachineAction?()
                }
            }
        } message: {
            Text("This removes \(machine.alias) and its saved connection setup from this \(AppDeviceCopy.thisDevice).")
        }
    }
}

private func statusProbeLabel(_ label: String) -> some View {
    Group {
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            Text(label)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.08))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("connection-debug-status")
                .accessibilityLabel(label)
        } else {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.clear)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("connection-debug-status")
                .accessibilityLabel(label)
        }
    }
}

struct ConnectionInspectorPane: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            Group {
                if let machine = model.selectedMachine {
                    VStack(alignment: .leading, spacing: 16) {
                        DisclosureGroup("Technical details") {
                            if model.isDemoModeEnabled {
                                AppInlineNotice(
                                    title: "Live route tools paused",
                                    detail: "Turn off reviewer demo mode in Settings before scanning host keys, editing routes, or using tailnet/bootstrap tooling.",
                                    tint: .blue,
                                    icon: "pause.circle"
                                )
                                .padding(.top, 12)
                            } else {
                                ConnectionTechnicalDetailsContent(model: model, machine: machine)
                                .padding(.top, 12)
                            }
                        }
                        .controlSize(.small)
                        .tint(.accentColor)
                    }
                } else {
                    EmptyConnectionStateView(model: model, compactCopy: true)
                }
            }
            .padding(24)
            .frame(maxWidth: 420, alignment: .leading)
        }
        .background(shellBackground)
    }
}

private struct ConnectionSetupCard: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let model: AppModel
    let machine: MachineRecord
    let onOpenTechnicalDetails: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var showsPasswordLogin = false
    @State private var savedSSHKeyRecoveryAvailability: SavedSSHKeyRecoveryAvailability = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader("Finish setup on \(AppDeviceCopy.thisDevice)", subtitle: setupSubtitle) {
                AppMetadataChip(title: setupBadgeLabel, tint: setupTint)
            }

            connectionSection("Progress") {
                Text(progressSummary)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            connectionSection(currentSetupStepTitle) {
                currentSetupStepContent
            }

            if setupCompletedStepCount == setupRequiredStepCount {
                AppInlineNotice(
                    title: "\(AppDeviceCopy.thisDeviceCapitalized) is ready",
                    detail: "\(machine.alias) is fully set up here. Use the best route below, then open Codex.",
                    tint: .green,
                    icon: "checkmark.circle"
                )
            }

            if model.sshTrustStatusLabel == "Trusted" || model.canRevealSSHLoginPublicKey {
                Button("Open technical details") {
                    onOpenTechnicalDetails()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("connection-plan-open-recovery-button")
            }
        }
        .adaptiveGlassSurface(tint: AppVisualStyle.chromeTint, cornerRadius: 22, padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-setup-card")
        .onAppear(perform: syncUsernameField)
        .onChange(of: model.selectedBootstrapRoute?.id) { _, _ in
            syncUsernameField()
            password = ""
            showsPasswordLogin = false
        }
        .task(id: recoverableKeyTaskID) {
            await syncRecoverableSavedSSHKeyState()
        }
    }

    private var sshAccessActionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sshKeyAccessButtons
                passwordToggleButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    sshKeyAccessButtons
                }
                passwordToggleButton
            }
        }
    }

    @ViewBuilder
    private var sshKeyAccessButtons: some View {
        if canRecoverSavedSSHKeyDirectly {
            Button("Use Existing SSH Key") {
                model.recoverSavedSSHKeyLogin()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("connection-plan-use-existing-ssh-key-button")

            Button("Create New SSH Key") {
                model.generateSSHKeyCredential()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canGenerateSSHKeyLogin)
            .accessibilityIdentifier("connection-plan-generate-ssh-key-button")
        } else if canSearchSavedSSHKeys {
            if trustReady {
                Button(savedSSHKeyCandidateCount == 1 ? "Try Existing SSH Key" : "Try Existing SSH Keys") {
                    model.recoverSavedSSHKeyLogin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("connection-plan-try-existing-ssh-keys-button")
            } else {
                Button("Verify Mac Fingerprint") {
                    model.scanSelectedRouteHostKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canScanSelectedRouteHostKey)
                .accessibilityIdentifier("connection-plan-verify-fingerprint-before-saved-keys-button")
            }

            Button("Create New SSH Key") {
                model.generateSSHKeyCredential()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canGenerateSSHKeyLogin)
            .accessibilityIdentifier("connection-plan-generate-ssh-key-button")
        } else {
            Button(model.canRevealSSHLoginPublicKey ? "Replace SSH Key" : "Create SSH Key") {
                model.generateSSHKeyCredential()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canGenerateSSHKeyLogin)
            .accessibilityIdentifier("connection-plan-generate-ssh-key-button")
        }

        if model.canRevealSSHLoginPublicKey {
            Button("Show Public Key") {
                model.revealSSHLoginPublicKey()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("connection-plan-show-public-key-button")
        }
    }

    private var passwordToggleButton: some View {
        Button(showsPasswordLogin ? "Hide Password Login" : "Use Password Login") {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsPasswordLogin.toggle()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("connection-plan-toggle-password-button")
    }

    private func copyPublicKeyButton(_ publicKey: String) -> some View {
        Button("Copy Public Key") {
            copyValueToPasteboard(publicKey)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("connection-plan-copy-public-key-button")
    }

    private func copyInstallCommandButton(_ publicKey: String) -> some View {
        Button("Copy Install Command") {
            copyValueToPasteboard(authorizedKeysInstallCommand(for: publicKey))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("connection-plan-copy-install-command-button")
    }

    private var hasDetectedRoute: Bool {
        !machine.routes.isEmpty
    }

    private var showsCompactTrustActionDock: Bool {
        horizontalSizeClass == .compact
    }

    private var accountReady: Bool {
        model.connectionSetupAccountReady
    }

    private var sshAccessReady: Bool {
        model.connectionSetupSSHAccessReady
    }

    private var trustReady: Bool {
        model.connectionSetupTrustReady
    }

    private var shouldShowTrustSetupSection: Bool {
        accountReady
            && !trustReady
            && (model.canScanSelectedRouteHostKey || model.canTrustScannedHostKey)
    }

    private var recoverableKeyTaskID: String {
        [
            machine.id.uuidString,
            model.sshBootstrapUsername,
            model.selectedBootstrapRoute?.id.uuidString ?? "no-route",
            model.selectedMachine?.credentialRef?.keychainAccount ?? "no-credential"
        ]
        .joined(separator: "|")
    }

    private var canRecoverSavedSSHKeyDirectly: Bool {
        savedSSHKeyRecoveryAvailability == .directRecovery
    }

    private var canSearchSavedSSHKeys: Bool {
        if case .candidateSearch = savedSSHKeyRecoveryAvailability {
            return true
        }
        return false
    }

    private var savedSSHKeyCandidateCount: Int? {
        if case let .candidateSearch(count) = savedSSHKeyRecoveryAvailability {
            return count
        }
        return nil
    }

    private var sshAccessPrompt: String {
        if canRecoverSavedSSHKeyDirectly {
            return "A saved device SSH key for @\(model.sshBootstrapUsername) was found on \(AppDeviceCopy.thisDevice). Use it now, create a new key, or switch to password if needed."
        }

        if let savedSSHKeyCandidateCount {
            let keyLabel = savedSSHKeyCandidateCount == 1 ? "key was" : "keys were"
            if trustReady {
                return "Saved device SSH \(keyLabel) found on \(AppDeviceCopy.thisDevice). Try them before creating a new key, or switch to password if needed."
            }
            return "Saved device SSH \(keyLabel) found on \(AppDeviceCopy.thisDevice). Verify the Mac fingerprint, then try them before creating a new key."
        }

        return "Choose how \(AppDeviceCopy.thisDevice) should sign in as @\(model.sshBootstrapUsername). SSH key login is recommended, and password login stays available when you need a quicker first connect."
    }

    @MainActor
    private func syncRecoverableSavedSSHKeyState() async {
        savedSSHKeyRecoveryAvailability = .none

        guard accountReady && !sshAccessReady else {
            return
        }

        for attempt in 0..<10 {
            let availability = await model.savedSSHKeyRecoveryAvailabilityForSelectedMachine()
            if availability != .none {
                savedSSHKeyRecoveryAvailability = availability
                return
            }

            if attempt < 9 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var setupCompletedStepCount: Int {
        model.connectionSetupCompletedStepCount
    }

    private var setupRequiredStepCount: Int {
        model.connectionSetupRequiredStepCount
    }

    private var setupSubtitle: String {
        switch setupCompletedStepCount {
        case let completed where completed >= setupRequiredStepCount:
            return "The required SSH setup is done on \(AppDeviceCopy.thisDevice)."
        case 3:
            return "One step left before \(AppDeviceCopy.thisDevice) can reconnect on its saved routes."
        case 2:
            return "Choose how \(AppDeviceCopy.thisDevice) should sign in after you pick the Mac account."
        case 1:
            return "Find the Mac once, then choose the Mac account this iPhone should use."
        default:
            return "Finish these four setup steps once on \(AppDeviceCopy.thisDevice), then future reconnects stay fast."
        }
    }

    private var setupBadgeLabel: String {
        setupCompletedStepCount >= setupRequiredStepCount ? "Ready" : "\(setupCompletedStepCount)/\(setupRequiredStepCount) ready"
    }

    private var setupTint: Color {
        setupCompletedStepCount >= setupRequiredStepCount ? .green : .secondary
    }

    private var progressSummary: String {
        let segments = [
            progressSegment(title: "Find Mac", isReady: hasDetectedRoute),
            progressSegment(title: "Account", isReady: accountReady),
            progressSegment(title: "SSH", isReady: sshAccessReady),
            progressSegment(title: "Fingerprint", isReady: trustReady)
        ]

        return segments.joined(separator: "  •  ")
    }

    private var currentSetupStepTitle: String {
        if !accountReady {
            return "Choose Mac account"
        }
        if !sshAccessReady {
            return "Set up SSH access"
        }
        if shouldShowTrustSetupSection {
            return "Verify Mac fingerprint"
        }
        return "Setup complete"
    }

    @ViewBuilder
    private var currentSetupStepContent: some View {
        if !accountReady {
            setupActionCard {
                Text("Which macOS account should \(AppDeviceCopy.thisDevice) use on \(machine.alias)? Choose it once so SSH access and host trust stay tied to the same account.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Mac account username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ssh-username-field")

                Button("Continue") {
                    model.saveSelectedBootstrapUsername(username)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ssh-save-username-button")
            }
        } else if !sshAccessReady {
            setupActionCard {
                Text(sshAccessPrompt)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                sshAccessActionRow

                if let connectionSetupNotice = model.connectionSetupNotice,
                   !connectionSetupNotice.isEmpty {
                    VStack(spacing: 0) {
                        AppInlineNotice(
                            title: "Saved SSH keys need one more step",
                            detail: connectionSetupNotice
                        )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("connection-plan-saved-key-notice")
                }

                if let publicKey = model.revealedSSHLoginPublicKey {
                    detailLine("Device public key", value: publicKey)
                        .textSelection(.enabled)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            copyPublicKeyButton(publicKey)
                            copyInstallCommandButton(publicKey)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            copyPublicKeyButton(publicKey)
                            copyInstallCommandButton(publicKey)
                        }
                    }

                    Text("On the Mac, sign in as \(model.sshBootstrapUsername) and run the copied command in Terminal to append this key to `~/.ssh/authorized_keys`.")
                        .font(.caption)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsPasswordLogin {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("Save the Mac account password for this route", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .accessibilityIdentifier("ssh-password-field")

                        HStack(spacing: 12) {
                            Button("Save Password Login") {
                                model.savePasswordCredential(password)
                                password = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(
                                password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || !model.canSavePasswordLogin
                            )
                            .accessibilityIdentifier("ssh-save-password-button")

                            Text("Stored in the Apple keychain for this device.")
                                .font(.caption)
                                .foregroundStyle(AppVisualStyle.secondaryText)
                        }
                    }
                }
            }
        } else if shouldShowTrustSetupSection {
            setupActionCard {
                Text(trustPrompt)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if showsCompactTrustActionDock {
                    Text(compactTrustActionPrompt)
                        .font(.caption)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    trustActionTiles
                }

                if let scannedFingerprint = model.pendingScannedHostKeyFingerprint {
                    detailLine("Scanned fingerprint", value: scannedFingerprint)
                }
            }
        } else {
            setupActionCard {
                Text("\(AppDeviceCopy.thisDeviceCapitalized) is ready to use SSH with \(machine.alias). The best route and fallback methods are below.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progressSegment(title: String, isReady: Bool) -> String {
        "\(title): \(isReady ? "Ready" : "Needs action")"
    }

    private var detectDetail: String {
        if let route = model.selectedBootstrapRoute {
            return "Saved routes already identify \(machine.alias) through \(route.label)."
        }

        return "Scan local network or add a route to create the first connection path."
    }

    private var accountDetail: String {
        if !accountReady {
            return model.sshBootstrapUsernameGuidance
                ?? "Choose the macOS account username for the route you want to use."
        }

        return "Using @\(model.sshBootstrapUsername) on \(AppDeviceCopy.thisDevice)."
    }

    private var sshAccessDetail: String {
        if !accountReady {
            return "Choose the Mac account username first."
        }

        if model.sshCredentialStatusLabel == "Missing" {
            return "Choose how \(AppDeviceCopy.thisDevice) should sign in as @\(model.sshBootstrapUsername)."
        }

        return "Using \(model.sshCredentialStatusLabel.lowercased()) for @\(model.sshBootstrapUsername)."
    }

    private var trustDetail: String {
        if let guidance = model.selectedRouteScannedHostKeyGuidance {
            return guidance
        }

        switch model.sshTrustStatusLabel {
        case "Trusted":
            return "The trusted host fingerprint is stored for this route."
        case "Testing override":
            return "A localhost-only testing trust override is active."
        case "Mismatch":
            return "The stored fingerprint no longer matches. Verify the host key before reconnecting."
        default:
            if model.selectedMachine?.credentialRef?.kind == .password {
                return "The password login is saved. One last step: scan the SSH fingerprint and verify that it matches your Mac."
            }
            return "Scan the SSH host key once and verify the fingerprint before reconnecting."
        }
    }

    private var trustPrompt: String {
        if let guidance = model.selectedRouteScannedHostKeyGuidance {
            return guidance
        }

        if model.selectedMachine?.credentialRef?.kind == .password {
            return "The password login is already saved. Before \(AppDeviceCopy.thisDevice) reconnects safely, scan the SSH fingerprint and confirm that it matches your Mac."
        }

        return "Before \(AppDeviceCopy.thisDevice) can reconnect safely, scan the SSH fingerprint and confirm that it matches your Mac."
    }

    private var compactTrustActionPrompt: String {
        if model.canTrustScannedHostKey {
            return "Use the action bar above the tab bar to trust this fingerprint or scan again."
        }

        return "Use the action bar above the tab bar to scan the current fingerprint."
    }

    @ViewBuilder
    private var trustActionTiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.canTrustScannedHostKey {
                Text("Compare the scanned fingerprint with your Mac, then save it for this route.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        trustPrimaryButton
                        trustSecondaryButton
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        trustPrimaryButton
                        trustSecondaryButton
                    }
                }
            } else {
                Text("Fetch the current SSH fingerprint from the selected route before you trust it.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                scanHostKeyButton
            }
        }
    }

    private var trustPrimaryButton: some View {
        Button("Trust scanned key") {
            model.trustScannedHostKey()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!model.canTrustScannedHostKey)
        .accessibilityIdentifier("connection-plan-trust-host-key-button")
    }

    private var trustSecondaryButton: some View {
        Button("Scan again") {
            model.scanSelectedRouteHostKey()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canScanSelectedRouteHostKey)
        .accessibilityIdentifier("connection-plan-scan-host-key-button")
    }

    private var scanHostKeyButton: some View {
        Button("Scan host key") {
            model.scanSelectedRouteHostKey()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!model.canScanSelectedRouteHostKey)
        .accessibilityIdentifier("connection-plan-scan-host-key-button")
    }

    private func syncUsernameField() {
        let current = model.sshBootstrapUsername
        username = current == "Required" ? "" : current
    }

    private func authorizedKeysInstallCommand(for publicKey: String) -> String {
        let escapedKey = publicKey.replacingOccurrences(of: "'", with: "'\\''")
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' '\(escapedKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    private func copyValueToPasteboard(_ value: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = value
#endif
    }
}

private struct CompactConnectionTrustActionBar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify Mac fingerprint")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    primaryActionButton

                    if model.canTrustScannedHostKey {
                        secondaryActionButton
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    primaryActionButton

                    if model.canTrustScannedHostKey {
                        secondaryActionButton
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(AppVisualStyle.secondaryBorder, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var primaryActionButton: some View {
        Button(primaryTitle) {
            primaryAction()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!primaryEnabled)
        .accessibilityIdentifier(primaryIdentifier)
    }

    private var secondaryActionButton: some View {
        Button("Scan again") {
            model.scanSelectedRouteHostKey()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canScanSelectedRouteHostKey)
        .accessibilityIdentifier("connection-plan-scan-host-key-button")
    }

    private var primaryTitle: String {
        model.canTrustScannedHostKey ? "Trust scanned key" : "Scan host key"
    }

    private var primaryIdentifier: String {
        model.canTrustScannedHostKey
            ? "connection-plan-trust-host-key-button"
            : "connection-plan-scan-host-key-button"
    }

    private var primaryEnabled: Bool {
        model.canTrustScannedHostKey ? model.canTrustScannedHostKey : model.canScanSelectedRouteHostKey
    }

    private func primaryAction() {
        if model.canTrustScannedHostKey {
            model.trustScannedHostKey()
        } else {
            model.scanSelectedRouteHostKey()
        }
    }
}

private struct ConnectionRoutesCard: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let model: AppModel
    let machine: MachineRecord
    let onOpenCodex: () -> Void
    let onOpenTechnicalDetails: () -> Void

    @State private var showsLocalRouteComposer = false
    @State private var remoteComposerKind: MachineRouteKind?
    @State private var showsTailnetSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader("Ways to connect", subtitle: routesSubtitle) {
                AppMetadataChip(title: routesBadgeLabel, tint: routesTint)
            }

            if let failureSummary = model.connectionFailureSummary {
                AppInlineNotice(
                    title: "Connection needs attention",
                    detail: failureSummary,
                    tint: .orange
                )
            }

            connectionSection("Same Wi-Fi or nearby") {
                compactStep(title: nearbyActionTitle, detail: nearbyDetail, isReady: nearbyReady)

                if let nearbySuggestion {
                    ConnectionFallbackRow(model: model, suggestion: nearbySuggestion)
                }

                routeActionRow {
                    Button {
                        model.scanLocalNetwork()
                    } label: {
                        HStack(spacing: 8) {
                            if case .scanning = model.localNetworkScanStatus {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(nearbyScanButtonTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isLocalNetworkScanInFlight)
                    .accessibilityIdentifier("connection-routes-scan-local-button")

                    Button("Add local hostname or IP") {
                        showsLocalRouteComposer.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("connection-routes-add-local-button")
                }

                if showsLocalRouteComposer {
                    QuickManualRouteCard(
                        model: model,
                        title: "Add nearby route",
                        subtitle: "Use this when the iPhone should reach the Mac over the same Wi-Fi or another nearby local network.",
                        submitTitle: "Save nearby route",
                        availableKinds: [.localLAN, .manualSSH],
                        initialKind: .localLAN
                    )
                }
            }

            connectionSection("Away from home") {
                compactStep(title: awayActionTitle, detail: awayDetail, isReady: awayReady)

                if !remoteSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(remoteSuggestions) { suggestion in
                            ConnectionFallbackRow(model: model, suggestion: suggestion)
                        }
                    }
                }

                routeActionRow {
                    Button("Add Tailscale hostname") {
                        remoteComposerKind = remoteComposerKind == .externalTailnet ? nil : .externalTailnet
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("connection-routes-add-tailnet-button")

                    Button("Add direct SSH host") {
                        remoteComposerKind = remoteComposerKind == .manualSSH ? nil : .manualSSH
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("connection-routes-add-remote-ssh-button")
                }

                if showsTailnetControls {
                    DisclosureGroup("Built-in and Tailscale routes", isExpanded: $showsTailnetSetup) {
                        TailnetProfilesCard(model: model)
                            .padding(.top, 12)
                    }
                    .tint(.accentColor)
                }

                if let remoteComposerKind {
                    QuickManualRouteCard(
                        model: model,
                        title: "Add away-from-home route",
                        subtitle: "Save a Tailscale hostname or direct SSH host so reconnects still work when the Mac is no longer nearby.",
                        submitTitle: "Save away-from-home route",
                        availableKinds: [.externalTailnet, .manualSSH],
                        initialKind: remoteComposerKind
                    )
                }
            }

            connectionSection("Saved routes and priority") {
                Text("Keep at least one nearby route and one away-from-home route. The app uses the healthiest eligible route automatically, or you can pin a default below.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if model.routeEvaluations.isEmpty {
                    Text("No routes are saved for this Mac yet.")
                        .font(.caption)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.routeEvaluations) { evaluation in
                            ConnectionSavedRouteRow(
                                model: model,
                                evaluation: evaluation,
                                preferredRouteID: machine.preferredRouteID
                            )
                        }
                    }
                }
            }

            if let guidance = networkChangeGuidance {
                AppInlineNotice(
                    title: guidance.title,
                    detail: guidance.detail,
                    tint: .blue,
                    icon: "antenna.radiowaves.left.and.right"
                )
                .accessibilityIdentifier("connection-plan-network-change-notice")
            }

            Button("Open technical details") {
                onOpenTechnicalDetails()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("connection-routes-open-technical-details-button")

#if canImport(UIKit)
            if model.needsLocalNetworkSettingsRepair,
               let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") {
                    UIApplication.shared.open(settingsURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("open-app-settings-button")
            }
#endif
        }
        .adaptiveGlassSurface(tint: AppVisualStyle.chromeTint, cornerRadius: 22, padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-routes-card")
    }

    private var preferredRoute: RouteRecord? {
        model.recommendedRoute ?? model.selectedBootstrapRoute
    }

    private var routeReady: Bool {
        model.connectionCandidateIsReady
    }

    private var nearbyEvaluations: [RouteEvaluation] {
        model.routeEvaluations.filter { evaluation in
            evaluation.route.kind == .localLAN
                || (evaluation.route.kind == .manualSSH && evaluation.route.requiresNearbyNetworkTransport)
        }
    }

    private var awayEvaluations: [RouteEvaluation] {
        model.routeEvaluations.filter { evaluation in
            !nearbyEvaluations.contains(where: { $0.id == evaluation.id })
        }
    }

    private var remoteSuggestions: [ConnectionFallbackSuggestion] {
        model.connectionFallbackSuggestions.filter { $0.kind != .sameLAN }
    }

    private var nearbySuggestion: ConnectionFallbackSuggestion? {
        model.connectionFallbackSuggestions.first(where: { $0.kind == .sameLAN })
    }

    private var routesSubtitle: String {
        if routeReady {
            return "Keep one nearby path and one away-from-home fallback so reconnects stay predictable."
        }

        return "Choose the nearby path and the away-from-home fallback you want to keep for this Mac."
    }

    private var routesBadgeLabel: String {
        if routeReady {
            return "Ready now"
        }
        if nearbyReady || awayReady {
            return "Routes saved"
        }
        return "Add routes"
    }

    private var routesTint: Color {
        routeReady ? .green : .secondary
    }

    private var nearbyReady: Bool {
        nearbyEvaluations.contains(where: \.isEligible)
    }

    private var awayReady: Bool {
        awayEvaluations.contains(where: \.isEligible)
    }

    private var showsPrimaryActionsNearHeader: Bool {
        horizontalSizeClass == .compact
    }

    private var primaryActionRow: some View {
        Group {
            if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 8) {
                    connectButton
                    openCodexButton
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    connectButton
                    openCodexButton
                }
            }
        }
    }

    private var canOpenCodex: Bool {
        model.selectedMachine != nil && (model.recommendedRoute != nil || model.activeSession != nil)
    }

    private var nearbyActionTitle: String {
        nearbyReady ? "Nearby route saved" : "Add nearby route"
    }

    private var awayActionTitle: String {
        awayReady ? "Away-from-home route saved" : "Add away-from-home route"
    }

    private var nearbyDetail: String {
        if let eligibleRoute = nearbyEvaluations.first(where: \.isEligible)?.route {
            return nearbyReadinessDetail(for: eligibleRoute)
        }

        if !nearbyEvaluations.isEmpty {
            return "A nearby route is saved, but it only works when the iPhone can still reach the Mac on the local network. Scan again or update the local hostname or IP if needed."
        }

        return "Scan local network first. If discovery does not find the Mac but both devices are still nearby, add a local hostname or IP manually."
    }

    private var awayDetail: String {
        if let eligibleRoute = awayEvaluations.first(where: \.isEligible)?.route {
            return awayRouteReadinessDetail(for: eligibleRoute)
        }

        if !awayEvaluations.isEmpty {
            return "An away-from-home route is saved, but it is not ready on the current network yet. Check Tailscale, Companion reachability, or the saved remote SSH host."
        }

        return "Save at least one away-from-home path before leaving the nearby network. Tailscale is the default fallback, and direct SSH stays available when you have another reachable host."
    }

    private var nearbyScanButtonTitle: String {
        if isLocalNetworkScanInFlight {
            return "Scanning local network..."
        }
        return "Scan local network"
    }

    private var isLocalNetworkScanInFlight: Bool {
        if case .scanning = model.localNetworkScanStatus {
            return true
        }
        return false
    }

    private var showsTailnetControls: Bool {
        model.showsEmbeddedTailnetFeature
            || !model.tailnetProfiles.isEmpty
            || model.showsExternalTailnetStatus
    }

    private func routeActionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                content()
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if routeReady {
            Button {
                model.connectLocalLoopback()
            } label: {
                Text(primaryActionTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.selectedMachine == nil)
            .accessibilityIdentifier("connect-live-button")
        }
    }

    @ViewBuilder
    private var openCodexButton: some View {
        if canOpenCodex {
            Button {
                onOpenCodex()
            } label: {
                Text("Open Codex")
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("open-codex-from-connections-button")
        }
    }

    private var currentActionTitle: String {
        switch preferredRoute?.kind {
        case .embeddedTailnet, .externalTailnet:
            return "Reconnect away from home"
        case .localLAN:
            return "Reconnect on the same Wi‑Fi"
        case .manualSSH:
            return "Reconnect with direct SSH"
        case .companionDirect:
            return "Reconnect through Companion"
        case nil:
            return "Use the best available route"
        }
    }

    private var primaryActionTitle: String {
        let prefix: String
        switch model.connectionState {
        case .connected:
            prefix = "Reconnect"
        case .connecting:
            return "Connecting…"
        case .disconnected, .failed:
            prefix = "Connect"
        }

        switch preferredRoute?.kind {
        case .embeddedTailnet, .externalTailnet:
            return "\(prefix) on Tailscale"
        case .localLAN:
            return "\(prefix) on same Wi-Fi"
        case .manualSSH:
            return "\(prefix) with SSH"
        case .companionDirect:
            return "\(prefix) via Companion"
        case nil:
            return "\(prefix) best route"
        }
    }

    private var networkChangeGuidance: (title: String, detail: String)? {
        if model.networkProxyStatusLabel != "Direct paths healthy" {
            return ("Check proxy or VPN rules", model.networkProxyDetail)
        }

        switch preferredRoute?.kind {
        case .localLAN, .manualSSH:
            return (
                "When you leave this Wi-Fi",
                "LAN and direct SSH routes are best nearby. Save a Tailscale fallback now so cellular reconnects do not depend on local discovery."
            )
        case .embeddedTailnet, .externalTailnet:
            return (
                "When you come back to this Wi-Fi",
                "Tailscale is your away-from-home path. Keep a same-Wi-Fi or manual SSH fallback ready for faster local recovery and trust repair."
            )
        case .companionDirect:
            return (
                "If the Companion path drops",
                "Keep an SSH-backed route ready so you can still reconnect, repair trust, or reach diagnostics without the Companion endpoint."
            )
        case nil:
            return nil
        }
    }

    private func nearbyReadinessDetail(for route: RouteRecord) -> String {
        switch route.kind {
        case .localLAN:
            return "\(route.label) is ready while the iPhone and Mac stay on the same Wi-Fi."
        case .manualSSH:
            return "\(route.label) is ready as a direct nearby SSH route."
        case .embeddedTailnet, .externalTailnet, .companionDirect:
            return "\(route.label) is saved."
        }
    }

    private func awayRouteReadinessDetail(for route: RouteRecord) -> String {
        switch route.kind {
        case .embeddedTailnet:
            return "\(route.label) is ready through the built-in Tailscale route."
        case .externalTailnet:
            return "\(route.label) is ready through the Tailscale app route."
        case .manualSSH:
            return "\(route.label) is ready as a direct remote SSH fallback."
        case .companionDirect:
            return "\(route.label) is ready through the Companion path."
        case .localLAN:
            return "\(route.label) is saved."
        }
    }
}

private struct ConnectionSavedRouteRow: View {
    let model: AppModel
    let evaluation: RouteEvaluation
    let preferredRouteID: RouteRecord.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(evaluation.route.label)
                        .font(.subheadline.weight(.semibold))
                    Text(savedRouteDetail)
                        .font(.caption)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isPreferred {
                    preferenceChip("Default", tint: .blue)
                } else if evaluation.isRecommended {
                    preferenceChip("Best now", tint: .green)
                }
            }

            HStack(spacing: 8) {
                preferenceChip(evaluation.route.kind.shortTitle, tint: .secondary)
                preferenceChip(evaluation.route.requiresNearbyNetworkTransport ? "Nearby" : "Remote", tint: .secondary)
                preferenceChip(evaluation.isReachable ? "Reachable" : "Unavailable", tint: evaluation.isReachable ? .green : .orange)
                preferenceChip(evaluation.route.trustState == .trusted ? "Verified" : "Needs fingerprint", tint: evaluation.route.trustState == .trusted ? .green : .orange)
            }

            if let endpointLabel {
                detailLine("Host", value: endpointLabel)
            }

            if !isPreferred, evaluation.route.kind != .companionDirect {
                Button("Make default") {
                    model.preferRoute(routeID: evaluation.route.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("connection-routes-prefer-\(evaluation.route.kind.rawValue)")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("connection-saved-route-\(evaluation.route.kind.rawValue)")
    }

    private var isPreferred: Bool {
        preferredRouteID == evaluation.route.id || evaluation.route.isUserPinned
    }

    private var savedRouteDetail: String {
        if evaluation.isEligible {
            return "Saved and ready on the current network."
        }
        if evaluation.isReachable {
            return "Saved, but not the best usable route right now."
        }
        return "Saved, but unavailable on the current network."
    }

    private var endpointLabel: String? {
        let route = evaluation.route
        let candidates = [
            route.magicDNSName,
            route.hostname,
            route.ipAddress,
            route.address
        ]

        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func preferenceChip(_ label: String, tint: Color) -> some View {
        AppMetadataChip(title: label, tint: tint)
    }
}

private func compactStep(title: String, detail: String, isReady: Bool) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isReady ? Color.green : AppVisualStyle.tertiaryText)
            .padding(.top, 1)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(isReady ? "Ready" : "Needs action")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isReady ? .green : .orange)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func connectionSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        content()
    }
}

private struct ConnectionFallbackRow: View {
    let model: AppModel
    let suggestion: ConnectionFallbackSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let actionTitle = suggestion.actionTitle {
                    Button(actionTitle) {
                        model.applyConnectionFallbackSuggestion(suggestion)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(suggestion.accessibilityIdentifier)-action")
                }
            }

            Text(suggestion.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier(suggestion.accessibilityIdentifier)
    }
}

private func detailLine(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Text(value)
            .font(.footnote.monospaced())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func setupActionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        content()
    }
    .padding(12)
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}
 

private struct RouteDiagnosticsCard: View {
    let model: AppModel
    let machine: MachineRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Route diagnostics")
                .font(.title3.weight(.semibold))

            if machine.routes.isEmpty {
                Text("No routes are configured for this Mac yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(model.routeEvaluations) { evaluation in
                        RouteDiagnosticRow(model: model, evaluation: evaluation)
                    }
                }
            }
        }
        .adaptiveGlassSurface(tint: AppVisualStyle.chromeTint, cornerRadius: 28)
    }
}

private struct RouteDiagnosticRow: View {
    let model: AppModel
    let evaluation: RouteEvaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.label)
                        .font(.headline)
                    Text(route.address)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Text(route.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    statusPill(healthStatusText, tint: healthTint)
                    statusPill(route.trustState.rawValue.capitalized, tint: trustTint)
                }
            }

            HStack(spacing: 8) {
                labelChip(discoverySourceLabel)
                if evaluation.isConfigured { labelChip("Configured") }
                if evaluation.isAuthenticated { labelChip("Authenticated") }
                if evaluation.isReachable { labelChip("Reachable") }
                if evaluation.isEligible { labelChip("Eligible") }
                if evaluation.isRecommended { labelChip("Recommended") }
                if evaluation.isActive { labelChip("Active") }
                if evaluation.isLastGood { labelChip("Last good") }
            }

            if !evaluation.isRecommended && route.kind != .companionDirect {
                Menu {
                    Button("Use This Route") {
                        model.preferRoute(routeID: route.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Route actions")
                .accessibilityIdentifier("use-route-\(route.kind.rawValue)")
            }
        }
        .padding(14)
        .background(AppVisualStyle.panelBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("route-diagnostic-row-\(route.kind.rawValue)")
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private func labelChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var route: RouteRecord { evaluation.route }

    private var healthTint: Color {
        switch route.health {
        case .healthy:
            .green
        case .degraded:
            .orange
        case .unavailable:
            .red
        }
    }

    private var trustTint: Color {
        switch route.trustState {
        case .trusted:
            .green
        case .unknown:
            .orange
        case .mismatch:
            .red
        }
    }

    private var discoverySourceLabel: String {
        switch route.discoverySource {
        case .manual:
            "Manual"
        case .bonjour:
            "Bonjour"
        case .cachedProbe:
            "Cached probe"
        case .companionAdvertisement:
            "Companion"
        case .tailnetProfile:
            "Tailnet"
        case .imported:
            "Imported"
        }
    }

    private var healthStatusText: String {
        route.health.rawValue.capitalized
    }
}

private struct RecentSessionsCard: View {
    @Environment(\.openWindow) private var openWindow

    let model: AppModel
    let sessions: [SessionRecord]
    let onOpenCodex: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader("Recent threads", subtitle: "Resume here, but daily browsing stays in Codex.") {
                AppMetadataChip(title: "\(sessions.count)", tint: .secondary)
            }

            if sessions.isEmpty {
                Text("No recent threads recorded for this Mac yet.")
                    .font(.subheadline)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            } else {
                VStack(spacing: 10) {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.threadID ?? "Thread pending")
                                .font(.subheadline.weight(.semibold))
                            Text(session.lastTurn?.summary ?? session.workspaceRoot ?? "Workspace not set")
                                .font(.caption)
                                .foregroundStyle(AppVisualStyle.secondaryText)

                            HStack(spacing: 10) {
                                Button("Resume thread") {
                                    model.resumeSession(session.id)
                                    onOpenCodex()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityIdentifier("connections-resume-thread-\(session.id.uuidString)")

                                Menu {
                                    Button("Open Window") {
                                        openWindow(id: CodingOnTheGoRouting.machineWindowGroupID, value: session.machineID.uuidString)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.body)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Thread actions")
                                .accessibilityIdentifier("open-session-window-\(session.id.uuidString)")
                            }
                        }
                        .appSurface(.secondary, padding: 12, cornerRadius: 16)
                    }
                }
            }
        }
        .appSurface(.secondary, padding: 14, cornerRadius: 18)
    }
}

private struct EmptyConnectionStateView: View {
    let model: AppModel
    var compactCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSectionHeader(
                compactCopy ? "No Mac selected" : "Connections",
                subtitle: compactCopy
                    ? "Choose a Mac from the sidebar, or add one first using discovery or manual SSH."
                    : "Add a Mac, confirm the connection path, then return to Codex to choose a project."
            )

            HStack(spacing: 12) {
                Button {
                    model.scanLocalNetwork()
                }
                label: {
                    HStack(spacing: 8) {
                        if case .scanning = model.localNetworkScanStatus {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(scanButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanInFlight)
                .accessibilityIdentifier("empty-state-scan-local-network-button")

                ProductSupportButtonRow(
                    privacyAccessibilityIdentifier: "empty-state-privacy-link",
                    supportAccessibilityIdentifier: "empty-state-support-link"
                )
            }
        }
        .adaptiveGlassSurface(tint: AppVisualStyle.chromeTint, cornerRadius: 22, padding: 16)
    }

    private var isScanInFlight: Bool {
        if case .scanning = model.localNetworkScanStatus {
            return true
        }
        return false
    }

    private var scanButtonTitle: String {
        if isScanInFlight {
            return "Scanning..."
        }
        return "Scan Local Network"
    }
}
