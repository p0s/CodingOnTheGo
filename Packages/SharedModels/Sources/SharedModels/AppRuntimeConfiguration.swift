import Foundation

public enum AppPrivacyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case privacy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard:
            "Standard"
        case .privacy:
            "Privacy Mode"
        }
    }

    public var summary: String {
        switch self {
        case .standard:
            "Keeps helpful local-only previews, workspace hints, and diagnostics on this device."
        case .privacy:
            "Reduces stored previews, paths, diagnostics, relay retention, and exported metadata."
        }
    }
}

public struct AppRuntimePaths: Hashable, Sendable {
    public var rootDirectoryURL: URL
    public var metadataStoreURL: URL
    public var syncMirrorURL: URL
    public var notificationOutboxURL: URL
    public var companionNotificationRelayDirectoryURL: URL
    public var companionListenerPIDURL: URL
    public var companionListenerLogURL: URL
    public var diagnosticsDirectoryURL: URL

    public init(
        rootDirectoryURL: URL,
        metadataStoreURL: URL,
        syncMirrorURL: URL,
        notificationOutboxURL: URL,
        companionNotificationRelayDirectoryURL: URL,
        companionListenerPIDURL: URL,
        companionListenerLogURL: URL,
        diagnosticsDirectoryURL: URL
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.metadataStoreURL = metadataStoreURL
        self.syncMirrorURL = syncMirrorURL
        self.notificationOutboxURL = notificationOutboxURL
        self.companionNotificationRelayDirectoryURL = companionNotificationRelayDirectoryURL
        self.companionListenerPIDURL = companionListenerPIDURL
        self.companionListenerLogURL = companionListenerLogURL
        self.diagnosticsDirectoryURL = diagnosticsDirectoryURL
    }

    public static func applicationSupport(
        appDirectoryName: String = "CodingOnTheGo",
        fileManager: FileManager = .default
    ) -> Self {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let rootDirectory = baseDirectory.appendingPathComponent(appDirectoryName, isDirectory: true)
        let diagnosticsDirectory = rootDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        let relayDirectory = rootDirectory.appendingPathComponent("NotificationRelay", isDirectory: true)
        let listenerDirectory = rootDirectory.appendingPathComponent("Companion", isDirectory: true)

        return Self(
            rootDirectoryURL: rootDirectory,
            metadataStoreURL: rootDirectory.appendingPathComponent("machine-directory.json"),
            syncMirrorURL: rootDirectory.appendingPathComponent("cotg-sync-mirror.json"),
            notificationOutboxURL: rootDirectory.appendingPathComponent("notification-outbox.json"),
            companionNotificationRelayDirectoryURL: relayDirectory,
            companionListenerPIDURL: listenerDirectory.appendingPathComponent("listener.pid"),
            companionListenerLogURL: diagnosticsDirectory.appendingPathComponent("companion-listener.log"),
            diagnosticsDirectoryURL: diagnosticsDirectory
        )
    }

    public static func uiTestIsolationDirectory(
        environment: [String: String],
        appDirectoryName: String = "CodingOnTheGo",
        fileManager: FileManager = .default
    ) -> URL? {
        guard environment["UI_TESTING"] == "1"
                || environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }

        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let suiteName = environment["COTG_UI_TEST_STORE_SUITE"]
            ?? environment["XCTestSessionIdentifier"]
            ?? environment["XCTestConfigurationFilePath"]
            ?? "default"
        let sanitizedSuiteName = suiteName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        return applicationSupport
            .appendingPathComponent(appDirectoryName)
            .appendingPathComponent("UITests")
            .appendingPathComponent(sanitizedSuiteName, isDirectory: true)
    }
}

public enum SyncCoordinatorBehavior: Hashable, Sendable {
    case localOnly
    case fileMirror(URL)
    case cloudKit(containerIdentifier: String?)
}

public enum NotificationBridgeSubmissionConfiguration: Hashable, Sendable {
    case fileRelay(URL)
    case broker(URL)
}

public struct AppRuntimeConfiguration: Hashable, Sendable {
    public var paths: AppRuntimePaths
    public var syncBehavior: SyncCoordinatorBehavior
    public var notificationBridgeSubmission: NotificationBridgeSubmissionConfiguration
    public var workspaceRootOverride: String?
    public var bootstrapWorkspaceRoot: String?

    public init(
        paths: AppRuntimePaths,
        syncBehavior: SyncCoordinatorBehavior,
        notificationBridgeSubmission: NotificationBridgeSubmissionConfiguration,
        workspaceRootOverride: String? = nil,
        bootstrapWorkspaceRoot: String? = nil
    ) {
        self.paths = paths
        self.syncBehavior = syncBehavior
        self.notificationBridgeSubmission = notificationBridgeSubmission
        self.workspaceRootOverride = workspaceRootOverride
        self.bootstrapWorkspaceRoot = bootstrapWorkspaceRoot
    }

    public init(
        paths: AppRuntimePaths,
        syncBehavior: SyncCoordinatorBehavior,
        notificationBridgeSubmission: NotificationBridgeSubmissionConfiguration
    ) {
        self.init(
            paths: paths,
            syncBehavior: syncBehavior,
            notificationBridgeSubmission: notificationBridgeSubmission,
            workspaceRootOverride: nil,
            bootstrapWorkspaceRoot: nil
        )
    }

    public static func localOnly(
        paths: AppRuntimePaths = .applicationSupport()
    ) -> Self {
        Self(
            paths: paths,
            syncBehavior: .localOnly,
            notificationBridgeSubmission: .fileRelay(paths.companionNotificationRelayDirectoryURL),
            workspaceRootOverride: nil,
            bootstrapWorkspaceRoot: nil
        )
    }

    public static func load(
        environment: [String: String],
        fileManager: FileManager = .default,
        appDirectoryName: String = "CodingOnTheGo"
    ) -> Self {
        var paths = AppRuntimePaths.applicationSupport(
            appDirectoryName: appDirectoryName,
            fileManager: fileManager
        )

        if let metadataPath = Self.nonEmpty(environment["COTG_METADATA_PATH"]) {
            paths.metadataStoreURL = URL(fileURLWithPath: metadataPath)
        }
        if let syncMirrorPath = Self.nonEmpty(environment["COTG_SYNC_MIRROR_PATH"]) {
            paths.syncMirrorURL = URL(fileURLWithPath: syncMirrorPath)
        }
        if let outboxPath = Self.nonEmpty(environment["COTG_NOTIFICATION_OUTBOX_PATH"]) {
            paths.notificationOutboxURL = URL(fileURLWithPath: outboxPath)
        }
        if let relayPath = Self.nonEmpty(environment["COTG_COMPANION_NOTIFICATION_RELAY_DIR"]) {
            paths.companionNotificationRelayDirectoryURL = URL(fileURLWithPath: relayPath, isDirectory: true)
        }

        let runningTests = environment["UI_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil

        if let isolatedUITestDirectory = AppRuntimePaths.uiTestIsolationDirectory(
            environment: environment,
            appDirectoryName: appDirectoryName,
            fileManager: fileManager
        ) {
            if Self.nonEmpty(environment["COTG_METADATA_PATH"]) == nil {
                paths.metadataStoreURL = isolatedUITestDirectory.appendingPathComponent("machine-directory.json")
            }
            if Self.nonEmpty(environment["COTG_SYNC_MIRROR_PATH"]) == nil {
                paths.syncMirrorURL = isolatedUITestDirectory.appendingPathComponent("cotg-sync-mirror.json")
            }
        }

        let syncBehavior: SyncCoordinatorBehavior
        if environment["COTG_DISABLE_CLOUDKIT_SYNC"] == "1"
            || environment["COTG_ENABLE_CLOUDKIT_SYNC"] != "1" {
            syncBehavior = runningTests ? .fileMirror(paths.syncMirrorURL) : .localOnly
        } else {
            syncBehavior = runningTests
                ? .fileMirror(paths.syncMirrorURL)
                : .cloudKit(containerIdentifier: Self.nonEmpty(environment["COTG_CLOUDKIT_CONTAINER_ID"]))
        }

        let notificationBridgeSubmission: NotificationBridgeSubmissionConfiguration
        if let brokerURLString = Self.nonEmpty(environment["COTG_COMPANION_PUSH_BROKER_URL"]),
           let brokerURL = URL(string: brokerURLString) {
            notificationBridgeSubmission = .broker(brokerURL)
        } else {
            notificationBridgeSubmission = .fileRelay(paths.companionNotificationRelayDirectoryURL)
        }

        let workspaceRootOverride = Self.nonEmpty(environment["COTG_UI_TEST_WORKSPACE_ROOT_OVERRIDE"])
        let bootstrapWorkspaceRoot = workspaceRootOverride
            ?? Self.nonEmpty(environment["COTG_WORKSPACE_ROOT"])

        return Self(
            paths: paths,
            syncBehavior: syncBehavior,
            notificationBridgeSubmission: notificationBridgeSubmission,
            workspaceRootOverride: workspaceRootOverride,
            bootstrapWorkspaceRoot: bootstrapWorkspaceRoot
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
