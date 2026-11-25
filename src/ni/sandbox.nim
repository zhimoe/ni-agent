# Reserved interface for Codemode script execution and OS sandboxing extensions.

import std/[json, tables]
import ./types

type
  CodeModeResult* = object
    completed*: bool
    output*: seq[ContentBlock]
    consoleOutput*: seq[string]
    errorMessage*: string
    wallTimeSeconds*: float

  CodeModeToolCaller* = proc(toolName: string, args: JsonNode): ToolOutput {.closure.}

  CodeModeEngine* = ref object of RootObj
    name*: string
    inlineBudget*: int
    store*: Table[string, JsonNode]

method isAvailable*(engine: CodeModeEngine): bool {.base.} =
  ## Return true when a concrete JS/script VM backend is linked.
  false

method runScript*(
  engine: CodeModeEngine,
  scriptSource: string,
  callTool: CodeModeToolCaller,
  abort: AbortFlag
): CodeModeResult {.base.} =
  ## Execute a sandboxed orchestration script against registered tools.
  CodeModeResult(
    completed: false,
    output: @[],
    consoleOutput: @[],
    errorMessage: "Codemode VM is not enabled in this build of ni (QuickJS/WASM omitted for single-binary portability; deferred MCP tools are reachable via `tool_search`).",
    wallTimeSeconds: 0.0
  )

proc newReservedCodeModeEngine*(inlineBudget = 3000): CodeModeEngine =
  ## Instantiate the default placeholder Codemode engine with persistent KV store slot.
  CodeModeEngine(
    name: "reserved-noop",
    inlineBudget: inlineBudget,
    store: initTable[string, JsonNode]()
  )
