import std/[os, strtabs, strutils]
import ./[tools, trust, types, utf8]

type
  WorkspaceDiffSection* = object
    title*, patch*: string

  GitOutput = object
    text: string
    exitCode: int
    truncated: bool

const MaxUntrackedPreviews = 20

proc readWorkspaceDiff*(cwd: string, policy: SecurityPolicy): seq[WorkspaceDiffSection] =
  ## Read tracked changes and new files within the current workspace without using a shell.
  let git = findExe("git")
  if git.len == 0:
    raise newException(IOError, "Git is required for /diff.")
  let env = policy.processEnvironment()
  env["GIT_OPTIONAL_LOCKS"] = "0"

  proc capture(args: seq[string], maxBytes = DefaultMaxBytes): GitOutput =
    let flags = @["--no-pager", "-c", "core.quotePath=false", "-c", "core.fsmonitor=false"]
    let (exe, argv) = policy.wrapProcess(git, flags & args, cwd)
    let abort = newAbortFlag()
    var bytes = 0
    let reply = runProcessCapture(exe, argv, cwd, env, 5, abort, onOutput = proc(delta: string) =
      bytes += delta.len
      if bytes > maxBytes: abort.aborted = true
    )
    if reply.timedOut:
      raise newException(IOError, "Git did not finish reading the workspace within 5 seconds.")
    let endAt = min(maxBytes, reply.output.len)
    GitOutput(text: reply.output[0 ..< endAt], exitCode: reply.exitCode,
      truncated: abort.aborted or endAt < reply.output.len)

  let inside = capture(@["rev-parse", "--is-inside-work-tree"])
  if inside.exitCode != 0 or inside.text.strip() != "true":
    let detail = inside.text.strip()
    raise newException(IOError, if detail.len > 0: detail else: "This directory is not a Git worktree.")

  proc checkedPatch(response: GitOutput, allowDifferences = false): string =
    if not response.truncated and response.exitCode != 0 and not (allowDifferences and response.exitCode == 1):
      raise newException(IOError, response.text.strip())
    let size = if response.truncated: completeUtf8Prefix(response.text) else: response.text.len
    let preview = truncateHead(replaceInvalidUtf8(response.text[0 ..< size]))
    result = preview.content
    if response.truncated or preview.truncated:
      result.add("\n[Diff truncated. Use Git to inspect the full changes.]")

  const diffArgs = @["diff", "--no-color", "--no-ext-diff", "--no-textconv"]
  for (title, flags) in [("Staged changes", @["--cached"]), ("Unstaged changes", newSeq[string]())]:
    let patch = checkedPatch(capture(diffArgs & flags & @["--relative", "--", "."]))
    if patch.len > 0: result.add(WorkspaceDiffSection(title: title, patch: patch))

  let untracked = capture(@["ls-files", "--others", "--exclude-standard", "-z", "--", "."])
  if not untracked.truncated and untracked.exitCode != 0:
    raise newException(IOError, untracked.text.strip())
  var paths = untracked.text.split('\0')
  # Ignore a possibly partial last filename after an output cap.
  paths.setLen(max(0, paths.len - 1))
  if paths.len == 0 and not untracked.truncated: return

  var patch = ""
  for i, path in paths:
    if patch.len >= DefaultMaxBytes:
      patch.add("\n[Untracked list truncated. Use git status to see all paths.]")
      break
    let label = replaceInvalidUtf8(path).replace("\r", "\\r").replace("\n", "\\n")
    if i >= MaxUntrackedPreviews:
      patch.add("? " & label & "\n")
      continue
    let diff = capture(diffArgs & @["--no-index", "--", "/dev/null", path], DefaultMaxBytes - patch.len)
    if not diff.truncated and (diff.exitCode notin [0, 1] or diff.text.len == 0):
      patch.add("? " & label & "\n")
    else:
      patch.add(checkedPatch(diff, allowDifferences = true) & "\n")
  if paths.len > MaxUntrackedPreviews:
    patch.add("\n[Only the first " & $MaxUntrackedPreviews & " untracked files have patch previews.]")
  if untracked.truncated:
    patch.add("\n[Untracked list truncated. Use git status to see all paths.]")
  result.add(WorkspaceDiffSection(title: "Untracked files", patch: patch))
