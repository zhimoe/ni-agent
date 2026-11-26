# Unit and integration tests for LLM providers (SSE streaming, DeepSeek reasoning_content, OpenAI Responses), sessions, and Agent loop.

import std/[json, os, strutils, tables, unittest]
import ../src/ni/[types, config, trust, provider, tools, mcp, session, agent]

suite "Provider SSE Streaming, Session Tree, and Multi-turn Agent Loop":
  test "OpenAI Completions SSE streaming with DeepSeek reasoning_content & multi-chunk tool_calls":
    let tmp = getTempDir() / ("ni_prov_" & $nowUnixMs())
    createDir(tmp)
    defer: removeDir(tmp)

    var capturedBodies: seq[JsonNode] = @[]
    var callNum = 0

    let mockTransport: HttpStreamTransport = proc(
      url, httpMethod: string,
      headers: Table[string, string],
      body, proxyUrl: string,
      timeoutMs: int,
      abort: AbortFlag,
      onLine: HttpLineChunkCallback
    ): HttpStreamResponse =
      inc callNum
      capturedBodies.add(parseJson(body))
      if callNum == 1:
        # Simulate HTTP 429 on attempt 1 to verify automatic transient retry!
        return HttpStreamResponse(statusCode: 429, errorBody: """{"error":{"message":"Rate limit"}}""")
      elif callNum == 2:
        onLine("""data: {"choices":[{"delta":{"reasoning_content":"Let's ask "}}]}""")
        onLine("""data: {"choices":[{"delta":{"reasoning_content":"the user first."}}]}""")
        onLine("""data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_q1","type":"function","function":{"name":"ask_question","arguments":"{\"questions\":[{\"question\":\"Pick"}}]}}]}""")
        onLine("""data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" target\",\"options\":[{\"label\":\"hello.txt\"}]}]}"}}]},"finish_reason":"tool_calls"}]}""")
        onLine("""data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":40,"total_tokens":160}}""")
        onLine("data: [DONE]")
        return HttpStreamResponse(statusCode: 200)
      elif callNum == 3:
        onLine("""data: {"choices":[{"delta":{"reasoning_content":"Writing file now."}}]}""")
        onLine("""data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_w1","type":"function","function":{"name":"write","arguments":"{\"path\":\"hello.txt\",\"content\":\"Hello from ni!\\n\"}"}}]},"finish_reason":"tool_calls"}]}""")
        onLine("data: [DONE]")
        return HttpStreamResponse(statusCode: 200)
      else:
        onLine("""data: {"choices":[{"delta":{"content":"Created hello.txt successfully."},"finish_reason":"stop"}],"usage":{"prompt_tokens":200,"completion_tokens":12,"total_tokens":212}}""")
        onLine("data: [DONE]")
        return HttpStreamResponse(statusCode: 200)

    let agentDir = tmp / "agent"
    let ws = tmp / "ws"
    createDir(agentDir)
    createDir(ws)
    saveApiKeyCredential(agentDir, "deepseek", "sk-mock-deepseek")

    let cfg = loadConfigBundle(ws, agentDir)
    cfg.settings.retry.baseDelayMs = 100
    let provReg = newProviderRegistry(cfg, mockTransport)
    let toolReg = newToolRegistry(cfg.settings.defaultTools)
    let mcpMgr = McpManager(servers: initOrderedTable[string, McpServerSession](), diagnostics: @[], workspaceRoot: ws)
    let sess = newSessionManager(ws, tmp / "sessions", persist = true, sessionName = "Test Run")
    let sec = newSecurityPolicy(ws, agentDir, smBalanced)
    let (dsReasoner, _) = provReg.resolveModel(cfg, "deepseek/deepseek-reasoner")

    var askInvoked = false
    let mockAsk: AskQuestionCallback = proc(questions: seq[AskQuestionItem]): seq[AskQuestionAnswer] =
      askInvoked = true
      check questions.len == 1
      check questions[0].question == "Pick target"
      @[AskQuestionAnswer(id: questions[0].id, question: questions[0].question, selected: @["hello.txt"])]

    let rt = newAgentRuntime(
      cfg = cfg,
      providerRegistry = provReg,
      toolRegistry = toolReg,
      mcpManager = mcpMgr,
      skills = @[],
      security = sec,
      session = sess,
      initialModel = dsReasoner,
      thinkingLevel = tlHigh,
      askQuestion = mockAsk
    )

    let finalMsg = rt.runPrompt("Create the chosen file")
    check askInvoked == true
    check finalMsg.stopReason == srStop
    check collectText(finalMsg.assistantBlocks) == "Created hello.txt successfully."
    check readFile(ws / "hello.txt") == "Hello from ni!\n"

    # Verify DeepSeek multi-turn tool call payload replayed reasoning_content on prior assistant turn!
    check capturedBodies.len == 4
    let thirdPayloadMsgs = capturedBodies[2]["messages"]
    var sawReplayedReasoning = false
    for m in thirdPayloadMsgs.items:
      if m{"role"}.getStr("") == "assistant" and m.hasKey("reasoning_content"):
        if m["reasoning_content"].getStr() == "Let's ask the user first.":
          sawReplayedReasoning = true
    check sawReplayedReasoning == true

    # Verify Pi v3 JSONL session reload, fork, and compaction
    check fileExists(sess.filePath)
    let reloaded = loadSessionFile(sess.filePath)
    let (reloadedMsgs, _, _) = reloaded.buildActiveContext()
    check reloadedMsgs.len == 6 # user -> assistant(ask) -> toolResult -> assistant(write) -> toolResult -> assistant(done)

    let forked = forkSession(sess.filePath, ws, tmp / "sessions")
    let (forkMsgs, _, _) = forked.buildActiveContext()
    check forkMsgs.len == 6

    # Test branching back to first entry
    let firstId = reloaded.entries[1].id # first message after session_info
    check reloaded.branchTo(firstId) == true
    let (branchedMsgs, _, _) = reloaded.buildActiveContext()
    check branchedMsgs.len == 1

  test "DeepSeek replays tool output containing malformed UTF-8 from a saved session":
    let tmp = getTempDir() / ("ni_utf8_" & $nowUnixMs())
    createDir(tmp)
    defer: removeDir(tmp)

    let sess = newSessionManager(tmp, tmp / "sessions", persist = true)
    discard sess.appendMessage(newUserMessage("检查输出 😀"))
    discard sess.appendMessage(AgentMessage(role: mrAssistant, assistantBlocks: @[
      toolCallBlock("call_utf8", "bash", %*{"command": "echo test"})
    ]))
    # A clipped CJK character and byte sequences encoding invalid Unicode scalar values.
    let legacyOutput = "中文\xE4\xB8\n\xED\xA0\x80|\xF4\x90\x80\x80|\xE0\x80\x80 😀"
    let validOutput = "中文�\n���|����|��� 😀"
    discard sess.appendMessage(AgentMessage(role: mrToolResult, toolCallId: "call_utf8",
      toolName: "bash", resultBlocks: @[textBlock(legacyOutput)]))
    let repairedJsonLine = readFile(sess.filePath).strip().splitLines()[^1]
    check parseJson(repairedJsonLine)["message"]["content"][0]["text"].getStr() == validOutput

    # Simulate a session written by an older version that emitted the raw bytes.
    let saved = readFile(sess.filePath)
    let legacyJsonl = saved.replace(escapeJson(validOutput), escapeJson(legacyOutput))
    require legacyJsonl != saved
    writeFile(sess.filePath, legacyJsonl)
    let (messages, _, _) = loadSessionFile(sess.filePath).buildActiveContext()
    require messages.len == 3
    check collectText(messages[^1].resultBlocks) == validOutput
    check readFile(sess.filePath) == legacyJsonl

    let transport: HttpStreamTransport = proc(
      url, httpMethod: string, headers: Table[string, string], body, proxyUrl: string,
      timeoutMs: int, abort: AbortFlag, onLine: HttpLineChunkCallback
    ): HttpStreamResponse =
      let payload = parseJson(body)["messages"]
      check payload[0]["content"].getStr() == "检查输出 😀"
      check payload[2]["tool_call_id"].getStr() == "call_utf8"
      check payload[2]["content"].getStr() == validOutput
      onLine("""data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}""")
      HttpStreamResponse(statusCode: 200)

    let cfg = loadConfigBundle(tmp, tmp / "agent")
    let registry = newProviderRegistry(cfg, transport)
    let (model, _) = registry.resolveModel(cfg, "deepseek/deepseek-chat", cliApiKey = "test-key")
    let reply = registry.streamCompletion(cfg = cfg, model = model, systemPrompt = "",
      messages = messages, tools = @[], thinkingLevel = tlOff, cliApiKey = "test-key")
    check reply.stopReason == srStop
    check collectText(reply.assistantBlocks) == "OK"

    let (liveMessages, _, _) = sess.buildActiveContext()
    check collectText(liveMessages[^1].resultBlocks) == legacyOutput
    let liveReply = registry.streamCompletion(cfg = cfg, model = model, systemPrompt = "",
      messages = liveMessages, tools = @[], thinkingLevel = tlOff, cliApiKey = "test-key")
    check liveReply.stopReason == srStop
    let exported = sess.exportSessionToFile(tmp / "export.jsonl")
    let (exportedMessages, _, _) = loadSessionFile(exported).buildActiveContext()
    require exportedMessages.len == 3
    check escapeJson(validOutput) in readFile(exported)

  test "Steering batches attachments and file references before one-at-a-time follow-ups":
    let tmp = getTempDir() / ("ni_queue_" & $nowUnixMs())
    createDir(tmp)
    defer: removeDir(tmp)
    writeFile(tmp / "notes.txt", "queue context")

    var requests: seq[JsonNode]
    let transport: HttpStreamTransport = proc(
      url, httpMethod: string,
      headers: Table[string, string],
      body, proxyUrl: string,
      timeoutMs: int,
      abort: AbortFlag,
      onLine: HttpLineChunkCallback
    ): HttpStreamResponse =
      requests.add(parseJson(body)["messages"])
      onLine("""data: {"choices":[{"delta":{"content":"Received"},"finish_reason":"stop"}]}""")
      HttpStreamResponse(statusCode: 200)

    let cfg = loadConfigBundle(tmp, tmp / "agent")
    let registry = newProviderRegistry(cfg, transport)
    let (model, _) = registry.resolveModel(cfg, "deepseek/deepseek-chat", cliApiKey = "test-key")
    let rt = newAgentRuntime(
      cfg, registry, newToolRegistry(@[]),
      McpManager(servers: initOrderedTable[string, McpServerSession]()), @[],
      newSecurityPolicy(tmp, cfg.agentDir), newSessionManager(tmp, tmp / "sessions", persist = false),
      model, tlOff, cliApiKey = "test-key"
    )
    rt.steeringMode = qmAll
    rt.steeringQueue = @[
      QueuedPrompt(text: "steer with image", images: @[imageBlock("AQID", "image/png")]),
      QueuedPrompt(text: "check @notes.txt")
    ]
    rt.followUpQueue = @[QueuedPrompt(text: "first follow-up"), QueuedPrompt(text: "second follow-up")]

    discard rt.runPrompt("Start")
    require requests.len == 4
    let steerMessages = requests[1]
    check steerMessages[steerMessages.len - 2]["content"][1]["image_url"]["url"].getStr() == "data:image/png;base64,AQID"
    check "queue context" in steerMessages[steerMessages.len - 1]["content"].getStr()
    check requests[2][requests[2].len - 1]["content"].getStr() == "first follow-up"
    check requests[3][requests[3].len - 1]["content"].getStr() == "second follow-up"

  test "OpenAI Responses (/v1/responses) SSE streaming adapter":
    let tmp = getTempDir() / ("ni_resp_" & $nowUnixMs())
    createDir(tmp)
    defer: removeDir(tmp)

    let mockResponsesTransport: HttpStreamTransport = proc(
      url, httpMethod: string,
      headers: Table[string, string],
      body, proxyUrl: string,
      timeoutMs: int,
      abort: AbortFlag,
      onLine: HttpLineChunkCallback
    ): HttpStreamResponse =
      check url.endsWith("/responses")
      onLine("""data: {"type":"response.reasoning_summary_text.delta","delta":"Checking..."}""")
      onLine("""data: {"type":"response.output_text.delta","delta":"Responses API "}""")
      onLine("""data: {"type":"response.output_text.delta","delta":"works!"}""")
      onLine("""data: {"type":"response.completed","response":{"usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60}}}""")
      onLine("data: [DONE]")
      HttpStreamResponse(statusCode: 200)

    let cfg = loadConfigBundle(tmp, tmp / "agent")
    let provReg = newProviderRegistry(cfg, mockResponsesTransport)
    let (gpt5, _) = provReg.resolveModel(cfg, "openai/gpt-5", cliApiKey = "sk-test-oai")
    check gpt5.api == "openai-responses"

    let reply = provReg.streamCompletion(
      cfg = cfg,
      model = gpt5,
      systemPrompt = "Be concise.",
      messages = @[newUserMessage("Ping")],
      tools = @[],
      thinkingLevel = tlMedium,
      cliApiKey = "sk-test-oai"
    )
    check reply.stopReason == srStop
    check collectThinking(reply.assistantBlocks) == "Checking..."
    check collectText(reply.assistantBlocks) == "Responses API works!"
    check reply.usage.totalTokens == 60
