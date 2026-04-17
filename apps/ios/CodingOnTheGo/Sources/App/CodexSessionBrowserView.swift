import AppState
import Foundation
import SharedModels
import SwiftUI

private enum CodexBrowserThreadFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case forks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .active:
            return "Active"
        case .forks:
            return "Forks"
        }
    }
}

struct CodexSessionBrowserView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("cotg.experimental.showAllReposAcrossMacs") private var showAllReposAcrossMacs = false
    @State private var isRefreshingRepos = false
    @State private var expandedRepoIDs: Set<String> = []
    @State private var expandedSessionPreviewRepoIDs: Set<String> = []
    @State private var searchText = ""
    @State private var threadFilter: CodexBrowserThreadFilter = .all
    @State private var showsArchivedThreads = false

    let model: AppModel
    var inSidebar = false
    let onSelectMachine: (MachineRecord.ID) -> Void
    let onResumeSession: (CodexSessionSummary) -> Void
    let onNewSession: (CodexRepoGroup) -> Void
    let onArchiveSession: (CodexSessionSummary, Bool) -> Void
    let onChooseWorkspace: (MachineRecord.ID, String?) -> Void
    let onOpenConnections: () -> Void

    var body: some View {
        let browserList = List {
            if showsSidebarMachineSection, !machineOptions.isEmpty {
                Section(showAllReposAcrossMacs ? "Macs" : "Current Mac") {
                    ForEach(machineOptions) { option in
                        Button {
                            onSelectMachine(option.machine.id)
                        } label: {
                            CodexMachineRow(
                                machine: option.machine,
                                isSelected: option.machine.id == model.selectedMachineID
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(cardBrowserRowInsets)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("machine-card-\(option.machine.alias)")
                    }
                }
            }

            Section {
                browserControls
                    .listRowInsets(bareBrowserRowInsets)
                    .listRowBackground(Color.clear)
            }

            if !filteredRecentSessions.isEmpty,
               searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Recent") {
                    ForEach(filteredRecentSessions.prefix(4)) { summary in
                        CodexBrowserSessionRow(
                            summary: summary,
                            showsMachineContext: showsMachineContext,
                            action: { onResumeSession(summary) },
                            onArchiveToggle: nil
                        )
                        .listRowInsets(bareBrowserRowInsets)
                        .listRowBackground(Color.clear)
                    }
                }
            }

            Section("Projects") {
                if filteredRepoGroups.isEmpty {
                    browserEmptyState
                } else {
                    ForEach(filteredRepoGroups) { group in
                        CodexProjectBrowserCard(
                            group: group,
                            showsMachineContext: showsMachineContext,
                            canChooseWorkspace: model.canBrowseWorkspaceDirectories,
                            isExpanded: isExpanded(group),
                            showsAllSessions: expandedSessionPreviewRepoIDs.contains(group.id),
                            onToggleExpanded: { toggleExpandedProject(group) },
                            onToggleSessionPreview: { toggleSessionPreview(group) },
                            onNewThread: { onNewSession(group) },
                            onChooseWorkspace: { onChooseWorkspace(group.machine.id, group.repoPath) },
                            onResumeSession: onResumeSession,
                            onArchiveSession: onArchiveSession
                        )
                        .listRowInsets(cardBrowserRowInsets)
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if showsArchivedThreads, !filteredArchivedSessions.isEmpty {
                Section("Archived") {
                    ForEach(filteredArchivedSessions) { summary in
                        CodexBrowserSessionRow(
                            summary: summary,
                            showsMachineContext: showsMachineContext,
                            action: { onResumeSession(summary) },
                            onArchiveToggle: { archived in
                                onArchiveSession(summary, archived)
                            }
                        )
                        .listRowInsets(bareBrowserRowInsets)
                        .listRowBackground(Color.clear)
                    }
                }
            }

        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(.compact)
        .searchable(text: $searchText, prompt: "Search projects or threads")
        .task(id: refreshTaskKey) {
            await refreshRepoBrowserIfNeeded()
        }
        .task(id: defaultExpandedRepoKey) {
            ensureDefaultExpandedProjectIfNeeded()
        }
        .overlay(alignment: .bottomTrailing) {
            browserStatusProbe
        }

        ZStack {
            if inSidebar {
                browserList
                    .listStyle(.sidebar)
                    .background(Color.clear)
            } else {
                browserList
                    .listStyle(.insetGrouped)
                    .background(shellBackground)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codex-browser-list")
    }

    @ViewBuilder
    private var browserEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRefreshingRepos || model.isRefreshingHostThreadCatalog {
                ProgressView("Loading projects")
                    .font(.headline)
            } else if let errorSummary = model.hostThreadCatalogErrorSummary,
                      !errorSummary.isEmpty {
                AppSectionHeader("Couldn’t load projects", subtitle: errorSummary)
            } else {
                AppSectionHeader(emptyStateTitle, subtitle: emptyStateMessage)
            }

            HStack(spacing: 10) {
                Button(model.machines.isEmpty ? "Open Connections" : "Fix in Connections") {
                    onOpenConnections()
                }
                .buttonStyle(.borderedProminent)

                if let workspaceBrowseMachine, model.canBrowseWorkspaceDirectories {
                    Button("Choose folder") {
                        onChooseWorkspace(
                            workspaceBrowseMachine.id,
                            model.activeSession?.machineID == workspaceBrowseMachine.id ? model.activeSession?.workspaceRoot : nil
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)

            if !model.canBrowseWorkspaceDirectories && !model.machines.isEmpty {
                Text("Choose folder becomes available after this Mac is connected and ready for live workspace browsing.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appSurface(.secondary, padding: 14, cornerRadius: 18)
        .padding(.vertical, 4)
        .accessibilityIdentifier("codex-browser-empty-state")
    }

    private var emptyStateTitle: String {
        if recentSessions.isEmpty {
            return searchText.isEmpty ? "No projects on this Mac yet" : "No matches"
        }

        return searchText.isEmpty ? "No host threads yet" : "No matches"
    }

    private var emptyStateMessage: String {
        if model.machines.isEmpty {
            return "Use Connections to discover and trust a Mac first. Projects appear here after real host thread data exists."
        }

        if let errorSummary = model.hostThreadCatalogErrorSummary,
           !errorSummary.isEmpty {
            return errorSummary
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a project name, path, or thread preview."
        }

        if recentSessions.isEmpty {
            if case .connected = model.connectionState {
                return "No host-backed Project and Thread history is available for the current Mac yet."
            }
            return "Connect this Mac in Connections to load live Projects and enable folder browsing."
        }

        return "Reconnect or check Connections if this Mac should already expose thread history."
    }

    private var refreshTaskKey: String {
        let machineID = model.selectedMachineID?.uuidString ?? "none"
        let connectionKey: String
        switch model.connectionState {
        case .connected:
            connectionKey = "connected"
        case .connecting:
            connectionKey = "connecting"
        case .disconnected:
            connectionKey = "disconnected"
        case .failed:
            connectionKey = "failed"
        }
        let needsRefresh = model.selectedMachineNeedsHostThreadCatalogRefresh ? "stale" : "fresh"
        return "\(machineID)-\(connectionKey)-\(needsRefresh)"
    }

    private var defaultExpandedRepoKey: String {
        "\(inSidebar)-\(threadFilter.rawValue)-\(showAllReposAcrossMacs)-" + filteredRepoGroups.map(\.id).joined(separator: "|")
    }

    private var showsMachineContext: Bool {
        CodexPresentation.showsMachineContext(for: model, includeAllMachines: showAllReposAcrossMacs)
    }

    private var showsSidebarMachineSection: Bool {
        !inSidebar && showsMachineContext
    }

    private var machineOptions: [CodexMachineOption] {
        CodexPresentation.machineOptions(for: model, includeAllMachines: showAllReposAcrossMacs)
    }

    private var recentSessions: [CodexSessionSummary] {
        CodexPresentation.recentSessionSummaries(for: model, includeAllMachines: showAllReposAcrossMacs)
    }

    private var repoGroups: [CodexRepoGroup] {
        CodexPresentation.repoGroups(for: model, includeAllMachines: showAllReposAcrossMacs)
    }

    private var workspaceBrowseMachine: MachineRecord? {
        if let selectedMachineID = model.selectedMachineID {
            return model.machines.first(where: { $0.id == selectedMachineID })
        }
        return machineOptions.first?.machine
    }

    private var bareBrowserRowInsets: EdgeInsets {
        let horizontalInset: CGFloat = horizontalSizeClass == .compact ? 14 : 0
        return EdgeInsets(top: 4, leading: horizontalInset, bottom: 4, trailing: horizontalInset)
    }

    private var cardBrowserRowInsets: EdgeInsets {
        let horizontalInset: CGFloat = horizontalSizeClass == .compact ? 10 : 0
        return EdgeInsets(top: 4, leading: horizontalInset, bottom: 4, trailing: horizontalInset)
    }

    @ViewBuilder
    private var browserControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CodexBrowserThreadFilter.allCases) { filter in
                        CodexBrowserFilterChip(
                            title: filter.title,
                            isSelected: threadFilter == filter
                        ) {
                            threadFilter = filter
                        }
                    }

                    if hasArchivedThreads || showsArchivedThreads {
                        CodexBrowserFilterChip(
                            title: "Archived",
                            isSelected: showsArchivedThreads,
                            tint: .orange
                        ) {
                            showsArchivedThreads.toggle()
                        }
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .compact ? 6 : 2)
                .padding(.vertical, 1)
            }

            HStack(spacing: 8) {
                if showsCrossMacToggle {
                    CodexBrowserFilterChip(
                        title: "This Mac",
                        isSelected: !showAllReposAcrossMacs
                    ) {
                        showAllReposAcrossMacs = false
                    }

                    CodexBrowserFilterChip(
                        title: "All Macs",
                        isSelected: showAllReposAcrossMacs
                    ) {
                        showAllReposAcrossMacs = true
                    }
                }

                Spacer(minLength: 8)

                if let workspaceBrowseMachine {
                    Button {
                        onChooseWorkspace(
                            workspaceBrowseMachine.id,
                            model.activeSession?.machineID == workspaceBrowseMachine.id ? model.activeSession?.workspaceRoot : nil
                        )
                    } label: {
                        Label("Choose folder", systemImage: "folder.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canBrowseWorkspaceDirectories)
                    .accessibilityIdentifier("browser-other-folder")
                }
            }

            if let browserSourceLabel {
                HStack(spacing: 8) {
                    AppMetadataChip(title: browserSourceLabel, tint: browserSourceTint)
                    if let browserObservedAtText {
                        Text(browserObservedAtText)
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var hasArchivedThreads: Bool {
        recentSessions.contains(where: \.isArchived)
    }

    private var showsCrossMacToggle: Bool {
        machineOptions.count > 1 || showAllReposAcrossMacs
    }

    private var filteredRecentSessions: [CodexSessionSummary] {
        let query = normalizedSearchText
        return recentSessions.filter { summary in
            guard !summary.isArchived,
                  matchesThreadFilter(summary) else {
                return false
            }

            guard !query.isEmpty else {
                return true
            }

            return matches(query: query, in: summary.threadTitle)
                || matches(query: query, in: summary.threadPreview)
                || matches(query: query, in: summary.projectName)
                || matches(query: query, in: summary.projectPath)
        }
    }

    private var filteredArchivedSessions: [CodexSessionSummary] {
        let query = normalizedSearchText
        return recentSessions.filter { summary in
            guard summary.isArchived,
                  matchesThreadFilter(summary) else {
                return false
            }

            guard !query.isEmpty else {
                return true
            }

            return matches(query: query, in: summary.threadTitle)
                || matches(query: query, in: summary.threadPreview)
                || matches(query: query, in: summary.projectName)
                || matches(query: query, in: summary.projectPath)
        }
    }

    private var filteredRepoGroups: [CodexRepoGroup] {
        let query = normalizedSearchText
        return repoGroups.compactMap { group in
            let filterMatchesGroup = query.isEmpty
                || matches(query: query, in: group.projectName)
                || matches(query: query, in: group.repoPath)
            let filteredSessions = group.sessions.filter { summary in
                guard matchesThreadFilter(summary) else {
                    return false
                }
                guard !query.isEmpty else {
                    return true
                }
                return matches(query: query, in: summary.threadTitle)
                    || matches(query: query, in: summary.threadPreview)
                    || matches(query: query, in: summary.projectPath)
                    || matches(query: query, in: group.projectName)
            }

            if filterMatchesGroup && threadFilter == .all {
                return CodexRepoGroup(
                    machine: group.machine,
                    repoName: group.repoName,
                    repoPath: group.repoPath,
                    sessions: query.isEmpty ? group.sessions : filteredSessions,
                    totalThreadCount: group.totalThreadCount,
                    archivedThreadCount: group.archivedThreadCount,
                    forkThreadCount: group.forkThreadCount,
                    activeThreadCount: group.activeThreadCount
                )
            }

            guard !filteredSessions.isEmpty else {
                return nil
            }

            return CodexRepoGroup(
                machine: group.machine,
                repoName: group.repoName,
                repoPath: group.repoPath,
                sessions: filteredSessions,
                totalThreadCount: group.totalThreadCount,
                archivedThreadCount: group.archivedThreadCount,
                forkThreadCount: group.forkThreadCount,
                activeThreadCount: group.activeThreadCount
            )
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(query: String, in value: String) -> Bool {
        value.lowercased().contains(query)
    }

    private func matchesThreadFilter(_ summary: CodexSessionSummary) -> Bool {
        switch threadFilter {
        case .all:
            return true
        case .active:
            return summary.isActive
        case .forks:
            return summary.isFork
        }
    }

    private func isExpanded(_ group: CodexRepoGroup) -> Bool {
        !normalizedSearchText.isEmpty
            || threadFilter != .all
            || expandedRepoIDs.contains(group.id)
    }

    private var browserStatusAccessibilityLabel: String {
        let connectionState: String = switch model.connectionState {
        case .connected:
            "connected"
        case .connecting:
            "connecting"
        case .disconnected:
            "disconnected"
        case .failed:
            "failed"
        }

        let errorSummary = model.hostThreadCatalogErrorSummary?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"

        let selectedMachine = model.selectedMachine
        let selectedMachineID = selectedMachine?.id.uuidString ?? "none"
        let selectedMachineAlias = selectedMachine?.alias ?? "none"
        let protocolKind = model.activeProtocolKind.rawValue
        let totalThreads = model.hostThreadCatalog.count
        let offscreenThreads = max(0, totalThreads - selectedMachineThreads.count)
        let machinesWithThreads = Set(model.hostThreadCatalog.map(\.machineID)).count
        let debugSummary = model.hostThreadCatalogDebugSummary?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"
        let provenance = model.selectedMachineHostThreadCatalogProvenance?.rawValue ?? "none"
        let observedAt = model.selectedMachineHostThreadCatalogObservedAt.map(Self.browserStatusDateFormatter.string(from:)) ?? "none"
        let workspaceHint = model.browserWorkspaceRootHint ?? "none"
        let activeWorkspace = model.activeSession?.workspaceRoot ?? "none"

        return "connection=\(connectionState);protocol=\(protocolKind);selectedMachine=\(selectedMachineAlias);selectedMachineID=\(selectedMachineID);activeWorkspace=\(activeWorkspace);workspaceHint=\(workspaceHint);visibleThreads=\(selectedMachineThreads.count);totalThreads=\(totalThreads);offscreenThreads=\(offscreenThreads);machinesWithThreads=\(machinesWithThreads);refreshing=\(model.isRefreshingHostThreadCatalog || isRefreshingRepos);provenance=\(provenance);observedAt=\(observedAt);error=\(errorSummary);debug=\(debugSummary)"
    }

    private var browserStatusProbe: some View {
        Group {
            if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
                Text(browserStatusAccessibilityLabel)
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.08))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("host-thread-browser-status")
                    .accessibilityLabel(browserStatusAccessibilityLabel)
            } else {
                Text(browserStatusAccessibilityLabel)
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("host-thread-browser-status")
                    .accessibilityLabel(browserStatusAccessibilityLabel)
            }
        }
    }

    private func refreshRepoBrowserIfNeeded() async {
        guard !isRefreshingRepos,
              !model.isRefreshingHostThreadCatalog else {
            return
        }

        switch model.connectionState {
        case .connected:
            isRefreshingRepos = true
            await model.refreshRepoBrowserSessions()
            isRefreshingRepos = false
        case .disconnected:
            guard hasStaleCachedBrowserContent,
                  let machine = model.selectedMachine else {
                return
            }

            let setupStatus = model.connectionSetupStatus(for: machine)
            guard setupStatus.sshAccessReady, setupStatus.trustReady else {
                return
            }

            model.connectLocalLoopback()
        case .connecting, .failed:
            return
        }
    }

    private var hasStaleCachedBrowserContent: Bool {
        guard model.selectedMachineHostThreadCatalogProvenance == .cachedHostCatalog,
              model.selectedMachineNeedsHostThreadCatalogRefresh,
              !selectedMachineThreads.isEmpty else {
            return false
        }

        switch model.connectionState {
        case .connected:
            return false
        case .connecting, .disconnected, .failed:
            return true
        }
    }

    private var selectedMachineThreads: [HostThreadCatalogEntry] {
        let machineIDs: Set<MachineRecord.ID>
        if showAllReposAcrossMacs {
            machineIDs = Set(model.machines.map(\.id))
        } else if let selectedMachineID = model.selectedMachineID {
            machineIDs = [selectedMachineID]
        } else {
            machineIDs = []
        }

        return model.hostThreadCatalog.filter { machineIDs.contains($0.machineID) }
    }

    private func toggleExpandedProject(_ group: CodexRepoGroup) {
        guard normalizedSearchText.isEmpty else {
            return
        }

        if expandedRepoIDs.contains(group.id) {
            expandedRepoIDs.remove(group.id)
        } else {
            expandedRepoIDs.insert(group.id)
        }
    }

    private func toggleSessionPreview(_ group: CodexRepoGroup) {
        if expandedSessionPreviewRepoIDs.contains(group.id) {
            expandedSessionPreviewRepoIDs.remove(group.id)
        } else {
            expandedSessionPreviewRepoIDs.insert(group.id)
        }
    }

    private func ensureDefaultExpandedProjectIfNeeded() {
        let validIDs = Set(filteredRepoGroups.map(\.id))
        expandedRepoIDs.formIntersection(validIDs)
        expandedSessionPreviewRepoIDs.formIntersection(validIDs)

        guard inSidebar || horizontalSizeClass == .compact || !normalizedSearchText.isEmpty else {
            return
        }

        if expandedRepoIDs.isEmpty {
            let activeProjectID = filteredRepoGroups.first(where: { group in
                group.sessions.contains(where: \.isActive)
            })?.id
            if let targetProjectID = activeProjectID ?? filteredRepoGroups.first?.id {
                expandedRepoIDs.insert(targetProjectID)
            }
        }
    }

    private var browserSourceLabel: String? {
        switch model.selectedMachineHostThreadCatalogProvenance {
        case .liveAppServer:
            return "Live app-server"
        case .sqliteRepaired:
            return "Live with sqlite repair"
        case .cachedHostCatalog:
            return "Cached host catalog"
        case nil:
            return nil
        }
    }

    private var browserSourceTint: Color {
        switch model.selectedMachineHostThreadCatalogProvenance {
        case .liveAppServer:
            return .green
        case .sqliteRepaired:
            return .orange
        case .cachedHostCatalog:
            return .secondary
        case nil:
            return .secondary
        }
    }

    private var browserObservedAtText: String? {
        guard let observedAt = model.selectedMachineHostThreadCatalogObservedAt else {
            return nil
        }
        return "Updated \(Self.relativeFormatter.localizedString(for: observedAt, relativeTo: .now))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let browserStatusDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct CodexMachineRow: View {
    let machine: MachineRecord
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(machine.alias)
                    .font(.subheadline.weight(.semibold))
                Text(machine.hostname)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            }

            Spacer()

            if let route = machine.preferredRoute {
                AppMetadataChip(title: route.kind.shortTitle, tint: isSelected ? .accentColor : .secondary)
            }
        }
        .appSurface(isSelected ? .accent(.accentColor) : .secondary, padding: 8, cornerRadius: 16)
        .contentShape(Rectangle())
    }
}

private struct CodexProjectBrowserCard: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let group: CodexRepoGroup
    let showsMachineContext: Bool
    let canChooseWorkspace: Bool
    let isExpanded: Bool
    let showsAllSessions: Bool
    let onToggleExpanded: () -> Void
    let onToggleSessionPreview: () -> Void
    let onNewThread: () -> Void
    let onChooseWorkspace: () -> Void
    let onResumeSession: (CodexSessionSummary) -> Void
    let onArchiveSession: (CodexSessionSummary, Bool) -> Void

    private var sessionPreviewLimit: Int {
        horizontalSizeClass == .compact ? 2 : 3
    }

    private var activeSession: CodexSessionSummary? {
        group.sessions.first(where: \.isActive)
    }

    private var displayedSessions: [CodexSessionSummary] {
        guard !showsAllSessions, group.sessions.count > sessionPreviewLimit else {
            return group.sessions
        }
        return Array(group.sessions.prefix(sessionPreviewLimit))
    }

    private var hiddenSessionCount: Int {
        max(group.sessions.count - sessionPreviewLimit, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggleExpanded) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.projectName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(group.repoPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppVisualStyle.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(projectSummaryLine)
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                            .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        if showsMachineContext {
                            AppMetadataChip(title: group.machine.alias, tint: .secondary)
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityLabel("\(group.projectName), \(group.repoPath), \(group.sessions.count) \(group.sessions.count == 1 ? "thread" : "threads")")
            .accessibilityIdentifier("project-disclosure-\(group.repoName)")

            if isExpanded {
                AppHairlineDivider()

                VStack(alignment: .leading, spacing: 10) {
                    actionButtons

                    if let activeSession {
                        Button {
                            onResumeSession(activeSession)
                        } label: {
                            Label("Jump to active", systemImage: "scope")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("project-active-thread-\(group.repoName)")
                    }

                    if group.sessions.isEmpty {
                        Text(group.archivedThreadCount > 0
                             ? "All saved threads in this project are archived."
                             : "No saved threads in this project yet.")
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    } else {
                        if hiddenSessionCount > 0 {
                            Button(action: onToggleSessionPreview) {
                                Label(
                                    showsAllSessions ? "Show fewer threads" : "Show \(hiddenSessionCount) more threads",
                                    systemImage: showsAllSessions ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("project-session-preview-toggle-\(group.repoName)")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(displayedSessions) { summary in
                                CodexBrowserSessionRow(
                                    summary: summary,
                                    showsMachineContext: showsMachineContext,
                                    action: { onResumeSession(summary) },
                                    onArchiveToggle: { archived in
                                        onArchiveSession(summary, archived)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .appSurface(.secondary, padding: horizontalSizeClass == .compact ? 12 : 8, cornerRadius: horizontalSizeClass == .compact ? 16 : 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-group-\(group.repoName)")
    }

    private var projectSummaryLine: String {
        var parts = [
            "\(group.totalThreadCount) \(group.totalThreadCount == 1 ? "thread" : "threads")"
        ]
        if group.activeThreadCount > 0 {
            parts.append("\(group.activeThreadCount) active")
        }
        if group.forkThreadCount > 0 {
            parts.append("\(group.forkThreadCount) forks")
        }
        if group.archivedThreadCount > 0 {
            parts.append("\(group.archivedThreadCount) archived")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 8) {
                newThreadButton
                chooseFolderButton
            }
        } else {
            HStack(spacing: 8) {
                newThreadButton
                chooseFolderButton
            }
        }
    }

    private var newThreadButton: some View {
        Button(action: onNewThread) {
            Label("New thread", systemImage: "plus.circle.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .compact ? .center : .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityIdentifier("new-thread-\(group.repoName)")
    }

    private var chooseFolderButton: some View {
        Button(action: onChooseWorkspace) {
            Label("Choose folder", systemImage: "folder.badge.plus")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .compact ? .center : .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canChooseWorkspace)
        .accessibilityIdentifier("choose-folder-\(group.repoName)")
    }
}

private struct CodexBrowserSessionRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let summary: CodexSessionSummary
    let showsMachineContext: Bool
    let action: () -> Void
    let onArchiveToggle: ((Bool) -> Void)?

    private var normalizedThreadTitle: String {
        summary.threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedThreadPreview: String {
        summary.threadPreview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var metadataLine: String {
        var parts = [summary.workspaceModeLabel, summary.routeLabel]
        if !summary.modelLabel.isEmpty {
            parts.append(summary.modelLabel)
        }
        if summary.isActive {
            parts.append("Active")
        } else if summary.isFork {
            parts.append("Fork")
        } else if summary.isArchived {
            parts.append("Archived")
        }
        if showsMachineContext {
            parts.append(summary.machine.alias)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if horizontalSizeClass == .compact {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.threadTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(summary.threadUpdatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(AppVisualStyle.secondaryText)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(summary.threadTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: 8)

                                Text(summary.threadUpdatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(AppVisualStyle.secondaryText)
                            }
                        }

                        if !normalizedThreadPreview.isEmpty, normalizedThreadPreview != normalizedThreadTitle {
                            Text(normalizedThreadPreview)
                                .font(.caption)
                                .foregroundStyle(AppVisualStyle.secondaryText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        Text(metadataLine)
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(summary.threadTitle), \(summary.projectPath), \(summary.threadStatusLabel), \(summary.routeLabel)")
            .accessibilityIdentifier("resume-thread-\(summary.thread.id)")

            if let onArchiveToggle {
                Menu {
                    Button("Open thread", action: action)
                    Button(summary.isArchived ? "Restore thread" : "Archive thread") {
                        onArchiveToggle(!summary.isArchived)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .frame(width: 28, height: 28)
                }
                .accessibilityIdentifier("thread-actions-\(summary.thread.id)")
            }
        }
    }
}

private struct CodexBrowserFilterChip: View {
    let title: String
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    isSelected ? tint.opacity(0.16) : AppVisualStyle.panelBackgroundMuted,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? tint.opacity(0.35) : AppVisualStyle.secondaryBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
