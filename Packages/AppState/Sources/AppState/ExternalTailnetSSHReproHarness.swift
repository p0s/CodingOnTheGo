import CodexRPC
import CryptoKit
import Foundation
#if canImport(Network)
import Network
#endif
import SSHTransport

public struct ExternalTailnetSSHReproConfiguration: Sendable {
    public var displayName: String
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

public struct ExternalTailnetSSHReproEvent: Codable, Sendable {
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

public struct ExternalTailnetSSHReproReport: Codable, Sendable {
    public var status: String
    public var startedAt: String
    public var completedAt: String?
    public var displayName: String
    public var tailnetDNSName: String
    public var reportPath: String
    public var sshUsername: String
    public var sshHostKeyFingerprint: String
    public var seedByteCount: Int
    public var transportMode: String
    public var finalError: String?
    public var tcpProbeSucceeded: Bool
    public var tcpProbeError: String?
    public var sshBannerProbeSucceeded: Bool
    public var sshBannerProbeDetail: String?
    public var sshConnected: Bool
    public var modelCount: Int?
    public var threadID: String?
    public var smokeTestSucceeded: Bool
    public var assistantReply: String?
    public var events: [ExternalTailnetSSHReproEvent]

    public init(
        status: String,
        startedAt: String,
        completedAt: String? = nil,
        displayName: String,
        tailnetDNSName: String,
        reportPath: String,
        sshUsername: String,
        sshHostKeyFingerprint: String,
        seedByteCount: Int,
        transportMode: String,
        finalError: String? = nil,
        tcpProbeSucceeded: Bool = false,
        tcpProbeError: String? = nil,
        sshBannerProbeSucceeded: Bool = false,
        sshBannerProbeDetail: String? = nil,
        sshConnected: Bool = false,
        modelCount: Int? = nil,
        threadID: String? = nil,
        smokeTestSucceeded: Bool = false,
        assistantReply: String? = nil,
        events: [ExternalTailnetSSHReproEvent] = []
    ) {
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.displayName = displayName
        self.tailnetDNSName = tailnetDNSName
        self.reportPath = reportPath
        self.sshUsername = sshUsername
        self.sshHostKeyFingerprint = sshHostKeyFingerprint
        self.seedByteCount = seedByteCount
        self.transportMode = transportMode
        self.finalError = finalError
        self.tcpProbeSucceeded = tcpProbeSucceeded
        self.tcpProbeError = tcpProbeError
        self.sshBannerProbeSucceeded = sshBannerProbeSucceeded
        self.sshBannerProbeDetail = sshBannerProbeDetail
        self.sshConnected = sshConnected
        self.modelCount = modelCount
        self.threadID = threadID
        self.smokeTestSucceeded = smokeTestSucceeded
        self.assistantReply = assistantReply
        self.events = events
    }
}

public actor ExternalTailnetSSHReproHarness {
    private let configuration: ExternalTailnetSSHReproConfiguration
    private let startDate = Date()
    private let isoFormatter = ISO8601DateFormatter()
    private var report: ExternalTailnetSSHReproReport
    private var observedTurnCompletion: String?
    private var observedAssistantReply: String?
    private var observedTransportError: String?

    public init(configuration: ExternalTailnetSSHReproConfiguration) {
        self.configuration = configuration
        self.report = ExternalTailnetSSHReproReport(
            status: "initialized",
            startedAt: isoFormatter.string(from: startDate),
            displayName: configuration.displayName,
            tailnetDNSName: configuration.tailnetDNSName,
            reportPath: configuration.reportPath,
            sshUsername: configuration.sshUsername,
            sshHostKeyFingerprint: Self.hostKeyFingerprint(configuration.sshHostKey) ?? "unknown",
            seedByteCount: configuration.sshRawKeySeed.count,
            transportMode: {
                let raw = ProcessInfo.processInfo.environment["COTG_SSH_BOOTSTRAP_MODE"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return raw?.isEmpty == false ? raw! : "auto"
            }()
        )
    }

    public func recordLifecycle(_ detail: String) async {
        appendEvent(category: "lifecycle", detail: detail)
    }

    public func snapshot() async -> ExternalTailnetSSHReproReport {
        report
    }

    public func run() async -> ExternalTailnetSSHReproReport {
        appendEvent(category: "run", detail: "External tailnet SSH repro started.")

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: configuration.reportPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return finishFailure("Failed to prepare repro directory: \(error.localizedDescription)")
        }

        let client = CodexSSHAppServerClient()
        do {
            let tcpProbe = await probeTCPReachability()
            report.tcpProbeSucceeded = tcpProbe.succeeded
            report.tcpProbeError = tcpProbe.error
            appendEvent(
                category: "tcpProbe",
                detail: tcpProbe.succeeded
                    ? "TCP connect to \(configuration.tailnetDNSName):22 succeeded."
                    : "TCP connect to \(configuration.tailnetDNSName):22 failed: \(tcpProbe.error ?? "unknown")"
            )
            guard tcpProbe.succeeded else {
                return finishFailure("TCP connect to \(configuration.tailnetDNSName):22 failed: \(tcpProbe.error ?? "unknown")")
            }

            let bannerProbe = await probeSSHBanner()
            report.sshBannerProbeSucceeded = bannerProbe.succeeded
            report.sshBannerProbeDetail = bannerProbe.detail
            appendEvent(
                category: "bannerProbe",
                detail: bannerProbe.succeeded
                    ? "SSH banner probe succeeded: \(bannerProbe.detail ?? "none")."
                    : "SSH banner probe failed: \(bannerProbe.detail ?? "unknown")"
            )

            let sshConfiguration = CodexSSHConfiguration(
                host: configuration.tailnetDNSName,
                port: 22,
                username: configuration.sshUsername,
                authentication: .ed25519Seed(configuration.sshRawKeySeed),
                hostValidation: .exactOpenSSHPublicKey(configuration.sshHostKey),
                cwd: configuration.cwd,
                codexHome: configuration.codexHome,
                clientInfo: CodexRPCClientInfo(
                    name: "Coding On The Go External SSH Repro",
                    version: "0.1"
                )
            )

            appendEvent(
                category: "ssh",
                detail: "Connecting to \(sshConfiguration.host):\(sshConfiguration.port) as \(sshConfiguration.username) seedBytes=\(configuration.sshRawKeySeed.count)."
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

    private func finishFailure(_ detail: String) -> ExternalTailnetSSHReproReport {
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
            ExternalTailnetSSHReproEvent(
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

    private static func hostKeyFingerprint(_ openSSHPublicKey: String) -> String? {
        let components = openSSHPublicKey.split(whereSeparator: \.isWhitespace)
        let payload = components.count >= 2 ? String(components[1]) : openSSHPublicKey
        let fingerprintData = Data(base64Encoded: payload) ?? Data(openSSHPublicKey.utf8)
        let digest = Data(SHA256.hash(data: fingerprintData))
        let encoded = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    private func probeTCPReachability() async -> (succeeded: Bool, error: String?) {
        #if canImport(Network)
        let host = NWEndpoint.Host(configuration.tailnetDNSName)
        let port = NWEndpoint.Port(rawValue: 22) ?? .ssh
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let queue = DispatchQueue(label: "ExternalTailnetSSHReproHarness.tcpProbe")

        return await withCheckedContinuation { continuation in
            let stateBox = LockedProbeContinuation(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    stateBox.resumeOnce(with: (true, nil))
                case let .failed(error):
                    connection.cancel()
                    stateBox.resumeOnce(with: (false, error.localizedDescription))
                case let .waiting(error):
                    connection.cancel()
                    stateBox.resumeOnce(with: (false, error.localizedDescription))
                case .cancelled:
                    stateBox.resumeOnce(with: (false, "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 8) {
                connection.cancel()
                stateBox.resumeOnce(with: (false, "timed out"))
            }
        }
        #else
        return (false, "Network framework unavailable")
        #endif
    }

    private func probeSSHBanner() async -> (succeeded: Bool, detail: String?) {
        #if canImport(Network)
        let host = NWEndpoint.Host(configuration.tailnetDNSName)
        let port = NWEndpoint.Port(rawValue: 22) ?? .ssh
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let queue = DispatchQueue(label: "ExternalTailnetSSHReproHarness.bannerProbe")

        return await withCheckedContinuation { continuation in
            let stateBox = LockedBannerProbeContinuation(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let banner = "SSH-2.0-COTGBannerProbe\r\n"
                    connection.send(content: Data(banner.utf8), completion: .contentProcessed { sendError in
                        if let sendError {
                            connection.cancel()
                            stateBox.resumeOnce(with: (false, "send failed: \(sendError.localizedDescription)"))
                            return
                        }

                        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, receiveError in
                            connection.cancel()
                            if let receiveError {
                                stateBox.resumeOnce(with: (false, receiveError.localizedDescription))
                                return
                            }
                            guard let data, !data.isEmpty else {
                                stateBox.resumeOnce(with: (false, "no banner data"))
                                return
                            }
                            let bannerText = String(decoding: data, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            stateBox.resumeOnce(with: (true, bannerText.isEmpty ? "<empty>" : bannerText))
                        }
                    })
                case let .failed(error):
                    connection.cancel()
                    stateBox.resumeOnce(with: (false, error.localizedDescription))
                case let .waiting(error):
                    connection.cancel()
                    stateBox.resumeOnce(with: (false, error.localizedDescription))
                case .cancelled:
                    stateBox.resumeOnce(with: (false, "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 8) {
                connection.cancel()
                stateBox.resumeOnce(with: (false, "timed out"))
            }
        }
        #else
        return (false, "Network framework unavailable")
        #endif
    }
}

#if canImport(Network)
private final class LockedProbeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(succeeded: Bool, error: String?), Never>?

    init(continuation: CheckedContinuation<(succeeded: Bool, error: String?), Never>) {
        self.continuation = continuation
    }

    func resumeOnce(with result: (succeeded: Bool, error: String?)) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private final class LockedBannerProbeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(succeeded: Bool, detail: String?), Never>?

    init(continuation: CheckedContinuation<(succeeded: Bool, detail: String?), Never>) {
        self.continuation = continuation
    }

    func resumeOnce(with result: (succeeded: Bool, detail: String?)) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
#endif
