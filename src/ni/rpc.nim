# Headless JSONL RPC mode (`ni --mode rpc`) compatible with Pi's stdin/stdout embedding protocol.

import std/[json, options, strutils, tables]
import ./[types, config, provider, tools, skills, session, agent, tui]

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
    "steeringMode": "one-at-a-time",
    "followUpMode": "one-at-a-time",
    "sessionId": rt.session.id,
    "autoCompactionEnabled": rt.cfg.settings.compaction.enabled,
    "messageCount": msgs.len,
    "pendingMessageCount": rt.steeringQueue.len + rt.followUpQueue.len
  }
  if rt.session.filePath.len > 0:
    result["sessionFile"] = %rt.session.filePath
  if rt.session.displayName.len > 0:
    result["sessionName"] = %rt.session.displayName

proc buildRpcAskQuestionBridge(): AskQuestionCallback =
  ## Bridge `ask_question` tool calls over RPC `extension_ui_request` / `extension_ui_response` messages.
  result = proc(questions: seq[AskQuestionItem]): seq[AskQuestionAnswer] =
    for q in questions:
      let reqUuid = "rpc_ui_" & genShortId()
      var optsArr = newJArray()
      for opt in q.options:
        optsArr.add(%opt.label)
      writeRpcLine(%*{
        "type": "extension_ui_request",
        "id": reqUuid,
        "method": "select",
        "title": q.question,
        "options": optsArr
      })
      var rawLine = ""
      var answered = false
      while stdin.readLine(rawLine):
        let trimmed = rawLine.strip()
        if trimmed.len == 0:
          continue
        let j = try: parseJson(trimmed) except CatchableError: nil
        if not j.isNil and j.kind == JObject and j{"type"}.getStr("") == "extension_ui_response" and
           j{"id"}.getStr("") == reqUuid:
          let cancelled = j{"cancelled"}.getBool(false)
          let val = j{"value"}.getStr("")
          result.add(AskQuestionAnswer(
            id: q.id,
            question: q.question,
            selected: (if not cancelled and val.len > 0: @[val] else: @[]),
            customText: val,
            cancelled: cancelled
          ))
          answered = true
          break
      if not answered:
        result.add(AskQuestionAnswer(id: q.id, question: q.question, cancelled: true))
        break

proc runRpcMode*(rt: AgentRuntime): int =
  ## Listen for JSONL RPC commands on stdin and emit responses + streaming events as JSONL on stdout.
  if rt.askQuestion.isNil:
    rt.askQuestion = buildRpcAskQuestionBridge()

  var currentAbort: AbortFlag = nil
  var line = ""

  while stdin.readLine(line):
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue

    let cmdNode = try: parseJson(trimmed) except CatchableError as e:
      writeRpcLine(rpcErr(nil, "parse", "Invalid JSON command: " & e.msg))
      continue

    if cmdNode.kind != JObject:
      writeRpcLine(rpcErr(nil, "parse", "RPC command must be a JSON object"))
      continue

    let reqId = if cmdNode.hasKey("id"): cmdNode["id"] else: nil
    let cmdType = cmdNode{"type"}.getStr("")
    if cmdType.len == 0:
      writeRpcLine(rpcErr(reqId, "unknown", "Missing `type` field on RPC command"))
      continue

    case cmdType
    of "get_state":
      writeRpcLine(rpcOk(reqId, "get_state", buildRpcStateJson(rt)))

    of "prompt":
      let message = cmdNode{"message"}.getStr("")
      var extraImgs: seq[ContentBlock] = @[]
      if cmdNode.hasKey("images") and cmdNode["images"].kind == JArray:
        for imgNode in cmdNode["images"].items:
          if imgNode.kind == JObject:
            let d = imgNode{"data"}.getStr("")
            let mime = imgNode{"mimeType"}.getStr("image/png")
            if d.len > 0:
              extraImgs.add(imageBlock(d, mime))

      writeRpcLine(rpcOk(reqId, "prompt", %*{ "disposition": "started" }))

      currentAbort = newAbortFlag()
      discard rt.runPrompt(message, onEvent = emitAgentEventJson, abort = currentAbort, extraImages = extraImgs)
      currentAbort = nil

    of "steer":
      let msg = cmdNode{"message"}.getStr("")
      if msg.len > 0:
        rt.steeringQueue.add(msg)
      writeRpcLine(rpcOk(reqId, "steer", %*{ "disposition": "queued" }))

    of "follow_up":
      let msg = cmdNode{"message"}.getStr("")
      if msg.len > 0:
        rt.followUpQueue.add(msg)
      writeRpcLine(rpcOk(reqId, "follow_up", %*{ "disposition": "queued" }))

    of "clear_queue":
      var sArr = newJArray()
      for s in rt.steeringQueue: sArr.add(%s)
      var fArr = newJArray()
      for f in rt.followUpQueue: fArr.add(%f)
      rt.steeringQueue.setLen(0)
      rt.followUpQueue.setLen(0)
      writeRpcLine(rpcOk(reqId, "clear_queue", %*{ "steering": sArr, "followUp": fArr }))

    of "abort":
      if not currentAbort.isNil:
        currentAbort.aborted = true
      writeRpcLine(rpcOk(reqId, "abort"))

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

    of "set_steering_mode":
      writeRpcLine(rpcOk(reqId, "set_steering_mode"))

    of "set_follow_up_mode":
      writeRpcLine(rpcOk(reqId, "set_follow_up_mode"))

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

  0
