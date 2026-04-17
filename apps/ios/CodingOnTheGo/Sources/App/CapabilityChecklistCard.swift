import AppState
import HostBootstrap
import SwiftUI

struct CapabilityChecklistCard: View {
    let report: HostCapabilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Capability diagnostics")
                .font(.title3.weight(.semibold))
            ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(check.title)
                            .font(.headline)
                        Spacer()
                        Text(check.state.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(check.state))
                    }
                    Text(HostCapabilityCheckFormatter.summary(for: check))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let remediation = HostCapabilityCheckFormatter.remediation(for: check) {
                        Text(remediation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .adaptiveGlassSurface(tint: Color.cyan.opacity(0.16), cornerRadius: 28)
    }

    private func statusColor(_ state: CapabilityCheckState) -> Color {
        switch state {
        case .ready:
            .green
        case .warning:
            .orange
        case .blocked:
            .red
        }
    }
}
