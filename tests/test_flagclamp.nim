import std/[os, strutils, unittest] # strutils for `in`/`contains` on strings
                                     # in this file's own `check` assertions

import argumint

type Rank = enum bronze, silver, gold

defineSetFlag(Rank)

suite "Flag Clamp integration":
  test "repeated --verbose clamps at the upper bound":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "",
        clamp = clamp(0..10)),
    )
    spec.parse(usage = "[-v]...", args = @["-v", "-v", "-v", "-v", "-v", "-v", "-v", "-v", "-v", "-v", "-v", "-v"],
      command = "prog")
    check spec.verbosity == 10

  test "+=/-= clamp, including a single operation overshooting by more than 1 (partial effect, not skipped)":
    let spec = (
      verbosity: flag[int]("--boost+=5, --dampen-=2", default = 8, help = "",
        clamp = clamp(0..10)),
    )
    spec.parse(usage = "[--boost | --dampen]...", args = @["--boost"], command = "prog")
    check spec.verbosity == 10 # 8 + 5 = 13, clamped to 10 -- not skipped, not left at 8

    let spec2 = (
      verbosity: flag[int]("--boost+=5, --dampen-=2", default = 1, help = "",
        clamp = clamp(0..10)),
    )
    spec2.parse(usage = "[--boost | --dampen]...", args = @["--dampen"], command = "prog")
    check spec2.verbosity == 0 # 1 - 2 = -1, clamped to 0

  test "env-sourced flag operations are clamped per-value, not just once at the end":
    putEnv("ARGUMINT_TEST_CLAMP_VERBOSE", "--verbose:--verbose:--verbose:--verbose")
    defer: delEnv("ARGUMINT_TEST_CLAMP_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_CLAMP_VERBOSE",
        help = "", clamp = clamp(0..2)),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 2 # 4 increments against a clamp of 0..2, clamped along the way

  test "an out-of-range coded default raises SpecDefect at flag() call time":
    expect SpecDefect:
      discard flag[int]("--verbose", default = 15, help = "", clamp = clamp(0..10))

  test "a default that already satisfies its own clamp is accepted":
    discard flag[int]("--verbose", default = 5, help = "", clamp = clamp(0..10))
    discard flag[int]("--verbose", default = 0, help = "", clamp = clamp(0..10))
    discard flag[int]("--verbose", default = 10, help = "", clamp = clamp(0..10))

  test "generated help shows the auto-generated clamp annotation":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "Adjust verbosity",
        clamp = clamp(0..10)),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "[clamp: 0..10]" in helpText

  test "generated help shows adjust's desc if given, nothing otherwise":
    let described = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "Adjust verbosity",
        clamp = adjust(proc (v: int): int = v, desc = "rounded silently")),
      help: help(),
    )
    var helpText = ""
    try:
      described.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "[rounded silently]" in helpText

    let undescribed = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "Adjust verbosity",
        clamp = adjust(proc (v: int): int = v)),
      help: help(),
    )
    helpText = ""
    try:
      undescribed.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    # no bracket annotation at all -- matches how a plain, clamp-less flag
    # renders (see test_argumint.nim's equivalent no-annotation assertion)
    check "  -v, --verbose  Adjust verbosity" in helpText

  test "adjust is the escape hatch for a type with no total order, e.g. set[E]":
    # `<` on set[Rank] means proper-subset inclusion (a partial order), so
    # clamp would be meaningless here -- adjust lets the flag's own
    # author decide what "constrain" means: keep only the highest rank seen.
    # `+=` (union) is used, not `=` (replace), so the set actually
    # accumulates across matches for adjust to then narrow down.
    let highestOnly = proc (v: set[Rank]): set[Rank] =
      if gold in v: {gold}
      elif silver in v: {silver}
      else: v
    let spec = (
      rank: flag[set[Rank]]("--bronze+=bronze, --silver+=silver, --gold+=gold",
        default = {}, help = "", clamp = adjust(highestOnly)),
    )
    spec.parse(usage = "[--bronze | --silver | --gold]...", args = @["--bronze", "--silver"],
      command = "prog")
    check spec.rank == {silver} # {bronze} unioned in, then narrowed to {silver} once silver arrives
