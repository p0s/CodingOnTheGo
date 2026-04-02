import Foundation
import SharedModels

public struct CodexRPCClientInfo: Codable, Hashable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public enum CodexReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public enum CodexCollaborationModeKind: String, Codable, CaseIterable, Sendable {
    case plan
    case `default`
}

public struct CodexCollaborationMode: Hashable, Codable, Sendable {
    public var mode: CodexCollaborationModeKind
    public var model: String
    public var reasoningEffort: CodexReasoningEffort?
    public var developerInstructions: String?

    public init(
        mode: CodexCollaborationModeKind,
        model: String,
        reasoningEffort: CodexReasoningEffort? = nil,
        developerInstructions: String? = nil
    ) {
        self.mode = mode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.developerInstructions = developerInstructions
    }

    public var jsonValue: JSONValue {
        var settings: [String: JSONValue] = [
            "model": .string(model)
        ]
        if let reasoningEffort {
            settings["reasoning_effort"] = .string(reasoningEffort.rawValue)
        }
        if let developerInstructions {
            settings["developer_instructions"] = .string(developerInstructions)
        }

        return .object([
            "mode": .string(mode.rawValue),
            "settings": .object(settings)
        ])
    }
}

public enum CodexInputModality: String, Codable, CaseIterable, Sendable {
    case text
    case image
}

public enum CodexUserInput: Hashable, Sendable {
    case text(String)
    case image(url: String)
    case localImage(path: String)

    public var jsonValue: JSONValue {
        switch self {
        case let .text(value):
            return .object([
                "type": .string("text"),
                "text": .string(value)
            ])
        case let .image(url):
            return .object([
                "type": .string("image"),
                "url": .string(url)
            ])
        case let .localImage(path):
            return .object([
                "type": .string("localImage"),
                "path": .string(path)
            ])
        }
    }
}

public struct CodexModelReasoningOption: Hashable, Codable, Sendable {
    public var effort: CodexReasoningEffort
    public var description: String

    public init(effort: CodexReasoningEffort, description: String) {
        self.effort = effort
        self.description = description
    }
}

public struct CodexModelDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var model: String
    public var displayName: String
    public var description: String
    public var isDefault: Bool
    public var hidden: Bool
    public var inputModalities: [CodexInputModality]
    public var defaultReasoningEffort: CodexReasoningEffort
    public var supportedReasoningEfforts: [CodexModelReasoningOption]
    public var supportsPersonality: Bool

    public init(
        id: String,
        model: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        hidden: Bool,
        inputModalities: [CodexInputModality] = [.text, .image],
        defaultReasoningEffort: CodexReasoningEffort,
        supportedReasoningEfforts: [CodexModelReasoningOption],
        supportsPersonality: Bool = false
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.hidden = hidden
        self.inputModalities = inputModalities
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsPersonality = supportsPersonality
    }

    public var supportsImageInputs: Bool {
        inputModalities.contains(.image)
    }
}

public enum CodexReviewDelivery: String, Codable, CaseIterable, Sendable {
    case inline
    case detached
}

public enum CodexReviewTarget: Hashable, Sendable {
    case uncommittedChanges
    case baseBranch(String)
    case commit(sha: String, title: String? = nil)
    case custom(String)
}

public struct CodexReviewContext: Hashable, Sendable {
    public var reviewThreadID: String
    public var turn: CodexTurnContext

    public init(reviewThreadID: String, turn: CodexTurnContext) {
        self.reviewThreadID = reviewThreadID
        self.turn = turn
    }
}

public enum CodexThreadRuntimeStatus: Hashable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active(activeFlags: [String])

    public var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }
}

public enum CodexThreadMessagePhase: String, Codable, Hashable, Sendable {
    case commentary
    case finalAnswer = "final_answer"
}

public enum CodexThreadItemSnapshot: Hashable, Sendable {
    case userMessage(String)
    case assistantMessage(String, phase: CodexThreadMessagePhase?)
    case reasoning(String)
    case plan(String)
    case commandExecution(summary: String, status: String)
    case fileChange(summary: String, status: String)
    case toolCall(String)
    case other(String)
}

public struct CodexThreadTurnSnapshot: Hashable, Sendable {
    public var id: String
    public var status: String
    public var items: [CodexThreadItemSnapshot]

    public init(
        id: String,
        status: String,
        items: [CodexThreadItemSnapshot]
    ) {
        self.id = id
        self.status = status
        self.items = items
    }

    public var isInProgress: Bool {
        status == "inProgress"
    }
}

public struct CodexThreadSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var cwd: String
    public var preview: String
    public var modelProvider: String
    public var name: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: CodexThreadRuntimeStatus

    public init(
        id: String,
        cwd: String,
        preview: String,
        modelProvider: String,
        name: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        status: CodexThreadRuntimeStatus
    ) {
        self.id = id
        self.cwd = cwd
        self.preview = preview
        self.modelProvider = modelProvider
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }
}

public struct CodexThreadSnapshot: Hashable, Sendable {
    public var summary: CodexThreadSummary
    public var turns: [CodexThreadTurnSnapshot]

    public init(summary: CodexThreadSummary, turns: [CodexThreadTurnSnapshot]) {
        self.summary = summary
        self.turns = turns
    }

    public var id: String { summary.id }
    public var cwd: String { summary.cwd }
    public var preview: String { summary.preview }
    public var modelProvider: String { summary.modelProvider }
    public var name: String? { summary.name }
    public var createdAt: Date { summary.createdAt }
    public var updatedAt: Date { summary.updatedAt }
    public var status: CodexThreadRuntimeStatus { summary.status }

    public var latestTurnID: String? {
        turns.last?.id
    }

    public var activeTurnID: String? {
        turns.reversed().first(where: \.isInProgress)?.id
    }
}

public struct CodexThreadListPage: Hashable, Sendable {
    public var threads: [CodexThreadSummary]
    public var nextCursor: String?

    public init(threads: [CodexThreadSummary], nextCursor: String?) {
        self.threads = threads
        self.nextCursor = nextCursor
    }
}

public struct CodexResumedThreadContext: Hashable, Sendable {
    public var thread: CodexThreadSnapshot
    public var cwd: String
    public var model: String?
    public var reasoningEffort: CodexReasoningEffort?
    public var executionProfile: CodexExecutionProfile?

    public init(
        thread: CodexThreadSnapshot,
        cwd: String,
        model: String?,
        reasoningEffort: CodexReasoningEffort? = nil,
        executionProfile: CodexExecutionProfile? = nil
    ) {
        self.thread = thread
        self.cwd = cwd
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.executionProfile = executionProfile
    }
}

public struct CodexRequestedPermissions: Hashable, Sendable {
    public var readRoots: [String]
    public var writeRoots: [String]
    public var networkEnabled: Bool?

    public init(readRoots: [String] = [], writeRoots: [String] = [], networkEnabled: Bool? = nil) {
        self.readRoots = readRoots
        self.writeRoots = writeRoots
        self.networkEnabled = networkEnabled
    }
}

public enum CodexApprovalRequestKind: String, Codable, Sendable {
    case commandExecution
    case fileChange
    case permissions
}

public enum CodexApprovalRequestMethod: String, Codable, Sendable {
    case commandExecutionRequestApproval = "item/commandExecution/requestApproval"
    case fileChangeRequestApproval = "item/fileChange/requestApproval"
    case permissionsRequestApproval = "item/permissions/requestApproval"
    case execCommandApproval
    case applyPatchApproval
}

public extension CodexApprovalRequestKind {
    var defaultMethod: CodexApprovalRequestMethod {
        switch self {
        case .commandExecution:
            return .commandExecutionRequestApproval
        case .fileChange:
            return .fileChangeRequestApproval
        case .permissions:
            return .permissionsRequestApproval
        }
    }
}

public struct CodexApprovalRequest: Identifiable, Hashable, Sendable {
    public var id: CodexRPCIdentifier
    public var kind: CodexApprovalRequestKind
    public var method: CodexApprovalRequestMethod
    public var threadID: String
    public var turnID: String?
    public var itemID: String
    public var approvalID: String?
    public var summary: String
    public var reason: String?
    public var requestedPermissions: CodexRequestedPermissions?

    public init(
        id: CodexRPCIdentifier,
        kind: CodexApprovalRequestKind,
        method: CodexApprovalRequestMethod? = nil,
        threadID: String,
        turnID: String? = nil,
        itemID: String,
        approvalID: String? = nil,
        summary: String,
        reason: String? = nil,
        requestedPermissions: CodexRequestedPermissions? = nil
    ) {
        self.id = id
        self.kind = kind
        self.method = method ?? kind.defaultMethod
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.approvalID = approvalID
        self.summary = summary
        self.reason = reason
        self.requestedPermissions = requestedPermissions
    }
}

public enum CodexApprovalDecision: Hashable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
    case grantRequestedPermissions(scopeSession: Bool)
    case denyPermissions
}

public struct CodexRPCInitializeCapabilities: Codable, Hashable, Sendable {
    public var experimentalApi: Bool
    public var optOutNotificationMethods: [String]?

    public init(
        experimentalApi: Bool = false,
        optOutNotificationMethods: [String]? = nil
    ) {
        self.experimentalApi = experimentalApi
        self.optOutNotificationMethods = optOutNotificationMethods
    }
}

public struct CodexRPCInitializeParams: Codable, Hashable, Sendable {
    public var clientInfo: CodexRPCClientInfo
    public var capabilities: CodexRPCInitializeCapabilities?

    public init(
        clientInfo: CodexRPCClientInfo,
        capabilities: CodexRPCInitializeCapabilities? = nil
    ) {
        self.clientInfo = clientInfo
        self.capabilities = capabilities
    }
}

public struct CodexRPCInitializedNotification: Encodable, Sendable {
    public var method = "initialized"

    public init() {}
}

public struct CodexRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    public var id: Int
    public var method: String
    public var params: Params

    public init(id: Int, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct CodexRPCNotification<Params: Encodable & Sendable>: Encodable, Sendable {
    public var method: String
    public var params: Params

    public init(method: String, params: Params) {
        self.method = method
        self.params = params
    }
}

public struct CodexRPCResultEnvelope<Result: Encodable & Sendable>: Encodable, Sendable {
    public var id: CodexRPCIdentifier
    public var result: Result

    public init(id: CodexRPCIdentifier, result: Result) {
        self.id = id
        self.result = result
    }
}

public struct CodexRPCErrorEnvelope: Encodable, Sendable {
    public var id: CodexRPCIdentifier
    public var error: RPCErrorPayload

    public init(id: CodexRPCIdentifier, error: RPCErrorPayload) {
        self.id = id
        self.error = error
    }
}

public enum CodexRPCIdentifier: Hashable, Sendable {
    case int(Int)
    case string(String)

    public var intValue: Int? {
        guard case let .int(value) = self else {
            return nil
        }
        return value
    }

    public var stringValue: String {
        switch self {
        case let .int(value):
            return String(value)
        case let .string(value):
            return value
        }
    }
}

extension CodexRPCIdentifier: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON-RPC identifier."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

extension CodexRPCIdentifier: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension CodexRPCIdentifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

public struct CodexRPCResponseEnvelope: Decodable, Hashable, Sendable {
    public var id: CodexRPCIdentifier?
    public var method: String?
    public var result: JSONValue?
    public var params: JSONValue?
    public var error: RPCErrorPayload?

    public init(
        id: CodexRPCIdentifier? = nil,
        method: String? = nil,
        result: JSONValue? = nil,
        params: JSONValue? = nil,
        error: RPCErrorPayload? = nil
    ) {
        self.id = id
        self.method = method
        self.result = result
        self.params = params
        self.error = error
    }
}

public struct RPCErrorPayload: Codable, Hashable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum CodexRPCLineCodec {
    public static func encode<Request: Encodable>(_ request: Request) throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        return data + Data([0x0A])
    }

    public static func decodeResponse(_ data: Data) throws -> CodexRPCResponseEnvelope {
        try JSONDecoder().decode(CodexRPCResponseEnvelope.self, from: data)
    }
}

public enum CodexThreadDecodingError: LocalizedError {
    case invalidThread(String)
    case invalidThreadList(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidThread(message):
            message
        case let .invalidThreadList(message):
            message
        }
    }
}

public enum CodexThreadCodec {
    public static func decodeThreadListPage(from resultObject: [String: JSONValue]) throws -> CodexThreadListPage {
        let threadValues = resultObject["data"]?.arrayValue
            ?? resultObject["items"]?.arrayValue
            ?? resultObject["threads"]?.arrayValue
        guard let threadValues else {
            throw CodexThreadDecodingError.invalidThreadList("thread/list response missing thread data.")
        }

        var threads: [CodexThreadSummary] = []
        var decodeErrors: [String] = []

        for value in threadValues {
            do {
                threads.append(try decodeThreadSummary(value))
            } catch {
                decodeErrors.append(error.localizedDescription)
            }
        }

        if threads.isEmpty, !threadValues.isEmpty {
            let firstError = decodeErrors.first ?? "Unknown thread decoding error."
            throw CodexThreadDecodingError.invalidThreadList(
                "thread/list decoded 0 of \(threadValues.count) thread entries. First error: \(firstError)"
            )
        }

        let nextCursor = resultObject["nextCursor"]?.stringValue ?? resultObject["next_cursor"]?.stringValue
        return CodexThreadListPage(threads: threads, nextCursor: nextCursor)
    }

    public static func decodeThreadSnapshot(from threadValue: JSONValue) throws -> CodexThreadSnapshot {
        let summary = try decodeThreadSummary(threadValue)
        guard let object = threadValue.objectValue else {
            throw CodexThreadDecodingError.invalidThread("Malformed thread payload.")
        }
        let turns = try (object["turns"]?.arrayValue ?? []).map(decodeTurn)
        return CodexThreadSnapshot(summary: summary, turns: turns)
    }

    private static func decodeThreadSummary(_ value: JSONValue) throws -> CodexThreadSummary {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue else {
            throw CodexThreadDecodingError.invalidThread("Malformed thread payload.")
        }

        let cwd = stringValue(in: object, keys: ["cwd", "path"]) ?? ""
        let preview = stringValue(in: object, keys: ["preview"]) ?? object["name"]?.stringValue ?? ""
        let modelProvider = stringValue(in: object, keys: ["modelProvider", "model_provider"]) ?? "unknown"
        let createdAt = try decodeTimestamp(in: object, keys: ["createdAt", "created_at"]) ?? .distantPast
        let updatedAt = try decodeTimestamp(in: object, keys: ["updatedAt", "updated_at"]) ?? createdAt

        return CodexThreadSummary(
            id: id,
            cwd: cwd,
            preview: preview,
            modelProvider: modelProvider,
            name: object["name"]?.stringValue,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: try decodeThreadStatus(object["status"])
        )
    }

    private static func decodeThreadStatus(_ value: JSONValue?) throws -> CodexThreadRuntimeStatus {
        if let status = value?.stringValue {
            switch status {
            case "notLoaded":
                return .notLoaded
            case "idle":
                return .idle
            case "systemError":
                return .systemError
            case "active":
                return .active(activeFlags: [])
            default:
                throw CodexThreadDecodingError.invalidThread("Unknown thread status payload.")
            }
        }

        guard let object = value?.objectValue else {
            return .notLoaded
        }

        switch object["type"]?.stringValue {
        case "notLoaded":
            return .notLoaded
        case "idle":
            return .idle
        case "systemError":
            return .systemError
        case "active":
            let activeFlags = object["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .active(activeFlags: activeFlags)
        default:
            throw CodexThreadDecodingError.invalidThread("Unknown thread status payload.")
        }
    }

    private static func stringValue(
        in object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private static func decodeTimestamp(
        in object: [String: JSONValue],
        keys: [String]
    ) throws -> Date? {
        for key in keys {
            guard let value = object[key] else {
                continue
            }

            if let intValue = value.intValue {
                return Date(timeIntervalSince1970: TimeInterval(intValue))
            }

            if let stringValue = value.stringValue {
                if let seconds = TimeInterval(stringValue) {
                    return Date(timeIntervalSince1970: seconds)
                }

                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: stringValue) {
                    return date
                }
            }

            throw CodexThreadDecodingError.invalidThread("Malformed thread timestamp payload.")
        }

        return nil
    }

    private static func decodeTurn(_ value: JSONValue) throws -> CodexThreadTurnSnapshot {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let status = object["status"]?.stringValue else {
            throw CodexThreadDecodingError.invalidThread("Malformed turn payload.")
        }

        let items = try (object["items"]?.arrayValue ?? []).map(decodeItem)
        return CodexThreadTurnSnapshot(id: id, status: status, items: items)
    }

    private static func decodeItem(_ value: JSONValue) throws -> CodexThreadItemSnapshot {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue else {
            return .other("Unknown thread item")
        }

        switch type {
        case "userMessage":
            let content = object["content"]?.arrayValue ?? []
            let summary = content.compactMap(decodeUserInputSummary)
                .joined(separator: "\n")
            return .userMessage(summary.isEmpty ? "User message" : summary)
        case "agentMessage":
            let phase = object["phase"]?.stringValue.flatMap(CodexThreadMessagePhase.init(rawValue:))
            return .assistantMessage(object["text"]?.stringValue ?? "", phase: phase)
        case "reasoning":
            let summary = (object["summary"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .joined(separator: "\n")
            let content = (object["content"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .joined(separator: "\n")
            return .reasoning(summary.isEmpty ? content : summary)
        case "plan":
            return .plan(object["text"]?.stringValue ?? "Plan")
        case "commandExecution":
            let summary = object["aggregatedOutput"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .commandExecution(
                summary: summary?.isEmpty == false ? summary! : (object["command"]?.stringValue ?? "Command execution"),
                status: object["status"]?.stringValue ?? "unknown"
            )
        case "fileChange":
            let changes = object["changes"]?.arrayValue?.compactMap { change -> String? in
                change.objectValue?["path"]?.stringValue
            } ?? []
            let summary = changes.isEmpty ? "File change" : changes.joined(separator: ", ")
            return .fileChange(summary: summary, status: object["status"]?.stringValue ?? "unknown")
        case "mcpToolCall":
            let server = object["server"]?.stringValue ?? "mcp"
            let tool = object["tool"]?.stringValue ?? "tool"
            return .toolCall("\(server):\(tool)")
        case "dynamicToolCall":
            let tool = object["tool"]?.stringValue ?? "dynamic tool"
            return .toolCall(tool)
        default:
            return .other(type)
        }
    }

    private static func decodeUserInputSummary(_ value: JSONValue) -> String? {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue else {
            return nil
        }

        switch type {
        case "text":
            return object["text"]?.stringValue
        case "image":
            return "[Image: \(object["url"]?.stringValue ?? "remote")]"
        case "localImage":
            if let path = object["path"]?.stringValue {
                return "[Image: \((path as NSString).lastPathComponent)]"
            }
            return "[Image]"
        case "skill":
            return "[Skill: \(object["name"]?.stringValue ?? "skill")]"
        case "mention":
            return "[Mention: \(object["name"]?.stringValue ?? "mention")]"
        default:
            return nil
        }
    }
}

public extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case let .number(value) = self {
            return Int(value)
        }
        return nil
    }
}
