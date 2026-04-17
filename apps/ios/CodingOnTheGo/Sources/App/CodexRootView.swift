import AppState
import CodexRPC
import GitWorkspace
import SharedModels
import SwiftUI

private struct CodexSelectionPresentation {
    let recentSessions: [SessionRecord]
    let storedSelectedSessionID: String
    let hasPreparedSession: Bool
    let activeThreadID: String?
    let browserIsVisible: Bool

    var resolvedSelectedSessionID: SessionRecord.ID? {
        guard let sessionID = UUID(uuidString: storedSelectedSessionID) else {
            return nil
        }

        guard recentSessions.contains(where: { $0.id == sessionID }) else {
            return nil
        }

        return sessionID
    }

    var sanitizedStoredSelectedSessionID: String {
        resolvedSelectedSessionID?.uuidString ?? ""
    }

    var hasConversationContext: Bool {
        resolvedSelectedSessionID != nil
            || hasPreparedSession
            || (!browserIsVisible && activeThreadID != nil)
    }
}

private struct CodexWorkspacePickerRequest: Identifiable {
    let machineID: MachineRecord.ID
    let initialPath: String?

    var id: String {
        "\(machineID.uuidString)::\(initialPath ?? "root")"
    }
}

private enum CodexBrowserPresentationSource {
    case automatic
    case explicit
}

struct CodexRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("cotg.experimental.showAllReposAcrossMacs") private var showAllReposAcrossMacs = false
    @AppStorage("cotg.codex.browserPresentationStyle") private var browserPresentationStyleRaw = CodexBrowserPresentationStyle.sheet.rawValue
    @SceneStorage("cotg.codex.browser.visible") private var showsBrowser = true
    @SceneStorage("cotg.codex.inspector.visible") private var showsInspector = false
    @SceneStorage("cotg.codex.selectedSessionID") private var storedSelectedSessionID = ""
    @SceneStorage("cotg.codex.review.visible") private var storedReviewVisible = false
    @State private var handledBrowserOpenRequestToken = 0
    @State private var browserPresentationSource: CodexBrowserPresentationSource = .automatic
    @State private var showsCompactNavigationOptions = false
    @State private var workspacePickerRequest: CodexWorkspacePickerRequest?

    let model: AppModel
    let isActiveTab: Bool
    let browserOpenRequestToken: Int
    let bottomAccessoryClearance: CGFloat
    let onOpenConnections: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .background(shellBackground)
        .onAppear {
            resetUITestScenePresentationIfNeeded()
            reconcileSelectionPresentation()
        }
        .onChange(of: model.recentSessions) { _, _ in
            reconcileSelectionPresentation()
        }
        .onChange(of: isActiveTab) { _, newValue in
            guard newValue else {
                return
            }
            reconcileSelectionPresentation()
        }
        .onChange(of: model.activeSession?.id) { _, _ in
            reconcileSelectionPresentation()
        }
        .onChange(of: model.activeSession?.threadID) { _, _ in
            reconcileSelectionPresentation()
        }
        .task(id: browserOpenRequestToken) {
            guard horizontalSizeClass == .compact,
                  browserOpenRequestToken > handledBrowserOpenRequestToken else {
                return
            }

            handledBrowserOpenRequestToken = browserOpenRequestToken
            requestBrowserPresentation(source: .explicit, forceRefreshIfAlreadyRequested: true)
        }
        .sheet(item: $workspacePickerRequest) { request in
            workspacePickerSheet(request: request)
        }
    }

    private var compactBody: some View {
        NavigationStack {
            codexContent
                .navigationTitle(hasConversationContext ? "" : "Choose a project")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            requestBrowserPresentation(source: .explicit, forceRefreshIfAlreadyRequested: isActiveTab)
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .accessibilityLabel("Browse")
                        .accessibilityIdentifier("codex-browse-button")
                    }

                    if hasConversationContext {
                        ToolbarItem(placement: .topBarTrailing) {
                            compactNavigationMenu
                        }
                    }

                    ToolbarItem(placement: .principal) {
                        CompactCodexNavigationTitle(
                            model: model,
                            hasConversationContext: hasConversationContext
                        )
                    }
                }
        }
        .sheet(isPresented: browserSheetBinding) {
            browserSheet
        }
        .confirmationDialog(
            "Open",
            isPresented: $showsCompactNavigationOptions,
            titleVisibility: .hidden
        ) {
            compactNavigationActions
        }
        .sheet(isPresented: $storedReviewVisible) {
            NavigationStack {
                inspectorContent
                    .navigationTitle("Inspector")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var regularBody: some View {
        NavigationSplitView {
            CodexSessionBrowserView(
                model: model,
                inSidebar: true,
                onSelectMachine: { machineID in
                    model.select(machineID: machineID)
                },
                onResumeSession: selectSession,
                onNewSession: startNewSession,
                onArchiveSession: archiveSession,
                onChooseWorkspace: openWorkspacePicker,
                onOpenConnections: onOpenConnections
            )
            .navigationTitle("Codex")
        } detail: {
            codexContent
                .navigationTitle("Codex")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if hasConversationContext {
                            Button {
                                showsInspector.toggle()
                            } label: {
                                Label(showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                            }
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorBinding) {
            inspectorContent
        }
    }

    private var browserSheet: some View {
        CodexBrowserSheet(
            model: model,
            browserPresentationDetents: browserPresentationDetents,
            sessionDebugStatusLabel: sessionDebugStatusLabel,
            closeBrowser: closeBrowserPresentation,
            onSelectMachine: { machineID in
                model.select(machineID: machineID)
            },
            onResumeSession: selectSession,
            onNewSession: startNewSession,
            onArchiveSession: archiveSession,
            onChooseWorkspace: openWorkspacePicker,
            onOpenConnections: openConnectionsFromBrowser
        )
    }

    private var browserSheetBinding: Binding<Bool> {
        Binding(
            get: { isActiveTab && showsBrowser },
            set: { isPresented in
                if isPresented {
                    showsBrowser = true
                } else {
                    closeBrowserPresentation()
                }
            }
        )
    }

    @ViewBuilder
    private func workspacePickerSheet(request: CodexWorkspacePickerRequest) -> some View {
        NavigationStack {
            CodexWorkspacePickerView(
                model: model,
                machine: model.machines.first(where: { $0.id == request.machineID }),
                initialPath: request.initialPath,
                onSelectWorkspace: { workspaceRoot in
                    startNewSession(machineID: request.machineID, workspaceRoot: workspaceRoot)
                    workspacePickerRequest = nil
                }
            )
            .navigationTitle("Choose Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        workspacePickerRequest = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var codexContent: some View {
        ZStack {
            shellBackground

            if hasConversationContext {
                conversationWorkspace
            } else {
                emptyWorkspace
            }
        }
        .task(id: activeThreadRefreshKey) {
            await runActiveThreadRefreshLoop(for: activeThreadRefreshKey)
        }
        .overlay(alignment: .bottomTrailing) {
            sessionStatusProbe
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: horizontalSizeClass == .compact ? 4 : 10) {
                if horizontalSizeClass == .compact,
                   let approval = model.pendingApprovalRequest {
                    PendingApprovalActionStrip(model: model, approval: approval)
                }

                ComposerToolsCard(model: model)
                    .padding(.bottom, bottomAccessoryClearance > 0 ? 2 : 0)
            }
        }
    }

    private var compactNavigationMenu: some View {
        Button {
            showsCompactNavigationOptions = true
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("codex-more-button")
    }

    @ViewBuilder
    private var compactNavigationActions: some View {
        if hasConversationContext {
            Button(storedReviewVisible ? "Hide Inspector" : "Show Inspector") {
                storedReviewVisible.toggle()
            }
            .accessibilityIdentifier("codex-inspector-button")
        }
    }

    private var inspectorContent: some View {
        CodexInspectorPane(model: model, onOpenSettings: onOpenSettings)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
    }

    private var conversationWorkspace: some View {
        let isCompact = horizontalSizeClass == .compact

        return VStack(spacing: isCompact ? 6 : AppVisualStyle.Metrics.sectionSpacing) {
            if model.isDemoModeEnabled {
                AppInlineNotice(
                    title: "Reviewer demo mode",
                    detail: "Projects, Threads, transcript history, and workspace status are coming from bundled local demo data. Live Macs, SSH, and tailnet are not in use.",
                    tint: .blue,
                    icon: "sparkles.rectangle.stack"
                )
            }

            if isCompact {
                CompactCodexChatChrome(
                    model: model,
                    openReview: openReview
                )
            } else {
                CodexSessionChrome(
                    model: model,
                    showMachineContext: showAllReposAcrossMacs || model.machines.count > 1,
                    mode: .regular
                )
            }

            VStack(alignment: .leading, spacing: isCompact ? 6 : AppVisualStyle.Metrics.sectionSpacing) {
                if !isCompact && !shouldHideWorkspaceSummaryDuringReconnect {
                    WorkspaceReviewCard(
                        model: model,
                        displayStyle: .summary,
                        openFullReview: openReview
                    )
                }

                SessionWorkspaceCard(
                    model: model,
                    onShowBrowser: {
                        requestBrowserPresentation(source: .explicit, forceRefreshIfAlreadyRequested: false)
                    },
                    onOpenConnections: onOpenConnections
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 960, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, isCompact ? 4 : 12)
        .padding(.bottom, isCompact ? 6 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppVisualStyle.Metrics.sectionSpacing) {
                if model.isDemoModeEnabled {
                    AppInlineNotice(
                        title: "Reviewer demo mode",
                        detail: "Use the bundled demo Mac and sample threads to explore the browser, transcript, composer, and reconnect flow without connecting to a real host.",
                        tint: .blue,
                        icon: "sparkles.rectangle.stack"
                    )
                }

                CodexEmptyState(
                    hasMachines: !model.machines.isEmpty,
                    showsReviewerDemoShortcut: !model.isDemoModeEnabled && model.machines.isEmpty,
                    onBrowse: { requestBrowserPresentation(source: .explicit, forceRefreshIfAlreadyRequested: true) },
                    onOpenConnections: onOpenConnections,
                    onOpenSettings: onOpenSettings
                )
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 16)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var horizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? 16 : 24
    }

    private var shouldHideWorkspaceSummaryDuringReconnect: Bool {
        guard case .connecting = model.connectionState else {
            return false
        }

        if model.transcript.isEmpty {
            return true
        }

        return model.workspaceSummary == nil
            && model.workspaceFailureSummary == nil
            && model.shouldShowTranscriptRestorePlaceholder
    }

    private var sessionStatusProbe: some View {
        codexStatusProbeLabel(sessionDebugStatusLabel)
    }

    private var sessionDebugStatusLabel: String {
        let connectionLabel = switch model.connectionState {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .failed:
            "failed"
        }

        let assistantReplyCount = model.transcript.reduce(into: 0) { count, message in
            if message.countsAsAssistantReply {
                count += 1
            }
        }
        let isStreaming = model.threadFeatureState.isStreaming
            || model.transcript.contains(where: \.isStreaming)
        let threadID = model.activeSession?.threadID ?? "none"
        let authorityState = model.activeExecutionProfileState == nil ? "missing" : "present"
        let authorityLabel = model.activeAuthorityStatusLabel ?? "none"
        let activeTurnID = model.activeTurnID ?? "none"
        let activityFlags = model.threadFeatureState.activityFlags.joined(separator: ",")
        let pendingApproval = model.pendingApprovalRequest
        let pendingApprovalState = pendingApproval == nil ? "false" : "true"
        let pendingApprovalMethod = pendingApproval?.method.rawValue ?? "none"
        let pendingApprovalThreadID = pendingApproval?.threadID ?? "none"
        let pendingApprovalTurnID = pendingApproval?.turnID ?? "none"
        let connectionError = model.connectionFailureSummary?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ";", with: ",")
            ?? "none"
        let sessionID = model.activeSession?.id.uuidString ?? "none"
        let activeSessionID = model.activeSessionID?.uuidString ?? "none"
        let preferredApproval = model.preferredApprovalPolicy ?? "none"
        let preferredSandbox = model.preferredSandboxMode?.rawValue ?? "none"
        let executionProfile = model.activeExecutionProfileState?.profile
        let requestedApproval = executionProfile?.approvalPolicy.requested ?? "none"
        let effectiveApproval = executionProfile?.approvalPolicy.effective ?? "none"
        let requestedSandbox = executionProfile?.sandboxMode.requested ?? "none"
        let effectiveSandbox = executionProfile?.sandboxMode.effective ?? "none"

        return "session=\(sessionID);activeSessionID=\(activeSessionID);thread=\(threadID);transcript=\(model.transcript.count);assistantReplies=\(assistantReplyCount);streaming=\(isStreaming);connection=\(connectionLabel);protocol=\(model.activeProtocolKind.rawValue);connectionError=\(connectionError);preferredApproval=\(preferredApproval);preferredSandbox=\(preferredSandbox);requestedApproval=\(requestedApproval);effectiveApproval=\(effectiveApproval);requestedSandbox=\(requestedSandbox);effectiveSandbox=\(effectiveSandbox);authorityState=\(authorityState);authorityLabel=\(authorityLabel);activeTurn=\(activeTurnID);activityFlags=\(activityFlags);pendingApproval=\(pendingApprovalState);pendingApprovalMethod=\(pendingApprovalMethod);pendingApprovalThread=\(pendingApprovalThreadID);pendingApprovalTurn=\(pendingApprovalTurnID);browserVisible=\(showsBrowser);browserRequest=\(browserOpenRequestToken);browserHandled=\(handledBrowserOpenRequestToken);composerAttempts=\(model.composerSendAttemptCount);draftCount=\(model.composerState.draft.count)"
    }

    private var browserPresentationStyle: CodexBrowserPresentationStyle {
        CodexBrowserPresentationStyle(rawValue: browserPresentationStyleRaw) ?? .sheet
    }

    private var browserPresentationDetents: Set<PresentationDetent> {
        switch browserPresentationStyle {
        case .sheet:
            [.large]
        case .drawer:
            [.medium, .large]
        }
    }

    private var hasConversationContext: Bool {
        selectionPresentation.hasConversationContext
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showsInspector && hasConversationContext },
            set: { showsInspector = $0 }
        )
    }

    private var activeThreadRefreshKey: String {
        model.visibleActiveThreadRefreshLoopKey(
            sceneIsActive: scenePhase == .active,
            browserIsVisible: showsBrowser
        )
    }

    private var selectionPresentation: CodexSelectionPresentation {
        CodexSelectionPresentation(
            recentSessions: model.recentSessions,
            storedSelectedSessionID: storedSelectedSessionID,
            hasPreparedSession: model.activeSession?.threadID != nil
                || normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot) != nil,
            activeThreadID: model.activeSession?.threadID,
            browserIsVisible: showsBrowser
        )
    }

    private var shouldResetScenePresentationForUITests: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
            && ProcessInfo.processInfo.environment["COTG_UI_TEST_RESET_ON_LAUNCH"] == "1"
    }

    private func runActiveThreadRefreshLoop(for refreshKey: String) async {
        guard refreshKey != "inactive" else {
            return
        }

        while !Task.isCancelled, refreshKey == activeThreadRefreshKey {
            await model.refreshVisibleActiveThreadIfNeeded()
            do {
                try await Task.sleep(for: model.visibleActiveThreadRefreshInterval())
            } catch {
                return
            }
        }
    }

    private func selectSession(_ session: CodexSessionSummary) {
        if model.selectedMachineID != session.machine.id {
            model.select(machineID: session.machine.id)
        }
        let resumedSessionID = model.resumeHostThreadCatalogEntry(session.thread)
        if resumedSessionID == nil, let matchedSessionID = session.matchedSessionID {
            model.resumeSession(matchedSessionID)
        }
        storedSelectedSessionID = resumedSessionID?.uuidString ?? session.matchedSessionID?.uuidString ?? ""
        closeBrowserPresentation()
    }

    private func startNewSession(_ group: CodexRepoGroup) {
        startNewSession(machineID: group.machine.id, workspaceRoot: group.repoPath)
    }

    private func startNewSession(machineID: MachineRecord.ID, workspaceRoot: String) {
        if model.selectedMachineID != machineID {
            model.select(machineID: machineID)
        }

        if let sessionID = model.prepareNewSession(
            machineID: machineID,
            workspaceRoot: workspaceRoot
        ) {
            storedSelectedSessionID = sessionID.uuidString
        }
        closeBrowserPresentation()
    }

    private func openReview() {
        if horizontalSizeClass == .compact {
            storedReviewVisible = true
        } else {
            showsInspector = true
        }
    }

    private func openConnectionsFromBrowser() {
        closeBrowserPresentation()
        onOpenConnections()
    }

    private func archiveSession(_ session: CodexSessionSummary, archived: Bool) {
        if model.selectedMachineID != session.machine.id {
            model.select(machineID: session.machine.id)
        }
        model.setHostThreadArchived(session.thread, archived: archived)
    }

    private func openWorkspacePicker(machineID: MachineRecord.ID, initialPath: String?) {
        if model.selectedMachineID != machineID {
            model.select(machineID: machineID)
        }
        closeBrowserPresentation()
        workspacePickerRequest = CodexWorkspacePickerRequest(
            machineID: machineID,
            initialPath: initialPath
        )
    }

    private func reconcileSelectionPresentation() {
        let presentation = selectionPresentation
        if storedSelectedSessionID != presentation.sanitizedStoredSelectedSessionID {
            storedSelectedSessionID = presentation.sanitizedStoredSelectedSessionID
        }

        if horizontalSizeClass == .compact,
           presentation.hasConversationContext,
           showsBrowser,
           browserPresentationSource != .explicit,
           model.activeSession?.threadID != nil {
            // Returning to Codex with a live thread should reopen the conversation, not leave a stale browser sheet in front.
            closeBrowserPresentation()
        }

        if horizontalSizeClass == .compact,
           (!presentation.hasConversationContext || shouldAutoPresentBrowserForWorkspaceOnlySession),
           !showsBrowser {
            requestBrowserPresentation(source: .automatic, forceRefreshIfAlreadyRequested: isActiveTab)
        }

        if horizontalSizeClass != .compact, !presentation.hasConversationContext {
            showsInspector = false
        }
    }

    private var shouldAutoPresentBrowserForWorkspaceOnlySession: Bool {
        guard isActiveTab,
              !showsBrowser,
              selectionPresentation.resolvedSelectedSessionID == nil,
              let activeSession = model.activeSession,
              activeSession.threadID == nil,
              normalizedCodexWorkspaceRoot(activeSession.workspaceRoot) != nil else {
            return false
        }

        return model.transcript.isEmpty
            && model.pendingApprovalRequest == nil
            && model.activeTurnID == nil
    }

    private func resetUITestScenePresentationIfNeeded() {
        guard shouldResetScenePresentationForUITests else {
            return
        }

        showsInspector = false
        storedReviewVisible = false
        storedSelectedSessionID = ""
        if horizontalSizeClass == .compact && isActiveTab {
            requestBrowserPresentation(source: .automatic, forceRefreshIfAlreadyRequested: false)
        } else {
            closeBrowserPresentation()
        }
    }

    private func requestBrowserPresentation(
        source: CodexBrowserPresentationSource,
        forceRefreshIfAlreadyRequested: Bool
    ) {
        browserPresentationSource = source

        guard horizontalSizeClass == .compact else {
            showsBrowser = true
            return
        }

        guard forceRefreshIfAlreadyRequested, showsBrowser else {
            showsBrowser = true
            return
        }

        // Compact sheet state can survive a tab switch even when the browser is no longer visible.
        // Force a clean re-presentation so Browse always does something observable.
        showsBrowser = false
        Task { @MainActor in
            await Task.yield()
            showsBrowser = true
        }
    }

    private func closeBrowserPresentation() {
        showsBrowser = false
        browserPresentationSource = .automatic
    }
}

private struct PendingApprovalActionStrip: View {
    let model: AppModel
    let approval: CodexApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Approval required", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                Spacer(minLength: 8)

                AppMetadataChip(title: approvalKindLabel, tint: .orange)
            }

            Text(approval.reason ?? approval.summary)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Approve") {
                    model.approvePendingRequest()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("approve-request-button")

                Button("Deny") {
                    model.denyPendingRequest()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("deny-request-button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(.orange), padding: 14, cornerRadius: 20)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-approval-action-strip")
    }

    private var approvalKindLabel: String {
        switch approval.kind {
        case .commandExecution:
            return "Command"
        case .fileChange:
            return "Files"
        case .permissions:
            return "Access"
        }
    }
}

private struct CodexBrowserSheet: View {
    let model: AppModel
    let browserPresentationDetents: Set<PresentationDetent>
    let sessionDebugStatusLabel: String
    let closeBrowser: () -> Void
    let onSelectMachine: (MachineRecord.ID) -> Void
    let onResumeSession: (CodexSessionSummary) -> Void
    let onNewSession: (CodexRepoGroup) -> Void
    let onArchiveSession: (CodexSessionSummary, Bool) -> Void
    let onChooseWorkspace: (MachineRecord.ID, String?) -> Void
    let onOpenConnections: () -> Void

    var body: some View {
        NavigationStack {
            CodexSessionBrowserView(
                model: model,
                onSelectMachine: onSelectMachine,
                onResumeSession: onResumeSession,
                onNewSession: onNewSession,
                onArchiveSession: onArchiveSession,
                onChooseWorkspace: { machineID, workspaceRoot in
                    closeAndPerform {
                        onChooseWorkspace(machineID, workspaceRoot)
                    }
                },
                onOpenConnections: {
                    closeAndPerform {
                        onOpenConnections()
                    }
                }
            )
            .navigationTitle("Projects & Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        closeBrowser()
                    }
                    .accessibilityIdentifier("browser-done-button")
                }
            }
        }
        .presentationDetents(browserPresentationDetents)
        .presentationDragIndicator(.visible)
        .overlay(alignment: .bottomTrailing) {
            codexStatusProbeLabel(sessionDebugStatusLabel)
        }
    }

    private func closeAndPerform(_ action: @escaping @MainActor () -> Void) {
        closeBrowser()
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }
}

private enum CodexSessionChromeMode {
    case compact
    case regular
}

private func normalizedCodexWorkspaceRoot(_ workspaceRoot: String?) -> String? {
    guard let trimmed = workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty,
          trimmed != "/" else {
        return nil
    }

    return trimmed
}

private func codexWorkspaceName(_ workspaceRoot: String?) -> String? {
    guard let workspaceRoot = normalizedCodexWorkspaceRoot(workspaceRoot),
          let lastComponent = workspaceRoot.split(separator: "/").last else {
        return nil
    }

    return String(lastComponent)
}

@MainActor
private func codexThreadTitle(for model: AppModel) -> String? {
    guard let session = model.activeSession else {
        return nil
    }

    if let threadDisplayTitle = session.threadDisplayTitle?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !threadDisplayTitle.isEmpty {
        return threadDisplayTitle
    }

    if let threadID = session.threadID,
       let entry = model.hostThreadCatalog.first(where: {
           $0.machineID == session.machineID && $0.id == threadID
       }) {
        if let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        let preview = entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return preview
        }
    }

    if session.threadID != nil,
       let lastTurn = session.lastTurn {
        let summary = lastTurn.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return summary
        }
    }

    return nil
}

private struct CodexSessionChrome: View {
    let model: AppModel
    let showMachineContext: Bool
    let mode: CodexSessionChromeMode

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: mode == .compact ? 8 : 10) {
                if mode == .regular {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(primaryTitle)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)

                            if let subtitleText {
                                Text(subtitleText)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppVisualStyle.secondaryText)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                            } else if let threadID = model.activeSession?.threadID {
                                Text(threadID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(AppVisualStyle.tertiaryText)
                                    .lineLimit(1)
                                    .accessibilityIdentifier("active-thread-id-label")
                            }
                        }

                        Spacer(minLength: 12)

                        if let connectionLabel {
                            AppMetadataChip(title: connectionLabel, systemImage: "dot.radiowaves.left.and.right", tint: .blue)
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if mode == .compact, let connectionLabel {
                            AppMetadataChip(title: connectionLabel, systemImage: "dot.radiowaves.left.and.right", tint: .blue)
                        }
                        metadataChips
                    }
                    .padding(.vertical, 1)
                }
            }
            .appSurface(.secondary, padding: mode == .compact ? 10 : 14, cornerRadius: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codex-session-header")
        .overlay(alignment: .bottomLeading) {
            if assistantReplyCount > 0 {
                hiddenAccessibilityText(
                    "\(assistantReplyCount) replies",
                    identifier: "assistant-reply-count-label"
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                if let threadID = model.activeSession?.threadID {
                    hiddenAccessibilityText(threadID, identifier: "active-thread-id-label")
                }
                if let approvalLabel {
                    hiddenAccessibilityText(approvalLabel, identifier: "active-approval-policy-label")
                }
                if let sandboxLabel {
                    hiddenAccessibilityText(sandboxLabel, identifier: "active-sandbox-label")
                }
                if let networkLabel {
                    hiddenAccessibilityText(networkLabel, identifier: "active-network-label")
                }
                if let authorityLabel {
                    hiddenAccessibilityText(authorityLabel, identifier: "active-authority-status-label")
                }
            }
        }
    }

    private var primaryTitle: String {
        if let threadTitle = codexThreadTitle(for: model) {
            return threadTitle
        }

        if let workspaceName = codexWorkspaceName(model.activeSession?.workspaceRoot) {
            return workspaceName
        }

        return model.activeSession?.threadID == nil ? "Choose a project" : "Active thread"
    }

    private var subtitleText: String? {
        if let repoPath {
            return repoPath
        }

        return model.activeSession?.threadID
    }

    private var repoPath: String? {
        normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot)
    }

    private var branchOrWorktreeLabel: String? {
        if let branch = model.workspaceSummary?.branch,
           !branch.isEmpty {
            return branch
        }
        if normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot) != nil {
            return "Project ready"
        }
        return nil
    }

    private var assistantReplyCount: Int {
        model.transcript.reduce(into: 0) { count, message in
            if message.countsAsAssistantReply {
                count += 1
            }
        }
    }

    private var approvalLabel: String? {
        guard model.activeSession?.threadID != nil
                || normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot) != nil else {
            return nil
        }

        if model.pendingApprovalRequest != nil {
            return "Approval required"
        }

        return model.activeApprovalPolicyLabel ?? "Approvals: unknown"
    }

    private var sandboxLabel: String? {
        model.activeSandboxLabel
    }

    private var authorityLabel: String? {
        model.activeAuthorityStatusLabel
    }

    private var networkLabel: String? {
        model.activeNetworkLabel
    }

    private var connectionLabel: String? {
        switch model.connectionState {
        case .disconnected:
            return nil
        case .connecting:
            return "Reconnecting"
        case .connected:
            return nil
        case .failed:
            return "Connection issue"
        }
    }

    private var metadataChips: some View {
        Group {
            if mode == .regular, let branchOrWorktreeLabel {
                compactMetric(branchOrWorktreeLabel, tint: .green)
            }
            if let modelName = model.activeThreadModelLabel {
                compactMetric(modelName, tint: .primary, monospaced: true)
            }
            if let runtimeStatus = model.hostRuntimeTransportStatus {
                compactMetric(runtimeStatus.label, tint: .orange)
            }
            if let approvalLabel {
                compactMetric(approvalLabel, tint: model.pendingApprovalRequest == nil ? .secondary : .orange)
            }
            if let sandboxLabel {
                compactMetric(sandboxLabel, tint: .secondary)
            }
            if let networkLabel {
                compactMetric(networkLabel, tint: .secondary)
            }
            if let authorityLabel {
                compactMetric(authorityLabel, tint: .secondary)
            }
            if showMachineContext, let machine = model.selectedMachine {
                compactMetric(machine.alias, tint: .secondary)
            }
        }
    }

    private func compactMetric(_ label: String, tint: Color = .secondary, monospaced: Bool = false) -> some View {
        AppMetadataChip(
            title: label,
            tint: tint,
            emphasized: tint != .secondary,
            monospaced: monospaced
        )
    }

    private func hiddenAccessibilityText(_ label: String, identifier: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }
}

private struct CompactCodexChatChrome: View {
    let model: AppModel
    let openReview: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            connectionChip

            if let modelName = model.activeThreadModelLabel {
                compactTextChip(modelName, monospaced: true)
            }

            if let runtimeStatus = model.hostRuntimeTransportStatus {
                compactTextChip(runtimeStatus.label, tint: .orange, emphasized: true)
            }

            Spacer(minLength: 4)

            workspaceControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codex-session-header")
        .overlay(alignment: .bottomLeading) {
            hiddenAccessibilityText(
                "\(assistantReplyCount) replies",
                identifier: "assistant-reply-count-label"
            )
        }
        .overlay(alignment: .bottomTrailing) {
            hiddenAccessibilityText(workspaceAccessibilityLabel, identifier: "workspace-review-summary")
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                if let threadID = model.activeSession?.threadID {
                    hiddenAccessibilityText(threadID, identifier: "active-thread-id-label")
                }
                if let approvalLabel {
                    hiddenAccessibilityText(approvalLabel, identifier: "active-approval-policy-label")
                }
                if let sandboxLabel = model.activeSandboxLabel {
                    hiddenAccessibilityText(sandboxLabel, identifier: "active-sandbox-label")
                }
                if let networkLabel = model.activeNetworkLabel {
                    hiddenAccessibilityText(networkLabel, identifier: "active-network-label")
                }
                if let authorityLabel = model.activeAuthorityStatusLabel {
                    hiddenAccessibilityText(authorityLabel, identifier: "active-authority-status-label")
                }
                if let runtimeStatus = model.hostRuntimeTransportStatus {
                    hiddenAccessibilityText(
                        "\(runtimeStatus.label). \(runtimeStatus.detail)",
                        identifier: "host-runtime-transport-status-label"
                    )
                }
            }
        }
    }

    private var connectionChip: some View {
        let status = connectionStatus

        return Label(status.title, systemImage: status.icon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(status.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.11), in: Capsule())
    }

    @ViewBuilder
    private var workspaceControl: some View {
        if let summary = model.workspaceSummary {
            HStack(spacing: 6) {
                let changeCount = summary.stagedCount + summary.modifiedCount + summary.untrackedCount
                if changeCount > 0 {
                    Text("\(changeCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(AppVisualStyle.panelBackgroundMuted, in: Capsule())
                        .accessibilityLabel("\(changeCount) changed files")
                }

                Button("Review") {
                    openReview()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(AppVisualStyle.panelBackgroundMuted, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-workspace-review-button")
            }
            .accessibilityLabel(workspaceSummaryLabel(summary))
        } else if model.workspaceFailureSummary != nil, hasWorkspaceContext {
            HStack(spacing: 6) {
                Label("Workspace unavailable", systemImage: "folder.badge.questionmark")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(AppVisualStyle.secondaryText)

                refreshWorkspaceButton
            }
        } else if hasWorkspaceContext {
            HStack(spacing: 6) {
                Label("Workspace pending", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(AppVisualStyle.secondaryText)

                refreshWorkspaceButton
            }
        }
    }

    private var refreshWorkspaceButton: some View {
        Button {
            model.refreshWorkspace()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(AppVisualStyle.panelBackgroundMuted, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh workspace")
        .accessibilityIdentifier("refresh-workspace-button")
    }

    private var connectionStatus: (title: String, icon: String, tint: Color) {
        switch model.connectionState {
        case .disconnected:
            return ("Offline", "wifi.slash", AppVisualStyle.secondaryText)
        case .connecting:
            return ("Syncing", "dot.radiowaves.left.and.right", .blue)
        case .connected:
            return ("Ready", "checkmark.circle", .green)
        case .failed:
            return ("Issue", "wifi.exclamationmark", .blue)
        }
    }

    private var assistantReplyCount: Int {
        model.transcript.reduce(into: 0) { count, message in
            if message.countsAsAssistantReply {
                count += 1
            }
        }
    }

    private var approvalLabel: String? {
        guard model.activeSession?.threadID != nil
                || normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot) != nil else {
            return nil
        }

        if model.pendingApprovalRequest != nil {
            return "Approval required"
        }

        return model.activeApprovalPolicyLabel ?? "Approvals: unknown"
    }

    private var hasWorkspaceContext: Bool {
        guard let workspaceRoot = model.activeSession?.workspaceRoot else {
            return false
        }

        let trimmed = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "/"
    }

    private var workspaceAccessibilityLabel: String {
        if let summary = model.workspaceSummary {
            return workspaceSummaryLabel(summary)
        }
        if let failure = model.workspaceFailureSummary, hasWorkspaceContext {
            return "Workspace unavailable. \(failure)"
        }
        return hasWorkspaceContext ? "Workspace pending" : "Workspace unavailable"
    }

    private func workspaceSummaryLabel(_ summary: GitWorkspaceSummary) -> String {
        let branch = summary.branch.isEmpty ? "Workspace" : summary.branch
        let changeCount = summary.stagedCount + summary.modifiedCount + summary.untrackedCount
        return "\(branch). \(changeCount) changed files. \(summary.aheadCount) ahead, \(summary.behindCount) behind."
    }

    private func compactTextChip(
        _ label: String,
        tint: Color = AppVisualStyle.secondaryText,
        emphasized: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        Text(label)
            .font(monospaced ? .caption2.monospaced() : .caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                emphasized ? AnyShapeStyle(tint.opacity(0.11)) : AnyShapeStyle(AppVisualStyle.panelBackgroundMuted),
                in: Capsule()
            )
    }

    private func hiddenAccessibilityText(_ label: String, identifier: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.clear)
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }
}

private func codexStatusProbeLabel(_ label: String) -> some View {
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
                .accessibilityIdentifier("codex-session-debug-status")
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
                .accessibilityIdentifier("codex-session-debug-status")
                .accessibilityLabel(label)
        }
    }
}

private struct CompactCodexNavigationTitle: View {
    let model: AppModel
    let hasConversationContext: Bool

    var body: some View {
        Group {
            if hasConversationContext {
                Text(primaryTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 220)
            } else {
                Text("Choose a project")
                    .font(.headline.weight(.semibold))
            }
        }
        .accessibilityIdentifier("codex-navigation-title")
        .accessibilityLabel(accessibilityTitle)
    }

    private var primaryTitle: String {
        if let threadTitle = codexThreadTitle(for: model) {
            return threadTitle
        }

        guard let workspaceName = codexWorkspaceName(model.activeSession?.workspaceRoot) else {
            return model.activeSession?.threadID == nil ? "Choose a project" : "Active thread"
        }

        return workspaceName
    }

    private var titleSubtitle: String {
        if codexThreadTitle(for: model) != nil,
           let workspaceName = codexWorkspaceName(model.activeSession?.workspaceRoot) {
            if let branch = model.workspaceSummary?.branch,
               !branch.isEmpty {
                return "\(workspaceName) · \(branch)"
            }
            return workspaceName
        }

        if let branch = model.workspaceSummary?.branch,
           !branch.isEmpty {
            return branch
        }

        if let workspaceRoot = normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot) {
            return workspaceRoot
        }

        return normalizedCodexWorkspaceRoot(model.activeSession?.workspaceRoot) == nil
            ? "Pick a project to start coding"
            : "Thread"
    }

    private var accessibilityTitle: String {
        hasConversationContext ? "\(primaryTitle), \(titleSubtitle)" : "Choose a project"
    }
}

private struct CodexEmptyState: View {
    let hasMachines: Bool
    let showsReviewerDemoShortcut: Bool
    let onBrowse: () -> Void
    let onOpenConnections: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(
                hasMachines ? "Choose a project first" : "Set up this Mac first",
                subtitle: hasMachines
                    ? "Browse the current Mac, then resume a thread or start a new one."
                    : "Use Connections to add or check a Mac. Daily work returns here."
            )

            Text(hasMachines
                 ? "The browser is the fastest way back into coding."
                 : "Connections handles setup, trust, route checks, and recovery before you return to Codex.")
                .font(.subheadline)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(hasMachines ? "Browse projects" : "Open Connections", action: hasMachines ? onBrowse : onOpenConnections)
                    .buttonStyle(.borderedProminent)

                if hasMachines {
                    Button("Connections", action: onOpenConnections)
                        .buttonStyle(.bordered)
                }
            }

            if showsReviewerDemoShortcut {
                Text("Reviewing without a Mac? Open reviewer demo mode in Settings.")
                    .font(.footnote)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open reviewer demo mode", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("codex-reviewer-demo-shortcut-button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.secondary, padding: 18, cornerRadius: 22)
        .accessibilityIdentifier("codex-empty-state")
    }
}

private struct CodexInspectorPane: View {
    let model: AppModel
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CodexRunOptionsCard(model: model)
                WorkspaceReviewCard(model: model, displayStyle: .inspector)
                SupportStatusCard(model: model, presentation: .inspector)
                inspectorFooter
            }
            .padding(16)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(shellBackground)
    }
    
    private var inspectorFooter: some View {
        Text("Advanced transport repair, diagnostics, and setup remain in Connections and Settings.")
            .font(.caption)
            .foregroundStyle(AppVisualStyle.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexRunOptionsCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader("Session defaults", subtitle: "Move deeper run controls out of the main composer while keeping them one step away.")

            menuRow(title: "Model", value: model.selectedModel ?? "Auto") {
                if model.availableModels.isEmpty {
                    Text("No models loaded")
                } else {
                    ForEach(model.availableModels) { descriptor in
                        Button(descriptor.displayName) {
                            model.selectModel(descriptor)
                        }
                    }
                }
            }

            menuRow(title: "Reasoning", value: model.selectedReasoningEffort.rawValue.capitalized) {
                ForEach(CodexReasoningEffort.allCases, id: \.self) { effort in
                    Button(effort.rawValue.capitalized) {
                        model.selectReasoningEffort(effort)
                    }
                }
            }

            menuRow(title: "Run mode", value: model.runModeLabel) {
                Button("Fast") { model.selectFastMode() }
                Button("Standard") { model.selectStandardMode() }
                Button("Plan") { model.selectPlanMode() }
                Button("Default") { model.selectDefaultCollaborationMode() }
            }

            menuRow(title: "Parallel agents", value: model.parallelAgentModeLabel) {
                Button("Off") { model.selectParallelAgentMode(.off) }
                Button("Client-orchestrated") { model.selectParallelAgentMode(.clientOrchestrated) }
                Button("Protocol-native") { model.selectParallelAgentMode(.protocolNative) }
                    .disabled(!model.canSelectProtocolNativeParallelAgents)
            }

            Text(model.parallelAgentCapabilityLabel)
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
        }
        .appSurface(.secondary, padding: 14, cornerRadius: 20)
    }

    private func menuRow<MenuContent: View>(
        title: String,
        value: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(AppVisualStyle.tertiaryText)
            }
            .font(.subheadline)
        }
        .buttonStyle(.plain)
    }
}
