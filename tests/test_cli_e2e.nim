# End-to-end blackbox CLI tests against the compiled `./ni` binary using a real local HTTP SSE LLM + Streamable HTTP MCP server.

import std/[json, os, osproc, streams, strutils, unittest]
import ../src/ni/[release_info, session, types]

suite "End-to-End CLI Binary + Live Local HTTP SSE Provider + Live Streamable HTTP MCP":
  test "HTTP MCP OAuth discovery, PKCE login, credential refresh and connection management":
    let pythonExe = findExe("python3")
    let niBin = getCurrentDir() / addFileExt("ni", ExeExt)
    if pythonExe.len == 0 or not fileExists(niBin):
      echo "  (Skipping MCP OAuth E2E test: requires python3 and compiled ./ni)"
    else:
      let fixture = getCurrentDir() / "tests" / "mock_mcp_oauth.py"
      let (output, status) = execCmdEx(quoteShellCommand([pythonExe, fixture, niBin]))
      if status != 0: echo output
      check status == 0

  test "CLI auth, MCP, model turns, session persistence, JSONL, and exit codes":
    let pythonExe = findExe("python3")
    let niBin = getCurrentDir() / addFileExt("ni", ExeExt)
    if pythonExe.len == 0 or not fileExists(niBin):
      echo "  (Skipping blackbox HTTP E2E test: requires python3 and compiled ./ni)"
    else:
      let root = getTempDir() / ("ni_e2e_" & $nowUnixMs())
      let agentDir = root / "agent"
      let ws = root / "ws"
      createDir(agentDir)
      createDir(ws)
      defer: removeDir(root)

      writeFile(ws / "note.txt", "NIM_SECRET_NUMBER=777\n")
      let portFile = root / "port.txt"
      let serverPy = root / "mock_http_servers.py"
      writeFile(serverPy, """
import http.server, json, socketserver, sys

port_file = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_DELETE(self):
        self.send_response(204)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8")) if length > 0 else {}

        if self.path.endswith("/chat/completions"):
            msgs = body.get("messages", [])
            has_tool_result = any(m.get("role") == "tool" for m in msgs)
            user_msgs = [m.get("content", "") for m in msgs if m.get("role") == "user"]
            prompt = user_msgs[-1]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if prompt in ("Record the seed", "Recall the seed", "Finish on turn 64",
                          "Use tools forever", "Truncated tool call"):
                result_count = sum(m.get("role") == "tool" for m in msgs)
                call = {"index": 0, "id": f"call_{result_count}", "type": "function",
                        "function": {"name": "read", "arguments": '{"path":"note.txt"}'}}
                if prompt == "Record the seed":
                    choice = {"delta": {"content": "Recorded"}, "finish_reason": "stop"}
                elif prompt == "Recall the seed":
                    answer = "History was loaded" if "Record the seed" in user_msgs[:-1] else "History is missing"
                    choice = {"delta": {"content": answer}, "finish_reason": "stop"}
                elif prompt == "Truncated tool call":
                    choice = {"delta": {"content": "Partial reply", "tool_calls": [call]}, "finish_reason": "length"}
                elif prompt == "Finish on turn 64" and result_count == 63:
                    choice = {"delta": {"content": "Completed at the limit"}, "finish_reason": "stop"}
                else:
                    choice = {"delta": {"tool_calls": [call]}, "finish_reason": "tool_calls"}
                self.wfile.write(("data: " + json.dumps({"choices": [choice]}) + "\n\n").encode("utf-8"))
                self.wfile.write(b"data: [DONE]\n\n")
                return
            if not has_tool_result:
                chunk1 = {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {"name": "read", "arguments": "{\"path\":\"note.txt\"}"}}]}, "finish_reason": "tool_calls"}]}
                self.wfile.write(("data: " + json.dumps(chunk1) + "\n\n").encode("utf-8"))
                self.wfile.write(b"data: [DONE]\n\n")
            else:
                tool_text = [m.get("content", "") for m in msgs if m.get("role") == "tool"][-1]
                ans = "Found: " + tool_text.strip()
                chunk2 = {"choices": [{"delta": {"content": ans}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 30, "completion_tokens": 8, "total_tokens": 38}}
                self.wfile.write(("data: " + json.dumps(chunk2) + "\n\n").encode("utf-8"))
                self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        if self.path == "/mcp":
            method = body.get("method")
            req_id = body.get("id")
            if req_id is None:
                self.send_response(202)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Mcp-Session-Id", "sess-http-123")
            self.end_headers()
            if method == "initialize":
                res = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "http-mcp", "version": "1.0"}}
            elif method == "tools/list":
                res = {"tools": [{"name": "ping_http", "description": "HTTP MCP ping tool", "inputSchema": {"type": "object", "properties": {}}}]}
            elif method == "tools/call":
                res = {"content": [{"type": "text", "text": "pong-from-http"}]}
            else:
                res = {}
            rpc = {"jsonrpc": "2.0", "id": req_id, "result": res}
            self.wfile.write(("event: message\ndata: " + json.dumps(rpc) + "\n\n").encode("utf-8"))
            self.wfile.flush()
            return

        self.send_response(404)
        self.end_headers()

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    with open(port_file, "w") as f:
        f.write(str(port))
    httpd.serve_forever()
""")

      let srvProc = startProcess(pythonExe, args = @["-u", serverPy, portFile], options = {poUsePath})
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
          if port.len > 0:
            break
        sleep(40)
      check port.len > 0

      writeFile(agentDir / "models.json", """{
        "providers": {
          "mocklocal": {
            "baseUrl": "http://127.0.0.1:""" & port & """/v1",
            "api": "openai-completions",
            "models": [{ "id": "local-coder", "contextWindow": 128000 }]
          }
        }
      }""")

      # 1. Test `ni auth login` & `ni auth check`
      let (_, loginCode) = execCmdEx(quoteShell(niBin) & " auth login mocklocal --api-key test-key-99 --agent-dir " & quoteShell(agentDir))
      check loginCode == 0
      let (chkOut, chkCode) = execCmdEx(quoteShell(niBin) & " auth check --provider mocklocal --json --agent-dir " & quoteShell(agentDir))
      check chkCode == 0
      check parseJson(chkOut.strip())["status"].getStr() == "ready"

      # 2. Test `ni mcp add --url` & `ni mcp list --json` against live Streamable HTTP SSE MCP server
      let mcpUrl = "http://127.0.0.1:" & port & "/mcp"
      let (_, addCode) = execCmdEx(quoteShell(niBin) & " mcp add remote-http --exposure direct --url " & quoteShell(mcpUrl) & " --agent-dir " & quoteShell(agentDir))
      check addCode == 0
      let (mcpOut, mcpCode) = execCmdEx(quoteShell(niBin) & " mcp list --json --agent-dir " & quoteShell(agentDir))
      check mcpCode == 0
      let mcpJson = parseJson(mcpOut.strip())
      check mcpJson["servers"][0]["state"].getStr() == "connected"
      check mcpJson["servers"][0]["tools"][0]["qualifiedName"].getStr() == "mcp__remote_http__ping_http"

      # 3. Test `ni --print` over real AsyncHttpClient SSE + `read` tool execution in workspace
      let (pOut, pCode) = execCmdEx(
        "cd " & quoteShell(ws) & " && " & quoteShell(niBin) &
        " -p --model mocklocal/local-coder --agent-dir " & quoteShell(agentDir) &
        " \"Read note.txt and report its content\""
      )
      check pCode == 0
      check "Found: NIM_SECRET_NUMBER=777" in pOut
      let (disabledOut, disabledCode) = execCmdEx(
        "cd " & quoteShell(ws) & " && " & quoteShell(niBin) &
        " -p --no-tools --no-session --model mocklocal/local-coder --agent-dir " & quoteShell(agentDir) &
        " \"Inspect note.txt\""
      )
      check disabledCode == 0
      check "Tool 'read' is not enabled" in disabledOut
      check "NIM_SECRET_NUMBER=777" notin disabledOut

      # 4. Test `ni --mode json` structured JSONL event stream
      let (jOut, jCode) = execCmdEx(
        "cd " & quoteShell(ws) & " && " & quoteShell(niBin) &
        " --mode json --no-session --model mocklocal/local-coder --agent-dir " & quoteShell(agentDir) &
        " \"Inspect note.txt\""
      )
      check jCode == 0
      check "\"type\":\"tool_execution_start\"" in jOut
      check "\"type\":\"agent_end\"" in jOut
      let ephemeralHeader = parseJson(jOut.splitLines()[0])
      check ephemeralHeader["type"] == %"session"
      check ephemeralHeader["version"] == %3
      check ephemeralHeader["cwd"] == %expandFilename(ws)

      let sessions = root / "sessions"
      let cli = "cd " & quoteShell(ws) & " && " & quoteShellCommand([niBin, "--no-mcp",
        "--model", "mocklocal/local-coder", "--agent-dir", agentDir, "--session-dir", sessions])
      let (versionOut, versionCode) = execCmdEx(quoteShellCommand([niBin, "--version"]))
      check versionCode == 0
      check versionOut.strip() == "ni " & NiVersion
      for (invalid, expected) in [
        (@["--mode", "invalid"], "--mode expects text, json, or rpc"),
        (@["--security", "invalid"], "--security expects strict, balanced, or permissive"),
        (@["--mode"], "Missing value for --mode"),
        (@["--security", "--no-tools"], "Missing value for --security"),
        (@["--model"], "Missing value for --model"),
        (@["--session-id", "a/../bad"], "--session-id expects")
      ]:
        let (outp, code) = execCmdEx(cli & " " & quoteShellCommand(@["-p", "Record the seed"] & invalid))
        check code == 1
        check expected in outp
        check "Recorded" notin outp
      check not dirExists(sessions)

      let (_, seedCode) = execCmdEx(cli & " -p --session-id audit-session " & quoteShell("Record the seed"))
      require seedCode == 0
      var savedFiles: seq[string]
      for path in walkDirRec(sessions):
        if path.endsWith(".jsonl"):
          savedFiles.add(path)
      require savedFiles.len == 1
      let savedPath = parentDir(savedFiles[0]) / "20260101T000000_audit-session.jsonl"
      moveFile(savedFiles[0], savedPath)

      let (resumeOut, resumeCode) = execCmdEx(cli & " --mode json --session-id audit-session " & quoteShell("Recall the seed"))
      check resumeCode == 0
      check "History was loaded" in resumeOut
      let original = readFile(savedPath)
      check parseJson(resumeOut.splitLines()[0]) == parseJson(original.splitLines()[0])
      check "Recall the seed" in original

      var beforeFork: seq[string]
      for path in walkDirRec(sessions): beforeFork.add(path)
      let (forkOut, forkCode) = execCmdEx(cli & " -p --no-session --fork " & quoteShell(savedPath) & " " &
        quoteShell("Recall the seed"))
      check forkCode == 0
      check "History was loaded" in forkOut
      check readFile(savedPath) == original
      var remaining: seq[string]
      for path in walkDirRec(sessions):
        remaining.add(path)
      check remaining == beforeFork

      # A complete line lacking its final newline must survive the next append.
      require original.endsWith("\n")
      let previous = loadSessionFile(savedPath, persist = false).activeBranchEntries()
      writeFile(savedPath, original[0 ..< original.len - 1])
      let (noNewlineOut, noNewlineCode) = execCmdEx(cli & " -p --session-id audit-session " & quoteShell("Recall the seed"))
      require noNewlineCode == 0
      check noNewlineOut.strip() == "History was loaded"
      let complete = loadSessionFile(savedPath, persist = false).activeBranchEntries()
      require complete.len == previous.len + 2
      check complete[previous.high].id == previous[^1].id

      let damaged = readFile(savedPath) & "{\"type\":\"message\",\"id\":"
      writeFile(savedPath, damaged)
      let (repairOut, repairCode) = execCmdEx(cli & " -p --session-id audit-session " & quoteShell("Recall the seed"))
      require repairCode == 0
      check "Skipped 1 malformed session record" in repairOut
      check "History was loaded" in repairOut
      check readFile(savedPath).startsWith(damaged & "\n")
      let restored = loadSessionFile(savedPath, persist = false).activeBranchEntries()
      require restored.len == complete.len + 2
      check restored[complete.high].id == complete[^1].id
      let (verifiedOut, verifiedCode) = execCmdEx(cli & " -p --no-session --session " & quoteShell(savedPath) & " " &
        quoteShell("Recall the seed"))
      check verifiedCode == 0
      check "History was loaded" in verifiedOut

      let owner = startProcess(niBin, workingDir = ws, args = @["--mode", "rpc", "--session-id", "parallel-session",
        "--no-mcp", "--model", "mocklocal/local-coder", "--agent-dir", agentDir, "--session-dir", sessions],
        options = {poStdErrToStdOut})
      defer:
        if owner.running(): owner.terminate()
        owner.close()
      owner.inputStream.writeLine("""{"id":"ready","type":"get_state"}""")
      owner.inputStream.flush()
      let ready = parseJson(owner.outputStream.readLine())
      require ready["success"].getBool()
      let parallelPath = ready["data"]["sessionFile"].getStr()
      require parallelPath.len > 0
      let reservedLog = readFile(parallelPath)
      for args in [@["--session-id", "parallel-session"], @["--session", parallelPath]]:
        let (busy, busyCode) = execCmdEx(cli & " " & quoteShellCommand(@["-p"] & args & @["Record the seed"]))
        check busyCode == 1
        check "Session is already open for writing" in busy
        check "Recorded" notin busy
        check readFile(parallelPath) == reservedLog
      var parallelFiles = 0
      for path in walkDirRec(sessions):
        if path.endsWith("_parallel-session.jsonl"): inc parallelFiles
      check parallelFiles == 1

      owner.inputStream.writeLine("""{"id":"leave","type":"new_session"}""")
      owner.inputStream.flush()
      require parseJson(owner.outputStream.readLine())["success"].getBool()
      let (afterSwitch, afterSwitchCode) = execCmdEx(cli & " -p --session-id parallel-session " & quoteShell("Record the seed"))
      require afterSwitchCode == 0
      check afterSwitch.strip() == "Recorded"
      owner.inputStream.writeLine($(%*{"id": "return", "type": "switch_session", "sessionPath": parallelPath}))
      owner.inputStream.flush()
      require parseJson(owner.outputStream.readLine())["success"].getBool()
      owner.terminate()
      discard owner.waitForExit(5000)
      let (afterOwner, afterOwnerCode) = execCmdEx(cli & " -p --session-id parallel-session " & quoteShell("Recall the seed"))
      check afterOwnerCode == 0
      check afterOwner.strip() == "History was loaded"
      check loadSessionFile(parallelPath, persist = false).activeBranchEntries().len == 4

      let (partialOut, partialCode) = execCmdEx(cli & " -p --no-session " & quoteShell("Truncated tool call"))
      check partialCode == 2
      check "Partial reply" in partialOut
      check "Model response reached its output limit" in partialOut
      let (lengthOut, lengthCode) = execCmdEx(cli & " --mode json --no-session " & quoteShell("Truncated tool call"))
      check lengthCode == 2
      check "\"stopReason\":\"length\",\"exitCode\":2" in lengthOut
      check "\"type\":\"tool_execution_start\"" notin lengthOut

      let (limitOut, limitCode) = execCmdEx(cli & " --mode json --no-session " & quoteShell("Use tools forever"))
      check limitCode == 3
      check "\"turns\":64,\"stopReason\":\"turnLimit\",\"exitCode\":3" in limitOut
      let (atLimitOut, atLimitCode) = execCmdEx(cli & " -p --no-session " & quoteShell("Finish on turn 64"))
      check atLimitCode == 0
      check atLimitOut.strip() == "Completed at the limit"
