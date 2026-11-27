# Headless JSONL RPC mode (`ni --mode rpc`) compatible with Pi's stdin/stdout embedding protocol.

import std/[deques, json, options, strutils, tables]
import ./[types, config, provider, tools, skills, session, agent, tui, utf8]

type
  RpcInputKind = enum
    rikLine
    rikEof

  RpcInput = object
    case kind: RpcInputKind
    of rikLine: line: string
    of rikEof: discard

  RpcCommand = object
    kind: string
    id: JsonNode
    payload: JsonNode

proc readRpcInput(input: ptr Channel[RpcInput]) {.thread.} =
  # The reader only transfers lines. The agent thread owns JSON parsing, state changes, and stdout.
  try:
    var line = ""
    while stdin.readLine(line):
      if line.len > 0:
        input[].send(RpcInput(kind: rikLine, line: line))
  except IOError:
    discard
  finally:
    input[].send(RpcInput(kind: rikEof))

proc writeRpcLine(node: JsonNode) =
  stdout.writeLine(encodeJsonUtf8(node))
  stdout.flushFile()

proc rpcOk(reqId: JsonNode, command: string, data: JsonNode = nil): JsonNode =
  result = %*{
    "type": "response",
    "command": command,
    "success": true
  }
  if not reqId.isNil and reqId.kind != JNull:
    result["id"] = reqId
  if not data.isNil:
    result["data"] = data

proc rpcErr(reqId: JsonNode, command: string, message: string): JsonNode =
  result = %*{
    "type": "response",
    "command": command,
    "success": false,
    "error": message
  }
  if not reqId.isNil and reqId.kind != JNull:
    result["id"] = reqId

proc modelToRpcJson(m: ModelConfig): JsonNode =
  %*{
    "id": m.id,
    "name": m.name,
    "provider": m.provider,
    "api": m.api,
    "baseUrl": m.baseUrl,
    "reasoning": m.reasoning,
    "input": m.inputs,
    "contextWindow": m.contextWindow,
    "maxTokens": m.maxTokens,
    "cost": {
      "input": m.cost.input,
      "output": m.cost.output,
      "cacheRead": m.cost.cacheRead,
      "cacheWrite": m.cost.cacheWrite
    }
  }

proc buildRpcStateJson(rt: AgentRuntime, isStreaming = false, isCompacting = false): JsonNode =
  let (msgs, _, _) = rt.session.buildActiveContext()
  result = %*{
    "model": modelToRpcJson(rt.currentModel),
    "thinkingLevel": $rt.thinkingLevel,
    "isStreaming": isStreaming,
    "isCompacting": isCompacting,
    "steeringMode": $rt.steeringMode,
    "followUpMode": $rt.followUpMode,
    "sessionId": rt.session.id,
    "autoCompactionEnabled": rt.cfg.settings.compaction.enabled,
    "messageCount": msgs.len,
    "pendingMessageCount": rt.steeringQueue.len + rt.followUpQueue.len
  }
  if rt.session.filePath.len > 0:
    result["sessionFile"] = %rt.session.filePath
  if rt.session.displayName.len > 0:
    result["sessionName"] = %rt.session.displayName

proc buildContextUsageJson(rt: AgentRuntime, messages: openArray[AgentMessage]): JsonNode =
  let window = rt.currentModel.contextWindow
  if window <= 0:
    return nil

  let branch = rt.session.activeBranchEntries()
  for i in countdown(branch.high, 0):
    let entry = branch[i]
    if entry.kind == sekCompaction:
      return %*{"tokens": newJNull(), "contextWindow": window, "percent": newJNull()}
    if entry.kind == sekMessage and entry.message.role == mrAssistant and
        entry.message.stopReason notin {srError, srAborted}:
      let usage = entry.message.usage
      if max(usage.totalTokens, usage.inputTokens + usage.outputTokens +
          usage.cacheReadTokens + usage.cacheWriteTokens) > 0:
        break

  let tokens = if messages.len == 0: 0 else: estimateContextTokens(rt.runtimeSystemPrompt(), messages)
  %*{"tokens": tokens, "contextWindow": window, "percent": tokens.float * 100 / window.float}

proc readPrompt(payload: JsonNode): QueuedPrompt =
  result.text = payload{"message"}.getStr("")
  let images = payload{"images"}
  if not images.isNil and images.kind == JArray:
    for img in images:
      let data = img{"data"}.getStr("")
      if data.len > 0:
        result.images.add(imageBlock(data, img{"mimeType"}.getStr("image/png")))

proc runRpcMode*(rt: AgentRuntime): int =
  ## Dispatch JSONL commands and poll prompt controls while the model or a dialog is waiting.
  var input: Channel[RpcInput]
  input.open(64)
  var reader: Thread[ptr Channel[RpcInput]]
  createThread(reader, readRpcInput, addr input)
  var inputClosed = false
  var deferred = initDeque[RpcCommand]()
  var currentAbort: AbortFlag = nil
  var bashAbort: AbortFlag = nil
  var compacting = false
  var abortRequests: seq[JsonNode] = @[]
  let emitAgentEventJson = makeJsonEventPrinter()

  proc decodeCommand(message: RpcInput): Option[RpcCommand] =
    if message.kind == rikEof:
      inputClosed = true
      return none(RpcCommand)
    let trimmed = message.line.strip()
    if trimmed.len == 0:
      return none(RpcCommand)

    let cmdNode = try: parseJson(trimmed) except CatchableError as e:
      writeRpcLine(rpcErr(nil, "parse", "Invalid JSON command: " & e.msg))
      return none(RpcCommand)

    if cmdNode.kind != JObject:
      writeRpcLine(rpcErr(nil, "parse", "RPC command must be a JSON object"))
      return none(RpcCommand)

    let reqId = cmdNode{"id"}
    let cmdType = cmdNode{"type"}.getStr("")
    if cmdType.len == 0:
      writeRpcLine(rpcErr(reqId, "unknown", "Missing `type` field on RPC command"))
      return none(RpcCommand)
    some(RpcCommand(kind: cmdType, id: reqId, payload: cmdNode))

  proc handlePromptControl(cmd: RpcCommand): bool =
    let active = not currentAbort.isNil
    case cmd.kind
    of "get_state":
      writeRpcLine(rpcOk(cmd.id, cmd.kind, buildRpcStateJson(rt, isStreaming = active and not compacting,
        isCompacting = compacting)))
    of "prompt", "steer", "follow_up":
      if cmd.kind == "prompt" and not active:
        return false
      let behavior = case cmd.kind
        of "steer": "steer"
        of "follow_up": "followUp"
        else: cmd.payload{"streamingBehavior"}.getStr("")
      if behavior notin ["steer", "followUp"]:
        writeRpcLine(rpcErr(cmd.id, cmd.kind, "A prompt is running. Use streamingBehavior steer or followUp."))
      else:
        let prompt = readPrompt(cmd.payload)
        if prompt.text.strip().len == 0 and prompt.images.len == 0:
          writeRpcLine(rpcErr(cmd.id, cmd.kind, "Provide a message or image"))
        else:
          if behavior == "steer":
            rt.steeringQueue.add(prompt)
          else:
            rt.followUpQueue.add(prompt)
          writeRpcLine(rpcOk(cmd.id, cmd.kind, %*{ "disposition": "queued" }))
          rt.emitQueueUpdate(emitAgentEventJson)
    of "clear_queue":
      var steering = newJArray()
      for prompt in rt.steeringQueue: steering.add(%prompt.text)
      var followUp = newJArray()
      for prompt in rt.followUpQueue: followUp.add(%prompt.text)
      rt.steeringQueue.setLen(0)
      rt.followUpQueue.setLen(0)
      writeRpcLine(rpcOk(cmd.id, cmd.kind, %*{ "steering": steering, "followUp": followUp }))
      rt.emitQueueUpdate(emitAgentEventJson)
    of "abort":
      if active:
        currentAbort.aborted = true
        abortRequests.add(cmd.id)
      else:
        writeRpcLine(rpcOk(cmd.id, cmd.kind))
    of "abort_retry":
      if active and currentAbort.retrying:
        currentAbort.aborted = true
      writeRpcLine(rpcOk(cmd.id, cmd.kind))
    of "abort_bash":
      if not bashAbort.isNil:
        bashAbort.aborted = true
      writeRpcLine(rpcOk(cmd.id, cmd.kind))
    of "set_steering_mode", "set_follow_up_mode":
      let mode = cmd.payload{"mode"}.getStr("")
      if mode notin [$qmOneAtATime, $qmAll]:
        writeRpcLine(rpcErr(cmd.id, cmd.kind, "Queue mode must be all or one-at-a-time"))
      else:
        let selected = if mode == $qmAll: qmAll else: qmOneAtATime
        if cmd.kind == "set_steering_mode": rt.steeringMode = selected
        else: rt.followUpMode = selected
        writeRpcLine(rpcOk(cmd.id, cmd.kind))
    of "extension_ui_response":
      discard
    else:
      return false
    true

  proc drainActiveInput() =
    while not inputClosed:
      let (available, message) = input.tryRecv()
      if not available:
        break
      let parsed = decodeCommand(message)
      if parsed.isSome and not handlePromptControl(parsed.get):
        deferred.addLast(parsed.get)

  proc askOverRpc(questions: seq[AskQuestionItem]): seq[AskQuestionAnswer] =
    for q in questions:
      let reqUuid = "rpc_ui_" & genShortId()
      var opts = newJArray()
      for opt in q.options: opts.add(%opt.label)
      writeRpcLine(%*{
        "type": "extension_ui_request", "id": reqUuid, "method": "select",
        "title": q.question, "options": opts
      })
      var answer = AskQuestionAnswer(id: q.id, question: q.question, cancelled: true)
      while not inputClosed and (currentAbort.isNil or not currentAbort.aborted):
        let parsed = decodeCommand(input.recv())
        if parsed.isNone:
          continue
        let cmd = parsed.get
        if cmd.kind == "extension_ui_response" and cmd.id.getStr("") == reqUuid:
          answer.cancelled = cmd.payload{"cancelled"}.getBool(false)
          let value = cmd.payload{"value"}.getStr("")
          if not answer.cancelled and value.len > 0:
            answer.selected = @[value]
            answer.customText = value
          break
        if not handlePromptControl(cmd):
          deferred.addLast(cmd)
      result.add(answer)
      if answer.cancelled:
        break

  let originalAsk = rt.askQuestion
  if originalAsk.isNil:
    rt.askQuestion = askOverRpc
  defer:
    rt.askQuestion = originalAsk

  while deferred.len > 0 or not inputClosed:
    let parsed = if deferred.len > 0: some(deferred.popFirst()) else: decodeCommand(input.recv())
    if parsed.isNone:
      continue
    let command = parsed.get
    if handlePromptControl(command):
      continue
    let reqId = command.id
    let cmdType = command.kind
    let cmdNode = command.payload

    case cmdType
    of "prompt":
      let prompt = readPrompt(cmdNode)
      if prompt.text.strip().len == 0 and prompt.images.len == 0:
        writeRpcLine(rpcErr(reqId, cmdType, "Provide a message or image"))
        continue
      currentAbort = newAbortFlag()
      let previousTick = rt.providerRegistry.onIdleTick
      rt.providerRegistry.onIdleTick = drainActiveInput
      defer:
        rt.providerRegistry.onIdleTick = previousTick
        currentAbort = nil
      writeRpcLine(rpcOk(reqId, cmdType, %*{ "disposition": "started" }))
      discard rt.runPrompt(prompt.text, abort = currentAbort, extraImages = prompt.images,
        onEvent = proc(ev: AgentEvent) =
          if ev.kind == aekCompactionStart: compacting = true
          elif ev.kind == aekCompaction: compacting = false
          emitAgentEventJson(ev)
          if ev.kind notin {aekToolStart, aekRunEnd}:
            drainActiveInput()
      )
      for id in abortRequests:
        writeRpcLine(rpcOk(id, "abort"))
      abortRequests.setLen(0)

    of "set_model":
      let prov = cmdNode{"provider"}.getStr("")
      let mid = cmdNode{"modelId"}.getStr("")
      var model: Option[ModelConfig]
      for providerId, providerConfig in rt.providerRegistry.providers.pairs:
        if prov.len > 0 and providerId != prov: continue
        for candidate in providerConfig.models:
          if candidate.id == mid or providerId & "/" & candidate.id == mid or (mid.len == 0 and prov.len > 0):
            model = some(candidate)
            break
        if model.isSome: break
      if model.isNone:
        writeRpcLine(rpcErr(reqId, "set_model", "Unknown model " & prov & "/" & mid))
      else:
        rt.switchModel(model.get)
        let level = clampThinkingLevel(model.get, rt.thinkingLevel)
        if level != rt.thinkingLevel: rt.switchThinkingLevel(level)
        writeRpcLine(rpcOk(reqId, "set_model", modelToRpcJson(model.get)))

    of "get_available_models":
      var arr = newJArray()
      for item in rt.providerRegistry.listSelectableModels(rt.cfg, rt.cliApiKey):
        if item.configured: arr.add(modelToRpcJson(item.model))
      writeRpcLine(rpcOk(reqId, "get_available_models", %*{ "models": arr }))

    of "cycle_model":
      let models = rt.providerRegistry.listSelectableModels(rt.cfg, rt.cliApiKey)
      if models.len <= 1:
        writeRpcLine(rpcOk(reqId, cmdType, newJNull()))
      else:
        var current = -1
        for index, item in models:
          if item.model.id == rt.currentModel.id and item.model.provider == rt.currentModel.provider:
            current = index
            break
        let model = models[(current + 1) mod models.len].model
        rt.switchModel(model)
        let level = clampThinkingLevel(model, rt.thinkingLevel)
        if level != rt.thinkingLevel: rt.switchThinkingLevel(level)
        writeRpcLine(rpcOk(reqId, cmdType, %*{"model": modelToRpcJson(model), "thinkingLevel": $level, "isScoped": false}))

    of "set_thinking_level":
      let lv = parseThinkingLevel(cmdNode{"level"}.getStr("medium"), rt.thinkingLevel)
      rt.switchThinkingLevel(clampThinkingLevel(rt.currentModel, lv))
      writeRpcLine(rpcOk(reqId, "set_thinking_level"))

    of "cycle_thinking_level":
      let levels = supportedThinkingLevels(rt.currentModel)
      if levels.len <= 1:
        writeRpcLine(rpcOk(reqId, "cycle_thinking_level", newJNull()))
      else:
        let curIdx = levels.find(rt.thinkingLevel)
        let nextLv = levels[(max(0, curIdx) + 1) mod levels.len]
        rt.switchThinkingLevel(nextLv)
        writeRpcLine(rpcOk(reqId, "cycle_thinking_level", %*{ "level": $nextLv }))

    of "get_available_thinking_levels":
      var lArr = newJArray()
      for lv in supportedThinkingLevels(rt.currentModel):
        lArr.add(%($lv))
      writeRpcLine(rpcOk(reqId, "get_available_thinking_levels", %*{ "levels": lArr }))

    of "compact":
      let beforeMsgs = rt.session.activeBranchEntries().len
      currentAbort = newAbortFlag()
      currentAbort.onIdle = drainActiveInput
      compacting = true
      let instructions = cmdNode{"customInstructions"}.getStr("")
      var compactionResult = newJNull()
      let summaryOpt = rt.compactSession(force = true, onEvent = proc(ev: AgentEvent) =
        if ev.kind == aekCompaction and ev.summaryText.len > 0:
          compactionResult = %*{"summary": ev.summaryText, "firstKeptEntryId": ev.firstKeptId,
            "tokensBefore": ev.tokensBefore, "estimatedTokensAfter": ev.estimatedTokensAfter,
            "usage": ev.compactionUsage.toJson(), "entriesBefore": beforeMsgs}
        emitAgentEventJson(ev), abort = currentAbort,
        customInstructions = instructions)
      for id in abortRequests: writeRpcLine(rpcOk(id, "abort"))
      abortRequests.setLen(0)
      currentAbort = nil
      compacting = false
      if summaryOpt.isSome:
        writeRpcLine(rpcOk(reqId, "compact", compactionResult))
      else:
        writeRpcLine(rpcErr(reqId, "compact", "Conversation is too short or compaction failed"))

    of "set_auto_compaction":
      rt.cfg.settings.compaction.enabled = cmdNode{"enabled"}.getBool(true)
      writeRpcLine(rpcOk(reqId, "set_auto_compaction"))

    of "set_auto_retry":
      rt.cfg.settings.retry.enabled = cmdNode{"enabled"}.getBool(true)
      writeRpcLine(rpcOk(reqId, "set_auto_retry"))

    of "bash":
      let cmdStr = cmdNode{"command"}.getStr("")
      let excludeCtx = cmdNode{"excludeFromContext"}.getBool(false)
      if cmdStr.strip().len == 0:
        writeRpcLine(rpcErr(reqId, "bash", "Missing `command`"))
      else:
        bashAbort = newAbortFlag()
        bashAbort.onIdle = drainActiveInput
        defer: bashAbort = nil
        try:
          let res = runUserShell(cmdStr, rt.cfg.cwd, rt.cfg.settings, rt.security, bashAbort,
            onOutput = proc(delta: string) =
              let update = %*{"type": "bash_execution_update", "delta": delta}
              if not reqId.isNil and reqId.kind != JNull:
                update["id"] = reqId
              writeRpcLine(update))
          let trunc = truncateHead(res.output.replace("\r\n", "\n"))
          if not excludeCtx:
            discard rt.session.appendMessage(newUserMessage(
              "<user_shell command=\"" & cmdStr & "\" exit_code=\"" & $res.exitCode & "\">\n" & trunc.content & "\n</user_shell>"
            ))
          let data = %*{"output": trunc.content, "exitCode": (if res.aborted: newJNull() else: %res.exitCode),
            "cancelled": res.aborted, "truncated": trunc.truncated}
          if trunc.truncated:
            let path = saveFullOutputTemp("bash", res.output)
            if path.len > 0: data["fullOutputPath"] = %path
            else: data["fullOutputError"] = %"Unable to save the full Bash output"
          writeRpcLine(rpcOk(reqId, "bash", data))
        except CatchableError as e:
          writeRpcLine(rpcErr(reqId, "bash", e.msg))

    of "new_session":
      let parentSess = cmdNode{"parentSession"}.getStr("")
      let sessionsRoot = rt.sessionsRoot
      rt.switchSession(newSessionManager(rt.cfg.cwd, sessionsRoot, persist = rt.session.persist, parentSessionPath = parentSess))
      writeRpcLine(rpcOk(reqId, "new_session", %*{ "cancelled": false, "sessionId": rt.session.id }))

    of "switch_session":
      let spath = cmdNode{"sessionPath"}.getStr("")
      let found = findSessionByIdOrPath(rt.sessionsRoot, rt.cfg.cwd, spath)
      if found.isNone:
        writeRpcLine(rpcErr(reqId, "switch_session", "Session not found: " & spath))
      else:
        try:
          rt.switchSession(rt.session.reopenSession(found.get))
          for diagnostic in rt.session.diagnostics:
            stderr.writeLine("Warning: " & diagnostic)
          writeRpcLine(rpcOk(reqId, "switch_session", %*{ "cancelled": false }))
        except IOError, OSError:
          writeRpcLine(rpcErr(reqId, cmdType, getCurrentExceptionMsg()))

    of "fork":
      let entryId = cmdNode{"entryId"}.getStr("")
      var selected: Option[SessionEntry]
      for entry in rt.session.activeBranchEntries():
        if entry.id == entryId and entry.kind == sekMessage and entry.message.role == mrUser:
          selected = some(entry)
          break
      if selected.isNone:
        writeRpcLine(rpcErr(reqId, cmdType, "Select a user message on the active branch to fork"))
      else:
        let text = collectText(selected.get.message.userBlocks)
        try:
          rt.switchSession(rt.session.forkSessionAtEntry(entryId, rt.sessionsRoot, before = true))
          writeRpcLine(rpcOk(reqId, cmdType, %*{"text": text, "cancelled": false, "sessionId": rt.session.id}))
        except IOError, OSError:
          writeRpcLine(rpcErr(reqId, cmdType, getCurrentExceptionMsg()))

    of "clone":
      try:
        rt.switchSession(rt.session.forkSessionAtEntry("", rt.sessionsRoot))
        writeRpcLine(rpcOk(reqId, cmdType, %*{"cancelled": false, "sessionId": rt.session.id}))
      except IOError, OSError:
        writeRpcLine(rpcErr(reqId, cmdType, getCurrentExceptionMsg()))

    of "get_fork_messages":
      let messages = newJArray()
      for entry in rt.session.entries:
        if entry.kind == sekMessage and entry.message.role == mrUser:
          var text = ""
          for blockItem in entry.message.userBlocks:
            if blockItem.kind == ckText:
              text.add(blockItem.text)
          if text.len > 0:
            messages.add(%*{"entryId": entry.id, "text": text})
      writeRpcLine(rpcOk(reqId, cmdType, %*{"messages": messages}))

    of "get_entries", "get_tree":
      let session = rt.session
      let leafId = if session.leafId.len > 0: %session.leafId else: newJNull()
      if cmdType == "get_tree":
        writeRpcLine(rpcOk(reqId, cmdType, %*{"tree": session.sessionTreeToJson(), "leafId": leafId}))
      else:
        var first = 0
        if cmdNode.hasKey("since"):
          let since = cmdNode["since"]
          if since.kind != JString:
            writeRpcLine(rpcErr(reqId, cmdType, "`since` must be an entry ID string"))
            continue
          let entryId = since.getStr()
          let index = session.indexById.getOrDefault(entryId, -1)
          if index < 0:
            writeRpcLine(rpcErr(reqId, cmdType, "Entry not found: " & entryId))
            continue
          first = index + 1
        let entries = newJArray()
        for i in first ..< session.entries.len:
          entries.add(entryToJson(session.entries[i]))
        writeRpcLine(rpcOk(reqId, cmdType, %*{"entries": entries, "leafId": leafId}))

    of "get_messages":
      let (msgs, _, _) = rt.session.buildActiveContext()
      var mArr = newJArray()
      mArr.add(AgentMessage(role: mrSystem, systemContent: rt.runtimeSystemPrompt()).toJson())
      for m in msgs:
        mArr.add(m.toJson())
      writeRpcLine(rpcOk(reqId, "get_messages", %*{ "messages": mArr }))

    of "get_last_assistant_text":
      writeRpcLine(rpcOk(reqId, "get_last_assistant_text", %*{ "text": rt.lastAssistantText }))

    of "set_session_name":
      let sname = cmdNode{"name"}.getStr("").strip()
      if sname.len > 0:
        rt.session.appendSessionName(sname)
      writeRpcLine(rpcOk(reqId, "set_session_name"))

    of "get_session_stats":
      let (msgs, _, _) = rt.session.buildActiveContext()
      let u = rt.session.totalUsage
      var userMessages, assistantMessages, toolCalls, toolResults, totalMessages: int
      for entry in rt.session.entries:
        if entry.kind != sekMessage:
          continue
        inc totalMessages
        case entry.message.role
        of mrUser: inc userMessages
        of mrAssistant:
          inc assistantMessages
          toolCalls += collectToolCalls(entry.message.assistantBlocks).len
        of mrToolResult: inc toolResults
        of mrSystem: discard
      let data = %*{
        "sessionId": rt.session.id,
        "sessionFile": rt.session.filePath,
        "entryCount": rt.session.entries.len,
        "messageCount": msgs.len,
        "userMessages": userMessages,
        "assistantMessages": assistantMessages,
        "toolCalls": toolCalls,
        "toolResults": toolResults,
        "totalMessages": totalMessages,
        "tokens": {
          "input": u.inputTokens,
          "output": u.outputTokens,
          "cacheRead": u.cacheReadTokens,
          "cacheWrite": u.cacheWriteTokens,
          "total": u.totalTokens
        },
        "cost": u.costTotal
      }
      let contextUsage = rt.buildContextUsageJson(msgs)
      if not contextUsage.isNil:
        data["contextUsage"] = contextUsage
      writeRpcLine(rpcOk(reqId, "get_session_stats", data))

    of "export_html":
      let outPath = cmdNode{"outputPath"}.getStr("")
      try:
        let written = rt.session.exportSessionToFile(outPath)
        writeRpcLine(rpcOk(reqId, "export_html", %*{ "path": written }))
      except CatchableError as e:
        writeRpcLine(rpcErr(reqId, "export_html", e.msg))

    of "get_commands":
      var cArr = newJArray()
      for sk in rt.skills:
        cArr.add(%*{
          "name": "skill:" & sk.name,
          "description": sk.description,
          "source": "skill",
          "path": sk.filePath
        })
      for tpl in rt.promptTemplates:
        cArr.add(%*{
          "name": tpl.name,
          "description": tpl.description,
          "source": "prompt",
          "path": tpl.filePath
        })
      writeRpcLine(rpcOk(reqId, "get_commands", %*{ "commands": cArr }))

    else:
      writeRpcLine(rpcErr(reqId, cmdType, "Unsupported RPC command: " & cmdType))

  joinThread(reader)
  input.close()
  0
