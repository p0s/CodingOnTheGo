import XCTest
@testable import Discovery
import SharedModels

final class DiscoveryTests: XCTestCase {
    func testMergeUsesFingerprintToPreserveIdentity() {
        let machineID = UUID()
        let existing = MachineRecord(
            id: machineID,
            displayName: "example-mac",
            hostname: "example-mac.local",
            stableHostFingerprint: "SHA256:example-old",
            lastKnownUser: "developer",
            lastConnectedAt: nil,
            preferredRouteID: nil,
            lastSuccessfulRouteID: nil,
            capabilitySnapshotID: nil,
            notes: nil,
            isPinned: false,
            sortRank: 0,
            routes: [
                RouteRecord(
                    machineID: machineID,
                    kind: .manualSSH,
                    label: "Remote Login",
                    hostname: "example-mac.local",
                    sshPort: 22,
                    health: .healthy,
                    isRecommended: true
                )
            ],
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: false,
                codexAppInstalled: false
            )
        )

        let sample = DiscoveryRouteSample(
            machineAlias: "example-mac",
            hostname: "example-mac.internal",
            port: 22,
            kind: .manualSSH,
            source: .bonjourSSH,
            fingerprint: "fingerprint-123",
            health: .healthy,
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                codexAppInstalled: false
            ),
            lastSeenAt: .init(timeIntervalSince1970: 10)
        )

        let result = DiscoveryEngine().merge(
            sample,
            into: [existing],
            fingerprintIndex: ["fingerprint-123": machineID]
        )

        XCTAssertFalse(result.createdMachine)
        XCTAssertEqual(result.updatedMachineID, machineID)
        XCTAssertEqual(result.machines.count, 1)
        XCTAssertEqual(result.machines[0].hostname, "example-mac.internal")
        let mergedRoute = result.machines[0].routes.first
        XCTAssertEqual(mergedRoute?.hostname, "example-mac.internal")
        XCTAssertEqual(result.machines[0].capabilities.supportsWebsocketListen, true)
        XCTAssertNil(result.machines[0].lastConnectedAt)
        XCTAssertNil(mergedRoute?.usernameHint)
        XCTAssertNil(mergedRoute?.lastSuccessAt)
        XCTAssertEqual(mergedRoute?.trustState, .unknown)
    }

    func testBestCandidatePrefersHealthyNewestDiscoveredRoute() {
        let machine = MachineRecord.preview
        let older = DiscoveryRouteSample(
            machineAlias: machine.alias,
            hostname: machine.hostname,
            port: 22,
            kind: .localLAN,
            source: .subnetReachability,
            health: .degraded,
            lastSeenAt: .init(timeIntervalSince1970: 1)
        )
        let newer = DiscoveryRouteSample(
            machineAlias: machine.alias,
            hostname: machine.hostname,
            port: 22,
            kind: .manualSSH,
            source: .bonjourSSH,
            health: .healthy,
            lastSeenAt: .init(timeIntervalSince1970: 2)
        )

        let candidate = DiscoveryEngine().bestCandidate(for: machine, discovered: [older, newer])

        XCTAssertEqual(candidate?.kind, .manualSSH)
        XCTAssertEqual(candidate?.health, .healthy)
    }

    func testManualRouteKeepsUsernameHintAndPortSeparate() async throws {
        let route = try await DiscoveryCoordinator().makeManualRoute(
            from: ManualRouteEntryDraft(
                label: "Desk SSH",
                address: "example-mac.local",
                kind: .manualSSH,
                usernameHint: "developer",
                port: 2222
            )
        )

        XCTAssertEqual(route.hostname, "example-mac.local")
        XCTAssertEqual(route.usernameHint, "developer")
        XCTAssertEqual(route.sshPort, 2222)
        XCTAssertEqual(route.address, "example-mac.local")
        XCTAssertEqual(route.health, .unavailable)
        XCTAssertNil(route.lastCheckedAt)
        XCTAssertNil(route.lastSuccessAt)
        XCTAssertFalse(route.isRecommended)
    }

    func testScanAndMergeUsesDiscovererSamplesToRefreshMachineRoutes() async {
        let machine = MachineRecord.preview
        let sample = DiscoveryRouteSample(
            machineID: machine.id,
            machineAlias: machine.alias,
            hostname: "lan-example-mac.local",
            port: 22,
            kind: .localLAN,
            source: .bonjourSSH,
            health: .healthy
        )
        let coordinator = DiscoveryCoordinator(
            discoverer: StubLANDiscoverer(samples: [sample])
        )

        let report = await coordinator.scanAndMerge(into: [machine])
        let updatedMachine = report.machines.first(where: { $0.id == machine.id })

        XCTAssertEqual(report.updatedMachineIDs, [machine.id])
        XCTAssertNotNil(updatedMachine?.routes.first(where: {
            $0.kind == .localLAN && $0.hostname == "lan-example-mac.local"
        }))
    }

    func testMergeCreatesDistinctMachineWhenHostnameCollidesButFingerprintDiffers() async {
        let existing = MachineRecord(
            displayName: "example-mac",
            hostname: "shared-host.local",
            stableHostFingerprint: "SHA256:fingerprint-a",
            routes: [],
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
        let sample = DiscoveryRouteSample(
            machineAlias: "example-mac",
            hostname: "shared-host.local",
            port: 22,
            kind: .manualSSH,
            source: .bonjourSSH,
            fingerprint: "SHA256:fingerprint-b",
            health: .healthy
        )

        let result = await DiscoveryCoordinator().mergeSamples([sample], into: [existing])

        XCTAssertEqual(result.machines.count, 2)
        XCTAssertTrue(result.createdMachineIDs.count == 1)
    }

    func testMergeUsesBonjourIPAddressToPreserveExistingManualLocalRoute() {
        let machineID = UUID()
        let routeID = UUID()
        let existing = MachineRecord(
            id: machineID,
            displayName: "192",
            hostname: "192.168.50.164",
            stableHostFingerprint: nil,
            lastKnownUser: "developer",
            lastConnectedAt: nil,
            preferredRouteID: routeID,
            lastSuccessfulRouteID: nil,
            capabilitySnapshotID: nil,
            notes: nil,
            isPinned: false,
            sortRank: 0,
            routes: [
                RouteRecord(
                    id: routeID,
                    machineID: machineID,
                    kind: .localLAN,
                    label: "Same Wi-Fi",
                    hostname: "192.168.50.164",
                    ipAddress: "192.168.50.164",
                    sshPort: 2222,
                    usernameHint: "developer",
                    health: .unavailable,
                    isRecommended: false,
                    isUserPinned: true,
                    discoverySource: .manual
                )
            ],
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: false,
                supportsWebsocketListen: false,
                codexAppInstalled: false
            )
        )

        let sample = DiscoveryRouteSample(
            machineAlias: "lab",
            hostname: "lab.local",
            ipAddress: "192.168.50.164",
            port: 2222,
            kind: .localLAN,
            source: .bonjourSSH,
            health: .healthy
        )

        let result = DiscoveryEngine().merge(sample, into: [existing])

        XCTAssertFalse(result.createdMachine)
        XCTAssertEqual(result.updatedMachineID, machineID)
        XCTAssertEqual(result.machines.count, 1)
        XCTAssertEqual(result.machines[0].displayName, "lab")
        XCTAssertEqual(result.machines[0].hostname, "lab.local")
        XCTAssertEqual(result.machines[0].routes.count, 1)
        XCTAssertEqual(result.machines[0].routes[0].id, routeID)
        XCTAssertEqual(result.machines[0].routes[0].hostname, "lab.local")
        XCTAssertEqual(result.machines[0].routes[0].ipAddress, "192.168.50.164")
        XCTAssertEqual(result.machines[0].routes[0].usernameHint, "developer")
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
