import Foundation
import Notifications
import SharedModels
#if os(macOS)
import Darwin
#endif

public enum CompanionControllerError: LocalizedError {
    case unsupportedPlatform
    case missingCodex
    case processFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Companion listener control requires macOS."
        case .missingCodex:
            "Codex is not installed on this Mac."
        case let .processFailure(message):
            message
        }
    }
}

public actor CompanionServiceController {
    private let port: Int
    private let pidFileURL: URL
    private let logFileURL: URL
    private let runtimeConfiguration: AppRuntimeConfiguration
    private let publisher: any CompanionMetadataPublishing
    private let notificationCoordinator: BridgedNotificationCoordinator
    private var lastSnapshot: CompanionHostSnapshot?

    public init(
        port: Int = 9494,
        runtimeConfiguration: AppRuntimeConfiguration = .localOnly(),
        pidFileURL: URL? = nil,
        logFileURL: URL? = nil,
        publisher: (any CompanionMetadataPublishing)? = nil,
        notificationCoordinator: BridgedNotificationCoordinator? = nil
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.port = port
        self.pidFileURL = pidFileURL ?? runtimeConfiguration.paths.companionListenerPIDURL
        self.logFileURL = logFileURL ?? runtimeConfiguration.paths.companionListenerLogURL
        self.publisher = publisher ?? CompanionMetadataPublisher(runtimeConfiguration: runtimeConfiguration)
        self.notificationCoordinator = notificationCoordinator ?? BridgedNotificationCoordinator(
            outbox: JSONNotificationOutboxStore(url: runtimeConfiguration.paths.notificationOutboxURL),
            bridgeSubmitter: NotificationBridgeFactory.makeDefaultSubmitter(
                configuration: runtimeConfiguration.notificationBridgeSubmission
            )
        )
    }

    public func refreshSnapshot() async -> CompanionHostSnapshot {
        let codexInstalled = (try? run("command -v codex >/dev/null 2>&1")) != nil
        let listenerHealth = inspectListenerHealth()
        let lanAddress = resolveLANAddress()
        try? await notificationCoordinator.flushPending()

        let publishedRoutes = publishedRoutes(
            lanAddress: lanAddress
        )
        var snapshot = CompanionHostSnapshot(
            hostDisplayName: ProcessInfo.processInfo.hostName,
            presence: CompanionPresenceStatus(
                isInstalled: true,
                isReachable: true,
                supportsEnhancedHostMode: codexInstalled
            ),
            publishedRoutes: publishedRoutes,
            sharedListenerState: listenerHealth.state,
            capabilities: CompanionCapabilitySummary(
                canPublishRoutes: true,
                canWarmSharedListener: codexInstalled,
                canExposeDirectEndpoint: false,
                canBridgeNotifications: true
            ),
            listenerStatusNote: listenerHealth.note
        )

        snapshot.publication = await publicationStatus(for: snapshot)
        let initialNotificationSnapshot = await notificationCoordinator.snapshot()
        snapshot.notificationBridge = initialNotificationSnapshot.bridge

        if let event = routeRecoveryEvent(from: lastSnapshot, to: snapshot) {
            try? await notificationCoordinator.schedule(event)
            let updatedNotificationSnapshot = await notificationCoordinator.snapshot()
            snapshot.notificationBridge = updatedNotificationSnapshot.bridge
        }

        lastSnapshot = snapshot
        return snapshot
    }

    public func startSharedListener() async throws -> CompanionHostSnapshot {
        guard (try? run("command -v codex >/dev/null 2>&1")) != nil else {
            throw CompanionControllerError.missingCodex
        }

        _ = try run(
            """
            set -Eeuo pipefail
            PID_FILE=\(shellQuote(pidFileURL.path))
            LOG_FILE=\(shellQuote(logFileURL.path))
            PORT=\(port)
            if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
              exit 0
            fi
            nohup env PATH=/opt/homebrew/bin:/usr/local/bin:$PATH codex app-server --listen "ws://127.0.0.1:$PORT" >"$LOG_FILE" 2>&1 &
            echo $! >"$PID_FILE"
            sleep 1
            """
        )

        return await refreshSnapshot()
    }

    public func stopSharedListener() async throws -> CompanionHostSnapshot {
        _ = try run(
            """
            set -Eeuo pipefail
            PID_FILE=\(shellQuote(pidFileURL.path))
            if [[ -f "$PID_FILE" ]]; then
              kill "$(cat "$PID_FILE")" 2>/dev/null || true
              rm -f "$PID_FILE"
            fi
            """
        )

        return await refreshSnapshot()
    }

    public func openCodexMac() async throws {
        _ = try run("open -a Codex")
    }

    private func publishedRoutes(
        lanAddress: String?
    ) -> [PublishedRoute] {
        guard let lanAddress else {
            return []
        }

        return [
            PublishedRoute(
                kind: .localLAN,
                address: lanAddress,
                health: .healthy
            )
        ]
    }

    private func publicationStatus(for snapshot: CompanionHostSnapshot) async -> CompanionPublicationStatus {
        do {
            return try await publisher.publish(snapshot)
        } catch {
            return CompanionPublicationStatus(
                metadataPath: runtimeConfiguration.paths.metadataStoreURL.path,
                syncMirrorPath: runtimeConfiguration.paths.syncMirrorURL.path,
                publishedMachineID: nil,
                publishedRouteCount: snapshot.publishedRoutes.count,
                lastPublishedAt: .now,
                note: "Publication failed: \(error.localizedDescription)"
            )
        }
    }

    private func routeRecoveryEvent(
        from previous: CompanionHostSnapshot?,
        to current: CompanionHostSnapshot
    ) -> NotificationEvent? {
        let currentHealthy = current.publishedRoutes.filter { $0.health == .healthy }
        guard !currentHealthy.isEmpty else {
            return nil
        }

        let previousHealthy = previous?.publishedRoutes.filter { $0.health == .healthy } ?? []
        let previousKeys = Set(previousHealthy.map { "\($0.kind.rawValue)|\($0.address.lowercased())" })
        guard let recovered = currentHealthy.first(where: { !previousKeys.contains("\($0.kind.rawValue)|\($0.address.lowercased())") }) else {
            return nil
        }

        let routeRecord = RouteRecord(
            kind: recovered.kind,
            label: recovered.kind.title,
            hostname: recovered.kind == .companionDirect ? nil : recovered.address,
            companionEndpoint: recovered.kind == .companionDirect ? URL(string: recovered.address) : nil,
            health: recovered.health,
            isRecommended: true,
            publishedByCompanion: true,
            discoverySource: .companionAdvertisement,
            trustState: .trusted
        )
        let machine = MachineRecord(
            displayName: ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ProcessInfo.processInfo.hostName,
            hostname: ProcessInfo.processInfo.hostName,
            preferredRouteID: routeRecord.id,
            routes: [routeRecord],
            capabilities: HostCapabilitySnapshot(
                remoteLoginEnabled: true,
                codexInstalled: current.capabilities.canWarmSharedListener,
                supportsWebsocketListen: current.capabilities.canWarmSharedListener,
                companionVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                companionState: current.sharedListenerState.rawValue,
                codexAppInstalled: true
            )
        )
        return .routeRecovered(machine: machine)
    }

    private func resolveLANAddress() -> String? {
        for command in [
            "ipconfig getifaddr en0 2>/dev/null",
            "ipconfig getifaddr en1 2>/dev/null",
            "ipconfig getifaddr bridge0 2>/dev/null"
        ] {
            guard let address = try? run(command)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !address.isEmpty,
                !address.hasPrefix("127.") else {
                continue
            }

            return address
        }

        return nil
    }

    private func inspectListenerHealth() -> ListenerHealth {
        let pidFileExists = FileManager.default.fileExists(atPath: pidFileURL.path)
        let processAlive = managedListenerProcessIsAlive()
        let portOpen = loopbackPortIsOpen()

        if processAlive && portOpen {
            return ListenerHealth(
                state: .ready,
                note: "Managed loopback listener is healthy on 127.0.0.1:\(port)."
            )
        }

        if processAlive {
            return ListenerHealth(
                state: .warming,
                note: "Listener process is running, but 127.0.0.1:\(port) is not healthy yet."
            )
        }

        if pidFileExists {
            return ListenerHealth(
                state: .degraded,
                note: "The companion has a stale listener pid file. Remove it or restart the listener."
            )
        }

        if portOpen {
            return ListenerHealth(
                state: .degraded,
                note: "A loopback listener is responding on 127.0.0.1:\(port), but it is not managed by the companion."
            )
        }

        return ListenerHealth(
            state: .stopped,
            note: "Managed shared listener is stopped. SSH stdio remains the safe lane."
        )
    }

    private func managedListenerProcessIsAlive() -> Bool {
        guard let pidString = try? String(contentsOf: pidFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString),
              pid > 0 else {
            return false
        }

        return kill(pid, 0) == 0
    }

    private func loopbackPortIsOpen() -> Bool {
        (try? run("nc -z 127.0.0.1 \(port) >/dev/null 2>&1")) != nil
    }

    private func run(_ command: String) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CompanionControllerError.processFailure(error.isEmpty ? output : error)
        }
        return output
        #else
        throw CompanionControllerError.unsupportedPlatform
        #endif
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private struct ListenerHealth {
    let state: SharedListenerState
    let note: String
}
