# Model Context Protocol (MCP) client: stdio & streamable HTTP transports, mcp.json config, tools, and resources.

import std/[asyncdispatch, asyncstreams, base64, hashes, httpclient, json, monotimes, options, os, osproc, sets, streams, strtabs, strutils, tables, tempfiles, times]
when defined(windows):
  import std/winlean
else:
  import std/posix
import ./[types, config, tools, trust, utf8, mcp_oauth, release_info]

const
  McpProtocolVersion* = "2025-03-26"
  McpToolMaxTextBytes* = 20 * 1024

type
  McpAbortError = object of IOError
  McpProtocolError = object of IOError
  McpSessionExpired = object of IOError
  McpAuthRejected = object of McpOAuthError

  McpFailureKind* = enum
    mcfNone = ""
    mcfAuth = "authentication"
    mcfNetwork = "network"
    mcfProtocol = "protocol"

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
    oauth*: McpOAuthOptions

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
    failureKind*: McpFailureKind
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
    protocolVersion: string
    resolvedHeaders*: Table[string, string]
    proxyUrl*: string
    oauthFile: string
    bundle: ConfigBundle
    security: SecurityPolicy

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

    let oauth = entry{"oauth"}
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
      source: source,
      oauth: McpOAuthOptions(clientId: oauth{"clientId"}.getStr(), clientSecret: oauth{"clientSecret"}.getStr(),
        clientName: oauth{"clientName"}.getStr(), scope: oauth{"scope"}.getStr(),
        metadataUrl: oauth{"authServerMetadataUrl"}.getStr(), callbackUrl: oauth{"callbackUrl"}.getStr(),
        callbackPort: oauth{"callbackPort"}.getInt())
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

proc findMcpConfig*(cfg: ConfigBundle, name: string): McpServerConfig =
  for serverName, server in loadMcpConfigs(cfg).servers.pairs:
    if canonicalServerKey(serverName) == canonicalServerKey(name):
      return server
  raise newException(ValueError, "Unknown MCP server '" & name & "'")

proc signInMcp*(cfg: ConfigBundle, server: McpServerConfig, openBrowser = true,
                announce: proc(url: string) {.closure.}) =
  if server.transportKind != mtkHttp:
    raise newException(ValueError, "OAuth is available only for Streamable HTTP servers")
  for key in server.headersRaw.keys:
    if key.toLowerAscii() == "authorization":
      raise newException(ValueError, "Remove the configured Authorization header before OAuth sign-in")
  var options = server.oauth
  if options.clientSecret.len > 0:
    let resolved = resolveConfigValue(options.clientSecret, cfg.commandCache, cacheCommands = true)
    if resolved.isNone:
      raise newException(ValueError, "The configured OAuth client secret could not be resolved")
    options.clientSecret = resolved.get
  loginMcpOAuth(server.url, cfg.settings.httpProxy, oauthPath(cfg.agentDir, server.name, server.url),
    options, openBrowser, announce)

proc signOutMcp*(cfg: ConfigBundle, server: McpServerConfig) =
  signOutOAuth(oauthPath(cfg.agentDir, server.name, server.url))

proc setMcpEnabled*(cfg: ConfigBundle, server: McpServerConfig, enabled: bool, tool = "") =
  let path = if server.source == "project": cfg.cwd / ProjectConfigDirName / "mcp.json"
    else: cfg.agentDir / "mcp.json"
  let root = parseJson(stripUtf8Bom(readFile(path)))
  let servers = root{"mcpServers"}
  if servers.isNil or servers.kind != JObject:
    raise newException(ValueError, "MCP configuration does not contain a server map")
  var entry: JsonNode
  for name, node in servers.pairs:
    if canonicalServerKey(name) == canonicalServerKey(server.name):
      entry = node
      break
  if entry.isNil or entry.kind != JObject:
    raise newException(ValueError, "MCP server configuration could not be found")
  if tool.len == 0:
    entry["enabled"] = %enabled
  else:
    if not entry.hasKey("toolExposure"): entry["toolExposure"] = newJObject()
    if entry["toolExposure"].kind != JObject:
      raise newException(ValueError, "MCP toolExposure must be an object")
    entry["toolExposure"][tool] = %(if enabled: "direct" else: "hidden")
  let permissions = getFilePermissions(path)
  let (file, temporary) = createTempFile(".ni-mcp-", "", parentDir(path))
  try:
    try:
      file.writeLine(encodeJsonUtf8(root))
    finally:
      file.close()
    setFilePermissions(temporary, permissions)
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)

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

proc readStdioLine(sess: McpServerSession, timeoutMs: int, abort: AbortFlag): Option[string] =
  let start = getMonoTime()
  let outFd = sess.process.outputHandle()

  while true:
    if abort.pollAbort():
      raise newException(McpAbortError, "MCP request cancelled")
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
  sess.process.inputStream.write(encodeJsonUtf8(payload) & "\n")
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

proc rpcRequestStdio(sess: McpServerSession, meth: string, params: JsonNode, workspaceRoot: string, abort: AbortFlag): JsonNode =
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

  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let remaining = (deadline - getMonoTime()).inMilliseconds.int
    if remaining <= 0:
      raise newException(IOError, "MCP stdio server '" & sess.config.name & "' timed out")
    let lineOpt = try: sess.readStdioLine(remaining, abort)
    except McpAbortError:
      try:
        sess.sendStdioJson(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
          "params": {"requestId": myId, "reason": "Cancelled by user"}})
      except CatchableError:
        discard
      raise
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

proc waitForMcpHttp[T](future: Future[T], deadline: MonoTime, abort: AbortFlag): T =
  if abort.pollAbort():
    raise newException(McpAbortError, "MCP request cancelled")
  while not future.finished:
    if abort.pollAbort():
      raise newException(McpAbortError, "MCP request cancelled")
    let remaining = (deadline - getMonoTime()).inMilliseconds.int
    if remaining <= 0:
      raise newException(IOError, "MCP HTTP request timed out")
    discard waitFor withTimeout(future, min(50, remaining))
  future.read()

proc requestMcpHttp(sess: McpServerSession, payload: JsonNode, expectResponse: bool,
                    token: string, abort: AbortFlag): Option[JsonNode] =
  var proxy: Proxy = nil
  if sess.proxyUrl.len > 0:
    proxy = newProxy(sess.proxyUrl)

  if abort.pollAbort():
    raise newException(McpAbortError, "MCP request cancelled")
  let client = newAsyncHttpClient(maxRedirects = 0, userAgent = "ni-mcp-client/" & NiVersion, proxy = proxy)
  defer: client.close()
  var hdrs = newHttpHeaders()
  hdrs["Content-Type"] = "application/json"
  hdrs["Accept"] = "application/json, text/event-stream"
  if sess.protocolVersion.len > 0:
    hdrs["MCP-Protocol-Version"] = sess.protocolVersion
  for k, v in sess.resolvedHeaders.pairs: hdrs[k] = v
  if token.len > 0: hdrs["Authorization"] = "Bearer " & token
  if sess.httpSessionId.len > 0: hdrs["Mcp-Session-Id"] = sess.httpSessionId
  let deadline = getMonoTime() + initDuration(seconds = sess.config.timeoutSec)
  let resp = waitForMcpHttp(client.request(sess.config.url, httpMethod = HttpPost,
    body = encodeJsonUtf8(payload), headers = hdrs), deadline, abort)
  let code = resp.code.int
  if code == 401:
    raise newException(McpAuthRejected, "MCP authorization rejected. Sign in with ni mcp login " & sess.config.name)
  if code == 403:
    raise newException(McpOAuthError, "MCP access forbidden. Check the credential or sign in with the required scope.")
  if code == 404 and sess.httpSessionId.len > 0:
    raise newException(McpSessionExpired, "MCP server no longer recognizes this session")
  if code < 200 or code >= 300:
    let message = "MCP HTTP " & $code & " from '" & sess.config.name & "'"
    if code < 500: raise newException(McpProtocolError, message)
    raise newException(IOError, message)
  let sessionId = resp.headers.getOrDefault("Mcp-Session-Id").strip()
  if sessionId.len > 0: sess.httpSessionId = sessionId
  if code == 202 or not expectResponse:
    return none(JsonNode)
  let isSse = "text/event-stream" in resp.headers.getOrDefault("Content-Type").toLowerAscii()
  let expectedId = payload{"id"}.getInt(-1)
  var rawBody = ""
  while true:
    let (more, chunk) = waitForMcpHttp(resp.bodyStream.read(), deadline, abort)
    if not more: break
    rawBody.add(chunk)
    if isSse and ("\n\n" in rawBody or "\r\n\r\n" in rawBody):
      let matched = parseSseJsonRpcResponse(rawBody, expectedId)
      if matched.isSome: return matched
  if isSse or rawBody.strip().startsWith("event:") or rawBody.strip().startsWith("data:"):
    let matched = parseSseJsonRpcResponse(rawBody, expectedId)
    if matched.isSome: return matched
    raise newException(McpProtocolError, "MCP SSE stream from '" & sess.config.name & "' ended without matching JSON-RPC response")
  try: some(parseJson(rawBody))
  except CatchableError:
    raise newException(McpProtocolError, "MCP server returned an invalid JSON response")

proc postMcpHttp(sess: McpServerSession, payload: JsonNode, expectResponse: bool, abort: AbortFlag = nil): Option[JsonNode] =
  let oauth = getOAuthToken(sess.oauthFile, sess.config.url, sess.proxyUrl, abort = abort)
  try:
    return requestMcpHttp(sess, payload, expectResponse, oauth.accessToken, abort)
  except McpAuthRejected:
    if oauth.refreshToken.len == 0: raise
    let refreshed = getOAuthToken(sess.oauthFile, sess.config.url, sess.proxyUrl, force = true,
      rejectedToken = oauth.accessToken, abort = abort)
    return requestMcpHttp(sess, payload, expectResponse, refreshed.accessToken, abort)

proc connectServer*(sess: McpServerSession, cfgBundle: ConfigBundle, security: SecurityPolicy = nil,
                    abort: AbortFlag = nil)

proc rpcRequest(sess: McpServerSession, meth: string, params: JsonNode, workspaceRoot: string, abort: AbortFlag = nil): JsonNode =
  case sess.config.transportKind
  of mtkStdio:
    rpcRequestStdio(sess, meth, params, workspaceRoot, abort)
  of mtkHttp:
    inc sess.nextReqId
    let myId = sess.nextReqId
    var req = %*{ "jsonrpc": "2.0", "id": myId, "method": meth }
    if not params.isNil:
      req["params"] = params
    var respOpt: Option[JsonNode]
    try:
      try:
        respOpt = postMcpHttp(sess, req, expectResponse = true, abort = abort)
      except McpSessionExpired:
        if sess.state != mcsConnected or sess.bundle.isNil: raise
        sess.connectServer(sess.bundle, sess.security, abort)
        if sess.state != mcsConnected:
          raise newException(IOError, "MCP reconnect failed: " & sess.lastError)
        respOpt = postMcpHttp(sess, req, expectResponse = true, abort = abort)
    except McpAbortError:
      if sess.state == mcsConnected:
        let timeout = newAbortFlag()
        let deadline = getMonoTime() + initDuration(milliseconds = 200)
        timeout.onIdle = proc() =
          if getMonoTime() >= deadline: timeout.aborted = true
        try:
          let token = loadOAuthToken(sess.oauthFile).accessToken
          discard requestMcpHttp(sess, %*{"jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": {"requestId": myId, "reason": "Cancelled by user"}}, false, token, timeout)
        except CatchableError:
          discard
      raise
    if respOpt.isNone:
      raise newException(McpProtocolError, "MCP server accepted the request without returning a result")
    let msg = respOpt.get
    if msg.kind != JObject or msg{"id"}.getInt(-1) != myId:
      raise newException(McpProtocolError, "MCP server returned a mismatched JSON-RPC response")
    if msg.hasKey("error") and msg["error"].kind == JObject:
      raise newException(McpProtocolError, "MCP '" & sess.config.name & "' " & meth & " error: " & msg["error"]{"message"}.getStr(""))
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

proc connectServer*(sess: McpServerSession, cfgBundle: ConfigBundle, security: SecurityPolicy = nil,
                    abort: AbortFlag = nil) =
  ## Start transport, run MCP initialize handshake, and fetch paginated tools/list.
  if not sess.config.enabled:
    sess.state = mcsDisabled
    return

  sess.bundle = cfgBundle
  sess.security = security
  sess.state = mcsIdle
  sess.httpSessionId = ""
  sess.protocolVersion = ""
  sess.remoteTools.setLen(0)
  try:
    case sess.config.transportKind
    of mtkStdio:
      let envTable = security.processEnvironment()
      for ek, rawVal in sess.config.envRaw.pairs:
        let resolved = resolveConfigValue(rawVal, cfgBundle.commandCache, cacheCommands = true)
        if resolved.isSome:
          envTable[ek] = resolved.get
      let opts: set[ProcessOption] =
        when defined(windows):
          # PeekNamedPipe works with anonymous pipes. Use blocking writes so
          # a JSONL request cannot be partially written into a full pipe.
          {poUsePath, poDaemon}
        else:
          {poUsePath}
      let runCwd = if dirExists(sess.config.cwd): sess.config.cwd else: cfgBundle.cwd
      let denial = security.checkFileRead(runCwd)
      if denial.len > 0:
        raise newException(IOError, denial)
      let (exe, args) = security.wrapProcess(sess.config.command, sess.config.args, runCwd)
      sess.process = startProcess(exe, workingDir = runCwd, args = args, env = envTable, options = opts)
    of mtkHttp:
      sess.proxyUrl = cfgBundle.settings.httpProxy
      sess.resolvedHeaders = initTable[string, string]()
      sess.oauthFile = oauthPath(cfgBundle.agentDir, sess.config.name, sess.config.url)
      for hk, rawVal in sess.config.headersRaw.pairs:
        if hk.toLowerAscii() == "authorization": sess.oauthFile = ""
        let resolved = resolveConfigValue(rawVal, cfgBundle.commandCache, cacheCommands = true)
        if resolved.isSome:
          sess.resolvedHeaders[hk] = resolved.get

    let initRes = sess.rpcRequest("initialize", %*{
      "protocolVersion": McpProtocolVersion,
      "capabilities": { "roots": { "listChanged": false } },
      "clientInfo": { "name": "ni", "version": NiVersion }
    }, cfgBundle.cwd, abort)
    sess.protocolVersion = initRes{"protocolVersion"}.getStr(McpProtocolVersion)

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
        let listRes = sess.rpcRequest("tools/list", params, cfgBundle.cwd, abort)
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
    sess.failureKind = mcfNone
  except CatchableError as e:
    sess.state = mcsFailed
    sess.lastError = e.msg
    sess.failureKind = if e of McpOAuthError: mcfAuth
      elif e of McpProtocolError or e of ValueError: mcfProtocol
      else: mcfNetwork
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
        let proxy = if sess.proxyUrl.len > 0: newProxy(sess.proxyUrl) else: nil
        let client = newHttpClient(maxRedirects = 0, timeout = 2000, proxy = proxy)
        defer: client.close()
        for key, value in sess.resolvedHeaders.pairs:
          client.headers[key] = value
        let credentials = loadOAuthToken(sess.oauthFile)
        if credentials.accessToken.len > 0:
          client.headers["Authorization"] = "Bearer " & credentials.accessToken
        client.headers["Mcp-Session-Id"] = sess.httpSessionId
        discard client.request(sess.config.url, httpMethod = HttpDelete)
      except CatchableError:
        discard
      sess.httpSessionId = ""
  if sess.state == mcsConnected:
    sess.state = mcsIdle

proc middleTruncateMcpText*(text, serverName: string): tuple[output: string, savedPath: string] =
  ## Match Pi's 20KB MCP middle-truncation behavior with full text saved to a temp file.
  if text.len <= McpToolMaxTextBytes:
    return (text, "")
  let saved = saveFullOutputTemp("mcp-" & sanitizeMcpIdent(serverName), text)
  let half = McpToolMaxTextBytes div 2
  let headEnd = utf8BoundaryBefore(text, half)
  let tailStart = utf8BoundaryAfter(text, text.len - half)
  let omitted = tailStart - headEnd
  var clipped = text[0 ..< headEnd] & "\n…" & $omitted & " bytes truncated…\n" & text[tailStart .. ^1]
  if saved.len > 0:
    clipped.add("\n[Full MCP tool result saved to " & saved & "]")
  (clipped, saved)

proc callMcpTool*(sess: McpServerSession, rawToolName: string, args: JsonNode, workspaceRoot: string,
                  abort: AbortFlag = nil): ToolOutput =
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
    }, workspaceRoot, abort)

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
    if not (e of McpAbortError):
      sess.lastError = e.msg
      sess.failureKind = if e of McpOAuthError: mcfAuth
        elif e of McpProtocolError or e of ValueError: mcfProtocol
        else: mcfNetwork
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
          let res = sess.rpcRequest("resources/list", params, mgr.workspaceRoot, ctx.abort)
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
        let res = sess.rpcRequest("resources/read", %*{ "uri": uri }, mgr.workspaceRoot, ctx.abort)
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
  else:
    reg.discoverableNames.incl(listTool.name)
    reg.discoverableNames.incl(readResTool.name)

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
      callMcpTool(sess, rawToolName, args, workspaceRoot, ctx.abort)
  )

proc newMcpManager*(cfg: ConfigBundle, reg: ToolRegistry, connectNow = true, security: SecurityPolicy = nil): McpManager =
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
      sess.connectServer(cfg, security)
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
          reg.discoverableNames.incl(rt.qualifiedName)
          needToolSearch = true

  if anyResources:
    registerMcpResourceTools(result, reg, widestResExposure)
    if widestResExposure != teDirect:
      needToolSearch = true

  # Auto-enable tool_search when deferred/codemode MCP tools are present so any Pi mcp.json works seamlessly!
  if needToolSearch and reg.tools.hasKey("tool_search"):
    reg.activeNames.incl("tool_search")

proc configureRuntimeTools*(cfg: ConfigBundle, overrides: seq[seq[string]],
                            noTools, noMcp: bool, security: SecurityPolicy = nil,
                            additionalTools: seq[AgentTool] = @[]):
    tuple[tools: ToolRegistry, mcp: McpManager] =
  result.tools = newToolRegistry(if noTools: @[] else: cfg.settings.defaultTools)
  result.mcp = if noTools or noMcp:
    McpManager(servers: initOrderedTable[string, McpServerSession](), workspaceRoot: cfg.cwd)
  else:
    newMcpManager(cfg, result.tools, security = security)
  if not noTools:
    for tool in additionalTools:
      result.tools.tools[tool.name] = tool
      result.tools.activeNames.incl(tool.name)
    for entries in overrides:
      result.tools.applyToolOverrides(entries)

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
