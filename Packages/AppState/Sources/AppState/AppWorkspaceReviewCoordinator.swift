import CodexRPC
import SharedModels

struct AppWorkspaceReviewResult: Sendable {
    let turnID: String
    let reviewThreadID: String
}

enum AppWorkspaceReviewCoordinator {
    @MainActor
    static func startInlineReview(
        protocolKind: CodexProtocolKind,
        safeLaneStart: () async throws -> CodexReviewContext,
        liveStart: () async throws -> CodexReviewContext
    ) async throws -> AppWorkspaceReviewResult {
        let review = switch protocolKind {
        case .stdio:
            try await safeLaneStart()
        case .websocket, .directEndpoint:
            try await liveStart()
        }

        return AppWorkspaceReviewResult(
            turnID: review.turn.id,
            reviewThreadID: review.reviewThreadID
        )
    }
}
