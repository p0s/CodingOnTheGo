import XCTest
@testable import SSHTransport
import CodexRPC

final class SSHTransportTests: XCTestCase {
    private static let workspaceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path
    private static let localhostRawKeyPath = ProcessInfo.processInfo.environment["COTG_TEST_SSH_RAW_KEY_PATH"] ?? "/tmp/cotg_app_test_key.raw"
    private static let localhostSSHUser = ProcessInfo.processInfo.environment["COTG_TEST_SSH_USER"]
        ?? ProcessInfo.processInfo.environment["USER"]
        ?? NSUserName()
    private static let externalTailnetHost = ProcessInfo.processInfo.environment["COTG_TEST_EXTERNAL_TAILNET_DNS_NAME"]
    private static let externalTailnetHostKey = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_KEY"]
    private static let realHost = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST"]
    private static let realHostKey = ProcessInfo.processInfo.environment["COTG_TEST_SSH_HOST_KEY"]
    private static let realHostPort = UInt16(ProcessInfo.processInfo.environment["COTG_TEST_SSH_PORT"] ?? "")
        ?? 22

    func testLoopbackListenerLogDetectsUnhealthyCodexState() {
        XCTAssertTrue(
            CodexSSHAppServerClient.loopbackListenerLogIndicatesUnhealthyState(
                "ERROR codex_app_server: failed to initialize sqlite state db: database disk image is malformed"
            )
        )
        XCTAssertTrue(
            CodexSSHAppServerClient.loopbackListenerLogIndicatesUnhealthyState(
                "error returned from database: (code: 11) database disk image is malformed"
            )
        )
        XCTAssertFalse(
            CodexSSHAppServerClient.loopbackListenerLogIndicatesUnhealthyState(
                "codex app-server (WebSockets) listening on: ws://127.0.0.1:9494"
            )
        )
    }

    func testAppServerStreamParserReassemblesArtificiallySplitEnvelope() throws {
        var parser = SSHAppServerStreamParser()
        let repeatedText = String(repeating: "app-store-upload-", count: 8_000)
        let payload = """
        {"id":2,"result":{"thread":{"id":"thread_123","preview":"\(repeatedText)"}}}
        """
        let original = Data(payload.utf8)
        let fragmented = Self.injectNewlines(into: original, every: 69_795) + Data([0x0A])

        let events = try parser.append(fragmented)
        let decodedEnvelopes = events.compactMap { event -> (CodexRPCResponseEnvelope, Data)? in
            guard case let .envelope(envelope, payload) = event else {
                return nil
            }
            return (envelope, payload)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(decodedEnvelopes.count, 1)
        XCTAssertEqual(decodedEnvelopes.first?.0.id, 2)
        XCTAssertEqual(decodedEnvelopes.first?.1.count, original.count)
    }

    func testAppServerStreamParserDiscardsOversizedIncompleteEnvelopeAndRecovers() throws {
        var parser = SSHAppServerStreamParser(maxBufferedJSONFragmentBytes: 96)
        let prefix = Data(#"{"method":"item/commandExecution/outputDelta","params":{"delta":""#.utf8)
        let oversizedBody = Data(String(repeating: "x", count: 128).utf8)
        let validEnvelope = Data(#"{"id":2,"result":{"thread":{"id":"thread_123"}}}"#.utf8)

        XCTAssertNoThrow(try parser.append(prefix + oversizedBody))

        let events = try parser.append(Data(#""}}"#.utf8) + validEnvelope)
        XCTAssertEqual(events.count, 2)
        guard case let .shellLine(diagnostic) = events.first else {
            XCTFail("Expected oversized payload diagnostic, got \(String(describing: events.first))")
            return
        }
        XCTAssertTrue(diagnostic.contains("Dropped oversized app-server JSON payload"))
        XCTAssertTrue(diagnostic.contains("limit is 96 bytes"))

        guard case let .envelope(envelope, decodedPayload) = events.last else {
            XCTFail("Expected parser to recover at the next JSON envelope.")
            return
        }
        XCTAssertEqual(envelope.id, .int(2))
        XCTAssertEqual(decodedPayload, validEnvelope)
    }

    func testAppServerStreamParserReassemblesCapturedResumeEnvelopeWhenAvailable() throws {
        let capturePath = "/tmp/cotg-thread-resume-capture.jsonl"
        guard FileManager.default.fileExists(atPath: capturePath) else {
            throw XCTSkip("No captured real thread/resume payload is available at \(capturePath).")
        }

        let contents = try String(contentsOfFile: capturePath, encoding: .utf8)
        let originalLine = try XCTUnwrap(
            contents
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .max(by: { $0.utf8.count < $1.utf8.count }),
            "Expected the capture file to contain a thread/resume result line."
        )

        var parser = SSHAppServerStreamParser()
        let original = Data(originalLine.utf8)
        let fragmented = Self.injectNewlines(into: original, every: 69_795) + Data([0x0A])

        let events = try parser.append(fragmented)
        let decodedEnvelopes = events.compactMap { event -> (CodexRPCResponseEnvelope, Data)? in
            guard case let .envelope(envelope, payload) = event else {
                return nil
            }
            return (envelope, payload)
        }

        XCTAssertEqual(decodedEnvelopes.count, 1)
        XCTAssertEqual(decodedEnvelopes.first?.0.id, 2)
        XCTAssertEqual(decodedEnvelopes.first?.1.count, original.count)
        XCTAssertNotNil(decodedEnvelopes.first?.0.result?.objectValue?["thread"])
    }

    func testAppServerStreamParserRejectsMalformedCompleteEnvelope() {
        var parser = SSHAppServerStreamParser()

        XCTAssertThrowsError(
            try parser.append(Data("{\"id\":1,\"result\":{\"thread\":}}\n".utf8))
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Failed to decode app-server payload"),
                "Unexpected error: \(error)"
            )
        }
    }

    func testAppServerStreamParserIgnoresNullPaddingInsideLargeEnvelope() throws {
        var parser = SSHAppServerStreamParser()
        let repeatedText = String(repeating: "app-store-upload-", count: 8_000)
        let payload = """
        {"id":2,"result":{"thread":{"id":"thread_123","preview":"\(repeatedText)"}}}
        """
        let original = Data(payload.utf8)
        let padded = Self.injectByte(0x00, into: original, every: 91) + Data([0x0A])

        let events = try parser.append(padded)
        let decodedEnvelopes = events.compactMap { event -> (CodexRPCResponseEnvelope, Data)? in
            guard case let .envelope(envelope, payload) = event else {
                return nil
            }
            return (envelope, payload)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(decodedEnvelopes.count, 1)
        XCTAssertEqual(decodedEnvelopes.first?.0.id, 2)
        XCTAssertEqual(decodedEnvelopes.first?.1, original)
    }

    func testAppServerStreamParserRecoversFromInlineShellNoiseBeforeEnvelope() throws {
        var parser = SSHAppServerStreamParser()
        let payload = Data("{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread_123\"}}}\n".utf8)
        let events = try parser.append(Data("bootstrap-check ".utf8) + payload)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .shellLine("bootstrap-check "))

        guard case let .envelope(envelope, decodedPayload) = try XCTUnwrap(events.last) else {
            XCTFail("Expected the parser to recover the JSON envelope after inline shell noise.")
            return
        }
        XCTAssertEqual(envelope.id, .int(2))
        XCTAssertEqual(decodedPayload, Data(payload.dropLast()))
    }

    func testAppServerStreamParserDecodesBackToBackEnvelopesWithoutNewlineDelimiter() throws {
        var parser = SSHAppServerStreamParser()
        let first = Data("{\"id\":1,\"result\":{\"thread\":{\"id\":\"thread_1\"}}}".utf8)
        let second = Data("{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"thread_1\"}}".utf8)

        let events = try parser.append(first + second)
        let envelopes = events.compactMap { event -> CodexRPCResponseEnvelope? in
            guard case let .envelope(envelope, _) = event else {
                return nil
            }
            return envelope
        }

        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes.first?.id, .int(1))
        XCTAssertEqual(envelopes.last?.method, "thread/status/changed")
    }

    func testAppServerStreamParserDecodesServerRequestWithStringIdentifier() throws {
        var parser = SSHAppServerStreamParser()
        let payload = Data("{\"id\":\"request_123\",\"method\":\"mcpServer/elicitation/request\",\"params\":{\"threadId\":\"thread_1\",\"turnId\":\"turn_1\"}}".utf8)

        let events = try parser.append(payload)

        guard case let .envelope(envelope, decodedPayload) = try XCTUnwrap(events.first) else {
            XCTFail("Expected a decoded envelope for the string-id server request.")
            return
        }
        XCTAssertEqual(envelope.id, .string("request_123"))
        XCTAssertEqual(envelope.method, "mcpServer/elicitation/request")
        XCTAssertEqual(decodedPayload, payload)
    }

    func testBootstrapReadinessRequiresVerifiedAccess() {
        let status = SSHBootstrapStatus(
            remoteLoginEnabled: true,
            credentialsConfigured: true,
            hostKeyVerified: true
        )

        XCTAssertTrue(status.readyForBootstrap)
    }

    func testMismatchBlocksConnectionEvenWithCredential() {
        let snapshot = SSHConnectionSnapshot(
            bootstrap: SSHBootstrapStatus(
                remoteLoginEnabled: true,
                credentialsConfigured: true,
                hostKeyVerified: true
            ),
            trustState: .mismatch,
            credential: SSHCredentialDescriptor(
                username: Self.localhostSSHUser,
                kind: .generatedKey,
                isEncryptedAtRest: true
            )
        )

        XCTAssertEqual(
            snapshot.failureReason,
            "The SSH host key changed and must be re-trusted before continuing."
        )
    }

    func testCapturePresentedHostKeySurvivesAuthenticationFailure() async throws {
        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .password("invalid-password-for-host-key-scan"),
            hostValidation: .capturePresentedHostKey,
            cwd: Self.workspaceRoot,
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        do {
            try await client.connect(configuration: configuration, onEvent: { _ in })
            XCTFail("Expected host-key capture to abort the scan path.")
        } catch let CodexSSHError.capturedHostKey(openSSHKey) {
            XCTAssertTrue(openSSHKey.hasPrefix("ssh-ed25519 "), "Unexpected host key: \(openSSHKey)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCanResumeAndReadExistingThreadHistory() async throws {
        let keyURL = try requireLocalhostIntegration()

        let recorder = EventRecorder()
        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-tests-resume/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { event in
            Task {
                await recorder.record(event)
            }
        })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let thread = try await client.startThread(
            cwd: Self.workspaceRoot,
            model: nil
        )
        let turn = try await client.startTurn(threadID: thread.id, text: "Reply with COTG_RESUME_OK only.")
        let completed = try await recorder.waitForTurnCompletion(
            turnID: turn.id,
            timeoutNanoseconds: 120_000_000_000
        )
        XCTAssertTrue(completed)

        let resumed = try await client.resumeThread(
            threadID: thread.id,
            cwd: Self.workspaceRoot,
            model: nil
        )
        let readSnapshot = try await client.readThread(threadID: thread.id, includeTurns: true)

        XCTAssertEqual(resumed.thread.id, thread.id)
        XCTAssertEqual(readSnapshot.id, thread.id)
        XCTAssertFalse(resumed.thread.turns.isEmpty)
        XCTAssertEqual(readSnapshot.latestTurnID, turn.id)

        let resumedAssistantText = resumed.thread.turns
            .flatMap(\.items)
            .compactMap { item -> String? in
                if case let .assistantMessage(text, _) = item {
                    return text
                }
                return nil
            }
            .joined(separator: "\n")
        XCTAssertTrue(resumedAssistantText.contains("COTG_RESUME_OK"), "Unexpected resumed assistant text: \(resumedAssistantText)")

        let threadPage = try await client.listThreads(
            cwd: Self.workspaceRoot,
            limit: 20
        )
        XCTAssertTrue(threadPage.threads.contains(where: { $0.id == thread.id }))
    }

    func testCanStageAttachmentToLocalhostAndReadItBack() async throws {
        let keyURL = try requireLocalhostIntegration()

        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-tests/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { _ in })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let staged = try await client.stageAttachment(
            data: Data("attachment-ok".utf8),
            suggestedFilename: "note.txt"
        )
        let command = "cat \(shellQuote(staged.remotePath))"
        let result = try await client.execute(command: command)

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.standardOutput, "attachment-ok")
        XCTAssertTrue(staged.remotePath.contains("/attachments/"))
        XCTAssertTrue(staged.remotePath.hasSuffix(".txt"))
    }

    func testCanStartTurnWithStagedLocalImageInput() async throws {
        let keyURL = try requireLocalhostIntegration()

        let recorder = EventRecorder()
        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-tests-vision/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { event in
            Task {
                await recorder.record(event)
            }
        })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let models = try await client.listModels()
        guard let model = models.first(where: \.supportsImageInputs) ?? models.first else {
            throw XCTSkip("No model is available for localhost app-server testing.")
        }

        let thread = try await client.startThread(
            cwd: Self.workspaceRoot,
            model: model.model
        )
        let staged = try await client.stageAttachment(
            data: Self.tinyPNGData,
            suggestedFilename: "pixel.png"
        )
        let turn = try await client.startTurn(
            threadID: thread.id,
            input: [
                .text("Reply with COTG_ATTACHMENT_OK only."),
                .localImage(path: staged.remotePath)
            ],
            model: model.model,
            effort: .low
        )

        let completed = try await recorder.waitForTurnCompletion(turnID: turn.id, timeoutNanoseconds: 120_000_000_000)
        XCTAssertTrue(completed)
        let assistantText = await recorder.completedAssistantText()
        XCTAssertTrue(assistantText.contains("COTG_ATTACHMENT_OK"), "Unexpected assistant text: \(assistantText)")
    }

    func testCanConnectToExternalTailnetWithConfiguredSSHKey() async throws {
        let keyURL = try requireExternalTailnetIntegration()

        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: Self.externalTailnetHost!,
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .exactOpenSSHPublicKey(Self.externalTailnetHostKey!),
            cwd: Self.workspaceRoot,
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { _ in })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let models = try await client.listModels()
        XCTAssertFalse(models.isEmpty)
    }

    func testLocalhostBundleRuntimePreservesNeverDangerFullAccessAuthority() async throws {
        let keyURL = try requireLocalhostIntegration()

        let recorder = EventRecorder()
        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-tests-full-access/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { event in
            Task {
                await recorder.record(event)
            }
        })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let runtimeDescriptor = await client.runtimeDescriptor()
        let runtime = try XCTUnwrap(runtimeDescriptor)
        XCTAssertTrue(
            runtime.binaryPath.hasSuffix("/Codex.app/Contents/Resources/codex"),
            "Expected bundled Codex runtime, got \(runtime.binaryPath)"
        )

        let startedThread = try await client.startThread(
            options: CodexThreadExecutionOptions(
                cwd: Self.workspaceRoot,
                approvalPolicy: "never",
                sandboxMode: .dangerFullAccess
            )
        )
        XCTAssertEqual(startedThread.executionProfile?.approvalPolicy.effective, "never")
        XCTAssertEqual(startedThread.executionProfile?.sandboxMode.effective, "danger-full-access")
        XCTAssertEqual(startedThread.executionProfile?.readAccess.effective, .fullAccess)
        XCTAssertEqual(startedThread.executionProfile?.networkAccess.effective, true)

        let turn = try await client.startTurn(
            threadID: startedThread.id,
            input: [.text("Reply with COTG_FULL_ACCESS_OK only.")],
            options: CodexTurnExecutionOptions(
                approvalPolicy: "never",
                sandboxPolicy: .dangerFullAccess
            )
        )
        let completed = try await recorder.waitForTurnCompletion(
            turnID: turn.id,
            timeoutNanoseconds: 120_000_000_000
        )
        XCTAssertTrue(completed)
        let assistantText = await recorder.completedAssistantText()
        XCTAssertTrue(
            assistantText.contains("COTG_FULL_ACCESS_OK"),
            "Unexpected assistant text: \(assistantText)"
        )

        let resumed = try await client.resumeThread(
            threadID: startedThread.id,
            options: CodexThreadExecutionOptions(
                cwd: Self.workspaceRoot,
                approvalPolicy: "never",
                sandboxMode: .dangerFullAccess
            )
        )
        XCTAssertEqual(resumed.executionProfile?.approvalPolicy.effective, "never")
        XCTAssertEqual(resumed.executionProfile?.sandboxMode.effective, "danger-full-access")
        XCTAssertEqual(resumed.executionProfile?.readAccess.effective, .fullAccess)
        XCTAssertEqual(resumed.executionProfile?.networkAccess.effective, true)
    }

    func testLocalhostLoopbackListenerUsesLaunchctlJobWhenGuiSessionIsAvailable() async throws {
        let keyURL = try requireLocalhostIntegration()

        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-tests-codesign/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { _ in })
        defer {
            Task {
                try? await client.stopLoopbackListener()
                await client.disconnect()
            }
        }

        _ = try await client.startLoopbackListener(port: 9497)
        let healthy = try await client.loopbackListenerIsHealthy(port: 9497)
        XCTAssertTrue(healthy)

        let pidFile = "/tmp/cotg-sshtransport-tests-codesign/.codex/cotg-runtime/localhost-listener.pid"
        let result = try await client.execute(command: "cat \(shellQuote(pidFile))")
        XCTAssertEqual(
            result.exitStatus,
            0,
            "Expected localhost loopback listener metadata to be readable. stdout=\(result.standardOutput) stderr=\(result.errorOutput)"
        )
        XCTAssertTrue(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("launchctl:"),
            "Expected localhost loopback listener to run via launchctl submit. stdout=\(result.standardOutput)"
        )
    }

    func testRealHostBundleRuntimeBootstrapAndExecutionProfilePersistence() async throws {
        let integration = try requireRealHostIntegration()

        let recorder = EventRecorder()
        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: integration.host,
            port: integration.port,
            username: integration.username,
            authentication: .ed25519Seed(try Data(contentsOf: integration.keyURL)),
            hostValidation: .exactOpenSSHPublicKey(integration.hostKey),
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-real-host/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { event in
            Task {
                await recorder.record(event)
            }
        })
        defer {
            Task {
                try? await client.stopLoopbackListener()
                await client.disconnect()
            }
        }

        let runtimeDescriptor = await client.runtimeDescriptor()
        let runtime = try XCTUnwrap(runtimeDescriptor)
        XCTAssertTrue(
            runtime.binaryPath.hasSuffix("/Codex.app/Contents/Resources/codex"),
            "Expected bundled Codex runtime, got \(runtime.binaryPath)"
        )
        XCTAssertTrue(
            runtime.provenance == .appBundle || runtime.provenance == .otherAppBundle,
            "Expected app-bundle runtime provenance, got \(runtime.provenance.rawValue)"
        )

        _ = try await client.readConfig()
        _ = try await client.readConfigRequirements()

        let startedThread = try await client.startThread(
            options: CodexThreadExecutionOptions(
                cwd: Self.workspaceRoot,
                approvalPolicy: "never",
                sandboxMode: .readOnly
            )
        )
        XCTAssertEqual(startedThread.executionProfile?.approvalPolicy.effective, "never")
        XCTAssertEqual(startedThread.executionProfile?.sandboxMode.effective, "read-only")

        _ = try await client.startLoopbackListener(port: 9496)
        let loopbackHealthy = try await client.loopbackListenerIsHealthy(port: 9496)
        XCTAssertTrue(loopbackHealthy)

        let turn = try await client.startTurn(
            threadID: startedThread.id,
            input: [.text("Reply with COTG_REAL_HOST_OK only.")],
            options: CodexTurnExecutionOptions(
                approvalPolicy: "on-request",
                sandboxPolicy: .workspaceWrite(
                    writableRoots: [Self.workspaceRoot],
                    readAccess: .restricted(includePlatformDefaults: true, readableRoots: []),
                    networkAccess: true,
                    excludeTmpdirEnvVar: false,
                    excludeSlashTmp: false
                )
            )
        )

        let completed = try await recorder.waitForTurnCompletion(
            turnID: turn.id,
            timeoutNanoseconds: 120_000_000_000
        )
        XCTAssertTrue(completed)
        let assistantText = await recorder.completedAssistantText()
        XCTAssertTrue(
            assistantText.contains("COTG_REAL_HOST_OK"),
            "Unexpected assistant text: \(assistantText)"
        )

        let resumed = try await client.resumeThread(
            threadID: startedThread.id,
            options: CodexThreadExecutionOptions(
                cwd: Self.workspaceRoot,
                approvalPolicy: "on-request",
                sandboxMode: .workspaceWrite
            )
        )
        XCTAssertEqual(resumed.executionProfile?.approvalPolicy.effective, "on-request")
        XCTAssertEqual(resumed.executionProfile?.sandboxMode.effective, "workspace-write")
        XCTAssertEqual(resumed.executionProfile?.writableRoots.effective, [Self.workspaceRoot])
        XCTAssertEqual(resumed.executionProfile?.networkAccess.effective, true)
    }

    func testRealHostCanRoundTripCommandApprovalRequest() async throws {
        let integration = try requireRealHostIntegration()

        let recorder = EventRecorder()
        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: integration.host,
            port: integration.port,
            username: integration.username,
            authentication: .ed25519Seed(try Data(contentsOf: integration.keyURL)),
            hostValidation: .exactOpenSSHPublicKey(integration.hostKey),
            cwd: Self.workspaceRoot,
            codexHome: "/tmp/cotg-sshtransport-real-host-approval/.codex",
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { event in
            Task {
                await recorder.record(event)
            }
        })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let thread = try await client.startThread(
            options: CodexThreadExecutionOptions(
                cwd: Self.workspaceRoot,
                approvalPolicy: "on-request",
                sandboxMode: .readOnly
            )
        )
        let turn = try await client.startTurn(
            threadID: thread.id,
            input: [.text("Create a file named COTG_APPROVAL_TEST.txt in the current workspace containing exactly APPROVAL_OK, then reply with only CREATED. Do not answer until you have actually written the file.")],
            options: CodexTurnExecutionOptions(
                approvalPolicy: "on-request",
                sandboxPolicy: .readOnly(readAccess: .fullAccess, networkAccess: false)
            )
        )

        let approval = try await recorder.waitForApprovalRequest(
            turnID: turn.id,
            timeoutNanoseconds: 120_000_000_000
        )
        try await client.resolveApproval(approval, decision: .accept)

        let completed = try await recorder.waitForTurnCompletion(
            turnID: turn.id,
            timeoutNanoseconds: 120_000_000_000
        )
        XCTAssertTrue(completed)
        let assistantText = await recorder.completedAssistantText()
        XCTAssertEqual(assistantText.trimmingCharacters(in: .whitespacesAndNewlines), "CREATED")
        let fileCheck = try await client.execute(
            command: "bash -lc \(shellQuote("cat \(Self.workspaceRoot)/COTG_APPROVAL_TEST.txt"))"
        )
        XCTAssertEqual(fileCheck.exitStatus, 0)
        XCTAssertEqual(fileCheck.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "APPROVAL_OK")
        _ = try await client.execute(
            command: "bash -lc \(shellQuote("rm -f \(Self.workspaceRoot)/COTG_APPROVAL_TEST.txt"))"
        )
    }

    func testCanListRealCodexHomeThreadsOverLocalhostSSH() async throws {
        let keyURL = try requireLocalhostIntegration()

        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: nil,
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { _ in })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let page = try await client.listThreads(limit: 200, sortKey: "updated_at")
        XCTAssertFalse(page.threads.isEmpty)
    }

    func testCanListRealCodexHomeThreadsFromStateStoreOverLocalhostSSH() async throws {
        let keyURL = try requireLocalhostIntegration()

        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: nil,
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { _ in })
        defer {
            Task {
                await client.disconnect()
            }
        }

        let firstPage = try await client.listThreadsFromStateStore(limit: 5)
        XCTAssertEqual(firstPage.threads.count, 5)
        XCTAssertFalse(firstPage.threads.contains(where: { $0.cwd.isEmpty }))
        XCTAssertNotNil(firstPage.nextCursor)

        let secondPage = try await client.listThreadsFromStateStore(
            limit: 5,
            cursor: firstPage.nextCursor
        )
        XCTAssertEqual(secondPage.threads.count, 5)
        XCTAssertTrue(Set(firstPage.threads.map(\.id)).isDisjoint(with: secondPage.threads.map(\.id)))
    }

    func testStateStoreThreadPageDecodesRowsAndPagination() throws {
        let rawJSON = """
        [
          {
            "id": "thread-1",
            "cwd": "/workspace/coding-on-the-go",
            "title": "Finish remote Codex client\\nextra details",
            "first_user_message": "Continue the same real thread on iPhone.",
            "updated_at": 1774952920,
            "created_at": 1774934815,
            "model_provider": "openai"
          },
          {
            "id": "thread-2",
            "cwd": "/workspace/reference-app",
            "title": "Refine codex UI architecture",
            "first_user_message": "",
            "updated_at": 1774951000,
            "created_at": 1774920000,
            "model_provider": "openai"
          }
        ]
        """

        let page = try CodexSSHAppServerClient.decodeStateStoreThreadListPage(
            from: rawJSON,
            limit: 1,
            offset: 0
        )

        XCTAssertEqual(page.threads.count, 1)
        XCTAssertEqual(page.threads[0].id, "thread-1")
        XCTAssertEqual(page.threads[0].name, "Finish remote Codex client")
        XCTAssertEqual(page.threads[0].preview, "Continue the same real thread on iPhone.")
        XCTAssertEqual(page.nextCursor, "offset:1")
    }

    func testStateStoreFallbackCompactsTextLikeLegacyFacade() {
        let compacted = CodexSSHStateStoreFallback.compactText(
            "   first line with trailing spaces    \nsecond line ignored",
            maxLength: 12
        )

        XCTAssertEqual(compacted, "first line…")
    }

    func testRuntimeArtifactsUseNamespacedCodexHomeRootWhenAvailable() {
        let paths = CodexSSHRuntimeArtifacts.paths(for: testConfiguration(codexHome: "/tmp/cotg-tests/.codex"))

        XCTAssertEqual(paths.rootDirectory, "/tmp/cotg-tests/.codex/cotg-runtime")
        XCTAssertEqual(paths.attachmentsDirectory, "/tmp/cotg-tests/.codex/cotg-runtime/attachments")
        XCTAssertEqual(paths.loopbackPIDFile, "/tmp/cotg-tests/.codex/cotg-runtime/localhost-listener.pid")
        XCTAssertEqual(paths.loopbackLogFile, "/tmp/cotg-tests/.codex/cotg-runtime/localhost-listener.log")
    }

    func testRuntimeArtifactsFallBackToNamespacedTmpRootWithoutCodexHome() {
        let paths = CodexSSHRuntimeArtifacts.paths(for: testConfiguration(codexHome: nil))

        XCTAssertEqual(paths.rootDirectory, "/tmp/cotg-runtime")
        XCTAssertEqual(paths.attachmentsDirectory, "/tmp/cotg-runtime/attachments")
        XCTAssertEqual(paths.loopbackPIDFile, "/tmp/cotg-runtime/localhost-listener.pid")
        XCTAssertEqual(paths.loopbackLogFile, "/tmp/cotg-runtime/localhost-listener.log")
    }

    func testLocalPortForwardStartsWhenNetworkBootstrapIsForced() async throws {
        let keyURL = try requireLocalhostIntegration()
        let previousMode = getenv("COTG_SSH_BOOTSTRAP_MODE").map { String(cString: $0) }
        setenv("COTG_SSH_BOOTSTRAP_MODE", "network", 1)
        defer {
            if let previousMode {
                setenv("COTG_SSH_BOOTSTRAP_MODE", previousMode, 1)
            } else {
                unsetenv("COTG_SSH_BOOTSTRAP_MODE")
            }
        }

        let client = CodexSSHAppServerClient()
        let configuration = CodexSSHConfiguration(
            host: "localhost",
            username: Self.localhostSSHUser,
            authentication: .ed25519Seed(try Data(contentsOf: keyURL)),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )

        try await client.connect(configuration: configuration, onEvent: { _ in })
        defer {
            Task {
                try? await client.stopLocalPortForward()
                await client.disconnect()
            }
        }

        let forwardedURL = try await client.startLocalPortForward(remotePort: 22)
        XCTAssertEqual(forwardedURL.scheme, "ws")
        XCTAssertEqual(forwardedURL.host, "127.0.0.1")
        XCTAssertNotNil(forwardedURL.port)
    }

    private static let tinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAKbJr3sAAAAASUVORK5CYII=")!

    private func requireLocalhostIntegration() throws -> URL {
        guard ProcessInfo.processInfo.environment["COTG_ENABLE_LOCALHOST_INTEGRATION"] == "1" else {
            throw XCTSkip("Set COTG_ENABLE_LOCALHOST_INTEGRATION=1 to run localhost SSH integration tests.")
        }

        let keyURL = URL(fileURLWithPath: Self.localhostRawKeyPath)
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw XCTSkip("Localhost SSH test key is unavailable at \(keyURL.path).")
        }

        return keyURL
    }

    private func requireExternalTailnetIntegration() throws -> URL {
        let keyURL = try requireLocalhostIntegration()

        guard let host = Self.externalTailnetHost, !host.isEmpty else {
            throw XCTSkip("Set COTG_TEST_EXTERNAL_TAILNET_DNS_NAME to run external tailnet SSH integration tests.")
        }
        guard let hostKey = Self.externalTailnetHostKey, !hostKey.isEmpty else {
            throw XCTSkip("Set COTG_TEST_SSH_HOST_KEY to run external tailnet SSH integration tests.")
        }

        XCTAssertFalse(host.isEmpty)
        XCTAssertFalse(hostKey.isEmpty)
        return keyURL
    }

    private func requireRealHostIntegration() throws -> (
        host: String,
        port: UInt16,
        username: String,
        hostKey: String,
        keyURL: URL
    ) {
        guard ProcessInfo.processInfo.environment["COTG_ENABLE_REAL_HOST_INTEGRATION"] == "1" else {
            throw XCTSkip("Set COTG_ENABLE_REAL_HOST_INTEGRATION=1 to run real-host SSH integration tests.")
        }

        let keyURL = URL(fileURLWithPath: Self.localhostRawKeyPath)
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw XCTSkip("Real-host SSH test key is unavailable at \(keyURL.path).")
        }
        guard let host = Self.realHost, !host.isEmpty else {
            throw XCTSkip("Set COTG_TEST_SSH_HOST to run real-host SSH integration tests.")
        }
        guard let hostKey = Self.realHostKey, !hostKey.isEmpty else {
            throw XCTSkip("Set COTG_TEST_SSH_HOST_KEY to run real-host SSH integration tests.")
        }

        return (
            host: host,
            port: Self.realHostPort,
            username: Self.localhostSSHUser,
            hostKey: hostKey,
            keyURL: keyURL
        )
    }

    private func testConfiguration(codexHome: String?) -> CodexSSHConfiguration {
        CodexSSHConfiguration(
            host: "example.com",
            username: "tester",
            authentication: .password("password"),
            hostValidation: .acceptAllForTesting,
            cwd: Self.workspaceRoot,
            codexHome: codexHome,
            clientInfo: CodexRPCClientInfo(name: "cotg-tests", version: "0.1")
        )
    }

    private static func injectNewlines(into data: Data, every chunkSize: Int) -> Data {
        guard chunkSize > 0, data.count > chunkSize else {
            return data
        }

        var fragmented = Data()
        var offset = 0
        while offset < data.count {
            let nextOffset = min(offset + chunkSize, data.count)
            fragmented.append(data[offset..<nextOffset])
            if nextOffset < data.count {
                fragmented.append(0x0A)
            }
            offset = nextOffset
        }
        return fragmented
    }

    private static func injectByte(_ byte: UInt8, into data: Data, every chunkSize: Int) -> Data {
        guard chunkSize > 0, data.count > chunkSize else {
            return data
        }

        var fragmented = Data()
        var offset = 0
        while offset < data.count {
            let nextOffset = min(offset + chunkSize, data.count)
            fragmented.append(data[offset..<nextOffset])
            if nextOffset < data.count {
                fragmented.append(byte)
            }
            offset = nextOffset
        }
        return fragmented
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private actor EventRecorder {
    private var events: [CodexLiveEvent] = []

    func record(_ event: CodexLiveEvent) {
        events.append(event)
    }

    func completedAssistantText() -> String {
        events.reduce(into: "") { partialResult, event in
            if case let .agentMessageCompleted(text) = event {
                partialResult = text
            }
        }
    }

    func waitForTurnCompletion(turnID: String, timeoutNanoseconds: UInt64) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if events.contains(where: { event in
                if case let .turnCompleted(completedTurnID) = event {
                    return completedTurnID == turnID
                }
                return false
            }) {
                return true
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }

    func waitForApprovalRequest(turnID: String, timeoutNanoseconds: UInt64) async throws -> CodexApprovalRequest {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let request = events.first(where: { event in
                if case let .approvalRequested(request) = event {
                    return request.turnID == turnID
                }
                return false
            }).flatMap({ event -> CodexApprovalRequest? in
                if case let .approvalRequested(request) = event {
                    return request
                }
                return nil
            }) {
                return request
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw XCTSkip("Timed out waiting for a live approval request.")
    }
}
