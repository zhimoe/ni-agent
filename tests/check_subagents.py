"""Drive the real CLI and its child processes against a local SSE provider."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


def call(name, arguments, index=0):
    return {"index": index, "id": f"call_{index}", "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)}}


def spawn(task, index=0):
    return call("spawn_agent", {"task": task}, index)


def wait_for(*ids):
    return call("wait_agent", {"ids": ids})


class Server(http.server.ThreadingHTTPServer):
    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.concurrent = threading.Barrier(2, timeout=6)
        self.connected = {name: threading.Event() for name in ("cancel", "abort", "exit", "orphan1", "orphan2")}
        self.closed = {name: threading.Event() for name in self.connected}
        self.errors = []


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_stream(self, delta, reason):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(("data: " + json.dumps({
            "choices": [{"delta": delta, "finish_reason": reason}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13},
        }) + "\n\ndata: [DONE]\n\n").encode())
        self.wfile.flush()

    def do_POST(self):
        try:
            self.handle_request()
        except Exception as error:
            self.server.errors.append(repr(error))
            raise

    def handle_request(self):
        assert self.headers["Authorization"] == "Bearer test-subagent-api-key"
        assert self.headers["X-Ni-Fixture"] == "inherited-header"
        assert self.headers["X-Ni-Model"] == "model-header"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert request["temperature"] == 0.2
        messages = request["messages"]
        users = [m["content"] for m in messages if m["role"] == "user"]
        tools = {t["function"]["name"] for t in request.get("tools", [])}
        prompt = users[-1]
        results = [m["content"] for m in messages if m["role"] == "tool"]
        assert "outside-secret" not in json.dumps(messages) and "dotenv-secret" not in json.dumps(messages)
        if prompt.startswith("worker "):
            assert len(users) == 1 and tools == {"read", "grep"}
            assert request["max_tokens"] == 4096
            task = prompt.split()[1]
            if task in self.server.connected:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.flush()
                self.connection.settimeout(8)
                self.server.connected[task].set()
                try:
                    assert self.connection.recv(1) == b""
                except ConnectionResetError:
                    pass
                self.server.closed[task].set()
                return
            if task in {"read", "other"} and not results:
                self.server.concurrent.wait()
                if task == "read":
                    assert "@../outside.txt @.env" in prompt
                    calls = [
                        call("read", {"path": "note.txt"}),
                        call("read", {"path": "../outside.txt"}, 1),
                        call("read", {"path": ".env"}, 2),
                        call("grep", {"pattern": "dotenv"}, 3),
                        call("write", {"path": "escape.txt", "content": "unexpected"}, 4),
                        call("spawn_agent", {"task": "no recursion"}, 5),
                    ]
                    self.send_stream({"tool_calls": calls}, "tool_calls")
                else:
                    self.send_stream({"content": "second worker"}, "stop")
                return
            if task == "read":
                assert results[0].strip() == "workspace-note"
                assert "only allows file tools" in results[1]
                assert "sensitive workspace files" in results[2]
                assert results[3] == "No matches found"
                assert "not enabled" in results[4] and "Unknown tool" in results[5]
                self.send_stream({"content": "workspace read only"}, "stop")
            else:
                self.send_stream({"tool_calls": [call("read", {"path": "note.txt"})]}, "tool_calls")
            return

        if prompt == "disabled":
            assert tools == {"read"} or not tools
            self.send_stream({"content": "disabled verified"}, "stop")
            return
        assert tools == {"read", "grep", "spawn_agent", "list_agents", "wait_agent", "cancel_agent"}
        if prompt == "parallel":
            if not results:
                calls = [spawn("worker read @../outside.txt @.env"), spawn("worker other", 1)]
            elif len(results) == 2:
                calls = [call("list_agents", {}), call("wait_agent", {"ids": ["agent-1", "agent-2"]}, 1)]
            else:
                jobs = json.loads(results[-1])
                assert jobs["allDone"]
                assert [j["output"] for j in jobs["agents"]] == ["workspace read only", "second worker"]
                assert [j["usage"]["totalTokens"] for j in jobs["agents"]] == [26, 13]
                assert all(j["status"] == "completed" for j in jobs["agents"])
                assert len(json.loads(results[-2])["agents"]) == 2
                self.send_stream({"content": "parallel verified"}, "stop")
                return
        elif prompt == "limit":
            calls = [spawn("worker loop")] if not results else [wait_for("agent-1")]
            if len(results) == 2:
                job = json.loads(results[-1])["agents"][0]
                assert (job["status"], job["stopReason"], job["turns"]) == ("failed", "turnLimit", 3)
                self.send_stream({"content": "limit verified"}, "stop")
                return
        elif prompt == "orphan":
            calls = [wait_for("agent-1", "agent-2")] if results else [spawn("worker orphan1"), spawn("worker orphan2", 1)]
        elif not results:
            calls = [spawn(f"worker {prompt}")]
        elif prompt == "abort":
            calls = [wait_for("agent-1")]
        elif prompt == "exit":
            assert self.server.connected["exit"].wait(5)
            self.send_stream({"content": "exit verified"}, "stop")
            return
        elif len(results) == 1:
            assert self.server.connected["cancel"].wait(5)
            calls = [call("wait_agent", {"ids": ["agent-1"], "timeoutMs": 0})]
        elif len(results) == 2:
            pending = json.loads(results[-1])
            assert not pending["allDone"] and pending["agents"][0]["status"] == "running"
            calls = [call("cancel_agent", {"id": "agent-1"})]
        else:
            assert json.loads(results[-1])["status"] == "cancelled"
            self.send_stream({"content": "cancel verified"}, "stop")
            return
        self.send_stream({"tool_calls": calls}, "tool_calls")


with tempfile.TemporaryDirectory(prefix="ni-subagents-") as tmp, Server(("127.0.0.1", 0), Provider) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(tmp)
    workspace = root / "workspace"
    workspace.mkdir()
    (workspace / "note.txt").write_text("workspace-note\n")
    (workspace / ".env").write_text("dotenv-secret\n")
    (root / "outside.txt").write_text("outside-secret\n")
    agent = root / "agent"
    agent.mkdir()
    (agent / "models.json").write_text(json.dumps({"providers": {"local-test": {
        "baseUrl": f"http://127.0.0.1:{server.server_port}/v1",
        "api": "openai-completions", "headers": {"X-Ni-Fixture": "inherited-header"},
        "models": [{"id": "worker-test", "maxTokens": 8192,
                    "headers": {"X-Ni-Model": "model-header"},
                    "samplingParams": {"temperature": 0.2, "max_tokens": 8192},
                    "thinkingLevelMap": {"off": "none"}}],
    }}}))
    env = {key: value for key, value in os.environ.items() if key.upper() not in {"HTTPS_PROXY", "HTTP_PROXY"}}
    command = [sys.argv[1], "--no-mcp", "--no-session", "--agent-dir", str(agent),
               "--model", "local-test/worker-test", "--api-key", "test-subagent-api-key"]
    active = command + ["--subagents", "--tools", "read,grep,spawn_agent,list_agents,wait_agent,cancel_agent"]

    def run(args, prompt):
        result = subprocess.run(args + ["--mode", "json", prompt], cwd=workspace, env=env,
                                capture_output=True, text=True, encoding="utf-8", timeout=20)
        assert result.returncode == 0, (result.stdout, result.stderr, server.errors)
        assert "test-subagent-api-key" not in result.stdout + result.stderr
        return result.stdout

    assert "disabled verified" in run(command + ["--tools", "read"], "disabled")
    assert "disabled verified" in run(command + ["--subagents", "--tools", "read"], "disabled")
    assert "disabled verified" in run(active + ["--no-tools"], "disabled")
    assert "parallel verified" in run(active, "parallel")
    assert "limit verified" in run(active + ["--max-turns", "3"], "limit")
    for name in ("cancel", "exit"):
        assert f"{name} verified" in run(active, name)
        assert server.closed[name].wait(5), f"Worker survived parent {name}"

    for prompt in ("abort", "orphan"):
        with subprocess.Popen(active + ["--mode", "rpc"], cwd=workspace, env=env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8") as proc:
            try:
                proc.stdin.write(json.dumps({"id": "run", "type": "prompt", "message": prompt}) + "\n")
                proc.stdin.flush()
                names = ("abort",) if prompt == "abort" else ("orphan1", "orphan2")
                for name in names:
                    assert server.connected[name].wait(5), f"Worker {name} never connected"
                if prompt == "abort":
                    proc.stdin.write('{"id":"cancel","type":"abort"}\n')
                    proc.stdin.flush()
                else:
                    proc.kill()
                stdout, stderr = proc.communicate(timeout=10)
                if prompt == "abort":
                    events = [json.loads(line) for line in stdout.splitlines()]
                    assert any(e["type"] == "agent_end" and e["exitCode"] == 130 for e in events), (stdout, stderr)
                    assert any(e["type"] == "response" and e.get("id") == "cancel" and e["success"] for e in events)
                for name in names:
                    assert server.closed[name].wait(5), f"Worker {name} survived the parent"
            finally:
                if proc.poll() is None:
                    proc.kill()
    assert not server.errors, server.errors
    assert not (workspace / "escape.txt").exists()
    assert not list(agent.rglob("*.jsonl"))
    server.shutdown()
