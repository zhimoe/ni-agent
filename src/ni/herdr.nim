import std/[os, osproc]

type
  HerdrState* = enum
    hsUnreported, hsIdle = "idle", hsWorking = "working", hsBlocked = "blocked", hsRelease

  ReporterContext = tuple[updates: ptr Channel[HerdrState], binary, pane: string]

  HerdrReporter* = ref object
    updates: Channel[HerdrState]
    worker: Thread[ReporterContext]
    latest: HerdrState

proc reportInBackground(context: ReporterContext) {.thread.} =
  while true:
    var state = context.updates[].recv()
    # Serialize requests and skip statuses superseded while Herdr was busy.
    while state != hsRelease:
      let pending = context.updates[].tryRecv()
      if not pending.dataAvailable: break
      state = pending.msg

    let action = if state == hsRelease: "release-agent" else: "report-agent"
    var args = @["pane", action, context.pane, "--source", "ni", "--agent", "Ni"]
    if state != hsRelease:
      args.add(["--state", $state])
    try:
      # Herdr's reply stays out of the TUI, even when the server is unavailable.
      let child = startProcess(context.binary, args = args, options = {poStdErrToStdOut})
      defer: child.close()
      discard child.waitForExit(timeout = 350)
    except CatchableError:
      discard
    if state == hsRelease: break

proc newHerdrReporter*(): HerdrReporter =
  if getEnv("HERDR_ENV") != "1": return nil
  let binary = getEnv("HERDR_BIN_PATH")
  let pane = getEnv("HERDR_PANE_ID")
  if binary.len == 0 or pane.len == 0: return nil
  let reporter = HerdrReporter()
  reporter.updates.open()
  try:
    createThread(reporter.worker, reportInBackground, (addr reporter.updates, binary, pane))
    result = reporter
  except CatchableError:
    reporter.updates.close()

proc state*(reporter: HerdrReporter): HerdrState =
  reporter.latest

proc report*(reporter: HerdrReporter, state: HerdrState) =
  if reporter.isNil or state == reporter.latest: return
  reporter.latest = state
  reporter.updates.send(state)

proc close*(reporter: HerdrReporter) =
  if reporter.isNil: return
  reporter.updates.send(hsRelease)
  joinThread(reporter.worker)
  reporter.updates.close()
