# Agent Skills specification (SKILL.md) loader, validator, prompt XML formatter, and /skill:<name> expander.

import std/[os, strutils, tables, sets, options, algorithm]
import ./config

const
  MaxSkillNameLen* = 64
  MaxSkillDescLen* = 1024

type
  Skill* = object
    name*: string
    description*: string
    filePath*: string
    baseDir*: string
    source*: string
    disableModelInvocation*: bool
    allowedTools*: seq[string]
    body*: string

  PromptTemplate* = object
    name*: string
    description*: string
    argumentHint*: string
    content*: string
    filePath*: string
    source*: string

proc unquoteYamlScalar(raw: string): string =
  let s = raw.strip()
  if s.len >= 2 and ((s.startsWith("\"") and s.endsWith("\"")) or (s.startsWith("'") and s.endsWith("'"))):
    return s[1 ..< s.high]
  s

proc parseSkillFrontmatter*(markdown: string): tuple[hasFrontmatter: bool, fields: Table[string, string], body: string] =
  ## Extract YAML frontmatter key-value pairs (including folded/indented continuation lines) and markdown body.
  let clean = stripUtf8Bom(markdown).replace("\r\n", "\n")
  if not clean.startsWith("---\n") and clean != "---":
    return (false, initTable[string, string](), clean)

  let lines = clean.split('\n')
  var endIdx = -1
  for i in 1 ..< lines.len:
    if lines[i].strip() == "---":
      endIdx = i
      break
  if endIdx < 0:
    return (false, initTable[string, string](), clean)

  var fields = initTable[string, string]()
  var currentKey = ""
  var blockMode = false

  for i in 1 ..< endIdx:
    let line = lines[i]
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let isIndented = line.len > 0 and (line[0] == ' ' or line[0] == '\t')
    if isIndented and currentKey.len > 0:
      if blockMode:
        if fields[currentKey].len > 0:
          fields[currentKey].add(" " & trimmed)
        else:
          fields[currentKey] = trimmed
      continue

    let colon = line.find(':')
    if colon <= 0:
      continue
    let key = line[0 ..< colon].strip().toLowerAscii()
    let valPart = line[colon + 1 .. ^1].strip()
    currentKey = key
    if valPart in ["|", ">", "|-", ">-"]:
      blockMode = true
      fields[key] = ""
    else:
      blockMode = false
      fields[key] = unquoteYamlScalar(valPart)

  let body = if endIdx + 1 < lines.len:
    lines[endIdx + 1 .. ^1].join("\n").strip()
  else:
    ""
  (true, fields, body)

proc validateSkillName*(name: string): seq[string] =
  ## Validate skill name against the Agent Skills specification.
  if name.len == 0:
    result.add("name is empty")
    return
  if name.len > MaxSkillNameLen:
    result.add("name exceeds " & $MaxSkillNameLen & " characters")
  for ch in name:
    if ch notin {'a'..'z', '0'..'9', '-'}:
      result.add("name must use lowercase letters, digits, and hyphens only")
      break
  if name.startsWith("-") or name.endsWith("-"):
    result.add("name must not start or end with a hyphen")
  if "--" in name:
    result.add("name must not contain consecutive hyphens")

proc parseSkillFile*(filePath: string, source: string, diagnostics: var seq[string]): Option[Skill] =
  ## Parse and validate one SKILL.md file.
  if not fileExists(filePath):
    return none(Skill)
  var raw = ""
  try:
    raw = readFile(filePath)
  except CatchableError as e:
    diagnostics.add("Failed to read skill " & filePath & ": " & e.msg)
    return none(Skill)

  let (hasFm, fields, body) = parseSkillFrontmatter(raw)
  if not hasFm:
    diagnostics.add("Skipping skill without frontmatter: " & filePath)
    return none(Skill)

  let parentName = extractFilename(parentDir(filePath)).toLowerAscii()
  let name = fields.getOrDefault("name", parentName).strip()
  let desc = fields.getOrDefault("description", "").strip()
  if desc.len == 0:
    diagnostics.add("Skipping skill without description: " & filePath)
    return none(Skill)

  let nameWarnings = validateSkillName(name)
  for w in nameWarnings:
    diagnostics.add("Skill '" & name & "' (" & filePath & "): " & w)
  if desc.len > MaxSkillDescLen:
    diagnostics.add("Skill '" & name & "' description exceeds " & $MaxSkillDescLen & " characters")

  let disableAuto = fields.getOrDefault("disable-model-invocation", "false").toLowerAscii() in ["true", "yes", "1"]
  var allowed: seq[string] = @[]
  let rawAllowed = fields.getOrDefault("allowed-tools", "")
  if rawAllowed.len > 0:
    for item in rawAllowed.replace("[", "").replace("]", "").split({',', ' '}):
      let cleanItem = unquoteYamlScalar(item)
      if cleanItem.len > 0:
        allowed.add(cleanItem)

  some(Skill(
    name: name,
    description: desc,
    filePath: normalizedPath(absolutePath(filePath)),
    baseDir: normalizedPath(absolutePath(parentDir(filePath))),
    source: source,
    disableModelInvocation: disableAuto,
    allowedTools: allowed,
    body: body
  ))

proc scanSkillDirectory(rootDir, source: string, outSkills: var seq[Skill], diagnostics: var seq[string]) =
  if not dirExists(rootDir):
    return
  let directSkill = rootDir / "SKILL.md"
  if fileExists(directSkill):
    let parsed = parseSkillFile(directSkill, source, diagnostics)
    if parsed.isSome:
      outSkills.add(parsed.get)

  var subdirs: seq[string] = @[]
  try:
    for kind, p in walkDir(rootDir):
      let base = extractFilename(p)
      if base.startsWith(".") or base == "node_modules":
        continue
      if kind in {pcDir, pcLinkToDir}:
        subdirs.add(p)
  except CatchableError:
    return

  subdirs.sort()
  for sub in subdirs:
    let candidate = sub / "SKILL.md"
    if fileExists(candidate):
      let parsed = parseSkillFile(candidate, source, diagnostics)
      if parsed.isSome:
        outSkills.add(parsed.get)
    else:
      scanSkillDirectory(sub, source, outSkills, diagnostics)

proc discoverSkills*(
  cwd, agentDir: string,
  extraSkillPaths: openArray[string] = [],
  projectTrusted = false,
  includeDefaults = true,
  userAgentsSkillsDir = ""
): tuple[skills: seq[Skill], diagnostics: seq[string]] =
  ## Discover skills across user (~/.pi/agent/skills, ~/.agents/skills), trusted project (.pi/skills, .agents/skills), and CLI paths.
  var diagnostics: seq[string] = @[]
  var candidates: seq[Skill] = @[]
  let effectiveHomeAgents = if userAgentsSkillsDir.len > 0: userAgentsSkillsDir else: (getHomeDir() / ".agents" / "skills")

  if includeDefaults:
    scanSkillDirectory(agentDir / "skills", "user", candidates, diagnostics)
    scanSkillDirectory(effectiveHomeAgents, "user-agents", candidates, diagnostics)

    if projectTrusted:
      let absCwd = normalizedPath(if cwd.isAbsolute: cwd else: getCurrentDir() / cwd)
      scanSkillDirectory(absCwd / ProjectConfigDirName / "skills", "project", candidates, diagnostics)

      # Walk ancestor .agents/skills up to git repo root (excluding ~/.agents/skills already scanned)
      let homeAgents = normalizedPath(effectiveHomeAgents)
      var cur = absCwd
      var ancestorDirs: seq[string] = @[]
      while cur.len > 0:
        let dirCandidate = normalizedPath(cur / ".agents" / "skills")
        if dirCandidate != homeAgents and dirExists(dirCandidate):
          ancestorDirs.add(dirCandidate)
        if dirExists(cur / ".git") or fileExists(cur / ".git"):
          break
        let parent = parentDir(cur)
        if parent == cur or parent.len == 0:
          break
        cur = parent
      for d in ancestorDirs:
        scanSkillDirectory(d, "project-agents", candidates, diagnostics)

  for rawPath in extraSkillPaths:
    let resolved = resolvePathFrom(rawPath, cwd)
    if dirExists(resolved):
      scanSkillDirectory(resolved, "path", candidates, diagnostics)
    elif fileExists(resolved) and resolved.toLowerAscii().endsWith(".md"):
      let s = parseSkillFile(resolved, "path", diagnostics)
      if s.isSome:
        candidates.add(s.get)
    else:
      diagnostics.add("Configured skill path not found: " & resolved)

  var seenNames = initTable[string, string]()
  var seenRealPaths = initHashSet[string]()
  var finalSkills: seq[Skill] = @[]

  for sk in candidates:
    var realKey = sk.filePath
    try:
      realKey = expandFilename(sk.filePath)
    except CatchableError:
      discard
    if realKey in seenRealPaths:
      continue
    if seenNames.hasKey(sk.name):
      diagnostics.add("Skill name collision '" & sk.name & "': keeping " & seenNames[sk.name] & ", ignoring " & sk.filePath)
      continue
    seenNames[sk.name] = sk.filePath
    seenRealPaths.incl(realKey)
    finalSkills.add(sk)

  (finalSkills, diagnostics)

proc escapeXmlText(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(ch)

proc formatSkillsForPrompt*(skills: openArray[Skill], readerTool = "read"): string =
  ## Render Pi-compatible <available_skills> XML block for model-invocable skills.
  var visible: seq[Skill] = @[]
  for sk in skills:
    if not sk.disableModelInvocation:
      visible.add(sk)
  if visible.len == 0:
    return ""

  var lines: seq[string] = @[
    "The following skills provide specialized instructions for specific tasks.",
    (if readerTool == "read":
      "Use the read tool to load a skill's file when the task matches its description."
    elif readerTool == "bash":
      "Use bash to load a skill's file when the task matches its description."
    else:
      "Load a skill's file when the task matches its description."),
    "Resolve relative paths against the skill's directory (parent of SKILL.md). Use absolute paths in tool calls.",
    "",
    "<available_skills>"
  ]
  for sk in visible:
    lines.add("  <skill>")
    lines.add("    <name>" & escapeXmlText(sk.name) & "</name>")
    lines.add("    <description>" & escapeXmlText(sk.description) & "</description>")
    lines.add("    <location>" & escapeXmlText(sk.filePath) & "</location>")
    lines.add("  </skill>")
  lines.add("</available_skills>")
  lines.join("\n")

proc expandSkillCommand*(input: string, skills: openArray[Skill]): Option[string] =
  ## Expand `/skill:<name> [args]` into an explicit skill-invocation user prompt.
  let trimmed = input.strip()
  if not trimmed.startsWith("/skill:"):
    return none(string)
  let rest = trimmed[7 .. ^1].strip()
  if rest.len == 0:
    return none(string)
  let spaceIdx = rest.find({' ', '\t', '\n'})
  let skillName = if spaceIdx < 0: rest else: rest[0 ..< spaceIdx]
  let userArgs = if spaceIdx < 0: "" else: rest[spaceIdx + 1 .. ^1].strip()

  for sk in skills:
    if sk.name == skillName:
      var expanded = "<skill_instructions name=\"" & escapeXmlText(sk.name) &
                     "\" dir=\"" & escapeXmlText(sk.baseDir) & "\">\n" &
                     sk.body & "\n</skill_instructions>"
      if userArgs.len > 0:
        expanded.add("\n\nUser request:\n" & userArgs)
      else:
        expanded.add("\n\nFollow the skill instructions above for the current workspace.")
      return some(expanded)
  none(string)

# Pi Prompt Templates (`~/.pi/agent/prompts/*.md` and `.pi/prompts/*.md`)

proc parseTemplateCommandArgs*(argsString: string): seq[string] =
  ## Parse slash-command arguments respecting bash-style single and double quotes (matching Pi's parseCommandArgs).
  var current = ""
  var hasToken = false
  var inQuote = '\0'
  var quoteStart = 0
  var i = 0

  while i < argsString.len:
    let ch = argsString[i]
    if inQuote != '\0':
      if ch == '\\' and i + 1 < argsString.len and argsString[i + 1] == inQuote:
        current.add(inQuote)
        inc i
      elif ch == inQuote:
        inQuote = '\0'
      else:
        current.add(ch)
    elif ch in {'"', '\''} and not hasToken:
      inQuote = ch
      quoteStart = i
      hasToken = true
    elif ch in {' ', '\t', '\r', '\n'}:
      if hasToken:
        result.add(current)
        current = ""
        hasToken = false
    else:
      current.add(ch)
      hasToken = true

    if inQuote != '\0' and i == argsString.high:
      # Unclosed quote: treat opening quote as literal character and re-scan remaining text
      inQuote = '\0'
      current = $argsString[quoteStart]
      i = quoteStart
    inc i

  if hasToken:
    result.add(current)

proc substituteTemplateArgs*(content: string, args: openArray[string]): string =
  ## Substitute `$1`, `$@`, `$ARGUMENTS`, `${N:-default}`, `${@:-default}`, `${@:N}`, `${@:N:L}` in a single pass.
  let allArgs = args.join(" ")
  result = newStringOfCap(content.len + allArgs.len)
  var i = 0

  while i < content.len:
    if content[i] != '$' or i + 1 >= content.len:
      result.add(content[i])
      inc i
      continue

    # Braced forms: `${...}`
    if content[i + 1] == '{':
      let closeBrace = content.find('}', i + 2)
      if closeBrace > i + 2:
        let expr = content[i + 2 ..< closeBrace]
        # 1) `${target:-default}`
        let defSep = expr.find(":-")
        if defSep > 0:
          let target = expr[0 ..< defSep]
          let defVal = expr[defSep + 2 .. ^1]
          if target == "@" or target == "ARGUMENTS":
            result.add(if allArgs.len > 0: allArgs else: defVal)
            i = closeBrace + 1
            continue
          elif target.allCharsInSet({'0'..'9'}):
            let idx = (try: parseInt(target) except ValueError: 0) - 1
            let val = if idx >= 0 and idx < args.len: args[idx] else: ""
            result.add(if val.len > 0: val else: defVal)
            i = closeBrace + 1
            continue

        # 2) `${@:N}` or `${@:N:L}`
        if expr.startsWith("@:"):
          let sliceSpec = expr[2 .. ^1]
          let parts = sliceSpec.split(':')
          if parts.len in [1, 2] and parts[0].len > 0 and parts[0].allCharsInSet({'0'..'9'}):
            let startIdx = max(0, (try: parseInt(parts[0]) except ValueError: 1) - 1)
            if parts.len == 1:
              if startIdx < args.len:
                result.add(args[startIdx .. ^1].join(" "))
              i = closeBrace + 1
              continue
            elif parts[1].len > 0 and parts[1].allCharsInSet({'0'..'9'}):
              let sliceLen = max(0, (try: parseInt(parts[1]) except ValueError: 0))
              if startIdx < args.len and sliceLen > 0:
                let endExcl = min(args.len, startIdx + sliceLen)
                result.add(args[startIdx ..< endExcl].join(" "))
              i = closeBrace + 1
              continue

    # Simple forms: `$ARGUMENTS`, `$@`, `$1`, `$2`, ...
    if content.continuesWith("$ARGUMENTS", i) and
       (i + 10 >= content.len or content[i + 10] notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      result.add(allArgs)
      i += 10
      continue

    if content[i + 1] == '@':
      result.add(allArgs)
      i += 2
      continue

    if content[i + 1] in {'0'..'9'}:
      var j = i + 1
      while j < content.len and content[j] in {'0'..'9'}:
        inc j
      let num = try: parseInt(content[i + 1 ..< j]) except ValueError: 0
      if num >= 1 and num <= args.len:
        result.add(args[num - 1])
      i = j
      continue

    result.add('$')
    inc i

proc parsePromptTemplateFile*(filePath, source: string, diagnostics: var seq[string]): Option[PromptTemplate] =
  ## Load a single `.md` prompt template file with optional YAML frontmatter (`description`, `argument-hint`).
  if not fileExists(filePath):
    return none(PromptTemplate)
  var raw = ""
  try:
    raw = readFile(filePath)
  except CatchableError as e:
    diagnostics.add("Failed to read prompt template " & filePath & ": " & e.msg)
    return none(PromptTemplate)

  let (hasFm, fields, fmBody) = parseSkillFrontmatter(raw)
  let body = if hasFm: fmBody else: stripUtf8Bom(raw).replace("\r\n", "\n").strip()
  let baseName = splitFile(filePath).name.strip()
  if baseName.len == 0:
    return none(PromptTemplate)

  var desc = if hasFm: fields.getOrDefault("description", "").strip() else: ""
  if desc.len == 0:
    for line in body.splitLines():
      let t = line.strip()
      if t.len > 0:
        desc = if t.len > 60: t[0 ..< 60] & "..." else: t
        break
  let argHint = if hasFm: fields.getOrDefault("argument-hint", "").strip() else: ""

  some(PromptTemplate(
    name: baseName,
    description: desc,
    argumentHint: argHint,
    content: body,
    filePath: normalizedPath(absolutePath(filePath)),
    source: source
  ))

proc scanPromptTemplatesDir(dirPath, source: string, outTemplates: var seq[PromptTemplate], diagnostics: var seq[string]) =
  if not dirExists(dirPath):
    return
  var files: seq[string] = @[]
  try:
    for kind, p in walkDir(dirPath):
      if kind in {pcFile, pcLinkToFile} and p.toLowerAscii().endsWith(".md"):
        files.add(p)
  except CatchableError:
    return
  files.sort()
  for f in files:
    let tpl = parsePromptTemplateFile(f, source, diagnostics)
    if tpl.isSome:
      outTemplates.add(tpl.get)

proc discoverPromptTemplates*(
  cwd, agentDir: string,
  extraPaths: openArray[string] = [],
  projectTrusted = false,
  includeDefaults = true
): tuple[templates: seq[PromptTemplate], diagnostics: seq[string]] =
  ## Discover `.md` prompt templates from `~/.pi/agent/prompts`, trusted `.pi/prompts`, and configured paths.
  var diagnostics: seq[string] = @[]
  var candidates: seq[PromptTemplate] = @[]

  if includeDefaults:
    scanPromptTemplatesDir(agentDir / "prompts", "user", candidates, diagnostics)
    if projectTrusted:
      let absCwd = normalizedPath(if cwd.isAbsolute: cwd else: getCurrentDir() / cwd)
      scanPromptTemplatesDir(absCwd / ProjectConfigDirName / "prompts", "project", candidates, diagnostics)

  for rawP in extraPaths:
    let resolved = resolvePathFrom(rawP, cwd)
    if dirExists(resolved):
      scanPromptTemplatesDir(resolved, "path", candidates, diagnostics)
    elif fileExists(resolved) and resolved.toLowerAscii().endsWith(".md"):
      let t = parsePromptTemplateFile(resolved, "path", diagnostics)
      if t.isSome:
        candidates.add(t.get)
    else:
      diagnostics.add("Configured prompt template path not found: " & resolved)

  var byName = initOrderedTable[string, PromptTemplate]()
  for tpl in candidates:
    # Later scopes (project / CLI) override user templates of the same name
    byName[tpl.name] = tpl

  var finalList: seq[PromptTemplate] = @[]
  for _, tpl in byName.pairs:
    finalList.add(tpl)
  (finalList, diagnostics)

proc expandPromptTemplateCommand*(input: string, templates: openArray[PromptTemplate]): Option[string] =
  ## If `input` starts with `/<templateName>` matching a loaded PromptTemplate, expand its arguments and return the body.
  let trimmed = input.strip()
  if not trimmed.startsWith("/") or trimmed.startsWith("/skill:"):
    return none(string)
  let spIdx = trimmed.find({' ', '\t', '\n'})
  let cmdName = if spIdx < 0: trimmed[1 .. ^1] else: trimmed[1 ..< spIdx]
  if cmdName.len == 0:
    return none(string)
  let rawArgs = if spIdx < 0: "" else: trimmed[spIdx + 1 .. ^1].strip()

  for tpl in templates:
    if tpl.name == cmdName:
      let parsedArgs = parseTemplateCommandArgs(rawArgs)
      return some(substituteTemplateArgs(tpl.content, parsedArgs))
  none(string)
