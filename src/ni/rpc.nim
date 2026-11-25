# Headless JSONL RPC mode (`ni --mode rpc`) compatible with Pi's stdin/stdout embedding protocol.

import std/[deques, json, options, strutils, tables]
import ./[types, config, provider, tools, skills, session, agent, tui]

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
  stdout.writeLine($node)
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
  var abortRequests: seq[JsonNode] = @[]

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
      writeRpcLine(rpcOk(cmd.id, cmd.kind, buildRpcStateJson(rt, isStreaming = active)))
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
    of "clear_queue":
      var steering = newJArray()
      for prompt in rt.steeringQueue: steering.add(%prompt.text)
      var followUp = newJArray()
      for prompt in rt.followUpQueue: followUp.add(%prompt.text)
      rt.steeringQueue.setLen(0)
      rt.followUpQueue.setLen(0)
      writeRpcLine(rpcOk(cmd.id, cmd.kind, %*{ "steering": steering, "followUp": followUp }))
    of "abort":
      if active:
        currentAbort.aborted = true
        abortRequests.add(cmd.id)
      else:
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
      if mid.len == 0 and prov.len == 0:
        writeRpcLine(rpcErr(reqId, "set_model", "Missing `modelId` or `provider`"))
      else:
        let (m, _) = rt.providerRegistry.resolveModel(rt.cfg, mid, prov, rt.cliApiKey)
        rt.switchModel(m)
        writeRpcLine(rpcOk(reqId, "set_model", modelToRpcJson(m)))

    of "get_available_models":
      var arr = newJArray()
      for _, prov in rt.providerRegistry.providers.pairs:
        for m in prov.models:
          arr.add(modelToRpcJson(m))
      writeRpcLine(rpcOk(reqId, "get_available_models", %*{ "models": arr }))

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
      let summaryOpt = rt.compactSession(force = true)
      if summaryOpt.isSome:
        writeRpcLine(rpcOk(reqId, "compact", %*{ "summary": summaryOpt.get, "entriesBefore": beforeMsgs }))
      else:
        writeRpcLine(rpcErr(reqId, "compact", "Conversation is too short or compaction failed"))

    of "set_auto_compaction":
      rt.cfg.settings.compaction.enabled = cmdNode{"enabled"}.getBool(true)
      writeRpcLine(rpcOk(reqId, "set_auto_compaction"))

    of "set_auto_retry":
      rt.cfg.settings.retry.enabled = cmdNode{"enabled"}.getBool(true)
      writeRpcLine(rpcOk(reqId, "set_auto_retry"))

    of "abort_retry":
      writeRpcLine(rpcOk(reqId, "abort_retry"))

    of "bash":
      let cmdStr = cmdNode{"command"}.getStr("")
      let excludeCtx = cmdNode{"excludeFromContext"}.getBool(false)
      if cmdStr.strip().len == 0:
        writeRpcLine(rpcErr(reqId, "bash", "Missing `command`"))
      else:
        let (exe, baseArgs) = resolveBashShell(rt.cfg.settings.shellPath)
        let res = runProcessCapture(exe, baseArgs & @[cmdStr], rt.cfg.cwd, nil, 0.0, nil)
        if not excludeCtx:
          let trunc = truncateHead(res.output.replace("\r\n", "\n"))
          discard rt.session.appendMessage(newUserMessage(
            "<user_shell command=\"" & cmdStr & "\" exit_code=\"" & $res.exitCode & "\">\n" & trunc.content & "\n</user_shell>"
          ))
        writeRpcLine(rpcOk(reqId, "bash", %*{
          "output": res.output,
          "exitCode": res.exitCode,
          "cancelled": res.aborted,
          "truncated": false
        }))

    of "new_session":
      let parentSess = cmdNode{"parentSession"}.getStr("")
      let sessionsRoot = resolveSessionsRoot(rt.cfg)
      rt.session = newSessionManager(rt.cfg.cwd, sessionsRoot, persist = rt.session.persist, parentSessionPath = parentSess)
      writeRpcLine(rpcOk(reqId, "new_session", %*{ "cancelled": false, "sessionId": rt.session.id }))

    of "switch_session":
      let spath = cmdNode{"sessionPath"}.getStr("")
      let found = findSessionByIdOrPath(resolveSessionsRoot(rt.cfg), rt.cfg.cwd, spath)
      if found.isNone:
        writeRpcLine(rpcErr(reqId, "switch_session", "Session not found: " & spath))
      else:
        rt.session = loadSessionFile(found.get, persist = rt.session.persist)
        writeRpcLine(rpcOk(reqId, "switch_session", %*{ "cancelled": false }))

    of "fork", "clone":
      let entryId = cmdNode{"entryId"}.getStr("")
      rt.session = rt.session.forkSessionAtEntry(entryId, resolveSessionsRoot(rt.cfg))
      writeRpcLine(rpcOk(reqId, cmdType, %*{ "text": "", "cancelled": false, "sessionId": rt.session.id }))

    of "get_tree":
      var tArr = newJArray()
      for item in rt.session.buildSessionTreeItems():
        tArr.add(%*{
          "id": item.entryId,
          "parentId": (if item.parentId.len > 0: %item.parentId else: newJNull()),
          "depth": item.depth,
          "role": item.roleLabel,
          "preview": item.preview,
          "isActivePath": item.isActivePath,
          "isCurrentLeaf": item.isCurrentLeaf
        })
      writeRpcLine(rpcOk(reqId, "get_tree", %*{ "tree": tArr, "leafId": rt.session.leafId }))

    of "get_messages":
      let (msgs, _, _) = rt.session.buildActiveContext()
      var mArr = newJArray()
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
      writeRpcLine(rpcOk(reqId, "get_session_stats", %*{
        "sessionId": rt.session.id,
        "sessionFile": rt.session.filePath,
        "entryCount": rt.session.entries.len,
        "messageCount": msgs.len,
        "tokens": {
          "input": u.inputTokens,
          "output": u.outputTokens,
          "cacheRead": u.cacheReadTokens,
          "cacheWrite": u.cacheWriteTokens,
          "total": u.totalTokens
        },
        "cost": u.costTotal
      }))

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
