import AppState
import SwiftUI

struct ConnectionsRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPath: [UUID] = []
    @State private var regularColumnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("cotg.connections.inspector.visible") private var showsInspector = false

    let model: AppModel
    let bottomAccessoryClearance: CGFloat
    let onOpenCodex: () -> Void

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                NavigationStack(path: $compactPath) {
                    MachineDirectoryView(
                        model: model,
                        isCompact: true,
                        onSelectCompact: { machineID in
                            model.select(machineID: machineID)
                            compactPath = [machineID]
                        },
                        onOpenCodex: onOpenCodex
                    )
                    .navigationTitle("Connections")
                    .navigationDestination(for: UUID.self) { machineID in
                        ConnectionScreenView(
                            model: model,
                            bottomAccessoryClearance: bottomAccessoryClearance,
                            onOpenCodex: onOpenCodex,
                            onForgetSavedMachine: {
                                compactPath = []
                            }
                        )
                            .navigationTitle(machineTitle(for: machineID))
                            .navigationBarTitleDisplayMode(.inline)
                            .onAppear {
                                model.select(machineID: machineID)
                            }
                    }
                }
            } else {
                NavigationSplitView(columnVisibility: $regularColumnVisibility) {
                    MachineDirectoryView(model: model, onOpenCodex: onOpenCodex)
                        .navigationTitle("Connections")
                        .accessibilityIdentifier("machine-directory-sidebar")
                } detail: {
                    ConnectionScreenView(
                        model: model,
                        bottomAccessoryClearance: 0,
                        onOpenCodex: onOpenCodex
                    )
                    .navigationTitle(model.selectedMachine?.alias ?? "Connections")
                    .toolbar {
                        if model.selectedMachine != nil {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showsInspector.toggle()
                                } label: {
                                    Label(
                                        showsInspector ? "Hide Details" : "Show Details",
                                        systemImage: "sidebar.right"
                                    )
                                }
                                .accessibilityIdentifier("connections-inspector-toggle")
                            }
                        }
                    }
                    .accessibilityIdentifier("connection-primary-pane")
                }
                .navigationSplitViewStyle(.balanced)
                .inspector(isPresented: $showsInspector) {
                    ConnectionInspectorPane(model: model)
                        .accessibilityIdentifier("connection-inspector-pane")
                }
            }
        }
        .background(shellBackground)
        .onAppear {
            syncCompactPath()
            syncRegularColumnVisibility()
        }
        .onChange(of: model.selectedMachineID) { _, newValue in
            if newValue == nil {
                showsInspector = false
            }
            syncCompactPath()
            syncRegularColumnVisibility()
        }
    }

    private func syncCompactPath() {
        guard horizontalSizeClass == .compact else {
            return
        }

        let targetPath = model.selectedMachineID.map { [$0] } ?? []
        if compactPath != targetPath {
            compactPath = targetPath
        }
    }

    private func syncRegularColumnVisibility() {
        guard horizontalSizeClass != .compact else {
            return
        }

        if regularColumnVisibility != .all {
            regularColumnVisibility = .all
        }
    }

    private func machineTitle(for machineID: UUID) -> String {
        model.machines.first(where: { $0.id == machineID })?.alias ?? "Connections"
    }
}
