# Pi-compatible configuration, auth.json, models.json, settings.json, and context file loader.

import std/[json, options, os, osproc, strutils, tables, sets]
when not defined(windows):
  import std/posix
import ./types

const
  ProjectConfigDirName* = ".pi"
  DefaultBuiltInTools* = @["read", "bash", "edit", "write", "grep", "find", "ls", "ask_question"]

type
  ProjectTrustMode* = enum
    ptmAsk = "ask"
    ptmAlways = "always"
    ptmNever = "never"

  CompactionSettings* = object
    enabled*: bool
    reserveTokens*: int
    keepRecentTokens*: int

  RetrySettings* = object
    enabled*: bool
    maxRetries*: int
    baseDelayMs*: int
    maxDelayMs*: int

  CodemodeSettings* = object
    mode*: string
    inlineBudget*: int

  NiSettings* = object
    defaultProvider*: string
    defaultModel*: string
    defaultThinkingLevel*: ThinkingLevel
    modelThinkingLevels*: Table[string, ThinkingLevel]
    hideThinkingBlock*: bool
    defaultProjectTrust*: ProjectTrustMode
    defaultTools*: seq[string]
    codemode*: CodemodeSettings
    sessionDir*: string
    compaction*: CompactionSettings
    httpProxy*: string
    httpIdleTimeoutMs*: int
    retry*: RetrySettings
    shellPath*: string
    shellCommandPrefix*: string
    skills*: seq[string]
    prompts*: seq[string]
    enableSkillCommands*: bool
    securityMode*: SecurityMode

  CredentialKind* = enum
    ckApiKey
    ckOAuth

  StoredCredential* = object
    kind*: CredentialKind
    rawKeyOrToken*: string
    env*: Table[string, string]
    refreshToken*: string     ## OAuth only
    expiresMs*: int64         ## OAuth only: access token expiry (Unix ms), 0 when unknown

  ModelPricing* = object
    input*: float
    output*: float
    cacheRead*: float
    cacheWrite*: float

  OpenAICompat* = object
    supportsStore*: Option[bool]
    supportsDeveloperRole*: Option[bool]
    supportsReasoningEffort*: Option[bool]
    supportsUsageInStreaming*: bool
    maxTokensField*: string
    requiresToolResultName*: bool
    requiresNonNullAssistantContent*: bool
    requiresReasoningContentOnAssistantMessages*: Option[bool]
    thinkingFormat*: string
    supportsStrictMode*: bool

  ModelConfig* = object
    id*: string
    name*: string
    provider*: string
    api*: string
    baseUrl*: string
    reasoning*: bool
    inputs*: seq[string]
    contextWindow*: int
    maxTokens*: int
    cost*: ModelPricing
    headers*: Table[string, string]
    compat*: OpenAICompat
    samplingParams*: JsonNode
    ## Pi `thinkingLevelMap`: a missing level uses its own name, `none` marks a level the model rejects (JSON null).
    thinkingLevelMap*: Table[ThinkingLevel, Option[string]]

  ProviderConfig* = object
    id*: string
    name*: string
    baseUrl*: string
    apiKeyRaw*: string
    api*: string
    authHeader*: bool
    headers*: Table[string, string]
    compat*: OpenAICompat
    envVars*: seq[string]
    models*: seq[ModelConfig]
    modelOverrides*: Table[string, JsonNode]

  ContextFile* = object
    path*: string
    content*: string

  ConfigBundle* = ref object
    cwd*: string
    agentDir*: string
    projectTrusted*: bool
    settings*: NiSettings
    auth*: Table[string, StoredCredential]
    storeProviders*: Table[string, ProviderConfig]
    customProviders*: Table[string, ProviderConfig]
    contextFiles*: seq[ContextFile]
    customSystemPrompt*: string
    appendSystemPrompt*: string
    commandCache*: Table[string, Option[string]]
    diagnostics*: seq[string]

proc stripUtf8Bom*(s: string): string =
  ## Strip leading UTF-8 BOM if present.
  if s.startsWith("\xEF\xBB\xBF"):
    s[3 .. ^1]
  else:
    s

proc resolvePathFrom*(p: string, baseDir: string): string =
  ## Resolve relative or ~ path against baseDir and normalize separators.
  let expanded = os.expandTilde(p.strip())
  if expanded.isAbsolute:
    normalizedPath(expanded)
  else:
    normalizedPath(baseDir / expanded)

proc getAgentDir*(overrideDir = ""): string =
  ## Locate agent configuration directory (~/.pi/agent by default, matching Pi).
  if overrideDir.strip().len > 0:
    return resolvePathFrom(overrideDir, getCurrentDir())
  let niEnv = getEnv("NI_AGENT_DIR").strip()
  if niEnv.len > 0:
    return resolvePathFrom(niEnv, getCurrentDir())
  let piEnv = getEnv("PI_CODING_AGENT_DIR").strip()
  if piEnv.len > 0:
    return resolvePathFrom(piEnv, getCurrentDir())
  normalizedPath(getHomeDir() / ".pi" / "agent")

# Config value resolution: literal, $ENV / ${ENV}, $$ / $!, and !command

proc isEnvIdentStart(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '_'}

proc isEnvIdentChar(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc runSecretCommand(cmd: string): Option[string] =
  let actual = cmd.strip()
  if actual.len == 0:
    return none(string)
  try:
    let (outp, code) = execCmdEx(actual, options = {poUsePath})
    let trimmed = outp.strip()
    if code == 0 and trimmed.len > 0:
      return some(trimmed)
  except CatchableError:
    discard
  none(string)

proc resolveConfigValue*(
  raw: string,
  commandCache: var Table[string, Option[string]],
  extraEnv: Table[string, string] = initTable[string, string](),
  cacheCommands = true
): Option[string] =
  ## Resolve a Pi config value: !command, $VAR / ${VAR} template, or literal.
  if raw.len == 0:
    return none(string)
  if raw.startsWith("!"):
    let cmd = raw[1 .. ^1]
    if cacheCommands and commandCache.hasKey(cmd):
      return commandCache[cmd]
    let res = runSecretCommand(cmd)
    if cacheCommands:
      commandCache[cmd] = res
    return res

  var outStr = ""
  var i = 0
  while i < raw.len:
    if raw[i] != '$':
      outStr.add(raw[i])
      inc i
      continue
    if i + 1 >= raw.len:
      outStr.add('$')
      inc i
      continue
    let nxt = raw[i + 1]
    if nxt == '$' or nxt == '!':
      outStr.add(nxt)
      i += 2
      continue
    if nxt == '{':
      let closeIdx = raw.find('}', i + 2)
      if closeIdx < 0:
        outStr.add('$')
        inc i
        continue
      let varName = raw[i + 2 ..< closeIdx]
      var valid = varName.len > 0 and isEnvIdentStart(varName[0])
      for ch in varName:
        if not isEnvIdentChar(ch):
          valid = false
          break
      if valid:
        let val = if extraEnv.hasKey(varName) and extraEnv[varName].len > 0:
          extraEnv[varName]
        else:
          getEnv(varName)
        if val.len == 0:
          return none(string)
        outStr.add(val)
      else:
        outStr.add(raw[i .. closeIdx])
      i = closeIdx + 1
      continue
    if isEnvIdentStart(nxt):
      var j = i + 1
      while j < raw.len and isEnvIdentChar(raw[j]):
        inc j
      let varName = raw[i + 1 ..< j]
      let val = if extraEnv.hasKey(varName) and extraEnv[varName].len > 0:
        extraEnv[varName]
      else:
        getEnv(varName)
      if val.len == 0:
        return none(string)
      outStr.add(val)
      i = j
      continue
    outStr.add('$')
    inc i

  some(outStr)

# Tool selection list merger (supports plain replacement or +tool / -tool delta syntax)

proc applyToolListSpec*(current: seq[string], entries: openArray[string]): seq[string] =
  ## Apply Pi's defaultTools / --tools selection semantics (+name, -name, or replacement).
  if entries.len == 0:
    return @[]
  var hasPlain = false
  for raw in entries:
    let item = raw.strip()
    if item.len == 0:
      continue
    if not item.startsWith("+") and not item.startsWith("-"):
      hasPlain = true
      break

  var active = if hasPlain: @[] else: current
  for raw in entries:
    let item = raw.strip()
    if item.len == 0:
      continue
    if item.startsWith("+"):
      let name = item[1 .. ^1].strip()
      if name.len > 0 and name notin active:
        active.add(name)
    elif item.startsWith("-"):
      let name = item[1 .. ^1].strip()
      var filtered: seq[string] = @[]
      for existing in active:
        if existing != name:
          filtered.add(existing)
      active = filtered
    else:
      if item notin active:
        active.add(item)
  active

proc defaultSettings*(): NiSettings =
  ## Built-in startup settings matching Pi defaults.
  NiSettings(
    defaultProvider: "",
    defaultModel: "",
    defaultThinkingLevel: tlMedium,
    modelThinkingLevels: initTable[string, ThinkingLevel](),
    hideThinkingBlock: false,
    defaultProjectTrust: ptmAsk,
    defaultTools: DefaultBuiltInTools,
    codemode: CodemodeSettings(mode: "on", inlineBudget: 3000),
    sessionDir: "",
    compaction: CompactionSettings(enabled: true, reserveTokens: 16384, keepRecentTokens: 20000),
    httpProxy: "",
    httpIdleTimeoutMs: 300_000,
    retry: RetrySettings(enabled: true, maxRetries: 3, baseDelayMs: 2000, maxDelayMs: 60_000),
    shellPath: "",
    shellCommandPrefix: "",
    skills: @[],
    prompts: @[],
    enableSkillCommands: true,
    securityMode: smBalanced
  )

proc readJsonFileSafe*(path: string, diagnostics: var seq[string]): Option[JsonNode] =
  ## Read and parse a JSON file safely, recording diagnostics on malformed JSON.
  if not fileExists(path):
    return none(JsonNode)
  try:
    let raw = stripUtf8Bom(readFile(path))
    if raw.strip().len == 0:
      return none(JsonNode)
    return some(parseJson(raw))
  except CatchableError as e:
    diagnostics.add("Failed to parse JSON file " & path & ": " & e.msg)
    return none(JsonNode)

proc mergeSettingsNode*(s: var NiSettings, node: JsonNode, baseDir: string, isUserScope: bool) =
  ## Merge one settings.json object into s; security-sensitive global settings apply only in user scope.
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("defaultProvider") and node["defaultProvider"].kind == JString:
    s.defaultProvider = node["defaultProvider"].getStr()
  if node.hasKey("defaultModel") and node["defaultModel"].kind == JString:
    s.defaultModel = node["defaultModel"].getStr()
  if node.hasKey("defaultThinkingLevel") and node["defaultThinkingLevel"].kind == JString:
    s.defaultThinkingLevel = parseThinkingLevel(node["defaultThinkingLevel"].getStr(), s.defaultThinkingLevel)
  if node.hasKey("modelThinkingLevels") and node["modelThinkingLevels"].kind == JObject:
    for k, v in node["modelThinkingLevels"].pairs:
      if v.kind == JString:
        s.modelThinkingLevels[k] = parseThinkingLevel(v.getStr(), s.defaultThinkingLevel)
  if node.hasKey("hideThinkingBlock") and node["hideThinkingBlock"].kind == JBool:
    s.hideThinkingBlock = node["hideThinkingBlock"].getBool()

  # Per Pi security spec: defaultProjectTrust and httpProxy can ONLY be set in agent-directory settings.
  if isUserScope:
    if node.hasKey("defaultProjectTrust") and node["defaultProjectTrust"].kind == JString:
      case node["defaultProjectTrust"].getStr().toLowerAscii()
      of "always": s.defaultProjectTrust = ptmAlways
      of "never": s.defaultProjectTrust = ptmNever
      else: s.defaultProjectTrust = ptmAsk
    if node.hasKey("httpProxy") and node["httpProxy"].kind == JString:
      s.httpProxy = node["httpProxy"].getStr()

  if node.hasKey("defaultTools") and node["defaultTools"].kind == JArray:
    var specs: seq[string] = @[]
    for item in node["defaultTools"].items:
      if item.kind == JString:
        specs.add(item.getStr())
    s.defaultTools = applyToolListSpec(s.defaultTools, specs)

  if node.hasKey("codemode") and node["codemode"].kind == JObject:
    let cm = node["codemode"]
    if cm.hasKey("mode") and cm["mode"].kind == JString:
      s.codemode.mode = cm["mode"].getStr()
    if cm.hasKey("inlineBudget") and cm["inlineBudget"].kind in {JInt, JFloat}:
      s.codemode.inlineBudget = cm["inlineBudget"].getInt(3000)

  if node.hasKey("sessionDir") and node["sessionDir"].kind == JString:
    let rawDir = node["sessionDir"].getStr()
    if rawDir.len > 0:
      s.sessionDir = resolvePathFrom(rawDir, baseDir)

  if node.hasKey("compaction") and node["compaction"].kind == JObject:
    let comp = node["compaction"]
    if comp.hasKey("enabled") and comp["enabled"].kind == JBool:
      s.compaction.enabled = comp["enabled"].getBool()
    if comp.hasKey("reserveTokens") and comp["reserveTokens"].kind == JInt:
      s.compaction.reserveTokens = max(0, comp["reserveTokens"].getInt())
    if comp.hasKey("keepRecentTokens") and comp["keepRecentTokens"].kind == JInt:
      s.compaction.keepRecentTokens = max(0, comp["keepRecentTokens"].getInt())

  if node.hasKey("httpIdleTimeoutMs"):
    let t = node["httpIdleTimeoutMs"]
    if t.kind == JString and t.getStr() == "disabled":
      s.httpIdleTimeoutMs = 0
    elif t.kind == JInt:
      s.httpIdleTimeoutMs = max(0, t.getInt())

  if node.hasKey("retry") and node["retry"].kind == JObject:
    let r = node["retry"]
    if r.hasKey("enabled") and r["enabled"].kind == JBool:
      s.retry.enabled = r["enabled"].getBool()
    if r.hasKey("maxRetries") and r["maxRetries"].kind == JInt:
      s.retry.maxRetries = max(0, r["maxRetries"].getInt())
    if r.hasKey("baseDelayMs") and r["baseDelayMs"].kind == JInt:
      s.retry.baseDelayMs = max(100, r["baseDelayMs"].getInt())
    if r.hasKey("maxAgentDelayMs") and r["maxAgentDelayMs"].kind == JInt:
      s.retry.maxDelayMs = max(100, r["maxAgentDelayMs"].getInt())

  if node.hasKey("shellPath") and node["shellPath"].kind == JString:
    s.shellPath = expandTilde(node["shellPath"].getStr())
  if node.hasKey("shellCommandPrefix") and node["shellCommandPrefix"].kind == JString:
    s.shellCommandPrefix = node["shellCommandPrefix"].getStr()

  if node.hasKey("skills") and node["skills"].kind == JArray:
    for item in node["skills"].items:
      if item.kind == JString:
        let rawSkill = item.getStr().strip()
        if rawSkill.len > 0 and not rawSkill.startsWith("-") and not rawSkill.startsWith("!"):
          let clean = if rawSkill.startsWith("+"): rawSkill[1 .. ^1] else: rawSkill
          let resolved = resolvePathFrom(clean, baseDir)
          if resolved notin s.skills:
            s.skills.add(resolved)

  if node.hasKey("prompts") and node["prompts"].kind == JArray:
    for item in node["prompts"].items:
      if item.kind == JString:
        let rawPromptPath = item.getStr().strip()
        if rawPromptPath.len > 0 and not rawPromptPath.startsWith("-") and not rawPromptPath.startsWith("!"):
          let clean = if rawPromptPath.startsWith("+"): rawPromptPath[1 .. ^1] else: rawPromptPath
          let resolved = resolvePathFrom(clean, baseDir)
          if resolved notin s.prompts:
            s.prompts.add(resolved)

  if node.hasKey("enableSkillCommands") and node["enableSkillCommands"].kind == JBool:
    s.enableSkillCommands = node["enableSkillCommands"].getBool()

  if node.hasKey("securityMode") and node["securityMode"].kind == JString:
    case node["securityMode"].getStr().toLowerAscii()
    of "strict": s.securityMode = smStrict
    of "permissive": s.securityMode = smPermissive
    else: s.securityMode = smBalanced

# auth.json loading and saving

proc loadAuthFile*(path: string, diagnostics: var seq[string]): Table[string, StoredCredential] =
  ## Load credentials from ~/.pi/agent/auth.json (both api_key and oauth bearer tokens).
  result = initTable[string, StoredCredential]()
  let parsed = readJsonFileSafe(path, diagnostics)
  if parsed.isNone or parsed.get.kind != JObject:
    return
  for providerId, entry in parsed.get.pairs:
    if entry.kind == JString:
      result[providerId] = StoredCredential(kind: ckApiKey, rawKeyOrToken: entry.getStr(), env: initTable[string, string]())
      continue
    if entry.kind != JObject:
      continue
    var envMap = initTable[string, string]()
    if entry.hasKey("env") and entry["env"].kind == JObject:
      for ek, ev in entry["env"].pairs:
        if ev.kind == JString:
          envMap[ek] = ev.getStr()
    let ctype = entry{"type"}.getStr("api_key")
    case ctype
    of "api_key":
      let k = entry{"key"}.getStr(entry{"apiKey"}.getStr(""))
      if k.len > 0:
        result[providerId] = StoredCredential(kind: ckApiKey, rawKeyOrToken: k, env: envMap)
    of "oauth":
      # Pi stores OAuth tokens under access / accessToken / token depending on provider flow.
      var tok = entry{"access"}.getStr("")
      if tok.len == 0: tok = entry{"accessToken"}.getStr("")
      if tok.len == 0: tok = entry{"token"}.getStr("")
      if tok.len > 0:
        result[providerId] = StoredCredential(
          kind: ckOAuth,
          rawKeyOrToken: tok,
          env: envMap,
          refreshToken: entry{"refresh"}.getStr(""),
          expiresMs: entry{"expires"}.getBiggestInt(0).int64
        )
    else:
      discard

proc saveOAuthCredential*(agentDir, providerId, access, refresh: string, expiresMs: int64) =
  ## Update a provider's oauth entry in auth.json in place (other fields are kept) with owner-only permissions.
  let authPath = agentDir / "auth.json"
  var root = newJObject()
  if fileExists(authPath):
    try:
      let existing = parseJson(stripUtf8Bom(readFile(authPath)))
      if existing.kind == JObject:
        root = existing
    except CatchableError:
      return # never overwrite an unreadable credential file
  var entry = if root.hasKey(providerId) and root[providerId].kind == JObject: root[providerId] else: newJObject()
  entry["type"] = %"oauth"
  entry["access"] = %access
  entry["refresh"] = %refresh
  entry["expires"] = %expiresMs
  root[providerId] = entry
  createDir(agentDir)
  writeFile(authPath, root.pretty() & "\n")
  when not defined(windows):
    discard chmod(authPath.cstring, 0o600)

proc saveApiKeyCredential*(agentDir, providerId, apiKey: string) =
  ## Save or update a provider's api_key entry in auth.json with owner-only permissions (0600 on POSIX).
  createDir(agentDir)
  let authPath = agentDir / "auth.json"
  var root = newJObject()
  if fileExists(authPath):
    try:
      let existing = parseJson(stripUtf8Bom(readFile(authPath)))
      if existing.kind == JObject:
        root = existing
    except CatchableError:
      root = newJObject()
  root[providerId] = %*{
    "type": "api_key",
    "key": apiKey
  }
  writeFile(authPath, root.pretty() & "\n")
  when not defined(windows):
    discard chmod(authPath.cstring, 0o600)

proc removeStoredCredential*(agentDir, providerId: string): bool =
  ## Delete a provider's credential from auth.json if present.
  let authPath = agentDir / "auth.json"
  if not fileExists(authPath):
    return false
  try:
    let existing = parseJson(stripUtf8Bom(readFile(authPath)))
    if existing.kind != JObject or not existing.hasKey(providerId):
      return false
    existing.delete(providerId)
    writeFile(authPath, existing.pretty() & "\n")
    when not defined(windows):
      discard chmod(authPath.cstring, 0o600)
    return true
  except CatchableError:
    return false

proc saveDefaultModelInSettings*(agentDir, providerId, modelId: string): bool =
  ## Persist `defaultProvider` and `defaultModel` into ~/.pi/agent/settings.json while preserving existing keys.
  createDir(agentDir)
  let settingsPath = agentDir / "settings.json"
  var root = newJObject()
  if fileExists(settingsPath):
    try:
      let parsed = parseJson(stripUtf8Bom(readFile(settingsPath)))
      if parsed.kind == JObject:
        root = parsed
    except CatchableError:
      return false
  root["defaultProvider"] = %providerId
  root["defaultModel"] = %modelId
  try:
    writeFile(settingsPath, root.pretty() & "\n")
    return true
  except CatchableError:
    return false

# models.json parsing

proc defaultCompat*(): OpenAICompat =
  OpenAICompat(
    supportsStore: none(bool),
    supportsDeveloperRole: none(bool),
    supportsReasoningEffort: none(bool),
    supportsUsageInStreaming: true,
    maxTokensField: "",
    requiresToolResultName: false,
    requiresNonNullAssistantContent: false,
    requiresReasoningContentOnAssistantMessages: none(bool),
    thinkingFormat: "",
    supportsStrictMode: false
  )

proc mergeCompatNode*(base: OpenAICompat, node: JsonNode): OpenAICompat =
  ## Merge an OpenAI-completions compat JSON object onto base.
  result = base
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("supportsStore") and node["supportsStore"].kind == JBool:
    result.supportsStore = some(node["supportsStore"].getBool())
  if node.hasKey("supportsDeveloperRole") and node["supportsDeveloperRole"].kind == JBool:
    result.supportsDeveloperRole = some(node["supportsDeveloperRole"].getBool())
  if node.hasKey("supportsReasoningEffort") and node["supportsReasoningEffort"].kind == JBool:
    result.supportsReasoningEffort = some(node["supportsReasoningEffort"].getBool())
  if node.hasKey("supportsUsageInStreaming") and node["supportsUsageInStreaming"].kind == JBool:
    result.supportsUsageInStreaming = node["supportsUsageInStreaming"].getBool()
  if node.hasKey("maxTokensField") and node["maxTokensField"].kind == JString:
    result.maxTokensField = node["maxTokensField"].getStr()
  if node.hasKey("requiresToolResultName") and node["requiresToolResultName"].kind == JBool:
    result.requiresToolResultName = node["requiresToolResultName"].getBool()
  if node.hasKey("requiresNonNullAssistantContent") and node["requiresNonNullAssistantContent"].kind == JBool:
    result.requiresNonNullAssistantContent = node["requiresNonNullAssistantContent"].getBool()
  if node.hasKey("requiresReasoningContentOnAssistantMessages") and node["requiresReasoningContentOnAssistantMessages"].kind == JBool:
    result.requiresReasoningContentOnAssistantMessages = some(node["requiresReasoningContentOnAssistantMessages"].getBool())
  if node.hasKey("thinkingFormat") and node["thinkingFormat"].kind == JString:
    result.thinkingFormat = node["thinkingFormat"].getStr()
  if node.hasKey("supportsStrictMode") and node["supportsStrictMode"].kind == JBool:
    result.supportsStrictMode = node["supportsStrictMode"].getBool()

proc mergeCompatObjects*(base, over: OpenAICompat): OpenAICompat =
  ## Overlay explicit compat fields from over onto base.
  result = base
  if over.supportsStore.isSome: result.supportsStore = over.supportsStore
  if over.supportsDeveloperRole.isSome: result.supportsDeveloperRole = over.supportsDeveloperRole
  if over.supportsReasoningEffort.isSome: result.supportsReasoningEffort = over.supportsReasoningEffort
  result.supportsUsageInStreaming = over.supportsUsageInStreaming
  if over.maxTokensField.len > 0: result.maxTokensField = over.maxTokensField
  if over.requiresToolResultName: result.requiresToolResultName = true
  if over.requiresNonNullAssistantContent: result.requiresNonNullAssistantContent = true
  if over.requiresReasoningContentOnAssistantMessages.isSome:
    result.requiresReasoningContentOnAssistantMessages = over.requiresReasoningContentOnAssistantMessages
  if over.thinkingFormat.len > 0: result.thinkingFormat = over.thinkingFormat
  if over.supportsStrictMode: result.supportsStrictMode = true

proc parseHeadersTable(node: JsonNode): Table[string, string] =
  result = initTable[string, string]()
  if not node.isNil and node.kind == JObject:
    for k, v in node.pairs:
      if v.kind == JString:
        result[k] = v.getStr()

proc parsePricing(node: JsonNode): ModelPricing =
  if node.isNil or node.kind != JObject:
    return ModelPricing()
  ModelPricing(
    input: node{"input"}.getFloat(0.0),
    output: node{"output"}.getFloat(0.0),
    cacheRead: node{"cacheRead"}.getFloat(0.0),
    cacheWrite: node{"cacheWrite"}.getFloat(0.0)
  )

proc parseThinkingLevelMap*(node: JsonNode): Table[ThinkingLevel, Option[string]] =
  ## Parse Pi's `thinkingLevelMap` object (`"medium": null` marks an unsupported level).
  result = initTable[ThinkingLevel, Option[string]]()
  if node.isNil or node.kind != JObject:
    return
  for k, v in node.pairs:
    if k notin ["off", "minimal", "low", "medium", "high", "xhigh", "max"]:
      continue
    let lv = parseThinkingLevel(k)
    case v.kind
    of JNull: result[lv] = none(string)
    of JString: result[lv] = some(v.getStr())
    else: discard

proc parseModelEntry*(providerId, providerApi, providerBaseUrl: string, providerCompat: OpenAICompat, node: JsonNode): Option[ModelConfig] =
  ## Parse a single model definition under models.json providers.<id>.models[].
  if node.isNil or node.kind != JObject:
    return none(ModelConfig)
  let id = node{"id"}.getStr("").strip()
  if id.len == 0:
    return none(ModelConfig)
  var inputs: seq[string] = @[]
  if node.hasKey("input") and node["input"].kind == JArray:
    for item in node["input"].items:
      if item.kind == JString:
        inputs.add(item.getStr())
  if inputs.len == 0:
    inputs = @["text"]

  let api = node{"api"}.getStr(if providerApi.len > 0: providerApi else: "openai-completions")
  let baseUrl = node{"baseUrl"}.getStr(providerBaseUrl)
  let sampling = if node.hasKey("samplingParams") and node["samplingParams"].kind == JObject:
    node["samplingParams"]
  else:
    nil

  some(ModelConfig(
    id: id,
    name: node{"name"}.getStr(id),
    provider: providerId,
    api: api,
    baseUrl: baseUrl,
    reasoning: node{"reasoning"}.getBool(false),
    inputs: inputs,
    contextWindow: node{"contextWindow"}.getInt(128_000),
    maxTokens: node{"maxTokens"}.getInt(16_384),
    cost: parsePricing(node{"cost"}),
    headers: parseHeadersTable(node{"headers"}),
    compat: mergeCompatNode(providerCompat, node{"compat"}),
    samplingParams: sampling,
    thinkingLevelMap: parseThinkingLevelMap(node{"thinkingLevelMap"})
  ))

proc loadModelsJson*(path: string, diagnostics: var seq[string]): Table[string, ProviderConfig] =
  ## Load custom and overridden providers from ~/.pi/agent/models.json.
  result = initTable[string, ProviderConfig]()
  let parsed = readJsonFileSafe(path, diagnostics)
  if parsed.isNone or parsed.get.kind != JObject:
    return
  let root = parsed.get
  let provObj = if root.hasKey("providers") and root["providers"].kind == JObject:
    root["providers"]
  else:
    return
  for pid, pnode in provObj.pairs:
    if pnode.kind != JObject:
      continue
    let pCompat = mergeCompatNode(defaultCompat(), pnode{"compat"})
    let pApi = pnode{"api"}.getStr("")
    let pBaseUrl = pnode{"baseUrl"}.getStr("")
    var models: seq[ModelConfig] = @[]
    if pnode.hasKey("models") and pnode["models"].kind == JArray:
      for mnode in pnode["models"].items:
        let m = parseModelEntry(pid, pApi, pBaseUrl, pCompat, mnode)
        if m.isSome:
          models.add(m.get)
    var overrides = initTable[string, JsonNode]()
    if pnode.hasKey("modelOverrides") and pnode["modelOverrides"].kind == JObject:
      for mid, onode in pnode["modelOverrides"].pairs:
        if onode.kind == JObject:
          overrides[mid] = onode
    result[pid] = ProviderConfig(
      id: pid,
      name: pnode{"name"}.getStr(pid),
      baseUrl: pBaseUrl,
      apiKeyRaw: pnode{"apiKey"}.getStr(""),
      api: pApi,
      authHeader: pnode{"authHeader"}.getBool(false),
      headers: parseHeadersTable(pnode{"headers"}),
      compat: pCompat,
      envVars: @[],
      models: models,
      modelOverrides: overrides
    )

# Context file discovery (AGENTS.override.md / AGENTS.md / CLAUDE.md)

const ContextCandidateGroups = [
  @["AGENTS.override.md"],
  @["AGENTS.md", "AGENTS.MD"],
  @["CLAUDE.md", "CLAUDE.MD"]
]

proc findContextFileInDir(dir: string): Option[ContextFile] =
  for group in ContextCandidateGroups:
    for name in group:
      let candidate = dir / name
      if fileExists(candidate):
        try:
          let text = stripUtf8Bom(readFile(candidate)).strip()
          if text.len > 0:
            return some(ContextFile(path: candidate, content: text))
        except CatchableError:
          discard
  none(ContextFile)

proc discoverContextFiles*(cwd, agentDir: string): seq[ContextFile] =
  ## Load context files from agentDir and ancestor chain down to cwd (matching Pi).
  var seenPaths = initHashSet[string]()

  let userCtx = findContextFileInDir(agentDir)
  if userCtx.isSome:
    seenPaths.incl(normalizedPath(userCtx.get.path))
    result.add(userCtx.get)

  var dirs: seq[string] = @[]
  var cur = normalizedPath(cwd)
  while cur.len > 0:
    dirs.add(cur)
    let parent = parentDir(cur)
    if parent == cur or parent.len == 0:
      break
    cur = parent

  for i in countdown(dirs.high, 0):
    let d = dirs[i]
    if normalizedPath(d) == normalizedPath(agentDir):
      continue
    let found = findContextFileInDir(d)
    if found.isSome:
      let key = normalizedPath(found.get.path)
      if key notin seenPaths:
        seenPaths.incl(key)
        result.add(found.get)

proc readPromptOverrideFile(projectDir, agentDir, fileName: string, projectTrusted: bool): string =
  if projectTrusted:
    let projFile = projectDir / fileName
    if fileExists(projFile):
      try:
        return stripUtf8Bom(readFile(projFile)).strip()
      except CatchableError:
        discard
  let userFile = agentDir / fileName
  if fileExists(userFile):
    try:
      return stripUtf8Bom(readFile(userFile)).strip()
    except CatchableError:
      discard
  ""

proc peekProjectSessionDir*(cwd: string): string =
  ## Pi reads only sessionDir from .pi/settings.json before project trust is resolved.
  let settingsPath = cwd / ProjectConfigDirName / "settings.json"
  if not fileExists(settingsPath):
    return ""
  try:
    let node = parseJson(stripUtf8Bom(readFile(settingsPath)))
    if node.kind == JObject and node.hasKey("sessionDir") and node["sessionDir"].kind == JString:
      let raw = node["sessionDir"].getStr().strip()
      if raw.len > 0:
        return resolvePathFrom(raw, cwd)
  except CatchableError:
    discard
  ""

proc loadConfigBundle*(
  cwd: string,
  agentDirOverride = "",
  projectTrusted = false,
  loadContext = true
): ConfigBundle =
  ## Load user and (if trusted) project configuration into a unified ConfigBundle.
  let resolvedCwd = normalizedPath(if cwd.len > 0: cwd else: getCurrentDir())
  let agentDir = getAgentDir(agentDirOverride)
  let projPiDir = resolvedCwd / ProjectConfigDirName

  var diagnostics: seq[string] = @[]
  var settings = defaultSettings()

  let userSettingsOpt = readJsonFileSafe(agentDir / "settings.json", diagnostics)
  if userSettingsOpt.isSome:
    mergeSettingsNode(settings, userSettingsOpt.get, agentDir, isUserScope = true)

  # Pre-trust sessionDir lookup matches Pi's documented session discovery behavior.
  let preSessionDir = peekProjectSessionDir(resolvedCwd)
  if preSessionDir.len > 0:
    settings.sessionDir = preSessionDir

  if projectTrusted:
    let projSettingsOpt = readJsonFileSafe(projPiDir / "settings.json", diagnostics)
    if projSettingsOpt.isSome:
      mergeSettingsNode(settings, projSettingsOpt.get, projPiDir, isUserScope = false)

  let auth = loadAuthFile(agentDir / "auth.json", diagnostics)
  let customProviders = loadModelsJson(agentDir / "models.json", diagnostics)
  # Load Pi's cached models-store.json separately so refreshed catalog entries replace built-in static lists cleanly
  var storeProviders = initTable[string, ProviderConfig]()
  let storeOpt = readJsonFileSafe(agentDir / "models-store.json", diagnostics)
  if storeOpt.isSome and storeOpt.get.kind == JObject:
    for pid, entry in storeOpt.get.pairs:
      if entry.kind != JObject or not entry.hasKey("models") or entry["models"].kind != JArray:
        continue
      var cached: seq[ModelConfig] = @[]
      var firstUrl = ""
      var firstApi = ""
      for mnode in entry["models"].items:
        if mnode.kind == JObject and mnode{"type"}.getStr("chat") == "chat":
          let mOpt = parseModelEntry(pid, "", "", defaultCompat(), mnode)
          if mOpt.isSome:
            if firstUrl.len == 0 and mOpt.get.baseUrl.len > 0: firstUrl = mOpt.get.baseUrl
            if firstApi.len == 0 and mOpt.get.api.len > 0: firstApi = mOpt.get.api
            cached.add(mOpt.get)
      if cached.len > 0:
        storeProviders[pid] = ProviderConfig(
          id: pid,
          name: pid,
          baseUrl: firstUrl,
          api: (if firstApi.len > 0: firstApi else: "openai-completions"),
          compat: defaultCompat(),
          models: cached,
          modelOverrides: initTable[string, JsonNode]()
        )
  let ctxFiles = if loadContext: discoverContextFiles(resolvedCwd, agentDir) else: @[]
  let customSystem = readPromptOverrideFile(projPiDir, agentDir, "SYSTEM.md", projectTrusted)
  let appendSystem = readPromptOverrideFile(projPiDir, agentDir, "APPEND_SYSTEM.md", projectTrusted)

  ConfigBundle(
    cwd: resolvedCwd,
    agentDir: agentDir,
    projectTrusted: projectTrusted,
    settings: settings,
    auth: auth,
    storeProviders: storeProviders,
    customProviders: customProviders,
    contextFiles: ctxFiles,
    customSystemPrompt: customSystem,
    appendSystemPrompt: appendSystem,
    commandCache: initTable[string, Option[string]](),
    diagnostics: diagnostics
  )
