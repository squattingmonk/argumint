# Locks `genHelp`'s semi-public status: exported from `argumint/help`, but
# deliberately *not* re-exported from `argumint`, so a caller opts in by
# importing the submodule. `tests/test_public_api.nim` holds the other half
# (the bare `import argumint` can't reach it) -- see the note there, and
# `docs/adr/0030-core-types-exported-spec-opaque.md` for the pattern.

import std/[strutils, unittest]

import argumint
import argumint/help

proc greeter(): Spec =
  newSpec((
    name: arg("<name>", help = "Who to greet"),
    times: opt("--times=<n>", default = 1, help = "How many times"),
    help: help(),
  ), prolog = "Greeter.", epilog = "See the README.",
     usage = "<name> [--times=<n>]")

suite "`genHelp` is callable by importing `argumint/help` directly":
  test "it renders the full message without raising":
    let text = greeter().genHelp("greet")
    check text.startsWith("Greeter.")
    check text.endsWith("See the README.")
    check "  greet <name> [--times=<n>]" in text
    check "Who to greet" in text
    check "How many times [default: 1]" in text

  test "`command` names the program in the usage lines":
    # `HelpArg.action` passes the command path that reached the Spec, which
    # is why a subcommand's help reads `prog ship move`.
    check "  navalfate <name>" in greeter().genHelp("navalfate")

  test "it returns exactly what `--help` would have raised":
    # The affordance is "render it yourself instead of catching HelpError",
    # so the two must not drift apart.
    let direct = greeter().genHelp("greet")
    var raised = ""
    try:
      greeter().parse(args = @["--help"], command = "greet")
    except HelpError as e:
      raised = e.msg
    check raised == direct
