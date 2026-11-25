# CLI entry point for `ni` coding agent (`ni`, `ni mcp ...`, `ni auth ...`).

import std/[json, options, os, strutils, tables, terminal]
import ./ni/[types, config, trust, provider, tools, skills, mcp, session, agent, terminal_io, tui, rpc]

const NiVersion = "0.2.0"

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
  -m, --model <pattern>            Select model (`provider/id` or pattern, optional `:thinking` suffix)
      --provider <name>            Select provider (`deepseek`, `anthropic`, `openai`, `google`, or custom ID)
      --api-key <key>              Runtime API key override (not written to disk)
      --thinking <level>           Set thinking level: off, minimal, low, medium, high, xhigh, max
      --list-models [filter]       List configured providers and models, then exit
  -c, --continue                   Continue most recent session for current directory
  -r, --resume                     Interactively pick a session to resume
      --session <id|path>          Open session by file path or ID prefix
      --session-id <id>            Use or create specific session ID
      --fork <id|path>             Fork an existing session into a new session
      --session-dir <dir>          Override session storage root directory
      --no-session                 Run in-memory without writing session JSONL
  -n, --name <title>               Set session display title
  -t, --tools <list>               Comma-separated tool allowlist or `+tool,-tool` deltas
      --no-tools                   Disable all tools
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
      --yolo                       Alias for --security permissive
      --agent-dir <dir>            Override ~/.pi/agent directory
  -v, --version                    Print version and exit
  -h, --help                       Print help and exit

Subcommands:
  ni mcp list [--json]
  ni mcp add <name> [-l|--local] [--exposure <mode>] [--description <text>]
                    [--env KEY=VAL] [--header KEY=VAL] [--url <url>] [-- <cmd> <args...>]
  ni mcp remove <name> [-l|--local]
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
      if i + 1 < args.len: providerId = args[i + 1]; inc i
    of "--api-key":
      if i + 1 < args.len: explicitKey = args[i + 1]; inc i
    of "--agent-dir":
      if i + 1 < args.len: agentDirOv = args[i + 1]; inc i
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
      stdout.writeLine($(%*{ "provider": providerId, "status": status }))
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
      elif args[i] == "--agent-dir" and i + 1 < args.len: agentDirOv = args[i + 1]; inc i
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
          "error": sess.lastError
        })
      stdout.writeLine($(%*{ "servers": arr, "diagnostics": mgr.diagnostics }))
    else:
      if mgr.servers.len == 0:
        stdout.writeLine("No MCP servers configured.")
      for name, sess in mgr.servers.pairs:
        if sess.config.enabled and sess.state != mcsConnected:
          hasFailure = true
        stdout.writeLine(name & " (" & $sess.config.transportKind & ", " & sess.config.source & "): " &
                         $sess.state & " — " & $sess.remoteTools.len & " tool(s), exposure=" & $sess.config.exposure)
        if sess.lastError.len > 0:
          stdout.writeLine("  error: " & sess.lastError)
        for rt in sess.remoteTools:
          stdout.writeLine("  - " & rt.qualifiedName & " [" & $rt.effectiveExposure & "]")
      for d in mgr.diagnostics:
        stderr.writeLine("warning: " & d)
    return (if hasFailure: 1 else: 0)

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
        if i + 1 < args.len: agentDirOv = args[i + 1]; inc i
      of "--url":
        if i + 1 < args.len: url = args[i + 1]; inc i
      of "--exposure":
        if i + 1 < args.len: exposure = parseToolExposure(args[i + 1]); inc i
      of "--description":
        if i + 1 < args.len: desc = args[i + 1]; inc i
      of "--env":
        if i + 1 < args.len:
          let kv = args[i + 1]
          let eq = kv.find('=')
          if eq > 0: envMap[kv[0 ..< eq]] = kv[eq + 1 .. ^1]
          inc i
      of "--header":
        if i + 1 < args.len:
          let kv = args[i + 1]
          let eq = kv.find('=')
          if eq > 0: hdrMap[kv[0 ..< eq]] = kv[eq + 1 .. ^1]
          inc i
      of "--bearer-token-env-var":
        if i + 1 < args.len:
          hdrMap["Authorization"] = "Bearer ${" & args[i + 1] & "}"
          inc i
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
    for i in 2 ..< args.len:
      if args[i] in ["-l", "--local"]: localScope = true
      elif args[i] == "--agent-dir" and i + 1 < args.len: agentDirOv = args[i + 1]
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
  initTerminal()
  let rawArgs = commandLineParams()
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
  var extraSkills: seq[string] = @[]
  var noSkills = false
  var extraPrompts: seq[string] = @[]
  var noPrompts = false
  var noContextFiles = false
  var sysPromptOv = ""
  var appendPrompts: seq[string] = @[]
  var trustOverride = none(bool)
  var securityOv = none(SecurityMode)
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
      if i + 1 < rawArgs.len: outputMode = rawArgs[i + 1].toLowerAscii(); inc i
    of "-m", "--model":
      if i + 1 < rawArgs.len: modelPat = rawArgs[i + 1]; inc i
    of "--provider":
      if i + 1 < rawArgs.len: providerOv = rawArgs[i + 1]; inc i
    of "--api-key":
      if i + 1 < rawArgs.len: cliApiKey = rawArgs[i + 1]; inc i
    of "--thinking":
      if i + 1 < rawArgs.len: thinkingOv = some(parseThinkingLevel(rawArgs[i + 1])); inc i
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
      if i + 1 < rawArgs.len: sessionSpec = rawArgs[i + 1]; inc i
    of "--session-id":
      if i + 1 < rawArgs.len: customSessionId = rawArgs[i + 1]; inc i
    of "--fork":
      if i + 1 < rawArgs.len: forkSpec = rawArgs[i + 1]; inc i
    of "--session-dir":
      if i + 1 < rawArgs.len: cliSessionDir = rawArgs[i + 1]; inc i
    of "--no-session":
      noSession = true
    of "-n", "--name":
      if i + 1 < rawArgs.len: sessionName = rawArgs[i + 1]; inc i
    of "-t", "--tools":
      if i + 1 < rawArgs.len:
        for part in rawArgs[i + 1].split(','):
          if part.strip().len > 0: toolsSpec.add(part.strip())
        inc i
    of "-nt", "--no-tools":
      noTools = true
    of "--no-mcp":
      noMcp = true
    of "--skill":
      if i + 1 < rawArgs.len: extraSkills.add(rawArgs[i + 1]); inc i
    of "-ns", "--no-skills":
      noSkills = true
    of "--prompt-template":
      if i + 1 < rawArgs.len: extraPrompts.add(rawArgs[i + 1]); inc i
    of "-np", "--no-prompt-templates":
      noPrompts = true
    of "-nc", "--no-context-files":
      noContextFiles = true
    of "--system-prompt":
      if i + 1 < rawArgs.len: sysPromptOv = rawArgs[i + 1]; inc i
    of "--append-system-prompt":
      if i + 1 < rawArgs.len: appendPrompts.add(rawArgs[i + 1]); inc i
    of "-a", "--approve":
      trustOverride = some(true)
    of "-na", "--no-approve":
      trustOverride = some(false)
    of "--security":
      if i + 1 < rawArgs.len:
        case rawArgs[i + 1].toLowerAscii()
        of "strict": securityOv = some(smStrict)
        of "permissive": securityOv = some(smPermissive)
        else: securityOv = some(smBalanced)
        inc i
    of "--yolo":
      securityOv = some(smPermissive)
    of "--agent-dir":
      if i + 1 < rawArgs.len: agentDirOv = rawArgs[i + 1]; inc i
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

  let cfg = loadConfigBundle(cwd, agentDir, projectTrusted = projectTrusted, loadContext = not noContextFiles)
  if sysPromptOv.len > 0:
    cfg.customSystemPrompt = readTextOrFileArg(sysPromptOv, cwd)

  var resolvedAppends: seq[string] = @[]
  for ap in appendPrompts:
    resolvedAppends.add(readTextOrFileArg(ap, cwd))

  if securityOv.isSome:
    cfg.settings.securityMode = securityOv.get

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
  if not stdin.isatty() and outputMode != "rpc":
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
  if (not stdin.isatty() or not stdout.isatty()) and outputMode == "text":
    printMode = true

  # Assemble tools, MCP servers, and skills
  var enabledTools = cfg.settings.defaultTools
  if noTools:
    enabledTools = @[]
  elif toolsSpec.len > 0:
    enabledTools = applyToolListSpec(enabledTools, toolsSpec)

  let toolReg = newToolRegistry(enabledTools)
  let mcpMgr = if noMcp or noTools:
    McpManager(servers: initOrderedTable[string, McpServerSession](), diagnostics: @[], workspaceRoot: cwd)
  else:
    newMcpManager(cfg, toolReg, connectNow = true)
  defer:
    mcpMgr.closeAll()

  var skillList: seq[Skill] = @[]
  if not noSkills:
    let (sks, _) = discoverSkills(cwd, agentDir, cfg.settings.skills & extraSkills, projectTrusted = projectTrusted, includeDefaults = true)
    skillList = sks
  elif extraSkills.len > 0:
    let (sks, _) = discoverSkills(cwd, agentDir, extraSkills, projectTrusted = projectTrusted, includeDefaults = false)
    skillList = sks

  var promptTplList: seq[PromptTemplate] = @[]
  if not noPrompts:
    let (tpls, _) = discoverPromptTemplates(cwd, agentDir, cfg.settings.prompts & extraPrompts, projectTrusted = projectTrusted, includeDefaults = true)
    promptTplList = tpls
  elif extraPrompts.len > 0:
    let (tpls, _) = discoverPromptTemplates(cwd, agentDir, extraPrompts, projectTrusted = projectTrusted, includeDefaults = false)
    promptTplList = tpls

  # Resolve session (new, --continue, --resume, --session, or --fork)
  let sessionsRoot = resolveSessionsRoot(cfg, cliSessionDir)
  var sessMgr: SessionManager = nil

  if forkSpec.len > 0:
    let found = findSessionByIdOrPath(sessionsRoot, cwd, forkSpec)
    if found.isNone:
      stderr.writeLine("Session not found to fork: " & forkSpec)
      return 1
    sessMgr = forkSession(found.get, cwd, sessionsRoot, customSessionId)
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
    if existing.len > 0:
      var opts: seq[QuestionOption] = @[]
      let cnt = min(15, existing.len)
      for idx in 0 ..< cnt:
        let s = existing[idx]
        opts.add(QuestionOption(label: s.displayName, description: s.id[0 ..< min(8, s.id.len)] & " · " & $s.messageCount & " msgs"))
      let pick = promptQuestionWidget(AskQuestionItem(
        id: "cli_resume",
        header: "Resume",
        question: "Choose a session to resume:",
        options: opts,
        multiSelect: false,
        allowOther: false
      ))
      if not pick.cancelled and pick.selected.len > 0:
        for idx in 0 ..< cnt:
          if opts[idx].label == pick.selected[0]:
            sessMgr = loadSessionFile(existing[idx].filePath, persist = not noSession)
            break

  if sessMgr.isNil:
    sessMgr = newSessionManager(cwd, sessionsRoot, persist = not noSession, customSessionId = customSessionId, sessionName = sessionName)

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

  let secPolicy = newSecurityPolicy(
    cwd = cwd,
    agentDir = agentDir,
    mode = cfg.settings.securityMode,
    prompt = (if isInteractive: interactiveSecurityPrompt else: nil)
  )

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
    promptTemplates = promptTplList
  )

  if outputMode == "rpc":
    return runRpcMode(rt)

  if outputMode == "json":
    if initialPrompt.strip().len == 0 and explicitFiles.len == 0:
      stderr.writeLine("Error: --mode json requires a prompt argument or piped stdin")
      return 1
    return runJsonMode(rt, initialPrompt, explicitFiles)

  if printMode:
    if initialPrompt.strip().len == 0 and explicitFiles.len == 0:
      stderr.writeLine("Error: --print requires a prompt argument or piped stdin")
      return 1
    return runPrintMode(rt, initialPrompt, explicitFiles)

  runInteractiveRepl(rt, initialPrompt, explicitFiles)

when isMainModule:
  quit(main())
