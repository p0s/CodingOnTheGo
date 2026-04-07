import Foundation
import SharedModels

public enum GitFileStatus: String, Codable, CaseIterable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case ignored
    case conflicted
}

public struct GitWorkspaceFileChange: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var path: String
    public var status: GitFileStatus
    public var indexStatus: String
    public var worktreeStatus: String
    public var previousPath: String?

    public init(
        id: UUID = UUID(),
        path: String,
        status: GitFileStatus,
        indexStatus: String,
        worktreeStatus: String,
        previousPath: String? = nil
    ) {
        self.id = id
        self.path = path
        self.status = status
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.previousPath = previousPath
    }
}

public struct GitWorkspaceContext: Hashable, Codable, Sendable {
    public var session: SessionRecord?
    public var workspaceRoot: String
    public var repositoryName: String?

    public init(session: SessionRecord? = nil, workspaceRoot: String, repositoryName: String? = nil) {
        self.session = session
        self.workspaceRoot = workspaceRoot
        self.repositoryName = repositoryName
    }
}

public struct GitWorkspaceStatusSnapshot: Hashable, Codable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var aheadBy: Int
    public var behindBy: Int
    public var isDetachedHead: Bool
    public var changes: [GitWorkspaceFileChange]
    public var workspaceRoot: String
    public var threadID: String?

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        aheadBy: Int = 0,
        behindBy: Int = 0,
        isDetachedHead: Bool = false,
        changes: [GitWorkspaceFileChange],
        workspaceRoot: String,
        threadID: String? = nil
    ) {
        self.branch = branch
        self.upstream = upstream
        self.aheadBy = aheadBy
        self.behindBy = behindBy
        self.isDetachedHead = isDetachedHead
        self.changes = changes
        self.workspaceRoot = workspaceRoot
        self.threadID = threadID
    }

    public var isDirty: Bool {
        !changes.isEmpty
    }
}

public struct GitWorkspaceCommand: Hashable, Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var input: String?

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        input: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.input = input
    }
}

public struct GitWorkspaceCommandResult: Hashable, Codable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct GitWorkspaceDiffPreview: Hashable, Codable, Sendable {
    public var affectedPaths: [String]
    public var conflictSummary: [String]
    public var reverseCheckPassed: Bool
    public var applySummary: String

    public init(
        affectedPaths: [String],
        conflictSummary: [String],
        reverseCheckPassed: Bool,
        applySummary: String
    ) {
        self.affectedPaths = affectedPaths
        self.conflictSummary = conflictSummary
        self.reverseCheckPassed = reverseCheckPassed
        self.applySummary = applySummary
    }
}

public protocol GitWorkspaceExecuting: Sendable {
    func execute(_ command: GitWorkspaceCommand) async throws -> GitWorkspaceCommandResult
}

public actor GitWorkspaceOperationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

public struct GitWorkspaceClient: Sendable {
    private let executor: GitWorkspaceExecuting
    public let context: GitWorkspaceContext

    public init(executor: GitWorkspaceExecuting, context: GitWorkspaceContext) {
        self.executor = executor
        self.context = context
    }

    public func status() async throws -> GitWorkspaceStatusSnapshot {
        let result = try await executor.execute(
            GitWorkspaceCommand(
                executable: "git",
                arguments: ["status", "--porcelain=v1", "-b"],
                workingDirectory: context.workspaceRoot
            )
        )
        return Self.parseStatus(result.standardOutput, workspaceRoot: context.workspaceRoot, threadID: context.session?.threadID)
    }

    public func diff() async throws -> GitWorkspaceDiffPreview {
        let result = try await executor.execute(
            GitWorkspaceCommand(
                executable: "git",
                arguments: ["diff", "--no-ext-diff", "--name-status"],
                workingDirectory: context.workspaceRoot
            )
        )
        return Self.parseDiffNameStatus(result.standardOutput)
    }

    public func branchSwitchPlan(to branch: String) -> GitWorkspaceCommand {
        GitWorkspaceCommand(
            executable: "git",
            arguments: ["switch", branch],
            workingDirectory: context.workspaceRoot
        )
    }

    public func branchCreatePlan(_ branch: String) -> GitWorkspaceCommand {
        GitWorkspaceCommand(
            executable: "git",
            arguments: ["switch", "-c", branch],
            workingDirectory: context.workspaceRoot
        )
    }

    public func commitPlan(message: String) -> GitWorkspaceCommand {
        GitWorkspaceCommand(
            executable: "git",
            arguments: ["commit", "-m", message],
            workingDirectory: context.workspaceRoot
        )
    }

    public func previewRevert(patch: String) async throws -> GitWorkspaceDiffPreview {
        let result = try await executor.execute(
            GitWorkspaceCommand(
                executable: "git",
                arguments: ["apply", "--reverse", "--check", "--verbose", "-"],
                workingDirectory: context.workspaceRoot,
                input: patch
            )
        )
        let affectedPaths = Self.parsePatchPaths(patch)
        let conflictSummary = result.exitCode == 0 ? [] : result.standardError.split(separator: "\n").map(String.init)
        return GitWorkspaceDiffPreview(
            affectedPaths: affectedPaths,
            conflictSummary: conflictSummary,
            reverseCheckPassed: result.exitCode == 0,
            applySummary: result.exitCode == 0 ? "Reverse-apply check passed." : "Reverse-apply check failed."
        )
    }

    static func parseStatus(_ output: String, workspaceRoot: String, threadID: String?) -> GitWorkspaceStatusSnapshot {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var branch: String?
        var upstream: String?
        var aheadBy = 0
        var behindBy = 0
        var isDetachedHead = false
        var changes: [GitWorkspaceFileChange] = []

        if let first = lines.first, first.hasPrefix("## ") {
            parseBranchLine(first, branch: &branch, upstream: &upstream, aheadBy: &aheadBy, behindBy: &behindBy, isDetachedHead: &isDetachedHead)
        }

        for line in lines.dropFirst() {
            guard line.count >= 3 else { continue }
            let indexStatus = String(line.prefix(1))
            let worktreeStatus = String(line.dropFirst().prefix(1))
            let path = String(line.dropFirst(3))
            let status = classify(indexStatus: indexStatus, worktreeStatus: worktreeStatus, line: line)
            changes.append(
                GitWorkspaceFileChange(
                    path: path,
                    status: status,
                    indexStatus: indexStatus,
                    worktreeStatus: worktreeStatus
                )
            )
        }

        return GitWorkspaceStatusSnapshot(
            branch: branch,
            upstream: upstream,
            aheadBy: aheadBy,
            behindBy: behindBy,
            isDetachedHead: isDetachedHead,
            changes: changes,
            workspaceRoot: workspaceRoot,
            threadID: threadID
        )
    }

    static func parseDiffNameStatus(_ output: String) -> GitWorkspaceDiffPreview {
        let paths = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2 else { return nil }
                return String(parts.last ?? "")
            }
        return GitWorkspaceDiffPreview(
            affectedPaths: paths,
            conflictSummary: [],
            reverseCheckPassed: true,
            applySummary: paths.isEmpty ? "No file changes." : "Files changed: \(paths.count)."
        )
    }

    static func parsePatchPaths(_ patch: String) -> [String] {
        var paths: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("diff --git ") else { continue }
            let components = line.split(separator: " ")
            guard components.count >= 4 else { continue }
            let rawPath = components[3]
            if rawPath.hasPrefix("b/") {
                paths.append(String(rawPath.dropFirst(2)))
            } else {
                paths.append(String(rawPath))
            }
        }
        return Array(Set(paths)).sorted()
    }

    private static func parseBranchLine(
        _ line: String,
        branch: inout String?,
        upstream: inout String?,
        aheadBy: inout Int,
        behindBy: inout Int,
        isDetachedHead: inout Bool
    ) {
        let remainder = String(line.dropFirst(3))
        if remainder.hasPrefix("(HEAD detached at ") {
            isDetachedHead = true
            branch = String(remainder.dropFirst("(HEAD detached at ".count).dropLast())
            return
        }

        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let branchPart = String(parts.first ?? Substring(remainder))
        if let range = branchPart.range(of: "...") {
            branch = String(branchPart[..<range.lowerBound])
            upstream = String(branchPart[range.upperBound...])
        } else {
            branch = branchPart
        }

        if parts.count > 1 {
            let status = String(parts[1])
            if let aheadRange = status.range(of: "ahead ") {
                let tail = status[aheadRange.upperBound...]
                aheadBy = Int(tail.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
            }
            if let behindRange = status.range(of: "behind ") {
                let tail = status[behindRange.upperBound...]
                behindBy = Int(tail.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
            }
        }
    }

    private static func classify(indexStatus: String, worktreeStatus: String, line: String) -> GitFileStatus {
        if line.hasPrefix("??") {
            return .untracked
        }
        if line.hasPrefix("!!") {
            return .ignored
        }
        if indexStatus.contains("U") || worktreeStatus.contains("U") || line.hasPrefix("AA") || line.hasPrefix("DD") {
            return .conflicted
        }
        if indexStatus == "R" || worktreeStatus == "R" {
            return .renamed
        }
        if indexStatus == "C" || worktreeStatus == "C" {
            return .copied
        }
        if indexStatus == "A" || worktreeStatus == "A" {
            return .added
        }
        if indexStatus == "D" || worktreeStatus == "D" {
            return .deleted
        }
        return .modified
    }
}
