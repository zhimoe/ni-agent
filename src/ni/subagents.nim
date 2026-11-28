# Per-run supervisor for independent read-only agent processes.

import std/[json, jsonutils, monotimes, os, osproc, streams, strtabs, strutils, tables, times]
when defined(posix):
  import std/posix
import ./[config, provider, tools, types, utf8]

const
  SubagentWorkerArg* = "--internal-subagent-worker"
  SubagentReadTools* = ["read", "grep", "find", "ls"]
  SubagentMaxTurns* = 8
  SubagentMaxOutputTokens* = 4096
  SubagentRunSeconds* = 120
  SubagentMaxTaskBytes* = 12 * 1024
  SubagentMaxResultBytes* = 12 * 1024
  SubagentMaxConcurrent = 4
  SubagentMaxPerRun = 12
  SubagentMaxWaitMs = 30000
  WorkerMaxReplyBytes = 160 * 1024

type
  SubagentRequest* = object
    task*, agentDir*: string
    model*: ModelConfig
    access*: ProviderAccess
    thinking*: ThinkingLevel
    security*: SecurityMode
    tools*: seq[string]
    maxTurns*: int
    proxy*: string
    httpTimeoutMs*: int
    retry*: RetrySettings

  SubagentState* = enum
    saRunning = "running"
    saCompleted = "completed"
    saFailed = "failed"
    saCancelled = "cancelled"
    saTimedOut = "timedOut"

  SubagentJob = ref object
    task: string
    state: SubagentState
    child: Process
    started: MonoTime
    pending: string
    turns: int
    usage: Usage
    resultText, stopReason, error: string
    receivedResult: bool

  SubagentPool* = ref object
    cwd: string
    jobs: OrderedTable[string, SubagentJob]

proc newSubagentPool*(cwd: string): SubagentPool =
  SubagentPool(cwd: cwd)

proc toolReply(node: JsonNode): ToolOutput =
  ToolOutput(content: @[textBlock(encodeJsonUtf8(node))])

proc subagentToolError*(message: string): ToolOutput =
  ToolOutput(content: @[textBlock(message)], isError: true)

proc subagentJobJson(id: string, job: SubagentJob, includeOutput = false): JsonNode =
  result = %*{"id": id, "status": $job.state, "task": job.task, "turns": job.turns,
    "usage": toJson(job.usage)}
  if job.stopReason.len > 0: result["stopReason"] = %job.stopReason
  if job.error.len > 0: result["error"] = %job.error
  if includeOutput and job.receivedResult: result["output"] = %job.resultText

proc closeChild(job: SubagentJob, terminate: bool) =
  let child = job.child
  if child.isNil: return
  job.child = nil
  try:
    if terminate and child.peekExitCode() == -1:
      try: child.kill()
      except OSError: discard # The worker can exit between checking and signalling.
    discard child.waitForExit()
  finally:
    child.close()
    job.pending.setLen(0)

proc stop(job: SubagentJob, state: SubagentState, reason: string) =
  job.state = state
  job.error = reason
  job.closeChild(terminate = true)

proc readWorkerOutput(job: SubagentJob) =
  while true:
    let (chunk, _) = readAvailableFd(job.child.outputHandle())
    if chunk.len == 0: break
    job.pending.add(chunk)
    if job.pending.len > WorkerMaxReplyBytes:
      raise newException(IOError, "Subagent exceeded its output limit")
    while true:
      let newline = job.pending.find('\n')
      if newline < 0: break
      let frame = parseJson(job.pending[0 ..< newline])
      job.pending = job.pending[newline + 1 .. ^1]
      job.turns = frame{"turns"}.getInt()
      job.usage = parseUsage(frame{"usage"})
      case frame{"type"}.getStr()
      of "usage": discard
      of "result":
        job.receivedResult = true
        job.resultText = frame{"output"}.getStr()
        job.stopReason = frame{"stopReason"}.getStr()
        job.error = frame{"error"}.getStr()
      else:
        raise newException(IOError, "Invalid response from subagent")

proc poll*(pool: SubagentPool) =
  for job in pool.jobs.values:
    if job.child.isNil: continue
    try:
      job.readWorkerOutput()
      let code = job.child.peekExitCode()
      if code != -1:
        job.readWorkerOutput()
        job.closeChild(terminate = false)
        if code == 0 and job.receivedResult:
          job.state = case job.stopReason
            of $srStop: saCompleted
            of "timeout": saTimedOut
            else: saFailed
        else:
          job.state = saFailed
          job.error = "Subagent process exited without a result (exit code " & $code & ")"
      elif (getMonoTime() - job.started).inSeconds >= SubagentRunSeconds:
        job.stop(saTimedOut, "Subagent exceeded its runtime limit")
    except CatchableError:
      job.stop(saFailed, "Could not read the subagent result")

proc close*(pool: SubagentPool) =
  pool.poll()
  for job in pool.jobs.values:
    if not job.child.isNil:
      job.stop(saCancelled, "Parent run ended")

proc spawn*(pool: SubagentPool, task: string, prepare: proc(): SubagentRequest {.closure.}): ToolOutput =
  if task.len == 0 or task.len > SubagentMaxTaskBytes:
    return subagentToolError("Provide a nonempty task under " & $SubagentMaxTaskBytes & " bytes.")
  pool.poll()
  if pool.jobs.len >= SubagentMaxPerRun:
    return subagentToolError("Reached the subagent task limit for this run.")
  var running = 0
  for job in pool.jobs.values:
    if job.state == saRunning: inc running
  if running >= SubagentMaxConcurrent:
    return subagentToolError("All " & $SubagentMaxConcurrent & " subagent slots are in use. Wait for or cancel a running subagent.")

  var request = prepare()
  if request.access.error.len > 0: return subagentToolError(request.access.error)
  request.task = task
  let payload = encodeJsonUtf8(toJson(request))
  # Pass only the runtime environment needed by the worker. Credentials go over the private pipe.
  let env = newStringTable(when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii() in ["PATH", "SYSTEMROOT", "WINDIR", "SSL_CERT_FILE", "SSL_CERT_DIR",
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "LANG", "TZ"]:
      env[key] = value
  let child = startProcess(getAppFilename(), workingDir = pool.cwd, args = [SubagentWorkerArg],
    env = env, options = {poDaemon, poStdErrToStdOut})
  let preview = if task.len <= 240: task else: task[0 ..< utf8BoundaryBefore(task, 240)] & "…"
  let job = SubagentJob(task: preview, child: child, started: getMonoTime())
  try:
    when defined(posix):
      # Other processes launched by the parent must not keep this worker's pipe open.
      for fd in [child.inputHandle(), child.outputHandle()]:
        if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1: raiseOSError(osLastError())
    child.inputStream.write(payload & "\n")
    child.inputStream.flush()
  except CatchableError:
    job.closeChild(terminate = true)
    return subagentToolError("Could not send the task to the subagent.")
  let id = "agent-" & $(pool.jobs.len + 1)
  pool.jobs[id] = job
  toolReply(subagentJobJson(id, job))

proc manage*(pool: SubagentPool, name: string, args: JsonNode, abort: AbortFlag): ToolOutput =
  pool.poll()
  case name
  of "list_agents":
    var agents = newJArray()
    for id, job in pool.jobs.pairs:
      agents.add(subagentJobJson(id, job))
    return toolReply(%*{"agents": agents})
  of "cancel_agent":
    let id = args{"id"}.getStr()
    if not pool.jobs.hasKey(id): return subagentToolError("Unknown subagent ID: " & id)
    let job = pool.jobs[id]
    if job.state == saRunning:
      job.stop(saCancelled, "Subagent cancelled")
    return toolReply(subagentJobJson(id, job, includeOutput = true))
  of "wait_agent":
    let requested = args{"ids"}
    if requested.isNil or requested.kind != JArray or requested.len == 0:
      return subagentToolError("Provide an array of one or more subagent IDs.")
    var ids: seq[string]
    for item in requested:
      let id = item.getStr()
      if not pool.jobs.hasKey(id): return subagentToolError("Unknown subagent ID: " & id)
      if id notin ids: ids.add(id)
    let timeoutMs = clamp(args{"timeoutMs"}.getInt(SubagentMaxWaitMs), 0, SubagentMaxWaitMs)
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while true:
      if abort.pollAbort(): return subagentToolError("Waiting for subagents was cancelled.")
      pool.poll()
      var allDone = true
      for id in ids:
        if pool.jobs[id].state == saRunning:
          allDone = false
          break
      if allDone or getMonoTime() >= deadline:
        var agents = newJArray()
        for id in ids: agents.add(subagentJobJson(id, pool.jobs[id], includeOutput = true))
        return toolReply(%*{"agents": agents, "allDone": allDone})
      sleep(30)
  else:
    return subagentToolError("Unknown subagent tool: " & name)

proc subagentTools*(): seq[AgentTool] =
  proc tool(name, description: string, parameters: JsonNode): AgentTool =
    AgentTool(name: name, description: description, parameters: parameters,
      execute: proc(args: JsonNode, ctx: ToolContext): ToolOutput =
        if ctx.subagentTool.isNil: subagentToolError("Subagents are unavailable in this run.")
        else: ctx.subagentTool(name, args))
  @[
    tool("spawn_agent",
      "Start an independent, read-only worker for a self-contained project task. Include the necessary context in task. " &
      "Spawn independent workers before waiting to run them in parallel. Collect needed results with wait_agent before ending your reply.",
      %*{"type": "object", "properties": {"task": {"type": "string", "description": "Self-contained task and expected findings"}},
         "required": ["task"]}),
    tool("list_agents", "List this run's subagents with their status and reported token usage.",
      %*{"type": "object", "properties": {}}),
    tool("wait_agent", "Wait for the selected subagents and return their status, findings, and reported usage.",
      %*{"type": "object", "properties": {
        "ids": {"type": "array", "items": {"type": "string"}},
        "timeoutMs": {"type": "integer", "minimum": 0, "maximum": SubagentMaxWaitMs}},
        "required": ["ids"]}),
    tool("cancel_agent", "Stop a subagent in this run and return its status.",
      %*{"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]})
  ]

proc subagentResultSummary*(name: string, output: ToolOutput): seq[string] =
  if name notin ["spawn_agent", "list_agents", "wait_agent", "cancel_agent"] or output.isError:
    return
  try:
    let reply = parseJson(collectText(output.content))
    let jobs = if reply.hasKey("agents"): reply["agents"] else: %*[reply]
    if jobs.kind != JArray: return
    for job in jobs:
      let id = job{"id"}.getStr()
      let status = job{"status"}.getStr()
      if not id.startsWith("agent-") or id.len <= 6 or not id[6 .. ^1].allCharsInSet(Digits):
        continue
      if status notin [$saRunning, $saCompleted, $saFailed, $saCancelled, $saTimedOut]:
        continue
      let tokens = job{"usage", "totalTokens"}.getInt()
      let usage = if tokens > 0: " · " & $tokens & " tok" else: ""
      result.add(id & " · " & status & usage)
  except CatchableError:
    discard
