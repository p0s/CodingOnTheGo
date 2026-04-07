import XCTest
@testable import TailnetEmbedded
import SharedModels
#if canImport(Network)
import Network
#endif

final class TailnetEmbeddedTests: XCTestCase {
    private func makeEmbeddedManager(
        dialerAdapter: any EmbeddedTailnetDialerAdapting = DeferredEmbeddedTailnetDialerAdapter()
    ) -> EmbeddedTailnetNodeManager {
        EmbeddedTailnetNodeManager(
            authCoordinator: StubEmbeddedTailnetAuthCoordinator(),
            dialerAdapter: dialerAdapter
        )
    }

    func testLoopbackCredentialResolverUsesVendorDocumentedSOCKSAuthShape() {
        let authentication = EmbeddedTailnetLoopbackCredentialResolver.proxyAuthentication(
            from: "abc123proxycred"
        )

        XCTAssertEqual(authentication.username, "tsnet")
        XCTAssertEqual(authentication.password, "abc123proxycred")
    }

    func testReadinessRequiresReachableAuthenticatedNode() {
        let status = EmbeddedTailnetStatus(
            isInstalled: true,
            authState: .authenticated,
            isReachable: true
        )

        XCTAssertTrue(status.readyForConnection)
    }

    func testCustomControlServerValidatorRequiresHTTPS() {
        XCTAssertTrue(TailnetControlURLValidator.isSupported(URL(string: "https://headscale.example.com")!))
        XCTAssertFalse(TailnetControlURLValidator.isSupported(URL(string: "http://localhost:8080")!))
    }

    func testManagerKeepsOnlyOneActiveEmbeddedProfile() async throws {
        let manager = makeEmbeddedManager()
        let primary = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer"
            )
        )
        let secondary = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Lab",
                controlURL: URL(string: "https://headscale.example.com")!,
                accountLabel: "developer"
            )
        )

        _ = primary
        let secondaryID = try XCTUnwrap(secondary.profiles.last?.id)
        let updated = try await manager.activate(profileID: secondaryID)

        XCTAssertTrue(updated.profiles.contains(where: { $0.id == secondaryID && $0.isActive }))
        XCTAssertFalse(updated.profiles.dropLast().contains(where: \.isActive))
    }

    func testManagerCompletesAuthenticationWithoutClaimingRuntimeReachability() async throws {
        let manager = makeEmbeddedManager()
        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)

        let pending = try await manager.beginAuthentication(profileID: profileID)
        XCTAssertEqual(pending.authSession?.phase, .pendingUserAction)
        XCTAssertFalse(pending.authSession?.ticket?.displayedCode.isEmpty ?? true)

        let authenticated = try await manager.completeAuthentication(profileID: profileID)
        XCTAssertEqual(authenticated.status.authState, .authenticated)
        XCTAssertFalse(authenticated.status.isReachable)
        XCTAssertEqual(authenticated.health.state, .needsRuntimeIntegration)
        XCTAssertNotNil(authenticated.profiles.first?.lastAuthenticatedAt)
    }

    func testSnapshotReconcilesCompletedBrowserAuthentication() async throws {
        let manager = makeEmbeddedManager(
            dialerAdapter: StubReadyEmbeddedTailnetDialerAdapter()
        )
        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)

        _ = try await manager.beginAuthentication(profileID: profileID)
        let reconciled = await manager.snapshot()

        XCTAssertEqual(reconciled.status.authState, .authenticated)
        XCTAssertNil(reconciled.authSession?.ticket)
        XCTAssertNotNil(reconciled.profiles.first?.lastAuthenticatedAt)
    }

    func testBeginAuthenticationPromotesRequestedProfileToActive() async throws {
        let manager = makeEmbeddedManager()
        _ = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer"
            )
        )
        let secondary = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Lab",
                controlURL: URL(string: "https://headscale.example.com")!,
                accountLabel: "c"
            )
        )
        let secondaryID = try XCTUnwrap(secondary.profiles.last?.id)

        let pending = try await manager.beginAuthentication(profileID: secondaryID)

        XCTAssertEqual(pending.activeProfileID, secondaryID)
        XCTAssertEqual(pending.authSession?.profileID, secondaryID)
    }

    func testResetAuthenticationClearsStoredStateWithoutDeletingProfile() async throws {
        let manager = makeEmbeddedManager()
        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)
        _ = try await manager.completeAuthentication(profileID: profileID)

        let reset = try await manager.resetAuthentication(profileID: profileID)

        XCTAssertEqual(reset.profiles.count, 1)
        XCTAssertNil(reset.profiles.first?.lastAuthenticatedAt)
        XCTAssertEqual(reset.status.authState, .signedOut)
        XCTAssertNil(reset.authSession)
    }

    func testDeleteProfileRemovesStoredTailnetProfile() async throws {
        let manager = makeEmbeddedManager()
        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)

        let updated = try await manager.deleteProfile(profileID: profileID)

        XCTAssertTrue(updated.profiles.isEmpty)
        XCTAssertNil(updated.activeProfileID)
    }

    func testRoutePublisherKeepsExternalRoutesDistinct() {
        let profileID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let snapshot = EmbeddedTailnetRuntimeSnapshot(
            profiles: [
                TailnetProfile(
                    id: profileID,
                    kind: .external,
                    displayName: "Studio Tailnet",
                    controlURL: URL(string: "https://headscale.example.com")!,
                    accountLabel: "developer",
                    tailnetDNSName: "harbor.ts.net",
                    isActive: true,
                    requiresExternalApp: true
                )
            ],
            activeProfileID: nil,
            authSession: nil,
            health: EmbeddedTailnetRuntimeHealth(
                state: .degraded,
                failureReasonCode: "external-tailnet-reachability-unverified"
            ),
            status: EmbeddedTailnetStatus(
                isInstalled: false,
                authState: .authenticated,
                isReachable: false
            ),
            dialPlan: EmbeddedTailnetDialPlan(
                profileID: profileID,
                routeKind: .externalTailnet,
                preferredHost: "harbor.ts.net",
                magicDNSName: "harbor.ts.net",
                requiresExternalApp: true
            )
        )

        let route = TailnetRoutePublisher.route(
            machineID: UUID(),
            hostname: "harbor.local",
            snapshot: snapshot
        )

        XCTAssertEqual(route?.kind, .externalTailnet)
        XCTAssertEqual(route?.hostname, "harbor.ts.net")
        XCTAssertTrue(route?.requiresExternalApp == true)
        XCTAssertEqual(route?.health, .degraded)
        XCTAssertEqual(route?.magicDNSName, "harbor.ts.net")
    }

    func testAuthenticatedEmbeddedProfileBecomesTrafficReadyWhenNativeTransportEndpointExists() async throws {
        let manager = makeEmbeddedManager(
            dialerAdapter: DeferredEmbeddedTailnetDialerAdapter(
                transportEndpointProvider: StubEmbeddedTailnetNativeTransportEndpointProvider(
                    endpoint: EmbeddedTailnetNativeTransportEndpoint(
                        socksProxyHost: "127.0.0.1",
                        socksProxyPort: 2222,
                        socksProxyUsername: "tailnet",
                        socksProxyPassword: "secret",
                        preferredHost: "100.100.0.8"
                    )
                )
            )
        )

        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .embedded,
                displayName: "Primary",
                controlURL: URL(string: "https://controlplane.tailscale.com")!,
                accountLabel: "developer",
                tailnetDNSName: "primary.ts.net"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)
        _ = try await manager.completeAuthentication(profileID: profileID)

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.health.state, .ready)
        XCTAssertTrue(snapshot.status.isReachable)
        XCTAssertEqual(snapshot.dialPlan?.socksProxyHost, "127.0.0.1")
        XCTAssertEqual(snapshot.dialPlan?.socksProxyPort, 2222)
        XCTAssertEqual(snapshot.dialPlan?.socksProxyUsername, "tailnet")
        XCTAssertEqual(snapshot.dialPlan?.socksProxyPassword, "secret")
        XCTAssertTrue(snapshot.dialPlan?.supportsNativeSSHTransport == true)

        let route = TailnetRoutePublisher.route(
            machineID: UUID(),
            hostname: "primary.local",
            snapshot: snapshot
        )

        XCTAssertEqual(route?.kind, .embeddedTailnet)
        XCTAssertEqual(route?.health, .healthy)
        XCTAssertTrue(route?.isEligibleForTraffic == true)
    }

    func testExternalProbeCanPromoteReachableRouteToHealthy() async throws {
        let manager = EmbeddedTailnetNodeManager(
            reachabilityProbe: StubTailnetReachabilityProbe(
                result: TailnetReachabilityProbeResult(
                    state: .reachable,
                    latencyMs: 7,
                    lastCheckedAt: .distantPast
                )
            )
        )

        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .external,
                displayName: "Studio",
                controlURL: URL(string: "https://headscale.example.com")!,
                accountLabel: "developer",
                tailnetDNSName: "studio.ts.net"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)
        _ = try await manager.activate(profileID: profileID)

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.health.state, .ready)
        XCTAssertTrue(snapshot.status.isReachable)
        XCTAssertEqual(snapshot.health.latencyMs, 7)

        let route = TailnetRoutePublisher.route(
            machineID: UUID(),
            hostname: "studio.local",
            snapshot: snapshot
        )

        XCTAssertEqual(route?.kind, .externalTailnet)
        XCTAssertEqual(route?.health, .healthy)
        XCTAssertTrue(route?.isEligibleForTraffic == true)
    }

    func testExternalProbeKeepsUnreachableRouteIneligible() async throws {
        let manager = EmbeddedTailnetNodeManager(
            reachabilityProbe: StubTailnetReachabilityProbe(
                result: TailnetReachabilityProbeResult(
                    state: .unreachable,
                    failureReasonCode: "external-tailnet-unreachable",
                    lastErrorSummary: "Probe failed."
                )
            )
        )

        let runtime = try await manager.saveProfile(
            TailnetProfileDraft(
                kind: .external,
                displayName: "Studio",
                controlURL: URL(string: "https://headscale.example.com")!,
                accountLabel: "developer",
                tailnetDNSName: "studio.ts.net"
            )
        )
        let profileID = try XCTUnwrap(runtime.profiles.first?.id)
        _ = try await manager.activate(profileID: profileID)

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.health.state, .degraded)
        XCTAssertFalse(snapshot.status.isReachable)

        let route = TailnetRoutePublisher.route(
            machineID: UUID(),
            hostname: "studio.local",
            snapshot: snapshot
        )

        XCTAssertEqual(route?.kind, .externalTailnet)
        XCTAssertEqual(route?.health, .degraded)
        XCTAssertTrue(route?.isEligibleForTraffic == false)
    }

    func testApplyingRuntimePublishesActiveTailnetRouteOnlyToExactHostMatch() {
        let profileID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let duplicatedRoute = RouteRecord(
            kind: .embeddedTailnet,
            label: "Embedded Tailnet",
            hostname: "example-mac.example.ts.net",
            magicDNSName: "example-mac.example.ts.net",
            usernameHint: "developer",
            tailnetProfileID: profileID,
            health: .healthy,
            discoverySource: .tailnetProfile
        )
        let snapshot = EmbeddedTailnetRuntimeSnapshot(
            profiles: [
                TailnetProfile(
                    id: profileID,
                    kind: .embedded,
                    displayName: "Embedded Tailnet",
                    controlURL: URL(string: "https://controlplane.tailscale.com")!,
                    accountLabel: "developer",
                    tailnetDNSName: "example-mac.example.ts.net",
                    isActive: true,
                    lastActivatedAt: .now,
                    lastAuthenticatedAt: .now,
                    supportsCustomControlServer: true,
                    requiresExternalApp: false
                )
            ],
            activeProfileID: profileID,
            authSession: nil,
            health: EmbeddedTailnetRuntimeHealth(state: .ready, lastCheckedAt: .now),
            status: EmbeddedTailnetStatus(
                isInstalled: true,
                authState: .authenticated,
                isReachable: true
            ),
            dialPlan: EmbeddedTailnetDialPlan(
                profileID: profileID,
                routeKind: .embeddedTailnet,
                preferredHost: "example-mac.example.ts.net",
                magicDNSName: "example-mac.example.ts.net",
                requiresExternalApp: false,
                supportsNativeSSHTransport: true
            )
        )

        let exactTailnetMachine = MachineRecord(
            id: UUID(),
            displayName: "example-mac",
            hostname: "example-mac.example.ts.net",
            lastKnownUser: "developer",
            preferredRouteID: duplicatedRoute.id,
            lastSuccessfulRouteID: duplicatedRoute.id,
            routes: [duplicatedRoute],
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: false,
                supportsWebsocketListen: false,
                codexAppInstalled: false
            )
        )
        let localMachine = MachineRecord(
            id: UUID(),
            displayName: "example-mac",
            hostname: "example-mac.local",
            preferredRouteID: duplicatedRoute.id,
            routes: [
                duplicatedRoute,
                RouteRecord(
                    kind: .localLAN,
                    label: "Subnet reachability",
                    hostname: "example-mac.local",
                    health: .healthy,
                    discoverySource: .cachedProbe
                )
            ],
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: false,
                supportsWebsocketListen: false,
                codexAppInstalled: false
            )
        )

        let applied = TailnetRoutePublisher.applying(snapshot, to: [exactTailnetMachine, localMachine])

        XCTAssertEqual(applied[0].routes.filter { $0.kind == .embeddedTailnet }.count, 1)
        XCTAssertEqual(applied[0].preferredRouteID, applied[0].routes.first(where: { $0.kind == .embeddedTailnet })?.id)
        XCTAssertEqual(applied[0].routes.first(where: { $0.kind == .embeddedTailnet })?.usernameHint, "developer")
        XCTAssertTrue(applied[1].routes.allSatisfy { $0.kind != .embeddedTailnet })
        XCTAssertEqual(applied[1].preferredRouteID, applied[1].routes.first(where: { $0.kind == .localLAN })?.id)
    }

    #if canImport(Network)
    func testAppleReachabilityProbeCanReachLoopbackListener() async throws {
        let queue = DispatchQueue(label: "TailnetEmbeddedTests.listener")
        let listener = try NWListener(using: .tcp, on: 0)
        let ready = expectation(description: "listener ready")
        let accepted = expectation(description: "listener accepted")

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            accepted.fulfill()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.fulfill()
            }
        }

        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)

        guard let port = listener.port?.rawValue else {
            XCTFail("Listener did not expose a bound port.")
            listener.cancel()
            return
        }

        let probe = AppleTailnetReachabilityProbe()
        let result = await probe.probe(TailnetReachabilityTarget(host: "127.0.0.1", port: port, timeoutSeconds: 5))

        XCTAssertEqual(result.state, .reachable)
        XCTAssertNotNil(result.latencyMs)

        await fulfillment(of: [accepted], timeout: 5)
        listener.cancel()
    }
    #endif
}

private struct StubTailnetReachabilityProbe: TailnetReachabilityProbing {
    let result: TailnetReachabilityProbeResult

    func probe(_ target: TailnetReachabilityTarget) async -> TailnetReachabilityProbeResult {
        var outcome = result
        outcome.lastCheckedAt = .now
        if outcome.failureReasonCode == nil, !outcome.isReachable {
            outcome.failureReasonCode = "external-tailnet-unreachable"
            outcome.lastErrorSummary = outcome.lastErrorSummary ?? "Stubbed reachability failure for \(target.host):\(target.port)."
        }
        return outcome
    }
}

private actor StubEmbeddedTailnetAuthCoordinator: EmbeddedTailnetAuthCoordinating {
    private var session: EmbeddedTailnetAuthSession?

    func currentSession() async -> EmbeddedTailnetAuthSession? {
        session
    }

    func prepareAuthentication(for profile: TailnetProfile) async throws -> EmbeddedTailnetAuthSession {
        let session = EmbeddedTailnetAuthSession(
            profileID: profile.id,
            phase: .pendingUserAction,
            ticket: EmbeddedTailnetAuthTicket(
                profileID: profile.id,
                authURL: profile.controlURL,
                displayedCode: String(profile.id.uuidString.prefix(6)).uppercased()
            )
        )
        self.session = session
        return session
    }

    func markAuthenticated(profile: TailnetProfile) async -> EmbeddedTailnetAuthSession {
        let session = EmbeddedTailnetAuthSession(
            profileID: profile.id,
            phase: .authenticated
        )
        self.session = session
        return session
    }

    func clearSession(for profileID: TailnetProfile.ID?) async {
        guard let profileID else {
            session = nil
            return
        }

        if session?.profileID == profileID {
            session = nil
        }
    }
}

private struct StubEmbeddedTailnetNativeTransportEndpointProvider: EmbeddedTailnetNativeTransportEndpointProviding {
    let endpoint: EmbeddedTailnetNativeTransportEndpoint?

    func endpoint(for profile: TailnetProfile) async -> EmbeddedTailnetNativeTransportEndpoint? {
        _ = profile
        return endpoint
    }
}

private struct StubReadyEmbeddedTailnetDialerAdapter: EmbeddedTailnetDialerAdapting {
    func runtimeHealth(
        for profile: TailnetProfile?,
        authSession: EmbeddedTailnetAuthSession?
    ) async -> EmbeddedTailnetRuntimeHealth {
        _ = authSession
        guard profile != nil else {
            return EmbeddedTailnetRuntimeHealth(state: .idle)
        }

        return EmbeddedTailnetRuntimeHealth(
            state: .ready,
            lastCheckedAt: .now
        )
    }

    func dialPlan(
        for profile: TailnetProfile?,
        health: EmbeddedTailnetRuntimeHealth
    ) async -> EmbeddedTailnetDialPlan? {
        guard let profile else {
            return nil
        }

        return EmbeddedTailnetDialPlan(
            profileID: profile.id,
            routeKind: .embeddedTailnet,
            preferredHost: profile.tailnetDNSName ?? "example-mac.example.ts.net",
            magicDNSName: profile.tailnetDNSName ?? "example-mac.example.ts.net",
            requiresExternalApp: false,
            socksProxyHost: "127.0.0.1",
            socksProxyPort: 1055,
            supportsNativeSSHTransport: health.isReachable
        )
    }
}
