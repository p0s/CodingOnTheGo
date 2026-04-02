import Foundation
import Persistence
import SharedModels

public enum SyncStatus: String, Sendable {
    case idle
    case syncing
    case blocked
}

public struct SyncBlocker: Hashable, Sendable {
    public var reason: String
    public var remediation: String

    public init(reason: String, remediation: String) {
        self.reason = reason
        self.remediation = remediation
    }
}

public struct SyncSnapshot: Hashable, Sendable {
    public var status: SyncStatus
    public var blocker: SyncBlocker?
    public var lastSyncedAt: Date?
    public var projectedRecordCount: Int
    public var secretBoundaryNote: String?

    public init(
        status: SyncStatus,
        blocker: SyncBlocker? = nil,
        lastSyncedAt: Date? = nil,
        projectedRecordCount: Int = 0,
        secretBoundaryNote: String? = nil
    ) {
        self.status = status
        self.blocker = blocker
        self.lastSyncedAt = lastSyncedAt
        self.projectedRecordCount = projectedRecordCount
        self.secretBoundaryNote = secretBoundaryNote
    }
}

public protocol SyncCoordinator: Sendable {
    func currentSnapshot() async -> SyncSnapshot
    func stage(_ snapshot: MachineDirectorySnapshot) async throws -> MachineDirectorySnapshot
}

public actor FileBackedSyncCoordinator: SyncCoordinator {
    private let metadataStore = JSONMetadataStore()
    private let mirrorURL: URL
    private let mergeEngine = SyncMergeEngine()
    private var snapshot = SyncSnapshot(status: .idle)

    public init(mirrorURL: URL? = nil) {
        if let mirrorURL {
            self.mirrorURL = mirrorURL
        } else {
            self.mirrorURL = AppRuntimePaths.applicationSupport().syncMirrorURL
        }
    }

    public func currentSnapshot() async -> SyncSnapshot {
        snapshot
    }

    public func stage(_ directorySnapshot: MachineDirectorySnapshot) async throws -> MachineDirectorySnapshot {
        snapshot = SyncSnapshot(status: .syncing, blocker: nil, lastSyncedAt: snapshot.lastSyncedAt)
        let mirroredSnapshot = (try? await metadataStore.load(from: mirrorURL)) ?? directorySnapshot
        let mergedSnapshot = mergeEngine.merge(local: directorySnapshot, remote: mirroredSnapshot)
        let projection = mergeEngine.project(mergedSnapshot)
        try await metadataStore.save(mergedSnapshot, to: mirrorURL)
        snapshot = SyncSnapshot(
            status: .idle,
            blocker: nil,
            lastSyncedAt: .now,
            projectedRecordCount: projection.records.count,
            secretBoundaryNote: projection.secretBoundaryNote
        )
        return mergedSnapshot
    }
}

public actor NoopCloudKitSyncCoordinator: SyncCoordinator {
    private var snapshot = SyncSnapshot(
        status: .idle,
        blocker: nil,
        lastSyncedAt: .now,
        projectedRecordCount: 0,
        secretBoundaryNote: "Cross-device sync is disabled in this build."
    )

    public init() {}

    public func currentSnapshot() async -> SyncSnapshot {
        snapshot
    }

    public func stage(_ snapshot: MachineDirectorySnapshot) async throws -> MachineDirectorySnapshot {
        self.snapshot = SyncSnapshot(
            status: .idle,
            blocker: nil,
            lastSyncedAt: .now,
            projectedRecordCount: snapshot.machines.count + snapshot.tailnetProfiles.count + snapshot.recentSessions.count + 1,
            secretBoundaryNote: "Cross-device sync is disabled in this build. Secrets remain out-of-band in Keychain."
        )
        return snapshot
    }
}
