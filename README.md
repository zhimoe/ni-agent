# Ni Agent

Ni is a terminal coding agent written in Nim. It streams model responses, runs workspace tools, and reuses the user and project configuration layout of [Pi](https://github.com/earendil-works/pi).

## Build and run

Use Nim 2.0 or later. The project has been tested with Nim 2.4.2. Build and run from the repository root on macOS or Linux.

```sh
nim c -d:release -o:ni src/ni.nim
./ni
```

Ni uses `~/.pi/agent` by default. Pass `--agent-dir` to use a separate configuration directory. If you need to add a provider credential, run `./ni auth login <provider>` or use `/login` in the terminal interface.

```sh
./ni -m anthropic/claude-sonnet-4-6:high
./ni -p "Summarize @src/ni/agent.nim"
./ni --mode json "List files in src/"
./ni --mode rpc
```

Use `./ni --no-alt-screen` to work in the terminal's regular scrollback with the same slash commands and input editor. Press `Ctrl+R` to search input history. Press it again for an older match, `Enter` to recall the match for editing, or `Esc` to keep your draft.

Use `/diff` to inspect staged, unstaged, and untracked changes under the current working directory. Use `/search [text]` to find messages and saved tool output on the active conversation branch, including messages before compaction. Press `Enter` on a result to jump to its transcript line or show a context preview. In a plain terminal, pass the query as `/search <text>`.

Use `--max-turns <N>` to set the agent turn limit for each run. The default is 64. This also works with `--print`, JSONL, and RPC.

### Windows

从 `dist/windows` 选择 `x64` 或 `arm64`，复制完整目录到 Windows，再从该目录运行 `.\ni.exe`。重新编译和打包见 [Windows 使用与打包说明](docs/windows.md)。

### Herdr

Run `ni` (or `./ni` after building from source) in a Herdr pane. Ni appears automatically in the Agents sidebar and in `herdr agent list`. The sidebar shows when Ni is ready for input, working, or waiting for a decision. The entry disappears when Ni exits. This works with the default Herdr configuration.

For a launch shortcut, add the following to `~/.config/herdr/config.toml` on macOS or Linux, or `%APPDATA%\herdr\config.toml` on Windows. If Ni is outside Herdr's `PATH`, set `command` to its quoted absolute path, for example `command = '"/opt/ni/ni"'`.

```toml
[[keys.command]]
key = "prefix+i"
type = "pane"
description = "Open Ni"
command = "ni"
```

Choose **Reload config** in Herdr (default `Ctrl+B`, then `Shift+R`). Press `Ctrl+B`, then `i` to open Ni in a temporary pane. The pane closes when Ni exits. [Herdr custom command keybindings](https://herdr.dev/tui/docs/configuration/#custom-command-keybindings)

## Features

- **Providers.** OpenAI Chat Completions and Responses, Anthropic Messages, Google Gemini, and OpenAI-compatible endpoints such as DeepSeek, Kimi, OpenRouter, Ollama, and vLLM. The provider adapters preserve supported thinking signatures across turns.
- **Terminal interface.** Stream Markdown, tables, code, and diffs. Edit multiline input with UTF-8 and CJK support, prompt history, command completion, and `@file` completion. During a reply, `Enter` queues a steering message, and `Alt+Enter` (`Ctrl+Q` on Windows) queues a follow-up. Configure the follow-up shortcut with `app.message.followUp` in `~/.pi/agent/keybindings.json`. `Esc` interrupts a model reply and keeps the draft.
- **Local commands and copying.** Type `!command` to run a local command with live output and add its result to context, or use `!!command` to keep it local. On macOS and Linux, local commands load interactive aliases when Bash or Zsh is selected and the sandbox is off. In fullscreen, drag across the visible transcript or draft and release to copy the selection.
- **Workspace tools.** Read, write, edit, run shell commands, search and list files, ask questions, and discover deferred tools. Fuzzy edits preserve the original BOM and line endings. Use `/copy` to copy a reply, code block, or diff.
- **Configuration.** Reuse Pi settings, models, credentials, project trust, skills, and prompt templates. Ni supports stdio and Streamable HTTP MCP servers and manages them with `ni mcp list`, `add`, and `remove`.

### Session recovery

Ni 0.3.0 gives each saved session one writer at a time across Ni processes. If a session is already open for writing, close or switch away from it in the other process and retry. Use `--no-session --session <id-or-path>` to work from an in-memory copy. The operating system releases the writer lock when Ni exits, including after a forced stop.

When a session contains malformed JSONL, Ni reports the file and the first affected line. It preserves the original bytes and starts the next entry on a new line, including when the last complete record has no final newline.
- **Sessions.** Resume or fork Pi v3 JSONL sessions, navigate conversation branches, compact history, and export HTML, Markdown, or JSONL.
- **Headless modes.** `--print` prints the final reply, `--mode json` streams JSONL events, and `--mode rpc` accepts JSONL commands on stdin. During model streaming, RPC clients can inspect state, steer, queue follow-ups, or abort. Other commands wait for the prompt to finish.

RPC clients can use `get_entries` with an optional `since` entry ID to read session history in append order. `get_tree` returns nested branches and their labels. `get_fork_messages` lists the text prompts available for forking.

Use `--session-id <id>` to continue an exact session ID in the current workspace or create it on first use. If older versions created multiple logs for one ID, Ni opens the most recently modified log. Use `--no-session --fork <id-or-path>` to continue from a saved branch in memory.

JSON mode emits a Pi v3 session header before the first agent event. RPC `get_session_stats` includes session-wide user, assistant, tool call and tool result counts, plus an estimate for the active context.

Print and JSON modes return `0` on completion, `1` on failure, `2` for truncated model output, `3` at the agent turn limit, and `130` on cancellation. JSONL and RPC `agent_end` events report the corresponding `stopReason` and `exitCode` for each run.

### Tool permissions and process sandbox

Use `--tools read,grep,find,ls` to limit which tools the model can execute or `--no-tools` to disable all model tools. `--sandbox read-only` prohibits project file edits and `--sandbox workspace-write` allows edits inside the workspace. Both modes constrain built-in file tools to the workspace and isolate Shell and stdio MCP processes. Sandboxed subprocesses can write to private scratch space, read system files subject to the platform policy, and cannot make IP connections through the host network. Configured HTTP MCP servers and model providers still connect through Ni.

The process sandbox uses Seatbelt on macOS and bubblewrap on Linux. Requests for a restricted mode fail when its platform backend is unavailable. The default `off` mode uses the existing tool approval policy.

### Subagents

Start Ni with `./ni --subagents` and ask it to investigate independent parts of the workspace in parallel. For example, ask it to have one subagent trace configuration loading and another review the tests, then combine their findings.

`spawn_agent` starts a worker with a self-contained task. `list_agents` shows status, `wait_agent` returns results and reported token usage, and `cancel_agent` stops a worker. These tools work in the TUI, print, JSONL, and RPC modes. An explicit `--tools` list must include the subagent tools you want to use. `--no-tools` disables them.

Each worker uses the parent's active model and a separate in-memory session. Workers can use the parent-enabled subset of `read`, `grep`, `find`, and `ls` within the workspace. Worker `grep` uses literal matching. Ni keeps up to four workers active and accepts up to twelve tasks per parent run. A worker can run for up to two minutes and take up to eight agent turns, further limited by the parent's `--max-turns`. Collect results before the parent run ends, since Ni stops any workers still running at that point.

### MCP authentication and management

Use `ni mcp login <name>` for HTTP OAuth, `logout` to remove local OAuth credentials, and `reconnect` to test a fresh connection. `mcp enable` and `mcp disable` accept `--tool <name>` for individual tools. Inside the TUI use `/mcp login <name>`, `/mcp logout <name>` or `/mcp enable <name> [tool]` and `/mcp disable <name> [tool]`.

OAuth discovery supports dynamic client registration and a preconfigured `oauth.clientId`. A registered client can specify `oauth.callbackPort` or a loopback `oauth.callbackUrl`, plus an optional `oauth.clientSecret` and `oauth.scope`. Use `--no-browser` to print the authorization URL. The browser must be able to reach Ni's loopback callback. Ni stores tokens under the agent directory in `mcp-credentials/`, keyed by server name and URL.

## Tests

```sh
nimble test
```

The test task rebuilds Ni and runs unit and integration tests. The integration tests use local mock servers and require Python 3.

See the [0.5.0 feature checklist](docs/feature-checklist.md) for everyday workflows, verified behavior, and remaining gaps. The [CLI agent comparison](docs/cli-agent-comparison.md) covers the earlier audit and [TODO](TODO.md) tracks follow-up work. [Architecture](docs/architecture.md) describes the runtime and module layout. Ni is distributed under the [MIT License](LICENSE).
