import CodexRPC
import Foundation
import SharedModels
import SSHTransport
import TailnetEmbedded

public struct EmbeddedTailnetSSHReproConfiguration: Sendable {
    public var displayName: String
    public var controlURL: URL
    public var tailnetDNSName: String
    public var sshUsername: String
    public var sshHostKey: String
    public var sshRawKeySeed: Data
    public var cwd: String
    public var codexHome: String?
    public var reportPath: String
    public var timeoutSeconds: TimeInterval
    public var pollIntervalMilliseconds: UInt64

    public init(
        displayName: String,
        controlURL: URL,
        tailnetDNSName: String,
        sshUsername: String,
        sshHostKey: String,
        sshRawKeySeed: Data,
        cwd: String,
        codexHome: String?,
        reportPath: String,
        timeoutSeconds: TimeInterval = 120,
        pollIntervalMilliseconds: UInt64 = 500
    ) {
        self.displayName = displayName
        self.controlURL = controlURL
        self.tailnetDNSName = tailnetDNSName
        self.sshUsername = sshUsername
        self.sshHostKey = sshHostKey
        self.sshRawKeySeed = sshRawKeySeed
        self.cwd = cwd
        self.codexHome = codexHome
        self.reportPath = reportPath
        self.timeoutSeconds = timeoutSeconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }
}

public struct EmbeddedTailnetSSHReproEvent: Codable, Sendable {
    public var timestamp: String
    public var elapsedMilliseconds: Int
    public var category: String
    public var detail: String

    public init(
        timestamp: String,
        elapsedMilliseconds: Int,
        category: String,
        detail: String
    ) {
        self.timestamp = timestamp
        self.elapsedMilliseconds = elapsedMilliseconds
        self.category = category
        self.detail = detail
    }
}

public struct EmbeddedTailnetSSHReproReport: Codable, Sendable {
    public var status: String
    public var startedAt: String
    public var completedAt: String?
    public var displayName: String
    public var controlURL: String
    public var tailnetDNSName: String
    public var reportPath: String
    public var finalError: String?
    public var tailnetAuthState: String?
    public var tailnetHealthState: String?
    public var tailnetReachable: Bool
    public var dialPlanHost: String?
    public var dialPlanPort: UInt16?
    public var dialPlanUsername: String?
    public var sshConnected: Bool
    public var modelCount: Int?
    public var threadID: String?
    public var smokeTestSucceeded: Bool
    public var assistantReply: String?
    public var events: [EmbeddedTailnetSSHReproEvent]

    public init(
        status: String,
        startedAt: String,
        completedAt: String? = nil,
        displayName: String,
        controlURL: String,
        tailnetDNSName: String,
        reportPath: String,
        finalError: String? = nil,
        tailnetAuthState: String? = nil,
        tailnetHealthState: String? = nil,
        tailnetReachable: Bool = false,
        dialPlanHost: String? = nil,
        dialPlanPort: UInt16? = nil,
        dialPlanUsername: String? = nil,
        sshConnected: Bool = false,
        modelCount: Int? = nil,
        threadID: String? = nil,
        smokeTestSucceeded: Bool = false,
        assistantReply: String? = nil,
        events: [EmbeddedTailnetSSHReproEvent] = []
    ) {
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.displayName = displayName
        self.controlURL = controlURL
        self.tailnetDNSName = tailnetDNSName
        self.reportPath = reportPath
        self.finalError = finalError
        self.tailnetAuthState = tailnetAuthState
        self.tailnetHealthState = tailnetHealthState
        self.tailnetReachable = tailnetReachable
        self.dialPlanHost = dialPlanHost
        self.dialPlanPort = dialPlanPort
        self.dialPlanUsername = dialPlanUsername
        self.sshConnected = sshConnected
        self.modelCount = modelCount
        self.threadID = threadID
        self.smokeTestSucceeded = smokeTestSucceeded
        self.assistantReply = assistantReply
        self.events = events
    }
}

public actor EmbeddedTailnetSSHReproHarness {
    private let configuration: EmbeddedTailnetSSHReproConfiguration
    private let startDate = Date()
    private let isoFormatter = ISO8601DateFormatter()
    private var report: EmbeddedTailnetSSHReproReport
    private var observedTurnCompletion: String?
    private var observedAssistantReply: String?
    private var observedTransportError: String?

    public init(configuration: EmbeddedTailnetSSHReproConfiguration) {
        self.configuration = configuration
        self.report = EmbeddedTailnetSSHReproReport(
            status: "initialized",
            startedAt: isoFormatter.string(from: startDate),
            displayName: configuration.displayName,
            controlURL: configuration.controlURL.absoluteString,
            tailnetDNSName: configuration.tailnetDNSName,
            reportPath: configuration.reportPath
        )
    }

    public func recordLifecycle(_ detail: String) async {
        appendEvent(category: "lifecycle", detail: detail)
    }

    public func snapshot() async -> EmbeddedTailnetSSHReproReport {
        report
    }

    public func run() async -> EmbeddedTailnetSSHReproReport {
        appendEvent(category: "run", detail: "Embedded tailnet plus SSH repro started.")

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: configuration.reportPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return finishFailure("Failed to prepare repro directory: \(error.localizedDescription)")
        }

        let manager = EmbeddedTailnetNodeManager()
        let profile = TailnetProfile(
            kind: .embedded,
            displayName: configuration.displayName,
            controlURL: configuration.controlURL,
            accountLabel: "Embedded SSH Repro",
            tailnetDNSName: configuration.tailnetDNSName,
            isActive: true,
            lastActivatedAt: .now,
            lastAuthenticatedAt: .now,
            supportsCustomControlServer: true,
            requiresExternalApp: false
        )

        _ = await manager.bootstrap(profiles: [profile], activeProfileID: profile.id)
        appendEvent(category: "tailnet", detail: "Embedded profile bootstrapped.")

        let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
        var dialPlan: EmbeddedTailnetDialPlan?
        while Date() < deadline {
            let snapshot = await manager.snapshot()
            record(snapshot: snapshot)
            if let plan = snapshot.dialPlan,
               snapshot.health.isReachable,
               plan.supportsNativeSSHTransport,
               let host = plan.socksProxyHost,
               !host.isEmpty,
               let port = plan.socksProxyPort {
                dialPlan = plan
                appendEvent(category: "tailnet", detail: "Published dial plan at \(host):\(port).")
                break
            }
            try? await Task.sleep(for: .milliseconds(configuration.pollIntervalMilliseconds))
        }

        guard let dialPlan,
              let proxyHost = dialPlan.socksProxyHost,
              let proxyPort = dialPlan.socksProxyPort else {
            return finishFailure("Embedded tailnet did not publish a SOCKS endpoint before timeout.")
        }

        let client = CodexSSHAppServerClient()
        do {
            let sshConfiguration = CodexSSHConfiguration(
                host: configuration.tailnetDNSName,
                port: 22,
                proxy: SSHProxyConfiguration(
                    host: proxyHost,
                    port: proxyPort,
                    username: dialPlan.socksProxyUsername,
                    password: dialPlan.socksProxyPassword
                ),
                username: configuration.sshUsername,
                authentication: .ed25519Seed(configuration.sshRawKeySeed),
                hostValidation: .exactOpenSSHPublicKey(configuration.sshHostKey),
                cwd: configuration.cwd,
                codexHome: configuration.codexHome,
                clientInfo: CodexRPCClientInfo(
                    name: "Coding On The Go Embedded SSH Repro",
                    version: "0.1"
                )
            )

            appendEvent(
                category: "ssh",
                detail: "Connecting to \(sshConfiguration.host):\(sshConfiguration.port) via \(proxyHost):\(proxyPort)."
            )
            try await client.connect(
                configuration: sshConfiguration,
                onEvent: { [weak self] event in
                    Task {
                        await self?.record(event: event)
                    }
                }
            )
            report.sshConnected = true
            appendEvent(category: "ssh", detail: "SSH transport connected; requesting model list.")

            let models = try await client.listModels()
            report.modelCount = models.count
            appendEvent(category: "ssh", detail: "model/list returned \(models.count) models.")

            let thread = try await client.startThread(
                cwd: configuration.cwd,
                model: models.first(where: \.isDefault)?.model ?? models.first?.model
            )
            report.threadID = thread.id
            appendEvent(category: "ssh", detail: "thread/start returned \(thread.id).")

            let turn = try await client.startTurn(
                threadID: thread.id,
                text: "Reply with COTG_APP_OK only.",
                model: models.first(where: \.isDefault)?.model ?? models.first?.model,
                effort: .medium
            )
            appendEvent(category: "ssh", detail: "turn/start returned \(turn.id).")

            let turnDeadline = Date().addingTimeInterval(configuration.timeoutSeconds)
            while Date() < turnDeadline {
                if let transportError = observedTransportError {
                    return finishFailure(transportError)
                }
                if observedTurnCompletion == turn.id {
                    report.assistantReply = observedAssistantReply
                    report.smokeTestSucceeded = observedAssistantReply?.contains("COTG_APP_OK") == true
                    appendEvent(
                        category: "ssh",
                        detail: "turn completed with assistant reply \(observedAssistantReply ?? "<nil>")."
                    )
                    break
                }
                try await Task.sleep(for: .milliseconds(configuration.pollIntervalMilliseconds))
            }

            if observedTurnCompletion != turn.id {
                return finishFailure("Timed out waiting for the smoke-test turn to complete.")
            }
            if report.smokeTestSucceeded != true {
                return finishFailure("Smoke-test turn completed without COTG_APP_OK.")
            }

            await client.disconnect()
            report.status = "succeeded"
            report.completedAt = isoFormatter.string(from: Date())
            persistReport()
            return report
        } catch {
            await client.disconnect()
            return finishFailure(error.localizedDescription)
        }
    }

    private func record(snapshot: EmbeddedTailnetRuntimeSnapshot) {
        report.tailnetAuthState = snapshot.status.authState.rawValue
        report.tailnetHealthState = snapshot.health.state.rawValue
        report.tailnetReachable = snapshot.status.isReachable
        report.dialPlanHost = snapshot.dialPlan?.socksProxyHost
        report.dialPlanPort = snapshot.dialPlan?.socksProxyPort
        report.dialPlanUsername = snapshot.dialPlan?.socksProxyUsername
        appendEvent(
            category: "tailnetStatus",
            detail: [
                "auth=\(snapshot.status.authState.rawValue)",
                "health=\(snapshot.health.state.rawValue)",
                "reachable=\(snapshot.status.isReachable)",
                "proxy=\(snapshot.dialPlan?.socksProxyHost ?? "<nil>"):\(snapshot.dialPlan?.socksProxyPort.map(String.init) ?? "<nil>")"
            ].joined(separator: " ")
        )
    }

    private func record(event: CodexLiveEvent) {
        appendEvent(category: "sshEvent", detail: String(describing: event))
        switch event {
        case let .agentMessageCompleted(message):
            observedAssistantReply = message
        case let .turnCompleted(turnID):
            observedTurnCompletion = turnID
        case let .error(message):
            observedTransportError = message
        default:
            break
        }
    }

    private func finishFailure(_ detail: String) -> EmbeddedTailnetSSHReproReport {
        report.status = "failed"
        report.finalError = detail
        report.completedAt = isoFormatter.string(from: Date())
        appendEvent(category: "error", detail: detail)
        persistReport()
        return report
    }

    private func appendEvent(category: String, detail: String) {
        let elapsed = Int(Date().timeIntervalSince(startDate) * 1000)
        report.events.append(
            EmbeddedTailnetSSHReproEvent(
                timestamp: isoFormatter.string(from: Date()),
                elapsedMilliseconds: elapsed,
                category: category,
                detail: detail
            )
        )
        persistReport()
    }

    private func persistReport() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: URL(fileURLWithPath: configuration.reportPath), options: .atomic)
        } catch {
        }
    }
}
