# Model Context Protocol (MCP) client: stdio & streamable HTTP transports, mcp.json config, tools, and resources.

import std/[base64, hashes, httpclient, json, monotimes, options, os, osproc, sets, streams, strtabs, strutils, tables, times]
when defined(windows):
  import std/winlean
else:
  import std/posix
import ./[types, config, tools]

const
  McpProtocolVersion* = "2025-03-26"
  McpToolMaxTextBytes* = 20 * 1024

type
  McpTransportKind* = enum
    mtkStdio = "stdio"
    mtkHttp = "streamable-http"

  McpServerConfig* = object
    name*: string
    transportKind*: McpTransportKind
    command*: string
    args*: seq[string]
    cwd*: string
    envRaw*: Table[string, string]
    url*: string
    headersRaw*: Table[string, string]
    timeoutSec*: int
    enabled*: bool
    exposure*: ToolExposure
    toolExposure*: OrderedTable[string, ToolExposure]
    description*: string
    source*: string

  McpConnectionState* = enum
    mcsIdle = "idle"
    mcsConnected = "connected"
    mcsFailed = "failed"
    mcsDisabled = "disabled"

  McpRemoteTool* = object
    rawName*: string
    qualifiedName*: string
    description*: string
    inputSchema*: JsonNode
    effectiveExposure*: ToolExposure

  McpServerSession* = ref object
    config*: McpServerConfig
    state*: McpConnectionState
    lastError*: string
    serverName*: string
    serverVersion*: string
    instructions*: string
    hasResources*: bool
    remoteTools*: seq[McpRemoteTool]
    nextReqId*: int
    # Stdio state
    process*: Process
    stdoutBuf*: string
    stderrTail*: string
    # Streamable HTTP state
    httpSessionId*: string
    resolvedHeaders*: Table[string, string]
    proxyUrl*: string

  McpManager* = ref object
    servers*: OrderedTable[string, McpServerSession]
    diagnostics*: seq[string]
    workspaceRoot*: string

when defined(windows):
  proc peekPipeMcp(
    hNamedPipe: Handle,
    lpBuffer: pointer,
    nBufferSize: int32,
    lpBytesRead: ptr int32,
    lpTotalBytesAvail: ptr int32,
    lpBytesLeftThisMessage: ptr int32
  ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}

# Naming & pattern rules (matching Pi's mcp__<server>__<tool> specification)

proc sanitizeMcpIdent*(raw: string): string =
  ## Replace any character outside [A-Za-z0-9_] with '_'.
  result = newStringOfCap(raw.len)
  for ch in raw:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      result.add(ch)
    else:
      result.add('_')

proc canonicalServerKey*(name: string): string =
  name.toLowerAscii().replace('-', '_')

proc isValidServerName*(name: string): bool =
  if name.len == 0:
    return false
  for ch in name:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
      return false
  true

proc resolveEffectiveExposure*(srv: McpServerConfig, rawToolName: string): ToolExposure =
  ## Resolve toolExposure overrides (exact match wins over first wildcard match, then server exposure).
  if srv.toolExposure.hasKey(rawToolName):
    return srv.toolExposure[rawToolName]
  for pat, exp in srv.toolExposure.pairs:
    if '*' in pat or '?' in pat:
      if matchGlob(pat, rawToolName):
        return exp
  srv.exposure

# mcp.json loading & CLI add/remove persistence

proc mergeMcpFile(
  servers: var OrderedTable[string, McpServerConfig],
  canonicalMap: var Table[string, string],
  path: string,
  source: string,
  cwd: string,
  diagnostics: var seq[string],
  isOverrideScope: bool
) =
  let parsed = readJsonFileSafe(path, diagnostics)
  if parsed.isNone or parsed.get.kind != JObject:
    return
  let root = parsed.get
  let srvObj = if root.hasKey("mcpServers") and root["mcpServers"].kind == JObject:
    root["mcpServers"]
  else:
    return

  for rawName, entry in srvObj.pairs:
    if entry.kind != JObject:
      diagnostics.add("MCP server '" & rawName & "' in " & path & " must be an object")
      continue
    if not isValidServerName(rawName):
      diagnostics.add("Invalid MCP server name '" & rawName & "' in " & path)
      continue

    let canon = canonicalServerKey(rawName)
    let hasCmd = entry.hasKey("command") and entry["command"].kind == JString
    let hasUrl = entry.hasKey("url") and entry["url"].kind == JString
    let rawType = entry{"type"}.getStr("").toLowerAscii()

    if rawType == "sse":
      diagnostics.add("MCP server '" & rawName & "': legacy SSE transport is unsupported; use streamable HTTP (`url`) instead.")
      continue

    # Project override without command/url/type patches enabled / exposure / toolExposure on existing user server
    if isOverrideScope and not hasCmd and not hasUrl and rawType.len == 0 and canonicalMap.hasKey(canon):
      let origName = canonicalMap[canon]
      var existing = servers[origName]
      if entry.hasKey("enabled") and entry["enabled"].kind == JBool:
        existing.enabled = entry["enabled"].getBool()
      if entry.hasKey("exposure") and entry["exposure"].kind == JString:
        existing.exposure = parseToolExposure(entry["exposure"].getStr(), existing.exposure)
      if entry.hasKey("toolExposure") and entry["toolExposure"].kind == JObject:
        for tk, tv in entry["toolExposure"].pairs:
          if tv.kind == JString:
            existing.toolExposure[tk] = parseToolExposure(tv.getStr(), existing.exposure)
      servers[origName] = existing
      continue

    if not hasCmd and not hasUrl:
      diagnostics.add("MCP server '" & rawName & "' in " & path & " requires either `command` (stdio) or `url` (streamable HTTP).")
      continue

    let tkind = if hasCmd: mtkStdio else: mtkHttp
    var args: seq[string] = @[]
    if entry.hasKey("args") and entry["args"].kind == JArray:
      for a in entry["args"].items:
        if a.kind == JString:
          args.add(expandTilde(a.getStr()))

    var envMap = initTable[string, string]()
    if entry.hasKey("env") and entry["env"].kind == JObject:
      for ek, ev in entry["env"].pairs:
        if ev.kind == JString:
          envMap[ek] = ev.getStr()

    var hdrMap = initTable[string, string]()
    if entry.hasKey("headers") and entry["headers"].kind == JObject:
      for hk, hv in entry["headers"].pairs:
        if hv.kind == JString:
          hdrMap[hk] = hv.getStr()

    var toolExp = initOrderedTable[string, ToolExposure]()
    let srvExp = parseToolExposure(entry{"exposure"}.getStr("codemode"), teCodemode)
    if entry.hasKey("toolExposure") and entry["toolExposure"].kind == JObject:
      for tk, tv in entry["toolExposure"].pairs:
        if tv.kind == JString:
          toolExp[tk] = parseToolExposure(tv.getStr(), srvExp)

    let rawSrvCwd = entry{"cwd"}.getStr("")
    let srvCwd = if rawSrvCwd.len > 0: resolvePathFrom(rawSrvCwd, cwd) else: cwd

    if canonicalMap.hasKey(canon) and canonicalMap[canon] != rawName:
      servers.del(canonicalMap[canon])
    canonicalMap[canon] = rawName

    servers[rawName] = McpServerConfig(
      name: rawName,
      transportKind: tkind,
      command: expandTilde(entry{"command"}.getStr("")),
      args: args,
      cwd: srvCwd,
      envRaw: envMap,
      url: entry{"url"}.getStr(""),
      headersRaw: hdrMap,
      timeoutSec: max(1, entry{"timeout"}.getInt(60)),
      enabled: entry{"enabled"}.getBool(true),
      exposure: srvExp,
      toolExposure: toolExp,
      description: entry{"description"}.getStr(""),
      source: source
    )

proc loadMcpConfigs*(cfg: ConfigBundle): tuple[servers: OrderedTable[string, McpServerConfig], diagnostics: seq[string]] =
  ## Load MCP servers from ~/.pi/agent/mcp.json and (when project is trusted) .pi/mcp.json.
  var servers = initOrderedTable[string, McpServerConfig]()
  var canonMap = initTable[string, string]()
  var diags: seq[string] = @[]

  mergeMcpFile(servers, canonMap, cfg.agentDir / "mcp.json", "user", cfg.cwd, diags, isOverrideScope = false)
  if cfg.projectTrusted:
    mergeMcpFile(servers, canonMap, cfg.cwd / ProjectConfigDirName / "mcp.json", "project", cfg.cwd, diags, isOverrideScope = true)

  (servers, diags)

proc saveMcpServerEntry*(mcpFilePath: string, srv: McpServerConfig) =
  ## Add or replace one server entry inside mcp.json while preserving unrelated entries.
  createDir(parentDir(mcpFilePath))
  var root = newJObject()
  if fileExists(mcpFilePath):
    try:
      let parsed = parseJson(stripUtf8Bom(readFile(mcpFilePath)))
      if parsed.kind == JObject:
        root = parsed
    except CatchableError:
      root = newJObject()
  if not root.hasKey("mcpServers") or root["mcpServers"].kind != JObject:
    root["mcpServers"] = newJObject()

  var entry = newJObject()
  case srv.transportKind
  of mtkStdio:
    entry["command"] = %srv.command
    if srv.args.len > 0:
      var a = newJArray()
      for item in srv.args: a.add(%item)
      entry["args"] = a
    if srv.envRaw.len > 0:
      var e = newJObject()
      for k, v in srv.envRaw.pairs: e[k] = %v
      entry["env"] = e
  of mtkHttp:
    entry["url"] = %srv.url
    if srv.headersRaw.len > 0:
      var h = newJObject()
      for k, v in srv.headersRaw.pairs: h[k] = %v
      entry["headers"] = h

  if srv.exposure != teCodemode:
    entry["exposure"] = %($srv.exposure)
  if srv.description.len > 0:
    entry["description"] = %srv.description
  if not srv.enabled:
    entry["enabled"] = %false

  root["mcpServers"][srv.name] = entry
  writeFile(mcpFilePath, root.pretty() & "\n")

proc removeMcpServerEntry*(mcpFilePath, serverName: string): bool =
  ## Remove a server entry from mcp.json.
  if not fileExists(mcpFilePath):
    return false
  try:
    let root = parseJson(stripUtf8Bom(readFile(mcpFilePath)))
    if root.kind != JObject or not root.hasKey("mcpServers") or root["mcpServers"].kind != JObject:
      return false
    if not root["mcpServers"].hasKey(serverName):
      return false
    root["mcpServers"].delete(serverName)
    writeFile(mcpFilePath, root.pretty() & "\n")
    return true
  except CatchableError:
    return false

# Stdio JSON-RPC 2.0 transport (non-blocking poll/PeekNamedPipe with timeout & server request handling)

proc drainStderr(sess: McpServerSession) =
  if sess.process.isNil:
    return
  let errFd = sess.process.errorHandle()
  when defined(windows):
    var avail: int32 = 0
    if peekPipeMcp(Handle(errFd), nil, 0, nil, addr avail, nil) != 0 and avail > 0:
      var buf = newString(min(avail.int, 4096))
      var n: int32 = 0
      if readFile(Handle(errFd), addr buf[0], buf.len.int32, addr n, nil) != 0 and n > 0:
        buf.setLen(n.int)
        sess.stderrTail.add(buf)
  else:
    var pfd: TPollfd
    pfd.fd = cint(errFd)
    pfd.events = cshort(POLLIN)
    if poll(addr pfd, 1, 0) > 0 and (pfd.revents and POLLIN) != 0:
      var buf = newString(4096)
      let n = posix.read(cint(errFd), addr buf[0], buf.len)
      if n > 0:
        buf.setLen(n)
        sess.stderrTail.add(buf)
  if sess.stderrTail.len > 8192:
    sess.stderrTail = sess.stderrTail[sess.stderrTail.len - 8192 .. ^1]

proc readStdioLine(sess: McpServerSession, timeoutMs: int): Option[string] =
  let start = getMonoTime()
  let outFd = sess.process.outputHandle()

  while true:
    let nl = sess.stdoutBuf.find('\n')
    if nl >= 0:
      var line = sess.stdoutBuf[0 ..< nl]
      sess.stdoutBuf = sess.stdoutBuf[nl + 1 .. ^1]
      if line.endsWith("\r"):
        line.setLen(line.len - 1)
      return some(line)

    sess.drainStderr()
    let elapsed = (getMonoTime() - start).inMilliseconds
    if timeoutMs > 0 and elapsed >= timeoutMs:
      raise newException(IOError, "MCP stdio server '" & sess.config.name & "' timed out after " & $(timeoutMs div 1000) & "s")

    let remainMs = if timeoutMs > 0: max(1, (timeoutMs - elapsed).int) else: 50
    when defined(windows):
      var avail: int32 = 0
      if peekPipeMcp(Handle(outFd), nil, 0, nil, addr avail, nil) == 0:
        return none(string)
      if avail > 0:
        var buf = newString(min(avail.int, 16384))
        var n: int32 = 0
        if readFile(Handle(outFd), addr buf[0], buf.len.int32, addr n, nil) == 0 or n <= 0:
          return none(string)
        buf.setLen(n.int)
        sess.stdoutBuf.add(buf)
      elif not sess.process.running():
        return none(string)
      else:
        sleep(min(15, remainMs))
    else:
      var pfd: TPollfd
      pfd.fd = cint(outFd)
      pfd.events = cshort(POLLIN or POLLHUP)
      pfd.revents = 0
      let rc = poll(addr pfd, 1, cint(min(50, remainMs)))
      if rc > 0 and (pfd.revents and POLLIN) != 0:
        var buf = newString(16384)
        let n = posix.read(cint(outFd), addr buf[0], buf.len)
        if n > 0:
          buf.setLen(n)
          sess.stdoutBuf.add(buf)
        elif n == 0:
          return none(string)
      elif rc > 0 and (pfd.revents and POLLHUP) != 0:
        return none(string)
      elif not sess.process.running():
        return none(string)

proc sendStdioJson(sess: McpServerSession, payload: JsonNode) =
  if sess.process.isNil or not sess.process.running():
    raise newException(IOError, "MCP stdio server '" & sess.config.name & "' is not running")
  sess.process.inputStream.write($payload & "\n")
  sess.process.inputStream.flush()

proc handleIncomingServerRequest(sess: McpServerSession, msg: JsonNode, workspaceRoot: string): Option[JsonNode] =
  let meth = msg{"method"}.getStr("")
  let reqId = msg{"id"}
  if reqId.isNil:
    return none(JsonNode)
  case meth
  of "ping":
    some(%*{ "jsonrpc": "2.0", "id": reqId, "result": {} })
  of "roots/list":
    let uri = "file://" & workspaceRoot.replace('\\', '/')
    some(%*{
      "jsonrpc": "2.0",
      "id": reqId,
      "result": {
        "roots": [{ "uri": uri, "name": extractFilename(workspaceRoot) }]
      }
    })
  else:
    some(%*{
      "jsonrpc": "2.0",
      "id": reqId,
      "error": { "code": -32601, "message": "Method not found: " & meth }
    })

proc rpcRequestStdio(sess: McpServerSession, meth: string, params: JsonNode, workspaceRoot: string): JsonNode =
  inc sess.nextReqId
  let myId = sess.nextReqId
  var req = %*{
    "jsonrpc": "2.0",
    "id": myId,
    "method": meth
  }
  if not params.isNil:
    req["params"] = params

  sess.sendStdioJson(req)
  let timeoutMs = sess.config.timeoutSec * 1000

  while true:
    let lineOpt = sess.readStdioLine(timeoutMs)
    if lineOpt.isNone:
      sess.drainStderr()
      let extra = if sess.stderrTail.strip().len > 0: ": " & sess.stderrTail.strip() else: ""
      raise newException(IOError, "MCP server '" & sess.config.name & "' closed connection unexpectedly" & extra)
    let line = lineOpt.get.strip()
    if line.len == 0:
      continue
    let msg = try: parseJson(line) except CatchableError: continue
    if msg.kind != JObject:
      continue

    # Server-to-client request (e.g., ping or roots/list)
    if msg.hasKey("method") and msg.hasKey("id"):
      let reply = sess.handleIncomingServerRequest(msg, workspaceRoot)
      if reply.isSome:
        sess.sendStdioJson(reply.get)
      continue

    # Server notification (ignore or log)
    if msg.hasKey("method") and not msg.hasKey("id"):
      continue

    # Response matching myId
    if msg.hasKey("id"):
      let respId = if msg["id"].kind == JInt: msg["id"].getInt(-1)
                   elif msg["id"].kind == JString: (try: parseInt(msg["id"].getStr()) except ValueError: -1)
                   else: -1
      if respId == myId:
        if msg.hasKey("error") and msg["error"].kind == JObject:
          let errMsg = msg["error"]{"message"}.getStr("MCP RPC error")
          raise newException(IOError, "MCP '" & sess.config.name & "' " & meth & " error: " & errMsg)
        return if msg.hasKey("result"): msg["result"] else: newJObject()

# Streamable HTTP JSON-RPC 2.0 transport (supports both application/json and text/event-stream SSE)

proc parseSseJsonRpcResponse*(sseBody: string, expectedId: int): Option[JsonNode] =
  var dataLines: seq[string] = @[]
  var found = none(JsonNode)

  proc flushEvent() =
    if dataLines.len == 0:
      return
    let joined = dataLines.join("\n").strip()
    dataLines.setLen(0)
    if joined.len == 0 or joined == "[DONE]":
      return
    try:
      let node = parseJson(joined)
      if node.kind == JObject and node.hasKey("id"):
        let rid = if node["id"].kind == JInt: node["id"].getInt(-1) else: -1
        if rid == expectedId:
          found = some(node)
    except CatchableError:
      discard

  for rawLine in sseBody.replace("\r\n", "\n").split('\n'):
    if rawLine.len == 0:
      flushEvent()
    elif rawLine.startsWith("data:"):
      var v = rawLine[5 .. ^1]
      if v.startsWith(" "): v = v[1 .. ^1]
      dataLines.add(v)
  flushEvent()
  found

proc postMcpHttp(sess: McpServerSession, payload: JsonNode, expectResponse: bool): Option[JsonNode] =
  var proxy: Proxy = nil
  if sess.proxyUrl.len > 0:
    proxy = newProxy(sess.proxyUrl)

  var attempt = 0
  while attempt < 3:
    inc attempt
    let client = newHttpClient(timeout = sess.config.timeoutSec * 1000, userAgent = "ni-mcp-client/0.1.0", proxy = proxy)
    defer: client.close()

    var hdrs = newHttpHeaders()
    hdrs["Content-Type"] = "application/json"
    hdrs["Accept"] = "application/json, text/event-stream"
    for k, v in sess.resolvedHeaders.pairs:
      hdrs[k] = v
    if sess.httpSessionId.len > 0:
      hdrs["Mcp-Session-Id"] = sess.httpSessionId

    let resp = client.request(sess.config.url, httpMethod = HttpPost, body = $payload, headers = hdrs)
    let code = resp.code.int

    if not resp.headers.isNil:
      for hk, hv in resp.headers.table.pairs:
        if hk.toLowerAscii() == "mcp-session-id" and hv.len > 0 and hv[0].len > 0:
          sess.httpSessionId = hv[0].strip()

    if code in [408, 429] or code >= 500:
      if attempt < 3:
        sleep(300 * attempt)
        continue

    if code == 202 or not expectResponse:
      return none(JsonNode)

    if code < 200 or code >= 300:
      raise newException(IOError, "MCP HTTP " & $code & " from '" & sess.config.name & "': " & resp.body.strip())

    var ctype = ""
    if not resp.headers.isNil:
      for hk, hv in resp.headers.table.pairs:
        if hk.toLowerAscii() == "content-type" and hv.len > 0:
          ctype = hv[0].toLowerAscii()
    let rawBody = resp.body
    if "text/event-stream" in ctype or rawBody.strip().startsWith("event:") or rawBody.strip().startsWith("data:"):
      let expId = payload{"id"}.getInt(-1)
      let matched = parseSseJsonRpcResponse(rawBody, expId)
      if matched.isSome:
        return matched
      raise newException(IOError, "MCP SSE stream from '" & sess.config.name & "' ended without matching JSON-RPC response")

    let parsed = parseJson(rawBody)
    return some(parsed)
  none(JsonNode)

proc rpcRequest(sess: McpServerSession, meth: string, params: JsonNode, workspaceRoot: string): JsonNode =
  case sess.config.transportKind
  of mtkStdio:
    rpcRequestStdio(sess, meth, params, workspaceRoot)
  of mtkHttp:
    inc sess.nextReqId
    let myId = sess.nextReqId
    var req = %*{ "jsonrpc": "2.0", "id": myId, "method": meth }
    if not params.isNil:
      req["params"] = params
    let respOpt = postMcpHttp(sess, req, expectResponse = true)
    if respOpt.isNone:
      return newJObject()
    let msg = respOpt.get
    if msg.hasKey("error") and msg["error"].kind == JObject:
      raise newException(IOError, "MCP '" & sess.config.name & "' " & meth & " error: " & msg["error"]{"message"}.getStr(""))
    if msg.hasKey("result"): msg["result"] else: newJObject()

proc sendNotification(sess: McpServerSession, meth: string, params: JsonNode = nil) =
  var notif = %*{ "jsonrpc": "2.0", "method": meth }
  if not params.isNil:
    notif["params"] = params
  case sess.config.transportKind
  of mtkStdio:
    sess.sendStdioJson(notif)
  of mtkHttp:
    discard postMcpHttp(sess, notif, expectResponse = false)

# Server lifecycle: connect, handshake, tool/resource discovery, tool invocation, close

proc qualifyServerTools*(serverName: string, rawTools: seq[tuple[name, desc: string, schema: JsonNode]], cfg: McpServerConfig): seq[McpRemoteTool] =
  ## Name tools `mcp__<server>__<tool>` and disambiguate collisions with a short hash suffix per Pi spec.
  let srvPart = sanitizeMcpIdent(serverName)
  var counts = initCountTable[string]()
  var baseNames: seq[string] = @[]
  for rt in rawTools:
    let q = "mcp__" & srvPart & "__" & sanitizeMcpIdent(rt.name)
    baseNames.add(q)
    counts.inc(q)

  for i, rt in rawTools.pairs:
    var q = baseNames[i]
    if counts[q] > 1:
      let h = toHex(abs(hash(rt.name)) and 0xFFFF, 4).toLowerAscii()
      q = q & "_" & h
    result.add(McpRemoteTool(
      rawName: rt.name,
      qualifiedName: q,
      description: rt.desc,
      inputSchema: (if rt.schema.isNil: %*{"type": "object", "properties": {}} else: rt.schema),
      effectiveExposure: resolveEffectiveExposure(cfg, rt.name)
    ))

proc connectServer*(sess: McpServerSession, cfgBundle: ConfigBundle) =
  ## Start transport, run MCP initialize handshake, and fetch paginated tools/list.
  if not sess.config.enabled:
    sess.state = mcsDisabled
    return

  try:
    case sess.config.transportKind
    of mtkStdio:
      var envTable = newStringTable(modeCaseSensitive)
      for k, v in envPairs():
        envTable[k] = v
      for ek, rawVal in sess.config.envRaw.pairs:
        let resolved = resolveConfigValue(rawVal, cfgBundle.commandCache, cacheCommands = true)
        if resolved.isSome:
          envTable[ek] = resolved.get
      let opts: set[ProcessOption] =
        when defined(windows):
          {poUsePath, poInteractive, poDaemon}
        else:
          {poUsePath}
      let runCwd = if dirExists(sess.config.cwd): sess.config.cwd else: cfgBundle.cwd
      sess.process = startProcess(sess.config.command, workingDir = runCwd, args = sess.config.args, env = envTable, options = opts)
    of mtkHttp:
      sess.proxyUrl = cfgBundle.settings.httpProxy
      sess.resolvedHeaders = initTable[string, string]()
      for hk, rawVal in sess.config.headersRaw.pairs:
        let resolved = resolveConfigValue(rawVal, cfgBundle.commandCache, cacheCommands = true)
        if resolved.isSome:
          sess.resolvedHeaders[hk] = resolved.get

    let initRes = sess.rpcRequest("initialize", %*{
      "protocolVersion": McpProtocolVersion,
      "capabilities": { "roots": { "listChanged": false } },
      "clientInfo": { "name": "ni", "version": "0.1.0" }
    }, cfgBundle.cwd)

    if initRes.hasKey("serverInfo") and initRes["serverInfo"].kind == JObject:
      sess.serverName = initRes["serverInfo"]{"name"}.getStr(sess.config.name)
      sess.serverVersion = initRes["serverInfo"]{"version"}.getStr("")
    sess.instructions = initRes{"instructions"}.getStr("")
    let caps = initRes{"capabilities"}
    sess.hasResources = not caps.isNil and caps.kind == JObject and caps.hasKey("resources")

    sess.sendNotification("notifications/initialized")

    # Fetch tools/list across pages if server advertises tools (or by default)
    var rawTools: seq[tuple[name, desc: string, schema: JsonNode]] = @[]
    let hasToolsCap = caps.isNil or caps.kind != JObject or caps.hasKey("tools")
    if hasToolsCap:
      var cursor = ""
      var pages = 0
      while pages < 50:
        inc pages
        let params = if cursor.len > 0: %*{ "cursor": cursor } else: newJObject()
        let listRes = sess.rpcRequest("tools/list", params, cfgBundle.cwd)
        if listRes.hasKey("tools") and listRes["tools"].kind == JArray:
          for tnode in listRes["tools"].items:
            if tnode.kind == JObject and tnode.hasKey("name"):
              rawTools.add((
                name: tnode["name"].getStr(),
                desc: tnode{"description"}.getStr(""),
                schema: tnode{"inputSchema"}
              ))
        cursor = listRes{"nextCursor"}.getStr("")
        if cursor.len == 0:
          break

    sess.remoteTools = qualifyServerTools(sess.config.name, rawTools, sess.config)
    sess.state = mcsConnected
    sess.lastError = ""
  except CatchableError as e:
    sess.state = mcsFailed
    sess.lastError = e.msg
    if not sess.process.isNil:
      killProcessTree(sess.process)
      try: sess.process.close() except CatchableError: discard
      sess.process = nil

proc closeServer*(sess: McpServerSession) =
  ## Gracefully close an MCP server connection (stdin close -> SIGTERM/taskkill or HTTP DELETE).
  if sess.isNil:
    return
  case sess.config.transportKind
  of mtkStdio:
    if not sess.process.isNil:
      try: sess.process.inputStream.close() except CatchableError: discard
      sleep(60)
      if sess.process.running():
        killProcessTree(sess.process)
      try: sess.process.close() except CatchableError: discard
      sess.process = nil
  of mtkHttp:
    if sess.httpSessionId.len > 0:
      try:
        let client = newHttpClient(timeout = 2000)
        defer: client.close()
        client.headers["Mcp-Session-Id"] = sess.httpSessionId
        discard client.request(sess.config.url, httpMethod = HttpDelete)
      except CatchableError:
        discard
  if sess.state == mcsConnected:
    sess.state = mcsIdle

proc middleTruncateMcpText*(text, serverName: string): tuple[output: string, savedPath: string] =
  ## Match Pi's 20KB MCP middle-truncation behavior with full text saved to a temp file.
  if text.len <= McpToolMaxTextBytes:
    return (text, "")
  let saved = saveFullOutputTemp("mcp-" & sanitizeMcpIdent(serverName), text)
  let half = McpToolMaxTextBytes div 2
  let omitted = text.len - (half * 2)
  var clipped = text[0 ..< half] & "\n…" & $omitted & " chars truncated…\n" & text[text.len - half .. ^1]
  if saved.len > 0:
    clipped.add("\n[Full MCP tool result saved to " & saved & "]")
  (clipped, saved)

proc callMcpTool*(sess: McpServerSession, rawToolName: string, args: JsonNode, workspaceRoot: string): ToolOutput =
  ## Invoke tools/call on a connected MCP server and convert CallToolResult to ToolOutput.
  if sess.state != mcsConnected:
    return ToolOutput(
      content: @[textBlock("MCP server '" & sess.config.name & "' is not connected: " & sess.lastError)],
      isError: true
    )
  try:
    let res = sess.rpcRequest("tools/call", %*{
      "name": rawToolName,
      "arguments": (if args.isNil: newJObject() else: args)
    }, workspaceRoot)

    let isErr = res{"isError"}.getBool(false)
    var blocks: seq[ContentBlock] = @[]
    var savedPath = ""

    if res.hasKey("content") and res["content"].kind == JArray:
      for item in res["content"].items:
        if item.kind != JObject:
          continue
        case item{"type"}.getStr("")
        of "text":
          let (txt, sp) = middleTruncateMcpText(item{"text"}.getStr(""), sess.config.name)
          if sp.len > 0: savedPath = sp
          blocks.add(textBlock(txt))
        of "image":
          blocks.add(imageBlock(item{"data"}.getStr(""), item{"mimeType"}.getStr("image/png")))
        of "resource":
          let r = item{"resource"}
          if not r.isNil and r.kind == JObject:
            if r.hasKey("text"):
              blocks.add(textBlock(r["text"].getStr()))
            else:
              blocks.add(textBlock("[MCP resource: " & r{"uri"}.getStr("") & "]"))
        else:
          blocks.add(textBlock($item))

    if blocks.len == 0 and res.hasKey("structuredContent"):
      let (txt, sp) = middleTruncateMcpText($res["structuredContent"], sess.config.name)
      savedPath = sp
      blocks.add(textBlock(txt))

    if blocks.len == 0:
      blocks.add(textBlock("(empty MCP tool result)"))

    ToolOutput(content: blocks, isError: isErr, fullOutputPath: savedPath)
  except CatchableError as e:
    ToolOutput(content: @[textBlock("MCP call failed: " & e.msg)], isError: true)

# Manager: connect servers, register tools & resource tools into ToolRegistry, build <mcp_servers> prompt section

proc registerMcpResourceTools(mgr: McpManager, reg: ToolRegistry, exposure: ToolExposure) =
  let listTool = AgentTool(
    name: "list_mcp_resources",
    description: "List resources offered by connected MCP servers.",
    snippet: "List MCP server resources",
    guidelines: @[],
    exposure: exposure,
    namespace: "mcp_resources",
    parameters: %*{
      "type": "object",
      "properties": {
        "server": { "type": "string", "description": "Optional MCP server name" },
        "cursor": { "type": "string", "description": "Optional pagination cursor" }
      }
    },
    execute: proc(args: JsonNode, ctx: ToolContext): ToolOutput =
      let targetSrv = args{"server"}.getStr("").strip()
      let cursor = args{"cursor"}.getStr("")
      var resourcesArr = newJArray()
      for sname, sess in mgr.servers.pairs:
        if sess.state != mcsConnected or not sess.hasResources:
          continue
        if targetSrv.len > 0 and sname != targetSrv:
          continue
        try:
          let params = if cursor.len > 0: %*{ "cursor": cursor } else: newJObject()
          let res = sess.rpcRequest("resources/list", params, mgr.workspaceRoot)
          if res.hasKey("resources") and res["resources"].kind == JArray:
            for item in res["resources"].items:
              if item.kind == JObject:
                let uri = item{"uri"}.getStr("")
                if uri.startsWith("ui://"): continue
                var copyItem = copy(item)
                copyItem["server"] = %sname
                resourcesArr.add(copyItem)
        except CatchableError as e:
          return ToolOutput(content: @[textBlock("Failed to list MCP resources: " & e.msg)], isError: true)
      ToolOutput(content: @[textBlock($(%*{ "resources": resourcesArr }))], isError: false)
  )

  let readResTool = AgentTool(
    name: "read_mcp_resource",
    description: "Read a resource by server name and URI from a connected MCP server.",
    snippet: "Read an MCP resource by URI",
    guidelines: @[],
    exposure: exposure,
    namespace: "mcp_resources",
    parameters: %*{
      "type": "object",
      "properties": {
        "server": { "type": "string", "description": "MCP server name" },
        "uri": { "type": "string", "description": "Resource URI to read" }
      },
      "required": ["server", "uri"]
    },
    execute: proc(args: JsonNode, ctx: ToolContext): ToolOutput =
      let sname = args{"server"}.getStr("").strip()
      let uri = args{"uri"}.getStr("").strip()
      if not mgr.servers.hasKey(sname):
        return ToolOutput(content: @[textBlock("Unknown MCP server: " & sname)], isError: true)
      let sess = mgr.servers[sname]
      if sess.state != mcsConnected:
        return ToolOutput(content: @[textBlock("MCP server '" & sname & "' is not connected")], isError: true)
      try:
        let res = sess.rpcRequest("resources/read", %*{ "uri": uri }, mgr.workspaceRoot)
        var blocks: seq[ContentBlock] = @[]
        if res.hasKey("contents") and res["contents"].kind == JArray:
          for c in res["contents"].items:
            if c.kind == JObject:
              if c.hasKey("text") and c["text"].kind == JString:
                blocks.add(textBlock(c["text"].getStr()))
              elif c.hasKey("blob") and c["blob"].kind == JString:
                let mime = c{"mimeType"}.getStr("application/octet-stream")
                if mime.startsWith("image/"):
                  blocks.add(imageBlock(c["blob"].getStr(), mime))
                else:
                  let decoded = base64.decode(c["blob"].getStr())
                  let p = saveFullOutputTemp("mcp-res", decoded)
                  blocks.add(textBlock("Saved binary MCP resource (" & mime & ") to " & p))
        if blocks.len == 0:
          blocks.add(textBlock("(empty resource)"))
        ToolOutput(content: blocks, isError: false)
      except CatchableError as e:
        ToolOutput(content: @[textBlock("Failed to read MCP resource: " & e.msg)], isError: true)
  )

  reg.tools[listTool.name] = listTool
  reg.tools[readResTool.name] = readResTool
  if exposure == teDirect:
    reg.activeNames.incl(listTool.name)
    reg.activeNames.incl(readResTool.name)

proc buildMcpAgentTool(sess: McpServerSession, rt: McpRemoteTool, serverName, workspaceRoot: string): AgentTool =
  let rawToolName = rt.rawName
  AgentTool(
    name: rt.qualifiedName,
    description: (if rt.description.len > 0: rt.description else: "MCP tool " & rawToolName & " on " & serverName),
    snippet: rt.description.splitLines()[0],
    guidelines: @[],
    parameters: rt.inputSchema,
    exposure: rt.effectiveExposure,
    namespace: "mcp__" & sanitizeMcpIdent(serverName),
    execute: proc(args: JsonNode, ctx: ToolContext): ToolOutput =
      callMcpTool(sess, rawToolName, args, workspaceRoot)
  )

proc newMcpManager*(cfg: ConfigBundle, reg: ToolRegistry, connectNow = true): McpManager =
  ## Load MCP configurations, connect enabled servers, and bind their tools into ToolRegistry.
  let (configs, diags) = loadMcpConfigs(cfg)
  result = McpManager(
    servers: initOrderedTable[string, McpServerSession](),
    diagnostics: diags,
    workspaceRoot: cfg.cwd
  )

  var needToolSearch = false
  var anyResources = false
  var widestResExposure = teDeferred

  for name, scfg in configs.pairs:
    let sess = McpServerSession(
      config: scfg,
      state: (if scfg.enabled: mcsIdle else: mcsDisabled)
    )
    if connectNow and scfg.enabled:
      sess.connectServer(cfg)
      if sess.state == mcsFailed:
        result.diagnostics.add("MCP server '" & name & "' failed to connect: " & sess.lastError)
    result.servers[name] = sess

    if sess.state == mcsConnected:
      if sess.hasResources and scfg.exposure != teHidden:
        anyResources = true
        if scfg.exposure == teDirect:
          widestResExposure = teDirect

      for rt in sess.remoteTools:
        let agentTool = buildMcpAgentTool(sess, rt, name, cfg.cwd)
        reg.tools[rt.qualifiedName] = agentTool
        if rt.effectiveExposure == teDirect:
          reg.activeNames.incl(rt.qualifiedName)
        elif rt.effectiveExposure in {teDeferred, teCodemode}:
          needToolSearch = true

  if anyResources:
    registerMcpResourceTools(result, reg, widestResExposure)
    if widestResExposure != teDirect:
      needToolSearch = true

  # Auto-enable tool_search when deferred/codemode MCP tools are present so any Pi mcp.json works seamlessly!
  if needToolSearch and reg.tools.hasKey("tool_search"):
    reg.activeNames.incl("tool_search")

proc closeAll*(mgr: McpManager) =
  ## Shut down all connected MCP servers cleanly.
  if mgr.isNil:
    return
  for _, sess in mgr.servers.pairs:
    sess.closeServer()

proc formatMcpServersPromptSection*(mgr: McpManager): string =
  ## Build <mcp_servers> summary for deferred/codemode servers, matching Pi's prompt layout.
  if mgr.isNil or mgr.servers.len == 0:
    return ""
  var lines: seq[string] = @[]
  for name, sess in mgr.servers.pairs:
    if sess.state != mcsConnected:
      continue
    var indirectCount = 0
    for rt in sess.remoteTools:
      if rt.effectiveExposure in {teDeferred, teCodemode}:
        inc indirectCount
    if indirectCount == 0:
      continue
    var summary = sess.config.description.strip()
    if summary.len == 0 and sess.instructions.strip().len > 0:
      summary = sess.instructions.strip().splitLines()[0]
    if summary.len == 0:
      summary = $indirectCount & " indirect tool(s)"
    lines.add("- " & name & " (namespace: mcp__" & sanitizeMcpIdent(name) & ", " &
              $indirectCount & " deferred tools — discover and load with `tool_search`): " & summary)
  if lines.len == 0:
    return ""
  "Connected MCP servers with deferred tools (use `tool_search` to load matching tools before calling):\n" & lines.join("\n")
