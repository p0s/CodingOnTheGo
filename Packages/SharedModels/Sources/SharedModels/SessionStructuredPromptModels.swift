import Foundation

public struct SessionStructuredOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String? = nil, label: String, detail: String? = nil) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? trimmedLabel
        self.label = trimmedLabel
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SessionStructuredQuestion: Identifiable, Hashable, Sendable {
    public var id: String
    public var prompt: String
    public var options: [SessionStructuredOption]
    public var allowsCustomAnswer: Bool
    public var customAnswerPlaceholder: String?

    public init(
        id: String,
        prompt: String,
        options: [SessionStructuredOption] = [],
        allowsCustomAnswer: Bool = false,
        customAnswerPlaceholder: String? = nil
    ) {
        self.id = id
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.options = options
        self.allowsCustomAnswer = allowsCustomAnswer
        self.customAnswerPlaceholder = customAnswerPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SessionStructuredPrompt: Hashable, Sendable {
    public var requestID: String
    public var questions: [SessionStructuredQuestion]

    public init(requestID: String, questions: [SessionStructuredQuestion]) {
        self.requestID = requestID
        self.questions = questions
    }
}
