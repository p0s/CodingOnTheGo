import Foundation
import Persistence
import SharedModels

struct AppMachineDirectoryMergeResult {
    let machines: [MachineRecord]
    let selectedMachineID: MachineRecord.ID?
    let didChange: Bool
}

enum AppMachineDirectoryCoordinator {
    static let localhostTestingFixtureNote = "cotg.testing.localhost.fixture"

    static func mergePersistedLocalState(
        liveMachines: [MachineRecord],
        selectedMachineID: MachineRecord.ID?,
        snapshot: MachineDirectorySnapshot,
        isUITesting: Bool,
        hostKeyFingerprint: (String) -> String?
    ) -> AppMachineDirectoryMergeResult {
        var machines = liveMachines
        var resolvedSelection = selectedMachineID
        var didChange = false
        let persistedMachinesByID = Dictionary(uniqueKeysWithValues: snapshot.machines.map { ($0.id, $0) })
        let preferredPersistedMachine = snapshot.preferences.preferredMachineID.flatMap { persistedMachinesByID[$0] }

        if !isUITesting {
            let filteredMachines = machines.filter { machine in
                if persistedMachineMatch(for: machine, persistedMachinesByID: persistedMachinesByID, snapshot: snapshot) != nil {
                    return true
                }
                return !isLocalhostTestingFixture(machine)
            }
            if filteredMachines.count != machines.count {
                machines = filteredMachines
                didChange = true
            }
        }

        if let preferredPersistedMachine,
           let preferredLiveMachine = machines.first(where: { machineIdentityMatches($0, preferredPersistedMachine) }) {
            let selectedMatchesPreferred = machines.first(where: { $0.id == resolvedSelection }).flatMap { current in
                machineIdentityMatches(current, preferredPersistedMachine) ? current.id : nil
            } != nil
            if !selectedMatchesPreferred {
                resolvedSelection = preferredLiveMachine.id
                didChange = true
            }
        } else if let preferredMachineID = snapshot.preferences.preferredMachineID,
                  resolvedSelection == nil || !machines.contains(where: { $0.id == resolvedSelection }) {
            resolvedSelection = preferredMachineID
            didChange = true
        }

        for machineIndex in machines.indices {
            guard let persistedMachine = persistedMachineMatch(
                for: machines[machineIndex],
                persistedMachinesByID: persistedMachinesByID,
                snapshot: snapshot
            ) else {
                continue
            }

            if machines[machineIndex].credentialRef == nil,
               let persistedCredential = persistedMachine.credentialRef {
                machines[machineIndex].credentialRef = persistedCredential
                didChange = true
            }

            if let persistedUser = nonEmptyTrimmed(persistedMachine.lastKnownUser),
               nonEmptyTrimmed(machines[machineIndex].lastKnownUser) == nil {
                machines[machineIndex].lastKnownUser = persistedUser
                didChange = true
            }

            if let persistedFingerprint = nonEmptyTrimmed(persistedMachine.stableHostFingerprint),
               nonEmptyTrimmed(machines[machineIndex].stableHostFingerprint) == nil {
                machines[machineIndex].stableHostFingerprint = persistedFingerprint
                didChange = true
            }

            if machines[machineIndex].preferredRouteID == nil,
               let persistedPreferredRouteID = persistedMachine.preferredRouteID,
               machines[machineIndex].routes.contains(where: { $0.id == persistedPreferredRouteID }) {
                machines[machineIndex].preferredRouteID = persistedPreferredRouteID
                didChange = true
            }

            if machines[machineIndex].lastSuccessfulRouteID == nil,
               let persistedSuccessfulRouteID = persistedMachine.lastSuccessfulRouteID,
               machines[machineIndex].routes.contains(where: { $0.id == persistedSuccessfulRouteID }) {
                machines[machineIndex].lastSuccessfulRouteID = persistedSuccessfulRouteID
                didChange = true
            }

            var routeDidChange = false
            for routeIndex in machines[machineIndex].routes.indices {
                let route = machines[machineIndex].routes[routeIndex]
                guard let persistedRoute = persistedMachine.routes.first(where: {
                    routeIdentityMatches($0, route)
                }) else {
                    continue
                }

                if let persistedUsername = nonEmptyTrimmed(persistedRoute.usernameHint),
                   nonEmptyTrimmed(machines[machineIndex].routes[routeIndex].usernameHint) == nil {
                    machines[machineIndex].routes[routeIndex].usernameHint = persistedUsername
                    routeDidChange = true
                }

                if machines[machineIndex].routes[routeIndex].trustState == .unknown,
                   persistedRoute.trustState != RouteTrustState.unknown {
                    machines[machineIndex].routes[routeIndex].trustState = persistedRoute.trustState
                    routeDidChange = true
                }

                if let persistedTrustedKey = nonEmptyTrimmed(persistedRoute.trustedOpenSSHPublicKey),
                   nonEmptyTrimmed(machines[machineIndex].routes[routeIndex].trustedOpenSSHPublicKey) == nil {
                    machines[machineIndex].routes[routeIndex].trustedOpenSSHPublicKey = persistedTrustedKey
                    routeDidChange = true
                }

                if machines[machineIndex].routes[routeIndex].lastSuccessAt == nil,
                   let persistedLastSuccessAt = persistedRoute.lastSuccessAt {
                    machines[machineIndex].routes[routeIndex].lastSuccessAt = persistedLastSuccessAt
                    routeDidChange = true
                }
            }

            if routeDidChange {
                if let credentialUsername = machines[machineIndex].credentialRef?.username,
                   nonEmptyTrimmed(machines[machineIndex].lastKnownUser) == nil {
                    machines[machineIndex].lastKnownUser = credentialUsername
                }
                let trustedKey = machines[machineIndex].routes
                    .first(where: { $0.trustState == .trusted && $0.trustedOpenSSHPublicKey != nil })?
                    .trustedOpenSSHPublicKey
                machines[machineIndex].stableHostFingerprint = trustedKey.flatMap(hostKeyFingerprint)
                didChange = true
            }
        }

        let normalizedSelection = normalizedSelectedMachineID(
            preferred: resolvedSelection,
            machines: machines
        )
        if resolvedSelection != normalizedSelection {
            resolvedSelection = normalizedSelection
            didChange = true
        }

        return AppMachineDirectoryMergeResult(
            machines: machines,
            selectedMachineID: resolvedSelection,
            didChange: didChange
        )
    }

    static func normalizedSelectedMachineID(
        preferred preferredMachineID: MachineRecord.ID?,
        machines: [MachineRecord],
        currentSelection: MachineRecord.ID? = nil
    ) -> MachineRecord.ID? {
        if let preferredMachineID,
           machines.contains(where: { $0.id == preferredMachineID }) {
            return preferredMachineID
        }

        if let currentSelection,
           machines.contains(where: { $0.id == currentSelection }) {
            return currentSelection
        }

        return machines.first?.id
    }

    static func persistedMachineMatch(
        for machine: MachineRecord,
        persistedMachinesByID: [MachineRecord.ID: MachineRecord],
        snapshot: MachineDirectorySnapshot
    ) -> MachineRecord? {
        if let exact = persistedMachinesByID[machine.id] {
            return exact
        }

        let matches = snapshot.machines.filter { persistedMachine in
            machineIdentityMatches(machine, persistedMachine)
        }

        return matches.count == 1 ? matches[0] : nil
    }

    static func routeIdentityMatches(_ lhs: RouteRecord, _ rhs: RouteRecord) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        if lhs.kind != rhs.kind {
            return false
        }

        if lhs.tailnetProfileID != nil || rhs.tailnetProfileID != nil {
            return lhs.tailnetProfileID == rhs.tailnetProfileID
        }

        return normalizedRouteAddress(lhs) == normalizedRouteAddress(rhs)
    }

    static func machineIdentityMatches(_ lhs: MachineRecord, _ rhs: MachineRecord) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        if let lhsFingerprint = nonEmptyTrimmed(lhs.stableHostFingerprint),
           let rhsFingerprint = nonEmptyTrimmed(rhs.stableHostFingerprint),
           lhsFingerprint == rhsFingerprint {
            return true
        }

        if normalizedTailnetHost(lhs.hostname) == normalizedTailnetHost(rhs.hostname) {
            return true
        }

        return lhs.routes.contains { lhsRoute in
            rhs.routes.contains { rhsRoute in
                routeIdentityMatches(lhsRoute, rhsRoute)
            }
        }
    }

    static func mergedMachinesPreservingLocalRoutes(
        current: [MachineRecord],
        refreshed: [MachineRecord]
    ) -> [MachineRecord] {
        var merged = refreshed.map { refreshedMachine in
            guard let currentMachine = current.first(where: { machineIdentityMatches($0, refreshedMachine) }) else {
                return refreshedMachine
            }
            return mergedMachinePreservingLocalRoutes(current: currentMachine, refreshed: refreshedMachine)
        }

        let currentOnlyMachines = current.filter { currentMachine in
            !refreshed.contains(where: { machineIdentityMatches(currentMachine, $0) })
        }
        merged.append(contentsOf: currentOnlyMachines)
        return merged
    }

    static func mergedMachinePreservingLocalRoutes(
        current: MachineRecord,
        refreshed: MachineRecord
    ) -> MachineRecord {
        var merged = refreshed

        for route in current.routes where !merged.routes.contains(where: { routeIdentityMatches($0, route) }) {
            merged.routes.append(route)
        }

        if let preferredRouteID = current.preferredRouteID,
           merged.routes.contains(where: { $0.id == preferredRouteID }) {
            merged.preferredRouteID = preferredRouteID
        }

        if let lastSuccessfulRouteID = current.lastSuccessfulRouteID,
           merged.routes.contains(where: { $0.id == lastSuccessfulRouteID }) {
            merged.lastSuccessfulRouteID = lastSuccessfulRouteID
        }

        return merged
    }

    static func isLocalhostTestingFixture(_ machine: MachineRecord) -> Bool {
        let hasFixtureNote = machine.notes?
            .trimmingCharacters(in: .whitespacesAndNewlines) == localhostTestingFixtureNote
        let hasTestingCredential = machine.credentialRef.map(isLocalhostTestingCredentialReference) == true

        guard hasFixtureNote || hasTestingCredential else {
            return false
        }

        return machine.displayName == "Local SSH"
            && machine.routes.allSatisfy({ $0.kind == .manualSSH })
    }

    static func isLocalhostTestingCredentialReference(_ credentialRef: CredentialRef) -> Bool {
        credentialRef.kind == .sshKey
            && credentialRef.keychainAccount.hasPrefix("cotg.testing.localhost.")
    }

    private static func normalizedRouteAddress(_ route: RouteRecord) -> String? {
        [
            route.magicDNSName,
            route.hostname,
            route.ipAddress
        ]
        .compactMap(nonEmptyTrimmed)
        .map { $0.lowercased() }
        .first
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedTailnetHost(_ host: String?) -> String? {
        guard let host = host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }
}
