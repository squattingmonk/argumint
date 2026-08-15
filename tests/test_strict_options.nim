# Strict Option Checking -- an option-shaped command-line token is never
# silently accepted as data. See docs/adr/0034-strict-option-checking.md.
#
# Organised by the acceptance criteria in issue #19.

import std/[strutils, unittest]

import argumint

proc catchAllSpec(): auto =
  ## `myapp [options] <file>...`, the shape where an unrecognized option
  ## used to be absorbed silently. A proc so each test gets a fresh
  ## single-use spec (ADR 0031).
  (port: opt("--port=<n>", default = 0, help = ""),
   name: opt("-n, --name=<s>", default = "", help = ""),
   rest: args("<rest>", help = ""),
   help: help())

const CatchAll = "[options] [<rest>...]"

## Every Non-Option Short from the issue's table: one leading dash, second
## character not an ASCII letter.
const NonOptionShorts = ["-5", "-12", "-3.5", "-.5", "-1e9", "-5.",
                         "-0x1F", "-+3", "-5x", "-1_000"]

suite "strictOptions: the setting itself":
  test "defaults to on and is settable through newSpecSettings":
    check DefaultStrictOptions
    check newSpecSettings().strictOptions
    check not newSpecSettings(strictOptions = false).strictOptions

  test "a nested subcommand observes the parent's setting without being passed it":
    # SpecSettings is shared by reference down the tree (ADR 0014).
    let child = (rest: args("<rest>", help = ""),)
    let spec = (go: command("go", child, help = ""), help: help())
    expect ParseError:
      spec.parse(args = @["go", "--nope"], command = "app", usage = "go")

    let child2 = (rest: args("<rest>", help = ""),)
    let lax = (go: command("go", child2, help = ""), help: help())
    lax.parse(args = @["go", "--nope"], command = "app", usage = "go",
              settings = newSpecSettings(strictOptions = false))
    check child2.rest == @["--nope"]

suite "strictOptions: the catch-all positional slot":
  test "an unrecognized option raises instead of being absorbed":
    let spec = catchAllSpec()
    expect ParseError:
      spec.parse(args = @["--nope"], command = "app", usage = CatchAll)

  test "a near-miss raises with its did-you-mean suggestion intact":
    let spec = catchAllSpec()
    try:
      spec.parse(args = @["--por", "80"], command = "app", usage = CatchAll)
      check false # unreachable
    except ParseError as e:
      check "--por" in e.msg
      check "did you mean --port?" in e.msg

  test "an unrecognized option after a valid positional is still caught":
    let spec = catchAllSpec()
    expect ParseError:
      spec.parse(args = @["f", "--nope"], command = "app", usage = CatchAll)

  test "a recognized option with its value still parses alongside the catch-all":
    let spec = catchAllSpec()
    spec.parse(args = @["--port", "80", "f"], command = "app", usage = CatchAll)
    check spec.port == 80
    check spec.rest == @["f"]

suite "strictOptions: the option value slot":
  # This one needs no catch-all at all.
  proc valueSpec(): auto =
    (name: opt("-n, --name=<s>", default = "", help = ""), help: help())

  test "an option-shaped token doesn't become the value -- the option starves":
    let spec = valueSpec()
    try:
      spec.parse(args = @["--name", "--help"], command = "app", usage = "[options]")
      check false # unreachable
    except ParseError as e:
      check "option --name requires a value" in e.msg

  test "the token that starved it is named too, rather than one masking the other":
    let spec = valueSpec()
    try:
      spec.parse(args = @["--name", "-q"], command = "app", usage = "[options]")
      check false # unreachable
    except ParseError as e:
      check "option --name requires a value" in e.msg
      check "unrecognized option -q" in e.msg

  test "but a declared option that starves another is never called unrecognized":
    # The wording bug ADR 0034 exists to fix, one level over: `--name` is
    # starved by a token this spec knows perfectly well.
    let spec = (name: opt("--name=<s>", default = "", help = ""),
                port: opt("--port=<n>", default = 0, help = ""))
    try:
      spec.parse(args = @["--name", "--port", "80"], command = "app", usage = "[options]")
      check false # unreachable
    except ParseError as e:
      check "option --name requires a value" in e.msg
      check "unrecognized" notin e.msg

  test "with strict off an option-shaped token still counts as a value":
    let spec = valueSpec()
    spec.parse(args = @["--name", "--help"], command = "app", usage = "[options]",
               settings = newSpecSettings(strictOptions = false))
    check spec.name == "--help"

suite "strictOptions: a starved option errors under both settings":
  # The one unconditional case -- nothing at all follows, so there is no
  # value to be had however permissive the setting.
  for strict in [true, false]:
    # No `help()` on purpose: its own `app (-h | --help)` usage line carries a
    # bare Option matcher that would report the starvation for free, hiding
    # whether the catch-all path can. See the next suite.
    test "nothing following raises `requires a value`, not `unrecognized` (strict=" & $strict & ")":
      let spec = (port: opt("--port=<n>", default = 0, help = ""),)
      try:
        spec.parse(args = @["--port"], command = "app", usage = "[options]",
                   settings = newSpecSettings(strictOptions = strict))
        check false # unreachable
      except ParseError as e:
        check "option --port requires a value" in e.msg
        check "unrecognized option --port" notin e.msg

suite "strictOptions: the starved complaint survives the catch-all's rollback":
  # `[options]` probes each declared option and rolls its own per-probe
  # messages back, so the complaint has to be re-asked afterwards -- see
  # `addStarved`.
  test "reached only through [options], with no other usage line to report it":
    let spec = (port: opt("--port=<n>", default = 0, help = ""),)
    try:
      spec.parse(args = @["--port"], command = "app", usage = "[options]")
      check false # unreachable
    except ParseError as e:
      check "option --port requires a value" in e.msg

  test "and still names the token that starved it":
    let spec = (port: opt("--port=<n>", default = 0, help = ""),)
    try:
      spec.parse(args = @["--port", "-q"], command = "app", usage = "[options]")
      check false # unreachable
    except ParseError as e:
      check "option --port requires a value" in e.msg
      check "unrecognized option -q" in e.msg

  test "alongside a catch-all positional, which must not swallow it":
    let spec = (port: opt("--port=<n>", default = 0, help = ""),
                rest: args[string]("<rest>", help = ""))
    try:
      spec.parse(args = @["--port"], command = "app", usage = "[options] [<rest>...]")
      check false # unreachable
    except ParseError as e:
      check "option --port requires a value" in e.msg

  test "and when it's why a required positional went unfilled":
    # The `Argument` matcher reports its own "missing argument" and never
    # reaches the leftover branch, so it has to ask too.
    let spec = (speed: opt("--speed=<kn>", default = 0, help = ""),
                x: arg[int]("<x>", help = ""),
                y: arg[int]("<y>", help = ""))
    try:
      spec.parse(args = @["1", "--speed"], command = "app",
                 usage = "<x> <y> [--speed=<kn>]")
      check false # unreachable
    except ParseError as e:
      check "missing argument: <y>" in e.msg
      check "option --speed requires a value" in e.msg

suite "strictOptions: Non-Option Short is exempt":
  test "every Non-Option Short reaches a catch-all positional":
    for tok in NonOptionShorts:
      let spec = catchAllSpec()
      spec.parse(args = @[tok], command = "app", usage = CatchAll)
      check spec.rest == @[tok]

  test "every Non-Option Short is accepted in an option's value slot":
    for tok in NonOptionShorts:
      let spec = (num: opt("--num=<v>", default = "", help = ""), help: help())
      spec.parse(args = @["--num", tok], command = "app", usage = "[options]")
      check spec.num == tok

  test "a typed negative int arrives converted":
    let spec = (n: arg[int]("<n>", help = ""), help: help())
    spec.parse(args = @["-5"], command = "app", usage = "<n>")
    check spec.n == -5

  test "two leading dashes are never exempt":
    for tok in ["--nope", "--1_000", "--5x"]:
      let spec = catchAllSpec()
      expect ParseError:
        spec.parse(args = @[tok], command = "app", usage = CatchAll)

  test "`--5` isn't option-shaped in the first place, so the gate never sees it":
    # `longOption <- '--' \w (\w / ('-' \w))+` needs two characters after the
    # dashes, so `--5` is plain literal text -- outside this feature's scope
    # rather than an exemption. Pinned because it looks like a hole.
    let spec = catchAllSpec()
    spec.parse(args = @["--5"], command = "app", usage = CatchAll)
    check spec.rest == @["--5"]

  test "a second character that is an ASCII letter is never exempt":
    # Including `-inf`, which the rejected `parseFloat` predicate admitted.
    # A spec with no competing short option, so nothing resolves these.
    for tok in ["-x", "-inf", "-qq"]:
      let spec = (port: opt("--port=<n>", default = 0, help = ""),
                  rest: args("<rest>", help = ""), help: help())
      expect ParseError:
        spec.parse(args = @[tok], command = "app", usage = CatchAll)

  test "a declared short option still claims a cluster that starts with it":
    # `-nan` against a declared `-n` is `-n` with the folded value `an`,
    # not an unrecognized token -- declared spellings resolve first.
    let spec = catchAllSpec()
    spec.parse(args = @["-nan"], command = "app", usage = CatchAll)
    check spec.name == "an"

  test "bare `-` is not option-shaped at all and is unaffected":
    let spec = catchAllSpec()
    spec.parse(args = @["-"], command = "app", usage = CatchAll)
    check spec.rest == @["-"]

suite "strictOptions: a declared option whose variant is non-option-short":
  # A declared spelling resolves against the spec's tables first, so the
  # exemption only ever applies to undeclared tokens.
  proc declaredSpec(): auto =
    (one: flag("-1, --one", help = ""),
     v: flag("-v", help = ""),
     level: opt("-2=<n>", default = 0, help = ""),
     rest: args("<rest>", help = ""),
     help: help())

  test "a declared `-1` still matches as that flag":
    let spec = declaredSpec()
    spec.parse(args = @["-1"], command = "app", usage = CatchAll)
    check spec.one
    check spec.rest.len == 0

  test "its non-numeric alias still works":
    let spec = declaredSpec()
    spec.parse(args = @["--one"], command = "app", usage = CatchAll)
    check spec.one

  test "a declared numeric option takes its value, detached and attached":
    let spec = declaredSpec()
    spec.parse(args = @["-2", "5"], command = "app", usage = CatchAll)
    check spec.level == 5
    let spec2 = declaredSpec()
    spec2.parse(args = @["-2=5"], command = "app", usage = CatchAll)
    check spec2.level == 5

  test "an undeclared neighbour still falls through to the catch-all":
    let spec = declaredSpec()
    spec.parse(args = @["-3"], command = "app", usage = CatchAll)
    check not spec.one
    check spec.rest == @["-3"]

  test "a valid cluster of two declared flags composes":
    let spec = declaredSpec()
    spec.parse(args = @["-1v"], command = "app", usage = CatchAll)
    check spec.one
    check spec.v

  test "an undeclared Non-Option Short is still taken as another option's value":
    let spec = declaredSpec()
    spec.parse(args = @["-2", "-5"], command = "app", usage = CatchAll)
    check spec.level == -5

  test "but a declared one is claimed as its own option, starving the other":
    # Documented in the README: declaring `-1` means argumint reads it as
    # that flag everywhere it can, so `-2 -1` leaves `-2` with no value.
    let spec = declaredSpec()
    try:
      spec.parse(args = @["-2", "-1"], command = "app", usage = CatchAll)
      check false # unreachable
    except ParseError as e:
      check "option -2 requires a value" in e.msg

  test "the attached form gives a declared spelling to the value slot":
    let spec = declaredSpec()
    spec.parse(args = @["-2=-1"], command = "app", usage = CatchAll)
    check spec.level == -1
    check not spec.one

suite "strictOptions: a cluster remainder is not a Non-Option Short":
  # Deviation from the issue as written, agreed in review: the exemption is
  # for tokens the user typed. `-1.5` against a declared `-1` Flag peels to
  # `-.5`, a cluster continuation whose `-.` resolves to nothing -- an
  # unrecognized option exactly as `-1x`'s `-x` is. See ADR 0034.
  proc declaredSpec(): auto =
    (one: flag("-1, --one", help = ""),
     rest: args("<rest>", help = ""),
     help: help())

  test "a remainder is refused whether or not it looks like a Non-Option Short":
    for tok in ["-1.5", "-1x", "-1abc"]:
      let spec = declaredSpec()
      expect ParseError:
        spec.parse(args = @[tok], command = "app", usage = CatchAll)

  test "but the same text typed directly is exempt":
    let spec = declaredSpec()
    spec.parse(args = @["-.5"], command = "app", usage = CatchAll)
    check not spec.one
    check spec.rest == @["-.5"]

  test "the leading-space escape still forces `-1.5` through as one token":
    let spec = declaredSpec()
    spec.parse(args = @[" -1.5"], command = "app", usage = CatchAll)
    check not spec.one
    check spec.rest == @[" -1.5"]

  test "an Optional's `-ovalue` folding never reaches the gate":
    # `classify` folds `-2.5` into `-2=.5` at the `-ovalue` branch, so an
    # Optional yields a value rather than a cluster remainder.
    let spec = (two: opt("-2=<s>", default = "", help = ""),
                rest: args("<rest>", help = ""), help: help())
    spec.parse(args = @["-2.5"], command = "app", usage = CatchAll)
    check spec.two == ".5"
    check spec.rest.len == 0

suite "strictOptions: every escape hatch still works":
  test "a CLI-typed `--`":
    let spec = catchAllSpec()
    spec.parse(args = @["--", "--nope"], command = "app", usage = CatchAll)
    check spec.rest == @["--nope"]

  test "the ADR 0020 usage-string marker, with no `--` typed":
    let spec = catchAllSpec()
    spec.parse(args = @["--nope"], command = "app", usage = "[options] [--] [<rest>...]")
    check spec.rest == @["--nope"]

  test "the ADR 0020 marker routes a whole dash-leading region":
    # ADR 0020 point 3 flags the marker/`[options]` repeat-loop backtracking
    # as worth confirming empirically rather than by inspection.
    let spec = catchAllSpec()
    spec.parse(args = @["--port", "80", "--nope", "-x", "--por"],
               command = "app", usage = "[options] -- <rest>...")
    check spec.port == 80
    check spec.rest == @["--nope", "-x", "--por"]

  test "the leading-space form":
    let spec = catchAllSpec()
    spec.parse(args = @[" -x"], command = "app", usage = CatchAll)
    check spec.rest == @[" -x"]

  test "the attached-value form takes a dash-leading value":
    let spec = catchAllSpec()
    spec.parse(args = @["--name=--nope"], command = "app", usage = CatchAll)
    check spec.name == "--nope"

suite "strictOptions: with the setting off, today's behavior is unchanged":
  test "the catch-all absorbs an unrecognized option again":
    let spec = catchAllSpec()
    spec.parse(args = @["--nope"], command = "app", usage = CatchAll,
               settings = newSpecSettings(strictOptions = false))
    check spec.rest == @["--nope"]

  test "and absorbs a two-token near-miss":
    let spec = catchAllSpec()
    spec.parse(args = @["--por", "80"], command = "app", usage = CatchAll,
               settings = newSpecSettings(strictOptions = false))
    check spec.rest == @["--por", "80"]

suite "strictOptions: a spec with no catch-all errors either way":
  test "nothing could absorb it, so the setting is irrelevant":
    for strict in [true, false]:
      let spec = (port: opt("--port=<n>", default = 0, help = ""), help: help())
      expect ParseError:
        spec.parse(args = @["--nope"], command = "app", usage = "[options]",
                   settings = newSpecSettings(strictOptions = strict))

suite "strictOptions: shell completion needs no special case":
  test "an already-invalid prefix yields no candidates":
    # completeArgs never raises -- an unparseable prefix simply produces
    # nothing, leaving the shell's own file completion to take over
    # (ADR 0012).
    let spec = newSpec(catchAllSpec(), usage = CatchAll)
    check spec.completeArgs(@["--nope", ""], "app").len == 0

  test "a valid prefix still offers candidates":
    let spec = newSpec(catchAllSpec(), usage = CatchAll)
    check spec.completeArgs(@["--"], "app").len > 0
