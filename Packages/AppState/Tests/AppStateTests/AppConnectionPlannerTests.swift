import Foundation
import XCTest
@testable import AppState
import SharedModels
import SSHTransport

@MainActor
final class AppConnectionPlannerTests: XCTestCase {
    func testConnectionCandidatePrefersDirectCodexWebSocketOverSSH() async throws {
        let fixture = makeMachineFixture()

        let candidate = try await AppConnectionPlanner.connectionCandidate(
            selectedMachine: fixture.machine,
            cwd: "/tmp/project",
            sshCandidate: { _, _ in
                XCTFail("SSH fallback should not be asked for when a direct Codex websocket endpoint is available.")
                return nil
            },
            directEndpointCandidate: { machine, cwd in
                Self.directCandidate(machine: machine, route: fixture.directWebSocketRoute, cwd: cwd)
            }
        )

        guard case let .directEndpoint(machineID, configuration, route, bootstrap) = candidate else {
            return XCTFail("Expected a direct Codex websocket endpoint candidate.")
        }

        XCTAssertEqual(machineID, fixture.machine.id)
        XCTAssertEqual(configuration.url, fixture.directWebSocketRoute.companionEndpoint)
        XCTAssertEqual(route.id, fixture.directWebSocketRoute.id)
        XCTAssertEqual(bootstrap, .codexAppServerWebSocket)
    }

    func testConnectionCandidateFallsBackToSSHWhenDirectWebSocketIsUnavailable() async throws {
        let fixture = makeMachineFixture()

        let candidate = try await AppConnectionPlanner.connectionCandidate(
            selectedMachine: fixture.machine,
            cwd: "/tmp/project",
            sshCandidate: { machine, cwd in
                Self.safeLaneCandidate(machine: machine, route: fixture.sshRoute, cwd: cwd)
            },
            directEndpointCandidate: { _, _ in
                nil
            }
        )

        guard case let .safeLane(machineID, configuration, route, bootstrap) = candidate else {
            return XCTFail("Expected SSH safe-lane fallback candidate.")
        }

        XCTAssertEqual(machineID, fixture.machine.id)
        XCTAssertEqual(configuration.host, "mac.local")
        XCTAssertEqual(route.id, fixture.sshRoute.id)
        XCTAssertEqual(bootstrap, .standardSSH)
    }

    func testAppModelTreatsHealthyDirectCodexWebSocketAsPrimaryReadyStateWithoutSSH() {
        let machineID = UUID()
        let companionRoute = RouteRecord(
            machineID: machineID,
            kind: .companionDirect,
            label: "Codex websocket",
            companionEndpoint: URL(string: "ws://127.0.0.1:9494"),
            health: .healthy,
            discoverySource: .bonjour,
            trustState: .trusted
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "Mac",
            hostname: "mac.local",
            routes: [companionRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: false,
                codexInstalled: true,
                supportsWebsocketListen: true,
                companionVersion: "1",
                companionState: "ready",
                codexAppInstalled: true
            )
        )
        let model = AppModel(sceneID: "codex-websocket-primary-ready", machines: [machine])

        XCTAssertTrue(model.connectionCandidateIsReady)
        XCTAssertTrue(model.connectionSetupAccountReady)
        XCTAssertTrue(model.connectionSetupSSHAccessReady)
        XCTAssertTrue(model.connectionSetupTrustReady)
        XCTAssertEqual(
            model.connectionCandidateStatusDetail,
            "Codex websocket is ready as the primary Codex app-server websocket lane."
        )
    }

    private static func directCandidate(
        machine: MachineRecord,
        route: RouteRecord,
        cwd: String
    ) -> ConnectionCandidate {
        AppConnectionPlanner.makeDirectEndpointCandidate(
            machineID: machine.id,
            endpoint: route.companionEndpoint!,
            route: route,
            cwd: cwd,
            bootstrap: .codexAppServerWebSocket
        )
    }

    private static func safeLaneCandidate(
        machine: MachineRecord,
        route: RouteRecord,
        cwd: String
    ) -> ConnectionCandidate {
        AppConnectionPlanner.makeSafeLaneCandidate(
            machineID: machine.id,
            endpoint: SSHBootstrapEndpoint(host: "mac.local", port: 22),
            route: route,
            username: "developer",
            authentication: .password("secret"),
            hostValidation: .acceptAllForTesting,
            proxy: nil,
            cwd: cwd,
            codexHome: nil
        )
    }

    private func makeMachineFixture() -> (
        machine: MachineRecord,
        sshRoute: RouteRecord,
        directWebSocketRoute: RouteRecord
    ) {
        let machineID = UUID()
        let sshRoute = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "SSH fallback",
            hostname: "mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeUnitTestKey developer@mac"
        )
        let directWebSocketRoute = RouteRecord(
            machineID: machineID,
            kind: .companionDirect,
            label: "Codex websocket",
            companionEndpoint: URL(string: "ws://127.0.0.1:9494"),
            health: .healthy,
            discoverySource: .bonjour,
            trustState: .trusted
        )
        let machine = MachineRecord(
            id: machineID,
            displayName: "Mac",
            hostname: "mac.local",
            lastKnownUser: "developer",
            credentialRef: CredentialRef(
                kind: .sshKey,
                keychainAccount: "cotg.test.mac",
                label: "SSH key",
                username: "developer",
                storageScope: .localKeychain
            ),
            routes: [sshRoute, directWebSocketRoute],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true,
                companionVersion: "1",
                companionState: "ready",
                codexAppInstalled: true
            )
        )

        return (machine, sshRoute, directWebSocketRoute)
    }
}
