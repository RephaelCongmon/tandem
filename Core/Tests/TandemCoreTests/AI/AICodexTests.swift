import XCTest
@testable import TandemCore

final class CodexLaunchTests: XCTestCase {
    func testOnlyKnownFeaturesAreDisabled() {
        let features = CodexLaunch.parseFeatures("""
        shell_tool                               stable             true
        unified_exec                             stable             true
        plugins                                  stable             true
        fast_mode                                stable             false
        garbage line with Capitals
        """)
        XCTAssertEqual(features, ["shell_tool", "unified_exec", "plugins", "fast_mode"])
        let arguments = CodexLaunch.arguments(knownFeatures: features, mcpServers: ["node_repl", "my server"])
        XCTAssertEqual(arguments.first, "app-server")
        XCTAssertTrue(arguments.contains("shell_tool") && arguments.contains("plugins"))
        XCTAssertFalse(arguments.contains("browser_use"), "a feature this Codex doesn't know would be an error")
        XCTAssertTrue(arguments.contains("mcp_servers.node_repl.enabled=false"))
        XCTAssertTrue(arguments.contains("mcp_servers.\"my server\".enabled=false"))
        XCTAssertTrue(arguments.contains("web_search=\"disabled\""))
    }

    func testReadsTopLevelMCPServersOnly() {
        let config = """
        model = "gpt-6.1-sol"
        [mcp_servers.node_repl]
        command = "node"
        [mcp_servers.node_repl.env]
        A = "1"
        [mcp_servers."computer use"]
        [[mcp_servers.list]]
        [plugins."browser@openai-bundled"]
        """
        XCTAssertEqual(CodexLaunch.mcpServerIDs(inConfig: config), ["node_repl", "computer use"])
    }

    func testReadsSignInState() {
        var status = CodexStatus(executable: URL(fileURLWithPath: "/x/codex"))
        CodexLocator.apply(loginStatus: "Logged in using ChatGPT\n", exitStatus: 0, to: &status)
        XCTAssertTrue(status.isReady && status.usesChatGPT)
        XCTAssertEqual(CodexLocator.parseVersion("codex-cli 0.159.2\n"), "0.159.2")
        status.version = "0.159.2"
        XCTAssertEqual(status.summary, "Codex 0.159.2 · signed in with ChatGPT")

        var key = CodexStatus(executable: URL(fileURLWithPath: "/x/codex"))
        CodexLocator.apply(loginStatus: "Logged in using an API key - sk-proj-ABCDEF***", exitStatus: 0, to: &key)
        XCTAssertEqual(key.method, "an API key", "never keeps the key itself")
        XCTAssertFalse(key.usesChatGPT)

        var out = CodexStatus(executable: URL(fileURLWithPath: "/x/codex"))
        CodexLocator.apply(loginStatus: "Not logged in", exitStatus: 1, to: &out)
        XCTAssertFalse(out.signedIn)
        XCTAssertEqual(out.summary, CodexMessages.signedOut)
        XCTAssertEqual(CodexStatus().summary, CodexMessages.notFound)
    }

    func testErrorsAreExplained() {
        XCTAssertEqual(CodexClient.turnError(message: "x", info: "unauthorized"), .invalidConfiguration(CodexMessages.signedOut))
        XCTAssertEqual(CodexClient.turnError(message: "Limit", info: "usageLimitExceeded"), .rateLimited(retryAfter: nil, message: "Limit"))
        XCTAssertEqual(CodexClient.turnError(message: "Busy", info: ["httpConnectionFailed": ["httpStatusCode": 503]]), .overloaded("Busy"))
        XCTAssertEqual(CodexClient.turnError(message: "The model gpt-9 does not exist", info: "badRequest"), .invalidConfiguration(CodexMessages.modelUnavailable))
    }

    func testProviderBasics() {
        XCTAssertFalse(AIProviderKind.codex.requiresAPIKey)
        XCTAssertTrue(AIProviderKind.codex.usesSubscription)
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .codex), "gpt-6.1-sol")
        XCTAssertTrue(ModelCatalog.presets(for: .codex).contains { $0.id == "gpt-6-astra" })
        XCTAssertEqual(ModelCatalog.capabilities(for: "gpt-6.1-sol", provider: .codex).supportedEfforts, ReasoningEffort.allCases)
        XCTAssertTrue(AIClientFactory.make(endpoint: AIEndpoint(kind: .codex, baseURL: URL(fileURLWithPath: "/x/codex"), apiKey: "")) is CodexClient)
    }
}

/// `CodexClient` against a stand-in `codex app-server` (a small Python script speaking the
/// same JSON-RPC), which logs what it receives.
final class CodexClientTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func fakeCodex() throws -> URL {
        let url = scratch.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/python3
        import json, sys, os
        log = open(os.path.join(os.path.dirname(sys.argv[0]), "log.jsonl"), "a")
        threads = 0
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        for line in sys.stdin:
            m = json.loads(line)
            log.write(json.dumps(m) + "\n"); log.flush()
            method, i, p = m.get("method"), m.get("id"), m.get("params", {})
            if method == "initialize": send({"id": i, "result": {"userAgent": "fake"}})
            elif method == "model/list": send({"id": i, "result": {"data": [{"id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "hidden": False}, {"id": "secret", "displayName": "S", "hidden": True}]}})
            elif method == "thread/start":
                threads += 1; send({"id": i, "result": {"thread": {"id": "thread-%d" % threads}}})
            elif method == "turn/start":
                t = p["threadId"]; send({"id": i, "result": {"turn": {"id": "turn-1"}}})
                text = " ".join(x.get("text", "") for x in p["input"] if x.get("type") == "text")
                images = [x["path"] for x in p["input"] if x.get("type") == "localImage"]
                log.write(json.dumps({"imagesExist": [os.path.exists(x) for x in images]}) + "\n"); log.flush()
                if "APPROVE" in text:
                    send({"id": 99, "method": "item/commandExecution/requestApproval", "params": {"threadId": t}})
                    log.write(json.dumps(json.loads(sys.stdin.readline())) + "\n"); log.flush()
                if "FAIL" in text:
                    send({"method": "turn/completed", "params": {"threadId": t, "turn": {"id": "turn-1", "status": "failed", "error": {"message": "Usage limit reached", "codexErrorInfo": "usageLimitExceeded"}}}})
                    continue
                if "HANG" in text: continue
                send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": t, "delta": "Thinking"}})
                send({"method": "item/agentMessage/delta", "params": {"threadId": t, "delta": "It wants "}})
                send({"method": "item/agentMessage/delta", "params": {"threadId": "someone-else", "delta": "NOT MINE"}})
                send({"method": "item/agentMessage/delta", "params": {"threadId": t, "delta": "a password."}})
                send({"method": "thread/tokenUsage/updated", "params": {"threadId": t, "tokenUsage": {"last": {"inputTokens": 100, "cachedInputTokens": 60, "outputTokens": 7, "cacheWriteInputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": 107}, "total": {}}}})
                send({"method": "turn/completed", "params": {"threadId": t, "turn": {"id": "turn-1", "status": "completed"}}})
            elif method == "turn/interrupt":
                send({"id": i, "result": {}})
                send({"method": "turn/completed", "params": {"threadId": p["threadId"], "turn": {"id": "turn-1", "status": "interrupted"}}})
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func client(_ executable: URL, pool: CodexSessionPool, idleTimeout: TimeInterval = 30) -> CodexClient {
        CodexClient(executable: executable, workingDirectory: scratch.appendingPathComponent("cwd"), idleTimeout: idleTimeout, pool: pool, arguments: ["app-server"])
    }

    private func logged() throws -> [[String: Any]] {
        try String(contentsOf: scratch.appendingPathComponent("log.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func requests(_ method: String) throws -> [[String: Any]] {
        try logged().filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
    }

    func testStreamsAnAnswerFromACleanThread() async throws {
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        var request = aiTestRequest(model: "gpt-6.1-sol", effort: .high, summary: true)
        request.conversation = AIConversationKey(conversationID: UUID(), messageIDs: [UUID()], replyID: UUID())
        let result = await aiTestCollect(client(try fakeCodex(), pool: pool).stream(request))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "It wants a password.", "only this thread's deltas")
        let completion = try XCTUnwrap(result.events.aiTestCompletion)
        XCTAssertEqual(completion.usage, AIUsage(inputTokens: 40, outputTokens: 7, cacheReadTokens: 60, cacheWriteTokens: 0))
        XCTAssertTrue(result.events.contains(.reasoningDelta("Thinking")))

        let thread = try XCTUnwrap(try requests("thread/start").first)
        XCTAssertEqual(thread["baseInstructions"] as? String, request.systemPrompt)
        XCTAssertEqual(thread["sandbox"] as? String, "read-only")
        XCTAssertEqual(thread["approvalPolicy"] as? String, "never")
        XCTAssertEqual(thread["ephemeral"] as? Bool, true)
        let turn = try XCTUnwrap(try requests("turn/start").first)
        XCTAssertEqual(turn["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(turn["effort"] as? String, "high")
        XCTAssertEqual(turn["summary"] as? String, "concise")
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["text", "localImage"])
        let imagePath = try XCTUnwrap(input[1]["path"] as? String)
        XCTAssertEqual(try logged().compactMap { $0["imagesExist"] as? [Bool] }.first, [true], "the screenshot is on disk while Codex reads it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath), "and removed afterwards")
    }

    func testFollowUpsContinueTheThread() async throws {
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        let codex = try fakeCodex()
        let conversation = UUID(), u1 = UUID(), a1 = UUID(), u2 = UUID()
        var first = aiTestRequest(model: "gpt-6-astra")
        first.conversation = AIConversationKey(conversationID: conversation, messageIDs: [u1], replyID: a1)
        let result1 = await aiTestCollect(client(codex, pool: pool).stream(first))
        XCTAssertNil(result1.error)

        var second = first
        second.turns = first.turns + [.assistant("It wants a password."), .user(.text("And the second field?"))]
        second.conversation = AIConversationKey(conversationID: conversation, messageIDs: [u1, a1, u2], replyID: UUID())
        let result2 = await aiTestCollect(client(codex, pool: pool).stream(second))
        XCTAssertNil(result2.error)

        XCTAssertEqual(try requests("thread/start").count, 1, "one thread for the whole conversation")
        let turns = try requests("turn/start")
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1]["threadId"] as? String, "thread-1")
        let input = try XCTUnwrap(turns[1]["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["text"] as? String }, ["And the second field?"], "only the new message")
        XCTAssertEqual(try requests("initialize").count, 1, "one Codex process")

        // A changed history (e.g. a retried answer) starts a new thread with everything folded in.
        var retried = second
        retried.conversation = AIConversationKey(conversationID: conversation, messageIDs: [u1, UUID(), u2], replyID: UUID())
        let result3 = await aiTestCollect(client(codex, pool: pool).stream(retried))
        XCTAssertNil(result3.error)
        XCTAssertEqual(try requests("thread/start").count, 2)
        let folded = try XCTUnwrap(try requests("turn/start").last?["input"] as? [[String: Any]])
        XCTAssertTrue(folded.compactMap { $0["text"] as? String }.first?.hasPrefix("The conversation so far.") == true)
    }

    func testFailuresAreExplainedAndEndTheThread() async throws {
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        var request = aiTestRequest(model: "gpt-6-astra")
        request.turns = [.user(.text("Please FAIL"))]
        let conversation = UUID()
        request.conversation = AIConversationKey(conversationID: conversation, messageIDs: [UUID()], replyID: UUID())
        let result = await aiTestCollect(client(try fakeCodex(), pool: pool).stream(request))
        XCTAssertEqual(result.error, .rateLimited(retryAfter: nil, message: "Usage limit reached"))
        XCTAssertEqual(pool.liveThreadCount, 0)
    }

    func testApprovalRequestsAreDeclined() async throws {
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        var request = aiTestRequest(model: "gpt-6-astra")
        request.turns = [.user(.text("APPROVE this"))]
        let result4 = await aiTestCollect(client(try fakeCodex(), pool: pool).stream(request))
        XCTAssertNil(result4.error)
        let reply = try XCTUnwrap(try logged().first { ($0["id"] as? Int) == 99 })
        XCTAssertEqual((reply["result"] as? [String: Any])?["decision"] as? String, "decline")
    }

    func testCancellingInterruptsTheTurn() async throws {
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        var request = aiTestRequest(model: "gpt-6-astra")
        request.turns = [.user(.text("HANG please"))]
        let stream = client(try fakeCodex(), pool: pool).stream(request)
        let task = Task { await aiTestCollect(stream) }
        await aiTestWait("the turn started", timeout: 5) { ((try? self.requests("turn/start"))?.count ?? 0) == 1 }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result.events.aiTestCompletion)
        await aiTestWait("the turn was interrupted", timeout: 5) { ((try? self.requests("turn/interrupt"))?.count ?? 0) == 1 }
    }

    func testListsVisibleModels() async throws {
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        let models = try await client(try fakeCodex(), pool: pool).listModels()
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol"])
    }
}

/// The real Codex CLI on this Mac (uses the ChatGPT plan): `TANDEM_LIVE_CODEX=1`.
final class CodexLiveTests: XCTestCase {
    func testAnswersAndRemembersTheConversation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_LIVE_CODEX"] == "1", "uses your ChatGPT plan")
        let executable = try XCTUnwrap(CodexLocator.quickLocate(override: nil), "Codex isn't installed")
        let pool = CodexSessionPool()
        defer { pool.removeAll() }
        let client = CodexClient(executable: executable, pool: pool)
        let conversation = UUID(), u1 = UUID(), a1 = UUID()
        var first = AIRequest(model: "gpt-6-astra", systemPrompt: "You are terse.", turns: [.user(.text("Pick a random animal and name only it."))], effort: .low)
        first.conversation = AIConversationKey(conversationID: conversation, messageIDs: [u1], replyID: a1)
        let one = await aiTestCollect(client.stream(first))
        XCTAssertNil(one.error)
        let animal = one.events.aiTestText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(animal.isEmpty)
        var second = first
        second.turns = first.turns + [.assistant(animal), .user(.text("Which animal did you pick? Answer with just the name."))]
        second.conversation = AIConversationKey(conversationID: conversation, messageIDs: [u1, a1, UUID()], replyID: UUID())
        let two = await aiTestCollect(client.stream(second))
        XCTAssertNil(two.error)
        XCTAssertTrue(two.events.aiTestText.lowercased().contains(animal.lowercased().trimmingCharacters(in: .punctuationCharacters)), "\(two.events.aiTestText) vs \(animal)")
    }
}
