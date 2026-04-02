import XCTest
@testable import SharedModels

final class SharedModelsTests: XCTestCase {
    func testRouteKindsStaySeparatedFromBootstrapAndProtocol() {
        XCTAssertEqual(
            MachineRouteKind.allCases,
            [
                .embeddedTailnet,
                .externalTailnet,
                .localLAN,
                .manualSSH,
                .companionDirect
            ]
        )
    }

    func testPreviewMachinesCoverMultipleHosts() {
        XCTAssertEqual(MachineRecord.previewMachines.map(\.alias), ["example-mac", "c"])
    }

    func testPreferredRouteUsesStoredPreferenceFirst() {
        XCTAssertEqual(MachineRecord.preview.preferredRoute?.kind, .embeddedTailnet)
    }

    func testCredentialSynchronizableFlagReflectsScope() {
        let ref = CredentialRef(
            kind: .sshKey,
            keychainAccount: "cotg.p.ssh",
            label: "Primary SSH key",
            username: "developer",
            storageScope: .synchronizableKeychain
        )

        XCTAssertTrue(ref.isSynchronizable)
    }

    func testHostThreadCatalogMergePreservesExistingTitleWhenNewerCopyOnlyHasPreview() {
        let machineID = MachineRecord.preview.id
        let titled = HostThreadCatalogEntry(
            id: "thread-1",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Finish remote Codex client",
            preview: "You are working in the Coding On The Go repo.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let previewOnly = HostThreadCatalogEntry(
            id: "thread-1",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: nil,
            preview: "You are working in the Coding On The Go repo.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = titled.merged(with: previewOnly)

        XCTAssertEqual(merged.name, "Finish remote Codex client")
        XCTAssertEqual(merged.preview, "You are working in the Coding On The Go repo.")
        XCTAssertEqual(merged.updatedAt, previewOnly.updatedAt)
    }

    func testHostThreadCatalogMergePrefersDistinctTitleOverPreviewShapedName() {
        let machineID = MachineRecord.preview.id
        let titled = HostThreadCatalogEntry(
            id: "thread-1",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Finish remote Codex client",
            preview: "You are working in the Coding On The Go repo.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let degraded = HostThreadCatalogEntry(
            id: "thread-1",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "You are working in the Coding On The Go repo.",
            preview: "You are working in the Coding On The Go repo.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = titled.merged(with: degraded)

        XCTAssertEqual(merged.name, "Finish remote Codex client")
        XCTAssertEqual(merged.preview, "You are working in the Coding On The Go repo.")
    }

    func testHostThreadCatalogLegacyDecodeDefaultsToCachedProvenance() throws {
        let json = """
        {
          "id": "thread-1",
          "machineID": "\(MachineRecord.preview.id.uuidString)",
          "workspaceRoot": "/workspace/coding-on-the-go",
          "name": "Finish remote Codex client",
          "preview": "Keep the browser honest.",
          "modelProvider": "openai",
          "createdAt": 100,
          "updatedAt": 200
        }
        """

        let entry = try JSONDecoder().decode(HostThreadCatalogEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.provenance, .cachedHostCatalog)
        XCTAssertEqual(entry.observedAt, entry.updatedAt)
    }

    func testHostThreadCatalogMergePrefersSQLiteRepairWhenObservedAtMatches() {
        let machineID = MachineRecord.preview.id
        let live = HostThreadCatalogEntry(
            id: "thread-1",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Finish remote Codex client",
            preview: "Keep the browser honest.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            observedAt: Date(timeIntervalSince1970: 300),
            provenance: .liveAppServer
        )
        let repaired = HostThreadCatalogEntry(
            id: "thread-1",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Finish remote Codex client",
            preview: "Keep the browser honest.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            observedAt: Date(timeIntervalSince1970: 300),
            provenance: .sqliteRepaired
        )

        let merged = live.merged(with: repaired)

        XCTAssertEqual(merged.provenance, .sqliteRepaired)
        XCTAssertEqual(merged.observedAt, Date(timeIntervalSince1970: 300))
    }

    func testRuntimeConfigurationLoaderCentralizesPathsAndModes() {
        let configuration = AppRuntimeConfiguration.load(
            environment: [
                "UI_TESTING": "1",
                "COTG_METADATA_PATH": "/tmp/test-metadata.json",
                "COTG_SYNC_MIRROR_PATH": "/tmp/test-sync.json",
                "COTG_NOTIFICATION_OUTBOX_PATH": "/tmp/test-outbox.json",
                "COTG_COMPANION_NOTIFICATION_RELAY_DIR": "/tmp/test-relay",
                "COTG_COMPANION_PUSH_BROKER_URL": "https://broker.example.com/submit",
                "COTG_UI_TEST_WORKSPACE_ROOT_OVERRIDE": "/tmp/override-workspace",
                "COTG_WORKSPACE_ROOT": "/tmp/bootstrap-workspace"
            ]
        )

        XCTAssertEqual(configuration.paths.metadataStoreURL.path, "/tmp/test-metadata.json")
        XCTAssertEqual(configuration.paths.syncMirrorURL.path, "/tmp/test-sync.json")
        XCTAssertEqual(configuration.paths.notificationOutboxURL.path, "/tmp/test-outbox.json")
        XCTAssertEqual(configuration.paths.companionNotificationRelayDirectoryURL.path, "/tmp/test-relay")
        XCTAssertEqual(configuration.syncBehavior, .fileMirror(URL(fileURLWithPath: "/tmp/test-sync.json")))
        XCTAssertEqual(configuration.workspaceRootOverride, "/tmp/override-workspace")
        XCTAssertEqual(configuration.bootstrapWorkspaceRoot, "/tmp/override-workspace")
        XCTAssertEqual(
            configuration.notificationBridgeSubmission,
            .broker(URL(string: "https://broker.example.com/submit")!)
        )
    }

    func testRuntimeConfigurationLoaderIsolatesUITestStoresByDefault() {
        let configuration = AppRuntimeConfiguration.load(
            environment: [
                "UI_TESTING": "1",
                "XCTestSessionIdentifier": "physical/device:test-iphone"
            ]
        )

        XCTAssertTrue(
            configuration.paths.metadataStoreURL.path.hasSuffix(
                "/CodingOnTheGo/UITests/physical_device_test-iphone/machine-directory.json"
            ),
            "Expected UI tests to isolate the metadata store by session. Saw: \(configuration.paths.metadataStoreURL.path)"
        )
        XCTAssertTrue(
            configuration.paths.syncMirrorURL.path.hasSuffix(
                "/CodingOnTheGo/UITests/physical_device_test-iphone/cotg-sync-mirror.json"
            ),
            "Expected UI tests to isolate the sync mirror by session. Saw: \(configuration.paths.syncMirrorURL.path)"
        )
        XCTAssertEqual(configuration.syncBehavior, .fileMirror(configuration.paths.syncMirrorURL))
    }

    func testSessionRecordDecodesWithoutExecutionProfileState() throws {
        let session = SessionRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sceneID: "scene-1",
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.routes.first?.id,
            threadID: "thread-1",
            threadDisplayTitle: "app store upload",
            unavailableSelectedThreadID: "thread-missing-1",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .manualSSH,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastReasoningEffort: .medium,
            lastMode: .local,
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000),
            executionProfileState: CodexExecutionProfileState(
                baselineConfig: CodexExecutionBaselineConfigSnapshot(
                    approvalPolicy: "never",
                    sandboxMode: "read-only"
                ),
                profile: CodexExecutionProfile(
                    approvalPolicy: CodexExecutionAuthority(
                        requested: "never",
                        effective: "never",
                        status: .effective
                    )
                )
            )
        )

        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "executionProfileState")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SessionRecord.self, from: legacyData)

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.threadID, session.threadID)
        XCTAssertNil(decoded.executionProfileState)
    }

    func testSessionRecordDecodesWithoutThreadDisplayTitle() throws {
        let session = SessionRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            sceneID: "scene-3",
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.routes.first?.id,
            threadID: "thread-3",
            threadDisplayTitle: "app store upload",
            unavailableSelectedThreadID: "thread-missing-3",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .manualSSH,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastReasoningEffort: .medium,
            lastMode: .local,
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "threadDisplayTitle")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SessionRecord.self, from: legacyData)

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.threadID, session.threadID)
        XCTAssertNil(decoded.threadDisplayTitle)
    }

    func testSessionRecordDecodesWithoutUnavailableSelectedThreadID() throws {
        let session = SessionRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sceneID: "scene-2",
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.routes.first?.id,
            threadID: nil,
            unavailableSelectedThreadID: "thread-missing-2",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .manualSSH,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastReasoningEffort: .medium,
            lastMode: .local,
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "unavailableSelectedThreadID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SessionRecord.self, from: legacyData)

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertNil(decoded.unavailableSelectedThreadID)
    }
}
