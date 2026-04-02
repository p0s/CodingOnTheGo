import Foundation
import Persistence
import SharedModels

public enum SyncRecordKind: String, Codable, CaseIterable, Sendable {
    case machine
    case route
    case tailnetProfile
    case session
    case hostThreadCatalogEntry
    case preferences
}

public enum SyncRecordSensitivity: String, Codable, CaseIterable, Sendable {
    case durablePreferenceState
    case localOperationalState
    case sensitiveConvenienceMetadata
    case secret
}

public struct SyncRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: SyncRecordKind
    public var sensitivity: SyncRecordSensitivity
    public var encodedPayload: Data
    public var updatedAt: Date

    public init(
        id: String,
        kind: SyncRecordKind,
        sensitivity: SyncRecordSensitivity,
        encodedPayload: Data,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.sensitivity = sensitivity
        self.encodedPayload = encodedPayload
        self.updatedAt = updatedAt
    }
}

public struct SyncProjection: Hashable, Sendable {
    public var records: [SyncRecord]
    public var secretBoundaryNote: String

    public init(records: [SyncRecord], secretBoundaryNote: String) {
        self.records = records
        self.secretBoundaryNote = secretBoundaryNote
    }
}

public struct SyncMachinePayload: Codable, Hashable, Sendable {
    public var id: UUID
    public var alias: String
    public var hostname: String
    public var platform: MachinePlatform
    public var stableHostFingerprint: String?
    public var lastKnownUser: String?
    public var lastConnectedAt: Date?
    public var preferredRouteID: UUID?
    public var lastSuccessfulRouteID: UUID?
    public var routeCount: Int
    public var preferredRouteKind: MachineRouteKind?
    public var capabilitySnapshot: HostCapabilitySnapshot
    public var notes: String?
    public var isPinned: Bool
    public var sortRank: Int
}

public struct SyncRoutePayload: Codable, Hashable, Sendable {
    public var id: UUID
    public var machineID: UUID
    public var kind: MachineRouteKind
    public var label: String
    public var address: String
    public var hostname: String?
    public var ipAddress: String?
    public var magicDNSName: String?
    public var sshPort: UInt16
    public var usernameHint: String?
    public var companionEndpoint: URL?
    public var tailnetProfileID: UUID?
    public var requiresExternalApp: Bool
    public var health: RouteHealthStatus
    public var lastLatencyMs: Int?
    public var lastCheckedAt: Date?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var failureReasonCode: String?
    public var isPreferred: Bool
    public var isUserPinned: Bool
    public var publishedByCompanion: Bool
    public var discoverySource: RouteDiscoverySource
    public var trustState: RouteTrustState
    public var trustedOpenSSHPublicKey: String?
}

public struct SyncTailnetProfilePayload: Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: TailnetProfileType
    public var displayName: String
    public var controlURL: URL
    public var accountLabel: String
    public var tailnetDNSName: String?
    public var usesEmbeddedNode: Bool
    public var isActive: Bool
    public var lastActivatedAt: Date?
    public var lastAuthenticatedAt: Date?
    public var supportsCustomControlServer: Bool
    public var requiresExternalApp: Bool
}

public struct SyncSessionPayload: Codable, Hashable, Sendable {
    public var id: UUID
    public var sceneID: String?
    public var machineID: UUID
    public var routeID: UUID?
    public var threadID: String?
    public var reviewThreadID: String?
    public var workspaceRoot: String?
    public var transportMode: SessionTransportMode
    public var lastKnownProtocol: CodexProtocolKind
    public var lastKnownRouteKind: MachineRouteKind?
    public var lastKnownBootstrap: BootstrapStrategy
    public var lastModel: String?
    public var lastReasoningEffort: ReasoningEffortLevel
    public var lastMode: WorkspaceMode
    public var lastTurnID: String?
    public var lastTurn: RecentTurnMetadata?
    public var lastOpenedAt: Date
    public var resumeStrategy: ResumeStrategy
    public var queuedPrompts: [String]
    public var lastErrorSummary: String?
    public var parentThreadID: String?
    public var parentLastTurnID: String?
}

public struct SyncHostThreadCatalogPayload: Codable, Hashable, Sendable {
    public var id: String
    public var machineID: UUID
    public var workspaceRoot: String
    public var name: String?
    public var preview: String
    public var modelProvider: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct SyncPreferencesPayload: Codable, Hashable, Sendable {
    public var preferredMachineID: UUID?
    public var preferredTailnetProfileID: UUID?
    public var restoreLastSessionOnLaunch: Bool
    public var preferredBootstrap: BootstrapStrategy?
    public var preferredProtocol: CodexProtocolKind?
    public var preferredReasoningEffort: String?
    public var preferredApprovalPolicy: String?
    public var preferredSandboxMode: String?
    public var privacyMode: AppPrivacyMode
}

public struct SyncMergeEngine: Sendable {
    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func project(_ snapshot: MachineDirectorySnapshot) -> SyncProjection {
        var records: [SyncRecord] = []

        for machine in snapshot.machines {
            records.append(
                SyncRecord(
                    id: "machine/\(machine.id.uuidString)",
                    kind: .machine,
                    sensitivity: .durablePreferenceState,
                    encodedPayload: encode(
                        SyncMachinePayload(
                            id: machine.id,
                            alias: machine.alias,
                            hostname: machine.hostname,
                            platform: machine.platform,
                            stableHostFingerprint: machine.stableHostFingerprint,
                            lastKnownUser: machine.lastKnownUser,
                            lastConnectedAt: machine.lastConnectedAt,
                            preferredRouteID: machine.preferredRouteID,
                            lastSuccessfulRouteID: machine.lastSuccessfulRouteID,
                            routeCount: machine.routes.count,
                            preferredRouteKind: machine.preferredRoute?.kind,
                            capabilitySnapshot: machine.capabilities,
                            notes: machine.notes,
                            isPinned: machine.isPinned,
                            sortRank: machine.sortRank
                        )
                    ),
                    updatedAt: machine.lastConnectedAt ?? machine.capabilities.capturedAt
                )
            )

            for route in machine.routes {
                records.append(
                    SyncRecord(
                        id: "route/\(machine.id.uuidString)/\(route.id.uuidString)",
                        kind: .route,
                        sensitivity: .durablePreferenceState,
                        encodedPayload: encode(
                            SyncRoutePayload(
                                id: route.id,
                                machineID: machine.id,
                                kind: route.kind,
                                label: route.label,
                                address: route.address,
                                hostname: route.hostname,
                                ipAddress: route.ipAddress,
                                magicDNSName: route.magicDNSName,
                                sshPort: route.sshPort,
                                usernameHint: route.usernameHint,
                                companionEndpoint: route.companionEndpoint,
                                tailnetProfileID: route.tailnetProfileID,
                                requiresExternalApp: route.requiresExternalApp,
                                health: route.health,
                                lastLatencyMs: route.lastLatencyMs,
                                lastCheckedAt: route.lastCheckedAt,
                                lastSuccessAt: route.lastSuccessAt,
                                lastFailureAt: route.lastFailureAt,
                                failureReasonCode: nil,
                                isPreferred: route.isRecommended || route.isUserPinned,
                                isUserPinned: route.isUserPinned,
                                publishedByCompanion: route.publishedByCompanion,
                                discoverySource: route.discoverySource,
                                trustState: route.trustState,
                                trustedOpenSSHPublicKey: nil
                            )
                        ),
                        updatedAt: route.lastCheckedAt ?? route.lastSuccessAt ?? route.lastFailureAt ?? .now
                    )
                )
            }
        }

        for profile in snapshot.tailnetProfiles {
            records.append(
                SyncRecord(
                    id: "tailnet/\(profile.id.uuidString)",
                    kind: .tailnetProfile,
                    sensitivity: .durablePreferenceState,
                    encodedPayload: encode(
                        SyncTailnetProfilePayload(
                            id: profile.id,
                            kind: profile.kind,
                            displayName: profile.displayName,
                            controlURL: profile.controlURL,
                            accountLabel: profile.accountLabel,
                            tailnetDNSName: profile.tailnetDNSName,
                            usesEmbeddedNode: profile.usesEmbeddedNode,
                            isActive: profile.isActive,
                            lastActivatedAt: profile.lastActivatedAt,
                            lastAuthenticatedAt: profile.lastAuthenticatedAt,
                            supportsCustomControlServer: profile.supportsCustomControlServer,
                            requiresExternalApp: profile.requiresExternalApp
                        )
                    ),
                    updatedAt: profile.lastActivatedAt ?? profile.lastAuthenticatedAt ?? .now
                )
            )
        }

        records.append(
            SyncRecord(
                    id: "preferences/root",
                    kind: .preferences,
                    sensitivity: .durablePreferenceState,
                encodedPayload: encode(
                    SyncPreferencesPayload(
                        preferredMachineID: snapshot.preferences.preferredMachineID,
                        preferredTailnetProfileID: snapshot.preferences.preferredTailnetProfileID,
                        restoreLastSessionOnLaunch: snapshot.preferences.restoreLastSessionOnLaunch,
                        preferredBootstrap: snapshot.preferences.preferredBootstrap,
                        preferredProtocol: snapshot.preferences.preferredProtocol,
                        preferredReasoningEffort: snapshot.preferences.preferredReasoningEffort,
                        preferredApprovalPolicy: snapshot.preferences.preferredApprovalPolicy,
                        preferredSandboxMode: snapshot.preferences.preferredSandboxMode,
                        privacyMode: snapshot.preferences.privacyMode
                        )
                    ),
                    updatedAt: .now
                )
            )

        return SyncProjection(
            records: records,
            secretBoundaryNote: "Secrets stay in Keychain. Thread previews, queued prompts, workspace paths, raw failure summaries, trusted host keys, and host browser caches stay local-only until a later explicit sync/export contract exists."
        )
    }

    public func merge(local: MachineDirectorySnapshot, remote: MachineDirectorySnapshot) -> MachineDirectorySnapshot {
        MachineDirectorySnapshot(
            machines: mergeMachines(local.machines, remote.machines),
            tailnetProfiles: mergeTailnetProfiles(local.tailnetProfiles, remote.tailnetProfiles),
            recentSessions: mergeSessions(local.recentSessions, remote.recentSessions),
            hostThreadCatalog: mergeHostThreadCatalog(local.hostThreadCatalog, remote.hostThreadCatalog),
            preferences: mergePreferences(local.preferences, remote.preferences)
        )
    }

    private func mergeMachines(_ local: [MachineRecord], _ remote: [MachineRecord]) -> [MachineRecord] {
        var merged = local

        for remoteMachine in remote {
            if let index = merged.firstIndex(where: { $0.id == remoteMachine.id }) {
                merged[index] = mergeMachine(merged[index], remoteMachine)
            } else {
                merged.append(remoteMachine)
            }
        }

        return merged
    }

    private func mergeMachine(_ local: MachineRecord, _ remote: MachineRecord) -> MachineRecord {
        var merged = local
        merged.displayName = remote.alias.isEmpty ? local.alias : remote.alias
        merged.hostname = remote.hostname.isEmpty ? local.hostname : remote.hostname
        merged.routes = mergeRoutes(local.routes, remote.routes)
        merged.capabilities = mergeCapabilities(local.capabilities, remote.capabilities, machineID: local.id)
        merged.lastConnectedAt = maxDate(local.lastConnectedAt, remote.lastConnectedAt)
        merged.preferredRouteID = remote.preferredRouteID ?? local.preferredRouteID
        merged.lastSuccessfulRouteID = remote.lastSuccessfulRouteID ?? local.lastSuccessfulRouteID
        merged.credentialRef = remote.credentialRef ?? local.credentialRef
        merged.notes = remote.notes ?? local.notes
        merged.isPinned = local.isPinned || remote.isPinned
        return merged
    }

    private func mergeRoutes(_ local: [RouteRecord], _ remote: [RouteRecord]) -> [RouteRecord] {
        var merged = local

        for remoteRoute in remote {
            if let index = merged.firstIndex(where: { $0.kind == remoteRoute.kind && $0.address == remoteRoute.address }) {
                merged[index] = mergeRoute(merged[index], remoteRoute)
            } else if let index = merged.firstIndex(where: { $0.kind == remoteRoute.kind }) {
                merged[index] = mergeRoute(merged[index], remoteRoute)
            } else {
                merged.append(remoteRoute)
            }
        }

        return merged
    }

    private func mergeRoute(_ local: RouteRecord, _ remote: RouteRecord) -> RouteRecord {
        var merged = local
        merged.label = remote.label.isEmpty ? local.label : remote.label
        merged.hostname = remote.hostname ?? local.hostname
        merged.ipAddress = remote.ipAddress ?? local.ipAddress
        merged.magicDNSName = remote.magicDNSName ?? local.magicDNSName
        merged.usernameHint = remote.usernameHint ?? local.usernameHint
        merged.companionEndpoint = remote.companionEndpoint ?? local.companionEndpoint
        merged.tailnetProfileID = remote.tailnetProfileID ?? local.tailnetProfileID
        merged.requiresExternalApp = local.requiresExternalApp || remote.requiresExternalApp
        merged.health = max(local.health, remote.health)
        merged.lastLatencyMs = remote.lastLatencyMs ?? local.lastLatencyMs
        merged.lastCheckedAt = maxDate(local.lastCheckedAt, remote.lastCheckedAt)
        merged.lastSuccessAt = maxDate(local.lastSuccessAt, remote.lastSuccessAt)
        merged.lastFailureAt = maxDate(local.lastFailureAt, remote.lastFailureAt)
        merged.failureReasonCode = remote.failureReasonCode ?? local.failureReasonCode
        merged.isRecommended = local.isRecommended || remote.isRecommended
        merged.isUserPinned = local.isUserPinned || remote.isUserPinned
        merged.publishedByCompanion = local.publishedByCompanion || remote.publishedByCompanion
        merged.discoverySource = remote.discoverySource
        merged.trustState = remote.trustState == .unknown ? local.trustState : remote.trustState
        return merged
    }

    private func mergeTailnetProfiles(_ local: [TailnetProfile], _ remote: [TailnetProfile]) -> [TailnetProfile] {
        var merged = local

        for remoteProfile in remote {
            if let index = merged.firstIndex(where: { $0.id == remoteProfile.id }) {
                merged[index] = mergeTailnetProfile(merged[index], remoteProfile)
            } else {
                merged.append(remoteProfile)
            }
        }

        return merged
    }

    private func mergeTailnetProfile(_ local: TailnetProfile, _ remote: TailnetProfile) -> TailnetProfile {
        TailnetProfile(
            id: local.id,
            kind: local.usesEmbeddedNode || remote.usesEmbeddedNode ? .embedded : remote.kind,
            displayName: remote.displayName.isEmpty ? local.displayName : remote.displayName,
            controlURL: remote.controlURL,
            accountLabel: remote.accountLabel.isEmpty ? local.accountLabel : remote.accountLabel,
            tailnetDNSName: remote.tailnetDNSName ?? local.tailnetDNSName,
            isActive: local.isActive || remote.isActive,
            lastActivatedAt: maxDate(local.lastActivatedAt, remote.lastActivatedAt),
            lastAuthenticatedAt: maxDate(local.lastAuthenticatedAt, remote.lastAuthenticatedAt),
            supportsCustomControlServer: local.supportsCustomControlServer || remote.supportsCustomControlServer,
            requiresExternalApp: local.requiresExternalApp || remote.requiresExternalApp
        )
    }

    private func mergeSessions(_ local: [SessionRecord], _ remote: [SessionRecord]) -> [SessionRecord] {
        var merged = local

        for remoteSession in remote {
            if let index = merged.firstIndex(where: { $0.id == remoteSession.id }) {
                merged[index] = mergeSession(merged[index], remoteSession)
            } else {
                merged.append(remoteSession)
            }
        }

        return merged.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func mergeHostThreadCatalog(
        _ local: [HostThreadCatalogEntry],
        _ remote: [HostThreadCatalogEntry]
    ) -> [HostThreadCatalogEntry] {
        var merged: [String: HostThreadCatalogEntry] = [:]

        for thread in local {
            let key = "\(thread.machineID.uuidString)::\(thread.id)"
            if let existing = merged[key] {
                merged[key] = existing.merged(with: thread)
            } else {
                merged[key] = thread
            }
        }

        for thread in remote {
            let key = "\(thread.machineID.uuidString)::\(thread.id)"
            if let existing = merged[key] {
                merged[key] = existing.merged(with: thread)
                continue
            }
            merged[key] = thread
        }

        return merged.values.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    private func mergeSession(_ local: SessionRecord, _ remote: SessionRecord) -> SessionRecord {
        let winner = remote.lastOpenedAt > local.lastOpenedAt ? remote : local
        let preservedExecutionProfileState = remote.lastOpenedAt > local.lastOpenedAt
            ? (remote.executionProfileState ?? local.executionProfileState)
            : (local.executionProfileState ?? remote.executionProfileState)
        return SessionRecord(
            id: local.id,
            sceneID: winner.sceneID ?? local.sceneID,
            machineID: local.machineID,
            routeID: winner.routeID ?? local.routeID,
            transportMode: winner.transportMode,
            threadID: winner.threadID ?? local.threadID,
            reviewThreadID: winner.reviewThreadID ?? local.reviewThreadID,
            workspaceRoot: winner.workspaceRoot ?? local.workspaceRoot,
            lastKnownProtocol: winner.lastKnownProtocol,
            lastKnownRouteKind: winner.lastKnownRouteKind ?? local.lastKnownRouteKind,
            lastKnownBootstrap: winner.lastKnownBootstrap,
            lastModel: winner.lastModel ?? local.lastModel,
            lastReasoningEffort: winner.lastReasoningEffort,
            lastMode: winner.lastMode,
            lastTurnID: winner.lastTurnID ?? local.lastTurnID,
            lastTurn: winner.lastTurn ?? local.lastTurn,
            lastOpenedAt: max(local.lastOpenedAt, remote.lastOpenedAt),
            resumeStrategy: winner.resumeStrategy,
            uiStateBlob: winner.uiStateBlob ?? local.uiStateBlob,
            transportState: winner.transportState,
            queuedPrompts: winner.queuedPrompts.isEmpty ? local.queuedPrompts : winner.queuedPrompts,
            lastErrorSummary: winner.lastErrorSummary ?? local.lastErrorSummary,
            parentThreadID: winner.parentThreadID ?? local.parentThreadID,
            parentLastTurnID: winner.parentLastTurnID ?? local.parentLastTurnID,
            isArchived: local.isArchived || remote.isArchived,
            executionProfileState: preservedExecutionProfileState
        )
    }

    private func mergePreferences(_ local: UserPreferencesSnapshot, _ remote: UserPreferencesSnapshot) -> UserPreferencesSnapshot {
        UserPreferencesSnapshot(
            preferredMachineID: remote.preferredMachineID ?? local.preferredMachineID,
            preferredTailnetProfileID: remote.preferredTailnetProfileID ?? local.preferredTailnetProfileID,
            restoreLastSessionOnLaunch: local.restoreLastSessionOnLaunch || remote.restoreLastSessionOnLaunch,
            preferredBootstrap: remote.preferredBootstrap ?? local.preferredBootstrap,
            preferredProtocol: remote.preferredProtocol ?? local.preferredProtocol,
            preferredReasoningEffort: remote.preferredReasoningEffort ?? local.preferredReasoningEffort,
            preferredApprovalPolicy: remote.preferredApprovalPolicy ?? local.preferredApprovalPolicy,
            preferredSandboxMode: remote.preferredSandboxMode ?? local.preferredSandboxMode,
            privacyMode: remote.privacyMode
        )
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func mergeCapabilities(
        _ local: HostCapabilitySnapshot,
        _ remote: HostCapabilitySnapshot,
        machineID: MachineRecord.ID
    ) -> HostCapabilitySnapshot {
        let latestCapture = max(local.capturedAt, remote.capturedAt)
        return HostCapabilitySnapshot(
            id: local.id,
            machineID: machineID,
            capturedAt: latestCapture,
            remoteLoginEnabled: local.remoteLoginEnabled || remote.remoteLoginEnabled,
            codexInstalled: local.codexInstalled || remote.codexInstalled,
            supportsAppServer: local.supportsAppServer || remote.supportsAppServer,
            supportsWebsocketListen: local.supportsWebsocketListen || remote.supportsWebsocketListen,
            supportsReview: local.supportsReview || remote.supportsReview,
            supportsThreadFork: local.supportsThreadFork || remote.supportsThreadFork,
            supportsApprovals: local.supportsApprovals || remote.supportsApprovals,
            supportsCommandExec: local.supportsCommandExec || remote.supportsCommandExec,
            supportsFSAPI: local.supportsFSAPI || remote.supportsFSAPI,
            supportsImageInputs: local.supportsImageInputs || remote.supportsImageInputs,
            supportsVoiceInput: local.supportsVoiceInput || remote.supportsVoiceInput,
            supportsAttachments: local.supportsAttachments || remote.supportsAttachments,
            gitVersion: remote.gitVersion ?? local.gitVersion,
            codexVersion: remote.codexVersion ?? local.codexVersion,
            companionVersion: remote.companionVersion ?? local.companionVersion,
            companionState: remote.companionState ?? local.companionState,
            codexAppInstalled: local.codexAppInstalled || remote.codexAppInstalled,
            hostOSVersion: remote.hostOSVersion ?? local.hostOSVersion
        )
    }
}

public struct SyncRecordMaterializer: Sendable {
    private let decoder: JSONDecoder

    public init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func materialize(records: [SyncRecord]) -> MachineDirectorySnapshot {
        var machinePayloads: [UUID: SyncMachinePayload] = [:]
        var routePayloads: [UUID: [SyncRoutePayload]] = [:]
        var tailnetProfiles: [UUID: TailnetProfile] = [:]
        var sessions: [UUID: SessionRecord] = [:]
        var hostThreadCatalog: [String: HostThreadCatalogEntry] = [:]
        var preferences = UserPreferencesSnapshot()

        for record in records.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            switch record.kind {
            case .machine:
                if let payload = decode(SyncMachinePayload.self, from: record.encodedPayload) {
                    machinePayloads[payload.id] = payload
                }
            case .route:
                if let payload = decode(SyncRoutePayload.self, from: record.encodedPayload) {
                    routePayloads[payload.machineID, default: []].append(payload)
                }
            case .tailnetProfile:
                if let payload = decode(SyncTailnetProfilePayload.self, from: record.encodedPayload) {
                    tailnetProfiles[payload.id] = TailnetProfile(
                        id: payload.id,
                        kind: payload.kind,
                        displayName: payload.displayName,
                        controlURL: payload.controlURL,
                        accountLabel: payload.accountLabel,
                        tailnetDNSName: payload.tailnetDNSName,
                        isActive: payload.isActive,
                        lastActivatedAt: payload.lastActivatedAt,
                        lastAuthenticatedAt: payload.lastAuthenticatedAt,
                        supportsCustomControlServer: payload.supportsCustomControlServer,
                        requiresExternalApp: payload.requiresExternalApp
                    )
                }
            case .session:
                if let payload = decode(SyncSessionPayload.self, from: record.encodedPayload) {
                    sessions[payload.id] = SessionRecord(
                        id: payload.id,
                        sceneID: payload.sceneID,
                        machineID: payload.machineID,
                        routeID: payload.routeID,
                        transportMode: payload.transportMode,
                        threadID: payload.threadID,
                        reviewThreadID: payload.reviewThreadID,
                        workspaceRoot: payload.workspaceRoot,
                        lastKnownProtocol: payload.lastKnownProtocol,
                        lastKnownRouteKind: payload.lastKnownRouteKind,
                        lastKnownBootstrap: payload.lastKnownBootstrap,
                        lastModel: payload.lastModel,
                        lastReasoningEffort: payload.lastReasoningEffort,
                        lastMode: payload.lastMode,
                        lastTurnID: payload.lastTurnID,
                        lastTurn: payload.lastTurn,
                        lastOpenedAt: payload.lastOpenedAt,
                        resumeStrategy: payload.resumeStrategy,
                        transportState: .disconnected,
                        queuedPrompts: payload.queuedPrompts,
                        lastErrorSummary: payload.lastErrorSummary,
                        parentThreadID: payload.parentThreadID,
                        parentLastTurnID: payload.parentLastTurnID
                    )
                }
            case .hostThreadCatalogEntry:
                if let payload = decode(SyncHostThreadCatalogPayload.self, from: record.encodedPayload) {
                    let key = "\(payload.machineID.uuidString)::\(payload.id)"
                    hostThreadCatalog[key] = HostThreadCatalogEntry(
                        id: payload.id,
                        machineID: payload.machineID,
                        workspaceRoot: payload.workspaceRoot,
                        name: payload.name,
                        preview: payload.preview,
                        modelProvider: payload.modelProvider,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                }
            case .preferences:
                if let payload = decode(SyncPreferencesPayload.self, from: record.encodedPayload) {
                    preferences = UserPreferencesSnapshot(
                        preferredMachineID: payload.preferredMachineID,
                        preferredTailnetProfileID: payload.preferredTailnetProfileID,
                        restoreLastSessionOnLaunch: payload.restoreLastSessionOnLaunch,
                        preferredBootstrap: payload.preferredBootstrap,
                        preferredProtocol: payload.preferredProtocol,
                        preferredReasoningEffort: payload.preferredReasoningEffort,
                        preferredApprovalPolicy: payload.preferredApprovalPolicy,
                        preferredSandboxMode: payload.preferredSandboxMode,
                        privacyMode: payload.privacyMode
                    )
                }
            }
        }

        let machineIDs = Set(machinePayloads.keys).union(routePayloads.keys)
        let machines = machineIDs.compactMap { machineID -> MachineRecord? in
            guard let payload = machinePayloads[machineID] else {
                return nil
            }

            let routes = (routePayloads[machineID] ?? []).map { route in
                RouteRecord(
                    id: route.id,
                    machineID: route.machineID,
                    kind: route.kind,
                    label: route.label,
                    hostname: route.hostname,
                    ipAddress: route.ipAddress,
                    magicDNSName: route.magicDNSName,
                    sshPort: route.sshPort,
                    usernameHint: route.usernameHint,
                    companionEndpoint: route.companionEndpoint,
                    tailnetProfileID: route.tailnetProfileID,
                    requiresExternalApp: route.requiresExternalApp,
                    health: route.health,
                    lastLatencyMs: route.lastLatencyMs,
                    lastCheckedAt: route.lastCheckedAt,
                    lastSuccessAt: route.lastSuccessAt,
                    lastFailureAt: route.lastFailureAt,
                    failureReasonCode: route.failureReasonCode,
                    isRecommended: route.isPreferred && !route.isUserPinned,
                    isUserPinned: route.isUserPinned,
                    publishedByCompanion: route.publishedByCompanion,
                    discoverySource: route.discoverySource,
                    trustState: route.trustState,
                    trustedOpenSSHPublicKey: route.trustedOpenSSHPublicKey
                )
            }

            return MachineRecord(
                id: payload.id,
                displayName: payload.alias,
                hostname: payload.hostname,
                platform: payload.platform,
                stableHostFingerprint: payload.stableHostFingerprint,
                lastKnownUser: payload.lastKnownUser,
                lastConnectedAt: payload.lastConnectedAt,
                preferredRouteID: payload.preferredRouteID,
                lastSuccessfulRouteID: payload.lastSuccessfulRouteID,
                capabilitySnapshotID: payload.capabilitySnapshot.id,
                notes: payload.notes,
                isPinned: payload.isPinned,
                sortRank: payload.sortRank,
                routes: routes,
                capabilities: payload.capabilitySnapshot
            )
        }

        return MachineDirectorySnapshot(
            machines: machines.sorted(by: { ($0.sortRank, $0.displayName) < ($1.sortRank, $1.displayName) }),
            tailnetProfiles: tailnetProfiles.values.sorted(by: { $0.displayName < $1.displayName }),
            recentSessions: sessions.values.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }),
            hostThreadCatalog: hostThreadCatalog.values.sorted(by: { $0.updatedAt > $1.updatedAt }),
            preferences: preferences
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}

private func max(_ lhs: RouteHealthStatus, _ rhs: RouteHealthStatus) -> RouteHealthStatus {
    func score(_ value: RouteHealthStatus) -> Int {
        switch value {
        case .healthy:
            return 3
        case .degraded:
            return 2
        case .unavailable:
            return 1
        }
    }

    return score(lhs) >= score(rhs) ? lhs : rhs
}
