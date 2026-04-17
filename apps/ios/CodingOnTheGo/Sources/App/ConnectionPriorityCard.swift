import RouteSelection
import SharedModels
import SwiftUI

struct ConnectionPriorityCard: View {
    let step: ConnectionStep
    let position: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(format: "%02d", position))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(statusColor.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 6) {
                Text(step.lane.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(step.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ConnectionStepTraits(step: step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(tint: statusColor.opacity(0.22), cornerRadius: 24)
    }

    private var statusColor: Color {
        switch step.readiness {
        case .ready:
            .green
        case .standby:
            .orange
        case .blocked:
            .red
        }
    }
}

private struct ConnectionStepTraits: View {
    let step: ConnectionStep

    var body: some View {
        AdaptiveGlassCluster(spacing: 10) {
            HStack(spacing: 10) {
                traitChip(step.readiness.rawValue.capitalized, tint: statusColor)
                if let route = step.route {
                    traitChip(route.title, tint: .blue)
                }
                if let bootstrap = step.bootstrap {
                    traitChip(bootstrapLabel(bootstrap), tint: .orange)
                }
                if let protocolKind = step.protocolKind {
                    traitChip(protocolLabel(protocolKind), tint: .purple)
                }
            }
        }
    }

    private var statusColor: Color {
        switch step.readiness {
        case .ready:
            .green
        case .standby:
            .orange
        case .blocked:
            .red
        }
    }

    private func traitChip(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func bootstrapLabel(_ bootstrap: BootstrapStrategy) -> String {
        switch bootstrap {
        case .standardSSH:
            "SSH bootstrap"
        case .companionManaged:
            "Companion managed"
        case .codexAppServerWebSocket:
            "Codex WebSocket"
        case .manual:
            "Manual"
        }
    }

    private func protocolLabel(_ protocolKind: CodexProtocolKind) -> String {
        switch protocolKind {
        case .stdio:
            "stdio"
        case .websocket:
            "websocket"
        case .directEndpoint:
            "direct"
        }
    }
}
