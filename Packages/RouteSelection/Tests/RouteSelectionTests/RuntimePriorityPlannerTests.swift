import XCTest
@testable import RouteSelection
import SharedModels

final class RuntimePriorityPlannerTests: XCTestCase {
    private func machineWithEmbeddedAndExternalTailnet(
        embeddedHealth: RouteHealthStatus = .healthy,
        externalHealth: RouteHealthStatus = .healthy
    ) -> MachineRecord {
        let machineID = UUID()
        let embeddedID = UUID()
        let externalID = UUID()

        return MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: embeddedID,
            lastSuccessfulRouteID: externalID,
            routes: [
                RouteRecord(
                    id: embeddedID,
                    machineID: machineID,
                    kind: .embeddedTailnet,
                    label: "Embedded tailnet",
                    ipAddress: "100.94.10.8",
                    usernameHint: "developer",
                    tailnetProfileID: UUID(),
                    health: embeddedHealth,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: externalID,
                    machineID: machineID,
                    kind: .externalTailnet,
                    label: "External tailnet",
                    magicDNSName: "p.tail.ts.net",
                    usernameHint: "developer",
                    requiresExternalApp: true,
                    health: externalHealth,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: true
            )
        )
    }

    func testPlannerMaintainsSpecifiedRuntimeOrder() {
        let plan = RuntimePriorityPlanner.plan(for: .preview(machine: .preview))

        XCTAssertEqual(
            plan.map(\.lane),
            [
                .codexWebSocketEndpoint,
                .embeddedTailnet,
                .sameLAN,
                .sshBootstrap,
                .sshForwardedLoopbackWebSocket,
                .stdioAppServer,
                .manualRescue
            ]
        )
    }

    func testPlannerKeepsSSHForwardedWebSocketAsStandbyFallback() {
        let step = RuntimePriorityPlanner.plan(for: .preview(machine: .preview))[4]

        XCTAssertEqual(step.lane, .sshForwardedLoopbackWebSocket)
        XCTAssertEqual(step.readiness, .ready)
    }

    func testPlannerPreservesLayerSeparationMetadata() {
        let first = RuntimePriorityPlanner.plan(for: .preview(machine: .secondaryPreview)).first

        XCTAssertEqual(first?.route, .companionDirect)
        XCTAssertEqual(first?.bootstrap, .companionManaged)
        XCTAssertEqual(first?.protocolKind, .directEndpoint)
    }

    func testReconnectPrefersLastGoodReachableRoute() throws {
        let machine = MachineRecord.secondaryPreview
        let route = try XCTUnwrap(
            ReconnectPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: .companionDirect
            )
        )

        XCTAssertEqual(route.kind, .companionDirect)
    }

    func testReconnectFallsBackToLANBeforeExternalTailnet() throws {
        var machine = MachineRecord.preview
        machine.lastSuccessfulRouteID = nil
        machine.preferredRouteID = nil
        machine.routes.append(
            RouteRecord(
                kind: .externalTailnet,
                label: "Fallback external",
                magicDNSName: "fallback.tail.ts.net",
                usernameHint: "developer",
                requiresExternalApp: true,
                health: .healthy,
                discoverySource: .imported,
                trustState: .trusted
            )
        )

        guard let lanIndex = machine.routes.firstIndex(where: { $0.kind == .localLAN }),
              let externalIndex = machine.routes.firstIndex(where: { $0.kind == .externalTailnet }) else {
            XCTFail("Preview machine is missing expected routes.")
            return
        }

        if let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }) {
            machine.routes[embeddedIndex].health = .unavailable
        }
        machine.routes[lanIndex].health = .healthy
        machine.routes[externalIndex].health = .healthy
        if let manualIndex = machine.routes.firstIndex(where: { $0.kind == .manualSSH }) {
            machine.routes[manualIndex].isUserPinned = false
            machine.routes[manualIndex].health = .unavailable
        }

        let route = try XCTUnwrap(
            ReconnectPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: nil
            )
        )

        XCTAssertEqual(route.kind, .localLAN)
    }

    func testSSHBootstrapRouteKeepsActiveExternalTailnetWhenStillReachable() throws {
        var machine = machineWithEmbeddedAndExternalTailnet()
        guard let externalIndex = machine.routes.firstIndex(where: { $0.kind == .externalTailnet }),
              let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }) else {
            XCTFail("Fixture machine is missing expected routes.")
            return
        }

        machine.routes[externalIndex].health = .healthy
        machine.routes[embeddedIndex].health = .healthy

        let route = try XCTUnwrap(
            RouteEvaluationPlanner.sshBootstrapRoute(
                for: machine,
                lastKnownRouteKind: .externalTailnet,
                activeRouteID: machine.routes[externalIndex].id,
                externalTailnetAppInstalled: true
            )
        )

        XCTAssertEqual(route.id, machine.routes[externalIndex].id)
        XCTAssertEqual(route.kind, .externalTailnet)
    }

    func testSSHBootstrapRouteKeepsLastKnownExternalTailnetBeforeEmbeddedFallback() throws {
        var machine = machineWithEmbeddedAndExternalTailnet()
        guard let externalIndex = machine.routes.firstIndex(where: { $0.kind == .externalTailnet }),
              let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }) else {
            XCTFail("Fixture machine is missing expected routes.")
            return
        }

        machine.routes[externalIndex].health = .healthy
        machine.routes[embeddedIndex].health = .healthy

        let route = try XCTUnwrap(
            RouteEvaluationPlanner.sshBootstrapRoute(
                for: machine,
                lastKnownRouteKind: .externalTailnet,
                activeRouteID: nil,
                externalTailnetAppInstalled: true
            )
        )

        XCTAssertEqual(route.id, machine.routes[externalIndex].id)
        XCTAssertEqual(route.kind, .externalTailnet)
    }

    func testSSHBootstrapRouteUsesPreferredExternalTailnetWhenNoActiveRoute() throws {
        let machineID = UUID()
        let manualID = UUID()
        let externalID = UUID()
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: externalID,
            routes: [
                RouteRecord(
                    id: manualID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Manual SSH",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    isUserPinned: true,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: externalID,
                    machineID: machineID,
                    kind: .externalTailnet,
                    label: "External Tailnet",
                    magicDNSName: "p.tail.example.ts.net",
                    usernameHint: "developer",
                    requiresExternalApp: true,
                    health: .healthy,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: true
            )
        )

        let route = try XCTUnwrap(
            RouteEvaluationPlanner.sshBootstrapRoute(
                for: machine,
                lastKnownRouteKind: nil,
                activeRouteID: nil,
                externalTailnetAppInstalled: true
            )
        )

        XCTAssertEqual(route.id, externalID)
        XCTAssertEqual(route.kind, .externalTailnet)
    }

    func testSSHBootstrapRouteUsesPreferredReachableRouteBeforeEligibleManualFallback() throws {
        let machineID = UUID()
        let embeddedID = UUID()
        let manualID = UUID()
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: embeddedID,
            routes: [
                RouteRecord(
                    id: embeddedID,
                    machineID: machineID,
                    kind: .embeddedTailnet,
                    label: "Embedded Tailnet",
                    hostname: "p.tail.example.ts.net",
                    usernameHint: "developer",
                    health: .healthy,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: manualID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Manual SSH",
                    hostname: "example-mac.local",
                    usernameHint: nil,
                    health: .healthy,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: true
            )
        )

        let route = try XCTUnwrap(
            RouteEvaluationPlanner.sshBootstrapRoute(
                for: machine,
                lastKnownRouteKind: nil,
                activeRouteID: nil
            )
        )

        XCTAssertEqual(route.id, embeddedID)
        XCTAssertEqual(route.kind, .embeddedTailnet)
    }

    func testSSHBootstrapRouteFallsBackAfterLastKnownExternalTailnetFailsMoreRecentlyThanItSucceeds() throws {
        var machine = machineWithEmbeddedAndExternalTailnet()
        guard let externalIndex = machine.routes.firstIndex(where: { $0.kind == .externalTailnet }),
              let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }) else {
            XCTFail("Fixture machine is missing expected routes.")
            return
        }

        machine.routes[externalIndex].health = .degraded
        machine.routes[externalIndex].lastSuccessAt = Date(timeIntervalSince1970: 100)
        machine.routes[externalIndex].lastFailureAt = Date(timeIntervalSince1970: 200)
        machine.routes[embeddedIndex].health = .healthy

        let route = try XCTUnwrap(
            RouteEvaluationPlanner.sshBootstrapRoute(
                for: machine,
                lastKnownRouteKind: .externalTailnet,
                activeRouteID: nil,
                externalTailnetAppInstalled: true
            )
        )

        XCTAssertEqual(route.id, machine.routes[embeddedIndex].id)
        XCTAssertEqual(route.kind, .embeddedTailnet)
    }

    func testSSHBootstrapRouteFallsBackAfterActiveExternalTailnetFailsMoreRecentlyThanItSucceeds() throws {
        var machine = machineWithEmbeddedAndExternalTailnet()
        guard let externalIndex = machine.routes.firstIndex(where: { $0.kind == .externalTailnet }),
              let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }) else {
            XCTFail("Fixture machine is missing expected routes.")
            return
        }

        machine.routes[externalIndex].health = .degraded
        machine.routes[externalIndex].lastSuccessAt = Date(timeIntervalSince1970: 100)
        machine.routes[externalIndex].lastFailureAt = Date(timeIntervalSince1970: 200)
        machine.routes[embeddedIndex].health = .healthy

        let route = try XCTUnwrap(
            RouteEvaluationPlanner.sshBootstrapRoute(
                for: machine,
                lastKnownRouteKind: .externalTailnet,
                activeRouteID: machine.routes[externalIndex].id,
                externalTailnetAppInstalled: true
            )
        )

        XCTAssertEqual(route.id, machine.routes[embeddedIndex].id)
        XCTAssertEqual(route.kind, .embeddedTailnet)
    }

    func testRouteEvaluationDoesNotRecommendDegradedEmbeddedOverHealthyLAN() throws {
        var machine = MachineRecord.preview
        guard let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }),
              let lanIndex = machine.routes.firstIndex(where: { $0.kind == .localLAN }) else {
            XCTFail("Preview machine is missing expected routes.")
            return
        }

        machine.lastSuccessfulRouteID = nil
        machine.preferredRouteID = nil
        machine.routes[embeddedIndex].health = .degraded
        machine.routes[lanIndex].health = .healthy
        if let manualIndex = machine.routes.firstIndex(where: { $0.kind == .manualSSH }) {
            machine.routes[manualIndex].isUserPinned = false
            machine.routes[manualIndex].health = .unavailable
        }

        let recommended = try XCTUnwrap(
            RouteEvaluationPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: nil
            )
        )

        XCTAssertEqual(recommended.kind, .localLAN)
    }

    func testRouteEvaluationPrefersHealthyLANOverHealthyEmbeddedTailnet() throws {
        var machine = MachineRecord.preview
        guard let embeddedIndex = machine.routes.firstIndex(where: { $0.kind == .embeddedTailnet }),
              let lanIndex = machine.routes.firstIndex(where: { $0.kind == .localLAN }) else {
            XCTFail("Preview machine is missing expected routes.")
            return
        }

        machine.lastSuccessfulRouteID = nil
        machine.preferredRouteID = nil
        machine.routes[embeddedIndex].health = .healthy
        machine.routes[lanIndex].health = .healthy
        if let manualIndex = machine.routes.firstIndex(where: { $0.kind == .manualSSH }) {
            machine.routes[manualIndex].isUserPinned = false
            machine.routes[manualIndex].health = .unavailable
        }

        let recommended = try XCTUnwrap(
            RouteEvaluationPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: nil
            )
        )

        XCTAssertEqual(recommended.kind, .localLAN)
    }

    func testPinnedManualRouteDoesNotBeatHealthyLANForBestNowRecommendation() throws {
        var machine = MachineRecord.preview
        guard let lanIndex = machine.routes.firstIndex(where: { $0.kind == .localLAN }),
              let manualIndex = machine.routes.firstIndex(where: { $0.kind == .manualSSH }) else {
            XCTFail("Preview machine is missing expected routes.")
            return
        }

        machine.lastSuccessfulRouteID = nil
        machine.preferredRouteID = machine.routes[manualIndex].id
        machine.routes[lanIndex].health = .healthy
        machine.routes[manualIndex].health = .healthy
        machine.routes[manualIndex].isUserPinned = true

        let recommended = try XCTUnwrap(
            RouteEvaluationPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: nil
            )
        )

        XCTAssertEqual(recommended.kind, .localLAN)
    }

    func testUserPinnedHealthyManualRouteBeatsExternalTailnet() throws {
        let machineID = UUID()
        let manualID = UUID()
        let externalID = UUID()
        var machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            routes: [
                RouteRecord(
                    id: manualID,
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Pinned Manual",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    isUserPinned: true,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: externalID,
                    machineID: machineID,
                    kind: .externalTailnet,
                    label: "External Tailnet",
                    magicDNSName: "p.tail.example.ts.net",
                    usernameHint: "developer",
                    requiresExternalApp: true,
                    health: .healthy,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: true
            )
        )

        machine.lastSuccessfulRouteID = nil

        let recommended = try XCTUnwrap(
            RouteEvaluationPlanner.recommendedRoute(
                for: machine,
                lastKnownRouteKind: nil
            )
        )

        XCTAssertEqual(recommended.kind, .manualSSH)
    }

    func testExternalTailnetIsNotEligibleWhenRequiredAppIsMissing() throws {
        let machineID = UUID()
        let lanID = UUID()
        let externalID = UUID()
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            routes: [
                RouteRecord(
                    id: lanID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "LAN",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: externalID,
                    machineID: machineID,
                    kind: .externalTailnet,
                    label: "External Tailnet",
                    magicDNSName: "p.tail.example.ts.net",
                    usernameHint: "developer",
                    requiresExternalApp: true,
                    health: .healthy,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: true
            )
        )

        let evaluations = RouteEvaluationPlanner.evaluateRoutes(
            for: machine,
            lastKnownRouteKind: nil,
            activeRouteID: nil,
            externalTailnetAppInstalled: false
        )

        let external = try XCTUnwrap(evaluations.first(where: { $0.route.id == externalID }))
        let lan = try XCTUnwrap(evaluations.first(where: { $0.route.id == lanID }))

        XCTAssertFalse(external.isAuthenticated)
        XCTAssertFalse(external.isEligible)
        XCTAssertFalse(external.isReachable)
        XCTAssertTrue(lan.isRecommended)
    }

    func testLocalLANIsNotEligibleWhenNearbyRoutesAreUnavailable() throws {
        let machineID = UUID()
        let lanID = UUID()
        let externalID = UUID()
        let machine = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            routes: [
                RouteRecord(
                    id: lanID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "LAN",
                    hostname: "example-mac.local",
                    usernameHint: "developer",
                    health: .healthy,
                    trustState: .trusted
                ),
                RouteRecord(
                    id: externalID,
                    machineID: machineID,
                    kind: .externalTailnet,
                    label: "External Tailnet",
                    magicDNSName: "p.tail.example.ts.net",
                    usernameHint: "developer",
                    tailnetProfileID: UUID(),
                    requiresExternalApp: true,
                    health: .healthy,
                    trustState: .trusted
                )
            ],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: true
            )
        )

        let evaluations = RouteEvaluationPlanner.evaluateRoutes(
            for: machine,
            lastKnownRouteKind: nil,
            activeRouteID: nil,
            externalTailnetAppInstalled: true,
            allowsNearbyNetworkRoutes: false
        )

        let lan: RouteEvaluation = try XCTUnwrap(evaluations.first(where: { $0.route.id == lanID }))
        let external: RouteEvaluation = try XCTUnwrap(evaluations.first(where: { $0.route.id == externalID }))

        XCTAssertFalse(lan.isReachable)
        XCTAssertFalse(lan.isEligible)
        XCTAssertTrue(external.isRecommended)
    }
}
