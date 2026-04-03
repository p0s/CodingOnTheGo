import XCTest
@testable import CompanionHost
import Notifications
import Persistence
import SharedModels

final class CompanionHostTests: XCTestCase {
    func testEnhancedModeRequiresReachableCompanion() {
        let status = CompanionPresenceStatus(
            isInstalled: true,
            isReachable: true,
            supportsEnhancedHostMode: true
        )

        XCTAssertTrue(status.readyForEnhancedMode)
    }

    func testPreviewSnapshotPublishesRoutes() {
        XCTAssertEqual(CompanionHostSnapshot.preview.publishedRoutes.count, 1)
        XCTAssertEqual(CompanionHostSnapshot.preview.sharedListenerState, .ready)
        XCTAssertEqual(CompanionHostSnapshot.preview.routeHealthCounts.healthy, 1)
        XCTAssertEqual(CompanionHostSnapshot.preview.recommendedPublishedRoute?.kind, .localLAN)
        XCTAssertEqual(CompanionHostSnapshot.preview.recommendation.state, .ready)
        XCTAssertNil(CompanionHostSnapshot.preview.directEndpoint)
        XCTAssertFalse(CompanionHostSnapshot.preview.capabilities.canExposeDirectEndpoint)
        XCTAssertFalse(CompanionHostSnapshot.preview.routeSummary.isEmpty)
    }

    func testRecommendationDoesNotClaimEnhancedModeWithoutDirectEndpoint() {
        let recommendation = CompanionHostSnapshot.preview.recommendation

        XCTAssertEqual(recommendation.state, .ready)
        XCTAssertEqual(recommendation.title, "Presence and route publishing are ready")
        XCTAssertTrue(recommendation.detail.contains("SSH safe lane remains the active transport"))
    }

    func testControllerRefreshAvoidsPublishingLoopbackOnlyDirectRoute() async throws {
        try requireLocalhostIntegration()
        let controller = CompanionServiceController(
            port: 9594,
            pidFileURL: URL(fileURLWithPath: "/tmp/cotg-companion-test.pid"),
            logFileURL: URL(fileURLWithPath: "/tmp/cotg-companion-test.log")
        )

        let snapshot = await controller.refreshSnapshot()
        XCTAssertFalse(snapshot.publishedRoutes.contains(where: { $0.kind == .companionDirect }))
        XCTAssertNil(snapshot.directEndpoint)
        if let publishedRoute = snapshot.publishedRoutes.first {
            XCTAssertEqual(publishedRoute.kind, .localLAN)
            XCTAssertFalse(publishedRoute.address.hasPrefix("127."))
        }
        XCTAssertFalse(snapshot.listenerSummary.isEmpty)
    }

    func testControllerCanStartAndStopListener() async throws {
        try requireLocalhostIntegration()
        let pidURL = URL(fileURLWithPath: "/tmp/cotg-companion-lifecycle.pid")
        let logURL = URL(fileURLWithPath: "/tmp/cotg-companion-lifecycle.log")
        let controller = CompanionServiceController(
            port: 9595,
            pidFileURL: pidURL,
            logFileURL: logURL
        )

        _ = try? await controller.stopSharedListener()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))

        let started = try await controller.startSharedListener()
        XCTAssertNotEqual(started.sharedListenerState, .stopped)
        XCTAssertNotEqual(started.sharedListenerState, .degraded)
        XCTAssertNil(started.directEndpoint)
        XCTAssertFalse(started.publishedRoutes.contains(where: { $0.kind == .companionDirect }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))

        let restarted = try await controller.startSharedListener()
        XCTAssertNotEqual(restarted.sharedListenerState, .stopped)
        XCTAssertNotEqual(restarted.sharedListenerState, .degraded)
        XCTAssertNil(restarted.directEndpoint)

        let stopped = try await controller.stopSharedListener()
        XCTAssertEqual(stopped.sharedListenerState, .stopped)
        XCTAssertNil(stopped.directEndpoint)
        XCTAssertFalse(stopped.publishedRoutes.contains(where: { $0.kind == .companionDirect }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
    }

    func testRecommendationOrderingFollowsSpecPriority() {
        let snapshot = CompanionHostSnapshot(
            hostDisplayName: "example-mac",
            presence: .init(isInstalled: true, isReachable: true, supportsEnhancedHostMode: true),
            publishedRoutes: [
                .init(kind: .localLAN, address: "192.168.1.24", health: .healthy),
                .init(kind: .embeddedTailnet, address: "100.64.0.8", health: .healthy),
                .init(kind: .manualSSH, address: "p.example.com", health: .healthy)
            ],
            sharedListenerState: .ready,
            capabilities: .init(
                canPublishRoutes: true,
                canWarmSharedListener: true,
                canExposeDirectEndpoint: false,
                canBridgeNotifications: false
            )
        )

        XCTAssertEqual(snapshot.recommendedPublishedRoute?.kind, .embeddedTailnet)
    }

    func testMetadataPublisherWritesSharedMachineDirectoryAndSyncMirror() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        let metadataURL = root.appending(path: "metadata.json")
        let syncURL = root.appending(path: "sync.json")
        let publisher = CompanionMetadataPublisher(
            metadataURL: metadataURL,
            syncMirrorURL: syncURL
        )

        let publication = try await publisher.publish(
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

        let snapshot = try await JSONMetadataStore().load(from: metadataURL)
        let machine = try XCTUnwrap(snapshot.machines.first)

        XCTAssertEqual(publication.publishedRouteCount, 1)
        XCTAssertEqual(machine.hostname, "example-mac.local")
        XCTAssertEqual(machine.capabilities.companionState, SharedListenerState.ready.rawValue)
        XCTAssertTrue(machine.routes.contains(where: { $0.publishedByCompanion && $0.kind == .localLAN }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncURL.path))
    }

    func testMetadataPublisherDoesNotCollapseDifferentHostsBySharedDisplayName() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        let metadataURL = root.appending(path: "metadata.json")
        let syncURL = root.appending(path: "sync.json")

        let existingSnapshot = MachineDirectorySnapshot(
            machines: [
                MachineRecord(
                    id: UUID(),
                    displayName: "example-mac",
                    hostname: "example-mac.local",
                    routes: [
                        RouteRecord(
                            kind: .localLAN,
                            label: "Local LAN",
                            ipAddress: "192.168.1.10",
                            health: .healthy,
                            publishedByCompanion: true,
                            discoverySource: .companionAdvertisement,
                            trustState: .trusted
                        )
                    ],
                    capabilities: HostCapabilitySnapshot(
                        remoteLoginEnabled: true,
                        codexInstalled: true,
                        supportsWebsocketListen: true
                    )
                )
            ],
            tailnetProfiles: [],
            recentSessions: [],
            preferences: UserPreferencesSnapshot()
        )
        try await JSONMetadataStore().save(existingSnapshot, to: metadataURL)

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

        let snapshot = try await JSONMetadataStore().load(from: metadataURL)
        XCTAssertEqual(snapshot.machines.count, 2)
    }

    func testMetadataPublisherRespectsPrivacyMode() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        let metadataURL = root.appending(path: "metadata.json")
        let syncURL = root.appending(path: "sync.json")

        let existingSnapshot = MachineDirectorySnapshot(
            machines: [],
            tailnetProfiles: [],
            recentSessions: [],
            preferences: UserPreferencesSnapshot(privacyMode: .privacy)
        )
        try await JSONMetadataStore().save(existingSnapshot, to: metadataURL)

        let publisher = CompanionMetadataPublisher(
            metadataURL: metadataURL,
            syncMirrorURL: syncURL
        )

        let publication = try await publisher.publish(
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

        let snapshot = try await JSONMetadataStore().load(from: metadataURL)
        let machine = try XCTUnwrap(snapshot.machines.first)

        XCTAssertNil(machine.capabilities.companionVersion)
        XCTAssertNil(machine.capabilities.hostOSVersion)
        XCTAssertTrue(publication.note.contains("reduced host metadata"))
    }

    func testControllerRefreshPublishesMetadataAndBridgesRouteRecovery() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        let metadataURL = root.appending(path: "metadata.json")
        let syncURL = root.appending(path: "sync.json")
        let outboxURL = root.appending(path: "outbox.json")
        let relayDirectory = root.appending(path: "relay")
        let publisher = CompanionMetadataPublisher(
            metadataURL: metadataURL,
            syncMirrorURL: syncURL
        )
        let notifications = BridgedNotificationCoordinator(
            outbox: JSONNotificationOutboxStore(url: outboxURL),
            bridgeSubmitter: FileRelayNotificationSubmitter(directoryURL: relayDirectory),
            localDeliverer: nil
        )
        let controller = CompanionServiceController(
            port: 9794,
            pidFileURL: root.appending(path: "listener.pid"),
            logFileURL: root.appending(path: "listener.log"),
            publisher: publisher,
            notificationCoordinator: notifications
        )

        let snapshot = await controller.refreshSnapshot()
        let metadata = try await JSONMetadataStore().load(from: metadataURL)

        XCTAssertEqual(snapshot.publication.publishedRouteCount, snapshot.publishedRoutes.count)
        XCTAssertEqual(snapshot.notificationBridge.mode, .fileRelay)
        XCTAssertEqual(snapshot.notificationBridge.deliveredCount, 1)
        XCTAssertEqual(metadata.machines.first?.hostname, snapshot.hostDisplayName)

        let relayFiles = try FileManager.default.contentsOfDirectory(atPath: relayDirectory.path)
        XCTAssertEqual(relayFiles.count, 1)
    }

    private func requireLocalhostIntegration() throws {
        guard ProcessInfo.processInfo.environment["COTG_ENABLE_LOCALHOST_INTEGRATION"] == "1" else {
            throw XCTSkip("Set COTG_ENABLE_LOCALHOST_INTEGRATION=1 to run companion localhost integration tests.")
        }
    }
}
