import AppState
import SwiftUI

enum SupportStatusPresentation: Equatable {
    case full
    case compact
    case inspector
}

struct SupportStatusCard: View {
    let model: AppModel
    var presentation: SupportStatusPresentation = .full

    var body: some View {
        Group {
            switch presentation {
            case .full:
                fullCard
            case .compact:
                compactCard
            case .inspector:
                inspectorCard
            }
        }
    }

    private func statusLine(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var canRunSmokeTest: Bool {
        guard case .connected = model.connectionState else {
            return false
        }

        return model.activeTurnID == nil
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reconnect and support")
                .font(.headline)

            statusBlock(compact: false)
            if model.hasConnectionFallbackSuggestions {
                fallbackSuggestionSection(compact: false)
            }
            Text(model.networkProxyDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ProductSupportButtonRow(
                privacyAccessibilityIdentifier: "privacy-policy-link",
                supportAccessibilityIdentifier: "support-link"
            )

            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        reconnectButton
                        smokeTestButton
                        scanLocalNetworkButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        reconnectButton
                        HStack(spacing: 10) {
                            smokeTestButton
                            scanLocalNetworkButton
                        }
                    }
                }

                if showsExtendedRecoveryActions {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            if model.canAttemptLoopbackUpgrade {
                                upgradeButton
                            }
                            if model.canReturnToSafeLane {
                                fallbackButton
                            }
                            if model.notificationSnapshot.authorization != .authorized {
                                enableNotificationsButton
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            if model.canAttemptLoopbackUpgrade {
                                upgradeButton
                            }
                            if model.canReturnToSafeLane {
                                fallbackButton
                            }
                            if model.notificationSnapshot.authorization != .authorized {
                                enableNotificationsButton
                            }
                        }
                    }
                }
            }

            if let blocker = model.syncSnapshot.blocker {
                Text(blocker.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveGlassSurface(tint: Color.cyan.opacity(0.14), cornerRadius: 28)
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: compactStatusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(compactStatusTint)
                    Text("Session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let compactStatusBadgeLabel {
                    Text(compactStatusBadgeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(compactStatusTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(compactStatusTint.opacity(0.08), in: Capsule())
                }

                compactPrimaryActions
            }

            statusBlock(compact: true)
            if model.hasConnectionFallbackSuggestions {
                fallbackSuggestionSection(compact: true)
            }

            if let compactRecoveryDetail {
                Text(compactRecoveryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .adaptiveGlassSurface(tint: Color.cyan.opacity(0.12), cornerRadius: 24)
    }

    @ViewBuilder
    private var compactPrimaryActions: some View {
        HStack(spacing: 6) {
            compactActionButton(
                title: "Reconnect best route",
                systemImage: "arrow.clockwise",
                accessibilityIdentifier: "reconnect-safe-lane-button",
                isDisabled: model.selectedMachine == nil
            ) {
                model.connectLocalLoopback()
            }

            if showsCompactAdvancedActions {
                Menu {
                    if canRunSmokeTest {
                        smokeTestButton
                    }
                    if model.canAttemptLoopbackUpgrade {
                        upgradeButton
                    }
                    if model.canReturnToSafeLane {
                        fallbackButton
                    }
                    scanLocalNetworkButton
                    if model.notificationSnapshot.authorization != .authorized {
                        enableNotificationsButton
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
                .accessibilityLabel("More support actions")
                .accessibilityIdentifier("support-actions-menu-button")
            }
        }
    }

    private func compactActionButton(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? .tertiary : .primary)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var inspectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: compactStatusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(compactStatusTint)
                    Text("Connection")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if showsInspectorReconnectAction {
                    compactActionButton(
                        title: "Reconnect best route",
                        systemImage: "arrow.clockwise",
                        accessibilityIdentifier: "reconnect-safe-lane-button",
                        isDisabled: model.selectedMachine == nil
                    ) {
                        model.connectLocalLoopback()
                    }
                }
            }

            statusBlock(compact: true)
            if model.hasConnectionFallbackSuggestions {
                fallbackSuggestionSection(compact: true)
            }

            if let compactRecoveryDetail {
                Text(compactRecoveryDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Route repair, diagnostics, and scans stay in Connections.")
                .font(.caption2)
                .foregroundStyle(AppVisualStyle.secondaryText)
        }
        .padding(14)
        .adaptiveGlassSurface(tint: Color.cyan.opacity(0.1), cornerRadius: 22)
    }

    private func statusBlock(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if compact {
                compactStatusLine("Transport", value: model.protocolLabel)
                compactStatusLine("Best route", value: model.recommendedRoute?.label ?? "Pending")
                compactStatusLine("Sync", value: model.syncSnapshot.status.rawValue.capitalized)
                if model.sshTrustStatusLabel != "Trusted" {
                    compactStatusLine("SSH trust", value: model.sshTrustStatusLabel)
                }
                if model.showsExternalTailnetStatus {
                    compactStatusLine("Tailnet", value: model.externalTailnetAppStatusLabel)
                }
            } else {
                statusLine("Transport", value: model.protocolLabel)
                statusLine("Best route", value: model.recommendedRoute?.label ?? "Pending")
                statusLine("SSH trust", value: model.sshTrustStatusLabel)
                statusLine("Sync", value: model.syncSnapshot.status.rawValue.capitalized)
                statusLine("Proxy hygiene", value: model.networkProxyStatusLabel)
                statusLine("SSH credential", value: model.sshCredentialStatusLabel)
                statusLine("Notifications", value: model.notificationSnapshot.authorization.rawValue.capitalized)
                statusLine("Discovery scan", value: model.discoverySnapshot.map { format($0.scannedAt) } ?? "Pending")
                statusLine("Queued prompts", value: "\(model.threadFeatureState.queuedPromptCount)")
                if model.showsExternalTailnetStatus {
                    statusLine("External Tailscale", value: model.externalTailnetAppStatusLabel)
                }
            }
        }
    }

    private func compactStatusLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func fallbackSuggestionSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(compact ? "Suggested fallbacks" : "Suggested fallbacks from this Mac")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(model.connectionFallbackSuggestions) { suggestion in
                fallbackSuggestionRow(suggestion, compact: compact)
            }
        }
        .padding(compact ? 10 : 12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: compact ? 16 : 18, style: .continuous))
    }

    @ViewBuilder
    private func fallbackSuggestionRow(_ suggestion: ConnectionFallbackSuggestion, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(suggestion.title)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let actionTitle = suggestion.actionTitle {
                    Button(actionTitle) {
                        model.applyConnectionFallbackSuggestion(suggestion)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("\(suggestion.accessibilityIdentifier)-action")
                }
            }

            Text(suggestion.detail)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(suggestion.accessibilityIdentifier)
    }

    private var reconnectButton: some View {
        Button(presentation == .full ? "Reconnect Best Route" : "Reconnect") {
            model.connectLocalLoopback()
        }
        .buttonStyle(.bordered)
        .controlSize(presentation == .compact ? .small : .small)
        .disabled(model.selectedMachine == nil)
        .accessibilityIdentifier("reconnect-safe-lane-button")
    }

    private var smokeTestButton: some View {
        Button("Smoke Test") {
            model.sendSmokeTestPrompt()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canRunSmokeTest)
        .accessibilityIdentifier("smoke-test-button")
    }

    private var upgradeButton: some View {
        Button("Try Faster Lane") {
            model.upgradeToLoopback()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("upgrade-loopback-button")
    }

    private var fallbackButton: some View {
        Button("Hold Safe Lane") {
            model.stopLoopbackListener()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("fallback-safe-lane-button")
    }

    private var scanLocalNetworkButton: some View {
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
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isScanInFlight)
        .accessibilityIdentifier("scan-local-network-button")
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

    private var enableNotificationsButton: some View {
        Button("Enable notifications") {
            model.requestNotificationAuthorization()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("enable-notifications-button")
    }

    private var showsExtendedRecoveryActions: Bool {
        model.canAttemptLoopbackUpgrade
            || model.canReturnToSafeLane
            || model.notificationSnapshot.authorization != .authorized
    }

    private var showsCompactAdvancedActions: Bool {
        canRunSmokeTest
            || model.canAttemptLoopbackUpgrade
            || model.canReturnToSafeLane
            || model.notificationSnapshot.authorization != .authorized
    }

    private var compactRecoveryDetail: String? {
        if let blocker = model.syncSnapshot.blocker?.reason,
           !blocker.isEmpty {
            return blocker
        }

        if model.networkProxyStatusLabel != "Direct paths healthy" {
            return model.networkProxyDetail
        }

        return nil
    }

    private var showsInspectorReconnectAction: Bool {
        switch model.connectionState {
        case .connected:
            return compactRecoveryDetail != nil
        case .connecting, .disconnected, .failed:
            return true
        }
    }

    private var compactStatusBadgeLabel: String? {
        switch model.connectionState {
        case .failed:
            return "Attention"
        case .connecting:
            return "Reconnecting"
        default:
            if model.syncSnapshot.blocker != nil {
                return "Attention"
            }
            if model.networkProxyStatusLabel != "Direct paths healthy" {
                return "Review"
            }
            return nil
        }
    }

    private var compactStatusSymbol: String {
        switch model.connectionState {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            if model.syncSnapshot.blocker != nil || model.networkProxyStatusLabel != "Direct paths healthy" {
                return "exclamationmark.circle"
            }
            return "checkmark.circle.fill"
        case .disconnected:
            return "wifi.slash"
        }
    }

    private var compactStatusTint: Color {
        switch model.connectionState {
        case .failed:
            return .orange
        case .connecting:
            return .blue
        case .connected:
            if model.syncSnapshot.blocker != nil || model.networkProxyStatusLabel != "Direct paths healthy" {
                return .orange
            }
            return .green
        case .disconnected:
            return .secondary
        }
    }
}
