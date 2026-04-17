import SwiftUI

struct MachineSidebarCard: View {
    let presentation: MachineConnectionPresentation
    let isSelected: Bool
    let primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.machine.alias)
                        .font(.headline)
                    Text(presentation.machine.hostname)
                        .font(.subheadline)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                }

                Spacer(minLength: 12)

                AppMetadataChip(
                    title: presentation.overallState.title,
                    tint: stateTint
                )
            }

            HStack(spacing: 8) {
                AppMetadataChip(title: presentation.bestRouteLabel, tint: .secondary)
                AppMetadataChip(title: presentation.savedWaysToConnectLabel, tint: .secondary)
                if let nearbyBadgeTitle = presentation.nearbyBadgeTitle {
                    AppMetadataChip(title: nearbyBadgeTitle, tint: .green)
                }
            }

            Text(presentation.summaryDetail)
                .font(.footnote)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            primaryButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .appSurface(isSelected ? .accent(.accentColor) : .secondary, padding: 14, cornerRadius: 18)
    }

    private var stateTint: Color {
        switch presentation.overallState {
        case .ready:
            .green
        case .needsSetup:
            .orange
        case .unavailable:
            .secondary
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if presentation.primaryAction == .finishSetup {
            Button(presentation.primaryAction.title, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(presentation.primaryAction.title, action: primaryAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
