## Target/regression tests for GitHub issue #8: a Flag's variants aren't
## mutually exclusive across usage-string alternation groups -- or even a
## plain sequence -- when they carry different Flag Operations, because
## Option/Flag matching in `fsm.nim` currently checks only `Arg` identity,
## never which specific variant was actually typed.
##
## Agreed design (see issue #8 discussion): a Flag's variants partition
## into "classes" by identical (op, value) spec text; `Matcher` gains a
## `variant` field recording which class its own transition represents;
## and the scan in `fsm.match`'s `of Option:`/`of Flag:` branch stops (does
## not skip past) the first same-Arg token whose class differs from the
## matcher's own, rather than continuing to scan for a same-class token
## further along.
##
## Tests prefixed "FAILING TODAY" exercise that target behavior and are
## expected to fail until the fix lands. Tests prefixed "REGRESSION"
## already pass on `main` and must keep passing -- they guard two
## easy-to-miss pitfalls surfaced while designing the fix:
##
## 1. A naive "skip past mismatched-class tokens, scan ahead for my own"
##    implementation breaks Match Accumulation's left-to-right ordering
##    guarantee for composing Flag Operations (see CONTEXT.md) -- e.g.
##    verbosity.nim's `--boost`/`--dampen` would apply out of order. The
##    stop-at-the-first-blocking-token design exists specifically to
##    preserve this ordering without needing a separate "find the leftmost
##    token across all sibling transitions" pass.
## 2. `parser.choice()`'s alternation dedup (`trivialArg`/`seenArgs`,
##    parser.nim) currently keys purely on `Arg`, collapsing
##    `(--up | --down)` to a single graph edge since both variants share
##    one underlying Arg. If the class check is added to `match()` without
##    ALSO widening this dedup key to `(Arg, class)`, the deduped-away
##    branch becomes permanently unreachable on its own -- a regression
##    worse than today's bug, not a fix.

import std/unittest

import argumint

suite "Flag Operation Class exclusivity (issue #8)":
  test "FAILING TODAY: a differently-classed variant at a later required position is rejected, not silently absorbed":
    # Only 2 tokens for 2 required positions, both direction-Arg-shaped --
    # today's Arg-only matching happily lets "--down" satisfy the
    # "--left | --right" position (since it never checks which variant),
    # so this currently succeeds silently with the wrong value instead of
    # raising. (A 3-token version, e.g. adding a trailing "--left", also
    # fails today, but via a confusing "unexpected flag: --left" error --
    # ParseError either way, which wouldn't distinguish buggy from fixed
    # behavior. This 2-token version fails open instead, which does.)
    let spec = (
      direction: flag[int]("--up=1, --down=-1, --left=2, --right=-2", default = 0, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "(--up | --down) (--left | --right)",
        args = @["--up", "--down"], command = "prog")

  test "FAILING TODAY: the same conflict occurs in a plain sequence, not just parenthesized alternation":
    let spec = (
      direction: flag[int]("--up=1, --down=-1", default = 0, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "--up --down", args = @["--up", "--up"], command = "prog")

  test "REGRESSION: each distinct-class variant in a choice group stays independently reachable (dedup must key on class, not just Arg)":
    let spec1 = (direction: flag[int]("--up=1, --down=-1", default = 0, help = ""))
    spec1.parse(usage = "(--up | --down)", args = @["--up"], command = "prog")
    check spec1.direction == 1

    let spec2 = (direction: flag[int]("--up=1, --down=-1", default = 0, help = ""))
    spec2.parse(usage = "(--up | --down)", args = @["--down"], command = "prog")
    check spec2.direction == -1

  test "REGRESSION: a repeated multi-class group composes operations in true CLI order, not branch-declaration order":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2",
        default = 1, help = "", clamp = clamp(0..10)),
    )
    spec.parse(usage = "[-v | --verbose | --quiet | --boost | --dampen]...",
      args = @["--dampen", "--boost", "-v"], command = "prog")
    check spec.verbosity == 6 # 1 -2=-1 -> clamp 0; +5=5; +1(-v)=6

  test "REGRESSION: same-class variants remain fully interchangeable at separate required positions, not just within one choice":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = ""),
    )
    spec.parse(usage = "-v --verbose", args = @["-v", "--verbose"], command = "prog")
    check spec.verbosity == 2
