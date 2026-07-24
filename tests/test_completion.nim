# Tests for dynamic shell completion (`fsm.completeArgs*`, the `__complete`
# entry point, and `completion.genCompletionScript*`) -- see
# `docs/adr/0012-fsm-driven-shell-completion.md`.

import std/[os, strutils, unittest]

import argumint
import argumint/backend
import argumint/completion
import argumint/fsm
import argumint/validators

suite "Option/value completion":
  let spec = (
    logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
    amend: flag("--amend"),
  )
  let built = newSpec(spec, usage = "[options]")

  test "an option's bare name is offered, not its declared placeholder suffix":
    check built.completeArgs(@["--lo"], "prog") == @["--log-level"]

  test "a pending option's value is completed from its Choice validator":
    check built.completeArgs(@["--log-level", ""], "prog") == @["debug", "info", "warn", "error"]

  test "a pending option's value completion is prefix-filtered":
    check built.completeArgs(@["--log-level", "d"], "prog") == @["debug"]

  test "a Flag never triggers pending-value completion, even mid-command-line":
    let result = built.completeArgs(@["--amend", ""], "prog")
    check "--log-level" in result
    check "--amend" in result
    # if --amend had wrongly been treated as pending a value, this would
    # instead be a Choice's candidate values -- neither of which is one
    check "debug" notin result

  test "an unrecognized already-typed word yields no candidates, never raises":
    check built.completeArgs(@["--unknown", ""], "prog") == newSeq[string]()

suite "Command completion and subcommand descent":
  let add = (
    files: args[string]("<file>"),
  )
  let commit = (
    message: arg[string]("<message>"),
    amend: flag("--amend"),
  )
  let spec = (
    verbose: flag("--verbose"),
    add: command("add", add),
    commit: command("commit", commit),
  )
  let built = newSpec(spec)

  test "a command's variant is offered by prefix":
    check built.completeArgs(@["comm"], "prog") == @["commit"]

  test "nothing typed yet offers every top-level option/command":
    let result = built.completeArgs(@[""], "prog")
    check "--verbose" in result
    check "add" in result
    check "commit" in result

  test "descends into a matched subcommand's own spliced FSM automatically":
    check built.completeArgs(@["commit", "--am"], "prog") == @["--amend"]

suite "A Command name shadowing a positional value stays live for completion":
  # ADR 0019: "ship" is a declared command name, but the "<file>" Usage
  # Line is a genuinely separate alternative that can also accept it as a
  # literal positional value -- completion after a fully-typed "ship"
  # should still explore both, not just the one Command descended into.
  let ship = (
    name: arg[string]("<name>", validator = choice(["titanic", "bismarck"])),
  )
  let spec = (
    ship: command("ship", ship, usage = "<name>"),
    file: arg[string]("<file>"),
    verbose: flag("--verbose"),
  )
  let built = newSpec(spec, usage = "ship\n<file> [--verbose]")

  test "completion after \"ship\" offers both the nested command's own candidates and what follows a literal <file> value":
    let result = built.completeArgs(@["ship", ""], "prog")
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
    check built.completeArgs(@[""], "prog") == @["--verbose"]

  test "a catch-all-only option keeps being offered, and doesn't hang":
    check built.completeArgs(@["--verbose", ""], "prog") == @["--moored"]
    check built.completeArgs(@["--verbose", "--moored", ""], "prog") == @["--moored"]
    check built.completeArgs(@["--verbose", "--moored", "--moored", ""], "prog") == @["--moored"]

  test "an already-consumed, explicitly-named non-repeatable option stops appearing":
    let result = built.completeArgs(@["--verbose", "--moored", ""], "prog")
    check "--verbose" notin result

suite "Env-var fallback during completion":
  let spec = (
    port: opt("--port=<port>", env = "ARGUMINT_TEST_COMPLETION_PORT"),
    other: flag("--other"),
  )
  let built = newSpec(spec, usage = "--port=<port> [--other]")

  test "without env, only the still-required option is offered":
    check built.completeArgs(@[""], "prog") == @["--port"]

  test "with env satisfying the required option, completion advances past it":
    putEnv("ARGUMINT_TEST_COMPLETION_PORT", "9090")
    try:
      check "--other" in built.completeArgs(@[""], "prog")
    finally:
      delEnv("ARGUMINT_TEST_COMPLETION_PORT")

suite "__complete entry point":
  test "raises CompletionError with newline-joined candidates and fires no hooks":
    var hookFired = false
    let spec = (
      logLevel: opt("--log-level=<level>", validator = choice(["debug", "info", "warn", "error"])),
    )
    let built = newSpec(spec, usage = "[options]")
    built.before = proc() = hookFired = true
    built.action = proc() = hookFired = true
    built.after = proc() = hookFired = true

    var caught = ""
    try:
      built.parse(args = @["__complete", "--lo"], command = "test")
    except CompletionError as e:
      caught = e.msg
    check caught == "--log-level"
    check not hookFired

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
