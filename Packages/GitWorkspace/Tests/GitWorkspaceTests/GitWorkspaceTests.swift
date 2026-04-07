import XCTest
@testable import GitWorkspace
import SharedModels

final class GitWorkspaceTests: XCTestCase {
    func testStatusParserCapturesBranchAndDirtyFiles() {
        let snapshot = GitWorkspaceClient.parseStatus(
            """
            ## main...origin/main [ahead 2, behind 1]
             M Sources/App.swift
            A  Sources/NewFile.swift
            ?? Notes/todo.md
            """,
            workspaceRoot: "/tmp/workspace",
            threadID: "thread-123"
        )

        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.upstream, "origin/main")
        XCTAssertEqual(snapshot.aheadBy, 2)
        XCTAssertEqual(snapshot.behindBy, 1)
        XCTAssertTrue(snapshot.isDirty)
        XCTAssertEqual(snapshot.changes.map(\.status), [.modified, .added, .untracked])
        XCTAssertEqual(snapshot.threadID, "thread-123")
    }

    func testPreviewRevertUsesReverseApplyCheckCommand() async throws {
        let executor = FakeExecutor(result: GitWorkspaceCommandResult(exitCode: 0, standardOutput: "", standardError: ""))
        let client = GitWorkspaceClient(
            executor: executor,
            context: GitWorkspaceContext(workspaceRoot: "/tmp/workspace")
        )

        let preview = try await client.previewRevert(
            patch: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 111..222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1 @@
            -old
            +new
            """
        )

        XCTAssertTrue(preview.reverseCheckPassed)
        XCTAssertEqual(preview.affectedPaths, ["Sources/App.swift"])
        XCTAssertEqual(executor.commands.first?.arguments, ["apply", "--reverse", "--check", "--verbose", "-"])
        XCTAssertEqual(executor.commands.first?.input?.contains("-old"), true)
    }

    func testWorktreeParserReadsBranchHeadAndFlags() {
        let entries = GitWorktreeParser.parse(
            """
            worktree /tmp/repo
            HEAD 0123456789abcdef
            branch refs/heads/main

            worktree /tmp/repo-feature
            HEAD abcdef0123456789
            branch refs/heads/feature/ui
            locked added-by-user
            prunable gitdir file points to non-existent location
            """
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "/tmp/repo")
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[1].path, "/tmp/repo-feature")
        XCTAssertEqual(entries[1].branch, "feature/ui")
        XCTAssertTrue(entries[1].isLocked)
        XCTAssertTrue(entries[1].isPrunable)
    }

    func testCommandBuilderCreatesExplicitGitWorkspaceCommands() {
        XCTAssertEqual(
            GitWorkspaceCommandBuilder.createBranchCommand(cwd: "/tmp/repo", branch: "feature/core"),
            "cd '/tmp/repo' && git switch -c 'feature/core'"
        )
        XCTAssertEqual(
            GitWorkspaceCommandBuilder.commitCommand(cwd: "/tmp/repo", message: "feat: wire safe lane"),
            "cd '/tmp/repo' && git commit -m 'feat: wire safe lane'"
        )
        XCTAssertEqual(
            GitWorkspaceCommandBuilder.createWorktreeCommand(
                cwd: "/tmp/repo",
                path: "/tmp/repo-worktrees/feature-core",
                branch: "feature-core"
            ),
            "cd '/tmp/repo' && git worktree add '/tmp/repo-worktrees/feature-core' -b 'feature-core'"
        )
    }

    func testOperationLockSerializesWork() async throws {
        let lock = GitWorkspaceOperationLock()
        let recorder = EventRecorder()
        let gate = Gate()

        let first = Task {
            try await lock.withLock {
                await recorder.append("first-start")
                await gate.release()
                try await Task.sleep(nanoseconds: 20_000_000)
                await recorder.append("first-end")
            }
        }

        await gate.wait()

        let second = Task {
            try await lock.withLock {
                await recorder.append("second-start")
                await recorder.append("second-end")
            }
        }

        try await first.value
        try await second.value

        let events = await recorder.values()
        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
    }
}

private final class FakeExecutor: GitWorkspaceExecuting, @unchecked Sendable {
    let result: GitWorkspaceCommandResult
    var commands: [GitWorkspaceCommand] = []

    init(result: GitWorkspaceCommandResult) {
        self.result = result
    }

    func execute(_ command: GitWorkspaceCommand) async throws -> GitWorkspaceCommandResult {
        commands.append(command)
        return result
    }
}

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else {
            return
        }

        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
