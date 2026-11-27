"""Exercise Ni's OAuth transport against a loopback MCP and authorization server."""
import base64
import hashlib
import http.server
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import urlopen

binary = Path(sys.argv[1]).resolve()
state = {"registration": 0, "refreshes": 0, "session": 0, "expire_session": True}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, status, data=None, headers=None):
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        if data is None:
            self.end_headers()
        else:
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        target = urlparse(self.path)
        if target.path == "/resource-metadata":
            self.send_json(200, {"resource": resource, "authorization_servers": [origin]})
        elif target.path == "/.well-known/oauth-authorization-server":
            self.send_json(200, {"issuer": origin, "authorization_endpoint": origin + "/authorize",
                                 "token_endpoint": origin + "/token", "registration_endpoint": origin + "/register",
                                 "code_challenge_methods_supported": ["S256"]})
        elif target.path == "/authorize":
            params = {key: values[0] for key, values in parse_qs(target.query).items()}
            assert params["client_id"] == "test-client" and params["resource"] == resource
            assert params["scope"] == "lookup:read" and params["code_challenge_method"] == "S256"
            assert params["redirect_uri"] == state["redirect"]
            state["challenge"] = params["code_challenge"]
            self.send_json(302, headers={"Location": params["redirect_uri"] + "?" + urlencode({
                "code": "test-code", "state": params["state"], "iss": origin})})
        else:
            self.send_json(404)

    def do_DELETE(self):
        self.send_json(204)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/register":
            data = json.loads(raw)
            state["registration"] += 1
            state["redirect"] = data["redirect_uris"][0]
            assert data["token_endpoint_auth_method"] == "none"
            self.send_json(201, {"client_id": "test-client"})
        elif self.path == "/token":
            form = {key: values[0] for key, values in parse_qs(raw.decode()).items()}
            assert form["client_id"] == "test-client" and form["resource"] == resource
            if form["grant_type"] == "authorization_code":
                assert form["redirect_uri"] == state["redirect"] and form["code"] == "test-code"
                digest = hashlib.sha256(form["code_verifier"].encode()).digest()
                assert base64.urlsafe_b64encode(digest).rstrip(b"=").decode() == state["challenge"]
                self.send_json(200, {"access_token": "initial", "refresh_token": "refresh-0",
                                     "token_type": "Bearer", "expires_in": 3600})
            elif form["grant_type"] == "refresh_token":
                assert form["refresh_token"] == f"refresh-{state['refreshes']}"
                state["refreshes"] += 1
                self.send_json(200, {"access_token": f"usable-{state['refreshes']}",
                                     "refresh_token": f"refresh-{state['refreshes']}",
                                     "token_type": "Bearer", "expires_in": 3600})
            else:
                self.send_json(400)
        elif self.path == "/mcp":
            auth = self.headers.get("Authorization")
            if not auth or auth == "Bearer initial":
                self.send_json(401, headers={"WWW-Authenticate":
                    f'Bearer resource_metadata="{origin}/resource-metadata", scope="lookup:read"'})
                return
            assert auth == f"Bearer usable-{state['refreshes']}"
            payload = json.loads(raw)
            method = payload["method"]
            if method == "initialize":
                state["session"] += 1
                self.send_json(200, {"jsonrpc": "2.0", "id": payload["id"],
                                     "result": {"capabilities": {"tools": {}}, "serverInfo": {"name": "oauth-mcp"}}},
                               {"Mcp-Session-Id": str(state["session"])})
            elif "id" not in payload:
                self.send_json(202)
            elif method == "tools/list":
                self.send_json(200, {"jsonrpc": "2.0", "id": payload["id"],
                                     "result": {"tools": [{"name": "lookup", "description": "Lookup",
                                                            "inputSchema": {"type": "object"}}]}})
            elif method == "tools/call":
                assert payload["params"]["name"] == "lookup"
                if state["expire_session"]:
                    state["expire_session"] = False
                    self.send_json(404)
                else:
                    self.send_json(200, {"jsonrpc": "2.0", "id": payload["id"],
                                         "result": {"content": [{"type": "text", "text": "mcp-result"}]}})
        elif self.path == "/v1/chat/completions":
            messages = json.loads(raw)["messages"]
            tool = next((message for message in messages if message["role"] == "tool"), None)
            if tool:
                choice = {"delta": {"content": tool["content"]}, "finish_reason": "stop"}
            else:
                choice = {"delta": {"tool_calls": [{"index": 0, "id": "call-1", "type": "function",
                          "function": {"name": "mcp__secure__lookup", "arguments": "{}"}}]}, "finish_reason": "tool_calls"}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(("data: " + json.dumps({"choices": [choice]}) + "\n\ndata: [DONE]\n\n").encode())
        else:
            self.send_json(404)


with tempfile.TemporaryDirectory(prefix="ni-mcp-oauth-") as tmp, http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = f"http://127.0.0.1:{server.server_port}"
    resource = origin + "/mcp"
    agent_dir = Path(tmp)
    (agent_dir / "mcp.json").write_text(json.dumps({"mcpServers": {"secure": {"url": resource, "exposure": "direct"}}}))
    (agent_dir / "models.json").write_text(json.dumps({"providers": {"mock": {"baseUrl": origin + "/v1",
        "api": "openai-completions", "models": [{"id": "mock"}]}}}))

    def ni(*args, expect=0):
        result = subprocess.run([binary, *args, "--agent-dir", agent_dir], cwd=tmp,
                                capture_output=True, text=True, encoding="utf-8", timeout=12)
        assert result.returncode == expect, (result.returncode, result.stdout, result.stderr)
        return result.stdout

    details = json.loads(ni("mcp", "list", "--json", expect=1))
    assert details["servers"][0]["errorKind"] == "authentication"

    login = subprocess.Popen([binary, "mcp", "login", "secure", "--no-browser", "--agent-dir", agent_dir],
                             cwd=tmp, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, encoding="utf-8")
    try:
        output = queue.Queue()
        threading.Thread(target=lambda: output.put(login.stdout.readline()), daemon=True).start()
        announced = output.get(timeout=10)
        assert announced.startswith("Authorize in a browser: "), announced
        with urlopen(announced.strip().removeprefix("Authorize in a browser: "), timeout=10) as callback:
            assert callback.status == 200
        _, error = login.communicate(timeout=10)
        assert login.returncode == 0, error
    finally:
        if login.poll() is None:
            login.kill()
            login.wait()

    assert state["registration"] == 1
    assert json.loads(ni("mcp", "list", "--json"))["servers"][0]["state"] == "connected"
    assert state["refreshes"] == 1
    credentials = next((agent_dir / "mcp-credentials").glob("*.json"))
    stored = json.loads(credentials.read_text())
    stored["expiresMs"] = 1
    credentials.write_text(json.dumps(stored))
    assert "Connected" in ni("mcp", "reconnect", "secure")
    assert state["refreshes"] == 2
    assert ni("-p", "--no-session", "--model", "mock/mock", "--api-key", "fake", "Call the MCP tool").strip() == "mcp-result"
    assert not state["expire_session"]

    ni("mcp", "disable", "secure", "--tool", "lookup")
    assert json.loads(ni("mcp", "list", "--json"))["servers"][0]["tools"][0]["exposure"] == "hidden"
    ni("mcp", "enable", "secure", "--tool", "lookup")
    ni("mcp", "disable", "secure")
    assert json.loads(ni("mcp", "list", "--json"))["servers"][0]["state"] == "disabled"
    ni("mcp", "enable", "secure")
    ni("mcp", "logout", "secure")
    assert not credentials.exists()
    assert json.loads(ni("mcp", "list", "--json", expect=1))["servers"][0]["errorKind"] == "authentication"
    server.shutdown()
