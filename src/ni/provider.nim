# Extensible LLM provider registry and real-time SSE streaming adapters (OpenAI, DeepSeek, and OpenAI-compatible endpoints).

import std/[asyncdispatch, httpclient, json, monotimes, net, options, os, strutils, tables, times, uri]
import ./[types, config, utf8, release_info]

type
  ToolSchemaDef* = object
    name*: string
    description*: string
    parameters*: JsonNode

  ProviderRequest* = object
    model*: ModelConfig
    apiKey*: string
    headers*: Table[string, string]
    systemPrompt*: string
    messages*: seq[AgentMessage]
    tools*: seq[ToolSchemaDef]
    thinkingLevel*: ThinkingLevel
    proxyUrl*: string
    timeoutMs*: int

  HttpLineChunkCallback* = proc(line: string) {.closure.}

  HttpStreamResponse* = object
    statusCode*: int
    headers*: Table[string, string]
    errorBody*: string

  HttpStreamTransport* = proc(
    url: string,
    httpMethod: string,
    headers: Table[string, string],
    body: string,
    proxyUrl: string,
    timeoutMs: int,
    abort: AbortFlag,
    onLine: HttpLineChunkCallback
  ): HttpStreamResponse {.closure.}

  ApiAdapterProc* = proc(
    req: ProviderRequest,
    transport: HttpStreamTransport,
    onEvent: StreamCallback,
    abort: AbortFlag
  ): AgentMessage {.closure.}

  ProviderRegistry* = ref object
    providers*: OrderedTable[string, ProviderConfig]
    adapters*: Table[string, ApiAdapterProc]
    transport*: HttpStreamTransport
    onIdleTick*: proc() {.closure.}

  PartialToolCall = object
    id: string
    name: string
    argsBuf: string
    started: bool

# Default real-time SSE / HTTP line transport backed by AsyncHttpClient

proc streamHttpAsync(
  url: string,
  httpMethod: string,
  headers: Table[string, string],
  body: string,
  proxyUrl: string,
  timeoutMs: int,
  abort: AbortFlag,
  onLine: HttpLineChunkCallback
): Future[HttpStreamResponse] {.async.} =
  var proxy: Proxy = nil
  let effectiveProxy = if proxyUrl.len > 0: proxyUrl
    elif getEnv("HTTPS_PROXY").len > 0: getEnv("HTTPS_PROXY")
    elif getEnv("HTTP_PROXY").len > 0: getEnv("HTTP_PROXY")
    else: ""
  if effectiveProxy.len > 0:
    proxy = newProxy(effectiveProxy)

  var hdrs = newHttpHeaders()
  for k, v in headers.pairs:
    hdrs[k] = v

  let client = newAsyncHttpClient(userAgent = "ni-coding-agent/" & NiVersion, proxy = proxy)
  defer:
    client.close()

  let meth = case httpMethod.toUpperAscii()
    of "GET": HttpGet
    of "DELETE": HttpDelete
    else: HttpPost

  let reqFut = client.request(url, httpMethod = meth, body = body, headers = hdrs)
  var waitedReqMs = 0
  while not reqFut.finished:
    if abort.pollAbort():
      return HttpStreamResponse(statusCode: 499, headers: initTable[string, string](), errorBody: "Aborted")
    let done = await withTimeout(reqFut, 80)
    if not done:
      waitedReqMs += 80
      if timeoutMs > 0 and waitedReqMs >= timeoutMs:
        raise newException(IOError, "HTTP request timeout exceeded (" & $timeoutMs & " ms)")

  let resp = await reqFut
  let code = resp.code.int
  var respHeaders = initTable[string, string]()
  if not resp.headers.isNil:
    for k, v in resp.headers.table.pairs:
      if v.len > 0:
        respHeaders[k.toLowerAscii()] = v.join(", ")

  if code < 200 or code >= 300:
    let bodyFuture = resp.bodyStream.readAll()
    let start = getMonoTime()
    while not bodyFuture.finished:
      if abort.pollAbort():
        return HttpStreamResponse(statusCode: 499, headers: respHeaders, errorBody: "Aborted")
      if timeoutMs > 0 and (getMonoTime() - start).inMilliseconds >= timeoutMs:
        raise newException(IOError, "HTTP error body timeout exceeded")
      discard await withTimeout(bodyFuture, 80)
    return HttpStreamResponse(statusCode: code, headers: respHeaders, errorBody: bodyFuture.read())

  var pending = ""
  while true:
    if abort.pollAbort():
      break
    let readFut = resp.bodyStream.read()
    var idleMs = 0
    while not readFut.finished:
      if abort.pollAbort():
        break
      let done = await withTimeout(readFut, 80)
      if not done:
        idleMs += 80
        if timeoutMs > 0 and idleMs >= timeoutMs:
          raise newException(IOError, "HTTP stream idle timeout exceeded (" & $timeoutMs & " ms)")
    if not abort.isNil and abort.aborted:
      break
    let (hasData, chunk) = await readFut
    if not hasData:
      break
    if not abort.isNil and abort.aborted:
      break
    pending.add(chunk)
    var startIdx = 0
    for i in 0 ..< pending.len:
      if pending[i] == '\n':
        var line = pending[startIdx ..< i]
        if line.endsWith("\r"):
          line.setLen(line.len - 1)
        if not onLine.isNil:
          onLine(line)
        startIdx = i + 1
    if startIdx > 0:
      pending = pending[startIdx .. ^1]

  if pending.len > 0 and (abort.isNil or not abort.aborted):
    var tail = pending
    if tail.endsWith("\r"):
      tail.setLen(tail.len - 1)
    if not onLine.isNil:
      onLine(tail)

  return HttpStreamResponse(statusCode: code, headers: respHeaders, errorBody: "")

proc defaultHttpStreamTransport*(
  url: string,
  httpMethod: string,
  headers: Table[string, string],
  body: string,
  proxyUrl: string,
  timeoutMs: int,
  abort: AbortFlag,
  onLine: HttpLineChunkCallback
): HttpStreamResponse =
  ## Execute a streaming HTTP request synchronously via waitFor over AsyncHttpClient.
  waitFor streamHttpAsync(url, httpMethod, headers, body, proxyUrl, timeoutMs, abort, onLine)

# Cost calculation

proc computeCost*(pricing: ModelPricing, usage: var Usage) =
  ## Compute total USD cost from per-million-token pricing.
  usage.costTotal =
    (usage.inputTokens.float * pricing.input +
     usage.outputTokens.float * pricing.output +
     usage.cacheReadTokens.float * pricing.cacheRead +
     usage.cacheWriteTokens.float * pricing.cacheWrite) / 1_000_000.0

# Endpoint URL builder

proc joinEndpoint*(baseUrl, suffix: string): string =
  ## Append API endpoint suffix (/chat/completions or /responses) cleanly.
  let cleanBase = baseUrl.strip(chars = {'/'}, leading = false, trailing = true)
  if cleanBase.endsWith(suffix):
    cleanBase
  else:
    cleanBase & suffix

# OpenAI Chat Completions adapter (handles OpenAI, DeepSeek, OpenRouter, Ollama, vLLM, Moonshot, etc.)

proc detectThinkingFormat(model: ModelConfig): string =
  if model.compat.thinkingFormat.len > 0:
    return model.compat.thinkingFormat
  let u = model.baseUrl.toLowerAscii()
  if "deepseek.com" in u or model.provider == "deepseek":
    return "deepseek"
  if "openrouter.ai" in u or model.provider == "openrouter":
    return "openrouter"
  if "bigmodel.cn" in u or model.provider == "zai":
    return "zai"
  "openai"

proc requiresReasoningFieldOnAssistant(model: ModelConfig): bool =
  if model.compat.requiresReasoningContentOnAssistantMessages.isSome:
    return model.compat.requiresReasoningContentOnAssistantMessages.get
  let u = model.baseUrl.toLowerAscii()
  "deepseek.com" in u or model.provider == "deepseek"

proc resolveMaxTokensField(model: ModelConfig): string =
  if model.compat.maxTokensField.len > 0:
    return model.compat.maxTokensField
  let u = model.baseUrl.toLowerAscii()
  if "api.openai.com" in u:
    return "max_completion_tokens"
  "max_tokens"

# Thinking levels (Pi's getSupportedThinkingLevels / clampThinkingLevel over `thinkingLevelMap`)

const ThinkingLevelOrder = [tlOff, tlMinimal, tlLow, tlMedium, tlHigh, tlXHigh, tlMax]

proc supportedThinkingLevels*(model: ModelConfig): seq[ThinkingLevel] =
  ## Levels the model accepts: mapped-to-null levels are dropped, xhigh/max need an explicit mapping.
  if not model.reasoning:
    return @[tlOff]
  for lv in ThinkingLevelOrder:
    if model.thinkingLevelMap.hasKey(lv):
      if model.thinkingLevelMap[lv].isNone:
        continue
    elif lv in {tlXHigh, tlMax}:
      continue
    result.add(lv)

proc clampThinkingLevel*(model: ModelConfig, level: ThinkingLevel): ThinkingLevel =
  ## Nearest supported level: the requested one, else the next higher, else the next lower.
  let avail = supportedThinkingLevels(model)
  if level in avail:
    return level
  for i in ord(level) .. ThinkingLevelOrder.high:
    if ThinkingLevelOrder[i] in avail:
      return ThinkingLevelOrder[i]
  for i in countdown(ord(level) - 1, 0):
    if ThinkingLevelOrder[i] in avail:
      return ThinkingLevelOrder[i]
  if avail.len > 0: avail[0] else: tlOff

proc thinkingEffort(model: ModelConfig, level: ThinkingLevel): string =
  if model.thinkingLevelMap.hasKey(level) and model.thinkingLevelMap[level].isSome:
    model.thinkingLevelMap[level].get
  else:
    $level

proc offEffort(model: ModelConfig): Option[string] =
  ## Value to send for "off": none when the model cannot turn reasoning off (mapped to null).
  if model.thinkingLevelMap.hasKey(tlOff):
    return model.thinkingLevelMap[tlOff]
  some("none")

proc supportsReasoningEffort(model: ModelConfig): bool =
  if model.compat.supportsReasoningEffort.isSome:
    return model.compat.supportsReasoningEffort.get
  # Pi's detected default: every OpenAI-compatible host except these.
  let u = model.baseUrl.toLowerAscii()
  not (model.provider in ["xai", "zai", "moonshot"] or "api.x.ai" in u or "bigmodel.cn" in u or "moonshot" in u)

const
  ContextSafetyTokens = 4096
  MinOutputWithRatioMargin = 32_768

proc clampMaxTokens*(model: ModelConfig, inputTokens: int): int =
  ## Fit maxTokens into the context window like Pi's clampMaxTokensToContext.
  if model.contextWindow <= 0:
    return max(1, model.maxTokens)
  let margin = max(ContextSafetyTokens, (inputTokens * 15 + 99) div 100)
  var room = model.contextWindow - inputTokens - margin
  if room < MinOutputWithRatioMargin:
    room = min(MinOutputWithRatioMargin, model.contextWindow - inputTokens - ContextSafetyTokens)
  min(model.maxTokens, max(1, room))

proc buildCompletionsMessages*(req: ProviderRequest): JsonNode =
  ## Convert conversation history into OpenAI Chat Completions wire messages.
  result = newJArray()
  let useDevRole = if req.model.compat.supportsDeveloperRole.isSome:
    req.model.compat.supportsDeveloperRole.get
  else:
    ("api.openai.com" in req.model.baseUrl.toLowerAscii()) and req.model.reasoning

  if req.systemPrompt.strip().len > 0:
    result.add(%*{
      "role": (if useDevRole: "developer" else: "system"),
      "content": req.systemPrompt
    })

  let needReasoningField = requiresReasoningFieldOnAssistant(req.model) and req.model.reasoning

  for msg in req.messages:
    case msg.role
    of mrSystem:
      if msg.systemContent.strip().len > 0:
        result.add(%*{
          "role": (if useDevRole: "developer" else: "system"),
          "content": msg.systemContent
        })
    of mrUser:
      var hasImage = false
      for b in msg.userBlocks:
        if b.kind == ckImage:
          hasImage = true
          break
      if not hasImage:
        result.add(%*{
          "role": "user",
          "content": collectText(msg.userBlocks)
        })
      else:
        var parts = newJArray()
        for b in msg.userBlocks:
          case b.kind
          of ckText:
            parts.add(%*{ "type": "text", "text": b.text })
          of ckImage:
            parts.add(%*{
              "type": "image_url",
              "image_url": { "url": "data:" & b.mimeType & ";base64," & b.data }
            })
          else:
            discard
        result.add(%*{ "role": "user", "content": parts })
    of mrAssistant:
      let txt = collectText(msg.assistantBlocks)
      let thinkTxt = collectThinking(msg.assistantBlocks)
      let tcs = collectToolCalls(msg.assistantBlocks)
      if txt.len == 0 and tcs.len == 0 and thinkTxt.len == 0:
        continue
      var amsg = newJObject()
      amsg["role"] = %"assistant"
      if txt.len > 0:
        amsg["content"] = %txt
      elif req.model.compat.requiresNonNullAssistantContent or tcs.len > 0:
        amsg["content"] = %""

      if thinkTxt.len > 0:
        amsg["reasoning_content"] = %thinkTxt
      elif needReasoningField:
        # DeepSeek reasoner requires reasoning_content on every assistant message in multi-turn tool calls.
        amsg["reasoning_content"] = %""

      if tcs.len > 0:
        var tcArr = newJArray()
        for tc in tcs:
          let argStr = if tc.arguments.isNil: "{}" else: $tc.arguments
          tcArr.add(%*{
            "id": tc.id,
            "type": "function",
            "function": {
              "name": tc.name,
              "arguments": argStr
            }
          })
        amsg["tool_calls"] = tcArr
      result.add(amsg)
    of mrToolResult:
      let resText = collectText(msg.resultBlocks)
      var tmsg = %*{
        "role": "tool",
        "tool_call_id": msg.toolCallId,
        "content": (if resText.strip().len > 0: resText else: "(no tool output)")
      }
      if req.model.compat.requiresToolResultName and msg.toolName.len > 0:
        tmsg["name"] = %msg.toolName
      result.add(tmsg)

proc applyReasoningParams(body: JsonNode, model: ModelConfig, level: ThinkingLevel) =
  ## Mirror Pi's openai-completions reasoning parameters per thinkingFormat.
  if not model.reasoning:
    return
  let lv = clampThinkingLevel(model, level)
  let effort = thinkingEffort(model, lv)
  let allowEffort = supportsReasoningEffort(model)

  case detectThinkingFormat(model)
  of "deepseek":
    if lv != tlOff:
      body["thinking"] = %*{ "type": "enabled" }
      if allowEffort:
        body["reasoning_effort"] = %effort
    elif offEffort(model).isSome:
      body["thinking"] = %*{ "type": "disabled" }
  of "openrouter":
    if lv != tlOff:
      body["reasoning"] = %*{ "effort": effort }
    elif offEffort(model).isSome:
      body["reasoning"] = %*{ "effort": offEffort(model).get }
  of "zai":
    body["thinking"] = %*{
      "type": (if lv == tlOff: "disabled" else: "enabled")
    }
  else:
    if lv != tlOff:
      if allowEffort:
        body["reasoning_effort"] = %effort
    elif allowEffort and model.thinkingLevelMap.hasKey(tlOff) and model.thinkingLevelMap[tlOff].isSome:
      body["reasoning_effort"] = %model.thinkingLevelMap[tlOff].get

proc buildCompletionsRequestBody*(req: ProviderRequest): JsonNode =
  ## Build JSON payload for POST /v1/chat/completions.
  result = %*{
    "model": req.model.id,
    "messages": buildCompletionsMessages(req),
    "stream": true
  }
  if req.model.compat.supportsUsageInStreaming:
    result["stream_options"] = %*{ "include_usage": true }

  if req.model.maxTokens > 0:
    let inputEstimate = ($result["messages"]).len div 4 + req.tools.len * 200
    result[resolveMaxTokensField(req.model)] = %clampMaxTokens(req.model, inputEstimate)

  applyReasoningParams(result, req.model, req.thinkingLevel)

  if req.tools.len > 0:
    var toolsArr = newJArray()
    for t in req.tools:
      var fnObj = %*{
        "name": t.name,
        "description": t.description,
        "parameters": (if t.parameters.isNil: %*{"type": "object", "properties": {}} else: t.parameters)
      }
      if req.model.compat.supportsStrictMode:
        fnObj["strict"] = %false
      toolsArr.add(%*{
        "type": "function",
        "function": fnObj
      })
    result["tools"] = toolsArr

  if not req.model.samplingParams.isNil and req.model.samplingParams.kind == JObject:
    for k, v in req.model.samplingParams.pairs:
      result[k] = v

proc parseToolArgumentsJson(raw: string): JsonNode =
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return newJObject()
  try:
    let parsed = parseJson(trimmed)
    if parsed.kind == JObject:
      return parsed
    return %*{ "value": parsed }
  except CatchableError:
    return %*{ "_raw": raw }

proc formatHttpError(providerId: string, status: int, body: string): string =
  var detail = body.strip()
  try:
    let j = parseJson(detail)
    if j.kind == JObject and j.hasKey("error"):
      let errNode = j["error"]
      if errNode.kind == JObject and errNode.hasKey("message"):
        detail = errNode["message"].getStr()
      elif errNode.kind == JString:
        detail = errNode.getStr()
  except CatchableError:
    discard
  if detail.len > 600:
    detail = detail[0 ..< utf8BoundaryBefore(detail, 600)] & "..."
  "Provider '" & providerId & "' HTTP " & $status & ": " & detail

proc openAICompletionsAdapter*(
  req: ProviderRequest,
  transport: HttpStreamTransport,
  onEvent: StreamCallback,
  abort: AbortFlag
): AgentMessage =
  ## Stream and parse OpenAI Chat Completions SSE (including DeepSeek reasoning_content and tool_calls).
  let url = joinEndpoint(req.model.baseUrl, "/chat/completions")
  let bodyJson = buildCompletionsRequestBody(req)

  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "text/event-stream, application/json"
  for k, v in req.headers.pairs:
    headers[k] = v
  if req.apiKey.len > 0 and not headers.hasKey("Authorization") and not headers.hasKey("authorization"):
    headers["Authorization"] = "Bearer " & req.apiKey

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekStart, modelId: req.model.id))

  var textAccum = ""
  var thinkingAccum = ""
  var thinkingFieldUsed = "reasoning_content"
  var partialCalls = initOrderedTable[int, PartialToolCall]()
  var finishReason = ""
  var usage = Usage()
  var nonSseLines: seq[string] = @[]
  var sawSseData = false

  proc handlePayload(dataStr: string) =
    if dataStr == "[DONE]" or dataStr.len == 0:
      return
    let chunk = try: parseJson(dataStr) except CatchableError: return
    if chunk.kind != JObject:
      return

    # Usage block (arrives in final streaming chunk or non-stream response)
    if chunk.hasKey("usage") and chunk["usage"].kind == JObject:
      let u = chunk["usage"]
      usage.inputTokens = u{"prompt_tokens"}.getInt(usage.inputTokens)
      usage.outputTokens = u{"completion_tokens"}.getInt(usage.outputTokens)
      usage.totalTokens = u{"total_tokens"}.getInt(usage.inputTokens + usage.outputTokens)
      if u.hasKey("prompt_tokens_details") and u["prompt_tokens_details"].kind == JObject:
        usage.cacheReadTokens = u["prompt_tokens_details"]{"cached_tokens"}.getInt(0)
      if u.hasKey("prompt_cache_hit_tokens"):
        usage.cacheReadTokens = u{"prompt_cache_hit_tokens"}.getInt(usage.cacheReadTokens)

    if not chunk.hasKey("choices") or chunk["choices"].kind != JArray or chunk["choices"].len == 0:
      return
    let choice = chunk["choices"][0]
    if choice.kind != JObject:
      return

    if choice.hasKey("finish_reason") and choice["finish_reason"].kind == JString:
      finishReason = choice["finish_reason"].getStr()

    # Support both streaming delta and non-streaming message fallback
    let delta = if choice.hasKey("delta") and choice["delta"].kind == JObject:
      choice["delta"]
    elif choice.hasKey("message") and choice["message"].kind == JObject:
      choice["message"]
    else:
      nil
    if delta.isNil:
      return

    # Reasoning fields (DeepSeek reasoning_content, OpenRouter reasoning, llama.cpp reasoning_text)
    for rfield in ["reasoning_content", "reasoning", "reasoning_text"]:
      if delta.hasKey(rfield) and delta[rfield].kind == JString:
        let rchunk = delta[rfield].getStr()
        if rchunk.len > 0:
          thinkingFieldUsed = rfield
          thinkingAccum.add(rchunk)
          if not onEvent.isNil:
            onEvent(StreamEvent(kind: sekThinkingDelta, thinkingDelta: rchunk))
          break

    if delta.hasKey("content") and delta["content"].kind == JString:
      let tchunk = delta["content"].getStr()
      if tchunk.len > 0:
        textAccum.add(tchunk)
        if not onEvent.isNil:
          onEvent(StreamEvent(kind: sekTextDelta, textDelta: tchunk))

    if delta.hasKey("tool_calls") and delta["tool_calls"].kind == JArray:
      for pos, tcNode in delta["tool_calls"].elems.pairs:
        if tcNode.kind != JObject:
          continue
        let idx = tcNode{"index"}.getInt(pos)
        var entry = partialCalls.getOrDefault(idx, PartialToolCall())
        if tcNode.hasKey("id") and tcNode["id"].kind == JString and tcNode["id"].getStr().len > 0:
          entry.id = tcNode["id"].getStr()
        if tcNode.hasKey("function") and tcNode["function"].kind == JObject:
          let fnNode = tcNode["function"]
          if fnNode.hasKey("name") and fnNode["name"].kind == JString and fnNode["name"].getStr().len > 0:
            entry.name.add(fnNode["name"].getStr())
          if not entry.started and (entry.id.len > 0 or entry.name.len > 0):
            entry.started = true
            if not onEvent.isNil:
              onEvent(StreamEvent(kind: sekToolCallStart, callIndex: idx, callId: entry.id, callName: entry.name))
          if fnNode.hasKey("arguments") and fnNode["arguments"].kind == JString:
            let frag = fnNode["arguments"].getStr()
            if frag.len > 0:
              entry.argsBuf.add(frag)
              if not onEvent.isNil:
                onEvent(StreamEvent(kind: sekToolCallDelta, deltaIndex: idx, argumentsDelta: frag))
        partialCalls[idx] = entry

  var httpResp: HttpStreamResponse
  try:
    httpResp = transport(
      url, "POST", headers, encodeJsonUtf8(bodyJson), req.proxyUrl, req.timeoutMs, abort,
      proc(line: string) =
        let trimmed = line.strip()
        if trimmed.len == 0 or trimmed.startsWith(":"):
          return
        if line.startsWith("data:"):
          sawSseData = true
          var payload = line[5 .. ^1]
          if payload.startsWith(" "):
            payload = payload[1 .. ^1]
          handlePayload(payload)
        else:
          nonSseLines.add(line)
    )
  except CatchableError as e:
    let abortedNow = not abort.isNil and abort.aborted
    let sr = if abortedNow: srAborted else: srError
    let errMsg = if abortedNow: "Request aborted" else: e.msg
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: errMsg))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: sr,
      errorMessage: errMsg
    )

  if not abort.isNil and abort.aborted:
    var partialBlocks: seq[ContentBlock] = @[]
    if thinkingAccum.len > 0:
      partialBlocks.add(thinkingBlock(thinkingAccum, thinkingFieldUsed))
    if textAccum.len > 0:
      partialBlocks.add(textBlock(textAccum))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: partialBlocks,
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srAborted,
      errorMessage: "Aborted by user"
    )

  if httpResp.statusCode < 200 or httpResp.statusCode >= 300:
    let errMsg = formatHttpError(req.model.provider, httpResp.statusCode, httpResp.errorBody)
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: errMsg))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srError,
      errorMessage: errMsg
    )

  # Fallback when an OpenAI-compatible proxy returns a single JSON object instead of SSE
  if not sawSseData and nonSseLines.len > 0:
    handlePayload(nonSseLines.join("\n"))

  var blocks: seq[ContentBlock] = @[]
  if thinkingAccum.len > 0:
    blocks.add(thinkingBlock(thinkingAccum, thinkingFieldUsed))
  if textAccum.len > 0:
    blocks.add(textBlock(textAccum))

  var callCounter = 0
  for idx, pc in partialCalls.pairs:
    inc callCounter
    let cid = if pc.id.len > 0: pc.id else: "call_" & $callCounter
    let tc = toolCallBlock(cid, pc.name, parseToolArgumentsJson(pc.argsBuf))
    blocks.add(tc)
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekToolCallEnd, endIndex: idx, finishedCall: tc))

  computeCost(req.model.cost, usage)

  let finalReason =
    if finishReason == "length":
      srLength
    elif partialCalls.len > 0 or finishReason == "tool_calls":
      srToolUse
    else:
      srStop

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekDone, stopReason: finalReason, usage: usage))

  AgentMessage(
    role: mrAssistant,
    timestampMs: nowUnixMs(),
    assistantBlocks: blocks,
    api: req.model.api,
    provider: req.model.provider,
    model: req.model.id,
    thinkingLevel: req.thinkingLevel,
    usage: usage,
    stopReason: finalReason,
    errorMessage: ""
  )

# OpenAI Responses API adapter (/v1/responses - used by Pi's built-in openai models like gpt-5.x)

proc buildResponsesInput*(req: ProviderRequest): JsonNode =
  result = newJArray()
  for msg in req.messages:
    case msg.role
    of mrSystem:
      if msg.systemContent.strip().len > 0:
        result.add(%*{ "role": "developer", "content": msg.systemContent })
    of mrUser:
      var contentArr = newJArray()
      for b in msg.userBlocks:
        case b.kind
        of ckText:
          contentArr.add(%*{ "type": "input_text", "text": b.text })
        of ckImage:
          contentArr.add(%*{
            "type": "input_image",
            "image_url": "data:" & b.mimeType & ";base64," & b.data
          })
        else:
          discard
      result.add(%*{ "role": "user", "content": contentArr })
    of mrAssistant:
      let txt = collectText(msg.assistantBlocks)
      if txt.len > 0:
        result.add(%*{
          "role": "assistant",
          "content": [{ "type": "output_text", "text": txt }]
        })
      for tc in collectToolCalls(msg.assistantBlocks):
        result.add(%*{
          "type": "function_call",
          "call_id": tc.id,
          "name": tc.name,
          "arguments": (if tc.arguments.isNil: "{}" else: $tc.arguments)
        })
    of mrToolResult:
      let outTxt = collectText(msg.resultBlocks)
      result.add(%*{
        "type": "function_call_output",
        "call_id": msg.toolCallId,
        "output": (if outTxt.strip().len > 0: outTxt else: "(no tool output)")
      })

proc openAIResponsesAdapter*(
  req: ProviderRequest,
  transport: HttpStreamTransport,
  onEvent: StreamCallback,
  abort: AbortFlag
): AgentMessage =
  ## Stream and parse OpenAI Responses API (/v1/responses) SSE events.
  let url = joinEndpoint(req.model.baseUrl, "/responses")
  var bodyJson = %*{
    "model": req.model.id,
    "input": buildResponsesInput(req),
    "stream": true,
    "store": false
  }
  if req.systemPrompt.strip().len > 0:
    bodyJson["instructions"] = %req.systemPrompt
  if req.model.maxTokens > 0:
    let inputEstimate = ($bodyJson["input"]).len div 4 + req.systemPrompt.len div 4 + req.tools.len * 200
    bodyJson["max_output_tokens"] = %clampMaxTokens(req.model, inputEstimate)
  if req.model.reasoning:
    let lv = clampThinkingLevel(req.model, req.thinkingLevel)
    if lv != tlOff:
      bodyJson["reasoning"] = %*{ "effort": thinkingEffort(req.model, lv), "summary": "auto" }
    elif offEffort(req.model).isSome:
      bodyJson["reasoning"] = %*{ "effort": offEffort(req.model).get }

  if req.tools.len > 0:
    var toolsArr = newJArray()
    for t in req.tools:
      toolsArr.add(%*{
        "type": "function",
        "name": t.name,
        "description": t.description,
        "parameters": (if t.parameters.isNil: %*{"type": "object", "properties": {}} else: t.parameters)
      })
    bodyJson["tools"] = toolsArr

  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "text/event-stream"
  for k, v in req.headers.pairs:
    headers[k] = v
  if req.apiKey.len > 0 and not headers.hasKey("Authorization") and not headers.hasKey("authorization"):
    headers["Authorization"] = "Bearer " & req.apiKey

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekStart, modelId: req.model.id))

  var textAccum = ""
  var thinkingAccum = ""
  var callsByItem = initOrderedTable[string, PartialToolCall]()
  var itemOrder: seq[string] = @[]
  var usage = Usage()
  var streamErr = ""
  var outputTruncated = false

  var httpResp: HttpStreamResponse
  try:
    httpResp = transport(
      url, "POST", headers, encodeJsonUtf8(bodyJson), req.proxyUrl, req.timeoutMs, abort,
      proc(line: string) =
        if not line.startsWith("data:"):
          return
        var payload = line[5 .. ^1].strip()
        if payload == "[DONE]" or payload.len == 0:
          return
        let ev = try: parseJson(payload) except CatchableError: return
        if ev.kind != JObject:
          return
        let evType = ev{"type"}.getStr("")
        case evType
        of "response.output_text.delta":
          let d = ev{"delta"}.getStr("")
          if d.len > 0:
            textAccum.add(d)
            if not onEvent.isNil:
              onEvent(StreamEvent(kind: sekTextDelta, textDelta: d))
        of "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
          let d = ev{"delta"}.getStr("")
          if d.len > 0:
            thinkingAccum.add(d)
            if not onEvent.isNil:
              onEvent(StreamEvent(kind: sekThinkingDelta, thinkingDelta: d))
        of "response.output_item.added":
          let item = ev{"item"}
          if not item.isNil and item.kind == JObject and item{"type"}.getStr("") == "function_call":
            let itemId = item{"id"}.getStr("item_" & $itemOrder.len)
            let callId = item{"call_id"}.getStr(itemId)
            let name = item{"name"}.getStr("")
            if itemId notin callsByItem:
              itemOrder.add(itemId)
            callsByItem[itemId] = PartialToolCall(id: callId, name: name, argsBuf: item{"arguments"}.getStr(""), started: true)
            if not onEvent.isNil:
              onEvent(StreamEvent(kind: sekToolCallStart, callIndex: itemOrder.high, callId: callId, callName: name))
        of "response.function_call_arguments.delta":
          let itemId = ev{"item_id"}.getStr("")
          let d = ev{"delta"}.getStr("")
          if itemId in callsByItem and d.len > 0:
            var pc = callsByItem[itemId]
            pc.argsBuf.add(d)
            callsByItem[itemId] = pc
            if not onEvent.isNil:
              onEvent(StreamEvent(kind: sekToolCallDelta, deltaIndex: itemOrder.find(itemId), argumentsDelta: d))
        of "response.output_item.done":
          let item = ev{"item"}
          if not item.isNil and item.kind == JObject and item{"type"}.getStr("") == "function_call":
            let itemId = item{"id"}.getStr("")
            let callId = item{"call_id"}.getStr(itemId)
            let name = item{"name"}.getStr("")
            let fullArgs = item{"arguments"}.getStr("")
            var pc = callsByItem.getOrDefault(itemId, PartialToolCall(id: callId, name: name))
            if callId.len > 0: pc.id = callId
            if name.len > 0: pc.name = name
            if pc.argsBuf.len == 0 and fullArgs.len > 0:
              pc.argsBuf = fullArgs
            if itemId notin callsByItem:
              itemOrder.add(itemId)
            callsByItem[itemId] = pc
        of "response.completed", "response.incomplete":
          let respObj = ev{"response"}
          if evType == "response.incomplete":
            let reason = respObj{"incomplete_details"}{"reason"}.getStr("unknown reason")
            if reason == "max_output_tokens":
              outputTruncated = true
            else:
              streamErr = "Responses stream incomplete: " & reason
          if not respObj.isNil and respObj.kind == JObject and respObj.hasKey("usage"):
            let u = respObj["usage"]
            usage.inputTokens = u{"input_tokens"}.getInt(0)
            usage.outputTokens = u{"output_tokens"}.getInt(0)
            usage.totalTokens = u{"total_tokens"}.getInt(usage.inputTokens + usage.outputTokens)
            if u.hasKey("input_tokens_details") and u["input_tokens_details"].kind == JObject:
              usage.cacheReadTokens = u["input_tokens_details"]{"cached_tokens"}.getInt(0)
        of "error", "response.failed":
          streamErr = ev{"message"}.getStr(ev{"error"}{"message"}.getStr("Responses stream failed"))
        else:
          discard
    )
  except CatchableError as e:
    streamErr = e.msg

  if not abort.isNil and abort.aborted:
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: (if textAccum.len > 0: @[textBlock(textAccum)] else: @[]),
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srAborted,
      errorMessage: "Aborted by user"
    )

  if httpResp.statusCode < 200 or httpResp.statusCode >= 300 or streamErr.len > 0:
    let errMsg = if streamErr.len > 0: streamErr
      else: formatHttpError(req.model.provider, httpResp.statusCode, httpResp.errorBody)
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: errMsg))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srError,
      errorMessage: errMsg
    )

  var blocks: seq[ContentBlock] = @[]
  if thinkingAccum.len > 0:
    blocks.add(thinkingBlock(thinkingAccum, "reasoning_summary"))
  if textAccum.len > 0:
    blocks.add(textBlock(textAccum))
  for idx, itemId in itemOrder.pairs:
    let pc = callsByItem[itemId]
    let tc = toolCallBlock(pc.id, pc.name, parseToolArgumentsJson(pc.argsBuf))
    blocks.add(tc)
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekToolCallEnd, endIndex: idx, finishedCall: tc))

  computeCost(req.model.cost, usage)
  let sr = if outputTruncated: srLength elif itemOrder.len > 0: srToolUse else: srStop
  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekDone, stopReason: sr, usage: usage))

  AgentMessage(
    role: mrAssistant,
    timestampMs: nowUnixMs(),
    assistantBlocks: blocks,
    api: req.model.api,
    provider: req.model.provider,
    model: req.model.id,
    thinkingLevel: req.thinkingLevel,
    usage: usage,
    stopReason: sr,
    errorMessage: ""
  )

# Anthropic Messages API adapter (/v1/messages) & Google Gemini Generative AI adapter (/v1beta/models/*:streamGenerateContent)

proc buildAnthropicEndpoint(baseUrl: string): string =
  let clean = baseUrl.strip(chars = {'/'}, leading = false, trailing = true)
  if clean.endsWith("/v1/messages") or clean.endsWith("/messages"):
    clean
  elif clean.endsWith("/v1"):
    clean & "/messages"
  else:
    clean & "/v1/messages"

proc normalizeAnthropicToolId(id: string): string =
  if id.len == 0:
    return "toolu_1"
  result = newStringOfCap(min(64, id.len))
  for ch in id:
    if result.len >= 64:
      break
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
      result.add(ch)
    else:
      result.add('_')

proc isSyntheticSignature(sig: string): bool =
  sig.len == 0 or sig in ["reasoning_content", "reasoning", "reasoning_text", "reasoning_summary"]

proc appendAnthropicRoleTurn(arr: JsonNode, role: string, blocks: seq[JsonNode]) =
  if blocks.len == 0:
    return
  if arr.len > 0 and arr[arr.len - 1]{"role"}.getStr("") == role:
    let existing = arr[arr.len - 1]["content"]
    for b in blocks:
      existing.add(b)
  else:
    var cArr = newJArray()
    for b in blocks:
      cArr.add(b)
    arr.add(%*{ "role": role, "content": cArr })

proc buildAnthropicMessages*(req: ProviderRequest, enableCache: bool): JsonNode =
  ## Convert conversation history into Anthropic Messages wire format, merging consecutive same-role / tool_result turns.
  result = newJArray()
  for msg in req.messages:
    case msg.role
    of mrSystem:
      if msg.systemContent.strip().len > 0:
        appendAnthropicRoleTurn(result, "user", @[%*{ "type": "text", "text": "<system_update>\n" & msg.systemContent & "\n</system_update>" }])
    of mrUser:
      var uBlocks: seq[JsonNode] = @[]
      var hasText = false
      for b in msg.userBlocks:
        case b.kind
        of ckText:
          if b.text.strip().len > 0:
            uBlocks.add(%*{ "type": "text", "text": b.text })
            hasText = true
        of ckImage:
          uBlocks.add(%*{
            "type": "image",
            "source": {
              "type": "base64",
              "media_type": b.mimeType,
              "data": b.data
            }
          })
        else:
          discard
      if uBlocks.len > 0 and not hasText:
        uBlocks.insert(%*{ "type": "text", "text": "(see attached image)" }, 0)
      appendAnthropicRoleTurn(result, "user", uBlocks)
    of mrAssistant:
      let sameVendor = (msg.api == "anthropic-messages" or msg.provider == req.model.provider)
      var aBlocks: seq[JsonNode] = @[]
      for b in msg.assistantBlocks:
        case b.kind
        of ckThinking:
          if sameVendor and not isSyntheticSignature(b.thinkingSignature):
            aBlocks.add(%*{
              "type": "thinking",
              "thinking": b.thinking,
              "signature": b.thinkingSignature
            })
          elif b.thinking.strip().len > 0:
            aBlocks.add(%*{ "type": "text", "text": b.thinking })
        of ckText:
          if b.text.len > 0:
            aBlocks.add(%*{ "type": "text", "text": b.text })
        of ckToolCall:
          aBlocks.add(%*{
            "type": "tool_use",
            "id": normalizeAnthropicToolId(b.id),
            "name": b.name,
            "input": (if b.arguments.isNil: newJObject() else: b.arguments)
          })
        else:
          discard
      appendAnthropicRoleTurn(result, "assistant", aBlocks)
    of mrToolResult:
      var contentNode: JsonNode
      var hasImg = false
      for b in msg.resultBlocks:
        if b.kind == ckImage:
          hasImg = true
          break
      if not hasImg:
        let txt = collectText(msg.resultBlocks)
        contentNode = %(if txt.strip().len > 0: txt else: "(no tool output)")
      else:
        contentNode = newJArray()
        for b in msg.resultBlocks:
          if b.kind == ckText and b.text.len > 0:
            contentNode.add(%*{ "type": "text", "text": b.text })
          elif b.kind == ckImage:
            contentNode.add(%*{
              "type": "image",
              "source": { "type": "base64", "media_type": b.mimeType, "data": b.data }
            })
      appendAnthropicRoleTurn(result, "user", @[%*{
        "type": "tool_result",
        "tool_use_id": normalizeAnthropicToolId(msg.toolCallId),
        "content": contentNode,
        "is_error": msg.isError
      }])

  # Attach ephemeral cache breakpoint to the final block of the last user message
  if enableCache and result.len > 0:
    for idx in countdown(result.len - 1, 0):
      if result[idx]{"role"}.getStr("") == "user":
        let c = result[idx]{"content"}
        if not c.isNil and c.kind == JArray and c.len > 0:
          c[c.len - 1]["cache_control"] = %*{ "type": "ephemeral" }
        break

proc anthropicMessagesAdapter*(
  req: ProviderRequest,
  transport: HttpStreamTransport,
  onEvent: StreamCallback,
  abort: AbortFlag
): AgentMessage =
  ## Stream and parse Anthropic Messages API (/v1/messages) SSE events with prompt caching and extended/adaptive thinking.
  let url = buildAnthropicEndpoint(req.model.baseUrl)
  let isOAuth = req.apiKey.startsWith("sk-ant-oat")
  let enableCache = "anthropic.com" in req.model.baseUrl.toLowerAscii() or "openrouter.ai" in req.model.baseUrl.toLowerAscii() or req.model.provider == "anthropic"

  let msgsJson = buildAnthropicMessages(req, enableCache)
  let inputEstimate = ($msgsJson).len div 4 + req.systemPrompt.len div 4 + req.tools.len * 200
  var maxOut = clampMaxTokens(req.model, inputEstimate)

  let lv = clampThinkingLevel(req.model, req.thinkingLevel)
  let wantThinking = req.model.reasoning and lv != tlOff
  let midLow = req.model.id.toLowerAscii()
  let usesAdaptive = "opus-4-6" in midLow or "opus-4-7" in midLow or "sonnet-4-6" in midLow

  var bodyJson = %*{
    "model": req.model.id,
    "messages": msgsJson,
    "stream": true
  }

  var sysArr = newJArray()
  if isOAuth:
    var ccIdent = %*{ "type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude." }
    if enableCache: ccIdent["cache_control"] = %*{ "type": "ephemeral" }
    sysArr.add(ccIdent)
  if req.systemPrompt.strip().len > 0:
    var sysBlock = %*{ "type": "text", "text": req.systemPrompt }
    if enableCache: sysBlock["cache_control"] = %*{ "type": "ephemeral" }
    sysArr.add(sysBlock)
  if sysArr.len > 0:
    bodyJson["system"] = sysArr

  if wantThinking:
    if usesAdaptive:
      bodyJson["thinking"] = %*{ "type": "adaptive" }
      let eff = case lv
        of tlMinimal, tlLow: "low"
        of tlMedium: "medium"
        of tlMax: "max"
        else: "high"
      bodyJson["output_config"] = %*{ "effort": eff }
    else:
      let budget = case lv
        of tlMinimal, tlLow: 2048
        of tlMedium: 8192
        of tlHigh: 16384
        of tlXHigh, tlMax: 31999
        else: 4096
      if maxOut <= budget:
        maxOut = min(max(req.model.maxTokens, budget + 4096), budget + 8192)
      bodyJson["thinking"] = %*{ "type": "enabled", "budget_tokens": budget }

  bodyJson["max_tokens"] = %max(1024, maxOut)

  if req.tools.len > 0:
    var toolsArr = newJArray()
    for i, t in req.tools.pairs:
      var tobj = %*{
        "name": t.name,
        "description": t.description,
        "input_schema": (if t.parameters.isNil: %*{"type": "object", "properties": {}} else: t.parameters)
      }
      if enableCache and i == req.tools.high:
        tobj["cache_control"] = %*{ "type": "ephemeral" }
      toolsArr.add(tobj)
    bodyJson["tools"] = toolsArr

  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "text/event-stream"
  headers["anthropic-version"] = "2023-06-01"

  var betas: seq[string] = @[]
  if isOAuth:
    betas.add("claude-code-20250219")
    betas.add("oauth-2025-04-20")
  if wantThinking and not usesAdaptive:
    betas.add("interleaved-thinking-2025-05-14")
  if betas.len > 0:
    headers["anthropic-beta"] = betas.join(",")

  for k, v in req.headers.pairs:
    headers[k] = v

  let hasCustomAuth = headers.hasKey("Authorization") or headers.hasKey("authorization") or
                      headers.hasKey("x-api-key") or headers.hasKey("X-Api-Key")
  if req.apiKey.len > 0 and not hasCustomAuth:
    if isOAuth:
      headers["Authorization"] = "Bearer " & req.apiKey
    else:
      headers["x-api-key"] = req.apiKey

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekStart, modelId: req.model.id))

  type AnthStreamBlock = object
    btype: string
    text: string
    thinking: string
    signature: string
    callId: string
    callName: string
    argsBuf: string

  var streamBlocks = initOrderedTable[int, AnthStreamBlock]()
  var stopReasonRaw = ""
  var usage = Usage()
  var streamErr = ""

  var httpResp: HttpStreamResponse
  try:
    httpResp = transport(
      url, "POST", headers, encodeJsonUtf8(bodyJson), req.proxyUrl, req.timeoutMs, abort,
      proc(line: string) =
        if not line.startsWith("data:"):
          return
        let payload = line[5 .. ^1].strip()
        if payload.len == 0 or payload == "[DONE]":
          return
        let ev = try: parseJson(payload) except CatchableError: return
        if ev.kind != JObject:
          return
        case ev{"type"}.getStr("")
        of "message_start":
          let m = ev{"message"}
          if not m.isNil and m.kind == JObject and m.hasKey("usage"):
            let u = m["usage"]
            usage.inputTokens = u{"input_tokens"}.getInt(usage.inputTokens)
            usage.cacheReadTokens = u{"cache_read_input_tokens"}.getInt(usage.cacheReadTokens)
            usage.cacheWriteTokens = u{"cache_creation_input_tokens"}.getInt(usage.cacheWriteTokens)
            usage.outputTokens = u{"output_tokens"}.getInt(usage.outputTokens)
        of "content_block_start":
          let idx = ev{"index"}.getInt(streamBlocks.len)
          let cb = ev{"content_block"}
          if not cb.isNil and cb.kind == JObject:
            let bt = cb{"type"}.getStr("")
            var sb = AnthStreamBlock(
              btype: bt,
              text: cb{"text"}.getStr(""),
              thinking: cb{"thinking"}.getStr(""),
              signature: cb{"signature"}.getStr(""),
              callId: cb{"id"}.getStr(""),
              callName: cb{"name"}.getStr("")
            )
            streamBlocks[idx] = sb
            if bt == "tool_use" and not onEvent.isNil:
              onEvent(StreamEvent(kind: sekToolCallStart, callIndex: idx, callId: sb.callId, callName: sb.callName))
        of "content_block_delta":
          let idx = ev{"index"}.getInt(0)
          let delta = ev{"delta"}
          if not delta.isNil and delta.kind == JObject and streamBlocks.hasKey(idx):
            var sb = streamBlocks[idx]
            case delta{"type"}.getStr("")
            of "text_delta":
              let d = delta{"text"}.getStr("")
              if d.len > 0:
                sb.text.add(d)
                if not onEvent.isNil:
                  onEvent(StreamEvent(kind: sekTextDelta, textDelta: d))
            of "thinking_delta":
              let d = delta{"thinking"}.getStr("")
              if d.len > 0:
                sb.thinking.add(d)
                if not onEvent.isNil:
                  onEvent(StreamEvent(kind: sekThinkingDelta, thinkingDelta: d))
            of "signature_delta":
              sb.signature.add(delta{"signature"}.getStr(""))
            of "input_json_delta":
              let d = delta{"partial_json"}.getStr("")
              if d.len > 0:
                sb.argsBuf.add(d)
                if not onEvent.isNil:
                  onEvent(StreamEvent(kind: sekToolCallDelta, deltaIndex: idx, argumentsDelta: d))
            else:
              discard
            streamBlocks[idx] = sb
        of "message_delta":
          let delta = ev{"delta"}
          if not delta.isNil and delta.kind == JObject and delta.hasKey("stop_reason") and delta["stop_reason"].kind == JString:
            stopReasonRaw = delta["stop_reason"].getStr()
          if ev.hasKey("usage") and ev["usage"].kind == JObject:
            usage.outputTokens = ev["usage"]{"output_tokens"}.getInt(usage.outputTokens)
        of "error":
          streamErr = ev{"error"}{"message"}.getStr(ev{"message"}.getStr("Anthropic stream error"))
        else:
          discard
    )
  except CatchableError as e:
    streamErr = e.msg

  usage.totalTokens = usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens

  if not abort.isNil and abort.aborted:
    var partial: seq[ContentBlock] = @[]
    for _, sb in streamBlocks.pairs:
      if sb.btype == "thinking" and sb.thinking.len > 0:
        partial.add(thinkingBlock(sb.thinking, sb.signature))
      elif sb.btype == "text" and sb.text.len > 0:
        partial.add(textBlock(sb.text))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: partial,
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srAborted,
      errorMessage: "Aborted by user"
    )

  if httpResp.statusCode < 200 or httpResp.statusCode >= 300 or streamErr.len > 0:
    let errMsg = if streamErr.len > 0: streamErr
      else: formatHttpError(req.model.provider, httpResp.statusCode, httpResp.errorBody)
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: errMsg))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srError,
      errorMessage: errMsg
    )

  var blocks: seq[ContentBlock] = @[]
  var sawToolCall = false
  for idx, sb in streamBlocks.pairs:
    case sb.btype
    of "thinking":
      if sb.thinking.len > 0 or sb.signature.len > 0:
        blocks.add(thinkingBlock(sb.thinking, sb.signature))
    of "text":
      if sb.text.len > 0:
        blocks.add(textBlock(sb.text))
    of "tool_use":
      sawToolCall = true
      let cid = if sb.callId.len > 0: sb.callId else: "toolu_" & $(idx + 1)
      let tc = toolCallBlock(cid, sb.callName, parseToolArgumentsJson(sb.argsBuf))
      blocks.add(tc)
      if not onEvent.isNil:
        onEvent(StreamEvent(kind: sekToolCallEnd, endIndex: idx, finishedCall: tc))
    else:
      discard

  computeCost(req.model.cost, usage)
  let sr = if stopReasonRaw == "max_tokens":
    srLength
  elif sawToolCall or stopReasonRaw == "tool_use":
    srToolUse
  else:
    srStop

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekDone, stopReason: sr, usage: usage))

  AgentMessage(
    role: mrAssistant,
    timestampMs: nowUnixMs(),
    assistantBlocks: blocks,
    api: req.model.api,
    provider: req.model.provider,
    model: req.model.id,
    thinkingLevel: req.thinkingLevel,
    usage: usage,
    stopReason: sr,
    errorMessage: ""
  )

# Google Gemini Generative AI Adapter (`google-generative-ai`)

proc sanitizeGeminiSchema(node: JsonNode): JsonNode =
  ## Strip JSON Schema meta fields (`$schema`, `additionalProperties`) unsupported by Gemini's OpenAPI function parameters.
  if node.isNil:
    return %*{ "type": "object", "properties": {} }
  case node.kind
  of JObject:
    result = newJObject()
    for k, v in node.pairs:
      if k in ["$schema", "additionalProperties", "$id", "default"]:
        continue
      result[k] = sanitizeGeminiSchema(v)
  of JArray:
    result = newJArray()
    for item in node.items:
      result.add(sanitizeGeminiSchema(item))
  else:
    result = copy(node)

proc isValidBase64Signature(sig: string): bool =
  if sig.len == 0 or isSyntheticSignature(sig) or (sig.len mod 4 != 0):
    return false
  for ch in sig:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}:
      return false
  true

proc geminiRequiresCallId(modelId: string): bool =
  let low = modelId.toLowerAscii()
  "gemini-3" in low or "gemini-4" in low or low.startsWith("claude-")

proc buildGeminiRequestBody*(req: ProviderRequest): JsonNode =
  ## Build JSON payload for POST /v1beta/models/<model>:streamGenerateContent?alt=sse.
  var contents = newJArray()
  let includeCallId = geminiRequiresCallId(req.model.id)

  for msg in req.messages:
    case msg.role
    of mrSystem:
      if msg.systemContent.strip().len > 0:
        contents.add(%*{
          "role": "user",
          "parts": [{ "text": "<system_update>\n" & msg.systemContent & "\n</system_update>" }]
        })
    of mrUser:
      var parts = newJArray()
      for b in msg.userBlocks:
        case b.kind
        of ckText:
          if b.text.len > 0:
            parts.add(%*{ "text": b.text })
        of ckImage:
          parts.add(%*{
            "inlineData": { "mimeType": b.mimeType, "data": b.data }
          })
        else:
          discard
      if parts.len > 0:
        contents.add(%*{ "role": "user", "parts": parts })
    of mrAssistant:
      let sameModel = (msg.provider == req.model.provider and msg.model == req.model.id)
      var parts = newJArray()
      for b in msg.assistantBlocks:
        case b.kind
        of ckThinking:
          let sig = if sameModel and isValidBase64Signature(b.thinkingSignature): b.thinkingSignature else: ""
          if sameModel:
            if b.thinking.strip().len > 0 or sig.len > 0:
              var p = %*{ "thought": true, "text": b.thinking }
              if sig.len > 0: p["thoughtSignature"] = %sig
              parts.add(p)
          elif b.thinking.strip().len > 0:
            parts.add(%*{ "text": b.thinking })
        of ckText:
          let sig = if sameModel and isValidBase64Signature(b.textSignature): b.textSignature else: ""
          if b.text.strip().len > 0 or sig.len > 0:
            var p = %*{ "text": b.text }
            if sig.len > 0: p["thoughtSignature"] = %sig
            parts.add(p)
        of ckToolCall:
          var fc = %*{
            "name": b.name,
            "args": (if b.arguments.isNil: newJObject() else: b.arguments)
          }
          if includeCallId and b.id.len > 0:
            fc["id"] = %b.id
          var p = %*{ "functionCall": fc }
          if sameModel and isValidBase64Signature(b.thoughtSignature):
            p["thoughtSignature"] = %b.thoughtSignature
          parts.add(p)
        else:
          discard
      if parts.len > 0:
        contents.add(%*{ "role": "model", "parts": parts })
    of mrToolResult:
      let resTxt = collectText(msg.resultBlocks)
      let valStr = if resTxt.strip().len > 0: resTxt else: "(no tool output)"
      var fnResp = %*{
        "name": msg.toolName,
        "response": (if msg.isError: %*{ "error": valStr } else: %*{ "output": valStr })
      }
      if includeCallId and msg.toolCallId.len > 0:
        fnResp["id"] = %msg.toolCallId
      let part = %*{ "functionResponse": fnResp }
      # Merge consecutive tool results into a single user turn per Gemini protocol requirements
      if contents.len > 0 and contents[contents.len - 1]{"role"}.getStr("") == "user" and
         contents[contents.len - 1]["parts"].len > 0 and
         contents[contents.len - 1]["parts"][0].hasKey("functionResponse"):
        contents[contents.len - 1]["parts"].add(part)
      else:
        contents.add(%*{ "role": "user", "parts": [part] })

  result = %*{ "contents": contents }

  if req.systemPrompt.strip().len > 0:
    result["systemInstruction"] = %*{
      "parts": [{ "text": req.systemPrompt }]
    }

  if req.tools.len > 0:
    var decls = newJArray()
    for t in req.tools:
      decls.add(%*{
        "name": t.name,
        "description": t.description,
        "parameters": sanitizeGeminiSchema(t.parameters)
      })
    result["tools"] = %*[{ "functionDeclarations": decls }]

  let inputEst = ($contents).len div 4 + req.systemPrompt.len div 4 + req.tools.len * 200
  var genCfg = %*{
    "maxOutputTokens": clampMaxTokens(req.model, inputEst)
  }

  if req.model.reasoning:
    let lv = clampThinkingLevel(req.model, req.thinkingLevel)
    let idLow = req.model.id.toLowerAscii()
    let usesLevel = "gemini-3" in idLow or "gemini-4" in idLow or "gemma-4" in idLow
    if lv == tlOff:
      genCfg["thinkingConfig"] = %*{ "thinkingBudget": 0 }
    elif usesLevel:
      let gLevel = case lv
        of tlMinimal: "MINIMAL"
        of tlLow: "LOW"
        of tlMedium: "MEDIUM"
        else: "HIGH"
      genCfg["thinkingConfig"] = %*{ "includeThoughts": true, "thinkingLevel": gLevel }
    else:
      let budget = case lv
        of tlMinimal, tlLow: 1024
        of tlMedium: 8192
        else: 24576
      genCfg["thinkingConfig"] = %*{ "includeThoughts": true, "thinkingBudget": budget }

  result["generationConfig"] = genCfg

proc googleGenerativeAIAdapter*(
  req: ProviderRequest,
  transport: HttpStreamTransport,
  onEvent: StreamCallback,
  abort: AbortFlag
): AgentMessage =
  ## Stream and parse Google Gemini Generative AI (`:streamGenerateContent?alt=sse`) SSE responses.
  let cleanBase = req.model.baseUrl.strip(chars = {'/'}, leading = false, trailing = true)
  let modelPath = if req.model.id.startsWith("models/"): req.model.id else: "models/" & req.model.id
  let url = cleanBase & "/" & modelPath & ":streamGenerateContent?alt=sse"
  let bodyJson = buildGeminiRequestBody(req)

  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "text/event-stream"
  for k, v in req.headers.pairs:
    headers[k] = v
  if req.apiKey.len > 0 and not headers.hasKey("x-goog-api-key") and
     not headers.hasKey("Authorization") and not headers.hasKey("authorization"):
    headers["x-goog-api-key"] = req.apiKey

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekStart, modelId: req.model.id))

  var blocks: seq[ContentBlock] = @[]
  var curKind = -1 # 0 = thinking, 1 = text
  var curText = ""
  var curSig = ""
  var toolCallSeq = 0
  var finishReasonRaw = ""
  var usage = Usage()
  var streamErr = ""

  proc flushCurrentPart() =
    if curKind == 0 and (curText.len > 0 or curSig.len > 0):
      blocks.add(thinkingBlock(curText, curSig))
    elif curKind == 1 and (curText.len > 0 or curSig.len > 0):
      blocks.add(textBlock(curText, curSig))
    curKind = -1
    curText = ""
    curSig = ""

  var httpResp: HttpStreamResponse
  try:
    httpResp = transport(
      url, "POST", headers, encodeJsonUtf8(bodyJson), req.proxyUrl, req.timeoutMs, abort,
      proc(line: string) =
        if not line.startsWith("data:"):
          return
        let payload = line[5 .. ^1].strip()
        if payload.len == 0 or payload == "[DONE]":
          return
        let chunk = try: parseJson(payload) except CatchableError: return
        if chunk.kind != JObject:
          return
        if chunk.hasKey("error") and chunk["error"].kind == JObject:
          streamErr = chunk["error"]{"message"}.getStr("Gemini stream error")
          return

        if chunk.hasKey("usageMetadata") and chunk["usageMetadata"].kind == JObject:
          let u = chunk["usageMetadata"]
          let promptTok = u{"promptTokenCount"}.getInt(0)
          let cachedTok = u{"cachedContentTokenCount"}.getInt(0)
          let candTok = u{"candidatesTokenCount"}.getInt(0)
          let thoughtTok = u{"thoughtsTokenCount"}.getInt(0)
          usage.inputTokens = max(0, promptTok - cachedTok)
          usage.cacheReadTokens = cachedTok
          usage.outputTokens = candTok + thoughtTok
          usage.totalTokens = u{"totalTokenCount"}.getInt(promptTok + candTok + thoughtTok)

        let cands = chunk{"candidates"}
        if not cands.isNil and cands.kind == JArray and cands.len > 0:
          let cand = cands[0]
          if cand.hasKey("finishReason") and cand["finishReason"].kind == JString:
            finishReasonRaw = cand["finishReason"].getStr()
          let parts = cand{"content"}{"parts"}
          if not parts.isNil and parts.kind == JArray:
            for part in parts.items:
              if part.kind != JObject:
                continue
              let inSig = part{"thoughtSignature"}.getStr("")
              if part.hasKey("text") and part["text"].kind == JString:
                let txt = part["text"].getStr()
                let isThought = part{"thought"}.getBool(false)
                let targetKind = if isThought: 0 else: 1
                if curKind != targetKind:
                  flushCurrentPart()
                  curKind = targetKind
                curText.add(txt)
                if inSig.len > 0:
                  curSig = inSig
                if txt.len > 0 and not onEvent.isNil:
                  if isThought:
                    onEvent(StreamEvent(kind: sekThinkingDelta, thinkingDelta: txt))
                  else:
                    onEvent(StreamEvent(kind: sekTextDelta, textDelta: txt))
              if part.hasKey("functionCall") and part["functionCall"].kind == JObject:
                flushCurrentPart()
                inc toolCallSeq
                let fc = part["functionCall"]
                let fname = fc{"name"}.getStr("")
                let fid = fc{"id"}.getStr(fname & "_call_" & $toolCallSeq)
                let fargs = if fc.hasKey("args") and fc["args"].kind == JObject: fc["args"] else: newJObject()
                let tc = toolCallBlock(fid, fname, fargs, inSig)
                let callIdx = blocks.len
                blocks.add(tc)
                if not onEvent.isNil:
                  onEvent(StreamEvent(kind: sekToolCallStart, callIndex: callIdx, callId: fid, callName: fname))
                  onEvent(StreamEvent(kind: sekToolCallDelta, deltaIndex: callIdx, argumentsDelta: $fargs))
                  onEvent(StreamEvent(kind: sekToolCallEnd, endIndex: callIdx, finishedCall: tc))
    )
  except CatchableError as e:
    streamErr = e.msg

  flushCurrentPart()

  if not abort.isNil and abort.aborted:
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: blocks,
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srAborted,
      errorMessage: "Aborted by user"
    )

  if httpResp.statusCode < 200 or httpResp.statusCode >= 300 or streamErr.len > 0:
    let errMsg = if streamErr.len > 0: streamErr
      else: formatHttpError(req.model.provider, httpResp.statusCode, httpResp.errorBody)
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: errMsg))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: req.model.api,
      provider: req.model.provider,
      model: req.model.id,
      thinkingLevel: req.thinkingLevel,
      usage: usage,
      stopReason: srError,
      errorMessage: errMsg
    )

  computeCost(req.model.cost, usage)
  let hasToolCalls = collectToolCalls(blocks).len > 0
  let sr = if finishReasonRaw == "MAX_TOKENS":
    srLength
  elif hasToolCalls:
    srToolUse
  else:
    srStop

  if not onEvent.isNil:
    onEvent(StreamEvent(kind: sekDone, stopReason: sr, usage: usage))

  AgentMessage(
    role: mrAssistant,
    timestampMs: nowUnixMs(),
    assistantBlocks: blocks,
    api: req.model.api,
    provider: req.model.provider,
    model: req.model.id,
    thinkingLevel: req.thinkingLevel,
    usage: usage,
    stopReason: sr,
    errorMessage: ""
  )

# Built-in provider catalog, aligned with Pi's packages/ai/catalog (deepseek.ts, openai.ts, kimi-coding.ts)

proc makeBuiltInModel(
  provider, id, name, api, baseUrl: string,
  reasoning = false,
  ctxWindow = 128_000,
  maxOut = 16_384,
  inCost = 0.0,
  outCost = 0.0,
  compat = defaultCompat(),
  vision = false,
  cacheReadCost = 0.0,
  cacheWriteCost = 0.0,
  thinking: openArray[(ThinkingLevel, Option[string])] = []
): ModelConfig =
  var tmap = initTable[ThinkingLevel, Option[string]]()
  for (lv, v) in thinking:
    tmap[lv] = v
  ModelConfig(
    id: id,
    name: name,
    provider: provider,
    api: api,
    baseUrl: baseUrl,
    reasoning: reasoning,
    inputs: if vision: @["text", "image"] else: @["text"],
    contextWindow: ctxWindow,
    maxTokens: maxOut,
    cost: ModelPricing(input: inCost, output: outCost, cacheRead: cacheReadCost, cacheWrite: cacheWriteCost),
    headers: initTable[string, string](),
    compat: compat,
    samplingParams: nil,
    thinkingLevelMap: tmap
  )

const
  NoLevel = none(string)
  DeepSeekV4Thinking = [(tlMinimal, NoLevel), (tlLow, NoLevel), (tlMedium, NoLevel),
                        (tlHigh, some("high")), (tlMax, some("max"))]
  DeepSeekFlashThinking = [(tlMinimal, NoLevel), (tlLow, some("low")), (tlMedium, NoLevel),
                           (tlHigh, some("high")), (tlMax, some("max"))]
  # GPT-6.2 rejects effort "none" and "minimal" (Pi catalog/families/openai.ts).
  Gpt62Thinking = [(tlOff, NoLevel), (tlMinimal, NoLevel), (tlLow, some("low")), (tlMedium, some("medium")),
                   (tlHigh, some("high")), (tlXHigh, some("xhigh")), (tlMax, some("max"))]
  # Kimi Code reports every model as always-thinking; K3-style models take low/high/max efforts.
  KimiK3Thinking = [(tlOff, NoLevel), (tlMinimal, NoLevel), (tlLow, some("low")), (tlMedium, NoLevel),
                    (tlHigh, some("high")), (tlXHigh, NoLevel), (tlMax, some("max"))]
  KimiAlwaysThinking = [(tlOff, NoLevel)]

proc builtInProviders*(): OrderedTable[string, ProviderConfig] =
  ## Built-in provider definitions: DeepSeek, OpenAI, Kimi Coding, and popular OpenAI-compatible endpoints.
  result = initOrderedTable[string, ProviderConfig]()

  var dsCompat = defaultCompat()
  dsCompat.supportsStore = some(false)
  dsCompat.maxTokensField = "max_tokens"
  dsCompat.requiresReasoningContentOnAssistantMessages = some(true)
  dsCompat.thinkingFormat = "deepseek"
  dsCompat.supportsStrictMode = true

  let dsUrl = "https://api.deepseek.com"
  result["deepseek"] = ProviderConfig(
    id: "deepseek",
    name: "DeepSeek",
    baseUrl: dsUrl,
    api: "openai-completions",
    compat: dsCompat,
    envVars: @["DEEPSEEK_API_KEY"],
    models: @[
      makeBuiltInModel("deepseek", "deepseek-flash", "DeepSeek V4.1 Flash", "openai-completions", dsUrl, true,
                       1_000_000, 384_000, 0.30, 1.20, dsCompat, vision = true, cacheReadCost = 0.006,
                       thinking = DeepSeekFlashThinking),
      makeBuiltInModel("deepseek", "deepseek-v4-pro", "DeepSeek V4 Pro", "openai-completions", dsUrl, true,
                       1_000_000, 384_000, 1.32, 3.96, dsCompat, cacheReadCost = 0.044,
                       thinking = DeepSeekV4Thinking)
    ],
    modelOverrides: initTable[string, JsonNode]()
  )

  var oaiCompat = defaultCompat()
  oaiCompat.supportsDeveloperRole = some(true)
  oaiCompat.supportsReasoningEffort = some(true)
  oaiCompat.maxTokensField = "max_completion_tokens"
  oaiCompat.thinkingFormat = "openai"
  oaiCompat.supportsStrictMode = true

  let oaiEnvBase = getEnv("OPENAI_BASE_URL").strip()
  let oaiUrl = if oaiEnvBase.len > 0: oaiEnvBase else: "https://api.openai.com/v1"
  result["openai"] = ProviderConfig(
    id: "openai",
    name: "OpenAI",
    baseUrl: oaiUrl,
    api: "openai-responses",
    compat: oaiCompat,
    envVars: @["OPENAI_API_KEY"],
    models: @[
      makeBuiltInModel("openai", "gpt-6.2-sol", "GPT-6.2 Sol", "openai-responses", oaiUrl, true,
                       272_000, 128_000, 2.0, 10.0, oaiCompat, vision = true,
                       cacheReadCost = 0.1, cacheWriteCost = 2.5, thinking = Gpt62Thinking)
    ],
    modelOverrides: initTable[string, JsonNode]()
  )

  var kimiK3Compat = defaultCompat()
  kimiK3Compat.supportsStore = some(false)
  kimiK3Compat.supportsReasoningEffort = some(true)
  kimiK3Compat.maxTokensField = "max_tokens"
  kimiK3Compat.thinkingFormat = "openai"
  kimiK3Compat.requiresReasoningContentOnAssistantMessages = some(true)
  var kimiFastCompat = defaultCompat()
  kimiFastCompat.supportsStore = some(false)
  kimiFastCompat.supportsReasoningEffort = some(false)
  kimiFastCompat.maxTokensField = "max_tokens"
  kimiFastCompat.thinkingFormat = "deepseek"

  let kimiUrl = "https://api.kimi.com/coding/v1"
  proc kimiModel(id, name: string, ctx, maxOut: int, inCost, outCost, cacheCost: float, k3Style = true): ModelConfig =
    makeBuiltInModel("kimi-coding", id, name, "openai-completions", kimiUrl, true, ctx, maxOut, inCost, outCost,
                     (if k3Style: kimiK3Compat else: kimiFastCompat), vision = true, cacheReadCost = cacheCost,
                     thinking = (if k3Style: @KimiK3Thinking else: @KimiAlwaysThinking))
  result["kimi-coding"] = ProviderConfig(
    id: "kimi-coding",
    name: "Kimi For Coding",
    baseUrl: kimiUrl,
    api: "openai-completions",
    compat: kimiK3Compat,
    envVars: @["KIMI_API_KEY"],
    models: @[
      kimiModel("k3", "Kimi K3", 1_048_576, 1_048_576, 3.0, 15.0, 0.3),
      kimiModel("k3-256k", "Kimi K3-256K", 262_144, 262_144, 3.0, 15.0, 0.3),
      kimiModel("k3.1-pro", "Kimi K3.1 Pro", 1_048_576, 1_048_576, 2.0, 10.0, 0.2),
      kimiModel("k3.1-pro-highspeed", "Kimi K3.1 Pro Highspeed", 1_048_576, 1_048_576, 4.0, 20.0, 0.2),
      kimiModel("kimi-for-coding", "kimi-for-coding", 1_048_576, 32_768, 0.95, 4.0, 0.19),
      kimiModel("kimi-for-coding-highspeed", "Kimi For Coding HighSpeed", 262_144, 32_768, 1.9, 8.0, 0.38, k3Style = false)
    ],
    modelOverrides: initTable[string, JsonNode]()
  )

  # Endpoint & protocol definitions for Anthropic, Google Gemini, and OpenAI-compatible gateways
  # (models are hydrated on demand from ~/.pi/agent/models-store.json, models.json, or explicit --model IDs)
  let anthEnvBase = getEnv("ANTHROPIC_BASE_URL").strip()
  let anthUrl = if anthEnvBase.len > 0: anthEnvBase else: "https://api.anthropic.com"
  result["anthropic"] = ProviderConfig(
    id: "anthropic",
    name: "Anthropic",
    baseUrl: anthUrl,
    api: "anthropic-messages",
    compat: defaultCompat(),
    envVars: @["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN"],
    models: @[],
    modelOverrides: initTable[string, JsonNode]()
  )

  let gemEnvBase = getEnv("GEMINI_BASE_URL").strip()
  let gemUrl = if gemEnvBase.len > 0: gemEnvBase else: "https://generativelanguage.googleapis.com/v1beta"
  result["google"] = ProviderConfig(
    id: "google",
    name: "Google Gemini",
    baseUrl: gemUrl,
    api: "google-generative-ai",
    compat: defaultCompat(),
    envVars: @["GEMINI_API_KEY", "GOOGLE_API_KEY"],
    models: @[],
    modelOverrides: initTable[string, JsonNode]()
  )

  let gatewayEndpoints = [
    ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY"),
    ("moonshot", "Moonshot AI", "https://api.moonshot.cn/v1", "MOONSHOT_API_KEY"),
    ("siliconflow", "SiliconFlow", "https://api.siliconflow.cn/v1", "SILICONFLOW_API_KEY"),
    ("groq", "Groq", "https://api.groq.com/openai/v1", "GROQ_API_KEY"),
    ("xai", "xAI", "https://api.x.ai/v1", "XAI_API_KEY"),
    ("mistral", "Mistral", "https://api.mistral.ai/v1", "MISTRAL_API_KEY"),
    ("zai", "ZAI (GLM)", "https://open.bigmodel.cn/api/paas/v4", "ZAI_API_KEY")
  ]
  for (pid, pname, purl, penv) in gatewayEndpoints:
    result[pid] = ProviderConfig(
      id: pid,
      name: pname,
      baseUrl: purl,
      api: "openai-completions",
      compat: defaultCompat(),
      envVars: @[penv],
      models: @[],
      modelOverrides: initTable[string, JsonNode]()
    )

proc applyModelOverride(m: var ModelConfig, ov: JsonNode) =
  if ov.isNil or ov.kind != JObject:
    return
  if ov.hasKey("name") and ov["name"].kind == JString:
    m.name = ov["name"].getStr()
  if ov.hasKey("reasoning") and ov["reasoning"].kind == JBool:
    m.reasoning = ov["reasoning"].getBool()
  if ov.hasKey("contextWindow") and ov["contextWindow"].kind == JInt:
    m.contextWindow = ov["contextWindow"].getInt()
  if ov.hasKey("maxTokens") and ov["maxTokens"].kind == JInt:
    m.maxTokens = ov["maxTokens"].getInt()
  if ov.hasKey("compat") and ov["compat"].kind == JObject:
    m.compat = mergeCompatNode(m.compat, ov["compat"])
  if ov.hasKey("samplingParams") and ov["samplingParams"].kind == JObject:
    m.samplingParams = ov["samplingParams"]
  if ov.hasKey("thinkingLevelMap") and ov["thinkingLevelMap"].kind == JObject:
    for lv, v in parseThinkingLevelMap(ov["thinkingLevelMap"]).pairs:
      m.thinkingLevelMap[lv] = v

proc newProviderRegistry*(cfg: ConfigBundle, customTransport: HttpStreamTransport = nil): ProviderRegistry =
  ## Build a ProviderRegistry merging built-in providers -> models-store.json -> models.json overrides.
  var provs = builtInProviders()

  # 1. Apply Pi's cached models-store.json (authoritative refreshed model list per provider)
  for pid, storeProv in cfg.storeProviders.pairs:
    if storeProv.models.len == 0:
      continue
    if provs.hasKey(pid):
      var merged = provs[pid]
      var hydrated: seq[ModelConfig] = @[]
      for sm in storeProv.models:
        var mcopy = sm
        if mcopy.baseUrl.len == 0: mcopy.baseUrl = merged.baseUrl
        if mcopy.api.len == 0: mcopy.api = merged.api
        hydrated.add(mcopy)
      merged.models = hydrated
      provs[pid] = merged
    else:
      var fresh = storeProv
      let envGuess = pid.toUpperAscii().replace("-", "_") & "_API_KEY"
      fresh.envVars = @[envGuess]
      provs[pid] = fresh

  # 2. Apply explicit user overrides and custom providers from ~/.pi/agent/models.json
  for pid, custom in cfg.customProviders.pairs:
    if provs.hasKey(pid):
      var merged = provs[pid]
      if custom.name.len > 0 and custom.name != pid:
        merged.name = custom.name
      if custom.baseUrl.len > 0:
        merged.baseUrl = custom.baseUrl
        for i in 0 ..< merged.models.len:
          merged.models[i].baseUrl = custom.baseUrl
      if custom.apiKeyRaw.len > 0:
        merged.apiKeyRaw = custom.apiKeyRaw
      if custom.api.len > 0:
        merged.api = custom.api
      for k, v in custom.headers.pairs:
        merged.headers[k] = v
      merged.compat = mergeCompatObjects(merged.compat, custom.compat)
      # Add or replace models by ID
      for cm in custom.models:
        var replaced = false
        for i in 0 ..< merged.models.len:
          if merged.models[i].id == cm.id:
            var mcopy = cm
            if mcopy.baseUrl.len == 0: mcopy.baseUrl = merged.baseUrl
            merged.models[i] = mcopy
            replaced = true
            break
        if not replaced:
          var mcopy = cm
          if mcopy.baseUrl.len == 0: mcopy.baseUrl = merged.baseUrl
          merged.models.add(mcopy)
      for mid, ov in custom.modelOverrides.pairs:
        for i in 0 ..< merged.models.len:
          if merged.models[i].id == mid:
            applyModelOverride(merged.models[i], ov)
      provs[pid] = merged
    else:
      var fresh = custom
      if fresh.api.len == 0:
        fresh.api = "openai-completions"
      let envGuess = pid.toUpperAscii().replace("-", "_") & "_API_KEY"
      fresh.envVars = @[envGuess]
      for i in 0 ..< fresh.models.len:
        if fresh.models[i].api.len == 0:
          fresh.models[i].api = fresh.api
        if fresh.models[i].baseUrl.len == 0:
          fresh.models[i].baseUrl = fresh.baseUrl
      provs[pid] = fresh

  var adapters = initTable[string, ApiAdapterProc]()
  adapters["openai-completions"] = openAICompletionsAdapter
  adapters["openai-responses"] = openAIResponsesAdapter
  adapters["azure-openai-responses"] = openAIResponsesAdapter
  adapters["anthropic-messages"] = anthropicMessagesAdapter
  adapters["google-generative-ai"] = googleGenerativeAIAdapter

  var chosenTransport: HttpStreamTransport = defaultHttpStreamTransport
  if not customTransport.isNil:
    chosenTransport = customTransport

  ProviderRegistry(
    providers: provs,
    adapters: adapters,
    transport: chosenTransport
  )

proc registerApiAdapter*(reg: ProviderRegistry, apiName: string, adapter: ApiAdapterProc) =
  ## Extension point: register or override an LLM wire protocol adapter.
  reg.adapters[apiName] = adapter

proc resolveProviderApiKey*(reg: ProviderRegistry, cfg: ConfigBundle, providerId: string, cliApiKey = ""): Option[string] =
  ## Resolve API key using Pi's exact precedence: --api-key -> auth.json -> models.json -> env vars.
  if cliApiKey.strip().len > 0:
    return some(cliApiKey.strip())

  if cfg.auth.hasKey(providerId):
    let cred = cfg.auth[providerId]
    let resolved = resolveConfigValue(cred.rawKeyOrToken, cfg.commandCache, cred.env, cacheCommands = true)
    if resolved.isSome and resolved.get.len > 0:
      return resolved

  if reg.providers.hasKey(providerId):
    let p = reg.providers[providerId]
    if p.apiKeyRaw.len > 0:
      var emptyCache = initTable[string, Option[string]]()
      let resolved = resolveConfigValue(p.apiKeyRaw, emptyCache, cacheCommands = false)
      if resolved.isSome and resolved.get.len > 0:
        return resolved
    for envName in p.envVars:
      let val = getEnv(envName).strip()
      if val.len > 0:
        return some(val)

  let fallbackEnv = providerId.toUpperAscii().replace("-", "_") & "_API_KEY"
  let fallbackVal = getEnv(fallbackEnv).strip()
  if fallbackVal.len > 0:
    return some(fallbackVal)

  none(string)

# OAuth token refresh (Kimi Code device-flow credentials written by Pi's /login)

const
  KimiOAuthClientId = "17e5f671-d194-4dfb-9706-5516cb48c098"
  OAuthRefreshSkewMs = 60_000'i64

proc kimiOAuthHost(): string =
  var host = getEnv("KIMI_CODE_OAUTH_HOST").strip()
  if host.len == 0: host = getEnv("KIMI_OAUTH_HOST").strip()
  if host.len == 0: host = "https://auth.kimi.com"
  host.strip(chars = {'/'}, leading = false, trailing = true)

proc oauthTokenFresh(cred: StoredCredential): bool =
  cred.expiresMs == 0 or nowUnixMs() < cred.expiresMs - OAuthRefreshSkewMs

proc refreshOAuthIfNeeded*(cfg: ConfigBundle, providerId: string): Option[string] =
  ## Refresh an expired Kimi Code OAuth token and save it to auth.json; returns an error message on failure.
  if providerId != "kimi-coding" or not cfg.auth.hasKey(providerId):
    return none(string)
  var cred = cfg.auth[providerId]
  if cred.kind != ckOAuth or oauthTokenFresh(cred):
    return none(string)
  # Pi may have refreshed already; refresh tokens rotate, so re-read auth.json before spending ours.
  var diags: seq[string] = @[]
  let onDisk = loadAuthFile(cfg.agentDir / "auth.json", diags)
  if onDisk.hasKey(providerId) and onDisk[providerId].kind == ckOAuth:
    cred = onDisk[providerId]
    cfg.auth[providerId] = cred
    if oauthTokenFresh(cred):
      return none(string)
  if cred.refreshToken.len == 0:
    return some("Kimi Code OAuth token expired and no refresh token is stored. Run `pi`, then /login kimi-coding.")

  let proxyUrl = if cfg.settings.httpProxy.len > 0: cfg.settings.httpProxy
    elif getEnv("HTTPS_PROXY").len > 0: getEnv("HTTPS_PROXY")
    else: getEnv("HTTP_PROXY")
  try:
    let client = newHttpClient(timeout = 30_000, proxy = (if proxyUrl.len > 0: newProxy(proxyUrl) else: nil))
    defer: client.close()
    client.headers = newHttpHeaders({
      "Content-Type": "application/x-www-form-urlencoded",
      "Accept": "application/json"
    })
    let form = encodeQuery({
      "client_id": KimiOAuthClientId,
      "grant_type": "refresh_token",
      "refresh_token": cred.refreshToken
    })
    let resp = client.request(kimiOAuthHost() & "/api/oauth/token", httpMethod = HttpPost, body = form)
    let raw = resp.body
    let j = try: parseJson(raw) except CatchableError: newJObject()
    let access = j{"access_token"}.getStr("")
    let refresh = j{"refresh_token"}.getStr("")
    let expiresIn = j{"expires_in"}.getFloat(0.0)
    if resp.code.int div 100 != 2 or access.len == 0 or refresh.len == 0 or expiresIn <= 0:
      let detail = j{"error_description"}.getStr(j{"error"}.getStr(raw.strip()))
      return some("Kimi Code OAuth token refresh failed (HTTP " & $resp.code.int & "): " & detail &
                  ". Run `pi`, then /login kimi-coding.")
    let expiresMs = nowUnixMs() + int64(expiresIn * 1000.0)
    saveOAuthCredential(cfg.agentDir, providerId, access, refresh, expiresMs)
    cfg.auth[providerId] = StoredCredential(kind: ckOAuth, rawKeyOrToken: access, env: cred.env,
                                            refreshToken: refresh, expiresMs: expiresMs)
    none(string)
  except CatchableError as e:
    some("Kimi Code OAuth token refresh failed: " & e.msg)

proc resolveHeaders*(reg: ProviderRegistry, cfg: ConfigBundle, model: ModelConfig): Table[string, string] =
  ## Merge and interpolate provider-level and model-level HTTP headers.
  result = initTable[string, string]()
  var extraEnv = initTable[string, string]()
  if cfg.auth.hasKey(model.provider):
    extraEnv = cfg.auth[model.provider].env
  if reg.providers.hasKey(model.provider):
    for k, rawV in reg.providers[model.provider].headers.pairs:
      let v = resolveConfigValue(rawV, cfg.commandCache, extraEnv, cacheCommands = false)
      if v.isSome:
        result[k] = v.get
  for k, rawV in model.headers.pairs:
    let v = resolveConfigValue(rawV, cfg.commandCache, extraEnv, cacheCommands = false)
    if v.isSome:
      result[k] = v.get

proc synthesizeAdHocModel(p: ProviderConfig, modelId: string): ModelConfig =
  let api = if p.api.len > 0: p.api else: "openai-completions"
  let low = modelId.toLowerAscii()
  let isReasoning = "reasoner" in low or "deepseek-v4" in low or "deepseek-flash" in low or
                    low.startsWith("o1") or low.startsWith("o3") or low.startsWith("o4") or
                    low.startsWith("gpt-5") or low.startsWith("gpt-6") or
                    low.startsWith("claude-") or low.startsWith("gemini-") or
                    low.startsWith("k3") or "thinking" in low
  makeBuiltInModel(p.id, modelId, modelId, api, p.baseUrl, isReasoning, 128_000, 32_768, 0.0, 0.0, p.compat)

proc isProviderConfigured*(reg: ProviderRegistry, cfg: ConfigBundle, providerId: string, cliApiKey = ""): bool =
  ## Return true when providerId has usable credentials (auth.json, env, models.json, or --api-key) or explicit models.json entry.
  reg.resolveProviderApiKey(cfg, providerId, cliApiKey).isSome or cfg.customProviders.hasKey(providerId)

proc listSelectableModels*(
  reg: ProviderRegistry,
  cfg: ConfigBundle,
  cliApiKey = "",
  includeUnconfigured = false
): seq[tuple[model: ModelConfig, configured: bool]] =
  ## List models matching Pi's `/model` visibility rules (configured providers by default; all models when requested).
  var configuredList: seq[tuple[model: ModelConfig, configured: bool]] = @[]
  var allList: seq[tuple[model: ModelConfig, configured: bool]] = @[]

  for pid, prov in reg.providers.pairs:
    if prov.models.len == 0:
      continue
    let isCfg = reg.isProviderConfigured(cfg, pid, cliApiKey)
    for m in prov.models:
      allList.add((m, isCfg))
      if isCfg:
        configuredList.add((m, true))

  if includeUnconfigured or configuredList.len == 0:
    return allList
  configuredList

proc resolveModel*(
  reg: ProviderRegistry,
  cfg: ConfigBundle,
  modelPattern = "",
  providerOverride = "",
  cliApiKey = ""
): tuple[model: ModelConfig, thinkingSuffix: Option[ThinkingLevel]] =
  ## Resolve startup or --model selection (`provider/model:thinking`, exact ID, fuzzy match, or ad-hoc model ID).
  var pat = modelPattern.strip()
  var thinkingOpt = none(ThinkingLevel)

  # Extract optional :<thinking> suffix (avoiding Ollama tags like qwen2.5-coder:7b unless valid thinking level)
  let colonIdx = pat.rfind(':')
  if colonIdx > 0 and colonIdx < pat.high:
    let suffix = pat[colonIdx + 1 .. ^1].toLowerAscii()
    if suffix in ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]:
      thinkingOpt = some(parseThinkingLevel(suffix))
      pat = pat[0 ..< colonIdx]

  var explicitProv = providerOverride.strip()
  if pat.contains('/'):
    let slashIdx = pat.find('/')
    let candidateProv = pat[0 ..< slashIdx]
    if reg.providers.hasKey(candidateProv):
      explicitProv = candidateProv
      pat = pat[slashIdx + 1 .. ^1]

  if pat.len == 0:
    pat = cfg.settings.defaultModel.strip()
  if explicitProv.len == 0 and pat.len == 0:
    explicitProv = cfg.settings.defaultProvider.strip()

  # 1. Explicit provider + explicit model ID (supports arbitrary model IDs on OpenAI-compatible endpoints!)
  if explicitProv.len > 0 and reg.providers.hasKey(explicitProv):
    let p = reg.providers[explicitProv]
    if pat.len > 0:
      for m in p.models:
        if m.id.toLowerAscii() == pat.toLowerAscii() or m.name.toLowerAscii() == pat.toLowerAscii():
          return (m, thinkingOpt)
      for m in p.models:
        if pat.toLowerAscii() in m.id.toLowerAscii() or pat.toLowerAscii() in m.name.toLowerAscii():
          return (m, thinkingOpt)
      return (synthesizeAdHocModel(p, pat), thinkingOpt)
    elif p.models.len > 0:
      return (p.models[0], thinkingOpt)

  # 2. Pattern without provider: prefer providers with configured credentials
  if pat.len > 0:
    var fallbackMatch = none(ModelConfig)
    for pid, p in reg.providers.pairs:
      let hasKey = reg.resolveProviderApiKey(cfg, pid, cliApiKey).isSome
      for m in p.models:
        if m.id.toLowerAscii() == pat.toLowerAscii() or m.name.toLowerAscii() == pat.toLowerAscii():
          if hasKey:
            return (m, thinkingOpt)
          if fallbackMatch.isNone:
            fallbackMatch = some(m)
    if fallbackMatch.isSome:
      return (fallbackMatch.get, thinkingOpt)

    for pid, p in reg.providers.pairs:
      let hasKey = reg.resolveProviderApiKey(cfg, pid, cliApiKey).isSome
      for m in p.models:
        if pat.toLowerAscii() in m.id.toLowerAscii() or pat.toLowerAscii() in m.name.toLowerAscii():
          if hasKey:
            return (m, thinkingOpt)
          if fallbackMatch.isNone:
            fallbackMatch = some(m)
    if fallbackMatch.isSome:
      return (fallbackMatch.get, thinkingOpt)

    # Ad-hoc model on defaultProvider or first authenticated provider
    let targetProv = if cfg.settings.defaultProvider in reg.providers: cfg.settings.defaultProvider else: "openai"
    if targetProv in reg.providers:
      return (synthesizeAdHocModel(reg.providers[targetProv], pat), thinkingOpt)

  # 3. Automatic selection: check defaultProvider, then first authenticated provider (deepseek -> openai -> others)
  if cfg.settings.defaultProvider.len > 0 and reg.providers.hasKey(cfg.settings.defaultProvider):
    let p = reg.providers[cfg.settings.defaultProvider]
    if p.models.len > 0:
      return (p.models[0], thinkingOpt)

  for pid in ["deepseek", "kimi-coding", "openai", "anthropic", "google"]:
    if reg.providers.hasKey(pid) and reg.resolveProviderApiKey(cfg, pid, cliApiKey).isSome and reg.providers[pid].models.len > 0:
      return (reg.providers[pid].models[0], thinkingOpt)

  for pid, p in reg.providers.pairs:
    if reg.resolveProviderApiKey(cfg, pid, cliApiKey).isSome and p.models.len > 0:
      return (p.models[0], thinkingOpt)

  (reg.providers["deepseek"].models[0], thinkingOpt)

proc streamCompletion*(
  reg: ProviderRegistry,
  cfg: ConfigBundle,
  model: ModelConfig,
  systemPrompt: string,
  messages: seq[AgentMessage],
  tools: seq[ToolSchemaDef],
  thinkingLevel: ThinkingLevel,
  cliApiKey = "",
  onEvent: StreamCallback = nil,
  abort: AbortFlag = nil
): AgentMessage =
  ## Dispatch a streaming model turn with automatic transient-error retries.
  let refreshErr = if cliApiKey.strip().len == 0: refreshOAuthIfNeeded(cfg, model.provider) else: none(string)
  if refreshErr.isSome:
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: refreshErr.get))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: model.api,
      provider: model.provider,
      model: model.id,
      thinkingLevel: thinkingLevel,
      stopReason: srError,
      errorMessage: refreshErr.get
    )
  let headers = reg.resolveHeaders(cfg, model)
  let keyOpt = reg.resolveProviderApiKey(cfg, model.provider, cliApiKey)
  let hasAuthHeader = headers.hasKey("Authorization") or headers.hasKey("authorization")
  if keyOpt.isNone and not hasAuthHeader:
    let errMsg = "No API key configured for provider '" & model.provider &
      "'. Set $" & model.provider.toUpperAscii() & "_API_KEY, run `ni auth login " & model.provider &
      "`, or configure ~/.pi/agent/auth.json or models.json."
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekError, errorMsg: errMsg))
    return AgentMessage(
      role: mrAssistant,
      timestampMs: nowUnixMs(),
      assistantBlocks: @[],
      api: model.api,
      provider: model.provider,
      model: model.id,
      thinkingLevel: thinkingLevel,
      stopReason: srError,
      errorMessage: errMsg
    )

  let apiName = if model.api.len > 0: model.api else: "openai-completions"
  let adapter = reg.adapters.getOrDefault(apiName, openAICompletionsAdapter)
  let req = ProviderRequest(
    model: model,
    apiKey: if keyOpt.isSome: keyOpt.get else: "",
    headers: headers,
    systemPrompt: systemPrompt,
    messages: messages,
    tools: tools,
    thinkingLevel: thinkingLevel,
    proxyUrl: cfg.settings.httpProxy,
    timeoutMs: cfg.settings.httpIdleTimeoutMs
  )

  let runAbort = if abort.isNil: newAbortFlag() else: abort
  let prevTick = runAbort.onIdle
  if prevTick.isNil:
    runAbort.onIdle = reg.onIdleTick
  defer:
    runAbort.onIdle = prevTick

  let maxAttempts = if cfg.settings.retry.enabled: max(1, cfg.settings.retry.maxRetries + 1) else: 1
  var attempt = 0
  proc finishRetry(msg: AgentMessage): AgentMessage =
    if attempt > 1 and not onEvent.isNil:
      onEvent(StreamEvent(kind: sekRetryEnd, retryAttempt: attempt,
        retryError: (if msg.stopReason in {srError, srAborted}: msg.errorMessage else: "")))
    msg
  while attempt < maxAttempts:
    inc attempt
    if runAbort.pollAbort():
      return finishRetry(AgentMessage(role: mrAssistant, provider: model.provider, model: model.id,
        stopReason: srAborted, errorMessage: "Request aborted"))
    let msg = adapter(req, reg.transport, onEvent, runAbort)
    if msg.stopReason != srError or runAbort.aborted:
      return finishRetry(msg)
    let isTransient = ("HTTP 429" in msg.errorMessage) or ("HTTP 408" in msg.errorMessage) or
                      ("HTTP 500" in msg.errorMessage) or ("HTTP 502" in msg.errorMessage) or
                      ("HTTP 503" in msg.errorMessage) or ("HTTP 504" in msg.errorMessage) or
                      ("timeout" in msg.errorMessage.toLowerAscii())
    if not isTransient or attempt >= maxAttempts:
      return finishRetry(msg)
    let delayMs = min(cfg.settings.retry.baseDelayMs * (1 shl min(20, attempt - 1)), cfg.settings.retry.maxDelayMs)
    let deadline = getMonoTime() + initDuration(milliseconds = delayMs)
    runAbort.retrying = true
    if not onEvent.isNil:
      onEvent(StreamEvent(kind: sekRetryStart, retryAttempt: attempt, retryLimit: maxAttempts,
        retryDelayMs: delayMs, retryError: msg.errorMessage))
    while getMonoTime() < deadline and not runAbort.pollAbort():
      sleep(max(1, min(50, (deadline - getMonoTime()).inMilliseconds.int)))
    runAbort.retrying = false
