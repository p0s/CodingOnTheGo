import AppState
import SharedModels
import SwiftUI

struct MachineDirectoryView: View {
    @Environment(\.openWindow) private var openWindow

    let model: AppModel
    var isCompact = false
    var onSelectCompact: ((MachineRecord.ID) -> Void)?
    var onOpenCodex: () -> Void = {}

    @State private var showsAddMacFlow = false
    @State private var addMacInitialMethod: AddMacMethod?

    var body: some View {
        List {
            if model.machines.isEmpty {
                Section {
                    ConnectionsEmptyDirectoryView(
                        onFindNearby: { openAddMac(.nearby) },
                        onAddManually: { openAddMac(nil) }
                    )
                }
                .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20))
                .listRowBackground(Color.clear)
            } else {
                Section("Macs") {
                    ForEach(model.machines) { machine in
                        machineRow(machine)
                    }
                }

                Section {
                    ProductSupportButtonRow(
                        privacyAccessibilityIdentifier: "machine-directory-privacy-link",
                        supportAccessibilityIdentifier: "machine-directory-support-link"
                    )
                } footer: {
                    Text("Connections keeps setup, repair, and route choices close at hand. Daily coding stays in Codex.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(shellBackground)
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openAddMac(nil)
                } label: {
                    Label("Add Mac", systemImage: "plus")
                }
                .accessibilityIdentifier("machine-directory-add-mac-toolbar-button")
            }
        }
        .sheet(isPresented: $showsAddMacFlow) {
            AddMacFlowView(
                model: model,
                initialMethod: addMacInitialMethod
            ) { machineID in
                handleSelection(machineID: machineID)
            }
        }
    }

    @ViewBuilder
    private func machineRow(_ machine: MachineRecord) -> some View {
        let presentation = MachineConnectionPresentation(
            machine: machine,
            model: model,
            nearbyResult: model.nearbyDiscoveryResults.first(where: { $0.machineID == machine.id })
        )

        HStack(alignment: .top, spacing: 12) {
            MachineSidebarCard(
                presentation: presentation,
                isSelected: machine.id == model.selectedMachine?.id,
                primaryAction: {
                    handlePrimaryAction(for: machine, presentation: presentation)
                }
            )
            .onTapGesture {
                handleSelection(machineID: machine.id)
            }
            .accessibilityIdentifier("machine-card-\(machine.alias)")

            if !isCompact {
                Button {
                    openWindow(id: CodingOnTheGoRouting.machineWindowGroupID, value: machine.id.uuidString)
                } label: {
                    Label("New Window", systemImage: "rectangle.on.rectangle")
                        .labelStyle(.iconOnly)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("open-machine-window-\(machine.alias)")
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private func latestSession(for machineID: MachineRecord.ID) -> SessionRecord? {
        let machineSessions = model.recentSessions
            .filter { $0.machineID == machineID }

        return machineSessions
            .filter { $0.threadID != nil }
            .max(by: { $0.lastOpenedAt < $1.lastOpenedAt })
            ?? machineSessions.max(by: { $0.lastOpenedAt < $1.lastOpenedAt })
    }

    private func handleSelection(machineID: MachineRecord.ID) {
        if isCompact {
            onSelectCompact?(machineID)
        } else {
            model.select(machineID: machineID)
        }
    }

    private func handlePrimaryAction(
        for machine: MachineRecord,
        presentation: MachineConnectionPresentation
    ) {
        handleSelection(machineID: machine.id)

        switch presentation.primaryAction {
        case .finishSetup:
            return
        case .connect:
            model.connectLocalLoopback()
        case .openCodex:
            onOpenCodex()
        case .resume:
            if let session = latestSession(for: machine.id) {
                model.resumeSession(session.id)
            }
            onOpenCodex()
        }
    }

    private func openAddMac(_ method: AddMacMethod?) {
        addMacInitialMethod = method
        showsAddMacFlow = true
    }
}

private struct ConnectionsEmptyDirectoryView: View {
    let onFindNearby: () -> Void
    let onAddManually: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect your Mac")
                .font(.title2.weight(.semibold))

            Text("Start with the nearby path first. If the Mac is not on the same network, add it with Tailscale, a local address, or another SSH address.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Find nearby Mac", action: onFindNearby)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("machine-directory-scan-button")

            Button("Add manually", action: onAddManually)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("machine-directory-open-add-mac-button")

            ProductSupportButtonRow(
                privacyAccessibilityIdentifier: "machine-directory-privacy-link",
                supportAccessibilityIdentifier: "machine-directory-support-link"
            )
        }
    }
}
