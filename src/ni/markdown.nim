# Terminal Markdown parser, CJK-aligned GFM table layout, multi-language syntax highlighter, and scrollback-safe live streaming renderer.

import std/[sets, strutils, unicode]
import ./terminal_io

type
  TableAlign = enum
    taLeft
    taCenter
    taRight

  StreamMarkdownRenderer* = ref object
    rawBuffer*: string
    committedSourceLen: int
    committedExtraLines: int   # Lines already committed within an oversized code fence
    committedBlockWidth: int
    ephemeralLineCount: int    # Erasable tail lines currently on screen
    maxWidth*: int

const CommonCodeKeywords = toHashSet([
  # Nim
  "proc", "func", "method", "iterator", "converter", "template", "macro",
  "type", "object", "tuple", "enum", "concept", "distinct", "ref", "ptr",
  "var", "let", "const", "import", "include", "from", "export", "bind", "mixin",
  "when", "elif", "else", "case", "of", "for", "in", "notin", "while", "block",
  "break", "continue", "return", "yield", "try", "except", "finally", "raise",
  "defer", "using", "discard", "addr", "cast", "and", "or", "not", "xor", "shl", "shr", "div", "mod",
  # TS / JS / Python / Go / Rust / C-family
  "function", "class", "interface", "extends", "implements", "namespace",
  "async", "await", "new", "delete", "typeof", "instanceof", "void", "readonly",
  "switch", "default", "catch", "throw", "do",
  "def", "lambda", "with", "as", "pass", "global", "nonlocal", "assert", "is",
  "package", "go", "chan", "select", "map", "range", "fallthrough",
  "fn", "pub", "impl", "trait", "struct", "crate", "use", "mut", "match", "loop", "where", "move", "unsafe"
])

const CommonTypeAndLiterals = toHashSet([
  "true", "false", "nil", "null", "undefined", "None", "True", "False", "self", "this", "result",
  "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
  "float", "float32", "float64", "bool", "char", "string", "cstring", "seq", "array", "openArray",
  "set", "Option", "Some", "Table", "OrderedTable", "HashSet", "JsonNode", "Future", "Promise",
  "number", "any", "unknown", "never", "Record", "Array", "Map", "Set", "Error", "str", "dict", "list",
  "usize", "isize", "u8", "u16", "u32", "u64", "i32", "i64", "f32", "f64", "Vec", "Box", "Result", "Ok", "Err"
])

const ShellKeywords = toHashSet([
  "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "case", "esac",
  "while", "until", "function", "return", "exit", "export", "local", "readonly",
  "set", "unset", "shift", "source", "echo", "printf", "cd", "pwd", "test"
])

# Syntax Highlighter (zero-dependency lexical scanner for fenced code blocks)

proc styleKeyword(s: string): string =
  if not colorsActive(): s else: "\x1b[1;35m" & s & "\x1b[0m"

proc styleTypeLit(s: string): string =
  if not colorsActive(): s else: "\x1b[36m" & s & "\x1b[0m"

proc styleStringLit(s: string): string =
  if not colorsActive(): s else: "\x1b[32m" & s & "\x1b[0m"

proc styleNumberLit(s: string): string =
  if not colorsActive(): s else: "\x1b[33m" & s & "\x1b[0m"

proc styleComment(s: string): string =
  if not colorsActive(): s else: "\x1b[90m" & s & "\x1b[0m"

proc highlightJsonLine(line: string): string =
  result = newStringOfCap(line.len + 32)
  var i = 0
  while i < line.len:
    let ch = line[i]
    if ch == '"':
      let start = i
      inc i
      while i < line.len:
        if line[i] == '\\' and i + 1 < line.len:
          i += 2
        elif line[i] == '"':
          inc i
          break
        else:
          inc i
      let tok = line[start ..< i]
      var k = i
      while k < line.len and line[k] in {' ', '\t'}:
        inc k
      if k < line.len and line[k] == ':':
        result.add(styleCyan(tok))
      else:
        result.add(styleStringLit(tok))
    elif ch in {'0'..'9'} or (ch == '-' and i + 1 < line.len and line[i + 1] in {'0'..'9'}):
      let start = i
      inc i
      while i < line.len and line[i] in {'0'..'9', '.', 'e', 'E', '+', '-'}:
        inc i
      result.add(styleNumberLit(line[start ..< i]))
    elif ch in {'t', 'f', 'n'}:
      let start = i
      while i < line.len and line[i] in {'a'..'z'}:
        inc i
      let word = line[start ..< i]
      if word in ["true", "false", "null"]:
        result.add(styleTypeLit(word))
      else:
        result.add(word)
    else:
      result.add(ch)
      inc i

proc highlightCodeLine*(line: string, lang: string): string =
  ## Apply terminal syntax highlighting to a single line of fenced code.
  if not colorsActive() or line.len == 0:
    return line

  let normLang = lang.strip().toLowerAscii()
  if normLang in ["diff", "patch"]:
    if line.startsWith("+++") or line.startsWith("---"):
      return styleBold(line)
    if line.startsWith("@@"):
      return styleCyan(line)
    if line.startsWith("+"):
      return styleGreen(line)
    if line.startsWith("-"):
      return styleRed(line)
    return styleDim(line)

  if normLang in ["json", "jsonl", "jsonc"]:
    return highlightJsonLine(line)

  let hashComments = normLang in ["nim", "py", "python", "sh", "bash", "zsh", "shell", "yaml", "yml", "toml", "ruby", "rb", "r", "makefile", "dockerfile", "ps1", "powershell", "conf", "ini"]
  let slashComments = normLang in ["ts", "tsx", "js", "jsx", "typescript", "javascript", "go", "golang", "rs", "rust", "c", "cpp", "cc", "h", "hpp", "java", "kt", "swift", "zig", "csharp", "cs", "dart", "scala", "proto", "css", "scss"]
  let dashComments = normLang in ["sql", "lua", "haskell", "hs"]
  let isShell = normLang in ["sh", "bash", "zsh", "shell"]

  result = newStringOfCap(line.len + 48)
  var i = 0
  while i < line.len:
    let ch = line[i]

    # Single-line comments
    if hashComments and ch == '#' and (not isShell or i == 0 or line[i - 1] in {' ', '\t', ';'}):
      result.add(styleComment(line[i .. ^1]))
      break
    if slashComments and ch == '/' and i + 1 < line.len and line[i + 1] == '/':
      result.add(styleComment(line[i .. ^1]))
      break
    if dashComments and ch == '-' and i + 1 < line.len and line[i + 1] == '-':
      result.add(styleComment(line[i .. ^1]))
      break

    # String literals
    if ch in {'"', '\''} or (ch == '`' and normLang in ["ts", "tsx", "js", "jsx", "typescript", "javascript", "go", "golang"]):
      # Avoid treating Rust lifetime `'a` as an unclosed string literal
      if ch == '\'' and normLang in ["rs", "rust"] and i + 1 < line.len and line[i + 1] in {'a'..'z', 'A'..'Z', '_'} and
         (i + 2 >= line.len or line[i + 2] != '\''):
        let start = i
        i += 2
        while i < line.len and line[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
          inc i
        result.add(styleTypeLit(line[start ..< i]))
        continue

      let quote = ch
      let start = i
      inc i
      while i < line.len:
        if line[i] == '\\' and i + 1 < line.len:
          i += 2
        elif line[i] == quote:
          inc i
          break
        else:
          inc i
      result.add(styleStringLit(line[start ..< i]))
      continue

    # Shell $VARIABLE
    if isShell and ch == '$' and i + 1 < line.len and line[i + 1] in {'A'..'Z', 'a'..'z', '_', '{', '0'..'9'}:
      let start = i
      inc i
      if line[i] == '{':
        while i < line.len and line[i] != '}': inc i
        if i < line.len: inc i
      else:
        while i < line.len and line[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: inc i
      result.add(styleCyan(line[start ..< i]))
      continue

    # Numeric literals
    if ch in {'0'..'9'} and (i == 0 or line[i - 1] notin {'A'..'Z', 'a'..'z', '_'}):
      let start = i
      inc i
      while i < line.len and line[i] in {'0'..'9', '_', '.', 'x', 'X', 'b', 'B', 'o', 'O', 'a'..'f', 'A'..'F', '\''}:
        inc i
      result.add(styleNumberLit(line[start ..< i]))
      continue

    # Identifiers, keywords, and PascalCase types
    if ch in {'A'..'Z', 'a'..'z', '_'}:
      let start = i
      inc i
      while i < line.len and line[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
        inc i
      let ident = line[start ..< i]
      if isShell:
        if ident in ShellKeywords:
          result.add(styleKeyword(ident))
        else:
          result.add(ident)
      elif ident in CommonCodeKeywords or (normLang in ["nim", "py", "python"] and ident == "if"):
        result.add(styleKeyword(ident))
      elif ident == "if":
        result.add(styleKeyword(ident))
      elif ident in CommonTypeAndLiterals or (ident[0] in {'A'..'Z'} and ident.len >= 2):
        result.add(styleTypeLit(ident))
      else:
        result.add(ident)
      continue

    result.add(ch)
    inc i

# Inline Markdown Formatter (`code`, [link](url), ![img](url), <url>, bare URL, **bold**, *italic*, ~~strike~~)

proc isCjkStopPunct(r: Rune): bool =
  let cp = int32(r)
  cp in [
    0x3001'i32, 0x3002'i32, 0xFF0C'i32, 0xFF0E'i32, 0xFF1A'i32, 0xFF1B'i32,
    0xFF1F'i32, 0xFF01'i32, 0x300B'i32, 0x300D'i32, 0x300F'i32, 0x3011'i32,
    0xFF09'i32, 0x201D'i32, 0x2019'i32
  ]

proc findClosingDelim(s: string, delim: string, startPos: int): int =
  var p = startPos
  while p <= s.len - delim.len:
    if s[p] == '\\':
      p += 2
      continue
    if s[p] == '`':
      var ticks = 0
      while p + ticks < s.len and s[p + ticks] == '`':
        inc ticks
      let endCode = s.find('`'.repeat(ticks), p + ticks)
      if endCode >= 0:
        p = endCode + ticks
        continue
    if s.continuesWith(delim, p):
      return p
    inc p
  -1

proc renderInlineMarkdown*(text: string): string =
  ## Convert inline Markdown spans into ANSI/OSC8 styled text while preserving escaped characters and code spans.
  if text.len == 0:
    return ""
  result = newStringOfCap(text.len + 32)
  var i = 0

  while i < text.len:
    let ch = text[i]

    # 1. Backslash escape `\*`, `\_`, `` \` ``, `\[`, `\\`, `\~`
    if ch == '\\' and i + 1 < text.len and text[i + 1] in {'\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '~', '|'}:
      result.add(text[i + 1])
      i += 2
      continue

    # 2. Inline code span (supports single or multi-backtick fences)
    if ch == '`':
      var ticks = 0
      while i + ticks < text.len and text[i + ticks] == '`':
        inc ticks
      let fence = '`'.repeat(ticks)
      let closeIdx = text.find(fence, i + ticks)
      if closeIdx >= 0:
        var codeContent = text[i + ticks ..< closeIdx]
        if codeContent.len >= 2 and codeContent.startsWith(" ") and codeContent.endsWith(" ") and codeContent.strip().len > 0:
          codeContent = codeContent[1 ..< codeContent.high]
        result.add(styleInlineCode(codeContent))
        i = closeIdx + ticks
        continue
      else:
        result.add(fence)
        i += ticks
        continue

    # 3. Image `![alt](url)`
    if ch == '!' and i + 1 < text.len and text[i + 1] == '[':
      let closeBracket = findClosingDelim(text, "]", i + 2)
      if closeBracket >= 0 and closeBracket + 1 < text.len and text[closeBracket + 1] == '(':
        let closeParen = text.find(')', closeBracket + 2)
        if closeParen >= 0:
          let alt = text[i + 2 ..< closeBracket]
          let url = text[closeBracket + 2 ..< closeParen].strip()
          let label = if alt.len > 0: "[image: " & alt & "]" else: "[image]"
          result.add(styleHyperlink(url, label))
          i = closeParen + 1
          continue

    # 4. Markdown link `[label](url)`
    if ch == '[':
      let closeBracket = findClosingDelim(text, "]", i + 1)
      if closeBracket >= 0 and closeBracket + 1 < text.len and text[closeBracket + 1] == '(':
        var p = closeBracket + 2
        var depth = 1
        while p < text.len and depth > 0:
          if text[p] == '\\':
            p += 2
            continue
          if text[p] == '(': inc depth
          elif text[p] == ')': dec depth
          if depth > 0: inc p
        if depth == 0 and p < text.len:
          let rawLabel = text[i + 1 ..< closeBracket]
          let rawUrl = text[closeBracket + 2 ..< p].strip()
          let spaceInUrl = rawUrl.find(' ')
          let cleanUrl = if spaceInUrl > 0: rawUrl[0 ..< spaceInUrl] else: rawUrl
          let styledLabel = renderInlineMarkdown(rawLabel)
          if colorsActive():
            result.add(styleHyperlink(cleanUrl, styledLabel))
          else:
            if rawLabel == cleanUrl or cleanUrl.len == 0:
              result.add(styledLabel)
            else:
              result.add(styledLabel & " (" & cleanUrl & ")")
          i = p + 1
          continue

    # 5. Angle-bracket autolink `<https://...>`
    if ch == '<' and (text.continuesWith("<https://", i) or text.continuesWith("<http://", i) or text.continuesWith("<file://", i)):
      let closeAngle = text.find('>', i + 1)
      if closeAngle > i + 4 and ' ' notin text[i + 1 ..< closeAngle]:
        let url = text[i + 1 ..< closeAngle]
        result.add(styleHyperlink(url, styleUnderline(styleCyan(url))))
        i = closeAngle + 1
        continue

    # 6. Bare URL `https://...` or `http://...` (stops before CJK punctuation and trailing sentence punctuation)
    if (ch == 'h' and (text.continuesWith("https://", i) or text.continuesWith("http://", i))) and
       (i == 0 or text[i - 1] notin {'A'..'Z', 'a'..'z', '0'..'9', '/', '('}):
      var p = i
      while p < text.len:
        if text[p] in {' ', '\t', '<', '>', '"', '\''}:
          break
        var r: Rune
        let prevP = p
        fastRuneAt(text, p, r, doInc = true)
        if isCjkStopPunct(r):
          p = prevP
          break
      # Trim trailing ASCII sentence punctuation like `.`, `,`, `;`, `)` when unmatched
      while p > i + 8 and text[p - 1] in {'.', ',', ';', ':', '!', '?'}:
        dec p
      while p > i + 8 and text[p - 1] == ')' and text[i ..< p].count(')') > text[i ..< p].count('('):
        dec p
      let url = text[i ..< p]
      result.add(styleHyperlink(url, styleUnderline(styleCyan(url))))
      i = p
      continue

    # 7. Bold+Italic `***...***`
    if text.continuesWith("***", i):
      let closeIdx = findClosingDelim(text, "***", i + 3)
      if closeIdx > i + 3:
        result.add(styleBold(styleItalic(renderInlineMarkdown(text[i + 3 ..< closeIdx]))))
        i = closeIdx + 3
        continue

    # 8. Bold `**...**` or `__...__` (CJK-friendly: works inline inside Chinese sentences without spaces)
    if text.continuesWith("**", i):
      let closeIdx = findClosingDelim(text, "**", i + 2)
      if closeIdx > i + 2:
        result.add(styleBold(renderInlineMarkdown(text[i + 2 ..< closeIdx])))
        i = closeIdx + 2
        continue

    if text.continuesWith("__", i) and (i == 0 or text[i - 1] notin {'A'..'Z', 'a'..'z', '0'..'9'}):
      let closeIdx = findClosingDelim(text, "__", i + 2)
      if closeIdx > i + 2 and (closeIdx + 2 >= text.len or text[closeIdx + 2] notin {'A'..'Z', 'a'..'z', '0'..'9'}):
        result.add(styleBold(renderInlineMarkdown(text[i + 2 ..< closeIdx])))
        i = closeIdx + 2
        continue

    # 9. Strikethrough `~~...~~`
    if text.continuesWith("~~", i) and i + 2 < text.len and text[i + 2] notin {' ', '~'}:
      let closeIdx = findClosingDelim(text, "~~", i + 2)
      if closeIdx > i + 2 and text[closeIdx - 1] != ' ':
        result.add(styleStrike(renderInlineMarkdown(text[i + 2 ..< closeIdx])))
        i = closeIdx + 2
        continue

    # 10. Italic `*...*` or boundary-guarded `_..._` (never triggers inside `snake_case_var`)
    if ch == '*' and i + 1 < text.len and text[i + 1] notin {' ', '*'}:
      let closeIdx = findClosingDelim(text, "*", i + 1)
      if closeIdx > i + 1 and text[closeIdx - 1] != ' ':
        result.add(styleItalic(renderInlineMarkdown(text[i + 1 ..< closeIdx])))
        i = closeIdx + 1
        continue

    if ch == '_' and i + 1 < text.len and text[i + 1] notin {' ', '_'} and
       (i == 0 or text[i - 1] notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      var searchFrom = i + 1
      var matchedClose = -1
      while true:
        let cand = findClosingDelim(text, "_", searchFrom)
        if cand < 0:
          break
        if text[cand - 1] != ' ' and (cand + 1 >= text.len or text[cand + 1] notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
          matchedClose = cand
          break
        searchFrom = cand + 1
      if matchedClose > i + 1:
        result.add(styleItalic(renderInlineMarkdown(text[i + 1 ..< matchedClose])))
        i = matchedClose + 1
        continue

    result.add(ch)
    inc i

# HTML comment stripping & GFM Table parsing/rendering

proc stripMarkdownHtmlComments*(src: string): string =
  ## Strip `<!-- ... -->` comments (including trailing unclosed comments while streaming).
  if "<!--" notin src:
    return src
  result = newStringOfCap(src.len)
  var i = 0
  while i < src.len:
    if src.continuesWith("<!--", i):
      let endComment = src.find("-->", i + 4)
      if endComment < 0:
        break
      i = endComment + 3
    else:
      result.add(src[i])
      inc i

proc splitTableCells(row: string): seq[string] =
  var s = row.strip()
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|") and not s.endsWith("\\|"): s = s[0 ..< s.high]
  var cur = ""
  var inCode = false
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '|':
      cur.add('|')
      i += 2
      continue
    if s[i] == '`':
      inCode = not inCode
      cur.add('`')
      inc i
      continue
    if s[i] == '|' and not inCode:
      result.add(cur.strip())
      cur = ""
      inc i
      continue
    cur.add(s[i])
    inc i
  result.add(cur.strip())

proc isTableDelimiterRow(line: string, alignments: var seq[TableAlign]): bool =
  let trimmed = line.strip()
  if '|' notin trimmed or '-' notin trimmed:
    return false
  let cells = splitTableCells(trimmed)
  if cells.len == 0:
    return false
  alignments.setLen(0)
  for cell in cells:
    let c = cell.strip()
    if c.len == 0:
      return false
    let leftColon = c.startsWith(":")
    let rightColon = c.endsWith(":")
    let coreStart = if leftColon: 1 else: 0
    let coreEnd = if rightColon: c.len - 1 else: c.len
    if coreEnd <= coreStart:
      return false
    for idx in coreStart ..< coreEnd:
      if c[idx] != '-':
        return false
    if leftColon and rightColon:
      alignments.add(taCenter)
    elif rightColon:
      alignments.add(taRight)
    else:
      alignments.add(taLeft)
  true

proc alignCellVisible(s: string, width: int, align: TableAlign): string =
  let w = visibleWidth(s)
  if w >= width:
    return s
  let pad = width - w
  case align
  of taLeft:
    s & spaces(pad)
  of taRight:
    spaces(pad) & s
  of taCenter:
    let leftPad = pad div 2
    spaces(leftPad) & s & spaces(pad - leftPad)

proc renderGfmTable(headerCells: seq[string], alignments: seq[TableAlign], bodyRows: seq[seq[string]], maxWidth: int): seq[string] =
  let colCount = max(1, max(headerCells.len, alignments.len))
  var colAlign = newSeq[TableAlign](colCount)
  for c in 0 ..< colCount:
    colAlign[c] = if c < alignments.len: alignments[c] else: taLeft

  var styledHeader = newSeq[string](colCount)
  var colWidths = newSeq[int](colCount)
  for c in 0 ..< colCount:
    let raw = if c < headerCells.len: headerCells[c] else: ""
    styledHeader[c] = styleBold(renderInlineMarkdown(raw))
    colWidths[c] = max(3, visibleWidth(styledHeader[c]))

  var styledBody: seq[seq[string]] = @[]
  for row in bodyRows:
    var srow = newSeq[string](colCount)
    for c in 0 ..< colCount:
      let raw = if c < row.len: row[c] else: ""
      srow[c] = renderInlineMarkdown(raw)
      colWidths[c] = max(colWidths[c], visibleWidth(srow[c]))
    styledBody.add(srow)

  # Fit columns within maxWidth when table is wider than terminal
  let borderOverhead = colCount * 3 + 1
  let availTotal = max(colCount * 4, maxWidth - borderOverhead)
  var sumWidths = 0
  for w in colWidths: sumWidths += w
  if sumWidths > availTotal:
    for c in 0 ..< colCount:
      let scaled = max(4, (colWidths[c] * availTotal) div max(1, sumWidths))
      colWidths[c] = scaled

  proc buildRule(leftCh, midCh, rightCh: string): string =
    var parts: seq[string] = @[]
    for c in 0 ..< colCount:
      parts.add("─".repeat(colWidths[c] + 2))
    styleDim(leftCh & parts.join(midCh) & rightCh)

  proc renderLogicalRow(cells: seq[string]): seq[string] =
    var wrappedCols = newSeq[seq[string]](colCount)
    var rowHeight = 1
    for c in 0 ..< colCount:
      wrappedCols[c] = wrapAnsiText(cells[c], colWidths[c])
      if wrappedCols[c].len == 0:
        wrappedCols[c] = @[""]
      rowHeight = max(rowHeight, wrappedCols[c].len)

    let vbar = styleDim("│")
    for r in 0 ..< rowHeight:
      var line = vbar
      for c in 0 ..< colCount:
        let cellLine = if r < wrappedCols[c].len: wrappedCols[c][r] else: ""
        line.add(" " & alignCellVisible(cellLine, colWidths[c], colAlign[c]) & " " & vbar)
      result.add(line)

  result.add(buildRule("┌", "┬", "┐"))
  for rline in renderLogicalRow(styledHeader):
    result.add(rline)
  result.add(buildRule("├", "┼", "┤"))
  for srow in styledBody:
    for rline in renderLogicalRow(srow):
      result.add(rline)
  result.add(buildRule("└", "┴", "┘"))

# Block-level helpers (headings, hr, lists, blockquotes, code fences)

proc parseFenceOpen(line: string): tuple[isFence: bool, ch: char, count: int, lang: string] =
  var i = 0
  while i < line.len and i < 3 and line[i] == ' ':
    inc i
  if i >= line.len or line[i] notin {'`', '~'}:
    return (false, '\0', 0, "")
  let fch = line[i]
  var cnt = 0
  while i + cnt < line.len and line[i + cnt] == fch:
    inc cnt
  if cnt < 3:
    return (false, '\0', 0, "")
  let info = line[i + cnt .. ^1].strip()
  if fch == '`' and '`' in info:
    return (false, '\0', 0, "")
  let lang = if info.len > 0: strutils.splitWhitespace(info)[0] else: ""
  (true, fch, cnt, lang)

proc isFenceClose(line: string, fch: char, minCount: int): bool =
  var i = 0
  while i < line.len and i < 3 and line[i] == ' ':
    inc i
  var cnt = 0
  while i + cnt < line.len and line[i + cnt] == fch:
    inc cnt
  if cnt < minCount:
    return false
  line[i + cnt .. ^1].strip().len == 0

proc isPartialStreamFenceTail(line: string, fch: char, minCount: int): bool =
  ## Detect a trailing 1..2 backtick/tilde line at the very end of an unclosed streamed code fence.
  let trimmed = line.strip()
  if trimmed.len == 0 or trimmed.len >= minCount:
    return false
  for ch in trimmed:
    if ch != fch:
      return false
  true

proc isHorizontalRule(line: string): bool =
  let t = line.strip()
  if t.len < 3:
    return false
  let first = t[0]
  if first notin {'-', '*', '_'}:
    return false
  var markerCount = 0
  for ch in t:
    if ch == first:
      inc markerCount
    elif ch != ' ':
      return false
  markerCount >= 3

proc parseHeadingLine(line: string): tuple[level: int, text: string] =
  var i = 0
  while i < line.len and i < 3 and line[i] == ' ':
    inc i
  var hashes = 0
  while i + hashes < line.len and line[i + hashes] == '#':
    inc hashes
  if hashes >= 1 and hashes <= 6 and i + hashes < line.len and line[i + hashes] in {' ', '\t'}:
    var content = line[i + hashes .. ^1].strip()
    while content.len > 0 and content[^1] == '#':
      content.setLen(content.len - 1)
    return (hashes, content.strip())
  (0, "")

proc parseListItemLine(line: string): tuple[matched: bool, indentCols: int, markerStyled: string, body: string] =
  var spacesCount = 0
  var i = 0
  while i < line.len:
    if line[i] == ' ':
      inc spacesCount
      inc i
    elif line[i] == '\t':
      spacesCount += 2
      inc i
    else:
      break
  if i >= line.len:
    return (false, 0, "", "")

  # Unordered list (`- `, `* `, `+ `) + task list (`- [ ] `, `- [x] `)
  if line[i] in {'-', '*', '+'} and i + 1 < line.len and line[i + 1] in {' ', '\t'}:
    let rest = line[i + 2 .. ^1].strip(leading = true, trailing = false)
    if rest.len >= 4 and rest[0] == '[' and rest[2] == ']' and rest[3] in {' ', '\t'}:
      let markCh = rest[1]
      if markCh in {'x', 'X'}:
        return (true, spacesCount, styleGreen("☑ "), rest[4 .. ^1])
      elif markCh == ' ':
        return (true, spacesCount, styleDim("☐ "), rest[4 .. ^1])
    let bullet = if spacesCount >= 2: styleDim("◦ ") else: styleCyan("• ")
    return (true, spacesCount, bullet, rest)

  # Ordered list (`1. `, `2) `)
  var numEnd = i
  while numEnd < line.len and line[numEnd] in {'0'..'9'}:
    inc numEnd
  if numEnd > i and numEnd - i <= 6 and numEnd + 1 < line.len and
     line[numEnd] in {'.', ')'} and line[numEnd + 1] in {' ', '\t'}:
    let numPrefix = line[i .. numEnd] & " "
    return (true, spacesCount, styleCyan(numPrefix), line[numEnd + 2 .. ^1].strip(leading = true, trailing = false))

  (false, 0, "", "")

proc renderMarkdown*(markdown: string, maxWidth = 88): seq[string] =
  ## Parse and render Markdown into width-wrapped ANSI terminal lines.
  let width = clamp(maxWidth, 24, 300)
  let cleaned = stripMarkdownHtmlComments(markdown.replace("\r\n", "\n").replace('\r', '\n'))
  if cleaned.strip().len == 0:
    return @[]

  let lines = cleaned.split('\n')
  var i = 0
  var prevBlank = true

  template emitBlankSeparator() =
    if result.len > 0 and not prevBlank:
      result.add("")
      prevBlank = true

  while i < lines.len:
    let line = lines[i]
    let trimmed = line.strip()

    if trimmed.len == 0:
      emitBlankSeparator()
      inc i
      continue

    # 1. Fenced code block (``` or ~~~)
    let fence = parseFenceOpen(line)
    if fence.isFence:
      emitBlankSeparator()
      var codeLines: seq[string] = @[]
      inc i
      var closed = false
      while i < lines.len:
        if isFenceClose(lines[i], fence.ch, fence.count):
          closed = true
          inc i
          break
        codeLines.add(lines[i])
        inc i
      if not closed and codeLines.len > 0 and isPartialStreamFenceTail(codeLines[^1], fence.ch, fence.count):
        codeLines.setLen(codeLines.len - 1)

      let badge = if fence.lang.len > 0: " " & fence.lang & " " else: ""
      let topRuleLen = max(4, min(width - 4, 48) - visibleWidth(badge))
      result.add("  " & styleDim("───" & badge & "─".repeat(topRuleLen)))
      for cl in codeLines:
        result.add("  " & highlightCodeLine(cl, fence.lang))
      result.add("  " & styleDim("─".repeat(min(width - 4, 51))))
      prevBlank = false
      continue

    # 2. ATX Heading (`#` .. `######`)
    let (hLevel, hText) = parseHeadingLine(line)
    if hLevel > 0:
      emitBlankSeparator()
      let inlineStyled = renderInlineMarkdown(hText)
      case hLevel
      of 1:
        for wl in wrapAnsiText(styleBold(styleCyan(inlineStyled)), width):
          result.add(wl)
        let ulen = min(width, max(8, visibleWidth(inlineStyled)))
        result.add(styleDim("═".repeat(ulen)))
      of 2:
        for wl in wrapAnsiText(styleBold(styleCyan(inlineStyled)), width):
          result.add(wl)
      of 3:
        for wl in wrapAnsiText(styleBold(styleYellow(inlineStyled)), width):
          result.add(wl)
      else:
        for wl in wrapAnsiText(styleBold(inlineStyled), width):
          result.add(wl)
      prevBlank = false
      inc i
      continue

    # 3. Horizontal rule (`---`, `***`, `___`)
    if isHorizontalRule(line):
      emitBlankSeparator()
      result.add(styleDim("─".repeat(min(width, 64))))
      prevBlank = false
      inc i
      continue

    # 4. GFM Table (`| col | col |` followed by delimiter row `| --- | --- |`)
    var tableAligns: seq[TableAlign] = @[]
    if '|' in line and i + 1 < lines.len and isTableDelimiterRow(lines[i + 1], tableAligns):
      emitBlankSeparator()
      let hdrCells = splitTableCells(line)
      i += 2
      var bodyRows: seq[seq[string]] = @[]
      while i < lines.len:
        let rtrim = lines[i].strip()
        if rtrim.len == 0 or '|' notin rtrim or parseFenceOpen(lines[i]).isFence:
          break
        bodyRows.add(splitTableCells(lines[i]))
        inc i
      for tline in renderGfmTable(hdrCells, tableAligns, bodyRows, width):
        result.add(tline)
      prevBlank = false
      continue

    # 5. Blockquote & GitHub Alerts (`> ...`, `> [!NOTE]`, `> [!WARNING]`, etc.)
    if trimmed.startsWith(">"):
      emitBlankSeparator()
      var quoteRawLines: seq[string] = @[]
      while i < lines.len and lines[i].strip().startsWith(">"):
        var q = lines[i].strip()
        q = q[1 .. ^1]
        if q.startsWith(" "): q = q[1 .. ^1]
        quoteRawLines.add(q)
        inc i

      var bar = styleDim("  │ ")
      if quoteRawLines.len > 0:
        let firstTrim = quoteRawLines[0].strip()
        case firstTrim.toUpperAscii()
        of "[!NOTE]":
          bar = styleCyan("  │ ")
          quoteRawLines[0] = "**Note**"
        of "[!TIP]":
          bar = styleGreen("  │ ")
          quoteRawLines[0] = "**Tip**"
        of "[!IMPORTANT]":
          bar = styleMagenta("  │ ")
          quoteRawLines[0] = "**Important**"
        of "[!WARNING]":
          bar = styleYellow("  │ ")
          quoteRawLines[0] = "**Warning**"
        of "[!CAUTION]":
          bar = styleRed("  │ ")
          quoteRawLines[0] = "**Caution**"
        else:
          discard

      for qline in quoteRawLines:
        if qline.strip().len == 0:
          result.add(bar)
        else:
          let styled = styleItalic(renderInlineMarkdown(qline))
          for wl in wrapAnsiText(styled, width, firstIndent = bar, contIndent = bar):
            result.add(wl)
      prevBlank = false
      continue

    # 6. Lists (unordered, ordered, task checkboxes, nested indentation)
    let firstItem = parseListItemLine(line)
    if firstItem.matched:
      while i < lines.len:
        let item = parseListItemLine(lines[i])
        if not item.matched:
          break
        inc i
        var bodyParts: seq[string] = @[item.body]
        # Absorb indented continuation lines belonging to this list item
        while i < lines.len:
          let nxt = lines[i]
          if nxt.strip().len == 0 or parseListItemLine(nxt).matched or
             parseFenceOpen(nxt).isFence or parseHeadingLine(nxt).level > 0 or nxt.strip().startsWith(">"):
            break
          if nxt.startsWith("  ") or nxt.startsWith("\t"):
            bodyParts.add(nxt.strip())
            inc i
          else:
            break
        let pad = spaces(min(12, item.indentCols))
        let firstPfx = pad & item.markerStyled
        let contPfx = spaces(visibleWidth(firstPfx))
        let inlineItem = renderInlineMarkdown(bodyParts.join(" "))
        for wl in wrapAnsiText(inlineItem, width, firstIndent = firstPfx, contIndent = contPfx):
          result.add(wl)
      prevBlank = false
      continue

    # 7. Standard paragraph (join consecutive non-special lines)
    var paraParts: seq[string] = @[]
    while i < lines.len:
      let pl = lines[i]
      let pt = pl.strip()
      if pt.len == 0 or parseFenceOpen(pl).isFence or parseHeadingLine(pl).level > 0 or
         isHorizontalRule(pl) or pt.startsWith(">") or parseListItemLine(pl).matched:
        break
      var dummyAligns: seq[TableAlign] = @[]
      if '|' in pl and i + 1 < lines.len and isTableDelimiterRow(lines[i + 1], dummyAligns):
        break
      paraParts.add(pt)
      inc i

    if paraParts.len > 0:
      let joined = renderInlineMarkdown(paraParts.join(" "))
      for wl in wrapAnsiText(joined, width):
        result.add(wl)
      prevBlank = false

  while result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc renderMarkdownText*(markdown: string, maxWidth = 88): string =
  ## Convenience helper returning rendered Markdown lines joined with `\n`.
  renderMarkdown(markdown, maxWidth).join("\n")

# Scrollback-Safe Live Streaming Markdown Renderer

proc newStreamMarkdownRenderer*(maxWidth = 0): StreamMarkdownRenderer =
  ## Create a streaming Markdown renderer that commits finished blocks and redraws the active tail.
  let (cols, _) = terminalSize()
  StreamMarkdownRenderer(maxWidth: (if maxWidth > 0: maxWidth else: max(32, cols - 2)))

proc findLastCommittedBoundary(buf: string, fromIdx: int): int =
  ## Find the last safe block boundary after the committed prefix.
  var i = fromIdx
  var inFence = false
  var fenceCh = '\0'
  var fenceCnt = 0
  var lastSafe = fromIdx

  while i < buf.len:
    let lineEnd = buf.find('\n', i)
    let curEnd = if lineEnd < 0: buf.len else: lineEnd
    let line = buf[i ..< curEnd]

    if not inFence:
      let fo = parseFenceOpen(line)
      if fo.isFence:
        inFence = true
        fenceCh = fo.ch
        fenceCnt = fo.count
      elif lineEnd >= 0 and line.strip().len == 0:
        # Blank line outside code fence commits everything up through this blank line!
        lastSafe = lineEnd + 1
    else:
      if isFenceClose(line, fenceCh, fenceCnt):
        inFence = false
        if lineEnd >= 0:
          lastSafe = lineEnd + 1

    if lineEnd < 0:
      break
    i = curEnd + 1

  lastSafe

proc stepStreamMarkdown*(
  smr: StreamMarkdownRenderer,
  delta: string,
  maxErasableLines = 18
): tuple[committedLines: seq[string], activeTailLines: seq[string]] =
  ## Append delta to rawBuffer and split into newly permanent scrollback lines + active erasable tail lines (used by DockViewport).
  if delta.len > 0:
    smr.rawBuffer.add(delta)

  let nextBoundary = findLastCommittedBoundary(smr.rawBuffer, smr.committedSourceLen)
  if nextBoundary > smr.committedSourceLen:
    let newlyCompleted = smr.rawBuffer[smr.committedSourceLen ..< nextBoundary]
    let width = if smr.committedBlockWidth > 0: smr.committedBlockWidth else: smr.maxWidth
    let fullBlockLines = renderMarkdown(newlyCompleted, width)
    let startLine = min(smr.committedExtraLines, fullBlockLines.len)
    for idx in startLine ..< fullBlockLines.len:
      result.committedLines.add(fullBlockLines[idx])
    if fullBlockLines.len > 0:
      result.committedLines.add("")
    smr.committedSourceLen = nextBoundary
    smr.committedExtraLines = 0
    smr.committedBlockWidth = 0

  let tailSource = if smr.committedSourceLen < smr.rawBuffer.len:
    smr.rawBuffer[smr.committedSourceLen .. ^1]
  else:
    ""

  if tailSource.strip().len > 0:
    let width = if smr.committedBlockWidth > 0: smr.committedBlockWidth else: smr.maxWidth
    let tailLines = renderMarkdown(tailSource, width)
    let cap = max(4, maxErasableLines)
    let firstTailLine = max(smr.committedExtraLines, tailLines.len - cap)
    let firstLineEnd = tailSource.find('\n')
    # Later table rows and inline closers can change already-rendered lines. Only code fence lines are stable here.
    if firstTailLine > smr.committedExtraLines and firstLineEnd >= 0 and
        parseFenceOpen(tailSource[0 ..< firstLineEnd]).isFence:
      for idx in smr.committedExtraLines ..< firstTailLine:
        result.committedLines.add(tailLines[idx])
      smr.committedExtraLines = firstTailLine
      smr.committedBlockWidth = width
    for idx in firstTailLine ..< tailLines.len:
      result.activeTailLines.add(tailLines[idx])

proc flushStreamMarkdown*(smr: StreamMarkdownRenderer): seq[string] =
  ## Flush any remaining un-committed Markdown lines at the end of an assistant stream and reset smr.
  if smr.rawBuffer.len == 0:
    return @[]
  if smr.committedSourceLen < smr.rawBuffer.len:
    let tailSource = smr.rawBuffer[smr.committedSourceLen .. ^1]
    if tailSource.strip().len > 0:
      let width = if smr.committedBlockWidth > 0: smr.committedBlockWidth else: smr.maxWidth
      let tailLines = renderMarkdown(tailSource, width)
      for idx in smr.committedExtraLines ..< tailLines.len:
        result.add(tailLines[idx])
  smr.rawBuffer = ""
  smr.committedSourceLen = 0
  smr.committedExtraLines = 0
  smr.committedBlockWidth = 0
  smr.ephemeralLineCount = 0

proc feedDelta*(smr: StreamMarkdownRenderer, delta: string) =
  ## Append streamed text delta and update terminal display without corrupting scrollback.
  if delta.len == 0:
    return
  if not colorsActive() or not isStdoutTty():
    smr.rawBuffer.add(delta)
    stdout.write(delta)
    stdout.flushFile()
    return

  let (_, termRows) = terminalSize()
  let drawnLines = smr.ephemeralLineCount
  let (committed, tail) = smr.stepStreamMarkdown(delta, termRows - 5)
  beginSyncOutput()
  clearRenderedLines(drawnLines)
  for line in committed: stdout.writeLine(line)
  for line in tail: stdout.writeLine(line)
  smr.ephemeralLineCount = tail.len
  endSyncOutput()

proc finishStream*(smr: StreamMarkdownRenderer) =
  ## Finalize any remaining active tail lines into permanent scrollback and reset state.
  if smr.rawBuffer.len == 0:
    return
  if not colorsActive() or not isStdoutTty():
    if not smr.rawBuffer.endsWith("\n"):
      stdout.write("\n")
    stdout.flushFile()
    smr.rawBuffer = ""
    return

  beginSyncOutput()
  clearRenderedLines(smr.ephemeralLineCount)
  for line in smr.flushStreamMarkdown(): stdout.writeLine(line)
  endSyncOutput()
