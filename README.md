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

### Windows

In PowerShell, build with `nim c -d:release -o:ni.exe src/ni.nim` and run `.\ni.exe` in Windows Terminal or the Windows console. Ni reads Unicode console input directly, including when prompts use Chinese or other non-ASCII text.

Place a PEM CA bundle named `cacert.pem` and the matching OpenSSL 3 DLLs beside `ni.exe`. The default filenames match Git for Windows.

| Architecture | OpenSSL DLLs |
| --- | --- |
| x64 | `libssl-3-x64.dll`, `libcrypto-3-x64.dll` |
| ARM64 | `libssl-3.dll`, `libcrypto-3.dll` |

Use `-d:sslVersion` to select another DLL suffix when compiling. Git for Windows supplies Bash for Bash commands.

## Features

- **Providers.** OpenAI Chat Completions and Responses, Anthropic Messages, Google Gemini, and OpenAI-compatible endpoints such as DeepSeek, Kimi, OpenRouter, Ollama, and vLLM. The provider adapters preserve supported thinking signatures across turns.
- **Terminal interface.** Stream Markdown, tables, code, and diffs. Edit multiline input with UTF-8 and CJK support, prompt history, command completion, and `@file` completion. During a reply, `Enter` queues a steering message, and `Alt+Enter` (`Ctrl+Q` on Windows) queues a follow-up. Configure the follow-up shortcut with `app.message.followUp` in `~/.pi/agent/keybindings.json`. `Esc` interrupts a model reply and keeps the draft.
- **Workspace tools.** Read, write, edit, run shell commands, search and list files, ask questions, and discover deferred tools. Fuzzy edits preserve the original BOM and line endings. Use `/copy` to copy a reply, code block, or diff.
- **Configuration.** Reuse Pi settings, models, credentials, project trust, skills, and prompt templates. Ni supports stdio and Streamable HTTP MCP servers and manages them with `ni mcp list`, `add`, and `remove`.
- **Sessions.** Resume or fork Pi v3 JSONL sessions, navigate conversation branches, compact history, and export HTML, Markdown, or JSONL.
- **Headless modes.** `--print` prints the final reply, `--mode json` streams JSONL events, and `--mode rpc` accepts JSONL commands on stdin. RPC processes commands serially, so steering and abort commands wait for the active prompt to finish.

## Tests

```sh
nimble test
```

The test task rebuilds Ni and runs unit and integration tests. The integration tests use local mock servers and require Python 3.

See [Architecture](docs/architecture.md) for the runtime and module layout. Ni is distributed under the [MIT License](LICENSE).
