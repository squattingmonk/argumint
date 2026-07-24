import std/[algorithm, options, os, sequtils, strutils, tables, terminal, unittest]

import argumint
import argumint/backend
import argumint/configsource/ini
import argumint/configsource/json
import argumint/fsm
import argumint/lexer
import argumint/validators

type Priority = enum
  low, medium, high

converter toPriority(value: string): Priority =
  parseEnum[Priority](value)

defineArg(Priority):
  case op
  of "=": value = arg
  else: raise newException(SpecDefect, "priority flags only support =")

type Level = enum
  quiet, normal, loud

converter toLevel(value: string): Level =
  parseEnum[Level](value)

defineFlag(Level, "Bump up one level"):
  case op
  of "": value = Level((ord(value) + 1) mod 3)
  of "=": value = arg
  else: raise newException(SpecDefect, "level flags only support = operations")

type Speed = enum
  slow, medium2, fast

converter toSpeed(value: string): Speed =
  parseEnum[Speed](value)

defineArg(Speed):
  # Deliberately doesn't support "=" -- used to test that `flag*` raises
  # SpecDefect when `env` is given for a type whose handler can't apply it.
  case op
  of "+=": value = Speed((ord(value) + 1) mod 3)
  else: raise newException(SpecDefect, "speed flags only support += operations")

type Color = enum
  red, green, blue

defineSetFlag(Color)

const warmColors = {red, green}

type
  FakeConfigSource = ref object of ConfigSource
    ## A minimal in-memory ConfigSource for exercising Value Precedence's
    ## Config Source tier without real file I/O -- see `fakeSource`.
    data: seq[(ConfigKey, seq[string])]
    lookups: int ## Counts `lookup` calls -- see the "queried at most once" regression test.

method lookup(self: FakeConfigSource, key: ConfigKey): Option[seq[string]] =
  self.lookups.inc
  for (k, v) in self.data:
    if k == key:
      return some(v)
  none(seq[string])

proc fakeSource(pairs: varargs[(ConfigKey, seq[string])]): ConfigSource =
  FakeConfigSource(data: @pairs)

suite "Positional args":
  test "parse scalar values and fall back to defaults when absent":
    let spec = (
      name: arg("<name>", default = "nobody", help = ""),
    )
    spec.parse(usage = "[<name>]", args = @["ship"], command = "prog")
    check spec.name == "ship"

    let spec2 = (
      name: arg("<name>", default = "nobody", help = ""),
    )
    spec2.parse(usage = "[<name>]", args = @[], command = "prog")
    check spec2.name == "nobody"

  test "parse multiple values without corrupting earlier elements (ORC regression)":
    let spec = (
      files: args[string]("<file>", help = ""),
    )
    spec.parse(usage = "<file>...", args = @["a", "b", "c", "d"], command = "prog")
    check spec.files == @["a", "b", "c", "d"]

  test "args[T] with no default given defaults to empty":
    let spec = (
      files: args[string]("<file>", help = ""),
    )
    spec.parse(usage = "[<file>...]", args = @[], command = "prog")
    check spec.files == newSeq[string]()

  test "args() with a non-empty default infers T without a bracket":
    let spec = (
      files: args("<file>", default = @["a", "b"], help = ""),
    )
    spec.parse(usage = "[<file>...]", args = @[], command = "prog")
    check spec.files == @["a", "b"]

suite "Optional args":
  test "parse `--option=value` and validate it":
    let spec = (
      speed: opt("--speed=<speed>", default = 1, validator = range(1..100), help = ""),
    )
    spec.parse(usage = "[--speed=<speed>]", args = @["--speed=42"], command = "prog")
    check spec.speed == 42

  test "raise ValidationError for values outside the validator's range":
    let spec = (
      speed: opt("--speed=<speed>", default = 1, validator = range(1..100), help = ""),
    )
    expect ValidationError:
      spec.parse(usage = "[--speed=<speed>]", args = @["--speed=999"], command = "prog")

  test "opts[T] with no default given defaults to empty":
    let spec = (
      tags: opts[string]("--tag=<tag>", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == newSeq[string]()

  test "opts() with a non-empty default infers T without a bracket":
    let spec = (
      tags: opts("--tag=<tag>", default = @["a", "b"], help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["a", "b"]

suite "Flags":
  test "bool flags toggle from their default":
    let spec = (
      moored: flag("--moored", default = false, help = ""),
    )
    spec.parse(usage = "[--moored]", args = @["--moored"], command = "prog")
    check spec.moored == true

  test "int flags apply their default increment op across repeats":
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @["--verbose", "--verbose", "--verbose"], command = "prog")
    check spec.verbosity == 3

  test "user-defined types work via the user's own converter (extensibility regression)":
    let spec = (
      p: flag[Priority]("--priority=high", default = low, help = ""),
    )
    spec.parse(usage = "[--priority]", args = @["--priority"], command = "prog")
    check spec.p == high

  test "SpecDefect raised when variantHelp references an unknown variant":
    expect SpecDefect:
      discard flag[int]("-v, --verbose", default = 0, help = "",
        variantHelp = {"--bogus": "nope"}.toTable)

  test "variantValues supplies a typed value directly, bypassing string parsing":
    let spec = (
      p: flag[Priority]("--priority=", default = low, variantValues = {"--priority": high}.toTable, help = ""),
    )
    spec.parse(usage = "[--priority]", args = @["--priority"], command = "prog")
    check spec.p == high

  test "SpecDefect raised when a variant has both a string value and a variantValues entry":
    expect SpecDefect:
      discard flag[Priority]("--priority=high", default = low,
        variantValues = {"--priority": high}.toTable, help = "")

  test "SpecDefect raised when variantValues references an unknown variant":
    expect SpecDefect:
      discard flag[int]("-v, --verbose", default = 0, help = "",
        variantValues = {"--bogus": 5}.toTable)

  test "custom flag types get auto-generated =/+=/-= descriptions for free":
    let spec = (
      p: flag[Priority]("--priority=high, --boost=medium", default = low, help = "Set priority"),
      help: help(),
    )
    var helpText = ""
    try: spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e: helpText = e.msg
    # --priority is the primary (first-declared) group, so it keeps the
    # shared `help` text; only the divergent --boost group shows its own
    # auto-generated description.
    check "Set priority" in helpText
    check "Set to medium" in helpText

  test "a custom flag type can supply blank-op wording via defineFlag":
    let spec = (
      lvl: flag[Level]("--set=loud, -b, --bump", default = quiet, help = "Adjust level"),
      help: help(),
    )
    var helpText = ""
    try: spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e: helpText = e.msg
    # --set is the primary group here, so -b/--bump (the divergent
    # blank-op group) is what shows the defineFlag-supplied blankDesc.
    check "Adjust level" in helpText
    check "Bump up one level" in helpText

suite "Set flags":
  test "= sets the value to a singleton set, replacing any existing elements":
    let spec = (colors: flag[set[Color]]("--red=red, --green=green", default = {blue}, help = ""))
    spec.parse(args = @["--red"], command = "prog")
    check spec.colors == {red}

  test "+= includes the element without clearing existing ones":
    let spec = (colors: flag[set[Color]]("--red=red, --add-green+=green", default = {}, help = ""))
    spec.parse(usage = "[--red] [--add-green]", args = @["--red", "--add-green"], command = "prog")
    check spec.colors == {red, green}

  test "-= excludes the element":
    let spec = (colors: flag[set[Color]]("--remove-red-=red", default = {red, green}, help = ""))
    spec.parse(args = @["--remove-red"], command = "prog")
    check spec.colors == {green}

  test "*= keeps the element only if already present (intersection)":
    let spec = (colors: flag[set[Color]]("--only-red*=red", default = {red, green}, help = ""))
    spec.parse(args = @["--only-red"], command = "prog")
    check spec.colors == {red}

  test "*= drops everything when the element isn't present":
    let spec = (colors: flag[set[Color]]("--only-blue*=blue", default = {red, green}, help = ""))
    spec.parse(args = @["--only-blue"], command = "prog")
    check spec.colors == {}

  test "variantValues supplies a multi-element set directly, including a referenced const":
    let spec = (colors: flag[set[Color]]("--warm=", variantValues = {"--warm": warmColors}.toTable, default = {}, help = ""))
    spec.parse(args = @["--warm"], command = "prog")
    check spec.colors == {red, green}

suite "[options] catch-all":
  test "an option mentioned explicitly can't also be matched again via [options]":
    let spec = (
      verbose: flag("--verbose", help = ""),
      moored: flag("--moored", help = ""),
    )
    spec.parse(usage = "[options] --verbose", args = @["--verbose"], command = "prog")

    expect ParseError:
      spec.parse(usage = "[options] --verbose", args = @["--verbose", "--verbose"], command = "prog")

  test "an option only reachable via [options] is unaffected":
    let spec = (
      verbose: flag("--verbose", help = ""),
      moored: flag("--moored", help = ""),
    )
    spec.parse(usage = "[options] --verbose", args = @["--moored", "--verbose"], command = "prog")
    check spec.moored == true

  test "the exclusion also applies to value-taking options (opt())":
    let spec = (
      speed: opt("--speed=<speed>", default = 1, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "[options] --speed=<speed>", args = @["--speed=1", "--speed=2"], command = "prog")

  test "an explicit repeat (...) on the mentioned option still works":
    let spec = (
      verbose: flag[int]("--verbose", default = 0, help = ""),
    )
    spec.parse(usage = "[options] --verbose...", args = @["--verbose", "--verbose", "--verbose"], command = "prog")
    check spec.verbose == 3

  test "the exclusion applies to options nested inside a mutually-exclusive choice group":
    let spec = (
      moored: flag("--moored", help = ""),
      drifting: flag("--drifting", help = ""),
    )
    let usage = "[options] [--moored | --drifting]"

    spec.parse(usage = usage, args = @["--moored"], command = "prog")
    check spec.moored == true

    expect ParseError:
      spec.parse(usage = usage, args = @["--moored", "--moored"], command = "prog")

    expect ParseError:
      spec.parse(usage = usage, args = @["--moored", "--drifting"], command = "prog")

    spec.parse(usage = usage, args = @[], command = "prog")

  test "[options]... lets a catch-all-only flag be matched more than once":
    let spec = (verbosity: flag[int]("--verbose", default = 0, help = ""))
    spec.parse(usage = "[options]...", args = @["--verbose", "--verbose", "--verbose"], command = "prog")
    check spec.verbosity == 3

  test "[options]... lets a catch-all-only multi-value opt accumulate":
    let spec = (tags: opts[string]("--tag=<tag>", help = ""))
    spec.parse(usage = "[options]...", args = @["--tag=a", "--tag=b"], command = "prog")
    check spec.tags == @["a", "b"]

  test "bare [options] (no ...) still allows a catch-all-only option to be matched more than once":
    let spec = (verbosity: flag[int]("--verbose", default = 0, help = ""))
    spec.parse(usage = "[options]", args = @["--verbose", "--verbose", "--verbose"], command = "prog")
    check spec.verbosity == 3

  test "bare [options] (no ...) lets a catch-all-only multi-value opt accumulate":
    let spec = (tags: opts[string]("--tag=<tag>", help = ""))
    spec.parse(usage = "[options]", args = @["--tag=a", "--tag=b"], command = "prog")
    check spec.tags == @["a", "b"]

  test "an option named explicitly on one Usage Line is still reachable via [options] on another":
    let spec = (
      name: arg("<name>", help = ""),
      format: opt("--format=<value>", default = "", help = ""),
    )
    let usage = "--format=<value>\n[options] <name>"

    # Line 1 requires exactly `--format=<value>` with no positional; line 2
    # is the one actually exercised here.
    spec.parse(usage = usage, args = @["--format=json", "somename"], command = "prog")
    check spec.name == "somename"
    check spec.format == "json"

  test "an option named explicitly (as part of a cluster) on one Usage Line is still reachable via [options] on another":
    let spec = (
      name: arg("<name>", help = ""),
      verbose: flag("-v", help = ""),
      quiet: flag("-q", help = ""),
    )
    let usage = "-vq\n[options] <name>"

    spec.parse(usage = usage, args = @["-v", "somename"], command = "prog")
    check spec.name == "somename"
    check spec.verbose == true

  test "an explicitly-mentioned option stays single-match even when the rest of [options]... repeats":
    let spec = (
      format: opt("--format=<value>", default = "", help = ""),
      verbose: flag[int]("--verbose", default = 0, help = ""),
    )
    let usage = "[options]... [--format=<value>]"
    spec.parse(usage = usage, args = @["--verbose", "--verbose", "--format=json"], command = "prog")
    check spec.verbose == 2
    check spec.format == "json"

    expect ParseError:
      spec.parse(usage = usage, args = @["--format=json", "--format=yaml"], command = "prog")

suite "Commands":
  test "a matched subcommand's action fires with its own parsed values":
    var moved = ""
    proc cmdMove(spec: tuple) =
      moved = spec.name

    let move = (name: arg("<name>", help = ""))
    let spec = (
      ship: command("ship", move, action = cmdMove, usage = "<name>", help = ""),
    )
    spec.parse(usage = "ship", args = @["ship", "Titanic"], command = "prog")
    check moved == "Titanic"

  test "before runs root-to-leaf, action fires once at the leaf, after runs leaf-to-root":
    var log: seq[string]
    proc outerBefore(spec: tuple) = log.add "outer-before"
    proc outerAfter(spec: tuple) = log.add "outer-after"
    proc innerBefore(spec: tuple) = log.add "inner-before"
    proc innerAction(spec: tuple) = log.add "inner-action"
    proc innerAfter(spec: tuple) = log.add "inner-after"

    let inner = (name: arg("<name>", help = ""))
    let outer = (
      move: command("move", inner, before = innerBefore, action = innerAction, after = innerAfter, usage = "<name>", help = ""),
    )
    let spec = (
      ship: command("ship", outer, before = outerBefore, after = outerAfter, help = ""),
    )
    spec.parse(usage = "ship", args = @["ship", "move", "Titanic"], command = "prog")
    check log == @["outer-before", "inner-before", "inner-action", "inner-after", "outer-after"]

  test "action fires when a command is invoked bare, but not when it routes to a subcommand":
    var shipActionFired = false
    var moveActionFired = false
    proc shipAction(spec: tuple) = shipActionFired = true
    proc moveAction(spec: tuple) = moveActionFired = true

    let move1 = ()
    let ship1 = (move: command("move", move1, action = moveAction, help = ""))
    let bareSpec = (ship: command("ship", ship1, action = shipAction, usage = "[move]", help = ""))
    bareSpec.parse(usage = "ship", args = @["ship"], command = "prog")
    check shipActionFired
    check not moveActionFired

    shipActionFired = false
    moveActionFired = false
    let move2 = ()
    let ship2 = (move: command("move", move2, action = moveAction, help = ""))
    let routedSpec = (ship: command("ship", ship2, action = shipAction, usage = "[move]", help = ""))
    routedSpec.parse(usage = "ship", args = @["ship", "move"], command = "prog")
    check not shipActionFired
    check moveActionFired

  test "before/action/after passed to the top-level parse* call fire around the whole tree":
    var log: seq[string]
    proc appBefore(spec: tuple) = log.add "app-before"
    proc appAction(spec: tuple) = log.add "app-action"
    proc appAfter(spec: tuple) = log.add "app-after"

    let spec = (name: arg("<name>", help = ""))
    spec.parse(usage = "<name>", args = @["Titanic"], command = "prog",
      before = appBefore, action = appAction, after = appAfter)
    check log == @["app-before", "app-action", "app-after"]

  test "an ancestor's after still runs when a nested command's own before raises":
    var log: seq[string]
    proc outerBefore(spec: tuple) = log.add "outer-before"
    proc outerAfter(spec: tuple) = log.add "outer-after"
    proc innerBefore(spec: tuple) = raise newException(CatchableError, "boom")
    proc innerAfter(spec: tuple) = log.add "inner-after"

    let inner = ()
    let outer = (
      move: command("move", inner, before = innerBefore, after = innerAfter, help = ""),
    )
    let spec = (
      ship: command("ship", outer, before = outerBefore, after = outerAfter, help = ""),
    )
    expect CatchableError:
      spec.parse(usage = "ship", args = @["ship", "move"], command = "prog")
    check log == @["outer-before", "outer-after"]

  test "before fires before a matched --help raises, and after still fires":
    var log: seq[string]
    proc appBefore(spec: tuple) = log.add "before"
    proc appAfter(spec: tuple) = log.add "after"

    let spec = (
      name: arg("<name>", help = ""),
      help: help(),
    )
    expect HelpError:
      spec.parse(usage = "<name>\n--help", args = @["--help"], command = "prog",
        before = appBefore, after = appAfter)
    check log == @["before", "after"]

  test "before fires before a matched message/version flag raises, and after still fires":
    var log: seq[string]
    proc appBefore(spec: tuple) = log.add "before"
    proc appAfter(spec: tuple) = log.add "after"

    let spec = (
      ver: version("myapp 1.2.3"),
    )
    expect MessageError:
      spec.parse(usage = "--version", args = @["--version"], command = "prog",
        before = appBefore, after = appAfter)
    check log == @["before", "after"]

  test "the [S, O] overload's options param reaches before, action, and after":
    var seenBefore, seenAction, seenAfter = ""
    let context = (label: "outer-context")
    proc cmdBefore(spec: tuple, opts: tuple) = seenBefore = opts.label
    proc cmdAction(spec: tuple, opts: tuple) = seenAction = opts.label
    proc cmdAfter(spec: tuple, opts: tuple) = seenAfter = opts.label

    let inner = ()
    let spec = (
      ship: command("ship", inner, context, before = cmdBefore, action = cmdAction, after = cmdAfter, help = ""),
    )
    spec.parse(usage = "ship", args = @["ship"], command = "prog")
    check seenBefore == "outer-context"
    check seenAction == "outer-context"
    check seenAfter == "outer-context"

  test "a nested command's own --help renders its own spec, not a sibling level's":
    # [--help] is explicitly named (not the [options] catch-all, which
    # excludes MessageArg/HelpArg) so it's reachable alongside `ship` in
    # one line, letting the walk enter ship's own subgraph (mutating
    # pc.spec) in the same successful walk that matched --help at the top
    # level -- exercising the fix that scopes HelpArg dispatch to the
    # correct per-level spec instead of the walk's final pc.spec.
    let spec = (
      ship: command("ship", (), help = ""),
      help: help(),
    )
    var helpText = ""
    try: spec.parse(usage = "[--help] ship", prolog = "TOP LEVEL", args = @["--help", "ship"], command = "prog")
    except HelpError as e: helpText = e.msg
    check "TOP LEVEL" in helpText

  test "a nested subcommand's own matched --help fires before/after root-to-leaf, same shape as action":
    var log: seq[string]
    proc outerBefore(spec: tuple) = log.add "outer-before"
    proc outerAfter(spec: tuple) = log.add "outer-after"
    proc innerBefore(spec: tuple) = log.add "inner-before"
    proc innerAfter(spec: tuple) = log.add "inner-after"

    let move = (help: help())
    let ship = (
      move: command("move", move, before = innerBefore, after = innerAfter, usage = "--help", help = ""),
    )
    let spec = (
      ship: command("ship", ship, before = outerBefore, after = outerAfter, help = ""),
    )
    expect HelpError:
      spec.parse(usage = "ship", args = @["ship", "move", "--help"], command = "prog")
    check log == @["outer-before", "inner-before", "inner-after", "outer-after"]

  test "two Commands can share one underlying proc, parameterized differently per call site":
    var log: seq[string]
    proc cmdToggle(spec: tuple, on: bool) =
      log.add (if on: "on" else: "off")

    let spec1 = (
      start: command("start", (), action = (proc(spec: tuple) = cmdToggle(spec, true)), help = ""),
      stop: command("stop", (), action = (proc(spec: tuple) = cmdToggle(spec, false)), help = ""),
    )
    spec1.parse(usage = "(start | stop)", args = @["start"], command = "prog")

    let spec2 = (
      start: command("start", (), action = (proc(spec: tuple) = cmdToggle(spec, true)), help = ""),
      stop: command("stop", (), action = (proc(spec: tuple) = cmdToggle(spec, false)), help = ""),
    )
    spec2.parse(usage = "(start | stop)", args = @["stop"], command = "prog")

    check log == @["on", "off"]

  test "the same Arg reachable at both an ancestor and a nested command's grammar gets each occurrence attributed to the right level":
    let tag = opts[string]("--tag=<tag>", help = "")
    let ship = (tag: tag)
    let spec = (
      tag: tag,
      ship: command("ship", ship, usage = "[--tag=<tag>]", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>] ship", args = @["--tag=a", "ship", "--tag=b"], command = "prog")
    check tag == @["a", "b"]

  test "SpecDefect: two top-level sibling Commands sequential in one Usage Line":
    # Direct reproduction from the originating issue: once `foo` matches,
    # tokenizeArgs hands off every remaining token to foo's own nested spec,
    # so `bar` can never be reached.
    expect SpecDefect:
      discard newSpec((
        foo: command("foo", (name: arg("<name>", help = "")), usage = "<name>", help = ""),
        bar: command("bar", (name: arg("<name>", help = "")), usage = "<name>", help = ""),
      ), usage = "foo bar")

  test "SpecDefect: a Command followed by a plain positional from the outer spec":
    # Not just a second Command -- anything from the outer spec following a
    # Command sequentially is equally unreachable.
    expect SpecDefect:
      discard newSpec((
        foo: command("foo", (), help = ""),
        name: arg("<name>", help = ""),
      ), usage = "foo <name>")

  test "SpecDefect: a Command inside a bracket or paren group still blocks what follows":
    # The blind spot a check scoped to one sequence() call frame would miss:
    # `foo` is parsed in a nested sequence() call (the bracket/paren branch
    # of atom()), `bar` in the outer one -- same runtime bug regardless.
    for usage in ["[foo] bar", "(foo) bar"]:
      expect SpecDefect:
        discard newSpec((
          foo: command("foo", (), help = ""),
          bar: command("bar", (), help = ""),
        ), usage = usage)

  test "SpecDefect: a Command after a choice whose alternative already contains a Command":
    # (foo | baz) bar: the `foo` branch alone hits the same runtime bug once
    # `bar` follows, even though the `baz` branch on its own is fine.
    expect SpecDefect:
      discard newSpec((
        foo: command("foo", (), help = ""),
        baz: command("baz", (), help = ""),
        bar: command("bar", (), help = ""),
      ), usage = "(foo | baz) bar")

  test "sibling Commands as choice alternatives alone remain legal":
    let spec = (
      foo: command("foo", (), help = ""),
      bar: command("bar", (), help = ""),
    )
    spec.parse(usage = "(foo | bar)", args = @["foo"], command = "prog")

  test "a Command reused as both a top-level sibling and a nested command's own subcommand doesn't trip the check":
    # `b` is both a top-level sibling of `a` and `a`'s own subcommand -- the
    # exact same CommandArg, mirroring "the same Arg reachable at both an
    # ancestor and a nested command's grammar" above, but for a Command.
    # Compiling `a\nb` must not raise SpecDefect, and each route must reach
    # the shared underlying command.
    var log: seq[string]
    proc bAction(spec: tuple) = log.add "b"

    block:
      let bCmd = command("b", (), action = bAction, help = "")
      let spec = (
        a: command("a", (b: bCmd), usage = "b", help = ""),
        b: bCmd,
      )
      spec.parse(usage = "a\nb", args = @["a", "b"], command = "prog")

    block:
      let bCmd = command("b", (), action = bAction, help = "")
      let spec = (
        a: command("a", (b: bCmd), usage = "b", help = ""),
        b: bCmd,
      )
      spec.parse(usage = "a\nb", args = @["b"], command = "prog")

    check log == @["b", "b"]

  test "SpecDefect: a repeated Command can never satisfy its own repeat":
    # foo...: once the first `foo` matches, tokenizeArgs hands off every
    # remaining token to foo's own nested spec permanently, so the self-loop
    # wired for `...` can never actually be re-entered by a second `foo`.
    expect SpecDefect:
      discard newSpec((
        foo: command("foo", (), help = ""),
      ), usage = "foo...")

  test "SpecDefect: a repeated group containing a Command is equally broken":
    # (foo)... and (foo | bar)...: repeating a group requires re-entering
    # its own start state, which a matched Command's permanent hand-off
    # prevents just as much as a bare repeated Command does.
    for usage in ["(foo)...", "(foo | bar)..."]:
      expect SpecDefect:
        discard newSpec((
          foo: command("foo", (), help = ""),
          bar: command("bar", (), help = ""),
        ), usage = usage)

  test "a repeated non-Command atom is unaffected":
    let spec = (names: args[string]("<name>", help = ""))
    spec.parse(usage = "<name>...", args = @["a", "b", "c"], command = "prog")
    check spec.names == @["a", "b", "c"]

suite "End-of-Options Marker":
  test "SpecDefect: an Option after -- in the same Usage Line":
    expect SpecDefect:
      discard newSpec((
        name: arg("<name>", help = ""),
        speed: opt("--speed=<speed>", default = 1, help = ""),
      ), usage = "<name> -- --speed=<speed>")

  test "SpecDefect: a Flag after -- in the same Usage Line":
    expect SpecDefect:
      discard newSpec((
        name: arg("<name>", help = ""),
        verbose: flag("--verbose", help = ""),
      ), usage = "<name> -- --verbose")

  test "SpecDefect: [options] after -- in the same Usage Line":
    expect SpecDefect:
      discard newSpec((
        name: arg("<name>", help = ""),
        verbose: flag("--verbose", help = ""),
      ), usage = "<name> -- [options]")

  test "SpecDefect: a Command after -- in the same Usage Line":
    expect SpecDefect:
      discard newSpec((
        name: arg("<name>", help = ""),
        foo: command("foo", (), help = ""),
      ), usage = "<name> -- foo")

  test "SpecDefect: a dead-code atom nested inside a bracket or paren group after -- still blocks it":
    for usage in ["<name> -- [--verbose]", "<name> -- (--verbose)"]:
      expect SpecDefect:
        discard newSpec((
          name: arg("<name>", help = ""),
          verbose: flag("--verbose", help = ""),
        ), usage = usage)

  test "SpecDefect: a second -- in the same Usage Line":
    expect SpecDefect:
      discard newSpec((
        a: arg("<a>", help = ""),
        b: arg("<b>", help = ""),
        c: arg("<c>", help = ""),
      ), usage = "<a> -- <b> -- <c>")

  test "SpecDefect: -- repeated with '...'":
    expect SpecDefect:
      discard newSpec((), usage = "--...")

  test "a Positional Argument (bare or grouped) may follow -- without tripping the check":
    let spec = (
      name: arg("<name>", help = ""),
      rest: args[string]("<rest>", help = ""),
    )
    spec.parse(usage = "<name> -- <rest>...", args = @["x", "y", "z"], command = "prog")
    check spec.name == "x"
    check spec.rest == @["y", "z"]

  test "bare -- <arg>... requires at least one arg after the marker":
    let spec = (rest: args[string]("<rest>", help = ""))
    expect ParseError:
      spec.parse(usage = "-- <rest>...", args = @[], command = "prog")

  test "[-- <arg>...] makes the whole marker-plus-args group skippable":
    let spec = (rest: args[string]("<rest>", help = "", default = @["untouched"]))
    spec.parse(usage = "[-- <rest>...]", args = @[], command = "prog")
    check spec.rest == @["untouched"]

  test "[--] and [ -- ] alone parse identically to bare --":
    # No Option/Flag declared at all here -- otherwise autoFillUsage would
    # silently append a competing "[options]" alternative for it (since
    # it'd be unreachable via this usage string), which legitimately wins
    # matcher priority over the marker and would confound this check.
    for usage in ["-- <name>", "[--] <name>", "[ -- ] <name>"]:
      block:
        let spec = (name: arg("<name>", help = ""))
        spec.parse(usage = usage, args = @["x"], command = "prog")
        check spec.name == "x"
      block:
        let spec = (name: arg("<name>", help = ""))
        spec.parse(usage = usage, args = @["--", "x"], command = "prog")
        check spec.name == "x"

suite "Empty specs":
  test "a top-level spec with zero declared args parses successfully given zero input":
    parse((), args = @[], command = "prog")

  test "two argument-less subcommands in a choice each parse correctly on their own":
    let spec = (
      ship: command("ship", (), help = "Ship"),
      mine: command("mine", (), help = "Mine"),
      help: help(),
    )
    spec.parse(usage = "(ship | mine)\n--help", args = @["ship"], command = "prog")

    let spec2 = (
      ship: command("ship", (), help = "Ship"),
      mine: command("mine", (), help = "Mine"),
      help: help(),
    )
    spec2.parse(usage = "(ship | mine)\n--help", args = @["mine"], command = "prog")

  test "an argument-less subcommand nested inside another subcommand parses correctly":
    let inner = (status: command("status", (), help = "Status"), help: help())
    let spec = (ship: command("ship", inner, help = "Ship"), help: help())
    spec.parse(usage = "ship", args = @["ship", "status"], command = "prog")

  test "an argument-less subcommand mixed with a normal one in the same choice still parses both":
    let spec = (
      status: command("status", (), help = "Status"),
      move: command("move", (x: arg("<x>", default = 0, help = "")), help = "Move"),
      help: help(),
    )
    spec.parse(usage = "(status | move)\n--help", args = @["status"], command = "prog")

    let moveArgs = (x: arg("<x>", default = 0, help = ""))
    let spec2 = (
      status: command("status", (), help = "Status"),
      move: command("move", moveArgs, help = "Move"),
      help: help(),
    )
    spec2.parse(usage = "(status | move)\n--help", args = @["move", "5"], command = "prog")
    check moveArgs.x == 5

suite "Errors":
  test "raise ParseError for unrecognized options":
    # ADR 0019: an option-shaped token undeclared anywhere in the spec is
    # only rejected when nothing else could take it -- this spec has no
    # positional arg at all, so "--nope" has nowhere left to fall through to.
    let spec = (
      verbose: flag("--verbose", help = ""),
    )
    expect ParseError:
      spec.parse(args = @["--nope"], command = "prog")

  test "unrecognized long options off by 1 character can trigger a suggestion":
    let spec = (
      help: help()
    )
    try:
      spec.parse(args = @["--hlp"], command = "prog")
    except ParseError as e:
      check "did you mean --help?" in e.msg

    try:
      spec.parse(args = @["--hlpp"], command = "prog")
    except ParseError as e:
      check "did you mean --help?" notin e.msg

    try:
      spec.parse(args = @["-j"], command = "prog")
    except ParseError as e:
      check "did you mean -h?" notin e.msg

  test "raise SpecDefect for a malformed positional variant":
    expect SpecDefect:
      discard newSpec((bad: arg("bad", help = "")))

  test "raise SpecDefect for a duplicate arg name":
    expect SpecDefect:
      discard newSpec((a: arg("<x>", help = ""), b: arg("<x>", help = "")))

  test "an [options]-only flag failing doesn't produce a duplicate message":
    let spec = (
      verbose: flag("--verbose", help = ""),
      add: command("add", (help: help()), help = "Add"),
      help: help(),
    )
    var caught = ""
    try:
      spec.parse(args = @[], command = "prog")
    except ParseError as e:
      caught = e.msg
    check caught.count("--verbose") == 1

  test "a satisfied repeated positional isn't reported missing when a later arg is":
    let spec = (
      src: args[string]("<src>", help = ""),
      dest: arg("<dest>", help = ""),
    )
    var caught = ""
    try:
      spec.parse(usage = "<src>... <dest>", args = @["a.txt"], command = "prog")
    except ParseError as e:
      caught = e.msg
    check "missing argument: <dest>" in caught
    check "missing argument: <src>" notin caught

  test "same-kind alternatives are grouped onto one line joined by |":
    let spec = (
      ship: command("ship", (help: help()), help = "Ship"),
      mine: command("mine", (help: help()), help = "Mine"),
      help: help(),
    )
    var caught = ""
    try:
      spec.parse(usage = "(ship | mine)\n(-h | --help)", args = @[], command = "prog")
    except ParseError as e:
      caught = e.msg
    check "missing command: (ship | mine)" in caught

  test "a single missing requirement renders without a | separator":
    let spec = (
      name: arg("<name>", help = ""),
    )
    var caught = ""
    try:
      spec.parse(usage = "<name>", args = @[], command = "prog")
    except ParseError as e:
      caught = e.msg
    check "missing argument: <name>" in caught
    check "|" notin caught

suite "parse(tuple)":
  test "parses a valid tuple in one step, same as newSpec + Spec.parse":
    let spec = (name: arg("<name>", help = ""))
    spec.parse(usage = "<name>", args = @["ship"], command = "prog")
    check spec.name == "ship"

  test "raises ParseError on bad CLI input instead of quitting":
    let spec = (name: arg("<name>", help = ""))
    expect ParseError:
      spec.parse(usage = "<name>", args = @[], command = "prog")

  test "raises SpecDefect on a malformed spec instead of quitting":
    expect SpecDefect:
      let spec = (bad: arg("bad", help = ""))
      spec.parse(args = @[], command = "prog")

suite "Messages":
  test "help() raises HelpError with the generated help text":
    let spec = (
      name: arg("<name>", help = "who to greet"),
      help: help(),
    )
    expect HelpError:
      spec.parse(usage = "<name>\n--help", args = @["--help"], command = "prog")

  test "version() raises MessageError with the configured text":
    let spec = (
      ver: version("myapp 1.2.3"),
    )
    var caught = ""
    try:
      spec.parse(usage = "--version", args = @["--version"], command = "prog")
    except MessageError as e:
      caught = e.msg
    check caught == "myapp 1.2.3"

  test "help text does not show hidden args":
    let spec = (
      deprecated: flag("--deprecated", help = "A deprecated flag", hidden = true),
      help: help()
    )
    try:
      spec.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      check "--deprecated" notin e.msg

  test "hidden args can still be parsed":
    let spec = (
      deprecated: flag("--deprecated", help = "A deprecated flag", hidden = true),
      help: help()
    )
    spec.parse(args = @["--deprecated"], command = "prog")
    check spec.deprecated == true

  test "help text lists groups as Commands, Arguments, Options, then user-defined groups":
    let spec = (
      verbose: flag("--verbose", help = "Verbose", group = "Global Options"),
      speed: opt("--speed=<speed>", default = 1, help = "Speed"),
      file: arg("<file>", help = "The file"),
      cmd: command("cmd", (x: arg("<x>", help = "x")), help = "A subcommand"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let order = @["Commands", "Arguments", "Options", "Global Options"].mapIt(helpText.find(it))
    check order == order.sorted
    check order.allIt(it >= 0)

  test "help text aligns variant columns across groups and skips padding for empty help":
    let spec = (
      verbose: flag("--verbose", help = "", group = "Global Options"),
      speed: opt("--speed=<speed>", default = 1, help = "Speed"),
      file: arg("<file>", help = "The file"),
      cmd: command("cmd", (x: arg("<x>", help = "x")), help = "A subcommand"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let width = "--speed=<speed>".len
    check ("  " & "cmd".alignLeft(width) & "  A subcommand") in helpText
    check ("  " & "<file>".alignLeft(width) & "  The file") in helpText
    check ("  --speed=<speed>  Speed") in helpText
    check "  --verbose" in helpText.splitLines

  test "variants column wraps at maxVariantsWidth with help text aligned to the first wrapped line":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 20), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let firstLine = "  " & "-v, --verbose,".alignLeft(20) & "  Adjust verbosity"
    let lines = helpText.splitLines
    let firstIdx = lines.find(firstLine)
    check firstIdx >= 0
    check lines[firstIdx + 1] == "    --quiet, --boost,"
    check lines[firstIdx + 2] == "    --dampen"

  test "variants column wraps without trailing whitespace when help text is empty":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = ""),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 20), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let lines = helpText.splitLines
    check "  -v, --verbose," in lines
    check "    --quiet, --boost," in lines
    check "    --dampen" in lines
    for line in lines:
      check line == line.strip(leading = false, trailing = true)

  test "a flag with divergent per-variant ops groups into rows, primary row keeping the shared help":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let colWidth = "-v, --verbose".len
    check ("  " & "-v, --verbose".alignLeft(colWidth) & "  Adjust verbosity [action: Increment by 1]") in helpText
    check ("    " & "--quiet".alignLeft(colWidth) & "  Set to 0") in helpText
    check ("    " & "--boost".alignLeft(colWidth) & "  Increase by 5") in helpText
    check ("    " & "--dampen".alignLeft(colWidth) & "  Decrease by 2") in helpText

  test "primary row shows [action: X] alone when arg.help is empty":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0", default = 0, help = ""),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "  -v, --verbose  [action: Increment by 1]" in helpText

  test "variantHelp overrides the auto-generated description for a specific variant":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2", default = 0, help = "Adjust verbosity",
        variantHelp = {"--quiet": "Reset to silent"}.toTable),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Reset to silent" in helpText
    check "Set to 0" notin helpText

  test "a bool flag's blank-op variants show \"Toggle the value\" when grouped with a divergent peer":
    let spec = (
      moored: flag("--docked=true, -m, --moored", default = false, help = "Ship status"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Ship status" in helpText
    check "Toggle the value" in helpText

  test "same-op variants collapse into a single ungrouped row (no divergence to disambiguate)":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "  -v, --verbose  Adjust verbosity" in helpText
    check "Increment by 1" notin helpText

  test "maxVariantsWidth defaults to 30 and is configurable":
    proc mkSpec(): auto = (verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = "Adjust verbosity"), help: help())
    let default = newSpec(mkSpec())
    let narrow = newSpec(mkSpec(), settings = newSpecSettings(maxVariantsWidth = 20))
    let unlimited = newSpec(mkSpec(), settings = newSpecSettings(maxVariantsWidth = 0))
    check default.settings.maxVariantsWidth == 30
    check narrow.settings.maxVariantsWidth == 20
    check unlimited.settings.maxVariantsWidth == 0

    var defaultText, unlimitedText = ""
    try: default.parse(@["--help"], "prog")
    except HelpError as e: defaultText = e.msg
    try: unlimited.parse(@["--help"], "prog")
    except HelpError as e: unlimitedText = e.msg

    check ("  " & "-v, --verbose, --quiet,".alignLeft(30) & "  Adjust verbosity") in defaultText
    check "    --boost, --dampen" in defaultText.splitLines
    check ("  -v, --verbose, --quiet, --boost, --dampen  Adjust verbosity") in unlimitedText

  test "maxVariantsWidth cascades from the root spec into nested subcommand specs":
    let move = (name: arg("<name>", help = ""), help: help())
    let ship = (move: command("move", move, help = "Move a ship"), help: help())
    let s = newSpec((ship: command("ship", ship, help = "Ship commands"), help: help()), settings = newSpecSettings(maxVariantsWidth = 20))
    check s.settings.maxVariantsWidth == 20
    check s.commands["ship"].spec.settings.maxVariantsWidth == 20
    check s.commands["ship"].spec.commands["move"].spec.settings.maxVariantsWidth == 20

  test "a SpecSettings instance is shared by reference, not copied, across the whole tree":
    let move = (name: arg("<name>", help = ""), help: help())
    let ship = (move: command("move", move, help = "Move a ship"), help: help())
    let settings = newSpecSettings(maxVariantsWidth = 20)
    let s = newSpec((ship: command("ship", ship, help = "Ship commands"), help: help()), settings = settings)
    check s.settings == settings
    check s.commands["ship"].spec.settings == settings
    check s.commands["ship"].spec.commands["move"].spec.settings == settings

    settings.maxVariantsWidth = 5
    check s.settings.maxVariantsWidth == 5
    check s.commands["ship"].spec.commands["move"].spec.settings.maxVariantsWidth == 5

  test "a before hook mutating shared SpecSettings affects this level's own --help, not just descendants'":
    # Exercises the ordering fix in docs/adr/0013-message-args-fire-after-before.md:
    # --help now parses after `before`, so a mutation made there is visible
    # in this level's own help output too, not only a nested command's.
    let settings = newSpecSettings(maxVariantsWidth = 0)
    proc widenColumn(spec: tuple) = settings.maxVariantsWidth = 100

    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = settings, args = @["--help"], command = "prog", before = widenColumn)
    except HelpError as e:
      helpText = e.msg
    check ("  -v, --verbose, --quiet, --boost, --dampen  Adjust verbosity") in helpText

  test "usage lines longer than 80 columns wrap with a hanging indent":
    let spec = (
      a: opt("--alpha=<a>", default = "", help = ""),
      b: opt("--bravo=<b>", default = "", help = ""),
      c: opt("--charlie=<c>", default = "", help = ""),
      d: opt("--delta=<d>", default = "", help = ""),
      e: opt("--echo=<e>", default = "", help = ""),
      f: args("<file>", default = @["x"], help = ""),
    )
    let s = newSpec(spec,
      usage = "[--alpha=<a>] [--bravo=<b>] [--charlie=<c>] [--delta=<d>] [--echo=<e>] <file>...")
    let lines = s.usage.formatUsage("prog").splitLines
    let indent = ' '.repeat("  prog ".len)
    check lines.len > 2
    check lines[1].len <= 80
    check lines[1].startsWith("  prog ")
    check lines[2].startsWith(indent)
    check not lines[2].startsWith(indent & " ")
    check lines[2].strip.len > 0

  test "help text for a single arg wraps at the configured width with a hanging indent":
    let longHelp = "How fast the ship should move across the open water, measured in knots"
    let spec = (speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help())
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog", settings = newSpecSettings(width = 80))
    except HelpError as e:
      helpText = e.msg
    let optionsLines = helpText.splitLines.filterIt(it.startsWith("  --speed") or it.startsWith("                   "))
    check optionsLines.len > 1
    for line in optionsLines:
      check line.len <= 80
    check optionsLines[1].startsWith("                   ")

  test "help text shows [default: X] for arg()/opt() but not flag()":
    let spec = (
      speed: opt("--speed=<speed>", default = 10, help = "Speed in knots"),
      x: arg("<x>", default = 0, help = "x grid reference"),
      name: arg("<name>", help = "who to greet"),
      files: args("<file>", default = @["a.txt", "b.txt"], help = "Files"),
      verbose: flag("--verbose", help = "Verbose output"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(usage = "<x> <name> <file>...\n[--speed=<speed>] [--verbose]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Speed in knots [default: 10]" in helpText
    check "Files [default: a.txt, b.txt]" in helpText
    check "who to greet" in helpText
    check "who to greet [default" notin helpText
    check "Verbose output [default" notin helpText

  test "help text suppresses [default: X] when the default is T's zero value":
    let spec = (
      x: arg("<x>", default = 0, help = "x grid reference"),
      speed: opt("--speed=<speed>", default = 0, help = "Speed in knots"),
      verbose: flag[int]("--verbose", default = 0, help = "Verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(usage = "<x> [--speed=<speed>] [--verbose]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "x grid reference [default" notin helpText
    check "Speed in knots [default" notin helpText
    check "Verbosity [default" notin helpText

  test "help text shows [default: X] alone when help is empty":
    let spec = (speed: opt("--speed=<speed>", default = 5, help = ""), help: help())
    var helpText = ""
    try:
      spec.parse(usage = "[--speed=<speed>]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "  --speed=<speed>  [default: 5]" in helpText

  test "help text shows a choice validator's help alongside its default in one bracket":
    let spec = (
      action: arg("<action>", default = "foo", help = "Action to perform",
        validator = choice(["foo", "bar", "baz"])),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(usage = "<action>\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Action to perform [choices: foo, bar, baz; default: foo]" in helpText

  test "help text shows a range validator's help without a default when default is the zero value":
    let spec = (
      speed: opt("--speed=<speed>", default = 0, help = "Speed", validator = range(1..100)),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(usage = "[--speed=<speed>]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Speed [range: 1..100]" in helpText
    check "default" notin helpText

  test "help text shows a check validator's description alone, with no label":
    let spec = (
      amount: opt("--amount=<amount>", default = 0,
        validator = checkIt[int](it mod 2 == 0, "must be even"), help = ""),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(usage = "[--amount=<amount>]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "  --amount=<amount>  [must be even]" in helpText

  test "an explicit width overrides terminal detection":
    let longHelp = "How fast the ship should move across the open water, measured in knots"
    let wide = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()), settings = newSpecSettings(width = 80))
    let narrow = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()), settings = newSpecSettings(width = 40))
    check wide.settings.width == 80
    check narrow.settings.width == 40

    var wideText, narrowText = ""
    try: wide.parse(@["--help"], "prog")
    except HelpError as e: wideText = e.msg
    try: narrow.parse(@["--help"], "prog")
    except HelpError as e: narrowText = e.msg

    check wideText.splitLines.allIt(it.len <= 80)
    check narrowText.splitLines.allIt(it.len <= 40)
    check narrowText.splitLines.len > wideText.splitLines.len

  test "width defaults to the detected terminal width, via the COLUMNS env var":
    putEnv("COLUMNS", "100")
    defer: delEnv("COLUMNS")
    let spec = newSpec((speed: opt("--speed=<speed>", default = 1, help = ""), help: help()))
    check spec.settings.width == 100

  test "width defaults to terminalWidth() when COLUMNS isn't set":
    delEnv("COLUMNS")
    let spec = newSpec((speed: opt("--speed=<speed>", default = 1, help = ""), help: help()))
    check spec.settings.width == terminalWidth()

  test "width cascades from the root spec into nested subcommand specs":
    let move = (name: arg("<name>", help = ""), help: help())
    let ship = (move: command("move", move, help = "Move a ship"), help: help())
    let s = newSpec((ship: command("ship", ship, help = "Ship commands"), help: help()), settings = newSpecSettings(width = 40))
    check s.settings.width == 40
    check s.commands["ship"].spec.settings.width == 40
    check s.commands["ship"].spec.commands["move"].spec.settings.width == 40

suite "autoFillUsage":
  test "MessageArgs are filled in individually; a single unreachable command needs no parens":
    let spec = (
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      mine: command("mine", (y: arg("<y>", help = "")), help = "Mine"),
      help: help(),
      version: version("1.0.0"),
    )
    let s = newSpec(spec, usage = "ship")
    check "mine" in s.usage
    check "-h" in s.usage
    check "-v" in s.usage

  test "multiple unreachable commands are consolidated into one alternation line, not one per command":
    let spec = (
      verbose: flag("--verbose", help = ""),
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      mine: command("mine", (y: arg("<y>", help = "")), help = "Mine"),
    )
    let s = newSpec(spec)
    check s.usage == "[options] (ship | mine)"

  test "positional args are only filled in when none of them are reachable":
    let spec = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
    )
    let s = newSpec(spec, usage = "")
    check "<a>" in s.usage and "<b>" in s.usage

    let spec2 = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
    )
    let s2 = newSpec(spec2, usage = "<a>")
    check s2.usage == "<a>"

  test "a spec auto-filled from a fully empty usage string actually parses, not just displays correctly":
    let spec = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
    )
    let s = newSpec(spec, usage = "")
    s.parse(@["x", "y"], "prog")
    check spec.a == "x"
    check spec.b == "y"

    let spec2 = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
    )
    let s2 = newSpec(spec2, usage = "")
    expect ParseError:
      s2.parse(@[], "prog")

  test "a standalone [options] line is added when nothing else needs appending":
    let spec = (
      verbose: flag("--verbose", default = false, help = ""),
    )
    let s = newSpec(spec, usage = "")
    check s.usage == "[options]"

  test "an appended command line is prefixed with [options] when needed":
    let spec = (
      verbose: flag("--verbose", default = false, help = ""),
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
    )
    let s = newSpec(spec, usage = "")
    check s.usage == "[options] ship"

suite "FSM choice deduplication":
  test "an auto-filled (-h | --help) line collapses to a single edge, both spellings still parse":
    let spec = (name: arg("<name>", help = ""), help: help())
    let s = newSpec(spec, usage = "<name>")
    check s.dot.count("Opt(-h)") == 1
    expect HelpError:
      s.parse(@["-h"], "prog")
    expect HelpError:
      s.parse(@["--help"], "prog")

  test "an explicitly-authored duplicate choice collapses the same way":
    let spec = (x: flag("-x, --xxx", help = ""), help: help())
    let s = newSpec(spec, usage = "(-x | --xxx)\n--help")
    check s.dot.count("Opt(-x)") == 1
    s.parse(@["-x"], "prog")
    check spec.x == true

    let spec2 = (x: flag("-x, --xxx", help = ""), help: help())
    let s2 = newSpec(spec2, usage = "(-x | --xxx)\n--help")
    s2.parse(@["--xxx"], "prog")
    check spec2.x == true

  test "a choice between distinct Args is not affected":
    let spec = (
      ship: command("ship", (v: flag("--verbose", help = "")), help = "Ship"),
      mine: command("mine", (v: flag("--verbose", help = "")), help = "Mine"),
      help: help(),
    )
    let s = newSpec(spec, usage = "(ship | mine)\n--help")
    check s.dot.count("Cmd(ship)") == 1
    check s.dot.count("Cmd(mine)") == 1
    s.parse(@["ship"], "prog")

    let spec2 = (
      ship: command("ship", (v: flag("--verbose", help = "")), help = "Ship"),
      mine: command("mine", (v: flag("--verbose", help = "")), help = "Mine"),
      help: help(),
    )
    let s2 = newSpec(spec2, usage = "(ship | mine)\n--help")
    s2.parse(@["mine"], "prog")

  test "three or more alternatives referencing the same Arg collapse to one edge":
    let spec = (v: flag("-a, -b, -c", help = ""), help: help())
    let s = newSpec(spec, usage = "(-a | -b | -c)\n--help")
    check s.dot.count("Opt(-a)") == 1

suite "FSM shortcut cycles":
  # A bracketed-and-repeated atom compiles to its own self-contained
  # 2-state mutual-shortcut pair. Two adjacent such atoms in one usage line
  # used to hang FSM construction (newSpec/prepare/simplify) forever --
  # entirely at spec-compile time, unrelated to env vars, `.parse()`, or CLI
  # args -- see docs/gotchas.md and GitHub issue #4.
  test "two adjacent optional-and-repeated atoms in one usage line don't hang FSM construction":
    let spec = (
      a: opts[string]("--av=<a>", help = ""),
      b: opts[string]("--bv=<b>", help = ""),
    )
    discard newSpec(spec, usage = "[--av=<a>]... [--bv=<b>]...")

  test "the first atom doesn't need its own repeat for the hang to occur":
    let spec = (
      a: opt[string]("--av=<a>", default = "", help = ""),
      b: opts[string]("--bv=<b>", help = ""),
    )
    discard newSpec(spec, usage = "[--av=<a>] [--bv=<b>]...")

  test "three or more adjacent optional-and-repeated atoms don't hang":
    let spec = (
      a: opts[string]("--av=<a>", help = ""),
      b: opts[string]("--bv=<b>", help = ""),
      c: opts[string]("--cv=<c>", help = ""),
    )
    discard newSpec(spec, usage = "[--av=<a>]... [--bv=<b>]... [--cv=<c>]...")

  test "two independently-repeatable env-configured options in one usage line resolve correctly, not just avoid hanging":
    putEnv("ARGUMINT_TEST_SHORTCUT_A", "foo:bar")
    defer: delEnv("ARGUMINT_TEST_SHORTCUT_A")
    putEnv("ARGUMINT_TEST_SHORTCUT_B", "baz:qux")
    defer: delEnv("ARGUMINT_TEST_SHORTCUT_B")
    let spec = (
      a: opts[string]("--av=<a>", env = "ARGUMINT_TEST_SHORTCUT_A", help = ""),
      b: opts[string]("--bv=<b>", env = "ARGUMINT_TEST_SHORTCUT_B", help = ""),
    )
    spec.parse(usage = "[--av=<a>]... [--bv=<b>]...", args = @[], command = "prog")
    check spec.a == @["foo", "bar"]
    check spec.b == @["baz", "qux"]

suite "Environment variables":
  test "opt: env var set, no CLI value, is used and converted like a CLI value":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", args = @[], command = "prog")
    check spec.port == 9090

  test "opt: an explicit CLI value overrides the env var":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", args = @["--port=1234"], command = "prog")
    check spec.port == 1234

  test "opt: an env value still goes through the option's validator":
    putEnv("ARGUMINT_TEST_PORT", "99999")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT",
        validator = range(1..65535), help = ""),
    )
    expect ValidationError:
      spec.parse(usage = "[--port=<port>]", args = @[], command = "prog")

  test "opt: neither CLI nor env set falls back to the coded default":
    delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", args = @[], command = "prog")
    check spec.port == 8080

  test "flag: env value names a variant, applied via that variant's own op; CLI flag overrides":
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbose")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 1 # blank-op variant's own increment-by-1, not an arbitrary env value

    let spec2 = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    spec2.parse(usage = "[--verbose]...", args = @["--verbose"], command = "prog")
    check spec2.verbosity == 1 # CLI's own increment op wins; env is skipped entirely

  test "flag: an env value naming no declared variant raises ParseError":
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbse") # typo
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    expect ParseError:
      spec.parse(usage = "[--verbose]...", args = @[], command = "prog")

  test "flag: repeatable position consumes multiple env-named variants, composing via each one's own op":
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbose:--verbose:--verbose")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 3

  test "flag: env now works for a type with no = support, applying its own declared op":
    # Speed's handler only supports `+=` (see its `defineArg` above) -- this
    # used to be impossible via env at all, since env used to force a `=`
    # conversion. Now env just names the variant's bare flag spelling
    # (`self.ops`' key), not the full "--speed+=slow" declaration text.
    putEnv("ARGUMINT_TEST_SPEED", "--speed")
    defer: delEnv("ARGUMINT_TEST_SPEED")
    let spec = (
      speed: flag[Speed]("--speed+=slow", default = slow, env = "ARGUMINT_TEST_SPEED", help = ""),
    )
    spec.parse(usage = "[--speed]", args = @[], command = "prog")
    check spec.speed == medium2

  test "a required option's env var satisfies the requirement":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "--port=<port>", args = @[], command = "prog")
    check spec.port == 9090

  test "a required flag's env var satisfies the requirement":
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbose")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    spec.parse(usage = "--verbose", args = @[], command = "prog")
    check spec.verbosity == 1

  test "an explicit CLI value overrides the env var for a required option too":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "--port=<port>", args = @["--port=1234"], command = "prog")
    check spec.port == 1234

  test "an option required twice needs two env values, and errors if given only one":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    expect ParseError:
      spec.parse(usage = "--port=<port> --port=<port>", args = @[], command = "prog")

  test "an option required twice has both occurrences satisfied by two delimited env values":
    putEnv("ARGUMINT_TEST_PORT", "9090:9091")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "--port=<port> --port=<port>", args = @[], command = "prog")
    check spec.port == 9091 # scalar Match Accumulation: last value wins

  test "an option required twice errors when given one more env value than it has slots for":
    putEnv("ARGUMINT_TEST_PORT", "9090:9091:9092")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    expect ParseError:
      spec.parse(usage = "--port=<port> --port=<port>", args = @[], command = "prog")

  test "an env-configured option reachable only via a repeatable [options] doesn't hang":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "[options]", args = @[], command = "prog")
    check spec.port == 9090

  test "opts: env var supplies multiple values via the delimiter":
    putEnv("ARGUMINT_TEST_TAGS", "foo:bar:baz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts[string]("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "empty segments from a doubled delimiter are kept as literal values, not dropped":
    putEnv("ARGUMINT_TEST_TAGS", "foo::bar")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts[string]("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "", "bar"]

  test "\\x1e takes priority over the configured delimiter":
    putEnv("ARGUMINT_TEST_TAGS", "foo:bar\x1ebaz:qux")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts[string]("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo:bar", "baz:qux"]

  test "a custom envDelim splits on something other than colon":
    putEnv("ARGUMINT_TEST_TAGS", "foo,bar,baz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts[string]("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", settings = newSpecSettings(envDelim = ","), args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "a per-arg env(name, delim) override splits on something other than the spec's envDelim":
    putEnv("ARGUMINT_TEST_TAGS", "foo;bar;baz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts[string]("--tag=<tag>", env = env("ARGUMINT_TEST_TAGS", ";"), help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "a per-arg delim override applies only to that arg, not the whole spec":
    putEnv("ARGUMINT_TEST_A", "foo;bar")
    defer: delEnv("ARGUMINT_TEST_A")
    putEnv("ARGUMINT_TEST_B", "foo:bar")
    defer: delEnv("ARGUMINT_TEST_B")
    let spec = (
      a: opts[string]("--av=<a>", env = env("ARGUMINT_TEST_A", ";"), help = ""),
      b: opts[string]("--bv=<b>", env = "ARGUMINT_TEST_B", help = ""),
    )
    spec.parse(usage = "[--av=<a>]... [--bv=<b>]...", args = @[], command = "prog")
    check spec.a == @["foo", "bar"]
    check spec.b == @["foo", "bar"]

  test "\\x1e still takes priority over a non-empty per-arg delim override":
    putEnv("ARGUMINT_TEST_TAGS", "foo;bar\x1ebaz;qux")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts[string]("--tag=<tag>", env = env("ARGUMINT_TEST_TAGS", ";"), help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo;bar", "baz;qux"]

  test "an empty per-arg delim override disables splitting entirely, even over \\x1e":
    putEnv("ARGUMINT_TEST_TOKEN", "a:b\x1ec")
    defer: delEnv("ARGUMINT_TEST_TOKEN")
    let spec = (
      token: opt[string]("--token=<token>", env = env("ARGUMINT_TEST_TOKEN", ""), help = ""),
    )
    spec.parse(usage = "[--token=<token>]", args = @[], command = "prog")
    check spec.token == "a:b\x1ec"

  test "flag: a per-arg delim override applies to how env-named variants are split":
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbose;--verbose")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = env("ARGUMINT_TEST_VERBOSE", ";"), help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 2

  test "an Arg whose position is never reached this walk still gets every available env value applied":
    putEnv("ARGUMINT_TEST_PORT", "1234:5678")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    spec.parse(usage = "<a>\n[options] <b>", args = @["foo"], command = "prog")
    check spec.port == 5678 # neither line 2 nor [options] was ever walked; every value still applies

  test "a top-level env-configured option's env var still applies when a nested command is also invoked":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let move = (name: arg("<name>", help = ""))
    let spec = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
      ship: command("ship", move, usage = "<name>", help = ""),
    )
    spec.parse(usage = "[--port=<port>] ship", args = @["ship", "Titanic"], command = "prog")
    check spec.port == 9090
    check move.name == "Titanic"

  test "the same Arg reachable at both an ancestor and a nested command's grammar isn't double-applied from its env var":
    putEnv("ARGUMINT_TEST_TAGS", "foo")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let tag = opts[string]("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = "")
    let ship = (tag: tag)
    let spec = (
      tag: tag,
      ship: command("ship", ship, usage = "[--tag=<tag>]", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>] ship", args = @["ship"], command = "prog")
    check tag == @["foo"]

  test "an env-fallback error deeper in the tree prevents every hook from firing, even an already-would-be-entered ancestor's":
    # Contrast with "an ancestor's after still runs when a nested command's
    # own before raises" (suite "Commands" above): that failure happens
    # *inside* dispatch's own try/finally chain, after `outer`'s before
    # already ran, so outer's after still fires for cleanup. An
    # env-fallback error is resolved in a separate pass that completes (or
    # raises) entirely before dispatch is ever called, so no level's
    # before runs at all here -- and per the "a level whose own before
    # raises never runs its own after" rule, that means no level's after
    # runs either, including outer's.
    putEnv("ARGUMINT_TEST_PORT", "9090:9091:9092") # one more value than the two slots below need
    defer: delEnv("ARGUMINT_TEST_PORT")
    var log: seq[string]
    proc outerBefore(spec: tuple) = log.add "outer-before"
    proc outerAfter(spec: tuple) = log.add "outer-after"

    let inner = (
      port: opt("--port=<port>", default = 0, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    let outer = (
      move: command("move", inner, usage = "--port=<port> --port=<port>", help = ""),
    )
    let spec = (
      ship: command("ship", outer, before = outerBefore, after = outerAfter, help = ""),
    )
    expect ParseError:
      spec.parse(usage = "ship", args = @["ship", "move"], command = "prog")
    check log.len == 0

  test "[env: X] appears in help text for opt and flag, combined with other annotations":
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = "Port"),
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = "Verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Port [default: 8080; env: ARGUMINT_TEST_PORT]" in helpText
    check "Verbosity [env: ARGUMINT_TEST_VERBOSE]" in helpText

suite "Config Source":
  test "opt: config value set, no CLI/env value, is used and converted like a CLI value":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090"]))])
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "opt: an explicit CLI value overrides the config value":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090"]))])
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @["--port=1234"], command = "prog")
    check spec.port == 1234

  test "opt: an env value overrides the config value":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["7070"]))])
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "opt: a config value still goes through the option's validator":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["99999"]))])
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = "port", validator = range(1..65535), help = ""),
    )
    expect ValidationError:
      spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")

  test "opt: neither CLI, env, nor config set falls back to the coded default":
    let settings = newSpecSettings(configSources = @[fakeSource()])
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 8080

  test "flag: config value names a variant, applied via that variant's own op; CLI flag overrides":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("verbose"), @["--verbose"]))])
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, configKey = "verbose", help = ""),
    )
    spec.parse(usage = "[--verbose]...", settings = settings, args = @[], command = "prog")
    check spec.verbosity == 1

    let spec2 = (
      verbosity: flag[int]("--verbose", default = 0, configKey = "verbose", help = ""),
    )
    spec2.parse(usage = "[--verbose]...", settings = settings, args = @["--verbose"], command = "prog")
    check spec2.verbosity == 1 # CLI's own increment op wins; config is skipped entirely

  test "flag: a config value naming no declared variant raises ParseError":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("verbose"), @["--verbse"]))]) # typo
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, configKey = "verbose", help = ""),
    )
    expect ParseError:
      spec.parse(usage = "[--verbose]...", settings = settings, args = @[], command = "prog")

  test "flag: repeatable position consumes multiple config-named variants, composing via each one's own op":
    let settings = newSpecSettings(configSources = @[
      fakeSource((configKey("verbose"), @["--verbose", "--verbose", "--verbose"]))
    ])
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, configKey = "verbose", help = ""),
    )
    spec.parse(usage = "[--verbose]...", settings = settings, args = @[], command = "prog")
    check spec.verbosity == 3

  test "a required option's config value satisfies the requirement":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090"]))])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "--port=<port>", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "a required flag's config value satisfies the requirement":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("verbose"), @["--verbose"]))])
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, configKey = "verbose", help = ""),
    )
    spec.parse(usage = "--verbose", settings = settings, args = @[], command = "prog")
    check spec.verbosity == 1

  test "an option required twice needs two config values, and errors if given only one":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090"]))])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    expect ParseError:
      spec.parse(usage = "--port=<port> --port=<port>", settings = settings, args = @[], command = "prog")

  test "an option required twice has both occurrences satisfied by config's own multi-value seq":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090", "9091"]))])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "--port=<port> --port=<port>", settings = settings, args = @[], command = "prog")
    check spec.port == 9091 # scalar Match Accumulation: last value wins

  test "an option required twice errors when given one more config value than it has slots for":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090", "9091", "9092"]))])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    expect ParseError:
      spec.parse(usage = "--port=<port> --port=<port>", settings = settings, args = @[], command = "prog")

  test "a config-configured option reachable only via a repeatable [options] doesn't hang":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090"]))])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "[options]", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "a Config Source probed-and-missed during the walk (via [options]) is queried at most once":
    # Regression test: `[options]`'s catch-all exploratory-probes every
    # declared option, including ones with no matching CLI token -- this
    # used to cause `applyTier`'s post-walk sweep to call `resolve` a
    # second time for an Arg that was already tried-and-missed during the
    # walk (ValueCursor.tried was set, but applyTier only checked
    # cursor.consumed, which a miss never populates). Fixed by also
    # checking `cursor.tried` before resolving again -- see
    # docs/adr/0018-config-source.md.
    let source = FakeConfigSource(data: @[]) # never has anything -- every lookup is a miss
    let settings = newSpecSettings(configSources = @[ConfigSource source])
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, help = ""),
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "[options]", settings = settings, args = @["--verbose"], command = "prog")
    check spec.port == 0
    check source.lookups <= 1

  test "opts: config supplies multiple values natively, no delimiter splitting involved":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("tags"), @["foo", "bar", "baz"]))])
    let spec = (
      tags: opts[string]("--tag=<tag>", configKey = "tags", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", settings = settings, args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "an Arg whose position is never reached this walk still gets every available config value applied":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["1234", "5678"]))])
    let spec = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "<a>\n[options] <b>", settings = settings, args = @["foo"], command = "prog")
    check spec.port == 5678 # neither line 2 nor [options] was ever walked; every value still applies

  test "a top-level config-configured option's value still applies when a nested command is also invoked":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["9090"]))])
    let move = (name: arg("<name>", help = ""))
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
      ship: command("ship", move, usage = "<name>", help = ""),
    )
    spec.parse(usage = "[--port=<port>] ship", settings = settings, args = @["ship", "Titanic"], command = "prog")
    check spec.port == 9090
    check move.name == "Titanic"

  test "the same Arg reachable at both an ancestor and a nested command's grammar isn't double-applied from its config value":
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("tags"), @["foo"]))])
    let tag = opts[string]("--tag=<tag>", configKey = "tags", help = "")
    let ship = (tag: tag)
    let spec = (
      tag: tag,
      ship: command("ship", ship, usage = "[--tag=<tag>]", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>] ship", settings = settings, args = @["ship"], command = "prog")
    check tag == @["foo"]

  test "layering: a later Config Source's hit fully replaces an earlier one's, never merges (scalar)":
    let settings = newSpecSettings(configSources = @[
      fakeSource((configKey("port"), @["9090"])),
      fakeSource((configKey("port"), @["7070"])),
    ])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 7070

  test "layering: a later Config Source's hit fully replaces an earlier one's, never merges (multi-value)":
    let settings = newSpecSettings(configSources = @[
      fakeSource((configKey("tags"), @["a", "b"])),
      fakeSource((configKey("tags"), @["c"])),
    ])
    let spec = (
      tags: opts[string]("--tag=<tag>", configKey = "tags", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", settings = settings, args = @[], command = "prog")
    check spec.tags == @["c"]

  test "layering: a later source without the key doesn't hide an earlier hit":
    let settings = newSpecSettings(configSources = @[
      fakeSource((configKey("port"), @["9090"])),
      fakeSource(),
    ])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "a before hook mutating configSources has no effect on the current parse, same carve-out as envDelim":
    # applyFallbacks (where Config Source values actually get applied) runs
    # to completion, for every level in the tree, entirely before dispatch
    # -- and thus before any before/action/after hook -- ever fires (see
    # fsm.parse*). A before hook mutating settings.configSources is
    # therefore always too late to affect the parse already in progress,
    # exactly the same carve-out Spec.settings.envDelim already has
    # (architecture.md's "Env var mechanics"). The mutation *is* visible to
    # a later, separate parse() call reusing the same held SpecSettings.
    let settings = newSpecSettings()
    proc addLocalSource(spec: tuple) =
      settings.configSources.add fakeSource((configKey("port"), @["9090"]))

    let inner = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    let spec = (
      ship: command("ship", inner, before = addLocalSource, help = ""),
    )
    spec.parse(usage = "ship", settings = settings, args = @["ship"], command = "prog")
    check inner.port == 0 # too late for this parse -- addLocalSource's mutation lands after applyFallbacks already ran

    let inner2 = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    let spec2 = (
      ship: command("ship", inner2, help = ""),
    )
    spec2.parse(usage = "ship", settings = settings, args = @["ship"], command = "prog")
    check inner2.port == 9090 # a later parse() call does see it -- same held SpecSettings ref

  test "[configKey: X] appears in help text for opt and flag, combined with other annotations":
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = configKey("server", "port"), help = "Port"),
      verbosity: flag[int]("--verbose", default = 0, configKey = "verbose", help = "Verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Port [default: 8080; configKey: server.port]" in helpText
    check "Verbosity [configKey: verbose]" in helpText

  test "end-to-end: iniConfigSource supplies a value from a real INI file":
    let path = getTempDir() / "argumint_test_config.ini"
    writeFile(path, "[server]\nport=9090\n")
    defer: removeFile(path)
    let settings = newSpecSettings(configSources = @[iniConfigSource(path)])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = configKey("server", "port"), help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "end-to-end: jsonConfigSource supplies multiple values from a real JSON file":
    let path = getTempDir() / "argumint_test_config.json"
    writeFile(path, """{"tags": ["foo", "bar", "baz"]}""")
    defer: removeFile(path)
    let settings = newSpecSettings(configSources = @[jsonConfigSource(path)])
    let spec = (
      tags: opts[string]("--tag=<tag>", configKey = "tags", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", settings = settings, args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "exploratory: a mixed CLI+config-satisfied repeated position silently drops the config contribution":
    # Documents current, pre-existing (not introduced by Config Source --
    # already true of CLI-vs-env mixing) behavior rather than promising a
    # contract: `applyFallbacks`'s post-walk sweep skips an Arg entirely
    # once it has *any* real CLI match (`arg in matches`), even though the
    # walk itself already let a Config Source value stand in for a
    # *different* occurrence of the same repeated position (via `probe`,
    # which succeeds without recording a `pc.matches` entry). The grammar
    # is satisfied (the walk reaches a terminal state), but the
    # config-supplied occurrence's value is silently never applied -- no
    # error, no second value. If this changes in the future, this test
    # should be updated to match, not deleted.
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["2222", "3333"]))])
    let spec = (
      port: opt("--port=<port>", default = 0, configKey = "port", help = ""),
    )
    spec.parse(usage = "--port=<port> --port=<port>", settings = settings, args = @["--port=1111"], command = "prog")
    check spec.port == 1111 # not 3333 -- the config-satisfied second position never actually applied
