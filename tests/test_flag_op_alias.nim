## Tests for GitHub issue #8: a Flag's variants weren't mutually exclusive
## across usage-string alternation groups (or even a plain sequence) when
## they carried different Flag Operations -- Option/Flag matching in
## `fsm.nim` compared only `Arg` identity, never which specific variant was
## typed.
##
## Fix: a Flag's variants partition into FlagOp Alias sets by identical
## (op, value) spec text (`Arg.aliases`, `argumint.nim`); `Matcher.variant`
## records which alias set a transition represents; `parser.choice()`'s
## dedup keys on `(Arg, variant)` via `Arg.aliases` instead of bare `Arg`,
## so non-aliased alternatives stay independently reachable.
##
## A same-Arg non-aliased token no longer blocks a scan -- it's skipped,
## like any other non-match (order-independent, per ADR 0019). What keeps
## composition correct despite that is `RawToken.idx`: every match
## remembers the original CLI argv position of the token it consumed, and
## `parseOwnValues`/`parseMessageArgs` apply a Flag's matched operations
## sorted by that index instead of by push/grammar-declaration order. This
## is what makes Flag Operations (often non-commutative, e.g. with
## `clamp`) compose in true typed order regardless of which usage-line
## position happened to match which token -- see several tests below
## asserting the *same* usage line gives *different* results for different
## CLI orderings.
##
## Two tests exercise the fix through a short-option cluster
## (`MatcherKind.Options`/`newOptsMatcher`) instead of a plain Option/Flag
## atom, since `fsm.match`'s `of Options:` branch is a separate code path.
## One test guards a regression the fix's first draft introduced: `of
## Flag:`'s alias check must only fire for the *same* Arg, not any
## unrelated Flag, or order-independent scanning (ADR 0019) breaks for two
## distinct Flags.

import std/[strutils, unittest]

import argumint

suite "FlagOp Alias exclusivity (issue #8)":
  test "a non-aliased variant at a later required position is rejected, not silently absorbed":
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

  test "two separate choice groups for the same Flag are order-independent, composing by true CLI order":
    # Same usage line and Arg as the test above, but each position's own
    # variant actually appears on the CLI -- just not in declared order.
    # `--up`/`--down`/`--left`/`--right` are all plain `=` assignments, so
    # whichever is typed *last* wins -- proving composition follows true
    # CLI order, not which usage position happened to match which token.
    let spec1 = (
      direction: flag[int]("--up=1, --down=-1, --left=2, --right=-2", default = 0, help = ""),
    )
    spec1.parse(usage = "(--up | --down) (--left | --right)",
      args = @["--left", "--up"], command = "prog")
    check spec1.direction == 1 # --up typed last

    let spec2 = (
      direction: flag[int]("--up=1, --down=-1, --left=2, --right=-2", default = 0, help = ""),
    )
    spec2.parse(usage = "(--up | --down) (--left | --right)",
      args = @["--right", "--down"], command = "prog")
    check spec2.direction == -1 # --down typed last

  test "a plain sequence for the same Flag is order-independent, composing by true CLI order":
    # `-u -d` are non-commutative ops with a clamp -- typing `-d` before
    # `-u` must give a different result than `-u` before `-d`, proving
    # composition tracks true CLI order rather than either order
    # succeeding by accident (or being rejected outright, as it was before
    # this fix).
    let spec1 = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = "", clamp = clamp(0..10)),
    )
    spec1.parse(usage = "-u -d", args = @["-u", "-d"], command = "prog")
    check spec1.verbosity == 4 # 1 + 5 = 6; 6 - 2 = 4

    let spec2 = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = "", clamp = clamp(0..10)),
    )
    spec2.parse(usage = "-u -d", args = @["-d", "-u"], command = "prog")
    check spec2.verbosity == 5 # 1 - 2 = -1 -> clamp 0; 0 + 5 = 5

  test "each non-aliased variant in a choice group stays independently reachable":
    let spec1 = (direction: flag[int]("--up=1, --down=-1", default = 0, help = ""))
    spec1.parse(usage = "(--up | --down)", args = @["--up"], command = "prog")
    check spec1.direction == 1

    let spec2 = (direction: flag[int]("--up=1, --down=-1", default = 0, help = ""))
    spec2.parse(usage = "(--up | --down)", args = @["--down"], command = "prog")
    check spec2.direction == -1

  test "a literal variant repeated within one choice group collapses to a single reachable position":
    # `Arg.aliases` is reflexive (`backend.nim`/`argumint.nim`), so
    # `choice()`'s dedup (`parser.nim`) also catches an exact duplicate
    # spelling now, not just a distinct non-aliased variant. A non-deduped
    # duplicate is otherwise functionally invisible -- either alternative
    # matches "--up" the same way -- so this checks the FSM's dot graph
    # directly rather than parse()/completeArgs() output.
    let spec = (
      direction: flag[int]("--up=1, --down=-1", default = 0, help = ""),
    )
    check spec.dot(usage = "(--up | --up)").count(" -> ") == 1

  test "a repeated group of multiple FlagOp Aliases composes operations in true CLI order, not branch-declaration order":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2",
        default = 1, help = "", clamp = clamp(0..10)),
    )
    spec.parse(usage = "[-v | --verbose | --quiet | --boost | --dampen]...",
      args = @["--dampen", "--boost", "-v"], command = "prog")
    check spec.verbosity == 6 # 1 -2=-1 -> clamp 0; +5=5; +1(-v)=6

  test "FlagOp Alias variants remain fully interchangeable at separate required positions, not just within one choice":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = ""),
    )
    spec.parse(usage = "-v --verbose", args = @["--verbose", "-v"], command = "prog")
    check spec.verbosity == 2

  test "two entirely distinct Flag Args stay order-independent regardless of CLI order":
    # Not about FlagOp Alias exclusivity -- guards ADR 0019's
    # order-independent scanning for two DIFFERENT Args, which the fix's
    # first draft broke (its `of Flag:` block-check fired on any unrelated
    # Flag token, not just a same-Arg non-aliased variant).
    let spec = (
      a: flag("--aa", default = false, help = ""),
      b: flag("--bb", default = false, help = ""),
    )
    spec.parse(usage = "--aa --bb", args = @["--bb", "--aa"], command = "prog")
    check spec.a == true
    check spec.b == true

  test "a short-option cluster composes two non-aliased FlagOps of one Flag in true left-to-right order":
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

  test "a cluster's peeled remainder can be left orphaned even though every position matches something":
    # "-dq" is one cluster token; classify() peels its first letter ("-d",
    # the dampen FlagOp) off at a time, leaving a remainder ("-q")
    # reinserted for a later matcher to claim. The separate "-u" position
    # now skips right past that peeled "-d" (order-independent) and
    # matches the literal "-u" token; the "(-d | -q)" position then can
    # only ever claim "-dq"'s peeled "-d" -- but usage has no third
    # position to absorb the leftover "-q" remainder, so it's reported as
    # an unexpected leftover token. Not about FlagOp Alias exclusivity
    # itself, but a structural token-budget gap the alias-skip change
    # exposes: matching every *position* doesn't guarantee every *token*
    # gets consumed.
    let spec = (
      verbosity: flag[int]("-u+=5, -d-=2, -q=0", default = 1, help = ""),
    )
    var msg = ""
    try:
      spec.parse(usage = "-u (-d | -q)", args = @["-dq", "-u"], command = "prog")
    except ParseError as e:
      msg = e.msg
    check "unexpected flag: -q" in msg

  test "a cluster mixing Flags and an Option is fully order-independent, composing the Flags by true CLI order":
    # "-udo" clusters three sub-matchers: -u/-d (two non-aliased FlagOps of
    # one Flag) and -o (an unrelated value-taking Option). All three are
    # now fully order-independent -- -o is never a Flag so it never
    # competed on order in the first place; -u/-d skip past each other and
    # match wherever their own token actually is, with `-clamp(0..10)`
    # making the composed result depend on which was typed first, proving
    # true CLI order rather than usage-declaration order.
    let spec1 = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = "", clamp = clamp(0..10)),
      output: opt("-o=<value>", default = "", help = ""),
    )
    spec1.parse(usage = "-udo", args = @["-u", "-d", "-o", "value"], command = "prog")
    check spec1.verbosity == 4 # 1 + 5 = 6; 6 - 2 = 4
    check spec1.output == "value"

    let spec2 = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = "", clamp = clamp(0..10)),
      output: opt("-o=<value>", default = "", help = ""),
    )
    spec2.parse(usage = "-udo", args = @["-d", "-u", "-o", "value"], command = "prog")
    check spec2.verbosity == 5 # 1 - 2 = -1 -> clamp 0; 0 + 5 = 5
    check spec2.output == "value"

    let spec3 = (
      verbosity: flag[int]("-u+=5, -d-=2", default = 1, help = "", clamp = clamp(0..10)),
      output: opt("-o=<value>", default = "", help = ""),
    )
    spec3.parse(usage = "-udo", args = @["-d", "-o", "value", "-u"], command = "prog")
    check spec3.verbosity == 5 # same order as above, -o interleaved
    check spec3.output == "value"
