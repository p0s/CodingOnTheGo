import Foundation
import SharedModels

public struct CodexLiveConfiguration: Hashable, Sendable {
    public var url: URL
    public var cwd: String
    public var clientInfo: CodexRPCClientInfo

    public init(
        url: URL,
        cwd: String,
        clientInfo: CodexRPCClientInfo
    ) {
        self.url = url
        self.cwd = cwd
        self.clientInfo = clientInfo
    }
}

public struct CodexThreadContext: Hashable, Sendable {
    public var id: String
    public var cwd: String
    public var model: String?
    public var reasoningEffort: CodexReasoningEffort?
    public var executionProfile: CodexExecutionProfile?

    public init(
        id: String,
        cwd: String,
        model: String?,
        reasoningEffort: CodexReasoningEffort? = nil,
        executionProfile: CodexExecutionProfile? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.executionProfile = executionProfile
    }
}

public struct CodexTurnContext: Hashable, Sendable {
    public var id: String
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

public enum CodexLiveEvent: Sendable {
    case configWarning(String)
    case threadStarted(String)
    case turnStarted(String)
    case turnCompleted(String)
    case agentMessageDelta(String)
    case agentMessageCompleted(String)
    case activity(CodexLiveActivityEvent)
    case approvalRequested(CodexApprovalRequest)
    case structuredUserInputRequested(CodexStructuredUserInputRequest)
    case serverRequestUnsupported(CodexUnhandledServerRequest)
    case error(String)
}

public struct CodexLiveActivityEvent: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case threadStatusChanged
        case tokenUsageUpdated
        case itemStarted
        case itemCompleted
        case planDelta
        case reasoningDelta
        case commandExecutionOutputDelta
        case fileChangeOutputDelta
        case fileChangePatchUpdated
        case turnDiffUpdated
        case turnPlanUpdated
        case rawResponseItemCompleted
    }

    public var kind: Kind
    public var threadID: String?
    public var turnID: String?
    public var itemID: String?
    public var itemType: String?
    public var text: String?
    public var shouldRefreshThread: Bool

    public init(
        kind: Kind,
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String? = nil,
        itemType: String? = nil,
        text: String? = nil,
        shouldRefreshThread: Bool = false
    ) {
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.itemType = itemType
        self.text = text
        self.shouldRefreshThread = shouldRefreshThread
    }
}

public enum CodexWebSocketError: LocalizedError {
    case notConnected
    case invalidResponse(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "The websocket transport is not connected."
        case let .invalidResponse(message):
            message
        case let .invalidRequest(message):
            message
        }
    }
}

public struct JSONObjectEncodable: Encodable, Sendable {
    public var value: [String: JSONValue]

    public init(value: [String: JSONValue]) {
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

public actor CodexWebSocketClient {
    private var socket: URLSessionWebSocketTask?
    private var nextRequestID = 1
    private var pendingResponses: [Int: AsyncThrowingStream<CodexRPCResponseEnvelope, Error>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (CodexLiveEvent) -> Void)?
    private var connectionGeneration = 0

    public init() {}

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    public func connect(
        configuration: CodexLiveConfiguration,
        onEvent: @escaping @Sendable (CodexLiveEvent) -> Void
    ) async throws {
        disconnect()
        connectionGeneration += 1
        let generation = connectionGeneration
        eventHandler = onEvent

        let task = URLSession.shared.webSocketTask(with: configuration.url)
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()

        receiveTask = Task { await self.receiveLoop(generation: generation) }

        let initialize = CodexSessionRPC.initializeRequest(
            id: nextID(),
            clientInfo: configuration.clientInfo
        )
        _ = try await send(request: initialize)
        try await send(notification: CodexSessionRPC.initializedNotification())
    }

    public func disconnect() {
        connectionGeneration += 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil

        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.finish(throwing: CancellationError())
        }
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

        let response = try await send(request: request)
        do {
            return try CodexSessionRPC.decodeThreadListPage(from: response)
        } catch let error as CodexSessionRPCError {
            throw Self.mapSessionError(error)
        }
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

    private func send<Request: Encodable & _RequestIDReadable>(request: Request) async throws -> CodexRPCResponseEnvelope {
        guard let socket else {
            throw CodexWebSocketError.notConnected
        }

        let requestID = request.requestID
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let stream = AsyncThrowingStream<CodexRPCResponseEnvelope, Error> { continuation in
            pendingResponses[requestID] = continuation
        }

        do {
            try await socket.send(.string(payload))
        } catch {
            failPendingResponse(id: requestID, error: error)
            throw error
        }

        var iterator = stream.makeAsyncIterator()
        guard let response = try await iterator.next() else {
            throw CancellationError()
        }
        return response
    }

    private func send<Notification: Encodable & Sendable>(notification: Notification) async throws {
        guard let socket else {
            throw CodexWebSocketError.notConnected
        }

        let payload = String(decoding: try JSONEncoder().encode(notification), as: UTF8.self)
        try await socket.send(.string(payload))
    }

    private func receiveLoop(generation: Int) async {
        guard let socket else {
            return
        }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let envelope = try CodexRPCLineCodec.decodeResponse(message.dataValue)
                await handle(envelope)
            } catch {
                guard generation == connectionGeneration, !Task.isCancelled else {
                    break
                }
                emit(.error(error.localizedDescription))
                break
            }
        }
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
                continuation.finish(throwing: CodexWebSocketError.invalidResponse(error.message))
            } else {
                continuation.yield(envelope)
                continuation.finish()
            }
            return
        }
    }

    private func emit(_ event: CodexLiveEvent) {
        eventHandler?(event)
    }

    private func sendResult<Result: Encodable & Sendable>(_ response: CodexRPCResultEnvelope<Result>) async throws {
        guard let socket else {
            throw CodexWebSocketError.notConnected
        }

        let payload = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        try await socket.send(.string(payload))
    }

    private func sendError(_ response: CodexRPCErrorEnvelope) async throws {
        guard let socket else {
            throw CodexWebSocketError.notConnected
        }

        let payload = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        try await socket.send(.string(payload))
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func failPendingResponse(id: Int, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.finish(throwing: error)
    }

    private static func mapSessionError(_ error: CodexSessionRPCError) -> CodexWebSocketError {
        switch error {
        case let .invalidResponse(message):
            return .invalidResponse(message)
        case let .invalidRequest(message):
            return .invalidRequest(message)
        }
    }
}

private protocol _RequestIDReadable {
    var requestID: Int { get }
}

extension CodexRPCRequest: _RequestIDReadable {
    fileprivate var requestID: Int { id }
}

private extension URLSessionWebSocketTask.Message {
    var dataValue: Data {
        get throws {
            switch self {
            case let .data(data):
                data
            case let .string(string):
                Data(string.utf8)
            @unknown default:
                throw CodexWebSocketError.invalidResponse("Unsupported websocket message.")
            }
        }
    }
}
