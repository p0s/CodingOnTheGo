import XCTest
@testable import AppState
import Discovery
import HostBootstrap
import SharedModels

final class ConnectionFallbackSuggestionTests: XCTestCase {
    private var savedEnvironment: [String: String?] = [:]
    private var savedDemoModeValue: Any?

    override func setUp() {
        super.setUp()
        saveAndClearTestEnvironment()
    }

    override func tearDown() {
        restoreTestEnvironment()
        super.tearDown()
    }

    @MainActor
    func testSuggestionsIncludeHostDerivedRoutesAndClientInstallGuidance() {
        let machine = makeMachine()
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: DiscoveryCoordinator(discoverer: NoopSuggestionLANDiscoverer()),
            externalTailnetAppDetector: StubExternalTailnetDetector(isInstalled: false)
        )
        model.select(machineID: machine.id)
        model.externalTailnetAppInstalled = false
        model.runtimeCapabilityDiagnostics = makeDiagnostics(
            localNetworkHostName: "example-mac",
            externalTailnetDNSName: "example-mac.example.ts.net",
            externalTailnetRunningOnHost: true,
            companionAppInstalled: true
        )

        let suggestions = model.connectionFallbackSuggestions

        XCTAssertEqual(
            Set(suggestions.map(\.kind)),
            Set([.sameLAN, .externalTailnet, .companionHint])
        )
        XCTAssertEqual(
            suggestions.first(where: { $0.kind == .externalTailnet })?.actionTitle,
            nil
        )
    }

    @MainActor
    func testSuggestionsOfferManualSSHRescueFromCurrentLANRoute() {
        let machineID = UUID()
        let lanRoute = RouteRecord(
            machineID: machineID,
            kind: .localLAN,
            label: "Desk LAN",
            hostname: "example-mac.local",
            usernameHint: "developer",
            health: .healthy,
            trustState: .trusted,
            trustedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaFake developer@example-mac"
        )
        let machine = makeMachine(
            id: machineID,
            routes: [lanRoute],
            preferredRouteID: lanRoute.id
        )
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: DiscoveryCoordinator(discoverer: NoopSuggestionLANDiscoverer()),
            externalTailnetAppDetector: StubExternalTailnetDetector(isInstalled: false)
        )
        model.select(machineID: machine.id)
        model.runtimeCapabilityDiagnostics = makeDiagnostics()

        XCTAssertEqual(
            model.connectionFallbackSuggestions.map(\.kind),
            [.manualSSH]
        )
    }

    @MainActor
    func testApplyingSameLANSuggestionAddsRoute() async throws {
        let machine = makeMachine()
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: DiscoveryCoordinator(discoverer: NoopSuggestionLANDiscoverer()),
            externalTailnetAppDetector: StubExternalTailnetDetector(isInstalled: false)
        )
        model.select(machineID: machine.id)
        model.runtimeCapabilityDiagnostics = makeDiagnostics(localNetworkHostName: "example-mac")

        let suggestion = try XCTUnwrap(
            model.connectionFallbackSuggestions.first(where: { $0.kind == .sameLAN })
        )

        model.applyConnectionFallbackSuggestion(suggestion)

        let didPersist = try await Self.waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.selectedMachine?.route(for: .localLAN) != nil
        }

        XCTAssertTrue(didPersist)
        XCTAssertEqual(model.selectedMachine?.route(for: .localLAN)?.hostname, "example-mac.local")
    }

    @MainActor
    func testApplyingExternalTailnetSuggestionAddsRouteWhenClientAppInstalled() async throws {
        let machine = makeMachine()
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: DiscoveryCoordinator(discoverer: NoopSuggestionLANDiscoverer()),
            externalTailnetAppDetector: StubExternalTailnetDetector(isInstalled: true)
        )
        model.select(machineID: machine.id)
        model.externalTailnetAppInstalled = true
        model.runtimeCapabilityDiagnostics = makeDiagnostics(
            externalTailnetDNSName: "example-mac.example.ts.net",
            externalTailnetRunningOnHost: true
        )

        let suggestion = try XCTUnwrap(
            model.connectionFallbackSuggestions.first(where: { $0.kind == .externalTailnet })
        )

        model.applyConnectionFallbackSuggestion(suggestion)

        let didPersist = try await Self.waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.selectedMachine?.route(for: .externalTailnet) != nil
        }

        XCTAssertTrue(didPersist)
        let route = try XCTUnwrap(model.selectedMachine?.route(for: .externalTailnet))
        XCTAssertEqual(route.hostname, "example-mac.example.ts.net")
        XCTAssertTrue(route.requiresExternalApp)
    }

    @MainActor
    func testApplyingExternalTailnetSuggestionSurvivesDelayedDiscoveryRefresh() async throws {
        let machine = makeMachine()
        let model = AppModel(
            machines: [machine],
            discoveryCoordinator: DiscoveryCoordinator(
                discoverer: DelayedSuggestionLANDiscoverer(
                    delay: .milliseconds(250),
                    samples: []
                )
            ),
            externalTailnetAppDetector: StubExternalTailnetDetector(isInstalled: true)
        )
        model.select(machineID: machine.id)
        model.externalTailnetAppInstalled = true
        model.runtimeCapabilityDiagnostics = makeDiagnostics(
            externalTailnetDNSName: "example-mac.example.ts.net",
            externalTailnetRunningOnHost: true
        )

        let suggestion = try XCTUnwrap(
            model.connectionFallbackSuggestions.first(where: { $0.kind == .externalTailnet })
        )

        model.applyConnectionFallbackSuggestion(suggestion)

        let refreshFinished = try await Self.waitUntil(timeoutNanoseconds: 5_000_000_000) {
            model.discoverySnapshot != nil
        }

        XCTAssertTrue(refreshFinished)
        let route = try XCTUnwrap(model.selectedMachine?.route(for: .externalTailnet))
        XCTAssertEqual(route.hostname, "example-mac.example.ts.net")
        XCTAssertTrue(route.requiresExternalApp)
    }

    private func saveAndClearTestEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        let keysToReset = Set(
            environment.keys.filter { $0 == "UI_TESTING" || $0.hasPrefix("COTG_") }
        )

        savedEnvironment = keysToReset.reduce(into: [:]) { partialResult, key in
            partialResult[key] = environment[key]
            unsetenv(key)
        }

        savedDemoModeValue = UserDefaults.standard.object(forKey: AppDemoScenario.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AppDemoScenario.defaultsKey)
    }

    private func restoreTestEnvironment() {
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
    }

    private func makeMachine(
        id: UUID = UUID(),
        routes: [RouteRecord] = [],
        preferredRouteID: RouteRecord.ID? = nil
    ) -> MachineRecord {
        MachineRecord(
            id: id,
            displayName: "example-mac",
            hostname: "example-mac.local",
            lastKnownUser: "developer",
            preferredRouteID: preferredRouteID,
            routes: routes,
            capabilities: HostCapabilitySnapshot(
                machineID: id,
                remoteLoginEnabled: true,
                codexInstalled: true,
                supportsWebsocketListen: true
            )
        )
    }

    private func makeDiagnostics(
        localNetworkHostName: String? = nil,
        externalTailnetDNSName: String? = nil,
        externalTailnetRunningOnHost: Bool = false,
        companionAppInstalled: Bool = false
    ) -> HostCapabilityDiagnostics {
        HostCapabilityDiagnostics(
            sshReachable: true,
            remoteLoginEnabled: true,
            codexInstalled: true,
            appServerAvailable: true,
            websocketSupported: true,
            authConfigured: true,
            hostKeyTrusted: true,
            localNetworkHostName: localNetworkHostName,
            externalTailnetAppInstalledOnHost: externalTailnetDNSName != nil,
            externalTailnetRunningOnHost: externalTailnetRunningOnHost,
            externalTailnetDNSName: externalTailnetDNSName,
            companionAppInstalled: companionAppInstalled
        )
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 100_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return await condition()
    }
}

private struct StubExternalTailnetDetector: ExternalTailnetAppDetecting {
    let isInstalled: Bool?

    func isInstalled() async -> Bool? {
        isInstalled
    }
}

private struct NoopSuggestionLANDiscoverer: LANRouteDiscovering {
    func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample] {
        _ = knownMachines
        _ = timeout
        return []
    }
}

private struct DelayedSuggestionLANDiscoverer: LANRouteDiscovering {
    let delay: Duration
    let samples: [DiscoveryRouteSample]

    func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample] {
        _ = knownMachines
        _ = timeout
        try? await Task.sleep(for: delay)
        return samples
    }
}
