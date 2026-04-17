import AppState
import Foundation
import SharedModels

enum CodexBrowserPresentationStyle: String, CaseIterable, Identifiable {
    case sheet
    case drawer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sheet:
            "Sheet"
        case .drawer:
            "Drawer"
        }
    }
}

struct CodexMachineOption: Identifiable, Hashable {
    let machine: MachineRecord

    var id: MachineRecord.ID { machine.id }
}

struct CodexSessionSummary: Identifiable, Hashable {
    let thread: HostThreadCatalogEntry
    let machine: MachineRecord
    let routeLabel: String
    let repoName: String
    let repoPath: String
    let matchedSessionID: SessionRecord.ID?
    let matchedThreadDisplayTitle: String?
    let matchedModel: String?
    let parentThreadID: String?
    let workspaceMode: WorkspaceMode
    let isArchived: Bool
    let isActive: Bool

    var id: String {
        "\(thread.machineID.uuidString)::\(thread.id)"
    }

    var projectName: String {
        repoName
    }

    var projectPath: String {
        repoPath
    }

    var threadTitle: String {
        if let matchedThreadDisplayTitle = matchedThreadDisplayTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !matchedThreadDisplayTitle.isEmpty {
            return matchedThreadDisplayTitle
        }

        if let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        let preview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "Untitled thread" : preview
    }

    var threadPreview: String {
        thread.preview
    }

    var threadStatusLabel: String {
        if isArchived {
            return "Archived thread"
        }
        if isActive {
            return "Active thread"
        }
        if isFork {
            return "Forked thread"
        }
        return "Saved thread"
    }

    var threadUpdatedAt: Date {
        thread.updatedAt
    }

    var modelLabel: String {
        matchedModel ?? thread.modelProvider
    }

    var isFork: Bool {
        parentThreadID != nil
    }

    var workspaceModeLabel: String {
        switch workspaceMode {
        case .local:
            return "Local"
        case .worktree:
            return "Worktree"
        }
    }
}

struct CodexRepoGroup: Identifiable, Hashable {
    let machine: MachineRecord
    let repoName: String
    let repoPath: String
    let sessions: [CodexSessionSummary]
    let totalThreadCount: Int
    let archivedThreadCount: Int
    let forkThreadCount: Int
    let activeThreadCount: Int

    var id: String {
        "\(machine.id.uuidString)::\(repoPath)"
    }

    var projectName: String {
        repoName
    }
}

@MainActor
enum CodexPresentation {
    static func showsMachineContext(for model: AppModel, includeAllMachines: Bool) -> Bool {
        includeAllMachines || model.machines.count > 1
    }

    static func machineOptions(for model: AppModel, includeAllMachines: Bool) -> [CodexMachineOption] {
        visibleMachines(for: model, includeAllMachines: includeAllMachines)
            .map(CodexMachineOption.init(machine:))
    }

    static func recentSessionSummaries(for model: AppModel, includeAllMachines: Bool) -> [CodexSessionSummary] {
        let visibleMachines = visibleMachineLookup(for: model, includeAllMachines: includeAllMachines)
        let sessionsByThreadKey = sessionLookupByThread(for: model)
        let activeThreadKey = activeThreadKey(for: model)

        return model.hostThreadCatalog
            .filter { visibleMachines[$0.machineID] != nil }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .compactMap { thread in
                guard let machine = visibleMachines[thread.machineID] else {
                    return nil
                }
                return makeSummary(
                    thread: thread,
                    machine: machine,
                    sessionsByThreadKey: sessionsByThreadKey,
                    activeThreadKey: activeThreadKey
                )
            }
    }

    static func repoGroups(for model: AppModel, includeAllMachines: Bool) -> [CodexRepoGroup] {
        let visibleMachines = visibleMachineLookup(for: model, includeAllMachines: includeAllMachines)
        let sessionsByThreadKey = sessionLookupByThread(for: model)
        let activeThreadKey = activeThreadKey(for: model)
        let groupedThreads = Dictionary(grouping: model.hostThreadCatalog.filter { thread in
            visibleMachines[thread.machineID] != nil
        }) { thread in
            RepoGroupKey(
                machineID: thread.machineID,
                repoPath: thread.workspaceRoot
            )
        }

        var repoGroups: [CodexRepoGroup] = []
        for (key, threads) in groupedThreads {
            guard let machine = visibleMachines[key.machineID] else {
                continue
            }

            let summaries = threads
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .compactMap { thread in
                    makeSummary(
                        thread: thread,
                        machine: machine,
                        sessionsByThreadKey: sessionsByThreadKey,
                        activeThreadKey: activeThreadKey
                    )
                }
            let visibleSummaries = summaries.filter { !$0.isArchived }

            repoGroups.append(CodexRepoGroup(
                machine: machine,
                repoName: repoName(forPath: key.repoPath),
                repoPath: key.repoPath,
                sessions: visibleSummaries,
                totalThreadCount: summaries.count,
                archivedThreadCount: summaries.filter(\.isArchived).count,
                forkThreadCount: summaries.filter(\.isFork).count,
                activeThreadCount: summaries.filter(\.isActive).count
            ))
        }

        let existingRepoKeys = Set(repoGroups.map { group in
            RepoGroupKey(machineID: group.machine.id, repoPath: group.repoPath)
        })
        if let currentWorkspaceGroup = currentWorkspaceRepoGroup(
            for: model,
            visibleMachines: visibleMachines,
            existingRepoKeys: existingRepoKeys
        ) {
            repoGroups.append(currentWorkspaceGroup)
        }

        let currentWorkspaceKey = currentWorkspaceRepoKey(for: model)
        return repoGroups.sorted { lhs, rhs in
            let lhsIsCurrentWorkspace = lhs.matches(currentWorkspaceKey)
            let rhsIsCurrentWorkspace = rhs.matches(currentWorkspaceKey)
            if lhsIsCurrentWorkspace != rhsIsCurrentWorkspace {
                return lhsIsCurrentWorkspace
            }

            let lhsUpdatedAt = lhs.sessions.first?.threadUpdatedAt ?? .distantPast
            let rhsUpdatedAt = rhs.sessions.first?.threadUpdatedAt ?? .distantPast
            if lhsUpdatedAt != rhsUpdatedAt {
                return lhsUpdatedAt > rhsUpdatedAt
            }

            return lhs.repoPath < rhs.repoPath
        }
    }

    private static func visibleMachines(for model: AppModel, includeAllMachines: Bool) -> [MachineRecord] {
        if includeAllMachines {
            return model.machines
        }

        return [model.selectedMachine].compactMap { $0 }
    }

    private static func visibleMachineLookup(for model: AppModel, includeAllMachines: Bool) -> [MachineRecord.ID: MachineRecord] {
        Dictionary(uniqueKeysWithValues: visibleMachines(for: model, includeAllMachines: includeAllMachines).map { ($0.id, $0) })
    }

    private static func sessionLookupByThread(for model: AppModel) -> [String: SessionRecord] {
        var sessionsByThread: [String: SessionRecord] = [:]

        for session in model.recentSessions {
            guard let threadID = session.threadID else {
                continue
            }

            let key = threadKey(machineID: session.machineID, threadID: threadID)
            if let existing = sessionsByThread[key], existing.lastOpenedAt >= session.lastOpenedAt {
                continue
            }
            sessionsByThread[key] = session
        }

        return sessionsByThread
    }

    private static func makeSummary(
        thread: HostThreadCatalogEntry,
        machine: MachineRecord,
        sessionsByThreadKey: [String: SessionRecord],
        activeThreadKey: String?
    ) -> CodexSessionSummary {
        let repoPath = thread.workspaceRoot
        let matchedSession = sessionsByThreadKey[threadKey(machineID: thread.machineID, threadID: thread.id)]
        return CodexSessionSummary(
            thread: thread,
            machine: machine,
            routeLabel: machine.route(id: matchedSession?.routeID)?.label ?? machine.preferredRoute?.label ?? "Best route",
            repoName: repoName(forPath: repoPath, fallback: machine.alias),
            repoPath: repoPath,
            matchedSessionID: matchedSession?.id,
            matchedThreadDisplayTitle: matchedSession?.threadDisplayTitle,
            matchedModel: matchedSession?.lastModel,
            parentThreadID: matchedSession?.parentThreadID,
            workspaceMode: matchedSession?.lastMode ?? workspaceMode(for: repoPath),
            isArchived: matchedSession?.isArchived ?? false,
            isActive: activeThreadKey == threadKey(machineID: thread.machineID, threadID: thread.id)
        )
    }

    private static func repoName(forPath path: String, fallback: String = "Project") -> String {
        path
            .split(separator: "/")
            .last
            .map(String.init)
            ?? fallback
    }

    private static func normalizedRepoPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "/" else {
            return nil
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    private static func workspaceMode(for workspaceRoot: String) -> WorkspaceMode {
        let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        return workspaceURL.deletingLastPathComponent().lastPathComponent.hasSuffix("-worktrees")
            ? .worktree
            : .local
    }

    private static func currentWorkspaceRepoKey(for model: AppModel) -> RepoGroupKey? {
        let machineID = model.activeSession?.machineID ?? model.selectedMachineID
        let workspaceRoot = normalizedRepoPath(model.browserWorkspaceRootHint)
        guard let machineID,
              let workspaceRoot else {
            return nil
        }
        return RepoGroupKey(machineID: machineID, repoPath: workspaceRoot)
    }

    private static func currentWorkspaceRepoGroup(
        for model: AppModel,
        visibleMachines: [MachineRecord.ID: MachineRecord],
        existingRepoKeys: Set<RepoGroupKey>
    ) -> CodexRepoGroup? {
        guard let currentWorkspaceKey = currentWorkspaceRepoKey(for: model),
              let machine = visibleMachines[currentWorkspaceKey.machineID],
              !existingRepoKeys.contains(currentWorkspaceKey) else {
            return nil
        }

        return CodexRepoGroup(
            machine: machine,
            repoName: repoName(forPath: currentWorkspaceKey.repoPath, fallback: machine.alias),
            repoPath: currentWorkspaceKey.repoPath,
            sessions: [],
            totalThreadCount: 0,
            archivedThreadCount: 0,
            forkThreadCount: 0,
            activeThreadCount: 0
        )
    }

    private static func activeThreadKey(for model: AppModel) -> String? {
        guard let activeSession = model.activeSession,
              let threadID = activeSession.threadID else {
            return nil
        }
        return threadKey(machineID: activeSession.machineID, threadID: threadID)
    }

    private static func threadKey(machineID: MachineRecord.ID, threadID: String) -> String {
        "\(machineID.uuidString)::\(threadID)"
    }
}

private struct RepoGroupKey: Hashable {
    let machineID: MachineRecord.ID
    let repoPath: String
}

private extension CodexRepoGroup {
    func matches(_ key: RepoGroupKey?) -> Bool {
        guard let key else {
            return false
        }
        return machine.id == key.machineID && repoPath == key.repoPath
    }
}
