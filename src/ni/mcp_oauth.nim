# OAuth authorization code flow for Streamable HTTP MCP servers.

import std/[asyncdispatch, asynchttpserver, asyncstreams, base64, browsers, httpclient, json,
  monotimes, net, os, strutils, sysrand, tempfiles, times, uri]
import std/openssl
when defined(posix): import std/posix
import ./[types, utf8, release_info]

type
  McpOAuthError* = object of IOError
  McpOAuthOptions* = object
    clientId*, clientSecret*, clientName*, scope*, metadataUrl*, callbackUrl*: string
    callbackPort*: int
  McpOAuthToken* = object
    clientId*, clientSecret*, accessToken*, refreshToken*, tokenEndpoint*: string
    expiresMs*: int64

proc sha256(data: pointer, size: csize_t, output: pointer): pointer
  {.cdecl, importc: "SHA256", dynlib: DLLUtilName.}

when defined(posix):
  proc credentialFlock(fd, operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}

proc digest(value: string): string =
  result = newString(32)
  if sha256(unsafeAddr value[0], value.len.csize_t, addr result[0]).isNil:
    raise newException(McpOAuthError, "Could not compute the OAuth PKCE challenge")

proc base64Url(value: string): string =
  base64.encode(value, safe = true).strip(leading = false, chars = {'='})

proc oauthPath*(agentDir, name, url: string): string =
  agentDir / "mcp-credentials" / (base64Url(digest(name.toLowerAscii() & "\n" & url)) & ".json")

proc lockCredentials(path: string, abort: AbortFlag = nil): File =
  when defined(posix):
    let dir = parentDir(path)
    createDir(dir)
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    let lock = open(path & ".lock", fmAppend)
    let deadline = getMonoTime() + initDuration(seconds = 20)
    try:
      const ExclusiveNonBlocking = 2 or 4
      while credentialFlock(cint(lock.getOsFileHandle()), ExclusiveNonBlocking) != 0:
        if osLastError().int32 notin [EAGAIN, EWOULDBLOCK, EINTR]:
          raiseOSError(osLastError())
        if abort.pollAbort() or getMonoTime() >= deadline:
          raise newException(McpOAuthError, "Could not acquire the MCP credential lock")
        sleep(25)
      return lock
    except CatchableError:
      lock.close()
      raise

proc signOutOAuth*(path: string) =
  if not fileExists(path): return
  let lock = lockCredentials(path)
  defer:
    if not lock.isNil: lock.close()
  if fileExists(path): removeFile(path)

proc loadOAuthToken*(path: string): McpOAuthToken =
  if path.len == 0 or not fileExists(path): return
  try:
    let node = parseFile(path)
    result = McpOAuthToken(
      clientId: node{"clientId"}.getStr(), clientSecret: node{"clientSecret"}.getStr(),
      accessToken: node{"accessToken"}.getStr(), refreshToken: node{"refreshToken"}.getStr(),
      tokenEndpoint: node{"tokenEndpoint"}.getStr(), expiresMs: node{"expiresMs"}.getBiggestInt())
    if '\r' in result.accessToken or '\n' in result.accessToken:
      raise newException(McpOAuthError, "Malformed OAuth access token")
  except CatchableError:
    raise newException(McpOAuthError, "Stored MCP credentials are unreadable. Sign in again.")

proc saveOAuthToken(path: string, token: McpOAuthToken) =
  let dir = parentDir(path)
  createDir(dir)
  when defined(posix):
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  let (f, temporary) = createTempFile(".oauth-", "", dir)
  try:
    try:
      when defined(posix):
        setFilePermissions(temporary, {fpUserRead, fpUserWrite})
      f.writeLine(encodeJsonUtf8(%*{"clientId": token.clientId, "clientSecret": token.clientSecret,
        "accessToken": token.accessToken, "refreshToken": token.refreshToken,
        "tokenEndpoint": token.tokenEndpoint, "expiresMs": token.expiresMs}))
    finally:
      f.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc checkOAuthUrl(value: string): Uri =
  result = parseUri(value)
  if result.hostname.len == 0 or result.username.len > 0 or result.password.len > 0 or result.anchor.len > 0 or
      (result.scheme != "https" and (result.scheme != "http" or
        result.hostname.toLowerAscii() notin ["localhost", "127.0.0.1", "::1"])):
    raise newException(McpOAuthError, "MCP OAuth URLs must use HTTPS or loopback HTTP")

proc waitOAuth[T](future: Future[T], deadline: MonoTime, abort: AbortFlag): T =
  while not future.finished:
    if abort.pollAbort():
      raise newException(McpOAuthError, "MCP authorization cancelled")
    let remaining = (deadline - getMonoTime()).inMilliseconds.int
    if remaining <= 0: raise newException(IOError, "MCP OAuth request timed out")
    discard waitFor withTimeout(future, min(50, remaining))
  future.read()

proc oauthRequest(url: string, verb: HttpMethod, proxyUrl: string, body = "",
                  contentType = "", abort: AbortFlag = nil):
    tuple[status: int, challenge: string, node: JsonNode] =
  discard checkOAuthUrl(url)
  let proxy = if proxyUrl.len > 0: newProxy(proxyUrl) else: nil
  let client = newAsyncHttpClient(maxRedirects = 0, proxy = proxy)
  defer: client.close()
  let headers = newHttpHeaders({"Accept": "application/json"})
  if contentType.len > 0: headers["Content-Type"] = contentType
  let deadline = getMonoTime() + initDuration(seconds = 15)
  let response = waitOAuth(client.request(url, httpMethod = verb, body = body, headers = headers), deadline, abort)
  result.status = response.code.int
  result.challenge = response.headers.getOrDefault("WWW-Authenticate")
  if result.status in 200..299:
    let text = waitOAuth(response.bodyStream.readAll(), deadline, abort)
    result.node = try: parseJson(text)
      except CatchableError: raise newException(McpOAuthError, "MCP OAuth endpoint returned invalid JSON")

proc challengeParam(header, name: string): string =
  let lower = header.toLowerAscii()
  let start = lower.find(name & "=")
  if start < 0: return ""
  let valueAt = start + name.len + 1
  if valueAt >= header.len: return ""
  if header[valueAt] == '"':
    let closing = header.find('"', valueAt + 1)
    if closing > valueAt: return header[valueAt + 1 ..< closing]
  else:
    return header[valueAt .. ^1].split({',', ' '})[0]
  ""

proc wellKnown(uri: Uri, name: string, withPath: bool): string =
  var metadata = uri
  metadata.path = "/.well-known/" & name & (if withPath: uri.path.strip(leading = false, chars = {'/'}) else: "")
  metadata.query = ""
  $metadata

proc discoverOAuth(resource, proxyUrl: string, options: McpOAuthOptions):
    tuple[metadata: JsonNode, scope: string] =
  let resourceUri = checkOAuthUrl(resource)
  if options.metadataUrl.len > 0:
    let metadata = oauthRequest(options.metadataUrl, HttpGet, proxyUrl)
    if metadata.status notin 200..299:
      raise newException(McpOAuthError, "Configured authorization metadata returned HTTP " & $metadata.status)
    return (metadata.node, options.scope)

  let init = oauthRequest(resource, HttpPost, proxyUrl,
    encodeJsonUtf8(%*{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
      "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "ni", "version": NiVersion}}}),
    "application/json")
  let discovered = challengeParam(init.challenge, "resource_metadata")
  let urls = if discovered.len > 0: @[discovered]
    else: @[wellKnown(resourceUri, "oauth-protected-resource", true), wellKnown(resourceUri, "oauth-protected-resource", false)]
  var issuer = ""
  var scope = challengeParam(init.challenge, "scope")
  for url in urls:
    let meta = oauthRequest(url, HttpGet, proxyUrl)
    if meta.status notin 200..299: continue
    if meta.node{"resource"}.getStr() != resource:
      raise newException(McpOAuthError, "OAuth protected-resource metadata does not identify the configured server")
    let servers = meta.node{"authorization_servers"}
    if not servers.isNil and servers.kind == JArray and servers.len > 0:
      issuer = servers[0].getStr()
    if scope.len == 0:
      let scopes = meta.node{"scopes_supported"}
      if not scopes.isNil and scopes.kind == JArray:
        var names: seq[string]
        for value in scopes:
          if value.kind == JString: names.add(value.getStr())
        scope = names.join(" ")
    break
  if issuer.len == 0:
    if discovered.len > 0:
      raise newException(McpOAuthError, "Protected-resource metadata does not specify an authorization server")
    var origin = resourceUri
    origin.path = ""
    origin.query = ""
    issuer = $origin

  let issuerUri = checkOAuthUrl(issuer)
  if issuerUri.query.len > 0:
    raise newException(McpOAuthError, "OAuth issuer cannot include a query")
  for url in [wellKnown(issuerUri, "oauth-authorization-server", true),
              issuer.strip(leading = false, chars = {'/'}) & "/.well-known/openid-configuration"]:
    let meta = oauthRequest(url, HttpGet, proxyUrl)
    if meta.status notin 200..299: continue
    if meta.node{"issuer"}.getStr() != issuer:
      raise newException(McpOAuthError, "OAuth authorization metadata issuer does not match discovery")
    return (meta.node, if options.scope.len > 0: options.scope else: scope)
  raise newException(McpOAuthError, "Could not discover OAuth authorization server metadata")

proc secureNonce(): string =
  let bytes = urandom(32)
  base64.encode(bytes, safe = true).strip(leading = false, chars = {'='})

proc applyTokenResponse(token: var McpOAuthToken, response: JsonNode) =
  let value = response{"access_token"}.getStr()
  if value.len == 0 or '\r' in value or '\n' in value or
      response{"token_type"}.getStr("Bearer").toLowerAscii() != "bearer":
    raise newException(McpOAuthError, "OAuth endpoint did not return a usable bearer token")
  token.accessToken = value
  token.refreshToken = response{"refresh_token"}.getStr(token.refreshToken)
  let expires = clamp(response{"expires_in"}.getBiggestInt(), 0'i64, high(int64) div 2000)
  token.expiresMs = if expires > 0: nowUnixMs() + expires * 1000 else: 0

proc exchangeToken(token: var McpOAuthToken, params: seq[(string, string)], proxyUrl: string,
                   abort: AbortFlag = nil) =
  var fields = params & @[("client_id", token.clientId)]
  if token.clientSecret.len > 0: fields.add(("client_secret", token.clientSecret))
  let reply = oauthRequest(token.tokenEndpoint, HttpPost, proxyUrl, encodeQuery(fields),
    "application/x-www-form-urlencoded", abort)
  if reply.status notin 200..299:
    raise newException(McpOAuthError, "OAuth token exchange returned HTTP " & $reply.status & ". Sign in again.")
  token.applyTokenResponse(reply.node)

proc getOAuthToken*(path, resource, proxyUrl: string, force = false, rejectedToken = "",
                    abort: AbortFlag = nil): McpOAuthToken =
  result = loadOAuthToken(path)
  if result.accessToken.len == 0: return
  proc needsRefresh(token: McpOAuthToken): bool =
    (force and token.accessToken == rejectedToken) or (token.expiresMs > 0 and token.expiresMs <= nowUnixMs() + 5000)
  if not needsRefresh(result): return
  let lock = lockCredentials(path, abort)
  defer:
    if not lock.isNil: lock.close()
  result = loadOAuthToken(path)
  if result.accessToken.len == 0 or not needsRefresh(result): return
  if result.refreshToken.len == 0:
    if not force and result.expiresMs > nowUnixMs(): return
    raise newException(McpOAuthError, "MCP credential expired. Sign in again.")
  let previous = result.refreshToken
  try:
    result.exchangeToken(@[("grant_type", "refresh_token"), ("refresh_token", previous),
      ("resource", resource)], proxyUrl, abort)
  except McpOAuthError:
    let newer = loadOAuthToken(path)
    if newer.refreshToken != previous and newer.accessToken.len > 0: return newer
    raise
  let latest = loadOAuthToken(path)
  if latest.accessToken.len == 0:
    raise newException(McpOAuthError, "MCP credentials were removed. Sign in again.")
  if latest.refreshToken != previous and latest.accessToken.len > 0: return latest
  saveOAuthToken(path, result)

proc loginMcpOAuth*(resource, proxyUrl, path: string, options: McpOAuthOptions, openBrowser = true,
                    announce: proc(url: string) {.closure.}) =
  let (metadata, scope) = discoverOAuth(resource, proxyUrl, options)
  let issuer = metadata{"issuer"}.getStr()
  let authEndpoint = metadata{"authorization_endpoint"}.getStr()
  discard checkOAuthUrl(authEndpoint)
  var token = McpOAuthToken(clientId: options.clientId, clientSecret: options.clientSecret,
    tokenEndpoint: metadata{"token_endpoint"}.getStr())
  discard checkOAuthUrl(token.tokenEndpoint)
  let methods = metadata{"code_challenge_methods_supported"}
  var supportsS256 = false
  if not methods.isNil and methods.kind == JArray:
    for challengeMethod in methods:
      if challengeMethod.getStr() == "S256": supportsS256 = true
  if not supportsS256: raise newException(McpOAuthError, "Authorization server did not advertise PKCE S256")

  var callback = parseUri(if options.callbackUrl.len > 0: options.callbackUrl else: "http://127.0.0.1/callback")
  discard checkOAuthUrl($callback)
  if callback.scheme != "http" or callback.hostname notin ["127.0.0.1", "localhost", "::1"] or
      callback.query.len > 0 or callback.path.len == 0:
    raise newException(McpOAuthError, "OAuth callback must be a loopback HTTP URL with a path")
  let port = if callback.port.len > 0: parseInt(callback.port) else: options.callbackPort
  if port notin 0..65535: raise newException(McpOAuthError, "Invalid OAuth callback port")
  let server = newAsyncHttpServer(maxBody = 4096)
  defer: server.close()
  let address = if callback.hostname == "localhost": "127.0.0.1" else: callback.hostname
  server.listen(Port(port), address, (if address == "::1": Domain.AF_INET6 else: Domain.AF_INET))
  callback.port = $server.getPort().int
  let redirect = $callback

  if token.clientId.len == 0:
    let registration = metadata{"registration_endpoint"}.getStr()
    if registration.len == 0:
      raise newException(McpOAuthError, "Authorization server requires a registered client ID")
    let reply = oauthRequest(registration, HttpPost, proxyUrl, encodeJsonUtf8(%*{
      "client_name": (if options.clientName.len > 0: options.clientName else: "ni"),
      "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"], "token_endpoint_auth_method": "none"}), "application/json")
    if reply.status notin 200..299 or reply.node{"client_id"}.getStr().len == 0:
      raise newException(McpOAuthError, "OAuth client registration failed with HTTP " & $reply.status)
    token.clientId = reply.node["client_id"].getStr()
    token.clientSecret = reply.node{"client_secret"}.getStr()

  let verifier = secureNonce()
  let state = secureNonce()
  var params = @[("response_type", "code"), ("client_id", token.clientId), ("redirect_uri", redirect),
    ("code_challenge", base64Url(digest(verifier))), ("code_challenge_method", "S256"),
    ("state", state), ("resource", resource)]
  if scope.len > 0: params.add(("scope", scope))
  let url = authEndpoint & (if '?' in authEndpoint: "&" else: "?") & encodeQuery(params)
  announce(url)
  if openBrowser: openDefaultBrowser(url)

  var code, denied: string
  let callbackDone = newFuture[void]("MCP OAuth callback")
  let requireIssuer = metadata{"authorization_response_iss_parameter_supported"}.getBool()
  proc handle(request: Request) {.async, gcsafe.} =
    if request.reqMethod != HttpGet or request.url.path != callback.path:
      await request.respond(Http404, "Unknown callback")
      return
    var actualState, actualIssuer, receivedCode, receivedError: string
    for key, value in decodeQuery(request.url.query):
      case key
      of "state": actualState = value
      of "iss": actualIssuer = value
      of "code": receivedCode = value
      of "error": receivedError = value
      else: discard
    if actualState != state or ((requireIssuer or actualIssuer.len > 0) and actualIssuer != issuer):
      await request.respond(Http400, "Invalid OAuth callback")
      return
    if code.len > 0 or denied.len > 0:
      await request.respond(Http409, "Authorization already received")
      return
    if receivedCode.len == 0 and receivedError.len == 0:
      await request.respond(Http400, "Missing OAuth authorization code")
      return
    code = receivedCode
    denied = receivedError
    await request.respond(Http200, "Authorization response received. Return to ni.")
    if not callbackDone.finished: callbackDone.complete()

  let deadline = getMonoTime() + initDuration(minutes = 3)
  var pending = server.acceptRequest(handle)
  while not callbackDone.finished:
    if getMonoTime() >= deadline:
      raise newException(McpOAuthError, "MCP OAuth callback timed out")
    discard waitFor withTimeout(callbackDone, 50)
    if not callbackDone.finished and pending.finished:
      pending.read()
      pending = server.acceptRequest(handle)
  if denied.len > 0: raise newException(McpOAuthError, "MCP OAuth authorization was denied")
  token.exchangeToken(@[("grant_type", "authorization_code"), ("code", code),
    ("code_verifier", verifier), ("redirect_uri", redirect), ("resource", resource)], proxyUrl)
  let lock = lockCredentials(path)
  defer:
    if not lock.isNil: lock.close()
  saveOAuthToken(path, token)
