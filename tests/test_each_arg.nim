# `eachArg`, which visits a Spec Tuple's Args the way `newSpec` registers
# them (#340).

import std/[os, osproc, strutils, unittest]

import argumint

import ./fixtures/eacharg_report

proc checkErrors(code: string): string =
  ## What `nim check` says about `code`, which starts on line 2 after
  ## `import argumint`.
  let
    dir = getTempDir() / "argumint_t340_" & $getCurrentProcessId()
    src = dir / "snippet.nim"
  createDir(dir)
  defer: removeDir(dir)
  writeFile(src, "import argumint\n" & code)
  let srcDir = currentSourcePath().parentDir.parentDir / "src"
  execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "check", "--hints:off",
    "--path:" & srcDir, src])).output

suite "eachArg":
  test "an Arg in two nested tuples is visited once, under its first leaf name":
    let
      target = opt("--target=<t>")
      spec = (
        build: (target: target, jobs: opt("--jobs=<n>")),
        test: (target: target, filters: opts("--filter=<f>")),
        verbose: flag("-v"))
    var names: seq[string]
    spec.eachArg(name, arg):
      names.add name
    check names == @["target", "jobs", "filters", "verbose"]

  test "an anonymous tuple's fields are named Field0, Field1, ...":
    let spec = (flag("-a"), (flag("-b"), flag("-c")))
    var names: seq[string]
    spec.eachArg(name, arg):
      names.add name
    check names == @["Field0", "Field0", "Field1"]

  test "a generic proc in another module reads each Arg by its own type":
    let spec = (
      verbose: flag[int](ops = "-v+=1"),
      keys: (target: opt("--target=<t>"), filters: opts("--filter=<f>")),
      dryRun: flag("--dry-run"))
    spec.parse(args = @["--filter=io", "-vv", "--target=arm64",
      "--filter=net"], command = "prog")
    check seenValues(spec) == @["verbose=2", "target=arm64", "filters=io",
      "filters=net"]

  test "a Command is visited, but not its own spec's Args":
    let spec = (
      ship: command("ship", (name: arg("<name>"), speed: opt("--speed=<kn>"))),
      verbose: flag("-v"))
    var names: seq[string]
    var commands = 0
    spec.eachArg(name, arg):
      names.add name
      when arg is CommandArg:
        inc commands
    check names == @["ship", "verbose"]
    check commands == 1

  test "Message Arguments are visited":
    let spec = (verbose: flag("-v"), help: help(), version: version("--version", "1.0"))
    var names: seq[string]
    spec.eachArg(name, arg):
      names.add name
    check names == @["verbose", "help", "version"]

  test "break ends the walk after the current Arg":
    let spec = (a: flag("-a"), b: flag("-b"), c: flag("-c"))
    var visited: seq[string]
    spec.eachArg(name, arg):
      visited.add name
      if name == "b":
        break
      visited.add "after " & name
    check visited == @["a", "after a", "b"]

  test "continue skips the rest of the body for the current Arg":
    let spec = (a: flag("-a"), b: flag("-b"), c: flag("-c"))
    var visited: seq[string]
    spec.eachArg(name, arg):
      if name == "b":
        continue
      visited.add name
    check visited == @["a", "c"]

  test "break and continue in a loop the body opens keep their meaning":
    let spec = (a: flag("-a"), b: flag("-b"))
    var visited: seq[string]
    spec.eachArg(name, arg):
      for i in 1 .. 3:
        if i == 2: continue
        if i == 3: break
        visited.add name & $i
      visited.add name
    check visited == @["a1", "a", "b1", "b"]

  test "break in a block the body opens leaves only that block":
    let spec = (a: flag("-a"), b: flag("-b"))
    var visited: seq[string]
    # Deprecated, but it still leaves only the block.
    {.push warning[UnnamedBreak]: off.}
    spec.eachArg(name, arg):
      block:
        if name == "a": break
        visited.add "inner " & name
      visited.add name
    {.pop.}
    check visited == @["a", "inner b", "b"]

  test "break and continue in a nested eachArg act on the nested one":
    let spec = (a: flag("-a"), b: flag("-b"))
    var visited: seq[string]
    spec.eachArg(outer, _):
      spec.eachArg(inner, _):
        if inner == "a": continue
        visited.add outer & inner
        break
      visited.add outer
    check visited == @["ab", "a", "bb", "b"]

  test "a member that is neither an Arg nor a tuple is a compile error":
    # The same for `newSpec`, which registers what `eachArg` visits.
    let errors = checkErrors("""
let spec = (verbose: flag("-v"), keys: (depth: 3))
spec.eachArg(name, arg):
  discard name
discard newSpec(spec)
""")
    check errors.count("Error: all members of a spec tuple must be args " &
      "or tuples, but depth is int") == 2
