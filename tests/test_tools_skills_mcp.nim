# Unit and live subprocess integration tests for built-in tools, Agent Skills, MCP (stdio + HTTP SSE), and clipboard helpers.

import std/[json, options, os, sets, strutils, tables, unittest]
import ../src/ni/[types, config, trust, tools, skills, mcp, terminal_io]
when defined(macosx) or defined(linux):
  import ../src/ni/sandbox

suite "Tools, Agent Skills, Live Stdio MCP Server, and Clipboard":
  when defined(macosx) or defined(linux):
    test "Restricted workspaces enforce native tool paths and Shell write modes":
      if defined(linux) and findExe("bwrap").len == 0:
        skip()
      else:
        let root = getTempDir() / ("ni_sandbox_" & $nowUnixMs())
        let workspace = root / "workspace"
        createDir(workspace)
        defer: removeDir(root)
        writeFile(root / "outside.txt", "outside")
        writeFile(workspace / "inside.txt", "inside")
        createSymlink(root / "missing.txt", workspace / "dangling.txt")
        let registry = newToolRegistry(DefaultBuiltInTools)
        for mode in [sandboxReadOnly, sandboxWorkspaceWrite]:
          let policy = newSecurityPolicy(workspace, root / "agent", smPermissive)
          policy.configureSandbox(mode)
          defer: policy.closeSandbox()
          let ctx = ToolContext(cwd: workspace, settings: defaultSettings(), security: policy, abort: newAbortFlag())
          check registry.invokeTool("read", %*{"path": "inside.txt"}, ctx).isError == false
          check registry.invokeTool("read", %*{"path": "../outside.txt"}, ctx).isError
          check registry.invokeTool("write", %*{"path": "dangling.txt", "content": "denied"}, ctx).isError
          check not fileExists(root / "missing.txt")
          let writeInside = registry.invokeTool("write", %*{"path": "written.txt", "content": "yes"}, ctx)
          check writeInside.isError == (mode == sandboxReadOnly)
          let res = runUserShell("printf yes > shell-written.txt; printf no > ../shell-outside.txt",
            workspace, ctx.settings, policy, ctx.abort)
          check res.exitCode != 0
          check fileExists(workspace / "shell-written.txt") == (mode == sandboxWorkspaceWrite)
          check not fileExists(root / "shell-outside.txt")

  test "read, write, edit (BOM + CRLF preservation + uniqueness + diff), ls, find, grep, bash":
    let ws = getTempDir() / ("ni_tools_" & $nowUnixMs())
    createDir(ws)
    defer: removeDir(ws)

    let reg = newToolRegistry(DefaultBuiltInTools)
    let sec = newSecurityPolicy(ws, ws / ".agent", smBalanced)
    let ctx = ToolContext(cwd: ws, settings: defaultSettings(), security: sec, abort: newAbortFlag())

    # Write & Read with offset/limit
    let wOut = reg.invokeTool("write", %*{
      "path": "src/demo.nim",
      "content": "line1\nline2\nline3\nline4\nline5"
    }, ctx)
    check not wOut.isError

    let rOut = reg.invokeTool("read", %*{ "path": "src/demo.nim", "offset": 2, "limit": 2 }, ctx)
    check not rOut.isError
    let rText = collectText(rOut.content)
    check "line2\nline3" in rText
    check "offset=4" in rText

    # Edit preserving UTF-8 BOM and Windows CRLF line endings!
    let crlfPath = ws / "win_file.txt"
    writeFile(crlfPath, "\xEF\xBB\xBFalpha\r\nbeta\r\ngamma\r\ndelta\r\n")
    let eOut = reg.invokeTool("edit", %*{
      "path": "win_file.txt",
      "edits": [
        { "oldText": "alpha\nbeta", "newText": "ALPHA\nBETA" },
        { "oldText": "delta", "newText": "DELTA" }
      ]
    }, ctx)
    check not eOut.isError
    check "+ALPHA" in eOut.diff
    let updatedRaw = readFile(crlfPath)
    check updatedRaw.startsWith("\xEF\xBB\xBF")
    check updatedRaw == "\xEF\xBB\xBFALPHA\r\nBETA\r\ngamma\r\nDELTA\r\n"

    # Duplicate oldText must fail safely without corrupting file
    writeFile(ws / "dup.txt", "same\nsame\n")
    let dupOut = reg.invokeTool("edit", %*{
      "path": "dup.txt",
      "edits": [{ "oldText": "same", "newText": "changed" }]
    }, ctx)
    check dupOut.isError

    # ls, find, grep
    let lsOut = reg.invokeTool("ls", %*{}, ctx)
    check "src/" in collectText(lsOut.content)

    let findOut = reg.invokeTool("find", %*{ "pattern": "**/*.nim" }, ctx)
    check collectText(findOut.content).strip() == "src/demo.nim"

    let grepOut = reg.invokeTool("grep", %*{ "pattern": "line3", "literal": true }, ctx)
    check "demo.nim:3:" in collectText(grepOut.content)

    # bash execution + timeout handling
    let bOk = reg.invokeTool("bash", %*{ "command": "printf 'ni-bash-ok'" }, ctx)
    check not bOk.isError
    check collectText(bOk.content) == "ni-bash-ok"

    let bTimeout = reg.invokeTool("bash", %*{ "command": "sleep 3", "timeout": 0.2 }, ctx)
    check bTimeout.isError
    check "timed out" in collectText(bTimeout.content).toLowerAscii()

  test "Tool output byte limits preserve UTF-8 characters at both edges":
    check truncateHead("ab中😀", maxBytes = 4).content == "ab"
    check truncateHead("ab中😀", maxBytes = 5).content == "ab中"
    check truncateHead("ab中😀", maxBytes = 8).content == "ab中"

    let half = McpToolMaxTextBytes div 2
    let prefix = repeat('a', half - 1)
    let suffix = repeat('b', half - 1)
    let raw = prefix & "中hidden😀" & suffix
    let clipped = middleTruncateMcpText(raw, "utf8-test")
    require clipped.savedPath.len > 0
    defer: removeFile(clipped.savedPath)
    check readFile(clipped.savedPath) == raw
    check clipped.output.startsWith(prefix & "\n…13 bytes truncated…\n" & suffix & "\n")

  test "SKILL.md discovery, validation, <available_skills> XML, and /skill:<name> expansion":
    let root = getTempDir() / ("ni_skills_" & $nowUnixMs())
    let agentDir = root / "agent"
    let ws = root / "ws"
    createDir(agentDir / "skills" / "nim-style")
    createDir(ws / ".pi" / "skills" / "deploy-only")
    defer: removeDir(root)

    writeFile(agentDir / "skills" / "nim-style" / "SKILL.md", """---
name: nim-style
description: Idiomatic Nim 2.4 style rules and memory management guidance.
---
Always prefer tagged object variants and explicit error handling.""")

    writeFile(ws / ".pi" / "skills" / "deploy-only" / "SKILL.md", """---
name: deploy-only
description: Production deployment checklist.
disable-model-invocation: true
---
Step 1: Run full suite before tagging.""")

    let (skillsList, diags) = discoverSkills(ws, agentDir, projectTrusted = true, userAgentsSkillsDir = root / "empty_agents_skills")
    check diags.len == 0
    check skillsList.len == 2

    let xml = formatSkillsForPrompt(skillsList)
    check "<name>nim-style</name>" in xml
    # disable-model-invocation skill is hidden from automatic prompt XML
    check "deploy-only" notin xml

    # Explicit /skill:deploy-only command still works!
    let expanded = expandSkillCommand("/skill:deploy-only v1.2.0", skillsList)
    check expanded.isSome
    check "Step 1: Run full suite before tagging." in expanded.get
    check "v1.2.0" in expanded.get

  test "Live Stdio MCP server (handshake, server ping, direct & deferred tools, tool_search, resources, mcp add/remove)":
    let pythonExe = findExe("python3")
    if pythonExe.len == 0:
      echo "  (Skipping live Python MCP subprocess test: python3 not on PATH)"
    else:
      let root = getTempDir() / ("ni_mcp_" & $nowUnixMs())
      let agentDir = root / "agent"
      let ws = root / "ws"
      createDir(agentDir)
      createDir(ws)
      defer: removeDir(root)

      let serverScript = root / "mock_mcp_server.py"
      writeFile(serverScript, """
import sys, json

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        send({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2025-03-26",
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": "demo-mcp", "version": "1.0.0"},
                "instructions": "Demo math and docs MCP server"
            }
        })
    elif method == "tools/list":
        # Send a server->client ping BEFORE replying to verify bidirectional JSON-RPC handling!
        send({"jsonrpc": "2.0", "id": 999, "method": "ping"})
        ping_reply = json.loads(sys.stdin.readline().strip())
        assert ping_reply.get("id") == 999
        send({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "tools": [
                    {
                        "name": "add_numbers",
                        "description": "Add two integers a and b",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                            "required": ["a", "b"]
                        }
                    },
                    {
                        "name": "search_wiki",
                        "description": "Search internal engineering wiki articles",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"topic": {"type": "string"}},
                            "required": ["topic"]
                        }
                    }
                ]
            }
        })
    elif method == "tools/call":
        params = msg.get("params", {})
        tname = params.get("name")
        targs = params.get("arguments", {})
        if tname == "add_numbers":
            total = int(targs.get("a", 0)) + int(targs.get("b", 0))
            send({"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": f"sum={total}"}]}})
        elif tname == "search_wiki":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": "Wiki hit: " + str(targs.get("topic", ""))}]}})
    elif method == "resources/list":
        send({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"resources": [{"uri": "memo://welcome", "name": "Welcome Memo"}]}
        })
    elif method == "resources/read":
        send({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"contents": [{"uri": "memo://welcome", "text": "Hello from MCP resource!"}]}
        })
""")

      let mcpJsonPath = agentDir / "mcp.json"
      saveMcpServerEntry(mcpJsonPath, McpServerConfig(
        name: "demo-srv",
        transportKind: mtkStdio,
        command: pythonExe,
        args: @["-u", serverScript],
        cwd: ws,
        timeoutSec: 10,
        enabled: true,
        exposure: teDeferred,
        toolExposure: toOrderedTable({"add_numbers": teDirect}),
        description: "Demo math & wiki server"
      ))
      # Patch toolExposure into mcp.json to verify per-tool exposure override!
      var mcpNode = parseJson(readFile(mcpJsonPath))
      mcpNode["mcpServers"]["demo-srv"]["toolExposure"] = %*{ "add_numbers": "direct" }
      writeFile(mcpJsonPath, mcpNode.pretty())

      let cfg = loadConfigBundle(ws, agentDir)
      let toolReg = newToolRegistry(cfg.settings.defaultTools)
      let mgr = newMcpManager(cfg, toolReg, connectNow = true)
      defer: mgr.closeAll()

      check mgr.diagnostics.len == 0
      check mgr.servers["demo-srv"].state == mcsConnected

      # add_numbers is direct; search_wiki is deferred; tool_search was auto-enabled!
      check "mcp__demo_srv__add_numbers" in toolReg.activeNames
      check "mcp__demo_srv__search_wiki" notin toolReg.activeNames
      check "tool_search" in toolReg.activeNames

      let ctx = ToolContext(cwd: ws, settings: cfg.settings, security: newSecurityPolicy(ws, agentDir), abort: newAbortFlag())
      let sumOut = toolReg.invokeTool("mcp__demo_srv__add_numbers", %*{ "a": 19, "b": 23 }, ctx)
      check not sumOut.isError
      check collectText(sumOut.content) == "sum=42"

      # Discover & activate search_wiki through tool_search!
      check toolReg.invokeTool("mcp__demo_srv__search_wiki", %*{"topic": "nim-orc"}, ctx).isError
      let searchOut = toolReg.invokeTool("tool_search", %*{ "query": "wiki articles" }, ctx)
      check not searchOut.isError
      check "mcp__demo_srv__search_wiki" in toolReg.activeNames

      let wikiOut = toolReg.invokeTool("mcp__demo_srv__search_wiki", %*{ "topic": "nim-orc" }, ctx)
      check collectText(wikiOut.content) == "Wiki hit: nim-orc"

      # Read MCP resources!
      let resources = toolReg.invokeTool("tool_search", %*{"query": "mcp resources"}, ctx)
      check not resources.isError
      let resListOut = toolReg.invokeTool("list_mcp_resources", %*{}, ctx)
      check "memo://welcome" in collectText(resListOut.content)
      let resReadOut = toolReg.invokeTool("read_mcp_resource", %*{ "server": "demo-srv", "uri": "memo://welcome" }, ctx)
      check collectText(resReadOut.content) == "Hello from MCP resource!"
      toolReg.applyToolOverrides(["-mcp__demo_srv__search_wiki"])
      discard toolReg.invokeTool("tool_search", %*{"query": "wiki"}, ctx)
      check toolReg.invokeTool("mcp__demo_srv__search_wiki", %*{"topic": "nim-orc"}, ctx).isError

      # Remove server config entry
      check removeMcpServerEntry(mcpJsonPath, "demo-srv") == true

  test "Streamable HTTP SSE JSON-RPC parser and clipboard code-block extraction":
    let ssePayload = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n\n"
    let parsed = parseSseJsonRpcResponse(ssePayload, 7)
    check parsed.isSome
    check parsed.get["result"]["ok"].getBool() == true

    let osc = buildOsc52Sequence("hello")
    check osc == "\x1b]52;c;aGVsbG8=\x07"

    let md = "Here is code:\n```nim\necho 123\n```\nAnd bash:\n```sh\nls -la\n```"
    let blocks = extractCodeBlocks(md)
    check blocks.len == 2
    check blocks[0] == "echo 123"
    check blocks[1] == "ls -la"
