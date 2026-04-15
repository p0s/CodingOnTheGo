import XCTest
@testable import AppState
import CodexRPC
import CompanionHost
import Discovery
import GitWorkspace
import HostBootstrap
import Persistence
import RouteSelection
import Secrets
import SharedModels
import SSHTransport
import SyncEngine
import TailnetEmbedded

@MainActor
final class AppStateTests: XCTestCase {
    private static let workspaceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path
    private static let localhostRawKeyPath = ProcessInfo.processInfo.environment["COTG_TEST_SSH_RAW_KEY_PATH"] ?? "/tmp/cotg_app_test_key.raw"
    private static let localhostSSHUser = ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"]
        ?? ProcessInfo.processInfo.environment["USER"]
        ?? NSUserName()
    nonisolated(unsafe) private var savedEnvironment: [String: String?] = [:]
    nonisolated(unsafe) private var savedDemoModeValue: Any?

    override func setUp() {
        super.setUp()
        saveAndClearTestEnvironment()
    }

    override func tearDown() {
        restoreTestEnvironment()
        super.tearDown()
    }

    private func loadPersistedSnapshotSynchronously(at url: URL) throws -> MachineDirectorySnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MachineDirectorySnapshot.self, from: data)
    }

    func testFreshInstallStartsWithoutSavedMachinesOrConnectionPlan() {
        let model = AppModel()

        XCTAssertNil(model.selectedMachine)
        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertTrue(model.tailnetProfiles.isEmpty)
        XCTAssertTrue(model.recentSessions.isEmpty)
        XCTAssertTrue(model.connectionPlan.isEmpty)
    }

    func testAddingManualRouteCreatesFirstMachineFromEmptyStartup() async throws {
        let model = AppModel()

        model.addManualRoute(
            label: "Lab SSH",
            address: "lab.local",
            kind: .manualSSH,
            usernameHint: "developer",
            port: 2222
        )

        let didCreateMachine = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.selectedMachine != nil
        }

        XCTAssertTrue(didCreateMachine)
        XCTAssertEqual(model.selectedMachine?.routes.first?.label, "Lab SSH")
        XCTAssertEqual(model.selectedMachine?.routes.first?.hostname, "lab.local")
        XCTAssertEqual(model.selectedMachine?.routes.first?.sshPort, 2222)
    }

    func testSendPromptBuildsDraftConversationWhenDisconnected() {
        let model = AppModel()
        let originalCount = model.transcript.count

        model.sendPrompt("Check the safe lane.")

        XCTAssertEqual(model.transcript.count, originalCount + 2)
        XCTAssertEqual(model.transcript[originalCount].role, .user)
        XCTAssertEqual(model.transcript[originalCount + 1].role, .assistant)
    }

    func testReviewerDemoModePopulatesBundledProjectsAndKeepsSameThreadAfterSend() {
        UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        }

        let model = AppModel(sceneID: "demo-review-scene")

        model.setDemoModeEnabled(true)

        XCTAssertTrue(model.isDemoModeEnabled)
        XCTAssertEqual(model.selectedMachine?.displayName, "Demo Mac")
        XCTAssertFalse(model.hostThreadCatalog.isEmpty)
        XCTAssertFalse(model.recentSessions.isEmpty)
        XCTAssertTrue(model.availableModels.contains(where: { $0.model == "gpt-5.5" }))
        XCTAssertEqual(model.connectionFailureSummary, nil)

        let originalThreadID = model.activeSession?.threadID
        XCTAssertEqual(originalThreadID, "demo-thread-reviewer-mode")
        XCTAssertTrue(model.transcript.contains(where: { $0.text.contains("bundled local data for Demo Mac") }))

        model.sendPrompt("Show that demo mode stays on the same thread for reviewers.")

        XCTAssertEqual(model.activeSession?.threadID, originalThreadID)
        XCTAssertEqual(model.transcript.last?.role, .assistant)
        XCTAssertTrue(model.transcript.last?.text.contains("same thread") == true)
    }

    func testAutomaticModelRefreshRepopulatesBundledCatalogSilently() {
        UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        }

        let model = AppModel(sceneID: "demo-model-refresh")

        model.setDemoModeEnabled(true)
        let transcriptCount = model.transcript.count
        model.availableModels = []

        model.refreshModelsIfNeeded()

        XCTAssertTrue(model.availableModels.contains(where: { $0.model == "gpt-5.5" }))
        XCTAssertEqual(model.transcript.count, transcriptCount)
    }

    func testActiveThreadModelLabelPrefersThreadModelOverSelectedDefault() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-desktop-55",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .websocket,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.5",
            lastOpenedAt: .now
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.availableModels = [
            CodexModelDescriptor(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "gpt-5.4",
                description: "",
                isDefault: true,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [.init(effort: .medium, description: "Medium")]
            ),
            CodexModelDescriptor(
                id: "gpt-5.5",
                model: "gpt-5.5",
                displayName: "gpt-5.5",
                description: "",
                isDefault: false,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [.init(effort: .medium, description: "Medium")]
            )
        ]
        model.selectedModel = "gpt-5.4"

        XCTAssertEqual(model.activeThreadModelLabel, "gpt-5.5")
    }

    func testActiveThreadModelLabelUsesSelectedModelWithoutConcreteThread() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .websocket,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastOpenedAt: .now
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedModel = "gpt-5.5"

        XCTAssertEqual(model.activeThreadModelLabel, "gpt-5.5")
    }

    func testSmokeTestPromptQueuesReconnectWhenConnectedWithoutThreadAndWithoutWorkspace() {
        let model = AppModel(bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)
        let originalSessionID = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            reconnect: false
        )
        model.connectionState = .connected("Connected to the SSH safe lane over stdio.")

        model.sendSmokeTestPrompt()

        XCTAssertNotEqual(model.activeSession?.id, originalSessionID)
        XCTAssertNil(model.activeSession?.threadID)
        XCTAssertNotNil(model.activeSession?.workspaceRoot)
        XCTAssertTrue(model.pendingPrompts.contains("Reply with COTG_APP_OK only."))
        if case .connecting = model.connectionState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected the smoke test path to start reconnecting on the prepared diagnostic session.")
        }
        XCTAssertFalse(
            model.transcript.contains(where: {
                $0.role == .assistant && $0.text.contains("Connect to a saved route before sending a prompt.")
            })
        )
    }

    func testSmokeTestPromptKeepsConnectedSessionWhenWorkspaceIsKnownButThreadIsMissing() {
        let model = AppModel(bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)
        let originalSessionID = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            reconnect: false
        )
        model.connectionState = .connected("Connected to the SSH safe lane over stdio.")

        model.sendSmokeTestPrompt()

        XCTAssertEqual(model.activeSession?.id, originalSessionID)
        XCTAssertNil(model.activeSession?.threadID)
        XCTAssertEqual(model.activeSession?.workspaceRoot, Self.workspaceRoot)
        if case .connected = model.connectionState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected the smoke test path to keep using the current live connection when a workspace is already known.")
        }
        XCTAssertFalse(model.pendingPrompts.contains("Reply with COTG_APP_OK only."))
        XCTAssertFalse(
            model.transcript.contains(where: {
                $0.role == .assistant && $0.text.contains("Connect to a saved route before sending a prompt.")
            })
        )
    }

    func testPrepareCodexWorkspaceForSelectedMachineIfNeededReusesPlaceholderSession() {
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer { unsetenv("COTG_WORKSPACE_ROOT") }

        let model = AppModel(bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)

        let originalSessionID = model.activeSession?.id
        let originalRecentSessionCount = model.recentSessions.count

        XCTAssertNil(model.activeSession?.threadID)
        XCTAssertNil(model.activeSession?.workspaceRoot)

        model.prepareCodexWorkspaceForSelectedMachineIfNeeded()

        XCTAssertEqual(model.activeSession?.id, originalSessionID)
        XCTAssertEqual(model.recentSessions.count, originalRecentSessionCount)
        XCTAssertNil(model.activeSession?.threadID)
        XCTAssertEqual(model.activeSession?.workspaceRoot, Self.workspaceRoot)
        XCTAssertTrue(model.transcript.isEmpty)
    }

    @MainActor
    func testPrepareCodexWorkspaceProjectsPreferredExecutionDefaultsOntoPlaceholderSession() {
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer { unsetenv("COTG_WORKSPACE_ROOT") }

        let model = AppModel(bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)
        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)

        model.prepareCodexWorkspaceForSelectedMachineIfNeeded()

        XCTAssertEqual(model.activeSession?.workspaceRoot, Self.workspaceRoot)
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.approvalPolicy.requested, "never")
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.approvalPolicy.status, .requested)
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.sandboxMode.requested, "danger-full-access")
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.sandboxMode.status, .requested)
        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: requested never")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: requested danger-full-access")
    }

    func testConnectionFailureSummaryExposesFailedDetail() {
        let model = AppModel()

        model.connectionState = .failed("The iPhone blocked this LAN SSH route before SSH started.")

        XCTAssertEqual(model.connectionFailureSummary, "The iPhone blocked this LAN SSH route before SSH started.")
    }

    func testDesktopContinuityActionsAppendImmediateTranscriptFeedback() {
        let model = AppModel(bootstrapSnapshot: .preview)

        model.select(machineID: MachineRecord.preview.id)
        _ = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            reconnect: false
        )
        model.connectionState = .connected("Connected to the SSH safe lane over stdio.")
        model.activeProtocolKind = .stdio

        let baselineCount = model.transcript.count

        model.revealCurrentWorkspaceInFinderOnHost()
        model.wakeMacDisplayOnHost()

        XCTAssertGreaterThanOrEqual(model.transcript.count, baselineCount + 2)
        XCTAssertEqual(
            model.transcript[baselineCount].text,
            "Requesting Finder reveal for \(URL(fileURLWithPath: Self.workspaceRoot).lastPathComponent) on the Mac."
        )
        XCTAssertEqual(
            model.transcript[baselineCount + 1].text,
            "Requesting a display wake signal for example-mac."
        )
    }

    func testWorkspaceWarningReflectsKnownWorkspaceFailureSummary() {
        let model = AppModel()

        model.workspaceFailureSummary = "This folder is not a git repository, so workspace review is unavailable."

        XCTAssertEqual(
            model.reviewState.failureSummary,
            "This folder is not a git repository, so workspace review is unavailable."
        )
        XCTAssertEqual(
            model.workspaceWarningText,
            "This folder is not a git repository, so workspace review is unavailable."
        )
    }

    func testEmbeddedTailnetProxyAdvisoryWaitsUntilTrustAndCredentialAreReady() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: "developer",
            tailnetProfileID: UUID(),
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: route.id,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            tailnetProfiles: [
                TailnetProfile(
                    id: route.tailnetProfileID ?? UUID(),
                    kind: .embedded,
                    displayName: "Embedded Tailnet",
                    controlURL: URL(string: "https://controlplane.tailscale.com")!,
                    accountLabel: "developer@example.com",
                    tailnetDNSName: "example-mac.example.ts.net",
                    isActive: true,
                    lastActivatedAt: .now,
                    lastAuthenticatedAt: .now,
                    supportsCustomControlServer: true,
                    requiresExternalApp: false
                )
            ],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)
        model.networkProxyDiagnostics = NetworkProxyDiagnosticSnapshot(
            systemProxyEnabled: true,
            envProxyKeys: [],
            localBypassConfigured: false,
            lanBypassConfigured: false,
            tailnetBypassConfigured: false,
            shadowrocketLikelyActive: false
        )

        XCTAssertNil(
            model.embeddedTailnetProxyAdvisory(
                for: route,
                hostValidationReady: false,
                authenticationReady: false
            )
        )
        XCTAssertEqual(
            model.embeddedTailnetProxyAdvisory(
                for: route,
                hostValidationReady: true,
                authenticationReady: true
            ),
            "Embedded Tailscale may be blocked by a system proxy or VPN. Bypass localhost, private ranges, 100.64.0.0/10, and *.ts.net traffic before retrying."
        )
    }

    func testCompletedCommentaryTurnsRestoreAsIdleHistory() {
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Finish the product",
                modelProvider: "openai",
                name: "Finish remote Codex client",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .idle
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-1",
                    status: "completed",
                    items: [
                        .userMessage("Ship the real mobile client."),
                        .assistantMessage("I audited the host-backed browser.", phase: .commentary),
                        .assistantMessage("I fixed the real Project and Thread flow.", phase: .finalAnswer)
                    ]
                )
            ]
        )

        let messages = AppModel.sessionMessages(from: snapshot)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[1].kind, .commentary)
        XCTAssertEqual(messages[2].kind, .standard)
        XCTAssertFalse(messages[1].isStreaming)
        XCTAssertFalse(messages[2].isStreaming)
        XCTAssertEqual(messages[1].text, "I audited the host-backed browser.")
        XCTAssertEqual(messages[2].text, "I fixed the real Project and Thread flow.")
    }

    func testSessionMessagesFiltersMacRuntimeTransportNotices() {
        let snapshot = CodexThreadSnapshot(
            summary: makeThreadSummary(id: "thread-runtime-transport", updatedAt: 1_700_000_000),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-1",
                    status: "completed",
                    items: [
                        .userMessage("Run it now."),
                        .other("Mac-side Codex retry: Reconnecting... 4/5"),
                        .other("Falling back from WebSockets to HTTPS transport. timeout waiting for child process to exit"),
                        .other("Loopback listener degraded. Falling back to the SSH safe lane."),
                        .other("Thread refresh failed: The operation couldn’t be completed. (NIOCore.ChannelError error 5.)"),
                        .assistantMessage("Done.", phase: .finalAnswer),
                        .other("Host runtime warning.")
                    ]
                )
            ]
        )

        let messages = AppModel.sessionMessages(from: snapshot)

        XCTAssertEqual(messages.map(\.text), ["Run it now.", "Done.", "Host runtime warning."])
    }

    func testSessionMessagesPreserveCompactActivityItemsFromThreadSnapshot() {
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Show progress",
                modelProvider: "openai",
                name: "Progress stream",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .idle
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-1",
                    status: "completed",
                    items: [
                        .userMessage("Fix the iPhone transcript."),
                        .assistantMessage("Thinking about the compact layout.", phase: .commentary),
                        .toolCall("Searching SessionWorkspaceCard.swift"),
                        .commandExecution(summary: "rg SessionWorkspaceCard", status: "completed"),
                        .fileChange(summary: "Updated SessionWorkspaceCard.swift", status: "modified"),
                        .assistantMessage("The compact progress stream is now visible in iOS.", phase: .finalAnswer)
                    ]
                )
            ]
        )

        let messages = AppModel.sessionMessages(from: snapshot)

        XCTAssertEqual(messages.map(\.kind), [.standard, .commentary, .toolCall, .commandExecution, .fileChange, .standard])
        XCTAssertEqual(messages.filter(\.countsAsAssistantReply).count, 1)
    }

    func testVisibleSessionMessagesKeepsExistingTranscriptWhenActiveSnapshotIsSparserForSameThread() {
        let existing = [
            SessionMessage(role: .user, text: "Keep this visible."),
            SessionMessage(role: .assistant, text: "Still rendering.")
        ]
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Keep this visible.",
                modelProvider: "openai",
                name: "Sparse active turn",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .active(activeFlags: ["running"])
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-2",
                    status: "inProgress",
                    items: [.toolCall("shell")]
                )
            ]
        )

        let messages = AppModel.visibleSessionMessages(
            existing: existing,
            displayedThreadID: "thread-1",
            snapshot: snapshot
        ).messages

        XCTAssertEqual(messages, existing)
    }

    func testVisibleSessionMessagesKeepsExistingTranscriptForSummaryOnlySameThreadSnapshot() {
        let existing = [
            SessionMessage(role: .user, text: "Keep this cached request."),
            SessionMessage(role: .assistant, text: "Keep this cached reply.")
        ]
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Large thread summary",
                modelProvider: "openai",
                name: "Large thread",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .idle
            ),
            turns: []
        )

        let presentation = AppModel.visibleSessionMessages(
            existing: existing,
            displayedThreadID: "thread-1",
            snapshot: snapshot
        )

        XCTAssertEqual(presentation.messages, existing)
        XCTAssertFalse(presentation.hasEarlierHistory)
    }

    func testVisibleSessionMessagesFiltersExistingRuntimeTransportNotices() {
        let existing = [
            SessionMessage(role: .user, text: "Keep this cached request."),
            SessionMessage(role: .system, text: "Loopback listener degraded. Falling back to the SSH safe lane."),
            SessionMessage(role: .system, text: "Thread refresh failed: The operation couldn’t be completed. (NIOCore.ChannelError error 5.)"),
            SessionMessage(role: .assistant, text: "Keep this cached reply.")
        ]
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Large thread summary",
                modelProvider: "openai",
                name: "Large thread",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .idle
            ),
            turns: []
        )

        let presentation = AppModel.visibleSessionMessages(
            existing: existing,
            displayedThreadID: "thread-1",
            snapshot: snapshot
        )

        XCTAssertEqual(
            presentation.messages.map(\.text),
            ["Keep this cached request.", "Keep this cached reply."]
        )
    }

    func testVisibleSessionMessagesPreservesMatchedMessageIdentityAcrossRefresh() {
        let existingAssistantID = UUID()
        let existingAssistantCreatedAt = Date(timeIntervalSince1970: 123)
        let existing = [
            SessionMessage(role: .user, text: "Explain the bug."),
            SessionMessage(
                id: existingAssistantID,
                role: .assistant,
                text: "Show full should stay expanded after live refresh.",
                createdAt: existingAssistantCreatedAt
            )
        ]
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Explain the bug.",
                modelProvider: "openai",
                name: "Stable transcript identity",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .idle
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-1",
                    status: "completed",
                    items: [
                        .userMessage("Explain the bug."),
                        .assistantMessage(
                            "Show full should stay expanded after live refresh.",
                            phase: .finalAnswer
                        )
                    ]
                )
            ]
        )

        let presentation = AppModel.visibleSessionMessages(
            existing: existing,
            displayedThreadID: "thread-1",
            snapshot: snapshot
        )

        XCTAssertEqual(presentation.messages.last?.id, existingAssistantID)
        XCTAssertEqual(presentation.messages.last?.createdAt, existingAssistantCreatedAt)
    }

    func testVisibleSessionMessagesShowsRecentSliceFirstForLongHistory() {
        let turns = (1...12).map { index in
            CodexThreadTurnSnapshot(
                id: "turn-\(index)",
                status: "completed",
                items: [
                    .userMessage("User request \(index)"),
                    .assistantMessage("Assistant response \(index)", phase: .finalAnswer)
                ]
            )
        }
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-1",
                cwd: Self.workspaceRoot,
                preview: "Long thread",
                modelProvider: "openai",
                name: "Long thread",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                status: .idle
            ),
            turns: turns
        )

        let presentation = AppModel.visibleSessionMessages(
            existing: [],
            displayedThreadID: nil,
            snapshot: snapshot
        )

        XCTAssertTrue(presentation.hasEarlierHistory)
        XCTAssertEqual(presentation.messages.count, 6)
        XCTAssertEqual(presentation.messages.first?.text, "User request 10")
        XCTAssertEqual(presentation.messages.last?.text, "Assistant response 12")
    }

    func testReconnectTranscriptPreviewFallsBackToHostThreadCatalogPreview() {
        let machine = MachineRecord.preview
        let entry = HostThreadCatalogEntry(
            id: "thread-real-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Fix Codex client UX",
            preview: "Latest saved reply preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "reconnect-preview", bootstrapSnapshot: snapshot)

        _ = model.resumeHostThreadCatalogEntry(entry, reconnect: false)
        model.connectionState = .connecting
        model.transcript = []
        model.recentSessions[0].lastTurn = nil

        XCTAssertEqual(model.reconnectTranscriptPreview, "Latest saved reply preview")
    }

    func testShouldRefreshVisibleActiveThreadWhenBaselineMissing() {
        let latest = makeThreadSummary(id: "thread-live", updatedAt: 200)

        XCTAssertTrue(
            AppModel.shouldRefreshVisibleActiveThread(
                baseline: nil,
                latest: latest,
                expectedThreadID: "thread-live"
            )
        )
    }

    func testShouldRefreshVisibleActiveThreadOnlyWhenSummaryChanges() {
        let baselineSummary = makeThreadSummary(id: "thread-live", updatedAt: 200)
        let baseline = AppModel.activeThreadSummaryDigest(from: baselineSummary)

        XCTAssertFalse(
            AppModel.shouldRefreshVisibleActiveThread(
                baseline: baseline,
                latest: baselineSummary,
                expectedThreadID: "thread-live"
            )
        )

        let previewChanged = CodexThreadSummary(
            id: "thread-live",
            cwd: baselineSummary.cwd,
            preview: "New preview",
            modelProvider: baselineSummary.modelProvider,
            name: baselineSummary.name,
            createdAt: baselineSummary.createdAt,
            updatedAt: baselineSummary.updatedAt,
            status: baselineSummary.status
        )
        XCTAssertTrue(
            AppModel.shouldRefreshVisibleActiveThread(
                baseline: baseline,
                latest: previewChanged,
                expectedThreadID: "thread-live"
            )
        )

        let updated = makeThreadSummary(id: "thread-live", updatedAt: 201)
        XCTAssertTrue(
            AppModel.shouldRefreshVisibleActiveThread(
                baseline: baseline,
                latest: updated,
                expectedThreadID: "thread-live"
            )
        )
    }

    func testVisibleActiveThreadSummaryGateIsDisabledForStdioSafeLane() {
        XCTAssertFalse(AppModel.shouldUseVisibleActiveThreadSummaryGate(protocolKind: .stdio))
        XCTAssertFalse(AppModel.shouldUseVisibleActiveThreadSummaryGate(protocolKind: .websocket))
        XCTAssertTrue(AppModel.shouldUseVisibleActiveThreadSummaryGate(protocolKind: .directEndpoint))
    }

    func testWebsocketErrorFallbackIsSuppressedDuringStdioUpgrade() {
        XCTAssertFalse(
            AppModel.shouldFallbackFromWebsocketError(
                protocolKind: .stdio,
                loopbackUpgradeInProgress: true
            )
        )
        XCTAssertTrue(
            AppModel.shouldFallbackFromWebsocketError(
                protocolKind: .stdio,
                loopbackUpgradeInProgress: false
            )
        )
        XCTAssertTrue(
            AppModel.shouldFallbackFromWebsocketError(
                protocolKind: .websocket,
                loopbackUpgradeInProgress: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldFallbackFromWebsocketError(
                protocolKind: .websocket,
                loopbackUpgradeInProgress: false,
                activeTurnID: "turn-that-just-ended",
                message: "cancelled"
            )
        )
        XCTAssertFalse(
            AppModel.shouldFallbackFromWebsocketError(
                protocolKind: .websocket,
                loopbackUpgradeInProgress: false,
                activeTurnID: "turn-with-mac-runtime-retry",
                message: "Falling back from WebSockets to HTTPS transport. timeout waiting for child process to exit"
            )
        )
        XCTAssertFalse(
            AppModel.shouldFallbackFromWebsocketError(
                protocolKind: .websocket,
                loopbackUpgradeInProgress: false,
                activeTurnID: "turn-that-just-ended",
                message: "The operation couldn’t be completed. (NSURLErrorDomain error -999.)"
            )
        )
        XCTAssertTrue(
            AppModel.shouldSuppressWebsocketErrorAfterCompletedTurn(
                source: .websocket,
                suppressNext: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldSuppressWebsocketErrorAfterCompletedTurn(
                source: .stdio,
                suppressNext: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldSuppressWebsocketErrorAfterCompletedTurn(
                source: .websocket,
                suppressNext: false
            )
        )
    }

    func testLoopbackUpgradeFreshListenerRetryIsLimitedToTransportFailures() {
        XCTAssertTrue(
            AppModel.shouldRetryLoopbackUpgradeWithFreshListener(
                after: NSError(
                    domain: "NIOCore.ChannelPipelineError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The operation couldn't be completed. (NIOCore.ChannelPipelineError error 1.)"
                    ]
                )
            )
        )
        XCTAssertFalse(
            AppModel.shouldRetryLoopbackUpgradeWithFreshListener(
                after: NSError(
                    domain: "Codex",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Loopback thread/resume did not complete in time."
                    ]
                )
            )
        )
    }

    func testVisibleActiveThreadRefreshLoopIncludesStdioSafeLane() {
        let model = AppModel(bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)
        _ = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            reconnect: false
        )
        let index = model.recentSessions.firstIndex { $0.id == model.activeSessionID }
        XCTAssertNotNil(index)
        model.recentSessions[index!].threadID = "thread-live"
        model.connectionState = .connected("Connected to the SSH safe lane over stdio.")
        model.activeProtocolKind = .stdio

        XCTAssertEqual(
            model.visibleActiveThreadRefreshLoopKey(sceneIsActive: true, browserIsVisible: false),
            "thread-live::stdio::idle"
        )
        XCTAssertEqual(
            model.visibleActiveThreadRefreshLoopKey(sceneIsActive: false, browserIsVisible: false),
            "inactive"
        )
        XCTAssertEqual(
            model.visibleActiveThreadRefreshLoopKey(sceneIsActive: true, browserIsVisible: true),
            "inactive"
        )
    }

    func testVisibleActiveThreadRefreshIntervalUsesFastPollingForWebsocketMirror() {
        let model = AppModel(bootstrapSnapshot: .preview)
        model.connectionState = .connected("Connected to the loopback websocket optimization lane.")
        model.activeProtocolKind = .websocket
        model.activeTurnID = nil
        model.transcript = [SessionMessage(role: .assistant, text: "Existing transcript.")]
        model.isRestoringActiveTranscript = false

        XCTAssertEqual(model.visibleActiveThreadRefreshInterval(), .milliseconds(700))
    }

    func testNeedsLocalNetworkSettingsRepairOnlyFlagsLocalNetworkFailures() {
        let model = AppModel()

        model.connectionState = .failed("Allow Local Network access for Coding On The Go and retry.")
        XCTAssertTrue(model.needsLocalNetworkSettingsRepair)

        model.connectionState = .failed("SSH host key mismatch.")
        XCTAssertFalse(model.needsLocalNetworkSettingsRepair)
    }

    func testClientOrchestratedModeBuildsTrackedSubtasksFromBulletList() {
        let model = AppModel()
        model.selectParallelAgentMode(.clientOrchestrated)

        model.sendPrompt(
            """
            - Audit the route priority stack
            - Verify the SSH safe lane fallback
            """
        )

        XCTAssertEqual(model.subagentActivitySummary, "Queued 2 client-orchestrated subtasks.")
        XCTAssertTrue(
            model.transcript.contains(where: {
                $0.role == .system && $0.text.contains("Queued 2 client-orchestrated subtasks")
            })
        )
        XCTAssertEqual(model.transcript.last?.role, .assistant)
    }

    func testComposerDraftSummarizesQueuedAttachmentWhenDisconnected() {
        let model = AppModel()
        let originalCount = model.transcript.count

        model.addPhotoAttachment(named: "preview.png", data: Data([0x89, 0x50]), suggestedFilename: "preview.png")
        model.sendComposerDraft()

        XCTAssertEqual(model.transcript.count, originalCount + 2)
        XCTAssertEqual(model.transcript[originalCount].role, .user)
        XCTAssertEqual(model.transcript[originalCount].text, "Shared 1 attachment.")
        XCTAssertEqual(model.transcript[originalCount].deliveryState, .failed)
        XCTAssertEqual(model.transcript[originalCount].attachments.map(\.displayName), ["preview.png"])
        XCTAssertEqual(model.transcript[originalCount + 1].role, .assistant)
    }

    func testSceneScopedSessionsPersistWithoutClobberingSiblingWindow() async throws {
        let metadataPath = "/tmp/cotg-scene-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-scene-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let sceneA = AppModel(sceneID: "scene-a", bootstrapSnapshot: .preview)
        let sceneB = AppModel(sceneID: "scene-b", bootstrapSnapshot: .preview)
        sceneA.select(machineID: MachineRecord.preview.id)
        sceneB.select(machineID: MachineRecord.secondaryPreview.id)
        sceneA.recentSessions.append(
            SessionRecord(
                sceneID: "scene-a",
                machineID: MachineRecord.preview.id,
                routeID: MachineRecord.preview.preferredRoute?.id,
                threadID: "thread-scene-a",
                workspaceRoot: "/tmp/cotg-scene-a",
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: MachineRecord.preview.preferredRoute?.kind,
                lastKnownBootstrap: .standardSSH,
                transportState: .connected,
                lastOpenedAt: .now
            )
        )
        sceneB.recentSessions.append(
            SessionRecord(
                sceneID: "scene-b",
                machineID: MachineRecord.secondaryPreview.id,
                routeID: MachineRecord.secondaryPreview.preferredRoute?.id,
                threadID: "thread-scene-b",
                workspaceRoot: "/tmp/cotg-scene-b",
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: MachineRecord.secondaryPreview.preferredRoute?.kind,
                lastKnownBootstrap: .standardSSH,
                transportState: .connected,
                lastOpenedAt: .now
            )
        )
        sceneA.sceneDidEnterBackground()
        sceneB.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(400))

        let restoredA = AppModel(sceneID: "scene-a", bootstrapSnapshot: .preview)
        let restoredB = AppModel(sceneID: "scene-b", bootstrapSnapshot: .preview)
        _ = await restoredA.restorePersistedState()
        _ = await restoredB.restorePersistedState()

        restoredA.select(machineID: MachineRecord.preview.id)
        restoredB.select(machineID: MachineRecord.secondaryPreview.id)

        XCTAssertEqual(restoredA.activeSession?.sceneID, "scene-a")
        XCTAssertEqual(restoredB.activeSession?.sceneID, "scene-b")
        XCTAssertTrue(restoredA.recentSessions.contains(where: { $0.sceneID == "scene-a" }))
        XCTAssertTrue(restoredA.recentSessions.contains(where: { $0.sceneID == "scene-b" }))
    }

    func testRestorePrefersPersistedSelectedMachine() async throws {
        let metadataPath = "/tmp/cotg-restore-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-restore-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let source = AppModel(sceneID: "scene-a", bootstrapSnapshot: .preview)
        source.select(machineID: MachineRecord.secondaryPreview.id)
        try await Task.sleep(for: .milliseconds(400))

        let restored = AppModel(sceneID: "scene-a", bootstrapSnapshot: .preview)
        let context = await restored.restorePersistedState()

        XCTAssertEqual(context.selectedMachineID, MachineRecord.secondaryPreview.id)
        XCTAssertFalse(context.shouldRestoreDetail)
        XCTAssertEqual(restored.selectedMachineID, MachineRecord.secondaryPreview.id)
    }

    func testResumeSessionAdoptsSavedThreadAndQueueForCurrentScene() {
        let model = AppModel(sceneID: "resume-scene", bootstrapSnapshot: .preview)
        let targetMachine = MachineRecord.secondaryPreview
        let session = SessionRecord(
            sceneID: nil,
            machineID: targetMachine.id,
            routeID: targetMachine.preferredRoute?.id,
            threadID: "thread-resume-123",
            workspaceRoot: "/tmp/cotg-resume",
            lastKnownProtocol: .websocket,
            lastKnownRouteKind: targetMachine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: .now,
            queuedPrompts: ["follow up"]
        )

        model.recentSessions.append(session)
        model.resumeSession(session.id, reconnect: false)

        XCTAssertEqual(model.selectedMachineID, targetMachine.id)
        XCTAssertEqual(model.activeSession?.threadID, "thread-resume-123")
        XCTAssertEqual(model.activeProtocolKind, .websocket)
        XCTAssertEqual(model.pendingPrompts, ["follow up"])
    }

    func testResumeSessionMarksExistingThreadAsRestoringUntilSnapshotArrives() {
        let model = AppModel(sceneID: "resume-restoring", bootstrapSnapshot: .preview)
        let targetMachine = MachineRecord.preview
        let session = SessionRecord(
            sceneID: nil,
            machineID: targetMachine.id,
            routeID: targetMachine.preferredRoute?.id,
            threadID: "thread-resume-restoring",
            workspaceRoot: "/tmp/cotg-resume-restoring",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: targetMachine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .disconnected,
            lastOpenedAt: .now
        )

        model.recentSessions.append(session)
        model.resumeSession(session.id, reconnect: true)

        XCTAssertEqual(model.activeSession?.threadID, "thread-resume-restoring")
        XCTAssertTrue(model.isRestoringActiveTranscript)
        XCTAssertTrue(model.shouldShowTranscriptRestorePlaceholder)
        XCTAssertNil(model.displayedTranscriptThreadID)
    }

    func testSendComposerDraftWhileReconnectingPinsVisibleTranscriptToActiveThread() {
        let model = AppModel(sceneID: "resume-restoring-send", bootstrapSnapshot: .preview)
        let targetMachine = MachineRecord.preview
        let session = SessionRecord(
            sceneID: nil,
            machineID: targetMachine.id,
            routeID: targetMachine.preferredRoute?.id,
            threadID: "thread-resume-restoring-send",
            workspaceRoot: "/tmp/cotg-resume-restoring-send",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: targetMachine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .disconnected,
            lastOpenedAt: .now
        )

        model.recentSessions.append(session)
        model.resumeSession(session.id, reconnect: true)
        model.connectionState = .connecting
        model.activeTurnID = "stale-turn-from-failed-transport"
        model.composerState.draft = "Follow up once reconnected."

        model.sendComposerDraft()

        XCTAssertNil(model.activeTurnID)
        XCTAssertEqual(model.threadFeatureState.queuedPromptCount, 1)
        XCTAssertEqual(model.displayedTranscriptThreadID, session.threadID)
        XCTAssertFalse(model.isRestoringActiveTranscript)
        XCTAssertEqual(model.transcript.first?.role, .user)
        XCTAssertEqual(model.transcript.first?.deliveryState, .queued)
        XCTAssertTrue(
            model.transcript.contains(where: { $0.text.contains("reconnect before sending") }),
            "Expected the reconnecting send path to keep a visible queued status instead of clearing the transcript."
        )
    }

    func testStaleConnectingSessionRestartsWhenNoConnectionTaskSurvivedRelaunch() {
        XCTAssertTrue(
            AppModel.shouldRestartStaleConnectingSession(
                activeTurnID: nil,
                connectionTaskActive: false,
                connectionAttemptStartedAt: nil,
                now: Date()
            )
        )
    }

    func testActiveConnectingSessionIsNotRestartedPrematurely() {
        let now = Date()
        XCTAssertFalse(
            AppModel.shouldRestartStaleConnectingSession(
                activeTurnID: nil,
                connectionTaskActive: true,
                connectionAttemptStartedAt: now.addingTimeInterval(-10),
                now: now
            )
        )
    }

    func testConnectingSessionWithActiveTurnIsNotRestarted() {
        XCTAssertFalse(
            AppModel.shouldRestartStaleConnectingSession(
                activeTurnID: "turn-active",
                connectionTaskActive: false,
                connectionAttemptStartedAt: nil,
                now: Date()
            )
        )
    }

    func testActiveSessionStaysPinnedWhenSiblingSessionBecomesNewer() throws {
        let machine = MachineRecord.preview
        let keptSession = SessionRecord(
            sceneID: "pin-scene",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-keep",
            workspaceRoot: "/tmp/cotg-keep",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let siblingSession = SessionRecord(
            sceneID: "pin-scene",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-sibling",
            workspaceRoot: "/tmp/cotg-sibling",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: Date(timeIntervalSince1970: 90)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [keptSession, siblingSession],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )

        let model = AppModel(sceneID: "pin-scene", bootstrapSnapshot: snapshot)
        model.resumeSession(keptSession.id, reconnect: false)
        XCTAssertEqual(model.activeSession?.id, keptSession.id)

        let siblingIndex = try XCTUnwrap(model.recentSessions.firstIndex(where: { $0.id == siblingSession.id }))
        model.recentSessions[siblingIndex].lastOpenedAt = Date(timeIntervalSince1970: 200)

        XCTAssertEqual(model.activeSession?.id, keptSession.id)
        XCTAssertEqual(model.activeSession?.threadID, "thread-keep")
    }

    func testResumeHostThreadCatalogEntryCreatesSessionForRealHostThread() {
        let machine = MachineRecord.preview
        let entry = HostThreadCatalogEntry(
            id: "thread-real-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Fix Codex client UX",
            preview: "Finish the real Project and Thread browser.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "host-catalog-create", bootstrapSnapshot: snapshot)

        let sessionID = model.resumeHostThreadCatalogEntry(entry, reconnect: false)

        XCTAssertNotNil(sessionID)
        XCTAssertEqual(model.activeSession?.threadID, entry.id)
        XCTAssertEqual(model.activeSession?.workspaceRoot, entry.workspaceRoot)
        XCTAssertEqual(model.recentSessions.count, 1)
        XCTAssertEqual(model.recentSessions.first?.threadID, entry.id)
        XCTAssertEqual(model.recentSessions.first?.lastTurn?.summary, entry.name)
    }

    func testPendingApprovalRequestIsPreservedWhenSnapshotStillShowsSameActiveTurn() {
        let request = CodexApprovalRequest(
            id: 7,
            kind: .permissions,
            threadID: "thread-live",
            turnID: "turn-live",
            itemID: "item-1",
            approvalID: "approval-1",
            summary: "Allow writing outside the workspace",
            reason: "The command needs to update ~/.asc.",
            requestedPermissions: CodexRequestedPermissions(
                readRoots: [],
                writeRoots: ["/workspace/.asc"],
                networkEnabled: nil
            )
        )
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-live",
                cwd: "/workspace/coding-on-the-go",
                preview: "Waiting on approval",
                modelProvider: "openai",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                status: .active(activeFlags: ["waitingOnApproval"])
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-live",
                    status: "inProgress",
                    items: []
                )
            ]
        )

        XCTAssertEqual(
            AppModel.pendingApprovalRequestToPreserve(
                current: request,
                snapshot: snapshot
            ),
            request
        )
    }

    func testPendingApprovalRequestClearsWhenSnapshotNoLongerShowsSameActiveTurn() {
        let request = CodexApprovalRequest(
            id: 7,
            kind: .permissions,
            threadID: "thread-live",
            turnID: "turn-live",
            itemID: "item-1",
            approvalID: "approval-1",
            summary: "Allow writing outside the workspace"
        )
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-live",
                cwd: "/workspace/coding-on-the-go",
                preview: "Turn finished",
                modelProvider: "openai",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                status: .idle
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-live",
                    status: "completed",
                    items: []
                )
            ]
        )

        XCTAssertNil(
            AppModel.pendingApprovalRequestToPreserve(
                current: request,
                snapshot: snapshot
            )
        )
    }

    func testPendingApprovalRequestWithoutTurnIDIsPreservedWhileThreadStillWaitsOnApproval() {
        let request = CodexApprovalRequest(
            id: 17,
            kind: .commandExecution,
            method: .execCommandApproval,
            threadID: "thread-live",
            itemID: "call-live",
            approvalID: "approval-legacy",
            summary: "touch ~/.cotg_approval_probe_test-iphone"
        )
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-live",
                cwd: "/workspace/coding-on-the-go",
                preview: "Waiting on approval",
                modelProvider: "openai",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                status: .active(activeFlags: ["waitingOnApproval"])
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-live",
                    status: "inProgress",
                    items: []
                )
            ]
        )

        XCTAssertEqual(
            AppModel.pendingApprovalRequestToPreserve(
                current: request,
                snapshot: snapshot
            ),
            request
        )
    }

    func testPendingApprovalRequestWithTurnIDIsPreservedWhileThreadStillWaitsOnApprovalEvenIfSnapshotTurnDiffers() {
        let request = CodexApprovalRequest(
            id: 18,
            kind: .permissions,
            threadID: "thread-live",
            turnID: "turn-live",
            itemID: "item-1",
            approvalID: "approval-1",
            summary: "Allow writing outside the workspace",
            reason: "The command needs to update ~/.asc.",
            requestedPermissions: CodexRequestedPermissions(
                readRoots: [],
                writeRoots: ["/workspace/.asc"],
                networkEnabled: nil
            )
        )
        let snapshot = CodexThreadSnapshot(
            summary: CodexThreadSummary(
                id: "thread-live",
                cwd: "/workspace/coding-on-the-go",
                preview: "Waiting on approval",
                modelProvider: "openai",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                status: .active(activeFlags: ["waitingOnApproval"])
            ),
            turns: [
                CodexThreadTurnSnapshot(
                    id: "turn-other",
                    status: "inProgress",
                    items: []
                )
            ]
        )

        XCTAssertEqual(
            AppModel.pendingApprovalRequestToPreserve(
                current: request,
                snapshot: snapshot
            ),
            request
        )
    }

    func testResumeHostThreadCatalogEntrySeedsExecutionProfileFromCurrentMachineSession() {
        let machine = MachineRecord.preview
        let seededExecutionProfileState = CodexExecutionProfileState(
            profile: CodexExecutionProfile(
                approvalPolicy: .init(
                    requested: "on-request",
                    effective: "on-request",
                    status: .effective
                ),
                sandboxMode: .init(
                    requested: "workspace-write",
                    effective: "workspace-write",
                    status: .effective
                ),
                networkAccess: .init(
                    requested: true,
                    effective: true,
                    status: .effective
                )
            )
        )
        let connectedSession = SessionRecord(
            sceneID: "host-catalog-seeded",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 50),
            transportState: .connected,
            executionProfileState: seededExecutionProfileState
        )
        let entry = HostThreadCatalogEntry(
            id: "thread-real-456",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Resume seeded session",
            preview: "Keep the live authority snapshot while switching threads.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [connectedSession],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "host-catalog-seeded", bootstrapSnapshot: snapshot)
        model.select(machineID: machine.id)

        let sessionID = model.resumeHostThreadCatalogEntry(entry, reconnect: false)

        XCTAssertEqual(
            model.recentSessions.first(where: { $0.id == sessionID })?.executionProfileState,
            seededExecutionProfileState
        )
    }

    func testSetHostThreadArchivedCreatesLocalProjectionForRealHostThread() throws {
        let machine = MachineRecord.preview
        let entry = HostThreadCatalogEntry(
            id: "thread-archive-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Archive browser thread",
            preview: "Hide this thread from the main project list.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "host-catalog-archive", bootstrapSnapshot: snapshot)

        model.select(machineID: machine.id)
        model.setHostThreadArchived(entry, archived: true)

        let archivedSession = try XCTUnwrap(model.recentSessions.first(where: { $0.threadID == entry.id }))
        XCTAssertEqual(archivedSession.workspaceRoot, entry.workspaceRoot)
        XCTAssertEqual(archivedSession.lastMode, .local)
        XCTAssertTrue(archivedSession.isArchived)
    }

    func testResumeHostThreadCatalogEntryReusesExistingSessionForSameThread() {
        let machine = MachineRecord.preview
        let existingSession = SessionRecord(
            sceneID: "host-catalog-reuse",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/tmp/stale-path",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .disconnected,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let entry = HostThreadCatalogEntry(
            id: "thread-real-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Fix Codex client UX",
            preview: "Finish the real Project and Thread browser.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [existingSession],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "host-catalog-reuse", bootstrapSnapshot: snapshot)

        let sessionID = model.resumeHostThreadCatalogEntry(entry, reconnect: false)

        XCTAssertEqual(sessionID, existingSession.id)
        XCTAssertEqual(model.recentSessions.count, 1)
        XCTAssertEqual(model.activeSession?.threadID, entry.id)
        XCTAssertEqual(model.activeSession?.workspaceRoot, entry.workspaceRoot)
        XCTAssertEqual(model.recentSessions.first?.lastTurn?.summary, entry.name)
    }

    func testResumeHostThreadCatalogEntrySeedsExistingSessionExecutionProfileUntilReconnect() {
        let machine = MachineRecord.preview
        let seededExecutionProfileState = CodexExecutionProfileState(
            profile: CodexExecutionProfile(
                approvalPolicy: .init(
                    requested: "on-request",
                    effective: "on-request",
                    status: .effective
                ),
                sandboxMode: .init(
                    requested: "workspace-write",
                    effective: "workspace-write",
                    status: .effective
                ),
                networkAccess: .init(
                    requested: true,
                    effective: true,
                    status: .effective
                )
            )
        )
        let existingSession = SessionRecord(
            sceneID: "host-catalog-reseed",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/tmp/stale-path",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .disconnected,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let connectedSession = SessionRecord(
            sceneID: "host-catalog-reseed",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 50),
            transportState: .connected,
            executionProfileState: seededExecutionProfileState
        )
        let entry = HostThreadCatalogEntry(
            id: "thread-real-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Fix Codex client UX",
            preview: "Finish the real Project and Thread browser.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [existingSession, connectedSession],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "host-catalog-reseed", bootstrapSnapshot: snapshot)

        let sessionID = model.resumeHostThreadCatalogEntry(entry, reconnect: false)

        XCTAssertEqual(sessionID, existingSession.id)
        XCTAssertEqual(
            model.recentSessions.first(where: { $0.id == existingSession.id })?.executionProfileState,
            seededExecutionProfileState
        )
    }

    func testRequestedThreadExecutionOptionsFallBackToSessionExecutionProfile() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                profile: CodexExecutionProfile(
                    approvalPolicy: .init(
                        requested: "on-request",
                        effective: "on-request",
                        status: .effective
                    ),
                    sandboxMode: .init(
                        requested: "workspace-write",
                        effective: "workspace-write",
                        status: .effective
                    )
                )
            )
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )

        let baseline = CodexExecutionBaselineConfigSnapshot(
            approvalPolicy: "on-request",
            sandboxMode: "workspace-write"
        )
        let withoutPreferences = model.requestedThreadExecutionOptions(
            session: session,
            cwd: session.workspaceRoot,
            model: "gpt-5.4",
            baselineConfig: baseline
        )
        XCTAssertEqual(withoutPreferences.approvalPolicy, "on-request")
        XCTAssertEqual(withoutPreferences.sandboxMode, .workspaceWrite)

        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)

        let withPreferences = model.requestedThreadExecutionOptions(
            session: session,
            cwd: session.workspaceRoot,
            model: "gpt-5.4",
            baselineConfig: baseline
        )
        XCTAssertEqual(withPreferences.approvalPolicy, "never")
        XCTAssertEqual(withPreferences.sandboxMode, .dangerFullAccess)
    }

    func testRequestedTurnExecutionOptionsFallBackToSessionExecutionProfileWhenPreferencesAreMissing() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                support: CodexExecutionSupportSnapshot(threadResumeOverrides: .unsupported),
                profile: CodexExecutionProfile(
                    approvalPolicy: .init(
                        requested: "on-request",
                        effective: "on-request",
                        status: .effective
                    ),
                    sandboxMode: .init(
                        requested: "workspace-write",
                        effective: "workspace-write",
                        status: .effective
                    )
                )
            )
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )

        let withoutPreferences = model.requestedTurnExecutionOptions(
            session: session,
            model: "gpt-5.4",
            effort: .medium,
            collaborationMode: nil
        )
        XCTAssertEqual(withoutPreferences.approvalPolicy, "on-request")
        XCTAssertEqual(
            withoutPreferences.sandboxPolicy,
            .workspaceWrite(
                writableRoots: [session.workspaceRoot ?? ""],
                readAccess: .fullAccess,
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        )

        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)

        let withPreferences = model.requestedTurnExecutionOptions(
            session: session,
            model: "gpt-5.4",
            effort: .medium,
            collaborationMode: nil
        )
        XCTAssertEqual(withPreferences.approvalPolicy, "never")
        XCTAssertEqual(withPreferences.sandboxPolicy, .dangerFullAccess)
    }

    @MainActor
    func testResumeSessionProjectsPreferredExecutionDefaultsOntoActivatedSession() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            sceneID: nil,
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-resume-full-access",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .disconnected,
            lastOpenedAt: .now
        )
        let model = AppModel(
            sceneID: "preferred-defaults-activation",
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )

        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)
        model.resumeSession(session.id, reconnect: false)

        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.approvalPolicy.requested, "never")
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.approvalPolicy.status, .requested)
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.sandboxMode.requested, "danger-full-access")
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.sandboxMode.status, .requested)
    }

    @MainActor
    func testRequiresLiveThreadBindingBeforeTurnStartWhenOnlySessionThreadExists() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-needs-live-bind",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )

        XCTAssertTrue(model.requiresLiveThreadBindingBeforeTurnStart(preferredThreadID: nil))
        XCTAssertNil(model.boundProtocolThreadID(preferredThreadID: nil))
        XCTAssertEqual(model.activeSession?.threadID, session.threadID)
    }

    @MainActor
    func testResumeSessionStillRequiresLiveThreadBindingBeforeTurnStartUntilProtocolResumeSucceeds() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-live-bound",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )

        model.resumeSession(session.id, reconnect: false)

        XCTAssertTrue(model.requiresLiveThreadBindingBeforeTurnStart(preferredThreadID: nil))
        XCTAssertNil(model.boundProtocolThreadID(preferredThreadID: nil))
        XCTAssertEqual(model.activeSession?.threadID, session.threadID)
    }

    @MainActor
    func testSettingPreferredExecutionDefaultsProjectsRequestedAuthorityOntoActiveSession() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                support: CodexExecutionSupportSnapshot(threadResumeOverrides: .supported),
                profile: CodexExecutionProfile(
                    approvalPolicy: .init(
                        effective: "on-request",
                        status: .effective
                    ),
                    sandboxMode: .init(
                        effective: "workspace-write",
                        status: .effective
                    )
                )
            )
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)

        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: on-request (requested never)")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: workspace-write (requested danger-full-access)")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: constrained")
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.approvalPolicy.requested, "never")
        XCTAssertEqual(model.activeSession?.executionProfileState?.profile.sandboxMode.requested, "danger-full-access")
    }

    func testAppModelRestoresExecutionAndReasoningPreferencesFromSnapshot() {
        let machine = MachineRecord.preview
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(
                preferredMachineID: machine.id,
                preferredReasoningEffort: "xhigh",
                preferredApprovalPolicy: "never",
                preferredSandboxMode: "danger-full-access"
            )
        )

        let model = AppModel(sceneID: "preferred-execution-defaults", bootstrapSnapshot: snapshot)

        XCTAssertEqual(model.selectedReasoningEffort, .xhigh)
        XCTAssertEqual(model.preferredApprovalPolicy, "never")
        XCTAssertEqual(model.preferredSandboxMode, .dangerFullAccess)
        XCTAssertEqual(model.preferredApprovalPolicyLabel, "Never")
        XCTAssertEqual(model.preferredSandboxModeLabel, "Full access")
    }

    @MainActor
    func testApplyRequestedTurnExecutionProfileStateShowsRequestedAuthorityForOverriddenTurn() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                support: CodexExecutionSupportSnapshot(turnStartOverrides: .unknown),
                profile: CodexExecutionProfile(
                    approvalPolicy: .init(
                        requested: "on-request",
                        effective: "on-request",
                        status: .effective
                    ),
                    sandboxMode: .init(
                        requested: "workspace-write",
                        effective: "workspace-write",
                        status: .effective
                    )
                )
            )
        )
        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        model.applyRequestedTurnExecutionProfileState(
            CodexTurnExecutionOptions(
                approvalPolicy: "never",
                sandboxPolicy: .dangerFullAccess
            )
        )

        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: requested never")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: requested danger-full-access")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: requested")
        XCTAssertNil(model.activeSession?.executionProfileState?.profile.approvalPolicy.effective)
        XCTAssertNil(model.activeSession?.executionProfileState?.profile.sandboxMode.effective)
    }

    func testResumeHostThreadCatalogEntryClearsArchivedFlagOnExistingSession() {
        let machine = MachineRecord.preview
        let existingSession = SessionRecord(
            sceneID: "host-catalog-unarchive",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 10),
            transportState: .disconnected,
            lastErrorSummary: nil,
            parentThreadID: nil,
            isArchived: true
        )
        let entry = HostThreadCatalogEntry(
            id: "thread-real-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Fix Codex client UX",
            preview: "Finish the real Project and Thread browser.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [existingSession],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "host-catalog-unarchive", bootstrapSnapshot: snapshot)

        _ = model.resumeHostThreadCatalogEntry(entry, reconnect: false)

        XCTAssertFalse(model.recentSessions.first?.isArchived ?? true)
        XCTAssertEqual(model.activeSession?.threadID, entry.id)
    }

    func testSelectedMachineNeedsHostThreadCatalogRefreshOnFreshLaunchEvenWithCachedThreads() {
        let machine = MachineRecord.preview
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [
                HostThreadCatalogEntry(
                    id: "thread-real-123",
                    machineID: machine.id,
                    workspaceRoot: "/workspace/coding-on-the-go",
                    name: "Fix Codex client UX",
                    preview: "Finish the real Project and Thread browser.",
                    modelProvider: "openai",
                    createdAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )

        let model = AppModel(sceneID: "cached-host-browser", bootstrapSnapshot: snapshot)

        XCTAssertTrue(model.selectedMachineNeedsHostThreadCatalogRefresh)
    }

    func testSelectingDifferentMachineRequiresFreshHostThreadCatalogFetch() {
        let snapshot = MachineDirectorySnapshot.preview
        let model = AppModel(sceneID: "switch-machine-browser-refresh", bootstrapSnapshot: snapshot)

        XCTAssertTrue(model.selectedMachineNeedsHostThreadCatalogRefresh)

        model.select(machineID: MachineRecord.secondaryPreview.id)

        XCTAssertTrue(model.selectedMachineNeedsHostThreadCatalogRefresh)
    }

    func testRestoredHostThreadCatalogUsesCachedProvenanceUntilRefreshed() {
        let machine = MachineRecord.preview
        let observedAt = Date(timeIntervalSince1970: 321)
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [
                HostThreadCatalogEntry(
                    id: "thread-live-1",
                    machineID: machine.id,
                    workspaceRoot: "/workspace/coding-on-the-go",
                    name: "Finish remote Codex client",
                    preview: "Keep the browser honest.",
                    modelProvider: "openai",
                    createdAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 200),
                    observedAt: observedAt,
                    provenance: .liveAppServer
                )
            ],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )

        let model = AppModel(sceneID: "cached-provenance", bootstrapSnapshot: snapshot)

        XCTAssertEqual(model.selectedMachineHostThreadCatalogProvenance, .cachedHostCatalog)
        XCTAssertEqual(model.selectedMachineHostThreadCatalogObservedAt, observedAt)
    }

    func testReplacingHostThreadCatalogEntriesPreservesSQLiteRepairProvenance() {
        let machine = MachineRecord.preview
        let observedAt = Date(timeIntervalSince1970: 555)
        let thread = CodexThreadSummary(
            id: "thread-sqlite-repair",
            cwd: "/workspace/coding-on-the-go",
            preview: "Repair missing workspace roots without pretending sqlite is canonical.",
            modelProvider: "openai",
            name: "Repair host browser provenance",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            status: .idle
        )

        let replacement = AppHostThreadCatalogCoordinator.replacingEntries(
            [thread],
            machine: machine,
            hostThreadCatalog: [],
            recentSessions: [],
            activeProtocolKind: .stdio,
            routeID: nil,
            routeKind: nil,
            bootstrap: .standardSSH,
            normalizeWorkspaceRoot: { $0 },
            workspaceMode: { _ in .local },
            provenanceByThreadID: [thread.id: .sqliteRepaired],
            observedAt: observedAt
        )

        let entry = replacement.hostThreadCatalog.first
        XCTAssertEqual(entry?.provenance, .sqliteRepaired)
        XCTAssertEqual(entry?.observedAt, observedAt)
    }

    func testReplacingHostThreadCatalogEntriesWithEmptyLiveResultClearsSelectedMachineCatalog() {
        let machine = MachineRecord.preview
        let otherMachineID = UUID()
        let staleEntry = HostThreadCatalogEntry(
            id: "thread-stale-selected-machine",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Stale selected thread",
            preview: "Should disappear when the live host reports no threads.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            observedAt: Date(timeIntervalSince1970: 300),
            provenance: .cachedHostCatalog
        )
        let otherMachineEntry = HostThreadCatalogEntry(
            id: "thread-other-machine",
            machineID: otherMachineID,
            workspaceRoot: "/workspace/other",
            name: "Other machine thread",
            preview: "Should stay visible.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 210),
            observedAt: Date(timeIntervalSince1970: 310),
            provenance: .cachedHostCatalog
        )

        let replacement = AppHostThreadCatalogCoordinator.replacingEntries(
            [],
            machine: machine,
            hostThreadCatalog: [staleEntry, otherMachineEntry],
            recentSessions: [],
            activeProtocolKind: .stdio,
            routeID: nil,
            routeKind: nil,
            bootstrap: .standardSSH,
            normalizeWorkspaceRoot: { $0 },
            workspaceMode: { _ in .local },
            provenanceByThreadID: [:],
            observedAt: Date(timeIntervalSince1970: 400)
        )

        XCTAssertFalse(
            replacement.hostThreadCatalog.contains(where: {
                $0.machineID == machine.id && $0.id == staleEntry.id
            })
        )
        XCTAssertTrue(
            replacement.hostThreadCatalog.contains(where: {
                $0.machineID == otherMachineID && $0.id == otherMachineEntry.id
            })
        )
    }

    func testPrepareNewSessionCreatesDistinctSessionRecordForSelectedRepo() {
        let model = AppModel(sceneID: "new-session-scene", bootstrapSnapshot: .preview)
        let targetMachine = MachineRecord.preview
        let existingSession = SessionRecord(
            sceneID: "new-session-scene",
            machineID: targetMachine.id,
            routeID: targetMachine.preferredRoute?.id,
            threadID: "thread-existing-123",
            workspaceRoot: "/tmp/cotg-existing-repo",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: targetMachine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )

        model.select(machineID: targetMachine.id)
        model.recentSessions = [existingSession]

        let newSessionID = model.prepareNewSession(
            machineID: targetMachine.id,
            workspaceRoot: "/tmp/cotg-new-repo",
            reconnect: false
        )

        XCTAssertNotNil(newSessionID)
        XCTAssertNotEqual(newSessionID, existingSession.id)
        XCTAssertEqual(model.recentSessions.count, 2)
        XCTAssertEqual(
            model.recentSessions.first(where: { $0.id == newSessionID })?.workspaceRoot,
            "/tmp/cotg-new-repo"
        )
        XCTAssertEqual(
            model.recentSessions.first(where: { $0.id == newSessionID })?.lastMode,
            .local
        )
        XCTAssertNil(model.recentSessions.first(where: { $0.id == newSessionID })?.threadID)

        model.resumeSession(existingSession.id, reconnect: false)

        XCTAssertEqual(model.activeSession?.id, existingSession.id)
        XCTAssertEqual(model.activeSession?.threadID, "thread-existing-123")
        XCTAssertEqual(model.recentSessions.count, 2)
    }

    func testPreviewBootstrapSeedsInitialSessionWithRecommendedRouteInsteadOfPreferredDefault() {
        let model = AppModel(sceneID: "recommended-bootstrap", bootstrapSnapshot: .preview)
        let initialRouteID = model.activeSession?.routeID
        let lanRouteID = MachineRecord.preview.route(for: .localLAN)?.id

        XCTAssertEqual(initialRouteID, lanRouteID)
        XCTAssertEqual(model.activeSession?.lastKnownRouteKind, .localLAN)
    }

    func testPrepareNewSessionUsesRecommendedRouteInsteadOfPreferredDefault() {
        let model = AppModel(sceneID: "recommended-new-session", bootstrapSnapshot: .preview)
        let targetMachine = MachineRecord.preview

        model.select(machineID: targetMachine.id)
        let newSessionID = model.prepareNewSession(
            machineID: targetMachine.id,
            workspaceRoot: "/tmp/cotg-best-route",
            reconnect: false
        )

        let newSession = model.recentSessions.first(where: { $0.id == newSessionID })
        XCTAssertEqual(newSession?.routeID, targetMachine.route(for: .localLAN)?.id)
        XCTAssertEqual(newSession?.lastKnownRouteKind, .localLAN)
    }

    func testPrepareNewSessionSeedsExecutionProfileFromCurrentMachineSession() {
        let machine = MachineRecord.preview
        let seededExecutionProfileState = CodexExecutionProfileState(
            profile: CodexExecutionProfile(
                approvalPolicy: .init(
                    requested: "on-request",
                    effective: "on-request",
                    status: .effective
                ),
                sandboxMode: .init(
                    requested: "workspace-write",
                    effective: "workspace-write",
                    status: .effective
                ),
                networkAccess: .init(
                    requested: true,
                    effective: true,
                    status: .effective
                )
            )
        )
        let connectedSession = SessionRecord(
            sceneID: "new-session-seeded",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 10),
            transportState: .connected,
            executionProfileState: seededExecutionProfileState
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [connectedSession],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "new-session-seeded", bootstrapSnapshot: snapshot)
        model.select(machineID: machine.id)

        let newSessionID = model.prepareNewSession(
            machineID: machine.id,
            workspaceRoot: "/tmp/cotg-new-repo",
            reconnect: false
        )

        XCTAssertEqual(
            model.recentSessions.first(where: { $0.id == newSessionID })?.executionProfileState,
            seededExecutionProfileState
        )
    }

    func testPrepareNewSessionStaysDistinctFromExistingHostThread() {
        let machine = MachineRecord.preview
        let existingSession = SessionRecord(
            sceneID: "new-thread-distinct",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-real-123",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let entry = HostThreadCatalogEntry(
            id: "thread-real-123",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Fix Codex client UX",
            preview: "Finish the real Project and Thread browser.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [existingSession],
            hostThreadCatalog: [entry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let model = AppModel(sceneID: "new-thread-distinct", bootstrapSnapshot: snapshot)
        model.select(machineID: machine.id)

        let newSessionID = model.prepareNewSession(
            machineID: machine.id,
            workspaceRoot: entry.workspaceRoot,
            reconnect: false
        )

        XCTAssertNotNil(newSessionID)
        XCTAssertNotEqual(newSessionID, existingSession.id)
        XCTAssertEqual(model.recentSessions.count, 2)
        XCTAssertNil(model.activeSession?.threadID)
        XCTAssertEqual(model.activeSession?.workspaceRoot, entry.workspaceRoot)
    }

    func testPrepareNewSessionUsesWorktreeModeForWorktreePaths() {
        let model = AppModel(sceneID: "new-session-worktree", bootstrapSnapshot: .preview)
        let targetMachine = MachineRecord.preview

        model.select(machineID: targetMachine.id)

        let newSessionID = model.prepareNewSession(
            machineID: targetMachine.id,
            workspaceRoot: "/tmp/CodingOnTheGo-worktrees/feature-browser",
            reconnect: false
        )

        XCTAssertEqual(
            model.recentSessions.first(where: { $0.id == newSessionID })?.lastMode,
            .worktree
        )
    }

    func testBrowseWorkspaceDirectoriesInDemoModeMarksCurrentRepo() async throws {
        UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        }

        let model = AppModel(sceneID: "demo-workspace-browser")
        model.setDemoModeEnabled(true)

        let projects = try await model.browseWorkspaceDirectories(at: "/workspace")
        XCTAssertFalse(projects.isCurrentPathGitRepository)
        XCTAssertNil(projects.parentPath)
        XCTAssertEqual(projects.entries.first?.name, "coding-on-the-go")
        XCTAssertTrue(projects.entries.first?.isGitRepository == true)

        let repo = try await model.browseWorkspaceDirectories(at: "/workspace/coding-on-the-go")
        XCTAssertTrue(repo.isCurrentPathGitRepository)
        XCTAssertEqual(repo.currentPath, "/workspace/coding-on-the-go")
        XCTAssertEqual(repo.parentPath, "/workspace")
        XCTAssertTrue(repo.entries.isEmpty)
    }

    func testRestoreAdoptsMostRecentSessionAcrossNewSceneIdentifier() async throws {
        let metadataPath = "/tmp/cotg-relaunch-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-relaunch-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let source = AppModel(sceneID: "old-scene", bootstrapSnapshot: .preview)
        source.select(machineID: MachineRecord.preview.id)
        source.recentSessions = [
            SessionRecord(
                sceneID: "old-scene",
                machineID: MachineRecord.preview.id,
                routeID: MachineRecord.preview.preferredRoute?.id,
                threadID: "thread-relaunch-123",
                workspaceRoot: "/tmp/cotg-relaunch",
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: MachineRecord.preview.preferredRoute?.kind,
                lastKnownBootstrap: .standardSSH,
                transportState: .connected,
                lastOpenedAt: .now
            )
        ]
        source.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(400))

        let restored = AppModel(sceneID: "new-scene", bootstrapSnapshot: .preview)
        let context = await restored.restorePersistedState()

        XCTAssertTrue(context.shouldRestoreDetail)
        XCTAssertEqual(restored.selectedMachineID, MachineRecord.preview.id)
        XCTAssertEqual(restored.activeSession?.threadID, "thread-relaunch-123")
        XCTAssertEqual(restored.activeSession?.sceneID, "new-scene")
    }

    func testRestoreLaunchContextKeepsSceneScopedSessionSelection() async throws {
        let metadataPath = "/tmp/cotg-relaunch-scene-session-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-relaunch-scene-session-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let source = AppModel(sceneID: "restore-scene", bootstrapSnapshot: .preview)
        source.select(machineID: MachineRecord.preview.id)

        let sceneScopedSession = SessionRecord(
            sceneID: "restore-scene",
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.preferredRoute?.id,
            threadID: "thread-scene-selected",
            workspaceRoot: "/tmp/cotg-restore-scene",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: MachineRecord.preview.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: Date(timeIntervalSinceNow: -120)
        )
        let newerSharedSession = SessionRecord(
            sceneID: nil,
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.preferredRoute?.id,
            threadID: "thread-shared-newer",
            workspaceRoot: "/tmp/cotg-restore-shared",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: MachineRecord.preview.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connected,
            lastOpenedAt: .now
        )

        source.recentSessions = [newerSharedSession, sceneScopedSession]
        source.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(400))

        let restored = AppModel(sceneID: "restore-scene", bootstrapSnapshot: .preview)
        let context = await restored.restorePersistedState()

        XCTAssertEqual(context.selectedMachineID, MachineRecord.preview.id)
        XCTAssertEqual(context.selectedSessionID, sceneScopedSession.id)
        XCTAssertEqual(restored.activeSession?.id, sceneScopedSession.id)
        XCTAssertEqual(restored.activeSession?.threadID, "thread-scene-selected")
    }

    func testRestoreSeedsHostThreadCatalogEntryForRestoredSession() async throws {
        let metadataPath = "/tmp/cotg-relaunch-browser-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-relaunch-browser-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let source = AppModel(sceneID: "old-scene", bootstrapSnapshot: .preview)
        source.select(machineID: MachineRecord.preview.id)
        source.recentSessions = [
            SessionRecord(
                sceneID: "old-scene",
                machineID: MachineRecord.preview.id,
                routeID: MachineRecord.preview.preferredRoute?.id,
                threadID: "thread-relaunch-456",
                workspaceRoot: "/tmp/cotg-relaunch-browser",
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: MachineRecord.preview.preferredRoute?.kind,
                lastKnownBootstrap: .standardSSH,
                lastModel: "gpt-5.4",
                lastTurn: RecentTurnMetadata(
                    turnID: "turn-123",
                    summary: "Persisted restored thread",
                    completedAt: .now
                ),
                transportState: .connected,
                lastOpenedAt: .now
            )
        ]
        source.hostThreadCatalog = []
        source.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(400))

        let restored = AppModel(sceneID: "new-scene", bootstrapSnapshot: .preview)
        _ = await restored.restorePersistedState()

        let entry = try XCTUnwrap(restored.hostThreadCatalog.first(where: { $0.id == "thread-relaunch-456" }))
        XCTAssertEqual(entry.workspaceRoot, "/tmp/cotg-relaunch-browser")
        XCTAssertEqual(entry.name, nil)
        XCTAssertEqual(entry.preview, "Restored thread")
    }

    func testRestoreDeduplicatesHostThreadCatalogEntriesWithSameMachineAndThread() async throws {
        let metadataPath = "/tmp/cotg-relaunch-dedupe-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-relaunch-dedupe-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let duplicateID = "thread-duplicate"
        let older = HostThreadCatalogEntry(
            id: duplicateID,
            machineID: MachineRecord.preview.id,
            workspaceRoot: "/tmp/cotg-older",
            name: nil,
            preview: "Older preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = HostThreadCatalogEntry(
            id: duplicateID,
            machineID: MachineRecord.preview.id,
            workspaceRoot: "/tmp/cotg-newer",
            name: "Newest title",
            preview: "Newer preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let snapshot = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [older, newer],
            preferences: UserPreferencesSnapshot(preferredMachineID: MachineRecord.preview.id)
        )
        try await JSONMetadataStore().save(snapshot, to: URL(fileURLWithPath: metadataPath))

        let restored = AppModel(sceneID: "dedupe-scene", bootstrapSnapshot: .preview)
        _ = await restored.restorePersistedState()

        let matchingEntries = restored.hostThreadCatalog.filter {
            $0.machineID == MachineRecord.preview.id && $0.id == duplicateID
        }
        XCTAssertEqual(matchingEntries.count, 1)
        XCTAssertEqual(matchingEntries.first?.workspaceRoot, "/tmp/cotg-newer")
        XCTAssertEqual(matchingEntries.first?.name, "Newest title")
    }

    func testReconcilePersistedLocalStateKeepsLiveHostThreadCatalogProvenanceInMemory() async throws {
        let metadataPath = "/tmp/cotg-reconcile-live-host-catalog-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-reconcile-live-host-catalog-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let threadID = "thread-live-host-catalog"
        let workspaceRoot = "/tmp/cotg-live-host-catalog"
        let observedAt = Date(timeIntervalSince1970: 350)
        let persistedSession = SessionRecord(
            sceneID: "persisted-scene",
            machineID: MachineRecord.preview.id,
            routeID: MachineRecord.preview.preferredRoute?.id,
            threadID: threadID,
            threadDisplayTitle: "app store upload",
            workspaceRoot: workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: MachineRecord.preview.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastMode: .local,
            lastOpenedAt: Date(timeIntervalSince1970: 360)
        )
        let persistedEntry = HostThreadCatalogEntry(
            id: threadID,
            machineID: MachineRecord.preview.id,
            workspaceRoot: workspaceRoot,
            name: "app store upload",
            preview: "Persisted cached browser entry",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300),
            observedAt: observedAt,
            provenance: .cachedHostCatalog
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [MachineRecord.preview],
            tailnetProfiles: [],
            recentSessions: [persistedSession],
            hostThreadCatalog: [persistedEntry],
            preferences: UserPreferencesSnapshot(preferredMachineID: MachineRecord.preview.id)
        )
        try await JSONMetadataStore().save(snapshot, to: URL(fileURLWithPath: metadataPath))

        let model = AppModel(sceneID: "reconcile-live-host-catalog", bootstrapSnapshot: .preview)
        model.hostThreadCatalog = [
            HostThreadCatalogEntry(
                id: threadID,
                machineID: MachineRecord.preview.id,
                workspaceRoot: workspaceRoot,
                name: "app store upload",
                preview: "Live app-server browser entry",
                modelProvider: "openai",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 300),
                observedAt: observedAt,
                provenance: .liveAppServer
            )
        ]

        await model.reconcilePersistedLocalStateIfNeeded()
        try await Task.sleep(for: .milliseconds(500))

        let liveEntry = try XCTUnwrap(model.hostThreadCatalog.first(where: { $0.id == threadID }))
        XCTAssertEqual(liveEntry.provenance, .liveAppServer)
        XCTAssertTrue(model.recentSessions.contains(where: { $0.threadID == threadID }))

        let restored = AppModel(sceneID: "reconcile-live-host-catalog-restored", bootstrapSnapshot: .preview)
        _ = await restored.restorePersistedState()

        let restoredEntry = try XCTUnwrap(restored.hostThreadCatalog.first(where: { $0.id == threadID }))
        XCTAssertEqual(restoredEntry.provenance, .cachedHostCatalog)
    }

    func testReconcilePersistedLocalStateRestoresSessionsAndHostCatalogWhenBootstrapStateIsBlank() async throws {
        let metadataPath = "/tmp/cotg-reconcile-session-state-\(UUID().uuidString)-metadata.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
        }

        let machineID = UUID()
        let routeID = UUID()
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: routeID,
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    sshPort: 22,
                    health: .healthy,
                    discoverySource: .cachedProbe,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let persistedSession = SessionRecord(
            sceneID: nil,
            machineID: machineID,
            routeID: routeID,
            threadID: "thread-app-store-upload",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .localLAN,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastTurn: RecentTurnMetadata(
                turnID: "turn-app-store-upload",
                summary: "app store upload",
                completedAt: Date(timeIntervalSince1970: 300)
            ),
            transportState: .disconnected,
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )
        let catalogEntry = HostThreadCatalogEntry(
            id: "thread-app-store-upload",
            machineID: machineID,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "app store upload",
            preview: "App Store upload state",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        try JSONMetadataStore().saveSynchronously(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [persistedSession],
                hostThreadCatalog: [catalogEntry],
                preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
            ),
            to: URL(fileURLWithPath: metadataPath)
        )

        let model = AppModel(
            sceneID: "reconcile-session-state",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )

        XCTAssertNil(model.activeSessionID)
        XCTAssertTrue(model.hostThreadCatalog.isEmpty)
        XCTAssertTrue(model.recentSessions.allSatisfy { $0.threadID == nil })

        await model.reconcilePersistedLocalStateIfNeeded()

        XCTAssertEqual(model.selectedMachineID, machineID)
        XCTAssertEqual(model.activeSession?.id, persistedSession.id)
        XCTAssertEqual(model.activeSession?.threadID, persistedSession.threadID)
        XCTAssertTrue(model.recentSessions.contains(where: { $0.id == persistedSession.id }))
        XCTAssertTrue(model.hostThreadCatalog.contains(where: {
            $0.machineID == machineID && $0.id == catalogEntry.id && $0.name == "app store upload"
        }))
    }

    func testReconcilePersistedLocalStateDoesNotReplaceExistingActiveSession() async throws {
        let metadataPath = "/tmp/cotg-reconcile-active-session-\(UUID().uuidString)-metadata.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
        }

        let machineID = UUID()
        let routeID = UUID()
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: routeID,
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    sshPort: 22,
                    health: .healthy,
                    discoverySource: .cachedProbe,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let persistedSession = SessionRecord(
            sceneID: nil,
            machineID: machineID,
            routeID: routeID,
            threadID: "thread-app-store-upload",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .localLAN,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastTurn: RecentTurnMetadata(
                turnID: "turn-app-store-upload",
                summary: "app store upload",
                completedAt: Date(timeIntervalSince1970: 300)
            ),
            transportState: .disconnected,
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )

        try JSONMetadataStore().saveSynchronously(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [persistedSession],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
            ),
            to: URL(fileURLWithPath: metadataPath)
        )

        let model = AppModel(
            sceneID: "reconcile-active-session",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        let currentSessionID = try XCTUnwrap(
            model.prepareNewSession(
                machineID: machineID,
                workspaceRoot: "/workspace/coding-on-the-go/current"
            )
        )
        XCTAssertEqual(model.activeSession?.id, currentSessionID)
        XCTAssertNil(model.activeSession?.threadID)

        await model.reconcilePersistedLocalStateIfNeeded()

        XCTAssertEqual(model.activeSession?.id, currentSessionID)
        XCTAssertTrue(model.recentSessions.contains(where: { $0.id == persistedSession.id }))
    }

    func testReconcilePersistedLocalStateRestoresTrustedRouteAndCredential() async throws {
        let metadataPath = "/tmp/cotg-reconcile-local-\(UUID().uuidString)-metadata.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
        }

        let machineID = UUID()
        let routeID = UUID()
        let trustedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        let persistedMachine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            stableHostFingerprint: "SHA256:trusted-fingerprint",
            lastKnownUser: "developer",
            preferredRouteID: routeID,
            lastSuccessfulRouteID: routeID,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.restore",
                label: "SSH private key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain
            ),
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Embedded Tailnet",
                    hostname: "example-mac.example.ts.net",
                    sshPort: 22,
                    usernameHint: "developer",
                    health: .healthy,
                    lastSuccessAt: .now,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: trustedKey
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let persistedSnapshot = MachineDirectorySnapshot(
            machines: [persistedMachine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )
        try await JSONMetadataStore().save(persistedSnapshot, to: URL(fileURLWithPath: metadataPath))

        let vault = InMemorySecretVault()
        try await vault.store(
            SecretPayload(
                reference: persistedMachine.credentialRef!,
                value: Data(repeating: 3, count: 32)
            )
        )
        let model = AppModel(
            sceneID: "reconcile-local-state",
            secretVault: vault
        )

        _ = await model.restorePersistedState()

        let reconciled = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.selectedMachine?.credentialRef?.kind == .sshKey
                && model.selectedMachine?.lastKnownUser == "developer"
                && model.selectedMachine?.route(id: routeID)?.usernameHint == "developer"
                && model.selectedMachine?.route(id: routeID)?.trustState == .trusted
                && model.selectedMachine?.route(id: routeID)?.trustedOpenSSHPublicKey == trustedKey
        }

        XCTAssertTrue(reconciled)
        XCTAssertEqual(model.selectedMachine?.stableHostFingerprint, persistedMachine.stableHostFingerprint)
        XCTAssertNotNil(model.storedTrustedHostKeyFingerprint)
    }

    func testSelectingUnknownMachineKeepsCurrentValidTrustedMachine() {
        let trustedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        let tailnetMachineID = UUID()
        let lanMachineID = UUID()
        let tailnetRouteID = UUID()

        let localMachine = MachineRecord(
            id: lanMachineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            routes: [
                RouteRecord(
                    machineID: lanMachineID,
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    health: .healthy
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: lanMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let tailnetMachine = MachineRecord(
            id: tailnetMachineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: tailnetRouteID,
            lastSuccessfulRouteID: tailnetRouteID,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.live",
                label: "SSH private key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain
            ),
            routes: [
                RouteRecord(
                    id: tailnetRouteID,
                    machineID: tailnetMachineID,
                    kind: .embeddedTailnet,
                    label: "Embedded Tailnet",
                    hostname: "example-mac.example.ts.net",
                    magicDNSName: "example-mac.example.ts.net",
                    sshPort: 22,
                    tailnetProfileID: UUID(),
                    health: .healthy,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: trustedKey
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: tailnetMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let snapshot = MachineDirectorySnapshot(
            machines: [localMachine, tailnetMachine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(preferredMachineID: tailnetMachineID)
        )
        let model = AppModel(
            sceneID: "invalid-selection-scene",
            bootstrapSnapshot: snapshot,
            secretVault: InMemorySecretVault()
        )

        XCTAssertEqual(model.selectedMachineID, tailnetMachineID)

        model.select(machineID: UUID())

        XCTAssertEqual(model.selectedMachineID, tailnetMachineID)
        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .embeddedTailnet)
        XCTAssertTrue(model.connectionDebugStatusLabel.contains("credentialReady=true"))
        XCTAssertTrue(model.connectionDebugStatusLabel.contains("hostValidationReady=true"))
    }

    func testConnectionCandidateStatusDetailMarksSavedTailnetRouteBlockedWhenEndpointMissing() {
        let trustedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        let machineID = UUID()
        let routeID = UUID()

        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: routeID,
            lastSuccessfulRouteID: routeID,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.live",
                label: "SSH private key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain
            ),
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .embeddedTailnet,
                    label: "Embedded Tailnet",
                    hostname: "example-mac.example.ts.net",
                    magicDNSName: "example-mac.example.ts.net",
                    sshPort: 22,
                    tailnetProfileID: UUID(),
                    health: .healthy,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: trustedKey
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            sceneID: "route-blocked-detail",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )

        XCTAssertFalse(model.connectionCandidateIsReady)
        XCTAssertEqual(
            model.connectionCandidateStatusDetail,
            "Embedded Tailnet is saved, but the app still needs a reachable SSH endpoint for it."
        )
    }

    func testConnectionCandidateStatusDetailExplainsMissingTrustedLogin() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Subnet reachability",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            sceneID: "missing-login-detail",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )

        XCTAssertEqual(
            model.connectionCandidateStatusDetail,
            "No login is stored on this iPhone for @developer. Generate a device SSH key or save a password login. If you reinstalled the app, the previous saved login may no longer be available on this iPhone."
        )
    }

    func testConnectionCandidateStatusDetailExplainsNearbyLANIsBlockedOnCellular() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Subnet reachability",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.live",
                label: "SSH private key",
                username: "developer",
                storageScope: .localKeychain
            ),
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            sceneID: "cellular-lan-detail",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.allowsNearbyNetworkRoutes = false

        XCTAssertFalse(model.connectionCandidateIsReady)
        XCTAssertEqual(
            model.connectionCandidateStatusDetail,
            "Subnet reachability is saved, but it only works while this iPhone is on the same Wi-Fi or nearby network as the Mac. Add a Tailscale or remote SSH fallback before leaving home."
        )
    }

    func testConnectionFailureSummaryExplainsMissingTrustedLogin() async {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Subnet reachability",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            sceneID: "missing-login-failure-summary",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )

        let summary = await model.connectionFailureSummary()
        XCTAssertEqual(
            summary,
            "No login is stored on this iPhone for @developer. Generate a device SSH key or save a password login before you connect over SSH. If you reinstalled the app, the previous saved login may no longer be available on this iPhone."
        )
    }

    func testConnectionSetupCompletedStepCountReflectsRequiredSSHSetup() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Subnet reachability",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.live",
                label: "SSH private key",
                username: "developer",
                storageScope: .localKeychain
            ),
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            sceneID: "connection-setup-complete",
            machines: [machine],
            secretVault: InMemorySecretVault()
        )

        XCTAssertTrue(model.connectionSetupAccountReady)
        XCTAssertTrue(model.connectionSetupSSHAccessReady)
        XCTAssertTrue(model.connectionSetupLoginReady)
        XCTAssertTrue(model.connectionSetupTrustReady)
        XCTAssertEqual(model.connectionSetupCompletedStepCount, 4)
    }

    func testRuntimeSnapshotUsesLiveCapabilityDiagnostics() {
        let model = AppModel(bootstrapSnapshot: .preview)
        model.runtimeCapabilityDiagnostics = HostCapabilityDiagnostics(
            sshReachable: true,
            remoteLoginEnabled: true,
            codexInstalled: true,
            appServerAvailable: false,
            websocketSupported: false,
            authConfigured: true,
            hostKeyTrusted: true
        )

        let stdioStep = model.connectionPlan.first(where: { $0.lane == .stdioAppServer })
        let websocketStep = model.connectionPlan.first(where: { $0.lane == .sshForwardedLoopbackWebSocket })

        XCTAssertEqual(stdioStep?.readiness, .blocked)
        XCTAssertEqual(websocketStep?.readiness, .blocked)
    }

    func testReconcilePersistedLocalStateTransfersTrustAcrossMachineIDDriftAndDropsOrphanedLocalhostFixture() async throws {
        let metadataURL = URL(fileURLWithPath: "/tmp/cotg-reconcile-live-id-drift-\(UUID().uuidString).json")
        setenv("COTG_METADATA_PATH", metadataURL.path, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(at: metadataURL)
        }

        let trustedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx"
        let tailnetProfileID = UUID()
        let persistedMachineID = UUID()
        let persistedRouteID = UUID()
        let liveMachineID = UUID()
        let liveRouteID = UUID()

        let persistedMachine = MachineRecord(
            id: persistedMachineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: persistedRouteID,
            lastSuccessfulRouteID: persistedRouteID,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.live",
                label: "SSH private key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain
            ),
            routes: [
                RouteRecord(
                    id: persistedRouteID,
                    machineID: persistedMachineID,
                    kind: .externalTailnet,
                    label: "External Tailnet",
                    hostname: "example-mac.example.ts.net",
                    magicDNSName: "example-mac.example.ts.net",
                    sshPort: 22,
                    tailnetProfileID: tailnetProfileID,
                    health: .healthy,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: trustedKey
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: persistedMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let secretVault = InMemorySecretVault()
        try await secretVault.store(
            SecretPayload(
                reference: persistedMachine.credentialRef!,
                value: Data(repeating: 0x11, count: 32)
            )
        )

        try JSONMetadataStore().saveSynchronously(
            MachineDirectorySnapshot(
                machines: [persistedMachine],
                tailnetProfiles: [],
                recentSessions: [],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(preferredMachineID: persistedMachineID)
            ),
            to: metadataURL
        )

        let orphanFixture = MachineRecord(
            id: UUID(),
            displayName: "Local SSH",
            hostname: "192.168.1.133",
            notes: AppMachineDirectoryCoordinator.localhostTestingFixtureNote,
            routes: [
                RouteRecord(
                    kind: .manualSSH,
                    label: "Local SSH",
                    hostname: "192.168.1.133",
                    sshPort: 22,
                    health: .healthy,
                    discoverySource: .manual,
                    trustState: .unknown
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: UUID(),
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: false
            )
        )

        let liveMachine = MachineRecord(
            id: liveMachineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            preferredRouteID: liveRouteID,
            routes: [
                RouteRecord(
                    id: liveRouteID,
                    machineID: liveMachineID,
                    kind: .externalTailnet,
                    label: "External Tailnet",
                    hostname: "example-mac.example.ts.net",
                    magicDNSName: "example-mac.example.ts.net",
                    sshPort: 22,
                    tailnetProfileID: tailnetProfileID,
                    health: .healthy,
                    trustState: .unknown
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: liveMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            sceneID: "reconcile-live-id-drift",
            machines: [orphanFixture, liveMachine],
            secretVault: secretVault
        )
        model.selectedMachineID = orphanFixture.id

        await model.reconcilePersistedLocalStateIfNeeded()

        XCTAssertEqual(model.selectedMachineID, liveMachineID)
        XCTAssertEqual(model.machines.map(\.displayName), ["example-mac"])
        XCTAssertEqual(model.selectedMachine?.credentialRef?.username, "developer")
        XCTAssertEqual(model.selectedMachine?.lastKnownUser, "developer")
        XCTAssertEqual(model.selectedBootstrapRoute?.trustState, .trusted)
        XCTAssertEqual(model.selectedBootstrapRoute?.trustedOpenSSHPublicKey, trustedKey)
        XCTAssertTrue(model.connectionDebugStatusLabel.contains("credentialReady=true"))
        XCTAssertTrue(model.connectionDebugStatusLabel.contains("hostValidationReady=true"))
    }

    func testReconcilePersistedLocalStateScrubsPersistedLocalhostTestingFixtureFromLiveStore() async throws {
        let metadataURL = URL(fileURLWithPath: "/tmp/cotg-reconcile-scrub-localhost-fixture-\(UUID().uuidString).json")
        setenv("COTG_METADATA_PATH", metadataURL.path, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(at: metadataURL)
        }

        let fixtureMachineID = UUID()
        let fixtureRouteID = UUID()
        let liveMachineID = UUID()
        let liveRouteID = UUID()

        let persistedFixture = MachineRecord(
            id: fixtureMachineID,
            displayName: "Local SSH",
            hostname: "192.168.1.133",
            preferredRouteID: fixtureRouteID,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "cotg.testing.localhost.p",
                label: "Localhost testing key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain
            ),
            notes: AppMachineDirectoryCoordinator.localhostTestingFixtureNote,
            routes: [
                RouteRecord(
                    id: fixtureRouteID,
                    machineID: fixtureMachineID,
                    kind: .manualSSH,
                    label: "Cached probe",
                    hostname: "192.168.1.133",
                    sshPort: 22,
                    usernameHint: "developer",
                    health: .unavailable,
                    discoverySource: .cachedProbe,
                    trustState: .unknown
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: fixtureMachineID,
                remoteLoginEnabled: false,
                codexInstalled: false,
                supportsWebsocketListen: false
            )
        )

        let persistedLiveMachine = MachineRecord(
            id: liveMachineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: liveRouteID,
            routes: [
                RouteRecord(
                    id: liveRouteID,
                    machineID: liveMachineID,
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    sshPort: 22,
                    health: .healthy,
                    discoverySource: .cachedProbe,
                    trustState: .unknown
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: liveMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        try JSONMetadataStore().saveSynchronously(
            MachineDirectorySnapshot(
                machines: [persistedFixture, persistedLiveMachine],
                tailnetProfiles: [],
                recentSessions: [],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(preferredMachineID: fixtureMachineID)
            ),
            to: metadataURL
        )

        let model = AppModel(
            sceneID: "reconcile-scrub-localhost-fixture",
            machines: [persistedFixture, persistedLiveMachine],
            secretVault: InMemorySecretVault()
        )
        model.selectedMachineID = fixtureMachineID

        await model.reconcilePersistedLocalStateIfNeeded()

        XCTAssertEqual(model.machines.map { $0.displayName }, ["example-mac"])
        XCTAssertEqual(model.selectedMachineID, liveMachineID)

        try await Task.sleep(nanoseconds: 250_000_000)
        let saved = try await JSONMetadataStore().load(from: metadataURL)
        let didPersist = saved.machines.map(\.displayName) == ["example-mac"]
            && saved.preferences.preferredMachineID == liveMachineID
        XCTAssertTrue(didPersist)
    }

    func testRestorePersistedStateKeepsRealManualLocalSSHMachineWithoutFixtureMarker() async throws {
        let metadataPath = "/tmp/cotg-restore-real-local-ssh-\(UUID().uuidString)-metadata.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
        }

        let machineID = UUID()
        let routeID = UUID()
        let threadID = "thread-app-store-upload"
        let workspaceRoot = "/workspace/coding-on-the-go"
        let machine = MachineRecord(
            id: machineID,
            displayName: "Local SSH",
            hostname: "example-mac.local",
            preferredRouteID: routeID,
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Local SSH",
                    hostname: "example-mac.local",
                    sshPort: 22,
                    usernameHint: "developer",
                    health: .healthy,
                    discoverySource: .manual,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey restore-real-local-ssh"
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let session = SessionRecord(
            sceneID: "restore-real-local-ssh",
            machineID: machineID,
            routeID: routeID,
            threadID: threadID,
            workspaceRoot: workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .manualSSH,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastTurn: RecentTurnMetadata(
                turnID: "turn-restore-real-local-ssh",
                summary: "app store upload",
                completedAt: .now
            ),
            transportState: .connected,
            lastOpenedAt: .now
        )
        let entry = HostThreadCatalogEntry(
            id: threadID,
            machineID: machineID,
            workspaceRoot: workspaceRoot,
            name: "app store upload",
            preview: "Resume the existing upload thread",
            modelProvider: "openai",
            createdAt: .now.addingTimeInterval(-300),
            updatedAt: .now
        )

        try await JSONMetadataStore().save(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [session],
                hostThreadCatalog: [entry],
                preferences: UserPreferencesSnapshot(
                    preferredMachineID: machineID,
                    restoreLastSessionOnLaunch: true
                )
            ),
            to: URL(fileURLWithPath: metadataPath)
        )

        let model = AppModel(sceneID: "restore-real-local-ssh")

        let launchContext = await model.restorePersistedState()

        XCTAssertEqual(model.machines.map(\.displayName), ["Local SSH"])
        XCTAssertEqual(model.selectedMachineID, machineID)
        XCTAssertEqual(model.activeSession?.id, session.id)
        XCTAssertEqual(model.activeSession?.threadID, threadID)
        XCTAssertEqual(model.hostThreadCatalog.map(\.id), [threadID])
        XCTAssertEqual(launchContext.selectedMachineID, machineID)
        XCTAssertEqual(launchContext.selectedSessionID, session.id)
        XCTAssertTrue(launchContext.shouldRestoreDetail)
    }

    func testRestoreSkipsStaleSceneScopedConnectingWorkspaceSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration.localOnly(paths: paths)
        let machine = MachineRecord.preview
        let staleSession = SessionRecord(
            sceneID: "simulator-scene",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connecting,
            lastOpenedAt: Date(timeIntervalSinceNow: -86_400)
        )
        let healthySession = SessionRecord(
            sceneID: "other-scene",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: "thread-healthy-websocket",
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .websocket,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.5",
            transportState: .connected,
            lastOpenedAt: .now
        )

        try await JSONMetadataStore().save(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [staleSession, healthySession],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(
                    preferredMachineID: machine.id,
                    restoreLastSessionOnLaunch: true
                )
            ),
            to: paths.metadataStoreURL
        )

        let model = AppModel(
            sceneID: "simulator-scene",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: NoopCloudKitSyncCoordinator(),
            startRuntimeServices: false
        )

        let launchContext = await model.restorePersistedState()

        XCTAssertEqual(launchContext.selectedSessionID, healthySession.id)
        XCTAssertEqual(model.activeSession?.id, healthySession.id)
        XCTAssertEqual(model.activeSession?.threadID, "thread-healthy-websocket")
        let restoredStale = try XCTUnwrap(model.recentSessions.first(where: { $0.id == staleSession.id }))
        XCTAssertEqual(restoredStale.transportState, .disconnected)
        XCTAssertTrue(model.canRestoreSessionOnLaunch(healthySession.id))
        XCTAssertFalse(model.canRestoreSessionOnLaunch(staleSession.id))
    }

    func testRestoreDropsOnlyStaleConnectingWorkspaceSessionWhenNoThreadExists() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration.localOnly(paths: paths)
        let machine = MachineRecord.preview
        let staleSession = SessionRecord(
            sceneID: "only-stale-scene",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            transportState: .connecting,
            lastOpenedAt: .now
        )

        try await JSONMetadataStore().save(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [staleSession],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(
                    preferredMachineID: machine.id,
                    restoreLastSessionOnLaunch: true
                )
            ),
            to: paths.metadataStoreURL
        )

        let model = AppModel(
            sceneID: "only-stale-scene",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: NoopCloudKitSyncCoordinator(),
            startRuntimeServices: false
        )

        let launchContext = await model.restorePersistedState()

        XCTAssertEqual(launchContext.selectedMachineID, machine.id)
        XCTAssertNil(launchContext.selectedSessionID)
        XCTAssertFalse(launchContext.shouldRestoreDetail)
        XCTAssertNil(model.activeSessionID)
        let restoredStale = try XCTUnwrap(model.recentSessions.first(where: { $0.id == staleSession.id }))
        XCTAssertEqual(restoredStale.transportState, .disconnected)
    }

    func testReconcilePersistedLocalStateKeepsRealEmbeddedTailnetMachineUsingExistingTestingKeyAccount() async throws {
        let metadataURL = URL(fileURLWithPath: "/tmp/cotg-reconcile-keep-embedded-machine-\(UUID().uuidString).json")
        setenv("COTG_METADATA_PATH", metadataURL.path, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(at: metadataURL)
        }

        let machineID = UUID()
        let routeID = UUID()
        let tailnetProfileID = UUID()
        let embeddedProfile = TailnetProfile(
            id: tailnetProfileID,
            displayName: "Embedded Tailnet",
            kind: .embedded,
            controlURL: URL(string: "https://controlplane.tailscale.com")!,
            accountLabel: "developer",
            tailnetDNSName: nil,
            usesEmbeddedNode: true,
            lastAuthenticatedAt: nil
        )

        let embeddedMachine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: routeID,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "cotg.testing.localhost.p",
                label: "Localhost testing key",
                username: "developer",
                storageScope: .thisDeviceOnlyKeychain
            ),
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .embeddedTailnet,
                    label: "Embedded Tailnet",
                    hostname: "example-mac.example.ts.net",
                    magicDNSName: "example-mac.example.ts.net",
                    sshPort: 22,
                    tailnetProfileID: tailnetProfileID,
                    health: .healthy,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx"
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        try JSONMetadataStore().saveSynchronously(
            MachineDirectorySnapshot(
                machines: [embeddedMachine],
                tailnetProfiles: [embeddedProfile],
                recentSessions: [],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(
                    preferredMachineID: machineID,
                    preferredTailnetProfileID: tailnetProfileID
                )
            ),
            to: metadataURL
        )

        let model = AppModel(
            sceneID: "reconcile-keep-embedded-machine",
            machines: [embeddedMachine],
            tailnetProfiles: [embeddedProfile],
            secretVault: InMemorySecretVault()
        )
        model.selectedMachineID = machineID

        await model.reconcilePersistedLocalStateIfNeeded()

        XCTAssertEqual(model.machines.map(\.displayName), ["example-mac"])
        XCTAssertEqual(model.selectedMachineID, machineID)
        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .embeddedTailnet)
        XCTAssertEqual(model.selectedMachine?.credentialRef?.keychainAccount, "cotg.testing.localhost.p")
    }

    func testAddingExternalTailnetProfileAppendsSavedProfile() async throws {
        let model = AppModel()

        model.addTailnetProfile(
            displayName: "External Tailnet",
            kind: .external,
            controlURLString: "https://controlplane.tailscale.com",
            accountLabel: "developer"
        )

        let saved = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.tailnetProfiles.contains(where: { $0.displayName == "External Tailnet" })
        }
        XCTAssertTrue(saved)
        XCTAssertTrue(model.tailnetProfiles.contains(where: { $0.displayName == "External Tailnet" }))
        XCTAssertEqual(model.transcript.last?.text, "Saved external tailnet profile External Tailnet.")
    }

    func testEmbeddedTailnetFeatureMatchesNativeRuntimeAvailability() {
        let model = AppModel()

        XCTAssertEqual(model.showsEmbeddedTailnetFeature, EmbeddedTailnetRuntimeFactory.hasNativeRuntime)
        if EmbeddedTailnetRuntimeFactory.hasNativeRuntime {
            XCTAssertTrue(model.showsEmbeddedTailnetFeature)
        } else {
            XCTAssertFalse(model.connectionPlan.contains(where: { $0.lane == .embeddedTailnet }))
            XCTAssertFalse(model.tailnetProfiles.contains(where: \.usesEmbeddedNode))
        }
    }

    func testSavingPasswordCredentialAssignsLocalKeychainReference() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Desk LAN",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        XCTAssertEqual(model.selectedMachine?.credentialRef, nil)

        model.savePasswordCredential("topsecret")

        let didPersist = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.selectedMachine?.credentialRef?.kind == .password
                && model.selectedMachine?.lastKnownUser == "developer"
        }

        XCTAssertTrue(didPersist)
        let credential = try XCTUnwrap(model.selectedMachine?.credentialRef)
        XCTAssertEqual(credential.kind, .password)
        XCTAssertEqual(credential.username, "developer")
        XCTAssertEqual(credential.storageScope, .localKeychain)
        XCTAssertTrue(credential.keychainAccount.hasPrefix("com.example.codingonthego.shared.hostbound.password."))
    }

    func testRestoreRecoversLegacySSHKeyBindingAfterReinstall() async throws {
        let metadataPath = "/tmp/cotg-recover-legacy-credential-\(UUID().uuidString)-metadata.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
        }

        let machineID = UUID()
        let trustedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            stableHostFingerprint: "SHA256:trusted-fingerprint",
            lastKnownUser: "developer",
            routes: [
                RouteRecord(
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: trustedKey
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )
        try await JSONMetadataStore().save(snapshot, to: URL(fileURLWithPath: metadataPath))

        let legacyReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "developer",
            storageScope: .thisDeviceOnlyKeychain
        )
        let vault = InMemorySecretVault()
        try await vault.store(
            SecretPayload(
                reference: legacyReference,
                value: Data(repeating: 7, count: 32)
            )
        )

        let model = AppModel(
            sceneID: "recover-legacy-credential",
            secretVault: vault
        )

        _ = await model.restorePersistedState()

        let recovered = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            guard let credential = model.selectedMachine?.credentialRef else {
                return false
            }
            return credential.kind == .sshKey
                && credential.keychainAccount.hasPrefix("com.example.codingonthego.shared.hostbound.sshkey.")
                && model.connectionDebugStatusLabel.contains("credentialReady=true")
        }

        XCTAssertTrue(recovered)
        let recoveredReference = try XCTUnwrap(model.selectedMachine?.credentialRef)
        let recoveredPayload = try await vault.load(reference: recoveredReference)
        XCTAssertNotNil(recoveredPayload)
    }

    func testRestoreRecoversLegacySSHKeyBindingWhenLegacyUsernameIsMissing() async throws {
        let metadataPath = "/tmp/cotg-recover-legacy-credential-no-username-\(UUID().uuidString)-metadata.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
        }

        let machineID = UUID()
        let trustedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            stableHostFingerprint: "SHA256:trusted-fingerprint",
            lastKnownUser: "developer",
            routes: [
                RouteRecord(
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: trustedKey
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [],
            preferences: UserPreferencesSnapshot(preferredMachineID: machineID)
        )
        try await JSONMetadataStore().save(snapshot, to: URL(fileURLWithPath: metadataPath))

        let legacyReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "",
            storageScope: .thisDeviceOnlyKeychain
        )
        let vault = InMemorySecretVault()
        try await vault.store(
            SecretPayload(
                reference: legacyReference,
                value: Data(repeating: 9, count: 32)
            )
        )

        let model = AppModel(
            sceneID: "recover-legacy-credential-no-username",
            secretVault: vault
        )

        _ = await model.restorePersistedState()

        let recovered = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            guard let credential = model.selectedMachine?.credentialRef else {
                return false
            }
            return credential.kind == .sshKey
                && credential.username == "developer"
                && credential.keychainAccount.hasPrefix("com.example.codingonthego.shared.hostbound.sshkey.")
        }

        XCTAssertTrue(recovered)
    }

    func testPreferRoutePinsManualSelection() throws {
        let model = AppModel(bootstrapSnapshot: .preview)
        let machine = try XCTUnwrap(model.machines.first)
        model.select(machineID: machine.id)
        let lanRoute = try XCTUnwrap(model.selectedMachine?.routes.first(where: { $0.kind == .localLAN }))

        model.preferRoute(routeID: lanRoute.id)

        let selectedMachine = try XCTUnwrap(model.selectedMachine)
        XCTAssertEqual(selectedMachine.preferredRouteID, lanRoute.id)
        XCTAssertEqual(
            selectedMachine.routes.filter(\.isUserPinned).map(\.id),
            [lanRoute.id]
        )
    }

    func testLocalNetworkScanRefreshesSelectedMachineRoutes() async throws {
        let machine = makeLocalNetworkTestMachine()
        let coordinator = DiscoveryCoordinator(
            discoverer: StubLANDiscoverer(
                samples: [
                    DiscoveryRouteSample(
                        machineID: machine.id,
                        machineAlias: machine.alias,
                        hostname: "lan-example-mac.local",
                        port: 22,
                        kind: .localLAN,
                        source: .bonjourSSH,
                        health: .healthy
                    )
                ]
            )
        )
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: coordinator,
            externalTailnetAppDetector: StubExternalTailnetAppDetector(installed: false),
            startRuntimeServices: false
        )

        XCTAssertEqual(model.selectedMachineID, machine.id)
        await model.scanLocalNetwork().value

        let didRefresh = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.selectedMachine?.routes.contains(where: {
                $0.kind == .localLAN && $0.hostname == "lan-example-mac.local"
            }) == true
        }

        XCTAssertTrue(didRefresh, "scanStatus=\(model.localNetworkScanStatus) debug=\(model.localNetworkDiscoveryDebugLabel)")
        XCTAssertEqual(model.discoverySnapshot?.recommendedRouteLabel, "Bonjour SSH")
        guard case let .found(totalMachineCount, newMachineCount) = model.localNetworkScanStatus else {
            return XCTFail("Expected a completed local-network scan result.")
        }
        XCTAssertEqual(totalMachineCount, 1)
        XCTAssertEqual(newMachineCount, 0)
    }

    func testLocalNetworkScanPublishesScanningStateWhileDiscoveryRuns() async throws {
        let machine = makeLocalNetworkTestMachine()
        let coordinator = DiscoveryCoordinator(
            discoverer: DelayedStubLANDiscoverer(
                delay: .milliseconds(250),
                samples: [
                    DiscoveryRouteSample(
                        machineID: machine.id,
                        machineAlias: machine.alias,
                        hostname: "lan-example-mac.local",
                        port: 22,
                        kind: .localLAN,
                        source: .bonjourSSH,
                        health: .healthy
                    )
                ]
            )
        )
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: coordinator,
            externalTailnetAppDetector: StubExternalTailnetAppDetector(installed: false),
            startRuntimeServices: false
        )

        XCTAssertEqual(model.selectedMachineID, machine.id)
        let scanTask = model.scanLocalNetwork()

        let didStartScanning = try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            if case .scanning = model.localNetworkScanStatus {
                return true
            }
            return false
        }

        XCTAssertTrue(didStartScanning)
        await scanTask.value
    }

    func testLocalNetworkScanExposesEmptyResultState() async throws {
        let model = AppModel(
            discoveryCoordinator: DiscoveryCoordinator(
                discoverer: StubLANDiscoverer(samples: [])
            )
        )

        await model.scanLocalNetwork().value

        guard case let .noResults(proxyRisk) = model.localNetworkScanStatus else {
            return XCTFail("Expected an empty local-network scan result.")
        }
        XCTAssertFalse(proxyRisk)
    }

    func testFirstLocalNetworkScanRetriesEmptyWarmupPass() async throws {
        let sample = DiscoveryRouteSample(
            machineAlias: "Desk",
            hostname: "desk.local",
            port: 22,
            kind: .localLAN,
            source: .bonjourSSH,
            health: .healthy
        )
        let discoverer = SequencedStubLANDiscoverer(
            responses: [
                [],
                [sample]
            ]
        )
        let model = AppModel(
            discoveryCoordinator: DiscoveryCoordinator(discoverer: discoverer),
            externalTailnetAppDetector: StubExternalTailnetAppDetector(installed: false),
            startRuntimeServices: false
        )

        await model.scanLocalNetwork().value

        let scanCount = await discoverer.recordedScanCount()
        XCTAssertEqual(scanCount, 2)
        XCTAssertEqual(model.machines.count, 1)
        XCTAssertEqual(model.selectedMachine?.hostname, "desk.local")
        XCTAssertEqual(
            model.selectedMachine?.routes.first(where: { $0.kind == .localLAN })?.hostname,
            "desk.local"
        )
        guard case let .found(totalMachineCount, newMachineCount) = model.localNetworkScanStatus else {
            return XCTFail("Expected the first local-network scan to retry and find a machine.")
        }
        XCTAssertEqual(totalMachineCount, 1)
        XCTAssertEqual(newMachineCount, 1)
    }

    func testSavingPasswordCredentialRequiresResolvedUsername() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .manualSSH,
            label: "Desk SSH",
            hostname: "example-mac.local",
            usernameHint: nil,
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: nil,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        model.savePasswordCredential("topsecret")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(model.selectedMachine?.credentialRef)
        XCTAssertTrue(
            model.transcript.contains(where: {
                $0.role == .system
                    && $0.text.contains("Add a username to Desk SSH before you save password-backed SSH login credentials.")
            })
        )
    }

    func testSavingSelectedBootstrapUsernameUpdatesRouteAndClearsMismatchedCredential() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: nil,
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: nil,
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "com.example.codingonthego.shared.sshkey.test",
                label: "SSH private key",
                username: "olduser",
                storageScope: .thisDeviceOnlyKeychain
            ),
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        model.saveSelectedBootstrapUsername("developer")

        XCTAssertEqual(model.selectedMachine?.lastKnownUser, "developer")
        XCTAssertEqual(model.selectedBootstrapRoute?.usernameHint, "developer")
        XCTAssertNil(model.selectedMachine?.credentialRef)
        XCTAssertTrue(
            model.transcript.contains(where: {
                $0.role == .system
                    && $0.text.contains("cleared the saved SSH credential because it belonged to a different username")
            })
        )
    }

    func testManualRescueRouteWithoutUsernameDoesNotBlockEmbeddedBootstrapUsername() {
        let machineID = UUID()
        let embeddedRoute = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Primary Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let manualRoute = RouteRecord(
            machineID: machineID,
            kind: .manualSSH,
            label: "Desk SSH",
            hostname: "example-mac.local",
            usernameHint: nil,
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            preferredRouteID: embeddedRoute.id,
            routes: [embeddedRoute, manualRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )

        model.select(machineID: machineID)

        XCTAssertEqual(model.sshBootstrapUsername, "developer")
        XCTAssertTrue(model.canSavePasswordLogin)
        XCTAssertTrue(model.canGenerateSSHKeyLogin)
    }

    func testPrepareSSHHostValidationPolicyForConnectionAutoTrustsFirstUseKey() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: "developer",
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        let scannedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        let policy = try await model.prepareSSHHostValidationPolicyForConnection(
            for: machine,
            route: route,
            scannedKeyProvider: { scannedKey }
        )

        XCTAssertEqual(policy, .exactOpenSSHPublicKey(scannedKey))
        XCTAssertEqual(model.selectedBootstrapRoute?.trustState, .trusted)
        XCTAssertEqual(model.selectedBootstrapRoute?.trustedOpenSSHPublicKey, scannedKey)
        XCTAssertNotNil(model.storedTrustedHostKeyFingerprint)
        XCTAssertTrue(
            model.transcript.contains(where: {
                $0.role == .system
                    && $0.text.contains("First-time SSH trust for Embedded Tailnet")
            })
        )
    }

    func testPrepareSSHHostValidationPolicyForConnectionBlocksFingerprintMismatch() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: "developer",
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            stableHostFingerprint: "SHA256:trusted-elsewhere",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        let scannedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"

        do {
            _ = try await model.prepareSSHHostValidationPolicyForConnection(
                for: machine,
                route: route,
                scannedKeyProvider: { scannedKey }
            )
            XCTFail("Expected a host-key mismatch to block first-use trust.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not match the fingerprint already trusted"))
        }

        XCTAssertEqual(model.selectedBootstrapRoute?.trustState, .mismatch)
        XCTAssertNil(model.selectedBootstrapRoute?.trustedOpenSSHPublicKey)
        XCTAssertEqual(model.pendingScannedHostKey, scannedKey)
    }

    func testPendingScannedHostKeyProducesActionableTrustGuidance() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: "developer",
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: route.id,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        let scannedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        model.pendingScannedHostKey = scannedKey
        model.pendingScannedHostKeyRouteID = route.id
        model.pendingScannedHostKeyFingerprint = "SHA256:test-fingerprint"

        XCTAssertEqual(model.sshTrustStatusLabel, "Review scanned key")
        XCTAssertEqual(
            model.selectedRouteScannedHostKeyGuidance,
            "Review the scanned fingerprint SHA256:test-fingerprint for Embedded Tailnet. If it matches your Mac, tap Trust scanned key to finish connecting."
        )
    }

    func testReconcilePendingScannedHostKeyRouteBindingRemapsReplacementRoute() {
        let machineID = UUID()
        let profileID = UUID()
        let originalRoute = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            magicDNSName: "example-mac.example.ts.net",
            usernameHint: "developer",
            tailnetProfileID: profileID,
            health: .unavailable,
            discoverySource: .tailnetProfile,
            trustState: .unknown
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: originalRoute.id,
            routes: [originalRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)
        model.pendingScannedHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeRemappedKey developer@example-mac"
        model.pendingScannedHostKeyRouteID = originalRoute.id
        model.pendingScannedHostKeyFingerprint = "SHA256:remapped"

        let replacementRoute = RouteRecord(
            id: UUID(),
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            magicDNSName: "example-mac.example.ts.net",
            usernameHint: "developer",
            tailnetProfileID: profileID,
            health: .healthy,
            lastCheckedAt: .now,
            isRecommended: true,
            discoverySource: .tailnetProfile,
            trustState: .unknown
        )
        let replacementMachine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: replacementRoute.id,
            routes: [replacementRoute],
            capabilities: machine.capabilities
        )

        let previousMachines = model.machines
        model.machines = [replacementMachine]
        model.reconcilePendingScannedHostKeyRouteBinding(previousMachines: previousMachines)

        XCTAssertEqual(model.pendingScannedHostKeyRouteID, replacementRoute.id)
        XCTAssertTrue(model.canTrustScannedHostKey)
        XCTAssertEqual(model.sshTrustStatusLabel, "Review scanned key")
    }

    func testReconcilePendingScannedHostKeyRouteBindingClearsMissingRoute() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .manualSSH,
            label: "Direct SSH",
            hostname: "lab.example.com",
            usernameHint: "developer",
            health: .healthy,
            discoverySource: .manual,
            trustState: .unknown
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "Lab",
            hostname: "lab.example.com",
            lastKnownUser: "developer",
            preferredRouteID: route.id,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)
        model.pendingScannedHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeMissingKey developer@lab"
        model.pendingScannedHostKeyRouteID = route.id
        model.pendingScannedHostKeyFingerprint = "SHA256:missing"

        let previousMachines = model.machines
        model.machines = [
            MachineRecord(
                id: machineID,
                displayName: "Lab",
                hostname: "lab.example.com",
                lastKnownUser: "developer",
                preferredRouteID: nil,
                routes: [],
                capabilities: machine.capabilities
            )
        ]
        model.reconcilePendingScannedHostKeyRouteBinding(previousMachines: previousMachines)

        XCTAssertNil(model.pendingScannedHostKey)
        XCTAssertNil(model.pendingScannedHostKeyRouteID)
        XCTAssertNil(model.pendingScannedHostKeyFingerprint)
        XCTAssertFalse(model.canTrustScannedHostKey)
    }

    func testSelectingSameMachinePreservesPendingScannedHostKey() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            magicDNSName: "example-mac.example.ts.net",
            usernameHint: "developer",
            tailnetProfileID: UUID(),
            health: .healthy,
            discoverySource: .tailnetProfile,
            trustState: .unknown
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: route.id,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)
        model.pendingScannedHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeReselectKey developer@example-mac"
        model.pendingScannedHostKeyRouteID = route.id
        model.pendingScannedHostKeyFingerprint = "SHA256:reselect"

        model.select(machineID: machineID)

        XCTAssertEqual(model.pendingScannedHostKeyRouteID, route.id)
        XCTAssertEqual(model.pendingScannedHostKeyFingerprint, "SHA256:reselect")
        XCTAssertTrue(model.canTrustScannedHostKey)
    }

    func testMarkRouteConnectionFailureDegradesFailedRouteAndFallsBackToHealthyEmbedded() {
        let machineID = UUID()
        let externalRoute = RouteRecord(
            machineID: machineID,
            kind: .externalTailnet,
            label: "External Tailnet",
            magicDNSName: "example-mac.example.ts.net",
            usernameHint: "developer",
            requiresExternalApp: true,
            health: .healthy,
            isUserPinned: true
        )
        let embeddedRoute = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            usernameHint: "developer",
            tailnetProfileID: UUID(),
            health: .healthy
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: externalRoute.id,
            routes: [externalRoute, embeddedRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let model = AppModel(
            machines: [machine],
            secretVault: InMemorySecretVault()
        )
        model.select(machineID: machineID)

        model.markRouteConnectionFailure(
            routeID: externalRoute.id,
            machineID: machineID,
            reason: "AuthenticationError error 1"
        )

        let failedRoute = model.selectedMachine?.route(id: externalRoute.id)
        XCTAssertEqual(failedRoute?.health, .degraded)
        XCTAssertEqual(failedRoute?.failureReasonCode, "ssh-handshake-ended")
        XCTAssertNotNil(failedRoute?.lastFailureAt)
        XCTAssertEqual(model.selectedMachine?.preferredRouteID, embeddedRoute.id)
        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .embeddedTailnet)
    }

    func testGeneratingSSHKeyAssignsSSHKeyCredential() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Desk LAN",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.select(machineID: machineID)

        model.generateSSHKeyCredential()
        let start = ContinuousClock.now
        var didPersist = false
        while start.duration(to: .now) < .seconds(5) {
            if let credential = model.selectedMachine?.credentialRef,
               credential.kind == .sshKey,
               model.revealedSSHLoginPublicKey?.contains("ssh-ed25519") == true,
               (try? await vault.load(reference: credential)) != nil {
                didPersist = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(didPersist)
        let credential = try XCTUnwrap(model.selectedMachine?.credentialRef)
        XCTAssertEqual(credential.kind, .sshKey)
        XCTAssertEqual(credential.username, "developer")
        XCTAssertEqual(credential.storageScope, .localKeychain)
        XCTAssertTrue(credential.keychainAccount.hasPrefix("com.example.codingonthego.shared.hostbound.sshkey."))
        XCTAssertTrue(model.canRevealSSHLoginPublicKey)
        let payload = try await vault.load(reference: credential)
        XCTAssertNotNil(payload)
    }

    func testRecoverSavedSSHKeyLoginAssignsRecoveredCredential() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Desk LAN",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        let legacyReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(machineID.uuidString.lowercased())",
            label: "SSH private key",
            username: "developer",
            storageScope: .localKeychain
        )
        try await vault.store(
            SecretPayload(
                reference: legacyReference,
                value: Data(repeating: 5, count: 32)
            )
        )

        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.select(machineID: machineID)

        let hasRecoverableSavedKey = await model.hasRecoverableSavedSSHKeyForSelectedMachine()
        XCTAssertTrue(hasRecoverableSavedKey)

        model.recoverSavedSSHKeyLogin()

        let didRecover = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            guard let credential = model.selectedMachine?.credentialRef else {
                return false
            }
            return credential.kind == .sshKey
                && credential.storageScope == .localKeychain
                && credential.keychainAccount.hasPrefix("com.example.codingonthego.shared.hostbound.sshkey.")
        }

        XCTAssertTrue(didRecover)
        XCTAssertEqual(model.selectedMachine?.lastKnownUser, "developer")
    }

    func testSavedSSHKeyRecoveryAvailabilitySearchesMultipleSavedKeys() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Subnet reachability",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        let firstReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "developer",
            storageScope: .localKeychain
        )
        let secondReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "other-user",
            storageScope: .localKeychain
        )
        try await vault.store(
            SecretPayload(
                reference: firstReference,
                value: Data(repeating: 7, count: 32)
            )
        )
        try await vault.store(
            SecretPayload(
                reference: secondReference,
                value: Data(repeating: 9, count: 32)
            )
        )

        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.select(machineID: machineID)

        let availability = await model.savedSSHKeyRecoveryAvailabilityForSelectedMachine()
        XCTAssertEqual(availability, .candidateSearch(count: 2))
    }

    func testSavedSSHKeyRecoveryAvailabilitySearchesHostBoundSavedKeys() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .manualSSH,
            label: "Manual SSH",
            hostname: "localhost",
            usernameHint: "developer",
            health: .healthy,
            trustState: .unknown
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            stableHostFingerprint: "SHA256:test-availability-fingerprint",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        let hostBoundReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.hostbound.sshkey.test-availability",
            label: "SSH private key",
            username: "developer",
            storageScope: .localKeychain
        )
        try await vault.store(
            SecretPayload(
                reference: hostBoundReference,
                value: Data(repeating: 11, count: 32)
            )
        )

        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.select(machineID: machineID)

        let availability = await model.savedSSHKeyRecoveryAvailabilityForSelectedMachine()
        XCTAssertEqual(availability, .candidateSearch(count: 1))
    }

    func testRecoverSavedSSHKeyLoginRequestsFingerprintBeforeTryingMultipleSavedKeys() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Subnet reachability",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .unknown
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        let firstReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "developer",
            storageScope: .localKeychain
        )
        let secondReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "other-user",
            storageScope: .localKeychain
        )
        try await vault.store(
            SecretPayload(
                reference: firstReference,
                value: Data(repeating: 7, count: 32)
            )
        )
        try await vault.store(
            SecretPayload(
                reference: secondReference,
                value: Data(repeating: 9, count: 32)
            )
        )

        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.select(machineID: machineID)

        model.recoverSavedSSHKeyLogin()

        let didAppendGuidance = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.transcript.last?.text == "Saved SSH keys were found on this iPhone. Verify the Mac fingerprint first, then try the saved keys again."
        }

        XCTAssertTrue(didAppendGuidance)
        XCTAssertEqual(
            model.connectionSetupNotice,
            "Saved SSH keys were found on this iPhone. Verify the Mac fingerprint first, then try the saved keys again."
        )
        XCTAssertNil(model.selectedMachine?.credentialRef)
    }

    func testRecoverSavedSSHKeyLoginTriesHostBoundSavedKeyCandidates() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let rawKeyData = try Data(contentsOf: URL(fileURLWithPath: rawKeyPath))
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-appstate-recover-hostbound-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-appstate-recover-hostbound-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-appstate-recover-hostbound-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("COTG_DISABLE_LOCALHOST_TESTING_CREDENTIAL_AUTOLOAD", "1", 1)
        setenv("COTG_DISABLE_SAVED_CREDENTIAL_BINDING_RECOVERY", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("COTG_DISABLE_LOCALHOST_TESTING_CREDENTIAL_AUTOLOAD")
            unsetenv("COTG_DISABLE_SAVED_CREDENTIAL_BINDING_RECOVERY")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .manualSSH,
            label: "Manual SSH",
            hostname: "localhost",
            ipAddress: "127.0.0.1",
            usernameHint: Self.localhostSSHUser,
            health: .healthy,
            trustState: .unknown
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "localhost",
            hostname: "localhost",
            stableHostFingerprint: "SHA256:test-recover-hostbound-fingerprint",
            lastKnownUser: Self.localhostSSHUser,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        let failingLegacyReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: Self.localhostSSHUser,
            storageScope: .localKeychain
        )
        let secondFailingLegacyReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.sshkey.\(UUID().uuidString.lowercased())",
            label: "SSH private key",
            username: "other-\(Self.localhostSSHUser)",
            storageScope: .localKeychain
        )
        let hostBoundReference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.hostbound.sshkey.test-recovery",
            label: "SSH private key",
            username: Self.localhostSSHUser,
            storageScope: .localKeychain
        )
        try await vault.store(
            SecretPayload(
                reference: failingLegacyReference,
                value: Data(repeating: 3, count: 32)
            )
        )
        try await vault.store(
            SecretPayload(
                reference: secondFailingLegacyReference,
                value: Data(repeating: 4, count: 32)
            )
        )
        try await vault.store(
            SecretPayload(
                reference: hostBoundReference,
                value: rawKeyData
            )
        )

        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.select(machineID: machineID)

        let availability = await model.savedSSHKeyRecoveryAvailabilityForSelectedMachine()
        XCTAssertEqual(availability, .candidateSearch(count: 3))

        model.recoverSavedSSHKeyLogin()

        let didRecover = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            guard let credential = model.selectedMachine?.credentialRef else {
                return false
            }
            return credential.kind == .sshKey
                && credential.username == Self.localhostSSHUser
                && credential.storageScope == .localKeychain
                && credential.keychainAccount.hasPrefix("com.example.codingonthego.shared.hostbound.sshkey.")
                && model.transcript.contains(where: { $0.text == "Recovered the saved device SSH key for localhost." })
        }

        XCTAssertTrue(
            didRecover,
            "Expected host-bound saved SSH key recovery to succeed after skipping a failing legacy key. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let credential = try XCTUnwrap(model.selectedMachine?.credentialRef)
        let payload = try await vault.load(reference: credential)
        XCTAssertEqual(payload?.value, rawKeyData)
    }

    func testForgetSelectedMachineRemovesSavedMachineStateAndUniqueCredential() async throws {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Desk LAN",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@example-mac"
        )
        let credential = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.hostbound.sshkey.test-forget",
            label: "SSH private key",
            username: "developer",
            storageScope: .localKeychain
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            credentialRef: credential,
            routes: [route],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let session = SessionRecord(
            machineID: machineID,
            routeID: route.id,
            threadID: "thread-forget",
            workspaceRoot: "/tmp/project",
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: route.kind,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now
        )
        let catalogEntry = HostThreadCatalogEntry(
            id: "thread-forget",
            machineID: machineID,
            workspaceRoot: "/tmp/project",
            name: "Fix forget flow",
            preview: "Preview",
            modelProvider: "gpt-5.4",
            createdAt: .now,
            updatedAt: .now
        )
        let vault = InMemorySecretVault()
        try await vault.store(
            SecretPayload(
                reference: credential,
                value: Data(repeating: 7, count: 32)
            )
        )

        let model = AppModel(
            machines: [machine],
            secretVault: vault
        )
        model.recentSessions = [session]
        model.hostThreadCatalog = [catalogEntry]
        model.select(machineID: machineID)
        model.connectionState = .connected("stdio://example-mac.local")
        model.activeProtocolKind = .stdio
        model.transcript = [
            SessionMessage(role: .assistant, text: "Existing transcript")
        ]
        model.displayedTranscriptThreadID = "thread-forget"
        model.workspaceSummary = GitWorkspaceSummary(
            branch: "main",
            aheadCount: 0,
            behindCount: 0,
            changes: []
        )

        await model.forgetSelectedMachine()

        XCTAssertNil(model.selectedMachine)
        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertTrue(model.recentSessions.isEmpty)
        XCTAssertTrue(model.hostThreadCatalog.isEmpty)
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertNil(model.displayedTranscriptThreadID)
        XCTAssertNil(model.workspaceSummary)
        let payload = try await vault.load(reference: credential)
        XCTAssertNil(payload)
    }

    func testForgetSelectedMachineKeepsSharedCredentialReferencedElsewhere() async throws {
        let sharedCredential = CredentialRef(
            kind: .sshKey,
            keychainAccount: "com.example.codingonthego.shared.hostbound.sshkey.test-shared",
            label: "SSH private key",
            username: "developer",
            storageScope: .localKeychain
        )

        let firstMachineID = UUID()
        let secondMachineID = UUID()
        let firstRoute = RouteRecord(
            machineID: firstMachineID,
            kind: .localLAN,
            label: "Desk LAN",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy
        )
        let secondRoute = RouteRecord(
            machineID: secondMachineID,
            kind: .manualSSH,
            label: "Manual SSH",
            hostname: "example-mac-alt.local",
            usernameHint: "developer",
            health: .healthy
        )
        let firstMachine = MachineRecord(
            id: firstMachineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            credentialRef: sharedCredential,
            routes: [firstRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: firstMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let secondMachine = MachineRecord(
            id: secondMachineID,
            displayName: "example-mac-alt",
            hostname: "example-mac-alt.local",
            lastKnownUser: "developer",
            credentialRef: sharedCredential,
            routes: [secondRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: secondMachineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let vault = InMemorySecretVault()
        try await vault.store(
            SecretPayload(
                reference: sharedCredential,
                value: Data(repeating: 9, count: 32)
            )
        )

        let model = AppModel(
            machines: [firstMachine, secondMachine],
            secretVault: vault
        )
        model.select(machineID: firstMachineID)

        await model.forgetSelectedMachine()

        XCTAssertEqual(model.machines.map(\.id), [secondMachineID])
        XCTAssertEqual(model.selectedMachine?.id, secondMachineID)
        let payload = try await vault.load(reference: sharedCredential)
        XCTAssertNotNil(payload)
    }

    func testRestoreIngestsCompanionPublishedRoutesFromSyncMirror() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let metadataURL = tempDirectory.appendingPathComponent("metadata.json")
        let syncURL = tempDirectory.appendingPathComponent("sync.json")

        setenv("COTG_METADATA_PATH", metadataURL.path, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncURL.path, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let publisher = CompanionMetadataPublisher(
            metadataURL: metadataURL,
            syncMirrorURL: syncURL
        )
        _ = try await publisher.publish(
            CompanionHostSnapshot(
                hostDisplayName: "example-mac.local",
                presence: .init(isInstalled: true, isReachable: true, supportsEnhancedHostMode: true),
                publishedRoutes: [
                    .init(kind: .localLAN, address: "192.168.1.24", health: .healthy)
                ],
                sharedListenerState: .ready,
                capabilities: .init(
                    canPublishRoutes: true,
                    canWarmSharedListener: true,
                    canExposeDirectEndpoint: false,
                    canBridgeNotifications: true
                )
            )
        )

        let model = AppModel(
            syncCoordinator: FileBackedSyncCoordinator(mirrorURL: syncURL)
        )
        _ = await model.restorePersistedState()

        let machine = try XCTUnwrap(model.machines.first(where: { $0.hostname == "example-mac.local" }))
        XCTAssertTrue(machine.routes.contains(where: { $0.publishedByCompanion && $0.kind == .localLAN }))
    }

    func testPrivacyModePersistsAcrossRestore() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration(
            paths: paths,
            syncBehavior: .fileMirror(paths.syncMirrorURL),
            notificationBridgeSubmission: .fileRelay(paths.companionNotificationRelayDirectoryURL)
        )

        let model = AppModel(
            sceneID: "privacy-source",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: FileBackedSyncCoordinator(mirrorURL: paths.syncMirrorURL),
            startRuntimeServices: false
        )
        model.setPrivacyMode(.privacy)
        model.sceneDidEnterBackground()

        let restored = AppModel(
            sceneID: "privacy-restored",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: FileBackedSyncCoordinator(mirrorURL: paths.syncMirrorURL),
            startRuntimeServices: false
        )
        _ = await restored.restorePersistedState()

        XCTAssertEqual(restored.privacyMode, .privacy)
    }

    func testPrepareNewSessionPersistsSynchronouslyForRestoreSafety() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration.localOnly(paths: paths)
        let model = AppModel(
            sceneID: "sync-persist-new-session",
            machines: [MachineRecord.preview],
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: NoopCloudKitSyncCoordinator(),
            startRuntimeServices: false
        )

        let sessionID = try XCTUnwrap(
            model.prepareNewSession(
                machineID: MachineRecord.preview.id,
                workspaceRoot: Self.workspaceRoot,
                reconnect: false
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadataStoreURL.path))
        let persisted = try loadPersistedSnapshotSynchronously(at: paths.metadataStoreURL)
        let persistedSession = try XCTUnwrap(persisted.recentSessions.first(where: { $0.id == sessionID }))
        XCTAssertEqual(persisted.preferences.preferredMachineID, MachineRecord.preview.id)
        XCTAssertNil(persistedSession.threadID)
        XCTAssertEqual(persistedSession.workspaceRoot, Self.workspaceRoot)
    }

    func testResumeHostThreadCatalogEntryPersistsSynchronouslyForRestoreSafety() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration.localOnly(paths: paths)
        let model = AppModel(
            sceneID: "sync-persist-browser-selection",
            machines: [MachineRecord.preview],
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: NoopCloudKitSyncCoordinator(),
            startRuntimeServices: false
        )
        let entry = HostThreadCatalogEntry(
            id: "thread-app-store-upload",
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            name: "app store upload",
            preview: "Continue the upload thread",
            modelProvider: "openai",
            createdAt: .now.addingTimeInterval(-60),
            updatedAt: .now
        )

        let sessionID = try XCTUnwrap(model.resumeHostThreadCatalogEntry(entry, reconnect: false))

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadataStoreURL.path))
        let persisted = try loadPersistedSnapshotSynchronously(at: paths.metadataStoreURL)
        let persistedSession = try XCTUnwrap(persisted.recentSessions.first(where: { $0.id == sessionID }))
        XCTAssertEqual(persisted.preferences.preferredMachineID, MachineRecord.preview.id)
        XCTAssertEqual(persistedSession.threadID, entry.id)
        XCTAssertEqual(persistedSession.threadDisplayTitle, "app store upload")
        XCTAssertEqual(persistedSession.workspaceRoot, Self.workspaceRoot)
        XCTAssertEqual(persistedSession.lastTurn?.summary, "app store upload")
    }

    func testSceneDidBecomeActiveReconnectsWhenSelectedThreadIsUnavailable() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            sceneID: "foreground-refresh-missing-thread",
            machineID: machine.id,
            routeID: machine.preferredRoute?.id,
            threadID: nil,
            unavailableSelectedThreadID: "thread-app-store-upload",
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: machine.preferredRoute?.kind,
            lastKnownBootstrap: .standardSSH,
            lastModel: "gpt-5.4",
            lastTurn: RecentTurnMetadata(
                turnID: "turn-app-store-upload",
                summary: "app store upload",
                completedAt: .now
            ),
            transportState: .disconnected,
            lastOpenedAt: .now
        )
        let snapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [session],
            hostThreadCatalog: [
                HostThreadCatalogEntry(
                    id: "thread-app-store-upload",
                    machineID: machine.id,
                    workspaceRoot: Self.workspaceRoot,
                    name: "app store upload",
                    preview: "Resume the upload thread",
                    modelProvider: "openai",
                    createdAt: .now.addingTimeInterval(-60),
                    updatedAt: .now
                )
            ],
            preferences: UserPreferencesSnapshot(
                preferredMachineID: machine.id,
                restoreLastSessionOnLaunch: true
            )
        )
        let model = AppModel(
            sceneID: "foreground-refresh-missing-thread",
            bootstrapSnapshot: snapshot,
            startRuntimeServices: false
        )
        model.connectionState = .disconnected

        model.sceneDidBecomeActive()

        if case .connecting = model.connectionState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected foreground activation to reconnect for browser refresh when the selected thread is marked unavailable.")
        }
    }

    func testExecutionPreferencesPersistAcrossRestoreWithFileMirrorSync() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration(
            paths: paths,
            syncBehavior: .fileMirror(paths.syncMirrorURL),
            notificationBridgeSubmission: .fileRelay(paths.companionNotificationRelayDirectoryURL)
        )

        let model = AppModel(
            sceneID: "execution-preferences-source",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: FileBackedSyncCoordinator(mirrorURL: paths.syncMirrorURL),
            startRuntimeServices: false
        )
        model.selectReasoningEffort(.xhigh)
        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)
        model.sceneDidEnterBackground()

        let restored = AppModel(
            sceneID: "execution-preferences-restored",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: FileBackedSyncCoordinator(mirrorURL: paths.syncMirrorURL),
            startRuntimeServices: false
        )
        _ = await restored.restorePersistedState()

        XCTAssertEqual(restored.selectedReasoningEffort, .xhigh)
        XCTAssertEqual(restored.preferredApprovalPolicy, "never")
        XCTAssertEqual(restored.preferredSandboxMode, .dangerFullAccess)
    }

    func testInitialRestorePreservesExecutionPreferencesChangedBeforeRestoreCompletes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = AppRuntimePaths(
            rootDirectoryURL: root,
            metadataStoreURL: root.appendingPathComponent("metadata.json"),
            syncMirrorURL: root.appendingPathComponent("sync.json"),
            notificationOutboxURL: root.appendingPathComponent("outbox.json"),
            companionNotificationRelayDirectoryURL: root.appendingPathComponent("relay", isDirectory: true),
            companionListenerPIDURL: root.appendingPathComponent("listener.pid"),
            companionListenerLogURL: root.appendingPathComponent("listener.log"),
            diagnosticsDirectoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let runtimeConfiguration = AppRuntimeConfiguration.localOnly(paths: paths)
        let metadataStore = JSONMetadataStore()

        try await metadataStore.save(
            MachineDirectorySnapshot(
                machines: [],
                tailnetProfiles: [],
                recentSessions: [],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(
                    restoreLastSessionOnLaunch: true,
                    preferredBootstrap: .standardSSH,
                    preferredProtocol: .stdio,
                    preferredReasoningEffort: CodexReasoningEffort.low.rawValue,
                    preferredApprovalPolicy: "on-request",
                    preferredSandboxMode: CodexSandboxMode.workspaceWrite.rawValue,
                    privacyMode: .standard
                )
            ),
            to: paths.metadataStoreURL
        )

        let model = AppModel(
            sceneID: "initial-restore-race",
            runtimeConfiguration: runtimeConfiguration,
            syncCoordinator: NoopCloudKitSyncCoordinator(),
            startRuntimeServices: false
        )

        model.selectReasoningEffort(.high)
        model.setPreferredApprovalPolicy("never")
        model.setPreferredSandboxMode(.dangerFullAccess)

        _ = await model.restorePersistedState()

        XCTAssertEqual(model.selectedReasoningEffort, .high)
        XCTAssertEqual(model.preferredApprovalPolicy, "never")
        XCTAssertEqual(model.preferredSandboxMode, .dangerFullAccess)

        let persisted = try await metadataStore.load(from: paths.metadataStoreURL)
        XCTAssertEqual(persisted.preferences.preferredReasoningEffort, CodexReasoningEffort.high.rawValue)
        XCTAssertEqual(persisted.preferences.preferredApprovalPolicy, "never")
        XCTAssertEqual(persisted.preferences.preferredSandboxMode, CodexSandboxMode.dangerFullAccess.rawValue)
    }

    func testProxyDiagnosticsDetectMissingBypassForLocalAndTailnetTraffic() {
        let diagnostics = NetworkProxyDiagnosticSnapshot.current(
            environment: [
                "HTTPS_PROXY": "http://127.0.0.1:9090"
            ],
            systemSettings: [
                "SOCKSEnable": NSNumber(value: 1)
            ]
        )

        XCTAssertEqual(diagnostics.statusLabel, "Bypass needed")
        XCTAssertTrue(diagnostics.localhostRisk)
        XCTAssertTrue(diagnostics.discoveryRisk)
        XCTAssertTrue(diagnostics.tailnetRisk)
    }

    func testProxyDiagnosticsRespectExplicitBypassConfiguration() {
        let diagnostics = NetworkProxyDiagnosticSnapshot.current(
            environment: [
                "HTTPS_PROXY": "http://127.0.0.1:9090",
                "NO_PROXY": "localhost,127.0.0.1,::1,.local,192.168.,10.,172.16.,172.17.,172.18.,172.19.,172.20.,172.21.,172.22.,172.23.,172.24.,172.25.,172.26.,172.27.,172.28.,172.29.,172.30.,172.31.,.ts.net,100.64."
            ],
            systemSettings: [:]
        )

        XCTAssertEqual(diagnostics.statusLabel, "Proxy active with bypass")
        XCTAssertFalse(diagnostics.localhostRisk)
        XCTAssertFalse(diagnostics.discoveryRisk)
        XCTAssertFalse(diagnostics.tailnetRisk)
    }

    func testProxyDiagnosticsStayHonestForLANRouteWhenOnlyTailnetBypassIsMissing() {
        let diagnostics = NetworkProxyDiagnosticSnapshot.current(
            environment: [:],
            systemSettings: [
                "HTTPEnable": NSNumber(value: 1),
                "ExcludeSimpleHostnames": NSNumber(value: 1),
                "ExceptionsList": [
                    "localhost",
                    "*.local",
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "192.168.0.0/16"
                ]
            ]
        )

        XCTAssertFalse(diagnostics.localhostRisk)
        XCTAssertFalse(diagnostics.discoveryRisk)
        XCTAssertTrue(diagnostics.tailnetRisk)
        XCTAssertEqual(diagnostics.statusLabel(for: .localLAN), "Proxy active with bypass")
        XCTAssertTrue(diagnostics.detail(for: .localLAN).contains("Local and LAN bypass rules appear to be configured"))
        XCTAssertTrue(diagnostics.detail(for: .localLAN).contains("Tailnet bypass still needs"))
        XCTAssertEqual(diagnostics.statusLabel(for: .embeddedTailnet), "Bypass needed")
    }

    func testLocalhostSafeLaneSmokeTurnCompletes() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-appstate-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-appstate-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-appstate-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "safe-lane-smoke",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.threadID != nil
            }
            return false
        }
        XCTAssertTrue(
            didConnect,
            "Safe-lane connection never became ready. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        model.sendSmokeTestPrompt()

        let didCompleteSmokeTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            model.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains("COTG_APP_OK")
            })
        }
        XCTAssertTrue(
            didCompleteSmokeTurn,
            "Smoke turn never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostConnectedPreparedSessionStartsThreadOnFirstComposerSend() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-appstate-first-send-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-appstate-first-send-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-appstate-first-send-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "first-send-threadless",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(didConnect)

        _ = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            reconnect: false
        )
        model.connectionState = .connected("stdio://localhost")
        model.activeProtocolKind = .stdio

        XCTAssertNil(model.activeSession?.threadID)
        XCTAssertEqual(model.activeSession?.workspaceRoot, Self.workspaceRoot)

        let marker = "COTG_FIRST_SEND_\(UUID().uuidString)"
        model.sendPrompt("Reply with \(marker) only.")

        let didStartThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            model.activeSession?.threadID != nil
                && model.transcript.contains(where: { message in
                    message.role == .assistant
                        && !message.isStreaming
                        && message.text.contains(marker)
                })
        }
        XCTAssertTrue(
            didStartThread,
            "First send on a connected threadless session never started a live thread. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostConnectedHostBackedSendPreparesSessionBeforeFirstTurn() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-appstate-bootstrap-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-appstate-bootstrap-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-appstate-bootstrap-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "first-send-bootstrap",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(didConnect)

        model.recentSessions = []

        let marker = "COTG_BOOTSTRAP_SEND_\(UUID().uuidString)"
        model.sendPrompt("Reply with \(marker) only.")

        let didPrepareAndReply = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            model.activeSession?.workspaceRoot == Self.workspaceRoot
                && model.activeSession?.threadID != nil
                && model.transcript.contains(where: { message in
                    message.role == .assistant
                        && !message.isStreaming
                        && message.text.contains(marker)
                })
        }
        XCTAssertTrue(
            didPrepareAndReply,
            "Connected send without a prepared session never bootstrapped a host-backed thread. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostSafeLaneSmokeTurnCompletesWithInlineRawKeyPayload() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let rawKeyData = try Data(contentsOf: URL(fileURLWithPath: rawKeyPath))
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-appstate-inline-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-appstate-inline-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-appstate-inline-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", "/tmp/cotg-missing-inline.raw", 1)
        setenv("COTG_TEST_SSH_RAW_KEY_BASE64", rawKeyData.base64EncodedString(), 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_RAW_KEY_BASE64")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "safe-lane-inline",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.threadID != nil
            }
            return false
        }
        XCTAssertTrue(
            didConnect,
            "Inline-key safe-lane connection never became ready. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostWorktreeFlowStartsNewThreadInWorktree() async throws {
        let workspaceRoot = try makeTemporaryGitFixtureRepo(prefix: "cotg-worktree-start")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try await withLocalhostIntegrationEnvironment(
            workspaceRoot: workspaceRoot,
            label: "worktree-start"
        ) {
            let model = AppModel(sceneID: "worktree-start", bootstrapSnapshot: .preview)
            let originalThreadID = try await self.prepareConnectedLocalhostThread(
                model: model,
                workspaceRoot: workspaceRoot,
                markerPrefix: "COTG_WORKTREE_START"
            )
            let originalSessionID = try XCTUnwrap(model.activeSession?.id)

            let result = try await model.startNewThreadInWorktreeNow(named: "flow-start", branch: nil)

            let switchedToWorktree = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == result.sessionID
                    && model.activeSession?.threadID == result.threadID
                    && model.activeSession?.lastMode == .worktree
                    && model.activeSession?.workspaceRoot == result.workspaceRoot
            }
            XCTAssertTrue(
                switchedToWorktree,
                """
                Worktree session never became active.
                originalSessionID=\(originalSessionID)
                expectedSessionID=\(result.sessionID)
                expectedThreadID=\(result.threadID)
                expectedWorkspaceRoot=\(result.workspaceRoot)
                activeSessionID=\(model.activeSession?.id.uuidString ?? "nil")
                activeThreadID=\(model.activeSession?.threadID ?? "nil")
                activeWorkspaceRoot=\(model.activeSession?.workspaceRoot ?? "nil")
                activeMode=\(String(describing: model.activeSession?.lastMode))
                recentSessions=\(model.recentSessions.map { "\($0.id.uuidString):\($0.threadID ?? "nil"):\($0.workspaceRoot ?? "nil")" }.joined(separator: " | "))
                """
            )
            XCTAssertNotEqual(result.threadID, originalThreadID)
            XCTAssertNotEqual(result.sessionID, originalSessionID)
            XCTAssertTrue(result.workspaceRoot.contains("-worktrees/"))
        }
    }

    func testLocalhostWorktreeFlowReturnsStartedWorktreeToParentLocalSession() async throws {
        let workspaceRoot = try makeTemporaryGitFixtureRepo(prefix: "cotg-worktree-start-return")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try await withLocalhostIntegrationEnvironment(
            workspaceRoot: workspaceRoot,
            label: "worktree-start-return"
        ) {
            let model = AppModel(sceneID: "worktree-start-return", bootstrapSnapshot: .preview)
            let originalThreadID = try await self.prepareConnectedLocalhostThread(
                model: model,
                workspaceRoot: workspaceRoot,
                markerPrefix: "COTG_WORKTREE_START_RETURN"
            )
            let originalSessionID = try XCTUnwrap(model.activeSession?.id)

            let started = try await model.startNewThreadInWorktreeNow(named: "flow-start-return", branch: nil)
            let didStart = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == started.sessionID
                    && model.activeSession?.threadID == started.threadID
                    && model.activeSession?.workspaceRoot == started.workspaceRoot
                    && model.activeSession?.lastMode == .worktree
            }
            XCTAssertTrue(didStart)

            let returned = try await model.returnCurrentThreadToLocalCheckoutNow()
            let didReturn = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == originalThreadID
                    && model.activeSession?.workspaceRoot == workspaceRoot
                    && model.activeSession?.lastMode == .local
            }
            XCTAssertTrue(didReturn)
            XCTAssertEqual(returned.sessionID, originalSessionID)
            XCTAssertEqual(returned.threadID, originalThreadID)
            XCTAssertEqual(returned.workspaceRoot, workspaceRoot)
            XCTAssertEqual(model.activeSession?.parentThreadID, started.threadID)
            XCTAssertEqual(
                model.recentSessions.filter { $0.threadID == originalThreadID }.count,
                1,
                "Returning from a started worktree should reactivate the existing Local session instead of duplicating it."
            )
        }
    }

    func testLocalhostWorktreeFlowReturnsStartedWorktreeToLocalWhenParentHasNoTurns() async throws {
        let workspaceRoot = try makeTemporaryGitFixtureRepo(prefix: "cotg-worktree-start-empty-return")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try await withLocalhostIntegrationEnvironment(
            workspaceRoot: workspaceRoot,
            label: "worktree-start-empty-return"
        ) {
            let model = AppModel(sceneID: "worktree-start-empty-return", bootstrapSnapshot: .preview)
            let originalSessionID = try await self.prepareConnectedLocalhostSessionWithoutTurns(
                model: model,
                workspaceRoot: workspaceRoot
            )
            XCTAssertNil(model.activeSession?.lastTurnID)

            let started = try await model.startNewThreadInWorktreeNow(named: "flow-start-empty-return", branch: nil)
            let didStart = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == started.sessionID
                    && model.activeSession?.threadID == started.threadID
                    && model.activeSession?.workspaceRoot == started.workspaceRoot
                    && model.activeSession?.lastMode == .worktree
            }
            XCTAssertTrue(didStart)

            let returned = try await model.returnCurrentThreadToLocalCheckoutNow()
            let didReturn = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == originalSessionID
                    && model.activeSession?.workspaceRoot == workspaceRoot
                    && model.activeSession?.lastMode == .local
                    && model.activeSession?.threadID != nil
                    && model.activeSession?.threadID != started.threadID
            }
            XCTAssertTrue(didReturn)
            XCTAssertEqual(returned.sessionID, originalSessionID)
            XCTAssertEqual(returned.workspaceRoot, workspaceRoot)
            XCTAssertNotEqual(returned.threadID, started.threadID)
            XCTAssertEqual(model.activeSession?.parentThreadID, started.threadID)
        }
    }

    func testLocalhostWorktreeFlowMovesThreadToWorktreeAndBackToLocal() async throws {
        let workspaceRoot = try makeTemporaryGitFixtureRepo(prefix: "cotg-worktree-move")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try await withLocalhostIntegrationEnvironment(
            workspaceRoot: workspaceRoot,
            label: "worktree-move"
        ) {
            let model = AppModel(sceneID: "worktree-move", bootstrapSnapshot: .preview)
            let originalThreadID = try await self.prepareConnectedLocalhostThread(
                model: model,
                workspaceRoot: workspaceRoot,
                markerPrefix: "COTG_WORKTREE_MOVE"
            )
            let originalSessionID = try XCTUnwrap(model.activeSession?.id)

            let moved = try await model.moveCurrentThreadToWorktreeNow(named: "flow-move", branch: nil)
            let didMove = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == moved.threadID
                    && model.activeSession?.workspaceRoot == moved.workspaceRoot
                    && model.activeSession?.lastMode == .worktree
            }
            XCTAssertTrue(
                didMove,
                """
                Move-to-worktree never became active.
                originalThreadID=\(originalThreadID)
                movedThreadID=\(moved.threadID)
                movedWorkspaceRoot=\(moved.workspaceRoot)
                activeSessionID=\(model.activeSession?.id.uuidString ?? "nil")
                activeThreadID=\(model.activeSession?.threadID ?? "nil")
                activeWorkspaceRoot=\(model.activeSession?.workspaceRoot ?? "nil")
                activeMode=\(String(describing: model.activeSession?.lastMode))
                recentSessions=\(model.recentSessions.map { "\($0.id.uuidString):\($0.threadID ?? "nil"):\($0.workspaceRoot ?? "nil")" }.joined(separator: " | "))
                """
            )
            XCTAssertEqual(moved.sessionID, originalSessionID)
            XCTAssertNotEqual(moved.threadID, originalThreadID)
            XCTAssertTrue(moved.workspaceRoot.contains("-worktrees/"))
            XCTAssertEqual(model.activeSession?.parentThreadID, originalThreadID)

            let returned = try await model.returnCurrentThreadToLocalCheckoutNow()
            let didReturn = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == returned.threadID
                    && model.activeSession?.workspaceRoot == workspaceRoot
                    && model.activeSession?.lastMode == .local
            }
            XCTAssertTrue(didReturn)
            XCTAssertEqual(returned.sessionID, originalSessionID)
            XCTAssertEqual(returned.threadID, originalThreadID)
            XCTAssertEqual(returned.workspaceRoot, workspaceRoot)
            XCTAssertEqual(model.activeSession?.parentThreadID, moved.threadID)
        }
    }

    func testLocalhostWorktreeFlowForksThreadIntoDistinctWorktreeSession() async throws {
        let workspaceRoot = try makeTemporaryGitFixtureRepo(prefix: "cotg-worktree-fork")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try await withLocalhostIntegrationEnvironment(
            workspaceRoot: workspaceRoot,
            label: "worktree-fork"
        ) {
            let model = AppModel(sceneID: "worktree-fork", bootstrapSnapshot: .preview)
            let originalThreadID = try await self.prepareConnectedLocalhostThread(
                model: model,
                workspaceRoot: workspaceRoot,
                markerPrefix: "COTG_WORKTREE_FORK"
            )
            let originalSessionID = try XCTUnwrap(model.activeSession?.id)

            let result = try await model.forkCurrentThreadToWorktreeNow(named: "flow-fork", branch: nil)

            let didActivateFork = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeSession?.id == result.sessionID
                    && model.activeSession?.threadID == result.threadID
                    && model.activeSession?.lastMode == .worktree
                    && model.activeSession?.workspaceRoot == result.workspaceRoot
            }
            XCTAssertTrue(
                didActivateFork,
                """
                Forked worktree session never became active.
                originalSessionID=\(originalSessionID)
                originalThreadID=\(originalThreadID)
                resultSessionID=\(result.sessionID)
                resultThreadID=\(result.threadID)
                resultWorkspaceRoot=\(result.workspaceRoot)
                activeSessionID=\(model.activeSession?.id.uuidString ?? "nil")
                activeThreadID=\(model.activeSession?.threadID ?? "nil")
                activeWorkspaceRoot=\(model.activeSession?.workspaceRoot ?? "nil")
                activeMode=\(String(describing: model.activeSession?.lastMode))
                recentSessions=\(model.recentSessions.map { "\($0.id.uuidString):\($0.threadID ?? "nil"):\($0.workspaceRoot ?? "nil"):\($0.parentThreadID ?? "nil")" }.joined(separator: " | "))
                """
            )
            XCTAssertNotEqual(result.threadID, originalThreadID)
            XCTAssertNotEqual(result.sessionID, originalSessionID)
            XCTAssertEqual(
                model.recentSessions.first(where: { $0.id == result.sessionID })?.parentThreadID,
                originalThreadID
            )
            XCTAssertEqual(
                model.recentSessions.first(where: { $0.id == originalSessionID })?.threadID,
                originalThreadID
            )
        }
    }

    func testLocalhostWorktreeFlowFallsBackToSafeLaneBeforeReturningToLocal() async throws {
        let workspaceRoot = try makeTemporaryGitFixtureRepo(prefix: "cotg-worktree-loopback")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try await withLocalhostIntegrationEnvironment(
            workspaceRoot: workspaceRoot,
            label: "worktree-loopback"
        ) {
            let model = AppModel(sceneID: "worktree-loopback", bootstrapSnapshot: .preview)
            let originalThreadID = try await self.prepareConnectedLocalhostThread(
                model: model,
                workspaceRoot: workspaceRoot,
                markerPrefix: "COTG_WORKTREE_LOOPBACK"
            )
            let originalLastTurnID = model.activeSession?.lastTurnID

            model.upgradeToLoopback()

            let didResolveUpgrade = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeProtocolKind == .websocket
                    || model.transcript.contains(where: { $0.text.contains("Loopback upgrade stayed on standby:") })
            }
            XCTAssertTrue(didResolveUpgrade)

            guard model.activeProtocolKind == .websocket else {
                throw XCTSkip("Loopback upgrade stayed on standby; skipping websocket-specific worktree fallback validation.")
            }

            let moved = try await model.moveCurrentThreadToWorktreeNow(named: "flow-loopback", branch: nil)
            let didMove = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeProtocolKind == .stdio
                    && model.activeSession?.threadID == moved.threadID
                    && model.activeSession?.workspaceRoot == moved.workspaceRoot
                    && model.activeSession?.lastMode == .worktree
            }
            XCTAssertTrue(
                didMove,
                "Loopback-upgraded worktree move never returned to the SSH safe lane. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
            )
            XCTAssertEqual(
                model.activeSession?.parentThreadID,
                originalThreadID,
                "Loopback move lost the parent thread reference. recentSessions=\(model.recentSessions.map { "\($0.id.uuidString):\($0.threadID ?? "nil"):\($0.parentThreadID ?? "nil"):\($0.parentLastTurnID ?? "nil"):\($0.lastTurnID ?? "nil")" }.joined(separator: " | "))"
            )
            XCTAssertEqual(
                model.activeSession?.parentLastTurnID,
                originalLastTurnID,
                "Loopback move lost the parent last-turn marker. recentSessions=\(model.recentSessions.map { "\($0.id.uuidString):\($0.threadID ?? "nil"):\($0.parentThreadID ?? "nil"):\($0.parentLastTurnID ?? "nil"):\($0.lastTurnID ?? "nil")" }.joined(separator: " | "))"
            )

            let returned = try await model.returnCurrentThreadToLocalCheckoutNow()
            let didReturn = try await self.waitUntil(timeoutNanoseconds: 60_000_000_000) {
                model.activeProtocolKind == .stdio
                    && model.activeSession?.threadID == returned.threadID
                    && model.activeSession?.workspaceRoot == workspaceRoot
                    && model.activeSession?.lastMode == .local
            }
            XCTAssertTrue(
                didReturn,
                "Loopback-upgraded worktree return never completed on the SSH safe lane. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
            )
            XCTAssertEqual(returned.threadID, originalThreadID)
            XCTAssertEqual(returned.workspaceRoot, workspaceRoot)
            XCTAssertEqual(model.activeSession?.parentThreadID, moved.threadID)
        }
    }

    func testLocalhostReconnectRestoresExistingThread() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-reconnect-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-reconnect-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-reconnect-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let initial = AppModel(
            sceneID: "reconnect-scene",
            bootstrapSnapshot: .preview
        )
        initial.select(machineID: MachineRecord.preview.id)
        initial.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = initial.connectionState, initial.activeProtocolKind == .stdio {
                return true
            }

            return initial.transcript.contains(where: { message in
                message.text.contains("Connected to the SSH safe lane over stdio.")
            })
        }
        XCTAssertTrue(
            didConnectInitially,
            "Initial safe-lane connection never became ready. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        _ = initial.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            reconnect: false
        )
        initial.connectionState = .connected("stdio://localhost")
        initial.activeProtocolKind = .stdio

        let marker = "COTG_MISSING_THREAD_\(UUID().uuidString)"
        initial.sendPrompt("Reply with \(marker) only.")

        let didCompleteInitialTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            initial.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains(marker)
            })
        }
        XCTAssertTrue(
            didCompleteInitialTurn,
            "Initial smoke turn never completed. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalThreadID = try XCTUnwrap(initial.activeSession?.threadID)
        try await Task.sleep(for: .milliseconds(500))

        let restored = AppModel(sceneID: "reconnect-scene")
        let launchContext = await restored.restorePersistedState()
        XCTAssertEqual(launchContext.selectedMachineID, MachineRecord.preview.id)
        XCTAssertEqual(restored.activeSession?.threadID, originalThreadID)

        restored.connectLocalLoopback()

        let didReconnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = restored.connectionState {
                return restored.activeSession?.threadID == originalThreadID
            }
            return false
        }
        XCTAssertTrue(
            didReconnect,
            "Reconnect never became ready. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let didRestoreHistory = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            restored.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains("COTG_APP_OK")
            })
        }
        XCTAssertTrue(
            didRestoreHistory,
            "Reconnect did not restore assistant history. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostReconnectFallsBackToBrowserWhenSelectedThreadIsUnavailable() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-missing-thread-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-missing-thread-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-missing-thread-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let initial = AppModel(
            sceneID: "missing-thread-scene",
            bootstrapSnapshot: .preview
        )
        initial.select(machineID: MachineRecord.preview.id)
        initial.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = initial.connectionState {
                return initial.activeProtocolKind == .stdio
            }

            return initial.transcript.contains(where: { $0.text.contains("Connected to the SSH safe lane over stdio.") })
        }
        _ = didConnectInitially

        if initial.activeSession?.threadID == nil {
            _ = initial.prepareNewSession(
                machineID: MachineRecord.preview.id,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareInitialThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = initial.connectionState {
                return initial.activeSession?.threadID != nil && initial.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didPrepareInitialThread,
            "Preparing the initial thread before the missing-thread fallback never completed. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let marker = "COTG_MISSING_THREAD_\(UUID().uuidString)"
        initial.sendPrompt("Reply with \(marker) only.")

        let didCompleteInitialTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            initial.activeSession?.threadID != nil
                && initial.transcript.contains(where: { message in
                    message.role == .assistant
                        && !message.isStreaming
                        && message.text.contains(marker)
                })
        }
        XCTAssertTrue(
            didCompleteInitialTurn,
            "Initial real-thread seed never completed. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalSessionID = try XCTUnwrap(initial.activeSession?.id)
        let missingThreadID = UUID().uuidString
        guard let sessionIndex = initial.recentSessions.firstIndex(where: { $0.id == originalSessionID }) else {
            XCTFail("Expected to find the active session before simulating a missing thread.")
            return
        }
        initial.recentSessions[sessionIndex].threadID = missingThreadID
        initial.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(500))

        let restored = AppModel(sceneID: "missing-thread-scene")
        let launchContext = await restored.restorePersistedState()
        XCTAssertEqual(launchContext.selectedMachineID, MachineRecord.preview.id)
        XCTAssertEqual(restored.activeSession?.threadID, missingThreadID)

        restored.connectLocalLoopback()

        let didFallbackToBrowser = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = restored.connectionState {
                return restored.activeSession?.threadID == nil
                    && restored.transcript.contains(where: {
                        $0.text.contains("Projects and threads are ready to browse.")
                    })
            }
            return false
        }
        XCTAssertTrue(
            didFallbackToBrowser,
            "Reconnect with a missing selected thread never recovered to the host browser. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )
        XCTAssertFalse(
            restored.transcript.contains(where: { $0.text.contains("Thread resume failed:") }),
            "Missing-thread fallback should recover to the browser instead of surfacing a hard resume failure. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostResumeOnConnectedSafeLaneFallsBackToBrowserWhenSelectedThreadIsUnavailable() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-connected-missing-thread-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-connected-missing-thread-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-connected-missing-thread-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "connected-missing-thread-scene",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }

            return model.transcript.contains(where: { $0.text.contains("Connected to the SSH safe lane over stdio.") })
        }
        _ = didConnectInitially

        if model.activeSession?.threadID == nil {
            let localhostMachineID = try XCTUnwrap(model.selectedMachine?.id)
            _ = model.prepareNewSession(
                machineID: localhostMachineID,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareInitialThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.threadID != nil && model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didPrepareInitialThread,
            "Preparing the initial thread before connected missing-thread recovery never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalSessionID = try XCTUnwrap(model.activeSession?.id)
        let missingThreadID = UUID().uuidString
        guard let sessionIndex = model.recentSessions.firstIndex(where: { $0.id == originalSessionID }) else {
            XCTFail("Expected to find the active session before simulating a missing thread on the live safe lane.")
            return
        }
        model.recentSessions[sessionIndex].threadID = missingThreadID

        model.resumeSession(originalSessionID, reconnect: true)

        let didFallbackToBrowser = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == nil
                    && model.activeSession?.unavailableSelectedThreadID == missingThreadID
                    && model.transcript.contains(where: {
                        $0.text.contains("I didn’t start a new thread automatically.")
                    })
            }
            return false
        }
        XCTAssertTrue(
            didFallbackToBrowser,
            "Connected missing-thread resume never recovered to the host browser. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
        XCTAssertFalse(
            model.transcript.contains(where: { $0.text.contains("Thread resume failed:") }),
            "Connected missing-thread resume should recover to the browser instead of surfacing a hard resume failure. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostReconnectFallbackDoesNotAutoStartReplacementThreadAfterSelectedThreadBecomesUnavailable() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-reconnect-send-missing-thread-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-reconnect-send-missing-thread-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-reconnect-send-missing-thread-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "reconnect-send-missing-thread-scene",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }

            return model.transcript.contains(where: { $0.text.contains("Connected to the SSH safe lane over stdio.") })
        }
        _ = didConnectInitially

        if model.activeSession?.threadID == nil {
            let localhostMachineID = try XCTUnwrap(model.selectedMachine?.id)
            _ = model.prepareNewSession(
                machineID: localhostMachineID,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareInitialThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.threadID != nil && model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didPrepareInitialThread,
            "Preparing the initial thread before reconnect-missing-thread protection never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalSessionID = try XCTUnwrap(model.activeSession?.id)
        let initialSessionCount = model.recentSessions.count
        let missingThreadID = UUID().uuidString
        guard let sessionIndex = model.recentSessions.firstIndex(where: { $0.id == originalSessionID }) else {
            XCTFail("Expected to find the active session before simulating a reconnect fallback on a missing thread.")
            return
        }
        model.recentSessions[sessionIndex].threadID = missingThreadID

        model.resumeSession(originalSessionID, reconnect: true)

        let didFallbackToUnavailableState = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == nil
                    && model.activeSession?.unavailableSelectedThreadID == missingThreadID
            }
            return false
        }
        XCTAssertTrue(
            didFallbackToUnavailableState,
            "Expected reconnect to keep the session threadless and marked unavailable instead of silently binding a replacement thread. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        model.sendPrompt("Repeat the prior upload context.")

        let didStayThreadless = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == nil
                    && model.activeSession?.unavailableSelectedThreadID == missingThreadID
                    && model.activeTurnID == nil
                    && model.recentSessions.count == initialSessionCount
                    && model.transcript.contains(where: {
                        $0.text.contains("I didn’t start a new thread automatically.")
                    })
            }
            return false
        }
        XCTAssertTrue(
            didStayThreadless,
            "Reconnect fallback should keep requiring explicit thread selection instead of auto-starting a replacement thread on send. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostSendDoesNotSilentlyStartNewThreadWhenSelectedThreadIsUnavailable() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-send-missing-thread-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-send-missing-thread-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-send-missing-thread-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "send-missing-thread-scene",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }

            return model.transcript.contains(where: { $0.text.contains("Connected to the SSH safe lane over stdio.") })
        }
        _ = didConnectInitially

        if model.activeSession?.threadID == nil {
            let localhostMachineID = try XCTUnwrap(model.selectedMachine?.id)
            _ = model.prepareNewSession(
                machineID: localhostMachineID,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareInitialThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.threadID != nil && model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didPrepareInitialThread,
            "Preparing the initial thread before missing-thread send protection never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalSessionID = try XCTUnwrap(model.activeSession?.id)
        guard let sessionIndex = model.recentSessions.firstIndex(where: { $0.id == originalSessionID }) else {
            XCTFail("Expected to find the active session before simulating a missing-thread send.")
            return
        }

        model.recentSessions[sessionIndex].threadID = UUID().uuidString
        model.resumeSession(originalSessionID, reconnect: false)

        model.sendPrompt("Repeat the prior upload context.")

        let didFailHonestly = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.id == originalSessionID
                    && model.activeSession?.threadID == nil
                    && model.activeSession?.unavailableSelectedThreadID != nil
                    && model.activeTurnID == nil
                    && model.transcript.contains(where: {
                        $0.text.contains("I didn’t start a new thread automatically.")
                    })
            }
            return false
        }
        XCTAssertTrue(
            didFailHonestly,
            "Missing-thread send should fail honestly instead of creating a fresh thread. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testPersistedSessionCatalogEntryUsesGenericRestoredPreview() {
        let session = SessionRecord(
            machineID: MachineRecord.preview.id,
            threadID: "thread-restored",
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastTurn: RecentTurnMetadata(
                turnID: "turn-restored",
                summary: "I need one line of context on what you want repeated.",
                completedAt: .now
            ),
            lastOpenedAt: .now
        )

        let entry = AppHostThreadCatalogCoordinator.entry(
            fromPersistedSession: session,
            normalizeWorkspaceRoot: { $0 }
        )

        XCTAssertEqual(entry?.id, "thread-restored")
        XCTAssertEqual(entry?.name, nil)
        XCTAssertEqual(entry?.preview, "Restored thread")
    }

    func testPersistedSessionCatalogEntryPreservesThreadDisplayTitle() {
        let session = SessionRecord(
            machineID: MachineRecord.preview.id,
            threadID: "thread-restored",
            threadDisplayTitle: "app store upload",
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastTurn: RecentTurnMetadata(
                turnID: "turn-restored",
                summary: "Again",
                completedAt: .now
            ),
            lastOpenedAt: .now
        )

        let entry = AppHostThreadCatalogCoordinator.entry(
            fromPersistedSession: session,
            normalizeWorkspaceRoot: { $0 }
        )

        XCTAssertEqual(entry?.id, "thread-restored")
        XCTAssertEqual(entry?.name, "app store upload")
        XCTAssertEqual(entry?.preview, "Restored thread")
    }

    func testReplacingEntriesPreservesPersistedThreadDisplayTitleOverLivePromptLikeName() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            threadID: "thread-app-store-upload",
            threadDisplayTitle: "app store upload",
            workspaceRoot: Self.workspaceRoot,
            lastKnownProtocol: .stdio,
            lastKnownRouteKind: .manualSSH,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let cachedEntry = HostThreadCatalogEntry(
            id: "thread-app-store-upload",
            machineID: machine.id,
            workspaceRoot: Self.workspaceRoot,
            name: "app store upload",
            preview: "Restored thread",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let liveSummary = CodexThreadSummary(
            id: "thread-app-store-upload",
            cwd: Self.workspaceRoot,
            preview: "I need one line of context on what you want repeated.",
            modelProvider: "openai",
            name: "Again",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300),
            status: .idle
        )

        let replacement = AppHostThreadCatalogCoordinator.replacingEntries(
            [liveSummary],
            machine: machine,
            hostThreadCatalog: [cachedEntry],
            recentSessions: [session],
            activeProtocolKind: .stdio,
            routeID: nil,
            routeKind: .manualSSH,
            bootstrap: .standardSSH,
            normalizeWorkspaceRoot: { $0 },
            workspaceMode: { _ in .local },
            provenanceByThreadID: [liveSummary.id: .liveAppServer],
            observedAt: Date(timeIntervalSince1970: 350)
        )

        let updatedEntry = replacement.hostThreadCatalog.first(where: { $0.id == liveSummary.id })
        XCTAssertEqual(updatedEntry?.name, "app store upload")
        XCTAssertEqual(updatedEntry?.preview, "I need one line of context on what you want repeated.")
        XCTAssertEqual(replacement.recentSessions.first?.threadDisplayTitle, "app store upload")
    }

    func testLocalhostHostThreadCatalogResumeRestoresHistoryAndKeepsSameThread() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-host-browser-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-host-browser-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-host-browser-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let initial = AppModel(
            sceneID: "host-browser-initial",
            bootstrapSnapshot: .preview
        )
        initial.select(machineID: MachineRecord.preview.id)
        initial.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = initial.connectionState {
                return initial.activeProtocolKind == .stdio
            }

            return initial.transcript.contains(where: { message in
                message.text.contains("Connected to the SSH safe lane over stdio.")
            })
        }
        _ = didConnectInitially

        if initial.activeSession?.threadID == nil {
            _ = initial.prepareNewSession(
                machineID: MachineRecord.preview.id,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareInitialThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = initial.connectionState {
                return initial.activeSession?.threadID != nil && initial.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didPrepareInitialThread,
            "Preparing the initial host-browser thread never completed. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        initial.sendSmokeTestPrompt()

        let didCompleteInitialTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            initial.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains("COTG_APP_OK")
            })
        }
        XCTAssertTrue(
            didCompleteInitialTurn,
            "Initial host-browser smoke turn never completed. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalThreadID = try XCTUnwrap(initial.activeSession?.threadID)
        await initial.refreshRepoBrowserSessions()
        XCTAssertTrue(initial.hostThreadCatalog.contains(where: { $0.id == originalThreadID }))

        initial.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(500))

        let restored = AppModel(sceneID: "host-browser-restored")
        _ = await restored.restorePersistedState()
        let entry = try XCTUnwrap(restored.hostThreadCatalog.first(where: { $0.id == originalThreadID }))

        let resumedSessionID = restored.resumeHostThreadCatalogEntry(entry)
        XCTAssertNotNil(resumedSessionID)

        restored.sendSmokeTestPrompt()

        let didResumeSelectedThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = restored.connectionState {
                return restored.activeSession?.threadID == originalThreadID
            }
            return false
        }
        XCTAssertTrue(
            didResumeSelectedThread,
            "Resuming from the host thread catalog never restored the selected thread. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let didRestoreHistory = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            restored.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains("COTG_APP_OK")
            })
        }
        XCTAssertTrue(
            didRestoreHistory,
            "Host-thread resume did not restore assistant history. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let didContinueOnSameThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            restored.activeSession?.threadID == originalThreadID
                && restored.transcript.filter({
                    $0.role == .assistant && !$0.isStreaming && $0.text.contains("COTG_APP_OK")
                }).count >= 2
        }
        XCTAssertTrue(
            didContinueOnSameThread,
            "Continuing from the resumed host thread diverged from the original thread. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostCrossDeviceContinuityRestoresSharedThreadHistoryAcrossModels() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let marker = "Cross-device continuity marker \(UUID().uuidString)"
        let metadataPath = "/tmp/cotg-cross-device-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-cross-device-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-cross-device-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let phoneModel = AppModel(
            sceneID: "cross-device-phone",
            bootstrapSnapshot: .preview
        )
        phoneModel.select(machineID: MachineRecord.preview.id)
        phoneModel.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 120_000_000_000) {
            if case .connected = phoneModel.connectionState {
                return phoneModel.activeProtocolKind == .stdio
            }

            return phoneModel.transcript.contains(where: { message in
                message.text.contains("Connected to the SSH safe lane over stdio.")
            })
        }
        _ = didConnectInitially

        if phoneModel.activeSession?.threadID == nil {
            _ = phoneModel.prepareNewSession(
                machineID: MachineRecord.preview.id,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareInitialThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = phoneModel.connectionState {
                return phoneModel.activeSession?.threadID != nil && phoneModel.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(didPrepareInitialThread)

        phoneModel.sendPrompt("Repeat exactly: \(marker)")

        let didSeedMarkerTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            phoneModel.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains(marker)
            })
        }
        XCTAssertTrue(
            didSeedMarkerTurn,
            "Initial cross-device seed never completed. Transcript: \(phoneModel.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalThreadID = try XCTUnwrap(phoneModel.activeSession?.threadID)
        await phoneModel.refreshRepoBrowserSessions()
        let originalEntry = try XCTUnwrap(phoneModel.hostThreadCatalog.first(where: { $0.id == originalThreadID }))

        phoneModel.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(500))

        let ipadModel = AppModel(sceneID: "cross-device-ipad")
        _ = await ipadModel.restorePersistedState()

        let resumedSessionID = ipadModel.resumeHostThreadCatalogEntry(originalEntry)
        XCTAssertNotNil(resumedSessionID)

        let didRestoreSameThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = ipadModel.connectionState {
                return ipadModel.activeSession?.threadID == originalThreadID
            }
            return false
        }
        XCTAssertTrue(
            didRestoreSameThread,
            "Cross-device restore never bound the second model to the original thread. Transcript: \(ipadModel.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let didRestoreMarkerHistory = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            ipadModel.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains(marker)
            })
        }
        XCTAssertTrue(
            didRestoreMarkerHistory,
            "Cross-device restore did not surface the seeded marker in transcript history. Transcript: \(ipadModel.transcript.map { $0.text }.joined(separator: " | "))"
        )

        ipadModel.sendSmokeTestPrompt()

        let didContinueSameThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            ipadModel.activeSession?.threadID == originalThreadID
                && ipadModel.transcript.contains(where: { message in
                    message.role == .assistant
                        && !message.isStreaming
                        && message.text.contains("COTG_APP_OK")
                })
        }
        XCTAssertTrue(
            didContinueSameThread,
            "Cross-device follow-up prompt diverged from the shared host-backed thread. Transcript: \(ipadModel.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testLocalhostReconnectRestoresExistingThreadAcrossNewSceneIdentifier() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-reconnect-cross-scene-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-reconnect-cross-scene-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-reconnect-cross-scene-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let initial = AppModel(
            sceneID: "reconnect-scene-initial",
            bootstrapSnapshot: .preview
        )
        initial.select(machineID: MachineRecord.preview.id)
        initial.connectLocalLoopback()

        let didConnectInitially = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = initial.connectionState {
                return initial.activeSession?.threadID != nil
            }
            return false
        }
        XCTAssertTrue(
            didConnectInitially,
            "Initial cross-scene safe-lane connection never became ready. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        initial.sendSmokeTestPrompt()

        let didCompleteInitialTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            initial.transcript.contains(where: { message in
                message.role == .assistant
                    && !message.isStreaming
                    && message.text.contains("COTG_APP_OK")
            })
        }
        XCTAssertTrue(
            didCompleteInitialTurn,
            "Initial cross-scene smoke turn never completed. Transcript: \(initial.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalThreadID = try XCTUnwrap(initial.activeSession?.threadID)
        initial.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(500))

        let restored = AppModel(sceneID: "reconnect-scene-restored")
        let launchContext = await restored.restorePersistedState()
        XCTAssertEqual(launchContext.selectedMachineID, MachineRecord.preview.id)
        XCTAssertEqual(restored.activeSession?.threadID, originalThreadID)

        restored.connectLocalLoopback()

        let didReconnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = restored.connectionState {
                return restored.activeSession?.threadID == originalThreadID
            }
            return false
        }
        XCTAssertTrue(
            didReconnect,
            "Cross-scene reconnect never resumed the original thread. Transcript: \(restored.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testShouldAutoUpgradeLoopbackDefaultsToTrueOutsideTests() {
        XCTAssertTrue(AppModel.shouldAutoUpgradeLoopback(environment: [:]))
        XCTAssertTrue(
            AppModel.shouldAutoUpgradeLoopback(
                environment: [
                    "COTG_ENABLE_AUTO_UPGRADE": "1",
                    "UI_TESTING": "1"
                ]
            )
        )
    }

    func testShouldAutoUpgradeLoopbackRespectsDisableAndTestGuards() {
        XCTAssertFalse(
            AppModel.shouldAutoUpgradeLoopback(
                environment: ["COTG_DISABLE_AUTO_UPGRADE": "1"]
            )
        )
        XCTAssertFalse(
            AppModel.shouldAutoUpgradeLoopback(
                environment: ["UI_TESTING": "1"]
            )
        )
        XCTAssertFalse(
            AppModel.shouldAutoUpgradeLoopback(
                environment: ["XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration"]
            )
        )
    }

    func testHostRuntimeTransportStatusClassifiesMacNetworkWarnings() {
        let retry = AppModel.hostRuntimeTransportStatus(from: "Mac-side Codex retry: Reconnecting... 3/5")
        XCTAssertEqual(retry?.kind, .retrying)
        XCTAssertEqual(retry?.label, "Mac Codex retry")
        XCTAssertEqual(retry?.detail, "Mac-side Codex retry: Reconnecting... 3/5")

        let fallback = AppModel.hostRuntimeTransportStatus(
            from: "Falling back from WebSockets to HTTPS transport. timeout waiting for child process to exit"
        )
        XCTAssertEqual(fallback?.kind, .httpsFallback)
        XCTAssertEqual(fallback?.label, "Mac Codex on HTTPS")

        let loopbackFallback = AppModel.hostRuntimeTransportStatus(
            from: "Loopback listener degraded. Falling back to the SSH safe lane."
        )
        XCTAssertEqual(loopbackFallback?.kind, .loopbackFallback)
        XCTAssertEqual(loopbackFallback?.label, "SSH fallback")

        let threadRefresh = AppModel.hostRuntimeTransportStatus(
            from: "Thread refresh failed: The operation couldn’t be completed. (NIOCore.ChannelError error 5.)"
        )
        XCTAssertEqual(threadRefresh?.kind, .threadRefreshFailed)
        XCTAssertEqual(threadRefresh?.label, "Thread sync retry")

        XCTAssertNil(AppModel.hostRuntimeTransportStatus(from: "Host runtime warning."))
    }

    func testShouldAttemptAutomaticLoopbackUpgradeRequiresConnectedStdioThread() {
        XCTAssertFalse(
            AppModel.shouldAttemptAutomaticLoopbackUpgrade(
                pending: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptAutomaticLoopbackUpgrade(
                pending: true,
                protocolKind: .websocket,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptAutomaticLoopbackUpgrade(
                pending: true,
                protocolKind: .stdio,
                isConnected: false,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptAutomaticLoopbackUpgrade(
                pending: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: false,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptAutomaticLoopbackUpgrade(
                pending: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: nil
            )
        )
        XCTAssertTrue(
            AppModel.shouldAttemptAutomaticLoopbackUpgrade(
                pending: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
    }

    func testShouldRetryPreferredLoopbackUpgradeRequiresIdleHealthyStdioContext() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(
            AppModel.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true,
                canUseOptimizationLane: true,
                lastAttemptAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppModel.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true,
                canUseOptimizationLane: true,
                lastAttemptAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppModel.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .websocket,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true,
                canUseOptimizationLane: true,
                lastAttemptAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppModel.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: "turn-1",
                loopbackUpgradeFeatureAvailable: true,
                canUseOptimizationLane: true,
                lastAttemptAt: nil,
                now: now
            )
        )
    }

    func testShouldRetryPreferredLoopbackUpgradeThrottlesRecentAttempts() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(
            AppModel.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true,
                canUseOptimizationLane: true,
                lastAttemptAt: Date(timeIntervalSince1970: 80),
                now: now,
                minimumRetryInterval: 30
            )
        )
        XCTAssertTrue(
            AppModel.shouldRetryPreferredLoopbackUpgrade(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true,
                canUseOptimizationLane: true,
                lastAttemptAt: Date(timeIntervalSince1970: 60),
                now: now,
                minimumRetryInterval: 30
            )
        )
    }

    func testShouldScheduleLoopbackRecoveryRetryRequiresLoopbackFallbackContext() {
        XCTAssertTrue(
            AppModel.shouldScheduleLoopbackRecoveryRetry(
                summary: "Loopback listener degraded. Falling back to the SSH safe lane.",
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleLoopbackRecoveryRetry(
                summary: "Returned to the SSH safe lane for Local / Worktree routing.",
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleLoopbackRecoveryRetry(
                summary: "Loopback listener degraded. Falling back to the SSH safe lane.",
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: nil,
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
    }

    func testShouldRecoverPreferredLoopbackAfterRelaunchRequiresHealthyConnectedStdioThread() {
        XCTAssertTrue(
            AppModel.shouldRecoverPreferredLoopbackAfterRelaunch(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldRecoverPreferredLoopbackAfterRelaunch(
                shouldAutoUpgrade: false,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldRecoverPreferredLoopbackAfterRelaunch(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldRecoverPreferredLoopbackAfterRelaunch(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .websocket,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldRecoverPreferredLoopbackAfterRelaunch(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1",
                activeTurnID: "turn-1",
                loopbackUpgradeFeatureAvailable: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldRecoverPreferredLoopbackAfterRelaunch(
                shouldAutoUpgrade: true,
                isSuppressedUntilReconnect: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: nil,
                activeTurnID: nil,
                loopbackUpgradeFeatureAvailable: true
            )
        )
    }

    func testShouldScheduleAutomaticLoopbackUpgradeRequiresBoundThreadAtConnect() {
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgrade(
                preferLoopbackUpgrade: false,
                unavailableSelectedThreadID: nil,
                hasBoundThread: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgrade(
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: "thread-unavailable",
                hasBoundThread: true
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgrade(
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: nil,
                hasBoundThread: false
            )
        )
        XCTAssertTrue(
            AppModel.shouldScheduleAutomaticLoopbackUpgrade(
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: nil,
                hasBoundThread: true
            )
        )
    }

    func testShouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn() {
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
                hadConcreteThreadBeforeTurn: true,
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: nil,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
                hadConcreteThreadBeforeTurn: false,
                preferLoopbackUpgrade: false,
                unavailableSelectedThreadID: nil,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
                hadConcreteThreadBeforeTurn: false,
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: "thread-unavailable",
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
                hadConcreteThreadBeforeTurn: false,
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: nil,
                threadID: nil
            )
        )
        XCTAssertTrue(
            AppModel.shouldScheduleAutomaticLoopbackUpgradeAfterPreparingThreadlessTurn(
                hadConcreteThreadBeforeTurn: false,
                preferLoopbackUpgrade: true,
                unavailableSelectedThreadID: nil,
                threadID: "thread-1"
            )
        )
    }

    func testShouldAttemptSigningSensitiveLoopbackUpgradeRequiresHealthyStdioContext() {
        XCTAssertFalse(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: false,
                preferLoopbackUpgrade: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: true,
                preferLoopbackUpgrade: false,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: true,
                preferLoopbackUpgrade: true,
                protocolKind: .websocket,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: true,
                preferLoopbackUpgrade: true,
                protocolKind: .stdio,
                isConnected: false,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: true,
                preferLoopbackUpgrade: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: false,
                threadID: "thread-1"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: true,
                preferLoopbackUpgrade: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: nil
            )
        )
        XCTAssertTrue(
            AppModel.shouldAttemptSigningSensitiveLoopbackUpgrade(
                requiresSigningSensitiveHostReadiness: true,
                preferLoopbackUpgrade: true,
                protocolKind: .stdio,
                isConnected: true,
                hasSelectedMachine: true,
                threadID: "thread-1"
            )
        )
    }

    func testIsSigningSensitiveTurnTextDetectsReleaseAndCodesignCommands() {
        XCTAssertTrue(
            AppModel.isSigningSensitiveTurnText(
                "Run the exact shell command security find-identity -v -p codesigning and /usr/bin/codesign /bin/ls."
            )
        )
        XCTAssertTrue(
            AppModel.isSigningSensitiveTurnText(
                "Use xcodebuild -archivePath /tmp/CodingOnTheGo.xcarchive archive, then exportArchive and upload to TestFlight."
            )
        )
        XCTAssertFalse(
            AppModel.isSigningSensitiveTurnText(
                "Archive this thread in the browser and upload the screenshot to docs."
            )
        )
        XCTAssertFalse(
            AppModel.isSigningSensitiveTurnText(
                "Explain why codesign can fail on macOS."
            )
        )
    }

    func testIsUploadAuthSensitiveTurnTextDetectsAscAndReleaseUpload() {
        XCTAssertTrue(AppModel.isUploadAuthSensitiveTurnText("Run asc auth token --confirm before upload."))
        XCTAssertTrue(AppModel.isSigningSensitiveTurnText("Run asc auth token --confirm before upload."))
        XCTAssertTrue(AppModel.isUploadAuthSensitiveTurnText("Use asc apps list --output json."))
        XCTAssertTrue(AppModel.isUploadAuthSensitiveTurnText("Upload this build to TestFlight."))
        XCTAssertTrue(AppModel.isUploadAuthSensitiveTurnText("Submit the app to App Store Connect."))
        XCTAssertFalse(AppModel.isUploadAuthSensitiveTurnText("Upload the screenshot to docs."))
        XCTAssertFalse(AppModel.isUploadAuthSensitiveTurnText("Archive the local notes."))
    }

    func testSigningSensitiveHostReadinessProbeCommandIncludesUploadAuthWhenRequested() {
        let signingOnlyCommand = AppModel.signingSensitiveHostReadinessProbeCommand(includeUploadAuth: false)
        let uploadCommand = AppModel.signingSensitiveHostReadinessProbeCommand(includeUploadAuth: true)

        XCTAssertTrue(signingOnlyCommand.contains("launchctl submit"))
        XCTAssertTrue(signingOnlyCommand.contains("__COTG_LAUNCHCTL_SUBMIT_BEGIN__"))
        XCTAssertTrue(signingOnlyCommand.contains("security find-identity -v -p codesigning"))
        XCTAssertTrue(signingOnlyCommand.contains("run_with_timeout 20 /usr/bin/codesign"))
        XCTAssertTrue(signingOnlyCommand.contains("CODESIGN_PROBE_TIMEOUT"))
        XCTAssertTrue(signingOnlyCommand.contains("/usr/bin/codesign --force --sign"))
        XCTAssertFalse(signingOnlyCommand.contains("asc auth token --confirm"))
        XCTAssertTrue(uploadCommand.contains("asc auth token --confirm"))
        XCTAssertTrue(uploadCommand.contains("ASC_AUTH_TIMEOUT"))
        XCTAssertTrue(uploadCommand.contains("asc apps list --limit 1 --output json"))
    }

    func testSigningSensitiveHostReadinessProbeFailureDetailClassifiesUploadAuthFailures() {
        let authFailure = SSHRemoteCommandResult(
            exitStatus: 31,
            standardOutput: "",
            errorOutput: """
            Error: auth token: credentials not found for profile "CodingOnTheGo"
            __COTG_PREFLIGHT_ASC_AUTH_FAILED__
            """
        )
        XCTAssertTrue(
            AppModel.signingSensitiveHostReadinessProbeFailureDetail(
                authFailure,
                includeUploadAuth: true
            ).contains("Upload auth not ready: asc could not load credentials for the active profile")
        )

        let authTimeout = SSHRemoteCommandResult(
            exitStatus: 33,
            standardOutput: "",
            errorOutput: "__COTG_PREFLIGHT_ASC_AUTH_TIMEOUT__"
        )
        XCTAssertTrue(
            AppModel.signingSensitiveHostReadinessProbeFailureDetail(
                authTimeout,
                includeUploadAuth: true
            ).contains("Upload auth not ready: asc auth timed out waiting for keychain or account access")
        )

        let codesignFailure = SSHRemoteCommandResult(
            exitStatus: 16,
            standardOutput: "",
            errorOutput: "__COTG_PREFLIGHT_CODESIGN_PROBE_FAILED__"
        )
        XCTAssertTrue(
            AppModel.signingSensitiveHostReadinessProbeFailureDetail(
                codesignFailure,
                includeUploadAuth: false
            ).contains("Signing not ready: codesign probe failed")
        )
    }

    func testSigningSensitiveTurnLaneFailureDetailRequiresWebsocket() {
        XCTAssertEqual(
            AppModel.signingSensitiveTurnLaneFailureDetail(
                protocolKind: .stdio,
                lastLoopbackUpgradeStandbyReason: nil
            ),
            "Loopback not upgraded to the GUI-session websocket lane."
        )
        XCTAssertEqual(
            AppModel.signingSensitiveTurnLaneFailureDetail(
                protocolKind: .directEndpoint,
                lastLoopbackUpgradeStandbyReason: "Loopback listener did not become healthy in time."
            ),
            "Loopback upgrade stayed on standby: Loopback listener did not become healthy in time."
        )
        XCTAssertNil(
            AppModel.signingSensitiveTurnLaneFailureDetail(
                protocolKind: .websocket,
                lastLoopbackUpgradeStandbyReason: "stale"
            )
        )
    }

    func testLoopbackUpgradeResumeMismatchMessageRequiresExactActiveThreadResume() {
        XCTAssertNil(
            AppModel.loopbackUpgradeResumeMismatchMessage(
                expectedThreadID: nil,
                resumedThreadID: nil
            )
        )

        XCTAssertEqual(
            AppModel.loopbackUpgradeResumeMismatchMessage(
                expectedThreadID: "thread-live-1",
                resumedThreadID: nil
            ),
            "Loopback websocket could not resume the active thread. Staying on the SSH safe lane."
        )

        XCTAssertEqual(
            AppModel.loopbackUpgradeResumeMismatchMessage(
                expectedThreadID: "thread-live-1",
                resumedThreadID: "thread-live-2"
            ),
            "Loopback websocket resumed a different thread. Staying on the SSH safe lane."
        )

        XCTAssertNil(
            AppModel.loopbackUpgradeResumeMismatchMessage(
                expectedThreadID: "thread-live-1",
                resumedThreadID: "thread-live-1"
            )
        )
    }

    func testRequestedThreadResumeMismatchMessageRequiresExactRequestedThreadResume() {
        XCTAssertNil(
            AppModel.requestedThreadResumeMismatchMessage(
                expectedThreadID: nil,
                resumedThreadID: nil
            )
        )

        XCTAssertEqual(
            AppModel.requestedThreadResumeMismatchMessage(
                expectedThreadID: "thread-live-1",
                resumedThreadID: nil
            ),
            "Requested thread resume could not resume the requested thread. I didn’t switch to a different thread automatically."
        )

        XCTAssertEqual(
            AppModel.requestedThreadResumeMismatchMessage(
                expectedThreadID: "thread-live-1",
                resumedThreadID: "thread-live-2"
            ),
            "Requested thread resume resumed a different thread. I didn’t switch to a different thread automatically."
        )

        XCTAssertNil(
            AppModel.requestedThreadResumeMismatchMessage(
                expectedThreadID: "thread-live-1",
                resumedThreadID: "thread-live-1"
            )
        )
    }

    func testResumableThreadIDRequiresAnExplicitBoundOrSelectedThread() {
        XCTAssertEqual(
            AppModel.resumableThreadID(
                boundProtocolThreadID: "thread-live-1",
                activeSessionThreadID: "thread-session-1",
                requiresExplicitThreadSelection: false
            ),
            "thread-session-1"
        )
        XCTAssertEqual(
            AppModel.resumableThreadID(
                boundProtocolThreadID: nil,
                activeSessionThreadID: "thread-session-1",
                requiresExplicitThreadSelection: false
            ),
            "thread-session-1"
        )
        XCTAssertNil(
            AppModel.resumableThreadID(
                boundProtocolThreadID: nil,
                activeSessionThreadID: nil,
                requiresExplicitThreadSelection: false
            )
        )
        XCTAssertNil(
            AppModel.resumableThreadID(
                boundProtocolThreadID: "thread-live-1",
                activeSessionThreadID: "thread-session-1",
                requiresExplicitThreadSelection: true
            )
        )
        XCTAssertNil(
            AppModel.resumableThreadID(
                boundProtocolThreadID: "   ",
                activeSessionThreadID: "\n",
                requiresExplicitThreadSelection: false
            )
        )
    }

    func testSafeLaneFallbackThreadIDPrefersTheSelectedSessionThread() {
        XCTAssertEqual(
            AppModel.safeLaneFallbackThreadID(
                activeSessionThreadID: "thread-session-1",
                stdioThreadID: "thread-stdio-1"
            ),
            "thread-session-1"
        )
        XCTAssertEqual(
            AppModel.safeLaneFallbackThreadID(
                activeSessionThreadID: nil,
                stdioThreadID: "thread-stdio-1"
            ),
            "thread-stdio-1"
        )
        XCTAssertEqual(
            AppModel.safeLaneFallbackThreadID(
                activeSessionThreadID: "  ",
                stdioThreadID: "\nthread-stdio-1\n"
            ),
            "thread-stdio-1"
        )
        XCTAssertNil(
            AppModel.safeLaneFallbackThreadID(
                activeSessionThreadID: " ",
                stdioThreadID: "\n"
            )
        )
    }

    func testTurnStartThreadIDPrefersSelectedSessionThreadOverProtocolBinding() {
        XCTAssertEqual(
            AppModel.turnStartThreadID(
                preferredThreadID: nil,
                boundProtocolThreadID: "thread-event-1",
                activeSessionThreadID: "thread-selected-1",
                initialThreadID: "thread-initial-1"
            ),
            "thread-selected-1"
        )
        XCTAssertEqual(
            AppModel.turnStartThreadID(
                preferredThreadID: "thread-explicit-1",
                boundProtocolThreadID: "thread-event-1",
                activeSessionThreadID: "thread-selected-1",
                initialThreadID: "thread-initial-1"
            ),
            "thread-explicit-1"
        )
        XCTAssertEqual(
            AppModel.turnStartThreadID(
                preferredThreadID: nil,
                boundProtocolThreadID: "thread-event-1",
                activeSessionThreadID: "  ",
                initialThreadID: "thread-initial-1"
            ),
            "thread-event-1"
        )
    }

    func testServerStartedThreadEventDoesNotReplaceSelectedOrBoundThread() {
        XCTAssertFalse(
            AppModel.shouldBindServerStartedThreadEvent(
                activeSessionThreadID: "thread-selected-1",
                existingProtocolThreadID: nil
            )
        )
        XCTAssertFalse(
            AppModel.shouldBindServerStartedThreadEvent(
                activeSessionThreadID: nil,
                existingProtocolThreadID: "thread-stdio-1"
            )
        )
        XCTAssertTrue(
            AppModel.shouldBindServerStartedThreadEvent(
                activeSessionThreadID: " ",
                existingProtocolThreadID: "\n"
            )
        )
    }

    func testLocalhostLoopbackUpgradeAndFallback() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-loopback-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-loopback-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-loopback-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "loopback-upgrade",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectLocalLoopback()

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didConnect,
            "Safe-lane connect never became ready. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        if model.activeSession?.threadID == nil {
            _ = model.prepareNewSession(
                machineID: MachineRecord.preview.id,
                workspaceRoot: Self.workspaceRoot,
                reconnect: true
            )
        }

        let didPrepareThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeSession?.threadID != nil && model.activeProtocolKind == .stdio
            }
            return false
        }
        XCTAssertTrue(
            didPrepareThread,
            "Preparing a live thread on the safe lane never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let originalThreadID = try XCTUnwrap(model.activeSession?.threadID)
        model.upgradeToLoopback()

        let didResolveUpgrade = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            model.activeProtocolKind == .websocket
                || model.transcript.contains(where: { $0.text.contains("Loopback upgrade stayed on standby:") })
        }
        XCTAssertTrue(
            didResolveUpgrade,
            "Loopback upgrade never resolved. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        guard model.activeProtocolKind == .websocket else {
            XCTAssertEqual(model.activeProtocolKind, .stdio)
            XCTAssertTrue(
                model.transcript.contains(where: { $0.text.contains("Loopback upgrade stayed on standby:") }),
                "Loopback standby state was never surfaced. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
            )
            return
        }

        XCTAssertEqual(
            model.activeSession?.threadID,
            originalThreadID,
            "Loopback upgrade should keep the selected thread anchored instead of rebinding to a different thread. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        model.sendSmokeTestPrompt()
        let didCompleteLoopbackSmokeTurn = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            model.activeProtocolKind == .websocket
                && model.transcript.contains(where: { message in
                    message.role == .assistant
                        && !message.isStreaming
                        && message.text.contains("COTG_APP_OK")
                })
        }
        XCTAssertTrue(
            didCompleteLoopbackSmokeTurn,
            "Smoke turn after loopback upgrade never completed on the upgraded lane. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        await model.refreshRepoBrowserSessions()
        let browserThreadIDs = model.hostThreadCatalog.map(\.id)
        let transcriptSummary = model.transcript.map(\.text).joined(separator: " | ")
        XCTAssertTrue(
            model.hostThreadCatalog.contains(where: { $0.id == originalThreadID }),
            "Refreshing the host browser after loopback upgrade dropped the real thread catalog. Browser: \(browserThreadIDs) Transcript: \(transcriptSummary)"
        )

        model.stopLoopbackListener()

        let didFallback = try await waitUntil(timeoutNanoseconds: 30_000_000_000) {
            model.activeProtocolKind == .stdio
        }
        XCTAssertTrue(
            didFallback,
            "Safe-lane fallback never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
        XCTAssertEqual(
            model.activeSession?.threadID,
            originalThreadID,
            "Safe-lane fallback should restore the original stdio thread anchor. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
    }

    func testSigningSensitiveTurnFailsClosedWhenLoopbackLaneIsUnavailable() async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-signing-sensitive-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-signing-sensitive-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-signing-sensitive-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", Self.workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        let model = AppModel(
            sceneID: "signing-sensitive-stdio",
            bootstrapSnapshot: .preview
        )
        model.select(machineID: MachineRecord.preview.id)
        model.connectSelectedMachine(preferLoopbackUpgrade: false)

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
                    && model.activeSession?.threadID != nil
            }
            return false
        }
        XCTAssertTrue(
            didConnect,
            "Safe-lane connection never became ready. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        model.sendPrompt("Use xcodebuild -archivePath /tmp/CodingOnTheGo.xcarchive archive and upload the build to TestFlight.")

        let didFailHonestly = try await waitUntil(timeoutNanoseconds: 30_000_000_000) {
            model.transcript.contains(where: { message in
                message.role == .system
                    && message.text.contains("Host not ready for signing-sensitive work: Loopback not upgraded to the GUI-session websocket lane.")
            })
        }
        XCTAssertTrue(
            didFailHonestly,
            "Signing-sensitive turn never failed closed on the SSH safe lane. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
        XCTAssertEqual(model.activeProtocolKind, .stdio)
        XCTAssertNil(model.activeTurnID)
        XCTAssertEqual(
            model.activeSession?.lastErrorSummary,
            "Host not ready for signing-sensitive work: Loopback not upgraded to the GUI-session websocket lane."
        )
    }

    func testSelectingFastModeUsesFastestSupportedReasoningEffort() {
        let model = AppModel()

        model.availableModels = [
            CodexModelDescriptor(
                id: "model",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                description: "Fast mode test model",
                isDefault: true,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [
                    .init(effort: .low, description: "Low"),
                    .init(effort: .medium, description: "Medium"),
                    .init(effort: .high, description: "High")
                ]
            )
        ]
        model.selectedModel = "gpt-5.4"

        model.selectFastMode()

        XCTAssertTrue(model.isFastModeSelected)
        XCTAssertEqual(model.selectedCollaborationMode, nil)
        XCTAssertEqual(model.selectedReasoningEffort, .low)
        XCTAssertEqual(model.runModeLabel, "Fast")
    }

    func testSelectingClientOrchestratedParallelAgentsAddsDeveloperInstructions() {
        let model = AppModel()

        model.selectParallelAgentMode(.clientOrchestrated)

        XCTAssertEqual(model.selectedParallelAgentMode, .clientOrchestrated)
        XCTAssertEqual(model.threadFeatureState.parallelAgentMode, .clientOrchestrated)
        XCTAssertEqual(model.threadFeatureState.parallelAgentCapability, .clientOrchestratedOnly)
        XCTAssertEqual(model.parallelAgentCapabilityLabel, "Client-orchestrated only")
        XCTAssertNotNil(model.parallelAgentDeveloperInstructions)

        let payload = model.collaborationModePayload(modelOverride: "gpt-5.4")
        XCTAssertEqual(payload?.mode, .default)
        XCTAssertEqual(payload?.developerInstructions, model.parallelAgentDeveloperInstructions)
    }

    func testProtocolNativeParallelAgentsRemainUnavailable() {
        let model = AppModel()

        XCTAssertFalse(model.canSelectProtocolNativeParallelAgents)
        model.selectParallelAgentMode(.protocolNative)

        XCTAssertEqual(model.selectedParallelAgentMode, .clientOrchestrated)
        XCTAssertEqual(model.threadFeatureState.parallelAgentCapability, .clientOrchestratedOnly)
        XCTAssertEqual(model.parallelAgentCapabilityLabel, "Client-orchestrated only")
        XCTAssertTrue(model.transcript.contains(where: {
            $0.role == .system && $0.text.contains("Protocol-native subagents are not available")
        }))
    }

    func testUITestResetClearsSyncMirrorState() {
        let metadataPath = "/tmp/cotg-ui-reset-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-reset-\(UUID().uuidString)-sync.json"
        FileManager.default.createFile(atPath: metadataPath, contents: Data("stale".utf8))
        FileManager.default.createFile(atPath: syncPath, contents: Data("stale".utf8))
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(sceneID: "ui-reset")
        model.resetPersistedStateForUITests(seedLocalhostManualRoute: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncPath))
    }

    func testUITestSeedCanPreferExternalTailnetRoute() {
        let metadataPath = "/tmp/cotg-ui-pref-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-pref-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_SSH_HOST", "192.168.50.164", 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_PORT", "22", 1)
        setenv("COTG_TEST_EXTERNAL_TAILNET_DNS_NAME", "example-mac.example.ts.net", 1)
        setenv("COTG_TEST_SSH_HOST_KEY", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx", 1)
        setenv("COTG_TEST_PREFERRED_ROUTE_KIND", "externalTailnet", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_PORT")
            unsetenv("COTG_TEST_EXTERNAL_TAILNET_DNS_NAME")
            unsetenv("COTG_TEST_SSH_HOST_KEY")
            unsetenv("COTG_TEST_PREFERRED_ROUTE_KIND")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(sceneID: "ui-pref")
        model.resetPersistedStateForUITests(seedLocalhostManualRoute: true)

        XCTAssertEqual(model.selectedMachine?.routes.count, 2)
        XCTAssertEqual(model.selectedMachine?.preferredRoute?.kind, .externalTailnet)
        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .externalTailnet)
    }

    func testUITestSeedCanBootstrapBonjourLocalLANRoute() {
        let metadataPath = "/tmp/cotg-ui-lan-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-lan-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_SSH_HOST", "192.168.50.164", 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_PORT", "22", 1)
        setenv("COTG_TEST_SSH_HOST_KEY", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_PORT")
            unsetenv("COTG_TEST_SSH_HOST_KEY")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(sceneID: "ui-lan")
        model.resetPersistedStateForUITests(seedLocalhostLANRoute: true)

        XCTAssertEqual(model.selectedMachine?.routes.count, 1)
        XCTAssertEqual(model.selectedMachine?.preferredRoute?.kind, .localLAN)
        XCTAssertEqual(model.selectedMachine?.preferredRoute?.discoverySource, .bonjour)
        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .localLAN)
    }

    func testUITestAppStoreSessionFixtureSeedsCurrentMarketingState() {
        let model = AppModel(sceneID: "ui-app-store")
        model.resetPersistedStateForUITests(seedAppStoreSessionFixture: true)

        XCTAssertEqual(model.selectedMachine?.alias, "example-mac")
        XCTAssertEqual(model.activeSession?.threadID, "thread-preview-1")
        XCTAssertEqual(model.connectionState, .connected("SSH safe lane"))
        XCTAssertEqual(model.selectedModel, "gpt-5.4")
        XCTAssertTrue(model.availableModels.contains(where: { $0.model == "gpt-5.5" }))
        XCTAssertEqual(model.transcript.map(\.kind), [.standard, .standard, .commentary, .toolCall, .fileChange, .standard])
        XCTAssertEqual(model.workspaceSummary?.branch, "main")
        XCTAssertEqual(model.workspaceSummary?.changes.count, 3)
        XCTAssertEqual(model.composerState.attachments.first?.displayName, "iphone-browser.png")
        XCTAssertTrue(model.composerState.canSend)
        XCTAssertTrue(model.hostThreadCatalog.contains(where: { $0.id == "thread-preview-1" }))
    }

    func testUITestPlanMessageSeedAppendsPlanAndSelectsPlanMode() {
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_UI_TEST_SEED_PLAN_MESSAGE", "1", 1)
        setenv(
            "COTG_UI_TEST_PLAN_MESSAGE",
            "1. Group recent activity into a compact cluster.\n2. Render plan summaries as dedicated plan cards.",
            1
        )
        defer {
            unsetenv("UI_TESTING")
            unsetenv("COTG_UI_TEST_SEED_PLAN_MESSAGE")
            unsetenv("COTG_UI_TEST_PLAN_MESSAGE")
        }

        let model = AppModel(sceneID: "ui-app-store-plan")
        model.resetPersistedStateForUITests(seedAppStoreSessionFixture: true)

        XCTAssertEqual(model.selectedCollaborationMode, .plan)
        XCTAssertEqual(model.transcript.last?.kind, .plan)
        XCTAssertEqual(
            model.transcript.last?.text,
            "1. Group recent activity into a compact cluster.\n2. Render plan summaries as dedicated plan cards."
        )
    }

    func testUITestStructuredPromptSeedAppendsPromptAndSelectsPlanMode() {
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_UI_TEST_SEED_STRUCTURED_PROMPT", "1", 1)
        setenv("COTG_UI_TEST_STRUCTURED_PROMPT_QUESTION", "Which implementation path should we take next?", 1)
        setenv(
            "COTG_UI_TEST_STRUCTURED_PROMPT_OPTIONS",
            "Structured plan questions||History catch-up improvements||Browser thread actions",
            1
        )
        defer {
            unsetenv("UI_TESTING")
            unsetenv("COTG_UI_TEST_SEED_STRUCTURED_PROMPT")
            unsetenv("COTG_UI_TEST_STRUCTURED_PROMPT_QUESTION")
            unsetenv("COTG_UI_TEST_STRUCTURED_PROMPT_OPTIONS")
        }

        let model = AppModel(sceneID: "ui-app-store-structured-prompt")
        model.resetPersistedStateForUITests(seedAppStoreSessionFixture: true)

        XCTAssertEqual(model.selectedCollaborationMode, .plan)
        XCTAssertEqual(model.transcript.last?.kind, .userInputPrompt)
        XCTAssertEqual(model.transcript.last?.structuredPrompt?.requestID, "ui-test-structured-prompt")
        XCTAssertEqual(model.transcript.last?.structuredPrompt?.questions.count, 1)
        XCTAssertEqual(
            model.transcript.last?.structuredPrompt?.questions.first?.options.map(\.label),
            [
                "Structured plan questions",
                "History catch-up improvements",
                "Browser thread actions"
            ]
        )
    }

    func testUseStructuredPromptAnswersPreparesComposerDraftAndLeavesPlanMode() {
        let model = AppModel(sceneID: "structured-prompt-answer")
        model.selectedCollaborationMode = .plan
        model.composerState.draft = "Existing draft"

        let prompt = SessionStructuredPrompt(
            requestID: "structured-prompt",
            questions: [
                SessionStructuredQuestion(
                    id: "next-step",
                    prompt: "Which implementation path should we take next?",
                    options: [
                        SessionStructuredOption(label: "Structured plan questions"),
                        SessionStructuredOption(label: "History catch-up improvements")
                    ],
                    allowsCustomAnswer: true
                )
            ]
        )

        model.useStructuredPromptAnswers(
            prompt,
            selectedOptionsByQuestionID: ["next-step": ["Structured plan questions"]],
            typedAnswersByQuestionID: ["next-step": "Add native answer submission."]
        )

        XCTAssertEqual(
            model.composerState.draft,
            """
            Existing draft

            Which implementation path should we take next?
            Structured plan questions
            Add native answer submission.
            """
        )
        XCTAssertEqual(model.selectedCollaborationMode, .default)
    }

    func testUITestSeedPrefersSharedHostFileOverStaleSSHHostEnvironment() throws {
        let metadataPath = "/tmp/cotg-ui-host-file-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-host-file-\(UUID().uuidString)-sync.json"
        let hostFilePath = "/tmp/cotg-ui-host-file-\(UUID().uuidString).txt"
        try "192.168.31.53".write(toFile: hostFilePath, atomically: true, encoding: .utf8)

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_SSH_HOST", "192.168.50.164", 1)
        setenv("COTG_TEST_SSH_HOST_FILE", hostFilePath, 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_PORT", "22", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_HOST_FILE")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_PORT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: hostFilePath)
        }

        let model = AppModel(sceneID: "ui-host-file")
        model.resetPersistedStateForUITests(seedLocalhostManualRoute: true)

        XCTAssertEqual(model.selectedMachine?.preferredRoute?.hostname, "192.168.31.53")
        XCTAssertEqual(model.selectedBootstrapRoute?.hostname, "192.168.31.53")
    }

    func testUITestSeedPrefersResolvedSSHHostEnvironmentOverStaleRawHost() {
        let metadataPath = "/tmp/cotg-ui-resolved-host-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-resolved-host-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_SSH_HOST", "192.168.50.164", 1)
        setenv("COTG_TEST_SSH_HOST_RESOLVED", "192.168.31.53", 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_PORT", "22", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_HOST_RESOLVED")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_PORT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(sceneID: "ui-resolved-host")
        model.resetPersistedStateForUITests(seedLocalhostManualRoute: true)

        XCTAssertEqual(model.selectedMachine?.preferredRoute?.hostname, "192.168.31.53")
        XCTAssertEqual(model.selectedBootstrapRoute?.hostname, "192.168.31.53")
    }

    func testUITestResolvedSSHHostAutoloadsInlineKeyForSeededManualRoute() {
        let metadataPath = "/tmp/cotg-ui-resolved-auth-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-resolved-auth-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_TEST_SSH_HOST", "192.168.50.164", 1)
        setenv("COTG_TEST_SSH_HOST_RESOLVED", "192.168.31.53", 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_PORT", "22", 1)
        setenv("COTG_TEST_SSH_HOST_KEY", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx", 1)
        setenv("COTG_TEST_SSH_RAW_KEY_BASE64", "ByaloKNmhnQY5TSSbGFZoPwByFeM+cwqmV3AFJw5L14=", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("UI_TESTING")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_HOST_RESOLVED")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_PORT")
            unsetenv("COTG_TEST_SSH_HOST_KEY")
            unsetenv("COTG_TEST_SSH_RAW_KEY_BASE64")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(sceneID: "ui-resolved-auth", startRuntimeServices: false)
        model.resetPersistedStateForUITests(seedLocalhostManualRoute: true)

        XCTAssertEqual(model.selectedBootstrapRoute?.hostname, "192.168.31.53")
        XCTAssertTrue(model.connectionSetupSSHAccessReady)
        XCTAssertEqual(model.sshCredentialStatusLabel, "Localhost test key available")
        XCTAssertEqual(model.capabilityReport.check(.sshAuthentication)?.state, .ready)
    }

    func testExternalTailnetFixtureAutoloadsInlineUITestSSHKey() {
        let metadataPath = "/tmp/cotg-ui-external-auth-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-external-auth-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_TEST_SSH_HOST", "192.168.50.164", 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_PORT", "22", 1)
        setenv("COTG_TEST_EXTERNAL_TAILNET_DNS_NAME", "example-mac.example.ts.net", 1)
        setenv("COTG_TEST_SSH_HOST_KEY", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx", 1)
        setenv("COTG_TEST_SSH_RAW_KEY_BASE64", "ByaloKNmhnQY5TSSbGFZoPwByFeM+cwqmV3AFJw5L14=", 1)
        setenv("COTG_TEST_PREFERRED_ROUTE_KIND", "externalTailnet", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("UI_TESTING")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_PORT")
            unsetenv("COTG_TEST_EXTERNAL_TAILNET_DNS_NAME")
            unsetenv("COTG_TEST_SSH_HOST_KEY")
            unsetenv("COTG_TEST_SSH_RAW_KEY_BASE64")
            unsetenv("COTG_TEST_PREFERRED_ROUTE_KIND")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(
            sceneID: "ui-external-auth",
            externalTailnetAppDetector: StubExternalTailnetAppDetector(installed: false),
            startRuntimeServices: false
        )
        model.resetPersistedStateForUITests(seedLocalhostManualRoute: true)

        let authCheck = model.capabilityReport.check(.sshAuthentication)

        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .externalTailnet)
        XCTAssertEqual(model.sshCredentialStatusLabel, "Localhost test key available")
        XCTAssertEqual(authCheck?.state, .ready)
        XCTAssertEqual(
            authCheck.map(HostCapabilityCheckFormatter.summary(for:)),
            "The client has a usable SSH credential."
        )
    }

    func testEmbeddedTailnetFixtureSeedsPendingScannedHostKeyForUITests() {
        let metadataPath = "/tmp/cotg-ui-embedded-trust-\(UUID().uuidString)-metadata.json"
        let syncPath = "/tmp/cotg-ui-embedded-trust-\(UUID().uuidString)-sync.json"
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_UI_TEST_SEED_PENDING_SCANNED_HOST_KEY", "1", 1)
        setenv("COTG_TEST_SSH_USER", "developer", 1)
        setenv("COTG_TEST_SSH_RAW_KEY_BASE64", "ByaloKNmhnQY5TSSbGFZoPwByFeM+cwqmV3AFJw5L14=", 1)
        setenv("COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST", "example-mac.example.ts.net", 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("UI_TESTING")
            unsetenv("COTG_UI_TEST_SEED_PENDING_SCANNED_HOST_KEY")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_RAW_KEY_BASE64")
            unsetenv("COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
        }

        let model = AppModel(
            sceneID: "ui-embedded-trust",
            startRuntimeServices: false
        )
        model.resetPersistedStateForUITests(seedEmbeddedTailnetRoute: true)

        XCTAssertEqual(model.selectedBootstrapRoute?.kind, .embeddedTailnet)
        XCTAssertTrue(model.connectionSetupSSHAccessReady)
        XCTAssertTrue(model.canTrustScannedHostKey)
        XCTAssertEqual(model.sshTrustStatusLabel, "Review scanned key")
    }

    func testExternalTailnetStatusReportsMissingApp() async throws {
        let machineID = UUID()
        let fallbackRoute = RouteRecord(
            machineID: machineID,
            kind: .manualSSH,
            label: "Manual SSH",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted
        )
        let externalRoute = RouteRecord(
            machineID: machineID,
            kind: .externalTailnet,
            label: "External Tailnet",
            hostname: "example-mac.example.ts.net",
            magicDNSName: "example-mac.example.ts.net",
            usernameHint: "developer",
            requiresExternalApp: true,
            health: .healthy,
            trustState: .trusted
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            routes: [fallbackRoute, externalRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )

        let model = AppModel(
            machines: [machine],
            externalTailnetAppDetector: StubExternalTailnetAppDetector(installed: false)
        )

        model.select(machineID: machine.id)
        let detectorResolved = try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.externalTailnetAppInstalled != nil
        }

        XCTAssertTrue(detectorResolved)
        XCTAssertTrue(model.showsExternalTailnetStatus)
        XCTAssertEqual(model.externalTailnetAppState, .notInstalled)
        XCTAssertEqual(model.externalTailnetAppStatusLabel, "Not installed")
        XCTAssertNotEqual(model.recommendedRoute?.kind, .externalTailnet)
        XCTAssertFalse(
            model.routeEvaluations.contains(where: {
                $0.route.kind == .externalTailnet && $0.isEligible
            })
        )
    }

    func testResolvedSSHBootstrapEndpointUsesEmbeddedDialPlanPreferredHost() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded",
            magicDNSName: "host.tailnet.ts.net",
            tailnetProfileID: MachineDirectorySeed.primaryTailnetID,
            health: .healthy,
            trustState: .trusted
        )
        let endpoint = SSHBootstrapEndpointResolver.resolve(
            route: route,
            dialPlan: EmbeddedTailnetDialPlan(
                profileID: MachineDirectorySeed.primaryTailnetID,
                routeKind: .embeddedTailnet,
                preferredHost: "100.64.0.8",
                magicDNSName: "host.tailnet.ts.net",
                requiresExternalApp: false,
                socksProxyHost: "127.0.0.1",
                socksProxyPort: 2222,
                socksProxyUsername: "tailnet",
                socksProxyPassword: "secret",
                supportsNativeSSHTransport: true
            ),
            environment: [:]
        )

        XCTAssertEqual(endpoint?.host, "100.64.0.8")
        XCTAssertEqual(endpoint?.port, 22)
    }

    func testResolvedSSHBootstrapEndpointKeepsExternalTailnetHostWhenManualHostOverrideExists() {
        let route = RouteRecord(
            machineID: UUID(),
            kind: .externalTailnet,
            label: "External",
            magicDNSName: "example-mac.example.ts.net",
            requiresExternalApp: true,
            health: .healthy,
            trustState: .trusted
        )

        let endpoint = SSHBootstrapEndpointResolver.resolve(
            route: route,
            dialPlan: nil,
            environment: [
                "COTG_TEST_SSH_HOST": "192.168.50.164",
                "COTG_TEST_SSH_PORT": "22"
            ]
        )

        XCTAssertEqual(endpoint?.host, "example-mac.example.ts.net")
        XCTAssertEqual(endpoint?.port, 22)
    }

    func testResolvedSSHProxyConfigurationUsesEmbeddedDialPlanSOCKSProxy() {
        let route = RouteRecord(
            machineID: UUID(),
            kind: .embeddedTailnet,
            label: "Embedded",
            magicDNSName: "host.tailnet.ts.net",
            tailnetProfileID: MachineDirectorySeed.primaryTailnetID,
            health: .healthy,
            trustState: .trusted
        )

        let proxy = SSHProxyConfigurationResolver.resolve(
            route: route,
            dialPlan: EmbeddedTailnetDialPlan(
                profileID: MachineDirectorySeed.primaryTailnetID,
                routeKind: .embeddedTailnet,
                preferredHost: "100.64.0.8",
                magicDNSName: "host.tailnet.ts.net",
                requiresExternalApp: false,
                socksProxyHost: "127.0.0.1",
                socksProxyPort: 2222,
                socksProxyUsername: "tailnet",
                socksProxyPassword: "secret",
                supportsNativeSSHTransport: true
            )
        )

        XCTAssertEqual(proxy?.host, "127.0.0.1")
        XCTAssertEqual(proxy?.port, 2222)
        XCTAssertEqual(proxy?.username, "tailnet")
        XCTAssertEqual(proxy?.password, "secret")
    }

    func testResolvedSSHBootstrapEndpointRejectsUnwiredEmbeddedRoute() {
        let machineID = UUID()
        let route = RouteRecord(
            machineID: machineID,
            kind: .embeddedTailnet,
            label: "Embedded",
            magicDNSName: "host.tailnet.ts.net",
            tailnetProfileID: MachineDirectorySeed.primaryTailnetID,
            health: .unavailable,
            trustState: .unknown
        )
        let endpoint = SSHBootstrapEndpointResolver.resolve(
            route: route,
            dialPlan: EmbeddedTailnetDialPlan(
                profileID: MachineDirectorySeed.primaryTailnetID,
                routeKind: .embeddedTailnet,
                preferredHost: "100.64.0.8",
                magicDNSName: "host.tailnet.ts.net",
                requiresExternalApp: false,
                supportsNativeSSHTransport: false
            ),
            environment: [:]
        )

        XCTAssertNil(endpoint)
    }

    func testQueuedFollowUpPromptWaitsBehindActiveTurn() {
        let model = AppModel(sceneID: "queue-test", bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)
        if let existingIndex = model.recentSessions.firstIndex(where: { $0.machineID == MachineRecord.preview.id }) {
            model.recentSessions[existingIndex].sceneID = "queue-test"
            model.recentSessions[existingIndex].threadID = "thread-queue"
        } else {
            model.recentSessions.append(
                SessionRecord(
                    sceneID: "queue-test",
                    machineID: MachineRecord.preview.id,
                    routeID: model.selectedMachine?.preferredRoute?.id,
                    threadID: "thread-queue",
                    workspaceRoot: "/tmp/cotg-queue",
                    lastKnownProtocol: .stdio,
                    lastKnownRouteKind: model.selectedMachine?.preferredRoute?.kind,
                    lastKnownBootstrap: .standardSSH,
                    transportState: .connected,
                    lastOpenedAt: .now
                )
            )
        }
        let sessionIndex = model.recentSessions.firstIndex(where: { $0.machineID == MachineRecord.preview.id && $0.sceneID == "queue-test" })!
        model.recentSessions[sessionIndex].threadID = "thread-queue"
        model.connectionState = .connected("stdio://localhost")
        model.activeTurnID = "turn-active"
        model.composerState.draft = "Follow up after the active turn."

        model.sendComposerDraft()

        XCTAssertEqual(model.pendingPrompts, ["Follow up after the active turn."])
        XCTAssertEqual(model.threadFeatureState.queuedPromptCount, 1)
        XCTAssertEqual(
            model.transcript.last(where: { $0.role == .user })?.deliveryState,
            .queued
        )
        XCTAssertTrue(model.transcript.contains(where: { $0.text == "Queued behind the active live turn." }))
    }

    func testConnectedSendFailureMarksUserMessageAsNotSent() async throws {
        let model = AppModel(sceneID: "send-failure", bootstrapSnapshot: .preview)
        model.select(machineID: MachineRecord.preview.id)
        let sessionID = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: Self.workspaceRoot,
            reconnect: false
        )
        model.connectionState = .connected("Connected to the SSH safe lane over stdio.")

        model.sendPrompt("Check whether the host really accepted this turn.")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.activeSession?.id, sessionID)
        XCTAssertEqual(
            model.transcript.last(where: { $0.role == .user })?.text,
            "Check whether the host really accepted this turn."
        )
        XCTAssertEqual(
            model.transcript.last(where: { $0.role == .user })?.deliveryState,
            .failed
        )
        XCTAssertTrue(
            model.transcript.contains(where: {
                $0.role == .system && $0.text.contains("Failed to start turn:")
            })
        )
    }

    func testPaginateThreadListCollectsAllPagesInOrder() async throws {
        let pages = [
            CodexThreadListPage(
                threads: [
                    makeThreadSummary(id: "thread-1", updatedAt: 1),
                    makeThreadSummary(id: "thread-2", updatedAt: 2)
                ],
                nextCursor: "cursor-2"
            ),
            CodexThreadListPage(
                threads: [
                    makeThreadSummary(id: "thread-3", updatedAt: 3)
                ],
                nextCursor: nil
            )
        ]
        var requestedCursors: [String?] = []
        var publishedPageCounts: [Int] = []
        var pageIndex = 0

        let threads = try await AppModel.paginateThreadList(
            fetchPage: { cursor in
                requestedCursors.append(cursor)
                defer { pageIndex += 1 }
                return pages[pageIndex]
            },
            onPage: { threads in
                publishedPageCounts.append(threads.count)
            }
        )

        XCTAssertEqual(requestedCursors, [nil, "cursor-2"])
        XCTAssertEqual(publishedPageCounts, [2, 3])
        XCTAssertEqual(threads.map(\.id), ["thread-1", "thread-2", "thread-3"])
    }

    func testPaginateThreadListRejectsRepeatedCursor() async throws {
        do {
            _ = try await AppModel.paginateThreadList { cursor in
                CodexThreadListPage(
                    threads: [self.makeThreadSummary(id: "thread-repeat", updatedAt: 1)],
                    nextCursor: cursor == nil ? "cursor-repeat" : "cursor-repeat"
                )
            }
            XCTFail("Expected repeated pagination cursor to fail.")
        } catch let error as CodexSSHError {
            guard case let .invalidResponse(message) = error else {
                XCTFail("Expected invalidResponse, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("repeated cursor"))
        }
    }

    func testRepairingMissingWorkspaceRootsKeepsCanonicalLiveThreadSet() {
        let livePage = CodexThreadListPage(
            threads: [
                CodexThreadSummary(
                    id: "thread-live-missing-cwd",
                    cwd: "",
                    preview: "Live thread",
                    modelProvider: "openai",
                    name: "Live",
                    createdAt: Date(timeIntervalSince1970: 10),
                    updatedAt: Date(timeIntervalSince1970: 20),
                    status: .idle
                ),
                makeThreadSummary(id: "thread-live-valid", updatedAt: 30)
            ],
            nextCursor: "cursor-2"
        )

        let repaired = AppModel.repairingMissingWorkspaceRoots(
            in: livePage,
            using: [
                "thread-live-missing-cwd": "/workspace/reference-app",
                "thread-state-only": "/workspace/coding-on-the-go"
            ]
        )

        XCTAssertEqual(repaired.threads.map(\.id), ["thread-live-missing-cwd", "thread-live-valid"])
        XCTAssertEqual(repaired.threads[0].cwd, "/workspace/reference-app")
        XCTAssertEqual(repaired.threads[1].cwd, "/workspace/coding-on-the-go")
        XCTAssertEqual(repaired.nextCursor, "cursor-2")
    }

    func testRepairingMissingWorkspaceRootsDoesNotOverwriteCanonicalWorkspace() {
        let livePage = CodexThreadListPage(
            threads: [
                makeThreadSummary(id: "thread-live-valid", updatedAt: 30)
            ],
            nextCursor: nil
        )

        let repaired = AppModel.repairingMissingWorkspaceRoots(
            in: livePage,
            using: [
                "thread-live-valid": "/workspace/reference-app"
            ]
        )

        XCTAssertEqual(repaired.threads.map(\.id), ["thread-live-valid"])
        XCTAssertEqual(repaired.threads[0].cwd, "/workspace/coding-on-the-go")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 250_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return condition()
    }

    private func withLocalhostIntegrationEnvironment(
        workspaceRoot: String,
        label: String,
        body: @escaping () async throws -> Void
    ) async throws {
        let rawKeyPath = try requireLocalhostIntegration()
        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-\(label)-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-\(label)-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-\(label)-\(testRunID)-codex-home/.codex"

        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_TEST_SSH_RAW_KEY_PATH", rawKeyPath, 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", Self.localhostSSHUser, 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("UI_TESTING", "1", 1)
        setenv("COTG_WORKSPACE_ROOT", workspaceRoot, 1)
        defer {
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_TEST_SSH_RAW_KEY_PATH")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("UI_TESTING")
            unsetenv("COTG_WORKSPACE_ROOT")
            try? FileManager.default.removeItem(atPath: metadataPath)
            try? FileManager.default.removeItem(atPath: syncPath)
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: codexHomePath).deletingLastPathComponent().path)
        }

        try await body()
    }

    private func prepareConnectedLocalhostThread(
        model: AppModel,
        workspaceRoot: String,
        markerPrefix: String
    ) async throws -> String {
        model.select(machineID: MachineRecord.preview.id)
        let localhostRouteID = try XCTUnwrap(
            model.selectedMachine?.routes.first(where: { route in
                route.kind == .manualSSH
                    && route.hostname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "localhost"
            })?.id
        )
        _ = model.prepareNewSession(
            machineID: MachineRecord.preview.id,
            workspaceRoot: workspaceRoot,
            routeID: localhostRouteID,
            reconnect: false
        )
        model.connectLocalLoopback()

        let didReconnectPreparedSession = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
                    && model.activeSession?.workspaceRoot == workspaceRoot
                    && model.activeSession?.routeID == localhostRouteID
            }
            return false
        }
        XCTAssertTrue(
            didReconnectPreparedSession,
            "Prepared localhost session never reconnected on the safe lane. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        let marker = "\(markerPrefix)_\(UUID().uuidString)"
        model.sendPrompt("Reply with \(marker) only.")

        let didSeedThread = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            model.activeSession?.threadID != nil
                && model.activeSession?.workspaceRoot == workspaceRoot
                && model.transcript.contains(where: { message in
                    message.role == .assistant
                        && !message.isStreaming
                        && message.text.contains(marker)
                })
        }
        XCTAssertTrue(
            didSeedThread,
            "Preparing the localhost thread for worktree flow never completed. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )
        return try XCTUnwrap(model.activeSession?.threadID)
    }

    private func prepareConnectedLocalhostSessionWithoutTurns(
        model: AppModel,
        workspaceRoot: String
    ) async throws -> SessionRecord.ID {
        model.select(machineID: MachineRecord.preview.id)
        let localhostRouteID = try XCTUnwrap(
            model.selectedMachine?.routes.first(where: { route in
                route.kind == .manualSSH
                    && route.hostname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "localhost"
            })?.id
        )
        let sessionID = try XCTUnwrap(
            model.prepareNewSession(
                machineID: MachineRecord.preview.id,
                workspaceRoot: workspaceRoot,
                routeID: localhostRouteID,
                reconnect: false
            )
        )
        model.connectLocalLoopback()

        let didReconnectPreparedSession = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
                    && model.activeSession?.id == sessionID
                    && model.activeSession?.workspaceRoot == workspaceRoot
                    && model.activeSession?.routeID == localhostRouteID
                    && model.activeSession?.threadID != nil
            }
            return false
        }
        XCTAssertTrue(
            didReconnectPreparedSession,
            "Prepared localhost session without turns never connected on the safe lane. Transcript: \(model.transcript.map { $0.text }.joined(separator: " | "))"
        )

        return sessionID
    }

    private func requireLocalhostIntegration() throws -> String {
        guard ProcessInfo.processInfo.environment["COTG_ENABLE_LOCALHOST_INTEGRATION"] == "1" else {
            throw XCTSkip("Set COTG_ENABLE_LOCALHOST_INTEGRATION=1 to run localhost SSH integration tests.")
        }

        guard FileManager.default.fileExists(atPath: Self.localhostRawKeyPath) else {
            throw XCTSkip("Localhost SSH test key is unavailable at \(Self.localhostRawKeyPath).")
        }

        return Self.localhostRawKeyPath
    }

    private func makeTemporaryGitFixtureRepo(prefix: String) throws -> String {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try runShell(["git", "init", "-b", "main", rootURL.path])
        try runShell(["git", "-C", rootURL.path, "config", "user.name", "Coding On The Go Tests"])
        try runShell(["git", "-C", rootURL.path, "config", "user.email", "tests@codingonthego.local"])
        try runShell(["git", "-C", rootURL.path, "config", "commit.gpgsign", "false"])
        try "# Worktree flow fixture\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runShell(["git", "-C", rootURL.path, "add", "README.md"])
        try runShell(["git", "-C", rootURL.path, "-c", "commit.gpgsign=false", "commit", "-m", "Initial fixture commit"])
        return rootURL.resolvingSymlinksInPath().path
    }

    private func runShell(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "AppStateTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "Command failed: \(arguments.joined(separator: " "))\n\(output)"
                ]
            )
        }
    }

    private func makeThreadSummary(id: String, updatedAt: TimeInterval) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            cwd: "/workspace/coding-on-the-go",
            preview: "Preview \(id)",
            modelProvider: "openai",
            name: "Thread \(id)",
            createdAt: Date(timeIntervalSince1970: updatedAt - 60),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle
        )
    }

    private nonisolated func saveAndClearTestEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        let keysToReset = Set(
            environment.keys.filter { key in
                guard key == "UI_TESTING" || key.hasPrefix("COTG_") else {
                    return false
                }
                return !key.hasPrefix("COTG_ENABLE_")
            }
        )

        savedEnvironment = keysToReset.reduce(into: [:]) { partialResult, key in
            partialResult[key] = environment[key]
            unsetenv(key)
        }

        savedDemoModeValue = UserDefaults.standard.object(forKey: AppDemoScenario.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        clearIsolatedUITestStoreDirectory()
    }

    private nonisolated func restoreTestEnvironment() {
        for (key, value) in savedEnvironment {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        savedEnvironment.removeAll()

        if let savedDemoModeValue {
            UserDefaults.standard.set(savedDemoModeValue, forKey: AppDemoScenario.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
        }
        savedDemoModeValue = nil
        clearIsolatedUITestStoreDirectory()
    }

    private nonisolated func clearIsolatedUITestStoreDirectory() {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let url = applicationSupport
            .appendingPathComponent("CodingOnTheGo", isDirectory: true)
            .appendingPathComponent("UITesting", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private func makeLocalNetworkTestMachine() -> MachineRecord {
        let machineID = UUID()
        let routeID = UUID()
        return MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            preferredRouteID: routeID,
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Manual SSH",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    discoverySource: .manual,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaFakeLocalNetwork developer@example-mac"
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
    }
}

private struct StubLANDiscoverer: LANRouteDiscovering {
    let samples: [DiscoveryRouteSample]

    func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample] {
        _ = knownMachines
        _ = timeout
        return samples
    }
}

private struct DelayedStubLANDiscoverer: LANRouteDiscovering {
    let delay: Duration
    let samples: [DiscoveryRouteSample]

    func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample] {
        _ = knownMachines
        _ = timeout
        try? await Task.sleep(for: delay)
        return samples
    }
}

private actor SequencedStubLANDiscoverer: LANRouteDiscovering {
    private let responses: [[DiscoveryRouteSample]]
    private var scanCount = 0

    init(responses: [[DiscoveryRouteSample]]) {
        self.responses = responses
    }

    func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample] {
        _ = knownMachines
        _ = timeout
        let index = scanCount
        scanCount += 1
        guard responses.indices.contains(index) else {
            return responses.last ?? []
        }
        return responses[index]
    }

    func recordedScanCount() -> Int {
        scanCount
    }
}

private struct StubExternalTailnetAppDetector: ExternalTailnetAppDetecting {
    let installed: Bool?

    func isInstalled() async -> Bool? {
        installed
    }
}
