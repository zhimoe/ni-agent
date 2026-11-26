# Interactive Docked TUI (persistent bottom input bar, live status border, searchable /model selector, streaming Markdown), print & JSONL modes.

import std/[algorithm, json, options, os, sets, strutils, tables]
import ./[types, config, trust, provider, tools, skills, mcp, session, prompt, agent, brand, terminal_io, keybindings, editor, markdown, viewport]

type
  DockViewport* = ref object
    rt*: AgentRuntime
    ed*: InputEditor
    transcript*: Transcript
    followUpKeys: set[KeyKind]
    gitBranch*: string
    workingPhase: string
    workingDetail: string
    activeTailLines*: seq[string]
    drawnFrame: seq[string]
    drawnSize: tuple[cols: int, rows: int]
    suspended*: bool
    fullScreen*: bool
    turnStartMs: int64

  ModelPickResult = object
    cancelled: bool
    chosenModel: ModelConfig
    saveAsDefault: bool

var activeRunAbort: AbortFlag = nil
var sigintCount = 0

proc installCtrlCHandler() =
  setControlCHook(proc() {.noconv.} =
    if not activeRunAbort.isNil and not activeRunAbort.aborted:
      activeRunAbort.aborted = true
      sigintCount = 0
    else:
      inc sigintCount
      if sigintCount >= 2:
        exitFullScreen()
        exitRawTerminalMode()
        quit(130)
  )

# Git branch & editor command / model autocomplete helpers

proc detectGitBranch*(cwd: string): string =
  ## Fast `.git/HEAD` check without spawning git subprocesses.
  var cur = normalizedPath(cwd)
  while cur.len > 0:
    let gitEntry = cur / ".git"
    if dirExists(gitEntry) and fileExists(gitEntry / "HEAD"):
      try:
        let headTxt = readFile(gitEntry / "HEAD").strip()
        if headTxt.startsWith("ref: refs/heads/"):
          return headTxt[16 .. ^1]
        if headTxt.len >= 7:
          return headTxt[0 ..< 7]
      except CatchableError:
        discard
      break
    elif fileExists(gitEntry):
      try:
        let first = readFile(gitEntry).strip()
        if first.startsWith("gitdir:"):
          let gdir = resolvePathFrom(first[7 .. ^1].strip(), cur)
          if fileExists(gdir / "HEAD"):
            let headTxt = readFile(gdir / "HEAD").strip()
            if headTxt.startsWith("ref: refs/heads/"):
              return headTxt[16 .. ^1]
            if headTxt.len >= 7:
              return headTxt[0 ..< 7]
      except CatchableError:
        discard
      break
    let p = parentDir(cur)
    if p == cur or p.len == 0:
      break
    cur = p
  ""

proc buildSlashCommandDefs*(rt: AgentRuntime): seq[SlashCommandDef] =
  ## Assemble built-in slash commands, `/skill:<name>` skills, and `/<template>` prompt templates for autocomplete.
  result = @[
    SlashCommandDef(name: "model", argumentHint: "[provider/model]", description: "Search & switch model (configured providers)", source: "builtin"),
    SlashCommandDef(name: "thinking", argumentHint: "[level]", description: "Set reasoning level (off, low, medium, high, xhigh, max)", source: "builtin"),
    SlashCommandDef(name: "copy", argumentHint: "[last|code|diff|<N>]", description: "Copy last reply, fenced code block, or edit diff", source: "builtin"),
    SlashCommandDef(name: "new", description: "Start a brand-new session", source: "builtin"),
    SlashCommandDef(name: "resume", description: "Select and resume a saved session", source: "builtin"),
    SlashCommandDef(name: "tree", description: "Navigate session tree and switch branches", source: "builtin"),
    SlashCommandDef(name: "fork", argumentHint: "[entryId]", description: "Fork conversation into a new session", source: "builtin"),
    SlashCommandDef(name: "export", argumentHint: "[path.html|path.md|path.jsonl]", description: "Export active session transcript", source: "builtin"),
    SlashCommandDef(name: "compact", description: "Summarize older turns to free context tokens", source: "builtin"),
    SlashCommandDef(name: "clear", description: "Reset to a clean root conversation branch", source: "builtin"),
    SlashCommandDef(name: "session", description: "Show session ID, file path, token usage, and cost", source: "builtin"),
    SlashCommandDef(name: "name", argumentHint: "<title>", description: "Set display title for the current session", source: "builtin"),
    SlashCommandDef(name: "skills", description: "List discovered Agent Skills", source: "builtin"),
    SlashCommandDef(name: "prompts", description: "List discovered Markdown prompt templates", source: "builtin"),
    SlashCommandDef(name: "mcp", argumentHint: "[list|reconnect]", description: "Show MCP server states/tools or reconnect", source: "builtin"),
    SlashCommandDef(name: "tools", argumentHint: "[+name|-name]", description: "List active tools or enable/disable tools", source: "builtin"),
    SlashCommandDef(name: "trust", argumentHint: "[allow|deny|status]", description: "Inspect or update project trust", source: "builtin"),
    SlashCommandDef(name: "login", argumentHint: "[provider]", description: "Save API key into ~/.pi/agent/auth.json", source: "builtin"),
    SlashCommandDef(name: "logout", argumentHint: "[provider]", description: "Remove stored credential from auth.json", source: "builtin"),
    SlashCommandDef(name: "reload", description: "Reload settings, models-store, skills, prompts, and MCP", source: "builtin"),
    SlashCommandDef(name: "hotkeys", description: "Show keyboard shortcuts for the TUI input editor", source: "builtin"),
    SlashCommandDef(name: "help", description: "Show available slash commands and tips", source: "builtin"),
    SlashCommandDef(name: "quit", description: "Exit ni", source: "builtin")
  ]
  if rt.cfg.settings.enableSkillCommands:
    for sk in rt.skills:
      result.add(SlashCommandDef(
        name: "skill:" & sk.name,
        argumentHint: "[args]",
        description: sk.description,
        source: "skill"
      ))
  for tpl in rt.promptTemplates:
    result.add(SlashCommandDef(
      name: tpl.name,
      argumentHint: tpl.argumentHint,
      description: "[prompt] " & tpl.description,
      source: "prompt"
    ))

proc buildModelAutocompleteItems*(rt: AgentRuntime): seq[AutocompleteItem] =
  ## Build inline `/model <Tab>` autocomplete items from configured providers (plus built-ins).
  let entries = rt.providerRegistry.listSelectableModels(rt.cfg, rt.cliApiKey, includeUnconfigured = true)
  for (m, isCfg) in entries:
    let full = m.provider & "/" & m.id
    let tag = if isCfg: "" else: " (no key)"
    result.add(AutocompleteItem(
      display: full,
      insertText: full,
      description: m.name & " · ctx " & formatCompactCount(m.contextWindow) & tag,
      isDirectory: false,
      score: (if isCfg: 100 else: 10)
    ))

proc buildEditorStatus*(rt: AgentRuntime, gitBranch: string, workingStatus = ""): EditorStatusInfo =
  let (msgs, _, _) = rt.session.buildActiveContext()
  let sysPrompt = buildSystemPrompt(PromptBuildInput(
    cwd: rt.cfg.cwd,
    customSystemPrompt: rt.cfg.customSystemPrompt,
    appendSystemPrompt: rt.cfg.appendSystemPrompt,
    cliAppendPrompts: rt.cliAppendPrompts,
    contextFiles: rt.cfg.contextFiles,
    toolRegistry: rt.toolRegistry,
    skills: rt.skills,
    mcpManager: rt.mcpManager
  ))
  let estTok = estimateContextTokens(sysPrompt, msgs)
  let pct = if rt.currentModel.contextWindow > 0 and msgs.len > 0:
    clamp((estTok * 100) div rt.currentModel.contextWindow, 1, 100)
  else:
    0
  let u = rt.session.totalUsage
  let isSub = rt.currentModel.provider == "kimi-coding" or
              (rt.cfg.auth.hasKey(rt.currentModel.provider) and rt.cfg.auth[rt.currentModel.provider].kind == ckOAuth)

  var queued: seq[string] = @[]
  for prompt in rt.steeringQueue: queued.add(prompt.text)
  for prompt in rt.followUpQueue: queued.add(prompt.text)

  EditorStatusInfo(
    cwd: rt.cfg.cwd,
    gitBranch: gitBranch,
    sessionName: rt.session.displayName,
    modelLabel: rt.currentModel.id,
    thinkingLabel: (if rt.currentModel.reasoning: $rt.thinkingLevel else: "off"),
    contextPct: pct,
    contextWindow: rt.currentModel.contextWindow,
    inputTokens: u.inputTokens,
    outputTokens: u.outputTokens,
    cacheReadTokens: u.cacheReadTokens,
    totalTokens: u.totalTokens,
    costUsd: u.costTotal,
    isSubscription: isSub,
    workingStatus: workingStatus,
    queuedMessages: queued
  )

# Persistent Docked Viewport Manager (keeps input box + status footer anchored at bottom at all times)

proc newDockViewport*(rt: AgentRuntime, ed: InputEditor): DockViewport =
  DockViewport(
    rt: rt,
    ed: ed,
    transcript: newTranscript(),
    followUpKeys: loadFollowUpKeys(rt.cfg.agentDir),
    gitBranch: detectGitBranch(rt.cfg.cwd),
    fullScreen: supportsFullScreen()
  )

proc isDockedActive(vp: DockViewport): bool =
  not vp.isNil and vp.fullScreen and not vp.suspended

proc setWorkingStatus(vp: DockViewport, phase = "", detail = "") =
  vp.workingPhase = phase
  vp.workingDetail = detail

proc setThinkingStatus(vp: DockViewport, chars: int) =
  vp.setWorkingStatus("Thinking", align(formatCompactCount(chars), 6) & " chars")

const
  SpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  SpinnerIntervalMs = 100

proc elapsedMilliseconds(vp: DockViewport): int64 =
  max(0'i64, nowUnixMs() - vp.turnStartMs)

proc formatWorkingStatus(vp: DockViewport): string =
  if vp.workingPhase.len == 0:
    return ""
  if vp.workingPhase == "Interrupting":
    return styleYellow("Interrupting…")
  let elapsedMs = vp.elapsedMilliseconds()
  let spinner = SpinnerFrames[(elapsedMs div SpinnerIntervalMs) mod SpinnerFrames.len]
  let elapsed = elapsedMs div 1000
  let minutes = align($(elapsed div 60), 2, '0')
  let seconds = align($(elapsed mod 60), 2, '0')
  styleCyan(spinner & " " & vp.workingPhase) & styleDim(" " & minutes & ":" & seconds & "s" &
    (if vp.workingDetail.len > 0: " · " & vp.workingDetail else: ""))

proc paintScreen(vp: DockViewport, forceRepaint = false) =
  ## Compose and paint one full frame: scrollable transcript above, input box + status line pinned to the bottom.
  if vp.isNil or not vp.isDockedActive():
    return
  let (cols, rows) = terminalSize()
  var full = forceRepaint or cols != vp.drawnSize.cols or rows != vp.drawnSize.rows
  if full:
    vp.drawnFrame.setLen(0)
  vp.transcript.setTail(vp.activeTailLines)
  let status = buildEditorStatus(vp.rt, vp.gitBranch, vp.formatWorkingStatus())
  let frame = vp.transcript.composeScreen(vp.ed, status, cols, rows)
  var output = ""
  if full and vp.drawnSize.cols > 0:
    output.add("\x1b[2J")
  output.add(paintDiff(vp.drawnFrame, frame, fullRepaint = full))
  if output.len > 0:
    beginSyncOutput()
    stdout.write(output)
    endSyncOutput()
  vp.drawnFrame = frame
  vp.drawnSize = (cols, rows)

proc redrawDock*(vp: DockViewport, commitLinesFirst: openArray[string] = []) =
  ## Commit permanent transcript rows, then repaint the docked input bar and status line.
  if vp.isNil:
    return
  if not vp.fullScreen:
    for cl in commitLinesFirst:
      stdout.writeLine(cl)
    if commitLinesFirst.len > 0:
      stdout.flushFile()
    return
  vp.transcript.addLines(commitLinesFirst)
  if vp.isDockedActive():
    vp.paintScreen()

proc suspendDock*(vp: DockViewport) =
  ## Clear the fixed layout so a modal selector (`/model`, `ask_question`, `/login`) can render from the top.
  if vp.isNil or vp.suspended:
    return
  if vp.isDockedActive():
    clearFullScreen()
  vp.drawnFrame.setLen(0)
  vp.suspended = true

proc resumeDock*(vp: DockViewport) =
  ## Re-anchor the transcript viewport and the docked input box after a modal closes.
  if vp.isNil:
    return
  vp.suspended = false
  vp.gitBranch = detectGitBranch(vp.rt.cfg.cwd)
  vp.drawnFrame.setLen(0)
  vp.redrawDock()

proc applyScrollKey*(vp: DockViewport, ev: KeyEvent): bool =
  ## Handle transcript scrolling keys; returns true when the key was consumed.
  if vp.isNil or not vp.fullScreen or vp.suspended:
    return false
  let (_, rows) = terminalSize()
  let page = max(1, rows - 8)
  case ev.kind
  of kkPageUp:
    vp.transcript.scrollBy(page)
  of kkPageDown:
    vp.transcript.scrollBy(-page)
  of kkScrollUp:
    vp.transcript.scrollBy(3)
  of kkScrollDown:
    vp.transcript.scrollBy(-3)
  of kkHome:
    if vp.transcript.atBottom(): return false
    vp.transcript.scrollToTop()
  of kkEnd:
    if vp.transcript.atBottom(): return false
    vp.transcript.scrollToBottom()
  else:
    return false
  true

proc handleDockKey(vp: DockViewport, ev: KeyEvent): Option[EditorOutcome] =
  if vp.applyScrollKey(ev):
    return none(EditorOutcome)
  if ev.kind == kkCtrlL:
    vp.drawnFrame.setLen(0)
  vp.ed.handleKeyEvent(ev)

proc printAboveDock*(vp: DockViewport, lines: openArray[string]) =
  ## Commit one or more rendered rows into the transcript as a notice block.
  if vp.isNil:
    return
  if vp.fullScreen:
    discard vp.transcript.beginSegment(segNotice)
    vp.transcript.addLines(lines)
    if vp.isDockedActive():
      vp.paintScreen()
    return
  for line in lines:
    stdout.writeLine(line)
  stdout.flushFile()

proc printAboveDock*(vp: DockViewport, text: string) =
  ## Commit a multi-line message permanently into the transcript above the docked input bar.
  if vp.isNil:
    return
  vp.printAboveDock(text.replace("\r\n", "\n").split('\n'))

proc renderUserPromptBlock*(displayText: string, cols: int): seq[string] =
  ## Format a submitted user prompt with a subtle left accent bar so user turns stand out clearly in scrollback.
  let bar = styleCyan("┃ ")
  let promptMark = styleBold(styleCyan("❯ "))
  let rawLines = displayText.replace("\r\n", "\n").split('\n')
  for idx, rl in rawLines.pairs:
    let firstPfx = if idx == 0: bar & promptMark else: bar & "  "
    let contPfx = bar & "  "
    let styled = if idx == 0: styleBold(rl) else: rl
    for wl in wrapAnsiText(styled, max(24, cols - 2), firstIndent = firstPfx, contIndent = contPfx):
      result.add(wl)
  result.add("")

proc promptTitle(displayText: string): string =
  ## First meaningful prompt line, used for the pinned transcript header.
  for line in displayText.replace("\r\n", "\n").split('\n'):
    let trimmed = line.strip()
    if trimmed.len > 0:
      return truncateVisible(trimmed, 64, ellipsis = "…")
  ""

proc beginUserTurn*(vp: DockViewport, displayText: string, cols: int) =
  ## Start a new user message block in the transcript and render its prompt rows.
  if vp.isNil:
    return
  discard vp.transcript.beginSegment(segUser, promptTitle(displayText))
  vp.redrawDock(renderUserPromptBlock(displayText, cols))

# Diff & tool call formatting

proc summarizeToolArgs(name: string, args: JsonNode): string =
  if args.isNil or args.kind != JObject:
    return ""
  case name
  of "read", "write", "edit":
    args{"path"}.getStr("")
  of "bash", "powershell":
    let c = args{"command"}.getStr("").strip().replace("\n", " ")
    if c.len > 72: c[0 ..< 69] & "..." else: c
  of "grep", "find":
    args{"pattern"}.getStr("") & (if args.hasKey("path"): " in " & args{"path"}.getStr("") else: "")
  of "ls":
    args{"path"}.getStr(".")
  of "tool_search":
    args{"query"}.getStr("")
  of "ask_question":
    let qs = args{"questions"}
    if not qs.isNil and qs.kind == JArray and qs.len > 0:
      $qs.len & " question(s)"
    else:
      "question"
  else:
    let s = $args
    if s.len > 72: s[0 ..< 69] & "..." else: s

proc formatColoredDiffLines*(diff: string): seq[string] =
  ## Format unified diff lines with colored +/- styling.
  for line in diff.splitLines():
    if line.startsWith("+++") or line.startsWith("---"):
      result.add("  " & styleBold(line))
    elif line.startsWith("@@"):
      result.add("  " & styleCyan(line))
    elif line.startsWith("+"):
      result.add("  " & styleGreen(line))
    elif line.startsWith("-"):
      result.add("  " & styleRed(line))
    else:
      result.add("  " & styleDim(line))

proc renderColoredDiff*(diff: string) =
  for l in formatColoredDiffLines(diff):
    stdout.writeLine(l)

proc indentLines(lines: openArray[string], pad = "  "): seq[string] =
  for l in lines:
    if l.len == 0: result.add("")
    else: result.add(pad & l)

proc renderThinkingLines(text: string, cols: int): seq[string] =
  let lines = text.strip().splitLines()
  for i, line in lines.pairs:
    let prefix = if i == 0: "  " & styleDim("💭 ") else: "     "
    result.add(wrapAnsiText(styleDim(line), max(28, cols - 4), firstIndent = prefix, contIndent = "     "))

proc makeInteractiveEventPrinter*(hideThinking: bool, vp: DockViewport = nil): AgentEventCallback =
  ## Build a streaming terminal renderer (dock-aware when vp != nil; standalone fallback otherwise).
  if vp.isNil:
    var inThinking = false
    var inText = false
    var mdStream = newStreamMarkdownRenderer()
    return proc(ev: AgentEvent) =
      case ev.kind
      of aekTurnStart:
        inThinking = false
        inText = false
        mdStream = newStreamMarkdownRenderer()
      of aekStream:
        case ev.streamEvent.kind
        of sekThinkingDelta:
          if not hideThinking:
            if not inThinking:
              stdout.write(styleDim("💭 "))
              inThinking = true
            stdout.write(styleDim(ev.streamEvent.thinkingDelta))
            stdout.flushFile()
        of sekTextDelta:
          if inThinking:
            stdout.write("\n\n")
            inThinking = false
          inText = true
          mdStream.feedDelta(ev.streamEvent.textDelta)
        of sekError:
          if inText: mdStream.finishStream(); inText = false
          stdout.writeLine(styleRed("✗ " & ev.streamEvent.errorMsg))
        else: discard
      of aekToolStart:
        if inText: mdStream.finishStream(); inText = false
        let argSummary = summarizeToolArgs(ev.toolName, ev.toolArgs)
        stdout.writeLine(styleCyan("● " & ev.toolName) & (if argSummary.len > 0: " " & styleDim(argSummary) else: ""))
      of aekToolEnd:
        if ev.toolOutput.isError:
          stdout.writeLine("  " & styleRed("✗ " & collectText(ev.toolOutput.content).splitLines()[0]))
        elif ev.toolOutput.diff.len > 0:
          renderColoredDiff(ev.toolOutput.diff)
      of aekTurnEnd:
        if inText: mdStream.finishStream(); inText = false
      else: discard

  # Docked TUI streaming printer: streams rendered Markdown & tool calls above the fixed bottom input bar
  var thinkingBuf = ""
  var thinkingChars = 0
  var inText = false
  var mdStream = newStreamMarkdownRenderer()

  proc flushThinkingAboveDock() =
    if thinkingBuf.strip().len > 0 and not hideThinking:
      let (cols, _) = terminalSize()
      vp.activeTailLines.setLen(0)
      discard vp.transcript.beginSegment(segThinking)
      vp.redrawDock(renderThinkingLines(thinkingBuf, cols) & @[""])
    thinkingBuf = ""

  proc flushTextAboveDock() =
    if inText:
      let rem = indentLines(mdStream.flushStreamMarkdown(), "  ")
      vp.activeTailLines.setLen(0)
      if rem.len > 0:
        vp.redrawDock(rem & @[""])
      else:
        vp.redrawDock()
      inText = false

  result = proc(ev: AgentEvent) =
    let (cols, rows) = terminalSize()
    mdStream.maxWidth = max(28, cols - 4)
    let maxErasable = rows - 1

    case ev.kind
    of aekTurnStart:
      thinkingBuf = ""
      thinkingChars = 0
      inText = false
      mdStream = newStreamMarkdownRenderer(max(28, cols - 4))
      vp.setThinkingStatus(thinkingChars)
      vp.redrawDock()

    of aekStream:
      let sev = ev.streamEvent
      case sev.kind
      of sekThinkingDelta:
        thinkingChars += sev.thinkingDelta.len
        thinkingBuf.add(sev.thinkingDelta)
        vp.setThinkingStatus(thinkingChars)
        if not hideThinking:
          let tailWrapped = renderThinkingLines(thinkingBuf, cols)
          if tailWrapped.len > maxErasable:
            vp.activeTailLines = tailWrapped[tailWrapped.len - maxErasable .. ^1]
          else:
            vp.activeTailLines = tailWrapped
        vp.redrawDock()

      of sekTextDelta:
        if thinkingBuf.len > 0:
          flushThinkingAboveDock()
        if not inText:
          discard vp.transcript.beginSegment(segAssistant, vp.rt.currentModel.id)
        inText = true
        vp.setWorkingStatus("Generating")
        let (committed, activeTail) = mdStream.stepStreamMarkdown(sev.textDelta, maxErasable)
        vp.activeTailLines = indentLines(activeTail, "  ")
        vp.redrawDock(indentLines(committed, "  "))

      of sekToolCallStart:
        if thinkingBuf.len > 0:
          flushThinkingAboveDock()
        if inText:
          flushTextAboveDock()
        vp.setWorkingStatus("Preparing tool", sev.callName)
        vp.redrawDock()

      of sekError:
        thinkingBuf = ""
        if inText:
          flushTextAboveDock()
        vp.activeTailLines.setLen(0)
        discard vp.transcript.beginSegment(segNotice)
        vp.redrawDock(@["  " & styleRed("✗ " & sev.errorMsg), ""])

      else:
        discard

    of aekToolStart:
      if thinkingBuf.len > 0:
        flushThinkingAboveDock()
      if inText:
        flushTextAboveDock()
      let argSummary = summarizeToolArgs(ev.toolName, ev.toolArgs)
      let toolLine = "  " & styleCyan("● " & ev.toolName) & (if argSummary.len > 0: " " & styleDim(argSummary) else: "")
      vp.setWorkingStatus("Running " & ev.toolName, argSummary)
      discard vp.transcript.beginSegment(segTool, ev.toolName & (if argSummary.len > 0: " " & argSummary else: ""))
      vp.redrawDock(@[toolLine])

    of aekToolEnd:
      var commit: seq[string] = @[]
      if ev.toolOutput.isError:
        let errPreview = collectText(ev.toolOutput.content).splitLines()[0]
        commit.add("    " & styleRed("✗ " & errPreview))
      else:
        if ev.toolOutput.diff.len > 0:
          for dl in formatColoredDiffLines(ev.toolOutput.diff):
            commit.add("  " & dl)
        if ev.toolOutput.activatedTools.len > 0:
          commit.add("    " & styleGreen("+ Activated tools: ") & ev.toolOutput.activatedTools.join(", "))
      if commit.len > 0:
        vp.redrawDock(commit)

    of aekCompaction:
      discard vp.transcript.beginSegment(segNotice)
      vp.redrawDock(@["  " & styleMagenta("⟳ Auto-compacted conversation (" & $ev.tokensBefore & " est. tokens summarized)")])

    of aekTurnEnd:
      if thinkingBuf.len > 0:
        flushThinkingAboveDock()
      if inText:
        flushTextAboveDock()

    of aekRunEnd:
      vp.setWorkingStatus()
      vp.activeTailLines.setLen(0)
      vp.redrawDock()

# Interactive Searchable `/model` Selector (aligned with Pi's ModelSelectorComponent)

proc promptModelSelector*(rt: AgentRuntime, initialQuery = ""): ModelPickResult =
  ## Open an interactive searchable `/model` picker showing configured providers by default (with Ctrl+A all-models toggle & Ctrl+S save default).
  if not isInteractiveTerminal():
    return ModelPickResult(cancelled: true)

  var showAll = false
  var query = initialQuery.strip()
  var selectedIdx = 0
  var renderedLines = 0

  proc computeFiltered(): seq[tuple[model: ModelConfig, configured: bool, score: int]] =
    # When user types a search query that matches unconfigured built-ins (e.g. `6.2` or `openai`), include them automatically
    let pool = rt.providerRegistry.listSelectableModels(rt.cfg, rt.cliApiKey, includeUnconfigured = showAll or query.len > 0)
    for (m, isCfg) in pool:
      let searchTarget = m.provider & " " & m.provider & "/" & m.id & " " & m.id & " " & m.name
      let sc = if query.len == 0: 100 else: fuzzyScore(query, searchTarget)
      if sc > 0:
        let isCur = (m.provider == rt.currentModel.provider and m.id == rt.currentModel.id)
        let isDef = (m.provider == rt.cfg.settings.defaultProvider and m.id == rt.cfg.settings.defaultModel)
        let rankBonus = (if isCur and query.len == 0: 2000 elif isDef and query.len == 0: 1000 elif isCfg: 200 else: 0)
        result.add((m, isCfg, sc + rankBonus))
    result.sort(proc(a, b: tuple[model: ModelConfig, configured: bool, score: int]): int =
      let c = cmp(b.score, a.score)
      if c != 0: return c
      let p = cmp(a.model.provider, b.model.provider)
      if p != 0: return p
      cmp(a.model.id, b.model.id)
    )

  enterRawTerminalMode()
  defer:
    exitRawTerminalMode()

  var firstFrame = true
  while true:
    let (cols, _) = terminalSize()
    let items = computeFiltered()
    if firstFrame:
      firstFrame = false
      for idx, item in items.pairs:
        if item.model.provider == rt.currentModel.provider and item.model.id == rt.currentModel.id:
          selectedIdx = idx
          break
    if items.len == 0:
      selectedIdx = 0
    else:
      selectedIdx = clamp(selectedIdx, 0, items.high)

    var frame: seq[string] = @[]
    let rule = styleDim("─".repeat(cols))
    frame.add(rule)
    let scopeNote = if showAll:
      styleCyan("Showing all built-in & configured models") & styleDim(" (Ctrl+A configured only)")
    else:
      styleYellow("Only showing models from configured providers.") & styleDim(" Use /login or Ctrl+A for all.")
    frame.add("  " & truncateVisible(scopeNote, max(20, cols - 4)))

    let cursorBlk = if colorsActive(): "\x1b[7m \x1b[27m" else: "▏"
    let filterDisp = if query.len > 0: query & cursorBlk else: cursorBlk & styleDim(" Filter by provider or model name…")
    frame.add("  " & styleBold(styleCyan("🔍 ")) & truncateVisible(filterDisp, max(16, cols - 6)))
    frame.add("")

    if items.len == 0:
      frame.add("    " & styleDim("No matching models. Press Backspace or Ctrl+A to show unconfigured providers."))
    else:
      let maxShown = min(10, items.len)
      var startIdx = 0
      if selectedIdx >= maxShown:
        startIdx = selectedIdx - maxShown + 1
      for idx in startIdx ..< min(items.len, startIdx + maxShown):
        let (m, isCfg, _) = items[idx]
        let isSel = (idx == selectedIdx)
        let isCur = (m.provider == rt.currentModel.provider and m.id == rt.currentModel.id)
        let isDef = (m.provider == rt.cfg.settings.defaultProvider and m.id == rt.cfg.settings.defaultModel)
        let ptrStr = if isSel: styleCyan("  ❯ ") else: "    "
        let fullId = m.provider & "/" & m.id
        let distinctName = if m.name.toLowerAscii() != m.id.toLowerAscii(): " · " & m.name else: ""
        var badges = ""
        if isCur: badges.add(styleGreen(" [current]"))
        if isDef: badges.add(styleMagenta(" [default]"))
        if not isCfg: badges.add(styleYellow(" [no key]"))

        var caps: seq[string] = @[formatCompactCount(m.contextWindow) & " ctx"]
        if "image" in m.inputs: caps.add("vision")
        if m.reasoning: caps.add("thinking")
        let metaRight = styleDim(" (" & caps.join(", ") & ")")

        let primary = (if isSel: styleBold(styleCyan(fullId)) else: fullId) &
                      (if distinctName.len > 0: styleDim(distinctName) else: "") & badges & metaRight
        frame.add(ptrStr & truncateVisible(primary, max(20, cols - 6)))

      if items.len > maxShown:
        frame.add(styleDim("    (" & $(selectedIdx + 1) & "/" & $items.len & ")"))

    frame.add("")
    frame.add(styleDim(truncateVisible("  Enter select · Ctrl+S set as default · Ctrl+A toggle all · Esc cancel", cols)))
    frame.add(rule)

    beginSyncOutput()
    clearRenderedLines(renderedLines)
    for l in frame:
      stdout.write(l & "\n")
    renderedLines = frame.len
    endSyncOutput()

    let ev = readRawKey()
    case ev.kind
    of kkUp, kkCtrlP, kkShiftTab:
      if items.len > 0:
        selectedIdx = if selectedIdx == 0: items.high else: selectedIdx - 1
    of kkDown, kkTab, kkCtrlN:
      if items.len > 0:
        selectedIdx = (selectedIdx + 1) mod items.len
    of kkCtrlA:
      showAll = not showAll
      selectedIdx = 0
    of kkBackspace:
      if query.len > 0:
        let cut = prevUtf8Index(query, query.len)
        query = query[0 ..< cut]
        selectedIdx = 0
    of kkCtrlU, kkCtrlW:
      query = ""
      selectedIdx = 0
    of kkEnter, kkNewline, kkAltEnter:
      clearRenderedLines(renderedLines)
      if items.len > 0:
        return ModelPickResult(cancelled: false, chosenModel: items[selectedIdx].model, saveAsDefault: false)
      elif query.strip().len > 0:
        let (adhoc, _) = rt.providerRegistry.resolveModel(rt.cfg, query.strip(), cliApiKey = rt.cliApiKey)
        return ModelPickResult(cancelled: false, chosenModel: adhoc, saveAsDefault: false)
      return ModelPickResult(cancelled: true)
    of kkCtrlS:
      clearRenderedLines(renderedLines)
      if items.len > 0:
        return ModelPickResult(cancelled: false, chosenModel: items[selectedIdx].model, saveAsDefault: true)
      return ModelPickResult(cancelled: true)
    of kkEscape, kkCtrlC, kkCtrlD, kkEof:
      clearRenderedLines(renderedLines)
      return ModelPickResult(cancelled: true)
    of kkSpace, kkChar:
      let s = if ev.text.len > 0: ev.text elif ev.ch != '\0': $ev.ch else: ""
      if s.len > 0:
        query.add(s)
        selectedIdx = 0
    else:
      discard

# Interactive trust & runtime security prompts (suspend dock cleanly while prompting)

proc interactiveProjectTrustPrompt*(projectPath: string): Option[tuple[trusted: bool, persist: bool]] =
  if not isInteractiveTerminal():
    return none(tuple[trusted: bool, persist: bool])
  let ans = promptQuestionWidget(AskQuestionItem(
    id: "project_trust",
    header: "Security",
    question: "Trust project configuration (.pi / .agents/skills) in " & projectPath & "?",
    options: @[
      QuestionOption(label: "Trust and remember", description: "Save trust decision in ~/.pi/agent/trust.json"),
      QuestionOption(label: "Trust for this session only", description: "Load project resources once without saving"),
      QuestionOption(label: "Do not trust (Recommended for unknown repos)", description: "Skip project settings, MCP servers, prompts, and skills")
    ],
    multiSelect: false,
    allowOther: false
  ))
  if ans.cancelled or ans.selected.len == 0:
    return some((trusted: false, persist: false))
  case ans.selected[0]
  of "Trust and remember":
    some((trusted: true, persist: true))
  of "Trust for this session only":
    some((trusted: true, persist: false))
  else:
    some((trusted: false, persist: false))

proc interactiveSecurityPrompt*(action: PermissionAction, target: string, reason: string): PermissionDecision =
  if not isInteractiveTerminal():
    return pdDeny
  let shortTarget = if target.len > 100: target[0 ..< 97] & "..." else: target
  let ans = promptQuestionWidget(AskQuestionItem(
    id: "sec_prompt",
    header: "Security Guard",
    question: reason & "\n  Target: " & shortTarget,
    options: @[
      QuestionOption(label: "Allow once", description: "Permit this operation"),
      QuestionOption(label: "Deny", description: "Block this operation and inform the agent")
    ],
    multiSelect: false,
    allowOther: false
  ))
  if not ans.cancelled and ans.selected.len > 0 and ans.selected[0] == "Allow once":
    pdAllow
  else:
    pdDeny

# Print (-p) and JSONL (--mode json) non-interactive runners

proc runPrintMode*(rt: AgentRuntime, prompt: string, explicitFiles: seq[string]): int =
  ## Run one prompt to completion, printing the final assistant text (Markdown-rendered when TTY, raw when piped).
  let finalMsg = rt.runPrompt(prompt, explicitFiles)
  if finalMsg.stopReason == srError:
    stderr.writeLine("Error: " & finalMsg.errorMessage)
    return 1
  let txt = collectText(finalMsg.assistantBlocks)
  if txt.len > 0:
    if colorsActive() and isStdoutTty():
      let (cols, _) = terminalSize()
      stdout.writeLine(renderMarkdownText(txt, max(40, cols - 2)))
    else:
      stdout.writeLine(txt)
  0

proc emitAgentEventJson*(ev: AgentEvent) =
  ## Serialize and write a single structured AgentEvent line to stdout (shared by `--mode json` and `--mode rpc`).
  var rec = newJObject()
  case ev.kind
  of aekTurnStart:
    rec = %*{ "type": "turn_start", "turn": ev.turnIndex, "model": ev.modelId }
  of aekStream:
    case ev.streamEvent.kind
    of sekTextDelta:
      rec = %*{ "type": "text_delta", "delta": ev.streamEvent.textDelta }
    of sekThinkingDelta:
      rec = %*{ "type": "thinking_delta", "delta": ev.streamEvent.thinkingDelta }
    of sekError:
      rec = %*{ "type": "error", "message": ev.streamEvent.errorMsg }
    else:
      return
  of aekToolStart:
    rec = %*{ "type": "tool_execution_start", "toolCallId": ev.toolCallId, "toolName": ev.toolName, "args": ev.toolArgs }
  of aekToolEnd:
    rec = %*{
      "type": "tool_execution_end",
      "toolCallId": ev.endToolCallId,
      "toolName": ev.endToolName,
      "isError": ev.toolOutput.isError,
      "output": collectText(ev.toolOutput.content)
    }
  of aekCompaction:
    rec = %*{ "type": "compaction", "tokensBefore": ev.tokensBefore }
  of aekTurnEnd:
    rec = %*{ "type": "turn_end", "message": ev.assistantMessage.toJson() }
  of aekRunEnd:
    rec = %*{ "type": "agent_end", "turns": ev.totalTurns, "stopReason": $ev.finalMessage.stopReason }
  stdout.writeLine($rec)
  stdout.flushFile()

proc runJsonMode*(rt: AgentRuntime, prompt: string, explicitFiles: seq[string]): int =
  ## Run one prompt to completion, emitting structured JSONL agent events on stdout.
  let finalMsg = rt.runPrompt(prompt, explicitFiles, onEvent = emitAgentEventJson)
  if finalMsg.stopReason == srError: 1 else: 0

# Slash command handlers

proc helpMarkdown(): string =
  """
### Slash Commands

| Command | Description |
| :--- | :--- |
| `/model [query]` | Interactive model selector (configured providers, `Ctrl+S` save default) |
| `/thinking [level]` | Set reasoning effort (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) |
| `/copy [last\|code\|diff\|<N>]` | Copy last reply, fenced code block, or edit diff to clipboard |
| `/new` · `/resume` · `/clear` | Start new session, resume saved session, or reset root branch |
| `/tree` · `/fork` · `/export` | Switch session tree branch, fork session, or export HTML/MD/JSONL |
| `/compact` · `/session` · `/name` | Compact context history, inspect token/cost stats, or rename session |
| `/skills` · `/prompts` · `/mcp` | List Agent Skills, Markdown prompt templates, or MCP servers |
| `/tools` · `/trust` · `/reload` | Toggle tools, manage project trust, or reload `~/.pi/agent` config |
| `/login` · `/logout` · `/hotkeys` | Manage provider credentials in `auth.json` or view editor shortcuts |
| `!<cmd>` · `!!<cmd>` | Run shell command (included in context vs. excluded from context) |
"""

proc hotkeysMarkdown(): string =
  """
### Editor Shortcuts

| Keys | Action |
| :--- | :--- |
| `Enter` | Submit prompt or queue a steering message during a reply |
| `Alt+Enter` (`Ctrl+Q` on Windows) | Default shortcut to queue a follow-up after the current reply |
| `Ctrl+J` / `Shift+Enter` | Insert newline (or end line with `\`) |
| `Tab` / `Shift+Tab` | Trigger or accept `/command`, `/model`, and `@file` autocomplete |
| `↑` / `↓` · `Ctrl+P` / `Ctrl+N` | Navigate lines, autocomplete popup, or persistent history |
| `Alt+B` / `Alt+F` · `Ctrl+A` / `Ctrl+E` | Jump by word or start/end of line |
| `Ctrl+U` / `Ctrl+K` / `Ctrl+W` / `Ctrl+Y` | Kill line/word into kill-ring & yank |
| `Ctrl+_` / `Ctrl+Z` · `Ctrl+G` | Undo edit or open `$VISUAL` / `$EDITOR` |
| `PgUp` / `PgDn` · wheel | Scroll transcript history (input box stays pinned at the bottom) |
| `Shift+↑` / `Shift+↓` · `Home` / `End` | Scroll one line, jump to the oldest row, or back to the live tail |
| `Esc` / `Ctrl+C` · `Ctrl+D` | Interrupt active turn, clear input, or exit on empty prompt |
"""

proc handleCopyCommand*(rt: AgentRuntime, argStr: string, vp: DockViewport = nil) =
  proc say(s: string) =
    if not vp.isNil: vp.printAboveDock(s) else: stdout.writeLine(s)

  let sub = argStr.strip().toLowerAscii()
  if sub == "diff":
    if rt.lastDiff.len == 0:
      say("  " & styleYellow("No edit diff available to copy yet."))
      return
    let (ok, meth) = copyToClipboard(rt.lastDiff)
    if ok:
      say("  " & styleGreen("✓ Copied last diff (" & $rt.lastDiff.len & " chars via " & meth & ")"))
    else:
      say("  " & styleRed("Clipboard unavailable."))
    return

  if rt.lastAssistantText.len == 0:
    say("  " & styleYellow("No assistant reply available to copy yet."))
    return

  if sub == "code" or (sub.len > 0 and sub.allCharsInSet({'0'..'9'})):
    let blocks = extractCodeBlocks(rt.lastAssistantText)
    if blocks.len == 0:
      say("  " & styleYellow("No fenced code blocks found in the last assistant reply."))
      return
    var targetIdx = blocks.high
    if sub != "code":
      let parsedIdx = (try: parseInt(sub) except ValueError: 1) - 1
      if parsedIdx < 0 or parsedIdx >= blocks.len:
        say("  " & styleYellow("Code block index out of range (1.." & $blocks.len & ")."))
        return
      targetIdx = parsedIdx
    elif blocks.len > 1 and isInteractiveTerminal():
      if not vp.isNil: vp.suspendDock()
      var opts: seq[QuestionOption] = @[]
      for i, cb in blocks.pairs:
        let preview = cb.strip().splitLines()[0]
        opts.add(QuestionOption(
          label: "Block #" & $(i + 1) & " (" & $cb.splitLines().len & " lines)",
          description: (if preview.len > 60: preview[0 ..< 57] & "..." else: preview)
        ))
      let pick = promptQuestionWidget(AskQuestionItem(
        id: "copy_code",
        header: "Clipboard",
        question: "Which code block do you want to copy?",
        options: opts,
        multiSelect: false,
        allowOther: false
      ))
      if not vp.isNil: vp.resumeDock()
      if pick.cancelled or pick.selected.len == 0:
        return
      for i, opt in opts.pairs:
        if opt.label == pick.selected[0]:
          targetIdx = i
          break

    let (ok, meth) = copyToClipboard(blocks[targetIdx])
    if ok:
      say("  " & styleGreen("✓ Copied code block #" & $(targetIdx + 1) & " (" & $blocks[targetIdx].len & " chars via " & meth & ")"))
    else:
      say("  " & styleRed("Clipboard unavailable."))
    return

  let (ok, meth) = copyToClipboard(rt.lastAssistantText)
  if ok:
    say("  " & styleGreen("✓ Copied last assistant message (" & $rt.lastAssistantText.len & " chars via " & meth & ")"))
  else:
    say("  " & styleRed("Clipboard unavailable."))

proc applyChosenModel(rt: AgentRuntime, m: ModelConfig, thinkOpt = none(ThinkingLevel), saveDefault = false, vp: DockViewport = nil) =
  rt.switchModel(m)
  let targetThink = if thinkOpt.isSome:
    clampThinkingLevel(m, thinkOpt.get)
  else:
    clampThinkingLevel(m, rt.thinkingLevel)
  if targetThink != rt.thinkingLevel:
    rt.switchThinkingLevel(targetThink)

  var savedNote = ""
  if saveDefault:
    if saveDefaultModelInSettings(rt.cfg.agentDir, m.provider, m.id):
      rt.cfg.settings.defaultProvider = m.provider
      rt.cfg.settings.defaultModel = m.id
      savedNote = " [saved as default]"

  let msg = "  " & styleGreen("✓ Model: ") & styleBold(m.provider & "/" & m.id) &
            styleDim(" (" & m.name & ", thinking=" & $rt.thinkingLevel & ")") & styleMagenta(savedNote)
  if not vp.isNil:
    vp.ed.modelItems = buildModelAutocompleteItems(rt)
    vp.printAboveDock(msg)
  else:
    stdout.writeLine(msg)

proc handleModelSlash(rt: AgentRuntime, arg: string, vp: DockViewport) =
  let pat = arg.strip()
  if pat.len > 0:
    let (m, thinkOpt) = rt.providerRegistry.resolveModel(rt.cfg, pat, cliApiKey = rt.cliApiKey)
    applyChosenModel(rt, m, thinkOpt, saveDefault = false, vp = vp)
    return

  vp.suspendDock()
  let pick = promptModelSelector(rt)
  vp.resumeDock()
  if not pick.cancelled:
    applyChosenModel(rt, pick.chosenModel, saveDefault = pick.saveAsDefault, vp = vp)

proc reloadRuntimeResources(rt: AgentRuntime, vp: DockViewport) =
  let trusted = rt.cfg.projectTrusted
  let newCfg = loadConfigBundle(rt.cfg.cwd, rt.cfg.agentDir, projectTrusted = trusted)
  rt.cfg = newCfg
  rt.providerRegistry = newProviderRegistry(newCfg, rt.providerRegistry.transport)
  if not rt.mcpManager.isNil:
    rt.mcpManager.closeAll()
  let newToolReg = newToolRegistry(newCfg.settings.defaultTools)
  let newMcp = newMcpManager(newCfg, newToolReg, connectNow = true)
  let (newSkills, skillDiags) = discoverSkills(newCfg.cwd, newCfg.agentDir, newCfg.settings.skills, projectTrusted = trusted)
  let (newTpls, tplDiags) = discoverPromptTemplates(newCfg.cwd, newCfg.agentDir, newCfg.settings.prompts, projectTrusted = trusted)
  rt.toolRegistry = newToolReg
  rt.mcpManager = newMcp
  rt.skills = newSkills
  rt.promptTemplates = newTpls
  rt.security.mode = newCfg.settings.securityMode
  vp.ed.commands = buildSlashCommandDefs(rt)
  vp.ed.modelItems = buildModelAutocompleteItems(rt)
  vp.followUpKeys = loadFollowUpKeys(newCfg.agentDir)
  vp.ed.invalidateFileCache()
  var lines = @["  " & styleGreen("✓ Reloaded config: ") &
                $newSkills.len & " skill(s), " & $newTpls.len & " prompt template(s), " &
                $newMcp.servers.len & " MCP server(s)."]
  for d in newCfg.diagnostics & skillDiags & tplDiags & newMcp.diagnostics:
    lines.add("    " & styleYellow("! " & d))
  vp.printAboveDock(lines)

proc runAgentTurnDocked(vp: DockViewport, prompt: string, explicitFiles: openArray[string] = []) =
  ## Run an agent prompt while keeping the bottom input bar docked, animating status, and accepting live Esc / queued follow-ups.
  let rt = vp.rt
  let runAbort = newAbortFlag()
  activeRunAbort = runAbort
  vp.turnStartMs = nowUnixMs()
  var lastSpinnerTick = 0'i64

  # Wrap ask_question & security prompt so modal selectors cleanly suspend/resume the docked bar
  let origAsk = rt.askQuestion
  let origSecPrompt = rt.security.prompt
  if isInteractiveTerminal():
    rt.askQuestion = proc(questions: seq[AskQuestionItem]): seq[AskQuestionAnswer] =
      vp.suspendDock()
      exitRawTerminalMode()
      defer:
        enterRawTerminalMode()
        vp.resumeDock()
      promptAskQuestionsInteractive(questions)
    rt.security.prompt = proc(action: PermissionAction, target, reason: string): PermissionDecision =
      vp.suspendDock()
      exitRawTerminalMode()
      defer:
        enterRawTerminalMode()
        vp.resumeDock()
      interactiveSecurityPrompt(action, target, reason)

  rt.providerRegistry.onIdleTick = proc() =
    # Poll non-blocking user keys while waiting on LLM SSE stream
    while true:
      let kevOpt = pollRawKeyNonBlocking(0)
      if kevOpt.isNone:
        break
      let kev = kevOpt.get
      if kev.kind == kkEof:
        runAbort.aborted = true
        break
      if (kev.kind == kkEscape and vp.ed.acKind == ackNone) or
          (kev.kind == kkCtrlC and vp.ed.currentText().len == 0):
        runAbort.aborted = true
        vp.setWorkingStatus("Interrupting")
      else:
        let followUp = kev.kind in vp.followUpKeys
        let inputKey = if followUp: KeyEvent(kind: kkEnter) else: kev
        let outOpt = vp.handleDockKey(inputKey)
        if outOpt.isSome and outOpt.get.kind == eokSubmit and outOpt.get.text.strip().len > 0:
          if followUp:
            rt.followUpQueue.add(QueuedPrompt(text: outOpt.get.text))
          else:
            rt.steeringQueue.add(QueuedPrompt(text: outOpt.get.text))
      vp.redrawDock()

    let spinnerTick = vp.elapsedMilliseconds() div SpinnerIntervalMs
    if terminalSize() != vp.drawnSize or (vp.workingPhase.len > 0 and spinnerTick != lastSpinnerTick and not runAbort.aborted):
      lastSpinnerTick = spinnerTick
      vp.redrawDock()

  defer:
    rt.providerRegistry.onIdleTick = nil
    rt.askQuestion = origAsk
    rt.security.prompt = origSecPrompt
    activeRunAbort = nil
    vp.setWorkingStatus()
    vp.activeTailLines.setLen(0)

  discard rt.runPrompt(
    prompt,
    explicitFiles,
    onEvent = makeInteractiveEventPrinter(rt.cfg.settings.hideThinkingBlock, vp),
    abort = runAbort
  )
  vp.ed.invalidateFileCache()

proc runInteractiveRepl*(rt: AgentRuntime, initialPrompt = "", initialFiles: seq[string] = @[]): int =
  ## Start the interactive ni TUI with a persistent docked input box and live Markdown rendering.
  installCtrlCHandler()
  let keyReady = rt.providerRegistry.resolveProviderApiKey(rt.cfg, rt.currentModel.provider, rt.cliApiKey).isSome
  let interactive = isInteractiveTerminal()

  var banner: seq[string] = @[]
  banner.add(styleBold(styleCyan(NiEmoji & " ni v0.2.0")) & styleDim(" — Fast Nim coding agent (Pi config compatible)"))
  banner.add(
    styleDim("  Model     : ") & styleCyan(rt.currentModel.provider & "/" & rt.currentModel.id) &
                   styleDim(" (" & rt.currentModel.name & ")") &
                   (if keyReady: styleGreen(" ✓") else: styleYellow(" (no key — run /login " & rt.currentModel.provider & ")")))
  banner.add(
    styleDim("  Resources : ") &
                   $rt.toolRegistry.activeNames.len & " tools · " &
                   $rt.skills.len & " skills · " &
                   $rt.promptTemplates.len & " prompts · " &
                   $rt.mcpManager.servers.len & " MCP" &
                   (if rt.cfg.contextFiles.len > 0: " · " & $rt.cfg.contextFiles.len & " AGENTS.md" else: ""))
  banner.add(styleDim("  Shortcuts : /model switch · /help commands · Tab complete · Ctrl+J newline · Esc interrupt"))
  banner.add("")
  for d in rt.cfg.diagnostics & rt.mcpManager.diagnostics:
    banner.add("  " & styleYellow("! " & d))

  let ed = newInputEditor(
    workspaceRoot = rt.cfg.cwd,
    historyFile = rt.cfg.agentDir / "ni_history.jsonl",
    commands = buildSlashCommandDefs(rt),
    modelItems = buildModelAutocompleteItems(rt)
  )
  let vp = newDockViewport(rt, ed)
  if interactive:
    enterRawTerminalMode()
    if vp.fullScreen:
      enterFullScreen()
  defer:
    if interactive:
      vp.suspendDock()
      if vp.fullScreen:
        exitFullScreen()
      exitRawTerminalMode()

  vp.redrawDock(banner)
  if initialPrompt.strip().len > 0 or initialFiles.len > 0:
    let (cols, _) = terminalSize()
    if initialPrompt.strip().len > 0:
      vp.beginUserTurn(initialPrompt, cols)
    else:
      vp.redrawDock()
    runAgentTurnDocked(vp, initialPrompt, initialFiles)

  # Non-TTY fallback (e.g. scripted pipe tests)
  if not interactive:
    while true:
      let status = buildEditorStatus(rt, vp.gitBranch)
      let outcome = ed.readPromptInteractive(status)
      if outcome.kind != eokSubmit:
        break
      let trimmed = outcome.text.strip()
      if trimmed in ["/quit", "/exit", "/q"]:
        break
      if trimmed.len > 0:
        discard rt.runPrompt(outcome.text, onEvent = makeInteractiveEventPrinter(rt.cfg.settings.hideThinkingBlock))
    return 0

  # Main persistent docked TUI loop
  while true:
    let event = pollRawKeyNonBlocking(100)
    if event.isNone:
      if vp.fullScreen and terminalSize() != vp.drawnSize:
        vp.redrawDock()
      continue
    let ev = event.get
    if ev.kind == kkCtrlG:
      vp.suspendDock()
      exitRawTerminalMode()
      discard ed.handleKeyEvent(ev, allowExternalEditor = true)
      enterRawTerminalMode()
      vp.resumeDock()
      continue

    let outcomeOpt = vp.handleDockKey(ev)
    if outcomeOpt.isNone:
      sigintCount = 0
      vp.redrawDock()
      continue

    let outcome = outcomeOpt.get
    case outcome.kind
    of eokEof:
      vp.suspendDock()
      break
    of eokCancel:
      inc sigintCount
      if sigintCount >= 2:
        vp.suspendDock()
        break
      vp.printAboveDock(styleDim("  (Press Ctrl+C again or Ctrl+D to exit)"))
      continue
    of eokSubmit:
      sigintCount = 0

    let rawInput = outcome.text
    let trimmed = rawInput.strip()
    if trimmed.len == 0:
      vp.redrawDock()
      continue

    let (cols, _) = terminalSize()

    # 1. `!cmd` (in context) and `!!cmd` (excluded from context)
    if trimmed.startsWith("!") and trimmed.len > 1:
      let excludeCtx = trimmed.startsWith("!!")
      let shCmd = (if excludeCtx: trimmed[2 .. ^1] else: trimmed[1 .. ^1]).strip()
      if shCmd.len == 0:
        vp.redrawDock()
        continue
      discard vp.transcript.beginSegment(segNotice, "$ " & shCmd)
      vp.redrawDock(@["  " & styleCyan("$ " & shCmd)])
      let (exe, baseArgs) = resolveBashShell(rt.cfg.settings.shellPath)
      let runAbort = newAbortFlag()
      activeRunAbort = runAbort
      vp.turnStartMs = nowUnixMs()
      vp.setWorkingStatus("Running shell", shCmd)
      vp.redrawDock()
      let res = runProcessCapture(exe, baseArgs & @[shCmd], rt.cfg.cwd, nil, 0.0, runAbort)
      activeRunAbort = nil
      vp.setWorkingStatus()
      var outLines: seq[string] = @[]
      if res.output.len > 0:
        for ol in res.output.replace("\r\n", "\n").strip(leading = false, trailing = true).split('\n'):
          outLines.add("  " & ol)
      if res.exitCode != 0:
        outLines.add("  " & styleYellow("[exit code " & $res.exitCode & "]"))
      outLines.add("")
      vp.printAboveDock(outLines)
      if not excludeCtx:
        let trunc = truncateHead(res.output.replace("\r\n", "\n"))
        discard rt.session.appendMessage(newUserMessage(
          "<user_shell command=\"" & shCmd & "\" exit_code=\"" & $res.exitCode & "\">\n" & trunc.content & "\n</user_shell>"
        ))
      ed.invalidateFileCache()
      continue

    # 2. Slash commands (except `/skill:<name>` and matching `/<prompt-template>`, which run as agent prompts)
    if trimmed.startsWith("/") and not trimmed.startsWith("/skill:"):
      if expandPromptTemplateCommand(trimmed, rt.promptTemplates).isSome:
        vp.beginUserTurn(outcome.displayText, cols)
        runAgentTurnDocked(vp, rawInput)
        continue

      let spIdx = trimmed.find({' ', '\t', '\n'})
      let cmd = (if spIdx < 0: trimmed else: trimmed[0 ..< spIdx]).toLowerAscii()
      let arg = if spIdx < 0: "" else: trimmed[spIdx + 1 .. ^1].strip()

      case cmd
      of "/quit", "/exit", "/q":
        vp.suspendDock()
        break
      of "/help", "/?":
        vp.printAboveDock(indentLines(renderMarkdown(helpMarkdown(), max(36, cols - 4)), "  ") & @[""])
      of "/hotkeys", "/keys":
        vp.printAboveDock(indentLines(renderMarkdown(hotkeysMarkdown(), max(36, cols - 4)), "  ") & @[""])
      of "/copy":
        handleCopyCommand(rt, arg, vp)
      of "/model":
        exitRawTerminalMode()
        handleModelSlash(rt, arg, vp)
        enterRawTerminalMode()
        vp.redrawDock()
      of "/thinking":
        let availLevels = supportedThinkingLevels(rt.currentModel)
        if arg.len > 0:
          let lv = clampThinkingLevel(rt.currentModel, parseThinkingLevel(arg, rt.thinkingLevel))
          rt.switchThinkingLevel(lv)
          vp.printAboveDock("  " & styleGreen("✓ Thinking level: ") & styleBold($lv))
        else:
          vp.suspendDock()
          exitRawTerminalMode()
          var opts: seq[QuestionOption] = @[]
          for lv in availLevels:
            let curTag = if lv == rt.thinkingLevel: " [current]" else: ""
            opts.add(QuestionOption(label: $lv & curTag, description: "Set reasoning effort to " & $lv))
          let ans = promptQuestionWidget(AskQuestionItem(
            id: "thinking",
            header: "Thinking",
            question: "Choose reasoning effort level for " & rt.currentModel.id & ":",
            options: opts,
            multiSelect: false,
            allowOther: false
          ))
          enterRawTerminalMode()
          vp.resumeDock()
          if not ans.cancelled and ans.selected.len > 0:
            let rawLv = ans.selected[0].split(' ')[0]
            let lv = parseThinkingLevel(rawLv)
            rt.switchThinkingLevel(lv)
            vp.printAboveDock("  " & styleGreen("✓ Thinking level: ") & styleBold($lv))
      of "/login":
        let prov = if arg.len > 0: arg else: rt.currentModel.provider
        vp.suspendDock()
        exitRawTerminalMode()
        stdout.write("  " & styleCyan("Enter API key for '" & prov & "' (or !command / $ENV_VAR): "))
        stdout.flushFile()
        var k = ""
        if stdin.readLine(k) and k.strip().len > 0:
          saveApiKeyCredential(rt.cfg.agentDir, prov, k.strip())
          rt.cfg.auth = loadAuthFile(rt.cfg.agentDir / "auth.json", rt.cfg.diagnostics)
          ed.modelItems = buildModelAutocompleteItems(rt)
          stdout.writeLine("  " & styleGreen("✓ Saved credential for '" & prov & "' in " & (rt.cfg.agentDir / "auth.json")))
        enterRawTerminalMode()
        vp.resumeDock()
      of "/logout":
        let prov = if arg.len > 0: arg else: rt.currentModel.provider
        if removeStoredCredential(rt.cfg.agentDir, prov):
          rt.cfg.auth.del(prov)
          ed.modelItems = buildModelAutocompleteItems(rt)
          vp.printAboveDock("  " & styleGreen("✓ Removed stored credential for '" & prov & "'"))
        else:
          vp.printAboveDock("  " & styleYellow("No stored credential in auth.json for '" & prov & "'"))
      of "/skills":
        if rt.skills.len == 0:
          vp.printAboveDock("  " & styleDim("No skills discovered (~/.pi/agent/skills, ~/.agents/skills, .pi/skills)."))
        else:
          var lines: seq[string] = @[]
          for sk in rt.skills:
            let modeTag = if sk.disableModelInvocation: " [manual /skill:" & sk.name & " only]" else: ""
            lines.add("  • " & styleBold(sk.name) & styleDim(" (" & sk.source & ")" & modeTag) & " — " & sk.description)
          lines.add("")
          vp.printAboveDock(lines)
      of "/prompts":
        if rt.promptTemplates.len == 0:
          vp.printAboveDock("  " & styleDim("No prompt templates discovered (~/.pi/agent/prompts, .pi/prompts)."))
        else:
          var lines: seq[string] = @[]
          for tpl in rt.promptTemplates:
            let hintStr = if tpl.argumentHint.len > 0: " " & tpl.argumentHint else: ""
            lines.add("  • " & styleBold("/" & tpl.name) & styleCyan(hintStr) & styleDim(" (" & tpl.source & ") — ") & tpl.description)
          lines.add("")
          vp.printAboveDock(lines)
      of "/mcp":
        if arg.toLowerAscii() == "reconnect":
          reloadRuntimeResources(rt, vp)
        elif rt.mcpManager.servers.len == 0:
          vp.printAboveDock("  " & styleDim("No MCP servers configured (~/.pi/agent/mcp.json or .pi/mcp.json)."))
        else:
          var lines: seq[string] = @[]
          for sname, sess in rt.mcpManager.servers.pairs:
            let stColor = case sess.state
              of mcsConnected: styleGreen($sess.state)
              of mcsFailed: styleRed($sess.state)
              else: styleDim($sess.state)
            lines.add("  • " & styleBold(sname) & " [" & stColor & ", " & $sess.config.transportKind &
                      ", exposure=" & $sess.config.exposure & ", tools=" & $sess.remoteTools.len & "]")
            if sess.lastError.len > 0:
              lines.add("    " & styleRed("Error: " & sess.lastError))
          lines.add("")
          vp.printAboveDock(lines)
      of "/tools":
        if arg.len > 0:
          let parts = arg.split({',', ' '})
          var curList: seq[string] = @[]
          for n in rt.toolRegistry.activeNames: curList.add(n)
          let updated = applyToolListSpec(curList, parts)
          rt.toolRegistry.activeNames.clear()
          for n in updated:
            if rt.toolRegistry.tools.hasKey(n):
              rt.toolRegistry.activeNames.incl(n)
        var lines: seq[string] = @[]
        for tname, t in rt.toolRegistry.tools.pairs:
          let mark = if tname in rt.toolRegistry.activeNames: styleGreen("●") else: styleDim("○")
          lines.add("  " & mark & " " & styleBold(tname) & styleDim(" (" & $t.exposure & ") — " & t.snippet))
        lines.add("")
        vp.printAboveDock(lines)
      of "/trust":
        case arg.toLowerAscii()
        of "allow", "true", "yes":
          saveProjectTrust(rt.cfg.agentDir, rt.cfg.cwd, some(true))
          rt.cfg.projectTrusted = true
          reloadRuntimeResources(rt, vp)
          vp.printAboveDock("  " & styleGreen("✓ Project trusted and saved to trust.json."))
        of "deny", "false", "no":
          saveProjectTrust(rt.cfg.agentDir, rt.cfg.cwd, some(false))
          rt.cfg.projectTrusted = false
          reloadRuntimeResources(rt, vp)
          vp.printAboveDock("  " & styleYellow("Project marked untrusted in trust.json."))
        else:
          vp.printAboveDock("  Project trusted: " & (if rt.cfg.projectTrusted: styleGreen("yes") else: styleYellow("no")) &
                            " (security mode: " & $rt.security.mode & ")")
      of "/session":
        let u = rt.session.totalUsage
        vp.printAboveDock(@[
          "  Session ID : " & rt.session.id,
          (if rt.session.displayName.len > 0: "  Name       : " & rt.session.displayName else: "  Name       : (untitled)"),
          "  File       : " & (if rt.session.filePath.len > 0: rt.session.filePath else: "(in-memory)"),
          "  Entries    : " & $rt.session.entries.len & " (leaf: " & rt.session.leafId & ")",
          "  Tokens     : in=" & $u.inputTokens & " out=" & $u.outputTokens &
            " cacheRead=" & $u.cacheReadTokens & " total=" & $u.totalTokens &
            " ($" & formatFloat(u.costTotal, ffDecimal, 4) & ")",
          ""
        ])
      of "/name":
        if arg.len == 0:
          vp.printAboveDock("  " & styleYellow("Usage: /name <session title>"))
        else:
          rt.session.appendSessionName(arg)
          vp.printAboveDock("  " & styleGreen("✓ Session named: ") & arg)
      of "/new":
        let sessionsRoot = resolveSessionsRoot(rt.cfg)
        rt.session = newSessionManager(rt.cfg.cwd, sessionsRoot, persist = rt.session.persist)
        vp.printAboveDock("  " & styleGreen("✓ Started new session ") & styleBold(rt.session.id))
      of "/tree":
        let items = rt.session.buildSessionTreeItems()
        if items.len == 0:
          vp.printAboveDock("  " & styleDim("Session tree is empty."))
        else:
          vp.suspendDock()
          exitRawTerminalMode()
          var opts: seq[QuestionOption] = @[]
          for item in items:
            let indent = "  ".repeat(min(6, item.depth))
            let leafTag = if item.isCurrentLeaf: " ← current" elif item.isActivePath: " ●" else: ""
            opts.add(QuestionOption(label: indent & "[" & item.entryId & "] " & item.roleLabel & leafTag, description: item.preview))
          let ans = promptQuestionWidget(AskQuestionItem(
            id: "session_tree",
            header: "Session Tree",
            question: "Select an entry to branch from:",
            options: opts,
            multiSelect: false,
            allowOther: false
          ))
          enterRawTerminalMode()
          vp.resumeDock()
          if not ans.cancelled and ans.selected.len > 0:
            for i, opt in opts.pairs:
              if opt.label == ans.selected[0]:
                if rt.session.branchTo(items[i].entryId):
                  vp.printAboveDock("  " & styleGreen("✓ Switched branch leaf to ") & styleBold(items[i].entryId))
                break
      of "/fork":
        var targetId = arg.strip()
        if targetId.len == 0:
          let items = rt.session.buildSessionTreeItems()
          if items.len > 0:
            vp.suspendDock()
            exitRawTerminalMode()
            var opts = @[QuestionOption(label: "Current leaf (" & rt.session.leafId & ")", description: "Duplicate active branch")]
            var entryIds = @[rt.session.leafId]
            for item in items:
              if item.roleLabel in ["user", "assistant"]:
                opts.add(QuestionOption(label: "[" & item.entryId & "] " & item.roleLabel, description: item.preview))
                entryIds.add(item.entryId)
            let ans = promptQuestionWidget(AskQuestionItem(
              id: "fork_entry",
              header: "Fork Session",
              question: "Fork into a new session from which point?",
              options: opts,
              multiSelect: false,
              allowOther: false
            ))
            enterRawTerminalMode()
            vp.resumeDock()
            if ans.cancelled or ans.selected.len == 0:
              continue
            for i, opt in opts.pairs:
              if opt.label == ans.selected[0]:
                targetId = entryIds[i]
                break
        let forked = rt.session.forkSessionAtEntry(targetId, resolveSessionsRoot(rt.cfg))
        rt.session = forked
        vp.printAboveDock("  " & styleGreen("✓ Forked into new session ") & styleBold(forked.id))
      of "/export":
        try:
          let written = rt.session.exportSessionToFile(arg)
          vp.printAboveDock("  " & styleGreen("✓ Exported session transcript to ") & styleBold(written))
        except CatchableError as e:
          vp.printAboveDock("  " & styleRed("Failed to export session: " & e.msg))
      of "/resume":
        let sessions = listSessions(resolveSessionsRoot(rt.cfg), rt.cfg.cwd)
        if sessions.len == 0:
          vp.printAboveDock("  " & styleYellow("No saved sessions found for this workspace."))
        else:
          vp.suspendDock()
          exitRawTerminalMode()
          var opts: seq[QuestionOption] = @[]
          let cnt = min(15, sessions.len)
          for i in 0 ..< cnt:
            let s = sessions[i]
            opts.add(QuestionOption(label: s.displayName, description: s.id[0 ..< min(8, s.id.len)] & " · " & $s.messageCount & " msgs"))
          let pick = promptQuestionWidget(AskQuestionItem(
            id: "resume_session",
            header: "Sessions",
            question: "Select a session to resume:",
            options: opts,
            multiSelect: false,
            allowOther: false
          ))
          enterRawTerminalMode()
          vp.resumeDock()
          if not pick.cancelled and pick.selected.len > 0:
            for i in 0 ..< cnt:
              if opts[i].label == pick.selected[0]:
                rt.session = loadSessionFile(sessions[i].filePath)
                vp.printAboveDock("  " & styleGreen("✓ Resumed session ") & sessions[i].id)
                break
      of "/compact":
        vp.turnStartMs = nowUnixMs()
        vp.setWorkingStatus("Compacting", "summarizing older context")
        vp.redrawDock()
        let res = rt.compactSession(force = true)
        vp.setWorkingStatus()
        if res.isSome:
          vp.printAboveDock("  " & styleGreen("✓ Compacted session history."))
        else:
          vp.printAboveDock("  " & styleYellow("Nothing to compact (conversation is short or compaction failed)."))
      of "/clear":
        discard rt.session.branchTo("")
        vp.printAboveDock("  " & styleGreen("✓ Started a clean conversation branch."))
      of "/reload":
        reloadRuntimeResources(rt, vp)
      else:
        vp.printAboveDock("  " & styleYellow("Unknown command '" & cmd & "'. Type /help for available commands."))
      continue

    # 3. Normal user message or `/skill:<name>` -> render user block in the transcript + run docked agent turn
    vp.beginUserTurn(outcome.displayText, cols)
    runAgentTurnDocked(vp, rawInput)

  0
