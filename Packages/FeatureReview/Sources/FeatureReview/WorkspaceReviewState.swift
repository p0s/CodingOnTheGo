import GitWorkspace

public typealias WorkspaceReviewState = GitWorkspace.WorkspaceReviewState

public enum WorkspaceReviewFeature {
    public static func warningText(for state: WorkspaceReviewState) -> String {
        GitWorkspace.WorkspaceReviewFeature.warningText(for: state)
    }
}
