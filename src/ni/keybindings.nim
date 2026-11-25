# Configurable Pi app shortcuts supported by Ni's terminal decoder.

import std/[json, os, strutils]
import ./terminal_io

const
  FollowUpBinding = "app.message.followUp"
  DEFAULT_APP_KEYBINDINGS = when defined(windows): {kkCtrlQ} else: {kkAltEnter}

proc decodeBinding(key: string): set[KeyKind] =
  case key.strip().toLowerAscii()
  of "alt+enter": {kkAltEnter}
  of "shift+enter", "ctrl+j": {kkNewline}
  of "shift+tab": {kkShiftTab}
  of "ctrl+a": {kkCtrlA}
  of "ctrl+e": {kkCtrlE}
  of "ctrl+g": {kkCtrlG}
  of "ctrl+k": {kkCtrlK}
  of "ctrl+l": {kkCtrlL}
  of "ctrl+n": {kkCtrlN}
  of "ctrl+p": {kkCtrlP}
  of "ctrl+q": {kkCtrlQ}
  of "ctrl+s": {kkCtrlS}
  of "ctrl+u": {kkCtrlU}
  of "ctrl+w": {kkCtrlW}
  of "ctrl+y": {kkCtrlY}
  of "pageup": {kkPageUp}
  of "pagedown": {kkPageDown}
  else: {}

proc loadFollowUpKeys*(agentDir: string): set[KeyKind] =
  ## Read the Pi follow-up shortcut from keybindings.json, retaining the platform default for unsupported values.
  let path = agentDir / "keybindings.json"
  if not fileExists(path):
    return DEFAULT_APP_KEYBINDINGS
  let config = try: parseFile(path) except CatchableError: return DEFAULT_APP_KEYBINDINGS
  let binding = config{FollowUpBinding}
  if not binding.isNil:
    case binding.kind
    of JString:
      result = decodeBinding(binding.getStr())
    of JArray:
      if binding.len == 0:
        return {}
      for key in binding:
        if key.kind == JString:
          result = result + decodeBinding(key.getStr())
    else:
      discard
  if result == {}:
    result = DEFAULT_APP_KEYBINDINGS
