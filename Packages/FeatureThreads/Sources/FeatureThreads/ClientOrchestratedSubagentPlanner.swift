import Foundation

public enum ClientSubagentTaskStatus: String, Hashable, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
}

public struct ClientSubagentTask: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var ordinal: Int
    public var title: String
    public var prompt: String
    public var status: ClientSubagentTaskStatus
    public var resultSummary: String?

    public init(
        id: UUID = UUID(),
        ordinal: Int,
        title: String,
        prompt: String,
        status: ClientSubagentTaskStatus = .queued,
        resultSummary: String? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.prompt = prompt
        self.status = status
        self.resultSummary = resultSummary
    }
}

public struct ClientSubagentPlan: Hashable, Codable, Sendable {
    public var originalPrompt: String
    public var tasks: [ClientSubagentTask]

    public init(originalPrompt: String, tasks: [ClientSubagentTask]) {
        self.originalPrompt = originalPrompt
        self.tasks = tasks
    }
}

public enum ClientOrchestratedSubagentPlanner {
    public static func makePlan(from draft: String) -> ClientSubagentPlan? {
        let normalizedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDraft.isEmpty else {
            return nil
        }

        let bulletTasks = normalizedDraft
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .compactMap(normalizeTaskLine(_:))

        guard bulletTasks.count >= 2 else {
            return nil
        }

        let tasks = bulletTasks.enumerated().map { index, task in
            ClientSubagentTask(
                ordinal: index + 1,
                title: task,
                prompt: """
                Client-orchestrated subtask \(index + 1) of \(bulletTasks.count):
                \(task)

                Work only on this subtask. Keep the response scoped to what the main thread needs next, and end with a concise summary for the main thread.
                """
            )
        }

        return ClientSubagentPlan(originalPrompt: normalizedDraft, tasks: tasks)
    }

    public static func summary(for tasks: [ClientSubagentTask]) -> String? {
        guard !tasks.isEmpty else {
            return nil
        }

        let running = tasks.filter { $0.status == .running }
        let queued = tasks.filter { $0.status == .queued }
        let completed = tasks.filter { $0.status == .completed }
        let failed = tasks.filter { $0.status == .failed }

        if let active = running.first {
            return "Running subtask \(active.ordinal)/\(tasks.count): \(active.title) · \(completed.count) completed, \(queued.count) queued"
        }

        if let blocked = failed.first {
            return "Subtask \(blocked.ordinal) failed: \(blocked.title) · \(completed.count) completed, \(queued.count) queued"
        }

        if queued.count == tasks.count {
            return "Queued \(tasks.count) client-orchestrated subtasks."
        }

        return "Completed \(completed.count)/\(tasks.count) client-orchestrated subtasks."
    }

    private static func normalizeTaskLine(_ line: String) -> String? {
        guard !line.isEmpty else {
            return nil
        }

        let trimmed: String
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            trimmed = String(line.dropFirst(2))
        } else if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            trimmed = String(line[range.upperBound...])
        } else {
            return nil
        }

        let normalized = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
