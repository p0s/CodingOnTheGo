import CompanionHost
import Foundation
import SharedModels

public enum DiscoverySource: String, Codable, CaseIterable, Sendable {
    case cachedProbe
    case bonjourSSH
    case companionAdvertisement
    case subnetReachability
    case manualAdd
}

public struct DiscoveryRouteSample: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var machineID: MachineRecord.ID?
    public var machineAlias: String
    public var hostname: String
    public var ipAddress: String?
    public var port: Int
    public var kind: MachineRouteKind
    public var source: DiscoverySource
    public var fingerprint: String?
    public var health: RouteHealthStatus
    public var capabilities: HostCapabilitySnapshot?
    public var lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        machineID: MachineRecord.ID? = nil,
        machineAlias: String,
        hostname: String,
        ipAddress: String? = nil,
        port: Int,
        kind: MachineRouteKind,
        source: DiscoverySource,
        fingerprint: String? = nil,
        health: RouteHealthStatus,
        capabilities: HostCapabilitySnapshot? = nil,
        lastSeenAt: Date = .now
    ) {
        self.id = id
        self.machineID = machineID
        self.machineAlias = machineAlias
        self.hostname = hostname
        self.ipAddress = ipAddress
        self.port = port
        self.kind = kind
        self.source = source
        self.fingerprint = fingerprint
        self.health = health
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
    }
}

public struct DiscoveryMergeResult: Hashable, Sendable {
    public var machines: [MachineRecord]
    public var updatedMachineID: MachineRecord.ID?
    public var createdMachine: Bool

    public init(machines: [MachineRecord], updatedMachineID: MachineRecord.ID?, createdMachine: Bool) {
        self.machines = machines
        self.updatedMachineID = updatedMachineID
        self.createdMachine = createdMachine
    }
}

public struct ManualRouteEntryDraft: Hashable, Codable, Sendable {
    public var label: String
    public var address: String
    public var kind: MachineRouteKind
    public var usernameHint: String?
    public var port: UInt16?

    public init(
        label: String,
        address: String,
        kind: MachineRouteKind,
        usernameHint: String? = nil,
        port: UInt16? = nil
    ) {
        self.label = label
        self.address = address
        self.kind = kind
        self.usernameHint = usernameHint
        self.port = port
    }
}

public struct DiscoverySnapshot: Hashable, Codable, Sendable {
    public var machineID: MachineRecord.ID
    public var scannedAt: Date
    public var manualRouteCount: Int
    public var publishedRouteCount: Int
    public var recommendedRouteLabel: String
    public var notes: [String]

    public init(
        machineID: MachineRecord.ID,
        scannedAt: Date = .now,
        manualRouteCount: Int,
        publishedRouteCount: Int,
        recommendedRouteLabel: String,
        notes: [String]
    ) {
        self.machineID = machineID
        self.scannedAt = scannedAt
        self.manualRouteCount = manualRouteCount
        self.publishedRouteCount = publishedRouteCount
        self.recommendedRouteLabel = recommendedRouteLabel
        self.notes = notes
    }
}

public struct DiscoveryScanReport: Hashable, Sendable {
    public var machines: [MachineRecord]
    public var samples: [DiscoveryRouteSample]
    public var updatedMachineIDs: [MachineRecord.ID]
    public var createdMachineIDs: [MachineRecord.ID]

    public init(
        machines: [MachineRecord],
        samples: [DiscoveryRouteSample],
        updatedMachineIDs: [MachineRecord.ID],
        createdMachineIDs: [MachineRecord.ID]
    ) {
        self.machines = machines
        self.samples = samples
        self.updatedMachineIDs = updatedMachineIDs
        self.createdMachineIDs = createdMachineIDs
    }
}

public protocol LANRouteDiscovering: Sendable {
    func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample]
}

public actor DiscoveryCoordinator {
    private let engine = DiscoveryEngine()
    private let discoverer: any LANRouteDiscovering

    public init(discoverer: any LANRouteDiscovering = BonjourLANScanner()) {
        self.discoverer = discoverer
    }

    public func makeManualRoute(from draft: ManualRouteEntryDraft) throws -> RouteRecord {
        let normalizedAddress = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = draft.usernameHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAddress.isEmpty else {
            throw DiscoveryCoordinatorError.invalidManualAddress
        }

        return RouteRecord(
            kind: draft.kind,
            label: draft.label.isEmpty ? "Manual route" : draft.label,
            hostname: normalizedAddress,
            ipAddress: draft.kind == .localLAN ? normalizedAddress : nil,
            sshPort: draft.port ?? 22,
            usernameHint: normalizedUsername?.isEmpty == false ? normalizedUsername : nil,
            companionEndpoint: draft.kind == .companionDirect ? URL(string: normalizedAddress) : nil,
            requiresExternalApp: draft.kind == .externalTailnet,
            health: .unavailable,
            isUserPinned: true,
            discoverySource: .manual,
            trustState: .unknown
        )
    }

    public func snapshot(
        for machine: MachineRecord,
        manualRoutes: [RouteRecord],
        publishedRoutes: [PublishedRoute],
        discoveredSamples: [DiscoveryRouteSample] = []
    ) -> DiscoverySnapshot {
        let bestCandidate = engine.bestCandidate(for: machine, discovered: discoveredSamples)
        let recommendedLabel = bestCandidate
            .flatMap { sample in
                machine.routes.first { route in
                    route.kind == sample.kind
                        && route.sshPort == UInt16(sample.port)
                        && !engine.sampleMatchTokens(for: sample)
                            .isDisjoint(with: engine.routeMatchTokens(for: route))
                }?.label
            }
            ?? bestCandidate?.kind.title
            ?? machine.preferredRoute?.label
            ?? "No recommended route"

        var notes: [String] = []
        if !manualRoutes.isEmpty {
            notes.append("\(manualRoutes.count) manual route\(manualRoutes.count == 1 ? "" : "s") available.")
        }
        if let published = publishedRoutes.first(where: { $0.health.isReachable }) {
            notes.append("Companion published \(published.kind.title.lowercased()) at \(published.address).")
        }
        if !discoveredSamples.isEmpty {
            let healthyCount = discoveredSamples.filter { $0.health == .healthy }.count
            notes.append("Local discovery saw \(healthyCount) healthy route\(healthyCount == 1 ? "" : "s") during the last scan.")
        }
        if notes.isEmpty {
            notes.append("Discovery has no healthy published or manual routes yet.")
        }

        return DiscoverySnapshot(
            machineID: machine.id,
            manualRouteCount: manualRoutes.count,
            publishedRouteCount: publishedRoutes.count,
            recommendedRouteLabel: recommendedLabel,
            notes: notes
        )
    }

    public func scanAndMerge(
        into machines: [MachineRecord],
        timeout: TimeInterval = 1.5
    ) async -> DiscoveryScanReport {
        let samples = await discoverer.scan(knownMachines: machines, timeout: timeout)
        return merge(deduplicate(samples), into: machines)
    }

    public func mergeSamples(
        _ samples: [DiscoveryRouteSample],
        into machines: [MachineRecord]
    ) -> DiscoveryScanReport {
        merge(deduplicate(samples), into: machines)
    }

    private func merge(
        _ samples: [DiscoveryRouteSample],
        into machines: [MachineRecord]
    ) -> DiscoveryScanReport {
        var workingMachines = machines
        var updatedMachineIDs: [MachineRecord.ID] = []
        var createdMachineIDs: [MachineRecord.ID] = []
        let fingerprintIndex = Dictionary(
            uniqueKeysWithValues: machines.compactMap { machine in
                machine.stableHostFingerprint.map { ($0, machine.id) }
            }
        )

        for sample in samples {
            let result = engine.merge(sample, into: workingMachines, fingerprintIndex: fingerprintIndex)
            workingMachines = result.machines
            if let machineID = result.updatedMachineID {
                updatedMachineIDs.append(machineID)
                if result.createdMachine {
                    createdMachineIDs.append(machineID)
                }
            }
        }

        return DiscoveryScanReport(
            machines: workingMachines,
            samples: samples,
            updatedMachineIDs: Array(Set(updatedMachineIDs)),
            createdMachineIDs: Array(Set(createdMachineIDs))
        )
    }

    private func deduplicate(_ samples: [DiscoveryRouteSample]) -> [DiscoveryRouteSample] {
        var bestByKey: [String: DiscoveryRouteSample] = [:]

        for sample in samples {
            let key = [
                sample.machineID?.uuidString ?? "_",
                sample.kind.rawValue,
                sample.hostname.lowercased(),
                String(sample.port)
            ].joined(separator: "|")

            if let existing = bestByKey[key] {
                if existing.health.priority < sample.health.priority || existing.lastSeenAt < sample.lastSeenAt {
                    bestByKey[key] = sample
                }
            } else {
                bestByKey[key] = sample
            }
        }

        return bestByKey.values.sorted { lhs, rhs in
            if lhs.health.priority != rhs.health.priority {
                return lhs.health.priority > rhs.health.priority
            }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }
}

public enum DiscoveryCoordinatorError: LocalizedError {
    case invalidManualAddress

    public var errorDescription: String? {
        switch self {
        case .invalidManualAddress:
            "Enter a hostname, IP address, or loopback endpoint for the manual route."
        }
    }
}

public struct DiscoveryEngine: Sendable {
    public init() {}

    public func merge(
        _ sample: DiscoveryRouteSample,
        into machines: [MachineRecord],
        fingerprintIndex: [String: MachineRecord.ID] = [:]
    ) -> DiscoveryMergeResult {
        var machines = machines

        let targetMachineID = sample.machineID
            ?? sample.fingerprint.flatMap { fingerprintIndex[$0] }
            ?? machines.first(where: {
                !sampleMatchTokens(for: sample).isDisjoint(with: machineMatchTokens(for: $0))
                    && !hasFingerprintConflict(existing: $0.stableHostFingerprint, discovered: sample.fingerprint)
            })?.id

        if let targetMachineID,
           let index = machines.firstIndex(where: { $0.id == targetMachineID }) {
            let machine = machines[index]
            machines[index] = merging(sample, into: machine)
            return DiscoveryMergeResult(
                machines: machines,
                updatedMachineID: targetMachineID,
                createdMachine: false
            )
        }

        let route = routeRecord(from: sample)
        let createdMachine = MachineRecord(
            id: sample.machineID ?? UUID(),
            displayName: sample.machineAlias,
            hostname: sample.hostname,
            stableHostFingerprint: sample.fingerprint,
            lastKnownUser: nil,
            lastConnectedAt: nil,
            preferredRouteID: nil,
            lastSuccessfulRouteID: nil,
            capabilitySnapshotID: sample.capabilities?.id,
            notes: nil,
            isPinned: false,
            sortRank: 0,
            routes: [route],
            capabilities: sample.capabilities ?? HostCapabilitySnapshot(
                remoteLoginEnabled: sample.kind == .manualSSH,
                codexInstalled: false,
                supportsWebsocketListen: false,
                codexAppInstalled: false
            )
        )
        machines.append(createdMachine)
        return DiscoveryMergeResult(
            machines: machines,
            updatedMachineID: createdMachine.id,
            createdMachine: true
        )
    }

    public func bestCandidate(for machine: MachineRecord, discovered samples: [DiscoveryRouteSample]) -> DiscoveryRouteSample? {
        samples
            .filter {
                $0.machineID == machine.id
                    || !sampleMatchTokens(for: $0).isDisjoint(with: machineMatchTokens(for: machine))
                    || $0.machineAlias == machine.alias
            }
            .sorted { lhs, rhs in
                if lhs.health != rhs.health {
                    return lhs.health.priority > rhs.health.priority
                }
                if lhs.kind.discoveryPriority != rhs.kind.discoveryPriority {
                    return lhs.kind.discoveryPriority < rhs.kind.discoveryPriority
                }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            .first
    }

    private func merging(_ sample: DiscoveryRouteSample, into machine: MachineRecord) -> MachineRecord {
        var machine = machine
        let previousHostname = machine.hostname
        machine.hostname = sample.hostname
        let previousDisplayName = machine.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousInferredName = inferredMachineDisplayName(from: previousHostname)
        if previousDisplayName.isEmpty || previousDisplayName == previousInferredName {
            let discoveredName = sample.machineAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            machine.displayName = discoveredName.isEmpty
                ? inferredMachineDisplayName(from: sample.hostname)
                : discoveredName
        }
        machine.stableHostFingerprint = sample.fingerprint ?? machine.stableHostFingerprint
        machine.capabilities = sample.capabilities ?? machine.capabilities

        let newRoute = routeRecord(from: sample)
        if let existingIndex = machine.routes.firstIndex(where: { $0.kind == newRoute.kind }) {
            let existing = machine.routes[existingIndex]
            machine.routes[existingIndex] = RouteRecord(
                id: existing.id,
                machineID: machine.id,
                kind: existing.kind,
                label: newRoute.label,
                hostname: newRoute.hostname,
                ipAddress: newRoute.ipAddress ?? existing.ipAddress,
                magicDNSName: newRoute.magicDNSName,
                sshPort: newRoute.sshPort,
                usernameHint: newRoute.usernameHint ?? existing.usernameHint,
                companionEndpoint: newRoute.companionEndpoint ?? existing.companionEndpoint,
                tailnetProfileID: newRoute.tailnetProfileID ?? existing.tailnetProfileID,
                requiresExternalApp: newRoute.requiresExternalApp,
                health: newRoute.health,
                lastLatencyMs: newRoute.lastLatencyMs ?? existing.lastLatencyMs,
                lastCheckedAt: newRoute.lastCheckedAt,
                lastSuccessAt: existing.lastSuccessAt,
                lastFailureAt: newRoute.health == .unavailable ? newRoute.lastFailureAt : nil,
                failureReasonCode: newRoute.health == .unavailable ? newRoute.failureReasonCode : nil,
                isRecommended: newRoute.isRecommended,
                isUserPinned: existing.isUserPinned,
                publishedByCompanion: existing.publishedByCompanion,
                discoverySource: newRoute.discoverySource,
                trustState: existing.trustState,
                trustedOpenSSHPublicKey: existing.trustedOpenSSHPublicKey
            )
        } else {
            machine.routes.append(
                RouteRecord(
                    id: newRoute.id,
                    machineID: machine.id,
                    kind: newRoute.kind,
                    label: newRoute.label,
                    hostname: newRoute.hostname,
                    ipAddress: newRoute.ipAddress,
                    magicDNSName: newRoute.magicDNSName,
                    sshPort: newRoute.sshPort,
                    usernameHint: newRoute.usernameHint,
                    companionEndpoint: newRoute.companionEndpoint,
                    tailnetProfileID: newRoute.tailnetProfileID,
                    requiresExternalApp: newRoute.requiresExternalApp,
                    health: newRoute.health,
                    lastLatencyMs: newRoute.lastLatencyMs,
                    lastCheckedAt: newRoute.lastCheckedAt,
                    lastSuccessAt: newRoute.lastSuccessAt,
                    lastFailureAt: newRoute.lastFailureAt,
                    failureReasonCode: newRoute.failureReasonCode,
                    isRecommended: newRoute.isRecommended,
                    isUserPinned: newRoute.isUserPinned,
                    discoverySource: newRoute.discoverySource,
                    trustState: newRoute.trustState
                )
            )
        }

        return machine
    }

    private func hasFingerprintConflict(existing: String?, discovered: String?) -> Bool {
        guard let existing, let discovered else {
            return false
        }
        return existing != discovered
    }

    private func routeRecord(from sample: DiscoveryRouteSample) -> RouteRecord {
        RouteRecord(
            id: sample.id,
            machineID: sample.machineID,
            kind: sample.kind,
            label: label(for: sample),
            hostname: sample.hostname,
            ipAddress: sample.ipAddress,
            magicDNSName: sample.kind == .embeddedTailnet ? sample.hostname : nil,
            sshPort: UInt16(sample.port),
            usernameHint: nil,
            companionEndpoint: sample.kind == .companionDirect ? URL(string: sample.hostname) : nil,
            tailnetProfileID: nil,
            requiresExternalApp: sample.kind == .externalTailnet,
            health: sample.health,
            lastLatencyMs: nil,
            lastCheckedAt: sample.lastSeenAt,
            lastSuccessAt: nil,
            lastFailureAt: sample.health == .unavailable ? sample.lastSeenAt : nil,
            failureReasonCode: sample.health == .unavailable ? "unreachable" : nil,
            isRecommended: sample.health == .healthy,
            isUserPinned: false,
            discoverySource: discoverySource(from: sample.source),
            trustState: .unknown
        )
    }

    fileprivate func sampleMatchTokens(for sample: DiscoveryRouteSample) -> Set<String> {
        routeHostTokens(
            hostname: sample.hostname,
            ipAddress: sample.ipAddress,
            magicDNSName: sample.kind == .embeddedTailnet ? sample.hostname : nil
        )
    }

    fileprivate func routeMatchTokens(for route: RouteRecord) -> Set<String> {
        routeHostTokens(
            hostname: route.hostname,
            ipAddress: route.ipAddress,
            magicDNSName: route.magicDNSName
        )
    }

    private func machineMatchTokens(for machine: MachineRecord) -> Set<String> {
        var tokens = routeHostTokens(
            hostname: machine.hostname,
            ipAddress: nil,
            magicDNSName: nil
        )
        for route in machine.routes {
            tokens.formUnion(routeMatchTokens(for: route))
        }
        return tokens
    }

    private func routeHostTokens(
        hostname: String?,
        ipAddress: String?,
        magicDNSName: String?
    ) -> Set<String> {
        Set(
            [hostname, ipAddress, magicDNSName]
                .compactMap { value in
                    value?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )
    }

    private func inferredMachineDisplayName(from hostname: String) -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "My Mac"
        }

        let primaryComponent = trimmed
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let primaryComponent, !primaryComponent.isEmpty {
            return primaryComponent
        }

        return "My Mac"
    }

    private func discoverySource(from source: DiscoverySource) -> RouteDiscoverySource {
        switch source {
        case .cachedProbe:
            .cachedProbe
        case .bonjourSSH:
            .bonjour
        case .companionAdvertisement:
            .companionAdvertisement
        case .subnetReachability:
            .cachedProbe
        case .manualAdd:
            .manual
        }
    }

    private func label(for sample: DiscoveryRouteSample) -> String {
        switch sample.source {
        case .bonjourSSH:
            "Bonjour SSH"
        case .companionAdvertisement:
            "Companion route"
        case .subnetReachability:
            "Subnet reachability"
        case .cachedProbe:
            "Cached probe"
        case .manualAdd:
            "Manual route"
        }
    }
}

private extension RouteHealthStatus {
    var priority: Int {
        switch self {
        case .healthy:
            3
        case .degraded:
            2
        case .unavailable:
            1
        }
    }
}

private extension MachineRouteKind {
    var discoveryPriority: Int {
        switch self {
        case .embeddedTailnet:
            0
        case .localLAN:
            1
        case .manualSSH:
            2
        case .externalTailnet:
            3
        case .companionDirect:
            4
        }
    }
}
