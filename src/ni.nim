# CLI entry point for `ni` coding agent (`ni`, `ni mcp ...`, `ni auth ...`).

import std/[json, options, os, strutils, tables]
import ./ni/[types, config, trust, provider, tools, mcp, session, agent, terminal_io, tui, rpc, sandbox, subagents, subagent_worker, utf8, release_info]

type CliArgumentError = object of ValueError

proc optionValue(args: openArray[string], index: var int): string =
  let flag = args[index]
  if index + 1 >= args.len:
    raise newException(CliArgumentError, "Missing value for " & flag)
  let value = args[index + 1]
  # Preserve values such as `--tools -bash` and free-form prompt text.
  let optionLike = value in ["-a", "-na", "-h", "-v", "-p", "-m", "-c", "-r", "-n", "-t", "-nt",
    "-ns", "-np", "-nc", "-l"] or (value.startsWith("--") and value.find(Whitespace) < 0)
  if value.len == 0 or optionLike:
    raise newException(CliArgumentError, "Missing value for " & flag)
  inc index
  value

proc printCliHelp() =
  stdout.writeLine("""
ni v""" & NiVersion & """ — Minimal, extensible coding agent in Nim (Pi config compatible)

Usage:
  ni [options] [--] [@files...] [prompt...]
  ni mcp <list|add|remove> [options]
  ni auth <login|logout|check> [options]

Options:
  -p, --print                      Run prompt once, print final assistant text, and exit
      --mode <text|json|rpc>       Output interface (`text` default, `json` JSONL events, `rpc` headless JSONL RPC)
      --no-alt-screen              Use the terminal's regular scrollback in interactive mode
      --max-turns <N>              Limit agent turns per run (default: 64)
  -m, --model <pattern>            Select model (`provider/id` or pattern, optional `:thinking` suffix)
      --provider <name>            Select provider (`deepseek`, `anthropic`, `openai`, `google`, or custom ID)
      --api-key <key>              Runtime API key override (not written to disk)
      --thinking <level>           Set thinking level: off, minimal, low, medium, high, xhigh, max
      --list-models [filter]       List configured providers and models, then exit
  -c, --continue                   Continue most recent session for current directory
  -r, --resume                     Interactively pick a session to resume
      --session <id|path>          Open session by file path or ID prefix
      --session-id <id>            Continue or create the session with this ID in the current workspace
      --fork <id|path>             Fork an existing session into a new session
      --session-dir <dir>          Override session storage root directory
      --no-session                 Run in-memory without writing session JSONL
  -n, --name <title>               Set session display title
  -t, --tools <list>               Comma-separated tool allowlist or `+tool,-tool` deltas
      --no-tools                   Disable all tools
      --subagents                  Enable parallel read-only subagents for this run
      --no-mcp                     Skip connecting MCP servers for this run
      --skill <path>               Load extra skill file or directory (repeatable)
      --no-skills                  Disable automatic skill discovery
      --prompt-template <path>     Load extra prompt template file or directory (repeatable)
      --no-prompt-templates        Disable automatic prompt template discovery
      --no-context-files           Disable AGENTS.md / CLAUDE.md discovery
      --system-prompt <text|file>  Replace base system prompt
      --append-system-prompt <v>   Append text or file contents to system prompt (repeatable)
  -a, --approve                    Trust project .pi / .agents configuration for this run
  -na, --no-approve                Ignore project .pi / .agents configuration for this run
      --security <mode>            Security policy: balanced (default), strict, permissive
      --sandbox <mode>             Process sandbox: off (default), read-only, workspace-write
      --yolo                       Alias for --security permissive
      --agent-dir <dir>            Override ~/.pi/agent directory
  -v, --version                    Print version and exit
  -h, --help                       Print help and exit

Subcommands:
  ni mcp list [--json]
  ni mcp add <name> [-l|--local] [--exposure <mode>] [--description <text>]
                    [--env KEY=VAL] [--header KEY=VAL] [--url <url>] [-- <cmd> <args...>]
  ni mcp remove <name> [-l|--local]
  ni mcp login <name> [--no-browser]
  ni mcp logout <name>
  ni mcp enable|disable <name> [--tool <tool-name>]
  ni mcp reconnect <name>
  ni auth login <provider> [--api-key <key>]
  ni auth logout <provider>
  ni auth check --provider <provider> [--json]
""")

proc readTextOrFileArg(val, cwd: string): string =
  let candidate = resolvePathFrom(val, cwd)
  if fileExists(candidate):
    try:
      return stripUtf8Bom(readFile(candidate))
    except CatchableError:
      return val
  val

# Subcommand: `ni auth ...`

proc runAuthSubcommand(args: seq[string]): int =
  if args.len == 0 or args[0] in ["-h", "--help"]:
    printCliHelp()
    return 0
  let action = args[0].toLowerAscii()
  var providerId = ""
  var explicitKey = ""
  var asJson = false
  var agentDirOv = ""

  var i = 1
  while i < args.len:
    let a = args[i]
    case a
    of "--provider":
      providerId = optionValue(args, i)
    of "--api-key":
      explicitKey = optionValue(args, i)
    of "--agent-dir":
      agentDirOv = optionValue(args, i)
    of "--json":
      asJson = true
    else:
      if not a.startsWith("-") and providerId.len == 0:
        providerId = a
    inc i

  let cfg = loadConfigBundle(getCurrentDir(), agentDirOv, projectTrusted = false, loadContext = false)
  let reg = newProviderRegistry(cfg)

  case action
  of "login":
    if providerId.len == 0:
      stderr.writeLine("Usage: ni auth login <provider> [--api-key <key>]")
      return 1
    var keyVal = explicitKey.strip()
    if keyVal.len == 0:
      stdout.write("API key for '" & providerId & "': ")
      stdout.flushFile()
      if not stdin.readLine(keyVal):
        return 1
      keyVal = keyVal.strip()
    if keyVal.len == 0:
      stderr.writeLine("Error: empty API key")
      return 1
    saveApiKeyCredential(cfg.agentDir, providerId, keyVal)
    stdout.writeLine("Saved API key for '" & providerId & "' in " & (cfg.agentDir / "auth.json"))
    return 0
  of "logout":
    if providerId.len == 0:
      stderr.writeLine("Usage: ni auth logout <provider>")
      return 1
    discard removeStoredCredential(cfg.agentDir, providerId)
    stdout.writeLine("Removed stored credentials (if any) for '" & providerId & "'")
    return 0
  of "check":
    if providerId.len == 0:
      stderr.writeLine("Usage: ni auth check --provider <provider> [--json]")
      return 2
    let resolved = reg.resolveProviderApiKey(cfg, providerId)
    let status = if resolved.isSome: "ready" else: "not_ready"
    if asJson:
      stdout.writeLine(encodeJsonUtf8(%*{ "provider": providerId, "status": status }))
    else:
      stdout.writeLine(status)
    return (if resolved.isSome: 0 else: 1)
  else:
    stderr.writeLine("Unknown auth command: " & action)
    return 1

# Subcommand: `ni mcp ...`

proc runMcpSubcommand(args: seq[string]): int =
  if args.len == 0 or args[0] in ["-h", "--help"]:
    printCliHelp()
    return 0
  let action = args[0].toLowerAscii()
  let cwd = getCurrentDir()

  case action
  of "list":
    var asJson = false
    var agentDirOv = ""
    var i = 1
    while i < args.len:
      if args[i] == "--json": asJson = true
      elif args[i] == "--agent-dir": agentDirOv = optionValue(args, i)
      inc i
    let agentDir = getAgentDir(agentDirOv)
    let trusted = resolveProjectTrust(cwd, agentDir, ptmAsk)
    let cfg = loadConfigBundle(cwd, agentDir, projectTrusted = trusted, loadContext = false)
    let toolReg = newToolRegistry(cfg.settings.defaultTools)
    let mgr = newMcpManager(cfg, toolReg, connectNow = true)
    defer: mgr.closeAll()

    var hasFailure = cfg.diagnostics.len > 0 or mgr.diagnostics.len > 0
    if asJson:
      var arr = newJArray()
      for name, sess in mgr.servers.pairs:
        if sess.config.enabled and sess.state != mcsConnected:
          hasFailure = true
        var tArr = newJArray()
        for rt in sess.remoteTools:
          tArr.add(%*{ "name": rt.rawName, "qualifiedName": rt.qualifiedName, "exposure": $rt.effectiveExposure })
        arr.add(%*{
          "name": name,
          "state": $sess.state,
          "transport": $sess.config.transportKind,
          "exposure": $sess.config.exposure,
          "source": sess.config.source,
          "tools": tArr,
          "error": sess.lastError,
          "errorKind": $sess.failureKind
        })
      stdout.writeLine(encodeJsonUtf8(%*{ "servers": arr, "diagnostics": mgr.diagnostics }))
    else:
      if mgr.servers.len == 0:
        stdout.writeLine("No MCP servers configured.")
      for name, sess in mgr.servers.pairs:
        if sess.config.enabled and sess.state != mcsConnected:
          hasFailure = true
        stdout.writeLine(name & " (" & $sess.config.transportKind & ", " & sess.config.source & "): " &
                         $sess.state & " — " & $sess.remoteTools.len & " tool(s), exposure=" & $sess.config.exposure)
        if sess.lastError.len > 0:
          stdout.writeLine("  " & $sess.failureKind & ": " & sess.lastError)
        for rt in sess.remoteTools:
          stdout.writeLine("  - " & rt.qualifiedName & " [" & $rt.effectiveExposure & "]")
      for d in mgr.diagnostics:
        stderr.writeLine("warning: " & d)
    return (if hasFailure: 1 else: 0)

  of "login", "logout", "enable", "disable", "reconnect":
    if args.len < 2 or not isValidServerName(args[1]):
      stderr.writeLine("Usage: ni mcp " & action & " <server-name>")
      return 1
    var agentDirOverride, tool: string
    var noBrowser, approve = false
    var i = 2
    while i < args.len:
      case args[i]
      of "--agent-dir", "--tool":
        let flag = args[i]
        let value = optionValue(args, i)
        if flag == "--agent-dir": agentDirOverride = value
        else: tool = value
      of "--no-browser": noBrowser = true
      of "-a", "--approve": approve = true
      else:
        stderr.writeLine("Unknown MCP option " & args[i])
        return 1
      inc i
    let agentDir = getAgentDir(agentDirOverride)
    let trusted = resolveProjectTrust(cwd, agentDir, ptmAsk, cliOverride = (if approve: some(true) else: none(bool)))
    let cfg = loadConfigBundle(cwd, agentDir, projectTrusted = trusted, loadContext = false)
    try:
      let config = findMcpConfig(cfg, args[1])
      case action
      of "login":
        signInMcp(cfg, config, openBrowser = not noBrowser, announce = proc(url: string) =
          stdout.writeLine("Authorize in a browser: " & url)
          stdout.flushFile())
        stdout.writeLine("Signed in to MCP server '" & config.name & "'.")
      of "logout":
        signOutMcp(cfg, config)
        stdout.writeLine("Removed stored MCP credentials for '" & config.name & "'.")
      of "enable", "disable":
        setMcpEnabled(cfg, config, action == "enable", tool)
        let target = if tool.len > 0: config.name & "/" & tool else: config.name
        stdout.writeLine(action.capitalizeAscii() & "d " & target & ".")
      of "reconnect":
        let session = McpServerSession(config: config)
        session.connectServer(cfg)
        defer: session.closeServer()
        if session.state != mcsConnected:
          stderr.writeLine("MCP reconnect failed: " & (if session.lastError.len > 0: session.lastError else: $session.state))
          return 1
        stdout.writeLine("Connected to MCP server '" & config.name & "'.")
      else: discard
    except CatchableError as e:
      stderr.writeLine(e.msg)
      return 1
    return 0

  of "add":
    if args.len < 2:
      stderr.writeLine("Usage: ni mcp add <name> [options] [--url <url> | -- <command> <args...>]")
      return 1
    let srvName = args[1]
    if not isValidServerName(srvName):
      stderr.writeLine("Invalid server name '" & srvName & "': use letters, digits, '_', or '-'")
      return 1

    var localScope = false
    var agentDirOv = ""
    var url = ""
    var exposure = teCodemode
    var desc = ""
    var envMap = initTable[string, string]()
    var hdrMap = initTable[string, string]()
    var cmdParts: seq[string] = @[]
    var afterDash = false

    var i = 2
    while i < args.len:
      let a = args[i]
      if afterDash:
        cmdParts.add(a)
        inc i
        continue
      case a
      of "--":
        afterDash = true
      of "-l", "--local":
        localScope = true
      of "--agent-dir":
        agentDirOv = optionValue(args, i)
      of "--url":
        url = optionValue(args, i)
      of "--exposure":
        exposure = parseToolExposure(optionValue(args, i))
      of "--description":
        desc = optionValue(args, i)
      of "--env":
        let kv = optionValue(args, i)
        let eq = kv.find('=')
        if eq > 0: envMap[kv[0 ..< eq]] = kv[eq + 1 .. ^1]
      of "--header":
        let kv = optionValue(args, i)
        let eq = kv.find('=')
        if eq > 0: hdrMap[kv[0 ..< eq]] = kv[eq + 1 .. ^1]
      of "--bearer-token-env-var":
        hdrMap["Authorization"] = "Bearer ${" & optionValue(args, i) & "}"
      else:
        cmdParts.add(a)
      inc i

    if url.len == 0 and cmdParts.len == 0:
      stderr.writeLine("Error: specify either `--url <https://...>` or `-- <command> [args...]`")
      return 1

    let targetFile = if localScope:
      cwd / ProjectConfigDirName / "mcp.json"
    else:
      getAgentDir(agentDirOv) / "mcp.json"

    let srvCfg = McpServerConfig(
      name: srvName,
      transportKind: (if url.len > 0: mtkHttp else: mtkStdio),
      command: (if cmdParts.len > 0: cmdParts[0] else: ""),
      args: (if cmdParts.len > 1: cmdParts[1 .. ^1] else: @[]),
      cwd: cwd,
      envRaw: envMap,
      url: url,
      headersRaw: hdrMap,
      timeoutSec: 60,
      enabled: true,
      exposure: exposure,
      toolExposure: initOrderedTable[string, ToolExposure](),
      description: desc
    )
    saveMcpServerEntry(targetFile, srvCfg)
    stdout.writeLine("Saved MCP server '" & srvName & "' to " & targetFile)
    return 0

  of "remove":
    if args.len < 2:
      stderr.writeLine("Usage: ni mcp remove <name> [-l|--local]")
      return 1
    let srvName = args[1]
    var localScope = false
    var agentDirOv = ""
    var i = 2
    while i < args.len:
      if args[i] in ["-l", "--local"]: localScope = true
      elif args[i] == "--agent-dir": agentDirOv = optionValue(args, i)
      inc i
    let targetFile = if localScope:
      cwd / ProjectConfigDirName / "mcp.json"
    else:
      getAgentDir(agentDirOv) / "mcp.json"
    if removeMcpServerEntry(targetFile, srvName):
      stdout.writeLine("Removed MCP server '" & srvName & "' from " & targetFile)
      return 0
    stderr.writeLine("MCP server '" & srvName & "' not found in " & targetFile)
    return 1

  else:
    stderr.writeLine("Unknown mcp command: " & action)
    return 1

# Main CLI entry

proc main(): int =
  let rawArgs = commandLineParams()
  if rawArgs == @[SubagentWorkerArg]:
    return runSubagentWorker()
  initTerminal()
  defer:
    when defined(windows):
      stdout.flushFile()
      stderr.flushFile()
    restoreTerminal()
  if rawArgs.len > 0:
    case rawArgs[0]
    of "mcp":
      return runMcpSubcommand(rawArgs[1 .. ^1])
    of "auth":
      return runAuthSubcommand(rawArgs[1 .. ^1])
    else:
      discard

  var printMode = false
  var outputMode = "text"
  var noAltScreen = false
  var maxTurns: Positive = MaxAgentTurnsPerRun
  var modelPat = ""
  var providerOv = ""
  var cliApiKey = ""
  var thinkingOv = none(ThinkingLevel)
  var listModelsFlag = false
  var listModelsFilter = ""
  var continueSession = false
  var resumePicker = false
  var sessionSpec = ""
  var customSessionId = ""
  var forkSpec = ""
  var cliSessionDir = ""
  var noSession = false
  var sessionName = ""
  var toolsSpec: seq[string] = @[]
  var noTools = false
  var noMcp = false
  var subagentsEnabled = false
  var extraSkills: seq[string] = @[]
  var noSkills = false
  var extraPrompts: seq[string] = @[]
  var noPrompts = false
  var noContextFiles = false
  var sysPromptOv = ""
  var appendPrompts: seq[string] = @[]
  var trustOverride = none(bool)
  var securityOv = none(SecurityMode)
  var sandboxMode = sandboxOff
  var agentDirOv = ""
  var explicitFiles: seq[string] = @[]
  var promptWords: seq[string] = @[]
  var positionalOnly = false

  var i = 0
  while i < rawArgs.len:
    let a = rawArgs[i]
    if positionalOnly:
      if a.startsWith("@") and a.len > 1:
        explicitFiles.add(a[1 .. ^1])
      else:
        promptWords.add(a)
      inc i
      continue

    case a
    of "--":
      positionalOnly = true
    of "-h", "--help":
      printCliHelp()
      return 0
    of "-v", "--version":
      stdout.writeLine("ni " & NiVersion)
      return 0
    of "-p", "--print":
      printMode = true
    of "--mode":
      outputMode = optionValue(rawArgs, i).toLowerAscii()
      if outputMode notin ["text", "json", "rpc"]:
        raise newException(CliArgumentError, "--mode expects text, json, or rpc")
    of "--no-alt-screen":
      noAltScreen = true
    of "--max-turns":
      let raw = optionValue(rawArgs, i)
      let parsed = try: parseInt(raw) except ValueError: 0
      if parsed <= 0:
        raise newException(CliArgumentError, "--max-turns expects a positive integer")
      maxTurns = parsed
    of "-m", "--model":
      modelPat = optionValue(rawArgs, i)
    of "--provider":
      providerOv = optionValue(rawArgs, i)
    of "--api-key":
      cliApiKey = optionValue(rawArgs, i)
    of "--thinking":
      let level = optionValue(rawArgs, i).strip().toLowerAscii()
      if level notin ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]:
        raise newException(CliArgumentError, "--thinking expects off, minimal, low, medium, high, xhigh, or max")
      thinkingOv = some(parseThinkingLevel(level))
    of "--list-models":
      listModelsFlag = true
      if i + 1 < rawArgs.len and not rawArgs[i + 1].startsWith("-"):
        listModelsFilter = rawArgs[i + 1].toLowerAscii()
        inc i
    of "-c", "--continue":
      continueSession = true
    of "-r", "--resume":
      resumePicker = true
    of "--session":
      sessionSpec = optionValue(rawArgs, i)
    of "--session-id":
      customSessionId = optionValue(rawArgs, i)
      if customSessionId.strip().len == 0 or customSessionId.find({'\0'..'\31', '/', '\\', ':', '*', '?', '"', '<', '>', '|'}) >= 0:
        raise newException(CliArgumentError, "--session-id expects a nonempty ID without path separators or filename control characters")
    of "--fork":
      forkSpec = optionValue(rawArgs, i)
    of "--session-dir":
      cliSessionDir = optionValue(rawArgs, i)
    of "--no-session":
      noSession = true
    of "-n", "--name":
      sessionName = optionValue(rawArgs, i)
    of "-t", "--tools":
      for part in optionValue(rawArgs, i).split(','):
        if part.strip().len > 0: toolsSpec.add(part.strip())
    of "-nt", "--no-tools":
      noTools = true
    of "--no-mcp":
      noMcp = true
    of "--subagents":
      subagentsEnabled = true
    of "--skill":
      extraSkills.add(optionValue(rawArgs, i))
    of "-ns", "--no-skills":
      noSkills = true
    of "--prompt-template":
      extraPrompts.add(optionValue(rawArgs, i))
    of "-np", "--no-prompt-templates":
      noPrompts = true
    of "-nc", "--no-context-files":
      noContextFiles = true
    of "--system-prompt":
      sysPromptOv = optionValue(rawArgs, i)
    of "--append-system-prompt":
      appendPrompts.add(optionValue(rawArgs, i))
    of "-a", "--approve":
      trustOverride = some(true)
    of "-na", "--no-approve":
      trustOverride = some(false)
    of "--security":
      case optionValue(rawArgs, i).toLowerAscii()
      of "strict": securityOv = some(smStrict)
      of "balanced": securityOv = some(smBalanced)
      of "permissive": securityOv = some(smPermissive)
      else: raise newException(CliArgumentError, "--security expects strict, balanced, or permissive")
    of "--yolo":
      securityOv = some(smPermissive)
    of "--sandbox":
      let mode = optionValue(rawArgs, i)
      if mode notin ["off", "read-only", "workspace-write"]:
        raise newException(CliArgumentError, "--sandbox expects off, read-only, or workspace-write")
      sandboxMode = parseEnum[SandboxMode](mode)
    of "--agent-dir":
      agentDirOv = optionValue(rawArgs, i)
    else:
      if a.startsWith("-"):
        stderr.writeLine("Unknown option: " & a & " (run `ni --help` for usage)")
        return 1
      if a.startsWith("@") and a.len > 1:
        explicitFiles.add(a[1 .. ^1])
      else:
        promptWords.add(a)
    inc i

  let cwd = normalizedPath(getCurrentDir())
  let agentDir = getAgentDir(agentDirOv)

  # Pre-load user settings to determine defaultProjectTrust before resolving project trust
  let preCfg = loadConfigBundle(cwd, agentDir, projectTrusted = false, loadContext = false)
  let isInteractive = isInteractiveTerminal() and not printMode and outputMode == "text"
  let projectTrusted = resolveProjectTrust(
    cwd = cwd,
    agentDir = agentDir,
    defaultMode = preCfg.settings.defaultProjectTrust,
    cliOverride = trustOverride,
    interactivePrompt = (if isInteractive: interactiveProjectTrustPrompt else: nil)
  )

  let configOverrides = RuntimeConfigOverrides(
    noContextFiles: noContextFiles, noSkills: noSkills, noPromptTemplates: noPrompts,
    systemPrompt: (if sysPromptOv.len > 0: some(readTextOrFileArg(sysPromptOv, cwd)) else: none(string)),
    securityMode: securityOv, extraSkills: extraSkills, extraPromptTemplates: extraPrompts
  )
  let cfg = loadRuntimeConfig(cwd, agentDir, projectTrusted, configOverrides)

  var resolvedAppends: seq[string] = @[]
  for ap in appendPrompts:
    resolvedAppends.add(readTextOrFileArg(ap, cwd))

  let provReg = newProviderRegistry(cfg)

  if listModelsFlag:
    let selectable = provReg.listSelectableModels(cfg, cliApiKey, includeUnconfigured = true)
    for (m, ready) in selectable:
      let fullId = m.provider & "/" & m.id
      if listModelsFilter.len == 0 or listModelsFilter in fullId.toLowerAscii() or listModelsFilter in m.name.toLowerAscii():
        stdout.writeLine(fullId.alignLeft(36) & "  " & m.name.alignLeft(28) & "  " &
                         (if ready: "[ready] " else: "[no key]") & "  (" & m.api & ")")
    return 0

  # Read piped stdin when stdin is redirected
  var pipedInput = ""
  if not isStdinTty() and outputMode != "rpc":
    try:
      pipedInput = stdin.readAll()
    except CatchableError:
      pipedInput = ""

  var initialPrompt = promptWords.join(" ")
  if pipedInput.strip().len > 0:
    if initialPrompt.len > 0:
      initialPrompt = "<stdin>\n" & pipedInput.strip() & "\n</stdin>\n\n" & initialPrompt
    else:
      initialPrompt = pipedInput.strip()

  # Redirected stdin/stdout defaults to print mode (matching Pi CLI behavior)
  if not isInteractiveTerminal() and outputMode == "text":
    printMode = true

  if initialPrompt.strip().len == 0 and explicitFiles.len == 0:
    if outputMode == "json":
      raise newException(CliArgumentError, "--mode json requires a prompt argument or piped stdin")
    if outputMode == "text" and printMode:
      raise newException(CliArgumentError, "--print requires a prompt argument or piped stdin")

  let secPolicy = newSecurityPolicy(
    cwd, agentDir, cfg.settings.securityMode,
    (if isInteractive: interactiveSecurityPrompt else: nil)
  )
  secPolicy.configureSandbox(sandboxMode)
  defer: secPolicy.closeSandbox()

  # Claim the session before connecting MCP servers or starting a model request.
  let sessionsRoot = resolveSessionsRoot(cfg, cliSessionDir)
  customSessionId = customSessionId.strip()
  var sessMgr: SessionManager = nil

  if forkSpec.len > 0:
    let found = findSessionByIdOrPath(sessionsRoot, cwd, forkSpec)
    if found.isNone:
      stderr.writeLine("Session not found to fork: " & forkSpec)
      return 1
    sessMgr = forkSession(found.get, cwd, sessionsRoot, customSessionId, persist = not noSession)
  elif sessionSpec.len > 0:
    let found = findSessionByIdOrPath(sessionsRoot, cwd, sessionSpec)
    if found.isNone:
      stderr.writeLine("Session not found: " & sessionSpec)
      return 1
    sessMgr = loadSessionFile(found.get, persist = not noSession)
  elif continueSession:
    let existing = listSessions(sessionsRoot, cwd)
    if existing.len > 0:
      sessMgr = loadSessionFile(existing[0].filePath, persist = not noSession)
  elif resumePicker and isInteractive:
    let existing = listSessions(sessionsRoot, cwd)
    let chosen = pickSavedSession(existing)
    if chosen >= 0:
      sessMgr = loadSessionFile(existing[chosen].filePath, persist = not noSession)
  elif not noSession and customSessionId.len > 0:
    sessMgr = openNamedSession(cwd, sessionsRoot, customSessionId, sessionName)

  if sessMgr.isNil:
    sessMgr = newSessionManager(cwd, sessionsRoot, persist = not noSession, customSessionId = customSessionId, sessionName = sessionName)
  defer: sessMgr.close()
  for diagnostic in sessMgr.diagnostics:
    stderr.writeLine("Warning: " & diagnostic)

  let toolOverrides = if toolsSpec.len > 0: @[toolsSpec] else: @[]
  let extraTools = if subagentsEnabled: subagentTools() else: @[]
  let (toolReg, mcpMgr) = configureRuntimeTools(cfg, toolOverrides, noTools, noMcp, secPolicy, extraTools)
  defer: mcpMgr.closeAll()
  let (skillList, promptTplList, _) = discoverRuntimeResources(cfg, configOverrides)

  # Resolve startup model and thinking level
  let (resolvedModel, suffixThink) = provReg.resolveModel(cfg, modelPat, providerOv, cliApiKey)
  let fullModelKey = resolvedModel.provider & "/" & resolvedModel.id
  var startThinking = cfg.settings.defaultThinkingLevel
  if cfg.settings.modelThinkingLevels.hasKey(fullModelKey):
    startThinking = cfg.settings.modelThinkingLevels[fullModelKey]
  if suffixThink.isSome:
    startThinking = suffixThink.get
  if thinkingOv.isSome:
    startThinking = thinkingOv.get

  let rt = newAgentRuntime(
    cfg = cfg,
    providerRegistry = provReg,
    toolRegistry = toolReg,
    mcpManager = mcpMgr,
    skills = skillList,
    security = secPolicy,
    session = sessMgr,
    initialModel = resolvedModel,
    thinkingLevel = startThinking,
    cliApiKey = cliApiKey,
    cliAppendPrompts = resolvedAppends,
    askQuestion = (if isInteractive: promptAskQuestionsInteractive else: nil),
    promptTemplates = promptTplList,
    keepModel = modelPat.len > 0 or providerOv.len > 0,
    keepThinking = thinkingOv.isSome or suffixThink.isSome,
    maxTurnsPerRun = maxTurns
  )
  rt.configOverrides = configOverrides
  rt.toolOverrides = toolOverrides
  rt.noTools = noTools
  rt.noMcp = noMcp
  rt.subagentsEnabled = subagentsEnabled and not noTools
  rt.sessionsRoot = sessionsRoot
  defer: rt.session.close()

  if outputMode == "rpc":
    return runRpcMode(rt)

  if outputMode == "json":
    return runJsonMode(rt, initialPrompt, explicitFiles)

  if printMode:
    return runPrintMode(rt, initialPrompt, explicitFiles)

  runInteractiveRepl(rt, initialPrompt, explicitFiles, noAltScreen = noAltScreen)

when isMainModule:
  try:
    quit(main())
  except CliArgumentError, IOError, OSError:
    stderr.writeLine("Error: " & getCurrentExceptionMsg())
    quit(1)
