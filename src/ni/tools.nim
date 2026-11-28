# Built-in coding agent tools (read, write, edit, bash, powershell, grep, find, ls, ask_question, tool_search).

import std/[algorithm, base64, json, monotimes, os, osproc, sets, streams, strtabs, strutils, tables, times]
when defined(windows):
  import std/winlean
else:
  import std/posix
import ./[types, config, trust, provider, utf8]

const
  DefaultMaxLines* = 2000
  DefaultMaxBytes* = 50 * 1024
  GrepMaxLineChars* = 500

type
  ToolContext* = ref object
    cwd*: string
    settings*: NiSettings
    security*: SecurityPolicy
    askQuestion*: AskQuestionCallback
    abort*: AbortFlag
    sessionId*: string
    modelId*: string
    onOutput*: proc(delta: string) {.closure.}
    subagentTool*: proc(name: string, args: JsonNode): ToolOutput {.closure.}

  ToolExecuteProc* = proc(args: JsonNode, ctx: ToolContext): ToolOutput {.closure.}

  AgentTool* = object
    name*: string
    description*: string
    snippet*: string
    guidelines*: seq[string]
    parameters*: JsonNode
    exposure*: ToolExposure
    namespace*: string
    execute*: ToolExecuteProc

  ToolRegistry* = ref object
    tools*: OrderedTable[string, AgentTool]
    activeNames*: HashSet[string]
    discoverableNames*: HashSet[string]

  EditBlock = object
    oldText: string
    newText: string

  MatchedSpan = object
    startIdx: int
    endIdx: int
    newText: string

# Cross-platform process helpers (timeout, non-blocking drain, process-tree termination)

when defined(windows):
  proc peekNamedPipeWin(
    hNamedPipe: Handle,
    lpBuffer: pointer,
    nBufferSize: int32,
    lpBytesRead: ptr int32,
    lpTotalBytesAvail: ptr int32,
    lpBytesLeftThisMessage: ptr int32
  ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}

proc killProcessTree*(p: Process) =
  ## Terminate a child process and its descendants across POSIX and Windows.
  if p.isNil:
    return
  let pid = p.processID()
  when defined(windows):
    if pid > 0 and p.running():
      try:
        discard execCmdEx("taskkill /pid " & $pid & " /T /F", options = {poUsePath, poDaemon})
      except CatchableError:
        discard
    try:
      p.terminate()
    except CatchableError:
      discard
  else:
    if pid > 0:
      # Try process group first when available, then direct PID.
      discard kill(Pid(-pid), SIGTERM)
      discard kill(Pid(pid), SIGTERM)
      sleep(80)
      if p.running():
        discard kill(Pid(-pid), SIGKILL)
        discard kill(Pid(pid), SIGKILL)

proc readAvailableFd*(fd: FileHandle): tuple[data: string, eof: bool] =
  when defined(windows):
    var avail: int32 = 0
    if peekNamedPipeWin(Handle(fd), nil, 0, nil, addr avail, nil) == 0:
      return ("", true)
    if avail <= 0:
      return ("", false)
    let toRead = min(avail.int, 16384)
    var buf = newString(toRead)
    var bytesRead: int32 = 0
    if readFile(Handle(fd), addr buf[0], toRead.int32, addr bytesRead, nil) == 0 or bytesRead <= 0:
      return ("", true)
    buf.setLen(bytesRead.int)
    return (buf, false)
  else:
    var pfd: TPollfd
    pfd.fd = cint(fd)
    pfd.events = cshort(POLLIN or POLLHUP)
    pfd.revents = 0
    let rc = poll(addr pfd, 1, 0)
    if rc <= 0:
      return ("", false)
    if (pfd.revents and POLLIN) != 0:
      var buf = newString(16384)
      let n = posix.read(cint(fd), addr buf[0], buf.len)
      if n > 0:
        buf.setLen(n)
        return (buf, false)
      elif n == 0:
        return ("", true)
    if (pfd.revents and POLLHUP) != 0:
      return ("", true)
    ("", false)

proc runProcessCapture*(
  exe: string,
  args: openArray[string],
  cwd: string,
  env: StringTableRef,
  timeoutSec: float,
  abort: AbortFlag,
  stdinPayload = "",
  onOutput: proc(delta: string) {.closure.} = nil
): tuple[output: string, exitCode: int, timedOut: bool, aborted: bool, wallSec: float] =
  ## Spawn a process without shell injection, stream combined stdout+stderr with deadline & abort support.
  let startMono = getMonoTime()
  let opts: set[ProcessOption] =
    when defined(windows):
      {poUsePath, poStdErrToStdOut, poInteractive, poDaemon}
    else:
      {poUsePath, poStdErrToStdOut, poDaemon}

  let p = startProcess(exe, workingDir = cwd, args = args, env = env, options = opts)
  defer:
    try: p.close() except CatchableError: discard

  if stdinPayload.len > 0:
    try:
      p.inputStream.write(stdinPayload)
      p.inputStream.flush()
    except CatchableError:
      discard
  try:
    p.inputStream.close()
  except CatchableError:
    discard

  let outFd = p.outputHandle()
  var output = newStringOfCap(4096)
  var pending = ""
  proc addOutput(chunk: string) =
    output.add(chunk)
    if not onOutput.isNil:
      pending.add(chunk)
      let endAt = completeUtf8Prefix(pending)
      if endAt > 0:
        onOutput(pending[0 ..< endAt])
        pending = pending[endAt .. ^1]
  var eof = false
  var timedOut = false
  var wasAborted = false
  let hasDeadline = timeoutSec > 0.0

  while not eof:
    if abort.pollAbort():
      wasAborted = true
      killProcessTree(p)
      break

    let elapsedSec = (getMonoTime() - startMono).inMilliseconds.float / 1000.0
    if hasDeadline and elapsedSec >= timeoutSec:
      timedOut = true
      killProcessTree(p)
      break

    let (chunk, hitEof) = readAvailableFd(outFd)
    if chunk.len > 0:
      addOutput(chunk)
    elif hitEof:
      eof = true
    elif not p.running():
      # Drain any final bytes queued right as the process exited
      let (tailChunk, _) = readAvailableFd(outFd)
      if tailChunk.len > 0:
        addOutput(tailChunk)
      else:
        eof = true
    else:
      when defined(windows):
        sleep(15)
      else:
        var pfd: TPollfd
        pfd.fd = cint(outFd)
        pfd.events = cshort(POLLIN or POLLHUP)
        pfd.revents = 0
        discard poll(addr pfd, 1, 25)

  var code = 1
  if not timedOut and not wasAborted:
    code = p.waitForExit()
  else:
    discard p.peekExitCode()
  if pending.len > 0:
    onOutput(pending)

  let wall = (getMonoTime() - startMono).inMilliseconds.float / 1000.0
  (output, code, timedOut, wasAborted, wall)

# Truncation & temp-file spill helpers

proc truncateHead*(text: string, maxLines = DefaultMaxLines, maxBytes = DefaultMaxBytes): tuple[
  content: string, truncated: bool, shownLines: int, totalLines: int, totalBytes: int
] =
  ## Keep leading lines up to maxLines and maxBytes, matching Pi's read/grep/find/ls truncation.
  let totalBytes = text.len
  if totalBytes == 0:
    return ("", false, 0, 0, 0)
  let lines = text.split('\n')
  let totalLines = lines.len
  if totalLines <= maxLines and totalBytes <= maxBytes:
    return (text, false, totalLines, totalLines, totalBytes)

  var outLines: seq[string] = @[]
  var usedBytes = 0
  for i, line in lines.pairs:
    if i >= maxLines:
      break
    let addBytes = line.len + (if outLines.len > 0: 1 else: 0)
    if usedBytes + addBytes > maxBytes:
      if outLines.len == 0:
        let sliceLen = utf8BoundaryBefore(line, maxBytes)
        outLines.add(line[0 ..< sliceLen])
      break
    outLines.add(line)
    usedBytes += addBytes

  (outLines.join("\n"), true, outLines.len, totalLines, totalBytes)

proc saveFullOutputTemp*(prefix, content: string): string =
  ## Save large command/MCP output to a temporary file and return its path.
  try:
    let dir = getTempDir() / "ni-output"
    createDir(dir)
    let path = dir / (prefix & "-" & $nowUnixMs() & ".log")
    writeFile(path, content)
    return path
  except CatchableError:
    return ""

proc errorOutput(msg: string): ToolOutput =
  ToolOutput(content: @[textBlock(msg)], isError: true)

proc okTextOutput(msg: string, diff = "", fullPath = ""): ToolOutput =
  ToolOutput(content: @[textBlock(msg)], isError: false, diff: diff, fullOutputPath: fullPath)

# Glob matcher (pure Nim, zero external PCRE/minimatch dependencies)

proc globMatchHere(pat, str: string, pi, si: int, caseInsensitive: bool): bool =
  var p = pi
  var s = si
  while p < pat.len:
    if pat[p] == '*':
      if p + 1 < pat.len and pat[p + 1] == '*':
        var nextP = p + 2
        if nextP < pat.len and pat[nextP] == '/':
          inc nextP
        if nextP >= pat.len:
          return true
        var k = s
        while k <= str.len:
          if globMatchHere(pat, str, nextP, k, caseInsensitive):
            return true
          inc k
        return false
      else:
        inc p
        var k = s
        while k <= str.len:
          if globMatchHere(pat, str, p, k, caseInsensitive):
            return true
          if k < str.len and str[k] == '/':
            break
          inc k
        return false
    elif pat[p] == '?':
      if s >= str.len or str[s] == '/':
        return false
      inc p
      inc s
    else:
      if s >= str.len:
        return false
      let pc = if caseInsensitive: pat[p].toLowerAscii() else: pat[p]
      let sc = if caseInsensitive: str[s].toLowerAscii() else: str[s]
      if pc != sc:
        return false
      inc p
      inc s
  s == str.len

proc matchGlob*(pattern, relPosixPath: string): bool =
  ## Match a relative POSIX path against a glob pattern (`*`, `?`, `**`, leading `!` negation).
  var pat = pattern.strip().replace('\\', '/')
  while pat.startsWith("./"):
    pat = pat[2 .. ^1]
  if pat.len == 0 or pat == "*":
    return true
  let cleanPath = relPosixPath.replace('\\', '/')
  if '/' notin pat:
    let base = extractFilename(cleanPath)
    return globMatchHere(pat, base, 0, 0, defined(windows))
  globMatchHere(pat, cleanPath, 0, 0, defined(windows))

# 1. `read` tool

proc detectImageMime(path: string): string =
  case splitFile(path).ext.toLowerAscii()
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  else: ""

proc looksBinary(sample: string): bool =
  let limit = min(sample.len, 8192)
  for i in 0 ..< limit:
    if sample[i] == '\0':
      return true
  false

proc execReadTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let rawPath = args{"path"}.getStr("").strip()
  if rawPath.len == 0:
    return errorOutput("Missing required parameter: path")
  let fullPath = resolvePathFrom(rawPath, ctx.cwd)
  let deny = ctx.security.checkFileRead(fullPath)
  if deny.len > 0:
    return errorOutput(deny)
  if not fileExists(fullPath):
    return errorOutput("File not found: " & rawPath)

  let mime = detectImageMime(fullPath)
  if mime.len > 0:
    try:
      let rawBytes = readFile(fullPath)
      let encoded = base64.encode(rawBytes)
      return ToolOutput(
        content: @[
          textBlock("Read image file " & rawPath & " (" & $rawBytes.len & " bytes, " & mime & ")"),
          imageBlock(encoded, mime)
        ],
        isError: false
      )
    except CatchableError as e:
      return errorOutput("Failed to read image " & rawPath & ": " & e.msg)

  var rawContent = ""
  try:
    rawContent = readFile(fullPath)
  except CatchableError as e:
    return errorOutput("Failed to read file " & rawPath & ": " & e.msg)

  if looksBinary(rawContent):
    return errorOutput("Cannot read binary file as text: " & rawPath & " (" & $rawContent.len & " bytes)")

  let clean = stripUtf8Bom(rawContent).replace("\r\n", "\n")
  let allLines = clean.split('\n')
  let totalFileLines = allLines.len

  let offset1 = max(1, args{"offset"}.getInt(1))
  let startIdx = offset1 - 1
  if startIdx >= totalFileLines:
    return errorOutput("Offset " & $offset1 & " is past end of file (" & $totalFileLines & " lines in " & rawPath & ")")

  let hasLimit = args.hasKey("limit") and args["limit"].kind in {JInt, JFloat}
  let endIdx = if hasLimit:
    min(totalFileLines, startIdx + max(1, args["limit"].getInt()))
  else:
    totalFileLines

  let sliceText = allLines[startIdx ..< endIdx].join("\n")
  let trunc = truncateHead(sliceText)
  var outText = trunc.content
  let lastShownLine = startIdx + trunc.shownLines
  if trunc.truncated or lastShownLine < totalFileLines:
    let nextOffset = lastShownLine + 1
    outText.add("\n\n[Showing lines " & $offset1 & "-" & $lastShownLine & " of " & $totalFileLines &
                ". Use offset=" & $nextOffset & " to read more.]")
  okTextOutput(outText)

# 2. `write` tool

proc execWriteTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let rawPath = args{"path"}.getStr("").strip()
  if rawPath.len == 0:
    return errorOutput("Missing required parameter: path")
  if not args.hasKey("content") or args["content"].kind != JString:
    return errorOutput("Missing required string parameter: content")
  let content = args["content"].getStr()
  let fullPath = resolvePathFrom(rawPath, ctx.cwd)

  let deny = ctx.security.checkFileMutation(fullPath, isEdit = false)
  if deny.len > 0:
    return errorOutput(deny)

  try:
    let dir = parentDir(fullPath)
    if dir.len > 0 and not dirExists(dir):
      createDir(dir)
    writeFile(fullPath, content)
    return okTextOutput("Successfully wrote " & $content.len & " bytes to " & rawPath)
  except CatchableError as e:
    return errorOutput("Failed to write " & rawPath & ": " & e.msg)

# 3. `edit` tool (exact unique non-overlapping replacements, BOM + CRLF preservation, unified diff)

proc normalizeEditArgs(args: JsonNode): seq[EditBlock] =
  if args.isNil or args.kind != JObject:
    return @[]
  var editsNode = args{"edits"}
  if not editsNode.isNil and editsNode.kind == JString:
    try:
      editsNode = parseJson(editsNode.getStr())
    except CatchableError:
      editsNode = nil

  if not editsNode.isNil:
    if editsNode.kind == JArray:
      for item in editsNode.items:
        if item.kind == JObject and item.hasKey("oldText") and item.hasKey("newText"):
          result.add(EditBlock(oldText: item["oldText"].getStr(), newText: item["newText"].getStr()))
    elif editsNode.kind == JObject and editsNode.hasKey("oldText") and editsNode.hasKey("newText"):
      result.add(EditBlock(oldText: editsNode["oldText"].getStr(), newText: editsNode["newText"].getStr()))

  if args.hasKey("oldText") and args.hasKey("newText") and
     args["oldText"].kind == JString and args["newText"].kind == JString:
    result.add(EditBlock(oldText: args["oldText"].getStr(), newText: args["newText"].getStr()))

proc buildSimpleUnifiedDiff*(displayPath, beforeText, afterText: string, contextLines = 3): string =
  ## Produce a concise, readable unified diff around changed line ranges.
  let oldLines = beforeText.split('\n')
  let newLines = afterText.split('\n')
  var prefix = 0
  while prefix < oldLines.len and prefix < newLines.len and oldLines[prefix] == newLines[prefix]:
    inc prefix
  if prefix == oldLines.len and prefix == newLines.len:
    return ""

  var oldTail = oldLines.high
  var newTail = newLines.high
  while oldTail >= prefix and newTail >= prefix and oldLines[oldTail] == newLines[newTail]:
    dec oldTail
    dec newTail

  let ctxStart = max(0, prefix - contextLines)
  let oldCtxEnd = min(oldLines.high, oldTail + contextLines)
  let newCtxEnd = min(newLines.high, newTail + contextLines)

  var lines: seq[string] = @[
    "--- a/" & displayPath.replace('\\', '/'),
    "+++ b/" & displayPath.replace('\\', '/'),
    "@@ -" & $(ctxStart + 1) & "," & $(oldCtxEnd - ctxStart + 1) &
    " +" & $(ctxStart + 1) & "," & $(newCtxEnd - ctxStart + 1) & " @@"
  ]
  for i in ctxStart ..< prefix:
    lines.add(" " & oldLines[i])
  for i in prefix .. oldTail:
    lines.add("-" & oldLines[i])
  for i in prefix .. newTail:
    lines.add("+" & newLines[i])
  for i in (oldTail + 1) .. oldCtxEnd:
    lines.add(" " & oldLines[i])
  lines.join("\n")

proc normalizeFuzzyLine(line: string): string =
  ## Normalize trailing whitespace, smart quotes, Unicode dashes, and non-breaking spaces for fuzzy line matching.
  let trimmedRight = line.strip(leading = false, trailing = true)
  trimmedRight
    .multiReplace([
      ("\xE2\x80\x98", "'"), ("\xE2\x80\x99", "'"), ("\xE2\x80\x9A", "'"), ("\xE2\x80\x9B", "'"),
      ("\xE2\x80\x9C", "\""), ("\xE2\x80\x9D", "\""), ("\xE2\x80\x9E", "\""), ("\xE2\x80\x9F", "\""),
      ("\xE2\x80\x90", "-"), ("\xE2\x80\x91", "-"), ("\xE2\x80\x92", "-"), ("\xE2\x80\x93", "-"),
      ("\xE2\x80\x94", "-"), ("\xE2\x80\x95", "-"), ("\xE2\x88\x92", "-"),
      ("\xC2\xA0", " "), ("\xE2\x80\xAF", " "), ("\xE3\x80\x80", " ")
    ])

proc findFuzzyLineMatchSpan(normContent, needle: string): tuple[count: int, startIdx: int, endIdx: int, trailingLf: bool] =
  ## Line-aligned fuzzy fallback matching Pi's edit-diff semantics: matches normalized lines while keeping untouched lines byte-exact.
  var needleClean = needle
  let hadTrailingLf = needleClean.endsWith("\n")
  if hadTrailingLf and needleClean.len > 1:
    needleClean.setLen(needleClean.len - 1)

  let needleLines = needleClean.split('\n')
  if needleLines.len == 0:
    return (0, -1, -1, false)
  var normNeedle = newSeq[string](needleLines.len)
  for i, nl in needleLines.pairs:
    normNeedle[i] = normalizeFuzzyLine(nl)

  type FileLineSpan = tuple[startPos: int, endPosNoLf: int, endPosWithLf: int, norm: string]
  var fileLines: seq[FileLineSpan] = @[]
  var pos = 0
  while pos <= normContent.len:
    let nlIdx = normContent.find('\n', pos)
    if nlIdx < 0:
      let seg = normContent[pos .. ^1]
      fileLines.add((pos, normContent.len, normContent.len, normalizeFuzzyLine(seg)))
      break
    else:
      let seg = normContent[pos ..< nlIdx]
      fileLines.add((pos, nlIdx, nlIdx + 1, normalizeFuzzyLine(seg)))
      pos = nlIdx + 1
      if pos == normContent.len:
        break

  if needleLines.len > fileLines.len:
    return (0, -1, -1, false)

  var matchCount = 0
  var matchedStart = -1
  var matchedEnd = -1
  for startLine in 0 .. (fileLines.len - needleLines.len):
    var ok = true
    for k in 0 ..< needleLines.len:
      if fileLines[startLine + k].norm != normNeedle[k]:
        ok = false
        break
    if ok:
      inc matchCount
      matchedStart = fileLines[startLine].startPos
      let lastLine = fileLines[startLine + needleLines.high]
      matchedEnd = if hadTrailingLf: lastLine.endPosWithLf else: lastLine.endPosNoLf
      if matchCount > 1:
        return (matchCount, -1, -1, hadTrailingLf)

  (matchCount, matchedStart, matchedEnd, hadTrailingLf)

proc execEditTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let rawPath = args{"path"}.getStr("").strip()
  if rawPath.len == 0:
    return errorOutput("Missing required parameter: path")
  let edits = normalizeEditArgs(args)
  if edits.len == 0:
    return errorOutput("Edit tool requires non-empty `edits` array of {oldText, newText}.")

  let fullPath = resolvePathFrom(rawPath, ctx.cwd)
  if not fileExists(fullPath):
    return errorOutput("Could not edit file (not found): " & rawPath)

  let deny = ctx.security.checkFileMutation(fullPath, isEdit = true)
  if deny.len > 0:
    return errorOutput(deny)

  var rawFile = ""
  try:
    rawFile = readFile(fullPath)
  except CatchableError as e:
    return errorOutput("Failed to read " & rawPath & ": " & e.msg)

  let hasBom = rawFile.startsWith("\xEF\xBB\xBF")
  let withoutBom = if hasBom: rawFile[3 .. ^1] else: rawFile
  let usesCrlf = "\r\n" in withoutBom
  let normContent = withoutBom.replace("\r\n", "\n")

  var spans: seq[MatchedSpan] = @[]
  for idx, ed in edits.pairs:
    let needle = ed.oldText.replace("\r\n", "\n")
    var replacement = ed.newText.replace("\r\n", "\n")
    if needle.len == 0:
      return errorOutput("edits[" & $idx & "].oldText must not be empty.")
    let firstPos = normContent.find(needle)
    if firstPos >= 0:
      let secondPos = normContent.find(needle, firstPos + 1)
      if secondPos >= 0:
        return errorOutput("edits[" & $idx & "].oldText matched multiple locations in " & rawPath &
                           ". Include more surrounding context lines to make it unique.")
      spans.add(MatchedSpan(startIdx: firstPos, endIdx: firstPos + needle.len, newText: replacement))
    else:
      let fuzzy = findFuzzyLineMatchSpan(normContent, needle)
      if fuzzy.count == 0:
        return errorOutput("Could not find exact or fuzzy match for edits[" & $idx & "].oldText in " & rawPath &
                           ". Read the file again and verify whitespace and surrounding lines.")
      if fuzzy.count > 1:
        return errorOutput("edits[" & $idx & "].oldText matched multiple locations (fuzzy) in " & rawPath &
                           ". Include more surrounding context lines to make it unique.")
      if fuzzy.trailingLf and not replacement.endsWith("\n") and fuzzy.endIdx <= normContent.len and
         fuzzy.endIdx > 0 and normContent[fuzzy.endIdx - 1] == '\n':
        replacement.add("\n")
      spans.add(MatchedSpan(startIdx: fuzzy.startIdx, endIdx: fuzzy.endIdx, newText: replacement))

  spans.sort(proc(a, b: MatchedSpan): int = cmp(a.startIdx, b.startIdx))
  for i in 1 ..< spans.len:
    if spans[i].startIdx < spans[i - 1].endIdx:
      return errorOutput("Overlapping edits detected in " & rawPath & ". Merge nearby replacements into a single edit.")

  var updatedNorm = newStringOfCap(normContent.len + 256)
  var cursor = 0
  for sp in spans:
    if sp.startIdx > cursor:
      updatedNorm.add(normContent[cursor ..< sp.startIdx])
    updatedNorm.add(sp.newText)
    cursor = sp.endIdx
  if cursor < normContent.len:
    updatedNorm.add(normContent[cursor .. ^1])

  let diffText = buildSimpleUnifiedDiff(rawPath, normContent, updatedNorm)
  let finalText = (if hasBom: "\xEF\xBB\xBF" else: "") &
                  (if usesCrlf: updatedNorm.replace("\n", "\r\n") else: updatedNorm)

  try:
    writeFile(fullPath, finalText)
  except CatchableError as e:
    return errorOutput("Failed to write edited file " & rawPath & ": " & e.msg)

  okTextOutput("Successfully replaced " & $edits.len & " block(s) in " & rawPath & ".", diff = diffText)

# 4. `bash` & `powershell` tools (cross-platform POSIX + native Windows Git Bash & PowerShell)

proc resolveBashShell*(configuredShell: string): tuple[exe: string, baseArgs: seq[string]] =
  ## Resolve Bash executable following Pi's Windows & POSIX rules.
  if configuredShell.strip().len > 0:
    return (configuredShell.strip(), @["-c"])
  when defined(windows):
    let pf = getEnv("ProgramFiles", "C:\\Program Files")
    let pfx86 = getEnv("ProgramFiles(x86)", "C:\\Program Files (x86)")
    for candidate in [
      pf / "Git" / "bin" / "bash.exe",
      pfx86 / "Git" / "bin" / "bash.exe"
    ]:
      if fileExists(candidate):
        return (candidate, @["-c"])
    let pathBash = findExe("bash")
    if pathBash.len > 0:
      return (pathBash, @["-c"])
    let cmdExe = getEnv("COMSPEC", "cmd.exe")
    return (cmdExe, @["/d", "/s", "/c"])
  else:
    let bashExe = findExe("bash")
    if bashExe.len > 0:
      return (bashExe, @["-c"])
    return ("/bin/sh", @["-c"])

proc resolvePowerShellExe*(): tuple[exe: string, baseArgs: seq[string]] =
  ## Resolve PowerShell executable in Pi's documented order (pwsh -> powershell).
  let baseFlags = @["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
  let pwshOnPath = findExe("pwsh")
  if pwshOnPath.len > 0:
    return (pwshOnPath, baseFlags)
  when defined(windows):
    let pf = getEnv("ProgramFiles", "C:\\Program Files")
    let pwsh7 = pf / "PowerShell" / "7" / "pwsh.exe"
    if fileExists(pwsh7):
      return (pwsh7, baseFlags)
    let psOnPath = findExe("powershell")
    if psOnPath.len > 0:
      return (psOnPath, baseFlags)
    let sysRoot = getEnv("SystemRoot", "C:\\Windows")
    let winPs = sysRoot / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    if fileExists(winPs):
      return (winPs, baseFlags)
  return ("", @[])

proc buildChildEnv(ctx: ToolContext): StringTableRef =
  result = ctx.security.processEnvironment()
  result["NI_CWD"] = ctx.cwd
  result["PI_CWD"] = ctx.cwd
  if ctx.modelId.len > 0:
    result["NI_MODEL"] = ctx.modelId
    result["PI_MODEL"] = ctx.modelId
  if ctx.sessionId.len > 0:
    result["NI_SESSION_ID"] = ctx.sessionId
    result["PI_SESSION_ID"] = ctx.sessionId

proc execShellCommon(shellKind: string, exe: string, baseArgs: seq[string], args: JsonNode, ctx: ToolContext): ToolOutput =
  let rawCmd = args{"command"}.getStr("").strip()
  if rawCmd.len == 0:
    return errorOutput("Missing required parameter: command")
  if exe.len == 0:
    return errorOutput(shellKind & " executable was not found on this system.")

  let deny = ctx.security.checkShellExecution(rawCmd)
  if deny.len > 0:
    return errorOutput(deny)

  let timeoutSec = if args.hasKey("timeout") and args["timeout"].kind in {JInt, JFloat}:
    args["timeout"].getFloat()
  else:
    0.0
  if timeoutSec < 0.0:
    return errorOutput("Invalid timeout: must be a positive number of seconds")

  let fullCmd = if ctx.settings.shellCommandPrefix.len > 0 and shellKind == "bash":
    ctx.settings.shellCommandPrefix & "\n" & rawCmd
  else:
    rawCmd

  if not dirExists(ctx.cwd):
    return errorOutput("Working directory does not exist: " & ctx.cwd)

  try:
    let (spawnExe, spawnArgs) = ctx.security.wrapProcess(exe, baseArgs & @[fullCmd], ctx.cwd)
    let res = runProcessCapture(spawnExe, spawnArgs, ctx.cwd, buildChildEnv(ctx), timeoutSec, ctx.abort,
      onOutput = ctx.onOutput)
    if res.aborted:
      return errorOutput("Command aborted by user")
    if res.timedOut:
      let saved = if res.output.len > 0: saveFullOutputTemp(shellKind, res.output) else: ""
      var msg = "Command timed out after " & $timeoutSec & "s."
      if res.output.len > 0:
        let trunc = truncateHead(res.output)
        msg.add("\nPartial output:\n" & trunc.content)
        if saved.len > 0:
          msg.add("\n[Full partial output saved to " & saved & "]")
      return ToolOutput(content: @[textBlock(msg)], isError: true, fullOutputPath: saved)

    let cleanOut = res.output.replace("\r\n", "\n")
    let trunc = truncateHead(cleanOut)
    var fullPath = ""
    var rendered = if trunc.content.len > 0: trunc.content else: "(no command output)"
    if trunc.truncated:
      fullPath = saveFullOutputTemp(shellKind, cleanOut)
      rendered.add("\n\n[Output truncated: showing " & $trunc.shownLines & " of " & $trunc.totalLines &
                   " lines (" & $trunc.totalBytes & " bytes)." &
                   (if fullPath.len > 0: " Full output saved to " & fullPath else: "") & "]")
    if res.exitCode != 0:
      rendered.add("\n[Command exited with code " & $res.exitCode & "]")
      return ToolOutput(content: @[textBlock(rendered)], isError: true, fullOutputPath: fullPath)
    return okTextOutput(rendered, fullPath = fullPath)
  except CatchableError as e:
    return errorOutput("Failed to execute " & shellKind & ": " & e.msg)

proc execBashTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let (exe, baseArgs) = resolveBashShell(ctx.settings.shellPath)
  execShellCommon("bash", exe, baseArgs, args, ctx)

proc execPowerShellTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let (exe, baseArgs) = resolvePowerShellExe()
  execShellCommon("powershell", exe, baseArgs, args, ctx)

proc runUserShell*(command, cwd: string, settings: NiSettings, policy: SecurityPolicy,
                   abort: AbortFlag, timeoutSec = 0.0,
                   onOutput: proc(delta: string) {.closure.} = nil):
    tuple[output: string, exitCode: int, timedOut: bool, aborted: bool, wallSec: float] =
  let (exe, args) = resolveBashShell(settings.shellPath)
  if exe.len == 0:
    raise newException(IOError, "bash executable was not found on this system")
  let (wrappedExe, wrappedArgs) = policy.wrapProcess(exe, args & @[command], cwd)
  runProcessCapture(wrappedExe, wrappedArgs, cwd, policy.processEnvironment(), timeoutSec, abort, onOutput = onOutput)

proc runInteractiveUserShell*(command, cwd: string, settings: NiSettings, policy: SecurityPolicy,
                              abort: AbortFlag, onOutput: proc(delta: string) {.closure.} = nil):
    tuple[output: string, exitCode: int, timedOut: bool, aborted: bool, wallSec: float] =
  ## Load user aliases for commands typed at the prompt. Automation and sandboxed commands keep their existing shell.
  when not defined(windows):
    if policy.isNil or policy.sandboxMode == sandboxOff:
      let configured = settings.shellPath.strip()
      let preferred = if configured.len > 0: configured else: getEnv("SHELL")
      let shell = if preferred.isAbsolute:
        (if fileExists(preferred): preferred else: "")
      elif preferred.len > 0 and DirSep notin preferred: findExe(preferred)
      else: ""
      let shellName = extractFilename(shell)
      if shellName in ["bash", "zsh"]:
        # Ignore prompt/plugin startup output once the shell reaches the user's command.
        let marker = "\x1eNi-shell-" & $getMonoTime().ticks & "\x1f"
        let script = "builtin printf '%s\\n' " & quoteShell(marker) & "\n" & command
        # The captured child is in its own process group, behind the TUI.
        let args = if shellName == "zsh": @["-o", "NO_MONITOR", "-ic", script]
          else: @["+m", "-ic", script]
        let boundary = marker & "\n"
        var startupTail = ""
        var started = false
        proc forwardCommandOutput(delta: string) =
          if started:
            onOutput(delta)
            return
          startupTail.add(delta)
          let index = startupTail.find(boundary)
          if index >= 0:
            started = true
            let first = index + boundary.len
            if first < startupTail.len:
              onOutput(startupTail[first .. ^1])
            startupTail.setLen(0)
          elif startupTail.len >= boundary.len:
            startupTail = startupTail[startupTail.len - boundary.len + 1 .. ^1]
        let forward = if onOutput.isNil: nil else: forwardCommandOutput
        result = runProcessCapture(shell, args, cwd, policy.processEnvironment(), 0, abort, onOutput = forward)
        let start = result.output.find(boundary)
        if start >= 0:
          result.output = result.output[start + boundary.len .. ^1]
        elif not onOutput.isNil and result.output.len > 0:
          onOutput(result.output)
        return
  runUserShell(command, cwd, settings, policy, abort, onOutput = onOutput)

# 5. `ls` tool

proc execLsTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let rel = args{"path"}.getStr(".")
  let limit = max(1, args{"limit"}.getInt(500))
  let dirPath = resolvePathFrom(rel, ctx.cwd)
  let deny = ctx.security.checkFileRead(dirPath)
  if deny.len > 0:
    return errorOutput(deny)
  if not dirExists(dirPath):
    if fileExists(dirPath):
      return errorOutput("Not a directory: " & rel)
    return errorOutput("Path not found: " & rel)

  var names: seq[string] = @[]
  try:
    for kind, full in walkDir(dirPath):
      let base = extractFilename(full)
      let suffix = if kind in {pcDir, pcLinkToDir}: "/" else: ""
      names.add(base & suffix)
  except CatchableError as e:
    return errorOutput("Cannot read directory " & rel & ": " & e.msg)

  names.sort(proc(a, b: string): int = cmpIgnoreCase(a, b))
  if names.len == 0:
    return okTextOutput("(empty directory)")

  let hitLimit = names.len > limit
  let shown = if hitLimit: names[0 ..< limit] else: names
  let trunc = truncateHead(shown.join("\n"), maxLines = high(int))
  var outStr = trunc.content
  if hitLimit:
    outStr.add("\n\n[" & $limit & " entries limit reached. Use limit=" & $(limit * 2) & " for more]")
  elif trunc.truncated:
    outStr.add("\n\n[50KB output limit reached]")
  okTextOutput(outStr)

# 6. `find` tool (uses `fd` when installed, with pure-Nim recursive glob walker fallback!)

proc shouldSkipWalkDir(name: string): bool =
  name in [".git", "node_modules", ".hg", ".svn", "nimcache"]

proc walkProjectFilesPureNim(searchRoot, pattern: string, maxResults: int, ctx: ToolContext): seq[string] =
  var stack: seq[string] = @[searchRoot]
  while stack.len > 0 and result.len < maxResults:
    if ctx.abort.pollAbort():
      break
    let cur = stack.pop()
    var subDirs: seq[string] = @[]
    var files: seq[string] = @[]
    try:
      for kind, p in walkDir(cur):
        if ctx.security.checkFileRead(p).len > 0:
          continue
        let name = extractFilename(p)
        if kind in {pcDir, pcLinkToDir}:
          if not shouldSkipWalkDir(name):
            subDirs.add(p)
        elif kind in {pcFile, pcLinkToFile}:
          files.add(p)
    except CatchableError:
      continue

    subDirs.sort(proc(a, b: string): int = cmpIgnoreCase(b, a)) # reversed for LIFO stack
    files.sort(proc(a, b: string): int = cmpIgnoreCase(a, b))
    for d in subDirs:
      stack.add(d)
    for f in files:
      let rel = relativePath(f, searchRoot).replace('\\', '/')
      if matchGlob(pattern, rel):
        result.add(rel)
        if result.len >= maxResults:
          break

proc execFindTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let pattern = args{"pattern"}.getStr("").strip()
  if pattern.len == 0:
    return errorOutput("Missing required parameter: pattern")
  let relDir = args{"path"}.getStr(".")
  let limit = max(1, args{"limit"}.getInt(1000))
  let searchRoot = resolvePathFrom(relDir, ctx.cwd)
  let deny = ctx.security.checkFileRead(searchRoot)
  if deny.len > 0:
    return errorOutput(deny)
  if not dirExists(searchRoot) and not fileExists(searchRoot):
    return errorOutput("Path not found: " & relDir)

  let matches = walkProjectFilesPureNim(searchRoot, pattern, limit + 1, ctx)
  if not ctx.abort.isNil and ctx.abort.aborted:
    return errorOutput("Operation aborted")
  if matches.len == 0:
    return okTextOutput("No files found matching pattern")

  let hitLimit = matches.len > limit
  let slice = if hitLimit: matches[0 ..< limit] else: matches
  let trunc = truncateHead(slice.join("\n"), maxLines = high(int))
  var outStr = trunc.content
  if hitLimit:
    outStr.add("\n\n[" & $limit & " results limit reached]")
  elif trunc.truncated:
    outStr.add("\n\n[50KB output limit reached]")
  okTextOutput(outStr)

# 7. `grep` tool (uses `rg` when available on PATH, with pure-Nim search fallback for Windows/minimal systems)

proc clipGrepLine(s: string): string =
  if s.len <= GrepMaxLineChars: s
  else: s[0 ..< utf8BoundaryBefore(s, GrepMaxLineChars)] & "...[truncated]"

proc execGrepPureNim(
  pattern, searchPath, globPat: string,
  ignoreCase, contextCount, limit: int,
  ctx: ToolContext
): ToolOutput =
  let needle = if ignoreCase != 0: pattern.toLowerAscii() else: pattern
  let files = if fileExists(searchPath):
    @[searchPath]
  else:
    let rels = walkProjectFilesPureNim(searchPath, if globPat.len > 0: globPat else: "*", 10_000, ctx)
    var fulls: seq[string] = @[]
    for r in rels:
      fulls.add(searchPath / r)
    fulls

  var outLines: seq[string] = @[]
  var matches = 0
  var hitLimit = false

  for fp in files:
    if ctx.abort.pollAbort():
      return errorOutput("Operation aborted")
    var raw = ""
    try:
      raw = readFile(fp)
    except CatchableError:
      continue
    if looksBinary(raw):
      continue
    let lines = raw.replace("\r\n", "\n").split('\n')
    let disp = if dirExists(searchPath): relativePath(fp, searchPath).replace('\\', '/') else: extractFilename(fp)
    for idx, line in lines.pairs:
      let hay = if ignoreCase != 0: line.toLowerAscii() else: line
      if needle in hay:
        inc matches
        if matches > limit:
          hitLimit = true
          break
        let startCtx = max(0, idx - contextCount)
        let endCtx = min(lines.high, idx + contextCount)
        for c in startCtx .. endCtx:
          let sep = if c == idx: ":" else: "-"
          outLines.add(disp & sep & $(c + 1) & sep & " " & clipGrepLine(lines[c]))
    if hitLimit:
      break

  if matches == 0:
    return okTextOutput("No matches found")
  let trunc = truncateHead(outLines.join("\n"), maxLines = high(int))
  var text = trunc.content
  if hitLimit:
    text.add("\n\n[" & $limit & " matches limit reached]")
  elif trunc.truncated:
    text.add("\n\n[50KB output limit reached]")
  okTextOutput(text)

proc execGrepTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let pattern = args{"pattern"}.getStr("")
  if pattern.len == 0:
    return errorOutput("Missing required parameter: pattern")
  let relDir = args{"path"}.getStr(".")
  let globPat = args{"glob"}.getStr("")
  let ignoreCase = args{"ignoreCase"}.getBool(false)
  let literal = args{"literal"}.getBool(false)
  let ctxLines = max(0, args{"context"}.getInt(0))
  let limit = max(1, args{"limit"}.getInt(100))

  let searchPath = resolvePathFrom(relDir, ctx.cwd)
  let deny = ctx.security.checkFileRead(searchPath)
  if deny.len > 0:
    return errorOutput(deny)
  if not dirExists(searchPath) and not fileExists(searchPath):
    return errorOutput("Path not found: " & relDir)

  let rgExe = if not ctx.security.isNil and ctx.security.workspaceReadsOnly: "" else: findExe("rg")
  if rgExe.len == 0:
    return execGrepPureNim(pattern, searchPath, globPat, (if ignoreCase: 1 else: 0), ctxLines, limit, ctx)

  let isDir = dirExists(searchPath)
  var rgArgs = @["--no-config", "--line-number", "--color=never", "--hidden"]
  if ignoreCase: rgArgs.add("--ignore-case")
  if literal: rgArgs.add("--fixed-strings")
  if globPat.len > 0:
    var cleanGlob = globPat
    while cleanGlob.startsWith("./"):
      cleanGlob = cleanGlob[2 .. ^1]
    rgArgs.add(["--glob", cleanGlob])
  if ctxLines > 0:
    rgArgs.add(["--context", $ctxLines])
  rgArgs.add(["--", pattern, (if isDir: "." else: searchPath)])

  let runDir = if isDir: searchPath else: parentDir(searchPath)
  let (spawnExe, spawnArgs) = ctx.security.wrapProcess(rgExe, rgArgs, runDir)
  let res = runProcessCapture(spawnExe, spawnArgs, runDir, buildChildEnv(ctx), 30.0, ctx.abort)
  if res.aborted:
    return errorOutput("Operation aborted")
  if res.exitCode == 1 and res.output.strip().len == 0:
    return okTextOutput("No matches found")
  if res.exitCode > 1:
    return errorOutput("grep error: " & res.output.strip())

  var formatted: seq[string] = @[]
  for rawLine in res.output.replace("\r\n", "\n").split('\n'):
    if rawLine.len == 0:
      continue
    var line = rawLine
    if line.startsWith("./"):
      line = line[2 .. ^1]
    formatted.add(clipGrepLine(line))
    if formatted.len >= limit * max(1, ctxLines * 2 + 1):
      break

  if formatted.len == 0:
    return okTextOutput("No matches found")
  let hitLimit = formatted.len > limit and ctxLines == 0
  let kept = if hitLimit: formatted[0 ..< limit] else: formatted
  let trunc = truncateHead(kept.join("\n"), maxLines = high(int))
  var finalOut = trunc.content
  if hitLimit:
    finalOut.add("\n\n[" & $limit & " matches limit reached]")
  elif trunc.truncated:
    finalOut.add("\n\n[50KB output limit reached]")
  okTextOutput(finalOut)

# 8. `ask_question` tool (interactive option selector + custom answer support)

proc parseAskQuestions(args: JsonNode): seq[AskQuestionItem] =
  if args.isNil or args.kind != JObject:
    return @[]
  var qArr = args{"questions"}
  # Also allow single-question shorthand { question: "...", options: [...] }
  if qArr.isNil and args.hasKey("question"):
    qArr = newJArray()
    qArr.add(args)
  if qArr.isNil or qArr.kind != JArray:
    return @[]

  for idx, qnode in qArr.elems.pairs:
    if qnode.kind != JObject:
      continue
    let qText = qnode{"question"}.getStr("").strip()
    if qText.len == 0:
      continue
    var opts: seq[QuestionOption] = @[]
    if qnode.hasKey("options") and qnode["options"].kind == JArray:
      for optNode in qnode["options"].items:
        if optNode.kind == JString:
          let lbl = optNode.getStr().strip()
          if lbl.len > 0:
            opts.add(QuestionOption(label: lbl, description: ""))
        elif optNode.kind == JObject:
          let lbl = optNode{"label"}.getStr(optNode{"title"}.getStr("")).strip()
          let desc = optNode{"description"}.getStr("").strip()
          if lbl.len > 0:
            opts.add(QuestionOption(label: lbl, description: desc))
    result.add(AskQuestionItem(
      id: qnode{"id"}.getStr("q" & $(idx + 1)),
      header: qnode{"header"}.getStr(""),
      question: qText,
      options: opts,
      multiSelect: qnode{"multiSelect"}.getBool(qnode{"is_multi_select"}.getBool(false)),
      allowOther: qnode{"allowOther"}.getBool(true)
    ))

proc execAskQuestionTool(args: JsonNode, ctx: ToolContext): ToolOutput =
  let questions = parseAskQuestions(args)
  if questions.len == 0:
    return errorOutput("ask_question requires at least one question with a non-empty `question` string.")
  if ctx.askQuestion.isNil:
    return errorOutput("Interactive user prompt is unavailable in non-interactive mode (--print / --mode json). State any assumption clearly or proceed with the safest default.")

  let answers = ctx.askQuestion(questions)
  var outArr = newJArray()
  for ans in answers:
    var selArr = newJArray()
    for s in ans.selected:
      selArr.add(%s)
    var obj = %*{
      "id": ans.id,
      "question": ans.question,
      "selected": selArr,
      "cancelled": ans.cancelled
    }
    if ans.customText.len > 0:
      obj["customText"] = %ans.customText
    outArr.add(obj)

  okTextOutput($(%*{ "answers": outArr }))

# 9. `tool_search` tool (discovers and activates deferred/codemode MCP tools)

proc scoreToolMatch(queryTerms: seq[string], tool: AgentTool): float =
  let nameLow = tool.name.toLowerAscii()
  let descLow = tool.description.toLowerAscii()
  let nsLow = tool.namespace.toLowerAscii()
  for term in queryTerms:
    if term.len == 0:
      continue
    if term == nameLow:
      result += 12.0
    elif term in nameLow:
      result += 6.0
    if term in nsLow:
      result += 3.0
    if term in descLow:
      result += 2.5

proc makeToolSearchTool*(reg: ToolRegistry): AgentTool =
  AgentTool(
    name: "tool_search",
    description: "Search indirect/deferred tools (such as MCP server tools) by keyword and activate matches so you can call them directly in your next turn.",
    snippet: "Search and load deferred MCP tools by keyword",
    guidelines: @["Use tool_search to discover and load tools from listed MCP servers before calling them."],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Keywords describing the tool capability you need" },
        "namespace": { "type": "string", "description": "Optional MCP server name filter" },
        "limit": { "type": "integer", "description": "Maximum tools to load (default: 8)" }
      },
      "required": ["query"]
    },
    execute: proc(args: JsonNode, ctx: ToolContext): ToolOutput =
      let query = args{"query"}.getStr("").strip().toLowerAscii()
      let nsFilter = args{"namespace"}.getStr("").strip().toLowerAscii().replace("-", "_")
      let limit = clamp(args{"limit"}.getInt(8), 1, 25)
      if query.len == 0:
        return errorOutput("query must not be empty")

      var terms: seq[string] = @[]
      for part in query.split({' ', '\t', '_', '-', '/', '.'}):
        if part.len > 0:
          terms.add(part)
      if terms.len == 0:
        terms.add(query)

      var scored: seq[tuple[score: float, tool: AgentTool]] = @[]
      for tname, tool in reg.tools.pairs:
        if tname notin reg.discoverableNames or tool.exposure == teHidden:
          continue
        if nsFilter.len > 0:
          let normNs = tool.namespace.toLowerAscii().replace("-", "_")
          if nsFilter notin normNs and normNs notin nsFilter:
            continue
        let sc = scoreToolMatch(terms, tool)
        if sc > 0.0:
          scored.add((sc, tool))

      scored.sort(proc(a, b: tuple[score: float, tool: AgentTool]): int = cmp(b.score, a.score))
      if scored.len == 0:
        return okTextOutput("No matching tools found for query: " & query)

      let count = min(limit, scored.len)
      var activated: seq[string] = @[]
      var lines: seq[string] = @["Loaded " & $count & " tool(s) for direct invocation:"]
      for i in 0 ..< count:
        let t = scored[i].tool
        reg.activeNames.incl(t.name)
        activated.add(t.name)
        lines.add("- " & t.name & ": " & t.description)

      ToolOutput(
        content: @[textBlock(lines.join("\n"))],
        isError: false,
        activatedTools: activated
      )
  )

# ToolRegistry construction and loadout preparation

proc registerBuiltInTools*(reg: ToolRegistry, includePowerShell = defined(windows)) =
  ## Register all built-in coding agent tools into reg.
  reg.tools["read"] = AgentTool(
    name: "read",
    description: "Read the contents of a file (text or PNG/JPG/GIF/WebP image). Text output is capped at 2000 lines or 50KB; use offset (1-indexed) and limit for large files.",
    snippet: "Read file contents",
    guidelines: @["Use read to examine files instead of cat or sed."],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the file to read (relative or absolute)" },
        "offset": { "type": "integer", "description": "1-indexed line number to start reading from" },
        "limit": { "type": "integer", "description": "Maximum number of lines to read" }
      },
      "required": ["path"]
    },
    execute: execReadTool
  )

  reg.tools["write"] = AgentTool(
    name: "write",
    description: "Write content to a file. Creates parent directories automatically and overwrites existing files.",
    snippet: "Create or overwrite files",
    guidelines: @["Use write only for new files or complete rewrites."],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the file to write (relative or absolute)" },
        "content": { "type": "string", "description": "Full text content to write" }
      },
      "required": ["path", "content"]
    },
    execute: execWriteTool
  )

  reg.tools["edit"] = AgentTool(
    name: "edit",
    description: "Edit an existing file using exact, unique, non-overlapping text replacements. Preserves UTF-8 BOM and LF/CRLF line endings.",
    snippet: "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
    guidelines: @[
      "Use edit for targeted changes. Batch changes to one file in a single call.",
      "Each edits[].oldText must uniquely match the original file without overlapping other edits."
    ],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the file to edit (relative or absolute)" },
        "edits": {
          "type": "array",
          "description": "List of non-overlapping {oldText, newText} replacements matched against the original file",
          "items": {
            "type": "object",
            "properties": {
              "oldText": { "type": "string", "description": "Exact unique text in the file to replace" },
              "newText": { "type": "string", "description": "Replacement text" }
            },
            "required": ["oldText", "newText"]
          }
        }
      },
      "required": ["path", "edits"]
    },
    execute: execEditTool
  )

  reg.tools["bash"] = AgentTool(
    name: "bash",
    description: "Execute a shell command in the workspace directory (Bash on Linux/macOS, Git Bash on Windows).",
    snippet: "Execute shell commands (git, build, test, etc.)",
    guidelines: @["Prefer dedicated read/edit/grep/find/ls tools over shell commands for routine file inspection."],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "command": { "type": "string", "description": "Shell command line to execute" },
        "timeout": { "type": "number", "description": "Optional timeout in seconds" }
      },
      "required": ["command"]
    },
    execute: execBashTool
  )

  if includePowerShell or findExe("pwsh").len > 0:
    reg.tools["powershell"] = AgentTool(
      name: "powershell",
      description: "Execute a PowerShell command (`pwsh` or Windows PowerShell) with -NoProfile -NonInteractive.",
      snippet: "Execute PowerShell commands (Windows native automation and cmdlets)",
      guidelines: @[],
      exposure: teDirect,
      namespace: "builtin",
      parameters: %*{
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "PowerShell script/command to execute" },
          "timeout": { "type": "number", "description": "Optional timeout in seconds" }
        },
        "required": ["command"]
      },
      execute: execPowerShellTool
    )

  reg.tools["grep"] = AgentTool(
    name: "grep",
    description: "Search file contents for a regex or literal string pattern. Uses ripgrep when installed with a built-in pure-Nim fallback.",
    snippet: "Search file contents for patterns",
    guidelines: @[],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "pattern": { "type": "string", "description": "Pattern to search for" },
        "path": { "type": "string", "description": "Directory or file to search (default: workspace root)" },
        "glob": { "type": "string", "description": "Optional file glob filter such as '*.nim' or 'src/**/*.ts'" },
        "ignoreCase": { "type": "boolean", "description": "Case-insensitive search" },
        "literal": { "type": "boolean", "description": "Treat pattern as fixed literal text" },
        "context": { "type": "integer", "description": "Context lines before and after each match" },
        "limit": { "type": "integer", "description": "Max matches to return (default: 100)" }
      },
      "required": ["pattern"]
    },
    execute: execGrepTool
  )

  reg.tools["find"] = AgentTool(
    name: "find",
    description: "Find files in the workspace matching a glob pattern (`*`, `?`, `**`).",
    snippet: "Find files by glob pattern",
    guidelines: @[],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "pattern": { "type": "string", "description": "Glob pattern such as '*.nim' or 'src/**/*.nim'" },
        "path": { "type": "string", "description": "Directory to search in (default: workspace root)" },
        "limit": { "type": "integer", "description": "Max file paths to return (default: 1000)" }
      },
      "required": ["pattern"]
    },
    execute: execFindTool
  )

  reg.tools["ls"] = AgentTool(
    name: "ls",
    description: "List directory entries sorted alphabetically with '/' appended to directories.",
    snippet: "List directory contents",
    guidelines: @[],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Directory to list (default: workspace root)" },
        "limit": { "type": "integer", "description": "Max entries to return (default: 500)" }
      }
    },
    execute: execLsTool
  )

  reg.tools["ask_question"] = AgentTool(
    name: "ask_question",
    description: "Ask the user one or more structured multiple-choice questions in the TUI (supports single-select, multi-select, option descriptions, and custom text answers).",
    snippet: "Ask the user interactive multiple-choice questions to clarify ambiguous requirements or choices",
    guidelines: @["Use ask_question when requirements or design choices have distinct options the user should pick from."],
    exposure: teDirect,
    namespace: "builtin",
    parameters: %*{
      "type": "object",
      "properties": {
        "questions": {
          "type": "array",
          "description": "Questions to present to the user in sequence",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string", "description": "Short identifier for the question" },
              "header": { "type": "string", "description": "Optional short category tag (e.g. 'Database', 'Auth')" },
              "question": { "type": "string", "description": "Clear question prompt shown to the user" },
              "options": {
                "type": "array",
                "description": "Choices presented to the user (put recommended choice first)",
                "items": {
                  "type": "object",
                  "properties": {
                    "label": { "type": "string", "description": "Concise option title" },
                    "description": { "type": "string", "description": "Optional trade-off or explanation" }
                  },
                  "required": ["label"]
                }
              },
              "multiSelect": { "type": "boolean", "description": "Allow selecting multiple options" },
              "allowOther": { "type": "boolean", "description": "Include a custom free-text 'Other' option (default: true)" }
            },
            "required": ["question", "options"]
          }
        }
      },
      "required": ["questions"]
    },
    execute: execAskQuestionTool
  )

  reg.tools["tool_search"] = makeToolSearchTool(reg)

proc newToolRegistry*(enabledList: openArray[string], includePowerShell = defined(windows)): ToolRegistry =
  ## Create a ToolRegistry and activate the requested startup tool names.
  result = ToolRegistry(
    tools: initOrderedTable[string, AgentTool](),
    activeNames: initHashSet[string](),
    discoverableNames: initHashSet[string]()
  )
  result.registerBuiltInTools(includePowerShell)
  for name in enabledList:
    if result.tools.hasKey(name):
      result.activeNames.incl(name)

proc applyToolOverrides*(reg: ToolRegistry, entries: openArray[string]) =
  ## Apply both execution and discovery restrictions to a loadout.
  var active, discoverable: seq[string]
  for name in reg.activeNames: active.add(name)
  for name in reg.discoverableNames: discoverable.add(name)
  reg.activeNames.clear()
  reg.discoverableNames.clear()
  for name in applyToolListSpec(active, entries):
    if reg.tools.hasKey(name) and reg.tools[name].exposure != teHidden:
      reg.activeNames.incl(name)
  for name in applyToolListSpec(discoverable, entries):
    if reg.tools.hasKey(name) and reg.tools[name].exposure in {teDeferred, teCodemode}:
      reg.discoverableNames.incl(name)

proc declaredToolSchemas*(reg: ToolRegistry): seq[ToolSchemaDef] =
  ## Build the list of tool JSON schemas exposed directly to the LLM on the next turn.
  for name, tool in reg.tools.pairs:
    if name in reg.activeNames and tool.exposure != teHidden:
      result.add(ToolSchemaDef(
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      ))

proc invokeTool*(reg: ToolRegistry, name: string, args: JsonNode, ctx: ToolContext): ToolOutput =
  ## Execute a registered tool by name, returning structured ToolOutput.
  if not reg.tools.hasKey(name):
    return errorOutput("Unknown tool: " & name)
  let tool = reg.tools[name]
  if tool.exposure == teHidden:
    return errorOutput("Tool '" & name & "' is hidden by configuration.")
  if name notin reg.activeNames:
    return errorOutput("Tool '" & name & "' is not enabled.")
  try:
    return tool.execute(if args.isNil: newJObject() else: args, ctx)
  except CatchableError as e:
    return errorOutput("Tool '" & name & "' raised an exception: " & e.msg)
