# Private child entry point. One request per process and no project startup hooks.

import std/[json, jsonutils, monotimes, options, os, times]
import ./[agent, config, provider, session, subagents, tools, trust, types, utf8]

proc watchParent() {.thread.} =
  # No more input is expected. The parent keeps this pipe open for its lifetime.
  var discarded: string
  while stdin.readLine(discarded): discard
  quit(130)

proc sendFrame(frame: JsonNode) =
  stdout.writeLine(encodeJsonUtf8(frame))
  stdout.flushFile()

proc clip(text: string): string =
  if text.len <= SubagentMaxResultBytes: return text
  text[0 ..< utf8BoundaryBefore(text, SubagentMaxResultBytes)] & "\n[Subagent output truncated]"

proc runSubagentWorker*(): int =
  var line: string
  if not stdin.readLine(line): return 1
  let request = jsonTo(parseJson(line), SubagentRequest)
  if request.task.len == 0 or request.task.len > SubagentMaxTaskBytes or request.agentDir.len == 0:
    return 1
  var parentWatcher: Thread[void]
  createThread(parentWatcher, watchParent)

  let cwd = getCurrentDir()
  let policy = newSecurityPolicy(cwd, request.agentDir, request.security)
  policy.workspaceReadsOnly = true
  var enabled: seq[string]
  for name in SubagentReadTools:
    if name in request.tools: enabled.add(name)
  let cfg = ConfigBundle(cwd: cwd, agentDir: request.agentDir, settings: NiSettings(
    httpProxy: request.proxy, httpIdleTimeoutMs: request.httpTimeoutMs, retry: request.retry),
    customSystemPrompt: "You are a read-only subagent. Complete the assigned project task within the current " &
      "workspace. The grep tool searches for literal text. Return concise findings with file references " &
      "and report any work you could not verify.")
  let registry = newProviderRegistry(cfg)
  registry.resolvedAccess = some(request.access)
  let sm = newSessionManager(cwd, "", persist = false)
  defer: sm.close()
  var model = request.model
  model.maxTokens = clamp(model.maxTokens, 1, SubagentMaxOutputTokens)
  let rt = newAgentRuntime(cfg, registry, newToolRegistry(enabled), nil, @[], policy, sm,
    model, request.thinking, maxTurnsPerRun = clamp(request.maxTurns, 1, SubagentMaxTurns))
  let abort = newAbortFlag()
  let started = getMonoTime()
  var timedOut = false
  abort.onIdle = proc() =
    if (getMonoTime() - started).inSeconds >= SubagentRunSeconds:
      timedOut = true
      abort.aborted = true
  var turns = 0
  let reply = rt.runPrompt(request.task, abort = abort, literalPrompt = true,
    onEvent = proc(ev: AgentEvent) =
      case ev.kind
      of aekTurnStart: turns = ev.turnIndex
      of aekAssistantEnd:
        sendFrame(%*{"type": "usage", "turns": turns, "usage": toJson(sm.totalUsage)})
      else: discard)
  let detail = if timedOut: "Subagent exceeded its runtime limit"
    elif reply.errorMessage.len > 0: clip(reply.errorMessage)
    elif reply.stopReason == srTurnLimit: "Subagent reached its turn limit"
    else: ""
  sendFrame(%*{"type": "result", "turns": turns, "usage": toJson(sm.totalUsage),
    "stopReason": (if timedOut: "timeout" else: $reply.stopReason),
    "output": clip(collectText(reply.assistantBlocks)), "error": detail})
  0
