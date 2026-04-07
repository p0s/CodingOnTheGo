import Foundation
#if canImport(TailscaleKit)
import TailscaleKit
#endif

public struct EmbeddedTailnetReproConfiguration: Sendable {
    public var hostName: String
    public var controlURL: String
    public var authKey: String
    public var storagePath: String
    public var reportPath: String
    public var tailscaleLogPath: String
    public var runtimeLabel: String
    public var timeoutSeconds: TimeInterval
    public var pollIntervalMilliseconds: UInt64

    public init(
        hostName: String,
        controlURL: String,
        authKey: String,
        storagePath: String,
        reportPath: String,
        tailscaleLogPath: String,
        runtimeLabel: String,
        timeoutSeconds: TimeInterval = 90,
        pollIntervalMilliseconds: UInt64 = 500
    ) {
        self.hostName = hostName
        self.controlURL = controlURL
        self.authKey = authKey
        self.storagePath = storagePath
        self.reportPath = reportPath
        self.tailscaleLogPath = tailscaleLogPath
        self.runtimeLabel = runtimeLabel
        self.timeoutSeconds = timeoutSeconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }
}

public struct EmbeddedTailnetReproEvent: Codable, Sendable {
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

public struct EmbeddedTailnetReproReport: Codable, Sendable {
    public var status: String
    public var runtimeLabel: String
    public var startedAt: String
    public var completedAt: String?
    public var hostName: String
    public var controlURL: String
    public var storagePath: String
    public var reportPath: String
    public var tailscaleLogPath: String
    public var finalError: String?
    public var finalBackendState: String?
    public var finalAuthURL: String?
    public var finalTailnetName: String?
    public var finalSelfDNSName: String?
    public var finalSelfOnline: Bool?
    public var finalTailscaleIPs: [String]
    public var loopbackPublished: Bool
    public var loopbackAddress: String?
    public var loopbackPublishedAt: String?
    public var events: [EmbeddedTailnetReproEvent]

    public init(
        status: String,
        runtimeLabel: String,
        startedAt: String,
        completedAt: String? = nil,
        hostName: String,
        controlURL: String,
        storagePath: String,
        reportPath: String,
        tailscaleLogPath: String,
        finalError: String? = nil,
        finalBackendState: String? = nil,
        finalAuthURL: String? = nil,
        finalTailnetName: String? = nil,
        finalSelfDNSName: String? = nil,
        finalSelfOnline: Bool? = nil,
        finalTailscaleIPs: [String] = [],
        loopbackPublished: Bool = false,
        loopbackAddress: String? = nil,
        loopbackPublishedAt: String? = nil,
        events: [EmbeddedTailnetReproEvent] = []
    ) {
        self.status = status
        self.runtimeLabel = runtimeLabel
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.hostName = hostName
        self.controlURL = controlURL
        self.storagePath = storagePath
        self.reportPath = reportPath
        self.tailscaleLogPath = tailscaleLogPath
        self.finalError = finalError
        self.finalBackendState = finalBackendState
        self.finalAuthURL = finalAuthURL
        self.finalTailnetName = finalTailnetName
        self.finalSelfDNSName = finalSelfDNSName
        self.finalSelfOnline = finalSelfOnline
        self.finalTailscaleIPs = finalTailscaleIPs
        self.loopbackPublished = loopbackPublished
        self.loopbackAddress = loopbackAddress
        self.loopbackPublishedAt = loopbackPublishedAt
        self.events = events
    }
}

public actor EmbeddedTailnetReproHarness {
    private let configuration: EmbeddedTailnetReproConfiguration
    private let startDate = Date()
    private let isoFormatter = ISO8601DateFormatter()
    private var report: EmbeddedTailnetReproReport

    public init(configuration: EmbeddedTailnetReproConfiguration) {
        self.configuration = configuration
        self.report = EmbeddedTailnetReproReport(
            status: "initialized",
            runtimeLabel: configuration.runtimeLabel,
            startedAt: isoFormatter.string(from: startDate),
            hostName: configuration.hostName,
            controlURL: configuration.controlURL,
            storagePath: configuration.storagePath,
            reportPath: configuration.reportPath,
            tailscaleLogPath: configuration.tailscaleLogPath
        )
    }

    public func recordLifecycle(_ detail: String) async {
        appendEvent(category: "lifecycle", detail: detail)
    }

    public func snapshot() async -> EmbeddedTailnetReproReport {
        report
    }

    public func run() async -> EmbeddedTailnetReproReport {
        appendEvent(category: "run", detail: "Minimal embedded-tailnet repro started.")

        #if canImport(TailscaleKit)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: configuration.storagePath),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: configuration.reportPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return finishFailure("Failed to prepare repro directories: \(error.localizedDescription)")
        }

        let logSink = EmbeddedTailnetReproLogSink(logPath: configuration.tailscaleLogPath)
        let consumer = EmbeddedTailnetReproMessageConsumer()
        var processor: MessageProcessor?
        var node: TailscaleNode?

        do {
            let nodeConfiguration = Configuration(
                hostName: configuration.hostName,
                path: configuration.storagePath,
                authKey: configuration.authKey,
                controlURL: configuration.controlURL,
                ephemeral: false
            )
            appendEvent(category: "step", detail: "Creating Tailscale node.")
            let createdNode = try TailscaleNode(config: nodeConfiguration, logger: logSink)
            node = createdNode
            let client = LocalAPIClient(localNode: createdNode, logger: logSink)

            appendEvent(category: "step", detail: "Starting IPN bus watch.")
            processor = try await client.watchIPNBus(
                mask: [.initialState, .engineUpdates, .prefs, .netmap],
                consumer: consumer
            )

            appendEvent(category: "step", detail: "Calling node.up().")
            try await createdNode.up()
            appendEvent(category: "step", detail: "node.up() returned successfully.")

            let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
            while Date() < deadline {
                await drainConsumerEvents(from: consumer)

                do {
                    let status = try await client.backendStatus()
                    recordStatus(status)
                } catch {
                    return finishFailure(mappedErrorSummary(error))
                }

                if let publishedLoopback = try? await createdNode.loopback() {
                    report.loopbackPublished = true
                    report.loopbackAddress = publishedLoopback.address
                    report.loopbackPublishedAt = isoFormatter.string(from: Date())
                    appendEvent(
                        category: "loopback",
                        detail: "Published loopback endpoint at \(publishedLoopback.address)."
                    )
                    report.status = "succeeded"
                    report.completedAt = isoFormatter.string(from: Date())
                    persistReport()
                    processor?.cancel()
                    try? await createdNode.close()
                    return report
                }

                try await Task.sleep(for: .milliseconds(configuration.pollIntervalMilliseconds))
            }

            let timeoutMessage = "Timed out waiting \(configuration.timeoutSeconds)s for a loopback SOCKS endpoint."
            report.finalError = timeoutMessage
            appendEvent(category: "error", detail: timeoutMessage)
            report.status = "timedOut"
            report.completedAt = isoFormatter.string(from: Date())
            persistReport()
            processor?.cancel()
            try? await createdNode.close()
            return report
        } catch {
            if let node {
                try? await node.close()
            }
            processor?.cancel()
            return finishFailure(mappedErrorSummary(error))
        }
        #else
        return finishFailure("TailscaleKit is unavailable in this build.")
        #endif
    }

    private func finishFailure(_ detail: String) -> EmbeddedTailnetReproReport {
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
            EmbeddedTailnetReproEvent(
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
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: URL(fileURLWithPath: configuration.reportPath), options: .atomic)
        } catch {
            // Ignore repro-report persistence failures to avoid hiding the runtime result.
        }
    }

    #if canImport(TailscaleKit)
    private func drainConsumerEvents(from consumer: EmbeddedTailnetReproMessageConsumer) async {
        let events = await consumer.drainEvents()
        for event in events {
            appendEvent(category: event.category, detail: event.detail)
        }
    }

    private func recordStatus(_ status: IpnState.Status) {
        report.finalBackendState = status.BackendState
        report.finalAuthURL = status.AuthURL.isEmpty ? nil : status.AuthURL
        report.finalTailnetName = status.CurrentTailnet?.Name
        report.finalSelfDNSName = status.SelfStatus?.DNSName
        report.finalSelfOnline = status.SelfStatus?.Online
        report.finalTailscaleIPs = status.TailscaleIPs ?? []

        let summary = [
            "BackendState=\(status.BackendState)",
            "AuthURL=\(status.AuthURL.isEmpty ? "<empty>" : status.AuthURL)",
            "Tailnet=\(status.CurrentTailnet?.Name ?? "<nil>")",
            "SelfDNS=\(status.SelfStatus?.DNSName ?? "<nil>")",
            "SelfOnline=\((status.SelfStatus?.Online).map { String($0) } ?? "<nil>")",
            "IPs=\((status.TailscaleIPs ?? []).joined(separator: ","))",
            "Health=\((status.Health ?? []).joined(separator: " | "))"
        ].joined(separator: " ")
        appendEvent(category: "backendStatus", detail: summary)
    }

    private func mappedErrorSummary(_ error: any Error) -> String {
        if let tailscaleError = error as? TailscaleError {
            switch tailscaleError {
            case .badInterfaceHandle:
                return "TailscaleError.badInterfaceHandle"
            case .listenerClosed:
                return "TailscaleError.listenerClosed"
            case .invalidTimeout:
                return "TailscaleError.invalidTimeout"
            case .connectionClosed:
                return "TailscaleError.connectionClosed"
            case .readFailed:
                return "TailscaleError.readFailed"
            case .shortWrite:
                return "TailscaleError.shortWrite"
            case .invalidProxyAddress:
                return "TailscaleError.invalidProxyAddress"
            case .invalidControlURL:
                return "TailscaleError.invalidControlURL"
            case .cannotFetchIps(let detail):
                return "TailscaleError.cannotFetchIps(\(detail ?? "<nil>"))"
            case .posixError(let code, let detail):
                return "TailscaleError.posixError(\(code), \(detail ?? "<nil>"))"
            case .unknownPosixError(let code, let detail):
                return "TailscaleError.unknownPosixError(\(code), \(detail ?? "<nil>"))"
            case .internalError(let detail):
                return "TailscaleError.internalError(\(detail ?? "<nil>"))"
            @unknown default:
                return "TailscaleError.unknownFutureCase"
            }
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }
    #endif
}

#if canImport(TailscaleKit)
private actor EmbeddedTailnetReproMessageConsumer: MessageConsumer {
    private var pendingEvents: [(category: String, detail: String)] = []

    func notify(_ notify: Ipn.Notify) {
        let summary = [
            "State=\((notify.State?.rawValue).map { String($0) } ?? "<nil>")",
            "BrowseToURL=\(notify.BrowseToURL ?? "<nil>")",
            "LocalTCPPort=\(notify.LocalTCPPort.map(String.init) ?? "<nil>")",
            "ErrMessage=\(notify.ErrMessage ?? "<nil>")",
            "LoginFinished=\(notify.LoginFinished == nil ? "false" : "true")",
            "Version=\(notify.Version ?? "<nil>")"
        ].joined(separator: " ")
        pendingEvents.append(("ipnNotify", summary))
    }

    func error(_ error: any Error) {
        pendingEvents.append(("ipnError", "\(type(of: error)): \(error.localizedDescription)"))
    }

    func drainEvents() -> [(category: String, detail: String)] {
        let snapshot = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return snapshot
    }
}

private final class EmbeddedTailnetReproLogSink: @unchecked Sendable, LogSink {
    let logFileHandle: Int32?
    private let lock = NSLock()

    init(logPath: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: logPath, contents: nil)
        self.logFileHandle = open(logPath, O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
    }

    deinit {
        if let logFileHandle {
            close(logFileHandle)
        }
    }

    func log(_ message: String) {
        guard let logFileHandle else {
            return
        }

        let line = message + "\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        _ = data.withUnsafeBytes { buffer in
            write(logFileHandle, buffer.baseAddress, buffer.count)
        }
    }
}
#endif
