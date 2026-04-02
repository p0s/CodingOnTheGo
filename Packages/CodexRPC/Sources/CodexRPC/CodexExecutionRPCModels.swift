import Foundation
import SharedModels

public enum CodexSandboxMode: String, Codable, CaseIterable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

public enum CodexSandboxPolicy: Hashable, Sendable {
    case dangerFullAccess
    case readOnly(readAccess: CodexSandboxReadAccess, networkAccess: Bool)
    case workspaceWrite(
        writableRoots: [String],
        readAccess: CodexSandboxReadAccess,
        networkAccess: Bool,
        excludeTmpdirEnvVar: Bool,
        excludeSlashTmp: Bool
    )
    case externalSandbox(networkEnabled: Bool?)
}

public enum CodexSandboxReadAccess: Hashable, Sendable {
    case fullAccess
    case restricted(includePlatformDefaults: Bool, readableRoots: [String])
}

public struct CodexThreadExecutionOptions: Hashable, Sendable {
    public var cwd: String?
    public var model: String?
    public var approvalPolicy: String?
    public var sandboxMode: CodexSandboxMode?

    public init(
        cwd: String? = nil,
        model: String? = nil,
        approvalPolicy: String? = nil,
        sandboxMode: CodexSandboxMode? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
    }
}

public struct CodexTurnExecutionOptions: Hashable, Sendable {
    public var cwd: String?
    public var model: String?
    public var approvalPolicy: String?
    public var sandboxPolicy: CodexSandboxPolicy?
    public var effort: CodexReasoningEffort?
    public var collaborationMode: CodexCollaborationMode?

    public init(
        cwd: String? = nil,
        model: String? = nil,
        approvalPolicy: String? = nil,
        sandboxPolicy: CodexSandboxPolicy? = nil,
        effort: CodexReasoningEffort? = nil,
        collaborationMode: CodexCollaborationMode? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.effort = effort
        self.collaborationMode = collaborationMode
    }
}

public struct CodexStructuredUserInputRequest: Hashable, Sendable {
    public var id: CodexRPCIdentifier
    public var threadID: String
    public var turnID: String
    public var itemID: String
    public var prompt: SessionStructuredPrompt

    public init(
        id: CodexRPCIdentifier,
        threadID: String,
        turnID: String,
        itemID: String,
        prompt: SessionStructuredPrompt
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.prompt = prompt
    }
}

public struct CodexUnhandledServerRequest: Hashable, Sendable {
    public var id: CodexRPCIdentifier
    public var method: String
    public var threadID: String?
    public var turnID: String?

    public init(id: CodexRPCIdentifier, method: String, threadID: String? = nil, turnID: String? = nil) {
        self.id = id
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
    }
}

public enum CodexServerRequest: Hashable, Sendable {
    case approval(CodexApprovalRequest)
    case structuredUserInput(CodexStructuredUserInputRequest)
    case unsupported(CodexUnhandledServerRequest)
}

extension CodexSandboxPolicy {
    var jsonValue: JSONValue {
        switch self {
        case .dangerFullAccess:
            return .object(["type": .string("dangerFullAccess")])
        case let .readOnly(readAccess, networkAccess):
            return .object([
                "type": .string("readOnly"),
                "access": readAccess.jsonValue,
                "networkAccess": .bool(networkAccess)
            ])
        case let .workspaceWrite(writableRoots, readAccess, networkAccess, excludeTmpdirEnvVar, excludeSlashTmp):
            return .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array(writableRoots.map(JSONValue.string)),
                "readOnlyAccess": readAccess.jsonValue,
                "networkAccess": .bool(networkAccess),
                "excludeTmpdirEnvVar": .bool(excludeTmpdirEnvVar),
                "excludeSlashTmp": .bool(excludeSlashTmp)
            ])
        case let .externalSandbox(networkEnabled):
            return .object([
                "type": .string("externalSandbox"),
                "networkAccess": .object([
                    "enabled": networkEnabled.map(JSONValue.bool) ?? .null
                ])
            ])
        }
    }
}

extension CodexSandboxReadAccess {
    var jsonValue: JSONValue {
        switch self {
        case .fullAccess:
            return .object(["type": .string("fullAccess")])
        case let .restricted(includePlatformDefaults, readableRoots):
            return .object([
                "type": .string("restricted"),
                "includePlatformDefaults": .bool(includePlatformDefaults),
                "readableRoots": .array(readableRoots.map(JSONValue.string))
            ])
        }
    }
}
