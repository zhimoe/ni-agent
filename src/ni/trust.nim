# Project trust store (~/.pi/agent/trust.json) and core runtime security policies.

import std/[json, options, os, strutils, strtabs, tables, algorithm]
import ./[types, config]

const ProtectedProjectEntries = [
  "settings.json",
  "mcp.json",
  "extensions",
  "skills",
  "prompts",
  "themes",
  "SYSTEM.md",
  "APPEND_SYSTEM.md"
]

type
  SandboxKind* = enum
    sbNone = "none"
    sbSeatbelt = "seatbelt"       # Reserved: macOS sandbox-exec profile wrapper
    sbBubblewrap = "bubblewrap"   # Reserved: Linux bwrap namespace isolation
    sbWindowsJob = "windows_job"  # Reserved: Windows Job Object / restricted token

  SandboxMode* = enum
    sandboxOff = "off"
    sandboxReadOnly = "read-only"
    sandboxWorkspaceWrite = "workspace-write"

  CommandSandboxProc* = proc(exe: string, args: seq[string], cwd: string): tuple[exe: string, args: seq[string]] {.closure.}

  SecurityPolicy* = ref object
    cwd*: string
    agentDir*: string
    mode*: SecurityMode
    prompt*: PermissionPromptCallback
    sandboxKind*: SandboxKind
    sandboxMode*: SandboxMode
    sandboxTempDir*: string
    sandboxWrap*: CommandSandboxProc
    workspaceReadsOnly*: bool

proc canonicalKey*(p: string): string =
  ## Normalize a directory or file path for trust comparisons (case-insensitive on Windows).
  var norm = normalizedPath(expandFilename(p))
  if norm.len == 0:
    norm = normalizedPath(absolutePath(p))
  when defined(windows):
    norm = norm.replace('/', '\\').toLowerAscii()
  norm

proc safeCanonicalPath(p: string, linkDepth = 0): string =
  let absP = if p.isAbsolute: normalizedPath(p) else: normalizedPath(getCurrentDir() / p)
  var cur = absP
  var tailParts: seq[string] = @[]
  while cur.len > 0 and not dirExists(cur) and not fileExists(cur):
    if symlinkExists(cur):
      if linkDepth >= 40:
        raise newException(IOError, "Too many symlinks while resolving " & p)
      var target = resolvePathFrom(expandSymlink(cur), parentDir(cur))
      for i in countdown(tailParts.high, 0):
        target = target / tailParts[i]
      return safeCanonicalPath(target, linkDepth + 1)
    let name = extractFilename(cur)
    let parent = parentDir(cur)
    if parent == cur or name.len == 0:
      break
    tailParts.add(name)
    cur = parent

  var resolvedBase = cur
  if cur.len > 0 and (dirExists(cur) or fileExists(cur)):
    try:
      resolvedBase = normalizedPath(expandFilename(cur))
    except CatchableError:
      resolvedBase = cur

  result = resolvedBase
  for i in countdown(tailParts.high, 0):
    result = result / tailParts[i]
  result = normalizedPath(result)
  when defined(windows):
    result = result.replace('/', '\\').toLowerAscii()

proc pathsEqualPlatform*(a, b: string): bool =
  safeCanonicalPath(a) == safeCanonicalPath(b)

proc isPathWithinDir*(baseDir, candidatePath: string): bool =
  ## Check whether candidatePath is equal to or nested inside baseDir after symlink resolution.
  let baseNorm = safeCanonicalPath(baseDir)
  let candNorm = safeCanonicalPath(candidatePath)
  if candNorm == baseNorm:
    return true
  let sep = when defined(windows): '\\' else: '/'
  let prefix = if baseNorm.endsWith($sep): baseNorm else: baseNorm & $sep
  candNorm.startsWith(prefix)

proc isSensitivePath*(policy: SecurityPolicy, targetPath: string): tuple[sensitive: bool, reason: string]

proc checkFileRead*(policy: SecurityPolicy, path: string): string =
  if not policy.isNil and (policy.sandboxMode != sandboxOff or policy.workspaceReadsOnly):
    if not isPathWithinDir(policy.cwd, path) or isPathWithinDir(policy.agentDir, path):
      return "Sandbox only allows file tools to access the workspace: " & path
    if policy.workspaceReadsOnly and policy.isSensitivePath(path).sensitive:
      return "Subagents cannot read sensitive workspace files: " & path
  ""

proc processEnvironment*(policy: SecurityPolicy): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if policy.isNil or policy.sandboxMode == sandboxOff or
        key in ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "TZ"] or key.startsWith("LC_"):
      result[key] = value
  if not policy.isNil and policy.sandboxTempDir.len > 0:
    for key in ["TMPDIR", "TMP", "TEMP"]:
      result[key] = policy.sandboxTempDir

proc wrapProcess*(policy: SecurityPolicy, exe: string, args: seq[string], cwd: string):
    tuple[exe: string, args: seq[string]] =
  if not policy.isNil and not policy.sandboxWrap.isNil:
    let resolved = if exe.isAbsolute: exe elif DirSep in exe: cwd / exe else: findExe(exe)
    if resolved.len == 0:
      raise newException(IOError, "Executable not found: " & exe)
    return policy.sandboxWrap(resolved, args, cwd)
  (exe, args)

# Project trust (~/.pi/agent/trust.json)

proc hasProtectedProjectResources*(cwd: string): bool =
  ## Return true when cwd contains trust-gated .pi/* resources or ancestor .agents/skills.
  let absCwd = normalizedPath(if cwd.isAbsolute: cwd else: getCurrentDir() / cwd)
  let piDir = absCwd / ProjectConfigDirName
  for entry in ProtectedProjectEntries:
    let candidate = piDir / entry
    if fileExists(candidate) or dirExists(candidate):
      return true

  let userAgentsSkills = safeCanonicalPath(getHomeDir() / ".agents" / "skills")
  var cur = absCwd
  while cur.len > 0:
    let projAgentsSkills = cur / ".agents" / "skills"
    if dirExists(projAgentsSkills) and safeCanonicalPath(projAgentsSkills) != userAgentsSkills:
      return true
    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      break
    let parent = parentDir(cur)
    if parent == cur or parent.len == 0:
      break
    cur = parent
  false

proc readTrustStore*(agentDir: string): Table[string, Option[bool]] =
  ## Load ~/.pi/agent/trust.json mapping canonical paths to true, false, or null.
  result = initTable[string, Option[bool]]()
  let path = agentDir / "trust.json"
  if not fileExists(path):
    return
  try:
    let node = parseJson(stripUtf8Bom(readFile(path)))
    if node.kind != JObject:
      return
    for k, v in node.pairs:
      case v.kind
      of JBool:
        result[k] = some(v.getBool())
      of JNull:
        result[k] = none(bool)
      else:
        discard
  except CatchableError:
    discard

proc saveProjectTrust*(agentDir, dirPath: string, decision: Option[bool]) =
  ## Persist a project trust decision (true, false, or null to clear) into trust.json.
  createDir(agentDir)
  let path = agentDir / "trust.json"
  var store = readTrustStore(agentDir)
  let normTarget = safeCanonicalPath(dirPath)
  var matchedKey = ""
  for k in store.keys:
    if safeCanonicalPath(k) == normTarget:
      matchedKey = k
      break
  let targetKey = if matchedKey.len > 0: matchedKey else: normalizedPath(if dirPath.isAbsolute: dirPath else: getCurrentDir() / dirPath)
  store[targetKey] = decision

  var sortedKeys: seq[string] = @[]
  for k in store.keys:
    sortedKeys.add(k)
  sortedKeys.sort()

  var outObj = newJObject()
  for k in sortedKeys:
    let v = store[k]
    if v.isSome:
      outObj[k] = %v.get
    else:
      outObj[k] = newJNull()
  writeFile(path, outObj.pretty() & "\n")

proc lookupSavedTrust*(agentDir, cwd: string): Option[bool] =
  ## Find nearest saved boolean trust decision for cwd or any parent directory.
  let store = readTrustStore(agentDir)
  if store.len == 0:
    return none(bool)
  var cur = normalizedPath(if cwd.isAbsolute: cwd else: getCurrentDir() / cwd)
  while cur.len > 0:
    let curCanon = safeCanonicalPath(cur)
    for k, val in store.pairs:
      if val.isSome and safeCanonicalPath(k) == curCanon:
        return val
    let parent = parentDir(cur)
    if parent == cur or parent.len == 0:
      break
    cur = parent
  none(bool)

proc resolveProjectTrust*(
  cwd, agentDir: string,
  defaultMode: ProjectTrustMode,
  cliOverride = none(bool),
  interactivePrompt: proc(projectPath: string): Option[ tuple[trusted: bool, persist: bool] ] = nil
): bool =
  ## Resolve project trust following Pi's precedence: CLI flag -> trust.json -> defaultProjectTrust / prompt.
  if cliOverride.isSome:
    return cliOverride.get

  if not hasProtectedProjectResources(cwd):
    return false

  let saved = lookupSavedTrust(agentDir, cwd)
  if saved.isSome:
    return saved.get

  case defaultMode
  of ptmAlways:
    return true
  of ptmNever:
    return false
  of ptmAsk:
    if interactivePrompt.isNil:
      return false
    let answer = interactivePrompt(cwd)
    if answer.isNone:
      return false
    if answer.get.persist:
      saveProjectTrust(agentDir, cwd, some(answer.get.trusted))
    return answer.get.trusted

# Runtime SecurityPolicy (file boundaries, sensitive credentials, destructive commands)

proc newSecurityPolicy*(
  cwd, agentDir: string,
  mode = smBalanced,
  prompt: PermissionPromptCallback = nil
): SecurityPolicy =
  SecurityPolicy(
    cwd: normalizedPath(if cwd.isAbsolute: cwd else: getCurrentDir() / cwd),
    agentDir: agentDir,
    mode: mode,
    prompt: prompt,
    sandboxKind: sbNone,
    sandboxWrap: nil
  )

proc isSensitivePath*(policy: SecurityPolicy, targetPath: string): tuple[sensitive: bool, reason: string] =
  ## Detect credential files, SSH keys, dotenv secrets, and git hook executables.
  let canon = safeCanonicalPath(targetPath)
  let base = extractFilename(canon).toLowerAscii()
  let posixCanon = canon.replace('\\', '/').toLowerAscii()

  if isPathWithinDir(policy.agentDir, targetPath) and base in ["auth.json", "mcp-auth.json", "trust.json"]:
    return (true, "Modifies protected agent credential/trust store (" & base & ")")
  if "/.ssh/" in posixCanon or base in ["id_rsa", "id_ed25519", "authorized_keys"]:
    return (true, "Touches SSH key or configuration (" & base & ")")
  if base == ".env" or base.startsWith(".env."):
    if not base.endsWith(".example") and not base.endsWith(".sample") and not base.endsWith(".template"):
      return (true, "Touches environment secret file (" & base & ")")
  if "/.git/hooks/" in posixCanon or posixCanon.endsWith("/.git/config"):
    return (true, "Modifies executable Git hook or repository config")
  (false, "")

proc askOrDeny(policy: SecurityPolicy, action: PermissionAction, target, reason: string): string =
  if policy.mode == smPermissive and action != paSensitiveFile:
    return ""
  if not policy.prompt.isNil:
    let dec = policy.prompt(action, target, reason)
    if dec == pdAllow:
      return ""
    return "Blocked by user security prompt: " & reason
  "Blocked by security policy (" & $policy.mode & " mode, non-interactive): " & reason

proc checkFileMutation*(policy: SecurityPolicy, targetPath: string, isEdit: bool): string =
  ## Return "" when writing/editing targetPath is allowed, or an error description when denied.
  if policy.isNil:
    return ""
  if policy.sandboxMode == sandboxReadOnly or policy.workspaceReadsOnly:
    return "Read-only sandbox prohibits editing workspace files"
  let sandboxDenial = policy.checkFileRead(targetPath)
  if sandboxDenial.len > 0:
    return sandboxDenial
  let (sens, sensReason) = policy.isSensitivePath(targetPath)
  if sens:
    return policy.askOrDeny(paSensitiveFile, targetPath, sensReason)

  if not isPathWithinDir(policy.cwd, targetPath):
    return policy.askOrDeny(
      paOutsideWorkspace,
      targetPath,
      "Target path is outside workspace root (" & policy.cwd & ")"
    )

  if policy.mode == smStrict:
    let act = if isEdit: paFileEdit else: paFileWrite
    return policy.askOrDeny(act, targetPath, "Strict mode requires confirmation for file modifications")

  ""

proc classifyDangerousCommand*(cmd: string): tuple[dangerous: bool, reason: string] =
  ## Identify destructive filesystem/git commands or credential-store exfiltration.
  let lower = cmd.toLowerAscii().strip()
  let patterns = [
    ("rm -rf /", "Recursive root/system deletion (`rm -rf /`)"),
    ("rm -rf ~", "Recursive home directory deletion (`rm -rf ~`)"),
    ("rm -rf $home", "Recursive home directory deletion"),
    ("git reset --hard", "Destructive `git reset --hard` discards uncommitted changes"),
    ("git clean -fd", "Destructive `git clean -fd` deletes untracked files"),
    ("git checkout -- .", "Destructive `git checkout` discards working tree edits"),
    ("git push --force", "Force-push rewrites remote repository history"),
    ("git push -f", "Force-push rewrites remote repository history"),
    ("mkfs.", "Filesystem formatting command (`mkfs`)"),
    ("dd if=", "Raw block device write (`dd`)"),
    ("format c:", "Disk formatting command"),
    ("remove-item -recurse -force c:\\", "Recursive root deletion in PowerShell"),
    ("auth.json", "Command accesses stored API credentials (`auth.json`)"),
    ("mcp-auth.json", "Command accesses stored MCP OAuth tokens (`mcp-auth.json`)"),
    ("/.ssh/id_", "Command accesses private SSH keys")
  ]
  for (pat, why) in patterns:
    if pat in lower:
      return (true, why)
  (false, "")

proc checkShellExecution*(policy: SecurityPolicy, command: string): string =
  ## Return "" when executing shell command is allowed, or an error description when denied.
  if policy.isNil:
    return ""
  let (isDang, why) = classifyDangerousCommand(command)
  if isDang:
    return policy.askOrDeny(paShellCommand, command, why)
  if policy.mode == smStrict:
    return policy.askOrDeny(paShellCommand, command, "Strict mode requires confirmation for shell execution")
  ""
