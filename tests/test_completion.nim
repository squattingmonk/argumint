# Tests for dynamic shell completion (`fsm.completeArgs*`, the `__complete`
# entry point, and `completion.genCompletionScript*`) -- see
# `docs/adr/0012-fsm-driven-shell-completion.md` and
# `docs/adr/0022-completion-candidate-help-text.md`.

import std/[os, sequtils, strutils, unittest]

import argumint
import argumint/backend
import argumint/completion
import argumint/fsm
import argumint/validators

proc values(candidates: seq[CompletionCandidate]): seq[string] =
  candidates.mapIt(it.value)

proc find(candidates: seq[CompletionCandidate], value: string): CompletionCandidate =
  for c in candidates:
    if c.value == value:
      return c
  raise newException(ValueError, "no candidate named " & value)

suite "Option/value completion":
  let spec = (
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
    amend: flag("--amend"),
  )
  let built = newSpec(spec, usage = "[options]")

  test "an option's bare name is offered, not its declared placeholder suffix":
    check built.completeArgs(@["--lo"], "prog").values == @["--log-level"]

  test "a pending option's value is completed from its Choice validator":
    check built.completeArgs(@["--log-level", ""], "prog").values == @["debug", "info", "warn", "error"]

  test "a pending option's value completion is prefix-filtered":
    check built.completeArgs(@["--log-level", "d"], "prog").values == @["debug"]

  test "a pending option's value completion carries no help text":
    for c in built.completeArgs(@["--log-level", ""], "prog"):
      check c.help == ""

  test "a Flag never triggers pending-value completion, even mid-command-line":
    let result = built.completeArgs(@["--amend", ""], "prog").values
    check "--log-level" in result
    check "--amend" in result
    # if --amend had wrongly been treated as pending a value, this would
    # instead be a Choice's candidate values -- neither of which is one
    check "debug" notin result

  test "an unrecognized already-typed word yields no candidates, never raises":
    check built.completeArgs(@["--unknown", ""], "prog") == newSeq[CompletionCandidate]()

suite "End-of-Options Marker is invisible to completion":
  test "-- is never offered as a candidate, even right at the marker's own position":
    let spec = (
      verbose: flag("--verbose"),
      files: args("<file>"),
    )
    let built = newSpec(spec, usage = "[options] -- <file>...")
    # Right after [options] is exhausted, live states include both the
    # repeat-loop-back (more options) and the marker's own transition --
    # neither `--verbose` completions nor `--` itself should ever include
    # a bare "--" candidate, since typing it is never required (ADR 0020
    # point 8).
    check "--" notin built.completeArgs(@[""], "prog").values
    check "--" notin built.completeArgs(@["--verbose", ""], "prog").values

suite "Command completion and subcommand descent":
  let add = (
    files: args("<file>"),
  )
  let commit = (
    message: arg("<message>"),
    amend: flag("--amend"),
  )
  let spec = (
    verbose: flag("--verbose"),
    add: command("add", add),
    commit: command("commit", commit),
  )
  let built = newSpec(spec)

  test "a command's variant is offered by prefix":
    check built.completeArgs(@["comm"], "prog").values == @["commit"]

  test "nothing typed yet offers every top-level option/command":
    let result = built.completeArgs(@[""], "prog").values
    check "--verbose" in result
    check "add" in result
    check "commit" in result

  test "descends into a matched subcommand's own spliced FSM automatically":
    check built.completeArgs(@["commit", "--am"], "prog").values == @["--amend"]

suite "A Command name shadowing a positional value stays live for completion":
  # ADR 0019: "ship" is a declared command name, but the "<file>" Usage
  # Line is a genuinely separate alternative that can also accept it as a
  # literal positional value -- completion after a fully-typed "ship"
  # should still explore both, not just the one Command descended into.
  let ship = (
    name: arg("<name>", validator = choice(["titanic", "bismarck"])),
  )
  let spec = (
    ship: command("ship", ship, usage = "<name>"),
    file: arg("<file>"),
    verbose: flag("--verbose"),
  )
  let built = newSpec(spec, usage = "ship\n<file> [--verbose]")

  test "completion after \"ship\" offers both the nested command's own candidates and what follows a literal <file> value":
    let result = built.completeArgs(@["ship", ""], "prog").values
    check "titanic" in result
    check "bismarck" in result
    check "--verbose" in result

suite "Catch-all repeatability and cycle safety":
  # `--verbose` is explicitly named (so excluded from the catch-all and
  # non-repeatable); `--moored` is reachable only via `[options]` (so
  # repeatable by default, per ADR 0002).
  let spec = (
    verbose: flag("--verbose"),
    moored: flag("--moored"),
  )
  let built = newSpec(spec, usage = "--verbose [options]")

  test "the required option is offered first":
    check built.completeArgs(@[""], "prog").values == @["--verbose"]

  test "a catch-all-only option keeps being offered, and doesn't hang":
    check built.completeArgs(@["--verbose", ""], "prog").values == @["--moored"]
    check built.completeArgs(@["--verbose", "--moored", ""], "prog").values == @["--moored"]
    check built.completeArgs(@["--verbose", "--moored", "--moored", ""], "prog").values == @["--moored"]

  test "an already-consumed, explicitly-named non-repeatable option stops appearing":
    let result = built.completeArgs(@["--verbose", "--moored", ""], "prog").values
    check "--verbose" notin result

suite "Env-var fallback during completion":
  let spec = (
    port: opt("--port=<port>", env = "ARGUMINT_TEST_COMPLETION_PORT"),
    other: flag("--other"),
  )
  let built = newSpec(spec, usage = "--port=<port> [--other]")

  test "without env, only the still-required option is offered":
    check built.completeArgs(@[""], "prog").values == @["--port"]

  test "with env satisfying the required option, completion advances past it":
    putEnv("ARGUMINT_TEST_COMPLETION_PORT", "9090")
    try:
      check "--other" in built.completeArgs(@[""], "prog").values
    finally:
      delEnv("ARGUMINT_TEST_COMPLETION_PORT")

suite "Completion candidates carry help text":
  test "an option's completion candidate carries its help text":
    let spec = (
      logLevel: opt("--log-level=<level>", help = "Logging verbosity"),
    )
    let built = newSpec(spec, usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--log-level").help == "Logging verbosity"

  test "a flag's completion candidate carries its help text":
    let spec = (
      verbose: flag("--verbose", help = "Be noisy"),
    )
    let built = newSpec(spec, usage = "[options]")
    check built.completeArgs(@[""], "prog").find("--verbose").help == "Be noisy"

  test "a command's completion candidate carries its help text":
    let sub = (files: args("<file>"))
    let spec = (
      add: command("add", sub, help = "Add files to the index"),
    )
    let built = newSpec(spec)
    check built.completeArgs(@[""], "prog").find("add").help == "Add files to the index"

  test "a flag with divergent per-variant ops carries each variant's own variantDesc, not its shared help":
    let spec = (
      rank: flag[int]("--boost+=5, --dampen-=2", default = 0, help = "Adjust rank"),
    )
    let built = newSpec(spec, usage = "[options]")
    let candidates = built.completeArgs(@[""], "prog")
    check candidates.find("--boost").help == "Increase by 5"
    check candidates.find("--dampen").help == "Decrease by 2"

  test "an option's own help never leaks onto its Choice-validator value candidates":
    let spec = (
      logLevel: opt("--log-level=<level>", help = "Logging verbosity",
        validator = choice(["debug", "info", "warn", "error"])),
    )
    let built = newSpec(spec, usage = "[options]")
    let candidates = built.completeArgs(@["--log-level", ""], "prog")
    check candidates.len > 0
    for c in candidates:
      check c.help == ""

suite "__complete entry point":
  test "raises CompletionError with tab-separated candidate/help lines and fires no hooks":
    var hookFired = false
    let spec = (
      logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
    )
    let built = newSpec(spec, usage = "[options]")
    built.before = proc(info: HookInfo) = hookFired = true
    built.action = proc(info: HookInfo) = hookFired = true
    built.after = proc(info: HookInfo) = hookFired = true

    var caught = ""
    try:
      built.parse(args = @["__complete", "--lo"], command = "test")
    except CompletionError as e:
      caught = e.msg
    check caught == "--log-level\t"
    check not hookFired

  test "a candidate's help text rides along after its own tab":
    let spec = (
      logLevel: opt("--log-level=<level>", help = "Logging verbosity"),
    )
    let built = newSpec(spec, usage = "[options]")
    var caught = ""
    try:
      built.parse(args = @["__complete", "--lo"], command = "test")
    except CompletionError as e:
      caught = e.msg
    check caught == "--log-level\tLogging verbosity"

suite "genCompletionScript":
  let spec = (
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
  )
  let built = newSpec(spec, usage = "[options]")

  test "every shell's script mentions the binary name and the __complete trigger":
    for shell in Shell:
      let script = built.completionScript(shell, "mycli")
      check "mycli" in script
      check "__complete" in script

  test "bash strips help text before offering candidates, since it has no description slot":
    check "cut -f1" in built.completionScript(bash, "mycli")

  test "zsh renders help text via compadd -d":
    check "compadd -d" in built.completionScript(zsh, "mycli")
