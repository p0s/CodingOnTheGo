import AppState
import SharedModels
import SwiftUI

struct QuickManualRouteCard: View {
    let model: AppModel
    let title: String
    let subtitle: String
    let labelPlaceholder: String
    let submitTitle: String
    let availableKinds: [MachineRouteKind]

    @State private var routeLabel = ""
    @State private var routeAddress = ""
    @State private var routeUsername = ""
    @State private var routePort = ""
    @State private var routeKind: MachineRouteKind

    init(
        model: AppModel,
        title: String = "Add route",
        subtitle: String = "Save another SSH-backed route for this Mac.",
        labelPlaceholder: String = "Route label (optional)",
        submitTitle: String = "Save route",
        availableKinds: [MachineRouteKind] = [.localLAN, .manualSSH],
        initialKind: MachineRouteKind = .manualSSH
    ) {
        self.model = model
        self.title = title
        self.subtitle = subtitle
        self.labelPlaceholder = labelPlaceholder
        self.submitTitle = submitTitle
        self.availableKinds = availableKinds
        let resolvedInitialKind = availableKinds.contains(initialKind) ? initialKind : (availableKinds.first ?? .manualSSH)
        _routeKind = State(initialValue: resolvedInitialKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField(labelPlaceholder, text: $routeLabel)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("quick-manual-route-label-field")

            TextField("IP address or hostname", text: $routeAddress)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("quick-manual-route-address-field")

            HStack(spacing: 12) {
                TextField("Username (optional)", text: $routeUsername)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("quick-manual-route-username-field")

                TextField("Port (optional)", text: $routePort)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("quick-manual-route-port-field")
            }

            if availableKinds.count > 1 {
                Picker("Connection type", selection: $routeKind) {
                    ForEach(availableKinds, id: \.self) { kind in
                        Text(kindPickerTitle(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("quick-manual-route-kind-picker")
            }

            Button(submitTitle) {
                addRoute()
            }
            .buttonStyle(.borderedProminent)
            .disabled(routeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("quick-manual-route-add-button")
        }
        .adaptiveGlassSurface(tint: Color.teal.opacity(0.14), cornerRadius: 28)
    }

    private func addRoute() {
        let trimmedLabel = routeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = routeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = routeUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = UInt16(routePort.trimmingCharacters(in: .whitespacesAndNewlines))

        model.addManualRoute(
            label: trimmedLabel.isEmpty ? routeKind.title : trimmedLabel,
            address: trimmedAddress,
            kind: routeKind,
            usernameHint: trimmedUsername.isEmpty ? nil : trimmedUsername,
            port: normalizedPort
        )

        routeLabel = ""
        routeAddress = ""
        routeUsername = ""
        routePort = ""
        routeKind = availableKinds.first(where: { $0 == routeKind }) ?? availableKinds.first ?? .manualSSH
    }

    private func kindPickerTitle(_ kind: MachineRouteKind) -> String {
        switch kind {
        case .localLAN:
            return "Same Wi‑Fi"
        case .manualSSH:
            return "Direct SSH"
        case .externalTailnet:
            return "Tailscale"
        case .embeddedTailnet:
            return "Built-in"
        case .companionDirect:
            return "Companion"
        }
    }
}
