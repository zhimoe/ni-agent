"""Smoke-test Ni in an isolated Windows console with Unicode key records."""

import ctypes
from ctypes import wintypes
import http.server
import json
import os
from pathlib import Path
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time


PROMPT = "中文🙂"


class ModelServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        content = request["messages"][-1]["content"]
        self.server.prompts.put(content)
        chunk = {"choices": [{"delta": {"content": "ECHO:" + str(content)}, "finish_reason": "stop"}]}
        body = ("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def check_console(binary, root):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)

    class Coord(ctypes.Structure):
        _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short)]

    class ScreenInfo(ctypes.Structure):
        _fields_ = [("size", Coord), ("cursor", Coord), ("attributes", wintypes.WORD),
                    ("window", ctypes.c_short * 4), ("maximum", Coord)]

    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                   wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetConsoleScreenBufferInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(ScreenInfo)]
    kernel.ReadConsoleOutputCharacterW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                                    Coord, ctypes.POINTER(wintypes.DWORD)]
    kernel.WriteConsoleInputW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                         ctypes.POINTER(wintypes.DWORD)]

    def require(ok):
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())

    def open_console(device):
        handle = kernel.CreateFileW(device, 0xC0000000, 3, None, 3, 0, None)
        require(handle != ctypes.c_void_p(-1).value and handle is not None)
        return handle

    def mode(handle):
        value = wintypes.DWORD()
        require(kernel.GetConsoleMode(handle, ctypes.byref(value)))
        return value.value

    def screen():
        output = open_console("CONOUT$")
        try:
            info = ScreenInfo()
            require(kernel.GetConsoleScreenBufferInfo(output, ctypes.byref(info)))
            left, top, right, bottom = info.window
            width = right - left + 1
            row = ctypes.create_unicode_buffer(width + 1)
            chars = wintypes.DWORD()
            lines = []
            for y in range(top, bottom + 1):
                require(kernel.ReadConsoleOutputCharacterW(output, row, width, Coord(left, y), ctypes.byref(chars)))
                lines.append(row[:chars.value])
            return "\n".join(lines).encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")
        finally:
            kernel.CloseHandle(output)

    def wait_for(label, process):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            contents = screen()
            if label in contents:
                return
            if process.poll() is not None:
                raise AssertionError(f"Ni exited before displaying {label!r}, code {process.returncode}")
            time.sleep(0.04)
        raise AssertionError(f"Did not see {label!r} in the console:\n{contents}")

    def send_keys(handle, text):
        units = text.encode("utf-16-le")
        # INPUT_RECORD starts with a WORD event type, then padding and a KEY_EVENT_RECORD.
        records = b"".join(struct.pack("<H2xiHHHHI", 1, 1, 1, 0x0D if unit == 13 else 0xE7, 0, unit, 0)
                           for unit, in struct.iter_unpack("<H", units))
        count = wintypes.DWORD()
        require(kernel.WriteConsoleInputW(handle, ctypes.create_string_buffer(records), len(units) // 2,
                                          ctypes.byref(count)))
        assert count.value == len(units) // 2

    agent = root / "agent"
    agent.mkdir()
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), ModelServer) as server:
        server.prompts = queue.Queue()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (agent / "models.json").write_text(json.dumps({"providers": {"fixture": {
            "api": "openai-completions", "apiKey": "test", "models": [{"id": "echo"}],
            "baseUrl": f"http://127.0.0.1:{server.server_port}/v1",
        }}}), encoding="utf-8")
        command = [binary, "--no-session", "--no-mcp", "--no-tools", "--no-context-files",
                   "--agent-dir", str(agent), "--model", "fixture/echo"]
        env = {key: value for key, value in os.environ.items() if not key.lower().endswith("_proxy")}
        env.pop("TERM", None)
        keys = open_console("CONIN$")
        output = open_console("CONOUT$")
        try:
            require(kernel.SetConsoleCP(437) and kernel.SetConsoleOutputCP(437))
            original_modes = (mode(keys), mode(output))
            for term, label in [(None, "Ask anything"), ("dumb", "ni> ")]:
                if term:
                    env["TERM"] = term
                with subprocess.Popen(command, env=env, cwd=root) as child:
                    try:
                        wait_for(label, child)
                        send_keys(keys, PROMPT + "\r")
                        assert server.prompts.get(timeout=8) == PROMPT
                        wait_for("ECHO:", child)
                        wait_for(label, child)
                        send_keys(keys, "/quit\r")
                        assert child.wait(timeout=8) == 0
                    finally:
                        if child.poll() is None:
                            child.kill()
                assert (mode(keys), mode(output)) == original_modes
                assert kernel.GetConsoleCP() == kernel.GetConsoleOutputCP() == 437
            env.pop("TERM")
            with open(os.devnull, "rb") as nul:
                result = subprocess.run(command, stdin=nul, env=env, cwd=root, timeout=8)
                assert result.returncode == 1, "NUL was treated as an interactive console"
            assert (mode(keys), mode(output)) == original_modes
            assert kernel.GetConsoleCP() == kernel.GetConsoleOutputCP() == 437

            printed = subprocess.run(command + ["--print", PROMPT], stdin=subprocess.DEVNULL,
                                     capture_output=True, env=env, cwd=root, timeout=8)
            assert printed.returncode == 0, printed.stderr
            assert ("ECHO:" + PROMPT).encode() in printed.stdout
            assert server.prompts.get(timeout=8) == PROMPT
            commands = [
                {"id": "before", "type": "get_state"},
                {"id": "shell", "type": "bash", "command": "echo NI_CMD_OK"},
                {"id": "after", "type": "get_state"},
            ]
            rpc_input = b"".join((json.dumps(record) + "\n").encode() for record in commands)
            rpc = subprocess.run(command + ["--mode", "rpc"], input=rpc_input,
                                 capture_output=True, env=env, cwd=root, timeout=8)
            assert rpc.returncode == 0, rpc.stderr
            lines = [json.loads(line) for line in rpc.stdout.splitlines()]
            records = [line for line in lines if line.get("type") == "response"]
            responses = {line["id"]: line for line in records}
            # State queries can return while the Shell command is still running.
            assert len(records) == 3 and set(responses) == {"before", "shell", "after"}, lines
            assert all(response.get("success") for response in responses.values()), responses
            assert responses["shell"]["data"]["output"].strip() == "NI_CMD_OK"
        finally:
            kernel.CloseHandle(keys)
            kernel.CloseHandle(output)
            server.shutdown()


if __name__ == "__main__":
    if os.name != "nt":
        sys.exit("This smoke test requires a Windows console.")
    if len(sys.argv) == 4 and sys.argv[1] == "--child":
        report = Path(sys.argv[3]) / "report.txt"
        try:
            check_console(sys.argv[2], report.parent)
            report.write_text("Windows console, Unicode input, NUL redirection and console restoration passed.\n")
        except Exception:
            import traceback
            report.write_text(traceback.format_exc(), encoding="utf-8")
            raise
    else:
        binary = Path(sys.argv[1] if len(sys.argv) > 1 else "ni.exe").resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix="ni-win-console-") as tmp:
            child = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--child", str(binary), tmp],
                                   creationflags=subprocess.CREATE_NEW_CONSOLE, timeout=45)
            report = Path(tmp) / "report.txt"
            assert report.is_file(), f"The console helper exited with code {child.returncode} without writing a report"
            sys.stdout.buffer.write(report.read_bytes())
            sys.exit(child.returncode)
