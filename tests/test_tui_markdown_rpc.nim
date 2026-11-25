# Comprehensive unit & E2E tests for TUI width/wrapping, InputEditor, Markdown/Syntax renderer, Anthropic & Gemini SSE, Prompt Templates, Fuzzy Edit, Session Tree/Export, and `--mode rpc`.

import std/[json, options, os, osproc, streams, strutils, tables, unittest]
import ../src/ni/[types, config, trust, provider, tools, skills, mcp, session, agent, terminal_io, keybindings, editor, markdown]

suite "TUI Layout, Multi-line Input Editor, and Terminal Markdown Renderer":
  test "Unicode/CJK visibleWidth, ANSI/OSC8 stripping, and ANSI-preserving word wrap":
    let prevColors = colorsActive()
    setColorsEnabled(true)
    defer: setColorsEnabled(prevColors)

    check visibleWidth("hello") == 5
    check visibleWidth("你好世界") == 8
    check visibleWidth("ni输入框") == 8
    check visibleWidth(styleBold(styleCyan("你好 ni"))) == 7
    check visibleWidth(styleHyperlink("https://example.com", "文档链接")) == 8
    let clippedLink = truncateVisible(styleHyperlink("https://example.com", "文档链接"), 5)
    check clippedLink.endsWith("\x1b]8;;\x07…")
    check visibleWidth(clippedLink) == 5

    let wrapped = wrapAnsiText(styleBold("中文测试加粗换行能力与English混合排版"), 12)
    check wrapped.len >= 3
    for wl in wrapped:
      check visibleWidth(wl) <= 12
      check "\x1b[1m" in wl

  test "InputEditor UTF-8/CJK editing, multi-line, bracketed paste collapse, undo, history, and autocomplete":
    let prevColors = colorsActive()
    setColorsEnabled(true)
    defer: setColorsEnabled(prevColors)

    let root = getTempDir() / ("ni_ed_" & $nowUnixMs())
    let ws = root / "ws"
    createDir(ws / "src")
    writeFile(ws / "src" / "main.nim", "echo 1\n")
    writeFile(ws / "README.md", "# Demo\n")
    defer: removeDir(root)

    let histFile = root / "ni_history.jsonl"
    let cmds = @[
      SlashCommandDef(name: "model", argumentHint: "[provider/model]", description: "Switch model", source: "builtin"),
      SlashCommandDef(name: "mcp", description: "Inspect MCP", source: "builtin"),
      SlashCommandDef(name: "review", argumentHint: "<target>", description: "Review code", source: "prompt")
    ]
    let ed = newInputEditor(workspaceRoot = ws, historyFile = histFile, commands = cmds)

    # 1. Slash command autocomplete (`/mo` + Tab -> `/model `)
    discard ed.handleKeyEvent(KeyEvent(kind: kkChar, ch: '/', text: "/"))
    discard ed.handleKeyEvent(KeyEvent(kind: kkChar, ch: 'm', text: "m"))
    discard ed.handleKeyEvent(KeyEvent(kind: kkChar, ch: 'o', text: "o"))
    check ed.acKind == ackSlash
    check ed.acItems.len >= 1
    check ed.acItems[0].display.startsWith("/model")
    discard ed.handleKeyEvent(KeyEvent(kind: kkTab))
    check ed.currentText() == "/model "

    # Clear with Ctrl+U and test CJK rune-safe movement + Backspace + Undo
    discard ed.handleKeyEvent(KeyEvent(kind: kkCtrlU))
    check ed.currentText() == ""
    ed.insertTextAtCursor("你好世界")
    discard ed.handleKeyEvent(KeyEvent(kind: kkLeft))
    discard ed.handleKeyEvent(KeyEvent(kind: kkBackspace))
    check ed.currentText() == "你好界"
    discard ed.handleKeyEvent(KeyEvent(kind: kkUndo))
    check ed.currentText() == "你好世界"

    # 2. `@file` workspace autocomplete (`@src/ma` + Tab -> `@src/main.nim `)
    discard ed.handleKeyEvent(KeyEvent(kind: kkEnd))
    ed.insertTextAtCursor(" @src/ma")
    check ed.acKind == ackFile
    check ed.acItems.len == 1
    check ed.acItems[0].display == "@src/main.nim"
    discard ed.handleKeyEvent(KeyEvent(kind: kkTab))
    check ed.currentText() == "你好世界 @src/main.nim "

    # 3. Multi-line newline + large bracketed paste collapsing into atomic `[paste #1 +5 lines]`
    discard ed.handleKeyEvent(KeyEvent(kind: kkNewline))
    let bigPaste = "lineA\nlineB\nlineC\nlineD\nlineE"
    discard ed.handleKeyEvent(KeyEvent(kind: kkPaste, text: bigPaste))
    check "[paste #1 +5 lines]" in ed.currentText()
    check ed.expandedText().endsWith(bigPaste)

    # Frame rendering includes borders, cursor, and status footer
    let frame = renderEditorFrame(ed, EditorStatusInfo(
      cwd: ws,
      gitBranch: "main",
      modelLabel: "anthropic/claude-sonnet-4-6",
      thinkingLabel: "high",
      contextPct: 14,
      totalTokens: 1200,
      costUsd: 0.0125
    ), 80)
    check frame.len >= 5
    check "claude-sonnet-4-6:high" in stripAnsi(frame[^1])

    # Submit expands paste marker and persists history
    let subOpt = ed.handleKeyEvent(KeyEvent(kind: kkEnter))
    check subOpt.isSome
    check subOpt.get.kind == eokSubmit
    check "你好世界 @src/main.nim \nlineA\nlineB\nlineC\nlineD\nlineE" == subOpt.get.text
    check fileExists(histFile)

    # Reload history in a fresh editor and navigate Up
    let ed2 = newInputEditor(workspaceRoot = ws, historyFile = histFile, commands = cmds)
    discard ed2.handleKeyEvent(KeyEvent(kind: kkUp))
    check "lineE" in ed2.currentText()

  test "Short terminals keep the active editor row and autocomplete within the dock":
    let ed = newInputEditor()
    let draft = "start\n" & "你好\n".repeat(10) & "finish"
    ed.setText(draft)
    let status = EditorStatusInfo(modelLabel: "local-model", queuedMessages: @["first", "second", "third"])

    let bottom = renderEditorFrame(ed, status, 22, maxRows = 6)
    check bottom.len == 6
    check "finish" in stripAnsi(bottom.join("\n"))
    check "local-model" in stripAnsi(bottom[^1])
    check "start" notin stripAnsi(bottom.join("\n"))

    ed.cursorLine = 0
    ed.cursorCol = 0
    let top = renderEditorFrame(ed, status, 22, maxRows = 6)
    check "start" in stripAnsi(top.join("\n"))
    check ed.currentText() == draft

    ed.setText("/model ")
    ed.acKind = ackModelArg
    ed.acItems = @[AutocompleteItem(display: "provider/very-long-model", description: "Very long model description")]
    let menu = renderEditorFrame(ed, status, 22, maxRows = 7)
    check menu.len <= 7
    check "queued messages" in stripAnsi(menu.join("\n"))
    check "provider/" in stripAnsi(menu[^1])
    for line in menu:
      check visibleWidth(line) <= 22

  test "Follow-up reads the Pi shortcut and supports disabling it":
    let root = getTempDir() / ("ni_keys_" & $nowUnixMs())
    createDir(root)
    defer: removeDir(root)
    let path = root / "keybindings.json"
    let defaultKeys = when defined(windows): {kkCtrlQ} else: {kkAltEnter}
    check loadFollowUpKeys(root) == defaultKeys
    writeFile(path, """{"app.message.followUp": "ctrl+s"}""")
    check loadFollowUpKeys(root) == {kkCtrlS}
    writeFile(path, """{"app.message.followUp": ["alt+enter", "ctrl+q"]}""")
    check loadFollowUpKeys(root) == {kkCtrlQ, kkAltEnter}
    writeFile(path, """{"app.message.followUp": []}""")
    check loadFollowUpKeys(root) == {}
    writeFile(path, """{"app.message.followUp": "unknown"}""")
    check loadFollowUpKeys(root) == defaultKeys

  test "Streaming Markdown waits for a complete blank line before committing a paragraph":
    let renderer = newStreamMarkdownRenderer(48)
    let first = renderer.stepStreamMarkdown("Hello\n  ", 4)
    check first.committedLines.len == 0
    let second = renderer.stepStreamMarkdown("world\n\n", 4)
    check second.committedLines == @["Hello world", ""]
    check renderer.flushStreamMarkdown().len == 0

  test "Streaming Markdown commits oversized fences once and renders complete tables at their final width":
    let renderer = newStreamMarkdownRenderer(48)
    let code = "```text\n" & "line\n".repeat(12)
    let first = renderer.stepStreamMarkdown(code, 4)
    check first.committedLines.len > 0
    check first.activeTailLines.len == 4
    renderer.maxWidth = 32
    let second = renderer.stepStreamMarkdown("```\n", 4)
    check first.committedLines & second.committedLines == renderMarkdown(code & "```", 48) & @[""]
    check renderer.flushStreamMarkdown().len == 0

    let table = "| A | B |\n| --- | --- |\n" & "| one | two |\n".repeat(8)
    let partial = renderer.stepStreamMarkdown(table, 4)
    check partial.committedLines.len == 0
    check partial.activeTailLines.len == 4
    let lastRow = "| wider column | 三 |"
    let completed = renderer.stepStreamMarkdown(lastRow & "\n\n", 4)
    check completed.committedLines == renderMarkdown(table & lastRow, 32) & @[""]
    check renderer.flushStreamMarkdown().len == 0

  test "Markdown renderer: headings, CJK inline styles, snake_case safety, GFM tables, alerts, and code syntax":
    let prevColors = colorsActive()
    setColorsEnabled(true)
    defer: setColorsEnabled(prevColors)

    let mdDoc = """
<!-- hidden comment -->
# 架构概览

支持**中文加粗**、`inline_code`、~~删除线~~，且保留 snake_case_ident_name 不被斜体破坏。
详情见 [Pi Docs](https://example.com/docs)，或直接访问 https://example.com/test。

> [!WARNING]
> 请勿直接修改生成文件。

| 能力模块 | 状态 | 备注 |
| :--- | :---: | ---: |
| 输入框 Editor | 已完成 | UTF-8 + 补全 |
| Markdown 渲染 | 已完成 | 表格对齐 |

- [x] 支持任务列表勾选
- [ ] 待办事项演示

```nim
# Nim syntax highlight check
proc greet*(name: string): int =
  let count = 42
  echo "Hello " & name
  return count
```
"""
    let rendered = renderMarkdown(mdDoc, maxWidth = 76)
    let plainJoined = stripAnsi(rendered.join("\n"))

    check "hidden comment" notin plainJoined
    check "架构概览" in plainJoined
    check "snake_case_ident_name" in plainJoined
    check "☑ 支持任务列表勾选" in plainJoined
    check "☐ 待办事项演示" in plainJoined
    check "Warning" in plainJoined

    # Verify every row of the GFM box-drawn table has identical visible column width!
    var tableRowWidths: seq[int] = @[]
    for rline in rendered:
      let p = stripAnsi(rline)
      if p.startsWith("┌") or p.startsWith("├") or p.startsWith("└") or p.startsWith("│"):
        tableRowWidths.add(visibleWidth(rline))
    check tableRowWidths.len >= 5
    for w in tableRowWidths:
      check w == tableRowWidths[0]

    # Verify syntax highlighting emitted ANSI SGR escapes on `proc` and `"Hello "`
    var sawHighlightedProc = false
    for rline in rendered:
      if "greet" in rline and "\x1b[" in rline:
        sawHighlightedProc = true
    check sawHighlightedProc

suite "Native Anthropic & Gemini Streaming Providers, Prompt Templates, Fuzzy Edit, and RPC":
  test "Anthropic Messages (/v1/messages) SSE streaming, prompt caching, merged tool_result, and signature replay":
    let tmp = getTempDir() / ("ni_anth_" & $nowUnixMs())
    createDir(tmp / "ws")
    defer: removeDir(tmp)

    var requests: seq[JsonNode] = @[]
    var capturedHeaders: Table[string, string]
    var turn = 0

    let mockAnthTransport: HttpStreamTransport = proc(
      url, httpMethod: string,
      headers: Table[string, string],
      body, proxyUrl: string,
      timeoutMs: int,
      abort: AbortFlag,
      onLine: HttpLineChunkCallback
    ): HttpStreamResponse =
      inc turn
      check url == "https://api.anthropic.com/v1/messages"
      capturedHeaders = headers
      requests.add(parseJson(body))
      if turn == 1:
        onLine("""data: {"type":"message_start","message":{"id":"msg_01","usage":{"input_tokens":80,"cache_read_input_tokens":40,"cache_creation_input_tokens":10,"output_tokens":1}}}""")
        onLine("""data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}""")
        onLine("""data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Inspecting directory."}}""")
        onLine("""data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"anth_sig_enc_999"}}""")
        onLine("""data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_a","name":"ls"}}""")
        onLine("""data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\".\"}"}}""")
        onLine("""data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_b","name":"ls"}}""")
        onLine("""data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}""")
        onLine("""data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":35}}""")
        return HttpStreamResponse(statusCode: 200)
      else:
        onLine("""data: {"type":"message_start","message":{"id":"msg_02","usage":{"input_tokens":110,"cache_read_input_tokens":90,"output_tokens":1}}}""")
        onLine("""data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}""")
        onLine("""data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Anthropic multi-turn OK!"}}""")
        onLine("""data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}""")
        return HttpStreamResponse(statusCode: 200)

    let cfg = loadConfigBundle(tmp / "ws", tmp / "agent")
    let provReg = newProviderRegistry(cfg, mockAnthTransport)
    let toolReg = newToolRegistry(DefaultBuiltInTools)
    let mcpMgr = McpManager(servers: initOrderedTable[string, McpServerSession](), diagnostics: @[], workspaceRoot: tmp / "ws")
    let sess = newSessionManager(tmp / "ws", tmp / "sessions", persist = false)
    let (claudeModel, _) = provReg.resolveModel(cfg, "anthropic/claude-sonnet-4-5", cliApiKey = "sk-ant-api03-test")

    let rt = newAgentRuntime(
      cfg = cfg,
      providerRegistry = provReg,
      toolRegistry = toolReg,
      mcpManager = mcpMgr,
      skills = @[],
      security = newSecurityPolicy(tmp / "ws", tmp / "agent"),
      session = sess,
      initialModel = claudeModel,
      thinkingLevel = tlMedium,
      cliApiKey = "sk-ant-api03-test"
    )

    let finalMsg = rt.runPrompt("Check workspace")
    check finalMsg.stopReason == srStop
    check collectText(finalMsg.assistantBlocks) == "Anthropic multi-turn OK!"
    check capturedHeaders["x-api-key"] == "sk-ant-api03-test"
    check capturedHeaders["anthropic-version"] == "2023-06-01"

    # Verify turn 2 merged both tool_results into one `user` message and replayed encrypted thinking `signature`
    check requests.len == 2
    let msgs2 = requests[1]["messages"]
    check msgs2.len == 3 # user -> assistant(thinking + 2 tool_use) -> user(2 merged tool_result)
    check msgs2[1]["content"][0]["signature"].getStr() == "anth_sig_enc_999"
    check msgs2[2]["role"].getStr() == "user"
    check msgs2[2]["content"].len == 2
    check msgs2[2]["content"][0]["type"].getStr() == "tool_result"
    check msgs2[2]["content"][1]["type"].getStr() == "tool_result"

  test "Google Gemini (:streamGenerateContent?alt=sse) SSE streaming and thoughtSignature replay":
    let tmp = getTempDir() / ("ni_gem_" & $nowUnixMs())
    createDir(tmp / "ws")
    defer: removeDir(tmp)

    var gemBodies: seq[JsonNode] = @[]
    var gemTurn = 0
    let validB64Sig = "R2VtaW5pVGhvdWdodFNpZzEyMzQ=" # 28 chars (multiple of 4, valid base64)

    let mockGemTransport: HttpStreamTransport = proc(
      url, httpMethod: string,
      headers: Table[string, string],
      body, proxyUrl: string,
      timeoutMs: int,
      abort: AbortFlag,
      onLine: HttpLineChunkCallback
    ): HttpStreamResponse =
      inc gemTurn
      check ":streamGenerateContent?alt=sse" in url
      check headers["x-goog-api-key"] == "AIzaSyTestKey"
      gemBodies.add(parseJson(body))
      if gemTurn == 1:
        onLine("""data: {"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"Planning ls call.","thoughtSignature":"""" & validB64Sig & """"},{"functionCall":{"id":"gcall_1","name":"ls","args":{"path":"."}},"thoughtSignature":"""" & validB64Sig & """"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":60,"candidatesTokenCount":15,"thoughtsTokenCount":10,"totalTokenCount":85}}""")
        return HttpStreamResponse(statusCode: 200)
      else:
        onLine("""data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Gemini 3 works!"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":95,"candidatesTokenCount":8,"totalTokenCount":103}}""")
        return HttpStreamResponse(statusCode: 200)

    let cfg = loadConfigBundle(tmp / "ws", tmp / "agent")
    let provReg = newProviderRegistry(cfg, mockGemTransport)
    let toolReg = newToolRegistry(DefaultBuiltInTools)
    let mcpMgr = McpManager(servers: initOrderedTable[string, McpServerSession](), diagnostics: @[], workspaceRoot: tmp / "ws")
    let sess = newSessionManager(tmp / "ws", tmp / "sessions", persist = false)
    let (gemModel, _) = provReg.resolveModel(cfg, "google/gemini-3-flash-preview", cliApiKey = "AIzaSyTestKey")

    let rt = newAgentRuntime(
      cfg = cfg,
      providerRegistry = provReg,
      toolRegistry = toolReg,
      mcpManager = mcpMgr,
      skills = @[],
      security = newSecurityPolicy(tmp / "ws", tmp / "agent"),
      session = sess,
      initialModel = gemModel,
      thinkingLevel = tlHigh,
      cliApiKey = "AIzaSyTestKey"
    )

    let reply = rt.runPrompt("Run ls")
    check reply.stopReason == srStop
    check collectText(reply.assistantBlocks) == "Gemini 3 works!"
    check gemBodies.len == 2
    check gemBodies[0]["generationConfig"]["thinkingConfig"]["thinkingLevel"].getStr() == "HIGH"
    let replayedModelParts = gemBodies[1]["contents"][1]["parts"]
    check replayedModelParts[0]["thought"].getBool() == true
    check replayedModelParts[0]["thoughtSignature"].getStr() == validB64Sig
    check replayedModelParts[1]["functionCall"]["id"].getStr() == "gcall_1"
    check replayedModelParts[1]["thoughtSignature"].getStr() == validB64Sig

  test "Prompt templates ($1, $@, ${2:-default}, ${@:2}), fuzzy edit fallback, and session tree + HTML/MD export":
    let root = getTempDir() / ("ni_tpl_" & $nowUnixMs())
    let ws = root / "ws"
    let agentDir = root / "agent"
    createDir(ws / ".pi" / "prompts")
    createDir(agentDir)
    defer: removeDir(root)

    writeFile(ws / ".pi" / "prompts" / "audit.md", """---
description: Security and style audit template
argument-hint: <file> [severity]
---
Audit target: $1 (severity=${2:-high})
Extra flags: ${@:3}
All args: $@""")

    let (tpls, diags) = discoverPromptTemplates(ws, agentDir, projectTrusted = true)
    check diags.len == 0
    check tpls.len == 1
    check tpls[0].name == "audit"
    check tpls[0].argumentHint == "<file> [severity]"

    let expandedDefault = expandPromptTemplateCommand("/audit \"src/main.nim\"", tpls)
    check expandedDefault.isSome
    check "Audit target: src/main.nim (severity=high)" in expandedDefault.get

    let expandedFull = expandPromptTemplateCommand("/audit src/a.nim critical --fast --strict", tpls)
    check expandedFull.isSome
    check "severity=critical" in expandedFull.get
    check "Extra flags: --fast --strict" in expandedFull.get

    # Fuzzy `edit` test: file has trailing spaces, smart quotes, em-dash, UTF-8 BOM, and CRLF
    let fuzzyPath = ws / "fuzzy.txt"
    writeFile(fuzzyPath, "\xEF\xBB\xBFkeep_top = 1\r\nmsg = “hello — world”   \r\nkeep_bottom = 2\r\n")
    let reg = newToolRegistry(DefaultBuiltInTools)
    let ctx = ToolContext(cwd: ws, settings: defaultSettings(), security: newSecurityPolicy(ws, agentDir), abort: newAbortFlag())
    let editRes = reg.invokeTool("edit", %*{
      "path": "fuzzy.txt",
      "edits": [{ "oldText": "msg = \"hello - world\"", "newText": "msg = \"updated cleanly\"" }]
    }, ctx)
    check not editRes.isError
    let afterBytes = readFile(fuzzyPath)
    check afterBytes == "\xEF\xBB\xBFkeep_top = 1\r\nmsg = \"updated cleanly\"\r\nkeep_bottom = 2\r\n"

    # Session tree items, fork, and HTML/Markdown export
    let sm = newSessionManager(ws, root / "sessions", persist = true, sessionName = "Export Demo")
    let u1 = sm.appendMessage(newUserMessage("First question"))
    discard sm.appendMessage(AgentMessage(role: mrAssistant, timestampMs: nowUnixMs(), provider: "deepseek", model: "deepseek-v4-pro", assistantBlocks: @[textBlock("First answer")]))
    check sm.branchTo(u1)
    discard sm.appendMessage(AgentMessage(role: mrAssistant, timestampMs: nowUnixMs(), provider: "anthropic", model: "claude-sonnet-4-6", assistantBlocks: @[textBlock("Branched second answer")]))

    let treeItems = sm.buildSessionTreeItems()
    check treeItems.len >= 4
    let forked = sm.forkSessionAtEntry(sm.leafId, root / "sessions")
    check forked.id != sm.id
    let htmlPath = sm.exportSessionToFile(ws / "out.html")
    let mdPath = sm.exportSessionToFile(ws / "out.md")
    check fileExists(htmlPath)
    check fileExists(mdPath)
    check "Branched second answer" in readFile(htmlPath)
    check "Branched second answer" in readFile(mdPath)

  test "Headless `ni --mode rpc` E2E over stdin/stdout JSONL":
    let pythonExe = findExe("python3")
    let niBin = getCurrentDir() / addFileExt("ni", ExeExt)
    if pythonExe.len == 0 or not fileExists(niBin):
      echo "  (Skipping RPC E2E test: requires python3 and compiled ./ni)"
    else:
      let root = getTempDir() / ("ni_rpc_" & $nowUnixMs())
      let agentDir = root / "agent"
      let ws = root / "ws"
      createDir(agentDir / "prompts")
      createDir(ws)
      defer: removeDir(root)

      writeFile(agentDir / "prompts" / "pingtpl.md", "Say pong to $1")
      let portFile = root / "rpc_port.txt"
      let srvPy = root / "rpc_mock_llm.py"
      writeFile(srvPy, """
import http.server, json, socketserver, sys

port_file = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}
        user_txt = ""
        for m in body.get("messages", []):
            if m.get("role") == "user":
                user_txt = str(m.get("content", ""))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        chunk = {"choices": [{"delta": {"content": "RPC_REPLY:" + user_txt}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17}}
        self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode("utf-8"))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    with open(port_file, "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
""")
      let srvProc = startProcess(pythonExe, args = @["-u", srvPy, portFile], options = {poUsePath})
      defer:
        try:
          srvProc.terminate()
          discard srvProc.waitForExit(1000)
          srvProc.close()
        except CatchableError:
          discard

      var port = ""
      for _ in 0 ..< 50:
        if fileExists(portFile):
          port = readFile(portFile).strip()
          if port.len > 0: break
        sleep(40)
      check port.len > 0

      writeFile(agentDir / "models.json", """{
        "providers": {
          "rpcmock": {
            "baseUrl": "http://127.0.0.1:""" & port & """/v1",
            "api": "openai-completions",
            "apiKey": "rpc-key",
            "models": [{ "id": "rpc-model" }]
          }
        }
      }""")

      let rpcProc = startProcess(
        niBin,
        workingDir = ws,
        args = @["--mode", "rpc", "--no-mcp", "--model", "rpcmock/rpc-model", "--agent-dir", agentDir],
        options = {poUsePath}
      )
      defer:
        try: rpcProc.close() except CatchableError: discard

      let rpcInput = [
        """{"id":"1","type":"get_state"}""",
        """{"id":"2","type":"get_commands"}""",
        """{"id":"3","type":"prompt","message":"/pingtpl Alice"}""",
        """{"id":"4","type":"get_last_assistant_text"}""",
        """{"id":"5","type":"get_tree"}"""
      ].join("\n") & "\n"

      rpcProc.inputStream.write(rpcInput)
      rpcProc.inputStream.flush()
      rpcProc.inputStream.close()

      let rpcOut = rpcProc.outputStream.readAll()
      check rpcProc.waitForExit() == 0

      var sawState = false
      var sawPromptCmd = false
      var sawAgentEnd = false
      var sawLastText = false
      var sawTree = false
      for line in rpcOut.splitLines():
        let t = line.strip()
        if t.len == 0: continue
        let j = parseJson(t)
        if j{"id"}.getStr("") == "1" and j{"success"}.getBool():
          check j["data"]["model"]["id"].getStr() == "rpc-model"
          sawState = true
        elif j{"id"}.getStr("") == "2" and j{"success"}.getBool():
          if "pingtpl" in $j["data"]["commands"]:
            sawPromptCmd = true
        elif j{"type"}.getStr("") == "agent_end":
          sawAgentEnd = true
        elif j{"id"}.getStr("") == "4" and j{"success"}.getBool():
          check j["data"]["text"].getStr() == "RPC_REPLY:Say pong to Alice"
          sawLastText = true
        elif j{"id"}.getStr("") == "5" and j{"success"}.getBool():
          check j["data"]["tree"].len >= 2
          sawTree = true

      check sawState
      check sawPromptCmd
      check sawAgentEnd
      check sawLastText
      check sawTree
