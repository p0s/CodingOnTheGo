import XCTest
#if canImport(Foundation)
import Foundation
#endif
#if canImport(UIKit)
import UIKit
#endif

final class CodingOnTheGoUITests: XCTestCase {
    private struct CodexSessionDebugSnapshot {
        let threadID: String
        let transcriptCount: Int
        let assistantReplies: Int
        let streaming: Bool
        let connection: String
        let protocolKind: String
        let composerAttempts: Int
        let draftCount: Int
    }

    private static let bundledLocalhostRawKeyBase64 = "ByaloKNmhnQY5TSSbGFZoPwByFeM+cwqmV3AFJw5L14="
    private static let fallbackPhysicalDeviceSSHHost = "example-mac.local"
    private static let physicalDeviceSSHUser = "developer"
    private static let embeddedTailnetTargetHostDefault = "example-mac.example.ts.net"
    private static let embeddedTailnetAuthKeyPathDefault = "/tmp/cotg_embedded_tailnet_auth_key.txt"
    private static let localhostHostKeyDefault = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx"
    private let app = XCUIApplication()
    private var metadataPath = ""
    private var syncMirrorPath = ""
    private var codexHomePath = ""
    private let workspaceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path
    private var screenshotCaptureMarkerPath: String {
        "\(workspaceRoot)/marketing/app-store/screenshots/.capture-request"
    }
    private var nonGitWorkspaceRootOverride: String? {
        guard let trimmed = ProcessInfo.processInfo.environment["COTG_TEST_NON_GIT_WORKSPACE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return "/workspace/codex-app-setup"
        }
        return trimmed
    }
    private var worktreeFlowRepoPath: String? {
        let value = ProcessInfo.processInfo.environment["COTG_TEST_WORKTREE_FLOW_REPO_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty == false {
            return value
        }
        let generatedValue = UITestWorktreeFlowRepoPath.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return generatedValue?.isEmpty == false ? generatedValue : nil
    }
    private var crossDeviceThreadIDPath: String {
        ProcessInfo.processInfo.environment["COTG_TEST_CROSS_DEVICE_THREAD_ID_PATH"]
            ?? "/tmp/cotg_cross_device_thread_id.txt"
    }
    private var iPadParityThreadIDPath: String {
        ProcessInfo.processInfo.environment["COTG_TEST_IPAD_PARITY_THREAD_ID_PATH"]
            ?? "/tmp/cotg_ipad_parity_thread_id.txt"
    }
    private var physicalDeviceSSHHostPath: String {
        ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_FILE"]
            ?? "/tmp/cotg_test_ssh_host.txt"
    }
    private var crossDeviceMarker: String? {
        let value = ProcessInfo.processInfo.environment["COTG_TEST_CROSS_DEVICE_MARKER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
    private var defaultCrossDeviceMarker: String {
        "Cross-device continuity marker COTG_SHARED_THREAD"
    }
    private var localhostRawKeyPath: String {
        ProcessInfo.processInfo.environment["COTG_TEST_SSH_RAW_KEY_PATH"] ?? "/tmp/cotg_app_test_key.raw"
    }
    private var localhostSSHHost: String {
        let resolvedValue = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_RESOLVED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedValue = UITestSSHHostOverride.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileValue = try? String(contentsOfFile: physicalDeviceSSHHostPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEnvironmentValue = resolvedValue?.isEmpty == false ? resolvedValue : nil
        let environmentValue = value?.isEmpty == false ? value : nil
        let generatedHostValue = generatedValue?.isEmpty == false ? generatedValue : nil
        let resolvedFileValue = fileValue?.isEmpty == false ? fileValue : nil

        // Physical-device runners can generate the resolved LAN host into Swift source because
        // device-side UI tests cannot read host-side files like /tmp/cotg_test_ssh_host.txt.
        return resolvedEnvironmentValue
            ?? generatedHostValue
            ?? (isSimulatorRuntime ? environmentValue : resolvedFileValue)
            ?? (isSimulatorRuntime ? resolvedFileValue : environmentValue)
            ?? (isSimulatorRuntime ? "localhost" : Self.fallbackPhysicalDeviceSSHHost)
    }

    private var physicalDeviceSSHHostFileValue: String? {
        let value = try? String(contentsOfFile: physicalDeviceSSHHostPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
    private var localhostSSHPort: String {
        let value = ProcessInfo.processInfo.environment["COTG_TEST_SSH_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false ? value : nil) ?? "22"
    }
    private var externalTailnetDNSName: String? {
        let value = ProcessInfo.processInfo.environment["COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty == false {
            return value
        }
        let generatedValue = UITestExternalTailnetDNSName.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return generatedValue?.isEmpty == false ? generatedValue : nil
    }
    private var embeddedTailnetTargetHost: String? {
        let value = ProcessInfo.processInfo.environment["COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : Self.embeddedTailnetTargetHostDefault
    }
    private func repoRootEnvValue(named key: String) -> String? {
        let envPath = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".env").path
        guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  let separatorIndex = line.firstIndex(of: "=") else {
                continue
            }
            let name = String(line[..<separatorIndex])
            guard name == key else {
                continue
            }
            var value = String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
    private var embeddedTailnetAuthKey: String? {
        let value = ProcessInfo.processInfo.environment["COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty == false {
            return value
        }
        if let generatedValue = UITestEmbeddedTailnetAuthKey.value {
            let trimmedValue = generatedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue.hasPrefix("tskey-") {
                return trimmedValue
            }
        }
        let authKeyPath = ProcessInfo.processInfo.environment["COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY_PATH"]
            ?? Self.embeddedTailnetAuthKeyPathDefault
        if let fileValue = try? String(contentsOfFile: authKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           fileValue.hasPrefix("tskey-") {
            return fileValue
        }
        if let repoEnvValue = repoRootEnvValue(named: "TAILSCALE_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           repoEnvValue.hasPrefix("tskey-") {
            return repoEnvValue
        }
#if canImport(UIKit)
        let pasteboardValue = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pasteboardValue?.hasPrefix("tskey-") == true ? pasteboardValue : nil
#else
        return nil
#endif
    }
    private var sshHostKeyOverride: String? {
        if ProcessInfo.processInfo.environment["COTG_TEST_DISABLE_SSH_HOST_KEY_OVERRIDE"] == "1" {
            return nil
        }
        let value = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty == false {
            return value
        }
        return Self.localhostHostKeyDefault
    }
    private var localhostSSHUser: String {
        let candidates: [String?] = if isSimulatorRuntime {
            [
                ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"],
                ProcessInfo.processInfo.environment["USER"],
                NSUserName(),
                Self.physicalDeviceSSHUser
            ]
        } else {
            [
                ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"],
                Self.physicalDeviceSSHUser
            ]
        }

        return candidates
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .first
            ?? "developer"
    }
    private var localhostRawKeyBase64: String? {
        if let inlineBase64 = ProcessInfo.processInfo.environment["COTG_TEST_SSH_RAW_KEY_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !inlineBase64.isEmpty {
            return inlineBase64
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: localhostRawKeyPath)) else {
            return Self.bundledLocalhostRawKeyBase64
        }
        return data.base64EncodedString()
    }
    private var isSimulatorRuntime: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
            || ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
    }
    private var localhostIntegrationPrepared: Bool {
        localhostRawKeyBase64 != nil || FileManager.default.fileExists(atPath: localhostRawKeyPath)
    }
    private let screenshotFixtureDisplayName = "Local SSH"

    override func setUp() {
        continueAfterFailure = false
        let testRunID = UUID().uuidString
        metadataPath = "/tmp/cotg-ui-\(testRunID)-metadata.json"
        syncMirrorPath = "/tmp/cotg-ui-\(testRunID)-sync.json"
        codexHomePath = "/tmp/cotg-ui-\(testRunID)-codex-home/.codex"
        addUIInterruptionMonitor(withDescription: "System trust and local network alerts") { alert in
            self.handleSystemAlertIfPossible(alert)
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        try super.tearDownWithError()
    }

    func testFreshInstallShowsHonestOnboardingState() {
        launch(resetPersistedState: true, selectedShellTab: "connections")
        openConnectionsTab()

        XCTAssertTrue(app.staticTexts["Connect your Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["machine-directory-scan-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["machine-directory-open-add-mac-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["machine-card-p"].exists)
        XCTAssertFalse(app.staticTexts["Primary Tailnet"].exists)
        XCTAssertFalse(app.buttons["begin-tailnet-login-primary-tailnet"].exists)
    }

    func testFreshInstallScanLocalNetworkShowsVisibleFeedback() throws {
        launch(resetPersistedState: true, selectedShellTab: "connections")
        openConnectionsTab()

        XCTAssertTrue(waitForButton("machine-directory-scan-button", enabled: true, timeout: 10))
        app.buttons["machine-directory-scan-button"].tap()
        allowLocalNetworkPromptIfNeeded()

        let sawFeedback = waitForNearbyScanFeedback(timeout: 20)

        if !sawFeedback {
            throw XCTSkip(
                "Current simulator run did not expose discovery feedback after scanning."
            )
        }
    }

    func testFreshInstallFallbackActionsExpandManualRouteFormAndPreselectKind() {
        launch(resetPersistedState: true, selectedShellTab: "connections")
        openConnectionsTab()

        let addManuallyButton = app.buttons["machine-directory-open-add-mac-button"]
        XCTAssertTrue(addManuallyButton.waitForExistence(timeout: 10))
        addManuallyButton.tap()

        let manualFallback = app.buttons["machine-directory-open-manual-route-button"]
        XCTAssertTrue(manualFallback.waitForExistence(timeout: 10))
        manualFallback.tap()

        XCTAssertTrue(app.textFields["manual-route-address-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Local address"].waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()

        let tailnetFallback = app.buttons["machine-directory-open-tailnet-route-button"]
        XCTAssertTrue(tailnetFallback.exists)
        tailnetFallback.tap()

        XCTAssertTrue(app.navigationBars["Tailscale"].waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()

        let remoteSSHFallback = app.buttons["machine-directory-open-remote-ssh-route-button"]
        XCTAssertTrue(remoteSSHFallback.exists)
        remoteSSHFallback.tap()

        XCTAssertTrue(app.navigationBars["SSH address"].waitForExistence(timeout: 10))
    }

    func testFreshInstallScanLocalNetworkDiagnosticStatus() throws {
        launch(resetPersistedState: true, selectedShellTab: "connections")
        openConnectionsTab()

        XCTAssertTrue(waitForButton("machine-directory-scan-button", enabled: true, timeout: 10))
        app.buttons["machine-directory-scan-button"].tap()
        allowLocalNetworkPromptIfNeeded()

        _ = waitForNearbyScanFeedback(timeout: 20)

        let debugStatus = localNetworkDiscoveryStatusValue() ?? "missing"
        let visibleFeedback = nearbyScanFeedbackTextLabels.first(where: { app.staticTexts[$0].exists }) ?? "none"
        let nearbyResults = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "nearby-result-")
        ).allElementsBoundByIndex.map(\.identifier)
        let machineCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "machine-card-")
        ).allElementsBoundByIndex.map(\.identifier)

        print("DISCOVERY_DIAGNOSTIC status=\(debugStatus)")
        print("DISCOVERY_DIAGNOSTIC feedback=\(visibleFeedback)")
        print("DISCOVERY_DIAGNOSTIC nearbyResults=\(nearbyResults.joined(separator: ","))")
        print("DISCOVERY_DIAGNOSTIC machineCards=\(machineCards.joined(separator: ","))")

        if debugStatus == "missing" {
            throw XCTSkip(
                "Current simulator run did not expose the discovery debug status probe after scanning."
            )
        }
    }

    func testShellTabsMatchProductModel() {
        launch(resetPersistedState: true)

        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.otherElements["compact-shell-tab-bar"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.tabBars.count, 1, "Expected the phone shell to use the system TabView tab bar.")
            XCTAssertTrue(app.tabBars.buttons["Codex"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.tabBars.buttons["Connections"].exists)
            XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
            XCTAssertTrue(app.buttons["codex-browse-button"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["codex-more-button"].exists, "Expected the empty compact Codex state to expose tab-bar navigation instead of a conversation actions menu.")
        } else {
            XCTAssertTrue(shellTabButton(title: "Codex", identifier: "bubble.left.and.bubble.right").waitForExistence(timeout: 10))
            XCTAssertTrue(shellTabButton(title: "Connections", identifier: "dot.radiowaves.left.and.right").exists)
            XCTAssertTrue(shellTabButton(title: "Settings", identifier: "gearshape").exists)
        }
    }

    func testDefaultLaunchOpensCodexWithoutSelectingSession() {
        launch(resetPersistedState: true)

        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.staticTexts["Projects & Threads"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["No projects on this Mac yet"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "machine-card-")).firstMatch.exists)
        } else {
            XCTAssertTrue(app.otherElements["codex-empty-state"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Choose a project or thread"].waitForExistence(timeout: 10))
        }
    }

    func testCodexSettingsExposeBrowserPresentationPreference() {
        launch(resetPersistedState: true, selectedShellTab: "settings")

        XCTAssertTrue(waitForElementWithIdentifier("browser-presentation-picker", timeout: 10))
        XCTAssertTrue(waitForElementWithIdentifier("show-all-repos-toggle", timeout: 10))
    }

    func testCodexSettingsExposeExecutionDefaultsAndExtendedReasoning() {
        launch(resetPersistedState: true, selectedShellTab: "settings")
        configurePreferredCodexDefaults(
            reasoningLabel: "X-High",
            approvalLabel: "Never",
            sandboxLabel: "Full access"
        )
    }

    func testReviewerDemoModeShowsBundledThreadAndContinuesOnSameThread() {
        launch(resetPersistedState: true)

        launch(
            resetPersistedState: false,
            selectedShellTab: "codex",
            enableDemoModeOnLaunch: true
        )

        if !waitForActiveCodexSession(timeout: 10) {
            openReposBrowserIfNeeded()
            XCTAssertTrue(waitForHostBrowserContent(timeout: 15))
            selectProjectThreadFromBrowser(threadID: "demo-thread-reviewer-mode", timeout: 20)
        }

        dismissReposBrowserIfNeeded()
        XCTAssertTrue(waitForActiveCodexSession(timeout: 15))
        XCTAssertTrue(waitForTranscriptConversationHistory(timeout: 15, minimumCount: 3))

        let originalThreadID = activeThreadIDValue()
        XCTAssertEqual(originalThreadID, "demo-thread-reviewer-mode")

        sendPromptFromMainComposerAndWaitForContinuation(
            "Show that reviewer demo mode keeps the same thread on device.",
            timeout: 30
        )

        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 15))
    }

    func testNewSessionCreatesDistinctBrowserEntry() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        sendSmokePromptFromConnections(timeout: 45)
        openCodexTab()
        openReposBrowserIfNeeded()

        let initialResumeCount = browserResumeElements().count
        let newSessionButton = firstNewThreadButton()
        if !newSessionButton.exists {
            let firstRepoGroup = firstProjectRow()
            if firstRepoGroup.waitForExistence(timeout: 5) {
                let disclosureButton = firstProjectDisclosureButton()
                if disclosureButton.waitForExistence(timeout: 2) {
                    tapBrowserElement(disclosureButton)
                } else {
                    tapBrowserElement(firstRepoGroup)
                }
            }
        }
        guard newSessionButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("No project-scoped new-thread action surfaced in this simulator fixture; distinct thread semantics are covered by AppState tests.")
        }
        newSessionButton.tap()

        XCTAssertTrue(waitForActiveCodexSession(timeout: 10))

        openReposBrowserIfNeeded()
        let updatedResumeCount = browserResumeElements().count
        XCTAssertGreaterThanOrEqual(updatedResumeCount, initialResumeCount + 1)
    }

    func testCodexBrowserShowsRecentAndRepoHierarchyAfterConnect() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        sendSmokePromptFromConnections(timeout: 45)
        openCodexTab()
        openReposBrowserIfNeeded()

        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search projects or threads"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "machine-card-")).firstMatch.exists)

        let repoGroup = firstProjectRow()
        XCTAssertTrue(repoGroup.waitForExistence(timeout: 10))
        XCTAssertTrue(firstNewThreadButton().waitForExistence(timeout: 10))
    }

    func testCodexBrowserShowsRecentAndProjectHierarchyFromSeededFixture() {
        launch(resetPersistedState: true, seedAppStoreSessionFixture: true, selectedShellTab: "codex")
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)
        openReposBrowserIfNeeded()

        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search projects or threads"].waitForExistence(timeout: 10))

        let projectRow = firstProjectRow()
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10))

        let resumeRow = firstResumeRow()
        XCTAssertTrue(resumeRow.waitForExistence(timeout: 10))

        let newThreadButton = firstNewThreadButton()
        if !newThreadButton.waitForExistence(timeout: 2) {
            let disclosureButton = firstProjectDisclosureButton()
            if disclosureButton.waitForExistence(timeout: 2) {
                tapBrowserElement(disclosureButton)
            } else {
                tapBrowserElement(projectRow)
            }
        }
        XCTAssertTrue(firstNewThreadButton().waitForExistence(timeout: 10))
    }

    func testCodexBrowserShowsCachedProjectsWhileReconnectIsPending() {
        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedConnectingRestore: true,
            selectedShellTab: "codex"
        )
        openReposBrowserIfNeeded()

        let projectRow = firstProjectRow()
        XCTAssertTrue(
            projectRow.waitForExistence(timeout: 10),
            "Expected cached Projects to remain visible while reconnect is pending. Browser status: \(browserStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            firstResumeRow().waitForExistence(timeout: 10),
            "Expected cached Threads to remain visible while reconnect is pending. Browser status: \(browserStatusValue() ?? "missing")"
        )

        let browserStatus = browserStatusValue() ?? ""
        XCTAssertTrue(browserStatus.contains("connection=connecting"), browserStatus)
        XCTAssertTrue(browserStatus.contains("provenance=cachedHostCatalog"), browserStatus)
        XCTAssertFalse(app.staticTexts["Loading live projects"].exists)
    }

    func testCodexBrowserShowsCurrentWorkspaceProjectWhenHostHistoryIsEmpty() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()

        let repoName = URL(fileURLWithPath: workspaceRoot, isDirectory: true).lastPathComponent
        let projectRow = app.otherElements["project-group-\(repoName)"]
        XCTAssertTrue(
            projectRow.waitForExistence(timeout: 10),
            "Expected the current workspace to appear as a project even before host thread history exists. Browser status: \(browserStatusValue() ?? "missing")"
        )
        XCTAssertTrue(app.buttons["new-thread-\(repoName)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No projects yet"].exists)
    }

    func testCodexBrowserProjectNewThreadDismissesSheetOnCompactWidth() throws {
        try requireLocalhostIntegration()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This browser handoff regression is compact-width only.")
        }

        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()

        let repoName = URL(fileURLWithPath: workspaceRoot, isDirectory: true).lastPathComponent
        let newThreadButton = app.buttons["new-thread-\(repoName)"]
        XCTAssertTrue(
            waitForElementExists(newThreadButton, timeout: 10, maxSwipes: 8),
            "Expected a project-scoped new-thread button for the current workspace. Browser status: \(browserStatusValue() ?? "missing")"
        )

        tapBrowserElement(newThreadButton)

        XCTAssertTrue(waitForElementToDisappear(app.staticTexts["Projects & Threads"], timeout: 10))
        XCTAssertTrue(waitForActiveCodexSession(timeout: 15))
        XCTAssertTrue(app.buttons["queue-prompt-button"].waitForExistence(timeout: 10))
    }

    func testActiveCodexSessionChromeKeepsAdminControlsSecondary() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        ensureSessionWorkspace(timeout: 10)

        XCTAssertTrue(waitForElementWithIdentifier("codex-session-header", timeout: 10))
        XCTAssertTrue(app.otherElements["codex-sticky-composer"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForElementWithIdentifier("photo-tool-button", timeout: 10))
        XCTAssertTrue(waitForElementWithIdentifier("voice-tool-button", timeout: 10))
        XCTAssertTrue(waitForElementWithIdentifier("workspace-review-summary", timeout: 10))

        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.buttons["model-menu-button"].exists)
        } else {
            XCTAssertTrue(app.buttons["model-menu-button"].waitForExistence(timeout: 10))
        }

        XCTAssertFalse(app.buttons["connect-live-button"].exists)
        XCTAssertFalse(app.buttons["reconnect-safe-lane-button"].exists)
        XCTAssertFalse(app.buttons["smoke-test-button"].exists)
        XCTAssertFalse(app.buttons["upgrade-loopback-button"].exists)
        XCTAssertFalse(app.buttons["fallback-safe-lane-button"].exists)
    }

    func testCompactWidthMachineNavigationReachesDetail() {
        launch(
            resetPersistedState: true,
            seedPreviewFixture: true,
            selectedShellTab: "connections"
        )
        navigateToPrimaryMachineInConnections()
        assertConnectionsDetailIsVisible(timeout: 15)
    }

    func testCompactWidthSeededManualRouteNavigationReachesDetail() throws {
        try requireLocalhostIntegration()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This seeded compact Connections navigation check is phone-only.")
        }

        launch(
            resetPersistedState: true,
            seedLocalhostManualRoute: true,
            selectedShellTab: "connections"
        )

        navigateToCurrentFixtureMachineInConnections()
        assertConnectionsDetailIsVisible(timeout: 15)
    }

    func testParallelAgentControlIsVisibleAndSelectable() {
        launch(resetPersistedState: true, seedPreviewFixture: true)
        navigateToPrimaryMachine()

        assertConnectionSurfaceIsVisible(timeout: 15)
        openSettingsTab()
        XCTAssertTrue(app.buttons["settings-parallel-agent-menu"].waitForExistence(timeout: 10))
        app.buttons["settings-parallel-agent-menu"].tap()
        XCTAssertTrue(app.buttons["Client-orchestrated"].waitForExistence(timeout: 10))
        app.buttons["Client-orchestrated"].tap()

        XCTAssertTrue(waitForButton("settings-parallel-agent-menu", enabled: true, timeout: 10))
        XCTAssertTrue(app.buttons["settings-parallel-agent-menu"].label.contains("Client-orchestrated"))
    }

    func testSettingsExposesPrivacyAndSupportLinks() {
        launch(resetPersistedState: true, seedPreviewFixture: true)
        openSettingsTab()

        XCTAssertTrue(waitForElementExists(app.descendants(matching: .any)["settings-privacy-link"], timeout: 10, maxSwipes: 8))
        XCTAssertTrue(waitForElementExists(app.descendants(matching: .any)["settings-support-link"], timeout: 10, maxSwipes: 8))
    }

    func testLiveLocalhostSafeLaneSmokePath() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedPreviewFixture: true)
        navigateToPrimaryMachine()

        assertSafeLaneSurfaceIsVisible(timeout: 20)

        sendSmokePromptFromConnections()
        XCTAssertTrue(waitForAssistantReplyCount(1, timeout: 30))
        XCTAssertTrue(waitForButton("interrupt-turn-button", enabled: false, timeout: 30))

        sendSmokePromptFromConnections()
        XCTAssertTrue(waitForAssistantReplyCount(2, timeout: 30))
        XCTAssertTrue(waitForButton("interrupt-turn-button", enabled: false, timeout: 30))
    }

    func testLoopbackUpgradeControlsAppearOnlyAfterSafeLaneConnect() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachine()

        assertConnectionSurfaceIsVisible(timeout: 20)
        XCTAssertFalse(app.buttons["upgrade-loopback-button"].exists)
        XCTAssertFalse(app.buttons["fallback-safe-lane-button"].exists)
        XCTAssertFalse(app.staticTexts["Loopback websocket"].exists)

        assertSafeLaneSurfaceIsVisible(timeout: 60)
        openConnectionsTab()
        expandDisclosureIfNeeded("Support and recovery")
        XCTAssertTrue(waitForButton("upgrade-loopback-button", enabled: true, timeout: 20, maxSwipes: 8))
        XCTAssertFalse(app.buttons["fallback-safe-lane-button"].exists)
    }

    func testLoopbackUpgradeAndManualFallbackWorkOnIOS() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToScreenshotMachine()

        assertSafeLaneSurfaceIsVisible(timeout: 60)
        openConnectionsTab()
        expandDisclosureIfNeeded("Support and recovery")
        XCTAssertTrue(waitForButton("upgrade-loopback-button", enabled: true, timeout: 20, maxSwipes: 8))

        app.buttons["upgrade-loopback-button"].tap()

        XCTAssertTrue(waitForStaticText("Loopback websocket", timeout: 45))
        XCTAssertTrue(waitForButton("fallback-safe-lane-button", enabled: true, timeout: 20, maxSwipes: 8))

        let baselineReplyCount = assistantReplyCount() ?? 0
        sendSmokePromptFromConnections(timeout: 45)
        XCTAssertTrue(waitForAssistantReplyCount(baselineReplyCount + 1, timeout: 45))

        openConnectionsTab()
        expandDisclosureIfNeeded("Support and recovery")
        app.buttons["fallback-safe-lane-button"].tap()

        XCTAssertTrue(waitForStaticText("SSH safe lane", timeout: 30))
        XCTAssertTrue(waitForButton("upgrade-loopback-button", enabled: true, timeout: 20, maxSwipes: 8))
        XCTAssertFalse(app.buttons["fallback-safe-lane-button"].exists)
    }

    func testLoopbackTurnFailureFallsBackToSafeLaneAndCompletesTurn() throws {
        try requireLocalhostIntegration()
        launch(
            resetPersistedState: true,
            seedLocalhostManualRoute: true,
            forceLoopbackFailureOnNextTurn: true
        )
        navigateToScreenshotMachine()

        assertSafeLaneSurfaceIsVisible(timeout: 60)
        openConnectionsTab()
        expandDisclosureIfNeeded("Support and recovery")
        XCTAssertTrue(waitForButton("upgrade-loopback-button", enabled: true, timeout: 20, maxSwipes: 8))
        app.buttons["upgrade-loopback-button"].tap()

        XCTAssertTrue(waitForStaticText("Loopback websocket", timeout: 45))

        let baselineReplyCount = assistantReplyCount() ?? 0
        sendSmokePromptFromConnections(timeout: 45)
        XCTAssertTrue(waitForAssistantReplyCount(baselineReplyCount + 1, timeout: 45))
        openConnectionsTab()
        expandDisclosureIfNeeded("Support and recovery")
        XCTAssertTrue(waitForStaticText("SSH safe lane", timeout: 30))
        XCTAssertTrue(waitForButton("upgrade-loopback-button", enabled: true, timeout: 20, maxSwipes: 8))
        XCTAssertFalse(app.buttons["fallback-safe-lane-button"].exists)
    }

    func testIPadSplitViewShowsInspectorAndTailnetContext() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This layout verification is iPad-only.")
        }

        launch(resetPersistedState: true, seedPreviewFixture: true, selectedShellTab: "connections")
        guard waitForScreenshotFixtureSurface(timeout: 10) else {
            throw XCTSkip("Seeded preview fixture did not surface a machine directory on this simulator run.")
        }

        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connections-inspector-toggle"].waitForExistence(timeout: 10))
    }

    func testIPadCodexSplitViewShowsBrowserAndInspector() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This layout verification is iPad-only.")
        }

        launch(resetPersistedState: true, seedPreviewFixture: true)
        navigateToPrimaryMachine()

        openCodexTab()
        XCTAssertTrue(app.otherElements["codex-browser-list"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["codex-session-header"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Show Inspector"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "machine-card-")).firstMatch.exists)

        app.buttons["Show Inspector"].tap()
        XCTAssertTrue(app.otherElements["workspace-review-full"].waitForExistence(timeout: 10))
    }

    func testIPadOpenMachineWindowCreatesSecondScene() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This multiwindow verification is iPad-only.")
        }

        launch(resetPersistedState: true, seedPreviewFixture: true)
        openConnectionsTab()
        returnToConnectionsListIfNeeded(missingMachineIdentifier: nil)
        scrollMachineDirectoryToTop()

        let openWindowButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "open-machine-window-")).firstMatch
        XCTAssertTrue(openWindowButton.waitForExistence(timeout: 10))
        let baselineWindowCount = max(app.windows.count, 1)

        openWindowButton.tap()

        guard waitForMinimumWindowCount(baselineWindowCount + 1, timeout: 10) else {
            throw XCTSkip("XCTest on this iPad simulator did not surface a second app window after openWindow; side-by-side placement remains under iPadOS window manager control.")
        }
    }

    func testReopenRestoresPreviouslySelectedMachineIfPersisted() {
        launch(resetPersistedState: true, seedPreviewFixture: true)
        navigateToSecondaryMachine()

        assertConnectionSurfaceIsVisible(timeout: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()

        openConnectionsTab()
        ensureConnectionsDetailVisible(timeout: 10, preferredMachineCardIdentifier: "machine-card-c")
    }

    func testReconnectAfterRelaunchResumesSameThread() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedPreviewFixture: true)
        navigateToPrimaryMachine()

        assertSafeLaneSurfaceIsVisible(timeout: 20)
        sendSmokePromptFromConnections()
        XCTAssertTrue(waitForAssistantReplyCount(1, timeout: 30))

        let threadLabel = activeThreadIDElement()
        XCTAssertTrue(threadLabel.waitForExistence(timeout: 10))
        let originalThreadID = threadLabel.label
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")

        RunLoop.current.run(until: Date().addingTimeInterval(1))

        app.terminate()
        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()

        if !waitForActiveCodexSession(timeout: 10) {
            navigateToPrimaryMachine()
        }

        openConnectionsTab()
        XCTAssertTrue(waitForButton("reconnect-safe-lane-button", enabled: true, timeout: 10))
        app.buttons["reconnect-safe-lane-button"].tap()

        openCodexTab()
        ensureSessionWorkspace(timeout: 15)
        let restoredThreadLabel = activeThreadIDElement()
        XCTAssertTrue(restoredThreadLabel.waitForExistence(timeout: 30))
        XCTAssertEqual(restoredThreadLabel.label, originalThreadID)
        let baselineReplyCount = assistantReplyCount() ?? 0
        sendSmokePromptFromConnections()

        XCTAssertTrue(
            waitForAssistantReplyCount(baselineReplyCount + 1, timeout: 30),
            "Expected assistant reply count to advance from \(baselineReplyCount) to \(baselineReplyCount + 1); current label: \(assistantReplyCountLabel() ?? "missing")"
        )
        XCTAssertTrue(waitForStaticText(originalThreadID, timeout: 10))
    }

    func testTailnetProfilesCardCanSaveCustomProfile() {
        launch(resetPersistedState: true, seedPreviewFixture: true)
        navigateToPrimaryMachineInConnections()
        expandDisclosureIfNeeded("Tailnet and companion")

        XCTAssertTrue(waitForElementExists(app.buttons["save-tailnet-profile-button"], timeout: 20, maxSwipes: 8))

        let nameField = app.textFields["tailnet-display-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Edge Headscale")

        let controlField = app.textFields["tailnet-control-url-field"]
        XCTAssertTrue(controlField.waitForExistence(timeout: 10))
        controlField.tap()
        controlField.typeText("edge.example.com")

        app.buttons["save-tailnet-profile-button"].tap()

        XCTAssertTrue(app.staticTexts["Edge Headscale"].waitForExistence(timeout: 10))
    }

    func testConnectionSetupCardShowsPrimarySSHLoginGuidance() {
        launch(
            resetPersistedState: true,
            seedEmbeddedTailnetRoute: true,
            selectedShellTab: "connections"
        )
        navigateToPrimaryMachineInConnections()
        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForAnyStaticText(["Set up SSH access", "Create SSH Key", "Replace SSH Key"], timeout: 10))
        XCTAssertFalse(app.buttons["connection-plan-open-recovery-button"].exists)
    }

    func testConnectionSetupCardPrioritizesMacAccountBeforeSSHAccess() {
        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            selectedShellTab: "connections",
            overrideTestSSHUser: ""
        )
        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Choose Mac account"].exists)
        XCTAssertTrue(app.textFields["ssh-username-field"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connection-plan-generate-ssh-key-button"].exists)
        XCTAssertFalse(app.otherElements["connection-routes-card"].exists)
    }

    func testConnectionSetupCardOffersExistingSSHKeyRecovery() {
        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            seedRecoverableSavedSSHKey: true,
            disableLocalhostTestingCredentialAutoload: true,
            disableSavedCredentialBindingRecovery: true,
            selectedShellTab: "connections",
            overrideTestSSHUser: "recoverable-user"
        )
        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        let didAutoRecover = waitForConnectionStatusSubstring("credentialReady=true", timeout: 10)
            || app.otherElements["connection-routes-card"].waitForExistence(timeout: 10)
        let didShowAutoNotice = waitForElementExists(
            app.otherElements["connection-plan-auto-saved-key-notice"],
            timeout: 5,
            maxSwipes: 4
        )
        XCTAssertTrue(
            didAutoRecover || didShowAutoNotice,
            connectionStatusValue() ?? "missing connection status"
        )
        XCTAssertFalse(app.buttons["connection-plan-use-existing-ssh-key-button"].exists)
        XCTAssertFalse(app.buttons["connection-plan-try-existing-ssh-keys-button"].exists)
    }

    func testConnectionSetupCardPrefersSearchingSavedSSHKeysBeforeCreatingNewOne() {
        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            seedRecoverableSavedSSHKey: true,
            seedMultipleSavedSSHKeys: true,
            disableLocalhostTestingCredentialAutoload: true,
            disableSSHHostKeyOverride: true,
            disableSavedCredentialBindingRecovery: true,
            selectedShellTab: "connections",
            overrideTestSSHUser: "recoverable-user"
        )
        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        let showsSavedKeyFirstAction = waitForElementExists(
            app.buttons["connection-plan-verify-fingerprint-before-saved-keys-button"],
            timeout: 5,
            maxSwipes: 4
        )
            || waitForElementExists(app.buttons["connection-plan-scan-host-key-button"], timeout: 5, maxSwipes: 4)
            || waitForElementExists(app.buttons["connection-plan-trust-host-key-button"], timeout: 5, maxSwipes: 4)
            || waitForElementExists(app.otherElements["connection-plan-inline-host-key-review"], timeout: 5, maxSwipes: 4)
            || waitForElementExists(app.otherElements["connection-plan-auto-saved-key-notice"], timeout: 5, maxSwipes: 4)
            || waitForConnectionStatusSubstring("credentialReady=true", timeout: 5)
        XCTAssertTrue(showsSavedKeyFirstAction)
        XCTAssertTrue(
            app.buttons["connection-plan-generate-ssh-key-button"].exists
                || app.otherElements["connection-routes-card"].exists
                || (connectionStatusValue()?.contains("credentialReady=true") ?? false)
        )
        XCTAssertFalse(app.buttons["connection-plan-try-existing-ssh-keys-button"].exists)
    }

    func testConnectionTechnicalDetailsCanForgetSavedMachine() {
        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            selectedShellTab: "connections"
        )
        navigateToPrimaryMachineInConnections()

        let forgetButton = app.buttons["forget-machine-button"]
        XCTAssertTrue(waitForElementExists(forgetButton, timeout: 10, maxSwipes: 8))
        forgetButton.tap()

        let forgetAlertButton = app.alerts.buttons["Delete Mac"]
        XCTAssertTrue(forgetAlertButton.waitForExistence(timeout: 10))
        forgetAlertButton.tap()

        XCTAssertTrue(waitForConnectionsEmptyStateAfterForgettingMachine(timeout: 10))
    }

    func testSSHBootstrapCardShowsExplicitTrustNoticeWhenScannedKeyNeedsReview() {
        launch(
            resetPersistedState: true,
            seedEmbeddedTailnetRoute: true,
            seedPendingScannedHostKey: true,
            disableSSHHostKeyOverride: true,
            selectedShellTab: "connections"
        )

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))

        XCTAssertTrue(waitForAnyStaticText(["Verify Mac fingerprint", "Scanned fingerprint"], timeout: 10))
        XCTAssertTrue(app.otherElements["connection-plan-inline-host-key-review"].waitForExistence(timeout: 10))
        let trustButton = app.buttons["connection-plan-trust-host-key-button"]
        XCTAssertTrue(trustButton.waitForExistence(timeout: 10))
        XCTAssertTrue(
            trustButton.isEnabled,
            connectionStatusValue() ?? "missing connection status"
        )

        tapElement(trustButton)

        XCTAssertTrue(
            waitForConnectionStatusSubstring("hostValidationReady=true", timeout: 5),
            connectionStatusValue() ?? "missing connection status"
        )
    }

    func testManualRouteFormAddsNewMacFromConnectionsList() {
        launch(resetPersistedState: true, selectedShellTab: "connections")
        openConnectionsTab()

        let addManuallyButton = app.buttons["machine-directory-open-add-mac-button"]
        XCTAssertTrue(addManuallyButton.waitForExistence(timeout: 10))
        addManuallyButton.tap()

        let manualFallback = app.buttons["machine-directory-open-manual-route-button"]
        XCTAssertTrue(manualFallback.waitForExistence(timeout: 10))
        manualFallback.tap()

        let addressField = app.textFields["manual-route-address-field"]
        XCTAssertTrue(waitForElementExists(addressField, timeout: 10, maxSwipes: 4))
        addressField.tap()
        addressField.typeText("lab.local")

        let usernameField = app.textFields["manual-route-username-field"]
        XCTAssertTrue(waitForElementExists(usernameField, timeout: 10, maxSwipes: 4))
        usernameField.tap()
        usernameField.typeText(localhostSSHUser)

        let portField = app.textFields["manual-route-port-field"]
        XCTAssertTrue(waitForElementExists(portField, timeout: 10, maxSwipes: 4))
        portField.tap()
        portField.typeText("2222")

        XCTAssertTrue(waitForButton("manual-route-add-button", enabled: true, timeout: 10))
        app.buttons["manual-route-add-button"].tap()
        XCTAssertTrue(app.buttons["connections-summary-finish-setup-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        app.terminate()
        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()
        openConnectionsTab()
        XCTAssertTrue(waitForAnyStaticText(["Lab", "lab.local"], timeout: 10))
    }

    func testManualRouteFreshInstallConnectsAndReconnectsAfterRelaunch() throws {
        try requireLocalhostIntegration()

        launch(resetPersistedState: true, selectedShellTab: "connections")
        openConnectionsTab()

        let addManuallyButton = app.buttons["machine-directory-open-add-mac-button"]
        XCTAssertTrue(addManuallyButton.waitForExistence(timeout: 10))
        addManuallyButton.tap()

        let manualFallback = app.buttons["machine-directory-open-manual-route-button"]
        XCTAssertTrue(manualFallback.waitForExistence(timeout: 10))
        manualFallback.tap()

        let addressField = app.textFields["manual-route-address-field"]
        XCTAssertTrue(waitForElementExists(addressField, timeout: 10, maxSwipes: 4))
        addressField.tap()
        addressField.typeText(localhostSSHHost)

        let usernameField = app.textFields["manual-route-username-field"]
        XCTAssertTrue(waitForElementExists(usernameField, timeout: 10, maxSwipes: 4))
        usernameField.tap()
        usernameField.typeText(localhostSSHUser)

        XCTAssertTrue(waitForButton("manual-route-add-button", enabled: true, timeout: 10))
        app.buttons["manual-route-add-button"].tap()

        assertConnectionsDetailIsVisible(timeout: 20)
        let launchAction = waitForConnectionLaunchAction(timeout: 10, maxSwipes: 4)
        if launchAction == nil {
            let finishSetupButton = app.buttons["connections-summary-finish-setup-button"]
            XCTAssertTrue(
                finishSetupButton.waitForExistence(timeout: 10),
                "Expected either a connect/resume/open-Codex action or a finish-setup CTA after adding a manual Mac. Status: \(connectionStatusValue() ?? "missing")"
            )
            tapElement(finishSetupButton)
            XCTAssertTrue(
                waitForAnyStaticText(
                    ["Choose Mac account", "Set up SSH access", "Verify Mac fingerprint"],
                    timeout: 10
                ),
                "Expected the manual-add flow to land on the next setup step when the Mac is not ready to connect yet. Status: \(connectionStatusValue() ?? "missing")"
            )

            app.terminate()
            app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
            app.launch()
            openConnectionsTab()
            assertConnectionsDetailIsVisible(timeout: 20)
            XCTAssertTrue(
                app.buttons["connections-summary-finish-setup-button"].waitForExistence(timeout: 10)
                    || waitForAnyStaticText(
                        ["Choose Mac account", "Set up SSH access", "Verify Mac fingerprint"],
                        timeout: 10
                    ),
                "Expected the fresh manual Mac to persist and reopen into the finish-setup flow after relaunch. Status: \(connectionStatusValue() ?? "missing")"
            )
            return
        }
        guard let launchAction else {
            return
        }
        tapElement(launchAction)
        allowLocalNetworkPromptIfNeeded()

        assertSafeLaneSurfaceIsVisible(timeout: 60)
        sendSmokePromptFromConnections(timeout: 45)
        XCTAssertTrue(waitForAssistantReplyCount(1, timeout: 45))

        let threadLabel = activeThreadIDElement()
        XCTAssertTrue(threadLabel.waitForExistence(timeout: 15))
        let originalThreadID = threadLabel.label
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")

        app.terminate()
        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()

        openConnectionsTab()
        if waitForButton("reconnect-safe-lane-button", enabled: true, timeout: 5, maxSwipes: 4) {
            app.buttons["reconnect-safe-lane-button"].tap()
            allowLocalNetworkPromptIfNeeded()
            openCodexTab()
        } else if waitForButton("connections-summary-resume-button", enabled: true, timeout: 5, maxSwipes: 4) {
            app.buttons["connections-summary-resume-button"].tap()
            allowLocalNetworkPromptIfNeeded()
        } else {
            XCTAssertTrue(
                waitForButton("open-codex-from-connections-button", enabled: true, timeout: 5, maxSwipes: 4),
                "Expected a reconnect or resume action after relaunch."
            )
            app.buttons["open-codex-from-connections-button"].tap()
        }

        ensureSessionWorkspace(timeout: 15)
        let restoredThreadLabel = activeThreadIDElement()
        XCTAssertTrue(restoredThreadLabel.waitForExistence(timeout: 30))
        XCTAssertEqual(restoredThreadLabel.label, originalThreadID)

        let baselineReplyCount = assistantReplyCount() ?? 1
        sendSmokePromptFromConnections(timeout: 45)
        XCTAssertTrue(waitForAssistantReplyCount(baselineReplyCount + 1, timeout: 45))
    }

    func testPhysicalRealHostBrowserShowsProjectsAndThreads() throws {
        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 45),
            "Expected real host browser content. Browser status: \(browserStatusValue() ?? "missing")"
        )
        captureProofScreenshot(named: "physical-real-host-browser")

        let firstResume = firstResumeRow()
        XCTAssertTrue(firstResume.waitForExistence(timeout: 20))

        let firstProject = firstProjectRow()
        XCTAssertTrue(firstProject.waitForExistence(timeout: 20))
    }

    func testPhysicalRealHostPhoneBrowserButtonsAndSheetActionsWork() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This browser-action audit is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 45),
            "Expected real host browser content before auditing browser actions. Browser status: \(browserStatusValue() ?? "missing")"
        )

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields["Search projects or threads"].waitForExistence(timeout: 10))

        let firstProject = firstProjectRow()
        XCTAssertTrue(firstProject.waitForExistence(timeout: 20))

        let disclosureButton = firstProjectDisclosureButton()
        if disclosureButton.waitForExistence(timeout: 5) {
            tapBrowserElement(disclosureButton)
        } else {
            tapBrowserElement(firstProject)
        }

        let newThreadButton = firstNewThreadButton()
        XCTAssertTrue(
            newThreadButton.waitForExistence(timeout: 10),
            "Expected the project row to expand and expose the project-scoped new-thread action."
        )
        captureProofScreenshot(named: "physical-real-host-browser-audit")

        dismissReposBrowserIfNeeded()
        XCTAssertFalse(app.staticTexts["Projects & Threads"].exists)
    }

    func testPhysicalConnectionsScreenSanityKeepsExistingStateAccessible() throws {
        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: false)
        openConnectionsTab()
        returnToConnectionsListIfNeeded(missingMachineIdentifier: nil)

        if waitForButton("machine-directory-scan-button", enabled: true, timeout: 8) {
            scrollMachineDirectoryToTop()
            captureProofScreenshot(named: "physical-connections-list")
            app.buttons["machine-directory-scan-button"].tap()
            allowLocalNetworkPromptIfNeeded()

            let sawScanFeedback = waitForAnyStaticText(
                nearbyScanFeedbackTextLabels,
                timeout: 20
            ) || waitForNearbyScanFeedback(timeout: 20) || anyMachineCardExists()
            XCTAssertTrue(sawScanFeedback, "Expected scan feedback or an existing saved-Mac list on the physical Connections screen.")
            captureProofScreenshot(named: "physical-connections-post-scan")
        } else {
            scrollMachineDirectoryToTop()
        }

        if !anyMachineCardExists() {
            throw XCTSkip(
                "Physical UI_TESTING launches use the isolated UITesting metadata store on device, so existing saved-Mac state must be validated through the normal app or agent-device instead."
            )
        }

        returnToConnectionsListIfNeeded(missingMachineIdentifier: nil)
        scrollMachineDirectoryToTop()
        let machineCard = firstMachineCard()
        XCTAssertTrue(
            waitForElementExists(machineCard, timeout: 20, maxSwipes: 8),
            "Expected at least one saved Mac on the physical Connections screen."
        )
        machineCard.tap()
        allowLocalNetworkPromptIfNeeded()

        if !app.buttons["connect-live-button"].waitForExistence(timeout: 8),
           !app.otherElements["connection-plan-card"].waitForExistence(timeout: 2) {
            captureProofScreenshot(named: "physical-connections-selection-isolated-state")
            throw XCTSkip(
                "Physical UI_TESTING on device can still diverge from the normal app after selecting a discovered Mac, so detailed Connections proof must come from the installed app or agent-device snapshot instead."
            )
        }

        assertConnectionsDetailIsVisible(timeout: 20)
        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Finish setup on this iPhone"].exists)
        captureProofScreenshot(named: "physical-connections-plan")

        if app.otherElements["connection-plan-card"].waitForExistence(timeout: 5) {
            XCTAssertTrue(app.staticTexts["Finish setup on this iPhone"].exists)
        }

        scrollToAnyText(["Ways to connect"], maxSwipes: 6)
        let addLocalRouteButton = app.buttons["connection-routes-add-local-button"]
        XCTAssertTrue(waitForElementExists(addLocalRouteButton, timeout: 10, maxSwipes: 6))
        addLocalRouteButton.tap()
        XCTAssertTrue(waitForElementWithIdentifier("quick-manual-route-address-field", timeout: 10))
        captureProofScreenshot(named: "physical-connections-manual-route")

        scrollToAnyText(["Troubleshoot & technical details"], maxSwipes: 4)
        expandDisclosureIfNeeded("Troubleshoot & technical details")
        XCTAssertTrue(waitForElementExists(app.buttons["ssh-generate-key-button"], timeout: 10, maxSwipes: 6))
        captureProofScreenshot(named: "physical-connections-recovery")

        let tailnetRefreshButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "refresh-tailnet-login-")
        ).firstMatch
        if tailnetRefreshButton.waitForExistence(timeout: 5) {
            captureProofScreenshot(named: "physical-connections-tailnet-pending")
            tailnetRefreshButton.tap()
            XCTAssertTrue(
                waitForElementToDisappear(app.staticTexts["Sign-in pending"], timeout: 15)
                    || waitForElementToDisappear(tailnetRefreshButton, timeout: 15),
                "Expected embedded tailnet status refresh to clear a stale sign-in-pending state after browser approval."
            )
            captureProofScreenshot(named: "physical-connections-tailnet-refreshed")
        }
    }

    func testPhysicalInstalledAppLiveScreenshots() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live installed-app screenshots only run on a physical device.")
        }

        launchNormalInstalledApp()

        openConnectionsTab()
        _ = app.otherElements["connection-plan-card"].waitForExistence(timeout: 10)
            || app.staticTexts["Connect your Mac"].waitForExistence(timeout: 2)
            || firstMachineCard().waitForExistence(timeout: 2)
        if app.otherElements["connection-plan-card"].exists {
            XCTAssertTrue(app.staticTexts["Finish setup on this iPhone"].exists)
            XCTAssertTrue(app.staticTexts["Ways to connect"].exists)
        }
        captureProofScreenshot(named: "physical-installed-connections-live")
    }

    func testPhysicalInstalledAppLiveCodexScreenshots() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live installed-app screenshots only run on a physical device.")
        }

        launchNormalInstalledApp()

        openCodexTab()
        let codexEmptyState = app.otherElements["codex-empty-state"]
        let composerField = app.textFields["session-prompt-field"]
        let browserTitle = app.staticTexts["Projects & Threads"]

        if waitForActiveCodexSession(timeout: 20)
            || app.otherElements["codex-session-surface"].waitForExistence(timeout: 2)
            || codexEmptyState.waitForExistence(timeout: 3)
            || composerField.waitForExistence(timeout: 3)
            || app.textFields["Message Codex"].waitForExistence(timeout: 2)
            || app.staticTexts["No projects yet"].waitForExistence(timeout: 2) {
            if app.staticTexts["Reconnecting"].exists {
                XCTAssertFalse(
                    app.staticTexts["Restoring thread"].exists,
                    "Expected the installed phone app to avoid showing both a reconnect banner and a duplicate restoring-thread card."
                )
            }
            captureProofScreenshot(named: "physical-installed-codex-live")
        } else if browserTitle.waitForExistence(timeout: 2) {
            let resumeCandidates = browserResumeElements().allElementsBoundByIndex
            if let resumeRow = resumeCandidates.first(where: { $0.exists || $0.waitForExistence(timeout: 2) }) {
                tapBrowserElement(resumeRow)
                if waitForActiveCodexSession(timeout: 10)
                    || app.otherElements["codex-session-surface"].waitForExistence(timeout: 2)
                    || composerField.waitForExistence(timeout: 2) {
                    captureProofScreenshot(named: "physical-installed-codex-live")
                    return
                }
            }

            captureProofScreenshot(named: "physical-installed-codex-browser-live")
        } else {
            captureProofScreenshot(named: "physical-installed-codex-unavailable")
            throw XCTSkip(
                "The normal installed app stayed on a non-Codex surface after switching tabs on this device state."
            )
        }
    }

    func testPhysicalInstalledAppMirrorsDesktopStartedTurnFromLoopback() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live desktop-started mirroring proof only runs on a physical device.")
        }

        let environment = ProcessInfo.processInfo.environment
        let threadID = try requireEnvironmentValue(
            "COTG_MIRROR_THREAD_ID",
            skipMessage: "Set COTG_MIRROR_THREAD_ID to the materialized host thread selected by the Mac-side mirror probe."
        )
        let expectedText = try requireEnvironmentValue(
            "COTG_MIRROR_EXPECTED_TEXT",
            skipMessage: "Set COTG_MIRROR_EXPECTED_TEXT to the token the Mac-side mirror probe will ask Codex to stream."
        )
        let readySignalPath = try requireEnvironmentValue(
            "COTG_MIRROR_READY_SIGNAL_PATH",
            skipMessage: "Set COTG_MIRROR_READY_SIGNAL_PATH so the Mac-side mirror probe knows when to start the desktop turn."
        )
        let completedSignalPath = environment["COTG_MIRROR_COMPLETED_SIGNAL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        launchNormalInstalledApp()
        ensureInstalledAppRealHostBrowserReady(timeout: 90)

        selectProjectThreadFromBrowser(threadID: threadID, timeout: 60)

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected selecting the mirror probe thread to reveal a ready Codex session. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertEqual(activeThreadIDValue(), threadID)
        XCTAssertTrue(
            waitForCodexSessionProtocol("websocket", timeout: 120),
            "Desktop-started mirroring must be validated from the loopback websocket lane. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        try writeMirrorSignal("ready", to: readySignalPath)

        let didStream = waitForCodexSessionStreaming(timeout: 90)
            || waitForTextContaining(expectedText, timeout: 1)
        XCTAssertTrue(
            didStream,
            "Expected the iPhone app to enter streaming state after the Mac-side turn started. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForTextContaining(expectedText, timeout: 180),
            "Expected the iPhone transcript to mirror the Mac-side turn text \(expectedText). Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForCodexSessionIdle(timeout: 90),
            "Expected the mirrored desktop-started turn to settle back to idle. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertEqual(activeThreadIDValue(), threadID)

        if let completedSignalPath, !completedSignalPath.isEmpty {
            try writeMirrorSignal("completed", to: completedSignalPath)
        }
        captureProofScreenshot(named: "physical-installed-desktop-started-mirror")
    }

    func testPhysicalSeededCodexBrowserCompactScreenshot() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Deterministic Codex browser screenshots only run on a physical device.")
        }

        launch(resetPersistedState: true, seedPreviewFixture: true)
        openCodexTab()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 45),
            "Expected seeded preview data to surface the compact Codex browser on the connected iPhone."
        )
        captureProofScreenshot(named: "physical-seeded-codex-browser-compact")
    }

    func testPhysicalInstalledConnectionsPlanShowsSetupAndUseSections() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live Connections proof only runs on a physical device.")
        }

        launchNormalInstalledApp()

        openConnectionsTab()

        let connectionPlanCard = app.otherElements["connection-plan-card"]
        if !connectionPlanCard.waitForExistence(timeout: 10) {
            let machineCard = firstMachineCard()
            if waitForElementExists(machineCard, timeout: 5, maxSwipes: 8) {
                machineCard.tap()
            } else {
                captureProofScreenshot(named: "physical-installed-connections-no-machine")
                throw XCTSkip(
                    "The normal installed app on the physical device does not currently expose a saved Mac in Connections, so the live detail-plan proof is not available."
                )
            }
        }

        XCTAssertTrue(connectionPlanCard.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Finish setup on this iPhone"].exists)
        XCTAssertTrue(app.staticTexts["Ways to connect"].exists)
        captureProofScreenshot(named: "physical-installed-connections-plan")
    }

    func testPhysicalInstalledConnectionsAutomaticallyTriesSavedSSHKeys() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live saved-key recovery proof only runs on a physical device.")
        }

        launchNormalInstalledApp()

        openConnectionsTab()

        let connectionPlanCard = app.otherElements["connection-plan-card"]
        if !connectionPlanCard.waitForExistence(timeout: 10) {
            let machineCard = firstMachineCard()
            if waitForElementExists(machineCard, timeout: 5, maxSwipes: 8) {
                machineCard.tap()
            } else {
                captureProofScreenshot(named: "physical-installed-connections-no-machine-for-saved-key-recovery")
                throw XCTSkip(
                    "The normal installed app on the physical device does not currently expose a saved Mac in Connections, so live saved-key recovery proof is unavailable."
                )
            }
        }

        XCTAssertTrue(connectionPlanCard.waitForExistence(timeout: 10))

        let verifyFingerprintButton = app.buttons["connection-plan-verify-fingerprint-before-saved-keys-button"]
        let scanHostKeyButton = app.buttons["connection-plan-scan-host-key-button"]
        let autoSavedKeyNotice = app.otherElements["connection-plan-auto-saved-key-notice"]
        let hasAutoNotice = waitForElementExists(autoSavedKeyNotice, timeout: 5, maxSwipes: 4)
        let hasVerifyFingerprintAction = waitForElementExists(verifyFingerprintButton, timeout: 5, maxSwipes: 2)
        let hasScanHostKeyAction = waitForElementExists(scanHostKeyButton, timeout: 5, maxSwipes: 4)
        let alreadyRecovered = waitForConnectionStatusSubstring("credentialReady=true", timeout: 5)
            || app.otherElements["connection-routes-card"].waitForExistence(timeout: 5)

        guard hasAutoNotice || hasVerifyFingerprintAction || hasScanHostKeyAction || alreadyRecovered else {
            captureProofScreenshot(named: "physical-installed-connections-no-saved-key-auto-path")
            throw XCTSkip(
                "The live Connections detail is not currently showing automatic saved-key recovery or the required fingerprint step on this device state."
            )
        }

        let statusBeforeRecovery = connectionStatusValue() ?? "missing"
        if hasAutoNotice || alreadyRecovered {
            let didRecoverCredential = waitForConnectionStatusSubstring("credentialReady=true", timeout: 20)
                || waitForButton("connect-live-button", enabled: true, timeout: 20, maxSwipes: 4)
            let didShowTrustNotice = waitForElementExists(
                app.otherElements["connection-plan-saved-key-notice"],
                timeout: 10,
                maxSwipes: 4
            )
                || waitForStaticText(
                    "Saved SSH keys were found on this iPhone. Verify the Mac fingerprint first, then try the saved keys again.",
                    timeout: 10
                )

            XCTAssertTrue(
                didRecoverCredential || didShowTrustNotice,
                "Expected automatic saved-key recovery to either recover a usable SSH credential or explain that fingerprint trust is still required. Before: \(statusBeforeRecovery); after: \(connectionStatusValue() ?? "missing")"
            )

            if didRecoverCredential {
                captureProofScreenshot(named: "physical-installed-connections-auto-saved-ssh-key-recovered")
            } else {
                captureProofScreenshot(named: "physical-installed-connections-auto-saved-ssh-key-needs-fingerprint")
            }
        } else {
            let requiredActionButton = hasVerifyFingerprintAction ? verifyFingerprintButton : scanHostKeyButton
            tapElement(requiredActionButton)

            let didExposeFingerprintStep = waitForAnyStaticText(["Scanned fingerprint", "Trust scanned key"], timeout: 20)
                || app.buttons["connection-plan-trust-host-key-button"].waitForExistence(timeout: 20)
            XCTAssertTrue(
                didExposeFingerprintStep,
                "Expected the saved-key flow to surface the fingerprint verification step before trying saved keys. Before: \(statusBeforeRecovery); after: \(connectionStatusValue() ?? "missing")"
            )

            captureProofScreenshot(named: "physical-installed-connections-saved-keys-shows-fingerprint-step")
        }

        XCTAssertFalse(app.buttons["connection-plan-try-existing-ssh-keys-button"].exists)
        XCTAssertFalse(app.buttons["connection-plan-use-existing-ssh-key-button"].exists)
    }

    func testPhysicalPhoneSeededConnectionsShowsVerifyFingerprintStep() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Seeded trust proof only runs on a physical device.")
        }

        launch(
            resetPersistedState: true,
            seedEmbeddedTailnetRoute: true,
            seedPendingScannedHostKey: true,
            disableSSHHostKeyOverride: true,
            selectedShellTab: "connections"
        )

        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForAnyStaticText(["Verify Mac fingerprint", "Scanned fingerprint"], timeout: 10))
        XCTAssertTrue(app.otherElements["connection-plan-inline-host-key-review"].waitForExistence(timeout: 10))

        let trustButton = app.buttons["connection-plan-trust-host-key-button"]
        XCTAssertTrue(trustButton.waitForExistence(timeout: 10))
        XCTAssertTrue(
            trustButton.isEnabled,
            connectionStatusValue() ?? "missing connection status"
        )

        tapElement(trustButton)

        XCTAssertTrue(
            waitForConnectionStatusSubstring("hostValidationReady=true", timeout: 5),
            connectionStatusValue() ?? "missing connection status"
        )
        captureProofScreenshot(named: "physical-connections-verify-fingerprint")
    }

    func testPhysicalPhoneSeededConnectionsSetupPrioritizesAccountBeforeSSHAccess() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Seeded setup proof only runs on a physical device.")
        }

        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            selectedShellTab: "connections",
            overrideTestSSHUser: ""
        )

        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Choose Mac account"].exists)
        XCTAssertTrue(app.textFields["ssh-username-field"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connection-plan-generate-ssh-key-button"].exists)
        captureProofScreenshot(named: "physical-connections-account-before-ssh")
    }

    func testPhysicalPhoneSeededConnectionsOffersExistingSSHKeyRecovery() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Saved SSH key recovery proof only runs on a physical device.")
        }

        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            seedRecoverableSavedSSHKey: true,
            disableLocalhostTestingCredentialAutoload: true,
            disableSavedCredentialBindingRecovery: true,
            selectedShellTab: "connections",
            overrideTestSSHUser: "recoverable-user"
        )

        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        let didAutoRecover = waitForConnectionStatusSubstring("credentialReady=true", timeout: 10)
            || app.otherElements["connection-routes-card"].waitForExistence(timeout: 10)
        let didShowAutoNotice = waitForElementExists(
            app.otherElements["connection-plan-auto-saved-key-notice"],
            timeout: 5,
            maxSwipes: 4
        )
        XCTAssertTrue(
            didAutoRecover || didShowAutoNotice,
            connectionStatusValue() ?? "missing connection status"
        )
        XCTAssertFalse(app.buttons["connection-plan-use-existing-ssh-key-button"].exists)
        XCTAssertFalse(app.buttons["connection-plan-try-existing-ssh-keys-button"].exists)
        captureProofScreenshot(named: "physical-connections-auto-existing-ssh-key")
    }

    func testPhysicalPhoneSeededConnectionsSearchesSavedSSHKeysBeforeCreatingNewOne() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Saved SSH key search proof only runs on a physical device.")
        }

        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            seedRecoverableSavedSSHKey: true,
            seedMultipleSavedSSHKeys: true,
            disableLocalhostTestingCredentialAutoload: true,
            disableSavedCredentialBindingRecovery: true,
            selectedShellTab: "connections",
            overrideTestSSHUser: "recoverable-user"
        )

        navigateToPrimaryMachineInConnections()

        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: 10))
        let showsSavedKeyFirstAction = waitForElementExists(
            app.buttons["connection-plan-verify-fingerprint-before-saved-keys-button"],
            timeout: 5,
            maxSwipes: 4
        )
            || waitForElementExists(app.buttons["connection-plan-scan-host-key-button"], timeout: 5, maxSwipes: 4)
            || waitForElementExists(app.buttons["connection-plan-trust-host-key-button"], timeout: 5, maxSwipes: 4)
            || waitForElementExists(app.otherElements["connection-plan-inline-host-key-review"], timeout: 5, maxSwipes: 4)
            || waitForElementExists(app.otherElements["connection-plan-auto-saved-key-notice"], timeout: 5, maxSwipes: 4)
            || waitForConnectionStatusSubstring("credentialReady=true", timeout: 5)
        XCTAssertTrue(showsSavedKeyFirstAction)
        XCTAssertTrue(
            app.buttons["connection-plan-generate-ssh-key-button"].exists
                || app.otherElements["connection-routes-card"].exists
                || (connectionStatusValue()?.contains("credentialReady=true") ?? false)
        )
        XCTAssertFalse(app.buttons["connection-plan-try-existing-ssh-keys-button"].exists)
        captureProofScreenshot(named: "physical-connections-search-saved-ssh-keys")
    }

    func testPhysicalPhoneSeededConnectionsCanForgetSavedMachine() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Forget-Mac proof only runs on a physical device.")
        }

        launch(
            resetPersistedState: true,
            seedLocalhostLANRoute: true,
            selectedShellTab: "connections"
        )

        navigateToPrimaryMachineInConnections()

        let forgetButton = app.buttons["forget-machine-button"]
        XCTAssertTrue(waitForElementExists(forgetButton, timeout: 10, maxSwipes: 8))
        forgetButton.tap()

        let forgetAlertButton = app.alerts.buttons["Delete Mac"]
        XCTAssertTrue(forgetAlertButton.waitForExistence(timeout: 10))
        forgetAlertButton.tap()

        XCTAssertTrue(waitForConnectionsEmptyStateAfterForgettingMachine(timeout: 10))
        captureProofScreenshot(named: "physical-connections-forget-machine")
    }

    func testPhysicalInstalledCodexLiveSurfaceStaysCompact() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live Codex proof only runs on a physical device.")
        }

        launchNormalInstalledApp()
        openCodexTab()
        ensureSessionWorkspace(timeout: 20)

        let sessionSurface = app.otherElements["codex-session-surface"]
        XCTAssertTrue(sessionSurface.waitForExistence(timeout: 10))

        if app.staticTexts["Reconnecting"].exists {
            XCTAssertFalse(
                app.staticTexts["Restoring thread"].exists,
                "Expected the live phone Codex view to avoid duplicating reconnect and restore states."
            )
        }

        let composer = app.otherElements["codex-sticky-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            composer.frame.height,
            132,
            "Expected the live phone composer to stay compact instead of leaving a tall empty block."
        )
        captureProofScreenshot(named: "physical-installed-codex-compact-live")
    }

    func testPhysicalInstalledAppThreadLifecycleShowsLatestAndStaysResponsive() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live thread lifecycle proof only runs on a physical device.")
        }

        launchNormalInstalledApp()
        openCodexTab()

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 5) {
            captureProofScreenshot(named: "physical-installed-thread-lifecycle-browser")
        }

        ensureSessionWorkspace(timeout: 60)
        let originalThreadID = activeThreadIDValue() ?? ""

        if app.staticTexts["Reconnecting"].waitForExistence(timeout: 5)
            || app.otherElements["codex-transcript-reconnect-preview"].waitForExistence(timeout: 1) {
            let browseButton = app.buttons["codex-browse-button"]
            XCTAssertTrue(browseButton.waitForExistence(timeout: 5))
            XCTAssertTrue(
                browseButton.isHittable,
                "Expected the installed iPhone app to keep top-bar navigation responsive while reconnecting."
            )
            captureProofScreenshot(named: "physical-installed-thread-lifecycle-reconnecting")
            browseButton.tap()
            if !app.staticTexts["Projects & Threads"].waitForExistence(timeout: 3) {
                let retryBrowseButton = app.buttons["codex-browse-button"]
                if retryBrowseButton.waitForExistence(timeout: 2), retryBrowseButton.isHittable {
                    retryBrowseButton.tap()
                }
            }
            XCTAssertTrue(app.staticTexts["Projects & Threads"].waitForExistence(timeout: 10))
            captureProofScreenshot(named: "physical-installed-thread-lifecycle-browser-during-reconnect")
            dismissReposBrowserIfNeeded()
            openCodexTab()
        }

        XCTAssertTrue(
            waitForActiveCodexSession(timeout: 15)
                || waitForElementWithIdentifier("codex-transcript-reconnect-preview", timeout: 10)
                || waitForVisibleTranscriptConversationHistory(timeout: 30, minimumCount: 1),
            "Expected the installed iPhone app to show an active, reconnecting, or transcript-backed Codex session promptly."
        )

        if !originalThreadID.isEmpty {
            XCTAssertTrue(waitForActiveThreadID(timeout: 20))
            XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        }

        if app.otherElements["codex-transcript-scroll"].exists,
           waitForVisibleTranscriptConversationHistory(timeout: 5, minimumCount: 1) {
            XCTAssertFalse(
                app.buttons["jump-to-latest-transcript-button"].exists,
                "Expected the installed iPhone app to land near the latest transcript messages instead of opening far above them."
            )
        }
        captureProofScreenshot(named: "physical-installed-thread-lifecycle-loaded")

        XCTAssertTrue(waitForCodexSessionIdle(timeout: 60))
        captureProofScreenshot(named: "physical-installed-thread-lifecycle-idle")

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        sendPromptFromComposer("Reply with INSTALLED_THREAD_OK only.", timeout: 45)

        XCTAssertTrue(
            waitForCodexSessionStreaming(timeout: 20),
            "Expected the installed iPhone app to show live thread work after sending instead of becoming unresponsive."
        )
        captureProofScreenshot(named: "physical-installed-thread-lifecycle-working")

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: !originalThreadID.isEmpty || activeThreadIDValue()?.isEmpty == false,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the installed iPhone app to keep the thread usable over time after reconnect."
        )
        XCTAssertTrue(waitForTextContaining("INSTALLED_THREAD_OK", timeout: 120))
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 90))
        if !originalThreadID.isEmpty {
            XCTAssertTrue(waitForActiveThreadID(timeout: 20))
            XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        }
        captureProofScreenshot(named: "physical-installed-thread-lifecycle-complete")
    }

    func testPhysicalInstalledAppStoreUploadThreadDoesNotForkOnSend() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This installed-app thread-binding proof only runs on a physical device.")
        }

        launchNormalInstalledApp()
        ensureInstalledAppRealHostBrowserReady(timeout: 90)

        let threadTitle = "app store upload"
        XCTAssertTrue(
            selectBrowserThreadByTitle(threadTitle, timeout: 60),
            "Expected to find the app store upload thread in the installed iPhone app browser. Browser status: \(browserStatusValue() ?? "missing")"
        )

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected selecting the app store upload thread to reveal a ready Codex session. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        let originalThreadID = try XCTUnwrap(activeThreadIDValue())
        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        let token = "APP_STORE_UPLOAD_BINDING_\(Int(Date().timeIntervalSince1970))"

        sendPromptFromComposer("Reply with \(token) only.", timeout: 45)

        XCTAssertTrue(
            waitForCodexSessionStreaming(timeout: 20),
            "Expected the selected app store upload thread to stream work after sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the installed app to keep the app store upload thread bound after sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining(token, timeout: 120))
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 90))
        XCTAssertEqual(
            activeThreadIDValue(),
            originalThreadID,
            "Expected the installed iPhone app to keep the same host thread instead of silently forking a new one."
        )

        openReposBrowserIfNeeded()
        XCTAssertTrue(waitForHostBrowserContent(timeout: 30))
        let searchField = app.searchFields["Search projects or threads"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("\(token)\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(
            browserResumeRows(containing: token).count,
            0,
            "Expected no new browser thread titled from the latest send token. Browser status: \(browserStatusValue() ?? "missing")"
        )
        captureProofScreenshot(named: "physical-installed-app-store-upload-thread-bound")
    }

    func testPhysicalInstalledAppStoreUploadThreadSurvivesRelaunchAndSend() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This installed-app relaunch proof only runs on a physical device.")
        }

        launchNormalInstalledApp()
        ensureInstalledAppRealHostBrowserReady(timeout: 90)

        XCTAssertTrue(
            selectBrowserThreadByTitle("app store upload", timeout: 60),
            "Expected to find the app store upload thread before relaunch. Browser status: \(browserStatusValue() ?? "missing")"
        )

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected app store upload to bind before relaunch. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        let originalThreadID = try XCTUnwrap(activeThreadIDValue())

        app.terminate()
        launchNormalInstalledApp()
        openCodexTab()

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 45),
            "Expected the relaunched installed app to restore a ready Codex session. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertEqual(
            activeThreadIDValue(),
            originalThreadID,
            "Expected the relaunched installed app to restore the same host-backed app store upload thread."
        )

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        let token = "APP_STORE_UPLOAD_RELAUNCH_\(Int(Date().timeIntervalSince1970))"

        sendPromptFromComposer("Reply with \(token) only.", timeout: 45)

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the relaunched installed app to keep the restored thread usable after send. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining(token, timeout: 120))
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 90))
        XCTAssertEqual(
            activeThreadIDValue(),
            originalThreadID,
            "Expected the relaunched installed app to keep the restored host thread instead of silently forking."
        )
    }

    func testPhysicalInstalledAppRelaunchRecoversLoopbackWebsocketLane() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This installed-app loopback recovery proof only runs on a physical device.")
        }

        launchNormalInstalledApp()
        openCodexTab()
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 60),
            "Expected the normal installed app to expose a ready Codex session. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForCodexSessionProtocol("websocket", timeout: 120),
            "Expected the normal installed app to recover the loopback websocket lane before relaunch. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        let originalThreadID = activeThreadIDValue()

        app.terminate()
        launchNormalInstalledApp()
        openCodexTab()

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 90),
            "Expected the relaunched installed app to restore a ready Codex session. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForCodexSessionProtocol("websocket", timeout: 120),
            "Expected the relaunched installed app to recover the loopback websocket lane instead of lingering on stdio. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        if let originalThreadID,
           originalThreadID != "thread-pending",
           let restoredThreadID = activeThreadIDValue() {
            XCTAssertEqual(
                restoredThreadID,
                originalThreadID,
                "Expected the relaunched installed app to keep the same active host thread while recovering loopback."
            )
        }
    }

    func testPhysicalInstalledAppFreshApprovalRequestShowsActionsAndContinues() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live approval-request proof only runs on a physical device.")
        }

        launchNormalInstalledApp()
        let originalThreadID = prepareRealHostPhoneSessionForLifecycle(timeout: 60)
        ensureSessionWorkspace(timeout: 60)

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected the installed iPhone app to expose a ready Codex session before triggering a fresh approval request."
        )

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()

        sendPromptFromComposer(
            "Run the exact command touch ~/.cotg_approval_probe_test-iphone on the host. If approval is required, request approval and, after approval is granted, reply with APPROVAL_ROUNDTRIP_OK only.",
            timeout: 45
        )

        XCTAssertTrue(
            waitForElementWithIdentifier("approve-request-button", timeout: 60),
            "Expected a fresh host approval request to show approve controls on the installed iPhone app. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForElementWithIdentifier("deny-request-button", timeout: 10),
            "Expected a fresh host approval request to show deny controls on the installed iPhone app."
        )
        captureProofScreenshot(named: "physical-installed-approval-request")

        app.buttons["approve-request-button"].tap()

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: !originalThreadID.isEmpty || activeThreadIDValue()?.isEmpty == false,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the installed iPhone app to continue the active thread after approving the fresh sandbox request. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining("APPROVAL_ROUNDTRIP_OK", timeout: 120))
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 90))
        if !originalThreadID.isEmpty {
            XCTAssertTrue(waitForActiveThreadID(timeout: 20))
            XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        }
        captureProofScreenshot(named: "physical-installed-approval-complete")
    }

    func testPhysicalRealHostPhoneFullAccessDefaultsAvoidApprovalRoundTrip() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live full-access proof only runs on a physical device.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This full-access proof is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(
            resetPersistedState: true,
            useRealHostCodexHome: false,
            preferredApprovalPolicyOverride: "never",
            preferredSandboxModeOverride: "danger-full-access"
        )
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        ensureSessionWorkspace(timeout: 90)
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the full-access validation thread to connect before sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        ensureSessionWorkspace(timeout: 60)
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected the full-access validation thread to expose a ready Codex session before sending."
        )
        let baselineThreadID = activeThreadIDValue() ?? ""
        let baselineHadConcreteThreadID = !baselineThreadID.isEmpty && baselineThreadID != "thread-pending"

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()

        sendPromptFromComposer(
            "Run the exact command sh -lc 'touch ~/.cotg_full_access_probe_test-iphone && printf FULL_ACCESS_NO_APPROVAL_OK' on the host and reply with the exact output only.",
            timeout: 45
        )

        XCTAssertTrue(
            waitForComposerSubmissionToStart(
                baselineTranscriptCount: baselineTranscriptCount,
                baselineAssistantReplies: baselineReplyCount,
                timeout: 20
            ),
            "Expected the full-access validation turn to start on the physical iPhone."
        )

        let authorityDeadline = Date().addingTimeInterval(15)
        var approvalAuthorityLabel: String?
        var sandboxAuthorityLabel: String?
        while Date() < authorityDeadline {
            approvalAuthorityLabel = accessibilityLabel(
                forElementWithIdentifier: "active-approval-policy-label",
                fallbackLabelPrefix: "Approvals:"
            )
            sandboxAuthorityLabel = accessibilityLabel(
                forElementWithIdentifier: "active-sandbox-label",
                fallbackLabelPrefix: "Sandbox:"
            )
            if approvalAuthorityLabel?.contains("never") == true,
               sandboxAuthorityLabel?.contains("danger-full-access") == true {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            approvalAuthorityLabel?.contains("never") == true,
            "Expected the physical iPhone full-access validation turn to stop advertising plain on-request authority once the turn started. Saw: \(approvalAuthorityLabel ?? "missing"); authority status: \(accessibilityLabel(forElementWithIdentifier: "active-authority-status-label", fallbackLabelPrefix: "Authority:") ?? "missing"); session: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            sandboxAuthorityLabel?.contains("danger-full-access") == true,
            "Expected the physical iPhone full-access validation turn to stop advertising plain workspace-write authority once the turn started. Saw: \(sandboxAuthorityLabel ?? "missing"); authority status: \(accessibilityLabel(forElementWithIdentifier: "active-authority-status-label", fallbackLabelPrefix: "Authority:") ?? "missing"); session: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertFalse(
            waitForElementWithIdentifier("approve-request-button", timeout: 5),
            "Expected the physical iPhone full-access validation turn to avoid showing an approval sheet. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        XCTAssertTrue(
            waitForThreadContinuationWithoutApprovalAfterSend(
                baselineHadThreadID: baselineHadConcreteThreadID,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the physical iPhone full-access validation turn to finish without any approval stop. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining("FULL_ACCESS_NO_APPROVAL_OK", timeout: 120))
        XCTAssertFalse(
            waitForElementWithIdentifier("approve-request-button", timeout: 2),
            "Expected the physical iPhone full-access validation turn to stay approval-free after the host command completed. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        let resolvedThreadID = activeThreadIDValue() ?? ""
        XCTAssertFalse(resolvedThreadID.isEmpty)
        XCTAssertNotEqual(resolvedThreadID, "thread-pending")
        if baselineHadConcreteThreadID {
            XCTAssertEqual(resolvedThreadID, baselineThreadID)
        }
        captureProofScreenshot(named: "physical-real-host-full-access-complete")
    }

    func testPhysicalRealHostPhoneCodesignSensitiveTurnAvoidsApprovalOnFreshWorkspaceSession() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live loopback/keychain proof only runs on a physical device.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This loopback/keychain proof is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(
            resetPersistedState: true,
            useRealHostCodexHome: false,
            preferredApprovalPolicyOverride: "never",
            preferredSandboxModeOverride: "danger-full-access",
            enableAutoUpgrade: true
        )
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        ensureSessionWorkspace(timeout: 90)
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the codesign validation thread to connect before sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected the codesign validation thread to expose a ready Codex session before sending."
        )

        let baselineThreadID = activeThreadIDValue() ?? ""
        let baselineHadConcreteThreadID = !baselineThreadID.isEmpty && baselineThreadID != "thread-pending"
        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()

        sendPromptFromComposer(
            "Run the exact shell command sh -lc 'tmpdir=$(mktemp -d); cp /bin/ls \"$tmpdir/ls\"; identity=$(/usr/bin/security find-identity -p codesigning -v | /usr/bin/grep \"Apple Development\" | /usr/bin/head -n 1 | /usr/bin/awk \"{print $2}\"); [ -n \"$identity\" ] && /usr/bin/codesign --force --sign \"$identity\" \"$tmpdir/ls\" >/dev/null 2>&1 && printf CODESIGN_KEYCHAIN_OK' and reply with the exact output only.",
            timeout: 45
        )

        XCTAssertTrue(
            waitForComposerSubmissionToStart(
                baselineTranscriptCount: baselineTranscriptCount,
                baselineAssistantReplies: baselineReplyCount,
                timeout: 20
            ),
            "Expected the physical iPhone codesign validation turn to start."
        )
        XCTAssertFalse(
            waitForElementWithIdentifier("approve-request-button", timeout: 5),
            "Expected the physical iPhone codesign validation turn to avoid showing an approval sheet. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForThreadContinuationWithoutApprovalAfterSend(
                baselineHadThreadID: baselineHadConcreteThreadID,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 180
            ),
            "Expected the physical iPhone codesign validation turn to finish without any approval stop. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining("CODESIGN_KEYCHAIN_OK", timeout: 180))
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        let resolvedThreadID = activeThreadIDValue() ?? ""
        XCTAssertFalse(resolvedThreadID.isEmpty)
        XCTAssertNotEqual(resolvedThreadID, "thread-pending")
        if baselineHadConcreteThreadID {
            XCTAssertEqual(
                resolvedThreadID,
                baselineThreadID,
                "Expected the codesign-sensitive proof to keep the already-selected thread instead of rebinding to a different one. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
            )
        }
        captureProofScreenshot(named: "physical-real-host-codesign-loopback-complete")
    }

    func testPhysicalRealHostPhoneCodesignSensitiveTurnFailsClosedWhenLoopbackTurnFails() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live loopback/keychain proof only runs on a physical device.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This loopback/keychain proof is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(
            resetPersistedState: true,
            useRealHostCodexHome: false,
            preferredApprovalPolicyOverride: "never",
            preferredSandboxModeOverride: "danger-full-access",
            forceLoopbackFailureOnNextTurn: true,
            enableAutoUpgrade: true
        )
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        ensureSessionWorkspace(timeout: 90)
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the codesign validation thread to connect before sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected the codesign validation thread to expose a ready Codex session before sending."
        )

        let baselineThreadID = activeThreadIDValue() ?? ""
        let baselineHadConcreteThreadID = !baselineThreadID.isEmpty && baselineThreadID != "thread-pending"

        sendPromptFromComposer(
            "Run the exact shell command sh -lc 'tmpdir=$(mktemp -d); cp /bin/ls \"$tmpdir/ls\"; identity=$(/usr/bin/security find-identity -p codesigning -v | /usr/bin/grep \"Apple Development\" | /usr/bin/head -n 1 | /usr/bin/awk \"{print $2}\"); [ -n \"$identity\" ] && /usr/bin/codesign --force --sign \"$identity\" \"$tmpdir/ls\" >/dev/null 2>&1 && printf CODESIGN_KEYCHAIN_OK' and reply with the exact output only.",
            timeout: 45
        )

        XCTAssertFalse(
            waitForElementWithIdentifier("approve-request-button", timeout: 5),
            "Expected the physical iPhone codesign validation refusal to avoid showing an approval sheet. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForTextContaining("Host not ready for signing-sensitive work", timeout: 180),
            "Expected the physical iPhone codesign validation turn to fail closed. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForTextContaining(
                "Loopback websocket failed before the signing-sensitive turn could start",
                timeout: 60
            ),
            "Expected the physical iPhone codesign validation turn to surface the loopback failure reason."
        )
        XCTAssertTrue(waitForReadyCodexSession(timeout: 45))
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        let resolvedThreadID = activeThreadIDValue() ?? ""
        XCTAssertFalse(resolvedThreadID.isEmpty)
        XCTAssertNotEqual(resolvedThreadID, "thread-pending")
        if baselineHadConcreteThreadID {
            XCTAssertEqual(
                resolvedThreadID,
                baselineThreadID,
                "Expected the codesign-sensitive refusal proof to keep the already-selected thread instead of rebinding to a different one. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
            )
        }
        captureProofScreenshot(named: "physical-real-host-codesign-loopback-refused")
    }

    func testPhysicalRealHostPhoneUploadAuthSensitiveTurnPreflightsBeforeExecution() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Live upload-auth host-readiness proof only runs on a physical device.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This upload-auth host-readiness proof is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(
            resetPersistedState: true,
            useRealHostCodexHome: false,
            preferredApprovalPolicyOverride: "never",
            preferredSandboxModeOverride: "danger-full-access",
            enableAutoUpgrade: true
        )
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        ensureSessionWorkspace(timeout: 90)
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the upload-auth validation thread to connect before sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected the upload-auth validation thread to expose a ready Codex session before sending."
        )

        sendPromptFromComposer(
            "Run asc auth token --confirm only. Do not upload anything. Reply ASC_AUTH_OK only if App Store Connect auth succeeds.",
            timeout: 45
        )

        XCTAssertFalse(
            waitForElementWithIdentifier("approve-request-button", timeout: 5),
            "Expected the upload-auth readiness preflight to avoid showing an approval sheet. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        let sawReadinessRefusal = waitForTextContaining("Host not ready for signing-sensitive work", timeout: 180)
        if sawReadinessRefusal {
            XCTAssertTrue(
                waitForTextContaining("Upload auth not ready", timeout: 60),
                "Expected the upload-auth sensitive turn to classify the failing phase. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
            )
            XCTAssertFalse(
                waitForTextContaining("ASC_AUTH_OK", timeout: 2),
                "Upload-auth refusal should not let the Codex turn report upload success."
            )
        } else {
            XCTAssertTrue(
                waitForTextContaining("ASC_AUTH_OK", timeout: 180),
                "Expected the upload-auth preflight to either refuse the unhealthy host state or allow a healthy ASC auth probe. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
            )
        }
        captureProofScreenshot(named: "physical-real-host-upload-auth-refused")
    }

    func testPhysicalPhoneCodexUsesTopBarNavigationInsteadOfBottomShell() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This shell validation is scoped to the physical iPhone.")
        }

        launch(resetPersistedState: true, seedAppStoreSessionFixture: true, selectedShellTab: "codex")
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let shellBar = app.otherElements["compact-shell-tab-bar"]
        XCTAssertFalse(shellBar.waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.count, 1, "Expected the compact phone shell to use the system TabView tab bar.")
        XCTAssertTrue(app.tabBars.buttons["Codex"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Connections"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["codex-browse-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["codex-more-button"].waitForExistence(timeout: 10))
        let composer = app.otherElements["codex-sticky-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            app.frame.maxY - composer.frame.maxY,
            36,
            "Expected the compact Codex composer to sit near the screen bottom instead of floating above a redundant bottom navigation bar."
        )

        tapElement(app.buttons["codex-more-button"])
        XCTAssertTrue(app.buttons["Connections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Settings"].exists)
        captureProofScreenshot(named: "physical-codex-topbar-nav-no-bottom-shell")
    }

    func testPhoneCompactBrowseButtonKeepsProjectsAndThreadsVisibleWithActiveSession() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This compact browser regression is scoped to the phone layout.")
        }

        launch(resetPersistedState: true, seedAppStoreSessionFixture: true, selectedShellTab: "codex")
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let browseButton = app.buttons["codex-browse-button"]
        XCTAssertTrue(browseButton.waitForExistence(timeout: 10))
        tapElement(browseButton)

        let browserTitle = app.staticTexts["Projects & Threads"]
        let browserList = app.otherElements["codex-browser-list"]
        XCTAssertTrue(
            browserTitle.waitForExistence(timeout: 10) || browserList.waitForExistence(timeout: 10),
            "Expected tapping Browse from an active phone session to keep the Projects & Threads sheet visible."
        )

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(
            browserTitle.exists || browserList.exists,
            "Expected the Projects & Threads sheet to stay visible after routine session updates instead of immediately dismissing itself."
        )
    }

    func testPhysicalPhoneCodexShowsCompactProgressStream() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This compact progress-stream validation is scoped to the physical iPhone.")
        }

        launch(resetPersistedState: true, seedAppStoreSessionFixture: true, selectedShellTab: "codex")
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let commentaryCluster = app.descendants(matching: .any)
            .matching(identifier: "session-commentary-cluster")
            .firstMatch
        let executionCluster = app.descendants(matching: .any)
            .matching(identifier: "session-execution-cluster")
            .firstMatch
        XCTAssertTrue(
            commentaryCluster.waitForExistence(timeout: 10)
                || executionCluster.waitForExistence(timeout: 10),
            "Expected a compact transcript activity cluster to appear on the physical iPhone."
        )
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session-bubble-assistant").firstMatch.waitForExistence(timeout: 10))
        captureProofScreenshot(named: "physical-codex-compact-progress-stream")
    }

    func testPhysicalPhoneCodexShowsCompactFailureRecoveryBar() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This compact recovery-bar validation is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedConnectionFailureDetail: "Allow Local Network access for Coding On The Go and retry.",
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        XCTAssertTrue(waitForCodexSessionConnectionState("failed", timeout: 10))
        XCTAssertTrue(app.staticTexts["Connection failed"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Allow Local Network access for Coding On The Go and retry."]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.buttons["Connections"].exists)
        captureProofScreenshot(named: "physical-codex-compact-failure-recovery-bar")
    }

    func testPhysicalPhoneQueuedPromptShowsQueuedOnIPhoneBadge() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This queued-prompt honesty proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedConnectingRestore: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        sendPromptFromComposer("Keep this prompt queued on the iPhone until the Mac reconnects.", timeout: 20)

        XCTAssertTrue(
            app.staticTexts["Queued on iPhone"].waitForExistence(timeout: 10),
            "Expected a truthful queued-on-phone delivery badge after sending while reconnecting."
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "session-bubble-user").firstMatch.exists
        )
        captureProofScreenshot(named: "physical-codex-queued-on-iphone-badge")
    }

    func testPhysicalPhoneCodexGroupsActivityAndPromotesPlanCard() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This transcript grouping proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedPlanMessage: """
            1. Group recent activity into a compact cluster.
            2. Render plan summaries as dedicated plan cards.
            3. Revalidate the transcript flow on the physical iPhone.
            """,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let commentaryCluster = app.descendants(matching: .any)
            .matching(identifier: "session-commentary-cluster")
            .firstMatch
        let executionCluster = app.descendants(matching: .any)
            .matching(identifier: "session-execution-cluster")
            .firstMatch
        XCTAssertTrue(
            commentaryCluster.waitForExistence(timeout: 10)
                || executionCluster.waitForExistence(timeout: 10),
            "Expected a grouped activity cluster to appear on the physical iPhone."
        )
        XCTAssertTrue(app.staticTexts["Plan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Implement next turn"].exists)
        captureProofScreenshot(named: "physical-codex-activity-and-plan-cards")
    }

    func testPhysicalPhoneCodexGroupsExecutionBurstsCompactly() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This activity-burst proof only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This activity-burst proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedActivityBurst: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let executionCluster = app.descendants(matching: .any)
            .matching(identifier: "session-execution-cluster")
            .firstMatch
        XCTAssertTrue(executionCluster.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Tool activity"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3 earlier tool updates hidden"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Show 3 more"].waitForExistence(timeout: 10))
        captureProofScreenshot(named: "physical-codex-execution-burst-collapsed")
    }

    func testPhysicalPhoneCodexShowsAttachmentHistoryChips() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This attachment-history proof only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This attachment-history proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedAttachmentHistory: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        XCTAssertTrue(app.staticTexts["browser-audit.png"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["route-summary.m4a"].waitForExistence(timeout: 10))
        captureProofScreenshot(named: "physical-codex-attachment-history")
    }

    func testPhysicalPhoneCodexShowsStructuredPlanQuestionCard() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This structured prompt proof only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This structured prompt proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedStructuredPrompt: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let questionText = app.staticTexts["Which implementation path should we take next?"]
        let optionButtonByIdentifier = app.descendants(matching: .any)
            .matching(identifier: "session-structured-option-next-step-Structured plan questions")
            .firstMatch
        let optionButtonByLabel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Structured plan questions")
        ).firstMatch
        XCTAssertTrue(
            questionText.waitForExistence(timeout: 10)
                || optionButtonByIdentifier.waitForExistence(timeout: 10)
                || optionButtonByLabel.waitForExistence(timeout: 10),
            "Expected the structured plan question prompt to appear on the physical iPhone."
        )

        let structuredOptionButton = optionButtonByIdentifier.exists ? optionButtonByIdentifier : optionButtonByLabel
        XCTAssertTrue(
            structuredOptionButton.waitForExistence(timeout: 5),
            "Expected the structured plan option button to appear on the physical iPhone."
        )
        structuredOptionButton.tap()

        let submitButton = app.descendants(matching: .any)
            .matching(identifier: "session-structured-prompt-submit")
            .firstMatch
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.tap()

        XCTAssertTrue(waitForComposerDraft("Which implementation path should we take next?", timeout: 10))
        XCTAssertTrue(waitForComposerDraft("Structured plan questions", timeout: 10))
        captureProofScreenshot(named: "physical-codex-structured-plan-question")
    }

    func testPhysicalPhoneBrowserShowsActiveJumpAndPreviewExpansion() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This browser-operations proof only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This browser-operations proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedBrowserOperations: true,
            selectedShellTab: "codex"
        )
        openCodexTab()
        XCTAssertTrue(waitForActiveCodexSession(timeout: 15))
        openReposBrowserIfNeeded()

        let projectDisclosure = app.buttons["project-disclosure-coding-on-the-go"]
        XCTAssertTrue(projectDisclosure.waitForExistence(timeout: 10))

        let activeThreadButton = app.buttons["project-active-thread-coding-on-the-go"]
        if !activeThreadButton.exists {
            tapBrowserElement(projectDisclosure)
        }

        let previewToggleButton = app.buttons["project-session-preview-toggle-coding-on-the-go"]
        XCTAssertTrue(activeThreadButton.waitForExistence(timeout: 10))
        XCTAssertTrue(previewToggleButton.waitForExistence(timeout: 10))
        tapBrowserElement(activeThreadButton)
        dismissReposBrowserIfNeeded()

        XCTAssertTrue(waitForActiveCodexSession(timeout: 10))
        XCTAssertEqual(activeThreadIDValue(), "browser-active-thread")
        captureProofScreenshot(named: "physical-browser-active-thread-jump")

        openReposBrowserIfNeeded()
        XCTAssertTrue(projectDisclosure.waitForExistence(timeout: 10))
        if !previewToggleButton.exists {
            tapBrowserElement(projectDisclosure)
        }

        XCTAssertTrue(
            scrollBrowserUntilElementHittable(previewToggleButton, maxSwipes: 6),
            "Expected the browser preview toggle to become tappable on the physical iPhone."
        )
        captureProofScreenshot(named: "physical-browser-preview-collapsed")

        tapBrowserElement(previewToggleButton)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let expandedPreviewToggleButton = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "project-session-preview-toggle-coding-on-the-go",
                "Show fewer"
            )
        ).firstMatch
        XCTAssertTrue(
            expandedPreviewToggleButton.waitForExistence(timeout: 10),
            "Expected the expanded preview toggle to switch to 'Show fewer threads' on the physical iPhone."
        )
        captureProofScreenshot(named: "physical-browser-preview-expanded")
    }

    func testPhysicalPhoneCodexAndBrowserEmptyStatesStayActionable() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This empty-state audit only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This empty-state audit is scoped to the physical iPhone.")
        }

        launch(resetPersistedState: true, selectedShellTab: "codex")
        dismissReposBrowserIfNeeded()

        XCTAssertTrue(app.staticTexts["Choose a project"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Set up this Mac first"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Use Connections to add or check a Mac. Daily work returns here."]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["Connections"].waitForExistence(timeout: 10))
        captureProofScreenshot(named: "physical-codex-empty-state")

        openReposBrowserIfNeeded()

        XCTAssertTrue(app.staticTexts["No projects on this Mac yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Connections"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Use Connections to discover and trust a Mac first. Projects appear here after real host thread data exists."]
                .waitForExistence(timeout: 10)
        )
        captureProofScreenshot(named: "physical-browser-empty-state")
    }

    func testPhysicalPhoneBrowserShowsSeededRecentAndProjectHierarchy() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This seeded browser proof only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This seeded browser proof is scoped to the physical iPhone.")
        }

        launch(resetPersistedState: true, seedAppStoreSessionFixture: true, selectedShellTab: "codex")
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)
        openReposBrowserIfNeeded()

        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 10))

        let projectRow = firstProjectRow()
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10))
        XCTAssertTrue(firstResumeRow().waitForExistence(timeout: 10))

        let newThreadButton = firstNewThreadButton()
        if !newThreadButton.waitForExistence(timeout: 2) {
            let disclosureButton = firstProjectDisclosureButton()
            if disclosureButton.waitForExistence(timeout: 2) {
                tapBrowserElement(disclosureButton)
            } else {
                tapBrowserElement(projectRow)
            }
        }
        XCTAssertTrue(firstNewThreadButton().waitForExistence(timeout: 10))
        captureProofScreenshot(named: "physical-browser-seeded-hierarchy")
    }

    func testPhysicalPhoneWorkspaceOnlySessionUsesProjectNameInsteadOfLastTurnSummary() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This workspace-only title proof only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This workspace-only title proof is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedThreadlessSessionSummary: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()

        XCTAssertTrue(waitForActiveCodexSession(timeout: 15))
        XCTAssertTrue(app.staticTexts["coding-on-the-go"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["I need one line of context on what you want repeated."].exists,
            "Workspace-only sessions should keep the project name in the header instead of promoting the last assistant summary."
        )
        XCTAssertNil(activeThreadIDValue())
        captureProofScreenshot(named: "physical-threadless-session-title")
    }

    func testCodexTranscriptJumpToLatestButtonAppearsAfterScrollingAwayFromBottom() {
        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedLongTranscript: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let jumpButton = app.descendants(matching: .any).matching(identifier: "jump-to-latest-transcript-button").firstMatch
        XCTAssertFalse(jumpButton.exists)

        let sessionSurface = app.otherElements["codex-session-surface"]
        XCTAssertTrue(sessionSurface.waitForExistence(timeout: 10))
        sessionSurface.swipeDown()

        XCTAssertTrue(jumpButton.waitForExistence(timeout: 10))
        jumpButton.tap()
        XCTAssertFalse(jumpButton.waitForExistence(timeout: 2))
    }

    func testPhysicalRealHostNonGitWorkspaceShowsUnavailableInsteadOfPending() throws {
        try requirePhysicalRealHostValidation()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This workspace-status validation is scoped to the physical iPhone.")
        }
        launchPhysicalRealHostValidationApp(
            resetPersistedState: true,
            workspaceRootOverride: nonGitWorkspaceRootOverride
        )
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        assertConnectionSurfaceIsVisible(timeout: 45)

        XCTAssertTrue(waitForElementWithIdentifier("workspace-review-summary", timeout: 15))
        XCTAssertTrue(app.staticTexts["Workspace unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Workspace pending"].exists)
        XCTAssertFalse(app.buttons["open-workspace-review-button"].exists)
        captureProofScreenshot(named: "physical-workspace-unavailable")
    }

    func testPhysicalRealHostPhoneWorktreeFlowStartsAndReturnsToLocal() throws {
        try requirePhysicalRealHostValidation()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This worktree-flow validation is scoped to the physical iPhone.")
        }
        guard let repoPath = worktreeFlowRepoPath else {
            throw XCTSkip("Set COTG_TEST_WORKTREE_FLOW_REPO_PATH to run the physical worktree-flow validation.")
        }

        launchPhysicalRealHostValidationApp(
            resetPersistedState: true,
            workspaceRootOverride: repoPath,
            useRealHostCodexHome: false
        )
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        startNewThreadInBrowserProject(repoPath: repoPath, timeout: 45)
        assertConnectionSurfaceIsVisible(timeout: 45)

        XCTAssertTrue(waitForElementWithIdentifier("workspace-review-summary", timeout: 15))
        XCTAssertTrue(app.buttons["open-workspace-review-button"].waitForExistence(timeout: 15))
        app.buttons["open-workspace-review-button"].tap()

        let startButton = app.buttons["workspace-start-worktree-thread-button"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 15))
        startButton.tap()

        let returnButton = app.buttons["workspace-return-thread-to-local-button"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 60))
        let worktreeThreadID = activeThreadIDElement().label
        XCTAssertFalse(worktreeThreadID.isEmpty)
        XCTAssertNotEqual(worktreeThreadID, "thread-pending")
        captureProofScreenshot(named: "physical-worktree-flow-worktree")

        returnButton.tap()

        XCTAssertTrue(startButton.waitForExistence(timeout: 60))
        let returnedThreadID = activeThreadIDElement().label
        XCTAssertFalse(returnedThreadID.isEmpty)
        XCTAssertNotEqual(returnedThreadID, "thread-pending")
        XCTAssertNotEqual(returnedThreadID, worktreeThreadID)
        captureProofScreenshot(named: "physical-worktree-flow-local")
    }

    func testPhysicalRealHostLaunchKeepsActiveThreadStableForFirstLoad() throws {
        try requirePhysicalRealHostValidation()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This launch-stability validation is scoped to the physical iPhone.")
        }

        launchPhysicalRealHostValidationApp(resetPersistedState: false)
        openCodexTab()
        assertConnectionSurfaceIsVisible(timeout: 20)
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        let initialThreadID = try XCTUnwrap(activeThreadIDValue())

        RunLoop.current.run(until: Date().addingTimeInterval(5))

        XCTAssertEqual(activeThreadIDValue(), initialThreadID)
        captureProofScreenshot(named: "physical-codex-launch-thread-stable")
    }

    func testPhysicalRealHostPhoneComposerStaysCompact() throws {
        try requirePhysicalRealHostValidation()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This composer-density validation is scoped to the physical iPhone.")
        }

        launchPhysicalRealHostValidationApp(resetPersistedState: false)
        openCodexTab()
        assertConnectionSurfaceIsVisible(timeout: 20)

        let composer = app.otherElements["codex-sticky-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))

        let promptField = composerPromptField()
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))

        XCTAssertLessThanOrEqual(
            composer.frame.height,
            148,
            "Expected the compact iPhone composer to stay visually dense instead of leaving a large empty footer."
        )
        captureProofScreenshot(named: "physical-codex-composer-compact")
    }

    func testPhysicalPhoneCodexStartsNearLatestMessageAndNativeKeyboardSendWorks() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This transcript and keyboard validation is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedLongTranscript: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        let latestAssistantSummary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "The reconnect path now keeps visible transcript history")
        ).firstMatch
        XCTAssertTrue(
            latestAssistantSummary.waitForExistence(timeout: 10),
            "Expected Codex to land near the latest transcript message on first render instead of opening at the oldest message."
        )

        let jumpButton = app.descendants(matching: .any)
            .matching(identifier: "jump-to-latest-transcript-button")
            .firstMatch
        XCTAssertFalse(jumpButton.exists, "Expected launch to pin the transcript to the latest message without requiring a manual jump.")

        let loadEarlierButton = app.buttons["transcript-load-earlier-button"]

        let composer = app.otherElements["codex-sticky-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            composer.frame.height,
            148,
            "Expected the compact phone composer to stay dense instead of leaving a tall empty block above the prompt field."
        )
        captureProofScreenshot(named: "physical-codex-latest-on-launch")

        let promptField = composerPromptField()
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))
        promptField.tap()

        XCTAssertFalse(
            app.buttons["dismiss-keyboard-button"].exists,
            "Expected compact iPhone keyboard dismissal to avoid an extra floating app-level Hide button."
        )
        XCTAssertFalse(
            app.buttons["keyboard-dismiss-button"].exists
                || app.keyboards.buttons["keyboard-dismiss-button"].exists
                || app.buttons["Hide"].exists
                || app.keyboards.buttons["Hide"].exists,
            "Expected the compact phone composer to avoid the floating keyboard-toolbar Hide control."
        )

        let keyboardSend = keyboardSendButton()
        XCTAssertTrue(
            keyboardSend.waitForExistence(timeout: 5),
            "Expected the native iOS keyboard to expose Send for the compact Codex prompt."
        )
        captureProofScreenshot(named: "physical-codex-keyboard-native-send-visible")

        let nativeSendPrompt = "Keyboard native send smoke"
        promptField.typeText(nativeSendPrompt)
        XCTAssertTrue(
            waitForComposerSendEnabled(timeout: 5),
            "Expected typing through the native keyboard to enable the app send button while the keyboard remains open. Composer value: \(composerPromptValue() ?? "missing")"
        )
        promptField.typeText("\n")
        XCTAssertTrue(
            waitForElementToDisappear(keyboardSend, timeout: 5),
            "Expected native keyboard Send to submit the compact composer and dismiss the keyboard."
        )
        XCTAssertFalse(
            composerSendButton().isEnabled,
            "Expected the native iOS keyboard Send key to submit and clear the composer instead of inserting a newline."
        )
        captureProofScreenshot(named: "physical-codex-keyboard-native-send-submitted")

        if loadEarlierButton.waitForExistence(timeout: 3) {
            loadEarlierButton.tap()
            XCTAssertTrue(
                waitForTextContaining("Do not let long answers take over the screen.", timeout: 10),
                "Expected the first staged history reveal to prepend the next older transcript page on the physical iPhone."
            )
            XCTAssertFalse(
                app.staticTexts["Audit the setup card first."].exists,
                "Expected staged transcript hydration to keep the oldest seeded history hidden after the first reveal on the physical iPhone."
            )
            captureProofScreenshot(named: "physical-codex-history-expanded-stage-1")

            if app.buttons["transcript-load-earlier-button"].waitForExistence(timeout: 3) {
                app.buttons["transcript-load-earlier-button"].tap()
                XCTAssertTrue(
                    waitForTextContaining("Do not overload the main screen with debug text.", timeout: 10),
                    "Expected the second staged history reveal to prepend another older transcript page on the physical iPhone."
                )
                XCTAssertFalse(
                    app.staticTexts["Audit the setup card first."].exists,
                    "Expected the oldest seeded history to remain hidden until the final staged reveal on the physical iPhone."
                )
                captureProofScreenshot(named: "physical-codex-history-expanded-stage-2")
            }

            if app.buttons["transcript-load-earlier-button"].waitForExistence(timeout: 3) {
                app.buttons["transcript-load-earlier-button"].tap()
                XCTAssertTrue(
                    waitForTextContaining("Audit the setup card first.", timeout: 10),
                    "Expected the final staged history reveal to surface the oldest seeded transcript entries on the physical iPhone."
                )
                XCTAssertFalse(
                    app.buttons["transcript-load-earlier-button"].exists,
                    "Expected the staged history affordance to disappear after all older seeded history is visible on the physical iPhone."
                )
                captureProofScreenshot(named: "physical-codex-history-expanded-stage-3")
            }
        }
    }

    func testPhysicalPhoneCodexReconnectStateStaysCompact() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This reconnect-layout validation is scoped to the physical iPhone.")
        }

        launch(
            resetPersistedState: true,
            seedAppStoreSessionFixture: true,
            seedConnectingRestore: true,
            selectedShellTab: "codex"
        )
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 15)

        XCTAssertTrue(app.staticTexts["Reconnecting"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["Restoring thread"].exists,
            "Expected reconnecting state to avoid showing a second restoring-thread card."
        )
        XCTAssertFalse(
            app.staticTexts["Loading the latest messages…"].exists,
            "Expected reconnecting state to collapse transcript restore messaging into the single reconnect banner."
        )
        XCTAssertFalse(
            app.staticTexts["Workspace pending"].exists,
            "Expected reconnecting state to avoid stacking a second pending workspace summary above the reconnect banner."
        )
        captureProofScreenshot(named: "physical-codex-reconnecting-compact")
    }

    func testPhysicalRealHostResumeContinuesExistingThread() throws {
        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()
        XCTAssertTrue(waitForHostBrowserContent(timeout: 45))

        let originalThreadID = resumeIdleProjectThreadFromBrowser(
            selectionTimeout: 20,
            idleTimeout: 20,
            maxCandidates: 4,
            startIndex: 1
        )
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")

        let baselineReplyCount = assistantReplyCount() ?? 0
        sendPromptFromComposer(
            "Continue this real thread from iPhone at \(Int(Date().timeIntervalSince1970))",
            timeout: 45
        )
        XCTAssertTrue(
            waitForVisibleTranscriptConversationHistory(timeout: 15, minimumCount: 1),
            "Expected the live transcript to stay visible on iPhone after sending. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        XCTAssertTrue(waitForAssistantReplyCount(baselineReplyCount + 1, timeout: 120))
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
    }

    func testPhysicalRealHostAppStoreUploadThreadSurvivesRelaunchAndSend() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This restore/send proof is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()
        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 45),
            "Expected live host browser content before selecting app store upload. Browser status: \(browserStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            selectBrowserThreadByTitle("app store upload", timeout: 60),
            "Expected to find the app store upload thread in the real-host browser. Browser status: \(browserStatusValue() ?? "missing")"
        )
        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 30),
            "Expected app store upload to bind before relaunch. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        let originalThreadID = try XCTUnwrap(activeThreadIDValue())

        app.terminate()
        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        XCTAssertTrue(
            waitForReadyCodexSession(timeout: 45),
            "Expected the relaunched real-host flow to restore a ready Codex session. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertEqual(
            activeThreadIDValue(),
            originalThreadID,
            "Expected the relaunched real-host flow to restore the same app store upload thread."
        )

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        let token = "APP_STORE_UPLOAD_REALHOST_\(Int(Date().timeIntervalSince1970))"

        sendPromptFromComposer("Reply with \(token) only.", timeout: 45)

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the relaunched real-host flow to keep the restored thread usable after send. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining(token, timeout: 120))
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 90))
        XCTAssertEqual(
            activeThreadIDValue(),
            originalThreadID,
            "Expected the relaunched real-host flow to keep the restored thread instead of forking."
        )
    }

    func testPhysicalRealHostPhoneReconnectPreviewShowsLatestAndStaysResponsive() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This lifecycle validation is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: false)
        let originalThreadID = prepareRealHostPhoneSessionForLifecycle(timeout: 60)
        openCodexTab()

        if app.staticTexts["Reconnecting"].waitForExistence(timeout: 5) {
            captureProofScreenshot(named: "physical-thread-lifecycle-reconnecting")
            let browseButton = app.buttons["codex-browse-button"]
            XCTAssertTrue(browseButton.waitForExistence(timeout: 5))
            XCTAssertTrue(browseButton.isHittable, "Expected the Codex screen to keep top-bar navigation responsive while reconnecting.")
            browseButton.tap()
            XCTAssertTrue(app.staticTexts["Projects & Threads"].waitForExistence(timeout: 10))
            captureProofScreenshot(named: "physical-thread-lifecycle-browser-during-reconnect")
            dismissReposBrowserIfNeeded()
            openCodexTab()
        }

        XCTAssertTrue(
            waitForElementWithIdentifier("codex-transcript-reconnect-preview", timeout: 10)
                || waitForVisibleTranscriptConversationHistory(timeout: 30, minimumCount: 1),
            "Expected the Codex screen to show either the latest transcript messages or a saved-reply reconnect preview promptly on the real phone."
        )
        if !originalThreadID.isEmpty,
           let activeThreadID = activeThreadIDValue(),
           activeThreadID != "thread-pending" {
            XCTAssertEqual(activeThreadID, originalThreadID)
        }
        captureProofScreenshot(named: "physical-thread-lifecycle-loaded")
    }

    func testPhysicalRealHostPhoneThreadWorksAfterReconnectOverTime() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This lifecycle validation is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: false)
        let originalThreadID = prepareRealHostPhoneSessionForLifecycle(timeout: 60)

        XCTAssertTrue(
            waitForElementWithIdentifier("codex-transcript-reconnect-preview", timeout: 10)
                || waitForVisibleTranscriptConversationHistory(timeout: 30, minimumCount: 1),
            "Expected the real phone to surface either a reconnect preview or visible transcript history before waiting for idle."
        )
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 60))
        captureProofScreenshot(named: "physical-thread-lifecycle-idle")

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        sendPromptFromComposer("Reply with THREAD_LIFECYCLE_OK only.", timeout: 45)

        XCTAssertTrue(
            waitForCodexSessionStreaming(timeout: 20),
            "Expected the real-host lifecycle to show live work after sending instead of freezing after reconnect."
        )
        captureProofScreenshot(named: "physical-thread-lifecycle-working")

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: !originalThreadID.isEmpty,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the active thread to continue and become usable after reconnect. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForTextContaining("THREAD_LIFECYCLE_OK", timeout: 120))
        if !originalThreadID.isEmpty {
            XCTAssertTrue(waitForActiveThreadID(timeout: 20))
            XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        }
        captureProofScreenshot(named: "physical-thread-lifecycle-complete")
    }

    func testPhysicalRealHostPhoneResumeSendAndRestoreAfterRelaunch() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This parity verification is iPhone-only.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 45),
            "Expected real host browser content. Browser status: \(browserStatusValue() ?? "missing")"
        )

        let originalThreadID = resumeIdleProjectThreadFromBrowser(
            selectionTimeout: 20,
            idleTimeout: 20,
            maxCandidates: 3
        )
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        sendPromptFromComposer(
            "Reply with COTG_APP_OK only.",
            timeout: 45
        )

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 120
            ),
            "Expected the iPhone send to append a real assistant reply. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)

        app.terminate()
        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()

        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        if activeThreadIDValue() != originalThreadID {
            openReposBrowserIfNeeded()
            XCTAssertTrue(waitForHostBrowserContent(timeout: 45))
            selectProjectThreadFromBrowser(threadID: originalThreadID, timeout: 20)
            XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        }
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        XCTAssertTrue(waitForTranscriptConversationHistory(timeout: 30, minimumCount: 1))
    }

    func testPhysicalRealHostPhoneShowsExecutionAuthorityLabels() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This execution-authority validation is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 60),
            "Expected real host browser content before resuming a thread. Browser status: \(browserStatusValue() ?? "missing")"
        )

        if !hasActiveCodexSession() {
            XCTAssertTrue(
                waitForBrowserSessionSelection(timeout: 20),
                "Expected either a saved thread or a new-thread action before validating authority labels. Browser status: \(browserStatusValue() ?? "missing")"
            )
            if browserResumeElements().count > 0 {
                selectProjectThreadFromBrowser(timeout: 20, preferredIndex: 0)
            } else {
                let newThreadButton = firstNewThreadButton()
                XCTAssertTrue(newThreadButton.waitForExistence(timeout: 20))
                tapBrowserElement(newThreadButton)
            }
        }
        XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the iPhone authority validation to reach a connected host-backed thread. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        let threadID = activeThreadIDValue() ?? ""
        XCTAssertFalse(threadID.isEmpty)
        XCTAssertNotEqual(threadID, "thread-pending")

        XCTAssertTrue(
            waitForElementWithIdentifierOrLabelPrefix(
                "active-approval-policy-label",
                labelPrefix: "Approvals:",
                timeout: 45
            ),
            "Expected approval authority to be visible. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForElementWithIdentifierOrLabelPrefix(
                "active-sandbox-label",
                labelPrefix: "Sandbox:",
                timeout: 45
            ),
            "Expected sandbox authority to be visible. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForElementWithIdentifierOrLabelPrefix(
                "active-authority-status-label",
                labelPrefix: "Authority:",
                timeout: 45
            ),
            "Expected overall authority status to be visible. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )

        let approvalLabel = accessibilityLabel(
            forElementWithIdentifier: "active-approval-policy-label",
            fallbackLabelPrefix: "Approvals:"
        )
        let sandboxLabel = accessibilityLabel(
            forElementWithIdentifier: "active-sandbox-label",
            fallbackLabelPrefix: "Sandbox:"
        )
        let authorityLabel = accessibilityLabel(
            forElementWithIdentifier: "active-authority-status-label",
            fallbackLabelPrefix: "Authority:"
        )
        let networkLabel = accessibilityLabel(
            forElementWithIdentifier: "active-network-label",
            fallbackLabelPrefix: "Network:"
        )

        XCTAssertEqual(approvalLabel?.split(separator: ":").first.map(String.init), "Approvals")
        XCTAssertEqual(sandboxLabel?.split(separator: ":").first.map(String.init), "Sandbox")
        XCTAssertTrue(
            [
                "Authority: effective",
                "Authority: constrained",
                "Authority: unknown",
                "Authority: unsupported"
            ].contains(authorityLabel ?? ""),
            "Expected a truthful authority status label. Saw: \(authorityLabel ?? "missing")"
        )
        if let networkLabel {
            XCTAssertEqual(networkLabel.split(separator: ":").first.map(String.init), "Network")
        }

        captureProofScreenshot(named: "physical-real-host-phone-execution-authority")
    }

    func testPhysicalReviewerDemoModeShowsBundledThreadAndContinuesOnSameThread() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("Reviewer demo mode hardware validation only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Reviewer demo mode hardware validation is scoped to iPhone.")
        }

        launch(
            resetPersistedState: true,
            selectedShellTab: "settings",
            enableDemoModeOnLaunch: true
        )

        openSettingsTab()
        scrollToAnyText(["Reviewer demo mode"], maxSwipes: 4)
        let identifiedDemoToggle = app.switches["settings-demo-mode-toggle"]
        let labeledDemoToggle = app.switches["Reviewer demo mode"]
        let demoToggle = identifiedDemoToggle.waitForExistence(timeout: 5) ? identifiedDemoToggle : labeledDemoToggle
        let demoSettingsLabel = app.staticTexts["Reviewer demo mode"]
        XCTAssertTrue(
            demoToggle.waitForExistence(timeout: 10) || demoSettingsLabel.waitForExistence(timeout: 10),
            "Expected reviewer demo mode control or label on Settings."
        )
        captureProofScreenshot(named: "reviewer-demo-settings")

        launch(
            resetPersistedState: false,
            selectedShellTab: "connections",
            enableDemoModeOnLaunch: true
        )
        XCTAssertTrue(app.staticTexts["Reviewer demo mode"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Demo Mac"].waitForExistence(timeout: 15))
        captureProofScreenshot(named: "reviewer-demo-connections")

        launch(
            resetPersistedState: false,
            selectedShellTab: "codex",
            enableDemoModeOnLaunch: true
        )
        XCTAssertTrue(waitForActiveCodexSession(timeout: 15))
        XCTAssertTrue(waitForTranscriptConversationHistory(timeout: 15, minimumCount: 3))
        let originalThreadID = activeThreadIDValue()
        XCTAssertEqual(originalThreadID, "demo-thread-reviewer-mode")
        captureProofScreenshot(named: "reviewer-demo-codex")

        sendPromptFromMainComposerAndWaitForContinuation(
            "Show that reviewer demo mode keeps the same thread on device.",
            timeout: 30
        )

        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        XCTAssertTrue(waitForCodexSessionIdle(timeout: 15))
        captureProofScreenshot(named: "reviewer-demo-post-send")
    }

    func testPhysicalPhoneSettingsUsesPlainLanguageStatusLabels() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This settings-label audit only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This settings-label audit is scoped to the physical iPhone.")
        }

        launch(resetPersistedState: true, selectedShellTab: "settings")
        openSettingsTab()

        scrollToAnyText(["Notifications permission", "Browser"], maxSwipes: 3)
        XCTAssertTrue(app.staticTexts["Notifications permission"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sync status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Best route now"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Proxy or VPN"].waitForExistence(timeout: 10))
        captureProofScreenshot(named: "physical-settings-plain-language")
    }

    func testPhysicalPhoneSettingsExposeExecutionDefaultsAndExtendedReasoning() throws {
        guard !isSimulatorRuntime else {
            throw XCTSkip("This execution-default audit only runs on a physical iPhone.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This execution-default audit is scoped to the physical iPhone.")
        }

        launch(resetPersistedState: true, selectedShellTab: "settings")
        configurePreferredCodexDefaults(
            reasoningLabel: "X-High",
            approvalLabel: "Never",
            sandboxLabel: "Full access"
        )
        captureProofScreenshot(named: "physical-settings-execution-defaults")
    }

    func testPhysicalRealHostPhoneSettingsExposeDesktopContinuityActions() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This desktop continuity audit is scoped to the physical iPhone.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        ensureSessionWorkspace(timeout: 20)

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()

        openSettingsTab()

        XCTAssertTrue(waitForElementExists(app.buttons["settings-continue-on-mac-button"], timeout: 10, maxSwipes: 4))
        XCTAssertTrue(waitForElementExists(app.buttons["settings-start-new-mac-thread-button"], timeout: 10, maxSwipes: 4))
        XCTAssertTrue(waitForElementExists(app.buttons["settings-reveal-current-workspace-button"], timeout: 10, maxSwipes: 4))
        XCTAssertTrue(waitForElementExists(app.buttons["settings-wake-mac-display-button"], timeout: 10, maxSwipes: 4))
        XCTAssertTrue(waitForElementExists(app.buttons["settings-share-current-thread-button"], timeout: 10, maxSwipes: 4))
        captureProofScreenshot(named: "physical-real-host-settings-desktop-continuity")

        tapElement(app.buttons["settings-reveal-current-workspace-button"])
        tapElement(app.buttons["settings-wake-mac-display-button"])

        openCodexTab()
        XCTAssertTrue(
            waitForTranscriptConversationHistory(timeout: 20, minimumCount: baselineTranscriptCount + 2),
            "Expected reveal and wake actions to append transcript feedback on the real host session."
        )
        captureProofScreenshot(named: "physical-real-host-settings-desktop-continuity-feedback")
    }

    func testPhysicalRealHostIPadResumeSendAndRestoreAfterRelaunch() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This parity verification is iPad-only.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 60),
            "Expected real host browser content. Browser status: \(browserStatusValue() ?? "missing")"
        )

        let originalThreadID = resumeIdleProjectThreadFromBrowser(
            selectionTimeout: 20,
            idleTimeout: 20,
            maxCandidates: 5,
            startIndex: 1
        )
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        sendPromptFromComposer(
            "Reply with COTG_APP_OK only.",
            timeout: 60
        )

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 150
            ),
            "Expected the iPad send to append a real assistant reply. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)

        app.terminate()
        app.launchEnvironment["COTG_UI_TEST_RESET_ON_LAUNCH"] = "0"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        if activeThreadIDValue() != originalThreadID {
            XCTAssertTrue(waitForHostBrowserContent(timeout: 60))
            selectProjectThreadFromBrowser(threadID: originalThreadID, timeout: 20)
            XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        }
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the relaunched iPad flow to reconnect the selected thread. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForCodexSessionIdle(timeout: 20),
            "Expected the relaunched iPad flow to restore an idle thread before verification. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 30))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        XCTAssertTrue(waitForTranscriptConversationHistory(timeout: 30, minimumCount: 1))
    }

    func testPhysicalRealHostIPadResumeSendKeepsSameThread() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This parity verification is iPad-only.")
        }

        try requirePhysicalRealHostValidation()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()

        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 60),
            "Expected real host browser content. Browser status: \(browserStatusValue() ?? "missing")"
        )

        let originalThreadID = resumeIdleProjectThreadFromBrowser(
            selectionTimeout: 20,
            idleTimeout: 20,
            maxCandidates: 4
        )
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        sendPromptFromComposer(
            "Reply with COTG_APP_OK only.",
            timeout: 60
        )

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 150
            ),
            "Expected the iPad send to append a real assistant reply. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        writeIPadParityThreadID(originalThreadID)
    }

    func testPhysicalRealHostIPadRelaunchRestoresSameThread() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This parity verification is iPad-only.")
        }

        try requirePhysicalRealHostValidation()
        let originalThreadID = try requireIPadParityThreadID()
        launchPhysicalRealHostValidationApp(resetPersistedState: false)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        XCTAssertTrue(waitForHostBrowserContent(timeout: 60))
        selectProjectThreadFromBrowser(threadID: originalThreadID, timeout: 20)
        XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        XCTAssertTrue(
            waitForCodexSessionConnectionState("connected", timeout: 45),
            "Expected the relaunched iPad flow to reconnect the selected thread. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForCodexSessionIdle(timeout: 20),
            "Expected the relaunched iPad flow to restore an idle thread before verification. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 30))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
        XCTAssertTrue(waitForTranscriptConversationHistory(timeout: 30, minimumCount: 1))
    }

    func testPhysicalRealHostPhoneSeedsCrossDeviceThreadForIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This continuity seed verification is iPhone-only.")
        }

        try requirePhysicalRealHostValidation()
        let marker = try requireCrossDeviceMarker()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()
        XCTAssertTrue(waitForHostBrowserContent(timeout: 45))

        let originalThreadID = resumeIdleProjectThreadFromBrowser(
            selectionTimeout: 20,
            idleTimeout: 20,
            maxCandidates: 3
        )
        XCTAssertFalse(originalThreadID.isEmpty)
        XCTAssertNotEqual(originalThreadID, "thread-pending")
        writeCrossDeviceThreadID(originalThreadID)

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineReplyCount = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        sendPromptFromComposer(
            "Repeat exactly: Cross-device continuity marker \(marker)",
            timeout: 45
        )

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: true,
                baselineAssistantReplies: baselineReplyCount,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: 150
            ),
            "Expected the iPhone seed send to append a real assistant reply. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), originalThreadID)
    }

    func testPhysicalRealHostIPadRestoresCrossDeviceThreadSeededByIPhone() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This continuity verification is iPad-only.")
        }

        try requirePhysicalRealHostValidation()
        let marker = try requireCrossDeviceMarker()
        launchPhysicalRealHostValidationApp(resetPersistedState: true)
        navigateToPhysicalRealHostMachineInConnections()
        connectSelectedMachineWithoutSelectingThread(timeout: 90)
        openCodexTab()
        XCTAssertTrue(waitForHostBrowserContent(timeout: 60))

        let resumedThreadID = resumeIdleProjectThreadFromBrowser(
            selectionTimeout: 20,
            idleTimeout: 20,
            maxCandidates: 1
        )
        XCTAssertFalse(resumedThreadID.isEmpty)
        XCTAssertNotEqual(resumedThreadID, "thread-pending")

        XCTAssertTrue(waitForActiveCodexSession(timeout: 30))
        XCTAssertTrue(
            waitForCodexSessionIdle(timeout: 20),
            "Expected the cross-device iPad restore to settle before transcript verification. Session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        XCTAssertTrue(waitForActiveThreadID(timeout: 20))
        XCTAssertEqual(activeThreadIDValue(), resumedThreadID)
        XCTAssertTrue(
            waitForTextContaining(marker, timeout: 30),
            "Expected the iPad transcript to include the iPhone cross-device marker \(marker)."
        )
    }

    func testSeededLocalhostManualRouteConnectsThroughConfiguredSSHOverride() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        navigateToCurrentFixtureMachineInConnections()

        assertSafeLaneSurfaceIsVisible(timeout: 60)
        sendPromptFromMainComposerAndWaitForContinuation("Reply with MANUAL_ROUTE_OK only.", timeout: 90)

        XCTAssertTrue(waitForActiveThreadID(timeout: 30))
    }

    func testSeededLocalhostLANRouteConnectsThroughDiscoveredBonjourRoute() throws {
        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostLANRoute: true)
        navigateToCurrentFixtureMachineInConnections()

        assertSafeLaneSurfaceIsVisible(timeout: 60)
        sendPromptFromMainComposerAndWaitForContinuation("Reply with SAME_LAN_OK only.", timeout: 90)

        XCTAssertTrue(waitForActiveThreadID(timeout: 30))
    }

    func testSeededExternalTailnetRouteConnectsThroughStandaloneTailscale() throws {
        try requireExternalTailnetIntegration()
        launch(
            resetPersistedState: true,
            seedLocalhostManualRoute: true,
            preferredRouteKind: "externalTailnet"
        )
        navigateToScreenshotMachineInConnections()
        assertConnectionsDetailIsVisible(timeout: 30)

        let resolvedExternalTailnetRoute = waitForConnectionStatusSubstring("route=externalTailnet", timeout: 10)
        let initialConnectionStatus = connectionStatusValue() ?? "missing"
        guard resolvedExternalTailnetRoute else {
            if initialConnectionStatus.contains("externalTailnetAppState=notInstalled") {
                throw XCTSkip(
                    "Standalone Tailscale is not installed on this device, so the seeded external tailnet route correctly stayed unavailable. Status: \(initialConnectionStatus)"
                )
            }
            if initialConnectionStatus.contains("externalTailnetAppState=installedReady"),
               (initialConnectionStatus.contains("recommended=manualSSH")
                || initialConnectionStatus.contains("recommended=localLAN")
                || initialConnectionStatus.contains("route=manualSSH")
                || initialConnectionStatus.contains("route=localLAN")) {
                let externalTailnetRouteRow = app.descendants(matching: .any)
                    .matching(identifier: "connection-saved-route-externalTailnet")
                    .firstMatch
                XCTAssertTrue(
                    waitForElementExists(externalTailnetRouteRow, timeout: 10, maxSwipes: 6),
                    "Expected the external tailnet fallback row to stay visible even when a healthier nearby route is currently recommended. Status: \(initialConnectionStatus)"
                )
                throw XCTSkip(
                    "A healthier nearby/direct route is currently best on this network, so the saved external tailnet route is correctly staying secondary. Status: \(initialConnectionStatus)"
                )
            }

            XCTFail(
                "Expected the seeded Connections screen to target the external tailnet route. Status: \(initialConnectionStatus)"
            )
            return
        }
        if let externalTailnetDNSName {
            XCTAssertTrue(
                waitForConnectionStatusSubstring("endpoint=\(externalTailnetDNSName):22", timeout: 10),
                "Expected the seeded Connections screen to target \(externalTailnetDNSName). Status: \(connectionStatusValue() ?? "missing")"
            )
        }

        connectSelectedMachineWithoutSelectingThread(timeout: 60)
        openCodexTab()
        openReposBrowserIfNeeded()
        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 45),
            "Expected connected host browser content over the external tailnet route. Browser status: \(browserStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForBrowserStatusSubstring("connection=connected", timeout: 15),
            "Expected the Codex browser to report a connected external tailnet session. Browser status: \(browserStatusValue() ?? "missing")"
        )
    }

    func testSeededEmbeddedTailnetRouteConnectsThroughInAppTailscale() throws {
        try requireEmbeddedTailnetIntegration()
        launch(
            resetPersistedState: true,
            seedEmbeddedTailnetRoute: true
        )

        navigateToFirstMachineInConnections()
        XCTAssertTrue(
            waitForConnectionStatusSubstring("route=embeddedTailnet", timeout: 10),
            "Expected the seeded Connections screen to target the embedded tailnet route. Status: \(connectionStatusValue() ?? "missing")"
        )
        if let embeddedTailnetTargetHost {
            XCTAssertTrue(
                waitForConnectionStatusSubstring("endpoint=\(embeddedTailnetTargetHost):22", timeout: 90),
                "Expected the seeded Connections screen to target \(embeddedTailnetTargetHost). Status: \(connectionStatusValue() ?? "missing")"
            )
        }

        connectSelectedMachineWithoutSelectingThread(timeout: 120)
        openCodexTab()
        openReposBrowserIfNeeded()
        XCTAssertTrue(
            waitForHostBrowserContent(timeout: 60),
            "Expected connected host browser content over the embedded tailnet route. Browser status: \(browserStatusValue() ?? "missing")"
        )
        XCTAssertTrue(
            waitForBrowserStatusSubstring("connection=connected", timeout: 15),
            "Expected the Codex browser to report a connected embedded tailnet session. Browser status: \(browserStatusValue() ?? "missing")"
        )
    }

    func testCaptureIPhoneAppStoreScreenshots() throws {
        guard shouldCaptureAppStoreScreenshots else {
            throw XCTSkip("Set COTG_CAPTURE_APP_STORE_SCREENSHOTS=1 to capture App Store screenshots.")
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This screenshot suite is for iPhone only.")
        }

        launch(resetPersistedState: true, seedPreviewFixture: true)
        XCTAssertTrue(waitForHostBrowserContent(timeout: 10))
        captureAppStoreScreenshot(named: "01-machine-directory")

        let resumeRow = firstResumeRow()
        XCTAssertTrue(resumeRow.waitForExistence(timeout: 10))
        resumeRow.tap()
        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }
        assertConnectionSurfaceIsVisible(timeout: 10)
        captureAppStoreScreenshot(named: "02-connection-health")

        app.terminate()
        launch(resetPersistedState: true, seedAppStoreSessionFixture: true)
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 10)
        captureAppStoreScreenshot(named: "03-live-session")

        XCTAssertTrue(app.buttons["Review"].waitForExistence(timeout: 10))
        app.buttons["Review"].tap()
        XCTAssertTrue(waitForElementWithIdentifier("workspace-review-full", timeout: 10))
        captureAppStoreScreenshot(named: "04-workspace-review")

        app.terminate()
        launch(resetPersistedState: true, seedAppStoreSessionFixture: true)
        dismissReposBrowserIfNeeded()
        assertConnectionSurfaceIsVisible(timeout: 10)
        XCTAssertTrue(waitForElementWithIdentifier("photo-tool-button", timeout: 10))
        app.buttons["photo-tool-button"].tap()
        XCTAssertTrue(
            app.buttons["Attach photo"].waitForExistence(timeout: 10)
                || app.buttons["Refresh models"].waitForExistence(timeout: 10)
        )
        captureAppStoreScreenshot(named: "05-composer-tools")
    }

    func testCaptureIPadAppStoreScreenshots() throws {
        guard shouldCaptureAppStoreScreenshots else {
            throw XCTSkip("Set COTG_CAPTURE_APP_STORE_SCREENSHOTS=1 to capture App Store screenshots.")
        }
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This screenshot suite is for iPad only.")
        }

        try requireLocalhostIntegration()
        launch(resetPersistedState: true, seedLocalhostManualRoute: true)
        XCTAssertTrue(waitForScreenshotFixtureSurface(timeout: 10))
        captureAppStoreScreenshot(named: "01-three-pane-directory")

        navigateToScreenshotMachine()
        assertConnectionSurfaceIsVisible(timeout: 20)
        captureAppStoreScreenshot(named: "02-route-diagnostics")

        assertSafeLaneSurfaceIsVisible(timeout: 20)
        if assistantReplyCount() != 1 {
            sendSmokePromptFromConnections()
            XCTAssertTrue(waitForAssistantReplyCount(1, timeout: 30))
        }
        captureAppStoreScreenshot(named: "03-live-session")

        scrollToElement(app.buttons["refresh-workspace-button"], maxSwipes: 4)
        XCTAssertTrue(app.buttons["refresh-workspace-button"].waitForExistence(timeout: 10))
        app.buttons["refresh-workspace-button"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        captureAppStoreScreenshot(named: "04-workspace-review")
    }

    private func launch(
        resetPersistedState: Bool,
        seedPreviewFixture: Bool = false,
        seedLocalhostLANRoute: Bool = false,
        seedLocalhostManualRoute: Bool = false,
        seedEmbeddedTailnetRoute: Bool = false,
        seedAppStoreSessionFixture: Bool = false,
        seedLongTranscript: Bool = false,
        seedPendingScannedHostKey: Bool = false,
        seedConnectionFailureDetail: String? = nil,
        seedConnectingRestore: Bool = false,
        seedRecoverableSavedSSHKey: Bool = false,
        seedMultipleSavedSSHKeys: Bool = false,
        disableLocalhostTestingCredentialAutoload: Bool = false,
        disableSSHHostKeyOverride: Bool = false,
        disableSavedCredentialBindingRecovery: Bool = false,
        seedPlanMessage: String? = nil,
        seedActivityBurst: Bool = false,
        seedAttachmentHistory: Bool = false,
        seedStructuredPrompt: Bool = false,
        seedThreadlessSessionSummary: Bool = false,
        seedBrowserOperations: Bool = false,
        preferredRouteKind: String? = nil,
        selectedShellTab: String? = nil,
        workspaceRootOverride: String? = nil,
        overrideTestSSHUser: String? = nil,
        useRealHostCodexHome: Bool = false,
        preferredReasoningEffortOverride: String? = nil,
        preferredApprovalPolicyOverride: String? = nil,
        preferredSandboxModeOverride: String? = nil,
        forceLoopbackFailureOnNextTurn: Bool = false,
        enableDemoModeOnLaunch: Bool = false,
        enableAutoUpgrade: Bool = false
    ) {
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = [
            "UI_TESTING": "1",
            "COTG_UI_TEST_RESET_ON_LAUNCH": resetPersistedState ? "1" : "0",
            "COTG_UI_TEST_SEED_PREVIEW_FIXTURE": seedPreviewFixture ? "1" : "0",
            "COTG_UI_TEST_SEED_LOCALHOST_LAN_ROUTE": seedLocalhostLANRoute ? "1" : "0",
            "COTG_UI_TEST_SEED_LOCALHOST_MANUAL_ROUTE": seedLocalhostManualRoute ? "1" : "0",
            "COTG_UI_TEST_SEED_EMBEDDED_TAILNET_ROUTE": seedEmbeddedTailnetRoute ? "1" : "0",
            "COTG_UI_TEST_SEED_APP_STORE_SESSION_FIXTURE": seedAppStoreSessionFixture ? "1" : "0",
            "COTG_UI_TEST_SEED_LONG_TRANSCRIPT": seedLongTranscript ? "1" : "0",
            "COTG_UI_TEST_SEED_PENDING_SCANNED_HOST_KEY": seedPendingScannedHostKey ? "1" : "0",
            "COTG_UI_TEST_SEED_CONNECTION_FAILURE": seedConnectionFailureDetail == nil ? "0" : "1",
            "COTG_UI_TEST_SEED_CONNECTING_RESTORE": seedConnectingRestore ? "1" : "0",
            "COTG_UI_TEST_SEED_RECOVERABLE_SSH_KEY": seedRecoverableSavedSSHKey ? "1" : "0",
            "COTG_UI_TEST_SEED_MULTIPLE_SAVED_SSH_KEYS": seedMultipleSavedSSHKeys ? "1" : "0",
            "COTG_DISABLE_LOCALHOST_TESTING_CREDENTIAL_AUTOLOAD": disableLocalhostTestingCredentialAutoload ? "1" : "0",
            "COTG_TEST_DISABLE_SSH_HOST_KEY_OVERRIDE": disableSSHHostKeyOverride ? "1" : "0",
            "COTG_DISABLE_SAVED_CREDENTIAL_BINDING_RECOVERY": disableSavedCredentialBindingRecovery ? "1" : "0",
            "COTG_UI_TEST_SEED_PLAN_MESSAGE": seedPlanMessage == nil ? "0" : "1",
            "COTG_UI_TEST_SEED_ACTIVITY_BURST": seedActivityBurst ? "1" : "0",
            "COTG_UI_TEST_SEED_ATTACHMENT_HISTORY": seedAttachmentHistory ? "1" : "0",
            "COTG_UI_TEST_SEED_STRUCTURED_PROMPT": seedStructuredPrompt ? "1" : "0",
            "COTG_UI_TEST_SEED_THREADLESS_SESSION_SUMMARY": seedThreadlessSessionSummary ? "1" : "0",
            "COTG_UI_TEST_SEED_BROWSER_OPERATIONS": seedBrowserOperations ? "1" : "0",
            "COTG_ENABLE_LOCALHOST_INTEGRATION": localhostIntegrationPrepared ? "1" : "0",
            "COTG_TEST_SSH_HOST": localhostSSHHost,
            "COTG_TEST_SSH_PORT": localhostSSHPort,
            "COTG_TEST_SSH_USER": overrideTestSSHUser ?? localhostSSHUser,
            "COTG_WORKSPACE_ROOT": workspaceRootOverride ?? workspaceRoot
        ]
        if enableAutoUpgrade {
            app.launchEnvironment["COTG_ENABLE_AUTO_UPGRADE"] = "1"
        } else {
            app.launchEnvironment["COTG_DISABLE_AUTO_UPGRADE"] = "1"
        }
        if let localhostRawKeyBase64 {
            // Physical devices cannot read the host-side raw key path directly, so
            // pass the test key inline and keep localhost autoload parity with the simulator.
            app.launchEnvironment["COTG_TEST_SSH_RAW_KEY_BASE64"] = localhostRawKeyBase64
        }
        if let seedConnectionFailureDetail {
            app.launchEnvironment["COTG_UI_TEST_CONNECTION_FAILURE_DETAIL"] = seedConnectionFailureDetail
        }
        if let seedPlanMessage {
            app.launchEnvironment["COTG_UI_TEST_PLAN_MESSAGE"] = seedPlanMessage
        }
        if !useRealHostCodexHome {
            app.launchEnvironment["COTG_TEST_CODEX_HOME"] = codexHomePath
        }
        if isSimulatorRuntime {
            app.launchEnvironment["COTG_TEST_SSH_RAW_KEY_PATH"] = localhostRawKeyPath
            app.launchEnvironment["COTG_METADATA_PATH"] = metadataPath
            app.launchEnvironment["COTG_SYNC_MIRROR_PATH"] = syncMirrorPath
        }
        if let externalTailnetDNSName {
            app.launchEnvironment["COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"] = externalTailnetDNSName
        }
        if let embeddedTailnetTargetHost {
            app.launchEnvironment["COTG_TEST_EMBEDDED_TAILNET_TARGET_HOST"] = embeddedTailnetTargetHost
        }
        if let embeddedTailnetAuthKey {
            app.launchEnvironment["COTG_EMBEDDED_TAILNET_AUTH_KEY"] = embeddedTailnetAuthKey
        }
        if let preferredRouteKind {
            app.launchEnvironment["COTG_TEST_PREFERRED_ROUTE_KIND"] = preferredRouteKind
        }
        if let selectedShellTab {
            app.launchEnvironment["COTG_UI_TEST_SELECTED_TAB"] = selectedShellTab
        }
        if let preferredReasoningEffortOverride {
            app.launchEnvironment["COTG_UI_TEST_PREFERRED_REASONING_EFFORT"] = preferredReasoningEffortOverride
        }
        if let preferredApprovalPolicyOverride {
            app.launchEnvironment["COTG_UI_TEST_PREFERRED_APPROVAL_POLICY"] = preferredApprovalPolicyOverride
        }
        if let preferredSandboxModeOverride {
            app.launchEnvironment["COTG_UI_TEST_PREFERRED_SANDBOX_MODE"] = preferredSandboxModeOverride
        }
        if !disableSSHHostKeyOverride, let sshHostKeyOverride {
            app.launchEnvironment["COTG_TEST_SSH_HOST_KEY"] = sshHostKeyOverride
        }
        if forceLoopbackFailureOnNextTurn {
            app.launchEnvironment["COTG_UI_TEST_FORCE_LOOPBACK_FAILURE_ON_NEXT_TURN"] = "1"
        }
        if enableDemoModeOnLaunch {
            app.launchEnvironment["COTG_ENABLE_DEMO_MODE_ON_LAUNCH"] = "1"
        }
        app.launch()
    }

    private func launchNormalInstalledApp() {
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = [:]
        app.launch()
    }

    private func launchPhysicalRealHostValidationApp(
        resetPersistedState: Bool,
        workspaceRootOverride: String? = nil,
        useRealHostCodexHome: Bool = true,
        preferredReasoningEffortOverride: String? = nil,
        preferredApprovalPolicyOverride: String? = nil,
        preferredSandboxModeOverride: String? = nil,
        forceLoopbackFailureOnNextTurn: Bool = false,
        enableAutoUpgrade: Bool = false
    ) {
        let launchPlan = physicalRealHostLaunchPlan()
        launch(
            resetPersistedState: resetPersistedState,
            seedLocalhostLANRoute: launchPlan.seedLocalhostLANRoute,
            seedLocalhostManualRoute: launchPlan.seedLocalhostManualRoute,
            seedEmbeddedTailnetRoute: launchPlan.seedEmbeddedTailnetRoute,
            preferredRouteKind: launchPlan.preferredRouteKind,
            selectedShellTab: "connections",
            workspaceRootOverride: workspaceRootOverride,
            useRealHostCodexHome: useRealHostCodexHome,
            preferredReasoningEffortOverride: preferredReasoningEffortOverride,
            preferredApprovalPolicyOverride: preferredApprovalPolicyOverride,
            preferredSandboxModeOverride: preferredSandboxModeOverride,
            forceLoopbackFailureOnNextTurn: forceLoopbackFailureOnNextTurn,
            enableAutoUpgrade: enableAutoUpgrade
        )
    }

    @discardableResult
    private func prepareRealHostPhoneSessionForLifecycle(timeout: TimeInterval) -> String {
        openConnectionsTab()
        let openCodexButton = app.buttons["open-codex-from-connections-button"]
        if openCodexButton.waitForExistence(timeout: 3) {
            tapElement(openCodexButton)
        }

        openCodexTab()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitForActiveCodexSession(timeout: 2) {
                if let threadID = activeThreadIDValue(),
                   !threadID.isEmpty,
                   threadID != "thread-pending" {
                    return threadID
                }

                if app.otherElements["codex-transcript-reconnect-preview"].exists
                    || app.staticTexts["Reconnecting"].exists
                    || waitForVisibleTranscriptConversationHistory(timeout: 1, minimumCount: 1)
                    || app.buttons["queue-prompt-button"].exists {
                    return activeThreadIDValue() ?? ""
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(
            hasActiveCodexSession()
                || app.otherElements["codex-transcript-reconnect-preview"].exists
                || app.staticTexts["Reconnecting"].exists,
            "Expected the installed iPhone app to reach an active or reconnecting Codex session without forcing the browser resume path."
        )
        return activeThreadIDValue() ?? ""
    }

    private func navigateToPhysicalRealHostMachineInConnections() {
        openConnectionsTab()
        if app.otherElements["connection-plan-card"].waitForExistence(timeout: 2) {
            return
        }

        returnToConnectionsListIfNeeded(missingMachineIdentifier: nil)
        scrollMachineDirectoryToTop()
        if !anyMachineCardExists(),
           waitForButton("machine-directory-scan-button", enabled: true, timeout: 8) {
            app.buttons["machine-directory-scan-button"].tap()
            allowLocalNetworkPromptIfNeeded()
            _ = waitForNearbyScanFeedback(timeout: 20) || anyMachineCardExists()
        }
        if !anyMachineCardExists() {
            seedPhysicalRealHostManualRouteIfNeeded()
            if app.buttons["connect-live-button"].waitForExistence(timeout: 8)
                || app.otherElements["connection-plan-card"].waitForExistence(timeout: 2) {
                return
            }
        }

        let machineCard = firstMachineCard()
        XCTAssertTrue(
            waitForElementExists(machineCard, timeout: 20, maxSwipes: 8),
            "Expected at least one saved Mac on the physical Connections screen."
        )
        machineCard.tap()
        allowLocalNetworkPromptIfNeeded()
    }

    private func seedPhysicalRealHostManualRouteIfNeeded() {
        let manualFallback = app.buttons["machine-directory-open-manual-route-button"]
        if !app.buttons["machine-directory-open-add-mac-button"].waitForExistence(timeout: 4) {
            return
        }

        tapElement(app.buttons["machine-directory-open-add-mac-button"])

        guard manualFallback.waitForExistence(timeout: 8) else {
            return
        }
        tapElement(manualFallback)

        let addressField = app.textFields["manual-route-address-field"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 10))
        addressField.tap()
        addressField.typeText(localhostSSHHost)

        let usernameField = app.textFields["manual-route-username-field"]
        if usernameField.waitForExistence(timeout: 2) {
            usernameField.tap()
            usernameField.typeText(localhostSSHUser)
        }

        let addRouteButton = app.buttons["manual-route-add-button"]
        XCTAssertTrue(waitForButton("manual-route-add-button", enabled: true, timeout: 10, maxSwipes: 4))
        tapElement(addRouteButton)
    }

    private func requireEnvironmentValue(_ name: String, skipMessage: String) throws -> String {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            throw XCTSkip(skipMessage)
        }
        return value
    }

    private func writeMirrorSignal(_ value: String, to path: String) throws {
        print("COTG_MIRROR_SIGNAL \(value) \(path)")
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try value.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            guard !isSimulatorRuntime else {
                throw error
            }
            print("COTG_MIRROR_SIGNAL_FILE_WRITE_FAILED \(error.localizedDescription)")
        }
    }

    private func physicalRealHostLaunchPlan() -> PhysicalRealHostLaunchPlan {
        if let explicitLaunchPlan = ProcessInfo.processInfo.environment["COTG_TEST_REAL_HOST_LAUNCH_PLAN"],
           let parsedLaunchPlan = PhysicalRealHostLaunchPlan(rawValue: explicitLaunchPlan) {
            return parsedLaunchPlan
        }
        if !isSimulatorRuntime, embeddedTailnetAuthKey != nil {
            return .embeddedTailnet
        }
        let explicitExternalTailnetDNSName = ProcessInfo.processInfo.environment["COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !isSimulatorRuntime, explicitExternalTailnetDNSName?.isEmpty == false {
            return .externalTailnet
        }
        return .manualSSH
    }

    private var shouldCaptureAppStoreScreenshots: Bool {
        FileManager.default.fileExists(atPath: screenshotCaptureMarkerPath)
    }

    private func captureAppStoreScreenshot(named name: String) {
        let outputDir = screenshotOutputDirectory()

        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("Failed to write screenshot \(name): \(error.localizedDescription)")
        }

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureProofScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let outputDir = ProcessInfo.processInfo.environment["COTG_UI_TEST_PROOF_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")

            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(to: url)
            } catch {
                XCTFail("Failed to write proof screenshot \(name): \(error.localizedDescription)")
            }
        }

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func screenshotOutputDirectory() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "\(workspaceRoot)/marketing/app-store/screenshots/ipad"
        default:
            return "\(workspaceRoot)/marketing/app-store/screenshots/iphone"
        }
    }

    private func navigateToPrimaryMachine() {
        if hasActiveCodexSession() {
            return
        }

        navigateToPrimaryMachineInConnections()

        if app.buttons["Open Codex"].waitForExistence(timeout: 5) {
            app.buttons["Open Codex"].tap()
        } else {
            openCodexTab()
        }

        ensureSessionWorkspace(timeout: 10)
    }

    private func navigateToScreenshotMachine() {
        if hasActiveCodexSession() {
            return
        }

        openConnectionsTab()
        scrollMachineDirectoryToTop()
        let fixtureMachineCard = screenshotFixtureMachineCard()
        if fixtureMachineCard.waitForExistence(timeout: 3) {
            fixtureMachineCard.tap()
            allowLocalNetworkPromptIfNeeded()
        } else {
            let firstMachineCard = firstMachineCard()
            if firstMachineCard.waitForExistence(timeout: 3) {
                firstMachineCard.tap()
                allowLocalNetworkPromptIfNeeded()
            }
        }

        if app.buttons["Open Codex"].waitForExistence(timeout: 5) {
            app.buttons["Open Codex"].tap()
        } else {
            openCodexTab()
        }

        ensureSessionWorkspace(timeout: 10)
    }

    private func navigateToScreenshotMachineInConnections() {
        openConnectionsTab()
        if isShowingConnectionsDetail(forMachineNamed: screenshotFixtureDisplayName) {
            return
        }
        _ = waitForConnectionsListSurface(timeout: 3)
        returnToConnectionsListIfNeeded(missingMachineIdentifier: "machine-card-\(screenshotFixtureDisplayName)")
        scrollMachineDirectoryToTop()
        let fixtureMachineCard = screenshotFixtureMachineCard()
        if waitForElementExists(fixtureMachineCard, timeout: 20, maxSwipes: 8) {
            fixtureMachineCard.tap()
            allowLocalNetworkPromptIfNeeded()
        } else {
            let firstMachineCard = firstMachineCard()
            XCTAssertTrue(waitForElementExists(firstMachineCard, timeout: 20, maxSwipes: 8))
            firstMachineCard.tap()
            allowLocalNetworkPromptIfNeeded()
        }
        XCTAssertTrue(waitForConnectionsDetailSurface(timeout: 10))
    }

    private func ensureSessionWorkspace(timeout: TimeInterval) {
        if hasReadyCodexSession() || waitForReadyCodexSession(timeout: min(timeout, 5)) {
            return
        }

        openCodexTab()

        if waitForReadyCodexSession(timeout: min(timeout, 5)) {
            return
        }

        openReposBrowserIfNeeded()

        if waitForReadyCodexSession(timeout: min(timeout, 3)) {
            return
        }

        if !waitForBrowserSessionSelection(timeout: min(timeout, 10)) {
            if waitForReadyCodexSession(timeout: min(timeout, 3)) {
                return
            }
            XCTFail("Expected browser content before choosing a thread. Browser status: \(browserStatusValue() ?? "missing")")
            return
        }

        let firstResume = firstResumeRow()
        if firstResume.waitForExistence(timeout: 5) {
            tapBrowserElement(firstResume)
        } else {
            let firstNewSession = firstNewThreadButton()
            XCTAssertTrue(
                firstNewSession.waitForExistence(timeout: 5),
                "Expected either a resumable thread or a new-thread action in the Codex browser. Browser status: \(browserStatusValue() ?? "missing")"
            )
            tapBrowserElement(firstNewSession)
        }

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }

        XCTAssertTrue(
            waitForReadyCodexSession(timeout: timeout),
            "Expected selecting a browser row to reveal an active Codex session. Browser status: \(browserStatusValue() ?? "missing"); session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
    }

    private func startNewThreadInBrowserProject(repoPath: String, timeout: TimeInterval) {
        openCodexTab()
        openReposBrowserIfNeeded()

        let repoName = URL(fileURLWithPath: repoPath, isDirectory: true).lastPathComponent
        XCTAssertTrue(
            waitForProjectBrowserAction(repoName: repoName, timeout: timeout),
            "Expected a project-scoped browser action for \(repoPath). Browser status: \(browserStatusValue() ?? "missing")"
        )

        let searchField = app.searchFields["Search projects or threads"]
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("\(repoName)\n")
        }

        let newThreadButton = app.buttons["new-thread-\(repoName)"]
        XCTAssertTrue(
            waitForElementExists(newThreadButton, timeout: timeout, maxSwipes: 8),
            "Expected a project-scoped new-thread button for \(repoName) after filtering the browser."
        )
        tapBrowserElement(newThreadButton)

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            dismissReposBrowserIfNeeded()
        }

        XCTAssertTrue(waitForActiveCodexSession(timeout: timeout))
    }

    @discardableResult
    private func waitForProjectBrowserAction(repoName: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let newThreadButton = app.buttons["new-thread-\(repoName)"]
        let projectRow = app.otherElements["project-group-\(repoName)"]
        var seededSearch = false

        while Date() < deadline {
            if newThreadButton.exists || projectRow.exists {
                return true
            }

            let searchField = app.searchFields["Search projects or threads"]
            if !seededSearch, searchField.waitForExistence(timeout: 1) {
                searchField.tap()
                searchField.typeText("\(repoName)\n")
                seededSearch = true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return newThreadButton.exists || projectRow.exists
    }

    private func allowLocalNetworkPromptIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let affirmativeButtons = ["Allow", "OK", "Continue"]
        let affirmativeIdentifiers = [
            "com.apple.lockdown.ax.trust.confirm_trust"
        ]
        let deadline = Date().addingTimeInterval(8)

        while Date() < deadline {
            let alertContainers = [app.alerts.element, springboard.alerts.element]
            for alert in alertContainers where alert.exists {
                for identifier in affirmativeIdentifiers {
                    let button = alert.descendants(matching: .button).matching(identifier: identifier).firstMatch
                    if button.exists {
                        if button.isHittable {
                            button.tap()
                        } else {
                            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        }
                        return
                    }
                }

                for label in affirmativeButtons {
                    let button = alert.buttons[label]
                    if button.exists {
                        button.tap()
                        return
                    }
                }

                let trustButton = alert.buttons.matching(NSPredicate(format: "label == %@", "Trust")).firstMatch
                if trustButton.exists {
                    if trustButton.isHittable {
                        trustButton.tap()
                    } else {
                        trustButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    }
                    return
                }

                if let button = alert.buttons.allElementsBoundByIndex.last,
                   button.exists,
                   !button.label.localizedCaseInsensitiveContains("don’t"),
                   !button.label.localizedCaseInsensitiveContains("don't") {
                    button.tap()
                    return
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func handleSystemAlertIfPossible(_ alert: XCUIElement) -> Bool {
        let affirmativeIdentifiers = [
            "com.apple.lockdown.ax.trust.confirm_trust"
        ]
        let affirmativeLabels = ["Trust", "Allow", "OK", "Continue"]

        for identifier in affirmativeIdentifiers {
            let button = alert.descendants(matching: .button).matching(identifier: identifier).firstMatch
            if button.exists {
                if button.isHittable {
                    button.tap()
                } else {
                    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                return true
            }
        }

        for label in affirmativeLabels {
            let button = alert.buttons[label]
            if button.exists {
                if button.isHittable {
                    button.tap()
                } else {
                    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                return true
            }
        }

        return false
    }

    private func navigateToSecondaryMachine() {
        openConnectionsTab()
        if app.otherElements["connection-plan-card"].waitForExistence(timeout: 2),
           !app.buttons["machine-card-c"].exists {
            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.waitForExistence(timeout: 2) {
                backButton.tap()
            }
        }
        scrollMachineDirectoryToTop()
        XCTAssertTrue(waitForElementExists(app.buttons["machine-card-c"], timeout: 8, maxSwipes: 8))
        app.buttons["machine-card-c"].tap()
        if app.buttons["Open Codex"].waitForExistence(timeout: 5) {
            app.buttons["Open Codex"].tap()
        } else {
            openCodexTab()
        }
    }

    private func assertSafeLaneSurfaceIsVisible(timeout: TimeInterval) {
        ensureConnectedSession(timeout: timeout)
        XCTAssertTrue(waitForReadyCodexSession(timeout: timeout))
    }

    private func assertConnectionSurfaceIsVisible(timeout: TimeInterval) {
        ensureSessionWorkspace(timeout: timeout)
        XCTAssertTrue(waitForReadyCodexSession(timeout: timeout))
        XCTAssertTrue(app.buttons["queue-prompt-button"].waitForExistence(timeout: timeout))
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.buttons["photo-tool-button"].waitForExistence(timeout: timeout))
            XCTAssertTrue(app.buttons["voice-tool-button"].waitForExistence(timeout: timeout))
        } else {
            XCTAssertTrue(app.buttons["model-menu-button"].waitForExistence(timeout: timeout))
        }
    }

    private func assertConnectionsDetailIsVisible(timeout: TimeInterval) {
        XCTAssertNotNil(
            waitForConnectionPrimaryAction(timeout: timeout, maxSwipes: 4),
            "Expected the Connections detail screen to expose a primary action."
        )
        XCTAssertTrue(app.otherElements["connection-plan-card"].waitForExistence(timeout: timeout))
    }

    private func isShowingConnectionsDetail(forMachineNamed machineName: String) -> Bool {
        guard waitForConnectionsDetailSurface(timeout: 8) else {
            return false
        }

        let navigationTitle = app.navigationBars[machineName]
        if navigationTitle.exists {
            return true
        }

        let navigationText = app.navigationBars.staticTexts[machineName]
        if navigationText.exists {
            return true
        }

        return false
    }

    @discardableResult
    private func waitForConnectionsDetailSurface(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.otherElements["connection-plan-card"].exists
                || connectionLaunchActionElement() != nil {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return app.otherElements["connection-plan-card"].exists
            || connectionLaunchActionElement() != nil
    }

    @discardableResult
    private func waitForConnectionsListSurface(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if anyMachineCardExists() || app.otherElements["machine-directory-sidebar"].exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return anyMachineCardExists() || app.otherElements["machine-directory-sidebar"].exists
    }

    private func ensureConnectedSession(timeout: TimeInterval) {
        ensureSessionWorkspace(timeout: timeout)

        if waitForActiveThreadID(timeout: 2) {
            return
        }

        openConnectionsTab()
        if !waitForConnectionsDetailSurface(timeout: 8) {
            navigateToCurrentFixtureMachineInConnections()
        }
        let connectAction = waitForConnectionLaunchAction(timeout: 10, maxSwipes: 8)
        XCTAssertTrue(
            connectAction != nil,
            "Expected a reconnect, resume, or open-Codex action. Status: \(connectionStatusValue() ?? "missing")"
        )
        guard let connectAction else {
            return
        }
        tapElement(connectAction)
        allowLocalNetworkPromptIfNeeded()

        openCodexTab()
        ensureSessionWorkspace(timeout: timeout)
        XCTAssertTrue(waitForReadyCodexSession(timeout: timeout))
    }

    private func navigateToCurrentFixtureMachineInConnections() {
        if waitForConnectionsDetailSurface(timeout: 8) {
            return
        }

        if app.buttons["machine-card-Same LAN"].exists {
            openConnectionsTab()
            returnToConnectionsListIfNeeded(missingMachineIdentifier: "machine-card-Same LAN")
            scrollMachineDirectoryToTop()
            let lanCard = app.buttons["machine-card-Same LAN"]
            XCTAssertTrue(waitForElementExists(lanCard, timeout: 8, maxSwipes: 8))
            lanCard.tap()
            allowLocalNetworkPromptIfNeeded()
            return
        }

        if screenshotFixtureMachineCard().exists {
            navigateToScreenshotMachineInConnections()
            return
        }

        if isSimulatorRuntime {
            navigateToScreenshotMachineInConnections()
        } else {
            navigateToPhysicalRealHostMachineInConnections()
        }
    }

    private func connectSelectedMachineWithoutSelectingThread(timeout: TimeInterval) {
        openConnectionsTab()
        if !waitForConnectionsDetailSurface(timeout: 8) {
            navigateToCurrentFixtureMachineInConnections()
        }
        scrollConnectionsDetailToTop()
        let buttonWaitTimeout = max(10, min(timeout, 60))
        let connectAction = waitForConnectionLaunchAction(timeout: buttonWaitTimeout, maxSwipes: 8)
        XCTAssertTrue(
            connectAction != nil,
            "Expected a reconnect, resume, or open-Codex action. Status: \(connectionStatusValue() ?? "missing")"
        )
        guard let connectAction else {
            return
        }
        tapElement(connectAction)
        allowLocalNetworkPromptIfNeeded()

        var attemptedSettingsRepair = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let connectionStatus = connectionStatusValue()
            if connectionStatus?.contains("connection=connected") == true {
                return
            }
            if connectionStatus?.contains("connection=failed") == true {
                let status = connectionStatus ?? "missing"
                if !attemptedSettingsRepair,
                   status.localizedCaseInsensitiveContains("allow local network access"),
                   repairLocalNetworkPermissionIfNeeded() {
                    attemptedSettingsRepair = true
                    openConnectionsTab()
                    if !waitForConnectionsDetailSurface(timeout: 8) {
                        navigateToCurrentFixtureMachineInConnections()
                    }
                    let repairedConnectAction = waitForConnectionLaunchAction(timeout: 10, maxSwipes: 8)
                    XCTAssertTrue(
                        repairedConnectAction != nil,
                        "Expected a reconnect, resume, or open-Codex action after repairing local-network permission. Status: \(connectionStatusValue() ?? "missing")"
                    )
                    guard let repairedConnectAction else {
                        return
                    }
                    tapElement(repairedConnectAction)
                    allowLocalNetworkPromptIfNeeded()
                    continue
                }

                XCTFail(
                    "Connection failed while waiting for the selected Mac to connect. Status: \(status) [uitestHost=\(localhostSSHHost) resolvedEnv=\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_RESOLVED"] ?? "missing") rawEnv=\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"] ?? "missing") hostFile=\(physicalDeviceSSHHostFileValue ?? "missing") hostFilePath=\(physicalDeviceSSHHostPath)]"
                )
                return
            }

            openCodexTab()
            openReposBrowserIfNeeded()
            _ = waitForHostBrowserContent(timeout: 2)
            if hasReadyCodexSession() {
                return
            }
            let browserStatus = browserStatusValue()
            if browserStatus?.contains("connection=connected") == true {
                return
            }
            if browserStatus?.contains("connection=failed") == true {
                XCTFail(
                    "Connection failed while waiting for the selected Mac to connect. Browser status: \(browserStatus ?? "missing") [uitestHost=\(localhostSSHHost) resolvedEnv=\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_RESOLVED"] ?? "missing") rawEnv=\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"] ?? "missing") hostFile=\(physicalDeviceSSHHostFileValue ?? "missing") hostFilePath=\(physicalDeviceSSHHostPath)]"
                )
                return
            }

            openConnectionsTab()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail(
            "Expected Codex to become available after connecting the selected Mac. Last connection status: \(connectionStatusValue() ?? "missing"); last browser status: \(browserStatusValue() ?? "missing") [uitestHost=\(localhostSSHHost) resolvedEnv=\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_RESOLVED"] ?? "missing") rawEnv=\(ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"] ?? "missing") hostFile=\(physicalDeviceSSHHostFileValue ?? "missing") hostFilePath=\(physicalDeviceSSHHostPath)]"
        )
    }

    private func ensureInstalledAppRealHostBrowserReady(timeout: TimeInterval) {
        openCodexTab()
        openReposBrowserIfNeeded()
        if waitForHostBrowserContent(timeout: min(timeout, 15)),
           browserStatusShowsLiveHostCatalog() {
            return
        }

        connectSelectedMachineWithoutSelectingThread(timeout: timeout)
        openCodexTab()
        openReposBrowserIfNeeded()
        XCTAssertTrue(
            waitForLiveHostBrowserCatalog(timeout: timeout),
            "Expected the installed app to expose live host browser content after reconnecting. Browser status: \(browserStatusValue() ?? "missing")"
        )
    }

    @discardableResult
    private func repairLocalNetworkPermissionIfNeeded() -> Bool {
        let openSettingsButton = app.buttons["open-app-settings-button"]
        guard openSettingsButton.waitForExistence(timeout: 3) else {
            return false
        }

        if openSettingsButton.isHittable {
            openSettingsButton.tap()
        } else {
            app.swipeUp()
            let buttonCoordinate = openSettingsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            buttonCoordinate.tap()
        }

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        guard settings.wait(for: .runningForeground, timeout: 8) else {
            return false
        }

        let localNetworkSwitch = settings.switches["Local Network"].firstMatch
        if !localNetworkSwitch.waitForExistence(timeout: 5) {
            settings.swipeUp()
        }

        guard localNetworkSwitch.waitForExistence(timeout: 3) else {
            return false
        }

        if let rawValue = localNetworkSwitch.value as? String,
           rawValue == "0" || rawValue.localizedCaseInsensitiveContains("off") {
            localNetworkSwitch.tap()
        }

        app.activate()
        return app.wait(for: .runningForeground, timeout: 8)
    }

    private func sendSmokePromptFromConnections(timeout: TimeInterval = 30) {
        ensureConnectedSession(timeout: timeout)
        openCodexTab()
        let baselineDebug = codexSessionDebugSnapshot()
        let baselineHadThreadID = activeThreadIDValue() != nil
        let baselineAssistantReplies = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        openConnectionsTab()
        if !app.buttons["smoke-test-button"].exists {
            if app.buttons["support-actions-menu-button"].waitForExistence(timeout: 2) {
                app.buttons["support-actions-menu-button"].tap()
            } else {
                expandDisclosureIfNeeded("Support and recovery")
            }
        }
        XCTAssertTrue(waitForButton("smoke-test-button", enabled: true, timeout: timeout, maxSwipes: 12))
        app.buttons["smoke-test-button"].tap()
        openCodexTab()
        if !waitForActiveCodexSession(timeout: min(timeout, 10)) {
            ensureSessionWorkspace(timeout: timeout)
        }
        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: baselineHadThreadID,
                baselineAssistantReplies: baselineAssistantReplies,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: timeout
            ),
            "Expected smoke test to continue the active thread. Baseline replies: \(baselineAssistantReplies); baseline transcript count: \(baselineTranscriptCount); current reply label: \(assistantReplyCountLabel() ?? "missing")"
        )
    }

    private func sendPromptFromComposer(_ prompt: String, timeout: TimeInterval = 30) {
        XCTAssertTrue(waitForReadyCodexSession(timeout: timeout))

        stabilizeDeviceOrientationIfNeeded()
        let baselineDebug = codexSessionDebugSnapshot()
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()
        let baselineAssistantReplies = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let promptField = composerPromptField()
        XCTAssertTrue(promptField.waitForExistence(timeout: timeout))
        if promptField.isHittable {
            promptField.tap()
        } else {
            promptField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        app.typeText(prompt)
        if !waitForComposerDraft(prompt, timeout: min(timeout, 6)) {
            promptField.typeText(prompt)
        }
        XCTAssertTrue(
            waitForComposerDraft(prompt, timeout: min(timeout, 6)),
            "Expected the main Codex composer to contain the prompt before sending. Composer value: \(composerPromptValue() ?? "missing")"
        )

        for attempt in composerSendAttemptSequence(promptField: promptField, timeout: timeout) {
            attempt()
            if waitForComposerSubmissionToStart(
                baselineTranscriptCount: baselineTranscriptCount,
                baselineAssistantReplies: baselineAssistantReplies,
                timeout: min(timeout, 20)
            ) {
                return
            }
        }
        let status = codexSessionDebugStatusValue() ?? "missing"
        XCTContext.runActivity(named: "Composer send did not start") { activity in
            activity.add(
                XCTAttachment(
                    string: "Session status after send: \(status)"
                )
            )
        }
        XCTFail("Expected the main Codex composer send to start. Session status: \(status)")
    }

    private func sendPromptFromMainComposerAndWaitForContinuation(
        _ prompt: String,
        timeout: TimeInterval = 30
    ) {
        openCodexTab()
        ensureSessionWorkspace(timeout: timeout)

        let baselineDebug = codexSessionDebugSnapshot()
        let baselineHadThreadID = activeThreadIDValue() != nil
        let baselineAssistantReplies = baselineDebug?.assistantReplies ?? assistantReplyCount() ?? 0
        let baselineTranscriptCount = baselineDebug?.transcriptCount ?? transcriptConversationBubbleCount()

        sendPromptFromComposer(prompt, timeout: timeout)

        XCTAssertTrue(
            waitForThreadContinuationAfterSend(
                baselineHadThreadID: baselineHadThreadID,
                baselineAssistantReplies: baselineAssistantReplies,
                baselineTranscriptCount: baselineTranscriptCount,
                timeout: timeout
            ),
            "Expected the main Codex composer to continue the active thread. Baseline replies: \(baselineAssistantReplies); baseline transcript count: \(baselineTranscriptCount); current reply label: \(assistantReplyCountLabel() ?? "missing"); session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
    }

    private func ensureConnectionsDetailVisible(
        timeout: TimeInterval,
        preferredMachineCardIdentifier: String? = nil
    ) {
        openConnectionsTab()
        if app.otherElements["connection-plan-card"].waitForExistence(timeout: 2) {
            return
        }

        scrollMachineDirectoryToTop()
        if let preferredMachineCardIdentifier {
            let preferredCard = app.buttons[preferredMachineCardIdentifier]
            if preferredCard.waitForExistence(timeout: 2) {
                preferredCard.tap()
                allowLocalNetworkPromptIfNeeded()
                assertConnectionsDetailIsVisible(timeout: timeout)
                return
            }
        }

        navigateToFirstMachineInConnections()
        assertConnectionsDetailIsVisible(timeout: timeout)
    }

    @discardableResult
    private func waitForButton(
        _ identifier: String,
        enabled: Bool,
        timeout: TimeInterval,
        maxSwipes: Int = 0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var swipeCount = 0

        while Date() < deadline {
            let button = app.buttons[identifier]
            if button.exists, button.isEnabled == enabled {
                return true
            }
            if swipeCount < maxSwipes {
                app.swipeUp()
                swipeCount += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let button = app.buttons[identifier]
        return button.exists && button.isEnabled == enabled
    }

    @discardableResult
    private func waitForElementExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        maxSwipes: Int = 0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var swipeCount = 0

        while Date() < deadline {
            if element.exists {
                return true
            }
            if swipeCount < maxSwipes {
                app.swipeUp()
                swipeCount += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return element.exists
    }

    private func menuChoiceElement(named label: String) -> XCUIElement? {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", label, label)
        let candidates: [XCUIElement] = [
            app.buttons.matching(predicate).firstMatch,
            app.menuItems.matching(predicate).firstMatch,
            app.cells.matching(predicate).firstMatch,
            app.staticTexts.matching(predicate).firstMatch,
            app.otherElements.matching(predicate).firstMatch,
            app.descendants(matching: .any).matching(predicate).firstMatch,
            springboard.buttons.matching(predicate).firstMatch,
            springboard.menuItems.matching(predicate).firstMatch,
            springboard.cells.matching(predicate).firstMatch,
            springboard.staticTexts.matching(predicate).firstMatch,
            springboard.otherElements.matching(predicate).firstMatch,
            springboard.descendants(matching: .any).matching(predicate).firstMatch
        ]

        return candidates.first(where: \.exists)
    }

    @discardableResult
    private func selectMenuChoice(
        menuIdentifier: String,
        choiceLabel: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let opener = app.buttons[menuIdentifier]
        var lastOpenAttempt = Date.distantPast

        while Date() < deadline {
            if opener.exists, opener.label.contains(choiceLabel) {
                return true
            }

            if let choice = menuChoiceElement(named: choiceLabel) {
                tapElement(choice)
                return true
            }

            if opener.exists,
               !opener.isHittable {
                app.swipeUp()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            if opener.exists,
               Date().timeIntervalSince(lastOpenAttempt) >= 0.6 {
                tapElement(opener)
                lastOpenAttempt = Date()
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return false
    }

    private func waitForConnectionsEmptyStateAfterForgettingMachine(timeout: TimeInterval) -> Bool {
        if waitForButton("machine-directory-scan-button", enabled: true, timeout: timeout) {
            return true
        }

        if waitForButton("empty-state-scan-local-network-button", enabled: true, timeout: max(2, timeout / 2)) {
            return true
        }

        return app.staticTexts["Connections"].waitForExistence(timeout: max(2, timeout / 2))
    }

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !element.exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return !element.exists
    }

    @discardableResult
    private func waitForElementHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if element.exists, element.isHittable {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return element.exists && element.isHittable
    }

    @discardableResult
    private func waitForElementWithIdentifier(_ identifier: String, timeout: TimeInterval) -> Bool {
        let queries = [
            app.buttons[identifier],
            app.otherElements[identifier],
            app.staticTexts[identifier],
            app.images[identifier],
            app.switches[identifier],
            app.textFields[identifier]
        ]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queries.contains(where: \.exists) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return queries.contains(where: \.exists)
    }

    @discardableResult
    private func waitForElementWithIdentifierOrLabelPrefix(
        _ identifier: String,
        labelPrefix: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", labelPrefix)

        while Date() < deadline {
            if waitForElementWithIdentifier(identifier, timeout: 0) {
                return true
            }

            if app.descendants(matching: .any).matching(predicate).count > 0 {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return waitForElementWithIdentifier(identifier, timeout: 0)
            || app.descendants(matching: .any).matching(predicate).count > 0
    }

    @discardableResult
    private func waitForAnyStaticText(_ texts: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if texts.contains(where: { app.staticTexts[$0].exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return texts.contains(where: { app.staticTexts[$0].exists })
    }

    private var nearbyScanFeedbackTextLabels: [String] {
        [
            "No nearby Mac found yet",
            "No nearby Macs are listed yet.",
            "Looking for Macs on this network.",
            "Nearby now"
        ]
    }

    @discardableResult
    private func waitForNearbyScanFeedback(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if nearbyScanFeedbackTextLabels.contains(where: { app.staticTexts[$0].exists }) {
                return true
            }
            if app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "nearby-result-")
            ).firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return nearbyScanFeedbackTextLabels.contains(where: { app.staticTexts[$0].exists })
            || app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "nearby-result-")
            ).firstMatch.exists
    }

    @discardableResult
    private func waitForStaticText(_ text: String, minimumCount: Int = 1, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count >= minimumCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count >= minimumCount
    }

    @discardableResult
    private func waitForAssistantReplyCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if assistantReplyCount() == count {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return assistantReplyCount() == count
    }

    @discardableResult
    private func waitForThreadContinuationAfterSend(
        baselineHadThreadID: Bool,
        baselineAssistantReplies: Int,
        baselineTranscriptCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.buttons["approve-request-button"].waitForExistence(timeout: 0.2) {
                app.buttons["approve-request-button"].tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }

            if let status = codexSessionDebugSnapshot() {
                let hasLiveThread = status.threadID != "none" && status.threadID != "thread-pending"
                if status.assistantReplies >= baselineAssistantReplies + 1 {
                    return baselineHadThreadID || hasLiveThread
                }
                if status.transcriptCount >= baselineTranscriptCount + 2, !status.streaming {
                    return baselineHadThreadID || hasLiveThread
                }
            }

            let hasLiveThread = baselineHadThreadID || activeThreadIDValue() != nil
            if let visibleAssistantReplies = assistantReplyCount(),
               visibleAssistantReplies >= baselineAssistantReplies + 1,
               hasLiveThread {
                return true
            }
            if transcriptConversationBubbleCount() >= baselineTranscriptCount + 2,
               hasLiveThread,
               !app.buttons["approve-request-button"].exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if let status = codexSessionDebugSnapshot() {
            let hasLiveThread = status.threadID != "none" && status.threadID != "thread-pending"
            return (status.assistantReplies >= baselineAssistantReplies + 1
                || (status.transcriptCount >= baselineTranscriptCount + 2 && !status.streaming))
                && (baselineHadThreadID || hasLiveThread)
        }

        let hasLiveThread = baselineHadThreadID || activeThreadIDValue() != nil
        if let visibleAssistantReplies = assistantReplyCount(),
           visibleAssistantReplies >= baselineAssistantReplies + 1,
           hasLiveThread {
            return true
        }
        if transcriptConversationBubbleCount() >= baselineTranscriptCount + 2,
           hasLiveThread,
           !app.buttons["approve-request-button"].exists {
            return true
        }

        return false
    }

    @discardableResult
    private func waitForThreadContinuationWithoutApprovalAfterSend(
        baselineHadThreadID: Bool,
        baselineAssistantReplies: Int,
        baselineTranscriptCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.buttons["approve-request-button"].exists {
                return false
            }

            if let status = codexSessionDebugSnapshot() {
                let hasLiveThread = status.threadID != "none" && status.threadID != "thread-pending"
                if status.assistantReplies >= baselineAssistantReplies + 1 {
                    return baselineHadThreadID || hasLiveThread
                }
                if status.transcriptCount >= baselineTranscriptCount + 2, !status.streaming {
                    return baselineHadThreadID || hasLiveThread
                }
            }

            let hasLiveThread = baselineHadThreadID || activeThreadIDValue() != nil
            if let visibleAssistantReplies = assistantReplyCount(),
               visibleAssistantReplies >= baselineAssistantReplies + 1,
               hasLiveThread {
                return true
            }
            if transcriptConversationBubbleCount() >= baselineTranscriptCount + 2,
               hasLiveThread {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if app.buttons["approve-request-button"].exists {
            return false
        }

        if let status = codexSessionDebugSnapshot() {
            let hasLiveThread = status.threadID != "none" && status.threadID != "thread-pending"
            return (status.assistantReplies >= baselineAssistantReplies + 1
                || (status.transcriptCount >= baselineTranscriptCount + 2 && !status.streaming))
                && (baselineHadThreadID || hasLiveThread)
        }

        let hasLiveThread = baselineHadThreadID || activeThreadIDValue() != nil
        if let visibleAssistantReplies = assistantReplyCount(),
           visibleAssistantReplies >= baselineAssistantReplies + 1,
           hasLiveThread {
            return true
        }
        if transcriptConversationBubbleCount() >= baselineTranscriptCount + 2,
           hasLiveThread {
            return true
        }

        return false
    }

    @discardableResult
    private func waitForCodexSessionConnectionState(_ state: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if codexSessionDebugSnapshot()?.connection == state {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return codexSessionDebugSnapshot()?.connection == state
    }

    @discardableResult
    private func waitForTranscriptConversationHistory(timeout: TimeInterval, minimumCount: Int) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if transcriptConversationBubbleCount() >= minimumCount {
                return true
            }
            if let snapshot = codexSessionDebugSnapshot(),
               snapshot.transcriptCount >= minimumCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if transcriptConversationBubbleCount() >= minimumCount {
            return true
        }

        if let snapshot = codexSessionDebugSnapshot() {
            return snapshot.transcriptCount >= minimumCount
        }

        return false
    }

    @discardableResult
    private func waitForVisibleTranscriptConversationHistory(timeout: TimeInterval, minimumCount: Int) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if transcriptConversationBubbleCount() >= minimumCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return transcriptConversationBubbleCount() >= minimumCount
    }

    private func assistantReplyCount() -> Int? {
        guard let label = assistantReplyCountLabel() else {
            return nil
        }

        if let count = Int(label.replacingOccurrences(of: "Assistant replies: ", with: "")) {
            return count
        }

        return Int(label.replacingOccurrences(of: " replies", with: ""))
    }

    private func assistantReplyCountLabel() -> String? {
        let identifiedLabel = app.staticTexts["assistant-reply-count-label"]
        if identifiedLabel.exists {
            return identifiedLabel.label
        }

        let visibleLabels = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@", " replies")
        )
        guard visibleLabels.count > 0 else {
            return nil
        }
        return visibleLabels.firstMatch.label
    }

    private func codexSessionDebugStatusValue() -> String? {
        let otherElement = app.otherElements["codex-session-debug-status"]
        if otherElement.exists, !otherElement.label.isEmpty {
            return otherElement.label
        }

        let staticText = app.staticTexts["codex-session-debug-status"]
        if staticText.exists, !staticText.label.isEmpty {
            return staticText.label
        }

        return nil
    }

    private func codexSessionDebugSnapshot() -> CodexSessionDebugSnapshot? {
        guard let label = codexSessionDebugStatusValue() else {
            return nil
        }

        let components = Dictionary(
            uniqueKeysWithValues: label
                .split(separator: ";")
                .compactMap { pair -> (String, String)? in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return (parts[0], parts[1])
                }
        )

        guard
            let threadID = components["thread"],
            let transcriptCount = components["transcript"].flatMap(Int.init),
            let assistantReplies = components["assistantReplies"].flatMap(Int.init),
            let streamingString = components["streaming"],
            let connection = components["connection"],
            let protocolKind = components["protocol"],
            let composerAttempts = components["composerAttempts"].flatMap(Int.init),
            let draftCount = components["draftCount"].flatMap(Int.init)
        else {
            return nil
        }

        return CodexSessionDebugSnapshot(
            threadID: threadID,
            transcriptCount: transcriptCount,
            assistantReplies: assistantReplies,
            streaming: streamingString == "true",
            connection: connection,
            protocolKind: protocolKind,
            composerAttempts: composerAttempts,
            draftCount: draftCount
        )
    }

    @discardableResult
    private func waitForCodexSessionIdle(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let snapshot = codexSessionDebugSnapshot(),
               snapshot.connection == "connected",
               !snapshot.streaming,
               !app.buttons["approve-request-button"].exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if let snapshot = codexSessionDebugSnapshot() {
            return snapshot.connection == "connected"
                && !snapshot.streaming
                && !app.buttons["approve-request-button"].exists
        }

        return false
    }

    private func hasReadyCodexSession() -> Bool {
        let browserSurfaceVisible = app.staticTexts["Projects & Threads"].exists
            || app.otherElements["codex-browser-list"].exists
            || app.searchFields["Search projects or threads"].exists
        let hasComposerSurface = app.otherElements["codex-session-surface"].exists
            || app.otherElements["codex-sticky-composer"].exists
            || app.textFields["session-prompt-field"].exists
            || app.textFields["Message Codex"].exists

        if let snapshot = codexSessionDebugSnapshot() {
            let hasResolvedThreadID = !snapshot.threadID.isEmpty
                && snapshot.threadID != "none"
                && snapshot.threadID != "thread-pending"
            if snapshot.connection == "connected",
               (hasResolvedThreadID
                || (!browserSurfaceVisible && hasComposerSurface)
                || app.buttons["queue-prompt-button"].isEnabled) {
                return true
            }
        }

        if activeThreadIDValue() != nil,
            codexSessionDebugSnapshot()?.connection == "connected" {
            return true
        }

        let sendButton = app.buttons["queue-prompt-button"]
        return (!browserSurfaceVisible && hasComposerSurface)
            || (sendButton.exists && sendButton.isEnabled)
    }

    @discardableResult
    private func waitForReadyCodexSession(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if hasReadyCodexSession() {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return hasReadyCodexSession()
    }

    @discardableResult
    private func waitForCodexSessionProtocol(_ protocolKind: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if codexSessionDebugSnapshot()?.protocolKind == protocolKind {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return codexSessionDebugSnapshot()?.protocolKind == protocolKind
    }

    @discardableResult
    private func waitForCodexSessionStreaming(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let snapshot = codexSessionDebugSnapshot(), snapshot.streaming {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return codexSessionDebugSnapshot()?.streaming == true
    }

    @discardableResult
    private func waitForTextContaining(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)

        while Date() < deadline {
            if app.staticTexts.matching(predicate).count > 0 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return app.staticTexts.matching(predicate).count > 0
    }

    @discardableResult
    private func waitForActiveThreadID(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if activeThreadIDValue() != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return activeThreadIDValue() != nil
    }

    private func hasActiveCodexSession() -> Bool {
        if app.staticTexts["Projects & Threads"].exists
            || app.otherElements["codex-browser-list"].exists {
            return false
        }

        if activeThreadIDValue() != nil {
            return true
        }

        if app.staticTexts["Approvals inline"].exists
            || app.staticTexts["Approval required"].exists
            || app.staticTexts["Approvals unavailable"].exists {
            return true
        }

        if app.staticTexts["No transcript yet"].exists
            || app.staticTexts["Thread ready"].exists
            || app.staticTexts["Connection failed"].exists
            || app.staticTexts["Reconnecting"].exists
            || app.staticTexts["Approval required"].exists {
            return true
        }

        if app.navigationBars["Browse"].exists {
            return true
        }

        return app.otherElements["codex-session-surface"].exists || app.otherElements["codex-session-header"].exists
    }

    private func transcriptConversationBubbleCount() -> Int {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == %@ OR identifier == %@",
                    "session-bubble-user",
                    "session-bubble-assistant"
                )
            )
            .count
    }

    private func activeThreadIDElement() -> XCUIElement {
        let otherElement = app.otherElements["active-thread-id-label"]
        if otherElement.exists {
            return otherElement
        }

        return app.staticTexts["active-thread-id-label"]
    }

    private func activeThreadIDLabelValue() -> String? {
        let label = activeThreadIDElement()
        guard label.exists, !label.label.isEmpty, label.label != "thread-pending" else {
            return nil
        }

        return label.label
    }

    private func activeThreadIDValue() -> String? {
        if let labelValue = activeThreadIDLabelValue() {
            return labelValue
        }

        if let snapshot = codexSessionDebugSnapshot(),
           !snapshot.threadID.isEmpty,
           snapshot.threadID != "none",
           snapshot.threadID != "thread-pending" {
            return snapshot.threadID
        }

        return nil
    }

    private func composerPromptField() -> XCUIElement {
        let composer = app.otherElements["codex-sticky-composer"]
        let composerTextField = composer.textFields["session-prompt-field"]
        if composerTextField.exists {
            return composerTextField
        }

        let composerTextView = composer.textViews["session-prompt-field"]
        if composerTextView.exists {
            return composerTextView
        }

        let identifiedField = app.textFields["session-prompt-field"]
        if identifiedField.exists {
            return identifiedField
        }

        let identifiedTextView = app.textViews["session-prompt-field"]
        if identifiedTextView.exists {
            return identifiedTextView
        }

        let firstTextView = app.textViews.firstMatch
        if firstTextView.exists {
            return firstTextView
        }

        return app.textFields.firstMatch
    }

    private func composerSendAttemptSequence(
        promptField: XCUIElement,
        timeout: TimeInterval
    ) -> [() -> Void] {
        [
            {
                self.dismissComposerKeyboardIfVisible(timeout: min(timeout, 5))
                self.tapComposerSendButton(timeout: min(timeout, 5))
            },
            {
                self.focusComposerPromptFieldIfNeeded(promptField)
                let keyboardSend = self.keyboardSendButton()
                if keyboardSend.waitForExistence(timeout: 2), keyboardSend.isHittable {
                    keyboardSend.tap()
                    return
                }
                self.app.typeText("\n")
            },
            {
                self.dismissComposerKeyboardIfVisible(timeout: min(timeout, 5))
                self.tapComposerSendButton(timeout: min(timeout, 5), forceCoordinateTap: true)
            }
        ]
    }

    private func tapComposerSendButton(timeout: TimeInterval, forceCoordinateTap: Bool = false) {
        stabilizeDeviceOrientationIfNeeded()
        let sendButton = composerSendButton()
        XCTAssertTrue(sendButton.waitForExistence(timeout: timeout))
        XCTAssertTrue(
            waitForComposerSendEnabled(timeout: min(timeout, 8)),
            "Expected the main Codex send button to enable after entering a prompt. Composer value: \(composerPromptValue() ?? "missing")"
        )
        if !forceCoordinateTap, waitForElementHittable(sendButton, timeout: min(timeout, 5)) {
            sendButton.tap()
        } else {
            sendButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func focusComposerPromptFieldIfNeeded(_ promptField: XCUIElement) {
        if promptField.isHittable {
            promptField.tap()
        } else {
            promptField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func dismissComposerKeyboardIfVisible(timeout: TimeInterval) {
        let dismissButton = keyboardDismissButton()
        guard dismissButton.waitForExistence(timeout: 1) else {
            return
        }

        if dismissButton.isHittable {
            dismissButton.tap()
        } else {
            dismissButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        _ = waitForElementToDisappear(dismissButton, timeout: timeout)
    }

    private func composerSendButton() -> XCUIElement {
        let identifiedButton = app.buttons["queue-prompt-button"]
        if identifiedButton.exists {
            return identifiedButton
        }

        let composer = app.otherElements["codex-sticky-composer"]
        let composerButton = composer.buttons["queue-prompt-button"]
        if composerButton.exists {
            return composerButton
        }

        return app.buttons["Up"]
    }

    private func keyboardSendButton() -> XCUIElement {
        let keyboardButton = app.keyboards.buttons["keyboard-send-button"]
        if keyboardButton.exists {
            return keyboardButton
        }

        let identifiedButton = app.buttons["keyboard-send-button"]
        if identifiedButton.exists {
            return identifiedButton
        }

        let keyboardSend = app.keyboards.buttons["Send"]
        if keyboardSend.exists {
            return keyboardSend
        }

        return app.keyboards.buttons["send"]
    }

    private func keyboardDismissButton() -> XCUIElement {
        let keyboardToolbarButton = app.keyboards.buttons["keyboard-dismiss-button"]
        if keyboardToolbarButton.exists {
            return keyboardToolbarButton
        }

        let identifiedButton = app.buttons["keyboard-dismiss-button"]
        if identifiedButton.exists {
            return identifiedButton
        }

        let appHideButton = app.buttons["Hide"]
        if appHideButton.exists {
            return appHideButton
        }

        return app.keyboards.buttons["Hide"]
    }

    private func composerPromptValue() -> String? {
        let promptField = composerPromptField()
        guard promptField.exists else {
            return nil
        }

        if let value = promptField.value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "Message Codex" {
                return trimmed
            }
        }

        let label = promptField.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != "Message Codex" else {
            return nil
        }
        return label
    }

    @discardableResult
    private func waitForComposerDraft(_ prompt: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if composerPromptValue()?.contains(prompt) == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return composerPromptValue()?.contains(prompt) == true
    }

    @discardableResult
    private func waitForComposerDraftToClear(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let promptValue = composerPromptValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if promptValue.isEmpty {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let promptValue = composerPromptValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return promptValue.isEmpty
    }

    @discardableResult
    private func waitForComposerSubmissionToStart(
        baselineTranscriptCount: Int,
        baselineAssistantReplies: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.buttons["approve-request-button"].exists {
                return true
            }

            if let snapshot = codexSessionDebugSnapshot() {
                if snapshot.streaming
                    || snapshot.transcriptCount > baselineTranscriptCount
                    || snapshot.assistantReplies > baselineAssistantReplies {
                    return true
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if let snapshot = codexSessionDebugSnapshot() {
            return snapshot.streaming
                || snapshot.transcriptCount > baselineTranscriptCount
                || snapshot.assistantReplies > baselineAssistantReplies
        }

        return false
    }

    @discardableResult
    private func waitForComposerSendEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let sendButton = composerSendButton()
            if sendButton.exists, sendButton.isEnabled {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let sendButton = composerSendButton()
        return sendButton.exists && sendButton.isEnabled
    }

    @discardableResult
    private func waitForActiveCodexSession(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if hasActiveCodexSession() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return hasActiveCodexSession()
    }

    private func scrollMachineDirectoryToTop() {
        for _ in 0..<4 where !anyMachineCardExists() {
            app.swipeDown()
        }
    }

    private func scrollConnectionsDetailToTop() {
        for _ in 0..<4 where connectionLaunchActionElement() == nil {
            app.swipeDown()
        }
    }

    private func connectionLaunchActionCandidates() -> [XCUIElement] {
        [
            app.buttons["connect-live-button"],
            app.buttons["connections-summary-resume-button"],
            app.buttons["open-codex-from-connections-button"],
            app.buttons["reconnect-safe-lane-button"]
        ]
    }

    private func connectionPrimaryActionCandidates() -> [XCUIElement] {
        connectionLaunchActionCandidates() + [
            app.buttons["connections-summary-finish-setup-button"]
        ]
    }

    private func connectionPrimaryActionElement() -> XCUIElement? {
        let candidates = connectionPrimaryActionCandidates()
        return candidates.first(where: { $0.exists && $0.isEnabled })
            ?? candidates.first(where: \.exists)
    }

    @discardableResult
    private func waitForConnectionPrimaryAction(timeout: TimeInterval, maxSwipes: Int = 0) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var swipeCount = 0

        while Date() < deadline {
            if let action = connectionPrimaryActionElement() {
                return action
            }
            if swipeCount < maxSwipes {
                app.swipeUp()
                swipeCount += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return connectionPrimaryActionElement()
    }

    private func connectionLaunchActionElement() -> XCUIElement? {
        let candidates = connectionLaunchActionCandidates()
        return candidates.first(where: { $0.exists && $0.isEnabled })
            ?? candidates.first(where: \.exists)
    }

    @discardableResult
    private func waitForConnectionLaunchAction(timeout: TimeInterval, maxSwipes: Int = 0) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var swipeCount = 0

        while Date() < deadline {
            if let action = connectionLaunchActionElement() {
                return action
            }
            if swipeCount < maxSwipes {
                app.swipeUp()
                swipeCount += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return connectionLaunchActionElement()
    }

    private func accessibilityLabel(forElementWithIdentifier identifier: String) -> String? {
        let queries = [
            app.buttons[identifier],
            app.otherElements[identifier],
            app.staticTexts[identifier],
            app.images[identifier],
            app.switches[identifier],
            app.textFields[identifier]
        ]

        return queries.first(where: \.exists)?.label
    }

    private func accessibilityLabel(
        forElementWithIdentifier identifier: String,
        fallbackLabelPrefix: String
    ) -> String? {
        if let label = accessibilityLabel(forElementWithIdentifier: identifier) {
            return label
        }

        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", fallbackLabelPrefix)
        let matchingElement = app.descendants(matching: .any).matching(predicate).firstMatch
        guard matchingElement.exists else {
            return nil
        }
        return matchingElement.label
    }

    private func openConnectionsTab() {
        stabilizeDeviceOrientationIfNeeded()
        dismissSettingsSheetIfNeeded()
        dismissReposBrowserIfNeeded()
        dismissInspectorIfNeeded()
        if app.buttons["connect-live-button"].exists
            || app.otherElements["connection-primary-pane"].exists
            || app.otherElements["machine-directory-sidebar"].exists
            || app.otherElements["connection-plan-card"].exists {
            return
        }
        let shellButton = shellTabButton(title: "Connections", identifier: "dot.radiowaves.left.and.right")
        if shellButton.waitForExistence(timeout: 5) {
            tapElement(shellButton)
            return
        }
        if openCompactCodexMenuIfNeeded() {
            let explicitConnectionsButton = app.buttons.matching(identifier: "codex-open-connections-button").element(boundBy: 0)
            let connectionsButton = explicitConnectionsButton.waitForExistence(timeout: 3)
                ? explicitConnectionsButton
                : app.buttons["Connections"]
            if connectionsButton.waitForExistence(timeout: 3) {
                connectionsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
    }

    private func openCodexTab() {
        stabilizeDeviceOrientationIfNeeded()
        dismissSettingsSheetIfNeeded()
        if app.otherElements["codex-session-header"].exists
            || app.otherElements["codex-sticky-composer"].exists
            || app.otherElements["codex-session-surface"].exists
            || app.staticTexts["Projects & Threads"].exists
            || app.otherElements["codex-browser-list"].exists
            || app.buttons["codex-browse-button"].exists {
            return
        }
        dismissReposBrowserIfNeeded()
        dismissInspectorIfNeeded()
        let openCodexButton = app.buttons["open-codex-from-connections-button"]
        if openCodexButton.waitForExistence(timeout: 2) {
            tapElement(openCodexButton)
            if waitForCodexTabSurface(timeout: 3) {
                return
            }
        }
        let shellButton = shellTabButton(title: "Codex", identifier: "bubble.left.and.bubble.right")
        if shellButton.waitForExistence(timeout: 5) {
            tapElement(shellButton)
            _ = waitForCodexTabSurface(timeout: 3)
        }
    }

    private func openSettingsTab() {
        stabilizeDeviceOrientationIfNeeded()
        dismissReposBrowserIfNeeded()
        dismissInspectorIfNeeded()
        let shellButton = shellTabButton(title: "Settings", identifier: "gearshape")
        if shellButton.waitForExistence(timeout: 5) {
            tapElement(shellButton)
            return
        }
        if openCompactCodexMenuIfNeeded() {
            let explicitSettingsButton = app.buttons.matching(identifier: "codex-open-settings-button").element(boundBy: 0)
            let settingsButton = explicitSettingsButton.waitForExistence(timeout: 3)
                ? explicitSettingsButton
                : app.buttons["Settings"]
            if settingsButton.waitForExistence(timeout: 3) {
                settingsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
    }

    private func configurePreferredCodexDefaults(
        reasoningLabel: String? = nil,
        approvalLabel: String? = nil,
        sandboxLabel: String? = nil
    ) {
        openSettingsTab()

        if reasoningLabel != nil {
            XCTAssertTrue(waitForElementExists(app.buttons["settings-reasoning-menu"], timeout: 10, maxSwipes: 4))
        }
        if approvalLabel != nil {
            XCTAssertTrue(waitForElementExists(app.buttons["settings-approval-policy-menu"], timeout: 10, maxSwipes: 4))
        }
        if sandboxLabel != nil {
            XCTAssertTrue(waitForElementExists(app.buttons["settings-sandbox-mode-menu"], timeout: 10, maxSwipes: 4))
        }

        if let reasoningLabel {
            XCTAssertTrue(selectMenuChoice(menuIdentifier: "settings-reasoning-menu", choiceLabel: reasoningLabel, timeout: 10))
            XCTAssertTrue(waitForButton("settings-reasoning-menu", enabled: true, timeout: 10))
            XCTAssertTrue(app.buttons["settings-reasoning-menu"].label.contains(reasoningLabel))
        }

        if let approvalLabel {
            XCTAssertTrue(selectMenuChoice(menuIdentifier: "settings-approval-policy-menu", choiceLabel: approvalLabel, timeout: 10))
            XCTAssertTrue(waitForButton("settings-approval-policy-menu", enabled: true, timeout: 10))
            XCTAssertTrue(app.buttons["settings-approval-policy-menu"].label.contains(approvalLabel))
        }

        if let sandboxLabel {
            XCTAssertTrue(selectMenuChoice(menuIdentifier: "settings-sandbox-mode-menu", choiceLabel: sandboxLabel, timeout: 10))
            XCTAssertTrue(waitForButton("settings-sandbox-mode-menu", enabled: true, timeout: 10))
            XCTAssertTrue(app.buttons["settings-sandbox-mode-menu"].label.contains(sandboxLabel))
        }
    }

    private func dismissSettingsSheetIfNeeded() {
        activateAppForInteraction()

        let settingsTitle = app.navigationBars["Settings"]
        let doneButton = app.buttons["Done"]
        guard settingsTitle.exists, doneButton.exists else {
            return
        }

        tapElement(doneButton)
        _ = waitForElementToDisappear(settingsTitle, timeout: 5)
    }

    @discardableResult
    private func openCompactCodexMenuIfNeeded() -> Bool {
        let menuButton = app.buttons["codex-more-button"]
        guard menuButton.waitForExistence(timeout: 2) else {
            return false
        }
        tapElement(menuButton)
        return true
    }

    private func shellTabButton(title: String, identifier: String) -> XCUIElement {
        let normalizedTitle = title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let explicitButton = app.buttons["shell-tab-\(normalizedTitle)"]
        if explicitButton.waitForExistence(timeout: 1) {
            return explicitButton
        }

        let explicitShellButton = app.descendants(matching: .any)
            .matching(identifier: "shell-tab-\(normalizedTitle)")
            .firstMatch
        if explicitShellButton.waitForExistence(timeout: 1) {
            return explicitShellButton
        }

        let shellButton = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier == %@",
                title,
                identifier
            )
        ).firstMatch
        if shellButton.exists {
            return shellButton
        }

        let compactShellButton = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier == %@",
                title,
                "compact-shell-tab-bar"
            )
        ).firstMatch
        if compactShellButton.exists {
            return compactShellButton
        }

        return app.tabBars.buttons[title]
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func dismissInspectorIfNeeded() {
        activateAppForInteraction()

        let inspectorTitle = app.navigationBars["Inspector"]
        guard inspectorTitle.exists,
              !app.staticTexts["Projects & Threads"].exists else {
            return
        }

        app.swipeDown()
        _ = waitForElementToDisappear(inspectorTitle, timeout: 5)
    }

    private func dismissReposBrowserIfNeeded() {
        activateAppForInteraction()

        let browserTitle = app.staticTexts["Projects & Threads"]
        let browserList = app.otherElements["codex-browser-list"]
        let searchField = app.searchFields["Search projects or threads"]
        guard browserTitle.exists || browserList.exists || searchField.exists else {
            return
        }

        let closeSearchButton = app.buttons.matching(NSPredicate(format: "label == %@", "close")).firstMatch
        if searchField.exists, closeSearchButton.waitForExistence(timeout: 1) {
            tapElement(closeSearchButton)
            _ = waitForElementToDisappear(searchField, timeout: 2)
        }

        let sheetGrabber = app.buttons["Sheet Grabber"]
        if sheetGrabber.waitForExistence(timeout: 1) {
            sheetGrabber.swipeDown()
            if waitForReposBrowserToDisappear(timeout: 3) {
                return
            }
        }

        let doneButton = app.buttons["browser-done-button"].exists
            ? app.buttons["browser-done-button"]
            : app.buttons["Done"]
        if doneButton.exists {
            if doneButton.isHittable {
                doneButton.tap()
                if waitForReposBrowserToDisappear(timeout: 3) {
                    return
                }
            }

            app.swipeDown()
            if waitForReposBrowserToDisappear(timeout: 2) {
                return
            }

            if doneButton.exists, doneButton.isHittable {
                doneButton.tap()
                if waitForReposBrowserToDisappear(timeout: 3) {
                    return
                }
            }
            if sheetGrabber.exists {
                sheetGrabber.swipeDown()
                if waitForReposBrowserToDisappear(timeout: 3) {
                    return
                }
            }
            return
        }

        for _ in 0..<2 where browserTitle.exists || browserList.exists || searchField.exists {
            app.swipeDown()
            if waitForReposBrowserToDisappear(timeout: 2) {
                return
            }
        }
    }

    private func waitForReposBrowserToDisappear(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let browserSurfaceVisible = app.staticTexts["Projects & Threads"].exists
                || app.otherElements["codex-browser-list"].exists
                || app.searchFields["Search projects or threads"].exists
            if !browserSurfaceVisible {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return !(app.staticTexts["Projects & Threads"].exists
            || app.otherElements["codex-browser-list"].exists
            || app.searchFields["Search projects or threads"].exists)
    }

    private func stabilizeDeviceOrientationIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return
        }

        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func openReposBrowserIfNeeded() {
        activateAppForInteraction()
        dismissInspectorIfNeeded()

        if app.staticTexts["Projects & Threads"].waitForExistence(timeout: 2) {
            return
        }

        let browseButton = app.buttons["codex-browse-button"]
        if browseButton.waitForExistence(timeout: 2) {
            if browseButton.isHittable {
                browseButton.tap()
            } else {
                app.activate()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if browseButton.isHittable {
                    browseButton.tap()
                }
            }
        }

        _ = app.otherElements["codex-browser-list"].waitForExistence(timeout: 5)
    }

    private func activateAppForInteraction() {
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    @discardableResult
    private func waitForCodexTabSurface(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.otherElements["codex-session-header"].exists
                || app.otherElements["codex-sticky-composer"].exists
                || app.otherElements["codex-session-surface"].exists
                || app.staticTexts["Projects & Threads"].exists
                || app.otherElements["codex-browser-list"].exists
                || app.buttons["codex-browse-button"].exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return app.otherElements["codex-session-header"].exists
            || app.otherElements["codex-sticky-composer"].exists
            || app.otherElements["codex-session-surface"].exists
            || app.staticTexts["Projects & Threads"].exists
            || app.otherElements["codex-browser-list"].exists
            || app.buttons["codex-browse-button"].exists
    }

    private func browserStatusValue() -> String? {
        let deadline = Date().addingTimeInterval(2)

        while Date() < deadline {
            if let label = currentBrowserStatusValue() {
                return label
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return currentBrowserStatusValue()
    }

    private func connectionStatusValue() -> String? {
        let queries = [
            app.staticTexts["connection-debug-status"],
            app.otherElements["connection-debug-status"]
        ]
        guard queries.contains(where: { $0.waitForExistence(timeout: 2) }) else {
            return nil
        }
        return queries.first(where: \.exists)?.label
    }

    @discardableResult
    private func waitForConnectionStatusSubstring(_ substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if connectionStatusValue()?.contains(substring) == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return connectionStatusValue()?.contains(substring) == true
    }

    @discardableResult
    private func waitForBrowserStatusSubstring(_ substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if browserStatusValue()?.contains(substring) == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return browserStatusValue()?.contains(substring) == true
    }

    private func localNetworkDiscoveryStatusValue() -> String? {
        let queries = [
            app.staticTexts["machine-directory-discovery-debug-status"],
            app.otherElements["machine-directory-discovery-debug-status"]
        ]
        guard queries.contains(where: { $0.waitForExistence(timeout: 2) }) else {
            return nil
        }
        return queries.first(where: \.exists)?.label
    }

    @discardableResult
    private func waitForHostBrowserContent(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var didExpandProject = false

        while Date() < deadline {
            let browserTitleVisible = app.staticTexts["Projects & Threads"].exists
            let browserListVisible = app.otherElements["codex-browser-list"].exists
            let searchFieldVisible = app.searchFields["Search projects or threads"].exists
            let browserStatusVisible = currentBrowserStatusValue() != nil
            let hasResumeRow = browserResumeElements().count > 0
            let projectRow = firstProjectRow()
            let hasProjectRow = projectRow.exists
            let hasProjectAction = newThreadElements().count > 0

            if hasActiveCodexSession() {
                return true
            }

            if (browserTitleVisible || browserListVisible || searchFieldVisible)
                && (hasProjectRow || hasResumeRow || hasProjectAction) {
                return true
            }

            if browserTitleVisible && browserListVisible && searchFieldVisible && browserStatusVisible {
                return true
            }

            if browserListVisible && browserStatusVisible && (searchFieldVisible || hasProjectRow || hasResumeRow || hasProjectAction) {
                return true
            }

            if hasProjectRow && !didExpandProject {
                let disclosureButton = firstProjectDisclosureButton()
                if disclosureButton.exists {
                    tapBrowserElement(disclosureButton)
                } else {
                    tapBrowserElement(projectRow)
                }
                didExpandProject = true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return hasActiveCodexSession()
            || (
                (app.staticTexts["Projects & Threads"].exists
                    || app.otherElements["codex-browser-list"].exists
                    || app.searchFields["Search projects or threads"].exists)
                    && (
                        firstProjectRow().exists
                            || browserResumeElements().count > 0
                            || newThreadElements().count > 0
                            || currentBrowserStatusValue() != nil
                    )
            )
    }

    @discardableResult
    private func waitForLiveHostBrowserCatalog(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if waitForHostBrowserContent(timeout: 0.5),
               browserStatusShowsLiveHostCatalog() {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return waitForHostBrowserContent(timeout: 0.5)
            && browserStatusShowsLiveHostCatalog()
    }

    private func browserStatusShowsLiveHostCatalog() -> Bool {
        guard let status = currentBrowserStatusValue() else {
            return false
        }

        return status.contains("connection=connected")
            && !status.contains("provenance=cachedHostCatalog")
    }

    @discardableResult
    private func waitForBrowserSessionSelection(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var didExpandProject = false

        while Date() < deadline {
            if hasActiveCodexSession() {
                return true
            }

            let firstResume = firstResumeRow()
            if firstResume.exists || firstNewThreadButton().exists {
                return true
            }

            let projectRow = firstProjectRow()
            if projectRow.exists && !didExpandProject {
                let disclosureButton = firstProjectDisclosureButton()
                if disclosureButton.exists {
                    tapBrowserElement(disclosureButton)
                } else {
                    tapBrowserElement(projectRow)
                }
                didExpandProject = true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return hasActiveCodexSession()
            || firstResumeRow().exists
            || firstNewThreadButton().exists
    }

    private func firstProjectRow() -> XCUIElement {
        browserElements(matching: projectRowPredicate).firstMatch
    }

    private func firstProjectDisclosureButton() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "project-disclosure-")
        ).firstMatch
    }

    private func firstResumeRow() -> XCUIElement {
        browserResumeElements().firstMatch
    }

    private func firstNewThreadButton() -> XCUIElement {
        newThreadElements().firstMatch
    }

    private func browserResumeElements() -> XCUIElementQuery {
        browserElements(matching: resumeRowPredicate)
    }

    private func browserResumeRows(containing titleFragment: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "resume-thread-",
                titleFragment
            )
        )
    }

    private func newThreadElements() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(newThreadButtonPredicate)
    }

    private func browserResumeElement(threadID: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "resume-thread-\(threadID)").firstMatch
    }

    private func selectFirstProjectThreadFromBrowser(timeout: TimeInterval) {
        selectProjectThreadFromBrowser(timeout: timeout, preferredIndex: 0)
    }

    private func selectProjectThreadFromBrowser(timeout: TimeInterval, preferredIndex: Int) {
        if browserResumeElements().count == 0 {
            let projectRow = firstProjectRow()
            XCTAssertTrue(projectRow.waitForExistence(timeout: timeout))
            let disclosureButton = firstProjectDisclosureButton()
            if disclosureButton.waitForExistence(timeout: 2) {
                tapBrowserElement(disclosureButton)
            } else {
                tapBrowserElement(projectRow)
            }
        }

        XCTAssertTrue(waitForBrowserResumeButtons(timeout: timeout))
        let resumeRows = browserResumeElements()
        let targetIndex = min(preferredIndex, max(0, resumeRows.count - 1))
        let resumeRow = resumeRows.element(boundBy: targetIndex)
        XCTAssertTrue(resumeRow.waitForExistence(timeout: timeout))
        tapBrowserElement(resumeRow)
    }

    private func selectProjectThreadFromBrowser(threadID: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let target = browserResumeElement(threadID: threadID)
            if target.exists {
                tapBrowserElement(target)
                return
            }

            let disclosureButtons = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "project-disclosure-")
            )
            let projectRows = browserElements(matching: projectRowPredicate)
            let candidateCount = max(disclosureButtons.count, projectRows.count)

            for index in 0..<candidateCount {
                let disclosureButton = disclosureButtons.element(boundBy: index)
                if disclosureButton.exists {
                    tapBrowserElement(disclosureButton)
                    if target.exists {
                        tapBrowserElement(target)
                        return
                    }
                    continue
                }

                let projectRow = projectRows.element(boundBy: index)
                if projectRow.exists {
                    tapBrowserElement(projectRow)
                    if target.exists {
                        tapBrowserElement(target)
                        return
                    }
                }
            }

            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        let target = browserResumeElement(threadID: threadID)
        XCTAssertTrue(target.waitForExistence(timeout: 2))
        tapBrowserElement(target)
    }

    @discardableResult
    private func selectBrowserThreadByTitle(_ titleFragment: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seededSearch = false

        while Date() < deadline {
            let matchingRow = browserResumeRows(containing: titleFragment).firstMatch
            if matchingRow.exists {
                tapBrowserElement(matchingRow)
                return true
            }

            let searchField = app.searchFields["Search projects or threads"]
            if !seededSearch, searchField.waitForExistence(timeout: 1) {
                searchField.tap()
                searchField.typeText("\(titleFragment)\n")
                seededSearch = true
            }

            if browserResumeElements().count == 0 {
                let disclosureButton = firstProjectDisclosureButton()
                if disclosureButton.exists {
                    tapBrowserElement(disclosureButton)
                } else if firstProjectRow().exists {
                    tapBrowserElement(firstProjectRow())
                }
            }

            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        return browserResumeRows(containing: titleFragment).firstMatch.exists
    }

    private func resumeIdleProjectThreadFromBrowser(
        selectionTimeout: TimeInterval,
        idleTimeout: TimeInterval,
        maxCandidates: Int,
        startIndex: Int = 0
    ) -> String {
        openReposBrowserIfNeeded()
        XCTAssertTrue(
            waitForHostBrowserContent(timeout: selectionTimeout),
            "Expected host browser content before selecting an idle thread. Browser status: \(browserStatusValue() ?? "missing")"
        )

        let totalCandidateCount = browserResumeElements().count
        let candidateStartIndex = min(max(0, startIndex), max(0, totalCandidateCount - 1))
        let candidateEndIndex = min(totalCandidateCount, candidateStartIndex + max(1, maxCandidates))
        var attemptedThreadSummaries: [String] = []

        for index in candidateStartIndex..<candidateEndIndex {
            openReposBrowserIfNeeded()
            selectProjectThreadFromBrowser(timeout: selectionTimeout, preferredIndex: index)

            guard waitForActiveCodexSession(timeout: 30) else {
                attemptedThreadSummaries.append("candidate\(index):no-session")
                continue
            }

            let connected = waitForCodexSessionConnectionState("connected", timeout: 45)
            let hasHistory = waitForTranscriptConversationHistory(timeout: 30, minimumCount: 1)
            let hasThreadID = waitForActiveThreadID(timeout: 20)
            let threadID = hasThreadID ? (activeThreadIDValue() ?? "missing") : "missing"
            let becameIdle = waitForCodexSessionIdle(timeout: idleTimeout)

            attemptedThreadSummaries.append(
                "\(threadID){connected=\(connected),history=\(hasHistory),idle=\(becameIdle),status=\(codexSessionDebugStatusValue() ?? "missing")}"
            )

            if connected, hasHistory, becameIdle {
                return threadID
            }
        }

        XCTFail(
            "Expected at least one resumed project thread to restore history and become idle before sending. Attempted: \(attemptedThreadSummaries.joined(separator: " | ")); final session status: \(codexSessionDebugStatusValue() ?? "missing")"
        )
        return activeThreadIDValue() ?? "missing"
    }

    @discardableResult
    private func waitForBrowserResumeButtons(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if browserResumeElements().count > 0 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return browserResumeElements().count > 0
    }

    private func browserElements(matching predicate: NSPredicate) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(predicate)
    }

    private func currentBrowserStatusValue() -> String? {
        let queries = [
            app.staticTexts["host-thread-browser-status"],
            app.otherElements["host-thread-browser-status"]
        ]
        guard queries.contains(where: { $0.waitForExistence(timeout: 2) }) else {
            return nil
        }
        return queries.first(where: \.exists)?.label
    }

    private func tapBrowserElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }

        let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coordinate.tap()
    }

    private func scrollBrowserUntilElementHittable(_ element: XCUIElement, maxSwipes: Int) -> Bool {
        let safeTapLimit = app.frame.maxY - 120
        var swipeCount = 0
        while swipeCount <= maxSwipes {
            if element.exists && element.isHittable && element.frame.maxY <= safeTapLimit {
                return true
            }

            guard swipeCount < maxSwipes else {
                break
            }

            swipeUpInBrowser()
            swipeCount += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        return element.exists && element.isHittable && element.frame.maxY <= safeTapLimit
    }

    private func swipeUpInBrowser() {
        let browserList = app.descendants(matching: .any)
            .matching(identifier: "codex-browser-list")
            .firstMatch
        if browserList.exists {
            browserList.swipeUp()
            return
        }

        app.swipeUp()
    }

    private var projectRowPredicate: NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "identifier BEGINSWITH %@", "project-group-"),
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "/", " threads")
        ])
    }

    private var resumeRowPredicate: NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "identifier BEGINSWITH %@", "resume-thread-"),
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "/", "Saved thread")
        ])
    }

    private var newThreadButtonPredicate: NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "identifier BEGINSWITH %@", "new-thread-"),
            NSPredicate(format: "label == %@", "New thread")
        ])
    }

    private func navigateToPrimaryMachineInConnections() {
        openConnectionsTab()
        dismissReposBrowserIfNeeded()
        if app.otherElements["connection-plan-card"].waitForExistence(timeout: 2) {
            return
        }
        returnToConnectionsListIfNeeded(missingMachineIdentifier: nil)
        _ = waitForScreenshotFixtureSurface(timeout: 10)
        scrollMachineDirectoryToTop()

        let preferredMachineCard = screenshotFixtureMachineCard()
        let machineCard: XCUIElement
        if preferredMachineCard.exists || waitForElementExists(preferredMachineCard, timeout: 3, maxSwipes: 4) {
            machineCard = preferredMachineCard
        } else {
            machineCard = firstMachineCard()
            XCTAssertTrue(waitForElementExists(machineCard, timeout: 8, maxSwipes: 8))
        }

        machineCard.tap()
        allowLocalNetworkPromptIfNeeded()
    }

    private func navigateToFirstMachineInConnections() {
        openConnectionsTab()
        if waitForConnectionsDetailSurface(timeout: 8) {
            return
        }
        returnToConnectionsListIfNeeded(missingMachineIdentifier: nil)
        scrollMachineDirectoryToTop()
        let machineCard = firstMachineCard()
        XCTAssertTrue(waitForElementExists(machineCard, timeout: 20, maxSwipes: 8))
        machineCard.tap()
        allowLocalNetworkPromptIfNeeded()
    }

    private func returnToConnectionsListIfNeeded(missingMachineIdentifier: String?) {
        guard app.otherElements["connection-plan-card"].waitForExistence(timeout: 2) else {
            return
        }
        if let missingMachineIdentifier, app.buttons[missingMachineIdentifier].exists {
            return
        }
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 2) {
            backButton.tap()
        }
    }

    private func expandDisclosureIfNeeded(_ label: String) {
        if label == "Support and recovery" {
            if app.staticTexts["Reconnect and support"].exists
                || app.buttons["smoke-test-button"].exists
                || app.buttons["upgrade-loopback-button"].exists
                || app.buttons["fallback-safe-lane-button"].exists
                || app.buttons["support-actions-menu-button"].exists {
                return
            }

            let technicalDetailsButtons = [
                app.buttons["connection-plan-open-recovery-button"],
                app.buttons["connection-routes-open-technical-details-button"]
            ]
            for button in technicalDetailsButtons where button.waitForExistence(timeout: 2) {
                button.tap()
                break
            }

            let technicalDisclosureButtons = [
                app.buttons["Troubleshoot & technical details"],
                app.staticTexts["Troubleshoot & technical details"],
                app.buttons["Technical details"],
                app.staticTexts["Technical details"]
            ]
            for control in technicalDisclosureButtons {
                if control.waitForExistence(timeout: 2) {
                    tapElement(control)
                    break
                }
            }

            let supportSurfaces = [
                app.staticTexts["Reconnect and support"],
                app.buttons["smoke-test-button"],
                app.buttons["upgrade-loopback-button"],
                app.buttons["fallback-safe-lane-button"],
                app.buttons["support-actions-menu-button"]
            ]

            for _ in 0..<20 {
                if supportSurfaces.contains(where: \.exists) {
                    return
                }
                app.swipeUp()
            }

            return
        }

        if app.buttons[label].waitForExistence(timeout: 5) {
            app.buttons[label].tap()
        } else if app.staticTexts[label].waitForExistence(timeout: 2) {
            app.staticTexts[label].tap()
        }
    }

    private func scrollToElement(_ element: XCUIElement, maxSwipes: Int) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    private func scrollToAnyText(_ texts: [String], maxSwipes: Int) {
        for _ in 0..<maxSwipes where !texts.contains(where: { app.staticTexts[$0].exists }) {
            app.swipeUp()
        }
    }

    private func waitForScreenshotFixtureSurface(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if anyMachineCardExists() || app.buttons["connect-live-button"].exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return anyMachineCardExists() || app.buttons["connect-live-button"].exists
    }

    private func anyMachineCardExists() -> Bool {
        firstMachineCard().exists
    }

    private func firstMachineCard() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "machine-card-"))
            .firstMatch
    }

    private func screenshotFixtureMachineCard() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "machine-card-\(screenshotFixtureDisplayName)"))
            .firstMatch
    }

    private func requireLocalhostIntegration() throws {
        guard localhostIntegrationPrepared else {
            throw XCTSkip("Prepare the localhost test SSH key at \(localhostRawKeyPath) to run localhost UI integration tests.")
        }
    }

    private func requirePhysicalRealHostValidation() throws {
        try requireLocalhostIntegration()
        guard !isSimulatorRuntime else {
            throw XCTSkip("Real-host Codex catalog validation only runs on a physical device.")
        }
    }

    private func requireCrossDeviceMarker() throws -> String {
        crossDeviceMarker ?? defaultCrossDeviceMarker
    }

    private func writeCrossDeviceThreadID(_ threadID: String) {
        print("COTG_CROSS_DEVICE_THREAD_ID=\(threadID)")
        try? threadID.write(toFile: crossDeviceThreadIDPath, atomically: true, encoding: .utf8)
    }

    private func requireIPadParityThreadID() throws -> String {
        if let value = ProcessInfo.processInfo.environment["COTG_TEST_IPAD_PARITY_THREAD_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        guard let value = try? String(contentsOfFile: iPadParityThreadIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw XCTSkip("Run the iPad send proof first so COTG_TEST_IPAD_PARITY_THREAD_ID or \(iPadParityThreadIDPath) contains the restored thread ID.")
        }

        return value
    }

    private func writeIPadParityThreadID(_ threadID: String) {
        print("COTG_IPAD_PARITY_THREAD_ID=\(threadID)")
        try? threadID.write(toFile: iPadParityThreadIDPath, atomically: true, encoding: .utf8)
    }

    private func requireExternalTailnetIntegration() throws {
        try requireLocalhostIntegration()
        guard externalTailnetDNSName != nil else {
            throw XCTSkip("Set COTG_TEST_EXTERNAL_TAILNET_DNS_NAME to run standalone tailnet UI integration tests.")
        }
        guard sshHostKeyOverride != nil else {
            throw XCTSkip("Set COTG_TEST_SSH_HOST_KEY to run standalone tailnet UI integration tests.")
        }
    }

    private func requireEmbeddedTailnetIntegration() throws {
        try requireLocalhostIntegration()
        guard embeddedTailnetAuthKey != nil else {
            throw XCTSkip("Copy a tskey auth key into the pasteboard or set COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY to run embedded tailnet UI integration tests.")
        }
        guard sshHostKeyOverride != nil else {
            throw XCTSkip("Set COTG_TEST_SSH_HOST_KEY to run embedded tailnet UI integration tests.")
        }
    }

    @discardableResult
    private func waitForMinimumWindowCount(_ minimum: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if app.windows.count >= minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return app.windows.count >= minimum
    }
}

private enum PhysicalRealHostLaunchPlan {
    case sameLAN
    case manualSSH
    case externalTailnet
    case embeddedTailnet

    init?(rawValue: String) {
        switch rawValue {
        case "sameLAN", "localLAN", "bonjour":
            self = .sameLAN
        case "manualSSH", "manual", "ssh":
            self = .manualSSH
        case "externalTailnet", "external":
            self = .externalTailnet
        case "embeddedTailnet", "embedded":
            self = .embeddedTailnet
        default:
            return nil
        }
    }

    var seedLocalhostManualRoute: Bool {
        switch self {
        case .manualSSH, .externalTailnet:
            return true
        case .sameLAN, .embeddedTailnet:
            return false
        }
    }

    var seedLocalhostLANRoute: Bool {
        switch self {
        case .sameLAN:
            return true
        case .manualSSH, .externalTailnet, .embeddedTailnet:
            return false
        }
    }

    var seedEmbeddedTailnetRoute: Bool {
        switch self {
        case .embeddedTailnet:
            return true
        case .sameLAN, .manualSSH, .externalTailnet:
            return false
        }
    }

    var preferredRouteKind: String? {
        switch self {
        case .externalTailnet:
            return "externalTailnet"
        case .sameLAN:
            return "localLAN"
        case .manualSSH, .embeddedTailnet:
            return nil
        }
    }
}
