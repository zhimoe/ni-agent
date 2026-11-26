# Pi v3 compatible JSONL tree session manager (persistence, branching, resume, fork, and compaction).

import std/[algorithm, json, options, os, random, strutils, tables, times]
import ./[types, config, utf8]

const SessionFormatVersion* = 3

type
  SessionEntryKind* = enum
    sekMessage = "message"
    sekModelChange = "model_change"
    sekThinkingChange = "thinking_level_change"
    sekCompaction = "compaction"
    sekSessionInfo = "session_info"
    sekLabel = "label"

  SessionEntry* = object
    id*: string
    parentId*: string
    timestamp*: string
    case kind*: SessionEntryKind
    of sekMessage:
      message*: AgentMessage
    of sekModelChange:
      provider*: string
      modelId*: string
    of sekThinkingChange:
      thinkingLevel*: ThinkingLevel
    of sekCompaction:
      summary*: string
      firstKeptEntryId*: string
      tokensBefore*: int
    of sekSessionInfo:
      name*: string
    of sekLabel:
      targetId*: string
      label*: Option[string]

  SessionSummaryInfo* = object
    id*: string
    filePath*: string
    cwd*: string
    timestamp*: string
    displayName*: string
    messageCount*: int
    modifiedTime*: Time

  SessionManager* = ref object
    id*: string
    cwd*: string
    parentSessionPath*: string
    filePath*: string
    persist*: bool
    createdAtIso*: string
    displayName*: string
    entries*: seq[SessionEntry]
    indexById*: Table[string, int]
    leafId*: string
    totalUsage*: Usage

var rngInitialized = false

proc ensureRng() =
  if not rngInitialized:
    randomize()
    rngInitialized = true

proc genShortId*(): string =
  ## Generate an 8-character lowercase hex entry ID matching Pi's session entries.
  ensureRng()
  const hexChars = "0123456789abcdef"
  result = newString(8)
  for i in 0 ..< 8:
    result[i] = hexChars[rand(15)]

proc genSessionUuid*(): string =
  ## Generate a random v4-style UUID for session headers and filenames.
  ensureRng()
  const hexChars = "0123456789abcdef"
  let lengths = [8, 4, 4, 4, 12]
  var parts: seq[string] = @[]
  for segLen in lengths:
    var s = newString(segLen)
    for i in 0 ..< segLen:
      s[i] = hexChars[rand(15)]
    parts.add(s)
  parts[2][0] = '4'
  parts.join("-")

proc sanitizeCwdBucket*(cwd: string): string =
  ## Encode workspace directory as `--<sanitized-path>--` matching Pi's session folder convention.
  var clean = normalizedPath(cwd).strip(chars = {'/', '\\'}, leading = true, trailing = true)
  var buf = newStringOfCap(clean.len + 4)
  buf.add("--")
  for ch in clean:
    if ch in {'/', '\\', ':'}:
      buf.add('-')
    else:
      buf.add(ch)
  buf.add("--")
  buf

proc resolveSessionsRoot*(cfg: ConfigBundle, cliSessionDir = ""): string =
  ## Resolve root sessions directory (--session-dir -> $PI_CODING_AGENT_SESSION_DIR -> settings.sessionDir -> ~/.pi/agent/sessions).
  if cliSessionDir.strip().len > 0:
    return resolvePathFrom(cliSessionDir, cfg.cwd)
  let envDir = getEnv("PI_CODING_AGENT_SESSION_DIR").strip()
  if envDir.len > 0:
    return resolvePathFrom(envDir, cfg.cwd)
  if cfg.settings.sessionDir.len > 0:
    return cfg.settings.sessionDir
  cfg.agentDir / "sessions"

proc entryToJson*(e: SessionEntry): JsonNode =
  ## Serialize a session entry in the JSONL format shared with Pi.
  result = %*{
    "type": $e.kind,
    "id": e.id,
    "parentId": (if e.parentId.len > 0: %e.parentId else: newJNull()),
    "timestamp": e.timestamp
  }
  case e.kind
  of sekMessage:
    result["message"] = e.message.toJson()
  of sekModelChange:
    result["provider"] = %e.provider
    result["modelId"] = %e.modelId
  of sekThinkingChange:
    result["thinkingLevel"] = %($e.thinkingLevel)
  of sekCompaction:
    result["summary"] = %e.summary
    result["firstKeptEntryId"] = %e.firstKeptEntryId
    result["tokensBefore"] = %e.tokensBefore
  of sekSessionInfo:
    result["name"] = %e.name
  of sekLabel:
    result["targetId"] = %e.targetId
    if e.label.isSome:
      result["label"] = %e.label.get

proc parseEntryJson(node: JsonNode): Option[SessionEntry] =
  if node.isNil or node.kind != JObject:
    return none(SessionEntry)
  let t = node{"type"}.getStr("")
  let id = node{"id"}.getStr("")
  if id.len == 0:
    return none(SessionEntry)
  let pid = if node.hasKey("parentId") and node["parentId"].kind == JString:
    node["parentId"].getStr()
  else:
    ""
  let ts = node{"timestamp"}.getStr("")

  case t
  of "message":
    let msgOpt = parseAgentMessage(node{"message"})
    if msgOpt.isNone:
      return none(SessionEntry)
    some(SessionEntry(id: id, parentId: pid, timestamp: ts, kind: sekMessage, message: msgOpt.get))
  of "model_change":
    some(SessionEntry(
      id: id, parentId: pid, timestamp: ts, kind: sekModelChange,
      provider: node{"provider"}.getStr(""),
      modelId: node{"modelId"}.getStr("")
    ))
  of "thinking_level_change":
    some(SessionEntry(
      id: id, parentId: pid, timestamp: ts, kind: sekThinkingChange,
      thinkingLevel: parseThinkingLevel(node{"thinkingLevel"}.getStr("medium"))
    ))
  of "compaction":
    some(SessionEntry(
      id: id, parentId: pid, timestamp: ts, kind: sekCompaction,
      summary: node{"summary"}.getStr(""),
      firstKeptEntryId: node{"firstKeptEntryId"}.getStr(id),
      tokensBefore: node{"tokensBefore"}.getInt(0)
    ))
  of "session_info":
    some(SessionEntry(
      id: id, parentId: pid, timestamp: ts, kind: sekSessionInfo,
      name: node{"name"}.getStr("")
    ))
  of "label":
    let label = node{"label"}
    some(SessionEntry(
      id: id, parentId: pid, timestamp: ts, kind: sekLabel,
      targetId: node{"targetId"}.getStr(""),
      label: (if not label.isNil and label.kind == JString: some(label.getStr()) else: none(string))
    ))
  else:
    none(SessionEntry)

proc writeHeaderIfNeeded(sm: SessionManager) =
  if not sm.persist or sm.filePath.len == 0 or fileExists(sm.filePath):
    return
  createDir(parentDir(sm.filePath))
  var hdr = %*{
    "type": "session",
    "version": SessionFormatVersion,
    "id": sm.id,
    "timestamp": sm.createdAtIso,
    "cwd": sm.cwd
  }
  if sm.parentSessionPath.len > 0:
    hdr["parentSession"] = %sm.parentSessionPath
  writeFile(sm.filePath, replaceInvalidUtf8($hdr) & "\n")

proc appendRawEntry(sm: SessionManager, entry: SessionEntry) =
  var e = entry
  while sm.indexById.hasKey(e.id):
    e.id = genShortId()
  sm.indexById[e.id] = sm.entries.len
  sm.entries.add(e)
  sm.leafId = e.id

  if e.kind == sekMessage and e.message.role == mrAssistant:
    sm.totalUsage.inputTokens += e.message.usage.inputTokens
    sm.totalUsage.outputTokens += e.message.usage.outputTokens
    sm.totalUsage.cacheReadTokens += e.message.usage.cacheReadTokens
    sm.totalUsage.cacheWriteTokens += e.message.usage.cacheWriteTokens
    sm.totalUsage.totalTokens += e.message.usage.totalTokens
    sm.totalUsage.costTotal += e.message.usage.costTotal
  elif e.kind == sekSessionInfo and e.name.len > 0:
    sm.displayName = e.name

  if sm.persist and sm.filePath.len > 0:
    sm.writeHeaderIfNeeded()
    let f = open(sm.filePath, fmAppend)
    defer: f.close()
    f.writeLine(replaceInvalidUtf8($entryToJson(e)))

proc newSessionManager*(
  cwd: string,
  sessionsRoot: string,
  persist = true,
  customSessionId = "",
  sessionName = "",
  parentSessionPath = ""
): SessionManager =
  ## Create a new empty SessionManager (persisted lazily on first entry, matching Pi).
  let sid = if customSessionId.strip().len > 0: customSessionId.strip() else: genSessionUuid()
  let tsIso = nowIsoUtc()
  let fileStamp = now().utc.format("yyyyMMdd'T'HHmmss")
  let bucketDir = sessionsRoot / sanitizeCwdBucket(cwd)
  let fpath = if persist: bucketDir / (fileStamp & "_" & sid & ".jsonl") else: ""

  result = SessionManager(
    id: sid,
    cwd: normalizedPath(cwd),
    parentSessionPath: parentSessionPath,
    filePath: fpath,
    persist: persist,
    createdAtIso: tsIso,
    displayName: sessionName,
    entries: @[],
    indexById: initTable[string, int](),
    leafId: "",
    totalUsage: Usage()
  )
  if sessionName.strip().len > 0:
    result.appendRawEntry(SessionEntry(
      id: genShortId(),
      parentId: "",
      timestamp: nowIsoUtc(),
      kind: sekSessionInfo,
      name: sessionName.strip()
    ))

proc loadSessionFile*(path: string, persist = true): SessionManager =
  ## Load an existing Pi v3 JSONL session file and reconstruct its tree and leaf state.
  # Older versions could write raw bytes from files or command output into JSONL.
  let raw = replaceInvalidUtf8(stripUtf8Bom(readFile(path)))
  let lines = raw.replace("\r\n", "\n").split('\n')

  result = SessionManager(
    id: genSessionUuid(),
    cwd: getCurrentDir(),
    filePath: normalizedPath(absolutePath(path)),
    persist: persist,
    createdAtIso: nowIsoUtc(),
    entries: @[],
    indexById: initTable[string, int](),
    leafId: "",
    totalUsage: Usage()
  )

  for line in lines:
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    let node = try: parseJson(trimmed) except CatchableError: continue
    if node.kind != JObject:
      continue
    if node{"type"}.getStr("") == "session":
      result.id = node{"id"}.getStr(result.id)
      result.cwd = node{"cwd"}.getStr(result.cwd)
      result.createdAtIso = node{"timestamp"}.getStr(result.createdAtIso)
      result.parentSessionPath = node{"parentSession"}.getStr("")
      continue

    let parsed = parseEntryJson(node)
    if parsed.isSome:
      let e = parsed.get
      result.indexById[e.id] = result.entries.len
      result.entries.add(e)
      result.leafId = e.id
      if e.kind == sekSessionInfo and e.name.len > 0:
        result.displayName = e.name
      elif e.kind == sekMessage and e.message.role == mrAssistant:
        result.totalUsage.inputTokens += e.message.usage.inputTokens
        result.totalUsage.outputTokens += e.message.usage.outputTokens
        result.totalUsage.cacheReadTokens += e.message.usage.cacheReadTokens
        result.totalUsage.cacheWriteTokens += e.message.usage.cacheWriteTokens
        result.totalUsage.totalTokens += e.message.usage.totalTokens
        result.totalUsage.costTotal += e.message.usage.costTotal

proc appendMessage*(sm: SessionManager, msg: AgentMessage): string =
  ## Append a message node as a child of the current leaf and return its entry ID.
  let e = SessionEntry(
    id: genShortId(),
    parentId: sm.leafId,
    timestamp: nowIsoUtc(),
    kind: sekMessage,
    message: msg
  )
  sm.appendRawEntry(e)
  sm.leafId

proc appendModelChange*(sm: SessionManager, provider, modelId: string) =
  sm.appendRawEntry(SessionEntry(
    id: genShortId(),
    parentId: sm.leafId,
    timestamp: nowIsoUtc(),
    kind: sekModelChange,
    provider: provider,
    modelId: modelId
  ))

proc appendThinkingChange*(sm: SessionManager, level: ThinkingLevel) =
  sm.appendRawEntry(SessionEntry(
    id: genShortId(),
    parentId: sm.leafId,
    timestamp: nowIsoUtc(),
    kind: sekThinkingChange,
    thinkingLevel: level
  ))

proc appendSessionName*(sm: SessionManager, name: string) =
  sm.appendRawEntry(SessionEntry(
    id: genShortId(),
    parentId: sm.leafId,
    timestamp: nowIsoUtc(),
    kind: sekSessionInfo,
    name: name
  ))

proc appendCompaction*(sm: SessionManager, summary, firstKeptEntryId: string, tokensBefore: int): string =
  ## Append a context compaction summary entry on the active branch.
  let id = genShortId()
  let kept = if firstKeptEntryId.len > 0: firstKeptEntryId else: id
  sm.appendRawEntry(SessionEntry(
    id: id,
    parentId: sm.leafId,
    timestamp: nowIsoUtc(),
    kind: sekCompaction,
    summary: summary,
    firstKeptEntryId: kept,
    tokensBefore: tokensBefore
  ))
  sm.leafId

proc branchTo*(sm: SessionManager, targetEntryId: string): bool =
  ## Move the active leaf pointer to an earlier entry (or "" for a fresh root branch).
  if targetEntryId.len == 0:
    sm.leafId = ""
    return true
  if sm.indexById.hasKey(targetEntryId):
    sm.leafId = targetEntryId
    return true
  false

proc activeBranchEntries*(sm: SessionManager): seq[SessionEntry] =
  ## Walk parentId links from leafId back to the root and return entries in chronological order.
  var rev: seq[SessionEntry] = @[]
  var cur = sm.leafId
  var guard = 0
  while cur.len > 0 and sm.indexById.hasKey(cur) and guard <= sm.entries.len:
    inc guard
    let e = sm.entries[sm.indexById[cur]]
    rev.add(e)
    cur = e.parentId
  for i in countdown(rev.high, 0):
    result.add(rev[i])

proc buildActiveContext*(sm: SessionManager): tuple[
  messages: seq[AgentMessage],
  lastModel: Option[tuple[provider, modelId: string]],
  lastThinking: Option[ThinkingLevel]
] =
  ## Reconstruct LLM-ready message history from the active branch, honoring the latest CompactionEntry.
  let branch = sm.activeBranchEntries()
  var lastModel = none(tuple[provider, modelId: string])
  var lastThinking = none(ThinkingLevel)
  var latestCompactionIdx = -1

  for i, e in branch.pairs:
    case e.kind
    of sekModelChange:
      lastModel = some((e.provider, e.modelId))
    of sekThinkingChange:
      lastThinking = some(e.thinkingLevel)
    of sekCompaction:
      latestCompactionIdx = i
    else:
      discard

  var msgs: seq[AgentMessage] = @[]
  if latestCompactionIdx >= 0:
    let comp = branch[latestCompactionIdx]
    msgs.add(newUserMessage("<conversation_summary>\nSummary of earlier conversation context:\n" &
                            comp.summary & "\n</conversation_summary>"))
    var keepFrom = latestCompactionIdx + 1
    if comp.firstKeptEntryId != comp.id:
      for j in 0 ..< latestCompactionIdx:
        if branch[j].id == comp.firstKeptEntryId:
          keepFrom = j
          break
    for j in keepFrom ..< branch.len:
      if j == latestCompactionIdx:
        continue
      if branch[j].kind == sekMessage and branch[j].message.role != mrSystem:
        msgs.add(branch[j].message)
  else:
    for e in branch:
      if e.kind == sekMessage and e.message.role != mrSystem:
        msgs.add(e.message)

  (msgs, lastModel, lastThinking)

# Session discovery, continue, resume, and fork helpers

proc summarizeSessionFile(path: string): Option[SessionSummaryInfo] =
  if not fileExists(path):
    return none(SessionSummaryInfo)
  try:
    let mtime = getLastModificationTime(path)
    let raw = replaceInvalidUtf8(stripUtf8Bom(readFile(path)))
    var sid = extractFilename(path)
    var cwd = ""
    var ts = ""
    var customName = ""
    var firstPrompt = ""
    var msgCount = 0

    for line in raw.replace("\r\n", "\n").split('\n'):
      let t = line.strip()
      if t.len == 0: continue
      let node = try: parseJson(t) except CatchableError: continue
      if node.kind != JObject: continue
      case node{"type"}.getStr("")
      of "session":
        sid = node{"id"}.getStr(sid)
        cwd = node{"cwd"}.getStr("")
        ts = node{"timestamp"}.getStr("")
      of "session_info":
        let n = node{"name"}.getStr("")
        if n.len > 0: customName = n
      of "message":
        inc msgCount
        if firstPrompt.len == 0 and node.hasKey("message") and node["message"]{"role"}.getStr("") == "user":
          let c = node["message"]{"content"}
          if not c.isNil:
            if c.kind == JString:
              firstPrompt = c.getStr().strip().splitLines()[0]
            elif c.kind == JArray and c.len > 0 and c[0].kind == JObject:
              firstPrompt = c[0]{"text"}.getStr("").strip().splitLines()[0]
      else:
        discard

    var disp = if customName.len > 0: customName
               elif firstPrompt.len > 0: firstPrompt
               else: sid
    if disp.len > 72:
      disp = disp[0 ..< 69] & "..."

    return some(SessionSummaryInfo(
      id: sid,
      filePath: normalizedPath(absolutePath(path)),
      cwd: cwd,
      timestamp: ts,
      displayName: disp,
      messageCount: msgCount,
      modifiedTime: mtime
    ))
  except CatchableError:
    return none(SessionSummaryInfo)

proc listSessions*(sessionsRoot: string, cwdFilter = ""): seq[SessionSummaryInfo] =
  ## List saved sessions sorted newest-first, optionally restricted to cwdFilter's bucket.
  if not dirExists(sessionsRoot):
    return @[]
  var dirsToScan: seq[string] = @[]
  if cwdFilter.len > 0:
    let bucket = sessionsRoot / sanitizeCwdBucket(cwdFilter)
    if dirExists(bucket):
      dirsToScan.add(bucket)
  else:
    for kind, d in walkDir(sessionsRoot):
      if kind in {pcDir, pcLinkToDir}:
        dirsToScan.add(d)

  for d in dirsToScan:
    try:
      for kind, f in walkDir(d):
        if kind in {pcFile, pcLinkToFile} and f.endsWith(".jsonl"):
          let s = summarizeSessionFile(f)
          if s.isSome:
            result.add(s.get)
    except CatchableError:
      discard

  result.sort(proc(a, b: SessionSummaryInfo): int = cmp(b.modifiedTime, a.modifiedTime))

proc findSessionByIdOrPath*(sessionsRoot, cwd, spec: string): Option[string] =
  ## Locate a session file by direct file path or full/prefix session ID.
  let resolved = resolvePathFrom(spec, cwd)
  if fileExists(resolved):
    return some(resolved)

  for scopeCwd in [cwd, ""]:
    for info in listSessions(sessionsRoot, scopeCwd):
      if info.id == spec or info.id.startsWith(spec) or extractFilename(info.filePath).contains(spec):
        return some(info.filePath)
  none(string)

proc forkSession*(sourcePath, targetCwd, sessionsRoot: string, customSessionId = ""): SessionManager =
  ## Copy active branch entries of sourcePath into a brand-new session file in targetCwd.
  let src = loadSessionFile(sourcePath, persist = false)
  result = newSessionManager(
    cwd = targetCwd,
    sessionsRoot = sessionsRoot,
    persist = true,
    customSessionId = customSessionId,
    sessionName = (if src.displayName.len > 0: src.displayName & " (fork)" else: ""),
    parentSessionPath = src.filePath
  )
  for e in src.activeBranchEntries():
    if e.kind == sekSessionInfo:
      continue
    var copyEntry = e
    copyEntry.parentId = result.leafId
    result.appendRawEntry(copyEntry)

# Interactive tree navigation, in-memory entry forking, and Markdown / HTML session export

type
  SessionTreeItem* = object
    entryId*: string
    parentId*: string
    depth*: int
    roleLabel*: string
    preview*: string
    isActivePath*: bool
    isCurrentLeaf*: bool

proc buildSessionTreeItems*(sm: SessionManager): seq[SessionTreeItem] =
  ## Flatten the session entry tree in DFS chronological order for `/tree` navigation.
  if sm.entries.len == 0:
    return @[]

  var activeIds = initTable[string, bool]()
  for ae in sm.activeBranchEntries():
    activeIds[ae.id] = true

  var childrenByParent = initTable[string, seq[int]]()
  for idx, e in sm.entries.pairs:
    let pid = e.parentId
    if not childrenByParent.hasKey(pid):
      childrenByParent[pid] = @[]
    childrenByParent[pid].add(idx)

  proc entrySummary(e: SessionEntry): tuple[roleLabel: string, preview: string] =
    case e.kind
    of sekMessage:
      case e.message.role
      of mrUser:
        let first = collectText(e.message.userBlocks).strip().splitLines()[0]
        ("user", if first.len > 64: first[0 ..< 61] & "..." else: first)
      of mrAssistant:
        let tcs = collectToolCalls(e.message.assistantBlocks)
        let txt = collectText(e.message.assistantBlocks).strip()
        if txt.len > 0:
          let first = txt.splitLines()[0]
          ("assistant", if first.len > 64: first[0 ..< 61] & "..." else: first)
        elif tcs.len > 0:
          var names: seq[string] = @[]
          for tc in tcs: names.add(tc.name)
          ("assistant", "tools: " & names.join(", "))
        else:
          ("assistant", "(empty)")
      of mrToolResult:
        ("tool:" & e.message.toolName, (if e.message.isError: "error" else: "ok"))
      of mrSystem:
        ("system", e.message.systemContent.strip().splitLines()[0])
    of sekModelChange:
      ("model", e.provider & "/" & e.modelId)
    of sekThinkingChange:
      ("thinking", $e.thinkingLevel)
    of sekCompaction:
      ("compaction", $e.tokensBefore & " tokens summarized")
    of sekSessionInfo:
      ("info", e.name)
    of sekLabel:
      ("label", e.label.get(""))

  proc walk(
    parentId: string,
    depth: int,
    entries: seq[SessionEntry],
    childrenByParent: Table[string, seq[int]],
    activeIds: Table[string, bool],
    leafId: string,
    outItems: var seq[SessionTreeItem]
  ) =
    if not childrenByParent.hasKey(parentId):
      return
    let kids = childrenByParent[parentId]
    let branchExtra = if kids.len > 1: 1 else: 0
    for idx in kids:
      let e = entries[idx]
      let (rl, pv) = entrySummary(e)
      outItems.add(SessionTreeItem(
        entryId: e.id,
        parentId: e.parentId,
        depth: depth,
        roleLabel: rl,
        preview: pv,
        isActivePath: activeIds.hasKey(e.id),
        isCurrentLeaf: e.id == leafId
      ))
      walk(e.id, depth + branchExtra, entries, childrenByParent, activeIds, leafId, outItems)

  walk("", 0, sm.entries, childrenByParent, activeIds, sm.leafId, result)

proc sessionTreeToJson*(sm: SessionManager): JsonNode =
  ## Serialize every branch with its entries and the latest label for each node.
  var labels = initTable[string, tuple[text, timestamp: string]]()
  for e in sm.entries:
    if e.kind == sekLabel:
      let label = e.label.get("")
      if label.len > 0:
        labels[e.targetId] = (label, e.timestamp)
      else:
        labels.del(e.targetId)

  var nodes = newSeqOfCap[JsonNode](sm.entries.len)
  for e in sm.entries:
    let node = %*{"entry": entryToJson(e), "children": []}
    if labels.hasKey(e.id):
      let label = labels[e.id]
      node["label"] = %label.text
      node["labelTimestamp"] = %label.timestamp
    nodes.add(node)

  result = newJArray()
  for i, e in sm.entries:
    let parent = sm.indexById.getOrDefault(e.parentId, -1)
    if parent < 0 or e.parentId == e.id:
      result.add(nodes[i])
    else:
      nodes[parent]["children"].add(nodes[i])

  for node in nodes:
    node["children"].elems.sort(proc(a, b: JsonNode): int =
      # Both Ni and Pi write timestamps in the same UTC ISO format.
      cmp(a["entry"]["timestamp"].getStr(), b["entry"]["timestamp"].getStr())
    )

proc forkSessionAtEntry*(sm: SessionManager, targetEntryId: string, sessionsRoot: string): SessionManager =
  ## Fork an open SessionManager from targetEntryId (or current leaf when empty) into a new session file.
  let savedLeaf = sm.leafId
  if targetEntryId.len > 0 and sm.indexById.hasKey(targetEntryId):
    sm.leafId = targetEntryId
  let branch = sm.activeBranchEntries()
  sm.leafId = savedLeaf

  result = newSessionManager(
    cwd = sm.cwd,
    sessionsRoot = sessionsRoot,
    persist = sm.persist,
    sessionName = (if sm.displayName.len > 0: sm.displayName & " (fork)" else: ""),
    parentSessionPath = sm.filePath
  )
  for e in branch:
    if e.kind == sekSessionInfo:
      continue
    var copyEntry = e
    copyEntry.parentId = result.leafId
    result.appendRawEntry(copyEntry)

proc escapeHtml(s: string): string =
  result = newStringOfCap(s.len + 16)
  for ch in s:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    else: result.add(ch)

proc exportSessionMarkdown*(sm: SessionManager): string =
  ## Export the active conversation branch as a readable Markdown document.
  var lines: seq[string] = @[]
  let title = if sm.displayName.len > 0: sm.displayName else: "ni Session " & sm.id
  lines.add("# " & title)
  lines.add("")
  lines.add("- **Session ID**: `" & sm.id & "`")
  lines.add("- **Workspace**: `" & sm.cwd & "`")
  lines.add("- **Tokens**: " & $sm.totalUsage.totalTokens & " ($" & formatFloat(sm.totalUsage.costTotal, ffDecimal, 4) & ")")
  lines.add("")
  lines.add("---")
  lines.add("")

  for e in sm.activeBranchEntries():
    case e.kind
    of sekMessage:
      let m = e.message
      case m.role
      of mrUser:
        lines.add("## User")
        lines.add("")
        lines.add(collectText(m.userBlocks))
        lines.add("")
      of mrAssistant:
        lines.add("## Assistant (`" & m.provider & "/" & m.model & "`)")
        lines.add("")
        let th = collectThinking(m.assistantBlocks)
        if th.len > 0:
          lines.add("<details><summary>Thinking</summary>\n\n" & th & "\n\n</details>")
          lines.add("")
        let txt = collectText(m.assistantBlocks)
        if txt.len > 0:
          lines.add(txt)
          lines.add("")
        for tc in collectToolCalls(m.assistantBlocks):
          lines.add("- Tool Call `" & tc.name & "`: `" & (if tc.arguments.isNil: "{}" else: $tc.arguments) & "`")
        if collectToolCalls(m.assistantBlocks).len > 0:
          lines.add("")
      of mrToolResult:
        if m.diff.len > 0:
          lines.add("```diff\n" & m.diff & "\n```")
          lines.add("")
      of mrSystem:
        discard
    of sekCompaction:
      lines.add("> **Compacted Summary** (" & $e.tokensBefore & " tokens):\n> " & e.summary.replace("\n", "\n> "))
      lines.add("")
    else:
      discard

  lines.join("\n")

proc exportSessionHtml*(sm: SessionManager): string =
  ## Export the active conversation branch as a self-contained HTML file (matching Pi's `/export` HTML mode).
  let title = if sm.displayName.len > 0: sm.displayName else: "ni Session " & sm.id
  var bodyParts: seq[string] = @[]

  for e in sm.activeBranchEntries():
    if e.kind == sekCompaction:
      bodyParts.add("<div class=\"card system\"><div class=\"role\">Compaction (" & $e.tokensBefore &
                    " tokens)</div><pre>" & escapeHtml(e.summary) & "</pre></div>")
      continue
    if e.kind != sekMessage:
      continue
    let m = e.message
    case m.role
    of mrUser:
      bodyParts.add("<div class=\"card user\"><div class=\"role\">User</div><pre>" &
                    escapeHtml(collectText(m.userBlocks)) & "</pre></div>")
    of mrAssistant:
      var inner = "<div class=\"role\">Assistant <span class=\"meta\">" &
                  escapeHtml(m.provider & "/" & m.model) & "</span></div>"
      let th = collectThinking(m.assistantBlocks)
      if th.len > 0:
        inner.add("<details class=\"thinking\"><summary>Thinking</summary><pre>" & escapeHtml(th) & "</pre></details>")
      let txt = collectText(m.assistantBlocks)
      if txt.len > 0:
        inner.add("<pre>" & escapeHtml(txt) & "</pre>")
      for tc in collectToolCalls(m.assistantBlocks):
        let aStr = if tc.arguments.isNil: "{}" else: $tc.arguments
        inner.add("<div class=\"tool-call\">● <code>" & escapeHtml(tc.name) & "</code> <span>" & escapeHtml(aStr) & "</span></div>")
      bodyParts.add("<div class=\"card assistant\">" & inner & "</div>")
    of mrToolResult:
      let cls = if m.isError: "tool-result error" else: "tool-result"
      let outTxt = if m.diff.len > 0: m.diff else: collectText(m.resultBlocks)
      bodyParts.add("<details class=\"card " & cls & "\"><summary>Tool Result: <code>" & escapeHtml(m.toolName) &
                    "</code>" & (if m.isError: " (error)" else: "") & "</summary><pre>" & escapeHtml(outTxt) & "</pre></details>")
    of mrSystem:
      discard

  """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>""" & escapeHtml(title) & """</title>
<style>
  body { background:#0d1117; color:#e6edf3; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; max-width:920px; margin:2rem auto; padding:0 1rem; line-height:1.5; }
  h1 { font-size:1.4rem; margin-bottom:0.25rem; }
  .header-meta { color:#8b949e; font-size:0.88rem; margin-bottom:1.5rem; }
  .card { border:1px solid #30363d; border-radius:8px; padding:0.9rem 1rem; margin-bottom:0.9rem; background:#161b22; }
  .card.user { border-left:3px solid #58a6ff; }
  .card.assistant { border-left:3px solid #3fb950; }
  .card.tool-result { background:#0d1117; font-size:0.88rem; }
  .card.tool-result.error { border-left:3px solid #f85149; }
  .role { font-weight:600; font-size:0.85rem; color:#8b949e; margin-bottom:0.4rem; }
  .meta { font-weight:400; color:#6e7681; }
  pre { white-space:pre-wrap; word-break:break-word; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:0.9rem; margin:0.3rem 0; }
  .thinking { color:#8b949e; margin-bottom:0.5rem; }
  .tool-call { color:#79c0ff; font-family:ui-monospace,monospace; font-size:0.85rem; margin-top:0.35rem; }
</style>
</head>
<body>
<h1>""" & escapeHtml(title) & """</h1>
<div class="header-meta">Session <code>""" & escapeHtml(sm.id) & """</code> · Workspace <code>""" & escapeHtml(sm.cwd) & """</code> · Tokens """ & $sm.totalUsage.totalTokens & """ ($""" & formatFloat(sm.totalUsage.costTotal, ffDecimal, 4) & """)</div>
""" & bodyParts.join("\n") & """
</body>
</html>
"""

proc exportSessionToFile*(sm: SessionManager, rawTarget = ""): string =
  ## Export session to `.html` (default), `.md`, or `.jsonl` and return the written absolute path.
  var outPath = rawTarget.strip()
  if outPath.len == 0:
    outPath = sm.cwd / ("ni-session-" & sm.id[0 ..< min(8, sm.id.len)] & ".html")
  else:
    outPath = resolvePathFrom(outPath, sm.cwd)

  createDir(parentDir(outPath))
  let ext = splitFile(outPath).ext.toLowerAscii()
  if ext == ".md" or ext == ".markdown":
    writeFile(outPath, exportSessionMarkdown(sm))
  elif ext == ".jsonl":
    var lines: seq[string] = @[]
    var hdr = %*{
      "type": "session",
      "version": SessionFormatVersion,
      "id": sm.id,
      "timestamp": sm.createdAtIso,
      "cwd": sm.cwd
    }
    lines.add($hdr)
    for e in sm.activeBranchEntries():
      lines.add($entryToJson(e))
    writeFile(outPath, replaceInvalidUtf8(lines.join("\n")) & "\n")
  else:
    writeFile(outPath, exportSessionHtml(sm))
  outPath
