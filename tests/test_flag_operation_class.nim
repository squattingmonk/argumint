## Tests for GitHub issue #8: a Flag's variants weren't mutually exclusive
## across usage-string alternation groups (or even a plain sequence) when
## they carried different Flag Operations -- Option/Flag matching in
## `fsm.nim` compared only `Arg` identity, never which specific variant was
## typed.
##
## Fix: a Flag's variants partition into "classes" by identical (op, value)
## spec text (`Arg.aliases`, `argumint.nim`); `Matcher.variant` records
## which class a transition represents; `fsm.match`'s `of Flag:` branch
## stops (does not skip past) the first same-Arg token whose class differs
## from the matcher's own; `parser.choice()`'s dedup keys on `(Arg, class)`
## instead of bare `Arg`, so differently-classed alternatives stay
## independently reachable.
##
## Two tests exercise the fix through a short-option cluster
## (`MatcherKind.Options`/`newOptsMatcher`) instead of a plain Option/Flag
## atom, since `fsm.match`'s `of Options:` branch is a separate code path.
## One test guards a regression the fix's first draft introduced: `of
## Flag:`'s blocking check must only fire for the *same* Arg with a
## mismatched class, not any unrelated Flag, or order-independent scanning
## (ADR 0019) breaks for two distinct Flags.

import std/[strutils, unittest]

import argumint

suite "Flag Operation Class exclusivity (issue #8)":
  test "a differently-classed variant at a later required position is rejected, not silently absorbed":
    let spec = (
      direction: flag[int]("--up=1, --down=-1, --left=2, --right=-2", default = 0, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "(--up | --down) (--left | --right)",
        args = @["--up", "--down"], command = "prog")

  test "the same conflict occurs in a plain sequence, not just parenthesized alternation":
    let spec = (
      direction: flag[int]("--up=1, --down=-1", default = 0, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "--up --down", args = @["--up", "--up"], command = "prog")

  test "each distinct-class variant in a choice group stays independently reachable":
    let spec1 = (direction: flag[int]("--up=1, --down=-1", default = 0, help = ""))
    spec1.parse(usage = "(--up | --down)", args = @["--up"], command = "prog")
    check spec1.direction == 1

    let spec2 = (direction: flag[int]("--up=1, --down=-1", default = 0, help = ""))
    spec2.parse(usage = "(--up | --down)", args = @["--down"], command = "prog")
    check spec2.direction == -1

  test "a repeated multi-class group composes operations in true CLI order, not branch-declaration order":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2",
        default = 1, help = "", clamp = clamp(0..10)),
    )
    spec.parse(usage = "[-v | --verbose | --quiet | --boost | --dampen]...",
      args = @["--dampen", "--boost", "-v"], command = "prog")
    check spec.verbosity == 6 # 1 -2=-1 -> clamp 0; +5=5; +1(-v)=6

  test "same-class variants remain fully interchangeable at separate required positions, not just within one choice":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = ""),
    )
    spec.parse(usage = "-v --verbose", args = @["--verbose", "-v"], command = "prog")
    check spec.verbosity == 2

  test "two entirely distinct Flag Args stay order-independent regardless of CLI order":
    # Not about Flag Operation Class -- guards ADR 0019's order-independent
    # scanning for two DIFFERENT Args, which the fix's first draft broke
    # (its `of Flag:` block-check fired on any unrelated Flag token, not
    # just a same-Arg mismatched class).
    let spec = (
      a: flag("--aa", default = false, help = ""),
      b: flag("--bb", default = false, help = ""),
    )
    spec.parse(usage = "--aa --bb", args = @["--bb", "--aa"], command = "prog")
    check spec.a == true
    check spec.b == true

  test "a short-option cluster composes two different classes of one Flag in true left-to-right order":
    # `-du` is one tkShortOptions atom in the usage string, which the
    # parser desugars into one chained `newOptMatcher(opt, variant)` per
    # letter (see docs/adr/0025 and issue #9) -- so this is really two
    # mandatory single-match atoms in a row, not a shared `of Options:`
    # matcher.
    let spec = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = "", clamp = clamp(0..10)),
    )
    spec.parse(usage = "-du", args = @["-du"], command = "prog")
    check spec.verbosity == 5 # -d first: 1 - 2 = -1 -> clamp 0; -u: 0 + 5 = 5

  test "a wrong-class token folded into a cluster still blocks a same-Flag matcher's scan elsewhere on the line":
    # "-dq" is one cluster token; classify() peels its first letter ("-d",
    # dampen class) off one at a time. The separate "-u" position's
    # matcher must still stop at that peeled "-d" instead of skipping past
    # it to find "-u" later in the args.
    let spec = (
      verbosity: flag[int]("-u+=5, -d-=2, -q=0", default = 1, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "-u (-d | -q)", args = @["-dq", "-u"], command = "prog")

  test "a cluster mixing Flags and an Option keeps the Option order-independent while the Flags stay class-exclusive":
    # "-udo" clusters three sub-matchers: -u/-d (two classes of one Flag)
    # and -o (an unrelated value-taking Option). Each is tried
    # independently: -d and -o both find their own token by skipping past
    # whatever's in front (order-independent -- -o is never a Flag, so it
    # never blocks); -u can't skip past the earlier -d (same Arg, blocked
    # class), so its own sub-matcher fails to find a usable token.
    #
    # Since issue #9's fix, an explicit cluster requires every one of its
    # sub-matchers to succeed (not just any), so -u failing fails the whole
    # "-udo" atom outright -- surfacing as "missing option: -u" rather than
    # a leftover-token "unexpected flag: -u".
    let spec = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = ""),
      output: opt("-o=<value>", default = "", help = ""),
    )
    var msg = ""
    try:
      spec.parse(usage = "-udo", args = @["-d", "-o", "value", "-u"], command = "prog")
    except ParseError as e:
      msg = e.msg
    check "missing option: -u" in msg
