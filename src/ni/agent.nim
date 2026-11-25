# Core multi-turn Agent runtime: @file expansion, context compaction, streaming LLM turns, and tool execution loop.

import std/[base64, json, options, os, strutils]
import ./[types, config, trust, provider, tools, skills, mcp, session, prompt]

const MaxAgentTurnsPerRun* = 64

type
  AgentEventKind* = enum
    aekTurnStart
    aekStream
    aekToolStart
    aekToolEnd
    aekCompaction
    aekTurnEnd
    aekRunEnd

  AgentEvent* = object
    case kind*: AgentEventKind
    of aekTurnStart:
      turnIndex*: int
      modelId*: string
    of aekStream:
      streamEvent*: StreamEvent
    of aekToolStart:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode
    of aekToolEnd:
      endToolCallId*: string
      endToolName*: string
      toolOutput*: ToolOutput
    of aekCompaction:
      tokensBefore*: int
      summaryText*: string
    of aekTurnEnd:
      assistantMessage*: AgentMessage
    of aekRunEnd:
      finalMessage*: AgentMessage
      totalTurns*: int

  AgentEventCallback* = proc(ev: AgentEvent) {.closure.}

  QueueMode* = enum
    qmOneAtATime = "one-at-a-time"
    qmAll = "all"

  QueuedPrompt* = object
    text*: string
    images*: seq[ContentBlock]

  AgentRuntime* = ref object
    cfg*: ConfigBundle
    providerRegistry*: ProviderRegistry
    toolRegistry*: ToolRegistry
    mcpManager*: McpManager
    skills*: seq[Skill]
    promptTemplates*: seq[PromptTemplate]
    security*: SecurityPolicy
    session*: SessionManager
    currentModel*: ModelConfig
    thinkingLevel*: ThinkingLevel
    cliApiKey*: string
    cliAppendPrompts*: seq[string]
    askQuestion*: AskQuestionCallback
    steeringQueue*: seq[QueuedPrompt]
    followUpQueue*: seq[QueuedPrompt]
    steeringMode*: QueueMode
    followUpMode*: QueueMode
    lastAssistantText*: string
    lastDiff*: string

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
        r = r[0 ..< 2000] & "\n...[truncated for summary]"
      parts.add("[ToolResult " & m.toolName & (if m.isError: " ERROR" else: "") & "]\n" & r)
    of mrSystem:
      discard
  parts.join("\n\n")

proc compactSession*(rt: AgentRuntime, force = false, onEvent: AgentEventCallback = nil, abort: AbortFlag = nil): Option[string] =
  ## Summarize older session entries when context approaches model limit or when `/compact` is invoked.
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
  let (activeMsgs, _, _) = rt.session.buildActiveContext()
  if activeMsgs.len < 4 and not force:
    return none(string)

  let estTokens = estimateContextTokens(sysPrompt, activeMsgs)
  let threshold = max(8_000, rt.currentModel.contextWindow - rt.cfg.settings.compaction.reserveTokens)
  if not force and (not rt.cfg.settings.compaction.enabled or estTokens < threshold):
    return none(string)

  let branch = rt.session.activeBranchEntries()
  if branch.len < 2:
    return none(string)

  # Determine split point keeping roughly `keepRecentTokens` of recent messages (or last 2 entries on forced compact)
  var keptTokens = 0
  var splitIdx = branch.len
  let keepBudget = if force: min(4000, rt.cfg.settings.compaction.keepRecentTokens)
                   else: rt.cfg.settings.compaction.keepRecentTokens

  for i in countdown(branch.high, 1):
    if branch[i].kind == sekMessage:
      let mt = estimateMessageTokens(branch[i].message)
      if keptTokens + mt > keepBudget and splitIdx < branch.len:
        break
      keptTokens += mt
    splitIdx = i
    # Do not split right between an assistant tool_call and its toolResult!
    if branch[i].kind == sekMessage and branch[i].message.role == mrToolResult:
      continue

  if splitIdx <= 0:
    splitIdx = max(1, branch.len - 2)
  let toSummarize = branch[0 ..< splitIdx]
  let transcript = renderTranscriptForSummary(toSummarize)
  if transcript.strip().len == 0:
    return none(string)

  let summaryPrompt = "Summarize the following coding session history concisely so another turn can continue seamlessly. Preserve: (1) user goals & constraints, (2) exact file paths read/modified and key decisions, (3) current progress, errors, and remaining next steps.\n\n<transcript>\n" & transcript & "\n</transcript>"
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
  if resp.stopReason == srError or resp.stopReason == srAborted:
    return none(string)

  let summaryText = collectText(resp.assistantBlocks).strip()
  if summaryText.len == 0:
    return none(string)

  let firstKeptId = if splitIdx < branch.len: branch[splitIdx].id else: ""
  discard rt.session.appendCompaction(summaryText, firstKeptId, estTokens)
  if not onEvent.isNil:
    onEvent(AgentEvent(kind: aekCompaction, tokensBefore: estTokens, summaryText: summaryText))
  some(summaryText)

# Main Agent Run Loop

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
  promptTemplates: seq[PromptTemplate] = @[]
): AgentRuntime =
  ## Wire together all subsystems into a ready-to-run AgentRuntime.
  var model = initialModel
  var tlevel = thinkingLevel

  # Restore session-saved model & thinking level when resuming an existing session
  let (_, savedModel, savedThinking) = session.buildActiveContext()
  if savedModel.isSome:
    let (prov, mid) = savedModel.get
    let (resolved, _) = providerRegistry.resolveModel(cfg, mid, prov, cliApiKey)
    model = resolved
  if savedThinking.isSome:
    tlevel = savedThinking.get

  AgentRuntime(
    cfg: cfg,
    providerRegistry: providerRegistry,
    toolRegistry: toolRegistry,
    mcpManager: mcpManager,
    skills: skills,
    promptTemplates: promptTemplates,
    security: security,
    session: session,
    currentModel: model,
    thinkingLevel: tlevel,
    cliApiKey: cliApiKey,
    cliAppendPrompts: cliAppendPrompts,
    askQuestion: askQuestion,
    steeringQueue: @[],
    followUpQueue: @[],
    lastAssistantText: "",
    lastDiff: ""
  )

proc switchModel*(rt: AgentRuntime, newModel: ModelConfig) =
  ## Switch active model and record ModelChangeEntry in session history.
  rt.currentModel = newModel
  rt.session.appendModelChange(newModel.provider, newModel.id)

proc switchThinkingLevel*(rt: AgentRuntime, level: ThinkingLevel) =
  ## Switch thinking level and record ThinkingLevelChangeEntry in session history.
  rt.thinkingLevel = level
  rt.session.appendThinkingChange(level)

proc appendQueuedPrompts(rt: AgentRuntime, queue: var seq[QueuedPrompt], mode: QueueMode): bool =
  if queue.len == 0:
    return false
  let count = if mode == qmAll: queue.len else: 1
  for i in 0 ..< count:
    let prompt = queue[i]
    discard rt.session.appendMessage(rt.buildUserPromptMessage(prompt.text, extraImages = prompt.images))
  if mode == qmAll:
    queue.setLen(0)
  else:
    queue.delete(0)
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
  let userMsg = rt.buildUserPromptMessage(rawPrompt, explicitFiles, extraImages)
  discard rt.session.appendMessage(userMsg)

  var turns = 0
  var lastAssistant = AgentMessage(role: mrAssistant, timestampMs: nowUnixMs(), stopReason: srStop)

  while turns < MaxAgentTurnsPerRun:
    if turnAbort.aborted:
      lastAssistant.stopReason = srAborted
      break

    inc turns
    discard rt.compactSession(force = false, onEvent = onEvent, abort = turnAbort)

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

    let (historyMsgs, _, _) = rt.session.buildActiveContext()
    let toolSchemas = rt.toolRegistry.declaredToolSchemas()

    if not onEvent.isNil:
      onEvent(AgentEvent(kind: aekTurnStart, turnIndex: turns, modelId: rt.currentModel.id))
    if turnAbort.aborted:
      lastAssistant.stopReason = srAborted
      break

    let assistantMsg = rt.providerRegistry.streamCompletion(
      cfg = rt.cfg,
      model = rt.currentModel,
      systemPrompt = sysPrompt,
      messages = historyMsgs,
      tools = toolSchemas,
      thinkingLevel = rt.thinkingLevel,
      cliApiKey = rt.cliApiKey,
      onEvent = proc(sev: StreamEvent) =
        if not onEvent.isNil:
          onEvent(AgentEvent(kind: aekStream, streamEvent: sev)),
      abort = turnAbort
    )

    lastAssistant = assistantMsg
    let txt = collectText(assistantMsg.assistantBlocks)
    if txt.strip().len > 0:
      rt.lastAssistantText = txt

    # Persist assistant turn unless completely empty error
    if assistantMsg.assistantBlocks.len > 0 or assistantMsg.stopReason == srError:
      discard rt.session.appendMessage(assistantMsg)

    if not onEvent.isNil:
      onEvent(AgentEvent(kind: aekTurnEnd, assistantMessage: assistantMsg))

    if assistantMsg.stopReason in {srError, srAborted}:
      break

    let toolCalls = collectToolCalls(assistantMsg.assistantBlocks)
    if toolCalls.len == 0:
      if turnAbort.aborted:
        lastAssistant.stopReason = srAborted
        break
      if rt.appendQueuedPrompts(rt.steeringQueue, rt.steeringMode) or
          rt.appendQueuedPrompts(rt.followUpQueue, rt.followUpMode):
        continue
      break

    let toolCtx = ToolContext(
      cwd: rt.cfg.cwd,
      settings: rt.cfg.settings,
      security: rt.security,
      askQuestion: rt.askQuestion,
      abort: turnAbort,
      sessionId: rt.session.id,
      modelId: rt.currentModel.provider & "/" & rt.currentModel.id
    )

    for tc in toolCalls:
      if turnAbort.aborted:
        let abortedOut = ToolOutput(content: @[textBlock("Tool execution cancelled by user")], isError: true)
        discard rt.session.appendMessage(newToolResultMessage(tc.id, tc.name, abortedOut))
        continue

      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekToolStart, toolCallId: tc.id, toolName: tc.name, toolArgs: tc.arguments))

      let outp = rt.toolRegistry.invokeTool(tc.name, tc.arguments, toolCtx)
      if outp.diff.len > 0:
        rt.lastDiff = outp.diff

      if not onEvent.isNil:
        onEvent(AgentEvent(kind: aekToolEnd, endToolCallId: tc.id, endToolName: tc.name, toolOutput: outp))

      discard rt.session.appendMessage(newToolResultMessage(tc.id, tc.name, outp))

    if not turnAbort.aborted:
      discard rt.appendQueuedPrompts(rt.steeringQueue, rt.steeringMode)

  if not onEvent.isNil:
    onEvent(AgentEvent(kind: aekRunEnd, finalMessage: lastAssistant, totalTurns: turns))
  lastAssistant
