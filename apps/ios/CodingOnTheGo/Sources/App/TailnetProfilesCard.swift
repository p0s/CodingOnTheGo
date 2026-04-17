import AppState
import SharedModels
import SwiftUI
import TailnetEmbedded

struct TailnetProfilesCard: View {
    @Environment(\.openURL) private var openURL
    @State private var displayName = ""
    @State private var controlURL = "https://"
    @State private var accountLabel = ""
    @State private var profileType: TailnetProfileType = .external

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tailscale fallback")
                        .font(.title3.weight(.semibold))
                    Text(tailnetSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.showsExternalTailnetStatus {
                        Text("External app: \(model.externalTailnetAppStatusLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("external-tailnet-status-label")
                    }
                }
                Spacer()
                if model.showsEmbeddedTailnetFeature {
                    TailnetStatusChip(status: model.embeddedTailnetStatus)
                }
            }

            if model.showsEmbeddedTailnetFeature {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.embeddedTailnetTrafficReadinessLabel)
                        .font(.subheadline.weight(.semibold))
                    if let detail = model.embeddedTailnetTrafficReadinessDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if model.showsEmbeddedTailnetFeature,
               let ticket = model.pendingTailnetAuthTicket {
                TailnetAuthTicketBanner(ticket: ticket)
            }

            VStack(spacing: 12) {
                ForEach(model.tailnetProfiles) { profile in
                    TailnetProfileRow(
                        profile: profile,
                        pendingTicket: pendingTicket(for: profile),
                        model: model,
                        openAuthURL: { authURL in
                            openURL(authURL)
                        }
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Add custom control server")
                    .font(.headline)

                if model.showsEmbeddedTailnetFeature {
                    Picker("Profile type", selection: $profileType) {
                        Text("Embedded").tag(TailnetProfileType.embedded)
                        Text("External").tag(TailnetProfileType.external)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("tailnet-profile-kind-picker")
                } else {
                    Text("This build only exposes external control servers because the native embedded Tailscale runtime is not vendored here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("tailnet-display-name-field")

                TextField("Control URL", text: $controlURL)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("tailnet-control-url-field")

                TextField("Account label", text: $accountLabel)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("tailnet-account-label-field")

                Button("Save Tailnet Profile") {
                    model.addTailnetProfile(
                        displayName: displayName,
                        kind: model.showsEmbeddedTailnetFeature ? profileType : .external,
                        controlURLString: controlURL,
                        accountLabel: accountLabel
                    )
                    displayName = ""
                    accountLabel = ""
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("save-tailnet-profile-button")
            }
        }
        .adaptiveGlassSurface(tint: Color.mint.opacity(0.14), cornerRadius: 28)
        .onAppear {
            if !model.showsEmbeddedTailnetFeature {
                profileType = .external
            }
        }
    }

    private var tailnetSummary: String {
        if model.showsEmbeddedTailnetFeature {
            return "Use Tailscale for away-from-home reconnects, while same-Wi‑Fi and direct SSH remain separate local fallbacks."
        }

        return "Manage external Tailscale routes for reconnects that need the standalone Tailscale app."
    }

    private func pendingTicket(for profile: TailnetProfile) -> EmbeddedTailnetAuthTicket? {
        guard model.pendingTailnetAuthTicket?.profileID == profile.id else {
            return nil
        }

        return model.pendingTailnetAuthTicket
    }
}

private struct TailnetProfileRow: View {
    let profile: TailnetProfile
    let pendingTicket: EmbeddedTailnetAuthTicket?
    let model: AppModel
    let openAuthURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text(profile.controlURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(profile.kind == .embedded ? "Embedded" : "External")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }

            HStack {
                Label(profile.accountLabel.isEmpty ? "No account label yet" : profile.accountLabel, systemImage: "person")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pendingTicket != nil {
                    Spacer()
                    Text("Sign-in pending")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if profile.kind == .embedded, profile.lastAuthenticatedAt == nil {
                    Spacer()
                    Text("Signed out")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let lastAuthenticatedAt = profile.lastAuthenticatedAt {
                    Spacer()
                    Text(lastAuthenticatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if profile.isActive {
                    Button("Active") {
                        model.activateTailnetProfile(profile.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("activate-tailnet-\(sanitizedID)")
                } else {
                    Button("Use This Route") {
                        model.activateTailnetProfile(profile.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("activate-tailnet-\(sanitizedID)")
                }

                if model.showsEmbeddedTailnetFeature,
                   profile.kind == .embedded,
                   pendingTicket == nil,
                   profile.lastAuthenticatedAt == nil {
                    Button("Sign in to Tailscale") {
                        model.beginEmbeddedTailnetAuthentication(profile.id) { ticket in
                            guard let ticket else {
                                return
                            }
                            openAuthURL(ticket.authURL)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("begin-tailnet-login-\(sanitizedID)")
                }

                if model.showsEmbeddedTailnetFeature,
                   profile.kind == .embedded,
                   let pendingTicket {
                    Button("Open Sign-In Page") {
                        openAuthURL(pendingTicket.authURL)
                    }
                    .buttonStyle(.bordered)

                    Button("Check Status") {
                        model.refreshEmbeddedTailnetRuntimeStatus()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("refresh-tailnet-login-\(sanitizedID)")
                }

                if model.showsEmbeddedTailnetFeature,
                   profile.kind == .embedded,
                   (profile.lastAuthenticatedAt != nil || pendingTicket != nil) {
                    Button(profile.lastAuthenticatedAt == nil ? "Reset Login" : "Sign Out") {
                        model.resetEmbeddedTailnetAuthentication(profile.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reset-tailnet-login-\(sanitizedID)")
                }

                Button(role: .destructive) {
                    model.deleteTailnetProfile(profile.id)
                } label: {
                    Text("Delete")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("delete-tailnet-\(sanitizedID)")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sanitizedID: String {
        profile.displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }
}

private struct TailnetAuthTicketBanner: View {
    let ticket: EmbeddedTailnetAuthTicket

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Embedded sign-in required")
                .font(.headline)
            Text("Open this exact sign-in page, finish approving the embedded node, then return to the app to refresh embedded tailnet status.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(ticket.authURL.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TailnetStatusChip: View {
    let status: EmbeddedTailnetStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status.authState {
        case .signedOut:
            "Signed out"
        case .authenticating:
            "Authenticating"
        case .authenticated:
            status.isReachable ? "Ready" : "Authenticated"
        case .blocked:
            "Blocked"
        }
    }

    private var tint: Color {
        switch status.authState {
        case .signedOut:
            .secondary
        case .authenticating:
            .orange
        case .authenticated:
            status.isReachable ? .green : .blue
        case .blocked:
            .red
        }
    }
}
