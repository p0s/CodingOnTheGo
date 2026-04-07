import Foundation

public enum WorkspaceFileStatus: String, Codable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case unmerged
    case unchanged
}

public struct WorkspaceFileChange: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var staged: WorkspaceFileStatus
    public var unstaged: WorkspaceFileStatus

    public init(path: String, staged: WorkspaceFileStatus, unstaged: WorkspaceFileStatus) {
        self.path = path
        self.staged = staged
        self.unstaged = unstaged
    }
}

public struct GitWorkspaceSummary: Hashable, Codable, Sendable {
    public var branch: String
    public var upstream: String?
    public var aheadCount: Int
    public var behindCount: Int
    public var changes: [WorkspaceFileChange]

    public init(
        branch: String,
        upstream: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        changes: [WorkspaceFileChange] = []
    ) {
        self.branch = branch
        self.upstream = upstream
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.changes = changes
    }

    public var stagedCount: Int {
        changes.filter { $0.staged != .unchanged }.count
    }

    public var modifiedCount: Int {
        changes.filter { $0.unstaged != .unchanged }.count
    }

    public var untrackedCount: Int {
        changes.filter { $0.staged == .untracked || $0.unstaged == .untracked }.count
    }
}

public struct RevertPreview: Hashable, Codable, Sendable {
    public var path: String
    public var diff: String

    public init(path: String, diff: String) {
        self.path = path
        self.diff = diff
    }
}

public struct GitWorktreeEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var branch: String?
    public var head: String?
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(
        path: String,
        branch: String? = nil,
        head: String? = nil,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public enum GitWorktreeParser {
    public static func parse(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var currentPath: String?
        var currentBranch: String?
        var currentHead: String?
        var currentLocked = false
        var currentPrunable = false

        func flushCurrentEntry() {
            guard let path = currentPath else {
                return
            }

            entries.append(
                GitWorktreeEntry(
                    path: path,
                    branch: currentBranch,
                    head: currentHead,
                    isLocked: currentLocked,
                    isPrunable: currentPrunable
                )
            )
            currentPath = nil
            currentBranch = nil
            currentHead = nil
            currentLocked = false
            currentPrunable = false
        }

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.isEmpty {
                flushCurrentEntry()
                continue
            }

            if line.hasPrefix("worktree ") {
                flushCurrentEntry()
                currentPath = String(line.dropFirst("worktree ".count))
                continue
            }

            if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
                continue
            }

            if line.hasPrefix("branch ") {
                currentBranch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
                continue
            }

            if line.hasPrefix("locked") {
                currentLocked = true
                continue
            }

            if line.hasPrefix("prunable") {
                currentPrunable = true
                continue
            }
        }

        flushCurrentEntry()
        return entries
    }
}

public enum GitStatusParser {
    public static func parse(_ output: String) -> GitWorkspaceSummary {
        var branch = "HEAD"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes: [WorkspaceFileChange] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            if raw.hasPrefix("## ") {
                let header = raw.dropFirst(3)
                let pieces = header.split(separator: " ")
                if let branchPart = pieces.first {
                    let branchInfo = branchPart.split(separator: ".")
                    branch = String(branchInfo.first ?? Substring("HEAD"))
                    if let rangeStart = raw.range(of: "...") {
                        let tail = raw[rangeStart.upperBound...]
                        upstream = tail.split(separator: " ").first.map(String.init)
                    }
                }
                if raw.contains("ahead ") {
                    ahead = extractCount(label: "ahead", from: raw)
                }
                if raw.contains("behind ") {
                    behind = extractCount(label: "behind", from: raw)
                }
                continue
            }

            guard raw.count >= 3 else {
                continue
            }

            let chars = Array(raw)
            let staged = status(for: chars[0])
            let unstaged = status(for: chars[1])
            let path = String(raw.dropFirst(3))
            changes.append(
                WorkspaceFileChange(
                    path: path,
                    staged: staged,
                    unstaged: unstaged
                )
            )
        }

        return GitWorkspaceSummary(
            branch: branch,
            upstream: upstream,
            aheadCount: ahead,
            behindCount: behind,
            changes: changes
        )
    }

    private static func extractCount(label: String, from header: String) -> Int {
        guard let range = header.range(of: "\(label) ") else {
            return 0
        }
        let suffix = header[range.upperBound...]
        let number = suffix.prefix { $0.isNumber }
        return Int(number) ?? 0
    }

    private static func status(for character: Character) -> WorkspaceFileStatus {
        switch character {
        case "A":
            .added
        case "M":
            .modified
        case "D":
            .deleted
        case "R":
            .renamed
        case "C":
            .copied
        case "U":
            .unmerged
        case "?":
            .untracked
        default:
            .unchanged
        }
    }
}

public enum GitWorkspaceCommandBuilder {
    public static func statusCommand(cwd: String) -> String {
        "cd \(shellQuote(cwd)) && git status --short --branch"
    }

    public static func switchBranchCommand(cwd: String, branch: String) -> String {
        "cd \(shellQuote(cwd)) && git switch \(shellQuote(branch))"
    }

    public static func createBranchCommand(cwd: String, branch: String) -> String {
        "cd \(shellQuote(cwd)) && git switch -c \(shellQuote(branch))"
    }

    public static func commitCommand(cwd: String, message: String) -> String {
        "cd \(shellQuote(cwd)) && git commit -m \(shellQuote(message))"
    }

    public static func diffPreviewCommand(cwd: String, path: String) -> String {
        "cd \(shellQuote(cwd)) && git diff -- \(shellQuote(path))"
    }

    public static func revertCommand(cwd: String, path: String) -> String {
        "cd \(shellQuote(cwd)) && git checkout -- \(shellQuote(path))"
    }

    public static func worktreeListCommand(cwd: String) -> String {
        "cd \(shellQuote(cwd)) && git worktree list --porcelain"
    }

    public static func createWorktreeCommand(
        cwd: String,
        path: String,
        branch: String
    ) -> String {
        "cd \(shellQuote(cwd)) && git worktree add \(shellQuote(path)) -b \(shellQuote(branch))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
