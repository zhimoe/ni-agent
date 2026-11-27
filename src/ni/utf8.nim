# UTF-8 byte boundaries for clipping text and validating provider payloads.

import std/json

const ContinuationBytes = {'\x80'..'\xBF'}

proc utf8BoundaryBefore*(text: string, offset: int): int =
  ## Move a byte limit back to the start of a character it would split.
  result = offset
  while result > 0 and result < text.len and text[result] in ContinuationBytes:
    dec result

proc utf8BoundaryAfter*(text: string, offset: int): int =
  ## Advance a suffix start past any partial character.
  result = offset
  while result < text.len and text[result] in ContinuationBytes:
    inc result

proc completeUtf8Prefix*(text: string): int =
  ## Hold a possible incomplete trailing character until the next stream chunk.
  if text.len == 0:
    return 0
  var start = text.high
  while start > 0 and text.high - start < 3 and text[start] in ContinuationBytes:
    dec start
  let length = case text[start]
    of '\xC2'..'\xDF': 2
    of '\xE0'..'\xEF': 3
    of '\xF0'..'\xF4': 4
    else: 1
  if text.len - start < length: start else: text.len

proc replaceInvalidUtf8*(text: string): string =
  ## Replace malformed sequences with U+FFFD, preserving every valid UTF-8 byte.
  var i = 0
  var copyFrom = 0
  while i < text.len:
    let start = i
    # Restrict the second byte to exclude overlong encodings, surrogates,
    # and code points beyond U+10FFFF.
    let (length, secondBytes) = case text[i]
      of '\x00'..'\x7F': (1, ContinuationBytes)
      of '\xC2'..'\xDF': (2, ContinuationBytes)
      of '\xE0': (3, {'\xA0'..'\xBF'})
      of '\xE1'..'\xEC', '\xEE'..'\xEF': (3, ContinuationBytes)
      of '\xED': (3, {'\x80'..'\x9F'})
      of '\xF0': (4, {'\x90'..'\xBF'})
      of '\xF1'..'\xF3': (4, ContinuationBytes)
      of '\xF4': (4, {'\x80'..'\x8F'})
      else: (0, {})
    inc i
    if length > 1 and i < text.len and text[i] in secondBytes:
      inc i
      while i - start < length and i < text.len and text[i] in ContinuationBytes:
        inc i
    if i - start != length:
      if copyFrom == 0:
        result = newStringOfCap(text.len)
      result.add(text[copyFrom ..< start])
      result.add("�")
      copyFrom = i
  if copyFrom == 0:
    return text
  result.add(text[copyFrom ..< text.len])

proc encodeJsonUtf8*(node: JsonNode): string =
  ## Nim escapes JSON syntax but otherwise emits string bytes verbatim.
  replaceInvalidUtf8($node)
