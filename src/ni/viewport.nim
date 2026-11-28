# Fixed-layout transcript viewport: in-app scrollback, pinned message headers, and full-screen composition for the alternate-buffer TUI.

import std/strutils
import ./[editor, terminal_io]

type
  SegmentKind* = enum
    segUser = "you"
    segAssistant = "assistant"
    segThinking = "thinking"
    segTool = "tool"
    segNotice = "notice"

  Segment* = object
    kind*: SegmentKind
    title*: string
    entryId*: string

  ScreenSelection* = object
    anchor*, head*: ScreenPoint

  Transcript* = ref object
    ## Committed transcript rows plus the live (re-rendered) tail, grouped into message segments.
    segments*: seq[Segment]
    segStart*: seq[int]
    lines*: seq[string]
    lineSeg*: seq[int]
    tail*: seq[string]
    tailSeg*: int
    scrollUp*: int
    visibleRows: int

proc beginSegment*(t: Transcript, kind: SegmentKind, title = "", entryId = ""): int =
  ## Open a new logical message block; committed rows and the live tail attach to it.
  result = t.segments.len
  t.segments.add(Segment(kind: kind, title: title, entryId: entryId))
  t.segStart.add(t.lines.len)
  t.tailSeg = result

proc newTranscript*(): Transcript =
  ## Create an empty transcript with a placeholder segment for boot output.
  result = Transcript(tailSeg: 0)
  discard result.beginSegment(segNotice)

proc currentSegment*(t: Transcript): int =
  t.segments.high

proc addLines*(t: Transcript, newLines: openArray[string]) =
  ## Commit permanent transcript rows into the current segment, keeping a scrolled-up view anchored.
  if newLines.len == 0:
    return
  if t.scrollUp > 0:
    t.scrollUp += newLines.len
  let seg = t.segments.high
  for line in newLines:
    t.lines.add(line)
    t.lineSeg.add(seg)

proc setTail*(t: Transcript, tailLines: openArray[string]) =
  ## Replace the live tail rows of the current segment without moving a scrolled-up view.
  if t.scrollUp > 0:
    t.scrollUp += tailLines.len - t.tail.len
  t.tail = @tailLines
  t.tailSeg = t.segments.high

proc clearTail*(t: Transcript) =
  t.setTail([])

proc totalLines*(t: Transcript): int =
  t.lines.len + t.tail.len

proc atBottom*(t: Transcript): bool =
  t.scrollUp <= 0

proc lineAt*(t: Transcript, idx: int): string =
  if idx < 0:
    return ""
  if idx < t.lines.len:
    t.lines[idx]
  elif idx - t.lines.len < t.tail.len:
    t.tail[idx - t.lines.len]
  else:
    ""

proc segmentAt*(t: Transcript, idx: int): int =
  if idx < t.lineSeg.len:
    t.lineSeg[idx]
  elif idx >= t.lines.len:
    t.tailSeg
  else:
    t.segments.high

proc maxScrollUp(t: Transcript): int =
  max(0, t.totalLines() - max(1, t.visibleRows))

proc scrollBy*(t: Transcript, delta: int) =
  ## Positive delta scrolls up into history; negative returns toward the live tail.
  if delta == 0:
    return
  t.scrollUp = clamp(t.scrollUp + delta, 0, t.maxScrollUp())

proc scrollToBottom*(t: Transcript) =
  t.scrollUp = 0

proc scrollToTop*(t: Transcript) =
  t.scrollUp = t.maxScrollUp()

proc revealLine*(t: Transcript, row: int) =
  ## Place a transcript row near the center of the viewport.
  let targetEnd = row + max(1, t.visibleRows div 2) + 1
  t.scrollUp = clamp(t.totalLines() - targetEnd, 0, t.maxScrollUp())

proc renderStickyHeader*(t: Transcript, segIdx, above, width: int): string =
  ## Render the pinned one-line header of the message that owns the topmost visible row.
  let seg = t.segments[clamp(segIdx, 0, t.segments.high)]
  let label = case seg.kind
    of segUser: styleCyan("❯ you")
    of segAssistant: styleGreen("⏺ assistant")
    of segThinking: styleDim("💭 thinking")
    of segTool: styleYellow("● tool")
    of segNotice: styleMagenta("• note")
  let rightText = styleDim($above & " lines above" & (if t.atBottom(): "" else: " · End ⇣"))
  let prefix = styleDim("── ")
  let fixedW = visibleWidth(prefix) + visibleWidth(rightText) + 2
  var leftText = label
  let title = seg.title.replace("\r", " ").replace("\n", " ").strip()
  let titleAvail = width - fixedW - 10
  if title.len > 0 and titleAvail > 4:
    leftText.add(styleDim(" · " & truncateVisible(title, titleAvail)))
  let fill = max(1, width - fixedW - visibleWidth(leftText))
  let header = prefix & leftText & styleDim(" " & "─".repeat(fill) & " ") & rightText
  fitScreenRow(header, width)

proc renderHistory*(t: Transcript, width, rows: int): seq[string] =
  ## Show up to one page of history while following the live tail or a scrolled position.
  result = newSeq[string](max(0, rows))
  if rows <= 0:
    return
  t.visibleRows = rows
  t.scrollUp = clamp(t.scrollUp, 0, t.maxScrollUp())
  let total = t.totalLines()
  if total == 0:
    return
  let inner = max(1, width)
  let endIdx = total - t.scrollUp
  var startIdx = max(0, endIdx - rows)
  var headerRows = 0
  if startIdx > 0 and rows > 1:
    let seg = t.segmentAt(startIdx + 1)
    if t.segStart[seg] < startIdx:
      inc startIdx
      result[0] = t.renderStickyHeader(seg, startIdx, inner)
      headerRows = 1
  var row = headerRows
  var idx = startIdx
  while idx < endIdx and row < rows:
    result[row] = fitScreenRow(t.lineAt(idx), inner)
    inc idx
    inc row

proc composeScreen*(t: Transcript, ed: InputEditor, status: EditorStatusInfo, cols, rows: int,
                    caret: ptr EditorCaret = nil): seq[string] =
  ## Build one full-screen frame: scrollable transcript on top, docked input box + status line pinned to the bottom rows.
  ## The rightmost column is left free so painting a row can never trigger terminal auto-wrap.
  let width = max(1, cols - 1)
  var dockLines = renderEditorFrame(ed, status, width, max(4, rows - 2), caret)
  if dockLines.len > rows - 2:
    dockLines.setLen(max(1, rows - 2))
  let historyRows = max(0, rows - dockLines.len)
  if not caret.isNil:
    caret[].row += historyRows
  result = t.renderHistory(width, historyRows)
  for line in dockLines:
    result.add(fitScreenRow(line, width))
  if result.len > rows:
    result.setLen(rows)
  elif result.len < rows:
    result.add(newSeq[string](rows - result.len))

proc historyView*(t: Transcript): tuple[rows, endLine: int] =
  (t.visibleRows, t.totalLines() - t.scrollUp)

proc selectionBounds(selection: ScreenSelection): tuple[first, last: ScreenPoint] =
  if selection.anchor <= selection.head: (selection.anchor, selection.head)
  else: (selection.head, selection.anchor)

proc selectionColumns(first, last: ScreenPoint, row: int): tuple[start, past: int] =
  let start = if row == first.row: first.col else: 0
  let past = if row == last.row: last.col + 1 else: high(int)
  (start, past)

proc highlightSelection*(frame: var seq[string], selection: ScreenSelection) =
  if selection.anchor == selection.head: return
  let (first, last) = selection.selectionBounds()
  for row in first.row .. min(last.row, frame.high):
    let (start, past) = selectionColumns(first, last, row)
    frame[row] = selectScreenCells(frame[row], start, past, paint = true)

proc selectedText*(frame: openArray[string], selection: ScreenSelection, caret: ScreenPoint): string =
  let (first, last) = selection.selectionBounds()
  for row in first.row .. min(last.row, frame.high):
    if row > first.row: result.add('\n')
    let (start, past) = selectionColumns(first, last, row)
    let marker = if not colorsActive() and caret.row == row: caret.col else: -1
    result.add(selectScreenCells(frame[row], start, past, cursorMarker = marker).strip(leading = false, chars = {' '}))

proc paintDiff*(previous, frame: seq[string], fullRepaint = false,
                historyRows = 0, scrollRows = 0): string =
  ## Repaint changed rows. For a matching history shift, let the terminal move
  ## the existing body rows while keeping the header and dock in place.
  let full = fullRepaint or previous.len != frame.len
  var scroll = false
  if not full and historyRows in 3 .. frame.len and
      scrollRows != 0 and abs(scrollRows) < historyRows - 2:
    let first = max(1, 1 - scrollRows)
    let past = min(historyRows, historyRows - scrollRows)
    var reused = 0
    for row in first ..< past:
      if previous[row + scrollRows] != frame[row]:
        reused = 0
        break
      if previous[row] != frame[row]:
        inc reused
    scroll = reused > abs(scrollRows)
  if scroll:
    result.add("\x1b[0m\x1b[2;" & $historyRows & "r\x1b[" & $abs(scrollRows) &
      (if scrollRows > 0: "S" else: "T") & "\x1b[r")
  for i in 0 ..< frame.len:
    let moves = scroll and i in 1 ..< historyRows
    let oldRow = if moves: i + scrollRows else: i
    let oldText = if full or (moves and oldRow notin 1 ..< historyRows): "" else: previous[oldRow]
    if full or oldText != frame[i]:
      result.add("\x1b[" & $(i + 1) & ";1H" & frame[i] & "\x1b[K")
