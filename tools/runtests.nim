## Builds and runs the test suite for `nimble test`: compiles every target in
## parallel, then runs the binaries one at a time. A lone `nim c` spends about
## half its time in the single-threaded frontend, so compiling several at once
## roughly halves the suite on a 4-core machine (issue #97). Running stays
## serial so tests that set env vars or write temp files can't interfere.
##
## Targets are every `.nim` file under `src/` (sanity-compiling modules with no
## `when isMainModule` block, and running the embedded tests of those with
## one) plus every `tests/*.nim`. Build output goes to `nimcache/test/`. If
## any compile fails, every failure is named and no tests run; otherwise the
## run stops at the first failing test.

import std/[algorithm, os, osproc, sequtils, strutils]

const BuildDir = "nimcache" / "test"

type
  Target = object
    ## One file to compile and run.
    source: string
      ## Path to the `.nim` file, relative to the project root
    key: string
      ## `source` flattened into a unique name for its nimcache and binary

proc nimFiles(dir: string, recurse: bool): seq[string] =
  ## Every `.nim` file in `dir`, sorted; with `recurse`, followed by each
  ## subdirectory's, in sorted order.
  var files, dirs: seq[string]
  for kind, path in walkDir(dir):
    case kind
    of pcFile, pcLinkToFile:
      if path.endsWith(".nim"): files.add path
    of pcDir, pcLinkToDir:
      if recurse: dirs.add path
  result = files.sorted
  for sub in dirs.sorted:
    result.add nimFiles(sub, recurse)

proc findTargets(): seq[Target] =
  for source in nimFiles("src", recurse = true) & nimFiles("tests", recurse = false):
    let key = source.changeFileExt("").multiReplace(("/", "_"), ("\\", "_"))
    result.add Target(source: source, key: key)

proc binary(t: Target): string =
  absolutePath(BuildDir / "bin" / t.key.addFileExt(ExeExt))

proc compileCmd(t: Target): string =
  quoteShellCommand(["nim", "c", "--hints:off", "--warnings:off",
    "--nimcache:" & BuildDir / t.key, "-o:" & t.binary, t.source])

proc compileAll(targets: seq[Target]): seq[Target] =
  ## Compiles `targets` in parallel, returning the ones that failed. Output
  ## isn't captured -- see docs/gotchas.md -- but a clean compile prints
  ## nothing, and each error line names its file.
  let workers = max(countProcessors(), 1).min(targets.len)
  echo "Compiling ", targets.len, " files with ", workers, " workers..."
  var failed: seq[int]
  discard execProcesses(targets.mapIt(it.compileCmd), n = workers,
    afterRunEvent = proc (i: int, p: Process) =
      if p.peekExitCode != 0: failed.add i)
  for i in failed.sorted:
    result.add targets[i]

proc run(t: Target): int =
  ## Runs `t`'s binary with the project root as its working directory,
  ## streaming its output, and returns its exit code.
  let p = startProcess(t.binary, options = {poParentStreams})
  result = p.waitForExit
  p.close

proc main(): int =
  let
    targets = findTargets()
    failed = targets.compileAll
  if failed.len > 0:
    for t in failed:
      echo "== FAILED to compile ", t.source
    return 1
  for t in targets:
    echo "\n== ", t.source
    if t.run != 0:
      echo "\n== FAILED: ", t.source
      return 1

when isMainModule:
  quit main()
