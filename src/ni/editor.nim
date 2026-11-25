# Interactive multi-line TUI input editor: UTF-8/CJK cursor editing, undo/kill-ring, persistent history, bracketed paste markers, $EDITOR, and /command + @file autocomplete.

import std/[algorithm, json, options, os, osproc, strutils, tables, unicode]
import ./terminal_io

const
  MaxHistoryEntries* = 200
  MaxUndoSnapshots = 64
  AutocompleteMaxVisible = 6
  PasteCollapseMinLines* = 4
  PasteCollapseMinChars* = 240

type
  SlashCommandDef* = object
    name*: string         # Without leading '/', e.g. "model", "skill:review", "plan"
    argumentHint*: string # Optional e.g. "[provider/model]"
    description*: string
    source*: string       # "builtin", "skill", "prompt"

  AutocompleteItem* = object
    display*: string
    insertText*: string
    description*: string
    isDirectory*: bool
    score*: int

  AutocompleteKind* = enum
    ackNone
    ackSlash
    ackModelArg
    ackFile

  EditorSnapshot = object
    lines: seq[string]
    cursorLine: int
    cursorCol: int
    pastes: Table[int, string]
    pasteCounter: int

  EditorStatusInfo* = object
    cwd*: string
    gitBranch*: string
    sessionName*: string
    modelLabel*: string
    thinkingLabel*: string
    contextPct*: int
    contextWindow*: int
    inputTokens*: int
    outputTokens*: int
    cacheReadTokens*: int
    totalTokens*: int
    costUsd*: float
    isSubscription*: bool
    workingStatus*: string
    queuedMessages*: seq[string]

  EditorOutcomeKind* = enum
    eokSubmit
    eokCancel
    eokEof

  EditorOutcome* = object
    case kind*: EditorOutcomeKind
    of eokSubmit:
      text*: string        # Expanded prompt text (with [paste #N] markers resolved)
      displayText*: string # Compact text as shown in editor
    of eokCancel, eokEof:
      discard

  InputEditor* = ref object
    lines*: seq[string]
    cursorLine*: int
    cursorCol*: int        # UTF-8 byte offset within lines[cursorLine]
    pastes*: Table[int, string]
    pasteCounter*: int
    undoStack: seq[EditorSnapshot]
    killRing*: seq[string]
    history*: seq[string]
    historyFile*: string
    historyIndex*: int     # history.len means editing live draft
    draftBeforeHistory: string
    commands*: seq[SlashCommandDef]
    modelItems*: seq[AutocompleteItem]
    workspaceRoot*: string
    cachedFiles: seq[tuple[relPath: string, isDir: bool]]
    filesCacheValid: bool
    acKind*: AutocompleteKind
    acItems*: seq[AutocompleteItem]
    acIndex*: int
    acTokenStart*: int     # Byte offset on cursorLine where completed token begins
    acMovedSelection*: bool

# UTF-8 & word boundary helpers

proc nextUtf8Index*(s: string, byteIdx: int): int =
  ## Return next UTF-8 codepoint boundary after byteIdx.
  if byteIdx >= s.len:
    return s.len
  let step = runeLenAt(s, byteIdx)
  min(s.len, byteIdx + max(1, step))

proc prevUtf8Index*(s: string, byteIdx: int): int =
  ## Return previous UTF-8 codepoint boundary before byteIdx.
  if byteIdx <= 0:
    return 0
  var p = min(byteIdx, s.len) - 1
  while p > 0 and (uint8(s[p]) and 0xC0'u8) == 0x80'u8:
    dec p
  p

proc isWordRune(r: Rune): bool =
  let cp = int32(r)
  if cp < 128:
    let c = char(cp)
    return c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}
  not (r == Rune(ord(' '))) and runeDisplayWidth(r) > 0

proc stepWordLeft*(s: string, byteIdx: int): int =
  ## Move backward over whitespace/punctuation and then over one word or CJK run.
  var p = clamp(byteIdx, 0, s.len)
  while p > 0:
    let prev = prevUtf8Index(s, p)
    let r = runeAt(s, prev)
    if isWordRune(r):
      break
    p = prev
  while p > 0:
    let prev = prevUtf8Index(s, p)
    let r = runeAt(s, prev)
    if not isWordRune(r):
      break
    p = prev
  p

proc stepWordRight*(s: string, byteIdx: int): int =
  ## Move forward over non-word characters and then to the end of the next word.
  var p = clamp(byteIdx, 0, s.len)
  while p < s.len:
    let r = runeAt(s, p)
    if isWordRune(r):
      break
    p = nextUtf8Index(s, p)
  while p < s.len:
    let r = runeAt(s, p)
    if not isWordRune(r):
      break
    p = nextUtf8Index(s, p)
  p

proc colVisualOffset(line: string, byteCol: int): int =
  let clamped = clamp(byteCol, 0, line.len)
  if clamped == 0: 0
  else: visibleWidth(line[0 ..< clamped])

proc byteColForVisualOffset(line: string, targetVis: int): int =
  var used = 0
  var i = 0
  while i < line.len:
    let prev = i
    var r: Rune
    fastRuneAt(line, i, r, doInc = true)
    let rw = runeDisplayWidth(r)
    if used + rw > targetVis:
      return prev
    used += rw
  line.len

# Paste marker helpers (`[paste #1 +12 lines]` / `[paste #2 320 chars]`)

proc parsePasteMarkerId(token: string): int =
  if not token.startsWith("[paste #") or not token.endsWith("]"):
    return -1
  var i = 8
  var numStr = ""
  while i < token.len and token[i] in {'0'..'9'}:
    numStr.add(token[i])
    inc i
  if numStr.len == 0:
    return -1
  if i < token.len and token[i] notin [' ', ']']:
    return -1
  try: parseInt(numStr) except ValueError: -1

proc findPasteMarkerEndingAt(line: string, endCol: int, pastes: Table[int, string]): int =
  ## If a valid `[paste #N ...]` marker ends right at endCol, return its start byte index; else -1.
  if endCol <= 0 or endCol > line.len or line[endCol - 1] != ']':
    return -1
  let startPos = line.rfind("[paste #", last = endCol - 1)
  if startPos < 0:
    return -1
  let candidate = line[startPos ..< endCol]
  let pid = parsePasteMarkerId(candidate)
  if pid > 0 and pastes.hasKey(pid):
    return startPos
  -1

proc expandPasteMarkers*(text: string, pastes: Table[int, string]): string =
  ## Replace all valid `[paste #N ...]` placeholders with their stored pasted contents.
  if pastes.len == 0 or "[paste #" notin text:
    return text
  result = newStringOfCap(text.len + 256)
  var i = 0
  while i < text.len:
    if text[i] == '[' and i + 8 < text.len and text.continuesWith("[paste #", i):
      let closeIdx = text.find(']', i + 8)
      if closeIdx > i:
        let tok = text[i .. closeIdx]
        let pid = parsePasteMarkerId(tok)
        if pid > 0 and pastes.hasKey(pid):
          result.add(pastes[pid])
          i = closeIdx + 1
          continue
    result.add(text[i])
    inc i

# Persistent history helpers (`~/.pi/agent/ni_history.jsonl`)

proc loadEditorHistory*(historyFile: string): seq[string] =
  ## Load saved prompt history entries from JSONL file.
  if historyFile.len == 0 or not fileExists(historyFile):
    return @[]
  try:
    for line in readFile(historyFile).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      let j = try: parseJson(trimmed) except CatchableError: nil
      if not j.isNil and j.kind == JObject and j.hasKey("text") and j["text"].kind == JString:
        let entry = j["text"].getStr()
        if entry.len > 0:
          result.add(entry)
    if result.len > MaxHistoryEntries:
      result = result[result.len - MaxHistoryEntries .. ^1]
  except CatchableError:
    discard

proc appendEditorHistory*(ed: InputEditor, promptText: string) =
  ## Record a non-empty prompt into in-memory and on-disk history, deduplicating consecutive identical entries.
  let clean = promptText.strip()
  if clean.len == 0:
    return
  if ed.history.len > 0 and ed.history[^1] == promptText:
    ed.historyIndex = ed.history.len
    return
  ed.history.add(promptText)
  if ed.history.len > MaxHistoryEntries:
    ed.history.delete(0)
  ed.historyIndex = ed.history.len
  if ed.historyFile.len > 0:
    try:
      createDir(parentDir(ed.historyFile))
      var outLines: seq[string] = @[]
      for item in ed.history:
        outLines.add($(%*{ "text": item }))
      writeFile(ed.historyFile, outLines.join("\n") & "\n")
    except CatchableError:
      discard

# Editor initialization & state management

proc newInputEditor*(
  workspaceRoot = "",
  historyFile = "",
  commands: seq[SlashCommandDef] = @[],
  modelItems: seq[AutocompleteItem] = @[]
): InputEditor =
  ## Create a new multi-line TUI input editor instance.
  let hist = loadEditorHistory(historyFile)
  InputEditor(
    lines: @[""],
    cursorLine: 0,
    cursorCol: 0,
    pastes: initTable[int, string](),
    pasteCounter: 0,
    undoStack: @[],
    killRing: @[],
    history: hist,
    historyFile: historyFile,
    historyIndex: hist.len,
    draftBeforeHistory: "",
    commands: commands,
    modelItems: modelItems,
    workspaceRoot: workspaceRoot,
    cachedFiles: @[],
    filesCacheValid: false,
    acKind: ackNone,
    acItems: @[],
    acIndex: 0,
    acTokenStart: 0,
    acMovedSelection: false
  )

proc currentText*(ed: InputEditor): string =
  ## Return raw editor buffer joined by `\n`.
  ed.lines.join("\n")

proc expandedText*(ed: InputEditor): string =
  ## Return editor buffer with any `[paste #N ...]` chips expanded to full text.
  expandPasteMarkers(ed.currentText(), ed.pastes)

proc setText*(ed: InputEditor, text: string) =
  ## Replace editor buffer with text and place cursor at the end.
  let norm = text.replace("\r\n", "\n").replace('\r', '\n')
  ed.lines = if norm.len == 0: @[""] else: norm.split('\n')
  if ed.lines.len == 0:
    ed.lines = @[""]
  ed.cursorLine = ed.lines.high
  ed.cursorCol = ed.lines[ed.cursorLine].len
  ed.acKind = ackNone
  ed.acItems.setLen(0)

proc resetBuffer*(ed: InputEditor) =
  ## Clear lines, paste table, undo stack, and autocomplete state for the next prompt turn.
  ed.lines = @[""]
  ed.cursorLine = 0
  ed.cursorCol = 0
  ed.pastes.clear()
  ed.pasteCounter = 0
  ed.undoStack.setLen(0)
  ed.historyIndex = ed.history.len
  ed.draftBeforeHistory = ""
  ed.acKind = ackNone
  ed.acItems.setLen(0)
  ed.acIndex = 0
  ed.acMovedSelection = false

proc invalidateFileCache*(ed: InputEditor) =
  ## Mark workspace `@file` completion cache stale so next `@` query rescans.
  ed.filesCacheValid = false

proc saveUndoSnapshot(ed: InputEditor) =
  var pastesCopy = initTable[int, string]()
  for k, v in ed.pastes.pairs:
    pastesCopy[k] = v
  let snap = EditorSnapshot(
    lines: ed.lines,
    cursorLine: ed.cursorLine,
    cursorCol: ed.cursorCol,
    pastes: pastesCopy,
    pasteCounter: ed.pasteCounter
  )
  if ed.undoStack.len >= MaxUndoSnapshots:
    ed.undoStack.delete(0)
  ed.undoStack.add(snap)

proc undoLastEdit*(ed: InputEditor): bool =
  if ed.undoStack.len == 0:
    return false
  let snap = ed.undoStack.pop()
  ed.lines = snap.lines
  ed.cursorLine = clamp(snap.cursorLine, 0, ed.lines.high)
  ed.cursorCol = clamp(snap.cursorCol, 0, ed.lines[ed.cursorLine].len)
  ed.pastes = snap.pastes
  ed.pasteCounter = snap.pasteCounter
  true

proc pushKill(ed: InputEditor, killed: string) =
  if killed.len == 0:
    return
  ed.killRing.add(killed)
  if ed.killRing.len > 32:
    ed.killRing.delete(0)

# Fuzzy scoring & `/command` + `@file` autocomplete

proc fuzzyScore*(query, candidate: string): int =
  ## Score query against candidate (>0 means match; higher is better).
  if query.len == 0:
    return 10
  let q = query.toLowerAscii()
  let c = candidate.toLowerAscii()
  if c == q:
    return 1000
  if c.startsWith(q):
    return 800 - min(200, c.len - q.len)
  let base = extractFilename(c.strip(chars = {'/'}, leading = false, trailing = true))
  if base.startsWith(q):
    return 700 - min(150, c.len)
  let subIdx = c.find(q)
  if subIdx >= 0:
    return 500 - min(200, subIdx * 4 + (c.len - q.len))

  # Subsequence match
  var qi = 0
  var bonus = 0
  var prevMatch = -2
  for ci in 0 ..< c.len:
    if qi < q.len and c[ci] == q[qi]:
      if ci == prevMatch + 1:
        bonus += 12
      if ci == 0 or c[ci - 1] in {'/', '_', '-', '.'}:
        bonus += 15
      prevMatch = ci
      inc qi
  if qi == q.len:
    return max(1, 200 + bonus - min(150, c.len))
  0

proc ensureWorkspaceFilesCached(ed: InputEditor) =
  if ed.filesCacheValid or ed.workspaceRoot.len == 0 or not dirExists(ed.workspaceRoot):
    return
  ed.cachedFiles.setLen(0)
  const skipDirs = [".git", "node_modules", ".hg", ".svn", "nimcache", "dist", "target", ".next"]
  const maxIndexed = 4000
  var stack: seq[string] = @[ed.workspaceRoot]
  while stack.len > 0 and ed.cachedFiles.len < maxIndexed:
    let cur = stack.pop()
    var subDirs: seq[string] = @[]
    var entries: seq[tuple[relPath: string, isDir: bool]] = @[]
    try:
      for kind, full in walkDir(cur):
        let name = extractFilename(full)
        if kind in {pcDir, pcLinkToDir}:
          if name in skipDirs:
            continue
          let rel = relativePath(full, ed.workspaceRoot).replace('\\', '/') & "/"
          entries.add((rel, true))
          subDirs.add(full)
        elif kind in {pcFile, pcLinkToFile}:
          let rel = relativePath(full, ed.workspaceRoot).replace('\\', '/')
          entries.add((rel, false))
    except CatchableError:
      continue
    entries.sort(proc(a, b: tuple[relPath: string, isDir: bool]): int = cmpIgnoreCase(a.relPath, b.relPath))
    for item in entries:
      ed.cachedFiles.add(item)
      if ed.cachedFiles.len >= maxIndexed:
        break
    subDirs.sort(proc(a, b: string): int = cmpIgnoreCase(b, a))
    for d in subDirs:
      stack.add(d)
  ed.filesCacheValid = true

proc refreshAutocomplete*(ed: InputEditor) =
  ## Recompute `/command` or `@file` autocomplete candidates for current cursor position.
  ed.acKind = ackNone
  ed.acItems.setLen(0)
  ed.acIndex = 0
  ed.acMovedSelection = false

  let line = ed.lines[ed.cursorLine]
  let uptoCursor = line[0 ..< clamp(ed.cursorCol, 0, line.len)]

  # 1. Slash command completion at start of line 0 (`/...` with no space yet)
  if ed.cursorLine == 0 and uptoCursor.startsWith("/") and ' ' notin uptoCursor and '\t' notin uptoCursor:
    let query = uptoCursor[1 .. ^1]
    var matches: seq[AutocompleteItem] = @[]
    for cmd in ed.commands:
      let sc = fuzzyScore(query, cmd.name)
      if sc > 0:
        let disp = "/" & cmd.name & (if cmd.argumentHint.len > 0: " " & cmd.argumentHint else: "")
        let ins = "/" & cmd.name & (if cmd.argumentHint.len > 0: " " else: "")
        matches.add(AutocompleteItem(
          display: disp,
          insertText: ins,
          description: cmd.description,
          isDirectory: false,
          score: sc
        ))
    matches.sort(proc(a, b: AutocompleteItem): int =
      let c = cmp(b.score, a.score)
      if c != 0: c else: cmp(a.display, b.display)
    )
    if matches.len > 0:
      ed.acKind = ackSlash
      ed.acItems = matches[0 ..< min(24, matches.len)]
      ed.acTokenStart = 0
    return

  # 1b. `/model <query>` inline model argument completion (matching Pi's modelCommand.getArgumentCompletions)
  if ed.cursorLine == 0 and uptoCursor.toLowerAscii().startsWith("/model ") and ed.modelItems.len > 0:
    let argQuery = uptoCursor[7 .. ^1].strip()
    var matches: seq[AutocompleteItem] = @[]
    for mitem in ed.modelItems:
      let sc = fuzzyScore(argQuery, mitem.display & " " & mitem.description)
      if sc > 0:
        var copyItem = mitem
        copyItem.score = sc
        matches.add(copyItem)
    matches.sort(proc(a, b: AutocompleteItem): int =
      let c = cmp(b.score, a.score)
      if c != 0: c else: cmp(a.display, b.display)
    )
    if matches.len > 0:
      ed.acKind = ackModelArg
      ed.acItems = matches[0 ..< min(24, matches.len)]
      ed.acTokenStart = 7
    return

  # 2. `@filepath` completion when current token starts with `@` at start-of-line or after whitespace/open-paren
  var atPos = -1
  for i in countdown(uptoCursor.high, 0):
    let ch = uptoCursor[i]
    if ch in {' ', '\t'}:
      break
    if ch == '@':
      if i == 0 or uptoCursor[i - 1] in {' ', '\t', '(', '[', '"', '\''}:
        atPos = i
      break

  if atPos >= 0:
    let rawQuery = uptoCursor[atPos + 1 .. ^1].strip(chars = {'"'}, leading = true, trailing = false)
    ed.ensureWorkspaceFilesCached()
    var matches: seq[AutocompleteItem] = @[]
    for item in ed.cachedFiles:
      let sc = fuzzyScore(rawQuery, item.relPath)
      if sc > 0:
        let needsQuotes = ' ' in item.relPath
        let formatted = if needsQuotes: "@\"" & item.relPath & "\""
                        elif item.isDir: "@" & item.relPath
                        else: "@" & item.relPath & " "
        matches.add(AutocompleteItem(
          display: "@" & item.relPath,
          insertText: formatted,
          description: (if item.isDir: "dir" else: "file"),
          isDirectory: item.isDir,
          score: sc
        ))
    matches.sort(proc(a, b: AutocompleteItem): int =
      let c = cmp(b.score, a.score)
      if c != 0: c else: cmp(a.display.len, b.display.len)
    )
    if matches.len > 0:
      ed.acKind = ackFile
      ed.acItems = matches[0 ..< min(24, matches.len)]
      ed.acTokenStart = atPos

proc applySelectedAutocomplete*(ed: InputEditor): bool =
  ## Replace the active `/command` or `@file` token with the highlighted suggestion.
  if ed.acKind == ackNone or ed.acItems.len == 0:
    return false
  ed.saveUndoSnapshot()
  let chosen = ed.acItems[clamp(ed.acIndex, 0, ed.acItems.high)]
  let line = ed.lines[ed.cursorLine]
  let prefix = if ed.acTokenStart > 0: line[0 ..< ed.acTokenStart] else: ""
  let suffix = if ed.cursorCol < line.len: line[ed.cursorCol .. ^1] else: ""
  ed.lines[ed.cursorLine] = prefix & chosen.insertText & suffix
  ed.cursorCol = prefix.len + chosen.insertText.len
  if chosen.isDirectory:
    ed.refreshAutocomplete()
  else:
    ed.acKind = ackNone
    ed.acItems.setLen(0)
    ed.acMovedSelection = false
  true

# Text insertion & paste handling

proc insertTextAtCursor*(ed: InputEditor, text: string, recordUndo = true) =
  ## Insert single-line or multi-line UTF-8 text at the current cursor position.
  if text.len == 0:
    return
  if recordUndo:
    ed.saveUndoSnapshot()
  let norm = text.replace("\r\n", "\n").replace('\r', '\n')
  let curLine = ed.lines[ed.cursorLine]
  let before = if ed.cursorCol > 0: curLine[0 ..< ed.cursorCol] else: ""
  let after = if ed.cursorCol < curLine.len: curLine[ed.cursorCol .. ^1] else: ""

  if '\n' notin norm:
    ed.lines[ed.cursorLine] = before & norm & after
    ed.cursorCol = before.len + norm.len
  else:
    let parts = norm.split('\n')
    var newLines: seq[string] = @[]
    for i in 0 ..< ed.cursorLine:
      newLines.add(ed.lines[i])
    newLines.add(before & parts[0])
    for i in 1 ..< parts.high:
      newLines.add(parts[i])
    let lastPart = parts[^1]
    newLines.add(lastPart & after)
    for i in (ed.cursorLine + 1) ..< ed.lines.len:
      newLines.add(ed.lines[i])
    ed.lines = newLines
    ed.cursorLine += parts.high
    ed.cursorCol = lastPart.len
  ed.refreshAutocomplete()

proc pasteIntoEditor*(ed: InputEditor, pasted: string) =
  ## Insert pasted text; collapse large multi-line pastes into an atomic `[paste #N +M lines]` marker.
  if pasted.len == 0:
    return
  let norm = pasted.replace("\r\n", "\n").replace('\r', '\n')
  let lineCount = norm.count('\n') + 1
  if lineCount >= PasteCollapseMinLines or norm.len >= PasteCollapseMinChars:
    ed.saveUndoSnapshot()
    inc ed.pasteCounter
    let pid = ed.pasteCounter
    ed.pastes[pid] = norm
    let marker = if lineCount >= PasteCollapseMinLines:
      "[paste #" & $pid & " +" & $lineCount & " lines]"
    else:
      "[paste #" & $pid & " " & $norm.len & " chars]"
    ed.insertTextAtCursor(marker, recordUndo = false)
  else:
    ed.insertTextAtCursor(norm, recordUndo = true)

proc openExternalEditor(ed: InputEditor): bool =
  ## Open `$VISUAL` / `$EDITOR` on the current prompt text (`Ctrl+G`).
  var editorCmd = getEnv("VISUAL").strip()
  if editorCmd.len == 0:
    editorCmd = getEnv("EDITOR").strip()
  if editorCmd.len == 0:
    editorCmd = when defined(windows): "notepad" else: "vi"

  let tmpPath = getTempDir() / ("ni_prompt_" & $getCurrentProcessId() & ".md")
  try:
    writeFile(tmpPath, ed.expandedText())
    disableBracketedPaste()
    if colorsActive():
      stdout.write("\x1b[?25h")
      stdout.flushFile()
    let exitCode = execCmd(editorCmd & " " & quoteShell(tmpPath))
    enableBracketedPaste()
    if exitCode == 0 and fileExists(tmpPath):
      let updated = readFile(tmpPath).strip(chars = {'\r', '\n'}, leading = false, trailing = true)
      ed.saveUndoSnapshot()
      ed.pastes.clear()
      ed.setText(updated)
      try: removeFile(tmpPath) except CatchableError: discard
      return true
  except CatchableError:
    discard
  try: removeFile(tmpPath) except CatchableError: discard
  false

# Deterministic single-key dispatcher (directly unit-testable without a TTY!)

proc handleKeyEvent*(ed: InputEditor, ev: KeyEvent, allowExternalEditor = false): Option[EditorOutcome] =
  ## Process one KeyEvent in the editor; return `some(EditorOutcome)` when submitting/cancelling/EOF, or `none` to continue editing.
  case ev.kind
  of kkEof:
    return some(EditorOutcome(kind: eokEof))

  of kkCtrlC:
    if ed.acKind != ackNone:
      ed.acKind = ackNone
      ed.acItems.setLen(0)
      return none(EditorOutcome)
    if ed.currentText().len > 0:
      ed.resetBuffer()
      return none(EditorOutcome)
    return some(EditorOutcome(kind: eokCancel))

  of kkCtrlD:
    if ed.currentText().len == 0:
      return some(EditorOutcome(kind: eokEof))
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol < line.len:
      ed.saveUndoSnapshot()
      let nxt = nextUtf8Index(line, ed.cursorCol)
      ed.lines[ed.cursorLine] = line[0 ..< ed.cursorCol] & line[nxt .. ^1]
      ed.refreshAutocomplete()
    elif ed.cursorLine < ed.lines.high:
      ed.saveUndoSnapshot()
      ed.lines[ed.cursorLine].add(ed.lines[ed.cursorLine + 1])
      ed.lines.delete(ed.cursorLine + 1)
      ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkEscape:
    if ed.acKind != ackNone:
      ed.acKind = ackNone
      ed.acItems.setLen(0)
      ed.acMovedSelection = false
    return none(EditorOutcome)

  of kkTab:
    if ed.acKind == ackNone:
      ed.refreshAutocomplete()
    if ed.acKind != ackNone and ed.acItems.len > 0:
      discard ed.applySelectedAutocomplete()
    return none(EditorOutcome)

  of kkShiftTab:
    if ed.acKind != ackNone and ed.acItems.len > 0:
      ed.acIndex = if ed.acIndex == 0: ed.acItems.high else: ed.acIndex - 1
      ed.acMovedSelection = true
    return none(EditorOutcome)

  of kkNewline, kkAltEnter:
    ed.insertTextAtCursor("\n")
    return none(EditorOutcome)

  of kkEnter:
    # Trailing backslash continuation (`\` + Enter inserts a newline)
    let curLine = ed.lines[ed.cursorLine]
    if ed.cursorCol == curLine.len and curLine.endsWith("\\"):
      ed.saveUndoSnapshot()
      ed.lines[ed.cursorLine] = curLine[0 ..< curLine.high]
      ed.cursorCol = ed.lines[ed.cursorLine].len
      ed.insertTextAtCursor("\n", recordUndo = false)
      return none(EditorOutcome)

    # If user navigated the autocomplete menu with arrows, Enter applies the highlighted item first
    if ed.acKind != ackNone and ed.acItems.len > 0 and ed.acMovedSelection:
      discard ed.applySelectedAutocomplete()
      return none(EditorOutcome)

    let disp = ed.currentText()
    let full = ed.expandedText()
    ed.appendEditorHistory(full)
    ed.resetBuffer()
    return some(EditorOutcome(kind: eokSubmit, text: full, displayText: disp))

  of kkUp, kkCtrlP:
    if ed.acKind != ackNone and ed.acItems.len > 0 and ev.kind == kkUp:
      ed.acIndex = if ed.acIndex == 0: ed.acItems.high else: ed.acIndex - 1
      ed.acMovedSelection = true
      return none(EditorOutcome)
    if ed.cursorLine > 0 and ev.kind == kkUp:
      let vis = colVisualOffset(ed.lines[ed.cursorLine], ed.cursorCol)
      dec ed.cursorLine
      ed.cursorCol = byteColForVisualOffset(ed.lines[ed.cursorLine], vis)
      ed.refreshAutocomplete()
      return none(EditorOutcome)
    if ed.history.len > 0 and ed.historyIndex > 0:
      if ed.historyIndex == ed.history.len:
        ed.draftBeforeHistory = ed.expandedText()
      dec ed.historyIndex
      ed.pastes.clear()
      ed.setText(ed.history[ed.historyIndex])
    return none(EditorOutcome)

  of kkDown, kkCtrlN:
    if ed.acKind != ackNone and ed.acItems.len > 0 and ev.kind == kkDown:
      ed.acIndex = (ed.acIndex + 1) mod ed.acItems.len
      ed.acMovedSelection = true
      return none(EditorOutcome)
    if ed.cursorLine < ed.lines.high and ev.kind == kkDown:
      let vis = colVisualOffset(ed.lines[ed.cursorLine], ed.cursorCol)
      inc ed.cursorLine
      ed.cursorCol = byteColForVisualOffset(ed.lines[ed.cursorLine], vis)
      ed.refreshAutocomplete()
      return none(EditorOutcome)
    if ed.historyIndex < ed.history.len:
      inc ed.historyIndex
      ed.pastes.clear()
      if ed.historyIndex == ed.history.len:
        ed.setText(ed.draftBeforeHistory)
      else:
        ed.setText(ed.history[ed.historyIndex])
    return none(EditorOutcome)

  of kkLeft:
    if ed.cursorCol > 0:
      let markerStart = findPasteMarkerEndingAt(ed.lines[ed.cursorLine], ed.cursorCol, ed.pastes)
      if markerStart >= 0:
        ed.cursorCol = markerStart
      else:
        ed.cursorCol = prevUtf8Index(ed.lines[ed.cursorLine], ed.cursorCol)
    elif ed.cursorLine > 0:
      dec ed.cursorLine
      ed.cursorCol = ed.lines[ed.cursorLine].len
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkRight:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol < line.len:
      if line.continuesWith("[paste #", ed.cursorCol):
        let closeIdx = line.find(']', ed.cursorCol + 8)
        if closeIdx > ed.cursorCol and parsePasteMarkerId(line[ed.cursorCol .. closeIdx]) in ed.pastes:
          ed.cursorCol = closeIdx + 1
          ed.refreshAutocomplete()
          return none(EditorOutcome)
      ed.cursorCol = nextUtf8Index(line, ed.cursorCol)
    elif ed.cursorLine < ed.lines.high:
      inc ed.cursorLine
      ed.cursorCol = 0
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkWordLeft:
    if ed.cursorCol > 0:
      ed.cursorCol = stepWordLeft(ed.lines[ed.cursorLine], ed.cursorCol)
    elif ed.cursorLine > 0:
      dec ed.cursorLine
      ed.cursorCol = ed.lines[ed.cursorLine].len
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkWordRight:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol < line.len:
      ed.cursorCol = stepWordRight(line, ed.cursorCol)
    elif ed.cursorLine < ed.lines.high:
      inc ed.cursorLine
      ed.cursorCol = 0
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkHome, kkCtrlA:
    ed.cursorCol = 0
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkEnd, kkCtrlE:
    ed.cursorCol = ed.lines[ed.cursorLine].len
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkBackspace:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol > 0:
      ed.saveUndoSnapshot()
      let markerStart = findPasteMarkerEndingAt(line, ed.cursorCol, ed.pastes)
      let cutFrom = if markerStart >= 0: markerStart else: prevUtf8Index(line, ed.cursorCol)
      ed.lines[ed.cursorLine] = line[0 ..< cutFrom] & line[ed.cursorCol .. ^1]
      ed.cursorCol = cutFrom
      ed.refreshAutocomplete()
    elif ed.cursorLine > 0:
      ed.saveUndoSnapshot()
      let prevLen = ed.lines[ed.cursorLine - 1].len
      ed.lines[ed.cursorLine - 1].add(line)
      ed.lines.delete(ed.cursorLine)
      dec ed.cursorLine
      ed.cursorCol = prevLen
      ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkDelete:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol < line.len:
      ed.saveUndoSnapshot()
      let nxt = nextUtf8Index(line, ed.cursorCol)
      ed.lines[ed.cursorLine] = line[0 ..< ed.cursorCol] & line[nxt .. ^1]
      ed.refreshAutocomplete()
    elif ed.cursorLine < ed.lines.high:
      ed.saveUndoSnapshot()
      ed.lines[ed.cursorLine].add(ed.lines[ed.cursorLine + 1])
      ed.lines.delete(ed.cursorLine + 1)
      ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkCtrlU:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol > 0:
      ed.saveUndoSnapshot()
      ed.pushKill(line[0 ..< ed.cursorCol])
      ed.lines[ed.cursorLine] = line[ed.cursorCol .. ^1]
      ed.cursorCol = 0
      ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkCtrlK:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol < line.len:
      ed.saveUndoSnapshot()
      ed.pushKill(line[ed.cursorCol .. ^1])
      ed.lines[ed.cursorLine] = line[0 ..< ed.cursorCol]
      ed.refreshAutocomplete()
    elif ed.cursorLine < ed.lines.high:
      ed.saveUndoSnapshot()
      ed.pushKill("\n")
      ed.lines[ed.cursorLine].add(ed.lines[ed.cursorLine + 1])
      ed.lines.delete(ed.cursorLine + 1)
      ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkCtrlW:
    let line = ed.lines[ed.cursorLine]
    if ed.cursorCol > 0:
      ed.saveUndoSnapshot()
      let target = stepWordLeft(line, ed.cursorCol)
      ed.pushKill(line[target ..< ed.cursorCol])
      ed.lines[ed.cursorLine] = line[0 ..< target] & line[ed.cursorCol .. ^1]
      ed.cursorCol = target
      ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkCtrlY:
    if ed.killRing.len > 0:
      ed.insertTextAtCursor(ed.killRing[^1])
    return none(EditorOutcome)

  of kkUndo:
    discard ed.undoLastEdit()
    ed.refreshAutocomplete()
    return none(EditorOutcome)

  of kkCtrlG:
    if allowExternalEditor:
      discard ed.openExternalEditor()
    return none(EditorOutcome)

  of kkCtrlL:
    if colorsActive() and isInteractiveTerminal():
      stdout.write("\x1b[2J\x1b[H")
      stdout.flushFile()
    return none(EditorOutcome)

  of kkPaste:
    ed.pasteIntoEditor(ev.text)
    return none(EditorOutcome)

  of kkSpace, kkChar:
    let ins = if ev.text.len > 0: ev.text elif ev.ch != '\0': $ev.ch else: ""
    if ins.len > 0:
      ed.insertTextAtCursor(ins)
    return none(EditorOutcome)

  else:
    return none(EditorOutcome)

# Visual layout & rendering of the TUI input box, cursor, status bar, and autocomplete popup

proc formatEditorLineWithCursor(line: string, cursorCol, width: int): tuple[rows: seq[string], cursorRow: int] =
  ## Wrap one logical input line into terminal-width visual rows, rendering an inverse-video cursor cell on the active row.
  result.cursorRow = -1
  var curRow = ""
  var curW = 0
  var i = 0

  while i < line.len:
    let atCursor = (i == cursorCol)
    let sb = i
    var r: Rune
    fastRuneAt(line, i, r, doInc = true)
    let glyph = if r == Rune(ord('\t')): "  " else: line[sb ..< i]
    let rw = runeDisplayWidth(r)
    if curW + rw > width and curW > 0:
      result.rows.add(curRow)
      curRow = ""
      curW = 0
    if atCursor:
      result.cursorRow = result.rows.len
      if colorsActive():
        curRow.add("\x1b[7m" & glyph & "\x1b[27m")
      else:
        curRow.add("▏" & glyph)
    else:
      curRow.add(glyph)
    curW += rw

  if cursorCol == line.len:
    if curW + 1 > width and curW > 0:
      result.rows.add(curRow)
      curRow = ""
    result.cursorRow = result.rows.len
    if colorsActive():
      curRow.add("\x1b[7m \x1b[27m")
    else:
      curRow.add("▏")

  result.rows.add(curRow)

proc shortenPathForStatus(p: string, maxCols = 28): string =
  let home = normalizedPath(getHomeDir())
  let norm = normalizedPath(p)
  var disp = if home.len > 0 and norm.startsWith(home):
    "~" & norm[home.len .. ^1]
  else:
    norm
  disp = disp.replace('\\', '/')
  if visibleWidth(disp) <= maxCols:
    return disp
  let parts = disp.split('/')
  if parts.len >= 2:
    let tail2 = "…/" & parts[^2] & "/" & parts[^1]
    if visibleWidth(tail2) <= maxCols:
      return tail2
  "…/" & extractFilename(norm)

proc formatCompactCount*(n: int): string =
  ## Format token counts compactly like Pi's FooterComponent (`1.2k`, `45k`, `1.0M`).
  if n < 1000:
    $n
  elif n < 10_000:
    formatFloat(n.float / 1000.0, ffDecimal, 1) & "k"
  elif n < 1_000_000:
    $(n div 1000) & "k"
  else:
    formatFloat(n.float / 1_000_000.0, ffDecimal, 1) & "M"

proc renderTopBorderWithStatus(cols: int, workingStatus: string): string =
  if workingStatus.len == 0:
    return styleDim("─".repeat(cols))
  let clipped = truncateVisible(workingStatus, max(8, cols - 6))
  let used = visibleWidth(clipped)
  let tailDashes = max(1, cols - 4 - used)
  styleDim("── ") & clipped & styleDim(" " & "─".repeat(tailDashes))

proc renderEditorFrame*(ed: InputEditor, status: EditorStatusInfo, termCols: int, maxRows = high(int)): seq[string] =
  ## Render the Pi/Codex-style docked input box: queued messages, status-embedded top border, multi-line input, bottom border, two-column footer, and autocomplete popup.
  let cols = clamp(termCols, 20, 300)
  # Reserve the two borders, footer, and one visible input row before showing queues or suggestions.
  let spareRows = max(4, maxRows) - 4
  let queueRows = min(status.queuedMessages.len, spareRows div 3)
  let totalSuggestions = if ed.acKind != ackNone: ed.acItems.len else: 0
  let menuRows = min(totalSuggestions, min(AutocompleteMaxVisible + 1, (spareRows - queueRows + 1) div 2))
  let inputRows = spareRows + 1 - queueRows - menuRows

  for i in 0 ..< queueRows:
    if i == queueRows - 1 and queueRows < status.queuedMessages.len:
      let summary = "  ↳ " & $(status.queuedMessages.len - i) & " queued messages"
      result.add(styleYellow(truncateVisible(summary, cols)))
    else:
      let oneLine = status.queuedMessages[i].replace("\n", " ").strip()
      result.add("  " & styleYellow("↳ Queued: ") & styleDim(truncateVisible(oneLine, cols - 12)))

  result.add(renderTopBorderWithStatus(cols, status.workingStatus))

  let prefixFirst = styleBold(styleCyan("❯ "))
  let prefixCont = styleDim("· ")
  let contentWidth = max(10, cols - 3)

  let isEmpty = ed.lines.len == 1 and ed.lines[0].len == 0
  if isEmpty:
    let hintStr = if status.workingStatus.len > 0:
      "Type a message to queue · Esc to interrupt"
    else:
      "Ask anything · /commands · @file · !shell · Ctrl+J newline"
    let placeholder = styleDim(hintStr)
    let clippedHint = truncateVisible(placeholder, max(8, contentWidth - 2))
    let cursorBlock = if colorsActive(): "\x1b[7m \x1b[27m" else: "▏"
    result.add(prefixFirst & cursorBlock & " " & clippedHint)
  else:
    var wrappedInput: seq[string] = @[]
    var cursorRow = 0
    for lineIdx, line in ed.lines.pairs:
      let col = if lineIdx == ed.cursorLine: ed.cursorCol else: -1
      let (wrapped, lineCursor) = formatEditorLineWithCursor(line, col, contentWidth)
      if lineCursor >= 0:
        cursorRow = wrappedInput.len + lineCursor
      for wIdx, wLine in wrapped.pairs:
        let pfx = if lineIdx == 0 and wIdx == 0: prefixFirst else: prefixCont
        wrappedInput.add(pfx & wLine)

    # Only the visible rows can be erased on the next redraw.
    let firstRow = max(0, cursorRow - inputRows + 1)
    result.add(wrappedInput[firstRow ..< min(wrappedInput.len, firstRow + inputRows)])

  result.add(styleDim("─".repeat(cols)))

  # Two-column justified footer matching Pi's FooterComponent:
  # Left:  ~/workspace (branch) [• sessionName]
  # Right: ↑in ↓out [Rcache] [$cost] [ctx%/win] · model:thinking
  var leftStr = ""
  if status.cwd.len > 0:
    leftStr = shortenPathForStatus(status.cwd, max(16, cols div 3))
    if status.gitBranch.len > 0:
      leftStr.add(" (" & status.gitBranch & ")")
    if status.sessionName.len > 0:
      leftStr.add(" • " & truncateVisible(status.sessionName, 18))

  var statsParts: seq[string] = @[]
  if status.inputTokens > 0:
    statsParts.add("↑" & formatCompactCount(status.inputTokens))
  if status.outputTokens > 0:
    statsParts.add("↓" & formatCompactCount(status.outputTokens))
  if status.cacheReadTokens > 0:
    statsParts.add("R" & formatCompactCount(status.cacheReadTokens))
  if status.costUsd > 0.0 or status.isSubscription:
    let cstr = "$" & formatFloat(status.costUsd, ffDecimal, 3) & (if status.isSubscription: " (sub)" else: "")
    statsParts.add(cstr)
  if status.contextPct > 0:
    let ctxDisp = if status.contextWindow > 0:
      $status.contextPct & "%/" & formatCompactCount(status.contextWindow)
    else:
      $status.contextPct & "% ctx"
    if status.contextPct > 90:
      statsParts.add(styleRed(ctxDisp))
    elif status.contextPct > 70:
      statsParts.add(styleYellow(ctxDisp))
    else:
      statsParts.add(ctxDisp)

  let modelDisp = if status.modelLabel.len > 0:
    (if status.thinkingLabel.len > 0 and status.thinkingLabel != "off":
      status.modelLabel & ":" & status.thinkingLabel
    else:
      status.modelLabel)
  else:
    ""

  var rightStyled = ""
  if statsParts.len > 0 and modelDisp.len > 0:
    rightStyled = styleDim(statsParts.join(" ") & " · ") & styleCyan(modelDisp)
  elif modelDisp.len > 0:
    rightStyled = styleCyan(modelDisp)
  elif statsParts.len > 0:
    rightStyled = styleDim(statsParts.join(" "))

  let leftStyled = styleDim(leftStr)
  let leftW = visibleWidth(leftStyled)
  let rightW = visibleWidth(rightStyled)

  if leftW > 0 and rightW > 0 and leftW + 2 + rightW <= cols:
    result.add(leftStyled & spaces(cols - leftW - rightW) & rightStyled)
  elif rightW > 0 and rightW <= cols:
    let remLeft = cols - rightW - 2
    if remLeft >= 8 and leftW > 0:
      let lTrunc = truncateVisible(leftStyled, remLeft)
      let pad = max(1, cols - visibleWidth(lTrunc) - rightW)
      result.add(lTrunc & spaces(pad) & rightStyled)
    else:
      result.add(truncateVisible(rightStyled, cols))
  else:
    result.add(truncateVisible(leftStyled & "  " & rightStyled, cols))

  # Autocomplete popup list (if active)
  if menuRows > 0:
    let showCount = menuRows > 1 and (totalSuggestions > menuRows or menuRows > AutocompleteMaxVisible)
    let shown = menuRows - int(showCount)
    var startIdx = 0
    if ed.acIndex >= shown:
      startIdx = ed.acIndex - shown + 1

    var primaryWidth = 16
    for i in startIdx ..< startIdx + shown:
      primaryWidth = clamp(max(primaryWidth, visibleWidth(ed.acItems[i].display) + 2), 16, 36)
    primaryWidth = min(primaryWidth, cols - 4)

    for i in startIdx ..< startIdx + shown:
      let item = ed.acItems[i]
      let selected = (i == ed.acIndex)
      let marker = if selected: styleCyan("  ▸ ") else: "    "
      let col1Raw = padRightVisible(truncateVisible(item.display, primaryWidth - 1), primaryWidth)
      let col1 = if selected: styleBold(styleCyan(col1Raw)) else: col1Raw
      let descAvail = cols - 4 - primaryWidth
      let desc = if item.description.len > 0: styleDim(truncateVisible(item.description, descAvail)) else: ""
      result.add(marker & col1 & desc)

    if showCount:
      let hint = "    (" & $(ed.acIndex + 1) & "/" & $totalSuggestions & " — ↑/↓ select, Tab complete, Esc close)"
      result.add(styleDim(truncateVisible(hint, cols)))

# Interactive prompt read loop

proc readPromptInteractive*(ed: InputEditor, status: EditorStatusInfo): EditorOutcome =
  ## Run the live TUI editor loop on TTY, or read from stdin line-by-line when non-interactive.
  if not isInteractiveTerminal():
    var line = ""
    if not stdin.readLine(line):
      return EditorOutcome(kind: eokEof)
    var lines = @[line]
    while lines[^1].endsWith("\\"):
      lines[^1] = lines[^1][0 ..< lines[^1].high]
      var nxt = ""
      if not stdin.readLine(nxt):
        break
      lines.add(nxt)
    let joined = lines.join("\n")
    return EditorOutcome(kind: eokSubmit, text: joined, displayText: joined)

  var renderedCount = 0
  stdout.write("\n")
  if colorsActive():
    stdout.write("\x1b[?25l")
  enableBracketedPaste()

  defer:
    disableBracketedPaste()
    if colorsActive():
      stdout.write("\x1b[?25h")
      stdout.flushFile()

  while true:
    let (cols, rows) = terminalSize()
    let frame = renderEditorFrame(ed, status, cols, rows - 1)

    beginSyncOutput()
    clearRenderedLines(renderedCount)
    for line in frame:
      stdout.write(line & "\n")
    renderedCount = frame.len
    endSyncOutput()

    let ev = readRawKey()
    let outcomeOpt = ed.handleKeyEvent(ev, allowExternalEditor = true)
    if outcomeOpt.isSome:
      let outcome = outcomeOpt.get
      beginSyncOutput()
      clearRenderedLines(renderedCount)
      renderedCount = 0
      if outcome.kind == eokSubmit and outcome.displayText.strip().len > 0:
        let lines = outcome.displayText.split('\n')
        stdout.write(styleBold(styleCyan("❯ ")) & styleBold(lines[0]) & "\n")
        for i in 1 ..< lines.len:
          stdout.write(styleDim("· ") & lines[i] & "\n")
      endSyncOutput()
      return outcome
