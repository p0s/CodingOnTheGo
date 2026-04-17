import AppState
import SharedModels
import SwiftUI

struct ConnectionHeroCard: View {
    let model: AppModel
    let machine: MachineRecord
    let routes: [RouteRecord]
    @State private var savedSSHKeyRecoveryAvailability: SavedSSHKeyRecoveryAvailability = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader("This Mac", subtitle: machine.hostname) {
                if let verificationRoute {
                    AppMetadataChip(title: routeChipTitle(for: verificationRoute), tint: verificationTint)
                }
            }

            Text(machine.alias)
                .font(.title3.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusFact(
                        title: "Route",
                        value: routeStatusLabel,
                        tint: verificationTint
                    )
                    statusFact(title: "Trust", value: trustStatusLabel, tint: trustTint)
                    statusFact(title: accountStatusTitle, value: accountStatusLabel, tint: accountStatusTint)
                }
                VStack(alignment: .leading, spacing: 8) {
                    statusFact(
                        title: "Route",
                        value: routeStatusLabel,
                        tint: verificationTint
                    )
                    statusFact(title: "Trust", value: trustStatusLabel, tint: trustTint)
                    statusFact(title: accountStatusTitle, value: accountStatusLabel, tint: accountStatusTint)
                }
            }

            if let fingerprintSummary {
                Text("Fingerprint \(fingerprintSummary)")
                    .font(.caption.monospaced())
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .lineLimit(1)
            }

            Text(verificationDetail)
                .font(.caption)
                .foregroundStyle(AppVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.secondary, padding: 16, cornerRadius: 20)
        .task(id: savedSSHKeyRecoveryTaskID) {
            await syncSavedSSHKeyRecoveryAvailability()
        }
    }

    private var verificationRoute: RouteRecord? {
        model.routeEvaluations.first(where: \.isActive)?.route
            ?? model.routeEvaluations.first(where: \.isLastGood)?.route
            ?? model.recommendedRoute
            ?? machine.preferredRoute
    }

    private var verificationTint: Color {
        if model.connectionCandidateIsReady {
            return .green
        }
        return model.connectionFailureSummary == nil ? .orange : .red
    }

    private var trustTint: Color {
        switch model.sshTrustStatusLabel {
        case "Trusted", "Testing override":
            return .green
        case "Mismatch":
            return .red
        default:
            return .orange
        }
    }

    private var accountStatusTint: Color {
        if !model.connectionSetupAccountReady || !model.connectionSetupSSHAccessReady {
            return .orange
        }
        return .green
    }

    private var routeStatusLabel: String {
        verificationRoute?.kind.shortTitle ?? "Add route"
    }

    private var trustStatusLabel: String {
        switch model.sshTrustStatusLabel {
        case "Review scanned key":
            return "Review key"
        case "Testing override":
            return "Testing"
        default:
            return model.sshTrustStatusLabel
        }
    }

    private var accountStatusTitle: String {
        model.connectionSetupAccountReady ? "SSH" : "Account"
    }

    private var accountStatusLabel: String {
        guard model.connectionSetupAccountReady else {
            return "Choose account"
        }

        guard let credential = model.selectedMachine?.credentialRef else {
            switch savedSSHKeyRecoveryAvailability {
            case .directRecovery:
                return "Saved key"
            case .candidateSearch:
                return "Saved keys"
            case .none:
                break
            }
            if model.sshCredentialStatusLabel == "Missing" {
                return "Set up SSH"
            }
            if model.sshCredentialStatusLabel == "Localhost test key available" {
                return "Test key"
            }
            return model.sshCredentialStatusLabel
        }

        switch credential.kind {
        case .sshKey:
            return "SSH key"
        case .password:
            return "Password"
        case .token:
            return "Token"
        case .companionMutualAuth:
            return "Companion"
        }
    }

    private var fingerprintSummary: String? {
        guard let fingerprint = model.pendingScannedHostKeyFingerprint ?? model.storedTrustedHostKeyFingerprint else {
            return nil
        }
        guard fingerprint.count > 18 else {
            return fingerprint
        }
        return "\(fingerprint.prefix(12))…\(fingerprint.suffix(6))"
    }

    private var verificationDetail: String {
        if let failureSummary = model.connectionFailureSummary,
           !failureSummary.isEmpty {
            return failureSummary
        }
        if let savedSSHKeyDetail = savedSSHKeyDetail {
            return savedSSHKeyDetail
        }
        return model.connectionCandidateStatusDetail
    }

    private var savedSSHKeyRecoveryTaskID: String {
        [
            machine.id.uuidString,
            model.sshBootstrapUsername,
            model.selectedBootstrapRoute?.id.uuidString ?? "no-route",
            model.selectedMachine?.credentialRef?.keychainAccount ?? "no-credential"
        ]
        .joined(separator: "|")
    }

    private var savedSSHKeyDetail: String? {
        guard model.connectionSetupAccountReady,
              !model.connectionSetupSSHAccessReady else {
            return nil
        }

        switch savedSSHKeyRecoveryAvailability {
        case .directRecovery:
            return "A saved device SSH key already exists on this iPhone for @\(model.sshBootstrapUsername). Use it before creating a new key."
        case .candidateSearch:
            if model.connectionSetupTrustReady {
                return "Saved device SSH keys were found on this iPhone. Try them before creating a new key."
            }
            return "Saved device SSH keys were found on this iPhone. Verify the Mac fingerprint, then try them before creating a new key."
        case .none:
            return nil
        }
    }

    @MainActor
    private func syncSavedSSHKeyRecoveryAvailability() async {
        savedSSHKeyRecoveryAvailability = .none

        guard model.connectionSetupAccountReady,
              !model.connectionSetupSSHAccessReady else {
            return
        }

        for attempt in 0..<10 {
            let availability = await model.savedSSHKeyRecoveryAvailabilityForSelectedMachine()
            if availability != .none {
                savedSSHKeyRecoveryAvailability = availability
                return
            }

            if attempt < 9 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func routeChipTitle(for route: RouteRecord) -> String {
        route.kind.shortTitle
    }

    private func statusFact(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppVisualStyle.secondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(tint), padding: 10, cornerRadius: 14)
    }
}
