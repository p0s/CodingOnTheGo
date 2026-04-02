import XCTest
@testable import SyncEngine
import Persistence
import SharedModels

final class SyncEngineTests: XCTestCase {
    private let sampleWorkspaceRoot = "/workspace/coding-on-the-go"
    private let sampleSecondaryWorkspaceRoot = "/workspace/secondary"

    func testFactoryPrefersFileBackedSyncDuringUITests() async throws {
        let configuration = AppRuntimeConfiguration.load(
            environment: [
                "UI_TESTING": "1",
                "COTG_SYNC_MIRROR_PATH": URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(UUID().uuidString)
                    .path
            ]
        )
        let coordinator = SyncCoordinatorFactory.makeDefault(configuration: configuration)

        _ = try await coordinator.stage(.preview)

        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertGreaterThan(snapshot.projectedRecordCount, 0)
    }

    func testFactoryCanDisableCloudKitExplicitly() async {
        let coordinator = SyncCoordinatorFactory.makeDefault(
            configuration: AppRuntimeConfiguration.load(
                environment: ["COTG_DISABLE_CLOUDKIT_SYNC": "1"]
            )
        )

        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.blocker)
    }

    func testFactoryDefaultsToLocalOnlyWithoutCloudKitOptIn() async {
        let coordinator = SyncCoordinatorFactory.makeDefault(
            configuration: AppRuntimeConfiguration.load(environment: [:])
        )

        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.blocker)
        XCTAssertEqual(snapshot.secretBoundaryNote, "Cross-device sync is disabled in this build.")
    }

    func testNoopCoordinatorRemainsIdleAfterStage() async throws {
        let coordinator = NoopCloudKitSyncCoordinator()

        let before = await coordinator.currentSnapshot()
        XCTAssertEqual(before.status, .idle)

        _ = try await coordinator.stage(.preview)

        let after = await coordinator.currentSnapshot()
        XCTAssertEqual(after.status, .idle)
        XCTAssertNotNil(after.lastSyncedAt)
        XCTAssertGreaterThan(after.projectedRecordCount, 0)
        XCTAssertEqual(after.secretBoundaryNote, "Cross-device sync is disabled in this build. Secrets remain out-of-band in Keychain.")
    }

    func testFileBackedCoordinatorWritesMirror() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let coordinator = FileBackedSyncCoordinator(mirrorURL: url)

        _ = try await coordinator.stage(.preview)

        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNotNil(snapshot.lastSyncedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(snapshot.projectedRecordCount, 0)
    }

    func testFileBackedCoordinatorMergesExistingMirrorBeforeWriting() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let coordinator = FileBackedSyncCoordinator(mirrorURL: url)
        let metadataStore = JSONMetadataStore()

        let remoteSnapshot = MachineDirectorySnapshot(
            machines: [
                MachineRecord.preview,
                MachineRecord.secondaryPreview
            ],
            tailnetProfiles: MachineDirectorySnapshot.preview.tailnetProfiles,
            recentSessions: [
                SessionRecord(
                    machineID: MachineRecord.preview.id,
                    threadID: "remote-thread",
                    workspaceRoot: sampleWorkspaceRoot,
                    lastKnownProtocol: .websocket,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now.addingTimeInterval(300)
                )
            ],
            preferences: UserPreferencesSnapshot(
                preferredMachineID: MachineRecord.secondaryPreview.id,
                restoreLastSessionOnLaunch: true
            )
        )

        try await metadataStore.save(remoteSnapshot, to: url)
        let merged = try await coordinator.stage(.preview)

        XCTAssertEqual(merged.machines.count, 2)
        XCTAssertEqual(merged.recentSessions.first?.threadID, "remote-thread")
        XCTAssertEqual(merged.preferences.preferredMachineID, MachineRecord.secondaryPreview.id)
    }

    func testMergeEnginePrefersFreshestSessionAndKeepsSecretBoundaryExplicit() {
        let engine = SyncMergeEngine()
        let local = MachineDirectorySnapshot.preview
        let remote = MachineDirectorySnapshot(
            machines: [
                MachineRecord.preview,
                MachineRecord.secondaryPreview
            ],
            tailnetProfiles: local.tailnetProfiles,
            recentSessions: [
                SessionRecord(
                    machineID: MachineRecord.preview.id,
                    threadID: "remote-thread",
                    workspaceRoot: sampleSecondaryWorkspaceRoot,
                    lastKnownProtocol: .websocket,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now.addingTimeInterval(120)
                )
            ],
            preferences: UserPreferencesSnapshot(
                preferredMachineID: MachineRecord.secondaryPreview.id,
                restoreLastSessionOnLaunch: false
            )
        )

        let merged = engine.merge(local: local, remote: remote)
        XCTAssertEqual(merged.machines.count, 2)
        XCTAssertEqual(merged.recentSessions.first?.threadID, "remote-thread")
        XCTAssertEqual(merged.preferences.preferredMachineID, MachineRecord.secondaryPreview.id)
        XCTAssertTrue(engine.project(local).secretBoundaryNote.contains("Keychain"))
    }

    func testMergeEnginePreservesExecutionPreferencesAndProjectionRoundTripsThem() {
        let engine = SyncMergeEngine()
        let machineID = MachineRecord.preview.id
        let local = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [],
            preferences: UserPreferencesSnapshot(
                preferredMachineID: machineID,
                restoreLastSessionOnLaunch: true,
                preferredBootstrap: .standardSSH,
                preferredProtocol: .websocket,
                preferredReasoningEffort: "xhigh",
                preferredApprovalPolicy: "never",
                preferredSandboxMode: "danger-full-access",
                privacyMode: .privacy
            )
        )
        let remote = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [],
            preferences: UserPreferencesSnapshot(
                preferredTailnetProfileID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                restoreLastSessionOnLaunch: false,
                privacyMode: .standard
            )
        )

        let merged = engine.merge(local: local, remote: remote)
        XCTAssertEqual(merged.preferences.preferredMachineID, machineID)
        XCTAssertEqual(merged.preferences.preferredTailnetProfileID, UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        XCTAssertEqual(merged.preferences.preferredBootstrap, .standardSSH)
        XCTAssertEqual(merged.preferences.preferredProtocol, .websocket)
        XCTAssertEqual(merged.preferences.preferredReasoningEffort, "xhigh")
        XCTAssertEqual(merged.preferences.preferredApprovalPolicy, "never")
        XCTAssertEqual(merged.preferences.preferredSandboxMode, "danger-full-access")
        XCTAssertEqual(merged.preferences.privacyMode, .standard)

        let materialized = SyncRecordMaterializer().materialize(records: engine.project(local).records)
        XCTAssertEqual(materialized.preferences.preferredMachineID, machineID)
        XCTAssertEqual(materialized.preferences.preferredBootstrap, .standardSSH)
        XCTAssertEqual(materialized.preferences.preferredProtocol, .websocket)
        XCTAssertEqual(materialized.preferences.preferredReasoningEffort, "xhigh")
        XCTAssertEqual(materialized.preferences.preferredApprovalPolicy, "never")
        XCTAssertEqual(materialized.preferences.preferredSandboxMode, "danger-full-access")
        XCTAssertEqual(materialized.preferences.privacyMode, .privacy)
    }

    func testMergeEnginePreservesExecutionProfileStateWhenFresherSessionDropsIt() throws {
        let engine = SyncMergeEngine()
        let machineID = MachineRecord.preview.id
        let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let executionProfileState = CodexExecutionProfileState(
            profile: CodexExecutionProfile(
                approvalPolicy: CodexExecutionAuthority(
                    requested: "never",
                    effective: "never",
                    status: .effective
                ),
                sandboxMode: CodexExecutionAuthority(
                    requested: "danger-full-access",
                    effective: "danger-full-access",
                    status: .effective
                ),
                networkAccess: CodexExecutionAuthority(
                    requested: true,
                    effective: true,
                    status: .effective
                )
            )
        )
        let local = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    id: sessionID,
                    machineID: machineID,
                    threadID: "thread-local",
                    workspaceRoot: sampleWorkspaceRoot,
                    lastKnownProtocol: .stdio,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now,
                    isArchived: true,
                    executionProfileState: executionProfileState
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )
        let remote = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    id: sessionID,
                    machineID: machineID,
                    threadID: "thread-remote",
                    workspaceRoot: sampleSecondaryWorkspaceRoot,
                    lastKnownProtocol: .websocket,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now.addingTimeInterval(30)
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )

        let merged = engine.merge(local: local, remote: remote)
        let mergedSession = try XCTUnwrap(merged.recentSessions.first)

        XCTAssertEqual(mergedSession.threadID, "thread-remote")
        XCTAssertEqual(mergedSession.executionProfileState, executionProfileState)
        XCTAssertEqual(mergedSession.isArchived, true)
    }

    func testMergeEngineKeepsSceneScopedSessionsDistinct() {
        let engine = SyncMergeEngine()
        let machineID = MachineRecord.preview.id
        let local = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    sceneID: "scene-a",
                    machineID: machineID,
                    threadID: "thread-a",
                    workspaceRoot: sampleWorkspaceRoot,
                    lastKnownProtocol: .stdio,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )
        let remote = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    sceneID: "scene-b",
                    machineID: machineID,
                    threadID: "thread-b",
                    workspaceRoot: sampleSecondaryWorkspaceRoot,
                    lastKnownProtocol: .websocket,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now.addingTimeInterval(30)
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )

        let merged = engine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.recentSessions.count, 2)
        XCTAssertTrue(merged.recentSessions.contains(where: { $0.sceneID == "scene-a" && $0.threadID == "thread-a" }))
        XCTAssertTrue(merged.recentSessions.contains(where: { $0.sceneID == "scene-b" && $0.threadID == "thread-b" }))
    }

    func testMergeEngineKeepsDistinctSessionIDsInSameScene() {
        let engine = SyncMergeEngine()
        let machineID = MachineRecord.preview.id
        let sharedSceneID = "scene-a"
        let local = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    sceneID: sharedSceneID,
                    machineID: machineID,
                    threadID: "thread-local",
                    workspaceRoot: sampleWorkspaceRoot,
                    lastKnownProtocol: .stdio,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )
        let remote = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    sceneID: sharedSceneID,
                    machineID: machineID,
                    threadID: "thread-remote",
                    workspaceRoot: sampleSecondaryWorkspaceRoot,
                    lastKnownProtocol: .websocket,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now.addingTimeInterval(30),
                    parentThreadID: "thread-local"
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )

        let merged = engine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.recentSessions.count, 2)
        XCTAssertTrue(merged.recentSessions.contains(where: { $0.id.uuidString == "11111111-1111-1111-1111-111111111111" }))
        XCTAssertTrue(
            merged.recentSessions.contains(where: {
                $0.id.uuidString == "22222222-2222-2222-2222-222222222222"
                    && $0.parentThreadID == "thread-local"
            })
        )
    }

    func testProjectionKeepsSensitiveSessionAndBrowserMetadataLocalOnly() {
        let engine = SyncMergeEngine()
        let machineID = MachineRecord.preview.id
        let snapshot = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [
                SessionRecord(
                    sceneID: "scene-a",
                    machineID: machineID,
                    threadID: "thread-a",
                    workspaceRoot: sampleWorkspaceRoot,
                    lastKnownProtocol: .stdio,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now
                ),
                SessionRecord(
                    sceneID: "scene-b",
                    machineID: machineID,
                    threadID: "thread-b",
                    workspaceRoot: sampleSecondaryWorkspaceRoot,
                    lastKnownProtocol: .websocket,
                    lastKnownBootstrap: .standardSSH,
                    lastOpenedAt: .now.addingTimeInterval(30),
                    parentThreadID: "thread-a"
                )
            ],
            preferences: UserPreferencesSnapshot(
                preferredMachineID: machineID,
                privacyMode: .privacy
            )
        )

        let projection = engine.project(snapshot)
        let kinds = Set(projection.records.map(\.kind))
        let materialized = SyncRecordMaterializer().materialize(records: projection.records)

        XCTAssertFalse(kinds.contains(.session))
        XCTAssertFalse(kinds.contains(.hostThreadCatalogEntry))
        XCTAssertTrue(projection.secretBoundaryNote.contains("queued prompts"))
        XCTAssertEqual(materialized.recentSessions.count, 0)
        XCTAssertEqual(materialized.preferences.privacyMode, .privacy)
    }

    func testMergeEnginePreservesCatalogTitleWhenRemoteEntryDropsIt() {
        let engine = SyncMergeEngine()
        let machine = MachineRecord.preview
        let local = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [
                HostThreadCatalogEntry(
                    id: "thread-1",
                    machineID: machine.id,
                    workspaceRoot: sampleWorkspaceRoot,
                    name: "Finish remote Codex client",
                    preview: "You are working in the Coding On The Go repo.",
                    modelProvider: "openai",
                    createdAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let remote = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [
                HostThreadCatalogEntry(
                    id: "thread-1",
                    machineID: machine.id,
                    workspaceRoot: sampleWorkspaceRoot,
                    name: nil,
                    preview: "You are working in the Coding On The Go repo.",
                    modelProvider: "openai",
                    createdAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 300)
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )

        let merged = engine.merge(local: local, remote: remote)
        let entry = try? XCTUnwrap(merged.hostThreadCatalog.first)

        XCTAssertEqual(entry?.name, "Finish remote Codex client")
        XCTAssertEqual(entry?.preview, "You are working in the Coding On The Go repo.")
        XCTAssertEqual(entry?.updatedAt, Date(timeIntervalSince1970: 300))
    }

    func testMergeEngineDeduplicatesDuplicateLocalHostThreadCatalogEntries() {
        let engine = SyncMergeEngine()
        let machine = MachineRecord.preview
        let older = HostThreadCatalogEntry(
            id: "thread-duplicate",
            machineID: machine.id,
            workspaceRoot: sampleWorkspaceRoot,
            name: nil,
            preview: "Older preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = HostThreadCatalogEntry(
            id: "thread-duplicate",
            machineID: machine.id,
            workspaceRoot: sampleSecondaryWorkspaceRoot,
            name: "Newest title",
            preview: "Newer preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let merged = engine.merge(
            local: MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [],
                hostThreadCatalog: [older, newer],
                preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
            ),
            remote: .empty
        )

        let matchingEntries = merged.hostThreadCatalog.filter {
            $0.machineID == machine.id && $0.id == "thread-duplicate"
        }
        XCTAssertEqual(matchingEntries.count, 1)
        XCTAssertEqual(matchingEntries.first?.workspaceRoot, sampleSecondaryWorkspaceRoot)
        XCTAssertEqual(matchingEntries.first?.name, "Newest title")
    }
}
