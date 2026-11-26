# Brand identity for ni: emoji, startup wordmark, and ANSI gradient rendering.

import std/[os, strutils, unicode]
import ./terminal_io

const
  NiEmoji* = "🌿"
  NiLogoIndent = 2
  # Compact four-row n; the i is a thin stem capped with a spark.
  NiWordmark = [
    "██   █  ✦",
    "█ █  █  █",
    "█  █ █  █",
    "█   ██  █",
  ]
  SparkRune = Rune(0x2726)
  # The spark keeps a fixed bright yellow accent instead of following the gradient.
  SparkColor = (r: 255, g: 230, b: 0)

type
  Rgb = tuple[r, g, b: int]

const
  # green → teal → sky → violet, echoing the multicolor agy logo.
  WordmarkStops: array[4, Rgb] = [
    (r: 134, g: 239, b: 172),
    (r: 45, g: 212, b: 191),
    (r: 56, g: 189, b: 248),
    (r: 168, g: 85, b: 247),
  ]

proc mix(lo, hi, t: float): int =
  int(lo + (hi - lo) * t + 0.5)

proc sampleGradient(stops: openArray[Rgb], t: float): Rgb =
  if stops.len == 1:
    return stops[0]
  let clamped = max(0.0, min(1.0, t))
  let scaled = clamped * float(stops.len - 1)
  var idx = int(scaled)
  if idx > stops.len - 2:
    idx = stops.len - 2
  let f = scaled - float(idx)
  let lo = stops[idx]
  let hi = stops[idx + 1]
  (r: mix(float(lo.r), float(hi.r), f),
   g: mix(float(lo.g), float(hi.g), f),
   b: mix(float(lo.b), float(hi.b), f))

proc truecolorAvailable(): bool =
  let colorTerm = getEnv("COLORTERM").toLowerAscii()
  if colorTerm.contains("truecolor") or colorTerm.contains("24bit"):
    return true
  let term = getEnv("TERM").toLowerAscii()
  let prog = getEnv("TERM_PROGRAM").toLowerAscii()
  for name in ["kitty", "wezterm", "ghostty", "alacritty", "iterm", "vscode"]:
    if term.contains(name) or prog.contains(name):
      return true
  false

proc ansi256Index(c: Rgb): int =
  let r = int(float(c.r) / 255.0 * 5.0 + 0.5)
  let g = int(float(c.g) / 255.0 * 5.0 + 0.5)
  let b = int(float(c.b) / 255.0 * 5.0 + 0.5)
  16 + 36 * r + 6 * g + b

proc paintGlyph(glyph: string, c: Rgb, truecolor: bool): string =
  if truecolor:
    styleRgb(glyph, c.r, c.g, c.b)
  else:
    styleAnsi256(glyph, ansi256Index(c))

proc lineWidth(line: string): int =
  var i = 0
  while i < line.len:
    var r: Rune
    fastRuneAt(line, i, r, doInc = true)
    result += runeDisplayWidth(r)

proc renderNiLogo*(indent = NiLogoIndent): seq[string] =
  ## Render the ni wordmark with a green→teal→sky→violet gradient.
  var maxCols = 0
  for art in NiWordmark:
    maxCols = max(maxCols, lineWidth(art))
  let rows = NiWordmark.len
  let useTruecolor = truecolorAvailable()
  for row in 0 ..< rows:
    let art = NiWordmark[row]
    var line = spaces(indent)
    var i = 0
    var col = 0
    while i < art.len:
      var r: Rune
      fastRuneAt(art, i, r, doInc = true)
      let w = runeDisplayWidth(r)
      if r == Rune(ord(' ')):
        line.add(' ')
      elif r == SparkRune:
        line.add(paintGlyph($r, SparkColor, useTruecolor))
      else:
        let t = (float(col) + float(row) * 1.6) /
                (float(maxCols - 1) + float(rows - 1) * 1.6)
        let c = sampleGradient(WordmarkStops, t)
        line.add(paintGlyph($r, c, useTruecolor))
      inc col, w
    result.add(line)
