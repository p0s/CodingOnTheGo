import Foundation
import SharedModels

public struct BonjourLANScanner: LANRouteDiscovering {
    private let browser: any BonjourServiceBrowsing
    private let probe: any TCPRouteProbing

    public init(
        browser: any BonjourServiceBrowsing = NetServiceBonjourBrowser(),
        probe: any TCPRouteProbing = NetworkTCPRouteProbe()
    ) {
        self.browser = browser
        self.probe = probe
    }

    public func scan(knownMachines: [MachineRecord], timeout: TimeInterval) async -> [DiscoveryRouteSample] {
        let duration = Duration.seconds(max(timeout, 0.5))
        let configuration = BonjourScanConfiguration(
            domain: "local.",
            browseTimeout: duration,
            resolveTimeout: max(0.75, timeout / 2),
            probeTimeout: duration
        )

        async let resolvedServices = browser.scan(configuration: configuration)
        async let probeSamples = KnownHostProbeService(probe: probe).probe(
            knownMachines: knownMachines,
            timeout: duration
        )

        let services = await resolvedServices
        var serviceSamples: [DiscoveryRouteSample] = []
        serviceSamples.reserveCapacity(services.count)

        for service in services {
            let isReachable = await probe.probe(
                host: service.hostName,
                port: service.port,
                timeout: duration
            )

            serviceSamples.append(
                DiscoveryRouteSample(
                    machineAlias: service.name,
                    hostname: service.hostName,
                    ipAddress: service.ipAddress,
                    port: service.port,
                    kind: .localLAN,
                    source: .bonjourSSH,
                    health: isReachable ? .healthy : .unavailable,
                    capabilities: isReachable ? HostCapabilitySnapshot(
                        remoteLoginEnabled: true,
                        codexInstalled: false,
                        supportsWebsocketListen: false,
                        codexAppInstalled: false
                    ) : nil
                )
            )
        }

        return serviceSamples + (await probeSamples)
    }
}

private struct KnownHostProbeService: Sendable {
    let probe: any TCPRouteProbing

    init(probe: any TCPRouteProbing = NetworkTCPRouteProbe()) {
        self.probe = probe
    }

    func probe(knownMachines: [MachineRecord], timeout: Duration) async -> [DiscoveryRouteSample] {
        let candidates = uniqueCandidates(from: knownMachines)
        var samples: [DiscoveryRouteSample] = []
        samples.reserveCapacity(candidates.count)

        for candidate in candidates {
            let isReachable = await probe.probe(
                host: candidate.hostname,
                port: Int(candidate.port),
                timeout: timeout
            )
            samples.append(
                DiscoveryRouteSample(
                    machineID: candidate.machineID,
                    machineAlias: candidate.machineAlias,
                    hostname: candidate.hostname,
                    ipAddress: candidate.ipAddress,
                    port: Int(candidate.port),
                    kind: candidate.kind,
                    source: candidate.source,
                    health: isReachable ? .healthy : .unavailable,
                    capabilities: isReachable ? HostCapabilitySnapshot(
                        machineID: candidate.machineID,
                        remoteLoginEnabled: true,
                        codexInstalled: false,
                        supportsWebsocketListen: false,
                        codexAppInstalled: false
                    ) : nil,
                    lastSeenAt: .now
                )
            )
        }

        return samples
    }

    private func uniqueCandidates(from machines: [MachineRecord]) -> [ProbeCandidate] {
        var seen: Set<String> = []
        var candidates: [ProbeCandidate] = []

        for machine in machines {
            for route in machine.routes where route.kind == .localLAN || route.kind == .manualSSH {
                guard let hostname = route.hostname ?? route.ipAddress, !hostname.isEmpty else {
                    continue
                }

                let key = "\(route.kind.rawValue)|\(hostname.lowercased())|\(route.sshPort)"
                guard seen.insert(key).inserted else {
                    continue
                }

                candidates.append(
                    ProbeCandidate(
                        machineID: machine.id,
                        machineAlias: machine.alias,
                        hostname: hostname,
                        ipAddress: route.ipAddress,
                        port: route.sshPort,
                        kind: route.kind,
                        source: route.kind == .localLAN ? .subnetReachability : .cachedProbe
                    )
                )
            }
        }

        return candidates
    }
}

private struct ProbeCandidate: Sendable {
    let machineID: MachineRecord.ID
    let machineAlias: String
    let hostname: String
    let ipAddress: String?
    let port: UInt16
    let kind: MachineRouteKind
    let source: DiscoverySource
}
