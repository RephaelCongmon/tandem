import XCTest
@testable import TandemCore

/// The Claude Code provider: stream-json parsing, request folding, invocation, and the process
/// plumbing (driven by a fake `claude` script).
final class AIClaudeCodeTests: XCTestCase {
    // MARK: Recorded output

    private func streamEvent(_ event: String) -> String {
        #"{"type":"stream_event","event":\#(event),"session_id":"s","parent_tool_use_id":null}"#
    }

    private var successLines: [String] {
        [
            #"{"type":"system","subtype":"init","model":"claude-opus-5-5","tools":[]}"#,
            #"{"type":"system","subtype":"status","status":"requesting"}"#,
            streamEvent(#"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12,"cache_read_input_tokens":1400,"output_tokens":1}}}"#),
            streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Reading the dialog."}}"#),
            streamEvent(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            streamEvent(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"It wants "}}"#),
            streamEvent(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"a password."}}"#),
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"It wants a password."}]}}"#,
            streamEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#),
            streamEvent(#"{"type":"message_stop"}"#),
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790734200}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"It wants a password.","usage":{"input_tokens":12,"output_tokens":9}}"#
        ]
    }

    private func parse(_ lines: [String], includeReasoning: Bool = true) -> (events: [AIStreamEvent], error: AIError?) {
        var parser = ClaudeCodeStreamParser(includeReasoning: includeReasoning)
        var events: [AIStreamEvent] = []
        do {
            for line in lines { events += try parser.consume(line: line) }
            if !parser.isFinished { events += try parser.finish(exitStatus: 0, errorOutput: "") }
            return (events, nil)
        } catch {
            return (events, error as? AIError)
        }
    }

    func testParserStreamsTextReasoningAndUsage() {
        let result = parse(successLines)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.first, .started(model: "claude-opus-5-5"))
        XCTAssertEqual(result.events.aiTestText, "It wants a password.")
        XCTAssertEqual(result.events.aiTestReasoning, "Reading the dialog.")
        let completion = result.events.aiTestCompletion
        XCTAssertEqual(completion?.stopReason, .endTurn)
        XCTAssertEqual(completion?.usage?.outputTokens, 9)
        XCTAssertEqual(completion?.usage?.cacheReadTokens, 1400)
        XCTAssertEqual(completion?.servedModel, "claude-opus-5-5")
    }

    func testCompletionWaitsForTheResultLine() {
        var parser = ClaudeCodeStreamParser(includeReasoning: true)
        var events: [AIStreamEvent] = []
        for line in successLines.dropLast() { events += (try? parser.consume(line: line)) ?? [] }
        XCTAssertNil(events.aiTestCompletion, "an error could still follow the stream")
        XCTAssertFalse(parser.isFinished)
        events += (try? parser.consume(line: successLines.last!)) ?? []
        XCTAssertNotNil(events.aiTestCompletion)
        XCTAssertTrue(parser.isFinished)
    }

    func testReasoningCanBeHidden() {
        let result = parse(successLines, includeReasoning: false)
        XCTAssertEqual(result.events.aiTestReasoning, "")
        XCTAssertEqual(result.events.aiTestText, "It wants a password.")
    }

    func testRetriedAPICallStartsAFreshMessage() {
        var lines = Array(successLines.prefix(3))
        lines += [
            streamEvent(#"{"type":"message_stop"}"#),
            streamEvent(#"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12,"output_tokens":1}}}"#),
            streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Second try."}}"#),
            streamEvent(#"{"type":"message_stop"}"#),
            #"{"type":"result","subtype":"success","is_error":false,"result":"Second try."}"#
        ]
        let result = parse(lines)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "Second try.")
    }

    func testSignedOutExplainsHowToSignIn() {
        let result = parse([
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"error":"authentication_failed"}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        ])
        XCTAssertEqual(result.error, .invalidConfiguration(ClaudeCodeMessages.signedOut))
    }

    func testUnavailableModelPointsToSettings() {
        let result = parse([
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]},"error":"model_not_found"}"#,
            #"{"type":"result","subtype":"success","is_error":true,"api_error_status":404,"result":"There's an issue with the selected model."}"#
        ])
        XCTAssertEqual(result.error, .invalidConfiguration(ClaudeCodeMessages.modelUnavailable))
    }

    func testUsageLimitBecomesRateLimitedWithResetTime() {
        let resets = Date().addingTimeInterval(600).timeIntervalSince1970
        let result = parse([
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":\#(resets)}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]},"error":"rate_limit"}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit"}"#
        ])
        guard case .rateLimited(let retryAfter, let message)? = result.error else {
            return XCTFail("expected rateLimited, got \(String(describing: result.error))")
        }
        XCTAssertEqual(message, "You've hit your limit")
        XCTAssertEqual(retryAfter ?? 0, 600, accuracy: 5)
    }

    func testUnknownErrorsShowTheCLIMessage() {
        let result = parse([#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Something odd happened"}"#])
        XCTAssertEqual(result.error, .invalidConfiguration("Something odd happened"))
    }

    func testOutputEndingWithoutResultReportsStderr() {
        var parser = ClaudeCodeStreamParser(includeReasoning: true)
        XCTAssertThrowsError(try parser.finish(exitStatus: 1, errorOutput: "warming up\nerror: unknown option '--frobnicate'\n")) { error in
            XCTAssertEqual(error as? AIError, .invalidConfiguration("Claude Code stopped before answering: error: unknown option '--frobnicate'"))
        }
        var silent = ClaudeCodeStreamParser(includeReasoning: true)
        XCTAssertThrowsError(try silent.finish(exitStatus: 9, errorOutput: "")) { error in
            XCTAssertEqual(error as? AIError, .invalidConfiguration("Claude Code stopped before answering (exit code 9)."))
        }
    }

    func testNonJSONLinesAreIgnored() {
        let result = parse(["[claude-code:warning] something", ""] + successLines)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "It wants a password.")
    }

    // MARK: Request

    private func decodedInput(_ request: AIRequest) throws -> [String: Any] {
        let data = try ClaudeCodeClient.inputLine(for: request)
        XCTAssertEqual(data.last, 0x0A, "one JSON object per line")
        XCTAssertFalse(data.dropLast().contains(0x0A), "no raw newlines inside the line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func content(of line: [String: Any]) -> [[String: Any]] {
        ((line["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    func testSingleTurnIsSentAsIs() throws {
        let line = try decodedInput(aiTestRequest(model: "claude-opus-5-5"))
        XCTAssertEqual(line["type"] as? String, "user")
        XCTAssertEqual((line["message"] as? [String: Any])?["role"] as? String, "user")
        let blocks = content(of: line)
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertEqual(blocks[0]["text"] as? String, "What does this dialog want?")
        let source = blocks[1]["source"] as? [String: Any]
        XCTAssertEqual(source?["type"] as? String, "base64")
        XCTAssertEqual(source?["media_type"] as? String, "image/png")
        XCTAssertEqual(source?["data"] as? String, aiTestImage.data.base64EncodedString())
    }

    func testEarlierTurnsAreFoldedIntoOneMessage() throws {
        var request = aiTestRequest(model: "claude-opus-5-5")
        request.turns = [
            .user(.text("What's this?"), .image(aiTestImage)),
            .assistant("A settings window."),
            .user(.text("And now?"))
        ]
        let texts = content(of: try decodedInput(request)).map { block -> String in
            block["type"] as? String == "image" ? "<image>" : (block["text"] as? String ?? "?")
        }
        XCTAssertEqual(texts, [
            "The conversation so far. You are the assistant; screenshots appear where they were shared.",
            "User:", "What's this?", "<image>",
            "Assistant:", "A settings window.",
            "The user's new message, which you should answer:", "And now?"
        ])
    }

    func testConversationMustEndWithTheUser() {
        var request = aiTestRequest(model: "claude-opus-5-5")
        request.turns = [.user(.text("Hi")), .assistant("Hello")]
        XCTAssertThrowsError(try ClaudeCodeClient.inputLine(for: request))
    }

    // MARK: Invocation

    func testArgumentsGiveACleanToollessSession() {
        let arguments = ClaudeCodeClient.arguments(for: aiTestRequest(model: "claude-opus-5-5", effort: .high), model: "claude-opus-5-5")
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--include-partial-messages", "--verbose"] {
            XCTAssertTrue(arguments.contains(flag), "missing \(flag)")
        }
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--input-format"), "stream-json")
        XCTAssertEqual(value(after: "--output-format"), "stream-json")
        XCTAssertEqual(value(after: "--model"), "claude-opus-5-5")
        XCTAssertEqual(value(after: "--effort"), "high")
        XCTAssertEqual(value(after: "--system-prompt"), "You help with what's on screen.")
        XCTAssertFalse(arguments.contains("--bare"), "--bare never reads the subscription sign-in")
    }

    func testEffortIsOnlySentToModelsThatSupportIt() {
        let haiku = ClaudeCodeClient.arguments(for: aiTestRequest(model: "claude-haiku-4-5", effort: .high), model: "claude-haiku-4-5")
        XCTAssertFalse(haiku.contains("--effort"))
        let none = ClaudeCodeClient.arguments(for: aiTestRequest(model: "claude-opus-5-5", effort: nil), model: "claude-opus-5-5")
        XCTAssertFalse(none.contains("--effort"))
    }

    func testBlankInstructionsStillReplaceTheCodingPrompt() {
        let arguments = ClaudeCodeClient.arguments(for: aiTestRequest(model: "claude-opus-5-5", system: "  "), model: "claude-opus-5-5")
        XCTAssertEqual(arguments.last, "You are a helpful assistant.")
    }

    func testEnvironmentAvoidsNestingAndAPIKeys() {
        let environment = ClaudeCodeClient.childEnvironment(
            from: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "ANTHROPIC_API_KEY": "sk-ant-x", "ANTHROPIC_AUTH_TOKEN": "t"],
            executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude"),
            maxOutputTokens: 16_000
        )
        XCTAssertEqual(environment["HOME"], "/Users/me")
        XCTAssertEqual(environment["PATH"], "/Users/me/.local/bin:/usr/bin:/bin")
        XCTAssertEqual(environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "16000")
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
            XCTAssertNil(environment[key], key)
        }
    }

    func testModelsComeFromTheCatalog() async throws {
        let client = ClaudeCodeClient(executable: URL(fileURLWithPath: "/nonexistent/claude"))
        let models = try await client.listModels()
        XCTAssertEqual(models.first?.id, "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.capabilities(for: "claude-opus-5-5", provider: .claudeCode), ModelCatalog.anthropicCapabilities(for: "claude-opus-5-5"))
        XCTAssertFalse(AIProviderKind.claudeCode.requiresAPIKey)
        XCTAssertTrue(AIClientFactory.make(endpoint: AIEndpoint(kind: .claudeCode, baseURL: URL(fileURLWithPath: "/x/claude"), apiKey: "")) is ClaudeCodeClient)
    }

    // MARK: Process (fake CLI)

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A stand-in `claude` that records its arguments and stdin, then runs `body`.
    private func fakeCLI(_ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(scratch.path)/args.txt"
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func client(_ executable: URL, idleTimeout: TimeInterval = 30, pool: ClaudeCodeSessionPool? = nil) -> ClaudeCodeClient {
        ClaudeCodeClient(executable: executable, environment: ["PATH": "/usr/bin:/bin"], workingDirectory: scratch.appendingPathComponent("cwd"), idleTimeout: idleTimeout, pool: pool)
    }

    // MARK: Live sessions

    /// A fake CLI that answers every stdin line, recording the line and its process id.
    private func conversationalCLI() throws -> URL {
        let output = scratch.appendingPathComponent("out.jsonl")
        try (successLines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        return try fakeCLI(#"while IFS= read -r line; do printf '%s\n' "$line" >> "\#(scratch.path)/stdin.jsonl"; echo $$ >> "\#(scratch.path)/pids"; cat "\#(output.path)"; done"#)
    }

    private func recorded(_ name: String) throws -> [String] {
        try String(contentsOf: scratch.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testFollowUpsReuseTheLiveSessionAndSendOnlyTheNewMessage() async throws {
        let executable = try conversationalCLI()
        let pool = ClaudeCodeSessionPool()
        defer { pool.removeAll() }
        let thread = UUID(), u1 = UUID(), a1 = UUID(), u2 = UUID(), a2 = UUID()

        var first = aiTestRequest(model: "claude-opus-5-5")
        first.conversation = AIConversationKey(conversationID: thread, messageIDs: [u1], replyID: a1)
        let one = await aiTestCollect(client(executable, pool: pool).stream(first))
        XCTAssertNil(one.error)
        XCTAssertEqual(pool.liveConversationID, thread, "kept for the next question")

        var second = first
        second.turns = first.turns + [.assistant("It wants a password."), .user(.text("And the second field?"))]
        second.conversation = AIConversationKey(conversationID: thread, messageIDs: [u1, a1, u2], replyID: a2)
        let two = await aiTestCollect(client(executable, pool: pool).stream(second))
        XCTAssertNil(two.error)
        XCTAssertEqual(two.events.aiTestText, "It wants a password.")

        let lines = try recorded("stdin.jsonl")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0] + "\n", String(decoding: try ClaudeCodeClient.inputLine(for: first), as: UTF8.self))
        let followUp = try ClaudeCodeClient.inputLine(content: ClaudeCodeClient.content(of: [.user(.text("And the second field?"))]))
        XCTAssertEqual(lines[1] + "\n", String(decoding: followUp, as: UTF8.self), "only the new message")
        let pids = try recorded("pids")
        XCTAssertEqual(pids.count, 2)
        XCTAssertEqual(pids[0], pids[1], "the same process answered both")
    }

    func testAChangedConversationStartsAFreshProcess() async throws {
        let executable = try conversationalCLI()
        let pool = ClaudeCodeSessionPool()
        defer { pool.removeAll() }
        let thread = UUID(), u1 = UUID(), a1 = UUID()

        var first = aiTestRequest(model: "claude-opus-5-5")
        first.conversation = AIConversationKey(conversationID: thread, messageIDs: [u1], replyID: a1)
        _ = await aiTestCollect(client(executable, pool: pool).stream(first))

        // The reply was retried, so the thread no longer matches what the CLI holds.
        var retried = first
        retried.turns = first.turns + [.assistant("Something else."), .user(.text("Next?"))]
        retried.conversation = AIConversationKey(conversationID: thread, messageIDs: [u1, UUID(), UUID()], replyID: UUID())
        let result = await aiTestCollect(client(executable, pool: pool).stream(retried))
        XCTAssertNil(result.error)
        let lines = try recorded("stdin.jsonl")
        XCTAssertEqual(lines.last.map { $0 + "\n" }, String(decoding: try ClaudeCodeClient.inputLine(for: retried), as: UTF8.self), "the whole conversation, folded")
        let pids = try recorded("pids")
        XCTAssertNotEqual(pids.first, pids.last)
    }

    func testASpareProcessIsReadyForTheNextConversation() async throws {
        let executable = try conversationalCLI()
        let pool = ClaudeCodeSessionPool()
        defer { pool.removeAll() }
        client(executable, pool: pool).prewarm(for: aiTestRequest(model: "claude-opus-5-5"))
        await aiTestWait("a spare starts") { pool.hasSpare }

        var request = aiTestRequest(model: "claude-opus-5-5")
        request.conversation = AIConversationKey(conversationID: UUID(), messageIDs: [UUID()], replyID: UUID())
        let result = await aiTestCollect(client(executable, pool: pool).stream(request))
        XCTAssertNil(result.error)
        await aiTestWait("another spare starts for the next one") { pool.hasSpare }

        // A different model can't use it.
        var other = aiTestRequest(model: "claude-sonnet-5-5")
        other.conversation = AIConversationKey(conversationID: UUID(), messageIDs: [UUID()], replyID: UUID())
        let otherResult = await aiTestCollect(client(executable, pool: pool).stream(other))
        XCTAssertNil(otherResult.error)
        let pids = try recorded("pids")
        XCTAssertEqual(pids.count, 2)
        XCTAssertNotEqual(pids[0], pids[1], "the other model got its own process")
    }

    func testAFailedAnswerEndsTheSession() async throws {
        let executable = try fakeCLI(#"while IFS= read -r line; do echo '{"type":"result","subtype":"error","is_error":true,"result":"Overloaded"}'; done"#)
        let pool = ClaudeCodeSessionPool()
        defer { pool.removeAll() }
        var request = aiTestRequest(model: "claude-opus-5-5")
        request.conversation = AIConversationKey(conversationID: UUID(), messageIDs: [UUID()], replyID: UUID())
        let result = await aiTestCollect(client(executable, pool: pool).stream(request))
        XCTAssertNotNil(result.error)
        XCTAssertNil(pool.liveConversationID, "a failed answer isn't kept")
    }

    func testStreamsThroughTheCLIAndSendsTheConversationOnStdin() async throws {
        let output = scratch.appendingPathComponent("out.jsonl")
        try (successLines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        let executable = try fakeCLI(#"cat > "\#(scratch.path)/stdin.jsonl"; cat "\#(output.path)""#)

        let result = await aiTestCollect(client(executable).stream(aiTestRequest(model: "claude-opus-5-5")))

        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "It wants a password.")
        XCTAssertNotNil(result.events.aiTestCompletion)
        let stdin = try Data(contentsOf: scratch.appendingPathComponent("stdin.jsonl"))
        XCTAssertEqual(stdin, try ClaudeCodeClient.inputLine(for: aiTestRequest(model: "claude-opus-5-5")))
        let arguments = try String(contentsOf: scratch.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("--safe-mode"))
    }

    func testCLIThatQuitsWithoutReadingReportsItsError() async throws {
        // A large screenshot fills the pipe; the write must fail quietly, not kill the process.
        let executable = try fakeCLI("echo \"error: unknown option '--safe-mode'\" >&2; exit 1")
        var request = aiTestRequest(model: "claude-opus-5-5")
        request.turns = [.user(.text("Big"), .image(AIImage(data: Data(repeating: 7, count: 3_000_000), mimeType: "image/jpeg", width: 2000, height: 1000)))]

        let result = await aiTestCollect(client(executable).stream(request))

        XCTAssertEqual(result.error, .invalidConfiguration("Claude Code stopped before answering: error: unknown option '--safe-mode'"))
    }

    func testCancellingStopsTheCLI() async throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let executable = try fakeCLI("cat > /dev/null; echo $$ > \"\(pidFile.path)\"; exec sleep 30")
        let stream = client(executable).stream(aiTestRequest(model: "claude-opus-5-5"))
        let task = Task { await aiTestCollect(stream) }
        await aiTestWait("the fake CLI is running") { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        let cancelledAt = Date()
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "the consumer must not hang")
        XCTAssertNil(result.events.aiTestCompletion)
        await aiTestWait("the CLI exits") { kill(pid, 0) != 0 }
    }

    func testSilentCLITimesOut() async throws {
        let executable = try fakeCLI("cat > /dev/null; sleep 30")
        let started = Date()
        let result = await aiTestCollect(client(executable, idleTimeout: 1.5).stream(aiTestRequest(model: "claude-opus-5-5")))
        XCTAssertEqual(result.error, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testMissingExecutableExplainsHowToInstall() async {
        let result = await aiTestCollect(client(URL(fileURLWithPath: "/nonexistent/claude")).stream(aiTestRequest(model: "claude-opus-5-5")))
        XCTAssertEqual(result.error, .invalidConfiguration(ClaudeCodeMessages.notFound))
    }

    // MARK: Locator

    func testLocatorReadsVersionAndSignIn() {
        XCTAssertEqual(ClaudeCodeLocator.parseVersion("2.1.285 (Claude Code)\n"), "2.1.285")
        var status = ClaudeCodeStatus(executable: URL(fileURLWithPath: "/x/claude"), version: "2.1.285")
        ClaudeCodeLocator.apply(authStatus: #"{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com", "subscriptionType": "max"}"#, to: &status)
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.summary, "Claude Code 2.1.285 · signed in as me@example.com · Max plan")

        var signedOut = ClaudeCodeStatus(executable: URL(fileURLWithPath: "/x/claude"))
        ClaudeCodeLocator.apply(authStatus: #"{"loggedIn": false}"#, to: &signedOut)
        XCTAssertFalse(signedOut.isReady)
        XCTAssertEqual(signedOut.summary, ClaudeCodeMessages.signedOut)
        XCTAssertEqual(ClaudeCodeStatus().summary, ClaudeCodeMessages.notFound)
    }

    func testLocatorFindsUsualInstallsAndOverrides() throws {
        let home = scratch.path
        XCTAssertNil(ClaudeCodeLocator.quickLocate(override: nil, home: home))
        let bin = scratch.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let installed = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: installed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        XCTAssertEqual(ClaudeCodeLocator.quickLocate(override: nil, home: home)?.path, installed.path)
        XCTAssertEqual(ClaudeCodeLocator.quickLocate(override: installed.path, home: "/nowhere")?.path, installed.path)
        XCTAssertNil(ClaudeCodeLocator.quickLocate(override: "/nonexistent/claude", home: home), "a wrong override isn't silently replaced")
    }
}

/// Opt-in checks against the real `claude` on this Mac: `TANDEM_LIVE_CLAUDE=1 swift test --filter AIClaudeCodeLiveTests`.
final class AIClaudeCodeLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_LIVE_CLAUDE"] == "1", "set TANDEM_LIVE_CLAUDE=1 to run")
    }

    func testStatusOfTheInstalledCLI() async throws {
        let status = await ClaudeCodeLocator.status(override: nil)
        print("LIVE status:", status, status.summary)
        XCTAssertNotNil(status.executable)
        XCTAssertNotNil(status.version)
        XCTAssertTrue(status.signedIn)
    }
}

/// Short helper commands (`--version`, `auth status`).
final class ChildProcessRunTests: XCTestCase {
    func testRunReturnsStatusAndOutput() async {
        let result = await ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo one; echo two; exit 3"], timeout: 5)
        XCTAssertEqual(result?.status, 3)
        XCTAssertEqual(result?.output, "one\ntwo")
    }

    func testTimedOutRunReturnsNil() async {
        let started = Date()
        let result = await ChildProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelledRunReturnsNilNotAFakeAnswer() async {
        let task = Task { await ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 1; echo late"], timeout: 10) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "a cancelled check must not read as \"signed out\"")
    }
}
