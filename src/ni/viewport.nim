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

  Transcript* = ref object
    ## Committed transcript rows plus the live (re-rendered) tail, grouped into message segments.
    segments*: seq[Segment]
    segStart*: seq[int]
    lines*: seq[string]
    lineSeg*: seq[int]
    tail*: seq[string]
    tailSeg*: int
    scrollUp*: int

proc beginSegment*(t: Transcript, kind: SegmentKind, title = ""): int =
  ## Open a new logical message block; committed rows and the live tail attach to it.
  result = t.segments.len
  t.segments.add(Segment(kind: kind, title: title))
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

proc clampView(t: Transcript) =
  t.scrollUp = clamp(t.scrollUp, 0, max(0, t.totalLines() - 1))

proc scrollBy*(t: Transcript, delta: int) =
  ## Positive delta scrolls up into history; negative returns toward the live tail.
  if delta == 0:
    return
  t.scrollUp += delta
  t.clampView()

proc scrollToBottom*(t: Transcript) =
  t.scrollUp = 0

proc scrollToTop*(t: Transcript) =
  t.scrollUp = max(0, t.totalLines() - 1)

proc renderStickyHeader*(t: Transcript, segIdx, above, width: int): string =
  ## Render the pinned one-line header of the message that owns the topmost visible row.
  let seg = t.segments[clamp(segIdx, 0, t.segments.high)]
  let label = case seg.kind
    of segUser: styleCyan("❯ you")
    of segAssistant: styleGreen("⏺ assistant")
    of segThinking: styleDim("💭 thinking")
    of segTool: styleYellow("● tool")
    of segNotice: styleMagenta("• note")
  let rightText = styleDim($above & " lines above · End ⇣")
  let prefix = styleDim("── ")
  let fixedW = visibleWidth(prefix) + visibleWidth(rightText) + 2
  var leftText = label
  let title = seg.title.replace("\r", " ").replace("\n", " ").strip()
  let titleAvail = width - fixedW - 10
  if title.len > 0 and titleAvail > 4:
    leftText.add(styleDim(" · " & truncateVisible(title, titleAvail)))
  let fill = max(1, width - fixedW - visibleWidth(leftText))
  result = prefix & leftText & styleDim(" " & "─".repeat(fill) & " ") & rightText

proc renderHistory*(t: Transcript, width, rows: int): seq[string] =
  ## Return exactly `rows` bottom-anchored transcript rows, pinning the active message header while scrolled.
  result = newSeq[string](max(0, rows))
  if rows <= 0:
    return
  let total = t.totalLines()
  if total == 0:
    return
  let inner = max(1, width)
  var endIdx = clamp(total - t.scrollUp, 1, total)
  var startIdx = max(0, endIdx - rows)
  var headerRows = 0
  if t.scrollUp > 0 and startIdx > 0 and t.segments.len > 0:
    let seg = t.segmentAt(startIdx)
    if t.segStart[seg] < startIdx:
      result[0] = t.renderStickyHeader(seg, startIdx, inner)
      headerRows = 1
      startIdx = max(0, endIdx - (rows - headerRows))
  var row = headerRows
  var idx = startIdx
  while idx < endIdx and row < rows:
    result[row] = truncateVisible(t.lineAt(idx), inner, ellipsis = "")
    inc idx
    inc row

proc composeScreen*(t: Transcript, ed: InputEditor, status: EditorStatusInfo, cols, rows: int): seq[string] =
  ## Build one full-screen frame: scrollable transcript on top, docked input box + status line pinned to the bottom rows.
  ## The rightmost column is left free so painting a row can never trigger terminal auto-wrap.
  let width = max(1, cols - 1)
  var dockLines = renderEditorFrame(ed, status, width, max(4, rows - 2))
  if dockLines.len > rows - 2:
    dockLines.setLen(max(1, rows - 2))
  let historyRows = max(0, rows - dockLines.len)
  result = t.renderHistory(width, historyRows)
  for line in dockLines:
    result.add(truncateVisible(line, width, ellipsis = ""))
  if result.len > rows:
    result.setLen(rows)
  elif result.len < rows:
    result.add(newSeq[string](rows - result.len))

proc paintDiff*(previous, frame: seq[string], fullRepaint = false): string =
  ## Emit the minimal absolute-positioned repaint for the rows that actually changed.
  let full = fullRepaint or previous.len != frame.len
  for i in 0 ..< frame.len:
    if full or i >= previous.len or previous[i] != frame[i]:
      result.add("\x1b[" & $(i + 1) & ";1H" & frame[i] & "\x1b[K")
