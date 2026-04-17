import AppState
import SharedModels
import SwiftUI

struct CodexWorkspacePickerView: View {
    @State private var listing: WorkspaceDirectoryListing?
    @State private var currentPath: String?
    @State private var errorSummary: String?
    @State private var isLoading = false
    @State private var searchText = ""

    let model: AppModel
    let machine: MachineRecord?
    let initialPath: String?
    let onSelectWorkspace: (String) -> Void

    init(
        model: AppModel,
        machine: MachineRecord?,
        initialPath: String?,
        onSelectWorkspace: @escaping (String) -> Void
    ) {
        self.model = model
        self.machine = machine
        self.initialPath = Self.normalizedPath(initialPath)
        self.onSelectWorkspace = onSelectWorkspace
        _currentPath = State(initialValue: Self.normalizedPath(initialPath))
    }

    var body: some View {
        List {
            Section {
                AppSectionHeader(
                    machine?.alias ?? "Selected Mac",
                    subtitle: listing?.currentPath ?? currentPath ?? "Browse for a git repository."
                ) {
                    if let listing {
                        AppMetadataChip(
                            title: listing.isCurrentPathGitRepository ? "Repo" : "Folder",
                            tint: listing.isCurrentPathGitRepository ? .green : .secondary
                        )
                    }
                }

                if let listing, listing.isCurrentPathGitRepository {
                    Button {
                        onSelectWorkspace(listing.currentPath)
                    } label: {
                        Label("Use current folder", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("workspace-picker-use-current")
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)

            if isLoading {
                Section {
                    ProgressView("Loading folders")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            } else if let errorSummary {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        AppSectionHeader("Couldn’t load folders", subtitle: errorSummary)

                        Button("Retry") {
                            Task {
                                await loadDirectory(at: currentPath)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .appSurface(.secondary, padding: 12, cornerRadius: 18)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            } else if let listing {
                Section("Folders") {
                    if let parentPath = listing.parentPath {
                        Button {
                            currentPath = parentPath
                        } label: {
                            Label("Parent folder", systemImage: "arrow.up.left")
                        }
                        .accessibilityIdentifier("workspace-picker-parent")
                    }

                    if filteredEntries.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "No folders found here yet."
                             : "No folders match your search.")
                            .font(.caption)
                            .foregroundStyle(AppVisualStyle.secondaryText)
                    } else {
                        ForEach(filteredEntries) { entry in
                            Button {
                                if entry.isGitRepository {
                                    onSelectWorkspace(entry.path)
                                } else {
                                    currentPath = entry.path
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.isGitRepository ? "arrow.triangle.branch" : "folder")
                                        .foregroundStyle(
                                            entry.isGitRepository
                                                ? AnyShapeStyle(Color.green)
                                                : AnyShapeStyle(AppVisualStyle.secondaryText)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(.subheadline.weight(.medium))
                                        Text(entry.path)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(AppVisualStyle.secondaryText)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    AppMetadataChip(
                                        title: entry.isGitRepository ? "Select" : "Open",
                                        tint: entry.isGitRepository ? .green : .secondary
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workspace-entry-\(entry.name)")
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(shellBackground)
        .searchable(text: $searchText, prompt: "Search folders")
        .task(id: currentPath ?? initialPath ?? "root") {
            await loadDirectory(at: currentPath ?? initialPath)
        }
    }

    private var filteredEntries: [WorkspaceDirectoryEntry] {
        guard let listing else {
            return []
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return listing.entries
        }

        return listing.entries.filter { entry in
            entry.name.lowercased().contains(query) || entry.path.lowercased().contains(query)
        }
    }

    private func loadDirectory(at path: String?) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let listing = try await model.browseWorkspaceDirectories(at: path)
            self.listing = listing
            self.currentPath = listing.currentPath
            self.errorSummary = nil
        } catch {
            self.errorSummary = error.localizedDescription
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
