# Tests for `parsed*`/`parsedOrQuit*` -- see
# `docs/adr/0031-parsed-fresh-spec-per-parse.md`.

import std/[strutils, unittest]

import argumint

proc buildCli(): auto =
  ## The issue #21 repro spec, as a builder.
  (tags: opts("--tag=<t>", help = ""),
   port: opt("--port=<n>", default = 80, help = ""),
   count: flag[int](ops = "-c+=1", default = 0, help = ""),
   help: help())

const ReproUsage = "[options]"

suite "parsed(builder): a parse is a pure function of args":
  test "the issue #21 repro table: three parses, none contaminating the next":
    # Before this existed, the same three parses against one spec gave
    # tags @["a"] -> @["a","b"] -> @["a","b"], port 81 -> 81 -> 81, and
    # count 1 -> 2 -> 2. Only the first row was ever right.
    let first = parsed(buildCli, usage = ReproUsage,
      args = @["--tag", "a", "--port", "81", "-c"], command = "app")
    # Compared field by field, not as a tuple: a converter doesn't fire
    # inside a tuple constructor (issue #16).
    check first.tags == @["a"]
    check first.port == 81
    check first.count == 1

    let second = parsed(buildCli, usage = ReproUsage,
      args = @["--tag", "b", "-c"], command = "app")
    check second.tags == @["b"]
    check second.port == 80
    check second.count == 1

    let third = parsed(buildCli, usage = ReproUsage, args = @[], command = "app")
    check third.tags == newSeq[string]()
    check third.port == 80
    check third.count == 0

  test "an earlier result keeps its own values after a later parse":
    let first = parsed(buildCli, usage = ReproUsage,
      args = @["--tag", "a", "--port", "81"], command = "app")
    discard parsed(buildCli, usage = ReproUsage,
      args = @["--tag", "z", "--port", "99"], command = "app")
    check first.tags == @["a"]
    check first.port == 81

  test "a table of (argv, expected) cases against one builder":
    # The natural way to test a CLI, and the case the issue calls out as
    # silently wrong before now.
    for (argv, expected) in {
      "--port 81": 81,
      "": 80,
      "--port 1 --port 2": 2,
    }.items:
      let cli = parsed(buildCli, usage = ReproUsage,
        args = argv.splitWhitespace, command = "app")
      check cli.port == expected

suite "parsed(builder): hooks":
  test "hooks receive the freshly built spec, not a stale one":
    var seen: seq[string]
    proc onAction(s: auto, info: HookInfo) =
      let port: int = s.port # concrete type, so the converter fires
      seen.add $port

    discard parsed(buildCli, usage = ReproUsage, args = @["--port", "81"],
      command = "app", action = onAction)
    discard parsed(buildCli, usage = ReproUsage, args = @[], command = "app",
      action = onAction)
    check seen == @["81", "80"]

  test "a Command's own hook sees that parse's nested values":
    var seen: seq[string]
    proc cmdShip(s: auto, info: HookInfo) =
      let name: string = s.name
      seen.add name

    proc buildShipCli(): auto =
      (ship: command("ship", (name: arg("<name>", help = "")), help = "",
         action = cmdShip),
       help: help())

    discard parsed(buildShipCli, args = @["ship", "Titanic"], command = "app")
    discard parsed(buildShipCli, args = @["ship", "Olympic"], command = "app")
    check seen == @["Titanic", "Olympic"]

  test "a Command hook's side effects on captured local state propagate":
    # Declared inside a proc so `seen` is a genuine closure capture, not a
    # module-level global that a `command*` hook would reach directly. This
    # is the property that ruled out a `deepCopy`-based overload taking an
    # already-built tuple: that copies the hook's captured environment, so
    # its writes land in the copy and are silently lost. See ADR 0031.
    proc run(): seq[string] =
      var seen: seq[string]
      proc cmdShip(s: auto, info: HookInfo) =
        let name: string = s.name
        seen.add name
      proc buildShipCli(): auto =
        (ship: command("ship", (name: arg("<name>", help = "")), help = "",
           action = cmdShip),
         help: help())
      discard parsed(buildShipCli, args = @["ship", "Titanic"], command = "app")
      discard parsed(buildShipCli, args = @["ship", "Olympic"], command = "app")
      seen

    check run() == @["Titanic", "Olympic"]

suite "parsedOrQuit(builder)":
  # Only the success path: the failure path calls `quit()`, which would take
  # the test runner with it. `parseOrQuit*` is untested here for the same
  # reason.
  test "returns the freshly parsed spec on success":
    let cli = parsedOrQuit(buildCli, usage = ReproUsage,
      args = @["--tag", "a", "--port", "81"], command = "app")
    check cli.tags == @["a"]
    check cli.port == 81

  test "repeated calls stay independent":
    let first = parsedOrQuit(buildCli, usage = ReproUsage,
      args = @["--port", "81"], command = "app")
    let second = parsedOrQuit(buildCli, usage = ReproUsage, args = @[],
      command = "app")
    check first.port == 81
    check second.port == 80

  test "hooks fire and receive the freshly built spec":
    proc run(): seq[string] =
      var seen: seq[string]
      proc onAction(s: auto, info: HookInfo) =
        let port: int = s.port
        seen.add $port
      discard parsedOrQuit(buildCli, usage = ReproUsage,
        args = @["--port", "81"], command = "app", action = onAction)
      seen

    check run() == @["81"]

suite "parsed(builder): failures":
  test "a parse failure still raises, exactly like parse(tuple)":
    expect ParseError:
      discard parsed(buildCli, usage = ReproUsage, args = @["--nope"],
        command = "app")

  test "a validation failure still raises":
    proc buildChecked(): auto =
      (port: opt("--port=<n>", default = 1, help = "",
         validator = range(1..10)), help: help())

    expect ValidationError:
      discard parsed(buildChecked, usage = "[--port=<n>]",
        args = @["--port", "99"], command = "app")

  test "a --help request still raises HelpError":
    expect HelpError:
      discard parsed(buildCli, usage = ReproUsage, args = @["-h"], command = "app")
