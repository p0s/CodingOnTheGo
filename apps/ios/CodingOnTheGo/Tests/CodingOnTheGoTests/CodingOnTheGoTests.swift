import AppState
import SharedModels
import XCTest

@MainActor
final class CodingOnTheGoTests: XCTestCase {
    private static let localhostHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHP8uqjK5csmT6YoapcfCqqAZEM/eqz4yY7AmJ1IBpx"

    func testFreshInstallStartsEmpty() {
        let model = AppModel()

        XCTAssertNil(model.selectedMachine)
        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertTrue(model.tailnetProfiles.isEmpty)
        XCTAssertTrue(model.recentSessions.isEmpty)
    }

    func testIOSRuntimeShowsLoopbackUpgradeLaneWhenSupported() {
        let model = AppModel(bootstrapSnapshot: .preview)

        XCTAssertTrue(model.showsLoopbackUpgradeFeature)
        XCTAssertTrue(model.connectionPlan.contains(where: { $0.lane == .sshForwardedLoopbackWebSocket }))
    }

    func testLocalhostSafeLaneConnectsOnSimulator() async throws {
        let rawKeyBase64: String
        if let inline = ProcessInfo.processInfo.environment["COTG_TEST_SSH_RAW_KEY_BASE64"],
           !inline.isEmpty {
            rawKeyBase64 = inline
        } else if let fallbackData = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/cotg_app_test_key.raw")) {
            rawKeyBase64 = fallbackData.base64EncodedString()
        } else {
            throw XCTSkip("Set COTG_TEST_SSH_RAW_KEY_BASE64 to run the localhost simulator integration test.")
        }

        let testRunID = UUID().uuidString
        let metadataPath = "/tmp/cotg-ios-unit-\(testRunID)-metadata.json"
        let syncPath = "/tmp/cotg-ios-unit-\(testRunID)-sync.json"
        let codexHomePath = "/tmp/cotg-ios-unit-\(testRunID)-codex-home/.codex"
        let workspaceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        setenv("UI_TESTING", "1", 1)
        setenv("COTG_ENABLE_LOCALHOST_INTEGRATION", "1", 1)
        setenv("COTG_DISABLE_AUTO_UPGRADE", "1", 1)
        setenv("COTG_TEST_SSH_HOST", "localhost", 1)
        setenv("COTG_TEST_SSH_USER", ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"] ?? "developer", 1)
        setenv("COTG_TEST_SSH_RAW_KEY_BASE64", rawKeyBase64, 1)
        setenv("COTG_TEST_SSH_HOST_KEY", Self.localhostHostKey, 1)
        setenv("COTG_METADATA_PATH", metadataPath, 1)
        setenv("COTG_SYNC_MIRROR_PATH", syncPath, 1)
        setenv("COTG_TEST_CODEX_HOME", codexHomePath, 1)
        setenv("COTG_WORKSPACE_ROOT", workspaceRoot, 1)
        defer {
            unsetenv("UI_TESTING")
            unsetenv("COTG_ENABLE_LOCALHOST_INTEGRATION")
            unsetenv("COTG_DISABLE_AUTO_UPGRADE")
            unsetenv("COTG_TEST_SSH_HOST")
            unsetenv("COTG_TEST_SSH_USER")
            unsetenv("COTG_TEST_SSH_RAW_KEY_BASE64")
            unsetenv("COTG_TEST_SSH_HOST_KEY")
            unsetenv("COTG_METADATA_PATH")
            unsetenv("COTG_SYNC_MIRROR_PATH")
            unsetenv("COTG_TEST_CODEX_HOME")
            unsetenv("COTG_WORKSPACE_ROOT")
        }

        let model = AppModel(sceneID: "ios-simulator-safe-lane")
        model.resetPersistedStateForUITests(seedLocalhostLANRoute: true)
        let machineID = try XCTUnwrap(model.selectedMachine?.id ?? model.machines.first?.id)
        model.select(machineID: machineID)
        model.connectLocalLoopback()

        let didConnect = try await waitUntil(timeoutNanoseconds: 60_000_000_000) {
            if case .connected = model.connectionState {
                return model.activeProtocolKind == .stdio
            }
            return false
        }
        let transcriptSummary = model.transcript.map(\.text).joined(separator: " | ")

        XCTAssertTrue(
            didConnect,
            "Simulator safe-lane connect never became ready. State: \(String(describing: model.connectionState)). Transcript: \(transcriptSummary)"
        )
        XCTAssertNil(model.hostThreadCatalogErrorSummary)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 200_000_000,
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
}
