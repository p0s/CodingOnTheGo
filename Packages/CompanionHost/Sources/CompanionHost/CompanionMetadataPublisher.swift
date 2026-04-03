import Foundation
import Persistence
import SharedModels
import SyncEngine

public protocol CompanionMetadataPublishing: Sendable {
    func publish(_ snapshot: CompanionHostSnapshot) async throws -> CompanionPublicationStatus
}

public actor CompanionMetadataPublisher: CompanionMetadataPublishing {
    private let metadataStore: any MetadataStore
    private let syncCoordinator: any SyncCoordinator
    private let metadataURL: URL
    private let syncMirrorURL: URL
    private let runtimeConfiguration: AppRuntimeConfiguration

    public init(
        metadataStore: any MetadataStore = JSONMetadataStore(),
        syncCoordinator: (any SyncCoordinator)? = nil,
        runtimeConfiguration: AppRuntimeConfiguration = .localOnly(),
        metadataURL: URL? = nil,
        syncMirrorURL: URL? = nil
    ) {
        let resolvedMetadataURL = metadataURL ?? runtimeConfiguration.paths.metadataStoreURL
        let resolvedSyncMirrorURL = syncMirrorURL ?? runtimeConfiguration.paths.syncMirrorURL

        self.metadataStore = metadataStore
        self.syncCoordinator = syncCoordinator ?? FileBackedSyncCoordinator(mirrorURL: resolvedSyncMirrorURL)
        self.metadataURL = resolvedMetadataURL
        self.syncMirrorURL = resolvedSyncMirrorURL
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func publish(_ snapshot: CompanionHostSnapshot) async throws -> CompanionPublicationStatus {
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.createDirectory(
            at: syncMirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let existing: MachineDirectorySnapshot
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            existing = try await metadataStore.load(from: metadataURL)
        } else {
            existing = emptySnapshot()
        }
        let locallyMerged = upsert(snapshot, into: existing)
        try await metadataStore.save(locallyMerged, to: metadataURL)

        let syncedSnapshot = try await syncCoordinator.stage(locallyMerged)
        try await metadataStore.save(syncedSnapshot, to: metadataURL)

        let machineID = matchingMachineID(in: syncedSnapshot, snapshot: snapshot)
            ?? locallyMerged.machines.last?.id

        return CompanionPublicationStatus(
            metadataPath: metadataURL.path,
            syncMirrorPath: syncMirrorURL.path,
            publishedMachineID: machineID,
            publishedRouteCount: snapshot.publishedRoutes.count,
            lastPublishedAt: .now,
            note: publicationNote(for: locallyMerged.preferences.privacyMode)
        )
    }

    private func emptySnapshot() -> MachineDirectorySnapshot {
        MachineDirectorySnapshot(
            machines: [],
            tailnetProfiles: [],
            recentSessions: [],
            preferences: UserPreferencesSnapshot()
        )
    }

    private func upsert(
        _ snapshot: CompanionHostSnapshot,
        into directory: MachineDirectorySnapshot
    ) -> MachineDirectorySnapshot {
        var machines = directory.machines
        let privacyMode = directory.preferences.privacyMode
        let machineID = matchingMachineID(in: directory, snapshot: snapshot)
            ?? UUID()

        let existingIndex = machines.firstIndex(where: { $0.id == machineID })
        var machine = existingIndex.flatMap { machines[$0] } ?? MachineRecord(
            id: machineID,
            displayName: shortDisplayName(for: snapshot.hostDisplayName),
            hostname: snapshot.hostDisplayName,
            routes: [],
            capabilities: HostCapabilitySnapshot(
                machineID: machineID,
                remoteLoginEnabled: true,
                codexInstalled: snapshot.capabilities.canWarmSharedListener,
                supportsAppServer: snapshot.capabilities.canWarmSharedListener,
                supportsWebsocketListen: snapshot.capabilities.canWarmSharedListener,
                companionVersion: privacyMode == .privacy ? nil : companionVersion(),
                companionState: snapshot.sharedListenerState.rawValue,
                codexAppInstalled: privacyMode == .privacy ? false : true,
                hostOSVersion: privacyMode == .privacy ? nil : hostOSVersion()
            )
        )

        machine.displayName = shortDisplayName(for: snapshot.hostDisplayName)
        machine.hostname = snapshot.hostDisplayName
        machine.capabilities = updatedCapabilities(
            for: machineID,
            snapshot: snapshot,
            privacyMode: privacyMode
        )
        machine.routes = mergedRoutes(existing: machine.routes, snapshot: snapshot, machineID: machineID)
        machine.preferredRouteID = machine.routes.first(where: \.isRecommended)?.id ?? machine.preferredRouteID

        if let index = existingIndex {
            machines[index] = machine
        } else {
            machines.append(machine)
        }

        return MachineDirectorySnapshot(
            machines: machines.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }),
            tailnetProfiles: directory.tailnetProfiles,
            recentSessions: directory.recentSessions,
            preferences: directory.preferences
        )
    }

    private func updatedCapabilities(
        for machineID: UUID,
        snapshot: CompanionHostSnapshot,
        privacyMode: AppPrivacyMode
    ) -> HostCapabilitySnapshot {
        HostCapabilitySnapshot(
            machineID: machineID,
            remoteLoginEnabled: snapshot.publishedRoutes.contains(where: { $0.kind == .localLAN || $0.kind == .manualSSH }),
            codexInstalled: snapshot.capabilities.canWarmSharedListener,
            supportsAppServer: snapshot.capabilities.canWarmSharedListener,
            supportsWebsocketListen: snapshot.capabilities.canWarmSharedListener,
            supportsVoiceInput: true,
            supportsAttachments: true,
            companionVersion: privacyMode == .privacy ? nil : companionVersion(),
            companionState: snapshot.sharedListenerState.rawValue,
            codexAppInstalled: privacyMode == .privacy ? false : true,
            hostOSVersion: privacyMode == .privacy ? nil : hostOSVersion()
        )
    }

    private func mergedRoutes(
        existing: [RouteRecord],
        snapshot: CompanionHostSnapshot,
        machineID: UUID
    ) -> [RouteRecord] {
        let recommendedKey = snapshot.recommendedPublishedRoute.map(routeKey(for:))
        let publishedByKey = Dictionary(
            uniqueKeysWithValues: snapshot.publishedRoutes.map { route in
                (routeKey(for: route), route)
            }
        )

        var merged: [RouteRecord] = []
        merged.reserveCapacity(max(existing.count, snapshot.publishedRoutes.count))

        for route in existing {
            let key = routeKey(for: route)
            if let published = publishedByKey[key] {
                merged.append(update(route: route, from: published, machineID: machineID, isRecommended: key == recommendedKey))
            } else if route.publishedByCompanion {
                if route.discoverySource != .companionAdvertisement {
                    var retained = route
                    retained.publishedByCompanion = false
                    retained.isRecommended = false
                    merged.append(retained)
                }
            } else {
                merged.append(route)
            }
        }

        let existingKeys = Set(merged.map(routeKey(for:)))
        for published in snapshot.publishedRoutes where !existingKeys.contains(routeKey(for: published)) {
            merged.append(makeRoute(from: published, machineID: machineID, isRecommended: routeKey(for: published) == recommendedKey))
        }

        return merged.sorted(by: {
            if $0.isRecommended != $1.isRecommended {
                return $0.isRecommended && !$1.isRecommended
            }
            return $0.kind.rawValue < $1.kind.rawValue
        })
    }

    private func makeRoute(
        from published: PublishedRoute,
        machineID: UUID,
        isRecommended: Bool
    ) -> RouteRecord {
        let endpoint = parsedAddress(published.address, kind: published.kind)
        return RouteRecord(
            machineID: machineID,
            kind: published.kind,
            label: published.kind.title,
            hostname: endpoint.hostname,
            ipAddress: endpoint.ipAddress,
            companionEndpoint: endpoint.companionEndpoint,
            health: published.health,
            lastCheckedAt: .now,
            failureReasonCode: published.health == .unavailable ? "companion-unavailable" : nil,
            isRecommended: isRecommended,
            publishedByCompanion: true,
            discoverySource: .companionAdvertisement,
            trustState: .trusted
        )
    }

    private func update(
        route: RouteRecord,
        from published: PublishedRoute,
        machineID: UUID,
        isRecommended: Bool
    ) -> RouteRecord {
        let endpoint = parsedAddress(published.address, kind: published.kind)
        var updated = route
        updated.machineID = machineID
        updated.health = published.health
        updated.lastCheckedAt = .now
        updated.failureReasonCode = published.health == .unavailable ? "companion-unavailable" : nil
        updated.isRecommended = isRecommended
        updated.publishedByCompanion = true
        updated.hostname = endpoint.hostname ?? updated.hostname
        updated.ipAddress = endpoint.ipAddress ?? updated.ipAddress
        updated.companionEndpoint = endpoint.companionEndpoint ?? updated.companionEndpoint
        if updated.discoverySource == .companionAdvertisement || route.publishedByCompanion {
            updated.discoverySource = .companionAdvertisement
        }
        return updated
    }

    private func matchingMachineID(
        in directory: MachineDirectorySnapshot,
        snapshot: CompanionHostSnapshot
    ) -> UUID? {
        let routeAddresses = Set(snapshot.publishedRoutes.map { $0.address.lowercased() })

        if let exactRouteMatch = directory.machines.first(where: { machine in
            machine.routes.contains(where: { route in
                route.publishedByCompanion && routeAddresses.contains(route.address.lowercased())
            })
        }) {
            return exactRouteMatch.id
        }

        if let fingerprintMatch = directory.machines.first(where: { machine in
            machine.routes.contains(where: { route in
                route.trustState == .trusted
                    && route.trustedOpenSSHPublicKey != nil
                    && routeAddresses.contains(route.address.lowercased())
            })
        }) {
            return fingerprintMatch.id
        }

        return nil
    }

    private func routeKey(for route: PublishedRoute) -> String {
        "\(route.kind.rawValue)|\(route.address.lowercased())"
    }

    private func routeKey(for route: RouteRecord) -> String {
        "\(route.kind.rawValue)|\(route.address.lowercased())"
    }

    private func parsedAddress(_ address: String, kind: MachineRouteKind) -> (hostname: String?, ipAddress: String?, companionEndpoint: URL?) {
        if kind == .companionDirect, let url = URL(string: address) {
            return (nil, nil, url)
        }

        if isIPAddress(address) {
            return (nil, address, nil)
        }

        return (address, nil, nil)
    }

    private func shortDisplayName(for host: String) -> String {
        if let first = host.split(separator: ".").first {
            let value = String(first)
            if !value.isEmpty {
                return value
            }
        }

        return host
    }

    private func isIPAddress(_ value: String) -> Bool {
        value.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
            || value.contains(":")
    }

    private func publicationNote(for privacyMode: AppPrivacyMode) -> String {
        switch privacyMode {
        case .standard:
            "Published companion presence and route health into shared machine metadata and the local sync mirror."
        case .privacy:
            "Published companion presence with reduced host metadata. SSH-safe-lane trust remains the identity anchor."
        }
    }

    private func companionVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private func hostOSVersion() -> String? {
        let processInfo = ProcessInfo.processInfo.operatingSystemVersion
        return "\(processInfo.majorVersion).\(processInfo.minorVersion).\(processInfo.patchVersion)"
    }
}
