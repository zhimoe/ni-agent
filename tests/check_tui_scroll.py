"""Exercise scrolling and streaming against the real fullscreen TUI."""

from base64 import b64encode
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


def read_repaints(master, marker=b""):
    output = bytearray()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not select.select([master], [], [], 0.08 if output else 0.5)[0]:
            if output.endswith(b"\x1b[?2026l") and marker in output:
                return output
            continue
        output.extend(os.read(master, 65536))
    raise AssertionError(f"Timed out waiting for TUI repaint {marker!r}: {output[-1000:]!r}")


def read_until(master, marker):
    output = bytearray()
    deadline = time.monotonic() + 5
    while marker not in output:
        remaining = max(0, deadline - time.monotonic())
        if not select.select([master], [], [], remaining)[0]:
            raise AssertionError(f"Timed out waiting for {marker!r}: {output[-1000:]!r}")
        output.extend(os.read(master, 65536))
    return output


def drag_copy(master, row, first, last, expected):
    os.write(master, f"\x1b[<0;{first};{row}M\x1b[<32;{last};{row}M".encode())
    preview = read_repaints(master, marker=b"\x1b[7m")
    assert b"\x1b[2J" not in preview
    os.write(master, f"\x1b[<0;{last};{row}m".encode())
    read_repaints(master, marker=b"\x1b]52;c;" + b64encode(expected.encode()) + b"\x07")


start_model = threading.Event()
resume_model = threading.Event()
unicode_prompt = "中文🙂"
model_requests = []


class ModelServer(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def write_chunk(self, payload):
        self.wfile.write(f"{len(payload):x}\r\n".encode() + payload + b"\r\n")
        self.wfile.flush()

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model_requests.append(request["messages"])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if request["messages"][-1]["content"] == unicode_prompt:
            choice = {"delta": {"content": "echo:" + unicode_prompt}, "finish_reason": "stop"}
            self.write_chunk(("data: " + json.dumps({"choices": [choice]}) + "\n\n").encode())
            self.write_chunk(b"data: [DONE]\n\n")
            self.write_chunk(b"")
            return
        start_model.wait(timeout=6)
        for i in range(120):
            text = {59: "STREAM_HOLD", 119: "STREAM_DONE"}.get(i, f"Streaming chunk {i:03d}\n\n")
            choice = {"delta": {"content": text}, "finish_reason": "stop" if i == 119 else None}
            self.write_chunk(("data: " + json.dumps({"choices": [choice]}) + "\n\n").encode())
            if i == 59:
                resume_model.wait(timeout=6)
            else:
                time.sleep(0.002)
        usage = {"choices": [], "usage": {"prompt_tokens": 20, "completion_tokens": 7, "total_tokens": 27}}
        self.write_chunk(("data: " + json.dumps(usage) + "\n\n").encode())
        self.write_chunk(b"data: [DONE]\n\n")
        self.write_chunk(b"")


def apply_repaints(screen, output):
    commands = rb"\x1b\[(?:(\d+);1H(.*?)\x1b\[K|(\d+);(\d+)r\x1b\[(\d+)([ST])\x1b\[r)"
    for row, text, start, end, distance, direction in re.findall(commands, output):
        if row:
            screen[int(row)] = text
        else:
            rows = range(int(start), int(end) + 1)
            amount = int(distance) * (1 if direction == b"S" else -1)
            shifted = {i: screen.get(i + amount, b"") if i + amount in rows else b"" for i in rows}
            screen.update(shifted)


with tempfile.TemporaryDirectory(prefix="ni-scroll-") as tmp, \
        http.server.ThreadingHTTPServer(("127.0.0.1", 0), ModelServer) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(tmp)
    agent_dir = root / "agent"
    agent_dir.mkdir()
    (agent_dir / "models.json").write_text(json.dumps({"providers": {"local-test": {
        "api": "openai-completions", "apiKey": "test",
        "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "models": [{"id": "stream", "contextWindow": 6000}],
    }}}), encoding="utf-8")
    session = root / "session.jsonl"
    history = "\n\n".join(f"History line {i:03d}" for i in range(100))
    history += "\n\n```text\n" + "\t" * 15 + "Indented code\n```\n\nLatest reply"
    records = [
        {"type": "session", "version": 3, "id": "scroll", "cwd": tmp},
        {"type": "message", "id": "reply", "parentId": None,
         "message": {"role": "assistant", "content": history, "usage": {"input": 4, "output": 3}}},
    ]
    session.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 80, 0, 0))
    env = {**os.environ, "TERM": "xterm-256color", "NO_COLOR": "1"}
    env.pop("HTTPS_PROXY", None)
    env.pop("HTTP_PROXY", None)
    shell = shutil.which("zsh") or shutil.which("bash")
    if shell:
        env.update(HOME=tmp, ZDOTDIR=tmp, SHELL=shell)
        (root / (".zshrc" if Path(shell).name == "zsh" else ".bashrc")).write_text(
            'echo shell-startup-log\nalias ll=\'printf "%s\\n" shell-alias-ran\'\n')
    mock_bin = root / "bin"
    mock_bin.mkdir()
    for utility in ("pbcopy", "wl-copy", "xclip", "xsel"):
        executable = mock_bin / utility
        executable.write_text("#!/bin/sh\n/bin/cat >/dev/null\n")
        executable.chmod(0o755)
    env["PATH"] = str(mock_bin) + os.pathsep + env["PATH"]
    command = [sys.argv[1], "--no-session", "--no-mcp", "--agent-dir", str(agent_dir),
               "--model", "local-test/stream", "--session", str(session)]
    process = subprocess.Popen(command, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    try:
        initial = read_repaints(master)
        bottom = {}
        apply_repaints(bottom, initial)
        assert b"Latest reply" in initial and len(bottom) == 20
        assert b"\t" not in initial
        assert b"7 tok" in bottom[20]

        history_row, history_line = next((row, text) for row, text in bottom.items() if b"Latest reply" in text)
        first = history_line.index(b"Latest reply") + 1
        drag_copy(master, history_row, first, first + len("Latest reply") - 1, "Latest reply")
        os.write(master, "中文 draft".encode())
        read_repaints(master, marker="中文 draft".encode())
        drag_copy(master, 18, 3, 12, "中文 draft")
        os.write(master, b"\x15")
        read_repaints(master, marker=b"Ask anything")

        os.write(master, b"\x1b[<64;20;5M" * 12)
        up = read_repaints(master)
        assert up.count(b"\x1b[?2026h") == 1, up
        scrolled = bottom.copy()
        apply_repaints(scrolled, up)
        assert scrolled != bottom

        os.write(master, b"\x1b[<65;20;5M" * 18)
        down = read_repaints(master)
        assert down.count(b"\x1b[?2026h") == 1, down
        assert b"\x1b[2J" not in down and b"\t" not in down
        apply_repaints(scrolled, down)
        assert scrolled == bottom

        # A single wheel report that reaches the bottom must preserve the title
        # row and shift the existing body instead of rewriting the whole page.
        os.write(master, b"\x1b[<68;20;5M")  # Shift + vertical wheel up.
        up = read_repaints(master)
        assert b"lines above" in up
        apply_repaints(scrolled, up)
        assert scrolled[1] != bottom[1]
        os.write(master, b"\x1b[<81;20;5M")  # Ctrl + vertical wheel down.
        last = read_repaints(master)
        assert b"\x1b[2;16r\x1b[3S\x1b[r" in last, last
        assert b"lines above" in last
        assert len(re.findall(rb"\x1b\[\d+;1H", last)) <= 4, last
        apply_repaints(scrolled, last)
        assert scrolled == bottom

        # A diagonal touchpad gesture can mix downward and horizontal reports
        # at the bottom. Each arrives far enough apart to get its own frame.
        for report in (b"65M", b"66M", b"65M", b"67M", b"70M", b"83M", b"64m"):
            os.write(master, b"\x1b[<" + report[:-1] + b";20;5" + report[-1:])
            assert not select.select([master], [], [], 0.15)[0], report

        # A regular key directly behind the reports still reaches the editor.
        os.write(master, b"\x1b[<65;20;5M" * 3 + b"Z")
        typed = read_repaints(master)
        assert re.search(rb"\x1b\[18;1H[^\x1b]*Z", typed), typed
        os.write(master, b"\x0c")
        refresh = read_repaints(master)
        assert b"\x1b[2J" not in refresh and b"Latest reply" in refresh

        os.write(master, b"\x15!")
        shell_mode = read_repaints(master, marker=b"Bash")
        assert b"\x1b[2J" not in shell_mode
        os.write(master, b"!")
        read_repaints(master, marker=b"Local only")
        os.write(master, b"\x1b")
        read_repaints(master, marker=b"Ask anything")

        if shell:
            os.write(master, b"!ll\r")
            shell_alias = read_repaints(master, marker=b"shell-alias-ran")
            assert b"shell-startup-log" not in shell_alias

        os.write(master, b"\x15!printf 'clear-before\\033[2Jclear-after\\n'\r")
        shell_result = read_repaints(master, marker=b"clear-beforeclear-after")
        assert b"\x1b[2J" not in shell_result
        os.write(master, b"\x1b[<64;20;5M" * 12)
        read_repaints(master)
        os.write(master, b"\x1b[<65;20;5M" * 12)
        shell_replay = read_repaints(master, marker=b"clear-beforeclear-after")
        assert b"\x1b[2J" not in shell_replay

        os.write(master, b"\x1b[200~" + b"Start response " * 32 + b"\x1b[201~\r")
        live_screen = bottom.copy()
        waiting = read_repaints(master, marker=b"Thinking (0s")
        apply_repaints(live_screen, waiting)
        assert b"Thinking (0s" in live_screen[16] and b"Esc to interrupt" in live_screen[16]
        assert b"Thinking" not in live_screen[17] and "❯".encode() in live_screen[18]
        assert b"7 tok" in live_screen[20]
        before = int(re.search(rb"(\d+)%/", bottom[20])[1])
        after = int(re.search(rb"(\d+)%/", live_screen[20])[1])
        assert after > before

        tick = read_repaints(master, marker=b"Thinking (1s")
        assert re.findall(rb"\x1b\[(\d+);1H", tick) == [b"16"], tick
        apply_repaints(live_screen, tick)
        start_model.set()

        first = read_repaints(master, marker=b"STREAM_HOLD")
        apply_repaints(live_screen, first)
        os.write(master, b"\x1b[<64;20;5M")
        apply_repaints(live_screen, read_repaints(master, marker=b"End"))
        os.write(master, b"\x1b[<65;20;5M")
        apply_repaints(live_screen, read_repaints(master, marker=b"lines above"))
        assert any(b"STREAM_HOLD" in row for row in live_screen.values())
        os.write(master, b"!!printf 'queued-%s\\n' 'shell-done'\r")
        read_repaints(master, marker=b"Queued: !!printf")
        resume_model.set()
        final = read_repaints(master, marker=b"queued-shell-done")
        apply_repaints(live_screen, final)
        assert any(b"STREAM_DONE" in row for row in live_screen.values())
        assert b"Generating" not in live_screen[16]
        assert b"34 tok" in live_screen[20]
        assert len(model_requests) == 1
        frames = (first + final).count(b"\x1b[?2026h")
        assert frames < 60, frames
    finally:
        start_model.set()
        resume_model.set()
        process.terminate()
        process.wait(timeout=5)
        os.close(master)
        os.close(slave)

    # Terminal sessions with no alternate screen must still accept a Unicode prompt.
    for term in (None, "dumb"):
        fallback_env = env.copy()
        fallback_env.pop("TERM")
        if term is not None:
            fallback_env["TERM"] = term
        master, slave = pty.openpty()
        process = subprocess.Popen(command, cwd=root, env=fallback_env, stdin=slave, stdout=slave, stderr=slave)
        try:
            if term is None:
                shown = read_repaints(master, marker=b"Ask anything")
                assert b"\x1b[?1049h" not in shown
                os.write(master, b"!echo public-fallback\r")
                read_repaints(master, marker=b"Ask anything")
                os.write(master, b"!!echo private-fallback\r")
                read_repaints(master, marker=b"Ask anything")
                os.write(master, unicode_prompt.encode() + b"\r")
                output = read_repaints(master, marker=b"Ask anything")
            else:
                shown = read_until(master, b"ni> ")
                os.write(master, b"!echo public-fallback\r")
                shell_output = read_until(master, b"ni> ")
                assert b"  public-fallback" in shell_output
                os.write(master, b"!!echo private-fallback\r")
                shell_output = read_until(master, b"ni> ")
                assert b"  private-fallback" in shell_output
                os.write(master, unicode_prompt.encode() + b"\r")
                output = read_until(master, b"ni> ")
                assert b"\x1b[" not in shown + output
            assert ("echo:" + unicode_prompt).encode() in output
            request = json.dumps(model_requests[-1])
            assert "public-fallback" in request and "private-fallback" not in request
            os.write(master, b"/quit\r")
            submitted = "❯ /quit\r\n".encode() if term is None else b"/quit\r\n"
            read_until(master, submitted)
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)
    server.shutdown()
