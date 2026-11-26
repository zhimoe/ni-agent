# Cross-platform terminal I/O: ANSI/OSC8 styling, Unicode widths, raw keys, bracketed paste, and clipboard.

import std/[base64, options, os, osproc, streams, strutils, terminal, unicode]
when defined(windows):
  import std/[monotimes, times, winlean]
else:
  import std/[posix, termios]
import ./types

type
  KeyKind* = enum
    kkUp
    kkDown
    kkLeft
    kkRight
    kkHome
    kkEnd
    kkDelete
    kkPageUp
    kkPageDown
    kkScrollUp
    kkScrollDown
    kkMouseOther
    kkWordLeft
    kkWordRight
    kkEnter
    kkAltEnter
    kkNewline
    kkEscape
    kkSpace
    kkTab
    kkShiftTab
    kkBackspace
    kkCtrlA
    kkCtrlC
    kkCtrlD
    kkEof
    kkCtrlE
    kkCtrlG
    kkCtrlK
    kkCtrlL
    kkCtrlN
    kkCtrlP
    kkCtrlQ
    kkCtrlS
    kkCtrlU
    kkCtrlW
    kkCtrlY
    kkUndo
    kkPaste
    kkChar

  KeyEvent* = object
    kind*: KeyKind
    ch*: char
    text*: string

var colorsEnabled = true

when defined(windows):
  const
    CP_UTF8_ID = 65001'u32

  proc setConsoleOutputCPWin(wCodePageID: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleOutputCP".}
  proc setConsoleCPWin(wCodePageID: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleCP".}

proc initTerminal*() =
  ## Enable UTF-8 and ANSI Virtual Terminal sequences (including native Windows Terminal / Conhost).
  when defined(windows):
    discard setConsoleOutputCPWin(CP_UTF8_ID)
    discard setConsoleCPWin(CP_UTF8_ID)
    for hid in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
      let h = getStdHandle(hid)
      var mode: DWORD = 0
      if getConsoleMode(h, addr mode) != 0:
        discard setConsoleMode(h, mode or ENABLE_PROCESSED_OUTPUT or ENABLE_VIRTUAL_TERMINAL_PROCESSING)

  let noColor = getEnv("NO_COLOR").len > 0 or getEnv("TERM").toLowerAscii() == "dumb"
  colorsEnabled = (not noColor) and stdin.isatty() and stdout.isatty()

proc isInteractiveTerminal*(): bool =
  ## Return true when both stdin and stdout are attached to an interactive TTY.
  stdin.isatty() and stdout.isatty()

proc isStdoutTty*(): bool =
  ## Return true when stdout is attached to a TTY.
  stdout.isatty()

var fullScreenActive = false

proc supportsFullScreen*(): bool =
  ## Return true when the terminal can host the fixed-layout alternate screen (interactive, non-dumb).
  if not isInteractiveTerminal():
    return false
  let term = getEnv("TERM").toLowerAscii()
  term.len > 0 and term != "dumb"

proc fullScreenEnabled*(): bool =
  ## Return true while the alternate screen buffer is active.
  fullScreenActive

proc enterFullScreen*() =
  ## Enter the alternate screen buffer, hide the cursor, and capture wheel events for in-app scrolling.
  if fullScreenActive or not supportsFullScreen():
    return
  stdout.write("\x1b[?1049h\x1b[H\x1b[2J\x1b[?1000h\x1b[?1006h\x1b[?25l")
  stdout.flushFile()
  fullScreenActive = true

proc exitFullScreen*() =
  ## Leave the alternate screen buffer, release mouse capture, and restore the cursor.
  if not fullScreenActive:
    return
  stdout.write("\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l")
  stdout.flushFile()
  fullScreenActive = false

proc clearFullScreen*() =
  ## Erase the whole alternate screen and home the cursor (used before modal widgets).
  if fullScreenActive:
    stdout.write("\x1b[2J\x1b[H")
    stdout.flushFile()

proc colorsActive*(): bool =
  ## Return true when ANSI styling sequences should be emitted.
  colorsEnabled

proc setColorsEnabled*(enabled: bool) =
  ## Override ANSI color output state (used by CLI flags or deterministic rendering tests).
  colorsEnabled = enabled

proc terminalSize*(): tuple[cols: int, rows: int] =
  ## Query current terminal dimensions with safe fallbacks when stdout is not a TTY.
  var cols = 80
  var rows = 24
  try:
    let w = terminalWidth()
    if w > 0: cols = w
  except CatchableError:
    let envCols = getEnv("COLUMNS").strip()
    if envCols.len > 0:
      try: cols = parseInt(envCols) except ValueError: discard
  try:
    let h = terminalHeight()
    if h > 0: rows = h
  except CatchableError:
    let envRows = getEnv("LINES").strip()
    if envRows.len > 0:
      try: rows = parseInt(envRows) except ValueError: discard
  (clamp(cols, 20, 512), clamp(rows, 8, 256))

proc beginSyncOutput*() =
  ## Enter DEC mode 2026 synchronized terminal output to prevent redraw flicker.
  if stdout.isatty():
    stdout.write("\x1b[?2026h")

proc endSyncOutput*() =
  ## Exit DEC mode 2026 synchronized terminal output and flush stdout.
  if stdout.isatty():
    stdout.write("\x1b[?2026l")
  stdout.flushFile()

proc enableBracketedPaste*() =
  ## Enable xterm bracketed paste mode (`\x1b[200~` ... `\x1b[201~`).
  if stdout.isatty():
    stdout.write("\x1b[?2004h")
    stdout.flushFile()

proc disableBracketedPaste*() =
  ## Disable xterm bracketed paste mode cleanly before running child processes or exiting.
  if stdout.isatty():
    stdout.write("\x1b[?2004l")
    stdout.flushFile()

# ANSI & OSC 8 styling helpers (scrollback-native, zero mouse hijacking so terminal copy-on-select always works)

proc ansiWrap(code, text: string): string =
  if not colorsEnabled or text.len == 0: text
  else: "\x1b[" & code & "m" & text & "\x1b[0m"

proc styleDim*(s: string): string = ansiWrap("2", s)
proc styleBold*(s: string): string = ansiWrap("1", s)
proc styleItalic*(s: string): string = ansiWrap("3", s)
proc styleUnderline*(s: string): string = ansiWrap("4", s)
proc styleStrike*(s: string): string = ansiWrap("9", s)
proc styleRed*(s: string): string = ansiWrap("31", s)
proc styleGreen*(s: string): string = ansiWrap("32", s)
proc styleYellow*(s: string): string = ansiWrap("33", s)
proc styleBlue*(s: string): string = ansiWrap("34", s)
proc styleMagenta*(s: string): string = ansiWrap("35", s)
proc styleCyan*(s: string): string = ansiWrap("36", s)
proc styleGray*(s: string): string = ansiWrap("90", s)
proc styleRgb*(s: string, r, g, b: int): string =
  ## Wrap text in a 24-bit foreground color when ANSI styling is active.
  if not colorsEnabled or s.len == 0:
    return s
  "\x1b[38;2;" & $r & ";" & $g & ";" & $b & "m" & s & "\x1b[0m"
proc styleAnsi256*(s: string, index: int): string =
  ## Wrap text in an xterm-256 foreground color when ANSI styling is active.
  if not colorsEnabled or s.len == 0:
    return s
  "\x1b[38;5;" & $max(0, min(255, index)) & "m" & s & "\x1b[0m"
proc styleInlineCode*(s: string): string =
  if not colorsEnabled or s.len == 0: s
  else: "\x1b[38;5;215;48;5;236m" & s & "\x1b[0m"

proc styleHyperlink*(url, label: string): string =
  ## Format an OSC 8 clickable terminal hyperlink when colors are active.
  if not colorsEnabled or url.len == 0:
    return label
  "\x1b]8;;" & url & "\x07" & styleUnderline(styleCyan(label)) & "\x1b]8;;\x07"

# Unicode / CJK display width and ANSI-aware wrapping

proc isCjkOrWideRune*(r: Rune): bool =
  ## Return true when Unicode codepoint occupies 2 terminal cells (East Asian Wide / Fullwidth / Emoji).
  let cp = int32(r)
  (cp >= 0x1100 and cp <= 0x115F) or
  (cp >= 0x2329 and cp <= 0x232A) or
  (cp >= 0x2E80 and cp <= 0x303E) or
  (cp >= 0x3040 and cp <= 0x33BF) or
  (cp >= 0x3400 and cp <= 0x4DBF) or
  (cp >= 0x4E00 and cp <= 0xA4CF) or
  (cp >= 0xA960 and cp <= 0xA97F) or
  (cp >= 0xAC00 and cp <= 0xD7A3) or
  (cp >= 0xF900 and cp <= 0xFAFF) or
  (cp >= 0xFE10 and cp <= 0xFE19) or
  (cp >= 0xFE30 and cp <= 0xFE6F) or
  (cp >= 0xFF01 and cp <= 0xFF60) or
  (cp >= 0xFFE0 and cp <= 0xFFE6) or
  (cp >= 0x1F300 and cp <= 0x1FAFF) or
  (cp >= 0x20000 and cp <= 0x3FFFD)

proc isZeroWidthRune(r: Rune): bool =
  let cp = int32(r)
  cp == 0 or
  (cp < 0x20) or
  (cp >= 0x7F and cp < 0xA0) or
  (cp >= 0x0300 and cp <= 0x036F) or
  (cp >= 0x1AB0 and cp <= 0x1AFF) or
  (cp >= 0x1DC0 and cp <= 0x1DFF) or
  (cp >= 0x200B and cp <= 0x200F) or
  (cp >= 0x20D0 and cp <= 0x20FF) or
  (cp >= 0xFE00 and cp <= 0xFE0F) or
  (cp >= 0xFE20 and cp <= 0xFE2F)

proc runeDisplayWidth*(r: Rune): int =
  ## Terminal column width of a single Unicode rune (0, 1, or 2).
  if r == Rune(ord('\t')):
    return 2
  if isZeroWidthRune(r):
    return 0
  if isCjkOrWideRune(r):
    return 2
  1

proc skipAnsiSeq(s: string, start: int): int =
  ## If s[start] starts an ANSI CSI/OSC escape sequence, return index past its end; otherwise return start.
  if start >= s.len or s[start] != '\x1b':
    return start
  if start + 1 >= s.len:
    return start + 1
  let nxt = s[start + 1]
  if nxt == '[':
    var i = start + 2
    while i < s.len:
      let c = s[i]
      inc i
      if c >= '@' and c <= '~':
        return i
    return s.len
  elif nxt == ']':
    var i = start + 2
    while i < s.len:
      if s[i] == '\x07':
        return i + 1
      if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '\\':
        return i + 2
      inc i
    return s.len
  else:
    return min(s.len, start + 2)

proc stripAnsi*(s: string): string =
  ## Strip all ANSI CSI/OSC escape sequences from s.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      i = skipAnsiSeq(s, i)
    else:
      result.add(s[i])
      inc i

proc visibleWidth*(s: string): int =
  ## Compute terminal column width of s ignoring ANSI escape codes and accounting for CJK/Emoji double-width runes.
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      i = skipAnsiSeq(s, i)
      continue
    var r: Rune
    fastRuneAt(s, i, r, doInc = true)
    result += runeDisplayWidth(r)

proc padRightVisible*(s: string, targetWidth: int): string =
  ## Pad s with trailing spaces so its visible column width reaches targetWidth.
  let w = visibleWidth(s)
  if w >= targetWidth: s
  else: s & spaces(targetWidth - w)

proc truncateVisible*(s: string, maxWidth: int, ellipsis = "…"): string =
  ## Truncate an ANSI-styled string to fit within maxWidth columns, appending ellipsis and resetting SGR if needed.
  if maxWidth <= 0:
    return ""
  if visibleWidth(s) <= maxWidth:
    return s
  let ellW = visibleWidth(ellipsis)
  let limit = max(0, maxWidth - ellW)
  var outBuf = newStringOfCap(s.len)
  var used = 0
  var sawAnsi = false
  var sawHyperlink = false
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      let nextI = skipAnsiSeq(s, i)
      let escape = s[i ..< nextI]
      outBuf.add(escape)
      sawAnsi = true
      sawHyperlink = sawHyperlink or escape.startsWith("\x1b]8;")
      i = nextI
      continue
    let prevI = i
    var r: Rune
    fastRuneAt(s, i, r, doInc = true)
    let rw = runeDisplayWidth(r)
    if used + rw > limit:
      break
    outBuf.add(s[prevI ..< i])
    used += rw
  if sawAnsi:
    outBuf.add("\x1b[0m")
  if sawHyperlink:
    outBuf.add("\x1b]8;;\x07")
  if ellW <= maxWidth:
    outBuf.add(ellipsis)
  outBuf

proc wrapAnsiText*(s: string, maxWidth: int, firstIndent = "", contIndent = ""): seq[string] =
  ## Word-wrap a single paragraph (preserving active ANSI SGR styles across wrapped lines and breaking cleanly on CJK).
  let firstW = visibleWidth(firstIndent)
  let contW = visibleWidth(contIndent)
  let availFirst = max(4, maxWidth - firstW)
  let availCont = max(4, maxWidth - contW)

  if s.len == 0:
    return @[firstIndent]

  type Token = object
    raw: string
    visWidth: int
    isSpace: bool
    activeSgr: string

  var tokens: seq[Token] = @[]
  var curRaw = ""
  var curW = 0
  var curIsSpace = false
  var haveToken = false
  var activeSgr = ""

  proc flushToken() =
    if haveToken or curRaw.len > 0:
      tokens.add(Token(raw: curRaw, visWidth: curW, isSpace: curIsSpace, activeSgr: activeSgr))
      curRaw = ""
      curW = 0
      haveToken = false

  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      let nextI = skipAnsiSeq(s, i)
      let seqStr = s[i ..< nextI]
      curRaw.add(seqStr)
      if seqStr.startsWith("\x1b[") and seqStr.endsWith("m"):
        if seqStr == "\x1b[0m" or seqStr == "\x1b[m":
          activeSgr = ""
        else:
          activeSgr.add(seqStr)
      i = nextI
      continue

    let startByte = i
    var r: Rune
    fastRuneAt(s, i, r, doInc = true)
    let slice = s[startByte ..< i]
    let rw = runeDisplayWidth(r)
    let isSp = (r == Rune(ord(' ')) or r == Rune(ord('\t')))
    let isCjk = isCjkOrWideRune(r)

    if isCjk:
      flushToken()
      tokens.add(Token(raw: slice, visWidth: rw, isSpace: false, activeSgr: activeSgr))
    elif not haveToken:
      curRaw.add(slice)
      curW = rw
      curIsSpace = isSp
      haveToken = true
    elif curIsSpace == isSp:
      curRaw.add(slice)
      curW += rw
    else:
      flushToken()
      curRaw = slice
      curW = rw
      curIsSpace = isSp
      haveToken = true

  flushToken()
  if tokens.len == 0:
    return @[firstIndent]

  var outLines: seq[string] = @[]
  var lineBuf = firstIndent
  var lineW = 0
  var lineLimit = availFirst
  var lineHasSgr = false
  var reopenSgr = ""

  template pushLine(nextSgr: string) =
    if lineHasSgr:
      lineBuf.add("\x1b[0m")
    outLines.add(lineBuf)
    lineBuf = contIndent & nextSgr
    lineW = 0
    lineLimit = availCont
    lineHasSgr = nextSgr.len > 0

  for tok in tokens:
    if tok.isSpace and lineW == 0 and outLines.len > 0:
      if "\x1b[" in tok.raw:
        lineBuf.add(stripAnsi(tok.raw).replace(" ", "")) # drop leading space only
        reopenSgr = tok.activeSgr
      continue

    if lineW + tok.visWidth <= lineLimit:
      lineBuf.add(tok.raw)
      lineW += tok.visWidth
      if "\x1b[" in tok.raw or reopenSgr.len > 0:
        lineHasSgr = true
      reopenSgr = tok.activeSgr
    elif tok.visWidth <= availCont and lineW > 0:
      pushLine(reopenSgr)
      if not tok.isSpace:
        lineBuf.add(tok.raw)
        lineW += tok.visWidth
        if "\x1b[" in tok.raw:
          lineHasSgr = true
      reopenSgr = tok.activeSgr
    else:
      # Hard-wrap an oversized single token (e.g. a long URL or file path) rune by rune
      var ti = 0
      while ti < tok.raw.len:
        if tok.raw[ti] == '\x1b':
          let nxt = skipAnsiSeq(tok.raw, ti)
          let esc = tok.raw[ti ..< nxt]
          lineBuf.add(esc)
          lineHasSgr = true
          if esc == "\x1b[0m" or esc == "\x1b[m":
            reopenSgr = ""
          elif esc.startsWith("\x1b[") and esc.endsWith("m"):
            reopenSgr.add(esc)
          ti = nxt
          continue
        let sb = ti
        var r: Rune
        fastRuneAt(tok.raw, ti, r, doInc = true)
        let rw = runeDisplayWidth(r)
        if lineW + rw > lineLimit and lineW > 0:
          pushLine(reopenSgr)
        lineBuf.add(tok.raw[sb ..< ti])
        lineW += rw

  if lineW > 0 or outLines.len == 0:
    if lineHasSgr and not lineBuf.endsWith("\x1b[0m"):
      lineBuf.add("\x1b[0m")
    outLines.add(lineBuf)
  outLines

# Raw single-keypress & bracketed-paste reader (POSIX termios + Windows Console _getch)

proc utf8ExpectedLen(firstByte: uint8): int =
  if (firstByte and 0x80'u8) == 0: 1
  elif (firstByte and 0xE0'u8) == 0xC0'u8: 2
  elif (firstByte and 0xF0'u8) == 0xE0'u8: 3
  elif (firstByte and 0xF8'u8) == 0xF0'u8: 4
  else: 1

proc normalizePastedText(raw: string): string =
  raw.replace("\r\n", "\n").replace('\r', '\n')

proc decodeCsiSequence(paramsStr: string, finalCh: char): KeyEvent =
  case finalCh
  of 'A':
    if paramsStr in ["1;2", "2"]:
      return KeyEvent(kind: kkScrollUp)
    return KeyEvent(kind: kkUp)
  of 'B':
    if paramsStr in ["1;2", "2"]:
      return KeyEvent(kind: kkScrollDown)
    return KeyEvent(kind: kkDown)
  of 'M', 'm':
    # SGR mouse tracking (`\x1b[<b;x;yM`): only wheel events scroll the transcript.
    if paramsStr.len > 1 and paramsStr[0] == '<':
      let code = (try: parseInt(paramsStr[1 .. ^1].split(';')[0]) except ValueError: -1)
      if finalCh == 'M' and code >= 0 and (code and 64) != 0:
        return KeyEvent(kind: (if (code and 1) == 0: kkScrollUp else: kkScrollDown))
    return KeyEvent(kind: kkMouseOther)
  of 'C':
    if paramsStr in ["1;3", "1;5", "3", "5"]:
      return KeyEvent(kind: kkWordRight)
    return KeyEvent(kind: kkRight)
  of 'D':
    if paramsStr in ["1;3", "1;5", "3", "5"]:
      return KeyEvent(kind: kkWordLeft)
    return KeyEvent(kind: kkLeft)
  of 'H':
    return KeyEvent(kind: kkHome)
  of 'F':
    return KeyEvent(kind: kkEnd)
  of 'Z':
    return KeyEvent(kind: kkShiftTab)
  of 'u':
    # Kitty keyboard protocol CSI-u (e.g. `13;2u` = Shift+Enter, `13;3u` = Alt+Enter, `9;2u` = Shift+Tab)
    let parts = paramsStr.split(';')
    let keyCode = if parts.len > 0: (try: parseInt(parts[0]) except ValueError: 0) else: 0
    let mods = if parts.len > 1: (try: parseInt(parts[1]) except ValueError: 1) else: 1
    if keyCode == 13:
      if mods == 3:
        return KeyEvent(kind: kkAltEnter)
      if mods > 1:
        return KeyEvent(kind: kkNewline, ch: '\n', text: "\n")
      return KeyEvent(kind: kkEnter)
    if keyCode == 9 and mods == 2:
      return KeyEvent(kind: kkShiftTab)
    if keyCode == 27:
      return KeyEvent(kind: kkEscape)
    if keyCode == 127:
      if mods in [3, 5]:
        return KeyEvent(kind: kkCtrlW)
      return KeyEvent(kind: kkBackspace)
    if keyCode >= 32 and keyCode <= 0x10FFFF:
      let s = $Rune(keyCode)
      let c = if s.len == 1: s[0] else: '\0'
      return KeyEvent(kind: kkChar, ch: c, text: s)
  of '~':
    let parts = paramsStr.split(';')
    let code = if parts.len > 0: (try: parseInt(parts[0]) except ValueError: 0) else: 0
    let mods = if parts.len > 1: (try: parseInt(parts[1]) except ValueError: 1) else: 1
    case code
    of 1, 7: return KeyEvent(kind: kkHome)
    of 3: return KeyEvent(kind: kkDelete)
    of 4, 8: return KeyEvent(kind: kkEnd)
    of 5: return KeyEvent(kind: kkPageUp)
    of 6: return KeyEvent(kind: kkPageDown)
    of 27:
      # xterm modifyOtherKeys (`27;2;13~` = Shift+Enter)
      if parts.len >= 3 and parts[2] == "13" and mods > 1:
        if mods == 3:
          return KeyEvent(kind: kkAltEnter)
        return KeyEvent(kind: kkNewline, ch: '\n', text: "\n")
    else:
      discard
  else:
    discard
  KeyEvent(kind: kkEscape)

var rawModeDepth = 0

when defined(windows):
  var savedConsoleMode: DWORD
else:
  var savedOrigTerm: Termios

proc setRawInputMode(): bool =
  when defined(windows):
    let handle = getStdHandle(STD_INPUT_HANDLE)
    if getConsoleMode(handle, addr savedConsoleMode) == 0:
      return false
    # Preserve console Ctrl+C signals so commands can be interrupted while the editor is idle.
    let flags = ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or ENABLE_MOUSE_INPUT or ENABLE_VIRTUAL_TERMINAL_INPUT
    setConsoleMode(handle, savedConsoleMode and not DWORD(flags)) != 0
  else:
    let fd = getFileHandle(stdin)
    if tcGetAttr(fd, addr savedOrigTerm) != 0:
      return false
    var raw = savedOrigTerm
    raw.c_lflag = raw.c_lflag and not Cflag(ICANON or ECHO or ISIG)
    raw.c_iflag = raw.c_iflag and not Cflag(IXON or ICRNL)
    raw.c_cc[VMIN] = 1.char
    raw.c_cc[VTIME] = 0.char
    tcSetAttr(fd, TCSANOW, addr raw) == 0

proc restoreInputMode() =
  when defined(windows):
    discard setConsoleMode(getStdHandle(STD_INPUT_HANDLE), savedConsoleMode)
  else:
    discard tcSetAttr(getFileHandle(stdin), TCSANOW, addr savedOrigTerm)

proc enterRawTerminalMode*() =
  ## Enable direct key input without echo and restore the original mode on exit.
  if not isInteractiveTerminal():
    return
  if rawModeDepth == 0:
    if not setRawInputMode():
      return
    stdout.write("\x1b[?25l")
    enableBracketedPaste()
  inc rawModeDepth

proc exitRawTerminalMode*() =
  ## Restore the original console mode and cursor when the last raw reader exits.
  if rawModeDepth == 0:
    return
  dec rawModeDepth
  if rawModeDepth != 0:
    return
  restoreInputMode()
  disableBracketedPaste()
  if stdout.isatty():
    stdout.write("\x1b[?25h")
    stdout.flushFile()

when defined(windows):
  # Console records carry UTF-16 units and virtual keys. Convert both to the byte stream used by the shared decoder.
  var consoleHighSurrogate: int
  var consoleBytes: string
  var consoleOffset: int
  var consoleRepeats: int

  proc consoleKeyBytes(record: KEY_EVENT_RECORD): string =
    const
      altMask = 0x03
      ctrlMask = 0x0c
      shiftMask = 0x10
    let alt = (record.dwControlKeyState and altMask) != 0
    let ctrl = (record.dwControlKeyState and ctrlMask) != 0
    let shift = (record.dwControlKeyState and shiftMask) != 0
    let unit = cast[uint16](record.uChar).int
    if unit in 0xd800 .. 0xdbff:
      consoleHighSurrogate = unit
      return ""
    let highSurrogate = consoleHighSurrogate
    consoleHighSurrogate = 0
    if unit in 0xdc00 .. 0xdfff:
      if highSurrogate != 0:
        return $Rune(0x10000 + ((highSurrogate - 0xd800) shl 10) + unit - 0xdc00)
      return ""

    case record.wVirtualKeyCode
    of 0x08: return (if alt or ctrl: "\x17" else: "\x7f") # Backspace
    of 0x09: return (if shift: "\x1b[Z" else: "\t")
    of 0x0d:
      if alt: return "\x1b\r"
      if shift: return "\n"
      return "\r"
    of 0x1b: return "\x1b"
    of 0x21: return "\x1b[5~" # Page Up
    of 0x22: return "\x1b[6~"
    of 0x23: return "\x1b[F" # End
    of 0x24: return "\x1b[H"
    of 0x25: return (if alt or ctrl: "\x1b[1;5D" else: "\x1b[D") # Left
    of 0x26: return "\x1b[A"
    of 0x27: return (if alt or ctrl: "\x1b[1;5C" else: "\x1b[C")
    of 0x28: return "\x1b[B"
    of 0x2e: return "\x1b[3~" # Delete
    else: discard

    if alt and not ctrl and unit in [ord('b'), ord('B'), ord('f'), ord('F')]:
      return "\x1b" & char(unit)
    if unit == 13:
      # A CR without VK_RETURN comes from pasted text. Do not submit it as a prompt.
      return "\n"
    if unit != 0:
      result = $Rune(unit)

  proc readInputByte(timeoutMs: int): int =
    let handle = getStdHandle(STD_INPUT_HANDLE)
    let started = getMonoTime()
    while consoleRepeats == 0:
      let remaining = if timeoutMs < 0: INFINITE else:
        int32(max(0, timeoutMs.int64 - (getMonoTime() - started).inMilliseconds))
      case waitForSingleObject(handle, remaining)
      of WAIT_TIMEOUT: return -1
      of WAIT_OBJECT_0: discard
      else: return -2
      var record: KEY_EVENT_RECORD
      var count: cint
      if readConsoleInput(handle, addr record, 1, addr count) == 0:
        return -2
      # Alt+numpad can report its resulting character on the Alt release.
      if count == 0 or record.eventType != 1 or
          (record.bKeyDown == 0 and (record.wVirtualKeyCode != 0x12 or record.uChar == 0)):
        continue
      consoleBytes = consoleKeyBytes(record)
      if consoleBytes.len > 0:
        consoleRepeats = max(1, cast[uint16](record.wRepeatCount).int)

    result = ord(consoleBytes[consoleOffset])
    inc consoleOffset
    if consoleOffset == consoleBytes.len:
      consoleOffset = 0
      dec consoleRepeats
else:
  proc readInputByte(timeoutMs: int): int =
    let fd = getFileHandle(stdin)
    var pfd = TPollfd(fd: fd, events: cshort(POLLIN))
    while true:
      let ready = poll(addr pfd, 1, cint(timeoutMs))
      if ready == 0:
        return -1
      if ready < 0:
        if errno == EINTR: continue
        return -2
      if (pfd.revents and POLLIN) == 0:
        return -2
      var b: uint8
      if posix.read(fd, addr b, 1) == 1:
        return b.int
      return -2

proc readBracketedPaste(): string =
  const endMarker = "\x1b[201~"
  var buf = newStringOfCap(256)
  while true:
    let b = readInputByte(150)
    if b < 0:
      break
    buf.add(char(b))
    if buf.endsWith(endMarker):
      buf.setLen(buf.len - endMarker.len)
      break
  normalizePastedText(buf)

proc decodeInputKey(first: int): KeyEvent =
  case first
  of -2, -1: return KeyEvent(kind: kkEof)
  of 1: return KeyEvent(kind: kkCtrlA)
  of 2: return KeyEvent(kind: kkLeft)
  of 3: return KeyEvent(kind: kkCtrlC)
  of 4: return KeyEvent(kind: kkCtrlD)
  of 5: return KeyEvent(kind: kkCtrlE)
  of 6: return KeyEvent(kind: kkRight)
  of 7: return KeyEvent(kind: kkCtrlG)
  of 8, 127: return KeyEvent(kind: kkBackspace)
  of 9: return KeyEvent(kind: kkTab)
  of 10:
    if not stdin.isatty():
      return KeyEvent(kind: kkEnter)
    return KeyEvent(kind: kkNewline, ch: '\n', text: "\n")
  of 11: return KeyEvent(kind: kkCtrlK)
  of 12: return KeyEvent(kind: kkCtrlL)
  of 13: return KeyEvent(kind: kkEnter)
  of 14: return KeyEvent(kind: kkCtrlN)
  of 16: return KeyEvent(kind: kkCtrlP)
  of 17: return KeyEvent(kind: kkCtrlQ)
  of 19: return KeyEvent(kind: kkCtrlS)
  of 21: return KeyEvent(kind: kkCtrlU)
  of 23: return KeyEvent(kind: kkCtrlW)
  of 25: return KeyEvent(kind: kkCtrlY)
  of 26, 31: return KeyEvent(kind: kkUndo)
  of 32: return KeyEvent(kind: kkSpace, ch: ' ', text: " ")
  of 27:
    let second = readInputByte(35)
    case second
    of ord('['):
      var params = ""
      while true:
        let next = readInputByte(35)
        if next < 0:
          break
        let ch = char(next)
        if ch in {'@'..'~'}:
          if params == "200" and ch == '~':
            return KeyEvent(kind: kkPaste, text: readBracketedPaste())
          return decodeCsiSequence(params, ch)
        params.add(ch)
    of ord('O'):
      let next = readInputByte(35)
      if next in [ord('A'), ord('B'), ord('C'), ord('D'), ord('H'), ord('F')]:
        return decodeCsiSequence("", char(next))
    of 10, 13: return KeyEvent(kind: kkAltEnter)
    of ord('b'), ord('B'): return KeyEvent(kind: kkWordLeft)
    of ord('f'), ord('F'): return KeyEvent(kind: kkWordRight)
    of 8, 127: return KeyEvent(kind: kkCtrlW)
    else: discard
    return KeyEvent(kind: kkEscape)
  else:
    let len = utf8ExpectedLen(uint8(first))
    var text = newStringOfCap(len)
    text.add(char(first))
    for _ in 1 ..< len:
      let next = readInputByte(25)
      if next < 0:
        break
      text.add(char(next))
    return KeyEvent(kind: kkChar, ch: (if text.len == 1: text[0] else: '\0'), text: text)

proc readRawKey*(): KeyEvent =
  ## Read a navigation, control, Unicode text, or bracketed-paste event without echo.
  let temporaryRawMode = rawModeDepth == 0 and stdin.isatty() and setRawInputMode()
  defer:
    if temporaryRawMode:
      restoreInputMode()
  decodeInputKey(readInputByte(-1))

proc pollRawKeyNonBlocking*(timeoutMs = 0): Option[KeyEvent] =
  ## Wait briefly for a key without blocking the interactive loop on an idle console.
  if not isInteractiveTerminal():
    return none(KeyEvent)
  let first = readInputByte(max(0, timeoutMs))
  if first == -1:
    return none(KeyEvent)
  some(decodeInputKey(first))

# Line-clearing helper for scrollback-native dynamic regions (widgets, input editor, streaming block tail)

proc clearRenderedLines*(lineCount: int) =
  ## Move cursor up lineCount rows and clear each row cleanly.
  if lineCount <= 0 or not stdout.isatty():
    return
  for _ in 0 ..< lineCount:
    stdout.write("\x1b[1A\x1b[2K\r")
  stdout.flushFile()

# Interactive `ask_question` & selector TUI widget

proc promptQuestionWidget*(item: AskQuestionItem): AskQuestionAnswer =
  ## Render an interactive single/multi-select question menu with arrow keys, numbers, checkboxes, and custom 'Other' input.
  var displayOpts = item.options
  let hasOther = item.allowOther
  let otherIdx = if hasOther: displayOpts.len else: -1
  if hasOther:
    displayOpts.add(QuestionOption(label: "Other (type custom answer...)", description: ""))

  if displayOpts.len == 0:
    stdout.write("\n" & styleCyan("? ") & styleBold(item.question) & "\n  " & styleCyan("> "))
    stdout.flushFile()
    var line = ""
    if stdin.readLine(line):
      return AskQuestionAnswer(id: item.id, question: item.question, selected: @[line.strip()], customText: line.strip())
    return AskQuestionAnswer(id: item.id, question: item.question, cancelled: true)

  var cursor = 0
  var checked = newSeq[bool](displayOpts.len)
  var renderedLines = 0
  let (termCols, _) = terminalSize()

  let headerPrefix = if item.header.len > 0: styleMagenta("[" & item.header & "] ") else: ""
  stdout.write("\n" & styleCyan("? ") & headerPrefix & styleBold(item.question) & "\n")
  let hint = if item.multiSelect:
    "  (↑/↓ or 1-9 move, Space toggle, Enter confirm, Esc cancel)"
  else:
    "  (↑/↓ or j/k move, 1-9 quick select, Enter confirm, Esc cancel)"
  stdout.write(styleDim(hint) & "\n")
  stdout.flushFile()

  while true:
    beginSyncOutput()
    clearRenderedLines(renderedLines)
    renderedLines = 0

    for i, opt in displayOpts.pairs:
      let isCur = i == cursor
      let pointer = if isCur: styleCyan("❯ ") else: "  "
      let box = if item.multiSelect:
        (if checked[i]: styleGreen("[✓] ") else: styleDim("[ ] "))
      else:
        ""
      let numTag = if i < 9: styleDim($(i + 1) & ". ") else: "   "
      let lblClipped = truncateVisible(opt.label, max(20, termCols - 12))
      let lblStyled = if isCur: styleBold(lblClipped) else: lblClipped
      stdout.write("  " & pointer & box & numTag & lblStyled & "\n")
      inc renderedLines
      if opt.description.len > 0:
        let descClipped = truncateVisible(opt.description, max(20, termCols - 10))
        stdout.write("        " & styleDim(descClipped) & "\n")
        inc renderedLines
    endSyncOutput()

    let ev = readRawKey()
    case ev.kind
    of kkUp, kkCtrlP, kkShiftTab:
      cursor = if cursor == 0: displayOpts.high else: cursor - 1
    of kkDown, kkTab, kkCtrlN:
      cursor = (cursor + 1) mod displayOpts.len
    of kkHome:
      cursor = 0
    of kkEnd:
      cursor = displayOpts.high
    of kkSpace:
      if item.multiSelect:
        checked[cursor] = not checked[cursor]
    of kkChar:
      if ev.ch == 'k':
        cursor = if cursor == 0: displayOpts.high else: cursor - 1
      elif ev.ch == 'j':
        cursor = (cursor + 1) mod displayOpts.len
      elif ev.ch in {'1'..'9'}:
        let idx = ord(ev.ch) - ord('1')
        if idx < displayOpts.len:
          cursor = idx
          if item.multiSelect:
            checked[idx] = not checked[idx]
          else:
            break
    of kkEnter, kkNewline, kkAltEnter:
      break
    of kkEscape, kkCtrlC, kkCtrlD, kkEof:
      clearRenderedLines(renderedLines)
      stdout.write("  " & styleYellow("Cancelled.") & "\n")
      stdout.flushFile()
      return AskQuestionAnswer(id: item.id, question: item.question, cancelled: true)
    else:
      discard

  clearRenderedLines(renderedLines)

  var chosenLabels: seq[string] = @[]
  var wantsCustom = false
  if item.multiSelect:
    var anyChecked = false
    for i in 0 ..< displayOpts.len:
      if checked[i]:
        anyChecked = true
        if i == otherIdx:
          wantsCustom = true
        else:
          chosenLabels.add(displayOpts[i].label)
    if not anyChecked:
      if cursor == otherIdx:
        wantsCustom = true
      else:
        chosenLabels.add(displayOpts[cursor].label)
  else:
    if cursor == otherIdx:
      wantsCustom = true
    else:
      chosenLabels.add(displayOpts[cursor].label)

  var customText = ""
  if wantsCustom:
    stdout.write("  " & styleCyan("Custom answer > "))
    stdout.flushFile()
    if stdin.readLine(customText):
      customText = customText.strip()
      if customText.len > 0:
        chosenLabels.add(customText)

  stdout.write("  " & styleGreen("✓ ") & styleDim(chosenLabels.join(", ")) & "\n")
  stdout.flushFile()
  AskQuestionAnswer(
    id: item.id,
    question: item.question,
    selected: chosenLabels,
    customText: customText,
    cancelled: false
  )

proc promptAskQuestionsInteractive*(questions: seq[AskQuestionItem]): seq[AskQuestionAnswer] =
  ## Run a sequence of structured agent questions interactively in the terminal.
  for q in questions:
    let ans = promptQuestionWidget(q)
    result.add(ans)
    if ans.cancelled:
      break

# Clipboard copy: OSC 52 escape sequence + native OS clipboard utilities (macOS pbcopy, Windows clip.exe, Linux wl-copy/xclip/xsel)

proc buildOsc52Sequence*(text: string): string =
  ## Encode text as an ANSI OSC 52 clipboard sequence (supported by Windows Terminal, iTerm2, WezTerm, Alacritty, Kitty, SSH).
  "\x1b]52;c;" & base64.encode(text) & "\x07"

proc pipeToCommand(exe: string, args: openArray[string], text: string): bool =
  let fullExe = findExe(exe)
  if fullExe.len == 0:
    return false
  try:
    let p = startProcess(fullExe, args = args, options = {poUsePath})
    defer:
      try: p.close() except CatchableError: discard
    p.inputStream.write(text)
    p.inputStream.close()
    return p.waitForExit() == 0
  except CatchableError:
    return false

proc copyToClipboard*(text: string): tuple[ok: bool, methodUsed: string] =
  ## Copy text to the user's clipboard using native OS clipboard commands plus OSC 52 terminal fallback.
  if text.len == 0:
    return (false, "empty")

  var oscSent = false
  if stdout.isatty():
    stdout.write(buildOsc52Sequence(text))
    stdout.flushFile()
    oscSent = true

  when defined(macosx):
    if pipeToCommand("pbcopy", [], text):
      return (true, if oscSent: "pbcopy + OSC52" else: "pbcopy")
  elif defined(windows):
    if pipeToCommand("clip", [], text) or pipeToCommand("clip.exe", [], text):
      return (true, if oscSent: "clip.exe + OSC52" else: "clip.exe")
  else:
    if getEnv("WAYLAND_DISPLAY").len > 0 and pipeToCommand("wl-copy", [], text):
      return (true, if oscSent: "wl-copy + OSC52" else: "wl-copy")
    if pipeToCommand("xclip", ["-selection", "clipboard"], text):
      return (true, if oscSent: "xclip + OSC52" else: "xclip")
    if pipeToCommand("xsel", ["--clipboard", "--input"], text):
      return (true, if oscSent: "xsel + OSC52" else: "xsel")

  if oscSent:
    return (true, "OSC52")
  (false, "unavailable")

proc extractCodeBlocks*(markdown: string): seq[string] =
  ## Extract fenced ``` code blocks from an assistant message for `/copy code` or `/copy <N>`.
  let lines = markdown.replace("\r\n", "\n").split('\n')
  var inFence = false
  var buf: seq[string] = @[]
  for line in lines:
    let trimmed = line.strip()
    if trimmed.startsWith("```") or trimmed.startsWith("~~~"):
      if not inFence:
        inFence = true
        buf.setLen(0)
      else:
        inFence = false
        result.add(buf.join("\n"))
        buf.setLen(0)
    elif inFence:
      buf.add(line)
