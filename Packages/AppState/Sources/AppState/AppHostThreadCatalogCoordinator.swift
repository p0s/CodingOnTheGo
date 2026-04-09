import Foundation
import CodexRPC
import SharedModels

struct AppHostThreadCatalogReplacementResult {
    let hostThreadCatalog: [HostThreadCatalogEntry]
    let recentSessions: [SessionRecord]
}

struct AppHostThreadCatalogPageResult {
    let page: CodexThreadListPage
    let provenanceByThreadID: [String: HostThreadCatalogProvenance]
}

enum AppHostThreadCatalogCoordinator {
    static func repairingMissingWorkspaceRoots(
        in livePage: CodexThreadListPage,
        using workspaceRootsByThreadID: [String: String],
        normalizeWorkspaceRoot: (String?) -> String?
    ) -> AppHostThreadCatalogPageResult {
        let repairedThreadIDs = Set(workspaceRootsByThreadID.keys)
        let repairedPage = CodexThreadListPage(
            threads: livePage.threads.map { thread in
                guard normalizeWorkspaceRoot(thread.cwd) == nil,
                      let workspaceRoot = workspaceRootsByThreadID[thread.id] else {
                    return thread
                }

                var repaired = thread
                repaired.cwd = workspaceRoot
                return repaired
            },
            nextCursor: livePage.nextCursor
        )
        let provenanceByThreadID = Dictionary(
            uniqueKeysWithValues: repairedPage.threads.map { thread in
                (
                    thread.id,
                    repairedThreadIDs.contains(thread.id)
                        ? HostThreadCatalogProvenance.sqliteRepaired
                        : HostThreadCatalogProvenance.liveAppServer
                )
            }
        )
        return AppHostThreadCatalogPageResult(
            page: repairedPage,
            provenanceByThreadID: provenanceByThreadID
        )
    }

    static func workspaceRootLookup(
        for threads: [CodexThreadSummary],
        matching threadIDs: Set<String>,
        normalizeWorkspaceRoot: (String?) -> String?
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: threads.compactMap { thread in
                guard threadIDs.contains(thread.id),
                      let workspaceRoot = normalizeWorkspaceRoot(thread.cwd) else {
                    return nil
                }
                return (thread.id, workspaceRoot)
            }
        )
    }

    static func entry(
        from summary: CodexThreadSummary,
        machineID: MachineRecord.ID,
        recentSessions: [SessionRecord],
        hostThreadCatalog: [HostThreadCatalogEntry],
        normalizeWorkspaceRoot: (String?) -> String?,
        provenance: HostThreadCatalogProvenance = .cachedHostCatalog,
        observedAt: Date = .now
    ) -> HostThreadCatalogEntry? {
        let matchedSession = recentSessions.first(where: {
            $0.machineID == machineID && $0.threadID == summary.id
        })
        let cachedEntry = hostThreadCatalog.first(where: {
            $0.machineID == machineID && $0.id == summary.id
        })
        let workspaceRoot = normalizeWorkspaceRoot(summary.cwd)
            ?? matchedSession.flatMap { normalizeWorkspaceRoot($0.workspaceRoot) }
            ?? cachedEntry?.workspaceRoot

        guard let workspaceRoot else {
            return nil
        }

        return HostThreadCatalogEntry(
            id: summary.id,
            machineID: machineID,
            workspaceRoot: workspaceRoot,
            name: preferredThreadDisplayTitle(
                liveTitle: summary.name,
                persistedTitle: matchedSession?.threadDisplayTitle,
                cachedTitle: cachedEntry?.name
            ),
            preview: summary.preview,
            modelProvider: summary.modelProvider,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            observedAt: observedAt,
            provenance: provenance
        )
    }

    static func entry(
        fromPersistedSession session: SessionRecord,
        normalizeWorkspaceRoot: (String?) -> String?
    ) -> HostThreadCatalogEntry? {
        guard let threadID = session.threadID,
              let workspaceRoot = normalizeWorkspaceRoot(session.workspaceRoot) else {
            return nil
        }

        return HostThreadCatalogEntry(
            id: threadID,
            machineID: session.machineID,
            workspaceRoot: workspaceRoot,
            name: normalizedThreadDisplayTitle(session.threadDisplayTitle),
            preview: "Restored thread",
            modelProvider: session.lastModel ?? "",
            createdAt: session.lastOpenedAt,
            updatedAt: session.lastOpenedAt,
            observedAt: session.lastOpenedAt,
            provenance: .cachedHostCatalog
        )
    }

    static func replacingEntries(
        _ threads: [CodexThreadSummary],
        machine: MachineRecord,
        hostThreadCatalog: [HostThreadCatalogEntry],
        recentSessions: [SessionRecord],
        activeProtocolKind: CodexProtocolKind,
        routeID: RouteRecord.ID?,
        routeKind: MachineRouteKind?,
        bootstrap: BootstrapStrategy,
        normalizeWorkspaceRoot: (String?) -> String?,
        workspaceMode: (String?) -> WorkspaceMode,
        provenanceByThreadID: [String: HostThreadCatalogProvenance],
        observedAt: Date
    ) -> AppHostThreadCatalogReplacementResult {
        let existingEntries = hostThreadCatalog
            .filter { $0.machineID == machine.id }
            .reduce(into: [String: HostThreadCatalogEntry]()) { partialResult, entry in
                if let existing = partialResult[entry.id] {
                    partialResult[entry.id] = existing.merged(with: entry)
                } else {
                    partialResult[entry.id] = entry
                }
            }
        let validEntries = threads.compactMap { thread in
            entry(
                from: thread,
                machineID: machine.id,
                recentSessions: recentSessions,
                hostThreadCatalog: hostThreadCatalog,
                normalizeWorkspaceRoot: normalizeWorkspaceRoot,
                provenance: provenanceByThreadID[thread.id] ?? .liveAppServer,
                observedAt: observedAt
            )
        }.map { entry in
            guard let existing = existingEntries[entry.id] else {
                return entry
            }
            return existing.merged(with: entry)
        }

        var updatedCatalog = hostThreadCatalog.filter { $0.machineID != machine.id }
        updatedCatalog.append(contentsOf: validEntries)
        updatedCatalog.sort(by: { $0.updatedAt > $1.updatedAt })

        var updatedSessions = recentSessions
        for entry in validEntries {
            guard let index = updatedSessions.firstIndex(where: {
                $0.machineID == machine.id && $0.threadID == entry.id
            }) else {
                continue
            }

            if updatedSessions[index].workspaceRoot != entry.workspaceRoot {
                updatedSessions[index].workspaceRoot = entry.workspaceRoot
                updatedSessions[index].lastMode = workspaceMode(entry.workspaceRoot)
            }
            if updatedSessions[index].threadDisplayTitle == nil,
               let threadDisplayTitle = normalizedThreadDisplayTitle(entry.name) {
                updatedSessions[index].threadDisplayTitle = threadDisplayTitle
            }
            if updatedSessions[index].lastOpenedAt < entry.updatedAt {
                updatedSessions[index].lastOpenedAt = entry.updatedAt
            }
            if updatedSessions[index].routeID == nil, let routeID {
                updatedSessions[index].routeID = routeID
            }
            updatedSessions[index].lastKnownProtocol = activeProtocolKind
            updatedSessions[index].lastKnownRouteKind = routeKind
            updatedSessions[index].lastKnownBootstrap = bootstrap
            updatedSessions[index].lastTurn = RecentTurnMetadata(
                turnID: "catalog-\(entry.id)",
                summary: entry.name ?? entry.preview,
                completedAt: entry.updatedAt
            )
        }

        updatedSessions.sort(by: { $0.lastOpenedAt > $1.lastOpenedAt })
        return AppHostThreadCatalogReplacementResult(
            hostThreadCatalog: updatedCatalog,
            recentSessions: updatedSessions
        )
    }

    static func updatingSession(
        _ session: SessionRecord,
        with entry: HostThreadCatalogEntry,
        routeKind: MachineRouteKind?,
        bootstrap: BootstrapStrategy,
        workspaceMode: (String?) -> WorkspaceMode
    ) -> SessionRecord {
        var updated = session
        updated.threadID = entry.id
        updated.unavailableSelectedThreadID = nil
        updated.workspaceRoot = entry.workspaceRoot
        updated.lastMode = workspaceMode(entry.workspaceRoot)
        if updated.threadDisplayTitle == nil,
           let threadDisplayTitle = normalizedThreadDisplayTitle(entry.name) {
            updated.threadDisplayTitle = threadDisplayTitle
        }
        updated.lastOpenedAt = max(updated.lastOpenedAt, entry.updatedAt)
        updated.lastTurn = RecentTurnMetadata(
            turnID: "catalog-\(entry.id)",
            summary: entry.name ?? entry.preview,
            completedAt: entry.updatedAt
        )
        updated.lastKnownRouteKind = routeKind
        updated.lastKnownBootstrap = bootstrap
        return updated
    }

    static func upsertingEntry(
        _ entry: HostThreadCatalogEntry,
        into hostThreadCatalog: [HostThreadCatalogEntry]
    ) -> [HostThreadCatalogEntry] {
        var updatedCatalog = hostThreadCatalog
        if let index = updatedCatalog.firstIndex(where: {
            $0.machineID == entry.machineID && $0.id == entry.id
        }) {
            updatedCatalog[index] = updatedCatalog[index].merged(with: entry)
        } else {
            updatedCatalog.append(entry)
        }

        updatedCatalog.sort(by: { $0.updatedAt > $1.updatedAt })
        return updatedCatalog
    }

    private static func preferredThreadDisplayTitle(
        liveTitle: String?,
        persistedTitle: String?,
        cachedTitle: String?
    ) -> String? {
        normalizedThreadDisplayTitle(persistedTitle)
            ?? normalizedThreadDisplayTitle(cachedTitle)
            ?? normalizedThreadDisplayTitle(liveTitle)
    }

    private static func normalizedThreadDisplayTitle(_ title: String?) -> String? {
        guard let title else {
            return nil
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
