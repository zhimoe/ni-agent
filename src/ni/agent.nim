# Core multi-turn Agent runtime: @file expansion, context compaction, streaming LLM turns, and tool execution loop.

import std/[base64, json, monotimes, options, os, strutils, tables, times]
import ./[types, config, trust, provider, tools, skills, mcp, session, prompt, utf8]

const MaxAgentTurnsPerRun* = 64

type
  AgentEventKind* = enum
    aekRunStart
    aekTurnStart
    aekStream
    aekMessage
    aekAssistantEnd
    aekToolStart
    aekToolUpdate
    aekToolEnd
    aekCompactionStart
    aekCompaction
    aekTurnEnd
    aekQueueUpdate
    aekRunEnd

  AgentEvent* = object
    case kind*: AgentEventKind
    of aekRunStart: discard
    of aekTurnStart:
      turnIndex*: int
      modelId*: string
    of aekStream:
      streamEvent*: StreamEvent
    of aekMessage:
      observedMessage*: AgentMessage
    of aekToolStart:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode
    of aekToolUpdate:
      updateToolCallId*: string
      updateToolName*: string
      updateToolArgs*: JsonNode
      partialOutput*: string
    of aekToolEnd:
      endToolCallId*: string
      endToolName*: string
      toolOutput*: ToolOutput
      toolDurationMs*: int64
    of aekCompactionStart, aekCompaction:
      tokensBefore*: int
      summaryText*: string
      firstKeptId*: string
      compactionReason*: string
      compactionError*: string
      compactionAborted*: bool
      estimatedTokensAfter*: int
      compactionUsage*: Usage
    of aekAssistantEnd, aekTurnEnd:
      assistantMessage*: AgentMessage
      assistantEntryId*: string
      turnToolResults*: seq[AgentMessage]
    of aekQueueUpdate:
      queuedSteering*, queuedFollowUps*: seq[string]
    of aekRunEnd:
      finalMessage*: AgentMessage
      totalTurns*: int
      runMessages*: seq[AgentMessage]

  AgentEventCallback* = proc(ev: AgentEvent) {.closure.}

  QueueMode* = enum
    qmOneAtATime = "one-at-a-time"
    qmAll = "all"

  QueuedPrompt* = object
    text*: string
    images*: seq[ContentBlock]

  RuntimeConfigOverrides* = object
    noContextFiles*, noSkills*, noPromptTemplates*: bool
    systemPrompt*: Option[string]
    securityMode*: Option[SecurityMode]
    extraSkills*, extraPromptTemplates*: seq[string]

  AgentRuntime* = ref object
    cfg*: ConfigBundle
    configOverrides*: RuntimeConfigOverrides
    providerRegistry*: ProviderRegistry
    toolRegistry*: ToolRegistry
    mcpManager*: McpManager
    toolOverrides*: seq[seq[string]]
    noTools*: bool
    noMcp*: bool
    skills*: seq[Skill]
    promptTemplates*: seq[PromptTemplate]
    security*: SecurityPolicy
    session*: SessionManager
    sessionsRoot*: string
    currentModel*: ModelConfig
    thinkingLevel*: ThinkingLevel
    cliApiKey*: string
    cliAppendPrompts*: seq[string]
    askQuestion*: AskQuestionCallback
    maxTurnsPerRun*: Positive
    steeringQueue*: seq[QueuedPrompt]
    followUpQueue*: seq[QueuedPrompt]
    steeringMode*: QueueMode
    followUpMode*: QueueMode
    lastAssistantText*: string
    lastDiff*: string

proc loadRuntimeConfig*(cwd, agentDir: string, projectTrusted: bool,
                        overrides: RuntimeConfigOverrides): ConfigBundle =
  result = loadConfigBundle(cwd, agentDir, projectTrusted, loadContext = not overrides.noContextFiles)
  if overrides.systemPrompt.isSome:
    result.customSystemPrompt = overrides.systemPrompt.get
  if overrides.securityMode.isSome:
    result.settings.securityMode = overrides.securityMode.get

proc discoverRuntimeResources*(cfg: ConfigBundle, overrides: RuntimeConfigOverrides): tuple[
    skills: seq[Skill], templates: seq[PromptTemplate], diagnostics: seq[string]] =
  let skillPaths = if overrides.noSkills: overrides.extraSkills else: cfg.settings.skills & overrides.extraSkills
  let promptPaths = if overrides.noPromptTemplates: overrides.extraPromptTemplates
    else: cfg.settings.prompts & overrides.extraPromptTemplates
  let (skills, skillDiagnostics) = discoverSkills(cfg.cwd, cfg.agentDir, skillPaths,
    projectTrusted = cfg.projectTrusted, includeDefaults = not overrides.noSkills)
  let (templates, templateDiagnostics) = discoverPromptTemplates(cfg.cwd, cfg.agentDir, promptPaths,
    projectTrusted = cfg.projectTrusted, includeDefaults = not overrides.noPromptTemplates)
  (skills, templates, skillDiagnostics & templateDiagnostics)

# Prompt preprocessing: `/skill:<name>` expansion and `@filepath` inline file/image attachments

proc detectPromptImageMime(path: string): string =
  case splitFile(path).ext.toLowerAscii()
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  else: ""

proc buildUserPromptMessage*(
  rt: AgentRuntime,
  rawPrompt: string,
  explicitFiles: openArray[string] = [],
  extraImages: openArray[ContentBlock] = []
): AgentMessage =
  ## Expand `/skill:<name>`, `/<prompt-template>`, explicit `@file` CLI args, and inline `@path` tokens into a User AgentMessage.
  var promptText = rawPrompt
  let skillExpanded = expandSkillCommand(rawPrompt, rt.skills)
  if skillExpanded.isSome:
    promptText = skillExpanded.get
  else:
    let tplExpanded = expandPromptTemplateCommand(rawPrompt, rt.promptTemplates)
    if tplExpanded.isSome:
      promptText = tplExpanded.get

  var attachmentBlocks: seq[ContentBlock] = @[]
  var attachedNotes: seq[string] = @[]

  proc attachFile(tokenPath: string): bool =
    let full = resolvePathFrom(tokenPath, rt.cfg.cwd)
    if not fileExists(full):
      return false
    let mime = detectPromptImageMime(full)
    try:
      if mime.len > 0:
        let enc = base64.encode(readFile(full))
        attachmentBlocks.add(imageBlock(enc, mime))
        attachedNotes.add("[Attached image: " & tokenPath & "]")
      else:
        let txt = stripUtf8Bom(readFile(full))
        let trunc = truncateHead(txt)
        attachedNotes.add("<file path=\"" & tokenPath.replace('\\', '/') & "\">\n" &
                          trunc.content &
                          (if trunc.truncated: "\n...[truncated]" else: "") &
                          "\n</file>")
      return true
    except CatchableError:
      return false

  for ef in explicitFiles:
    discard attachFile(ef)

  # Scan inline @path tokens (avoiding email addresses like user@example.com)
  for word in promptText.splitWhitespace():
    if word.startsWith("@") and word.len > 1:
      let candidate = word[1 .. ^1].strip(chars = {',', ';', ':', ')', ']', '"', '\''})
      if candidate.len > 0 and fileExists(resolvePathFrom(candidate, rt.cfg.cwd)):
        discard attachFile(candidate)

  var combinedText = ""
  if attachedNotes.len > 0:
    combinedText = attachedNotes.join("\n\n") & "\n\n" & promptText
  else:
    combinedText = promptText

  var allBlocks: seq[ContentBlock] = @[textBlock(combinedText)]
  for img in attachmentBlocks:
    allBlocks.add(img)
  for img in extraImages:
    allBlocks.add(img)
  newUserBlocksMessage(allBlocks)

# Token estimation & automatic/manual context compaction

proc estimateMessageTokens*(msg: AgentMessage): int =
  ## Fast heuristic (~4 chars per token) used for compaction threshold checks.
  var chars = 16
  case msg.role
  of mrSystem:
    chars += msg.systemContent.len
  of mrUser:
    for b in msg.userBlocks:
      if b.kind == ckText: chars += b.text.len
      elif b.kind == ckImage: chars += 1200
  of mrAssistant:
    for b in msg.assistantBlocks:
      case b.kind
      of ckText: chars += b.text.len
      of ckThinking: chars += b.thinking.len
      of ckToolCall: chars += b.name.len + (if b.arguments.isNil: 2 else: ($b.arguments).len)
      of ckImage: chars += 1200
  of mrToolResult:
    for b in msg.resultBlocks:
      if b.kind == ckText: chars += b.text.len
      elif b.kind == ckImage: chars += 1200
  max(1, chars div 4)

proc estimateContextTokens*(systemPrompt: string, messages: openArray[AgentMessage]): int =
  result = max(1, systemPrompt.len div 4)
  for m in messages:
    result += estimateMessageTokens(m)

proc renderTranscriptForSummary(entries: openArray[SessionEntry]): string =
  var parts: seq[string] = @[]
  for e in entries:
    if e.kind != sekMessage:
      continue
    let m = e.message
    case m.role
    of mrUser:
      parts.add("[User]\n" & collectText(m.userBlocks))
    of mrAssistant:
      let txt = collectText(m.assistantBlocks)
      let tcs = collectToolCalls(m.assistantBlocks)
      var line = "[Assistant]"
      if txt.len > 0: line.add("\n" & txt)
      for tc in tcs:
        line.add("\nTool call: " & tc.name & "(" & (if tc.arguments.isNil: "{}" else: $tc.arguments) & ")")
      parts.add(line)
    of mrToolResult:
      var r = collectText(m.resultBlocks)
      if r.len > 2000:
        r = r[0 ..< utf8BoundaryBefore(r, 2000)] & "\n...[truncated for summary]"
      parts.add("[ToolResult " & m.toolName & (if m.isError: " ERROR" else: "") & "]\n" & r)
    of mrSystem:
      discard
  parts.join("\n\n")

proc runtimeSystemPrompt*(rt: AgentRuntime): string =
  buildSystemPrompt(PromptBuildInput(
    cwd: rt.cfg.cwd,
    customSystemPrompt: rt.cfg.customSystemPrompt,
    appendSystemPrompt: rt.cfg.appendSystemPrompt,
    cliAppendPrompts: rt.cliAppendPrompts,
    contextFiles: rt.cfg.contextFiles,
    toolRegistry: rt.toolRegistry,
    skills: rt.skills,
    mcpManager: rt.mcpManager
  ))

proc compactSession*(rt: AgentRuntime, force = false, onEvent: AgentEventCallback = nil,
                     abort: AbortFlag = nil, overflow = false, customInstructions = ""): Option[string] =
  ## Summarize older context, keeping each assistant call and its tool results together.
  let (activeMsgs, _, _) = rt.session.buildActiveContext()
  if activeMsgs.len < 2 or (not force and not rt.cfg.settings.compaction.enabled):
    return none(string)

  let estTokens = estimateContextTokens(rt.runtimeSystemPrompt(), activeMsgs)
  let threshold = max(8_000, rt.currentModel.contextWindow - rt.cfg.settings.compaction.reserveTokens)
  if not force and not overflow and estTokens < threshold:
    return none(string)

  let branch = rt.session.activeBranchEntries()
  var firstActive = 0
  var priorSummary = ""
  for i in countdown(branch.high, 0):
    if branch[i].kind == sekCompaction:
      let previous = branch[i]
      priorSummary = previous.summary
      firstActive = i + 1
      if previous.firstKeptEntryId != previous.id:
        for j in 0 ..< i:
          if branch[j].id == previous.firstKeptEntryId:
            firstActive = j
            break
      break

  var entries: seq[SessionEntry]
  var starts: seq[int]
  for i in firstActive ..< branch.len:
    let entry = branch[i]
    if entry.kind != sekMessage or entry.message.role == mrSystem:
      continue
    if entry.message.role != mrToolResult:
      starts.add(entries.len)
    entries.add(entry)
  if starts.len < 2:
    return none(string)
  let keepBudget = if force: min(4000, rt.cfg.settings.compaction.keepRecentTokens)
    elif overflow: min(rt.cfg.settings.compaction.keepRecentTokens, max(1, estTokens div 4))
    else: rt.cfg.settings.compaction.keepRecentTokens
  var splitIdx = starts[^1]
  var keptTokens = 0
  var boundary = entries.len
  for group in countdown(starts.high, (if force or overflow: 1 else: 0)):
    let start = starts[group]
    var tokens = 0
    for i in start ..< boundary:
      tokens += estimateMessageTokens(entries[i].message)
    if group < starts.high and keptTokens + tokens > keepBudget:
      break
    keptTokens += tokens
    splitIdx = start
    boundary = start
  if splitIdx == 0:
    return none(string)
  var transcript = renderTranscriptForSummary(entries[0 ..< splitIdx])
  if priorSummary.len > 0:
    transcript = "[Earlier summary]\n" & priorSummary & "\n\n" & transcript
  if transcript.strip().len == 0:
    return none(string)

  let reason = if overflow: "overflow" elif force: "manual" else: "threshold"
  if not onEvent.isNil:
    onEvent(AgentEvent(kind: aekCompactionStart, compactionReason: reason))
  let extra = if customInstructions.len > 0: "\n\nUser summary instructions:\n" & customInstructions else: ""
  let summaryPrompt = "Summarize the following coding session history concisely so another turn can continue seamlessly. Preserve: (1) user goals & constraints, (2) exact file paths read/modified and key decisions, (3) current progress, errors, and remaining next steps." & extra & "\n\n<transcript>\n" & transcript & "\n</transcript>"
  let resp = rt.providerRegistry.streamCompletion(
    cfg = rt.cfg,
    model = rt.currentModel,
    systemPrompt = "You summarize coding agent transcripts accurately and concisely.",
    messages = @[newUserMessage(summaryPrompt)],
    tools = @[],
    thinkingLevel = tlOff,
    cliApiKey = rt.cliApiKey,
    onEvent = nil,
    abort = abort
  )
  let summaryText = collectText(resp.assistantBlocks).strip()
  if resp.stopReason in {srError, srAborted, srLength} or summaryText.len == 0:
    if not onEvent.isNil:
      onEvent(AgentEvent(kind: aekCompaction, compactionReason: reason, compactionAborted: resp.stopReason == srAborted,
        compactionError: resp.errorMessage))
    return none(string)

  let firstKeptId = entries[splitIdx].id
  discard rt.session.appendCompaction(summaryText, firstKeptId, estTokens)
  if not onEvent.isNil:
    let (kept, _, _) = rt.session.buildActiveContext()
    onEvent(AgentEvent(kind: aekCompaction, tokensBefore: estTokens, summaryText: summaryText,
      firstKeptId: firstKeptId, compactionReason: reason,
      estimatedTokensAfter: estimateContextTokens(rt.runtimeSystemPrompt(), kept), compactionUsage: resp.usage))
  some(summaryText)

proc contextOverflow(msg: AgentMessage): bool =
  if msg.stopReason == srLength:
    return true
  if msg.stopReason != srError:
    return false
  let detail = msg.errorMessage.toLowerAscii()
  for phrase in ["context_length_exceeded", "context window", "context length", "context limit",
                 "prompt is too long", "input is too long", "too many input tokens", "input token count", "context overflow"]:
    if phrase in detail:
      return true
  false

# Main Agent Run Loop

proc restoreSessionState*(rt: AgentRuntime, keepModel = false, keepThinking = false) =
  let (_, selectedModel, selectedThinking) = rt.session.buildActiveContext()
  var savedModel = selectedModel
  var savedThinking = selectedThinking
  rt.lastAssistantText = ""
  rt.lastDiff = ""
  let entries = rt.session.activeBranchEntries()
  for i in countdown(entries.high, 0):
    if entries[i].kind != sekMessage: continue
    let msg = entries[i].message
    if msg.role == mrAssistant:
      if savedModel.isNone and msg.provider.len > 0 and msg.model.len > 0:
        savedModel = some((provider: msg.provider, modelId: msg.model))
      if savedThinking.isNone and msg.model.len > 0:
        savedThinking = some(msg.thinkingLevel)
      if rt.lastAssistantText.len == 0:
        rt.lastAssistantText = collectText(msg.assistantBlocks)
    elif msg.role == mrToolResult and rt.lastDiff.len == 0:
      rt.lastDiff = msg.diff
  if not keepModel and savedModel.isSome:
    let (provider, id) = savedModel.get
    if rt.providerRegistry.providers.hasKey(provider):
      for model in rt.providerRegistry.providers[provider].models:
        if model.id == id:
          rt.currentModel = model
          break
  if not keepThinking:
    rt.thinkingLevel = savedThinking.get(rt.thinkingLevel)
  rt.thinkingLevel = clampThinkingLevel(rt.currentModel, rt.thinkingLevel)

proc switchSession*(rt: AgentRuntime, session: SessionManager) =
  if rt.session != session:
    rt.session.close()
    rt.session = session
  rt.restoreSessionState()

proc newAgentRuntime*(
  cfg: ConfigBundle,
  providerRegistry: ProviderRegistry,
  toolRegistry: ToolRegistry,
  mcpManager: McpManager,
  skills: seq[Skill],
  security: SecurityPolicy,
  session: SessionManager,
  initialModel: ModelConfig,
  thinkingLevel: ThinkingLevel,
  cliApiKey = "",
  cliAppendPrompts: seq[string] = @[],
  askQuestion: AskQuestionCallback = nil,
  promptTemplates: seq[PromptTemplate] = @[],
  keepModel = false,
  keepThinking = false,
  maxTurnsPerRun: Positive = MaxAgentTurnsPerRun
): AgentRuntime =
  ## Wire together all subsystems into a ready-to-run AgentRuntime.
  result = AgentRuntime(
    cfg: cfg,
    providerRegistry: providerRegistry,
    toolRegistry: toolRegistry,
    mcpManager: mcpManager,
    skills: skills,
    promptTemplates: promptTemplates,
    security: security,
    session: session,
    sessionsRoot: resolveSessionsRoot(cfg),
    currentModel: initialModel,
    thinkingLevel: thinkingLevel,
    cliApiKey: cliApiKey,
    cliAppendPrompts: cliAppendPrompts,
    askQuestion: askQuestion,
    maxTurnsPerRun: maxTurnsPerRun,
    steeringQueue: @[],
    followUpQueue: @[],
    lastAssistantText: "",
    lastDiff: ""
  )
  result.restoreSessionState(keepModel, keepThinking)

proc switchModel*(rt: AgentRuntime, newModel: ModelConfig) =
  ## Switch active model and record ModelChangeEntry in session history.
  rt.currentModel = newModel
  rt.session.appendModelChange(newModel.provider, newModel.id)

proc switchThinkingLevel*(rt: AgentRuntime, level: ThinkingLevel) =
  ## Switch thinking level and record ThinkingLevelChangeEntry in session history.
  rt.thinkingLevel = level
  rt.session.appendThinkingChange(level)

proc emitQueueUpdate*(rt: AgentRuntime, onEvent: AgentEventCallback) =
  if not onEvent.isNil:
    var ev = AgentEvent(kind: aekQueueUpdate)
    for prompt in rt.steeringQueue: ev.queuedSteering.add(prompt.text)
    for prompt in rt.followUpQueue: ev.queuedFollowUps.add(prompt.text)
    onEvent(ev)

proc appendObservedMessage(rt: AgentRuntime, msg: AgentMessage, onEvent: AgentEventCallback) =
  discard rt.session.appendMessage(msg)
  if not onEvent.isNil:
    onEvent(AgentEvent(kind: aekMessage, observedMessage: msg))

proc appendQueuedPrompts(rt: AgentRuntime, queue: var seq[QueuedPrompt], mode: QueueMode,
                         onEvent: AgentEventCallback): bool =
  if queue.len == 0:
    return false
  let count = if mode == qmAll: queue.len else: 1
  for i in 0 ..< count:
    let prompt = queue[i]
    rt.appendObservedMessage(rt.buildUserPromptMessage(prompt.text, extraImages = prompt.images), onEvent)
  if mode == qmAll:
    queue.setLen(0)
  else:
    queue.delete(0)
  rt.emitQueueUpdate(onEvent)
  true

proc runPrompt*(
  rt: AgentRuntime,
  rawPrompt: string,
  explicitFiles: openArray[string] = [],
  onEvent: AgentEventCallback = nil,
  abort: AbortFlag = nil,
  extraImages: openArray[ContentBlock] = []
): AgentMessage =
  ## Submit a user prompt and run the agent tool-calling loop to completion.
  let turnAbort = if abort.isNil: newAbortFlag() else: abort
  let previousIdle = turnAbort.onIdle
  if previousIdle.isNil:
    turnAbort.onIdle = rt.providerRegistry.onIdleTick
  defer: turnAbort.onIdle = previousIdle
  let firstNewEntry = rt.session.entries.len
  if not onEvent.isNil:
    onEvent(AgentEvent(kind: aekRunStart))
  let userMsg = rt.buildUserPromptMessage(rawPrompt, explicitFiles, extraImages)
  rt.appendObservedMessage(userMsg, onEvent)

  var turns = 0
  var lastAssistant = AgentMessage(role: mrAssistant, timestampMs: nowUnixMs(), stopReason: srStop)

  while true:
    if turnAbort.aborted:
      lastAssistant.stopReason = srAborted
      break
    if turns >= rt.maxTurnsPerRun:
      lastAssistant.stopReason = srTurnLimit
      break

    inc turns
    discard rt.compactSession(force = false, onEvent = onEvent, abort = turnAbort)

    let sysPrompt = rt.runtimeSystemPrompt()
    let toolSchemas = rt.toolRegistry.declaredToolSchemas()

    if turnAbort.aborted:
      lastAssistant.stopReason = srAborted
      break

    var assistantMsg: AgentMessage
    for attempt in 0..1:
      let (historyMsgs, _, _) = rt.session.buildActiveContext()
      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekTurnStart, turnIndex: turns, modelId: rt.currentModel.id))
      assistantMsg = rt.providerRegistry.streamCompletion(
        cfg = rt.cfg, model = rt.currentModel, systemPrompt = sysPrompt, messages = historyMsgs,
        tools = toolSchemas, thinkingLevel = rt.thinkingLevel, cliApiKey = rt.cliApiKey,
        onEvent = proc(sev: StreamEvent) =
          if not onEvent.isNil:
            onEvent(AgentEvent(kind: aekStream, streamEvent: sev)),
        abort = turnAbort)
      if attempt == 0 and not turnAbort.aborted and contextOverflow(assistantMsg) and
          rt.compactSession(onEvent = onEvent, abort = turnAbort, overflow = true).isSome:
        if not onEvent.isNil:
          onEvent(AgentEvent(kind: aekAssistantEnd, assistantMessage: assistantMsg))
        continue
      break

    if turnAbort.aborted:
      assistantMsg.stopReason = srAborted
    if assistantMsg.stopReason in {srLength, srError, srAborted}:
      var complete: seq[ContentBlock]
      for blockItem in assistantMsg.assistantBlocks:
        if blockItem.kind != ckToolCall: complete.add(blockItem)
      assistantMsg.assistantBlocks = complete

    lastAssistant = assistantMsg
    let txt = collectText(assistantMsg.assistantBlocks)
    if txt.strip().len > 0:
      rt.lastAssistantText = txt

    # Persist assistant turn unless completely empty error
    let assistantEntryId = if assistantMsg.assistantBlocks.len > 0 or assistantMsg.stopReason == srError:
        rt.session.appendMessage(assistantMsg)
      else: ""

    if not onEvent.isNil:
      onEvent(AgentEvent(kind: aekAssistantEnd, assistantMessage: assistantMsg, assistantEntryId: assistantEntryId))

    if assistantMsg.stopReason in {srError, srAborted, srLength}:
      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekTurnEnd, assistantMessage: assistantMsg))
      break

    let toolCalls = collectToolCalls(assistantMsg.assistantBlocks)
    if toolCalls.len == 0:
      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekTurnEnd, assistantMessage: assistantMsg))
      if turnAbort.aborted:
        lastAssistant.stopReason = srAborted
        break
      if rt.steeringQueue.len == 0 and rt.followUpQueue.len == 0:
        break
      if turns < rt.maxTurnsPerRun:
        discard rt.appendQueuedPrompts(rt.steeringQueue, rt.steeringMode, onEvent) or
          rt.appendQueuedPrompts(rt.followUpQueue, rt.followUpMode, onEvent)
      continue

    let toolCtx = ToolContext(
      cwd: rt.cfg.cwd,
      settings: rt.cfg.settings,
      security: rt.security,
      askQuestion: rt.askQuestion,
      abort: turnAbort,
      sessionId: rt.session.id,
      modelId: rt.currentModel.provider & "/" & rt.currentModel.id
    )

    var toolResults: seq[AgentMessage]
    for tc in toolCalls:
      if turnAbort.aborted:
        let abortedOut = ToolOutput(content: @[textBlock("Tool execution cancelled by user")], isError: true)
        let toolMessage = newToolResultMessage(tc.id, tc.name, abortedOut)
        toolResults.add(toolMessage)
        rt.appendObservedMessage(toolMessage, onEvent)
        continue

      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekToolStart, toolCallId: tc.id, toolName: tc.name, toolArgs: tc.arguments))
        let id = tc.id
        let name = tc.name
        let args = tc.arguments
        var partial = ""
        toolCtx.onOutput = proc(delta: string) =
          if partial.len < DefaultMaxBytes:
            partial.add(delta[0 ..< utf8BoundaryBefore(delta, min(delta.len, DefaultMaxBytes - partial.len))])
            onEvent(AgentEvent(kind: aekToolUpdate, updateToolCallId: id, updateToolName: name,
              updateToolArgs: args, partialOutput: partial))

      let toolStarted = getMonoTime()
      let outp = rt.toolRegistry.invokeTool(tc.name, tc.arguments, toolCtx)
      if outp.diff.len > 0:
        rt.lastDiff = outp.diff

      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekToolEnd, endToolCallId: tc.id, endToolName: tc.name, toolOutput: outp,
          toolDurationMs: (getMonoTime() - toolStarted).inMilliseconds))

      let toolMessage = newToolResultMessage(tc.id, tc.name, outp)
      toolResults.add(toolMessage)
      rt.appendObservedMessage(toolMessage, onEvent)

    if not onEvent.isNil:
      onEvent(AgentEvent(kind: aekTurnEnd, assistantMessage: assistantMsg, turnToolResults: toolResults))
    if not turnAbort.aborted and turns < rt.maxTurnsPerRun:
      discard rt.appendQueuedPrompts(rt.steeringQueue, rt.steeringMode, onEvent)

  if turnAbort.aborted:
    lastAssistant.stopReason = srAborted
  if not onEvent.isNil:
    var messages: seq[AgentMessage]
    for i in firstNewEntry ..< rt.session.entries.len:
      let entry = rt.session.entries[i]
      if entry.kind == sekMessage: messages.add(entry.message)
    onEvent(AgentEvent(kind: aekRunEnd, finalMessage: lastAssistant, totalTurns: turns, runMessages: messages))
  lastAssistant
