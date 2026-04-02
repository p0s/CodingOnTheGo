import Foundation
import Persistence
import SharedModels
#if canImport(CloudKit)
import CloudKit
#endif

public enum SyncCoordinatorFactory {
    public static func makeDefault(
        configuration: AppRuntimeConfiguration = .localOnly()
    ) -> any SyncCoordinator {
        switch configuration.syncBehavior {
        case .localOnly:
            return NoopCloudKitSyncCoordinator()
        case let .fileMirror(url):
            return FileBackedSyncCoordinator(mirrorURL: url)
        case let .cloudKit(containerIdentifier):
            #if canImport(CloudKit)
            return CloudKitSyncCoordinator(containerIdentifier: containerIdentifier)
            #else
            return NoopCloudKitSyncCoordinator()
            #endif
        }
    }

    static func isRunningUnderTests(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> Bool {
        if environment["UI_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        if bundle.bundlePath.hasSuffix(".xctest") {
            return true
        }

        if let executablePath = bundle.executablePath,
           executablePath.contains("xctest") {
            return true
        }

        let processName = processInfo.processName.lowercased()
        return processName == "xctest" || processName.contains("xctest")
    }
}

public actor CloudKitSyncCoordinator: SyncCoordinator {
    private let mergeEngine = SyncMergeEngine()
    private let materializer = SyncRecordMaterializer()
    private let containerIdentifier: String?
    private var snapshot = SyncSnapshot(
        status: .blocked,
        blocker: SyncBlocker(
            reason: "CloudKit sync has not been authenticated in this environment.",
            remediation: "Sign into iCloud and configure CKSyncEngine entitlements to enable cross-device sync."
        )
    )

    #if canImport(CloudKit)
    private var remoteRecords: [String: SyncRecord] = [:]
    private var outboundRecords: [String: SyncRecord] = [:]
    private var lastProjectedRecordIDs: Set<String> = []
    private var remoteSnapshot = MachineDirectorySnapshot(
        machines: [],
        tailnetProfiles: [],
        recentSessions: [],
        preferences: UserPreferencesSnapshot()
    )
    private var stateSerialization: CKSyncEngine.State.Serialization?
    private var syncEngine: CKSyncEngine?
    private var delegateBridge: CloudKitSyncDelegateBridge?
    #endif

    public init(containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
    }

    public func currentSnapshot() async -> SyncSnapshot {
        if snapshot.lastSyncedAt == nil {
            snapshot = await availabilitySnapshot()
        }
        return snapshot
    }

    public func stage(_ directorySnapshot: MachineDirectorySnapshot) async throws -> MachineDirectorySnapshot {
        let mergedSnapshot = mergeEngine.merge(local: directorySnapshot, remote: currentRemoteSnapshot())
        let projection = mergeEngine.project(mergedSnapshot)
        let availability = await availabilitySnapshot()

        guard availability.status != .blocked else {
            snapshot = SyncSnapshot(
                status: .blocked,
                blocker: availability.blocker,
                lastSyncedAt: snapshot.lastSyncedAt,
                projectedRecordCount: projection.records.count,
                secretBoundaryNote: projection.secretBoundaryNote
            )
            return mergedSnapshot
        }

        snapshot = SyncSnapshot(
            status: .syncing,
            blocker: nil,
            lastSyncedAt: snapshot.lastSyncedAt,
            projectedRecordCount: projection.records.count,
            secretBoundaryNote: projection.secretBoundaryNote
        )

        #if canImport(CloudKit)
        do {
            let engine = try makeSyncEngine()
            queuePendingChanges(projection.records, syncEngine: engine)
            if #available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
                try await engine.sendChanges(
                    CKSyncEngine.SendChangesOptions(scope: .zoneIDs([Self.zoneID]))
                )
                try await engine.fetchChanges(
                    CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([Self.zoneID]))
                )
            }

            let mergedAfterFetch = mergeEngine.merge(local: directorySnapshot, remote: currentRemoteSnapshot())
            let syncedProjection = mergeEngine.project(mergedAfterFetch)
            snapshot = SyncSnapshot(
                status: .idle,
                blocker: nil,
                lastSyncedAt: .now,
                projectedRecordCount: syncedProjection.records.count,
                secretBoundaryNote: syncedProjection.secretBoundaryNote
            )
            return mergedAfterFetch
        } catch {
            snapshot = blockedSnapshot(
                reason: "CloudKit sync failed.",
                remediation: remediation(for: error),
                projectedRecordCount: projection.records.count,
                secretBoundaryNote: projection.secretBoundaryNote
            )
            return mergedSnapshot
        }
        #else
        snapshot = blockedSnapshot(
            reason: "CloudKit is unavailable on this build.",
            remediation: "Build on Apple platforms with CloudKit and CKSyncEngine support to enable cross-device sync.",
            projectedRecordCount: projection.records.count,
            secretBoundaryNote: projection.secretBoundaryNote
        )
        return mergedSnapshot
        #endif
    }

    private func currentRemoteSnapshot() -> MachineDirectorySnapshot {
        #if canImport(CloudKit)
        remoteSnapshot
        #else
        Self.emptySnapshot
        #endif
    }

    private func availabilitySnapshot() async -> SyncSnapshot {
        #if canImport(CloudKit)
        guard let container = makeContainer() else {
            return blockedSnapshot(
                reason: "CloudKit is unavailable in this process.",
                remediation: "Run inside the signed app target or provide COTG_CLOUDKIT_CONTAINER_ID with valid iCloud entitlements."
            )
        }

        guard #available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) else {
            return blockedSnapshot(
                reason: "CKSyncEngine requires a newer Apple platform runtime.",
                remediation: "Run on iOS 17+, iPadOS 17+, or macOS 14+ to enable CloudKit sync."
            )
        }

        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                return SyncSnapshot(
                    status: .idle,
                    blocker: nil,
                    lastSyncedAt: snapshot.lastSyncedAt,
                    projectedRecordCount: snapshot.projectedRecordCount,
                    secretBoundaryNote: snapshot.secretBoundaryNote ?? "Secrets remain out-of-band in Keychain."
                )
            case .noAccount:
                return blockedSnapshot(
                    reason: "iCloud is not signed in on this device.",
                    remediation: "Sign into iCloud and enable the app's CloudKit entitlements to sync machines and routes."
                )
            case .restricted:
                return blockedSnapshot(
                    reason: "CloudKit is restricted on this device.",
                    remediation: "Review Screen Time, MDM, or system restrictions for iCloud Drive and CloudKit."
                )
            case .temporarilyUnavailable:
                return blockedSnapshot(
                    reason: "CloudKit is temporarily unavailable.",
                    remediation: "Check network reachability and try syncing again when iCloud is reachable."
                )
            case .couldNotDetermine:
                return blockedSnapshot(
                    reason: "CloudKit account status could not be determined.",
                    remediation: "Confirm the app is signed with iCloud entitlements and that the device can reach iCloud."
                )
            @unknown default:
                return blockedSnapshot(
                    reason: "CloudKit reported an unknown account state.",
                    remediation: "Verify the app's iCloud entitlements and the current iCloud account state."
                )
            }
        } catch {
            return blockedSnapshot(
                reason: "CloudKit availability check failed.",
                remediation: remediation(for: error)
            )
        }
        #else
        return blockedSnapshot(
            reason: "CloudKit is unavailable on this build.",
            remediation: "Build on Apple platforms with CloudKit support to enable cross-device sync."
        )
        #endif
    }

    private func blockedSnapshot(
        reason: String,
        remediation: String,
        projectedRecordCount: Int = 0,
        secretBoundaryNote: String? = "Secrets remain out-of-band in Keychain."
    ) -> SyncSnapshot {
        SyncSnapshot(
            status: .blocked,
            blocker: SyncBlocker(reason: reason, remediation: remediation),
            lastSyncedAt: snapshot.lastSyncedAt,
            projectedRecordCount: projectedRecordCount,
            secretBoundaryNote: secretBoundaryNote
        )
    }

    #if canImport(CloudKit)
    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func makeSyncEngine() throws -> CKSyncEngine {
        if let syncEngine {
            return syncEngine
        }

        guard let container = makeContainer() else {
            throw SyncRuntimeError.unavailable("CloudKit container is unavailable in this process.")
        }

        let delegateBridge = CloudKitSyncDelegateBridge(owner: self)
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: delegateBridge
        )
        configuration.automaticallySync = false
        configuration.subscriptionID = "com.example.codingonthego.sync"

        let syncEngine = CKSyncEngine(configuration)
        self.syncEngine = syncEngine
        self.delegateBridge = delegateBridge
        return syncEngine
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    fileprivate func handleSyncEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            stateSerialization = update.stateSerialization
        case let .accountChange(change):
            handleAccountChange(change)
        case let .fetchedDatabaseChanges(changes):
            handleFetchedDatabaseChanges(changes)
        case let .fetchedRecordZoneChanges(changes):
            applyFetchedRecordZoneChanges(changes)
        case let .sentDatabaseChanges(changes):
            handleSentDatabaseChanges(changes, syncEngine: syncEngine)
        case let .sentRecordZoneChanges(changes):
            handleSentRecordZoneChanges(changes, syncEngine: syncEngine)
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    fileprivate func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }

        guard !pendingChanges.isEmpty else {
            return nil
        }

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for pendingChange in pendingChanges {
            switch pendingChange {
            case let .saveRecord(recordID):
                guard let logicalID = Self.logicalID(from: recordID),
                      let record = outboundRecords[logicalID].map(cloudKitRecord(from:)) else {
                    continue
                }
                recordsToSave.append(record)
            case let .deleteRecord(recordID):
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else {
            return nil
        }

        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            atomicByZone: false
        )
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    fileprivate func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([Self.zoneID]))
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func queuePendingChanges(_ records: [SyncRecord], syncEngine: CKSyncEngine) {
        let nextRecordIDs = Set(records.map(\.id))
        outboundRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
        )

        let recordSaves = records.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID(for: $0.id)) }
        let recordDeletes = lastProjectedRecordIDs.subtracting(nextRecordIDs).map {
            CKSyncEngine.PendingRecordZoneChange.deleteRecord(Self.recordID(for: $0))
        }

        syncEngine.state.add(pendingRecordZoneChanges: recordSaves + recordDeletes)
        lastProjectedRecordIDs = nextRecordIDs
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        remoteRecords.removeAll()
        remoteSnapshot = Self.emptySnapshot

        switch change.changeType {
        case .signOut, .switchAccounts:
            snapshot = blockedSnapshot(
                reason: "The active iCloud account changed.",
                remediation: "Sign back into the intended iCloud account and retry sync."
            )
        case .signIn:
            break
        @unknown default:
            break
        }
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
            remoteRecords.removeAll()
            remoteSnapshot = Self.emptySnapshot
        }
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func applyFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            guard modification.record.recordID.zoneID == Self.zoneID,
                  let record = syncRecord(from: modification.record) else {
                continue
            }
            remoteRecords[record.id] = record
        }

        for deletion in changes.deletions where deletion.recordID.zoneID == Self.zoneID {
            guard let logicalID = Self.logicalID(from: deletion.recordID) else {
                continue
            }
            remoteRecords.removeValue(forKey: logicalID)
        }

        remoteSnapshot = materializer.materialize(records: Array(remoteRecords.values))
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func handleSentDatabaseChanges(
        _ changes: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        let successfulChanges = changes.savedZones.map(CKSyncEngine.PendingDatabaseChange.saveZone)
            + changes.deletedZoneIDs.map(CKSyncEngine.PendingDatabaseChange.deleteZone)
        syncEngine.state.remove(pendingDatabaseChanges: successfulChanges)

        if let error = changes.failedZoneSaves.first?.error ?? changes.failedZoneDeletes.values.first {
            snapshot = blockedSnapshot(
                reason: "CloudKit zone sync failed.",
                remediation: remediation(for: error),
                projectedRecordCount: snapshot.projectedRecordCount,
                secretBoundaryNote: snapshot.secretBoundaryNote
            )
        }
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private func handleSentRecordZoneChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        let successfulChanges = changes.savedRecords.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID) }
            + changes.deletedRecordIDs.map(CKSyncEngine.PendingRecordZoneChange.deleteRecord)
        syncEngine.state.remove(pendingRecordZoneChanges: successfulChanges)

        if let error = changes.failedRecordSaves.first?.error ?? changes.failedRecordDeletes.values.first {
            snapshot = blockedSnapshot(
                reason: "CloudKit record sync failed.",
                remediation: remediation(for: error),
                projectedRecordCount: snapshot.projectedRecordCount,
                secretBoundaryNote: snapshot.secretBoundaryNote
            )
        }
    }

    private func cloudKitRecord(from record: SyncRecord) -> CKRecord {
        let cloudKitRecord = CKRecord(recordType: Self.recordType, recordID: Self.recordID(for: record.id))
        cloudKitRecord["logicalID"] = record.id as NSString
        cloudKitRecord["kind"] = record.kind.rawValue as NSString
        cloudKitRecord["sensitivity"] = record.sensitivity.rawValue as NSString
        cloudKitRecord["updatedAt"] = record.updatedAt as NSDate
        cloudKitRecord["payload"] = record.encodedPayload as NSData
        return cloudKitRecord
    }

    private func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard record.recordType == Self.recordType else {
            return nil
        }

        let logicalID = (record["logicalID"] as? String) ?? Self.logicalID(from: record.recordID)
        guard let logicalID,
              let kindString = record["kind"] as? String,
              let kind = SyncRecordKind(rawValue: kindString),
              let payload = record["payload"] as? Data else {
            return nil
        }

        let sensitivity = (record["sensitivity"] as? String)
            .flatMap(SyncRecordSensitivity.init(rawValue:))
            ?? .durablePreferenceState
        let updatedAt = (record["updatedAt"] as? Date)
            ?? (record["updatedAt"] as? NSDate).map { $0 as Date }
            ?? .now

        return SyncRecord(
            id: logicalID,
            kind: kind,
            sensitivity: sensitivity,
            encodedPayload: payload,
            updatedAt: updatedAt
        )
    }

    private func remediation(for error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return "Sign into iCloud on the device and ensure the app has CloudKit entitlements."
            case .permissionFailure:
                return "The build lacks usable CloudKit entitlements or container access for this account."
            case .networkUnavailable, .networkFailure:
                return "Restore network access to iCloud and retry sync."
            case .quotaExceeded:
                return "Reduce stored sync payloads or free space in the iCloud private database."
            default:
                break
            }
        }

        return error.localizedDescription
    }

    private func makeContainer() -> CKContainer? {
        if SyncCoordinatorFactory.isRunningUnderTests() {
            return nil
        }

        if let containerIdentifier,
           !containerIdentifier.isEmpty {
            return CKContainer(identifier: containerIdentifier)
        }

        return CKContainer.default()
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private static let zoneID = CKRecordZone.ID(
        zoneName: "MachineDirectory",
        ownerName: CKCurrentUserDefaultName
    )
    private static let recordType = "SyncRecord"
    private static let emptySnapshot = MachineDirectorySnapshot(
        machines: [],
        tailnetProfiles: [],
        recentSessions: [],
        preferences: UserPreferencesSnapshot()
    )

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private static func recordID(for logicalID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: sanitizedRecordName(logicalID), zoneID: zoneID)
    }

    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    private static func logicalID(from recordID: CKRecord.ID) -> String? {
        guard recordID.zoneID == zoneID else {
            return nil
        }

        return desanitizedRecordName(recordID.recordName)
    }

    private static func sanitizedRecordName(_ logicalID: String) -> String {
        logicalID.replacingOccurrences(of: "/", with: "__")
    }

    private static func desanitizedRecordName(_ recordName: String) -> String {
        recordName.replacingOccurrences(of: "__", with: "/")
    }
    #endif
}

#if canImport(CloudKit)
@available(macOS 14.0, macCatalyst 17.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
private final class CloudKitSyncDelegateBridge: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    private let owner: CloudKitSyncCoordinator

    init(owner: CloudKitSyncCoordinator) {
        self.owner = owner
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner.handleSyncEvent(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner.nextRecordZoneChangeBatch(context, syncEngine: syncEngine)
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        await owner.nextFetchChangesOptions(context, syncEngine: syncEngine)
    }
}
#endif

private enum SyncRuntimeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message
        }
    }
}
