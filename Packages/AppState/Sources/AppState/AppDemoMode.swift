import CodexRPC
import FeatureComposer
import Foundation
import GitWorkspace
import Persistence
import SharedModels
import SyncEngine

struct AppDemoThreadState: Sendable {
    var entry: HostThreadCatalogEntry
    var transcript: [SessionMessage]
    var workspaceSummary: GitWorkspaceSummary?
}

struct AppDemoScenario: Sendable {
    static let defaultsKey = "cotg.advanced.demoModeEnabled"
    static let launchEnvironmentKey = "COTG_ENABLE_DEMO_MODE_ON_LAUNCH"

    var snapshot: MachineDirectorySnapshot
    var threadStatesByID: [String: AppDemoThreadState]
    var availableModels: [CodexModelDescriptor]
    var syncSnapshot: SyncSnapshot
    var recommendedComposerDraft: String

    static func make(sceneID: String) -> AppDemoScenario {
        let machineID = UUID(uuidString: "A1111111-1111-1111-1111-111111111111")!
        let manualRouteID = UUID(uuidString: "A2222222-2222-2222-2222-222222222222")!
        let lanRouteID = UUID(uuidString: "A3333333-3333-3333-3333-333333333333")!
        let baseDate = Date(timeIntervalSince1970: 1_775_088_808)

        let demoMachine = MachineRecord(
            id: machineID,
            displayName: "Demo Mac",
            hostname: "review-demo.mac",
            stableHostFingerprint: "SHA256:cotg-review-demo-mode",
            lastKnownUser: "review",
            lastConnectedAt: baseDate,
            preferredRouteID: manualRouteID,
            lastSuccessfulRouteID: manualRouteID,
            capabilitySnapshotID: UUID(uuidString: "A4444444-4444-4444-4444-444444444444")!,
            credentialRef: CredentialRef(
                kind: .password,
                keychainAccount: "cotg.demo.review",
                label: "Reviewer demo login",
                username: "review",
                storageScope: .thisDeviceOnlyKeychain,
                lastValidatedAt: baseDate
            ),
            notes: "Reviewer-safe demo fixture with no live host dependency.",
            isPinned: true,
            sortRank: 0,
            routes: [
                RouteRecord(
                    id: manualRouteID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Reviewer SSH safe lane",
                    hostname: "review-demo.mac",
                    usernameHint: "review",
                    health: .healthy,
                    lastLatencyMs: 18,
                    lastCheckedAt: baseDate,
                    lastSuccessAt: baseDate,
                    isRecommended: true,
                    isUserPinned: true,
                    discoverySource: .manual,
                    trustState: .trusted,
                    trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoModeReviewKey reviewer-demo"
                ),
                RouteRecord(
                    id: lanRouteID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Same-LAN backup",
                    hostname: "review-demo.local",
                    ipAddress: "192.168.50.24",
                    usernameHint: "review",
                    health: .healthy,
                    lastLatencyMs: 6,
                    lastCheckedAt: baseDate.addingTimeInterval(-300),
                    lastSuccessAt: baseDate.addingTimeInterval(-300),
                    discoverySource: .bonjour,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                capturedAt: baseDate,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsAppServer: true,
                supportsWebsocketListen: true,
                supportsReview: true,
                supportsThreadFork: true,
                supportsApprovals: true,
                supportsCommandExec: true,
                supportsFSAPI: true,
                supportsImageInputs: true,
                supportsVoiceInput: true,
                supportsAttachments: true,
                gitVersion: "2.49.0",
                codexVersion: "0.118.0",
                codexAppInstalled: true,
                hostOSVersion: "macOS 15.5"
            )
        )

        let threads = makeThreadStates(machineID: machineID, baseDate: baseDate)
        let sessions = [
            SessionRecord(
                id: UUID(uuidString: "A5555555-5555-5555-5555-555555555551")!,
                sceneID: sceneID,
                machineID: machineID,
                routeID: manualRouteID,
                threadID: "demo-thread-reviewer-mode",
                workspaceRoot: "/workspace/coding-on-the-go",
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: .manualSSH,
                lastKnownBootstrap: .standardSSH,
                lastModel: "gpt-5.4",
                lastReasoningEffort: .medium,
                lastMode: .worktree,
                lastTurnID: "demo-turn-reviewer-mode-3",
                lastTurn: RecentTurnMetadata(
                    turnID: "demo-turn-reviewer-mode-3",
                    summary: "Demo mode now keeps reviewers inside a safe local fixture instead of requiring a reachable Mac.",
                    completedAt: baseDate
                ),
                lastOpenedAt: baseDate,
                resumeStrategy: .resumeThread,
                transportState: .connected
            ),
            SessionRecord(
                id: UUID(uuidString: "A5555555-5555-5555-5555-555555555552")!,
                sceneID: nil,
                machineID: machineID,
                routeID: lanRouteID,
                threadID: "demo-thread-testflight",
                workspaceRoot: "/workspace/release-ops",
                lastKnownProtocol: .stdio,
                lastKnownRouteKind: .localLAN,
                lastKnownBootstrap: .standardSSH,
                lastModel: "gpt-5.4",
                lastReasoningEffort: .medium,
                lastMode: .worktree,
                lastTurnID: "demo-turn-testflight-2",
                lastTurn: RecentTurnMetadata(
                    turnID: "demo-turn-testflight-2",
                    summary: "The current internal TestFlight build is ready, and the App Store version still needs the final release pass.",
                    completedAt: baseDate.addingTimeInterval(-1_200)
                ),
                lastOpenedAt: baseDate.addingTimeInterval(-1_200),
                resumeStrategy: .resumeThread,
                transportState: .connected
            )
        ]

        return AppDemoScenario(
            snapshot: MachineDirectorySnapshot(
                machines: [demoMachine],
                tailnetProfiles: [],
                recentSessions: sessions,
                hostThreadCatalog: threads.map(\.entry).sorted(by: { $0.updatedAt > $1.updatedAt }),
                preferences: UserPreferencesSnapshot(
                    preferredMachineID: machineID,
                    preferredTailnetProfileID: nil,
                    restoreLastSessionOnLaunch: true,
                    preferredBootstrap: .standardSSH,
                    preferredProtocol: .stdio
                )
            ),
            threadStatesByID: Dictionary(uniqueKeysWithValues: threads.map { ($0.entry.id, $0) }),
            availableModels: demoModels(),
            syncSnapshot: SyncSnapshot(
                status: .blocked,
                blocker: SyncBlocker(
                    reason: "Reviewer demo mode is using bundled local fixture data.",
                    remediation: "Turn off demo mode in Settings to return to your saved Macs and live Codex data."
                ),
                lastSyncedAt: baseDate,
                projectedRecordCount: 0,
                secretBoundaryNote: "Demo mode does not sync or require iCloud."
            ),
            recommendedComposerDraft: ""
        )
    }

    private static func makeThreadStates(machineID: MachineRecord.ID, baseDate: Date) -> [AppDemoThreadState] {
        [
            AppDemoThreadState(
                entry: HostThreadCatalogEntry(
                    id: "demo-thread-reviewer-mode",
                    machineID: machineID,
                    workspaceRoot: "/workspace/coding-on-the-go",
                    name: "Reviewer-safe demo mode",
                    preview: "Demo mode now keeps reviewers inside a safe local fixture instead of requiring a reachable Mac.",
                    modelProvider: "openai",
                    createdAt: baseDate.addingTimeInterval(-7_200),
                    updatedAt: baseDate
                ),
                transcript: [
                    SessionMessage(role: .system, text: "Reviewer demo mode loaded bundled local data for Demo Mac."),
                    SessionMessage(role: .user, text: "We need a reviewer-safe demo mode so TestFlight and App Review can try the app without a real Mac."),
                    SessionMessage(role: .assistant, text: "I added an advanced demo toggle that swaps the app into bundled Projects, Threads, transcript history, and workspace state. Reviewers can browse, reopen a real-looking thread, send from the main composer, and stay on the same thread without any SSH or tailnet dependency."),
                    SessionMessage(role: .assistant, text: "The same demo mode can drive the short review video, so the submission no longer depends on a dedicated cloud Mac or temporary SSH credential.")
                ],
                workspaceSummary: GitWorkspaceSummary(
                    branch: "main",
                    upstream: "origin/main",
                    aheadCount: 2,
                    changes: [
                        WorkspaceFileChange(path: "Packages/AppState/Sources/AppState/AppDemoMode.swift", staged: .added, unstaged: .unchanged),
                        WorkspaceFileChange(path: "apps/ios/CodingOnTheGo/Sources/App/SettingsRootView.swift", staged: .modified, unstaged: .unchanged),
                        WorkspaceFileChange(path: "marketing/app-store/review-notes.md", staged: .unchanged, unstaged: .modified)
                    ]
                )
            ),
            AppDemoThreadState(
                entry: HostThreadCatalogEntry(
                    id: "demo-thread-testflight",
                    machineID: machineID,
                    workspaceRoot: "/workspace/release-ops",
                    name: "Release checklist",
                    preview: "The latest internal 0.9.1 build is ready, and the App Store version still needs the final release-ops pass.",
                    modelProvider: "openai",
                    createdAt: baseDate.addingTimeInterval(-14_400),
                    updatedAt: baseDate.addingTimeInterval(-1_200)
                ),
                transcript: [
                    SessionMessage(role: .system, text: "Reviewer demo mode loaded bundled local data for Demo Mac."),
                    SessionMessage(role: .user, text: "Summarize what is still missing before we attach the intended 0.9.1 build to the App Store version."),
                    SessionMessage(role: .assistant, text: "Internal TestFlight is already covered. The remaining App Store step is selecting the intended 0.9.1 build on version 0.9.0, confirming the review notes, and filling What’s New.")
                ],
                workspaceSummary: GitWorkspaceSummary(
                    branch: "release/0.9",
                    upstream: "origin/release/0.9",
                    aheadCount: 0,
                    behindCount: 0,
                    changes: [
                        WorkspaceFileChange(path: "marketing/app-store/release-checklist.md", staged: .modified, unstaged: .unchanged),
                        WorkspaceFileChange(path: "marketing/app-store/review-environment.md", staged: .unchanged, unstaged: .modified)
                    ]
                )
            ),
            AppDemoThreadState(
                entry: HostThreadCatalogEntry(
                    id: "demo-thread-browser-polish",
                    machineID: machineID,
                    workspaceRoot: "/workspace/coding-on-the-go",
                    name: "Project and Thread browser polish",
                    preview: "Keep Project -> Thread browsing honest, searchable, and stable across relaunch.",
                    modelProvider: "openai",
                    createdAt: baseDate.addingTimeInterval(-21_600),
                    updatedAt: baseDate.addingTimeInterval(-2_400)
                ),
                transcript: [
                    SessionMessage(role: .system, text: "Reviewer demo mode loaded bundled local data for Demo Mac."),
                    SessionMessage(role: .user, text: "Make the browser feel more like the Mac Codex app without inventing fake rows."),
                    SessionMessage(role: .assistant, text: "The browser now treats canonical host-backed threads as the source of truth, groups them by project, and keeps the current Mac as the default browsing scope.")
                ],
                workspaceSummary: GitWorkspaceSummary(
                    branch: "ux/browser",
                    upstream: "origin/ux/browser",
                    aheadCount: 1,
                    changes: [
                        WorkspaceFileChange(path: "apps/ios/CodingOnTheGo/Sources/App/CodexSessionBrowserView.swift", staged: .modified, unstaged: .modified),
                        WorkspaceFileChange(path: "Packages/AppState/Tests/AppStateTests/AppStateTests.swift", staged: .unchanged, unstaged: .modified)
                    ]
                )
            )
        ]
    }

    private static func demoModels() -> [CodexModelDescriptor] {
        [
            CodexModelDescriptor(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                description: "Balanced default for reviewer demo mode",
                isDefault: true,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [
                    .init(effort: .low, description: "Fast"),
                    .init(effort: .medium, description: "Balanced"),
                    .init(effort: .high, description: "Deep")
                ]
            ),
            CodexModelDescriptor(
                id: "gpt-5.5",
                model: "gpt-5.5",
                displayName: "GPT-5.5",
                description: "Frontier model for complex coding, research, and real-world work",
                isDefault: false,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [
                    .init(effort: .low, description: "Fast"),
                    .init(effort: .medium, description: "Balanced"),
                    .init(effort: .high, description: "Deep"),
                    .init(effort: .xhigh, description: "Extra deep")
                ],
                supportsPersonality: true
            ),
            CodexModelDescriptor(
                id: "gpt-5.4-mini",
                model: "gpt-5.4-mini",
                displayName: "GPT-5.4 Mini",
                description: "Faster fallback for reviewer demo mode",
                isDefault: false,
                hidden: false,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: [
                    .init(effort: .low, description: "Fast"),
                    .init(effort: .medium, description: "Balanced"),
                    .init(effort: .high, description: "Deep")
                ]
            )
        ]
    }
}
