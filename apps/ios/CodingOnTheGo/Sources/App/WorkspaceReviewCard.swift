import AppState
import GitWorkspace
import SharedModels
import SwiftUI

enum WorkspaceReviewDisplayStyle {
    case summary
    case inspector
    case full
}

struct WorkspaceReviewCard: View {
    @State private var branchDraft = ""
    @State private var commitDraft = ""
    @State private var worktreeNameDraft = ""
    @State private var worktreeBranchDraft = ""
    @State private var showsGitControls = false

    let model: AppModel
    var displayStyle: WorkspaceReviewDisplayStyle = .full
    var openFullReview: (() -> Void)? = nil

    var body: some View {
        Group {
            if displayStyle == .summary {
                compactSummaryRow
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workspace-review-summary")
            } else if displayStyle == .inspector {
                inspectorCard
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workspace-review-full")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if showsCompactUnavailableSummary {
                        compactUnavailableSummary
                    } else {
                        header
                        summaryContent
                        advancedGitControls
                    }
                }
                .padding(contentPadding)
                .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace-review-full")
            }
        }
    }

    private var inspectorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(
                "Workspace",
                subtitle: workspaceStatusSubtitle
            ) {
                if hasWorkspaceContext {
                    Button {
                        model.refreshWorkspace()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("Refresh workspace")
                    .accessibilityIdentifier("refresh-workspace-button")
                }
            }

            if let summary = model.workspaceSummary {
                HStack(spacing: 6) {
                    summaryMetricCount(summary.stagedCount, tint: .orange, label: "staged")
                    summaryMetricCount(summary.modifiedCount, tint: .blue, label: "modified")
                    summaryMetricCount(summary.untrackedCount, tint: .green, label: "untracked")
                    if summary.aheadCount > 0 || summary.behindCount > 0 {
                        AppMetadataChip(title: "↑\(summary.aheadCount) ↓\(summary.behindCount)", tint: .secondary)
                    }
                }

                Text(summary.changes.isEmpty ? "No changed files" : "\(summary.changes.count) changed files")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            } else {
                Text(workspaceStatusDetail)
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            worktreeFlowSection
        }
        .appSurface(.secondary, padding: 16, cornerRadius: 20)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayStyle == .summary ? "Workspace summary" : "Workspace review")
                    .font(.title3.weight(.semibold))
                Text(workspaceStatusSubtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppVisualStyle.secondaryText)
            }

            Spacer()

            if showRefreshControl {
                Button("Refresh") {
                    model.refreshWorkspace()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasWorkspaceContext)
                .accessibilityIdentifier("refresh-workspace-button")
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = model.workspaceSummary {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    metricChip("\(summary.stagedCount) staged", tint: .orange)
                    metricChip("\(summary.modifiedCount) modified", tint: .blue)
                    metricChip("\(summary.untrackedCount) untracked", tint: .green)
                    if summary.aheadCount > 0 || summary.behindCount > 0 {
                        metricChip("↑\(summary.aheadCount) ↓\(summary.behindCount)", tint: .purple)
                    }
                }

                ForEach(summary.changes.prefix(displayStyle == .summary ? 3 : 5)) { change in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.path)
                                .font(.subheadline.weight(.semibold))
                            Text("\(change.staged.rawValue) / \(change.unstaged.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                if displayStyle == .summary, let openFullReview {
                    Button("Open full review") {
                        openFullReview()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("open-workspace-review-button")
                }
            }
        } else {
            Text(workspaceStatusDetail)
                .foregroundStyle(AppVisualStyle.secondaryText)
        }
    }

    private var compactSummaryRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if let summary = model.workspaceSummary {
                if let branch = normalizedBranch {
                    AppMetadataChip(title: branch, tint: .secondary, monospaced: true)
                } else {
                    Text("Workspace")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }

                Spacer(minLength: 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        summaryMetricCount(summary.stagedCount, tint: .orange, label: "staged")
                        summaryMetricCount(summary.modifiedCount, tint: .blue, label: "modified")
                        summaryMetricCount(summary.untrackedCount, tint: .green, label: "untracked")
                        if summary.aheadCount > 0 || summary.behindCount > 0 {
                            AppMetadataChip(title: "↑\(summary.aheadCount) ↓\(summary.behindCount)", tint: .secondary)
                        }
                    }
                }
            } else if let failureSummary = model.workspaceFailureSummary, hasWorkspaceContext {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Workspace unavailable", systemImage: "folder.badge.questionmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppVisualStyle.secondaryText)
                    Text(failureSummary)
                        .font(.caption2)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    model.refreshWorkspace()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(AppVisualStyle.panelBackgroundMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh workspace")
                .accessibilityIdentifier("refresh-workspace-button")
            } else if hasWorkspaceContext {
                Label("Workspace pending", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppVisualStyle.secondaryText)
                Spacer(minLength: 8)
                Button {
                    model.refreshWorkspace()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(AppVisualStyle.panelBackgroundMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh workspace")
                .accessibilityIdentifier("refresh-workspace-button")
            } else {
                compactUnavailableSummary
            }

            if let openFullReview, model.workspaceSummary != nil {
                Button("Review") {
                    openFullReview()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppVisualStyle.panelBackgroundMuted, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-workspace-review-button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.secondary, padding: 10, cornerRadius: 14)
    }

    private var compactUnavailableSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Label("Workspace unavailable", systemImage: "folder.badge.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var showsCompactUnavailableSummary: Bool {
        displayStyle == .summary && model.workspaceSummary == nil && !hasWorkspaceContext
    }

    private var showRefreshControl: Bool {
        displayStyle == .full || hasWorkspaceContext
    }

    private var hasWorkspaceContext: Bool {
        guard let workspaceRoot = model.activeSession?.workspaceRoot else {
            return false
        }

        let trimmed = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "/"
    }

    private var workspaceStatusSubtitle: String {
        if let branch = model.workspaceSummary?.branch {
            return branch
        }
        if model.workspaceFailureSummary != nil {
            return "Workspace unavailable"
        }
        return hasWorkspaceContext ? "Git status pending" : "Workspace unavailable"
    }

    private var workspaceStatusDetail: String {
        if let failureSummary = model.workspaceFailureSummary {
            return failureSummary
        }
        return hasWorkspaceContext
            ? "Connect first to fetch git status from the host workspace."
            : "Resume or start a thread in a real project workspace to review changes."
    }

    @ViewBuilder
    private var fullReviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary = model.workspaceSummary {
                changePreviewActions(summary: summary)
            }
            worktreeFlowSection
            branchActions
            commitActions

            Text(model.workspaceWarningText)
                .font(.footnote)
                .foregroundStyle(AppVisualStyle.secondaryText)

            if let preview = model.revertPreview {
                revertPreview(preview)
            }
        }
    }

    private func changePreviewActions(summary: GitWorkspaceSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change previews")
                .font(.headline)

            ForEach(summary.changes.prefix(5)) { change in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.path)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text("\(change.staged.rawValue) / \(change.unstaged.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Preview") {
                        model.previewRevert(for: change.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("preview-revert-\(sanitized(change.path))")
                }
            }
        }
    }

    private var advancedGitControls: some View {
        DisclosureGroup(isExpanded: $showsGitControls) {
            fullReviewContent
                .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced Git controls")
                    .font(.subheadline.weight(.semibold))
                Text("Branch switching, commits, and revert previews stay available here when you need them.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.accentColor)
    }

    private var branchActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Branch actions")
                .font(.headline)

            TextField("feature/session-polish", text: $branchDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("workspace-branch-field")

            HStack(spacing: 12) {
                Button("Switch") {
                    model.switchWorkspaceBranch(to: branchDraft)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasWorkspaceContext || branchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("workspace-switch-branch-button")

                Button("Create") {
                    model.createWorkspaceBranch(named: branchDraft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasWorkspaceContext || branchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("workspace-create-branch-button")
            }
        }
    }

    private var commitActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit staged changes")
                .font(.headline)

            TextField("feat: tighten reconnect flow", text: $commitDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
                .accessibilityIdentifier("workspace-commit-message-field")

            Button("Commit") {
                model.commitWorkspaceChanges(message: commitDraft)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!hasWorkspaceContext || commitDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("workspace-commit-button")
        }
    }

    private var worktreeFlowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local / Worktree")
                    .font(.headline)
                Spacer()
                Button("Refresh Worktrees") {
                    model.refreshWorktrees()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRefreshWorktreeList)
                .accessibilityIdentifier("refresh-worktrees-button")
            }

            Text(worktreeFlowDetail)
                .font(.footnote)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                metricChip(currentWorkspaceModeLabel, tint: currentWorkspaceMode == .worktree ? .orange : .green)
                if workspaceHasPendingChanges {
                    metricChip("Workspace dirty", tint: .orange)
                } else if model.workspaceSummary != nil {
                    metricChip("Workspace clean", tint: .blue)
                }
            }

            TextField("Worktree name (optional)", text: $worktreeNameDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("workspace-worktree-name-field")

            TextField("Branch name (optional)", text: $worktreeBranchDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("workspace-worktree-branch-field")

            if currentWorkspaceMode == .local {
                worktreeActionButton(
                    "Start new thread in worktree",
                    prominent: true,
                    disabled: !canRunWorktreeRouting,
                    accessibilityIdentifier: "workspace-start-worktree-thread-button"
                ) {
                    model.startNewThreadInWorktree(
                        named: trimmedWorktreeName,
                        branch: trimmedWorktreeBranch
                    )
                }

                worktreeActionButton(
                    "Handoff this thread to worktree",
                    disabled: !canMoveThreadAcrossWorkspaces,
                    accessibilityIdentifier: "workspace-move-thread-to-worktree-button"
                ) {
                    model.moveCurrentThreadToWorktree(
                        named: trimmedWorktreeName,
                        branch: trimmedWorktreeBranch
                    )
                }

                worktreeActionButton(
                    "Fork this thread to worktree",
                    disabled: !canMoveThreadAcrossWorkspaces,
                    accessibilityIdentifier: "workspace-fork-thread-to-worktree-button"
                ) {
                    model.forkCurrentThreadToWorktree(
                        named: trimmedWorktreeName,
                        branch: trimmedWorktreeBranch
                    )
                }
            } else {
                worktreeActionButton(
                    "Handoff this thread to Local",
                    prominent: true,
                    disabled: !canMoveThreadAcrossWorkspaces,
                    accessibilityIdentifier: "workspace-return-thread-to-local-button"
                ) {
                    model.returnCurrentThreadToLocalCheckout()
                }

                worktreeActionButton(
                    "Fork this thread to Local",
                    disabled: !canMoveThreadAcrossWorkspaces,
                    accessibilityIdentifier: "workspace-fork-thread-to-local-button"
                ) {
                    model.forkCurrentThreadToLocalCheckout()
                }
            }

            if model.worktrees.isEmpty {
                Text(
                    canRefreshWorktreeList
                        ? "Refresh to inspect the current Local and Worktree checkouts."
                        : "Connect to a real SSH-backed project workspace to inspect Local and Worktree checkouts."
                )
                    .font(.footnote)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            } else {
                ForEach(model.worktrees) { worktree in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(worktree.path)
                            .font(.footnote.monospaced())
                        HStack(spacing: 8) {
                            if worktree.path == model.activeSession?.workspaceRoot {
                                metricChip("Current", tint: .blue)
                            }
                            if let branch = worktree.branch {
                                metricChip(branch, tint: .green)
                            }
                            if worktree.isLocked {
                                metricChip("Locked", tint: .orange)
                            }
                            if worktree.isPrunable {
                                metricChip("Prunable", tint: .red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var currentWorkspaceMode: WorkspaceMode {
        model.activeSession?.lastMode ?? .local
    }

    private var currentWorkspaceModeLabel: String {
        currentWorkspaceMode == .worktree ? "Worktree" : "Local"
    }

    private var hasThreadContext: Bool {
        model.activeSession?.threadID != nil
    }

    private var canRunWorktreeRouting: Bool {
        hasWorkspaceContext
            && model.activeProtocolKind != .directEndpoint
            && model.connectionFailureSummary == nil
            && {
                if case .connected = model.connectionState {
                    return true
                }
                return false
            }()
    }

    private var canRefreshWorktreeList: Bool {
        hasWorkspaceContext
            && model.activeProtocolKind != .directEndpoint
            && {
                if case .connected = model.connectionState {
                    return true
                }
                return false
            }()
    }

    private var canMoveThreadAcrossWorkspaces: Bool {
        canRunWorktreeRouting && hasThreadContext && !workspaceHasPendingChanges
    }

    private var workspaceHasPendingChanges: Bool {
        guard let summary = model.workspaceSummary else {
            return false
        }
        return summary.stagedCount > 0 || summary.modifiedCount > 0 || summary.untrackedCount > 0
    }

    private var trimmedWorktreeName: String? {
        let trimmed = worktreeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var trimmedWorktreeBranch: String? {
        let trimmed = worktreeBranchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var worktreeFlowDetail: String {
        guard hasWorkspaceContext else {
            return "Resume or start a thread in a real project workspace before moving between Local and Worktree."
        }
        guard model.activeProtocolKind != .directEndpoint else {
            return "Switch back to the SSH safe lane to create worktrees or move the current thread between checkouts."
        }
        guard canRunWorktreeRouting else {
            return "Connect to the selected Mac before changing where this thread runs."
        }
        if workspaceHasPendingChanges {
            return "Handoff and fork actions stay safe only when the current workspace is clean. Start a new worktree thread if you need a fresh checkout right now."
        }
        if currentWorkspaceMode == .worktree {
            return "This thread is running in a worktree. Handoff it back to Local when you want the main checkout back, or fork it to keep both contexts available."
        }
        return "Start a fresh worktree thread, hand this clean thread off to a worktree, or fork it without losing the Local checkout."
    }

    private func revertPreview(_ preview: RevertPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview: \(preview.path)")
                    .font(.headline)
                Spacer()
                Button("Apply Revert") {
                    model.applyRevert(for: preview.path)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ScrollView {
                Text(preview.diff.isEmpty ? "No diff output for this path." : preview.diff)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricChip(_ label: String, tint: Color) -> some View {
        AppMetadataChip(title: label, tint: tint, emphasized: true)
    }

    private func worktreeActionButton(
        _ title: String,
        prominent: Bool = false,
        disabled: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(action: action) {
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var backgroundStyle: AnyShapeStyle {
        return AnyShapeStyle(AppVisualStyle.panelBackground)
    }

    private var contentPadding: CGFloat {
        24
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
    }

    private var normalizedBranch: String? {
        guard let branch = model.workspaceSummary?.branch.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else {
            return nil
        }
        return branch
    }

    private func summaryMetricCount(_ count: Int, tint: Color, label: String) -> some View {
        AppMetadataChip(title: "\(count)", tint: tint, emphasized: true)
            .accessibilityLabel("\(count) \(label)")
    }
}
