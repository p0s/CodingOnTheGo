import CodexRPC
import CryptoKit
import Foundation
import HostBootstrap
import NIO
import NIOCore
import SharedModels
#if canImport(NIOPosix)
import NIOPosix
#endif
#if canImport(NIOTransportServices)
import NIOTransportServices
#endif
@preconcurrency import NIOSSH
@preconcurrency import SSHClient

public enum SSHHostValidationPolicy: Hashable, Sendable {
    case acceptAllForTesting
    case capturePresentedHostKey
    case exactOpenSSHPublicKey(String)
}

public enum SSHAuthenticationMaterial: Hashable, Sendable {
    case password(String)
    case ed25519Seed(Data)
}

public struct SSHProxyConfiguration: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?

    public init(
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public struct SSHGeneratedKeyMaterial: Hashable, Sendable {
    public var privateKeySeed: Data
    public var openSSHPublicKey: String

    public init(privateKeySeed: Data, openSSHPublicKey: String) {
        self.privateKeySeed = privateKeySeed
        self.openSSHPublicKey = openSSHPublicKey
    }

    public static func generateEd25519(comment: String) throws -> SSHGeneratedKeyMaterial {
        let key = Curve25519.Signing.PrivateKey()
        let openSSH = publicKeyString(forEd25519Seed: key.rawRepresentation, comment: comment)
        return SSHGeneratedKeyMaterial(
            privateKeySeed: key.rawRepresentation,
            openSSHPublicKey: openSSH
        )
    }

    public static func publicKeyString(forEd25519Seed seed: Data, comment: String) -> String {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return "\(String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)) \(comment)"
    }
}

public struct CodexSSHConfiguration: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var proxy: SSHProxyConfiguration?
    public var username: String
    public var authentication: SSHAuthenticationMaterial
    public var hostValidation: SSHHostValidationPolicy
    public var cwd: String
    public var codexHome: String?
    public var clientInfo: CodexRPCClientInfo

    public init(
        host: String,
        port: UInt16 = 22,
        proxy: SSHProxyConfiguration? = nil,
        username: String,
        authentication: SSHAuthenticationMaterial,
        hostValidation: SSHHostValidationPolicy,
        cwd: String,
        codexHome: String? = nil,
        clientInfo: CodexRPCClientInfo
    ) {
        self.host = host
        self.port = port
        self.proxy = proxy
        self.username = username
        self.authentication = authentication
        self.hostValidation = hostValidation
        self.cwd = cwd
        self.codexHome = codexHome
        self.clientInfo = clientInfo
    }
}

public enum CodexSSHError: LocalizedError {
    case notConnected
    case invalidResponse(String)
    case invalidRequest(String)
    case capturedHostKey(String)
    case hostKeyMismatch(expected: String, received: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "The SSH app-server transport is not connected."
        case let .invalidResponse(message):
            message
        case let .invalidRequest(message):
            message
        case let .capturedHostKey(received):
            "Captured SSH host key \(received)."
        case let .hostKeyMismatch(expected, received):
            "The SSH host key did not match. Expected \(expected), received \(received)."
        }
    }
}

public struct SSHRemoteCommandResult: Hashable, Sendable {
    public var exitStatus: Int
    public var standardOutput: String
    public var errorOutput: String

    public init(exitStatus: Int, standardOutput: String, errorOutput: String) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.errorOutput = errorOutput
    }
}

public struct SSHStagedAttachment: Hashable, Sendable {
    public var remotePath: String
    public var displayName: String

    public init(remotePath: String, displayName: String) {
        self.remotePath = remotePath
        self.displayName = displayName
    }
}

struct CodexStateStoreThreadRow: Decodable, Sendable {
    var id: String
    var cwd: String
    var title: String
    var firstUserMessage: String
    var updatedAt: Int
    var createdAt: Int
    var modelProvider: String

    enum CodingKeys: String, CodingKey {
        case id
        case cwd
        case title
        case firstUserMessage = "first_user_message"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case modelProvider = "model_provider"
    }
}

public actor CodexSSHAppServerClient {
    private var appServerRuntime: SSHAppServerRuntime?
    private var lastConfiguration: CodexSSHConfiguration?
    private var portForwardRuntime: LocalPortForwardRuntime?
    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<CodexRPCResponseEnvelope, Error>] = [:]
    private var eventHandler: (@Sendable (CodexLiveEvent) -> Void)?
    private var streamParser = SSHAppServerStreamParser()
    private var resolvedRuntime: CodexResolvedRuntime?

    public init() {}

    static let loopbackListenerUnhealthyLogPattern = "failed to initialize sqlite state db|database disk image is malformed"

    static func loopbackListenerLogIndicatesUnhealthyState(_ log: String) -> Bool {
        log.range(
            of: loopbackListenerUnhealthyLogPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public func connect(
        configuration: CodexSSHConfiguration,
        onEvent: @escaping @Sendable (CodexLiveEvent) -> Void
    ) async throws {
        try? await stopLocalPortForward()
        let existingRuntime = appServerRuntime
        appServerRuntime = nil
        if let existingRuntime {
            try? await existingRuntime.stop().get()
        }
        disconnect()
        eventHandler = onEvent
        lastConfiguration = configuration

        let runtime = SSHAppServerRuntime()
        sshDiagnosticLog("COTG SSH: opening app-server SSH session")
        try await runtime.start(
            configuration: configuration,
            command: Self.bootstrapCommand(for: configuration),
            onStdout: { [weak self] data in
                Task {
                    await self?.consumeShellBytes(data)
                }
            },
            onStderr: { data in
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    return
                }
                sshDiagnosticLog("COTG SSH stderr: \(message.count) characters")
            },
            onClosed: { [weak self] error in
                guard let self else { return }
                Task {
                    await self.handleShellFailure(error ?? CodexSSHError.notConnected)
                }
            }
        ).get()
        sshDiagnosticLog("COTG SSH: tcp/auth ready")

        self.appServerRuntime = runtime
        try await Task.sleep(for: .milliseconds(250))
        sshDiagnosticLog("COTG SSH: app-server exec ready")

        let initialize = CodexSessionRPC.initializeRequest(
            id: nextID(),
            clientInfo: configuration.clientInfo
        )
        _ = try await send(request: initialize)
        try await send(notification: CodexSessionRPC.initializedNotification())
        resolvedRuntime = try? await discoverRuntimeDescriptor()
        sshDiagnosticLog("COTG SSH: initialize completed")
    }

    public func connectForLoopbackBootstrap(
        configuration: CodexSSHConfiguration
    ) async throws {
        try? await stopLocalPortForward()
        let existingRuntime = appServerRuntime
        appServerRuntime = nil
        if let existingRuntime {
            try? await existingRuntime.stop().get()
        }
        disconnect()
        eventHandler = nil
        lastConfiguration = configuration

        let runtime = SSHAppServerRuntime()
        sshDiagnosticLog("COTG SSH: opening loopback bootstrap SSH session")
        try await runtime.start(
            configuration: configuration,
            command: Self.loopbackBootstrapCommand(),
            onStdout: { data in
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    return
                }
                sshDiagnosticLog("COTG SSH bootstrap stdout: \(message.count) characters")
            },
            onStderr: { data in
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    return
                }
                sshDiagnosticLog("COTG SSH bootstrap stderr: \(message.count) characters")
            },
            onClosed: { [weak self] error in
                guard let self else { return }
                Task {
                    await self.handleShellFailure(error ?? CodexSSHError.notConnected)
                }
            }
        ).get()
        sshDiagnosticLog("COTG SSH: loopback bootstrap channel ready")

        self.appServerRuntime = runtime
        resolvedRuntime = try? await discoverRuntimeDescriptor()
    }

    public func disconnect() {
        eventHandler = nil
        portForwardRuntime?.stopInBackground()
        portForwardRuntime = nil

        if let appServerRuntime {
            Task {
                try? await appServerRuntime.stop().get()
            }
        }
        self.appServerRuntime = nil
        lastConfiguration = nil
        resolvedRuntime = nil

        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
        streamParser.reset()
    }

    public func startThread(cwd: String) async throws -> CodexThreadContext {
        try await startThread(cwd: cwd, model: nil)
    }

    public func startThread(cwd: String, model: String?) async throws -> CodexThreadContext {
        try await startThread(
            options: CodexThreadExecutionOptions(
                cwd: cwd,
                model: model
            )
        )
    }

    public func startThread(options: CodexThreadExecutionOptions) async throws -> CodexThreadContext {
        let request = CodexSessionRPC.startThreadRequest(id: nextID(), options: options)
        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeStartedThread(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func resumeThread(
        threadID: String,
        cwd: String?,
        model: String?
    ) async throws -> CodexResumedThreadContext {
        try await resumeThread(
            threadID: threadID,
            options: CodexThreadExecutionOptions(
                cwd: cwd,
                model: model
            )
        )
    }

    public func resumeThread(
        threadID: String,
        options: CodexThreadExecutionOptions
    ) async throws -> CodexResumedThreadContext {
        let request = CodexSessionRPC.resumeThreadRequest(
            id: nextID(),
            threadID: threadID,
            options: options
        )

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeResumedThread(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func readThread(threadID: String, includeTurns: Bool = true) async throws -> CodexThreadSnapshot {
        let request = CodexSessionRPC.readThreadRequest(
            id: nextID(),
            threadID: threadID,
            includeTurns: includeTurns
        )

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeThreadSnapshot(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func listThreads(
        cwd: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        sortKey: String? = nil,
        searchTerm: String? = nil
    ) async throws -> CodexThreadListPage {
        let request = CodexSessionRPC.listThreadsRequest(
            id: nextID(),
            cwd: cwd,
            limit: limit,
            cursor: cursor,
            sortKey: sortKey,
            searchTerm: searchTerm
        )

        sshDiagnosticLog("COTG SSH: thread/list request id=\(request.id) cursorPresent=\(cursor != nil) limit=\(limit.map(String.init) ?? "nil")")
        let response = try await send(request: request)
        do {
            let page = try CodexSessionRPC.decodeThreadListPage(from: response)
            sshDiagnosticLog("COTG SSH: thread/list response id=\(request.id) count=\(page.threads.count) nextCursorPresent=\(page.nextCursor != nil)")
            return page
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func listThreadsFromStateStore(
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> CodexThreadListPage {
        // The sqlite read is a 1.0 repair/fallback path for zero-install hosts. Live
        // app-server data remains the canonical browser source whenever it is available.
        let pageSize = max(1, limit ?? 200)
        let offset = try Self.decodeStateStoreCursor(cursor)
        let fetchCount = pageSize + 1
        let query = """
        SELECT id, cwd, title, first_user_message, updated_at, created_at, model_provider
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT \(fetchCount) OFFSET \(offset);
        """

        let databaseAssignment: String
        if let codexHome = lastConfiguration?.codexHome {
            let databasePath = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("state_5.sqlite", isDirectory: false)
                .path
            databaseAssignment = "STATE_DB=\(shellQuote(databasePath))"
        } else {
            databaseAssignment = #"STATE_DB="$HOME/.codex/state_5.sqlite""#
        }

        let command = """
        bash -lc \(shellQuote("""
        set -euo pipefail
        \(databaseAssignment)
        if [[ ! -f "$STATE_DB" ]]; then
          printf '[]'
          exit 0
        fi
        sqlite3 -json "$STATE_DB" \(shellQuote(query))
        """))
        """

        let result = try await execute(command: command)
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(
                result.errorOutput.isEmpty
                    ? "Failed to read the remote Codex state store."
                    : result.errorOutput
            )
        }

        let page = try Self.decodeStateStoreThreadListPage(
            from: result.standardOutput,
            limit: pageSize,
            offset: offset
        )
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            sshDiagnosticLog(
                "COTG SSH: state-store page count=\(page.threads.count) nextCursorPresent=\(page.nextCursor != nil) cursorPresent=\(cursor != nil) stderrBytes=\(result.errorOutput.utf8.count)"
            )
            if page.threads.isEmpty {
                let diagnosticCommand = """
                bash -lc \(shellQuote("""
                set -euo pipefail
                \(databaseAssignment)
                printf 'HOME=%s\\nSTATE_DB=%s\\n' "$HOME" "$STATE_DB"
                if [[ -d "${STATE_DB%/*}" ]]; then
                  ls -ld "${STATE_DB%/*}"
                else
                  echo "STATE_DB_DIR_MISSING"
                fi
                if [[ -f "$STATE_DB" ]]; then
                  ls -l "$STATE_DB"
                  sqlite3 "$STATE_DB" 'SELECT COUNT(*) AS active_threads FROM threads WHERE archived = 0;'
                else
                  echo "STATE_DB_MISSING"
                fi
                """))
                """
                do {
                    let diagnosticResult = try await execute(command: diagnosticCommand)
                    sshDiagnosticLog(
                        "COTG SSH: state-store debug exit=\(diagnosticResult.exitStatus) stdoutBytes=\(diagnosticResult.standardOutput.utf8.count) stderrBytes=\(diagnosticResult.errorOutput.utf8.count)"
                    )
                } catch {
                    sshDiagnosticLog("COTG SSH: state-store debug failed: \(type(of: error))")
                }
            }
        }

        return page
    }

    public func debugStateStoreLocation() async throws -> String {
        let databaseAssignment: String
        if let codexHome = lastConfiguration?.codexHome {
            let databasePath = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("state_5.sqlite", isDirectory: false)
                .path
            databaseAssignment = "STATE_DB=\(shellQuote(databasePath))"
        } else {
            databaseAssignment = #"STATE_DB="$HOME/.codex/state_5.sqlite""#
        }

        let command = """
        bash -lc \(shellQuote("""
        set -euo pipefail
        \(databaseAssignment)
        printf 'HOME=%s STATE_DB=%s ' "$HOME" "$STATE_DB"
        if [[ -f "$STATE_DB" ]]; then
          printf 'STATE_DB_EXISTS=1 '
          printf 'THREAD_COUNT=%s' "$(sqlite3 "$STATE_DB" 'SELECT COUNT(*) FROM threads WHERE archived = 0;')"
        else
          printf 'STATE_DB_EXISTS=0'
        fi
        """))
        """

        let result = try await execute(command: command)
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(
                result.errorOutput.isEmpty
                    ? "Failed to inspect the remote Codex state store."
                    : result.errorOutput
            )
        }

        let summary = Self.compactStateStoreText(result.standardOutput, maxLength: 400)
        if summary.isEmpty {
            return "stateStoreDebug=empty"
        }
        return summary
    }

    public func startTurn(threadID: String, text: String) async throws -> CodexTurnContext {
        try await startTurn(
            threadID: threadID,
            input: [.text(text)],
            model: nil,
            effort: nil,
            collaborationMode: nil
        )
    }

    public func startTurn(
        threadID: String,
        text: String,
        model: String?,
        effort: CodexReasoningEffort?,
        collaborationMode: CodexCollaborationMode? = nil
    ) async throws -> CodexTurnContext {
        try await startTurn(
            threadID: threadID,
            input: [.text(text)],
            options: CodexTurnExecutionOptions(
                model: model,
                effort: effort,
                collaborationMode: collaborationMode
            )
        )
    }

    public func startTurn(
        threadID: String,
        input: [CodexUserInput],
        model: String?,
        effort: CodexReasoningEffort?,
        collaborationMode: CodexCollaborationMode? = nil
    ) async throws -> CodexTurnContext {
        try await startTurn(
            threadID: threadID,
            input: input,
            options: CodexTurnExecutionOptions(
                model: model,
                effort: effort,
                collaborationMode: collaborationMode
            )
        )
    }

    public func startTurn(
        threadID: String,
        input: [CodexUserInput],
        options: CodexTurnExecutionOptions
    ) async throws -> CodexTurnContext {
        let request: CodexRPCRequest<JSONObjectEncodable>
        do {
            request = try CodexSessionRPC.startTurnRequest(
                id: nextID(),
                threadID: threadID,
                input: input,
                options: options
            )
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeStartedTurn(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func listModels() async throws -> [CodexModelDescriptor] {
        let request = CodexSessionRPC.listModelsRequest(id: nextID())
        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeModels(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func readConfig() async throws -> CodexExecutionBaselineConfigSnapshot {
        let request = CodexSessionRPC.readConfigRequest(id: nextID())
        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeBaselineConfigSnapshot(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func readConfigRequirements() async throws -> CodexExecutionConstraintsSnapshot {
        let request = CodexSessionRPC.readConfigRequirementsRequest(id: nextID())
        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeConfigRequirementsSnapshot(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func steerTurn(threadID: String, expectedTurnID: String, text: String) async throws -> CodexTurnContext {
        let request = CodexSessionRPC.steerTurnRequest(
            id: nextID(),
            threadID: threadID,
            expectedTurnID: expectedTurnID,
            text: text
        )

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeSteeredTurn(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func interruptTurn(threadID: String, turnID: String) async throws {
        let request = CodexSessionRPC.interruptTurnRequest(
            id: nextID(),
            threadID: threadID,
            turnID: turnID
        )

        _ = try await send(request: request)
    }

    public func forkThread(threadID: String, cwd: String?, model: String?) async throws -> CodexThreadContext {
        let request = CodexSessionRPC.forkThreadRequest(
            id: nextID(),
            threadID: threadID,
            cwd: cwd,
            model: model
        )

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeForkedThread(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func startReview(
        threadID: String,
        delivery: CodexReviewDelivery,
        target: CodexReviewTarget
    ) async throws -> CodexReviewContext {
        let request = CodexSessionRPC.reviewStartRequest(
            id: nextID(),
            threadID: threadID,
            delivery: delivery,
            target: target
        )

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeStartedReview(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
    }

    public func resolveApproval(_ request: CodexApprovalRequest, decision: CodexApprovalDecision) async throws {
        let response = CodexSessionRPC.approvalResultEnvelope(request: request, decision: decision)
        try await sendResult(response)
    }

    public func resolveStructuredUserInput(
        _ request: CodexStructuredUserInputRequest,
        answersByQuestionID: [String: [String]]
    ) async throws {
        let response = CodexSessionRPC.structuredUserInputResultEnvelope(
            request: request,
            answersByQuestionID: answersByQuestionID
        )
        try await sendResult(response)
    }

    public func execute(command: String) async throws -> SSHRemoteCommandResult {
        guard let runtime = appServerRuntime else {
            throw CodexSSHError.notConnected
        }

        return try await runtime.execute(command: command).get()
    }

    public func stageAttachment(
        data: Data,
        suggestedFilename: String,
        remoteDirectory: String? = nil
    ) async throws -> SSHStagedAttachment {
        guard let runtime = appServerRuntime else {
            throw CodexSSHError.notConnected
        }

        let rootDirectory = remoteDirectory ?? Self.defaultAttachmentDirectory(for: lastConfiguration)
        let attachmentDirectory = rootDirectory + "/" + UUID().uuidString
        let mkdirResult = try await execute(command: "mkdir -p \(shellQuote(attachmentDirectory))")
        guard mkdirResult.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(
                mkdirResult.errorOutput.isEmpty
                    ? "Failed to prepare the remote attachment directory."
                    : mkdirResult.errorOutput
            )
        }

        let fileName = Self.sanitizedAttachmentFilename(from: suggestedFilename)
        let remotePath = attachmentDirectory + "/" + fileName
        let base64Payload = Data((data.base64EncodedString() + "\n").utf8)
        let uploadCommand = """
        bash -lc \(shellQuote("base64 -D > \(shellQuote(remotePath))"))
        """
        let uploadResult = try await runtime.execute(
            command: uploadCommand,
            standardInput: base64Payload
        ).get()
        guard uploadResult.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(
                uploadResult.errorOutput.isEmpty
                    ? "Failed to stage the attachment on the remote host."
                    : uploadResult.errorOutput
            )
        }

        return SSHStagedAttachment(
            remotePath: remotePath,
            displayName: fileName
        )
    }

    public func startLoopbackListener(
        port: Int = 9494,
        pidFile: String? = nil,
        logFile: String? = nil
    ) async throws -> URL {
        let artifactPaths = CodexSSHRuntimeArtifacts.paths(for: lastConfiguration)
        let resolvedPIDFile = pidFile ?? artifactPaths.loopbackPIDFile
        let resolvedLogFile = logFile ?? artifactPaths.loopbackLogFile
        let appServerEnvironment = Self.appServerEnvironment(for: lastConfiguration)
        let runtimeEnvironment = "\(appServerEnvironment)PATH=/opt/homebrew/bin:/usr/local/bin:$PATH"
        let appServerAuthSetup = Self.appServerAuthSetup(for: lastConfiguration)
        let runtimeBootstrap = Self.runtimeBootstrapCommand(using: resolvedRuntime)
        let runtimeExecutable = resolvedRuntime.map { shellQuote($0.binaryPath) } ?? "\"$CODEX_RUNTIME_PATH\""
        let launchctlSubmitCondition = Self.launchctlSubmitCondition()
        let unhealthyLogPattern = shellQuote(Self.loopbackListenerUnhealthyLogPattern)
        let command = """
        set -Eeuo pipefail
        ROOT_DIR=\(shellQuote(artifactPaths.rootDirectory))
        PID_FILE=\(shellQuote(resolvedPIDFile))
        LOG_FILE=\(shellQuote(resolvedLogFile))
        PORT=\(port)
        SSH_UID="$(id -u)"
        UNHEALTHY_LOG_PATTERN=\(unhealthyLogPattern)
        mkdir -p "$ROOT_DIR"
        listener_log_indicates_unhealthy_state() {
          [[ -f "$LOG_FILE" ]] && grep -Eiq "$UNHEALTHY_LOG_PATTERN" "$LOG_FILE"
        }
        clear_listener_log() {
          : >"$LOG_FILE"
        }
        stop_recorded_listener() {
          local pid_content="${1:-}"
          if [[ "$pid_content" == launchctl:* ]]; then
            launchctl remove "${pid_content#launchctl:}" >/dev/null 2>&1 || true
          elif [[ -n "$pid_content" ]]; then
            kill "$pid_content" >/dev/null 2>&1 || true
          fi
          rm -f "$PID_FILE"
        }
        if [[ -f "$PID_FILE" ]]; then
          PID_CONTENT="$(cat "$PID_FILE")"
          if [[ "$PID_CONTENT" == launchctl:* ]]; then
            LABEL="${PID_CONTENT#launchctl:}"
            if \(launchctlSubmitCondition) && launchctl print "gui/$SSH_UID/$LABEL" >/dev/null 2>&1; then
              if listener_log_indicates_unhealthy_state; then
                stop_recorded_listener "$PID_CONTENT"
                clear_listener_log
              else
                exit 0
              fi
            else
              launchctl remove "$LABEL" >/dev/null 2>&1 || true
              rm -f "$PID_FILE"
            fi
          elif kill -0 "$PID_CONTENT" 2>/dev/null; then
            if listener_log_indicates_unhealthy_state; then
              stop_recorded_listener "$PID_CONTENT"
              clear_listener_log
            else
              exit 0
            fi
          else
            rm -f "$PID_FILE"
          fi
        fi
        \(runtimeBootstrap)
        \(appServerAuthSetup)
        if \(launchctlSubmitCondition); then
          LABEL="cotg.app-server.$(date +%s).$RANDOM.$RANDOM"
          launchctl remove "$LABEL" >/dev/null 2>&1 || true
          launchctl submit -l "$LABEL" -o "$LOG_FILE" -e "$LOG_FILE" -- /usr/bin/env \(runtimeEnvironment) \(runtimeExecutable) app-server --listen "ws://127.0.0.1:$PORT"
          echo "launchctl:$LABEL" >"$PID_FILE"
        elif command -v setsid >/dev/null 2>&1; then
          setsid /usr/bin/env \(runtimeEnvironment) \(runtimeExecutable) app-server --listen "ws://127.0.0.1:$PORT" </dev/null >"$LOG_FILE" 2>&1 &
          echo $! >"$PID_FILE"
        else
          nohup /usr/bin/env \(runtimeEnvironment) \(runtimeExecutable) app-server --listen "ws://127.0.0.1:$PORT" </dev/null >"$LOG_FILE" 2>&1 &
          echo $! >"$PID_FILE"
        fi
        sleep 1
        if listener_log_indicates_unhealthy_state; then
          if [[ -f "$PID_FILE" ]]; then
            stop_recorded_listener "$(cat "$PID_FILE")"
          fi
          echo "Loopback listener reported unhealthy Codex state; refusing to use the websocket lane. See $LOG_FILE." >&2
          exit 42
        fi
        """

        let result = try await execute(command: "bash -lc \(shellQuote(command))")
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(result.errorOutput.isEmpty ? "Failed to start loopback listener." : result.errorOutput)
        }
        return URL(string: "ws://127.0.0.1:\(port)")!
    }

    public func stopLoopbackListener(pidFile: String? = nil) async throws {
        let resolvedPIDFile = pidFile ?? CodexSSHRuntimeArtifacts.paths(for: lastConfiguration).loopbackPIDFile
        let command = """
        set -Eeuo pipefail
        PID_FILE=\(shellQuote(resolvedPIDFile))
        if [[ -f "$PID_FILE" ]]; then
          PID_CONTENT="$(cat "$PID_FILE")"
          if [[ "$PID_CONTENT" == launchctl:* ]]; then
            launchctl remove "${PID_CONTENT#launchctl:}" 2>/dev/null || true
          else
            kill "$PID_CONTENT" 2>/dev/null || true
          fi
          rm -f "$PID_FILE"
        fi
        """

        let result = try await execute(command: "bash -lc \(shellQuote(command))")
        guard result.exitStatus == 0 else {
            throw CodexSSHError.invalidResponse(result.errorOutput.isEmpty ? "Failed to stop loopback listener." : result.errorOutput)
        }
    }

    public func loopbackListenerIsHealthy(port: Int = 9494) async throws -> Bool {
        let command = "bash -lc \(shellQuote("nc -z 127.0.0.1 \(port)"))"
        let result = try await execute(command: command)
        return result.exitStatus == 0
    }

    public func startLocalPortForward(
        remoteHost: String = "127.0.0.1",
        remotePort: Int = 9494,
        localHost: String = "127.0.0.1",
        preferredLocalPort: Int = 0
    ) async throws -> URL {
        guard let configuration = lastConfiguration else {
            throw CodexSSHError.notConnected
        }

        if let portForwardRuntime {
            try await portForwardRuntime.stop().get()
            self.portForwardRuntime = nil
        }

        let runtime = LocalPortForwardRuntime()
        let localPort = try await runtime.start(
            configuration: configuration,
            remoteHost: remoteHost,
            remotePort: remotePort,
            localHost: localHost,
            preferredLocalPort: preferredLocalPort
        ).get()
        portForwardRuntime = runtime
        return URL(string: "ws://\(localHost):\(localPort)")!
    }

    public func stopLocalPortForward() async throws {
        guard let portForwardRuntime else {
            return
        }

        try await portForwardRuntime.stop().get()
        self.portForwardRuntime = nil
    }

    public func runtimeDescriptor() -> CodexResolvedRuntime? {
        resolvedRuntime
    }

    private func send<Params: Encodable & Sendable>(request: CodexRPCRequest<Params>) async throws -> CodexRPCResponseEnvelope {
        guard let runtime = appServerRuntime else {
            throw CodexSSHError.notConnected
        }

        let payload = try CodexRPCLineCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[request.id] = continuation

            Task { [weak self] in
                do {
                    try await runtime.write(payload).get()
                } catch {
                    await self?.failPendingResponse(id: request.id, error: error)
                }
            }
        }
    }

    private func send<Notification: Encodable & Sendable>(notification: Notification) async throws {
        guard let runtime = appServerRuntime else {
            throw CodexSSHError.notConnected
        }

        try await runtime.write(try CodexRPCLineCodec.encode(notification)).get()
    }

    private func sendResult<Result: Encodable & Sendable>(_ response: CodexRPCResultEnvelope<Result>) async throws {
        guard let runtime = appServerRuntime else {
            throw CodexSSHError.notConnected
        }

        try await runtime.write(try CodexRPCLineCodec.encode(response)).get()
    }

    private func sendError(_ response: CodexRPCErrorEnvelope) async throws {
        guard let runtime = appServerRuntime else {
            throw CodexSSHError.notConnected
        }

        try await runtime.write(try CodexRPCLineCodec.encode(response)).get()
    }

    private func consumeShellBytes(_ bytes: Data) async {
        sshDiagnosticLog("COTG SSH: read \(bytes.count) bytes")
        do {
            let events = try streamParser.append(bytes)
            for event in events {
                switch event {
                case let .shellLine(line):
                    sshDiagnosticLog("COTG SSH: dropped shell line length=\(line.count)")
                case let .envelope(envelope, payload):
                    sshDiagnosticLog("COTG SSH: rpc envelope bytes=\(payload.count)")
                    await handle(envelope)
                }
            }
        } catch {
            await handleShellFailure(error)
        }
    }

    private func handleShellFailure(_ error: Error) async {
        sshDiagnosticLog("COTG SSH: shell failed \(type(of: error))")
        streamParser.reset()
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        emit(.error(error.localizedDescription))
    }

    private func failPendingResponse(id: Int, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func handle(_ envelope: CodexRPCResponseEnvelope) async {
        if CodexSessionRPC.isServerInitiatedEnvelope(envelope) {
            if let serverRequest = CodexSessionRPC.decodeServerRequest(from: envelope) {
                switch serverRequest {
                case .approval, .structuredUserInput:
                    if let event = CodexSessionRPC.liveEvent(from: envelope) {
                        emit(event)
                    }
                case let .unsupported(request):
                    emit(.serverRequestUnsupported(request))
                    try? await sendError(
                        CodexSessionRPC.unsupportedServerRequestErrorEnvelope(
                            id: request.id,
                            method: request.method
                        )
                    )
                }
                return
            }

            if let event = CodexSessionRPC.liveEvent(from: envelope) {
                emit(event)
                return
            }
        }

        if let id = envelope.id?.intValue,
           let continuation = pendingResponses.removeValue(forKey: id) {
            if let error = envelope.error {
                continuation.resume(throwing: CodexSSHError.invalidResponse(error.message))
            } else {
                continuation.resume(returning: envelope)
            }
            return
        }

        if let rpcError = envelope.error {
            emit(.error(rpcError.message))
            return
        }

        if let event = CodexSessionRPC.liveEvent(from: envelope) {
            emit(event)
        }
    }

    private func emit(_ event: CodexLiveEvent) {
        eventHandler?(event)
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private static func summarizedRPCLine(_ data: Data, prefixLimit: Int = 240) -> String {
        guard data.count > prefixLimit else {
            return String(decoding: data, as: UTF8.self)
        }

        let prefix = String(decoding: data.prefix(prefixLimit), as: UTF8.self)
        return "\(prefix)… [\(data.count) bytes]"
    }

    private static func bootstrapCommand(for configuration: CodexSSHConfiguration) -> String {
        let cwd = shellQuoted(configuration.cwd)
        let runtimeBootstrap = runtimeBootstrapCommand(using: nil)
        let runtimeEnvironment = "\(appServerEnvironment(for: configuration))PATH=/opt/homebrew/bin:/usr/local/bin:$PATH"
        if let codexHome = configuration.codexHome {
            let quotedCodexHome = shellQuoted(codexHome)
            return """
            \(runtimeBootstrap)
            ORIGINAL_HOME="$HOME" && mkdir -p \(quotedCodexHome) && if [ -f "$ORIGINAL_HOME/.codex/auth.json" ] && [ ! -f \(quotedCodexHome)/auth.json ]; then cp "$ORIGINAL_HOME/.codex/auth.json" \(quotedCodexHome)/auth.json; fi && if [ -d \(cwd) ]; then cd \(cwd); else cd /tmp; fi && exec /usr/bin/env \(runtimeEnvironment) "$CODEX_RUNTIME_PATH" app-server --listen stdio:// 2>>\(quotedCodexHome)/app-server.stderr
            """
            + "\n"
        }

        return """
        \(runtimeBootstrap)
        mkdir -p "$HOME/.codex" && if [ -d \(cwd) ]; then cd \(cwd); else cd /tmp; fi && exec /usr/bin/env \(runtimeEnvironment) "$CODEX_RUNTIME_PATH" app-server --listen stdio:// 2>>"$HOME/.codex/app-server.stderr"
        """
        + "\n"
    }

    private static func loopbackBootstrapCommand() -> String {
        "sh -lc \(shellQuoted("trap 'exit 0' TERM INT; while :; do sleep 3600; done"))\n"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func appServerEnvironment(for configuration: CodexSSHConfiguration?) -> String {
        guard let codexHome = configuration?.codexHome else {
            return ""
        }

        let quotedCodexHome = shellQuoted(codexHome)
        return "CODEX_HOME=\(quotedCodexHome) "
    }

    private static func launchctlSubmitCondition(uidVariable: String = "$SSH_UID") -> String {
        #"[[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1 && launchctl print "gui/\#(uidVariable)" >/dev/null 2>&1"#
    }

    private static func appServerAuthSetup(for configuration: CodexSSHConfiguration?) -> String {
        guard let codexHome = configuration?.codexHome else {
            return ""
        }

        let quotedCodexHome = shellQuote(codexHome)
        return """
        ORIGINAL_HOME="$HOME"
        mkdir -p \(quotedCodexHome)
        if [[ -f "$ORIGINAL_HOME/.codex/auth.json" ]] && [[ ! -f \(quotedCodexHome)/auth.json ]]; then
          cp "$ORIGINAL_HOME/.codex/auth.json" \(quotedCodexHome)/auth.json
        fi
        """
    }

    private static func defaultAttachmentDirectory(for configuration: CodexSSHConfiguration?) -> String {
        CodexSSHRuntimeArtifacts.paths(for: configuration).attachmentsDirectory
    }

    private static func sanitizedAttachmentFilename(from suggestedFilename: String) -> String {
        CodexSSHRuntimeArtifacts.sanitizedAttachmentFilename(from: suggestedFilename)
    }

    private func discoverRuntimeDescriptor() async throws -> CodexResolvedRuntime? {
        let result = try await execute(command: CodexRuntimeDiscovery.summaryCommand())
        guard result.exitStatus == 0,
              let discovery = CodexRuntimeDiscovery.parseSummary(result.standardOutput) else {
            return nil
        }
        return discovery.runtime
    }

    private static func runtimeBootstrapCommand(using runtime: CodexResolvedRuntime?) -> String {
        if let runtime {
            return """
            CODEX_RUNTIME_PATH=\(shellQuoted(runtime.binaryPath))
            """
        }

        return """
        \(CodexRuntimeDiscovery.resolverShell())
        resolve_codex_runtime || exit 127
        """
    }

    private static func mapSessionError(_ error: CodexSessionRPCError) -> CodexSSHError {
        switch error {
        case let .invalidResponse(message):
            return .invalidResponse(message)
        case let .invalidRequest(message):
            return .invalidRequest(message)
        }
    }

    static func decodeStateStoreThreadListPage(
        from rawJSON: String,
        limit: Int,
        offset: Int
    ) throws -> CodexThreadListPage {
        try CodexSSHStateStoreFallback.decodeThreadListPage(
            from: rawJSON,
            limit: limit,
            offset: offset
        )
    }

    static func decodeStateStoreCursor(_ cursor: String?) throws -> Int {
        try CodexSSHStateStoreFallback.decodeCursor(cursor)
    }

    static func encodeStateStoreCursor(_ offset: Int) -> String {
        CodexSSHStateStoreFallback.encodeCursor(offset)
    }

    static func compactStateStoreText(_ raw: String, maxLength: Int = 140) -> String {
        CodexSSHStateStoreFallback.compactText(raw, maxLength: maxLength)
    }
}

private final class Ed25519KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let privateKey: NIOSSHPrivateKey
    private var challengeCount = 0

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        challengeCount += 1
        sshDiagnosticLog("COTG SSH: public-key auth challenge \(challengeCount) methods=\(availableMethods.debugSummary)")
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(CodexSSHError.invalidRequest("The server did not allow public-key authentication."))
            return
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

private extension NIOSSHAvailableUserAuthenticationMethods {
    var debugSummary: String {
        var methods: [String] = []
        if contains(.publicKey) {
            methods.append("publicKey")
        }
        if contains(.password) {
            methods.append("password")
        }
        if contains(.hostBased) {
            methods.append("hostBased")
        }
        return methods.isEmpty ? "[]" : methods.joined(separator: ",")
    }
}

private struct ExactHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let expectedOpenSSHKey: String

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let received = String(openSSHPublicKey: hostKey)
        sshDiagnosticLog("COTG SSH: host-key validate received")
        if received == expectedOpenSSHKey {
            sshDiagnosticLog("COTG SSH: host-key matched expected key")
            validationCompletePromise.succeed(())
        } else {
            sshDiagnosticLog("COTG SSH: host-key mismatch")
            validationCompletePromise.fail(
                CodexSSHError.hostKeyMismatch(
                    expected: expectedOpenSSHKey,
                    received: received
                )
            )
        }
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private enum SSHBootstrapMode: String, Sendable {
    case auto
    case posix
    case network

    static func configured() -> SSHBootstrapMode {
        let raw = ProcessInfo.processInfo.environment["COTG_SSH_BOOTSTRAP_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return SSHBootstrapMode(rawValue: raw ?? "") ?? .auto
    }
}

private func shouldTraceRawSSHBytes() -> Bool {
    ProcessInfo.processInfo.environment["COTG_SSH_TRACE_RAW"] == "1"
}

private func sshDiagnosticLoggingEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["COTG_SSH_DIAGNOSTIC_LOGS"] == "1" || environment["UI_TESTING"] == "1"
}

private func sshDiagnosticLog(_ message: @autoclosure () -> String) {
    guard sshDiagnosticLoggingEnabled() else {
        return
    }
    print(message())
}

private func sshClientBootstrap(
    group: EventLoopGroup,
    configuration: CodexSSHConfiguration,
    authenticationHandler: SSHAuthenticationCompletionHandler,
    clientConfiguration: SSHClientConfiguration,
    mode: SSHBootstrapMode
) -> NIOClientTCPBootstrapProtocol {
    let bootstrap: NIOClientTCPBootstrapProtocol
    switch mode {
    case .auto:
        #if canImport(NIOTransportServices) && (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        if let niotsGroup = group as? NIOTSEventLoopGroup {
            bootstrap = NIOTSConnectionBootstrap(group: niotsGroup)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        } else {
            bootstrap = ClientBootstrap(group: group)
        }
        #elseif canImport(NIOPosix)
        bootstrap = ClientBootstrap(group: group)
        #elseif canImport(NIOTransportServices)
        bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        #else
        bootstrap = ClientBootstrap(group: group)
        #endif
    case .posix:
        #if canImport(NIOPosix)
        bootstrap = ClientBootstrap(group: group)
        #elseif canImport(NIOTransportServices)
        bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        #else
        bootstrap = ClientBootstrap(group: group)
        #endif
    case .network:
        #if canImport(NIOTransportServices)
        if let niotsGroup = group as? NIOTSEventLoopGroup {
            bootstrap = NIOTSConnectionBootstrap(group: niotsGroup)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        } else {
            bootstrap = ClientBootstrap(group: group)
        }
        #elseif canImport(NIOPosix)
        bootstrap = ClientBootstrap(group: group)
        #else
        bootstrap = ClientBootstrap(group: group)
        #endif
    }

    return bootstrap
        .channelInitializer { channel in
            if configuration.proxy == nil {
                let traceEnabled = shouldTraceRawSSHBytes()
                let addTrace = traceEnabled
                    ? channel.pipeline.addHandler(SSHRawByteTraceHandler(label: "parent"))
                    : channel.eventLoop.makeSucceededFuture(())
                return addTrace.flatMap {
                    channel.pipeline.addHandler(
                        NIOSSHHandler(
                            role: .client(clientConfiguration),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }.flatMap {
                    channel.pipeline.addHandlers([
                        SSHTransportErrorLogger(),
                        authenticationHandler,
                        NIOCloseOnErrorHandler()
                    ])
                }
            }

            return channel.pipeline.addHandlers([
                SOCKS5ProxyHandshakeHandler(
                    configuration: configuration,
                    clientConfiguration: clientConfiguration,
                    authenticationHandler: authenticationHandler
                ),
                NIOCloseOnErrorHandler()
            ])
        }
        .channelOption(ChannelOptions.autoRead, value: true)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
}

private func bootstrapEndpoint(for configuration: CodexSSHConfiguration) -> (host: String, port: Int) {
    if let proxy = configuration.proxy {
        return (proxy.host, Int(proxy.port))
    }
    return (configuration.host, Int(configuration.port))
}

private func makeSSHEventLoopGroup(mode: SSHBootstrapMode) -> EventLoopGroup {
    switch mode {
    case .auto:
        #if canImport(NIOTransportServices) && (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return NIOTSEventLoopGroup()
        #else
        return MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #endif
    case .posix:
        return MultiThreadedEventLoopGroup(numberOfThreads: 1)
    case .network:
        #if canImport(NIOTransportServices)
        return NIOTSEventLoopGroup()
        #else
        return MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #endif
    }
}

private final class SSHAppServerRuntime: @unchecked Sendable {
    private let bootstrapMode = SSHBootstrapMode.configured()
    private lazy var group: EventLoopGroup = makeSSHEventLoopGroup(mode: bootstrapMode)
    private var parentChannel: Channel?
    private var sessionChannel: Channel?
    private var didStop = false

    func start(
        configuration: CodexSSHConfiguration,
        command: String,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (Error?) -> Void
    ) -> EventLoopFuture<Void> {
        let capturedHostKeyBox = CapturedHostKeyBox()
        let authenticationHandler = SSHAuthenticationCompletionHandler(
            eventLoop: group.next(),
            timeout: .seconds(10)
        )
        let clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: authenticationDelegate(for: configuration),
            serverAuthDelegate: hostValidationDelegate(
                for: configuration,
                capturedHostKeyBox: capturedHostKeyBox
            )
        )

        let bootstrap = sshClientBootstrap(
            group: group,
            configuration: configuration,
            authenticationHandler: authenticationHandler,
            clientConfiguration: clientConfiguration,
            mode: bootstrapMode
        )
        let endpoint = bootstrapEndpoint(for: configuration)
        sshDiagnosticLog("COTG SSH: bootstrap mode=\(bootstrapMode.rawValue) rawTrace=\(shouldTraceRawSSHBytes())")

        return bootstrap.connect(host: endpoint.host, port: endpoint.port)
            .flatMap { channel in
                sshDiagnosticLog("COTG SSH: parent channel connected")
                self.parentChannel = channel
                channel.closeFuture.whenComplete { result in
                    guard !self.didStop else {
                        return
                    }

                    switch result {
                    case .success:
                        sshDiagnosticLog("COTG SSH: parent channel closed success=true")
                        onClosed(CodexSSHError.notConnected)
                    case let .failure(error):
                        sshDiagnosticLog("COTG SSH: parent channel closed success=false")
                        onClosed(error)
                    }
                }
                authenticationHandler.authenticated.whenComplete { result in
                    switch result {
                    case .success:
                        sshDiagnosticLog("COTG SSH: auth future completed success=true")
                    case .failure:
                        sshDiagnosticLog("COTG SSH: auth future completed success=false")
                    }
                }
                return authenticationHandler.authenticated.map { channel }
            }
            .flatMap { channel in
                self.openAppServerChannel(
                    parentChannel: channel,
                    command: command,
                    onStdout: onStdout,
                    onStderr: onStderr,
                    onClosed: onClosed
                )
            }
            .flatMapError { error in
                if case .capturePresentedHostKey = configuration.hostValidation,
                   let capturedHostKey = capturedHostKeyBox.value {
                    return self.group.next().makeFailedFuture(
                        CodexSSHError.capturedHostKey(capturedHostKey)
                    )
                }

                return self.group.next().makeFailedFuture(error)
            }
    }

    func write(_ data: Data) -> EventLoopFuture<Void> {
        guard let sessionChannel else {
            return group.next().makeFailedFuture(CodexSSHError.notConnected)
        }

        var buffer = sessionChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return sessionChannel.writeAndFlush(buffer)
    }

    func execute(
        command: String,
        standardInput: Data? = nil
    ) -> EventLoopFuture<SSHRemoteCommandResult> {
        guard let parentChannel else {
            return group.next().makeFailedFuture(CodexSSHError.notConnected)
        }

        return parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)
            let resultPromise = parentChannel.eventLoop.makePromise(of: SSHRemoteCommandResult.self)
            sshHandler.createChannel(channelPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(
                        CodexSSHError.invalidResponse("SSH exec opened the wrong channel type.")
                    )
                }

                return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap {
                        childChannel.pipeline.addHandlers([
                            SSHExecCommandHandler(
                                command: command,
                                standardInput: standardInput,
                                resultPromise: resultPromise
                            ),
                            NIOCloseOnErrorHandler()
                        ])
                    }
            }

            return channelPromise.futureResult.flatMap { _ in
                resultPromise.futureResult
            }
        }
    }

    func stop() -> EventLoopFuture<Void> {
        if didStop {
            return group.next().makeSucceededFuture(())
        }
        didStop = true

        let sessionClose = sessionChannel?.close() ?? group.next().makeSucceededFuture(())
        let parentClose = parentChannel?.close() ?? group.next().makeSucceededFuture(())

        return sessionClose.flatMap {
            parentClose
        }.flatMap { _ in
            let promise = self.group.next().makePromise(of: Void.self)
            self.group.shutdownGracefully { error in
                if let error {
                    promise.fail(error)
                } else {
                    promise.succeed(())
                }
            }
            return promise.futureResult
        }
    }

    private func openAppServerChannel(
        parentChannel: Channel,
        command: String,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (Error?) -> Void
    ) -> EventLoopFuture<Void> {
        parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)
            let startedPromise = parentChannel.eventLoop.makePromise(of: Void.self)
            sshHandler.createChannel(channelPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(
                        CodexSSHError.invalidResponse("SSH app-server opened the wrong channel type.")
                    )
                }

                return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap {
                        childChannel.pipeline.addHandlers([
                            SSHAppServerChannelHandler(
                                command: command,
                                startedPromise: startedPromise,
                                onStdout: onStdout,
                                onStderr: onStderr,
                                onClosed: { error in
                                    guard !self.didStop else {
                                        return
                                    }
                                    onClosed(error)
                                }
                            ),
                            NIOCloseOnErrorHandler()
                        ])
                    }
            }

            return channelPromise.futureResult.flatMap { channel in
                self.sessionChannel = channel
                return startedPromise.futureResult
            }
        }
    }

    private func authenticationDelegate(for configuration: CodexSSHConfiguration) -> NIOSSHClientUserAuthenticationDelegate {
        switch configuration.authentication {
        case let .password(password):
            return PasswordAuthDelegate(username: configuration.username, password: password)
        case let .ed25519Seed(seed):
            let key = NIOSSHPrivateKey(
                ed25519Key: try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            )
            return Ed25519KeyAuthDelegate(
                username: configuration.username,
                privateKey: key
            )
        }
    }

    private func hostValidationDelegate(
        for configuration: CodexSSHConfiguration,
        capturedHostKeyBox: CapturedHostKeyBox
    ) -> NIOSSHClientServerAuthenticationDelegate {
        switch configuration.hostValidation {
        case .acceptAllForTesting:
            return AcceptAllHostKeysDelegate()
        case .capturePresentedHostKey:
            return CapturePresentedHostKeyDelegate(capturedHostKeyBox: capturedHostKeyBox)
        case let .exactOpenSSHPublicKey(expected):
            return ExactHostKeyValidator(expectedOpenSSHKey: expected)
        }
    }
}

private final class SSHAppServerChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let startedPromise: EventLoopPromise<Void>
    private let onStdout: @Sendable (Data) -> Void
    private let onStderr: @Sendable (Data) -> Void
    private let onClosed: @Sendable (Error?) -> Void
    private var didResolveStart = false
    private var didClose = false

    init(
        command: String,
        startedPromise: EventLoopPromise<Void>,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (Error?) -> Void
    ) {
        self.command = command
        self.startedPromise = startedPromise
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.onClosed = onClosed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let contextRef = ChannelHandlerContextRef(context)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            contextRef.context?.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        let contextRef = ChannelHandlerContextRef(context)
        context.triggerUserOutboundEvent(request).whenFailure { error in
            self.resolveStartIfNeeded(with: error)
            self.finish(with: error)
            contextRef.context?.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)

        guard case let .byteBuffer(buffer) = message.data,
              let payload = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return
        }

        switch message.type {
        case .channel:
            onStdout(payload)
        case .stdErr:
            onStderr(payload)
        default:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            resolveStartIfNeeded()
        case is ChannelFailureEvent:
            let error = CodexSSHError.invalidResponse("SSH app-server exec request failed.")
            resolveStartIfNeeded(with: error)
            finish(with: error)
            context.close(promise: nil)
        case let exit as SSHChannelRequestEvent.ExitStatus:
            if exit.exitStatus != 0 {
                let error = CodexSSHError.invalidResponse("SSH app-server exited with status \(exit.exitStatus).")
                finish(with: error)
            }
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            finish(with: CodexSSHError.invalidResponse("SSH app-server session ended unexpectedly."))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: CodexSSHError.notConnected)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        resolveStartIfNeeded(with: CodexSSHError.notConnected)
        finish(with: CodexSSHError.notConnected)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        resolveStartIfNeeded(with: error)
        finish(with: error)
        context.close(promise: nil)
    }

    private func resolveStartIfNeeded(with error: Error? = nil) {
        guard !didResolveStart else {
            return
        }
        didResolveStart = true
        if let error {
            startedPromise.fail(error)
        } else {
            startedPromise.succeed(())
        }
    }

    private func finish(with error: Error?) {
        guard !didClose else {
            return
        }
        didClose = true
        onClosed(error)
    }
}

private final class SSHExecCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let standardInput: Data?
    private let resultPromise: EventLoopPromise<SSHRemoteCommandResult>
    private var standardOutput = Data()
    private var standardError = Data()
    private var exitStatus: Int?
    private var didFinish = false

    init(
        command: String,
        standardInput: Data?,
        resultPromise: EventLoopPromise<SSHRemoteCommandResult>
    ) {
        self.command = command
        self.standardInput = standardInput
        self.resultPromise = resultPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let contextRef = ChannelHandlerContextRef(context)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            contextRef.context?.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        let contextRef = ChannelHandlerContextRef(context)
        context.triggerUserOutboundEvent(request).whenFailure { error in
            self.finish(with: error)
            contextRef.context?.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)

        guard case let .byteBuffer(buffer) = message.data,
              let payload = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return
        }

        switch message.type {
        case .channel:
            standardOutput.append(payload)
        case .stdErr:
            standardError.append(payload)
        default:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if let standardInput,
               !standardInput.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: standardInput.count)
                buffer.writeBytes(standardInput)
                context.writeAndFlush(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            }
            context.close(mode: .output, promise: nil)
        case is ChannelFailureEvent:
            finish(with: CodexSSHError.invalidResponse("SSH exec request failed."))
            context.close(promise: nil)
        case let exit as SSHChannelRequestEvent.ExitStatus:
            exitStatus = exit.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let exitStatus {
            finish(
                with: nil,
                result: SSHRemoteCommandResult(
                    exitStatus: exitStatus,
                    standardOutput: String(decoding: standardOutput, as: UTF8.self),
                    errorOutput: String(decoding: standardError, as: UTF8.self)
                )
            )
        } else {
            finish(with: CodexSSHError.invalidResponse("SSH exec channel closed before returning an exit status."))
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let exitStatus {
            finish(
                with: nil,
                result: SSHRemoteCommandResult(
                    exitStatus: exitStatus,
                    standardOutput: String(decoding: standardOutput, as: UTF8.self),
                    errorOutput: String(decoding: standardError, as: UTF8.self)
                )
            )
        } else {
            finish(with: CodexSSHError.notConnected)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: error)
        context.close(promise: nil)
    }

    private func finish(with error: Error?, result: SSHRemoteCommandResult? = nil) {
        guard !didFinish else {
            return
        }
        didFinish = true

        if let result {
            resultPromise.succeed(result)
        } else if let error {
            resultPromise.fail(error)
        } else {
            resultPromise.fail(CodexSSHError.notConnected)
        }
    }
}

private final class ChannelHandlerContextRef: @unchecked Sendable {
    weak var context: ChannelHandlerContext?

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}

private final class LocalPortForwardRuntime: @unchecked Sendable {
    private let bootstrapMode = SSHBootstrapMode.configured()
    private lazy var group: EventLoopGroup = makeSSHEventLoopGroup(mode: bootstrapMode)
    private var listenerChannel: Channel?
    private var parentChannel: Channel?
    private var didStop = false

    func start(
        configuration: CodexSSHConfiguration,
        remoteHost: String,
        remotePort: Int,
        localHost: String,
        preferredLocalPort: Int
    ) -> EventLoopFuture<Int> {
        let capturedHostKeyBox = CapturedHostKeyBox()
        let authenticationHandler = SSHAuthenticationCompletionHandler(
            eventLoop: group.next(),
            timeout: .seconds(10)
        )
        let clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: authenticationDelegate(for: configuration),
            serverAuthDelegate: hostValidationDelegate(
                for: configuration,
                capturedHostKeyBox: capturedHostKeyBox
            )
        )

        let bootstrap = sshClientBootstrap(
            group: group,
            configuration: configuration,
            authenticationHandler: authenticationHandler,
            clientConfiguration: clientConfiguration,
            mode: bootstrapMode
        )
        let endpoint = bootstrapEndpoint(for: configuration)

        return bootstrap.connect(host: endpoint.host, port: endpoint.port)
            .flatMap { channel in
                self.parentChannel = channel
                channel.closeFuture.whenComplete { _ in
                    self.stopInBackground()
                }
                return authenticationHandler.authenticated.map { channel }
            }
            .flatMap { channel in
                self.bindLocalServer(
                    parentChannel: channel,
                    remoteHost: remoteHost,
                    remotePort: remotePort,
                    localHost: localHost,
                    preferredLocalPort: preferredLocalPort
                )
            }
            .flatMapError { error in
                if case .capturePresentedHostKey = configuration.hostValidation,
                   let capturedHostKey = capturedHostKeyBox.value {
                    return self.group.next().makeFailedFuture(
                        CodexSSHError.capturedHostKey(capturedHostKey)
                    )
                }

                return self.group.next().makeFailedFuture(error)
            }
    }

    func stop() -> EventLoopFuture<Void> {
        if didStop {
            return group.next().makeSucceededFuture(())
        }
        didStop = true

        let listenerClose = listenerChannel?.close() ?? group.next().makeSucceededFuture(())
        let parentClose = parentChannel?.close() ?? group.next().makeSucceededFuture(())

        return listenerClose.flatMap {
            parentClose
        }.flatMap { _ in
            let promise = self.group.next().makePromise(of: Void.self)
            self.group.shutdownGracefully { error in
                if let error {
                    promise.fail(error)
                } else {
                    promise.succeed(())
                }
            }
            return promise.futureResult
        }
    }

    func stopInBackground() {
        guard !didStop else {
            return
        }
        _ = stop()
    }

    private func bindLocalServer(
        parentChannel: Channel,
        remoteHost: String,
        remotePort: Int,
        localHost: String,
        preferredLocalPort: Int
    ) -> EventLoopFuture<Int> {
        let childChannelInitializer: @Sendable (Channel) -> EventLoopFuture<Void> = { inboundChannel in
            parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)
                let originatorAddress = inboundChannel.remoteAddress
                    ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                let channelType = SSHChannelType.directTCPIP(
                    .init(
                        targetHost: remoteHost,
                        targetPort: remotePort,
                        originatorAddress: originatorAddress
                    )
                )

                sshHandler.createChannel(promise, channelType: channelType) { childChannel, createdType in
                    guard case .directTCPIP = createdType else {
                        return childChannel.eventLoop.makeFailedFuture(
                            CodexSSHError.invalidResponse("SSH local forward opened the wrong channel type.")
                        )
                    }

                    let (sshGlue, localGlue) = GlueHandler.matchedPair()
                    return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .flatMap {
                            childChannel.pipeline.addHandlers([
                                SSHWrapperHandler(),
                                sshGlue,
                                NIOCloseOnErrorHandler()
                            ])
                        }
                        .flatMap {
                            inboundChannel.pipeline.addHandlers([
                                localGlue,
                                NIOCloseOnErrorHandler()
                            ])
                        }
                }

                return promise.futureResult.map { _ in }
            }
        }

        let bindFuture: EventLoopFuture<Channel>
        #if canImport(NIOTransportServices)
        if let niotsGroup = group as? NIOTSEventLoopGroup {
            // Local forwarding must use the listener bootstrap that matches the NIOTS event loop.
            bindFuture = NIOTSListenerBootstrap(group: niotsGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer(childChannelInitializer)
                .bind(host: localHost, port: preferredLocalPort)
        } else {
            bindFuture = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer(childChannelInitializer)
                .bind(host: localHost, port: preferredLocalPort)
        }
        #else
        bindFuture = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer(childChannelInitializer)
            .bind(host: localHost, port: preferredLocalPort)
        #endif

        return bindFuture
            .flatMapThrowing { channel in
                self.listenerChannel = channel
                guard let port = channel.localAddress?.port else {
                    throw CodexSSHError.invalidResponse("SSH local forward failed to bind a local port.")
                }
                return port
            }
    }

    private func authenticationDelegate(for configuration: CodexSSHConfiguration) -> NIOSSHClientUserAuthenticationDelegate {
        switch configuration.authentication {
        case let .password(password):
            return PasswordAuthDelegate(username: configuration.username, password: password)
        case let .ed25519Seed(seed):
            let key = NIOSSHPrivateKey(
                ed25519Key: try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            )
            return Ed25519KeyAuthDelegate(
                username: configuration.username,
                privateKey: key
            )
        }
    }

    private func hostValidationDelegate(
        for configuration: CodexSSHConfiguration,
        capturedHostKeyBox: CapturedHostKeyBox
    ) -> NIOSSHClientServerAuthenticationDelegate {
        switch configuration.hostValidation {
        case .acceptAllForTesting:
            return AcceptAllHostKeysDelegate()
        case .capturePresentedHostKey:
            return CapturePresentedHostKeyDelegate(capturedHostKeyBox: capturedHostKeyBox)
        case let .exactOpenSSHPublicKey(expected):
            return ExactHostKeyValidator(expectedOpenSSHKey: expected)
        }
    }
}

private final class SOCKS5ProxyHandshakeHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case greeting
        case authenticating
        case connecting
        case ready
    }

    private let configuration: CodexSSHConfiguration
    private let clientConfiguration: SSHClientConfiguration
    private let authenticationHandler: SSHAuthenticationCompletionHandler
    private var state: State = .greeting
    private var receiveBuffer = ByteBuffer()

    init(
        configuration: CodexSSHConfiguration,
        clientConfiguration: SSHClientConfiguration,
        authenticationHandler: SSHAuthenticationCompletionHandler
    ) {
        self.configuration = configuration
        self.clientConfiguration = clientConfiguration
        self.authenticationHandler = authenticationHandler
    }

    func channelActive(context: ChannelHandlerContext) {
        guard let proxy = configuration.proxy else {
            context.fireErrorCaught(CodexSSHError.invalidRequest("SOCKS5 proxy configuration is missing."))
            return
        }

        var buffer = context.channel.allocator.buffer(capacity: 4)
        buffer.writeInteger(UInt8(0x05))
        if proxy.username != nil || proxy.password != nil {
            buffer.writeInteger(UInt8(0x02))
            buffer.writeInteger(UInt8(0x00))
            buffer.writeInteger(UInt8(0x02))
        } else {
            buffer.writeInteger(UInt8(0x01))
            buffer.writeInteger(UInt8(0x00))
        }
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inboundBuffer = unwrapInboundIn(data)
        receiveBuffer.writeBuffer(&inboundBuffer)

        while true {
            switch state {
            case .greeting:
                guard receiveBuffer.readableBytes >= 2 else {
                    return
                }

                guard receiveBuffer.readInteger(as: UInt8.self) == 0x05 else {
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy returned an invalid greeting version."))
                    return
                }

                let method = receiveBuffer.readInteger(as: UInt8.self) ?? 0xFF
                if method == 0xFF {
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy rejected every authentication method."))
                    return
                }

                if method == 0x02 {
                    state = .authenticating
                    writeUsernamePasswordRequest(context: context)
                } else if method == 0x00 {
                    state = .connecting
                    writeConnectRequest(context: context)
                } else {
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy selected unsupported method \(method)."))
                    return
                }
            case .authenticating:
                guard receiveBuffer.readableBytes >= 2 else {
                    return
                }

                guard receiveBuffer.readInteger(as: UInt8.self) == 0x01,
                      receiveBuffer.readInteger(as: UInt8.self) == 0x00 else {
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy rejected username/password authentication."))
                    return
                }

                state = .connecting
                writeConnectRequest(context: context)
            case .connecting:
                guard let responseLength = socksConnectResponseLength(from: receiveBuffer) else {
                    return
                }

                guard receiveBuffer.readableBytes >= responseLength else {
                    return
                }

                guard receiveBuffer.readInteger(as: UInt8.self) == 0x05 else {
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy returned an invalid connect response version."))
                    return
                }

                let reply = receiveBuffer.readInteger(as: UInt8.self) ?? 0xFF
                _ = receiveBuffer.readInteger(as: UInt8.self)
                let atyp = receiveBuffer.readInteger(as: UInt8.self) ?? 0x00
                if reply != 0x00 {
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy connect failed with reply code \(reply)."))
                    return
                }

                switch atyp {
                case 0x01:
                    _ = receiveBuffer.readBytes(length: 4)
                case 0x03:
                    let length = Int(receiveBuffer.readInteger(as: UInt8.self) ?? 0)
                    _ = receiveBuffer.readBytes(length: length)
                case 0x04:
                    _ = receiveBuffer.readBytes(length: 16)
                default:
                    context.fireErrorCaught(CodexSSHError.invalidResponse("SOCKS5 proxy returned an unsupported address type \(atyp)."))
                    return
                }
                _ = receiveBuffer.readInteger(as: UInt16.self)

                state = .ready
                promoteToSSHPipeline(context: context)
                return
            case .ready:
                if receiveBuffer.readableBytes > 0 {
                    context.fireChannelRead(wrapInboundOut(receiveBuffer))
                    receiveBuffer.clear()
                }
                return
            }
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    private func writeUsernamePasswordRequest(context: ChannelHandlerContext) {
        let username = configuration.proxy?.username ?? ""
        let password = configuration.proxy?.password ?? ""
        var buffer = context.channel.allocator.buffer(capacity: 3 + username.utf8.count + password.utf8.count)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeInteger(UInt8(username.utf8.count))
        buffer.writeString(username)
        buffer.writeInteger(UInt8(password.utf8.count))
        buffer.writeString(password)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func writeConnectRequest(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: 300)
        buffer.writeInteger(UInt8(0x05))
        buffer.writeInteger(UInt8(0x01))
        buffer.writeInteger(UInt8(0x00))
        let hostBytes = Array(configuration.host.utf8)
        buffer.writeInteger(UInt8(0x03))
        buffer.writeInteger(UInt8(hostBytes.count))
        buffer.writeBytes(hostBytes)

        buffer.writeInteger(configuration.port)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func promoteToSSHPipeline(context: ChannelHandlerContext) {
        let contextRef = ChannelHandlerContextRef(context)
        context.channel.pipeline.addHandlers([
            NIOSSHHandler(
                role: .client(clientConfiguration),
                allocator: context.channel.allocator,
                inboundChildChannelInitializer: nil
            ),
            authenticationHandler
        ], position: .after(self)).whenComplete { result in
            switch result {
            case .success:
                contextRef.context?.fireChannelActive()
                if self.receiveBuffer.readableBytes > 0 {
                    contextRef.context?.fireChannelRead(self.wrapInboundOut(self.receiveBuffer))
                    self.receiveBuffer.clear()
                    contextRef.context?.fireChannelReadComplete()
                }
                contextRef.context?.pipeline.removeHandler(self, promise: nil)
            case let .failure(error):
                contextRef.context?.fireErrorCaught(error)
            }
        }
    }

    private func socksConnectResponseLength(from buffer: ByteBuffer) -> Int? {
        guard buffer.readableBytes >= 5 else {
            return nil
        }

        let readable = buffer.readableBytesView
        let atyp = readable[readable.index(readable.startIndex, offsetBy: 3)]
        let baseLength = 4
        switch atyp {
        case 0x01:
            return baseLength + 4 + 2
        case 0x03:
            let length = Int(readable[readable.index(readable.startIndex, offsetBy: 4)])
            return baseLength + 1 + length + 2
        case 0x04:
            return baseLength + 16 + 2
        default:
            return nil
        }
    }
}

private final class SSHAuthenticationCompletionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    enum AuthenticationError: Error {
        case timeout
        case endedChannel
    }

    let authenticated: EventLoopFuture<Void>
    private let promise: EventLoopPromise<Void>
    private let timeoutTask: Scheduled<Void>
    private var capturedError: Error?

    init(eventLoop: EventLoop, timeout: TimeAmount) {
        let promise = eventLoop.makePromise(of: Void.self)
        self.promise = promise
        self.authenticated = promise.futureResult
        self.timeoutTask = eventLoop.scheduleTask(in: timeout) {
            sshDiagnosticLog("COTG SSH: auth timeout fired")
            promise.fail(AuthenticationError.timeout)
        }
    }

    deinit {
        timeoutTask.cancel()
        sshDiagnosticLog("COTG SSH: auth handler deinit")
        promise.fail(AuthenticationError.endedChannel)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH: auth handler added")
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH: auth handler removed")
    }

    func channelActive(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH: auth handler channel active")
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            sshDiagnosticLog("COTG SSH: received UserAuthSuccessEvent")
            timeoutTask.cancel()
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        capturedError = error
        sshDiagnosticLog("COTG SSH: auth handler error \(type(of: error))")
        timeoutTask.cancel()
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH: auth handler channel inactive capturedError=\(capturedError != nil)")
        timeoutTask.cancel()
        promise.fail(capturedError ?? AuthenticationError.endedChannel)
        context.fireChannelInactive()
    }
}

private final class SSHTransportErrorLogger: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sshDiagnosticLog("COTG SSH: pipeline error \(type(of: error))")
        context.fireErrorCaught(error)
    }
}

private final class SSHRawByteTraceHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let label: String
    private var inboundChunks = 0
    private var outboundChunks = 0

    init(label: String) {
        self.label = label
    }

    func handlerAdded(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH RAW[\(label)]: handler added")
    }

    func channelActive(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH RAW[\(label)]: channel active")
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        inboundChunks += 1
        sshDiagnosticLog("COTG SSH RAW[\(label)]: inbound[\(inboundChunks)] bytes=\(buffer.readableBytes)")
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        outboundChunks += 1
        sshDiagnosticLog("COTG SSH RAW[\(label)]: outbound[\(outboundChunks)] bytes=\(buffer.readableBytes)")
        context.write(wrapOutboundOut(buffer), promise: promise)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sshDiagnosticLog("COTG SSH RAW[\(label)]: error \(type(of: error))")
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        sshDiagnosticLog("COTG SSH RAW[\(label)]: channel inactive")
        context.fireChannelInactive()
    }

    private static func debugPrefix(for buffer: ByteBuffer, limit: Int = 48) -> String {
        guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: min(buffer.readableBytes, limit)),
              !bytes.isEmpty else {
            return "<empty>"
        }

        return bytes.map { byte in
            if byte == 10 {
                return "\\n"
            }
            if byte == 13 {
                return "\\r"
            }
            if (32...126).contains(byte) {
                let scalar = UnicodeScalar(byte)
                return String(Character(scalar))
            }
            return String(format: "\\x%02X", byte)
        }.joined()
    }
}

private struct PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(CodexSSHError.invalidRequest("The server did not allow password authentication."))
            return
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
        )
    }
}

private struct AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class CapturedHostKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedHostKey: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return capturedHostKey
    }

    func store(_ hostKey: String) {
        lock.lock()
        if capturedHostKey == nil {
            capturedHostKey = hostKey
        }
        lock.unlock()
    }
}

private struct CapturePresentedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let capturedHostKeyBox: CapturedHostKeyBox

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSHKey = String(openSSHPublicKey: hostKey)
        capturedHostKeyBox.store(openSSHKey)
        validationCompletePromise.fail(
            CodexSSHError.capturedHostKey(openSSHKey)
        )
    }
}

private final class SSHWrapperHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)

        guard case .channel = data.type,
              case let .byteBuffer(buffer) = data.data else {
            context.fireErrorCaught(CodexSSHError.invalidResponse("SSH local forward received invalid channel data."))
            return
        }

        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

private final class GlueHandler: @unchecked Sendable {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent,
           case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

struct SSHAppServerStreamParser: Sendable {
    enum Event: Hashable, Sendable {
        case shellLine(String)
        case envelope(CodexRPCResponseEnvelope, payload: Data)
    }

    static let defaultMaxBufferedJSONFragmentBytes = 64 * 1024 * 1024

    private let maxBufferedJSONFragmentBytes: Int
    private var receiveBuffer = Data()
    private var oversizedJSONDiscarder: OversizedJSONDiscarder?

    init(maxBufferedJSONFragmentBytes: Int = Self.defaultMaxBufferedJSONFragmentBytes) {
        self.maxBufferedJSONFragmentBytes = maxBufferedJSONFragmentBytes
    }

    fileprivate enum TransportEscapeState {
        case normal
        case escape
        case controlSequence
    }

    mutating func reset() {
        receiveBuffer.removeAll(keepingCapacity: false)
        oversizedJSONDiscarder = nil
    }

    mutating func append(_ bytes: Data) throws -> [Event] {
        receiveBuffer.append(bytes)

        var events: [Event] = []
        if let diagnostic = consumeOversizedJSONDiscarder() {
            events.append(.shellLine(diagnostic))
        }

        while true {
            receiveBuffer.trimLeadingTransportPadding()
            guard !receiveBuffer.isEmpty else {
                break
            }

            if receiveBuffer.first == 0x7B {
                guard let endIndex = Self.completeJSONObjectEnd(in: receiveBuffer) else {
                    let bufferedPayload = receiveBuffer.normalizedJSONTransportPayload()
                    guard bufferedPayload.count <= maxBufferedJSONFragmentBytes else {
                        if let diagnostic = beginDiscardingOversizedJSON() {
                            events.append(.shellLine(diagnostic))
                            continue
                        }
                        break
                    }
                    break
                }

                let rawPayload = Data(receiveBuffer[..<endIndex])
                receiveBuffer.removeSubrange(..<endIndex)
                let payload = rawPayload.normalizedJSONTransportPayload()
                do {
                    let envelope = try CodexRPCLineCodec.decodeResponse(payload)
                    events.append(.envelope(envelope, payload: payload))
                } catch {
                    throw Self.invalidPayloadError(for: payload, underlying: error)
                }
                continue
            }

            if let objectStartIndex = receiveBuffer.firstJSONObjectStartIndex {
                let shellNoise = Data(receiveBuffer[..<objectStartIndex]).trimmingShellNoise()
                receiveBuffer.removeSubrange(..<objectStartIndex)
                if !shellNoise.isEmpty {
                    events.append(.shellLine(String(decoding: shellNoise, as: UTF8.self)))
                }
                continue
            }

            guard let lineEndIndex = receiveBuffer.firstLineBreakIndex else {
                break
            }

            let line = Data(receiveBuffer[..<lineEndIndex]).trimmingShellNoise()
            receiveBuffer.removeFirstLine(including: lineEndIndex)
            guard !line.isEmpty else {
                continue
            }
            events.append(.shellLine(String(decoding: line, as: UTF8.self)))
        }

        return events
    }

    private mutating func beginDiscardingOversizedJSON() -> String? {
        var discarder = OversizedJSONDiscarder(limit: maxBufferedJSONFragmentBytes)
        let completionIndex = discarder.consume(receiveBuffer)
        if let completionIndex {
            receiveBuffer.removeSubrange(..<completionIndex)
            return discarder.diagnostic
        }

        receiveBuffer.removeAll(keepingCapacity: false)
        oversizedJSONDiscarder = discarder
        return nil
    }

    private mutating func consumeOversizedJSONDiscarder() -> String? {
        guard var discarder = oversizedJSONDiscarder else {
            return nil
        }

        let completionIndex = discarder.consume(receiveBuffer)
        if let completionIndex {
            receiveBuffer.removeSubrange(..<completionIndex)
            oversizedJSONDiscarder = nil
            return discarder.diagnostic
        }

        receiveBuffer.removeAll(keepingCapacity: false)
        oversizedJSONDiscarder = discarder
        return nil
    }

    private static func invalidPayloadError(for payload: Data, underlying: Error) -> CodexSSHError {
        CodexSSHError.invalidResponse(
            "Failed to decode app-server payload (\(payload.count) bytes): \(underlying.localizedDescription)"
        )
    }

    private static func completeJSONObjectEnd(in data: Data) -> Data.Index? {
        guard data.first == 0x7B else {
            return nil
        }

        var depth = 0
        var insideString = false
        var escaped = false
        var escapeState = TransportEscapeState.normal

        for index in data.indices {
            let byte = data[index]

            switch escapeState {
            case .escape:
                if byte == 0x5B {
                    escapeState = .controlSequence
                } else {
                    escapeState = .normal
                }
                continue
            case .controlSequence:
                if (0x40...0x7E).contains(byte) {
                    escapeState = .normal
                }
                continue
            case .normal:
                break
            }

            if insideString {
                if byte < 0x20 {
                    continue
                }
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    insideString = false
                }
                continue
            }

            switch byte {
            case 0x00, 0x0A, 0x0D, 0x0B, 0x0C:
                continue
            case 0x1B:
                escapeState = .escape
                continue
            case 0x22:
                insideString = true
            case 0x7B, 0x5B:
                depth += 1
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 0 {
                    return data.index(after: index)
                }
                if depth < 0 {
                    return nil
                }
            default:
                continue
            }
        }

        return nil
    }
}

private struct OversizedJSONDiscarder: Sendable {
    let limit: Int
    private(set) var rawByteCount = 0

    private var depth = 0
    private var insideString = false
    private var escaped = false
    private var escapeState = SSHAppServerStreamParser.TransportEscapeState.normal

    init(limit: Int) {
        self.limit = limit
    }

    var diagnostic: String {
        "Dropped oversized app-server JSON payload after \(rawByteCount) bytes; limit is \(limit) bytes."
    }

    mutating func consume(_ data: Data) -> Data.Index? {
        for index in data.indices {
            rawByteCount += 1
            let byte = data[index]

            switch escapeState {
            case .escape:
                if byte == 0x5B {
                    escapeState = .controlSequence
                } else {
                    escapeState = .normal
                }
                continue
            case .controlSequence:
                if (0x40...0x7E).contains(byte) {
                    escapeState = .normal
                }
                continue
            case .normal:
                break
            }

            if insideString {
                if byte < 0x20 {
                    continue
                }
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    insideString = false
                }
                continue
            }

            switch byte {
            case 0x00, 0x0A, 0x0D, 0x0B, 0x0C:
                continue
            case 0x1B:
                escapeState = .escape
                continue
            case 0x22:
                insideString = true
            case 0x7B, 0x5B:
                depth += 1
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 0 {
                    return data.index(after: index)
                }
                if depth < 0 {
                    return data.index(after: index)
                }
            default:
                continue
            }
        }

        return nil
    }
}

private extension Data {
    func trimmingShellNoise() -> Data {
        let trimmedBytes = self.drop { byte in
            byte == 0x0D || byte == 0x0A || byte == 0x00
        }.reversed().drop { byte in
            byte == 0x0D || byte == 0x0A || byte == 0x00
        }.reversed()
        return Data(trimmedBytes)
    }

    func normalizedJSONTransportPayload() -> Data {
        var normalized = Data()
        normalized.reserveCapacity(count)

        var insideString = false
        var escaped = false
        var escapeState = SSHAppServerStreamParser.TransportEscapeState.normal

        for byte in self {
            switch escapeState {
            case .escape:
                if byte == 0x5B {
                    escapeState = .controlSequence
                } else {
                    escapeState = .normal
                }
                continue
            case .controlSequence:
                if (0x40...0x7E).contains(byte) {
                    escapeState = .normal
                }
                continue
            case .normal:
                break
            }

            if insideString {
                if escaped {
                    normalized.append(byte)
                    escaped = false
                    continue
                }

                if byte == 0x5C {
                    normalized.append(byte)
                    escaped = true
                    continue
                }

                if byte == 0x22 {
                    normalized.append(byte)
                    insideString = false
                    continue
                }

                if byte < 0x20 {
                    continue
                }

                normalized.append(byte)
                continue
            }

            switch byte {
            case 0x00, 0x0A, 0x0D, 0x0B, 0x0C:
                continue
            case 0x1B:
                escapeState = .escape
            case 0x22:
                normalized.append(byte)
                insideString = true
            default:
                normalized.append(byte)
            }
        }

        return normalized
    }

    mutating func trimLeadingTransportPadding() {
        while let first = self.first, first == 0x0A || first == 0x0D || first == 0x00 {
            removeFirst()
        }
    }

    var firstLineBreakIndex: Data.Index? {
        firstIndex { byte in
            byte == 0x0A || byte == 0x0D
        }
    }

    var firstJSONObjectStartIndex: Data.Index? {
        firstIndex { byte in
            byte == 0x7B
        }
    }

    mutating func removeFirstLine(including lineEndIndex: Data.Index) {
        var removalEnd = index(after: lineEndIndex)
        while removalEnd < endIndex {
            let byte = self[removalEnd]
            guard byte == 0x0A || byte == 0x0D else {
                break
            }
            removalEnd = index(after: removalEnd)
        }
        removeSubrange(..<removalEnd)
    }
}
