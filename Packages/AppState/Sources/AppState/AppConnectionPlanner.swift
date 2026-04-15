import CodexRPC
import Foundation
import SharedModels
import SSHTransport

enum AppConnectionPlanner {
    @MainActor
    static func connectionCandidate(
        selectedMachine: MachineRecord?,
        cwd: String,
        sshCandidate: (MachineRecord, String) async throws -> ConnectionCandidate?,
        directEndpointCandidate: (MachineRecord, String) -> ConnectionCandidate?
    ) async throws -> ConnectionCandidate? {
        guard let machine = selectedMachine else {
            return nil
        }

        if let directEndpointCandidate = directEndpointCandidate(machine, cwd) {
            return directEndpointCandidate
        }

        return try await sshCandidate(machine, cwd)
    }

    static func makeSafeLaneCandidate(
        machineID: MachineRecord.ID,
        endpoint: SSHBootstrapEndpoint,
        route: RouteRecord,
        username: String,
        authentication: SSHAuthenticationMaterial,
        hostValidation: SSHHostValidationPolicy,
        proxy: SSHProxyConfiguration?,
        cwd: String,
        codexHome: String?
    ) -> ConnectionCandidate {
        .safeLane(
            machineID: machineID,
            configuration: CodexSSHConfiguration(
                host: endpoint.host,
                port: endpoint.port,
                proxy: proxy,
                username: username,
                authentication: authentication,
                hostValidation: hostValidation,
                cwd: cwd,
                codexHome: codexHome,
                clientInfo: clientInfo()
            ),
            route: route,
            bootstrap: .standardSSH
        )
    }

    static func makeDirectEndpointCandidate(
        machineID: MachineRecord.ID,
        endpoint: URL,
        route: RouteRecord,
        cwd: String,
        bootstrap: BootstrapStrategy = .codexAppServerWebSocket
    ) -> ConnectionCandidate {
        .directEndpoint(
            machineID: machineID,
            configuration: CodexLiveConfiguration(
                url: endpoint,
                cwd: cwd,
                clientInfo: clientInfo()
            ),
            route: route,
            bootstrap: bootstrap
        )
    }

    static func clientInfo() -> CodexRPCClientInfo {
        CodexRPCClientInfo(
            name: "Coding On The Go",
            version: "0.1"
        )
    }
}
