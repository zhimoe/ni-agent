# End-to-end blackbox CLI tests against the compiled `./ni` binary using a real local HTTP SSE LLM + Streamable HTTP MCP server.

import std/[json, os, osproc, strutils, unittest]
import ../src/ni/types

suite "End-to-End CLI Binary + Live Local HTTP SSE Provider + Live Streamable HTTP MCP":
  test "ni auth CLI, ni mcp HTTP SSE server, ni --print, ni --mode json, and ni --continue":
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
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
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
            "models": [{ "id": "local-coder" }]
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

      # 4. Test `ni --mode json` structured JSONL event stream
      let (jOut, jCode) = execCmdEx(
        "cd " & quoteShell(ws) & " && " & quoteShell(niBin) &
        " --mode json --no-session --model mocklocal/local-coder --agent-dir " & quoteShell(agentDir) &
        " \"Inspect note.txt\""
      )
      check jCode == 0
      check "\"type\":\"tool_execution_start\"" in jOut
      check "\"type\":\"agent_end\"" in jOut
