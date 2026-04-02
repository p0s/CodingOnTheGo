import Foundation
import SharedModels

public protocol MetadataStore: Sendable {
    func load(from url: URL) async throws -> MachineDirectorySnapshot
    func save(_ snapshot: MachineDirectorySnapshot, to url: URL) async throws
    func mergeAndSave(_ incoming: MachineDirectorySnapshot, to url: URL) async throws -> MachineDirectorySnapshot
}

public actor JSONMetadataStore: MetadataStore {
    public init() {}

    public func load(from url: URL) async throws -> MachineDirectorySnapshot {
        try Self.loadSynchronously(from: url)
    }

    public func save(_ snapshot: MachineDirectorySnapshot, to url: URL) async throws {
        try saveSynchronously(snapshot, to: url)
    }

    public func mergeAndSave(_ incoming: MachineDirectorySnapshot, to url: URL) async throws -> MachineDirectorySnapshot {
        try mergeAndSaveSynchronously(incoming, to: url)
    }

    public nonisolated func mergeAndSaveSynchronously(
        _ incoming: MachineDirectorySnapshot,
        to url: URL
    ) throws -> MachineDirectorySnapshot {
        let snapshot: MachineDirectorySnapshot
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Self.loadSynchronously(from: url)
            snapshot = Self.mergedSnapshot(existing: existing, incoming: incoming)
        } else {
            snapshot = incoming
        }

        try saveSynchronously(snapshot, to: url)
        return snapshot
    }

    private static func mergedSnapshot(
        existing: MachineDirectorySnapshot,
        incoming: MachineDirectorySnapshot
    ) -> MachineDirectorySnapshot {
        MachineDirectorySnapshot(
            machines: incoming.machines,
            tailnetProfiles: incoming.tailnetProfiles,
            recentSessions: mergeRecentSessions(
                existing: existing.recentSessions,
                incoming: incoming.recentSessions
            ),
            hostThreadCatalog: mergeHostThreadCatalog(
                existing: existing.hostThreadCatalog,
                incoming: incoming.hostThreadCatalog
            ),
            preferences: incoming.preferences
        )
    }

    private static func mergeRecentSessions(existing: [SessionRecord], incoming: [SessionRecord]) -> [SessionRecord] {
        var merged: [String: SessionRecord] = [:]

        for session in existing {
            merged[sessionStorageKey(for: session)] = session
        }
        for session in incoming {
            merged[sessionStorageKey(for: session)] = session
        }

        return merged.values.sorted { lhs, rhs in
            if lhs.machineID != rhs.machineID {
                return lhs.machineID.uuidString < rhs.machineID.uuidString
            }
            return (lhs.sceneID ?? "") < (rhs.sceneID ?? "")
        }
    }

    private static func mergeHostThreadCatalog(
        existing: [HostThreadCatalogEntry],
        incoming: [HostThreadCatalogEntry]
    ) -> [HostThreadCatalogEntry] {
        var merged: [String: HostThreadCatalogEntry] = [:]

        for entry in existing {
            merged[hostThreadCatalogStorageKey(for: entry)] = entry
        }

        for entry in incoming {
            let key = hostThreadCatalogStorageKey(for: entry)
            if let current = merged[key] {
                merged[key] = current.merged(with: entry)
                continue
            }
            merged[key] = entry
        }

        return merged.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func sessionStorageKey(for session: SessionRecord) -> String {
        session.id.uuidString
    }

    private static func hostThreadCatalogStorageKey(for entry: HostThreadCatalogEntry) -> String {
        "\(entry.machineID.uuidString)::\(entry.id)"
    }

    private static func loadSynchronously(from url: URL) throws -> MachineDirectorySnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MachineDirectorySnapshot.self, from: data)
    }

    public nonisolated func saveSynchronously(_ snapshot: MachineDirectorySnapshot, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
