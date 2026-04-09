import Foundation
import Persistence
import SharedModels
import SyncEngine

struct AppStatePersistencePersistResult: Sendable {
    let snapshot: MachineDirectorySnapshot
    let syncSnapshot: SyncSnapshot
}

struct AppStatePersistenceCoordinator: Sendable {
    let metadataStore: JSONMetadataStore
    let syncCoordinator: any SyncCoordinator
    let runtimeConfiguration: AppRuntimeConfiguration
    let environment: [String: String]

    init(
        metadataStore: JSONMetadataStore,
        syncCoordinator: any SyncCoordinator,
        runtimeConfiguration: AppRuntimeConfiguration,
        environment: [String: String]
    ) {
        self.metadataStore = metadataStore
        self.syncCoordinator = syncCoordinator
        self.runtimeConfiguration = runtimeConfiguration
        self.environment = environment
    }

    func metadataStoreURL() -> URL {
        if let isolatedUITestURL = isolatedUITestStoreDirectoryURL() {
            return isolatedUITestURL.appendingPathComponent("machine-directory.json")
        }
        return runtimeConfiguration.paths.metadataStoreURL
    }

    func syncMirrorStoreURL() -> URL {
        if let isolatedUITestURL = isolatedUITestStoreDirectoryURL() {
            return isolatedUITestURL.appendingPathComponent("cotg-sync-mirror.json")
        }
        return runtimeConfiguration.paths.syncMirrorURL
    }

    func loadSnapshot() async throws -> MachineDirectorySnapshot {
        try await metadataStore.load(from: metadataStoreURL())
    }

    func saveSnapshot(_ snapshot: MachineDirectorySnapshot) async throws {
        try await metadataStore.save(snapshot, to: metadataStoreURL())
    }

    func saveSnapshotSynchronously(_ snapshot: MachineDirectorySnapshot) throws {
        try metadataStore.saveSynchronously(snapshot, to: metadataStoreURL())
    }

    func mergeAndSaveSnapshotSynchronously(_ snapshot: MachineDirectorySnapshot) throws -> MachineDirectorySnapshot {
        try metadataStore.mergeAndSaveSynchronously(snapshot, to: metadataStoreURL())
    }

    func mergeAndStage(_ snapshot: MachineDirectorySnapshot) async throws -> AppStatePersistencePersistResult {
        let mergedSnapshot = try await metadataStore.mergeAndSave(snapshot, to: metadataStoreURL())
        let stagedSnapshot = try await syncCoordinator.stage(mergedSnapshot)
        let syncSnapshot = await syncCoordinator.currentSnapshot()
        return AppStatePersistencePersistResult(
            snapshot: stagedSnapshot,
            syncSnapshot: syncSnapshot
        )
    }

    private func isolatedUITestStoreDirectoryURL() -> URL? {
        AppRuntimePaths.uiTestIsolationDirectory(environment: environment)
    }
}
