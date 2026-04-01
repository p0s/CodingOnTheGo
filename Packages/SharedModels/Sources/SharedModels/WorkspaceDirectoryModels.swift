import Foundation

public struct WorkspaceDirectoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isGitRepository: Bool

    public init(name: String, path: String, isGitRepository: Bool) {
        self.name = name
        self.path = path
        self.isGitRepository = isGitRepository
    }
}

public struct WorkspaceDirectoryListing: Hashable, Sendable {
    public var currentPath: String
    public var parentPath: String?
    public var isCurrentPathGitRepository: Bool
    public var entries: [WorkspaceDirectoryEntry]

    public init(
        currentPath: String,
        parentPath: String?,
        isCurrentPathGitRepository: Bool,
        entries: [WorkspaceDirectoryEntry]
    ) {
        self.currentPath = currentPath
        self.parentPath = parentPath
        self.isCurrentPathGitRepository = isCurrentPathGitRepository
        self.entries = entries
    }
}
