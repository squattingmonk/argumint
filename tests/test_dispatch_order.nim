# Tests for the value-parsing/hook firing order -- see
# `docs/adr/0032-parse-all-values-before-dispatch.md`.

import std/[os, unittest]

import argumint

suite "values are parsed for the whole tree before any hook fires":
  test "a bad value in a child command fires no hook at any level":
    var log: seq[string]
    proc topBefore(spec: tuple, info: HookInfo) = log.add "top-before"
    proc topAfter(spec: tuple, info: HookInfo) = log.add "top-after"
    proc goBefore(spec: tuple, info: HookInfo) = log.add "go-before"
    proc goAfter(spec: tuple, info: HookInfo) = log.add "go-after"

    let sub = (port: opt("--port=<n>", default = 0, help = ""))
    let spec = (
      go: command("go", sub, before = goBefore, after = goAfter,
                  usage = "[--port=<n>]", help = ""),)

    expect ParseError:
      spec.parse(usage = "go", args = @["go", "--port", "abc"], command = "app",
                 before = topBefore, after = topAfter)
    # `after` doesn't fire either: no `before` completed, so nothing was
    # entered that needs cleanup.
    check log == newSeq[string]()

  test "a bad value from an env var fires no hook either":
    # The other half of the equivalence the test above establishes: the env
    # tier already raised before any hook, because applyFallbacks runs
    # before dispatch. This pins that down so the two tiers can't drift
    # apart again. Note `--port` is deliberately absent from `args` -- an
    # Arg matched on the command line never consults its env var.
    var log: seq[string]
    proc before(spec: tuple, info: HookInfo) = log.add "before"

    let sub = (port: opt("--port=<n>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""))
    let spec = (go: command("go", sub, usage = "[--port=<n>]", help = ""),)

    putEnv("ARGUMINT_TEST_PORT", "abc")
    try:
      expect ParseError:
        spec.parse(usage = "go", args = @["go"], command = "app", before = before)
    finally:
      delEnv("ARGUMINT_TEST_PORT")
    check log == newSeq[string]()

  test "a value that converts but fails validation also fires no hook":
    # The conversion tests above raise ParseError from the converter. A
    # validator failure is a separate path -- `99999` is a perfectly good
    # int, so it gets stored and only then rejected -- and CONTEXT.md's
    # Value Precedence entry promises an unconvertible *or invalid* value
    # raises before a hook. Covers both halves of that claim.
    var log: seq[string]
    proc topBefore(spec: tuple, info: HookInfo) = log.add "top-before"
    proc topAfter(spec: tuple, info: HookInfo) = log.add "top-after"

    let sub = (port: opt("--port=<n>", default = 80, validator = range(1..65535),
                         help = ""))
    let spec = (go: command("go", sub, usage = "[--port=<n>]", help = ""),)

    expect ValidationError:
      spec.parse(usage = "go", args = @["go", "--port", "99999"], command = "app",
                 before = topBefore, after = topAfter)
    check log == newSeq[string]()

  test "a parent's before hook reads a child command's parsed values":
    var seenPort = -1
    var seenName = "unset"
    let sub = (port: opt("--port=<n>", default = 0, help = ""),
               name: arg("<name>", default = "", help = ""))
    proc topBefore(spec: tuple, info: HookInfo) =
      seenPort = int(sub.port)
      seenName = string(sub.name)

    let spec = (go: command("go", sub, usage = "[--port=<n>] <name>", help = ""),)
    spec.parse(usage = "go", args = @["go", "--port", "8080", "titanic"],
               command = "app", before = topBefore)
    # Before this ADR both read as their coded defaults (0 and ""), even
    # though the walk had already matched them.
    check seenPort == 8080
    check seenName == "titanic"

  test "a Flag Operation shared across two levels composes in command-line order":
    # One Arg reachable at two grammar levels. It holds every match under a
    # single `matches` key regardless of which level recorded them, so a flat
    # pass applies them exactly once -- no dedupe needed. Level order and
    # index order always agree (ADR 0010), so all three arrangements compose
    # identically.
    for args in @[@["-v", "go", "-v", "hi"], @["go", "-v", "-v", "hi"],
                  @["-v", "-v", "go", "hi"]]:
      let shared = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0, help = "")
      let sub = (v: shared, name: arg("<name>", default = "", help = ""))
      let spec = (v: shared,
                  go: command("go", sub, usage = "[-v]... <name>", help = ""))
      spec.parse(usage = "[-v]... go", args = args, command = "app")
      check int(shared) == 2

suite "a conversion failure beats a matched Message Argument":
  test "a bad value below the level --help matched at still raises":
    # The one behavior change for input that previously succeeded: `-h`
    # matched at the top level while `--port abc` failed inside `go`.
    # A Message Argument is that level's action (ADR 0013), so it inherits
    # that level's preconditions.
    let sub = (port: opt("--port=<n>", default = 0, help = ""))
    let spec = (help: help(), go: command("go", sub, usage = "[--port=<n>]", help = ""))
    expect ParseError:
      spec.parse(usage = "[-h] go", args = @["-h", "go", "--port", "abc"],
                 command = "app")

  test "the same invocation with a good value still shows help":
    let sub = (port: opt("--port=<n>", default = 0, help = ""))
    let spec = (help: help(), go: command("go", sub, usage = "[--port=<n>]", help = ""))
    expect HelpError:
      spec.parse(usage = "[-h] go", args = @["-h", "go", "--port", "99"],
                 command = "app")

  test "a bad sibling value at the same level still raises, unchanged":
    let spec = (port: opt("--port=<n>", default = 0, help = ""), help: help())
    expect ParseError:
      spec.parse(usage = "[--port=<n>] [--help]", args = @["--port", "abc", "--help"],
                 command = "app")

suite "Match.spec still scopes matches to their own level":
  # parseAllValues drops the per-level `Match.spec` filter, but
  # matchedCommand and parseMessageArgs still need it. Both only break when
  # an Arg is genuinely shared across two spec levels -- see ADR 0032.

  test "a Command shared by two levels dispatches at the level it was typed":
    var log: seq[string]
    proc goBefore(spec: tuple, info: HookInfo) = log.add "go"
    proc statBefore(spec: tuple, info: HookInfo) = log.add "stat"

    let leaf = (name: arg("<n>", default = "", help = ""))
    let sharedCmd = command("stat", leaf, before = statBefore, usage = "<n>", help = "")
    let sub = (stat: sharedCmd)
    let spec = (stat: sharedCmd, go: command("go", sub, before = goBefore,
                                             usage = "stat", help = ""))

    spec.parse(usage = "go\nstat", args = @["go", "stat", "x"], command = "app")
    # Without matchedCommand's filter the top level claims the shared
    # Command as its own and dispatches straight to it, skipping `go`.
    check log == @["go", "stat"]
    check string(leaf.name) == "x"

  test "a Message Argument shared by two levels fires at the level it was typed":
    var log: seq[string]
    proc goBefore(spec: tuple, info: HookInfo) = log.add "go"

    let sharedHelp = help()
    let sub = (h: sharedHelp)
    let spec = (h: sharedHelp, go: command("go", sub, before = goBefore,
                                           usage = "(-h|--help)", help = ""))

    expect HelpError:
      spec.parse(usage = "go\n(-h|--help)", args = @["go", "--help"], command = "app")
    # Without parseMessageArgs' filter the top level fires the shared help
    # before descending, so `go`'s before hook never runs.
    check log == @["go"]
