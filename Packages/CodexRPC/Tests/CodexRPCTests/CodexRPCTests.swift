import XCTest
@testable import CodexRPC

final class CodexRPCTests: XCTestCase {
    func testTransportKindsStayBounded() {
        XCTAssertEqual(CodexTransportKind.allCases, [.stdio, .websocket])
    }

    func testInitializeRequestEncodingIncludesMethod() throws {
        let request = CodexRPCRequest(
            id: 1,
            method: "initialize",
            params: CodexRPCInitializeParams(
                clientInfo: CodexRPCClientInfo(
                    name: "cotg-tests",
                    version: "0.1"
                ),
                capabilities: CodexRPCInitializeCapabilities(experimentalApi: true)
            )
        )

        let payload = try XCTUnwrap(
            String(data: try CodexRPCLineCodec.encode(request), encoding: .utf8)
        )

        XCTAssertTrue(payload.contains("\"method\":\"initialize\""))
        XCTAssertTrue(payload.contains("\"experimentalApi\":true"))
        XCTAssertTrue(payload.hasSuffix("\n"))
    }

    func testInitializedNotificationEncodesBareMethod() throws {
        let payload = try XCTUnwrap(
            String(
                data: CodexRPCLineCodec.encode(CodexRPCInitializedNotification()),
                encoding: .utf8
            )
        )

        XCTAssertEqual(payload, "{\"method\":\"initialized\"}\n")
    }

    func testThreadListRequestEncodesUserFacingSourceKindsOnly() throws {
        let request = CodexSessionRPC.listThreadsRequest(
            id: 2,
            cwd: nil,
            limit: 20,
            cursor: nil,
            sortKey: "updated_at",
            searchTerm: nil
        )

        let payload = try XCTUnwrap(
            String(data: try CodexRPCLineCodec.encode(request), encoding: .utf8)
        )

        XCTAssertTrue(payload.contains("\"sourceKinds\":[\"vscode\",\"appServer\"]"))
        XCTAssertFalse(payload.contains("\"cli\""))
        XCTAssertFalse(payload.contains("\"exec\""))
        XCTAssertFalse(payload.contains("\"unknown\""))
    }

    func testResponseDecodingHandlesResultEnvelope() throws {
        let response = try CodexRPCLineCodec.decodeResponse(
            Data("{\"id\":1,\"result\":{\"status\":\"ok\"}}".utf8)
        )

        XCTAssertEqual(response.id, .int(1))
        XCTAssertEqual(response.result, .object(["status": .string("ok")]))
    }

    func testResponseDecodingHandlesStringIdentifierResultEnvelope() throws {
        let response = try CodexRPCLineCodec.decodeResponse(
            Data("{\"id\":\"request_1\",\"result\":{\"status\":\"ok\"}}".utf8)
        )

        XCTAssertEqual(response.id, .string("request_1"))
        XCTAssertEqual(response.result, .object(["status": .string("ok")]))
    }

    func testLocalImageUserInputEncodesPathPayload() {
        XCTAssertEqual(
            CodexUserInput.localImage(path: "/tmp/example.png").jsonValue,
            .object([
                "type": .string("localImage"),
                "path": .string("/tmp/example.png")
            ])
        )
    }

    func testThreadCodecDecodesTurnsIntoTranscriptSnapshots() throws {
        let threadValue: JSONValue = .object([
            "id": .string("thread_123"),
            "cwd": .string("/tmp/workspace"),
            "preview": .string("Resume me"),
            "modelProvider": .string("openai"),
            "name": .string("Resume thread"),
            "createdAt": .number(1_700_000_000),
            "updatedAt": .number(1_700_000_120),
            "status": .object([
                "type": .string("active"),
                "activeFlags": .array([.string("waitingOnUserInput")])
            ]),
            "turns": .array([
                .object([
                    "id": .string("turn_1"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("user_1"),
                            "type": .string("userMessage"),
                            "content": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string("hello")
                                ])
                            ])
                        ]),
                        .object([
                            "id": .string("assistant_1"),
                            "type": .string("agentMessage"),
                            "text": .string("world"),
                            "phase": .string("final_answer")
                        ])
                    ])
                ])
            ])
        ])

        let snapshot = try CodexThreadCodec.decodeThreadSnapshot(from: threadValue)

        XCTAssertEqual(snapshot.id, "thread_123")
        XCTAssertEqual(snapshot.latestTurnID, "turn_1")
        XCTAssertEqual(snapshot.activeTurnID, nil)
        XCTAssertEqual(snapshot.turns.count, 1)

        guard case let .userMessage(userText) = snapshot.turns[0].items[0] else {
            return XCTFail("Expected decoded user message item.")
        }
        XCTAssertEqual(userText, "hello")

        guard case let .assistantMessage(assistantText, phase) = snapshot.turns[0].items[1] else {
            return XCTFail("Expected decoded assistant message item.")
        }
        XCTAssertEqual(assistantText, "world")
        XCTAssertEqual(phase, .finalAnswer)
    }

    func testThreadListCodecDecodesNextCursorForPagination() throws {
        let page = try CodexThreadCodec.decodeThreadListPage(
            from: [
                "data": .array([
                    .object([
                        "id": .string("thread_123"),
                        "cwd": .string("/tmp/workspace"),
                        "preview": .string("Resume me"),
                        "modelProvider": .string("openai"),
                        "name": .string("Resume thread"),
                        "createdAt": .number(1_700_000_000),
                        "updatedAt": .number(1_700_000_120),
                        "status": .object([
                            "type": .string("idle")
                        ])
                    ])
                ]),
                "nextCursor": .string("cursor-2")
            ]
        )

        XCTAssertEqual(page.threads.count, 1)
        XCTAssertEqual(page.threads.first?.id, "thread_123")
        XCTAssertEqual(page.nextCursor, "cursor-2")
    }

    func testThreadListCodecToleratesSnakeCaseAndMissingOptionalSummaryFields() throws {
        let page = try CodexThreadCodec.decodeThreadListPage(
            from: [
                "threads": .array([
                    .object([
                        "id": .string("thread_456"),
                        "path": .string("/tmp/workspace"),
                        "name": .string("Resume thread"),
                        "created_at": .string("2026-03-31T13:26:55Z"),
                        "updated_at": .number(1_700_000_120),
                        "status": .string("idle")
                    ])
                ])
            ]
        )

        let thread = try XCTUnwrap(page.threads.first)
        XCTAssertEqual(thread.id, "thread_456")
        XCTAssertEqual(thread.cwd, "/tmp/workspace")
        XCTAssertEqual(thread.preview, "Resume thread")
        XCTAssertEqual(thread.modelProvider, "unknown")
        XCTAssertEqual(thread.status, .idle)
    }

    func testThreadListCodecSkipsMalformedEntriesWhenOtherThreadsDecode() throws {
        let page = try CodexThreadCodec.decodeThreadListPage(
            from: [
                "data": .array([
                    .object([
                        "id": .string("thread_good"),
                        "cwd": .string("/tmp/workspace"),
                        "preview": .string("Resume me"),
                        "modelProvider": .string("openai"),
                        "createdAt": .number(1_700_000_000),
                        "updatedAt": .number(1_700_000_120),
                        "status": .object([
                            "type": .string("idle")
                        ])
                    ]),
                    .object([
                        "cwd": .string("/tmp/malformed")
                    ])
                ])
            ]
        )

        XCTAssertEqual(page.threads.map(\.id), ["thread_good"])
    }

    func testThreadListCodecThrowsWhenAllEntriesMalformed() {
        XCTAssertThrowsError(
            try CodexThreadCodec.decodeThreadListPage(
                from: [
                    "data": .array([
                        .object([
                            "cwd": .string("/tmp/malformed")
                        ]),
                        .object([
                            "status": .string("idle")
                        ])
                    ])
                ]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("decoded 0 of 2"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testResponseDecoderHandlesCapturedRealThreadListPayloadWhenAvailable() throws {
        let capturePath = "/tmp/cotg-thread-list-capture.jsonl"
        guard FileManager.default.fileExists(atPath: capturePath) else {
            throw XCTSkip("No captured real thread/list payload is available at \(capturePath).")
        }

        let contents = try String(contentsOfFile: capturePath, encoding: .utf8)
        let line = try XCTUnwrap(
            contents.split(whereSeparator: \.isNewline).last.map(String.init),
            "Expected the capture file to contain a thread/list result line."
        )

        let envelope = try CodexRPCLineCodec.decodeResponse(Data(line.utf8))
        XCTAssertEqual(envelope.id, 2)
        XCTAssertNotNil(envelope.result?.objectValue?["data"]?.arrayValue)
    }

    func testSessionRPCMapsPlanDeltaIntoLiveActivityEvent() {
        let envelope = CodexRPCResponseEnvelope(
            method: "item/plan/delta",
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_plan"),
                "delta": .string("1. Check the mirror path.\n")
            ])
        )

        guard case let .activity(activity)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected a live activity event.")
        }

        XCTAssertEqual(activity.kind, .planDelta)
        XCTAssertEqual(activity.threadID, "thread_123")
        XCTAssertEqual(activity.turnID, "turn_456")
        XCTAssertEqual(activity.itemID, "item_plan")
        XCTAssertEqual(activity.text, "1. Check the mirror path.\n")
        XCTAssertFalse(activity.shouldRefreshThread)
    }

    func testSessionRPCMapsReasoningAndCommandOutputDeltasIntoLiveActivityEvents() {
        let reasoningEnvelope = CodexRPCResponseEnvelope(
            method: "item/reasoning/summaryTextDelta",
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_reasoning"),
                "delta": .string("Thinking through the transport boundary.")
            ])
        )
        let commandEnvelope = CodexRPCResponseEnvelope(
            method: "item/commandExecution/outputDelta",
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_command"),
                "delta": .string("swift test passed\n")
            ])
        )

        guard case let .activity(reasoning)? = CodexSessionRPC.liveEvent(from: reasoningEnvelope),
              case let .activity(command)? = CodexSessionRPC.liveEvent(from: commandEnvelope) else {
            return XCTFail("Expected live activity events.")
        }

        XCTAssertEqual(reasoning.kind, .reasoningDelta)
        XCTAssertEqual(reasoning.text, "Thinking through the transport boundary.")
        XCTAssertEqual(command.kind, .commandExecutionOutputDelta)
        XCTAssertEqual(command.text, "swift test passed\n")
    }

    func testSessionRPCTruncatesLargeCommandOutputDeltaForLiveMirror() {
        let largeOutput = String(repeating: "x", count: 20_000)
        let commandEnvelope = CodexRPCResponseEnvelope(
            method: "item/commandExecution/outputDelta",
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_command"),
                "delta": .string(largeOutput)
            ])
        )

        guard case let .activity(command)? = CodexSessionRPC.liveEvent(from: commandEnvelope) else {
            return XCTFail("Expected a live activity event.")
        }

        let text = command.text ?? ""
        XCTAssertEqual(command.kind, .commandExecutionOutputDelta)
        XCTAssertLessThan(text.count, largeOutput.count)
        XCTAssertTrue(text.hasPrefix(String(repeating: "x", count: 16_384)))
        XCTAssertTrue(text.contains("characters omitted from the iPhone live mirror"))
    }

    func testSessionRPCLabelsRetryingRuntimeErrorsAsMacSideRetries() {
        let envelope = CodexRPCResponseEnvelope(
            method: "error",
            params: .object([
                "message": .string("Reconnecting... 2/5"),
                "willRetry": .bool(true)
            ])
        )

        guard case let .configWarning(message)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected retrying errors to stay non-fatal.")
        }

        XCTAssertEqual(message, "Mac-side Codex retry: Reconnecting... 2/5")
    }

    func testSessionRPCMapsThreadRefreshEventsIntoLiveActivityEvents() {
        let statusEnvelope = CodexRPCResponseEnvelope(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string("thread_123"),
                "status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([.string("waitingOnUserInput")])
                ])
            ])
        )
        let completedEnvelope = CodexRPCResponseEnvelope(
            method: "item/completed",
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "item": .object([
                    "id": .string("item_file"),
                    "type": .string("fileChange")
                ])
            ])
        )

        guard case let .activity(status)? = CodexSessionRPC.liveEvent(from: statusEnvelope),
              case let .activity(completed)? = CodexSessionRPC.liveEvent(from: completedEnvelope) else {
            return XCTFail("Expected live activity events.")
        }

        XCTAssertEqual(status.kind, .threadStatusChanged)
        XCTAssertEqual(status.threadID, "thread_123")
        XCTAssertEqual(status.text, "Thread is active: waitingOnUserInput.")
        XCTAssertTrue(status.shouldRefreshThread)
        XCTAssertEqual(completed.kind, .itemCompleted)
        XCTAssertEqual(completed.itemID, "item_file")
        XCTAssertEqual(completed.itemType, "fileChange")
        XCTAssertTrue(completed.shouldRefreshThread)
    }

    func testSessionRPCMapsApprovalRequestIntoLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: 7,
            method: "item/permissions/requestApproval",
            result: nil,
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_789"),
                "reason": .string("Need network access."),
                "permissions": .object([
                    "fileSystem": .object([
                        "read": .array([.string("/tmp/read")]),
                        "write": .array([.string("/tmp/write")])
                    ]),
                    "network": .object([
                        "enabled": .bool(true)
                    ])
                ])
            ]),
            error: nil
        )

        guard case let .approvalRequested(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected an approval live event.")
        }

        XCTAssertEqual(request.id, .int(7))
        XCTAssertEqual(request.kind.rawValue, CodexApprovalRequestKind.permissions.rawValue)
        XCTAssertEqual(request.method, .permissionsRequestApproval)
        XCTAssertEqual(request.threadID, "thread_123")
        XCTAssertEqual(request.requestedPermissions?.readRoots, ["/tmp/read"])
        XCTAssertEqual(request.requestedPermissions?.writeRoots, ["/tmp/write"])
        XCTAssertEqual(request.requestedPermissions?.networkEnabled, true)
    }

    func testServerInitiatedEnvelopeClassificationPrefersMethodEvenWhenIDIsPresent() {
        let envelope = CodexRPCResponseEnvelope(
            id: 3,
            method: "item/commandExecution/requestApproval",
            result: nil,
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_789"),
                "command": .string("touch ~/.cotg_approval_probe_test-iphone")
            ]),
            error: nil
        )

        XCTAssertTrue(CodexSessionRPC.isServerInitiatedEnvelope(envelope))

        guard case let .approvalRequested(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected a method-bearing envelope with an id to stay classified as a server request.")
        }

        XCTAssertEqual(request.id, .int(3))
        XCTAssertEqual(request.threadID, "thread_123")
        XCTAssertEqual(request.turnID, "turn_456")
        XCTAssertEqual(request.summary, "touch ~/.cotg_approval_probe_test-iphone")
    }

    func testSessionRPCMapsLegacyExecCommandApprovalIntoLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: 17,
            method: "execCommandApproval",
            result: nil,
            params: .object([
                "conversationId": .string("thread_legacy"),
                "callId": .string("call_123"),
                "approvalId": .string("approval_legacy"),
                "command": .array([
                    .string("touch"),
                    .string("~/.cotg_approval_probe_test-iphone")
                ]),
                "cwd": .string("/workspace/coding-on-the-go"),
                "reason": .string("Need approval to write outside the sandbox.")
            ]),
            error: nil
        )

        guard case let .approvalRequested(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected a legacy command-approval live event.")
        }

        XCTAssertEqual(request.id, .int(17))
        XCTAssertEqual(request.kind, .commandExecution)
        XCTAssertEqual(request.method, .execCommandApproval)
        XCTAssertEqual(request.threadID, "thread_legacy")
        XCTAssertNil(request.turnID)
        XCTAssertEqual(request.itemID, "call_123")
        XCTAssertEqual(request.approvalID, "approval_legacy")
        XCTAssertEqual(request.summary, "touch ~/.cotg_approval_probe_test-iphone")
    }

    func testSessionRPCMapsLegacyApplyPatchApprovalIntoLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: 18,
            method: "applyPatchApproval",
            result: nil,
            params: .object([
                "conversationId": .string("thread_legacy"),
                "callId": .string("patch_123"),
                "grantRoot": .string("/workspace/.asc"),
                "reason": .string("Need to update the ASC profile."),
                "fileChanges": .object([
                    "/workspace/.asc/config.json": .object([:])
                ])
            ]),
            error: nil
        )

        guard case let .approvalRequested(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected a legacy apply-patch approval live event.")
        }

        XCTAssertEqual(request.id, .int(18))
        XCTAssertEqual(request.kind, .fileChange)
        XCTAssertEqual(request.method, .applyPatchApproval)
        XCTAssertEqual(request.threadID, "thread_legacy")
        XCTAssertNil(request.turnID)
        XCTAssertEqual(request.itemID, "patch_123")
        XCTAssertEqual(request.summary, "Approve file changes under /workspace/.asc.")
    }

    func testSessionRPCBuildsPermissionApprovalResultEnvelope() {
        let request = CodexApprovalRequest(
            id: 9,
            kind: .permissions,
            threadID: "thread_123",
            turnID: "turn_456",
            itemID: "item_789",
            summary: "Approve network access.",
            requestedPermissions: CodexRequestedPermissions(
                readRoots: ["/tmp/read"],
                writeRoots: ["/tmp/write"],
                networkEnabled: true
            )
        )

        let envelope = CodexSessionRPC.approvalResultEnvelope(
            request: request,
            decision: .grantRequestedPermissions(scopeSession: true)
        )

        XCTAssertEqual(envelope.id, .int(9))
        XCTAssertEqual(
            envelope.result.value,
            [
                "permissions": .object([
                    "fileSystem": .object([
                        "read": .array([.string("/tmp/read")]),
                        "write": .array([.string("/tmp/write")])
                    ]),
                    "network": .object([
                        "enabled": .bool(true)
                    ])
                ]),
                "scope": .string("session")
            ]
        )
    }

    func testSessionRPCBuildsLegacyExecCommandApprovalResultEnvelope() {
        let request = CodexApprovalRequest(
            id: 10,
            kind: .commandExecution,
            method: .execCommandApproval,
            threadID: "thread_legacy",
            itemID: "call_123",
            summary: "touch ~/.cotg_approval_probe_test-iphone"
        )

        let envelope = CodexSessionRPC.approvalResultEnvelope(
            request: request,
            decision: .acceptForSession
        )

        XCTAssertEqual(envelope.id, .int(10))
        XCTAssertEqual(
            envelope.result.value,
            [
                "decision": .string("approved_for_session")
            ]
        )
    }

    func testSessionRPCRejectsEmptyTurnInput() {
        XCTAssertThrowsError(
            try CodexSessionRPC.startTurnRequest(
                id: 1,
                threadID: "thread_123",
                input: [],
                model: nil,
                effort: nil,
                collaborationMode: nil
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "turn/start requires at least one input item."
            )
        }
    }

    func testModelListDecodesFutureVisibleModelsAndFiltersHiddenEntries() throws {
        let response = CodexRPCResponseEnvelope(
            id: .int(2),
            result: .object([
                "data": .array([
                    modelListItem(
                        id: "gpt-5.6",
                        displayName: "GPT-5.6",
                        description: "Future host-provided model",
                        isDefault: false,
                        hidden: false
                    ),
                    modelListItem(
                        id: "internal-test-model",
                        displayName: "Internal",
                        description: "Hidden internal model",
                        isDefault: false,
                        hidden: true
                    )
                ])
            ])
        )

        let models = try CodexSessionRPC.decodeModels(from: response)

        XCTAssertEqual(models.map(\.model), ["gpt-5.6"])
        XCTAssertEqual(models.first?.displayName, "GPT-5.6")
        XCTAssertEqual(models.first?.supportedReasoningEfforts.map(\.effort), [.low, .medium, .high, .xhigh])
        XCTAssertTrue(models.first?.supportsPersonality == true)
    }

    func testModelListDefaultsOptionalFutureModelMetadata() throws {
        let response = CodexRPCResponseEnvelope(
            id: .int(3),
            result: .object([
                "data": .array([
                    .object([
                        "id": .string("gpt-5.7"),
                        "model": .string("gpt-5.7")
                    ])
                ])
            ])
        )

        let model = try XCTUnwrap(CodexSessionRPC.decodeModels(from: response).first)

        XCTAssertEqual(model.model, "gpt-5.7")
        XCTAssertEqual(model.displayName, "gpt-5.7")
        XCTAssertEqual(model.description, "")
        XCTAssertFalse(model.hidden)
        XCTAssertFalse(model.isDefault)
        XCTAssertEqual(model.defaultReasoningEffort, .medium)
        XCTAssertEqual(model.supportedReasoningEfforts.map(\.effort), [.low, .medium, .high, .xhigh])
    }

    func testStartThreadRequestEncodesExecutionOverrides() throws {
        let request = CodexSessionRPC.startThreadRequest(
            id: 1,
            options: CodexThreadExecutionOptions(
                cwd: "/tmp/workspace",
                model: "gpt-5.4",
                approvalPolicy: "never",
                sandboxMode: .readOnly
            )
        )

        let payload = try requestPayload(request)

        XCTAssertEqual(payload["method"] as? String, "thread/start")
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["cwd"] as? String, "/tmp/workspace")
    }

    func testResumeThreadRequestEncodesExecutionOverrides() throws {
        let request = CodexSessionRPC.resumeThreadRequest(
            id: 2,
            threadID: "thread_123",
            options: CodexThreadExecutionOptions(
                cwd: "/tmp/workspace",
                model: "gpt-5.4",
                approvalPolicy: "on-request",
                sandboxMode: .workspaceWrite
            )
        )

        let payload = try requestPayload(request)

        XCTAssertEqual(payload["method"] as? String, "thread/resume")
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread_123")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["sandbox"] as? String, "workspace-write")
    }

    func testThreadStartAndResumeDecodeModelAndReasoningEffort() throws {
        let started = try CodexSessionRPC.decodeStartedThread(
            from: CodexRPCResponseEnvelope(
                id: .int(10),
                result: .object([
                    "thread": .object([
                        "id": .string("thread_123")
                    ]),
                    "cwd": .string("/tmp/workspace"),
                    "model": .string("gpt-5.5"),
                    "reasoningEffort": .string("xhigh")
                ])
            )
        )

        XCTAssertEqual(started.model, "gpt-5.5")
        XCTAssertEqual(started.reasoningEffort, .xhigh)

        let resumed = try CodexSessionRPC.decodeResumedThread(
            from: CodexRPCResponseEnvelope(
                id: .int(11),
                result: .object([
                    "thread": .object([
                        "id": .string("thread_123"),
                        "cwd": .string("/tmp/workspace"),
                        "preview": .string("Resume me"),
                        "modelProvider": .string("openai"),
                        "createdAt": .number(1_700_000_000),
                        "updatedAt": .number(1_700_000_120),
                        "status": .object([
                            "type": .string("idle")
                        ]),
                        "turns": .array([])
                    ]),
                    "cwd": .string("/tmp/workspace"),
                    "model": .string("gpt-5.5"),
                    "reasoning_effort": .string("xhigh")
                ])
            )
        )

        XCTAssertEqual(resumed.model, "gpt-5.5")
        XCTAssertEqual(resumed.reasoningEffort, .xhigh)
    }

    func testTurnStartRequestEncodesSandboxPolicyOverride() throws {
        let request = try CodexSessionRPC.startTurnRequest(
            id: 3,
            threadID: "thread_123",
            input: [.text("hello")],
            options: CodexTurnExecutionOptions(
                approvalPolicy: "on-request",
                sandboxPolicy: .workspaceWrite(
                    writableRoots: ["/tmp/workspace"],
                    readAccess: .restricted(includePlatformDefaults: true, readableRoots: ["/tmp/read-only"]),
                    networkAccess: true,
                    excludeTmpdirEnvVar: false,
                    excludeSlashTmp: false
                ),
                effort: .medium
            )
        )

        let payload = try requestPayload(request)

        XCTAssertEqual(payload["method"] as? String, "turn/start")
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        let sandboxPolicy = try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandboxPolicy["type"] as? String, "workspaceWrite")
        XCTAssertEqual(sandboxPolicy["writableRoots"] as? [String], ["/tmp/workspace"])
        let readOnlyAccess = try XCTUnwrap(sandboxPolicy["readOnlyAccess"] as? [String: Any])
        XCTAssertEqual(readOnlyAccess["readableRoots"] as? [String], ["/tmp/read-only"])
        XCTAssertEqual(sandboxPolicy["networkAccess"] as? Bool, true)
    }

    func testDecodeBaselineConfigSnapshotTreatsConfigAsBaseline() throws {
        let response = CodexRPCResponseEnvelope(
            id: 4,
            method: nil,
            result: .object([
                "config": .object([
                    "approval_policy": .string("never"),
                    "sandbox_mode": .string("workspace-write"),
                    "sandbox_workspace_write": .object([
                        "writable_roots": .array([.string("/tmp/workspace")]),
                        "network_access": .bool(true)
                    ])
                ])
            ]),
            params: nil,
            error: nil
        )

        let snapshot = try CodexSessionRPC.decodeBaselineConfigSnapshot(from: response)

        XCTAssertEqual(snapshot.approvalPolicy, "never")
        XCTAssertEqual(snapshot.sandboxMode, "workspace-write")
        XCTAssertEqual(snapshot.writableRoots, ["/tmp/workspace"])
        XCTAssertEqual(snapshot.networkAccess, true)
    }

    func testDecodeConfigRequirementsSnapshot() throws {
        let response = CodexRPCResponseEnvelope(
            id: 5,
            method: nil,
            result: .object([
                "requirements": .object([
                    "allowedApprovalPolicies": .array([.string("never"), .string("on-request")]),
                    "allowedSandboxModes": .array([.string("read-only")]),
                    "allowedWebSearchModes": .array([.string("enabled")]),
                    "featureRequirements": .object([
                        "threadResumeOverrides": .bool(false)
                    ]),
                    "enforceResidency": .string("none")
                ])
            ]),
            params: nil,
            error: nil
        )

        let snapshot = try CodexSessionRPC.decodeConfigRequirementsSnapshot(from: response)

        XCTAssertEqual(snapshot.allowedApprovalPolicies, ["never", "on-request"])
        XCTAssertEqual(snapshot.allowedSandboxModes, ["read-only"])
        XCTAssertEqual(snapshot.allowedWebSearchModes, ["enabled"])
        XCTAssertEqual(snapshot.featureRequirements?["threadResumeOverrides"], false)
        XCTAssertEqual(snapshot.enforceResidency, "none")
    }

    func testSessionRPCMapsStructuredUserInputRequestIntoLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: 8,
            method: "item/tool/requestUserInput",
            result: nil,
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_789"),
                "questions": .array([
                    .object([
                        "id": .string("mode"),
                        "question": .string("Which mode should we use?"),
                        "options": .array([
                            .object([
                                "label": .string("Read only"),
                                "description": .string("Keeps writes disabled.")
                            ])
                        ])
                    ])
                ])
            ]),
            error: nil
        )

        guard case let .structuredUserInputRequested(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected a structured user-input live event.")
        }

        XCTAssertEqual(request.id, .int(8))
        XCTAssertEqual(request.prompt.questions.first?.id, "mode")
        XCTAssertEqual(request.prompt.questions.first?.options.first?.label, "Read only")
    }

    func testSessionRPCMapsUnsupportedServerRequestIntoLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: 9,
            method: "item/tool/call",
            result: nil,
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456")
            ]),
            error: nil
        )

        guard case let .serverRequestUnsupported(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected an unsupported server-request live event.")
        }

        XCTAssertEqual(request.id, .int(9))
        XCTAssertEqual(request.method, "item/tool/call")
        XCTAssertEqual(request.threadID, "thread_123")
        XCTAssertEqual(request.turnID, "turn_456")
    }

    func testSessionRPCMapsStringIdentifierApprovalRequestIntoLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: "request_approval_7",
            method: "item/commandExecution/requestApproval",
            result: nil,
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456"),
                "itemId": .string("item_789"),
                "command": .string("touch ~/.cotg_approval_probe_test-iphone")
            ]),
            error: nil
        )

        guard case let .approvalRequested(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected a string-id approval live event.")
        }

        XCTAssertEqual(request.id, .string("request_approval_7"))
        XCTAssertEqual(request.threadID, "thread_123")
        XCTAssertEqual(request.turnID, "turn_456")
        XCTAssertEqual(request.summary, "touch ~/.cotg_approval_probe_test-iphone")
    }

    func testSessionRPCMapsUnknownStringIdentifierServerRequestIntoUnsupportedLiveEvent() {
        let envelope = CodexRPCResponseEnvelope(
            id: "request_unknown_9",
            method: "mcpServer/elicitation/request",
            result: nil,
            params: .object([
                "threadId": .string("thread_123"),
                "turnId": .string("turn_456")
            ]),
            error: nil
        )

        guard case let .serverRequestUnsupported(request)? = CodexSessionRPC.liveEvent(from: envelope) else {
            return XCTFail("Expected an unsupported server-request live event for string identifiers.")
        }

        XCTAssertEqual(request.id, .string("request_unknown_9"))
        XCTAssertEqual(request.method, "mcpServer/elicitation/request")
        XCTAssertEqual(request.threadID, "thread_123")
        XCTAssertEqual(request.turnID, "turn_456")

        let errorEnvelope = CodexSessionRPC.unsupportedServerRequestErrorEnvelope(
            id: request.id,
            method: request.method
        )
        XCTAssertEqual(errorEnvelope.id, .string("request_unknown_9"))
        XCTAssertEqual(errorEnvelope.error.message, "Client does not support server request mcpServer/elicitation/request.")
    }

    private func modelListItem(
        id: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        hidden: Bool
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "model": .string(id),
            "displayName": .string(displayName),
            "description": .string(description),
            "isDefault": .bool(isDefault),
            "hidden": .bool(hidden),
            "defaultReasoningEffort": .string("medium"),
            "inputModalities": .array([.string("text"), .string("image")]),
            "supportedReasoningEfforts": .array([
                .object([
                    "reasoningEffort": .string("low"),
                    "description": .string("Fast")
                ]),
                .object([
                    "reasoningEffort": .string("medium"),
                    "description": .string("Balanced")
                ]),
                .object([
                    "reasoningEffort": .string("high"),
                    "description": .string("Deep")
                ]),
                .object([
                    "reasoningEffort": .string("xhigh"),
                    "description": .string("Extra deep")
                ])
            ]),
            "supportsPersonality": .bool(true),
            "additionalSpeedTiers": .array([.string("fast")])
        ])
    }

    private func requestPayload<Params: Encodable & Sendable>(
        _ request: CodexRPCRequest<Params>
    ) throws -> [String: Any] {
        let data = try CodexRPCLineCodec.encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object
    }
}
