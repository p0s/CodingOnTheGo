import CompanionHost
import SwiftUI

struct CompanionDashboardView: View {
    let model: CompanionAppModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Host") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.snapshot.hostDisplayName)
                            .font(.headline)
                        Text(model.snapshot.recommendation.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(model.snapshot.recommendation.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Published routes") {
                    if model.snapshot.publishedRoutes.isEmpty {
                        Text("No routes published yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.publishedRoutes) { route in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.kind.title)
                                    .font(.headline)
                                Text(route.address)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Health") {
                    LabeledContent("Routes", value: model.snapshot.routeSummary)
                    LabeledContent("Listener", value: model.snapshot.listenerSummary)
                    LabeledContent("Direct endpoint", value: model.snapshot.directEndpoint?.absoluteString ?? "Not published")
                }

                Section("Publication") {
                    LabeledContent("Metadata", value: model.snapshot.publication.metadataPath)
                    LabeledContent("Sync mirror", value: model.snapshot.publication.syncMirrorPath)
                    LabeledContent("Published routes", value: "\(model.snapshot.publication.publishedRouteCount)")
                    Text(model.snapshot.publication.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Notification bridge") {
                    LabeledContent("Mode", value: model.snapshot.notificationBridge.mode.rawValue.capitalized)
                    LabeledContent("Relay", value: model.snapshot.notificationBridge.relayDescription ?? "Not configured")
                    LabeledContent("Pending", value: "\(model.snapshot.notificationBridge.pendingCount)")
                    LabeledContent("Delivered", value: "\(model.snapshot.notificationBridge.deliveredCount)")
                    if let lastError = model.snapshot.notificationBridge.lastErrorSummary {
                        Text(lastError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Companion")
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                Text("Coding On The Go Companion")
                    .font(.largeTitle.weight(.bold))

                statusBanner
                recommendationCard

                HStack(spacing: 12) {
                    statCard(title: "Shared listener", value: model.snapshot.sharedListenerState.rawValue.capitalized)
                    statCard(title: "Healthy routes", value: "\(model.snapshot.routeHealthCounts.healthy)")
                    statCard(title: "Launch at login", value: model.loginItemStatus.label)
                    statCard(title: "Bridge outbox", value: "\(model.snapshot.notificationBridge.pendingCount) pending")
                }

                detailRow("Route publishing", value: model.snapshot.capabilities.canPublishRoutes ? "Enabled" : "Unavailable")
                detailRow("Publication", value: model.snapshot.publication.note)
                detailRow("Notification bridge", value: model.snapshot.notificationBridge.relayDescription ?? "Inactive")
                detailRow("Endpoint mode", value: model.snapshot.capabilities.canExposeDirectEndpoint ? "Available" : "Disabled")
                detailRow("Launch at login", value: model.loginItemStatus.label)
                detailRow("Last refresh", value: model.lastUpdatedAt.map(Self.timestampFormatter.string(from:)) ?? "Not refreshed yet")
                Text(model.loginItemStatus.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                eventTimeline

                HStack(spacing: 12) {
                    Button("Refresh") {
                        model.refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)

                    Button("Start Listener") {
                        model.startSharedListener()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.snapshot.sharedListenerState == .ready)

                    Button("Stop Listener") {
                        model.stopSharedListener()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.snapshot.sharedListenerState == .stopped)

                    Button("Enable at Login") {
                        model.enableLaunchAtLogin()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || !model.loginItemStatus.canEnable)

                    Button("Disable at Login") {
                        model.disableLaunchAtLogin()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || !model.loginItemStatus.canDisable)

                    Button("Open Codex Mac") {
                        model.openCodexMac()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                Spacer()
            }
            .padding(32)
        }
    }

    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.snapshot.recommendation.title)
                .font(.title3.weight(.semibold))
            Text(model.snapshot.recommendation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                statusChip(
                    title: model.actionState.rawValue.replacingOccurrences(of: "Listener", with: " listener").capitalized,
                    tint: actionTint
                )
                statusChip(
                    title: model.snapshot.presence.readyForEnhancedMode ? "Presence ready" : "Presence needs attention",
                    tint: model.snapshot.presence.readyForEnhancedMode ? .green : .orange
                )
                statusChip(
                    title: model.snapshot.sharedListenerState.rawValue.capitalized,
                    tint: listenerTint
                )
            }

            Text(model.actionSummary)
                .font(.headline)
            Text(model.statusSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent state transitions")
                .font(.headline)

            if model.statusEvents.isEmpty {
                Text("Refresh or change listener state to capture companion events.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.statusEvents) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(event.level == .error ? Color.red : Color.blue)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.summary)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(Self.timestampFormatter.string(from: event.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func statusChip(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var actionTint: Color {
        switch model.actionState {
        case .idle:
            .green
        case .refreshing:
            .blue
        case .startingListener, .stoppingListener, .updatingLoginItem, .launchingCodex:
            .orange
        case .failed:
            .red
        }
    }

    private var listenerTint: Color {
        switch model.snapshot.sharedListenerState {
        case .ready:
            .green
        case .warming:
            .orange
        case .degraded:
            .red
        case .stopped:
            .secondary
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
