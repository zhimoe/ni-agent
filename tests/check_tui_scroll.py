"""Exercise scrolling and streaming against the real fullscreen TUI."""

import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
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


start_model = threading.Event()
resume_model = threading.Event()


class ModelServer(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def write_chunk(self, payload):
        self.wfile.write(f"{len(payload):x}\r\n".encode() + payload + b"\r\n")
        self.wfile.flush()

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
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
        resume_model.set()
        final = read_repaints(master, marker=b"34 tok")
        apply_repaints(live_screen, final)
        assert any(b"STREAM_DONE" in row for row in live_screen.values())
        assert b"Generating" not in live_screen[16]
        assert b"34 tok" in live_screen[20]
        frames = (first + final).count(b"\x1b[?2026h")
        assert frames < 60, frames
    finally:
        start_model.set()
        resume_model.set()
        process.terminate()
        process.wait(timeout=5)
        os.close(master)
        os.close(slave)
        server.shutdown()
