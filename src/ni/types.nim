# Core domain types, tagged unions, and JSON wire serialization for ni.

import std/[json, options, tables, times, strutils]

type
  ThinkingLevel* = enum
    tlOff = "off"
    tlMinimal = "minimal"
    tlLow = "low"
    tlMedium = "medium"
    tlHigh = "high"
    tlXHigh = "xhigh"
    tlMax = "max"

  StopReason* = enum
    srStop = "stop"
    srLength = "length"
    srToolUse = "toolUse"
    srError = "error"
    srAborted = "aborted"
    srTurnLimit = "turnLimit"

  ContentKind* = enum
    ckText
    ckThinking
    ckToolCall
    ckImage

  ContentBlock* = object
    case kind*: ContentKind
    of ckText:
      text*: string
      textSignature*: string
    of ckThinking:
      thinking*: string
      thinkingSignature*: string
    of ckToolCall:
      id*: string
      name*: string
      arguments*: JsonNode
      thoughtSignature*: string
    of ckImage:
      data*: string
      mimeType*: string

  Usage* = object
    inputTokens*: int
    outputTokens*: int
    cacheReadTokens*: int
    cacheWriteTokens*: int
    totalTokens*: int
    costTotal*: float

  MessageRole* = enum
    mrSystem = "system"
    mrUser = "user"
    mrAssistant = "assistant"
    mrToolResult = "toolResult"

  AgentMessage* = object
    timestampMs*: int64
    case role*: MessageRole
    of mrSystem:
      systemContent*: string
      sections*: OrderedTable[string, string]
    of mrUser:
      userBlocks*: seq[ContentBlock]
    of mrAssistant:
      assistantBlocks*: seq[ContentBlock]
      api*: string
      provider*: string
      model*: string
      thinkingLevel*: ThinkingLevel
      usage*: Usage
      stopReason*: StopReason
      errorMessage*: string
    of mrToolResult:
      toolCallId*: string
      toolName*: string
      resultBlocks*: seq[ContentBlock]
      isError*: bool
      diff*: string
      fullOutputPath*: string

  ToolExposure* = enum
    teDirect = "direct"
    teDeferred = "deferred"
    teCodemode = "codemode"
    teHidden = "hidden"

  ToolOutput* = object
    content*: seq[ContentBlock]
    isError*: bool
    diff*: string
    fullOutputPath*: string
    activatedTools*: seq[string]

  QuestionOption* = object
    label*: string
    description*: string

  AskQuestionItem* = object
    id*: string
    header*: string
    question*: string
    options*: seq[QuestionOption]
    multiSelect*: bool
    allowOther*: bool

  AskQuestionAnswer* = object
    id*: string
    question*: string
    selected*: seq[string]
    customText*: string
    cancelled*: bool

  AskQuestionCallback* = proc(questions: seq[AskQuestionItem]): seq[AskQuestionAnswer] {.closure.}

  SecurityMode* = enum
    smBalanced = "balanced"
    smStrict = "strict"
    smPermissive = "permissive"

  PermissionAction* = enum
    paFileWrite = "file_write"
    paFileEdit = "file_edit"
    paSensitiveFile = "sensitive_file"
    paOutsideWorkspace = "outside_workspace"
    paShellCommand = "shell_command"
    paMcpTool = "mcp_tool"

  PermissionDecision* = enum
    pdAllow
    pdDeny

  PermissionPromptCallback* = proc(action: PermissionAction, target: string, reason: string): PermissionDecision {.closure.}

  AbortFlag* = ref object
    aborted*: bool
    retrying*: bool
    onIdle*: proc() {.closure.}

  StreamEventKind* = enum
    sekStart
    sekThinkingDelta
    sekTextDelta
    sekToolCallStart
    sekToolCallDelta
    sekToolCallEnd
    sekDone
    sekError
    sekRetryStart
    sekRetryEnd

  StreamEvent* = object
    case kind*: StreamEventKind
    of sekStart:
      modelId*: string
    of sekThinkingDelta:
      thinkingDelta*: string
    of sekTextDelta:
      textDelta*: string
    of sekToolCallStart:
      callIndex*: int
      callId*: string
      callName*: string
    of sekToolCallDelta:
      deltaIndex*: int
      argumentsDelta*: string
    of sekToolCallEnd:
      endIndex*: int
      finishedCall*: ContentBlock
    of sekDone:
      stopReason*: StopReason
      usage*: Usage
    of sekError:
      errorMsg*: string
    of sekRetryStart, sekRetryEnd:
      retryAttempt*: int
      retryLimit*: int
      retryDelayMs*: int
      retryError*: string

  StreamCallback* = proc(ev: StreamEvent) {.closure.}

# Timestamp helpers

proc nowUnixMs*(): int64 =
  ## Current wall-clock time in Unix milliseconds.
  let t = getTime()
  t.toUnix() * 1000 + (t.nanosecond div 1_000_000)

proc nowIsoUtc*(): string =
  ## Current UTC timestamp formatted as ISO-8601.
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc newAbortFlag*(): AbortFlag =
  ## Allocate a fresh cancellation flag shared across one agent turn.
  AbortFlag(aborted: false)

proc pollAbort*(abort: AbortFlag): bool =
  if abort.isNil:
    return false
  if not abort.aborted and not abort.onIdle.isNil:
    abort.onIdle()
  abort.aborted

# ContentBlock constructors

proc textBlock*(text: string, signature = ""): ContentBlock =
  ## Construct a plain text content block (with optional Gemini thoughtSignature).
  ContentBlock(kind: ckText, text: text, textSignature: signature)

proc thinkingBlock*(thinking: string, signature = "reasoning_content"): ContentBlock =
  ## Construct a reasoning/thinking content block.
  ContentBlock(kind: ckThinking, thinking: thinking, thinkingSignature: signature)

proc toolCallBlock*(id, name: string, arguments: JsonNode, thoughtSignature = ""): ContentBlock =
  ## Construct a structured tool-call block (with optional Gemini thoughtSignature).
  let args = if arguments.isNil: newJObject() else: arguments
  ContentBlock(kind: ckToolCall, id: id, name: name, arguments: args, thoughtSignature: thoughtSignature)

proc imageBlock*(data, mimeType: string): ContentBlock =
  ## Construct a base64 image block.
  ContentBlock(kind: ckImage, data: data, mimeType: mimeType)

# Message constructors and helpers

proc newUserMessage*(text: string): AgentMessage =
  ## Construct a user message containing a single text block.
  AgentMessage(
    role: mrUser,
    timestampMs: nowUnixMs(),
    userBlocks: @[textBlock(text)]
  )

proc newUserBlocksMessage*(blocks: seq[ContentBlock]): AgentMessage =
  ## Construct a user message with multiple content blocks (e.g. @file + text).
  AgentMessage(
    role: mrUser,
    timestampMs: nowUnixMs(),
    userBlocks: blocks
  )

proc newToolResultMessage*(toolCallId, toolName: string, output: ToolOutput): AgentMessage =
  ## Construct a tool-result message from a completed ToolOutput.
  AgentMessage(
    role: mrToolResult,
    timestampMs: nowUnixMs(),
    toolCallId: toolCallId,
    toolName: toolName,
    resultBlocks: if output.content.len > 0: output.content else: @[textBlock("(no tool output)")],
    isError: output.isError,
    diff: output.diff,
    fullOutputPath: output.fullOutputPath
  )

proc collectText*(blocks: openArray[ContentBlock]): string =
  ## Concatenate all ckText blocks with newlines.
  var parts: seq[string] = @[]
  for b in blocks:
    if b.kind == ckText and b.text.len > 0:
      parts.add(b.text)
  parts.join("\n")

proc collectThinking*(blocks: openArray[ContentBlock]): string =
  ## Concatenate all ckThinking blocks.
  var parts: seq[string] = @[]
  for b in blocks:
    if b.kind == ckThinking and b.thinking.len > 0:
      parts.add(b.thinking)
  parts.join("\n")

proc collectToolCalls*(blocks: openArray[ContentBlock]): seq[ContentBlock] =
  ## Extract all ckToolCall blocks in order.
  for b in blocks:
    if b.kind == ckToolCall:
      result.add(b)

proc parseThinkingLevel*(raw: string, fallback = tlMedium): ThinkingLevel =
  ## Parse a Pi thinking level string case-insensitively.
  case raw.strip().toLowerAscii()
  of "off", "none": tlOff
  of "minimal": tlMinimal
  of "low": tlLow
  of "medium": tlMedium
  of "high": tlHigh
  of "xhigh": tlXHigh
  of "max": tlMax
  else: fallback

proc parseToolExposure*(raw: string, fallback = teCodemode): ToolExposure =
  ## Parse an MCP exposure setting string (accepting codemode-deferred alias).
  case raw.strip().toLowerAscii()
  of "direct": teDirect
  of "deferred": teDeferred
  of "codemode", "codemode-deferred": teCodemode
  of "hidden": teHidden
  else: fallback

# Pi v3 JSON serialization for ContentBlock, Usage, and AgentMessage

proc toJson*(b: ContentBlock): JsonNode =
  ## Serialize a ContentBlock to Pi's session JSON format.
  case b.kind
  of ckText:
    var obj = %*{ "type": "text", "text": b.text }
    if b.textSignature.len > 0:
      obj["textSignature"] = %b.textSignature
    obj
  of ckThinking:
    var obj = %*{ "type": "thinking", "thinking": b.thinking }
    if b.thinkingSignature.len > 0:
      obj["thinkingSignature"] = %b.thinkingSignature
    obj
  of ckToolCall:
    var obj = %*{
      "type": "toolCall",
      "id": b.id,
      "name": b.name,
      "arguments": (if b.arguments.isNil: newJObject() else: b.arguments)
    }
    if b.thoughtSignature.len > 0:
      obj["thoughtSignature"] = %b.thoughtSignature
    obj
  of ckImage:
    %*{ "type": "image", "data": b.data, "mimeType": b.mimeType }

proc parseContentBlock*(node: JsonNode): Option[ContentBlock] =
  ## Parse a ContentBlock from a JSON object at the session/wire boundary.
  if node.isNil or node.kind != JObject:
    return none(ContentBlock)
  let t = node{"type"}.getStr("")
  case t
  of "text":
    some(textBlock(node{"text"}.getStr(""), node{"textSignature"}.getStr("")))
  of "thinking":
    some(thinkingBlock(node{"thinking"}.getStr(""), node{"thinkingSignature"}.getStr("reasoning_content")))
  of "toolCall":
    let args = if node.hasKey("arguments") and node["arguments"].kind == JObject:
      node["arguments"]
    else:
      newJObject()
    some(toolCallBlock(node{"id"}.getStr(""), node{"name"}.getStr(""), args, node{"thoughtSignature"}.getStr("")))
  of "image":
    some(imageBlock(node{"data"}.getStr(""), node{"mimeType"}.getStr("image/png")))
  else:
    none(ContentBlock)

proc toJson*(u: Usage): JsonNode =
  ## Serialize token and cost usage compatible with Pi v3 sessions.
  %*{
    "input": u.inputTokens,
    "output": u.outputTokens,
    "cacheRead": u.cacheReadTokens,
    "cacheWrite": u.cacheWriteTokens,
    "totalTokens": u.totalTokens,
    "cost": {
      "total": u.costTotal
    }
  }

proc parseUsage*(node: JsonNode): Usage =
  ## Parse Usage from Pi session JSON.
  if node.isNil or node.kind != JObject:
    return Usage()
  result.inputTokens = node{"input"}.getInt(0)
  result.outputTokens = node{"output"}.getInt(0)
  result.cacheReadTokens = node{"cacheRead"}.getInt(0)
  result.cacheWriteTokens = node{"cacheWrite"}.getInt(0)
  result.totalTokens = node{"totalTokens"}.getInt(result.inputTokens + result.outputTokens)
  if node.hasKey("cost") and node["cost"].kind == JObject:
    result.costTotal = node["cost"]{"total"}.getFloat(0.0)

proc toJson*(msg: AgentMessage): JsonNode =
  ## Serialize an AgentMessage to Pi v3 session message format.
  case msg.role
  of mrSystem:
    var secObj = newJObject()
    for k, v in msg.sections.pairs:
      secObj[k] = %v
    result = %*{
      "role": "system",
      "content": msg.systemContent,
      "sections": secObj,
      "timestamp": msg.timestampMs
    }
  of mrUser:
    if msg.userBlocks.len == 1 and msg.userBlocks[0].kind == ckText:
      result = %*{
        "role": "user",
        "content": msg.userBlocks[0].text,
        "timestamp": msg.timestampMs
      }
    else:
      var arr = newJArray()
      for b in msg.userBlocks:
        arr.add(b.toJson())
      result = %*{
        "role": "user",
        "content": arr,
        "timestamp": msg.timestampMs
      }
  of mrAssistant:
    var arr = newJArray()
    for b in msg.assistantBlocks:
      arr.add(b.toJson())
    result = %*{
      "role": "assistant",
      "content": arr,
      "api": msg.api,
      "provider": msg.provider,
      "model": msg.model,
      "thinkingLevel": $msg.thinkingLevel,
      "usage": msg.usage.toJson(),
      "stopReason": $msg.stopReason,
      "timestamp": msg.timestampMs
    }
    if msg.errorMessage.len > 0:
      result["errorMessage"] = %msg.errorMessage
  of mrToolResult:
    var arr = newJArray()
    for b in msg.resultBlocks:
      arr.add(b.toJson())
    result = %*{
      "role": "toolResult",
      "toolCallId": msg.toolCallId,
      "toolName": msg.toolName,
      "content": arr,
      "isError": msg.isError,
      "timestamp": msg.timestampMs
    }
    if msg.diff.len > 0:
      result["diff"] = %msg.diff
    if msg.fullOutputPath.len > 0:
      result["fullOutputPath"] = %msg.fullOutputPath

proc parseBlocksField(node: JsonNode): seq[ContentBlock] =
  if node.isNil:
    return @[]
  if node.kind == JString:
    return @[textBlock(node.getStr())]
  if node.kind == JArray:
    for item in node.items:
      let parsed = parseContentBlock(item)
      if parsed.isSome:
        result.add(parsed.get)

proc parseAgentMessage*(node: JsonNode): Option[AgentMessage] =
  ## Deserialize an AgentMessage from Pi v3 session JSON.
  if node.isNil or node.kind != JObject:
    return none(AgentMessage)
  let roleStr = node{"role"}.getStr("")
  let ts = node{"timestamp"}.getBiggestInt(0)
  case roleStr
  of "system":
    var secs = initOrderedTable[string, string]()
    if node.hasKey("sections") and node["sections"].kind == JObject:
      for k, v in node["sections"].pairs:
        if v.kind == JString:
          secs[k] = v.getStr()
    some(AgentMessage(
      role: mrSystem,
      timestampMs: ts,
      systemContent: node{"content"}.getStr(""),
      sections: secs
    ))
  of "user":
    some(AgentMessage(
      role: mrUser,
      timestampMs: ts,
      userBlocks: parseBlocksField(node{"content"})
    ))
  of "assistant":
    let stopRaw = node{"stopReason"}.getStr("stop")
    let sr = case stopRaw
      of "length": srLength
      of "toolUse": srToolUse
      of "error": srError
      of "aborted": srAborted
      of "turnLimit": srTurnLimit
      else: srStop
    some(AgentMessage(
      role: mrAssistant,
      timestampMs: ts,
      assistantBlocks: parseBlocksField(node{"content"}),
      api: node{"api"}.getStr("openai-completions"),
      provider: node{"provider"}.getStr(""),
      model: node{"model"}.getStr(""),
      thinkingLevel: parseThinkingLevel(node{"thinkingLevel"}.getStr("medium")),
      usage: parseUsage(node{"usage"}),
      stopReason: sr,
      errorMessage: node{"errorMessage"}.getStr("")
    ))
  of "toolResult":
    some(AgentMessage(
      role: mrToolResult,
      timestampMs: ts,
      toolCallId: node{"toolCallId"}.getStr(""),
      toolName: node{"toolName"}.getStr(""),
      resultBlocks: parseBlocksField(node{"content"}),
      isError: node{"isError"}.getBool(false),
      diff: node{"diff"}.getStr(""),
      fullOutputPath: node{"fullOutputPath"}.getStr("")
    ))
  else:
    none(AgentMessage)
