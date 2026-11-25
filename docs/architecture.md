# Ni architecture

## Runtime

The CLI loads user settings, resolves project trust, and loads the permitted workspace configuration. It opens a session and starts the terminal interface, print mode, JSONL output, or the stdin/stdout RPC server.

The agent expands file references, skills, and prompt templates. It combines the active session branch with instructions and tool schemas, then sends the request to the selected provider. Provider adapters translate requests and responses into shared message and stream event types. The agent executes tool calls, records their results, and sends the updated context on the next turn.

The terminal interface renders stream events above the editor. Completed Markdown blocks are written to scrollback. The current draft and the unfinished response are redrawn as they change. On resize, the terminal history is rebuilt from the current Ni transcript.

## Modules

| File | Responsibility |
| --- | --- |
| `src/ni.nim` | Parse CLI arguments, initialize the runtime, and select the output mode. |
| `src/ni/config.nim` | Load settings, models, credentials, and project instructions. Resolve `$ENV` and `!command` config values. |
| `src/ni/trust.nim` | Resolve project trust and enforce workspace and command permissions. |
| `src/ni/types.nim` | Define messages, content blocks, stream events, and Pi v3 JSON codecs. |
| `src/ni/provider.nim` | Register provider adapters, stream SSE responses, resolve credentials, and retry eligible requests. |
| `src/ni/tools.nim` | Register workspace tools and handle file edits, shell execution, search, and deferred tool discovery. |
| `src/ni/mcp.nim` | Connect to stdio and Streamable HTTP MCP servers and expose their tools and resources. |
| `src/ni/skills.nim` | Discover skills and prompt templates and expand their arguments. |
| `src/ni/prompt.nim` | Assemble tools, instructions, project context, skills, and MCP metadata into the system prompt. |
| `src/ni/session.nim` | Read and write Pi v3 JSONL sessions, manage branches, and export transcripts. |
| `src/ni/agent.nim` | Run model and tool turns, manage queued messages, and compact history. |
| `src/ni/terminal_io.nim` | Decode POSIX and Windows console input, measure terminal width, and handle clipboard output. |
| `src/ni/keybindings.nim` | Load the follow-up shortcut from Pi's keybinding configuration. |
| `src/ni/editor.nim` | Edit multiline input and manage history, paste markers, and autocomplete. |
| `src/ni/markdown.nim` | Render Markdown, tables, syntax-highlighted code, and streamed response blocks. |
| `src/ni/tui.nim` | Render the transcript and editor, dispatch slash commands, and handle interactive input during replies. |
| `src/ni/rpc.nim` | Receive JSONL commands and send responses, agent events, and dialog requests. |
| `src/ni/sandbox.nim` | Define the reserved CodeMode engine interface. |

## Integration points

The provider registry accepts `ApiAdapterProc` adapters and an injectable `HttpStreamTransport`. Tests can supply a transport that emits mock SSE events. The security policy accepts a `CommandSandboxProc` to wrap executable and argument lists before launch.

MCP tools with `deferred` or `codemode` exposure are available through `tool_search`. This keeps their schemas out of the initial prompt until the agent activates them.
