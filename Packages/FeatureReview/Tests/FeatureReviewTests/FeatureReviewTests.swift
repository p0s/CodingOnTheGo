import GitWorkspace
import XCTest
@testable import FeatureReview

final class FeatureReviewTests: XCTestCase {
    func testWarningMentionsUntrackedFiles() {
        let state = FeatureReview.WorkspaceReviewState(
            summary: GitWorkspaceSummary(
                branch: "main",
                changes: [
                    WorkspaceFileChange(path: "tmp.txt", staged: .untracked, unstaged: .untracked)
                ]
            )
        )

        XCTAssertEqual(
            FeatureReview.WorkspaceReviewFeature.warningText(for: state),
            "Untracked files will not be reverted automatically."
        )
    }

    func testWarningUsesKnownWorkspaceFailureSummary() {
        let state = FeatureReview.WorkspaceReviewState(
            summary: nil,
            preview: nil,
            failureSummary: "This folder is not a git repository, so workspace review is unavailable."
        )

        XCTAssertEqual(
            FeatureReview.WorkspaceReviewFeature.warningText(for: state),
            "This folder is not a git repository, so workspace review is unavailable."
        )
    }
}
