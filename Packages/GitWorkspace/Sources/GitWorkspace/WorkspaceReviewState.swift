public struct WorkspaceReviewState: Hashable, Sendable {
    public var summary: GitWorkspaceSummary?
    public var preview: RevertPreview?
    public var failureSummary: String?

    public init(
        summary: GitWorkspaceSummary? = nil,
        preview: RevertPreview? = nil,
        failureSummary: String? = nil
    ) {
        self.summary = summary
        self.preview = preview
        self.failureSummary = failureSummary
    }
}

public enum WorkspaceReviewFeature {
    public static func warningText(for state: WorkspaceReviewState) -> String {
        if let failureSummary = state.failureSummary {
            return failureSummary
        }
        guard let summary = state.summary else {
            return "No workspace metadata yet."
        }
        if summary.untrackedCount > 0 {
            return "Untracked files will not be reverted automatically."
        }
        if summary.stagedCount > 0 {
            return "Revert actions should be reviewed because staged changes exist."
        }
        return "Workspace is safe to review from mobile."
    }
}
