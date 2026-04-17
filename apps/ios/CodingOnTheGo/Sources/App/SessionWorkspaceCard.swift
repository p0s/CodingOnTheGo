import AppState
import CodexRPC
import SharedModels
import SwiftUI

struct SessionWorkspaceCard: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let shouldAnimateTranscriptScroll = ProcessInfo.processInfo.environment["UI_TESTING"] != "1"
    private let transcriptScrollCoordinateSpace = "codex-transcript-scroll-space"
    @State private var transcriptViewportHeight: CGFloat = 0
    @State private var transcriptBottomMaxY: CGFloat = 0
    @State private var hasPerformedInitialTranscriptScroll = false
    @State private var transcriptRenderRows: [SessionTranscriptRenderRow] = []

    let model: AppModel
    var onShowBrowser: (() -> Void)? = nil
    var onOpenConnections: (() -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: showsCompactReconnectSurface ? 6 : 10) {
                connectionRecoveryBanner

                if let approval = model.pendingApprovalRequest,
                   horizontalSizeClass != .compact {
                    PendingApprovalCard(model: model, approval: approval)
                }

                transcriptSection(proxy: proxy)

                if let subagentSummary = model.threadFeatureState.subagentStatusSummary {
                    activityLine(icon: "point.3.filled.connected.trianglepath.dotted", detail: subagentSummary)
                } else if !model.threadFeatureState.activityFlags.isEmpty {
                    activityLine(icon: "waveform.path.ecg", detail: model.threadFeatureState.activityFlags.joined(separator: ", "))
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: shouldExpandSurfaceHeight ? .infinity : nil,
                alignment: .topLeading
            )
            .appSurface(.transcript, padding: 14, cornerRadius: 22)
            .accessibilityIdentifier("codex-session-surface")
            .userActivity(CodingOnTheGoRouting.handoffActivityType, isActive: model.activeSession?.threadID != nil) { activity in
                CodingOnTheGoRouting.configure(activity, model: model)
            }
            .onChange(of: model.activeSession?.id) { _, _ in
                hasPerformedInitialTranscriptScroll = false
            }
            .onChange(of: model.activeSession?.threadID) { _, _ in
                hasPerformedInitialTranscriptScroll = false
            }
            .onAppear {
                refreshTranscriptRenderRows()
            }
            .onChange(of: model.transcript) { _, _ in
                refreshTranscriptRenderRows()
            }
            .onChange(of: transcriptAutoScrollToken) { _, _ in
                guard !model.transcript.isEmpty else {
                    return
                }

                if !hasPerformedInitialTranscriptScroll {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    hasPerformedInitialTranscriptScroll = true
                    return
                }

                guard shouldKeepTranscriptPinnedToBottom else {
                    return
                }

                scrollTranscriptToBottom(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private var connectionRecoveryBanner: some View {
        if let trustGuidance = model.selectedRouteScannedHostKeyGuidance {
            ConnectionRecoveryBar(
                title: "Trust required",
                detail: trustGuidance,
                tint: .orange,
                icon: "checkmark.shield",
                accessibilityIdentifier: "session-ssh-trust-required-notice",
                statusChipTitle: "Needs trust",
                primaryActionTitle: "Trust key",
                primaryAction: { model.trustScannedHostKey() },
                primaryActionEnabled: model.canTrustScannedHostKey,
                secondaryActionTitle: onOpenConnections == nil ? nil : "Connections",
                secondaryAction: onOpenConnections
            )
        } else if showsPendingTurnProgressBanner {
            ConnectionRecoveryBar(
                title: "Working on your prompt",
                detail: pendingTurnProgressDetail,
                tint: .blue,
                icon: "sparkles",
                accessibilityIdentifier: "codex-turn-progress-banner",
                statusChipTitle: isReconnectQueuedState ? "Queued" : "Working",
                secondaryActionTitle: onShowBrowser == nil ? nil : "Open browser",
                secondaryAction: onShowBrowser
            )
        } else if case let .failed(detail) = model.connectionState {
            ConnectionRecoveryBar(
                title: "Connection failed",
                detail: detail,
                tint: .red,
                icon: "wifi.exclamationmark",
                accessibilityIdentifier: "connection-error-detail",
                statusChipTitle: "Blocked",
                primaryActionTitle: "Retry",
                primaryAction: { model.connectLocalLoopback() },
                secondaryActionTitle: onOpenConnections == nil ? nil : "Connections",
                secondaryAction: onOpenConnections
            )
        } else if case .connecting = model.connectionState, !showsCompactReconnectSurface {
            ConnectionRecoveryBar(
                title: "Reconnecting",
                detail: reconnectStatusDetail,
                tint: .blue,
                icon: "arrow.triangle.2.circlepath",
                statusChipTitle: model.threadFeatureState.queuedPromptCount > 0 ? "Queued" : "In progress"
            )
        }
    }

    @ViewBuilder
    private func transcriptSection(proxy: ScrollViewProxy) -> some View {
        if showsCompactReconnectSurface {
            compactReconnectState
        } else if model.shouldShowTranscriptRestorePlaceholder {
            if case .connecting = model.connectionState {
                if model.transcript.isEmpty {
                    compactReconnectState
                } else {
                    transcriptScrollView(proxy: proxy)
                }
            } else {
                restoringTranscriptState
            }
        } else if model.transcript.isEmpty {
            emptyTranscriptState
        } else {
            transcriptScrollView(proxy: proxy)
        }
    }

    private func transcriptScrollView(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasHiddenTranscriptHistory {
                Button {
                    model.revealEarlierTranscriptHistory()
                } label: {
                    Label("Load earlier messages", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appSurface(.secondary, padding: 10, cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcript-load-earlier-button")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transcriptRenderRows) { renderRow in
                        SessionTranscriptRowView(
                            model: model,
                            row: renderRow.row,
                            prefersCollapsedPreview: renderRow.prefersCollapsedPreview
                        )
                    }
                    transcriptBottomAnchor
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .coordinateSpace(name: transcriptScrollCoordinateSpace)
            .scrollDismissesKeyboard(.interactively)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: TranscriptViewportHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("codex-transcript-scroll")
            .overlay(alignment: .bottomTrailing) {
                if showsJumpToLatestButton {
                    Button {
                        scrollTranscriptToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Jump to latest")
                    .accessibilityIdentifier("jump-to-latest-transcript-button")
                }
            }
        }
        .onPreferenceChange(TranscriptViewportHeightPreferenceKey.self) { transcriptViewportHeight = $0 }
        .onPreferenceChange(TranscriptBottomPositionPreferenceKey.self) { transcriptBottomMaxY = $0 }
        .task(id: transcriptInitialScrollToken) {
            await performInitialTranscriptScrollIfNeeded(proxy: proxy)
        }
    }

    private func refreshTranscriptRenderRows() {
        transcriptRenderRows = SessionTranscriptRenderRow.build(from: model.transcript)
    }

    private var transcriptBottomAnchor: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: TranscriptBottomPositionPreferenceKey.self,
                    value: proxy.frame(in: .named(transcriptScrollCoordinateSpace)).maxY
                )
        }
        .frame(height: 1)
        .id("transcript-bottom")
    }

    private var showsJumpToLatestButton: Bool {
        guard transcriptViewportHeight > 0 else {
            return false
        }

        return transcriptBottomMaxY - transcriptViewportHeight > 44
    }

    private var transcriptInitialScrollToken: String {
        "\(model.activeSession?.id.uuidString ?? "none")-\(model.activeSession?.threadID ?? "none")-\(model.transcript.count)"
    }

    private var transcriptAutoScrollToken: TranscriptAutoScrollToken {
        TranscriptAutoScrollToken(
            count: model.transcript.count,
            lastMessageID: model.transcript.last?.id,
            lastMessageText: model.transcript.last?.text ?? "",
            lastMessageStreaming: model.transcript.last?.isStreaming ?? false
        )
    }

    private var shouldKeepTranscriptPinnedToBottom: Bool {
        !showsJumpToLatestButton || model.transcript.last?.isStreaming == true
    }

    @MainActor
    private func performInitialTranscriptScrollIfNeeded(proxy: ScrollViewProxy) async {
        guard !model.transcript.isEmpty,
              !hasPerformedInitialTranscriptScroll else {
            return
        }

        await Task.yield()
        await Task.yield()
        proxy.scrollTo("transcript-bottom", anchor: .bottom)
        hasPerformedInitialTranscriptScroll = true
    }

    private func scrollTranscriptToBottom(proxy: ScrollViewProxy) {
        if shouldAnimateTranscriptScroll {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    private var emptyTranscriptState: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(
                model.activeSession?.threadID == nil ? "Thread ready" : "No transcript yet",
                subtitle: model.activeSession?.threadID == nil
                    ? "Start typing to open a new thread in this project."
                    : "Send a prompt to continue this thread."
            )

            if model.selectedMachine == nil {
                Text("No Mac is selected yet. Use Connections to find one first.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            }

            HStack(spacing: 10) {
                if let onShowBrowser {
                    Button("Open browser") {
                        onShowBrowser()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let onOpenConnections, model.selectedMachine == nil {
                    Button("Connections") {
                        onOpenConnections()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .appSurface(.secondary, padding: 16, cornerRadius: 18)
        .padding(.vertical, 8)
    }

    private var restoringTranscriptState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text("Restoring thread")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Text("Loading the saved transcript for this project and thread.")
                .font(.footnote)
                .foregroundStyle(AppVisualStyle.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appSurface(.secondary, padding: 16, cornerRadius: 18)
        .padding(.top, 4)
        .accessibilityIdentifier("codex-transcript-restoring")
    }

    private var compactReconnectState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)

                Text("Reconnecting")
                    .font(.subheadline.weight(.semibold))

                AppMetadataChip(title: "In progress", tint: .blue)
            }

            if let queuedPromptPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(queuedPromptPreviewTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppVisualStyle.secondaryText)

                    Text(queuedPromptPreview)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let preview = model.reconnectTranscriptPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest saved reply")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppVisualStyle.secondaryText)

                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(reconnectStatusDetail)
                    .font(.footnote)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            }

            HStack(spacing: 10) {
                if let onShowBrowser {
                    Button("Open browser") {
                        onShowBrowser()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let onOpenConnections {
                    Button("Connections") {
                        onOpenConnections()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(.blue), padding: 12, cornerRadius: 18)
        .padding(.top, 4)
        .accessibilityIdentifier("codex-transcript-reconnect-preview")
    }

    private func activityLine(icon: String, detail: String) -> some View {
        Label(detail, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(AppVisualStyle.secondaryText)
    }

    private var shouldExpandSurfaceHeight: Bool {
        !(showsCompactReconnectSurface || (model.shouldShowTranscriptRestorePlaceholder && model.transcript.isEmpty))
    }

    private var showsCompactReconnectSurface: Bool {
        guard case .connecting = model.connectionState else {
            return false
        }

        return model.transcript.isEmpty
    }

    private var queuedPromptPreview: String? {
        let normalized = model.pendingPrompts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private var queuedPromptPreviewTitle: String {
        let count = model.threadFeatureState.queuedPromptCount
        return count == 1 ? "Queued prompt" : "Queued \(count) prompts"
    }

    private var reconnectStatusDetail: String {
        let queuedCount = model.threadFeatureState.queuedPromptCount
        if queuedCount > 0 {
            return queuedCount == 1
                ? "Your latest prompt is queued and will send as soon as the preferred route reconnects."
                : "\(queuedCount) prompts are queued and will send as soon as the preferred route reconnects."
        }

        if model.shouldShowTranscriptRestorePlaceholder {
            return "Re-establishing the preferred route and loading the latest messages first."
        }

        return "Re-establishing the preferred route for this thread."
    }

    private var isReconnectQueuedState: Bool {
        if case .connecting = model.connectionState {
            return model.threadFeatureState.queuedPromptCount > 0
        }
        return false
    }

    private var showsPendingTurnProgressBanner: Bool {
        guard !showsCompactReconnectSurface else {
            return false
        }

        return isReconnectQueuedState
            || (model.threadFeatureState.isStreaming && !model.transcript.contains(where: \.isStreaming))
    }

    private var pendingTurnProgressDetail: String {
        let queuedCount = model.threadFeatureState.queuedPromptCount
        if queuedCount > 0 {
            return reconnectStatusDetail
        }

        return "Codex started the next turn and will stream updates here as they arrive."
    }

}

private struct TranscriptAutoScrollToken: Equatable {
    let count: Int
    let lastMessageID: UUID?
    let lastMessageText: String
    let lastMessageStreaming: Bool
}

private struct SessionTranscriptRenderRow: Identifiable {
    let row: SessionTranscriptRow
    let prefersCollapsedPreview: Bool

    var id: UUID { row.id }

    static func build(from messages: [SessionMessage]) -> [SessionTranscriptRenderRow] {
        let rows = SessionTranscriptRow.build(from: messages)
        return rows.enumerated().map { index, row in
            SessionTranscriptRenderRow(
                row: row,
                prefersCollapsedPreview: index < max(0, rows.count - 2)
            )
        }
    }
}

private struct ConnectionRecoveryBar: View {
    let title: String
    let detail: String
    let tint: Color
    let icon: String
    var accessibilityIdentifier: String? = nil
    var statusChipTitle: String? = nil
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var primaryActionEnabled = true
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let statusChipTitle {
                        AppMetadataChip(title: statusChipTitle, tint: tint)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if primaryActionTitle != nil || secondaryActionTitle != nil {
                    HStack(spacing: 10) {
                        if let primaryActionTitle, let primaryAction {
                            Button(action: primaryAction) {
                                Text(primaryActionTitle)
                            }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!primaryActionEnabled)
                                .accessibilityIdentifier(buttonAccessibilityIdentifier(for: primaryActionTitle))
                        }

                        if let secondaryActionTitle, let secondaryAction {
                            Button(action: secondaryAction) {
                                Text(secondaryActionTitle)
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier(buttonAccessibilityIdentifier(for: secondaryActionTitle))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(tint), padding: 12, cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier ?? title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    private func buttonAccessibilityIdentifier(for title: String) -> String {
        switch title {
        case "Trust key":
            return "session-trust-host-key-button"
        case "Connections":
            return "session-open-connections-button"
        default:
            return title.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }
}

private struct TranscriptViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TranscriptBottomPositionPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PendingApprovalCard: View {
    let model: AppModel
    let approval: CodexApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(approval.summary)
                .font(.subheadline.weight(.medium))
            if let reason = approval.reason,
               reason != approval.summary {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(AppVisualStyle.secondaryText)
            }
            if let requestedPermissions = approval.requestedPermissions {
                permissionLine("Read roots", values: requestedPermissions.readRoots)
                permissionLine("Write roots", values: requestedPermissions.writeRoots)
                if let networkEnabled = requestedPermissions.networkEnabled {
                    Text("Network: \(networkEnabled ? "Requested" : "Not requested")")
                        .font(.footnote)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }
            }
            HStack(spacing: 12) {
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
        .appSurface(.accent(.orange), padding: 16, cornerRadius: 18)
    }

    private func permissionLine(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(values.isEmpty ? "None" : values.joined(separator: ", "))
                .font(.footnote.monospaced())
                .foregroundStyle(AppVisualStyle.secondaryText)
        }
    }
}

private enum SessionTranscriptRow: Identifiable {
    case message(SessionMessage)
    case activityCluster(SessionActivityCluster)

    var id: UUID {
        switch self {
        case .message(let message):
            return message.id
        case .activityCluster(let cluster):
            return cluster.id
        }
    }

    static func build(from messages: [SessionMessage]) -> [SessionTranscriptRow] {
        var rows: [SessionTranscriptRow] = []
        var clusterBuffer: [SessionMessage] = []
        var clusterKind: SessionActivityClusterKind?

        func flushCluster() {
            guard !clusterBuffer.isEmpty else {
                return
            }

            if clusterBuffer.count == 1, let message = clusterBuffer.first {
                rows.append(.message(message))
            } else if let first = clusterBuffer.first, let clusterKind {
                rows.append(
                    .activityCluster(
                        SessionActivityCluster(
                            id: first.id,
                            kind: clusterKind,
                            messages: clusterBuffer
                        )
                    )
                )
            }
            clusterBuffer.removeAll(keepingCapacity: true)
            clusterKind = nil
        }

        for message in messages {
            if let nextClusterKind = message.activityClusterKind {
                if clusterKind == nil || clusterKind == nextClusterKind {
                    clusterKind = nextClusterKind
                    clusterBuffer.append(message)
                    continue
                }

                flushCluster()
                clusterKind = nextClusterKind
                clusterBuffer.append(message)
            } else {
                flushCluster()
                rows.append(.message(message))
            }
        }

        flushCluster()
        return rows
    }
}

private struct SessionTranscriptRowView: View {
    let model: AppModel
    let row: SessionTranscriptRow
    let prefersCollapsedPreview: Bool

    var body: some View {
        switch row {
        case .message(let message):
            SessionMessageRow(
                model: model,
                message: message,
                prefersCollapsedPreview: prefersCollapsedPreview
            )
        case .activityCluster(let cluster):
            SessionActivityClusterCard(cluster: cluster)
        }
    }
}

private struct SessionMessageRow: View {
    let model: AppModel
    let message: SessionMessage
    let prefersCollapsedPreview: Bool
    @State private var isExpanded = false

    var body: some View {
        if message.kind == .plan {
            SessionPlanCard(model: model, message: message)
        } else if message.kind == .userInputPrompt, let structuredPrompt = message.structuredPrompt {
            SessionStructuredPromptCard(model: model, message: message, prompt: structuredPrompt)
        } else if message.usesCompactActivityRow {
            compactActivityRow
        } else {
            bubbleRow
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .bottom) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if message.role == .assistant {
                        Text("Codex")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    }

                    if message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .tint(roleTint)
                    }

                    if message.role == .user,
                       let deliveryState = message.deliveryState {
                        Text(deliveryState.transcriptLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(deliveryState.transcriptTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(deliveryState.transcriptTint.opacity(0.12), in: Capsule())
                            .accessibilityIdentifier("session-message-delivery-state")
                    }

                    Spacer(minLength: 0)

                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppVisualStyle.tertiaryText)
                }

                if !displayedBubbleText.isEmpty {
                    Text(displayedBubbleText)
                        .font(message.role == .assistant ? .body : .subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
                        .textSelection(.enabled)
                        .lineLimit(shouldShowCompactPreview ? 3 : nil)
                        .accessibilityLabel(message.displayText)
                }

                if !message.attachments.isEmpty {
                    SessionMessageAttachmentStrip(attachments: message.attachments)
                }

                if canToggleCollapsedPreview {
                    Button(isExpanded ? "Show less" : "Show full") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: message.role == .assistant ? .infinity : 320, alignment: .leading)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppVisualStyle.secondaryBorder, lineWidth: 1)
                }
            }

            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(message.bubbleAccessibilityIdentifier)
    }

    private var compactActivityRow: some View {
        HStack(spacing: 8) {
            Image(systemName: message.activityIconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.activityTint)

            Text(message.displayText)
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .lineLimit(nil)

            Spacer(minLength: 0)

            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(AppVisualStyle.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.secondary, padding: 10, cornerRadius: 14)
        .accessibilityIdentifier(message.bubbleAccessibilityIdentifier)
    }

    private var roleTint: Color {
        switch message.role {
        case .system:
            AppVisualStyle.warningTint
        case .user:
            .accentColor
        case .assistant:
            .green
        }
    }

    private var backgroundStyle: Color {
        switch message.role {
        case .system:
            AppVisualStyle.systemBubble
        case .user:
            AppVisualStyle.userBubble
        case .assistant:
            AppVisualStyle.assistantBubble
        }
    }

    private var showsBorder: Bool {
        message.role != .assistant
    }

    private var cornerRadius: CGFloat {
        switch message.role {
        case .assistant:
            12
        case .system:
            16
        case .user:
            20
        }
    }

    private var horizontalPadding: CGFloat {
        message.role == .assistant ? 14 : 16
    }

    private var verticalPadding: CGFloat {
        12
    }

    private var canToggleCollapsedPreview: Bool {
        message.kind == .standard
            && !message.isStreaming
            && message.structuredPrompt == nil
            && (prefersCollapsedPreview || message.showsExpandablePreview)
    }

    private var shouldShowCompactPreview: Bool {
        canToggleCollapsedPreview && !isExpanded
    }

    private var displayedBubbleText: String {
        shouldShowCompactPreview ? message.condensedPreviewText : message.displayText
    }
}

private struct SessionActivityCluster: Hashable {
    let id: UUID
    let kind: SessionActivityClusterKind
    let messages: [SessionMessage]
}

private struct SessionMessageAttachmentStrip: View {
    let attachments: [SessionMessageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Label(attachment.displayName, systemImage: attachment.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppVisualStyle.panelBackgroundMuted, in: Capsule())
                }
            }
        }
        .accessibilityIdentifier("session-message-attachments")
    }
}

private enum SessionActivityClusterKind: Hashable {
    case commentary
    case execution
    case reasoning
    case other

    var title: String {
        switch self {
        case .commentary:
            return "Progress updates"
        case .execution:
            return "Tool activity"
        case .reasoning:
            return "Reasoning notes"
        case .other:
            return "System activity"
        }
    }

    var iconName: String {
        switch self {
        case .commentary:
            return "sparkles"
        case .execution:
            return "terminal"
        case .reasoning:
            return "brain.head.profile"
        case .other:
            return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .commentary, .reasoning:
            return .accentColor
        case .execution:
            return .green
        case .other:
            return AppVisualStyle.warningTint
        }
    }

    var collapsedVisibleCount: Int {
        switch self {
        case .commentary:
            return 2
        case .execution, .reasoning, .other:
            return 3
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .commentary:
            return "session-commentary-cluster"
        case .execution:
            return "session-execution-cluster"
        case .reasoning:
            return "session-reasoning-cluster"
        case .other:
            return "session-system-cluster"
        }
    }

    func hiddenSummary(_ count: Int) -> String {
        switch self {
        case .commentary:
            return "\(count) earlier progress updates hidden"
        case .execution:
            return "\(count) earlier tool updates hidden"
        case .reasoning:
            return "\(count) earlier reasoning notes hidden"
        case .other:
            return "\(count) earlier system updates hidden"
        }
    }
}

private struct SessionActivityClusterCard: View {
    let cluster: SessionActivityCluster
    @State private var isExpanded = false

    private var visibleMessages: [SessionMessage] {
        if isExpanded {
            return cluster.messages
        }

        return Array(cluster.messages.suffix(cluster.kind.collapsedVisibleCount))
    }

    private var hiddenMessageCount: Int {
        max(0, cluster.messages.count - visibleMessages.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(cluster.kind.title, systemImage: cluster.kind.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                AppMetadataChip(
                    title: "\(cluster.messages.count) updates",
                    tint: cluster.kind.tint,
                    emphasized: true
                )

                Spacer(minLength: 0)

                if let latest = cluster.messages.last?.createdAt {
                    Text(latest, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppVisualStyle.tertiaryText)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if hiddenMessageCount > 0 {
                    Text(cluster.kind.hiddenSummary(hiddenMessageCount))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppVisualStyle.tertiaryText)
                }

                ForEach(visibleMessages) { message in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: message.activityIconName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(message.activityTint)
                            .padding(.top, 2)

                        Text(message.displayText)
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(message.displayText)
                    }
                }
            }

            if hiddenMessageCount > 0 || isExpanded {
                Button(isExpanded ? "Show less" : "Show \(hiddenMessageCount) more") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("\(cluster.kind.accessibilityIdentifier)-toggle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.secondary, padding: 12, cornerRadius: 16)
        .accessibilityIdentifier(cluster.kind.accessibilityIdentifier)
    }
}

private struct SessionPlanCard: View {
    let model: AppModel
    let message: SessionMessage

    private var parsedPlan: ParsedPlanContent {
        ParsedPlanContent(text: message.displayText)
    }

    private var isPlanModeSelected: Bool {
        model.selectedCollaborationMode == .plan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Plan", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                AppMetadataChip(
                    title: isPlanModeSelected ? "Plan mode" : "Ready to implement",
                    tint: isPlanModeSelected ? .accentColor : .green,
                    emphasized: true
                )

                Spacer(minLength: 0)

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(AppVisualStyle.tertiaryText)
            }

            if let intro = parsedPlan.intro {
                Text(intro)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !parsedPlan.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(parsedPlan.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            AppMetadataChip(
                                title: "\(index + 1)",
                                tint: .accentColor,
                                emphasized: true,
                                monospaced: true
                            )

                            Text(step)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let outro = parsedPlan.outro {
                Text(outro)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isPlanModeSelected {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Implement next turn") {
                        model.selectDefaultCollaborationMode()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("session-plan-implement-button")

                    Text("The next send will use default execution mode instead of asking for another plan.")
                        .font(.caption)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(.accentColor), padding: 14, cornerRadius: 18)
        .accessibilityIdentifier("session-plan-card")
    }
}

private struct SessionStructuredPromptCard: View {
    let model: AppModel
    let message: SessionMessage
    let prompt: SessionStructuredPrompt

    @State private var selectedOptionsByQuestionID: [String: [String]] = [:]
    @State private var typedAnswersByQuestionID: [String: String] = [:]
    @State private var hasPreparedComposerAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Questions", systemImage: "list.bullet.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                AppMetadataChip(
                    title: "Plan input",
                    tint: .accentColor,
                    emphasized: true
                )

                Spacer(minLength: 0)

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(AppVisualStyle.tertiaryText)
            }

            ForEach(prompt.questions) { question in
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.prompt)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.options.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(question.options) { option in
                                structuredOptionButton(option, question: question)
                            }
                        }
                    }

                    if question.allowsCustomAnswer {
                        TextField(
                            question.customAnswerPlaceholder ?? "Type your answer",
                            text: Binding(
                                get: { typedAnswersByQuestionID[question.id] ?? "" },
                                set: { typedAnswersByQuestionID[question.id] = $0 }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AppVisualStyle.panelBackgroundMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("session-structured-question-input-\(question.id)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button(hasPreparedComposerAnswer ? "Prepared in composer" : "Use answer in composer") {
                    model.useStructuredPromptAnswers(
                        prompt,
                        selectedOptionsByQuestionID: selectedOptionsByQuestionID,
                        typedAnswersByQuestionID: typedAnswersByQuestionID
                    )
                    hasPreparedComposerAnswer = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSubmitAnswer)
                .accessibilityIdentifier("session-structured-prompt-submit")

                Text("This prepares the selected answer in the main composer and exits plan mode for the next send.")
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(.accentColor), padding: 14, cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-structured-prompt-card")
    }

    private var canSubmitAnswer: Bool {
        prompt.questions.allSatisfy { question in
            let hasSelectedOption = !(selectedOptionsByQuestionID[question.id] ?? []).isEmpty
            let typedAnswer = typedAnswersByQuestionID[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return hasSelectedOption || !typedAnswer.isEmpty
        }
    }

    private func structuredOptionButton(
        _ option: SessionStructuredOption,
        question: SessionStructuredQuestion
    ) -> some View {
        let isSelected = selectedOptionsByQuestionID[question.id]?.contains(option.label) == true

        return Button {
            selectedOptionsByQuestionID[question.id] = [option.label]
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)

                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    }
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : AppVisualStyle.panelBackgroundMuted)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(option.label)
        .accessibilityHint(option.detail ?? "Use this answer in the composer.")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("session-structured-option-\(question.id)-\(option.id)")
    }
}

private struct ParsedPlanContent {
    let intro: String?
    let steps: [String]
    let outro: String?

    init(text: String) {
        let lines = text.components(separatedBy: .newlines)
        var introLines: [String] = []
        var steps: [String] = []
        var outroLines: [String] = []
        var hasSeenStep = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if let step = Self.planStep(from: trimmed) {
                steps.append(step)
                hasSeenStep = true
            } else if hasSeenStep {
                outroLines.append(trimmed)
            } else {
                introLines.append(trimmed)
            }
        }

        if steps.isEmpty {
            intro = Self.optionalText(text)
        } else {
            intro = Self.optionalText(introLines.joined(separator: "\n"))
        }
        self.steps = steps
        outro = Self.optionalText(outroLines.joined(separator: "\n"))
    }

    private static func planStep(from line: String) -> String? {
        let patterns = [
            #"^\s*[-*]\s+(.+)$"#,
            #"^\s*\d+[.)]\s+(.+)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let stepRange = Range(match.range(at: 1), in: line) else {
                continue
            }

            let step = line[stepRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return step.isEmpty ? nil : step
        }

        return nil
    }

    private static func optionalText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension SessionMessage {
    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    var showsExpandablePreview: Bool {
        kind == .standard
            && !isStreaming
            && structuredPrompt == nil
            && displayText.count > 120
    }

    var condensedPreviewText: String {
        let normalized = displayText.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let leadParagraph = paragraphs.first ?? normalized
        if leadParagraph.count <= 96 {
            return leadParagraph
        }

        let truncated = leadParagraph.prefix(93).trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated + "..."
    }

    var usesCompactActivityRow: Bool {
        kind == .commentary || (role == .system && kind != .plan && kind != .userInputPrompt)
    }

    var groupsIntoActivityCluster: Bool {
        activityClusterKind != nil
    }

    var activityClusterKind: SessionActivityClusterKind? {
        switch kind {
        case .commentary:
            return .commentary
        case .reasoning:
            return .reasoning
        case .commandExecution, .fileChange, .toolCall:
            return .execution
        case .other:
            return .other
        case .standard, .plan, .userInputPrompt:
            return nil
        }
    }

    var activityIconName: String {
        switch kind {
        case .commentary:
            return "sparkles"
        case .reasoning:
            return "brain.head.profile"
        case .plan:
            return "checklist"
        case .userInputPrompt:
            return "list.bullet.clipboard"
        case .commandExecution:
            return "terminal"
        case .fileChange:
            return "doc.badge.gearshape"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .other, .standard:
            return "info.circle"
        }
    }

    var activityTint: Color {
        switch kind {
        case .commentary, .reasoning, .plan, .userInputPrompt:
            return .accentColor
        case .commandExecution, .fileChange, .toolCall:
            return .green
        case .other, .standard:
            return AppVisualStyle.warningTint
        }
    }

    var bubbleAccessibilityIdentifier: String {
        switch role {
        case .system:
            switch kind {
            case .commandExecution:
                return "session-bubble-command"
            case .fileChange:
                return "session-bubble-file-change"
            case .toolCall:
                return "session-bubble-tool-call"
            case .reasoning:
                return "session-bubble-reasoning"
            case .plan:
                return "session-bubble-plan"
            case .userInputPrompt:
                return "session-bubble-user-input-prompt"
            case .other, .standard, .commentary:
                return "session-bubble-system"
            }
        case .user:
            return "session-bubble-user"
        case .assistant:
            return kind == .commentary ? "session-bubble-commentary" : "session-bubble-assistant"
        }
    }
}

private extension SessionMessage.DeliveryState {
    var transcriptLabel: String {
        switch self {
        case .sending:
            return "Sending"
        case .queued:
            return "Queued on iPhone"
        case .failed:
            return "Not sent"
        }
    }

    var transcriptTint: Color {
        switch self {
        case .sending:
            return .accentColor
        case .queued:
            return AppVisualStyle.warningTint
        case .failed:
            return .red
        }
    }
}

private extension SessionMessageAttachment {
    var iconName: String {
        switch kind {
        case .photo:
            return "photo"
        case .voiceMemo:
            return "waveform"
        }
    }
}
