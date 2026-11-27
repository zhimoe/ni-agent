# OS process sandbox profiles and the reserved Codemode interface.

import std/[json, os, tables]
when defined(macosx) or defined(linux):
  import std/tempfiles
import ./[types, trust]

proc configureSandbox*(policy: SecurityPolicy, mode: SandboxMode) =
  if mode == sandboxOff:
    return
  when defined(macosx) or defined(linux):
    let workspace = expandFilename(policy.cwd)
    let agentDir = if dirExists(policy.agentDir): expandFilename(policy.agentDir) else: absolutePath(policy.agentDir)
    if isPathWithinDir(agentDir, workspace):
      raise newException(IOError, "The sandbox workspace cannot be inside the agent configuration directory")
    when defined(macosx):
      let sandboxExe = "/usr/bin/sandbox-exec"
      if not fileExists(sandboxExe):
        raise newException(IOError, "macOS sandbox-exec is unavailable")
    else:
      let sandboxExe = findExe("bwrap")
      if sandboxExe.len == 0:
        raise newException(IOError, "The Linux sandbox requires bubblewrap (bwrap)")
    let scratch = expandFilename(createTempDir("ni-sandbox-", ""))
    policy.sandboxTempDir = scratch
    policy.sandboxMode = mode
    when defined(macosx):
      policy.sandboxKind = sbSeatbelt
      var profile = "(version 1) (allow default) (deny network*) (deny file-write*) " &
        "(allow file-write-data (literal \"/dev/null\")) " &
        "(allow file-write* (subpath " & escapeJson(scratch) & ")) "
      if mode == sandboxWorkspaceWrite:
        profile.add("(allow file-write* (subpath " & escapeJson(workspace) & ")) ")
      profile.add("(deny file-read* file-write* (subpath " & escapeJson(agentDir) & "))")
      policy.sandboxWrap = proc(exe: string, args: seq[string], cwd: string): tuple[exe: string, args: seq[string]] =
        (sandboxExe, @["-p", profile, exe] & args)
    else:
      policy.sandboxKind = sbBubblewrap
      policy.sandboxWrap = proc(exe: string, args: seq[string], cwd: string): tuple[exe: string, args: seq[string]] =
        var wrap = @["--die-with-parent", "--unshare-user-try", "--unshare-ipc", "--unshare-pid", "--unshare-net", "--ro-bind", "/", "/",
          "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run"]
        wrap.add([(if mode == sandboxReadOnly: "--ro-bind" else: "--bind"), workspace, workspace])
        wrap.add(["--bind", scratch, scratch])
        if dirExists(agentDir):
          wrap.add(["--tmpfs", agentDir, "--remount-ro", agentDir])
        wrap.add(["--chdir", cwd, "--", exe])
        (sandboxExe, wrap & args)
  else:
    raise newException(IOError, "Restricted subprocess execution is unavailable on this platform")

proc closeSandbox*(policy: SecurityPolicy) =
  if not policy.isNil and policy.sandboxTempDir.len > 0:
    try: removeDir(policy.sandboxTempDir)
    except OSError: discard
    policy.sandboxTempDir = ""

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
