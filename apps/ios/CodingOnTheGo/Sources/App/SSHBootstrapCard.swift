import AppState
import SwiftUI

struct SSHBootstrapCard: View {
    let model: AppModel
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSH details")
                .font(.title3.weight(.semibold))

            statusLine("Connection path", value: model.selectedBootstrapRoute?.label ?? "Unavailable")
            statusLine("Username", value: model.sshBootstrapUsername)
            statusLine("Trust", value: model.sshTrustStatusLabel)
            statusLine("Login", value: model.sshCredentialStatusLabel)

            if let guidance = model.sshBootstrapUsernameGuidance {
                Text(guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.sshBootstrapUsername == "Required" || model.sshBootstrapUsernameGuidance != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SSH username")
                        .font(.headline)
                    Text("Set the Mac account username for the selected route so trust, password save, and SSH key generation all target the same login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Mac account username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh-username-field")
                    Button("Save Username") {
                        model.saveSelectedBootstrapUsername(username)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ssh-save-username-button")
                }
            }

            if let storedFingerprint = model.storedTrustedHostKeyFingerprint {
                detailLine("Trusted fingerprint", value: storedFingerprint)
            } else {
                detailLine("Trusted fingerprint", value: "Not trusted yet")
            }

            if let trustGuidance = model.selectedRouteScannedHostKeyGuidance {
                AppInlineNotice(
                    title: "Verify Mac fingerprint",
                    detail: trustGuidance,
                    tint: .orange,
                    icon: "checkmark.shield"
                )
                .accessibilityIdentifier("ssh-trust-required-notice")

                if let scannedFingerprint = model.pendingScannedHostKeyFingerprint {
                    detailLine("Scanned fingerprint", value: scannedFingerprint)
                }
            } else if let scannedFingerprint = model.pendingScannedHostKeyFingerprint {
                detailLine("Scanned fingerprint", value: scannedFingerprint)
            }

            if model.showsLocalhostTestingControls,
               let generatedKey = model.generatedSSHTestPublicKey {
                detailLine("Generated localhost test key", value: generatedKey)
                    .textSelection(.enabled)
            }

            if model.showsLocalhostTestingControls {
                Text(model.localhostTestKeyExists
                    ? "The localhost testing key stays separate from normal host trust and is meant only for local verification."
                    : "Generate the clearly marked localhost testing key only when you need a local verification path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("SSH key login")
                    .font(.headline)
                Text("Generate a device SSH key for \(AppDeviceCopy.thisDevice), then add the public key to ~/.ssh/authorized_keys on the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let publicKey = model.revealedSSHLoginPublicKey {
                    detailLine("Public key", value: publicKey)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Button(model.canRevealSSHLoginPublicKey ? "Replace SSH Key" : "Generate SSH Key") {
                        model.generateSSHKeyCredential()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canGenerateSSHKeyLogin)
                    .accessibilityIdentifier("ssh-generate-key-button")

                    if model.canRevealSSHLoginPublicKey {
                        Button("Show Public Key") {
                            model.revealSSHLoginPublicKey()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("ssh-show-public-key-button")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Password login")
                    .font(.headline)
                SecureField("Save the Mac account password for this route", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .accessibilityIdentifier("ssh-password-field")
                HStack(spacing: 12) {
                    Button("Save Password Login") {
                        model.savePasswordCredential(password)
                        password = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !model.canSavePasswordLogin
                    )
                    .accessibilityIdentifier("ssh-save-password-button")

                    Text("Stored in the Apple keychain for this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    primaryActions
                    secondaryActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    primaryActions
                    secondaryActions
                }
            }
        }
        .adaptiveGlassSurface(tint: Color.orange.opacity(0.14), cornerRadius: 28)
        .onAppear(perform: syncUsernameField)
        .onChange(of: model.selectedBootstrapRoute?.id) { _, _ in
            syncUsernameField()
        }
    }

    private var primaryActions: some View {
        Group {
            if model.canTrustScannedHostKey {
                Button("Scan again") {
                    model.scanSelectedRouteHostKey()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canScanSelectedRouteHostKey)
                .accessibilityIdentifier("ssh-scan-host-key-button")

                Button("Trust scanned key") {
                    model.trustScannedHostKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canTrustScannedHostKey)
                .accessibilityIdentifier("ssh-trust-host-key-button")
            } else {
                Button("Scan host key") {
                    model.scanSelectedRouteHostKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canScanSelectedRouteHostKey)
                .accessibilityIdentifier("ssh-scan-host-key-button")

                Button("Trust scanned key") {
                    model.trustScannedHostKey()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canTrustScannedHostKey)
                .accessibilityIdentifier("ssh-trust-host-key-button")
            }

            Button("Clear trusted key") {
                model.clearTrustedHostKey()
            }
            .buttonStyle(.bordered)
            .disabled(!model.canClearTrustedHostKey)
            .accessibilityIdentifier("ssh-clear-host-key-button")
        }
    }

    private var secondaryActions: some View {
        Group {
            if model.showsLocalhostTestingControls {
                Button("Generate localhost test key") {
                    model.generateSSHTestKeyIfMissing()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ssh-generate-test-key-button")

                Button("Load localhost test key") {
                    model.loadLocalhostTestCredential()
                }
                .buttonStyle(.bordered)
                .disabled(!model.localhostTestKeyExists)
                .accessibilityIdentifier("ssh-load-test-key-button")
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

    private func detailLine(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
        }
    }

    private func syncUsernameField() {
        let current = model.sshBootstrapUsername
        username = current == "Required" ? "" : current
    }
}
