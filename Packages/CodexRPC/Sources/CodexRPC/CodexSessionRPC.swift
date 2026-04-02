import Foundation
import SharedModels

public enum CodexSessionRPCError: LocalizedError, Sendable {
    case invalidResponse(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(message), let .invalidRequest(message):
            return message
        }
    }
}

public enum CodexSessionRPC {
    private static let maxLiveActivityDeltaCharacters = 16_384

    // Live runtime verification on 2026-04-22 (`Codex.app` bundled `codex-cli 0.122.0-alpha.13`)
    // showed that threads created through app-server currently surface as source `vscode`,
    // while raw CLI usage surfaces as source `cli`. The daily mobile browser should follow
    // the user-facing desktop/browser thread family, not every raw runtime session on disk.
    private static let browserThreadSourceKinds = ["vscode", "appServer"]

    public static func initializeRequest(id: Int, clientInfo: CodexRPCClientInfo) -> CodexRPCRequest<CodexRPCInitializeParams> {
        CodexRPCRequest(
            id: id,
            method: "initialize",
            params: CodexRPCInitializeParams(
                clientInfo: clientInfo,
                capabilities: CodexRPCInitializeCapabilities(experimentalApi: true)
            )
        )
    }

    public static func initializedNotification() -> CodexRPCInitializedNotification {
        CodexRPCInitializedNotification()
    }

    public static func startThreadRequest(id: Int, cwd: String, model: String?) -> CodexRPCRequest<JSONObjectEncodable> {
        startThreadRequest(
            id: id,
            options: CodexThreadExecutionOptions(
                cwd: cwd,
                model: model
            )
        )
    }

    public static func startThreadRequest(
        id: Int,
        options: CodexThreadExecutionOptions
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        var payload: [String: JSONValue] = [
            "experimentalRawEvents": .bool(false),
            "persistExtendedHistory": .bool(true)
        ]
        if let cwd = options.cwd {
            payload["cwd"] = .string(cwd)
        }
        if let model = options.model {
            payload["model"] = .string(model)
        }
        if let approvalPolicy = options.approvalPolicy {
            payload["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandboxMode = options.sandboxMode {
            payload["sandbox"] = .string(sandboxMode.rawValue)
        }

        return CodexRPCRequest(
            id: id,
            method: "thread/start",
            params: JSONObjectEncodable(value: payload)
        )
    }

    public static func decodeStartedThread(from response: CodexRPCResponseEnvelope) throws -> CodexThreadContext {
        guard let result = response.result,
              let object = result.objectValue,
              let threadObject = object["thread"]?.objectValue,
              let threadID = threadObject["id"]?.stringValue,
              let resolvedCWD = object["cwd"]?.stringValue else {
            throw CodexSessionRPCError.invalidResponse("Missing thread/start result.")
        }

        return CodexThreadContext(
            id: threadID,
            cwd: resolvedCWD,
            model: object["model"]?.stringValue,
            reasoningEffort: decodeReasoningEffort(from: object),
            executionProfile: decodeEffectiveExecutionProfile(from: object)
        )
    }

    public static func resumeThreadRequest(
        id: Int,
        threadID: String,
        cwd: String?,
        model: String?
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        resumeThreadRequest(
            id: id,
            threadID: threadID,
            options: CodexThreadExecutionOptions(
                cwd: cwd,
                model: model
            )
        )
    }

    public static func resumeThreadRequest(
        id: Int,
        threadID: String,
        options: CodexThreadExecutionOptions
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        var payload: [String: JSONValue] = [
            "threadId": .string(threadID),
            "persistExtendedHistory": .bool(true)
        ]
        if let cwd = options.cwd {
            payload["cwd"] = .string(cwd)
        }
        if let model = options.model {
            payload["model"] = .string(model)
        }
        if let approvalPolicy = options.approvalPolicy {
            payload["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandboxMode = options.sandboxMode {
            payload["sandbox"] = .string(sandboxMode.rawValue)
        }

        return CodexRPCRequest(
            id: id,
            method: "thread/resume",
            params: JSONObjectEncodable(value: payload)
        )
    }

    public static func decodeResumedThread(from response: CodexRPCResponseEnvelope) throws -> CodexResumedThreadContext {
        guard let resultObject = response.result?.objectValue,
              let threadValue = resultObject["thread"] else {
            throw CodexSessionRPCError.invalidResponse("Missing thread/resume result.")
        }

        let snapshot: CodexThreadSnapshot
        do {
            snapshot = try CodexThreadCodec.decodeThreadSnapshot(from: threadValue)
        } catch {
            throw CodexSessionRPCError.invalidResponse(error.localizedDescription)
        }

        return CodexResumedThreadContext(
            thread: snapshot,
            cwd: resultObject["cwd"]?.stringValue ?? snapshot.cwd,
            model: resultObject["model"]?.stringValue,
            reasoningEffort: decodeReasoningEffort(from: resultObject),
            executionProfile: decodeEffectiveExecutionProfile(from: resultObject)
        )
    }

    public static func readThreadRequest(
        id: Int,
        threadID: String,
        includeTurns: Bool
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "thread/read",
            params: JSONObjectEncodable(value: [
                "threadId": .string(threadID),
                "includeTurns": .bool(includeTurns)
            ])
        )
    }

    public static func decodeThreadSnapshot(from response: CodexRPCResponseEnvelope) throws -> CodexThreadSnapshot {
        guard let threadValue = response.result?.objectValue?["thread"] else {
            throw CodexSessionRPCError.invalidResponse("Missing thread/read result.")
        }

        do {
            return try CodexThreadCodec.decodeThreadSnapshot(from: threadValue)
        } catch {
            throw CodexSessionRPCError.invalidResponse(error.localizedDescription)
        }
    }

    public static func listThreadsRequest(
        id: Int,
        cwd: String?,
        limit: Int?,
        cursor: String?,
        sortKey: String?,
        searchTerm: String?
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        var payload: [String: JSONValue] = [
            "sourceKinds": .array(browserThreadSourceKinds.map(JSONValue.string))
        ]
        if let cwd {
            payload["cwd"] = .string(cwd)
        }
        if let limit {
            payload["limit"] = .number(Double(limit))
        }
        if let cursor {
            payload["cursor"] = .string(cursor)
        }
        if let sortKey {
            payload["sortKey"] = .string(sortKey)
        }
        if let searchTerm {
            payload["searchTerm"] = .string(searchTerm)
        }

        return CodexRPCRequest(
            id: id,
            method: "thread/list",
            params: JSONObjectEncodable(value: payload)
        )
    }

    public static func decodeThreadListPage(from response: CodexRPCResponseEnvelope) throws -> CodexThreadListPage {
        guard let resultObject = response.result?.objectValue else {
            throw CodexSessionRPCError.invalidResponse("Missing thread/list result.")
        }

        do {
            return try CodexThreadCodec.decodeThreadListPage(from: resultObject)
        } catch {
            throw CodexSessionRPCError.invalidResponse(error.localizedDescription)
        }
    }

    public static func startTurnRequest(
        id: Int,
        threadID: String,
        input: [CodexUserInput],
        model: String?,
        effort: CodexReasoningEffort?,
        collaborationMode: CodexCollaborationMode?
    ) throws -> CodexRPCRequest<JSONObjectEncodable> {
        try startTurnRequest(
            id: id,
            threadID: threadID,
            input: input,
            options: CodexTurnExecutionOptions(
                model: model,
                effort: effort,
                collaborationMode: collaborationMode
            )
        )
    }

    public static func startTurnRequest(
        id: Int,
        threadID: String,
        input: [CodexUserInput],
        options: CodexTurnExecutionOptions
    ) throws -> CodexRPCRequest<JSONObjectEncodable> {
        guard !input.isEmpty else {
            throw CodexSessionRPCError.invalidRequest("turn/start requires at least one input item.")
        }

        var payload: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input.map(\.jsonValue))
        ]
        if let cwd = options.cwd {
            payload["cwd"] = .string(cwd)
        }
        if let model = options.model {
            payload["model"] = .string(model)
        }
        if let approvalPolicy = options.approvalPolicy {
            payload["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandboxPolicy = options.sandboxPolicy {
            payload["sandboxPolicy"] = sandboxPolicy.jsonValue
        }
        if let effort = options.effort {
            payload["effort"] = .string(effort.rawValue)
        }
        if let collaborationMode = options.collaborationMode {
            payload["collaborationMode"] = collaborationMode.jsonValue
        }

        return CodexRPCRequest(
            id: id,
            method: "turn/start",
            params: JSONObjectEncodable(value: payload)
        )
    }

    public static func decodeStartedTurn(from response: CodexRPCResponseEnvelope) throws -> CodexTurnContext {
        guard let result = response.result,
              let turn = result.objectValue?["turn"]?.objectValue,
              let turnID = turn["id"]?.stringValue,
              let status = turn["status"]?.stringValue else {
            throw CodexSessionRPCError.invalidResponse("Missing turn/start result.")
        }

        return CodexTurnContext(id: turnID, status: status)
    }

    public static func readConfigRequest(id: Int) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "config/read",
            params: JSONObjectEncodable(value: [:])
        )
    }

    public static func decodeBaselineConfigSnapshot(from response: CodexRPCResponseEnvelope) throws -> CodexExecutionBaselineConfigSnapshot {
        guard let config = response.result?.objectValue?["config"]?.objectValue else {
            throw CodexSessionRPCError.invalidResponse("Missing config/read result.")
        }

        let sandboxMode = config["sandbox_mode"]?.stringValue
        let workspaceWrite = config["sandbox_workspace_write"]?.objectValue
        return CodexExecutionBaselineConfigSnapshot(
            approvalPolicy: config["approval_policy"]?.stringValue,
            sandboxMode: sandboxMode,
            writableRoots: workspaceWrite?["writable_roots"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            networkAccess: workspaceWrite?["network_access"]?.boolValue
        )
    }

    public static func readConfigRequirementsRequest(id: Int) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "configRequirements/read",
            params: JSONObjectEncodable(value: [:])
        )
    }

    public static func decodeConfigRequirementsSnapshot(from response: CodexRPCResponseEnvelope) throws -> CodexExecutionConstraintsSnapshot {
        guard let requirements = response.result?.objectValue?["requirements"]?.objectValue else {
            return CodexExecutionConstraintsSnapshot()
        }

        return CodexExecutionConstraintsSnapshot(
            allowedApprovalPolicies: requirements["allowedApprovalPolicies"]?.arrayValue?.compactMap(\.stringValue),
            allowedSandboxModes: requirements["allowedSandboxModes"]?.arrayValue?.compactMap(\.stringValue),
            allowedWebSearchModes: requirements["allowedWebSearchModes"]?.arrayValue?.compactMap(\.stringValue),
            featureRequirements: requirements["featureRequirements"]?.objectValue?.reduce(into: [String: Bool]()) { partialResult, entry in
                if let value = entry.value.boolValue {
                    partialResult[entry.key] = value
                }
            },
            enforceResidency: requirements["enforceResidency"]?.stringValue
        )
    }

    public static func writeConfigValueRequest(
        id: Int,
        key: String,
        value: JSONValue
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "config/value/write",
            params: JSONObjectEncodable(value: [
                "key": .string(key),
                "value": value
            ])
        )
    }

    public static func listModelsRequest(id: Int) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "model/list",
            params: JSONObjectEncodable(value: [:])
        )
    }

    public static func decodeModels(from response: CodexRPCResponseEnvelope) throws -> [CodexModelDescriptor] {
        guard let data = response.result?.objectValue?["data"]?.arrayValue else {
            throw CodexSessionRPCError.invalidResponse("Missing model/list result.")
        }

        return try data.map(decodeModel)
            .filter { !$0.hidden }
    }

    public static func steerTurnRequest(
        id: Int,
        threadID: String,
        expectedTurnID: String,
        text: String
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "turn/steer",
            params: JSONObjectEncodable(value: [
                "threadId": .string(threadID),
                "expectedTurnId": .string(expectedTurnID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            ])
        )
    }

    public static func decodeSteeredTurn(from response: CodexRPCResponseEnvelope) throws -> CodexTurnContext {
        guard let turnID = response.result?.objectValue?["turnId"]?.stringValue else {
            throw CodexSessionRPCError.invalidResponse("Missing turn/steer result.")
        }

        return CodexTurnContext(id: turnID, status: "inProgress")
    }

    public static func interruptTurnRequest(
        id: Int,
        threadID: String,
        turnID: String
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "turn/interrupt",
            params: JSONObjectEncodable(value: [
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }

    public static func forkThreadRequest(
        id: Int,
        threadID: String,
        cwd: String?,
        model: String?
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        var payload: [String: JSONValue] = [
            "threadId": .string(threadID)
        ]
        if let cwd {
            payload["cwd"] = .string(cwd)
        }
        if let model {
            payload["model"] = .string(model)
        }

        return CodexRPCRequest(
            id: id,
            method: "thread/fork",
            params: JSONObjectEncodable(value: payload)
        )
    }

    public static func decodeForkedThread(from response: CodexRPCResponseEnvelope) throws -> CodexThreadContext {
        guard let result = response.result,
              let object = result.objectValue,
              let threadObject = object["thread"]?.objectValue,
              let forkedThreadID = threadObject["id"]?.stringValue,
              let resolvedCWD = object["cwd"]?.stringValue else {
            throw CodexSessionRPCError.invalidResponse("Missing thread/fork result.")
        }

        return CodexThreadContext(
            id: forkedThreadID,
            cwd: resolvedCWD,
            model: object["model"]?.stringValue,
            reasoningEffort: decodeReasoningEffort(from: object)
        )
    }

    public static func reviewStartRequest(
        id: Int,
        threadID: String,
        delivery: CodexReviewDelivery,
        target: CodexReviewTarget
    ) -> CodexRPCRequest<JSONObjectEncodable> {
        CodexRPCRequest(
            id: id,
            method: "review/start",
            params: JSONObjectEncodable(value: [
                "threadId": .string(threadID),
                "delivery": .string(delivery.rawValue),
                "target": reviewTargetValue(for: target)
            ])
        )
    }

    public static func decodeStartedReview(from response: CodexRPCResponseEnvelope) throws -> CodexReviewContext {
        guard let result = response.result?.objectValue,
              let reviewThreadID = result["reviewThreadId"]?.stringValue,
              let turn = result["turn"]?.objectValue,
              let turnID = turn["id"]?.stringValue,
              let status = turn["status"]?.stringValue else {
            throw CodexSessionRPCError.invalidResponse("Missing review/start result.")
        }

        return CodexReviewContext(
            reviewThreadID: reviewThreadID,
            turn: CodexTurnContext(id: turnID, status: status)
        )
    }

    public static func approvalResultEnvelope(
        request: CodexApprovalRequest,
        decision: CodexApprovalDecision
    ) -> CodexRPCResultEnvelope<JSONObjectEncodable> {
        CodexRPCResultEnvelope(
            id: request.id,
            result: JSONObjectEncodable(value: approvalResponseBody(for: request, decision: decision))
        )
    }

    public static func isServerInitiatedEnvelope(_ envelope: CodexRPCResponseEnvelope) -> Bool {
        envelope.method != nil
    }

    public static func liveEvent(from envelope: CodexRPCResponseEnvelope) -> CodexLiveEvent? {
        if let serverRequest = decodeServerRequest(from: envelope) {
            switch serverRequest {
            case let .approval(request):
                return .approvalRequested(request)
            case let .structuredUserInput(request):
                return .structuredUserInputRequested(request)
            case let .unsupported(request):
                return .serverRequestUnsupported(request)
            }
        }

        guard let method = envelope.method else {
            return nil
        }

        switch method {
        case "configWarning":
            return .configWarning(envelope.params?.objectValue?["summary"]?.stringValue ?? "Unknown config warning.")
        case "thread/started":
            if let threadID = envelope.params?.objectValue?["thread"]?.objectValue?["id"]?.stringValue {
                return .threadStarted(threadID)
            }
            return nil
        case "thread/status/changed":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            return .activity(
                CodexLiveActivityEvent(
                    kind: .threadStatusChanged,
                    threadID: params["threadId"]?.stringValue,
                    text: threadStatusSummary(params["status"]),
                    shouldRefreshThread: true
                )
            )
        case "thread/tokenUsage/updated":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            return .activity(
                CodexLiveActivityEvent(
                    kind: .tokenUsageUpdated,
                    threadID: params["threadId"]?.stringValue,
                    turnID: params["turnId"]?.stringValue
                )
            )
        case "turn/started":
            if let turnID = envelope.params?.objectValue?["turn"]?.objectValue?["id"]?.stringValue {
                return .turnStarted(turnID)
            }
            return nil
        case "turn/completed":
            if let turnID = envelope.params?.objectValue?["turn"]?.objectValue?["id"]?.stringValue {
                return .turnCompleted(turnID)
            }
            return nil
        case "turn/diff/updated":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            return .activity(
                CodexLiveActivityEvent(
                    kind: .turnDiffUpdated,
                    threadID: params["threadId"]?.stringValue,
                    turnID: params["turnId"]?.stringValue,
                    text: params["diff"]?.stringValue,
                    shouldRefreshThread: true
                )
            )
        case "turn/plan/updated":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            return .activity(
                CodexLiveActivityEvent(
                    kind: .turnPlanUpdated,
                    threadID: params["threadId"]?.stringValue,
                    turnID: params["turnId"]?.stringValue,
                    text: planSummary(from: params),
                    shouldRefreshThread: true
                )
            )
        case "item/started":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            let item = params["item"]?.objectValue
            return .activity(
                CodexLiveActivityEvent(
                    kind: .itemStarted,
                    threadID: params["threadId"]?.stringValue,
                    turnID: params["turnId"]?.stringValue,
                    itemID: item?["id"]?.stringValue,
                    itemType: item?["type"]?.stringValue
                )
            )
        case "item/agentMessage/delta":
            if let delta = envelope.params?.objectValue?["delta"]?.stringValue {
                return .agentMessageDelta(delta)
            }
            return nil
        case "item/plan/delta":
            return threadScopedDeltaActivity(from: envelope, kind: .planDelta)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return threadScopedDeltaActivity(from: envelope, kind: .reasoningDelta)
        case "item/commandExecution/outputDelta":
            return threadScopedDeltaActivity(from: envelope, kind: .commandExecutionOutputDelta)
        case "item/fileChange/outputDelta":
            return threadScopedDeltaActivity(from: envelope, kind: .fileChangeOutputDelta)
        case "item/fileChange/patchUpdated":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            return .activity(
                CodexLiveActivityEvent(
                    kind: .fileChangePatchUpdated,
                    threadID: params["threadId"]?.stringValue,
                    turnID: params["turnId"]?.stringValue,
                    itemID: params["itemId"]?.stringValue,
                    shouldRefreshThread: true
                )
            )
        case "item/completed":
            if let item = envelope.params?.objectValue?["item"]?.objectValue,
               item["type"]?.stringValue == "agentMessage",
               let text = item["text"]?.stringValue {
                return .agentMessageCompleted(text)
            }
            if let params = envelope.params?.objectValue {
                let item = params["item"]?.objectValue
                return .activity(
                    CodexLiveActivityEvent(
                        kind: .itemCompleted,
                        threadID: params["threadId"]?.stringValue,
                        turnID: params["turnId"]?.stringValue,
                        itemID: item?["id"]?.stringValue,
                        itemType: item?["type"]?.stringValue,
                        shouldRefreshThread: true
                    )
                )
            }
            return nil
        case "rawResponseItem/completed":
            guard let params = envelope.params?.objectValue else {
                return nil
            }
            return .activity(
                CodexLiveActivityEvent(
                    kind: .rawResponseItemCompleted,
                    threadID: params["threadId"]?.stringValue,
                    turnID: params["turnId"]?.stringValue,
                    shouldRefreshThread: true
                )
            )
        case "warning", "guardianWarning", "deprecationNotice":
            let params = envelope.params?.objectValue
            return .configWarning(
                params?["message"]?.stringValue
                    ?? params?["summary"]?.stringValue
                    ?? params?["text"]?.stringValue
                    ?? "Host runtime warning."
            )
        case "error":
            let params = envelope.params?.objectValue
            let message = params?["error"]?.objectValue?["message"]?.stringValue
                ?? params?["message"]?.stringValue
                ?? "Unknown protocol error."
            let willRetry = params?["willRetry"]?.boolValue ?? false
            return willRetry ? .configWarning(retryingRuntimeWarningText(message)) : .error(message)
        default:
            return nil
        }
    }

    private static func retryingRuntimeWarningText(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Mac-side Codex retry."
        }
        guard !trimmed.lowercased().hasPrefix("mac-side codex retry:") else {
            return trimmed
        }
        return "Mac-side Codex retry: \(trimmed)"
    }

    private static func threadScopedDeltaActivity(
        from envelope: CodexRPCResponseEnvelope,
        kind: CodexLiveActivityEvent.Kind
    ) -> CodexLiveEvent? {
        guard let params = envelope.params?.objectValue,
              let delta = params["delta"]?.stringValue else {
            return nil
        }

        return .activity(
            CodexLiveActivityEvent(
                kind: kind,
                threadID: params["threadId"]?.stringValue,
                turnID: params["turnId"]?.stringValue,
                itemID: params["itemId"]?.stringValue,
                text: liveActivityDisplayDelta(delta, kind: kind)
            )
        )
    }

    private static func liveActivityDisplayDelta(
        _ delta: String,
        kind: CodexLiveActivityEvent.Kind
    ) -> String {
        switch kind {
        case .commandExecutionOutputDelta, .fileChangeOutputDelta:
            return truncatedLiveActivityDelta(delta)
        case .threadStatusChanged, .tokenUsageUpdated, .itemStarted, .itemCompleted, .planDelta,
             .reasoningDelta, .fileChangePatchUpdated, .turnDiffUpdated, .turnPlanUpdated,
             .rawResponseItemCompleted:
            return delta
        }
    }

    private static func truncatedLiveActivityDelta(_ delta: String) -> String {
        guard delta.count > maxLiveActivityDeltaCharacters else {
            return delta
        }

        let omittedCharacters = delta.count - maxLiveActivityDeltaCharacters
        return """
        \(delta.prefix(maxLiveActivityDeltaCharacters))

        ... \(omittedCharacters) characters omitted from the iPhone live mirror. Open Codex on the Mac for the full output.
        """
    }

    private static func threadStatusSummary(_ value: JSONValue?) -> String? {
        guard let object = value?.objectValue,
              let type = object["type"]?.stringValue else {
            return value?.stringValue
        }

        if type == "active" {
            let flags = object["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return flags.isEmpty ? "Thread is active." : "Thread is active: \(flags.joined(separator: ", "))."
        }

        if type == "systemError" {
            return "Thread reported a system error."
        }

        return nil
    }

    private static func planSummary(from params: [String: JSONValue]) -> String? {
        let explanation = params["explanation"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = params["plan"]?.arrayValue?.compactMap { value -> String? in
            guard let object = value.objectValue else {
                return nil
            }
            let status = object["status"]?.stringValue
            let step = object["step"]?.stringValue
                ?? object["text"]?.stringValue
                ?? object["description"]?.stringValue
            guard let step,
                  !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if let status,
               !status.isEmpty {
                return "- [\(status)] \(step)"
            }
            return "- \(step)"
        } ?? []

        let parts = ([explanation].compactMap { $0 } + steps)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public static func decodeServerRequest(from envelope: CodexRPCResponseEnvelope) -> CodexServerRequest? {
        if let approvalRequest = decodeApprovalRequest(from: envelope) {
            return .approval(approvalRequest)
        }

        if let structuredUserInput = decodeStructuredUserInputRequest(from: envelope) {
            return .structuredUserInput(structuredUserInput)
        }

        guard let id = envelope.id,
              let method = envelope.method else {
            return nil
        }

        return .unsupported(
            CodexUnhandledServerRequest(
                id: id,
                method: method,
                threadID: envelope.params?.objectValue?["threadId"]?.stringValue
                    ?? envelope.params?.objectValue?["conversationId"]?.stringValue,
                turnID: envelope.params?.objectValue?["turnId"]?.stringValue
            )
        )
    }

    public static func decodeModel(_ value: JSONValue) throws -> CodexModelDescriptor {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let model = object["model"]?.stringValue else {
            throw CodexSessionRPCError.invalidResponse("Malformed model/list item.")
        }
        let displayName = object["displayName"]?.stringValue ?? model
        let description = object["description"]?.stringValue ?? ""

        let supportedReasoningEfforts = (object["supportedReasoningEfforts"]?.arrayValue ?? [])
            .compactMap { option -> CodexModelReasoningOption? in
                guard let optionObject = option.objectValue,
                      let effort = optionObject["reasoningEffort"]?.stringValue.flatMap(CodexReasoningEffort.init(rawValue:)),
                      let description = optionObject["description"]?.stringValue else {
                    return nil
                }
                return CodexModelReasoningOption(effort: effort, description: description)
            }

        return CodexModelDescriptor(
            id: id,
            model: model,
            displayName: displayName,
            description: description,
            isDefault: object["isDefault"]?.boolValue ?? false,
            hidden: object["hidden"]?.boolValue ?? false,
            inputModalities: (object["inputModalities"]?.arrayValue ?? [.string("text"), .string("image")])
                .compactMap { $0.stringValue }
                .compactMap(CodexInputModality.init(rawValue:)),
            defaultReasoningEffort: object["defaultReasoningEffort"]?.stringValue
                .flatMap(CodexReasoningEffort.init(rawValue:)) ?? .medium,
            supportedReasoningEfforts: supportedReasoningEfforts.isEmpty
                ? [
                    .init(effort: .low, description: "Fast"),
                    .init(effort: .medium, description: "Balanced"),
                    .init(effort: .high, description: "Deep"),
                    .init(effort: .xhigh, description: "Extra deep")
                ]
                : supportedReasoningEfforts,
            supportsPersonality: object["supportsPersonality"]?.boolValue ?? false
        )
    }

    private static func decodeEffectiveExecutionProfile(from object: [String: JSONValue]) -> CodexExecutionProfile {
        let sandbox = decodeSandbox(object["sandbox"]?.objectValue)
        return CodexExecutionProfile(
            approvalPolicy: CodexExecutionAuthority(
                effective: object["approvalPolicy"]?.stringValue,
                status: object["approvalPolicy"]?.stringValue == nil ? .unknown : .effective
            ),
            sandboxMode: CodexExecutionAuthority(
                effective: sandbox?.sandboxMode,
                status: sandbox?.sandboxMode == nil ? .unknown : .effective
            ),
            writableRoots: CodexExecutionAuthority(
                effective: sandbox?.writableRoots,
                status: sandbox?.writableRoots == nil ? .unknown : .effective
            ),
            extraReadableRoots: CodexExecutionAuthority(
                effective: sandbox?.extraReadableRoots,
                status: sandbox?.extraReadableRoots == nil ? .unknown : .effective
            ),
            readAccess: CodexExecutionAuthority(
                effective: sandbox?.readAccess ?? .unknown,
                status: sandbox == nil ? .unknown : .effective
            ),
            networkAccess: CodexExecutionAuthority(
                effective: sandbox?.networkAccess,
                status: sandbox?.networkAccess == nil ? .unknown : .effective
            )
        )
    }

    private static func decodeReasoningEffort(from object: [String: JSONValue]) -> CodexReasoningEffort? {
        object["reasoningEffort"]?.stringValue.flatMap(CodexReasoningEffort.init(rawValue:))
            ?? object["reasoning_effort"]?.stringValue.flatMap(CodexReasoningEffort.init(rawValue:))
    }

    public static func structuredUserInputResultEnvelope(
        request: CodexStructuredUserInputRequest,
        answersByQuestionID: [String: [String]]
    ) -> CodexRPCResultEnvelope<JSONObjectEncodable> {
        let answerObject = answersByQuestionID.reduce(into: [String: JSONValue]()) { partialResult, entry in
            partialResult[entry.key] = .object([
                "answers": .array(entry.value.map(JSONValue.string))
            ])
        }

        return CodexRPCResultEnvelope(
            id: request.id,
            result: JSONObjectEncodable(value: [
                "answers": .object(answerObject)
            ])
        )
    }

    public static func unsupportedServerRequestErrorEnvelope(
        id: CodexRPCIdentifier,
        method: String
    ) -> CodexRPCErrorEnvelope {
        CodexRPCErrorEnvelope(
            id: id,
            error: RPCErrorPayload(
                code: -32601,
                message: "Client does not support server request \(method)."
            )
        )
    }

    private static func decodeSandbox(_ object: [String: JSONValue]?) -> (
        sandboxMode: String?,
        writableRoots: [String],
        extraReadableRoots: [String],
        readAccess: CodexReadAccessKind,
        networkAccess: Bool?
    )? {
        guard let object,
              let type = object["type"]?.stringValue else {
            return nil
        }

        switch type {
        case "dangerFullAccess":
            return ("danger-full-access", [], [], .fullAccess, true)
        case "readOnly":
            let access = decodeReadAccess(object["access"]?.objectValue)
            return ("read-only", [], access.roots, access.kind, object["networkAccess"]?.boolValue)
        case "workspaceWrite":
            let access = decodeReadAccess(object["readOnlyAccess"]?.objectValue)
            return (
                "workspace-write",
                object["writableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                access.roots,
                access.kind,
                object["networkAccess"]?.boolValue
            )
        case "externalSandbox":
            return (
                type,
                [],
                [],
                .unknown,
                object["networkAccess"]?.objectValue?["enabled"]?.boolValue
            )
        default:
            return (type, [], [], .unknown, nil)
        }
    }

    private static func decodeReadAccess(_ object: [String: JSONValue]?) -> (kind: CodexReadAccessKind, roots: [String]) {
        guard let object,
              let type = object["type"]?.stringValue else {
            return (.unknown, [])
        }

        switch type {
        case "fullAccess":
            return (.fullAccess, [])
        case "restricted":
            return (
                .restricted,
                object["readableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        default:
            return (.unknown, [])
        }
    }

    private static func reviewTargetValue(for target: CodexReviewTarget) -> JSONValue {
        switch target {
        case .uncommittedChanges:
            return .object(["type": .string("uncommittedChanges")])
        case let .baseBranch(branch):
            return .object([
                "type": .string("baseBranch"),
                "branch": .string(branch)
            ])
        case let .commit(sha, title):
            var value: [String: JSONValue] = [
                "type": .string("commit"),
                "sha": .string(sha)
            ]
            if let title {
                value["title"] = .string(title)
            }
            return .object(value)
        case let .custom(instructions):
            return .object([
                "type": .string("custom"),
                "instructions": .string(instructions)
            ])
        }
    }

    private static func decodeApprovalRequest(from envelope: CodexRPCResponseEnvelope) -> CodexApprovalRequest? {
        guard let id = envelope.id,
              let method = envelope.method,
              let params = envelope.params?.objectValue else {
            return nil
        }

        switch method {
        case "item/commandExecution/requestApproval":
            guard let threadID = params["threadId"]?.stringValue,
                  let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue else {
                return nil
            }
            return CodexApprovalRequest(
                id: id,
                kind: .commandExecution,
                method: .commandExecutionRequestApproval,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                approvalID: params["approvalId"]?.stringValue,
                summary: params["command"]?.stringValue ?? "Approve the requested command execution.",
                reason: params["reason"]?.stringValue
            )
        case "item/fileChange/requestApproval":
            guard let threadID = params["threadId"]?.stringValue,
                  let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue else {
                return nil
            }
            let grantRoot = params["grantRoot"]?.stringValue
            let summary = grantRoot.map { "Approve file changes under \($0)." } ?? "Approve the requested file changes."
            return CodexApprovalRequest(
                id: id,
                kind: .fileChange,
                method: .fileChangeRequestApproval,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                summary: summary,
                reason: params["reason"]?.stringValue
            )
        case "item/permissions/requestApproval":
            guard let threadID = params["threadId"]?.stringValue,
                  let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue else {
                return nil
            }
            let requested = decodeRequestedPermissions(from: params["permissions"]?.objectValue)
            return CodexApprovalRequest(
                id: id,
                kind: .permissions,
                method: .permissionsRequestApproval,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                summary: "Approve the requested additional permissions.",
                reason: params["reason"]?.stringValue,
                requestedPermissions: requested
            )
        case "execCommandApproval":
            guard let threadID = params["conversationId"]?.stringValue,
                  let callID = params["callId"]?.stringValue else {
                return nil
            }
            return CodexApprovalRequest(
                id: id,
                kind: .commandExecution,
                method: .execCommandApproval,
                threadID: threadID,
                turnID: nil,
                itemID: callID,
                approvalID: params["approvalId"]?.stringValue,
                summary: legacyCommandApprovalSummary(from: params),
                reason: params["reason"]?.stringValue
            )
        case "applyPatchApproval":
            guard let threadID = params["conversationId"]?.stringValue,
                  let callID = params["callId"]?.stringValue else {
                return nil
            }
            return CodexApprovalRequest(
                id: id,
                kind: .fileChange,
                method: .applyPatchApproval,
                threadID: threadID,
                turnID: nil,
                itemID: callID,
                summary: legacyPatchApprovalSummary(from: params),
                reason: params["reason"]?.stringValue
            )
        default:
            return nil
        }
    }

    private static func decodeStructuredUserInputRequest(from envelope: CodexRPCResponseEnvelope) -> CodexStructuredUserInputRequest? {
        guard let id = envelope.id,
              envelope.method == "item/tool/requestUserInput",
              let params = envelope.params?.objectValue,
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let itemID = params["itemId"]?.stringValue,
              let questionValues = params["questions"]?.arrayValue else {
            return nil
        }

        let questions = questionValues.compactMap(decodeStructuredQuestion)
        let prompt = SessionStructuredPrompt(requestID: id.stringValue, questions: questions)
        return CodexStructuredUserInputRequest(
            id: id,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            prompt: prompt
        )
    }

    private static func decodeStructuredQuestion(_ value: JSONValue) -> SessionStructuredQuestion? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let prompt = object["question"]?.stringValue ?? object["header"]?.stringValue else {
            return nil
        }

        let options = object["options"]?.arrayValue?.compactMap { optionValue -> SessionStructuredOption? in
            guard let optionObject = optionValue.objectValue,
                  let label = optionObject["label"]?.stringValue else {
                return nil
            }
            return SessionStructuredOption(
                label: label,
                detail: optionObject["description"]?.stringValue
            )
        } ?? []

        return SessionStructuredQuestion(
            id: id,
            prompt: prompt,
            options: options,
            allowsCustomAnswer: object["isOther"]?.boolValue ?? false,
            customAnswerPlaceholder: object["isSecret"]?.boolValue == true ? "Secret answer" : nil
        )
    }

    private static func decodeRequestedPermissions(from object: [String: JSONValue]?) -> CodexRequestedPermissions {
        let fileSystem = object?["fileSystem"]?.objectValue
        let readRoots = fileSystem?["read"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let writeRoots = fileSystem?["write"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let networkEnabled = object?["network"]?.objectValue?["enabled"]?.boolValue
        return CodexRequestedPermissions(
            readRoots: readRoots,
            writeRoots: writeRoots,
            networkEnabled: networkEnabled
        )
    }

    private static func legacyCommandApprovalSummary(from params: [String: JSONValue]) -> String {
        let command = params["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !command.isEmpty {
            return command.joined(separator: " ")
        }
        return "Approve the requested command execution."
    }

    private static func legacyPatchApprovalSummary(from params: [String: JSONValue]) -> String {
        if let grantRoot = params["grantRoot"]?.stringValue {
            return "Approve file changes under \(grantRoot)."
        }

        let fileCount = params["fileChanges"]?.objectValue?.count ?? 0
        if fileCount == 1,
           let filePath = params["fileChanges"]?.objectValue?.keys.first {
            return "Approve file changes to \(filePath)."
        }
        if fileCount > 1 {
            return "Approve file changes to \(fileCount) files."
        }
        return "Approve the requested file changes."
    }

    private static func approvalResponseBody(
        for request: CodexApprovalRequest,
        decision: CodexApprovalDecision
    ) -> [String: JSONValue] {
        switch request.method {
        case .commandExecutionRequestApproval, .fileChangeRequestApproval:
            return [
                "decision": approvalDecisionValue(decision)
            ]
        case .permissionsRequestApproval:
            return permissionDecisionValue(for: request, decision: decision)
        case .execCommandApproval, .applyPatchApproval:
            return [
                "decision": legacyApprovalDecisionValue(decision)
            ]
        }
    }

    private static func approvalDecisionValue(_ decision: CodexApprovalDecision) -> JSONValue {
        switch decision {
        case .accept:
            return .string("accept")
        case .acceptForSession:
            return .string("acceptForSession")
        case .decline:
            return .string("decline")
        case .cancel:
            return .string("cancel")
        case .grantRequestedPermissions:
            return .string("accept")
        case .denyPermissions:
            return .string("decline")
        }
    }

    private static func legacyApprovalDecisionValue(_ decision: CodexApprovalDecision) -> JSONValue {
        switch decision {
        case .accept:
            return .string("approved")
        case .acceptForSession:
            return .string("approved_for_session")
        case .decline, .denyPermissions:
            return .string("denied")
        case .cancel:
            return .string("abort")
        case let .grantRequestedPermissions(scopeSession):
            return .string(scopeSession ? "approved_for_session" : "approved")
        }
    }

    private static func permissionDecisionValue(
        for request: CodexApprovalRequest,
        decision: CodexApprovalDecision
    ) -> [String: JSONValue] {
        switch decision {
        case let .grantRequestedPermissions(scopeSession):
            let requested = request.requestedPermissions ?? CodexRequestedPermissions()
            return [
                "permissions": .object([
                    "fileSystem": .object([
                        "read": .array(requested.readRoots.map(JSONValue.string)),
                        "write": .array(requested.writeRoots.map(JSONValue.string))
                    ]),
                    "network": .object([
                        "enabled": requested.networkEnabled.map(JSONValue.bool) ?? .null
                    ])
                ]),
                "scope": .string(scopeSession ? "session" : "turn")
            ]
        case .denyPermissions, .decline, .cancel:
            return [
                "permissions": .object([:]),
                "scope": .string("turn")
            ]
        case .accept, .acceptForSession:
            return permissionDecisionValue(
                for: request,
                decision: .grantRequestedPermissions(scopeSession: decision == .acceptForSession)
            )
        }
    }
}
