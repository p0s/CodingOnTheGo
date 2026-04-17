import AppState
import SharedModels
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum AddMacMethod: String, CaseIterable, Hashable, Identifiable {
    case nearby
    case externalTailnet
    case manualSSH
    case localLAN

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearby:
            "Nearby"
        case .externalTailnet:
            "Tailscale"
        case .manualSSH:
            "SSH address"
        case .localLAN:
            "Local address"
        }
    }

    var subtitle: String {
        switch self {
        case .nearby:
            "Scan for Macs on the same Wi-Fi or nearby network."
        case .externalTailnet:
            "Use your Mac’s `*.ts.net` name for away-from-home access."
        case .manualSSH:
            "Use a direct hostname or reachable SSH address."
        case .localLAN:
            "Type a local hostname or IP if the Mac is nearby but not discoverable."
        }
    }

    var systemImage: String {
        switch self {
        case .nearby:
            "dot.radiowaves.left.and.right"
        case .externalTailnet:
            "point.3.connected.trianglepath.dotted"
        case .manualSSH:
            "network"
        case .localLAN:
            "wifi"
        }
    }

    var routeKind: MachineRouteKind? {
        switch self {
        case .nearby:
            nil
        case .externalTailnet:
            .externalTailnet
        case .manualSSH:
            .manualSSH
        case .localLAN:
            .localLAN
        }
    }
}

struct AddMacFlowView: View {
    @Environment(\.dismiss) private var dismiss

    let model: AppModel
    let initialMethod: AddMacMethod?
    let onComplete: (MachineRecord.ID) -> Void

    @State private var path: [AddMacMethod] = []

    var body: some View {
        NavigationStack(path: $path) {
            AddMacMethodPickerView { method in
                path = [method]
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: AddMacMethod.self) { method in
                destination(for: method)
            }
            .onAppear {
                guard let initialMethod, path.isEmpty else {
                    return
                }
                path = [initialMethod]
            }
        }
    }

    @ViewBuilder
    private func destination(for method: AddMacMethod) -> some View {
        switch method {
        case .nearby:
            NearbyScanResultsView(model: model) { machineID in
                finish(with: machineID)
            }
        case .externalTailnet, .manualSSH, .localLAN:
            ConnectionMethodFormView(
                model: model,
                method: method
            ) { machineID in
                finish(with: machineID)
            }
        }
    }

    private func finish(with machineID: MachineRecord.ID) {
        onComplete(machineID)
        dismiss()
    }
}

private struct AddMacMethodPickerView: View {
    let onSelect: (AddMacMethod) -> Void

    var body: some View {
        List {
            Section("How do you want to find this Mac?") {
                ForEach(AddMacMethod.allCases) { method in
                    Button {
                        onSelect(method)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: method.systemImage)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20, height: 20)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(method.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(method.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 12)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(methodAccessibilityIdentifier(method))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(shellBackground)
    }

    private func methodAccessibilityIdentifier(_ method: AddMacMethod) -> String {
        switch method {
        case .nearby:
            return "add-mac-method-nearby"
        case .externalTailnet:
            return "machine-directory-open-tailnet-route-button"
        case .manualSSH:
            return "machine-directory-open-remote-ssh-route-button"
        case .localLAN:
            return "machine-directory-open-manual-route-button"
        }
    }
}

private struct NearbyScanResultsView: View {
    @Environment(\.openURL) private var openURL

    let model: AppModel
    let onComplete: (MachineRecord.ID) -> Void

    @State private var hasAutoAdvanced = false

    var body: some View {
        List {
            Section {
                Text("Nearby discovery is the easiest path. Choose a Mac below or scan again if the list is stale.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    model.scanLocalNetwork()
                } label: {
                    HStack(spacing: 8) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isScanning ? "Finding nearby Mac..." : "Find nearby Mac")
                    }
                }
                .accessibilityIdentifier("machine-directory-scan-button")
            }

            if !model.nearbyDiscoveryResults.isEmpty {
                Section("Nearby now") {
                    ForEach(model.nearbyDiscoveryResults) { result in
                        Button {
                            onComplete(result.machineID)
                        } label: {
                            NearbyResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("nearby-result-\(result.machineID.uuidString)")
                    }
                }
            } else {
                scanFeedbackSection
            }

            Section("If nearby scan does not find it") {
                Text(noResultsGuidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

#if canImport(UIKit)
                if model.needsLocalNetworkSettingsRepair,
                   let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") {
                        openURL(settingsURL)
                    }
                    .accessibilityIdentifier("machine-directory-open-settings-button")
                }
#endif
            }
        }
        .navigationTitle("Nearby")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(shellBackground)
        .task {
            if model.nearbyDiscoveryResults.isEmpty {
                model.scanLocalNetwork()
            }
        }
        .onChange(of: model.nearbyDiscoveryResults.map(\.id)) { _, _ in
            autoAdvanceIfPossible()
        }
        .onAppear {
            autoAdvanceIfPossible()
        }
    }

    @ViewBuilder
    private var scanFeedbackSection: some View {
        switch model.localNetworkScanStatus {
        case .idle, .scanning:
            Section("Nearby now") {
                Text(isScanning ? "Looking for Macs on this network." : "No nearby Macs are listed yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case let .found(totalMachineCount, newMachineCount):
            Section("Nearby now") {
                Text(scanSuccessDetail(totalMachineCount: totalMachineCount, newMachineCount: newMachineCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case let .noResults(proxyRisk):
            Section("Nearby now") {
                AppInlineNotice(
                    title: "No nearby Mac found yet",
                    detail: proxyRisk
                        ? "A proxy or VPN may be blocking local discovery. Keep the Mac awake, on the same Wi-Fi, and bypass local traffic before trying again."
                        : "Keep the Mac awake, on the same Wi-Fi, and allow Local Network access if iPhone asks.",
                    tint: .orange,
                    icon: "wifi.exclamationmark"
                )
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.localNetworkScanStatus {
            return true
        }
        return false
    }

    private var noResultsGuidance: String {
        "Use Local address if you know the Mac’s `.local` hostname or IP, or choose Tailscale or SSH address if the Mac is not nearby."
    }

    private func scanSuccessDetail(totalMachineCount: Int, newMachineCount: Int) -> String {
        if newMachineCount > 0 {
            return "Found \(newMachineCount) new Mac\(newMachineCount == 1 ? "" : "s")."
        }

        return "Refreshed \(totalMachineCount) saved Mac\(totalMachineCount == 1 ? "" : "s")."
    }

    private func autoAdvanceIfPossible() {
        guard !hasAutoAdvanced else {
            return
        }

        let highConfidenceResults = model.nearbyDiscoveryResults.filter(\.isHighConfidence)
        guard highConfidenceResults.count == 1,
              let result = highConfidenceResults.first else {
            return
        }

        hasAutoAdvanced = true
        onComplete(result.machineID)
    }
}

private struct NearbyResultRow: View {
    let result: NearbyMachineResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(result.machineAlias)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if result.isAlreadySaved {
                    AppMetadataChip(title: "Already saved", tint: .blue)
                } else {
                    AppMetadataChip(title: "Nearby", tint: .green)
                }
            }

            Text(result.hostname)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                AppMetadataChip(title: result.routeKind.shortTitle, tint: .secondary)
                AppMetadataChip(title: result.health == .healthy ? "Reachable" : "Checking", tint: result.health == .healthy ? .green : .secondary)
                if result.isAlreadySaved {
                    AppMetadataChip(title: "Nearby now", tint: .green)
                }
            }
        }
    }
}

private struct ConnectionMethodFormView: View {
    let model: AppModel
    let method: AddMacMethod
    let onComplete: (MachineRecord.ID) -> Void

    @State private var address = ""
    @State private var username = ""
    @State private var port = ""

    var body: some View {
        Form {
            Section {
                Text(method.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Connection details") {
                TextField(addressPlaceholder, text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("manual-route-address-field")

                TextField("Username (optional)", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("manual-route-username-field")

                TextField("Port (optional)", text: $port)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("manual-route-port-field")
            }

            Section {
                Button("Add Mac") {
                    addMac()
                }
                .disabled(trimmedAddress.isEmpty)
                .accessibilityIdentifier("manual-route-add-button")
            }
        }
        .navigationTitle(method.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addressPlaceholder: String {
        switch method {
        case .externalTailnet:
            "your-mac.example.ts.net"
        case .manualSSH:
            "ssh.example.com"
        case .localLAN:
            "example-mac.local or 192.168.1.20"
        case .nearby:
            ""
        }
    }

    private func addMac() {
        guard let kind = method.routeKind else {
            return
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines))

        model.addManualMachine(
            machineLabel: nil,
            address: trimmedAddress,
            kind: kind,
            usernameHint: trimmedUsername.isEmpty ? nil : trimmedUsername,
            port: normalizedPort
        ) { machineID in
            onComplete(machineID)
        }
    }
}
