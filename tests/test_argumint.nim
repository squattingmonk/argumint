import std/[importutils, json, options, os, pegs, sequtils, strutils, tables, terminal, unittest]

import argumint
import argumint/argtypes
import argumint/backend
import argumint/precedence
import argumint/specbuild
import argumint/configsource/ini
import argumint/configsource/json
import argumint/display

privateAccess(ValueArgBase)      ## White-box assertions on the arg
privateAccess(ValueArg[string])  ## types exported by issue #27 -- type
privateAccess(ValuesArg[string]) ## public, state private.
privateAccess(FlagArg[bool])

template restoringEnv(keys: openArray[string], body: untyped) =
  ## Runs `body`, then puts each of `keys` back as it was, set or not.
  let saved = @keys.mapIt((it, existsEnv(it), getEnv(it)))
  try: body
  finally:
    for (key, existed, value) in saved:
      if existed: putEnv(key, value) else: delEnv(key)

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
    lookups: int
      ## Counts `lookup` calls -- see the "queried at most once" regression
      ## test.

method lookup(self: FakeConfigSource, key: ConfigKey): Option[seq[string]] =
  self.lookups.inc
  for (k, v) in self.data:
    if k == key:
      return some(v)
  none(seq[string])

proc fakeSource(pairs: varargs[(ConfigKey, seq[string])]): ConfigSource =
  FakeConfigSource(data: @pairs)

# One fixture for both fallback tiers, so a shared behaviour is written once
# and run for each -- see the "Fallback tiers" suite.
const FallbackVar = "ARGUMINT_TEST_FALLBACK"
const FallbackDelim = ","
  ## No fixture value contains it.

proc tierName(t: FallbackTier): string =
  case t
  of ftEnv: "env"
  of ftConfig: "config"

proc envFor(t: FallbackTier): Option[EnvSource] =
  ## `t`'s source for an Arg under test; the other tier gets none.
  if t == ftEnv: env(FallbackVar, FallbackDelim) else: none(EnvSource)

proc keyFor(t: FallbackTier): ConfigKey =
  ## `t`'s Config Key for an Arg under test; the other tier gets none.
  if t == ftConfig: configKey("fallback") else: noConfigKey()

proc supply(t: FallbackTier, values: varargs[string]): SpecSettings =
  ## Settings under which `t` supplies `values`, in order. Joined on
  ## `FallbackDelim`, so the env tier's split doesn't depend on `envDelim`.
  ## Pair with `defer: clearFallback()`.
  case t
  of ftEnv:
    putEnv(FallbackVar, @values.join(FallbackDelim))
    newSpecSettings(style = nil)
  of ftConfig:
    newSpecSettings(style = nil, configSources = @[fakeSource((configKey("fallback"), @values))])

proc supplyNothing(t: FallbackTier): SpecSettings =
  ## Settings under which `t` is configured but has no value: the variable
  ## unset, or a Config Source without the key.
  case t
  of ftEnv:
    delEnv(FallbackVar)
    newSpecSettings(style = nil)
  of ftConfig:
    newSpecSettings(style = nil, configSources = @[fakeSource()])

proc clearFallback() = delEnv(FallbackVar)

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
      files: args("<file>", help = ""),
    )
    spec.parse(usage = "<file>...", args = @["a", "b", "c", "d"], command = "prog")
    check spec.files == @["a", "b", "c", "d"]

  test "args[T] with no default given defaults to empty":
    let spec = (
      files: args("<file>", help = ""),
    )
    spec.parse(usage = "[<file>...]", args = @[], command = "prog")
    check spec.files == newSeq[string]()

  test "args() with a non-empty default infers T without a bracket":
    let spec = (
      files: args("<file>", default = @["a", "b"], help = ""),
    )
    spec.parse(usage = "[<file>...]", args = @[], command = "prog")
    check spec.files == @["a", "b"]

  test "arg() with no T and no default falls back to the bare-call string shorthand":
    let spec = (
      name: arg("<name>", help = ""),
    )
    spec.parse(usage = "[<name>]", args = @[], command = "prog")
    check spec.name == ""

  test "arg[T] with an explicit T and no default falls back to default(T)":
    let spec = (
      count: arg[int]("<n>", help = ""),
    )
    spec.parse(usage = "[<n>]", args = @[], command = "prog")
    check spec.count == 0

  test "args() with no T and no default falls back to the bare-call string shorthand":
    let spec = (
      files: args("<file>", help = ""),
    )
    spec.parse(usage = "[<file>...]", args = @[], command = "prog")
    check spec.files == newSeq[string]()

suite "All-caps NAME variants":
  # The variant PEG's own complaint, not a later one from the usage lexer.
  proc invalidVariant(spec: tuple): bool =
    try:
      spec.parse(args = @[], command = "prog")
    except SpecDefect as e:
      result = "arg variant" in e.msg

  test "a NAME positional and an =NAME placeholder parse like <name> ones":
    let spec = (
      keys: args("KEY", help = ""),
      values: args("<value>", help = ""),
      output: opt("-o, --output=FILE", default = "", help = ""),
      n: arg("N", help = ""),
    )
    spec.parse(usage = "[options] N (KEY <value>)...",
      args = @["3", "k1", "v1", "k2", "v2", "--output=out.txt"], command = "prog")
    check spec.n == "3"
    check spec.keys == @["k1", "k2"]
    check spec.values == @["v1", "v2"]
    check spec.output == "out.txt"

  test "a short option with a NAME placeholder takes a separate value":
    let spec = (output: opt("-o, --output=FILE", default = "", help = ""),)
    spec.parse(args = @["-o", "x"], command = "prog")
    check spec.output == "x"

  test "an auto-filled usage names NAME positionals":
    let spec = (
      src: args("SRC", help = ""),
      dest: arg("DEST", help = ""),
      output: opt("--output=FILE", default = "", help = ""),
    )
    spec.parse(args = @["a", "b", "c", "--output=f"], command = "prog")
    check spec.src == @["a", "b"]
    check spec.dest == "c"
    check spec.output == "f"

  test "help lists NAME positionals and placeholders":
    let spec = (
      key: arg("KEY", help = "A key"),
      output: opt("-o, --output=FILE", default = "", help = "Where to write"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog",
        settings = newSpecSettings(style = nil))
    except HelpError as e:
      helpText = e.msg
    check "prog [options] KEY" in helpText
    let rows = helpText.splitLines.mapIt(it.splitWhitespace.join(" "))
    check "KEY A key" in rows
    check "-o, --output=FILE Where to write" in rows

  test "a NAME placeholder is a metavar":
    check opt("--output=FILE", default = "").metavars == @["FILE"]

  test "a NAME can join its parts with _ or -, but not end with one":
    let spec = (
      src: arg("SRC_DIR", help = ""),
      output: opt("--out=OUT-FILE", default = "", help = ""),
    )
    spec.parse(args = @["a", "--out=b"], command = "prog")
    check spec.src == "a"
    check spec.output == "b"
    check invalidVariant((k: arg("KEY-", help = "")))
    check invalidVariant((o: opt("--out=FILE_", default = "", help = "")))

  test "a lowercase or mixed-case bare name is still a SpecDefect":
    for variant in ["key", "Key", "kEY"]:
      check invalidVariant((k: arg(variant, help = "")))
    for variant in ["--output=file", "--output=File"]:
      check invalidVariant((o: opt(variant, default = "", help = "")))

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

  test "raise ValidationError for a value outside the validator's choice set":
    let spec = (
      color: opt("--color=<color>", default = "red", validator = choice(["red", "green", "blue"]), help = ""),
    )
    expect ValidationError:
      spec.parse(usage = "[--color=<color>]", args = @["--color=purple"], command = "prog")

  test "all() rejects a value failing either composed validator, end-to-end through parse()":
    let spec = (
      num: opt("--num=<num>", default = 0, validator = all(range(0..10), checkIt[int](it mod 2 == 0, "must be even")), help = ""),
    )
    var caught = ""
    try:
      spec.parse(usage = "[--num=<num>]", args = @["--num=7"], command = "prog")
    except ValidationError as e:
      caught = e.msg
    check "must be even" in caught

  test "unique() end-to-end rejects a value repeated across two matches of the same multi-value option":
    let spec = (
      tags: opts("--tag=<tag>", validator = unique[string](), help = ""),
    )
    expect ValidationError:
      spec.parse(usage = "[--tag=<tag>]...", args = @["--tag=a", "--tag=a"], command = "prog")

  test "opts[T] with no default given defaults to empty":
    let spec = (
      tags: opts("--tag=<tag>", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == newSeq[string]()

  test "opts() with a non-empty default infers T without a bracket":
    let spec = (
      tags: opts("--tag=<tag>", default = @["a", "b"], help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["a", "b"]

  test "opt() with no T and no default falls back to the bare-call string shorthand":
    let spec = (
      name: opt("--name=<name>", help = ""),
    )
    spec.parse(usage = "[--name=<name>]", args = @[], command = "prog")
    check spec.name == ""

  test "opt[T] with an explicit T and no default falls back to default(T)":
    let spec = (
      speed: opt[float]("--speed=<speed>", help = ""),
    )
    spec.parse(usage = "[--speed=<speed>]", args = @[], command = "prog")
    check spec.speed == 0.0

  test "opts() with no T and no default falls back to the bare-call string shorthand":
    let spec = (
      tags: opts("--tag=<tag>", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == newSeq[string]()

suite "Flags":
  test "a bare flag has no Flag Operation Description to show, on any variant (#154)":
    let f = flag("-v, --verbose")
    check f.variantDesc("-v") == ""
    check f.variantDesc("--verbose") == ""

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

  test "user-defined types work as a flag's explicit Flag Operation value (extensibility regression)":
    let spec = (
      p: flag[Priority](ops = [flagOp("--priority", "=", high)], default = low, help = ""),
    )
    spec.parse(usage = "[--priority]", args = @["--priority"], command = "prog")
    check spec.p == high

  test "a bare name is rejected at construction when T has no blank op (#183)":
    template rejects(body: untyped) =
      var caught = ""
      try: discard body
      except SpecDefect as e: caught = e.msg
      check "--xx" in caught
      check "blank operation" in caught
    rejects flag[float]("--xx")
    rejects flag[string]("--xx")
    rejects flag[char]("--xx")
    rejects flag[float]("--xx", ops = "--up+=1.5")
    rejects flag[Priority]("--xx")
    rejects flag[set[Color]]("--xx")

  test "a bare name still builds when T has a blank op, and ops alone are unaffected (#183)":
    let spec = (
      quiet: flag("--quiet"),
      verbosity: flag[int]("-v, --verbose"),
      speed: flag[float](ops = "--up+=1.5"),
    )
    spec.parse(usage = "[--quiet] [-v]... [--up]", args = @["--quiet", "-v", "-v", "--up"], command = "prog")
    check spec.quiet == true
    check spec.verbosity == 2
    check spec.speed == 1.5

  test "flag[T] with an explicit T and no default falls back to default(T), same as arg/opt/args/opts":
    let spec = (
      verbosity: flag[int]("--verbose", help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 0

  test "flag[T] with no default falls back to default(T) for a custom enum type too":
    let spec = (
      p: flag[Priority](ops = [flagOp("--priority", "=", high)], help = ""),
    )
    spec.parse(usage = "[--priority]", args = @[], command = "prog")
    check spec.p == low

  test "flag[bool](...) explicit bracket form works the same as the bare bool overload":
    let spec = (
      verbose: flag[bool]("--verbose", help = ""),
    )
    spec.parse(usage = "[--verbose]", args = @["--verbose"], command = "prog")
    check spec.verbose == true

  test "flagOp supplies a typed value directly, e.g. a custom enum with no natural string spelling requirement":
    let spec = (
      p: flag[Priority](ops = [flagOp("--priority", "=", high)], default = low, help = ""),
    )
    spec.parse(usage = "[--priority]", args = @["--priority"], command = "prog")
    check spec.p == high

  test "custom flag types get auto-generated =/+=/-= descriptions for free":
    let spec = (
      p: flag[Priority](ops = [flagOp("--priority", "=", high), flagOp("--boost", "=", medium)], default = low, help = "Set priority"),
      help: help(),
    )
    var helpText = ""
    try: spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e: helpText = e.msg
    # --priority and --boost are two independent explicit groups with
    # genuinely divergent auto-generated descriptions.
    check "Set priority" in helpText
    check "Set to medium" in helpText

  test "a custom flag type can supply blank-op wording via defineFlag":
    let spec = (
      lvl: flag[Level]("-b, --bump", ops = [flagOp("--set", "=", loud)], default = quiet, help = "Adjust level"),
      help: help(),
    )
    var helpText = ""
    try: spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e: helpText = e.msg
    # -b/--bump (the implicit blank-op group) is what shows the
    # defineFlag-supplied blankDesc.
    check "Adjust level" in helpText
    check "Bump up one level" in helpText

suite "Set flags":
  test "= sets the value to a singleton set, replacing any existing elements":
    let spec = (colors: flag[set[Color]](ops = [flagOp("--red", "=", {red}), flagOp("--green", "=", {green})], default = {blue}, help = ""))
    spec.parse(args = @["--red"], command = "prog")
    check spec.colors == {red}

  test "+= includes the element without clearing existing ones":
    let spec = (colors: flag[set[Color]](ops = [flagOp("--red", "=", {red}), flagOp("--add-green", "+=", {green})], default = {}, help = ""))
    spec.parse(usage = "[--red] [--add-green]", args = @["--red", "--add-green"], command = "prog")
    check spec.colors == {red, green}

  test "-= excludes the element":
    let spec = (colors: flag[set[Color]](ops = [flagOp("--remove-red", "-=", {red})], default = {red, green}, help = ""))
    spec.parse(args = @["--remove-red"], command = "prog")
    check spec.colors == {green}

  test "*= keeps the element only if already present (intersection)":
    let spec = (colors: flag[set[Color]](ops = [flagOp("--only-red", "*=", {red})], default = {red, green}, help = ""))
    spec.parse(args = @["--only-red"], command = "prog")
    check spec.colors == {red}

  test "*= drops everything when the element isn't present":
    let spec = (colors: flag[set[Color]](ops = [flagOp("--only-blue", "*=", {blue})], default = {red, green}, help = ""))
    spec.parse(args = @["--only-blue"], command = "prog")
    check spec.colors == {}

  test "flagOp supplies a multi-element set directly, including a referenced const":
    let spec = (colors: flag[set[Color]](ops = [flagOp("--warm", "=", warmColors)], default = {}, help = ""))
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
    let spec = (tags: opts("--tag=<tag>", help = ""))
    spec.parse(usage = "[options]...", args = @["--tag=a", "--tag=b"], command = "prog")
    check spec.tags == @["a", "b"]

  test "bare [options] (no ...) still allows a catch-all-only option to be matched more than once":
    let spec = (verbosity: flag[int]("--verbose", default = 0, help = ""))
    spec.parse(usage = "[options]", args = @["--verbose", "--verbose", "--verbose"], command = "prog")
    check spec.verbosity == 3

  test "bare [options] (no ...) lets a catch-all-only multi-value opt accumulate":
    let spec = (tags: opts("--tag=<tag>", help = ""))
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
    proc cmdMove(spec: tuple, info: HookInfo) =
      moved = spec.name

    let move = (name: arg("<name>", help = ""))
    let spec = (
      ship: command("ship", move, action = cmdMove, usage = "<name>", help = ""),
    )
    spec.parse(usage = "ship", args = @["ship", "Titanic"], command = "prog")
    check moved == "Titanic"

  test "before runs root-to-leaf, action fires once at the leaf, after runs leaf-to-root":
    var log: seq[string]
    proc outerBefore(spec: tuple, info: HookInfo) = log.add "outer-before"
    proc outerAfter(spec: tuple, info: HookInfo) = log.add "outer-after"
    proc innerBefore(spec: tuple, info: HookInfo) = log.add "inner-before"
    proc innerAction(spec: tuple, info: HookInfo) = log.add "inner-action"
    proc innerAfter(spec: tuple, info: HookInfo) = log.add "inner-after"

    let inner = (name: arg("<name>", help = ""))
    let outer = (
      move: command("move", inner, before = innerBefore, action = innerAction, after = innerAfter, usage = "<name>", help = ""),
    )
    let spec = (
      ship: command("ship", outer, before = outerBefore, after = outerAfter, help = ""),
    )
    spec.parse(usage = "ship", args = @["ship", "move", "Titanic"], command = "prog")
    check log == @["outer-before", "inner-before", "inner-action", "inner-after", "outer-after"]

  test "before/action/after ordering generalizes past 2 levels of nesting":
    var log: seq[string]
    proc before1(spec: tuple, info: HookInfo) = log.add "before1"
    proc after1(spec: tuple, info: HookInfo) = log.add "after1"
    proc before2(spec: tuple, info: HookInfo) = log.add "before2"
    proc after2(spec: tuple, info: HookInfo) = log.add "after2"
    proc before3(spec: tuple, info: HookInfo) = log.add "before3"
    proc action3(spec: tuple, info: HookInfo) = log.add "action3"
    proc after3(spec: tuple, info: HookInfo) = log.add "after3"

    let leaf = (name: arg("<name>", help = ""))
    let mid = (
      delete: command("delete", leaf, before = before3, action = action3, after = after3, usage = "<name>", help = ""),
    )
    let outer = (
      branch: command("branch", mid, before = before2, after = after2, help = ""),
    )
    let spec = (
      remote: command("remote", outer, before = before1, after = after1, help = ""),
    )
    spec.parse(usage = "remote", args = @["remote", "branch", "delete", "origin"], command = "prog")
    check log == @["before1", "before2", "before3", "action3", "after3", "after2", "after1"]
    check leaf.name == "origin" # confirms 3-level structural resolution, not just hook order

  test "action fires when a command is invoked bare, but not when it routes to a subcommand":
    var shipActionFired = false
    var moveActionFired = false
    proc shipAction(spec: tuple, info: HookInfo) = shipActionFired = true
    proc moveAction(spec: tuple, info: HookInfo) = moveActionFired = true

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
    proc appBefore(spec: tuple, info: HookInfo) = log.add "app-before"
    proc appAction(spec: tuple, info: HookInfo) = log.add "app-action"
    proc appAfter(spec: tuple, info: HookInfo) = log.add "app-after"

    let spec = (name: arg("<name>", help = ""))
    spec.parse(usage = "<name>", args = @["Titanic"], command = "prog",
      before = appBefore, action = appAction, after = appAfter)
    check log == @["app-before", "app-action", "app-after"]

  test "an ancestor's after still runs when a nested command's own before raises":
    var log: seq[string]
    proc outerBefore(spec: tuple, info: HookInfo) = log.add "outer-before"
    proc outerAfter(spec: tuple, info: HookInfo) = log.add "outer-after"
    proc innerBefore(spec: tuple, info: HookInfo) = raise newException(CatchableError, "boom")
    proc innerAfter(spec: tuple, info: HookInfo) = log.add "inner-after"

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

  test "before fires before a matched --help raises, and after still fires, with info.showsMessage true":
    var log: seq[string]
    var seenShowsMessage = false
    proc appBefore(spec: tuple, info: HookInfo) =
      log.add "before"
      seenShowsMessage = info.showsMessage
    proc appAfter(spec: tuple, info: HookInfo) = log.add "after"

    let spec = (
      name: arg("<name>", help = ""),
      help: help(),
    )
    expect HelpError:
      spec.parse(usage = "<name>\n--help", args = @["--help"], command = "prog",
        before = appBefore, after = appAfter)
    check log == @["before", "after"]
    check seenShowsMessage

  test "before fires before a matched message/version flag raises, and after still fires, with info.showsMessage true":
    var log: seq[string]
    var seenShowsMessage = false
    proc appBefore(spec: tuple, info: HookInfo) =
      log.add "before"
      seenShowsMessage = info.showsMessage
    proc appAfter(spec: tuple, info: HookInfo) = log.add "after"

    let spec = (
      ver: version("--version", "myapp 1.2.3"),
    )
    expect MessageError:
      spec.parse(usage = "--version", args = @["--version"], command = "prog",
        before = appBefore, after = appAfter)
    check log == @["before", "after"]
    check seenShowsMessage

  test "info.showsMessage is false for an ordinary, non-message parse":
    var seenShowsMessage = true
    proc appBefore(spec: tuple, info: HookInfo) = seenShowsMessage = info.showsMessage

    let spec = (
      name: arg("<name>", help = ""),
    )
    spec.parse(usage = "<name>", args = @["Titanic"], command = "prog", before = appBefore)
    check not seenShowsMessage

  test "info.matched contains the Arg objects matched during this invocation":
    var seenMatched: seq[Arg]
    proc appBefore(spec: tuple, info: HookInfo) = seenMatched = info.matched

    let spec = (
      name: arg("<name>", help = ""),
      verbose: flag("--verbose", help = ""),
    )
    spec.parse(usage = "[--verbose] <name>", args = @["--verbose", "Titanic"], command = "prog", before = appBefore)
    check Arg(spec.name) in seenMatched
    check Arg(spec.verbose) in seenMatched

  test "the [S, O] overload's options param reaches before, action, and after":
    var seenBefore, seenAction, seenAfter = ""
    let context = (label: "outer-context")
    proc cmdBefore(spec: tuple, opts: tuple, info: HookInfo) = seenBefore = opts.label
    proc cmdAction(spec: tuple, opts: tuple, info: HookInfo) = seenAction = opts.label
    proc cmdAfter(spec: tuple, opts: tuple, info: HookInfo) = seenAfter = opts.label

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
    proc outerBefore(spec: tuple, info: HookInfo) = log.add "outer-before"
    proc outerAfter(spec: tuple, info: HookInfo) = log.add "outer-after"
    proc innerBefore(spec: tuple, info: HookInfo) = log.add "inner-before"
    proc innerAfter(spec: tuple, info: HookInfo) = log.add "inner-after"

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

  test "an ancestor command's before sees info.showsMessage true when a nested command's --help matches":
    # The 'ship' router's own before never sees a matched MessageArg at its
    # own spec level -- --help belongs to the nested 'move' spec several
    # levels down -- but info.matched is a flat view across the whole
    # matched dispatch chain, so info.showsMessage is still true here. See
    # docs/adr/0021-hook-info-matched-args.md.
    var outerSawShowsMessage = false
    proc outerBefore(spec: tuple, info: HookInfo) = outerSawShowsMessage = info.showsMessage

    let move = (help: help())
    let ship = (
      move: command("move", move, usage = "--help", help = ""),
    )
    let spec = (
      ship: command("ship", ship, before = outerBefore, help = ""),
    )
    expect HelpError:
      spec.parse(usage = "ship", args = @["ship", "move", "--help"], command = "prog")
    check outerSawShowsMessage

  test "two Commands can share one underlying proc, parameterized differently per call site":
    var log: seq[string]
    proc cmdToggle(spec: tuple, on: bool) =
      log.add (if on: "on" else: "off")

    let spec1 = (
      start: command("start", (), action = (proc(spec: tuple, info: HookInfo) = cmdToggle(spec, true)), help = ""),
      stop: command("stop", (), action = (proc(spec: tuple, info: HookInfo) = cmdToggle(spec, false)), help = ""),
    )
    spec1.parse(usage = "(start | stop)", args = @["start"], command = "prog")

    let spec2 = (
      start: command("start", (), action = (proc(spec: tuple, info: HookInfo) = cmdToggle(spec, true)), help = ""),
      stop: command("stop", (), action = (proc(spec: tuple, info: HookInfo) = cmdToggle(spec, false)), help = ""),
    )
    spec2.parse(usage = "(start | stop)", args = @["stop"], command = "prog")

    check log == @["on", "off"]

  test "the same Arg reachable at both an ancestor and a nested command's grammar gets each occurrence attributed to the right level":
    let tag = opts("--tag=<tag>", help = "")
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
    proc bAction(spec: tuple, info: HookInfo) = log.add "b"

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
    let spec = (names: args("<name>", help = ""))
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
      rest: args("<rest>", help = ""),
    )
    spec.parse(usage = "<name> -- <rest>...", args = @["x", "y", "z"], command = "prog")
    check spec.name == "x"
    check spec.rest == @["y", "z"]

  test "bare -- <arg>... requires at least one arg after the marker":
    let spec = (rest: args("<rest>", help = ""))
    expect ParseError:
      spec.parse(usage = "-- <rest>...", args = @[], command = "prog")

  test "[-- <arg>...] makes the whole marker-plus-args group skippable":
    let spec = (rest: args("<rest>", help = "", default = @["untouched"]))
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

suite "Usage Lines":
  test "a blank line in a usage string isn't a bare call":
    for usage in ["<foo>\n\n<bar>", "\n<foo>", "<foo>\n", "  \n<foo>"]:
      let spec = (foo: arg("<foo>", help = ""), bar: arg("<bar>", help = ""))
      expect ParseError:
        spec.parse(usage = usage, args = @[], command = "prog",
          settings = newSpecSettings(style = nil))

  test "an indented line continues its Usage Line across a blank line":
    let spec = (foo: arg("<foo>", help = ""), bar: arg("<bar>", help = ""))
    spec.parse(usage = "<foo>\n\n  <bar>", args = @["a", "b"], command = "prog")
    check spec.foo == "a" and spec.bar == "b"

  test "a Usage Line that is only {cmd} is a bare call":
    for args in [newSeq[string](), @["a"], @["a", "b"]]:
      let spec = (foo: arg("<foo>", help = ""), bar: arg("<bar>", help = ""))
      spec.parse(usage = "{cmd}\n{cmd} <foo> [<bar>]", args = args, command = "prog")
    let spec = (foo: arg("<foo>", help = ""), bar: arg("<bar>", help = ""))
    expect ParseError:
      spec.parse(usage = "{cmd}\n{cmd} <foo> [<bar>]", args = @["a", "b", "c"],
        command = "prog", settings = newSpecSettings(style = nil))

  test "a subcommand's {cmd} line is a bare call, shown with the command path":
    let sub = (n: arg("<n>", default = 0, help = ""))
    let spec = (sub: command("sub", sub, usage = "{cmd}\n{cmd} <n>", help = ""))
    spec.parse(usage = "sub", args = @["sub"], command = "prog")
    spec.parse(usage = "sub", args = @["sub", "1"], command = "prog")
    check sub.n == 1
    try:
      spec.parse(usage = "sub", args = @["sub", "1", "2"], command = "prog",
        settings = newSpecSettings(style = nil))
      fail()
    except ParseError as e:
      check "Usage:\n  prog sub\n  prog sub <n>" in e.msg

  test "{cmd} lines mix with auto-filled ones, and the usage reads back as written":
    let spec = newSpec((foo: arg("<foo>", help = ""), v: flag("-v", help = ""), help: help()),
      usage = "{cmd}\n<foo>", settings = newSpecSettings(style = nil))
    check spec.usage == "{cmd}\n<foo>\n[options]\n(-h | --help)"
    spec.parse(args = @[], command = "prog")
    spec.parse(args = @["-v"], command = "prog")
    spec.parse(args = @["a"], command = "prog")
    try:
      spec.parse(args = @["-h"], command = "prog")
      fail()
    except HelpError as e:
      check e.msg.startsWith("Usage:\n  prog\n  prog <foo>\n  prog [options]\n  prog (-h | --help)")

  test "{cmd} anywhere but a Usage Line's start is a SpecDefect":
    for usage in ["<foo> {cmd}", "{cmd}<foo>", "<foo>\n  {cmd}"]:
      expect SpecDefect:
        discard newSpec((foo: arg("<foo>", help = "")), usage = usage)

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

    # A short option is never offered: every one-character name is one edit
    # from every other. See docs/adr/0035-parse-failure-reporting.md.
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

  test "an [options]-only flag is never reported missing":
    # It's optional by construction, so it can't be what the user had to
    # supply -- ADR 0035's rule 1. The real complaint is the command.
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
    check "--verbose" notin caught
    check "missing command: add" in caught

  test "a satisfied repeated positional isn't reported missing when a later arg is":
    let spec = (
      src: args("<src>", help = ""),
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

suite "Help groups":
  test "an opt with an empty group is listed under Options":
    let spec = (
      name: opt("--name=<n>", default = "", help = "A name", group = ""),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "demo",
                 settings = newSpecSettings(style = nil))
    except HelpError as e:
      helpText = e.msg
    check helpText.splitLines.filterIt(it.endsWith(":")) == @["Usage:", "Options:"]
    check "  --name=<n>  A name" in helpText

  test "each constructor fills in its kind's group, before any spec is built":
    for group in ["", "Extra"]:
      let want = (pos: if group == "": "Arguments" else: group,
                  opt: if group == "": "Options" else: group,
                  cmd: if group == "": "Commands" else: group)
      check arg("<a>", group = group).group == want.pos
      check args("<a>", group = group).group == want.pos
      check arg[int]("<a>", group = group).group == want.pos
      check args[int]("<a>", group = group).group == want.pos
      check opt("--o=<v>", group = group).group == want.opt
      check opts("--o=<v>", group = group).group == want.opt
      check opt[int]("--o=<v>", group = group).group == want.opt
      check opts[int]("--o=<v>", group = group).group == want.opt
      check flag("-f", group = group).group == want.opt
      check flag[int]("-f", group = group).group == want.opt
      check flag("-f", ops = "--go=true", group = group).group == want.opt
      check flag[int]("-f", ops = "--go+=2", group = group).group == want.opt
      check help(group = group).group == want.opt
      check message("-m", "text", group = group).group == want.opt
      check version("-V", "1.0", group = group).group == want.opt
      check command("c", (x: flag("-x"),), group = group).group == want.cmd
    check arg("<a>").group == "Arguments"
    check opt("--o=<v>").group == "Options"
    check flag("-f").group == "Options"
    check help().group == "Options"
    check command("c", (x: flag("-x"),)).group == "Commands"

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
      ver: version("--version", "myapp 1.2.3"),
    )
    var caught = ""
    try:
      spec.parse(usage = "--version", args = @["--version"], command = "prog")
    except MessageError as e:
      caught = e.msg
    check caught == "myapp 1.2.3"

  test "hidden args can still be parsed":
    let spec = (
      deprecated: flag("--deprecated", help = "A deprecated flag", hidden = true),
      help: help()
    )
    spec.parse(args = @["--deprecated"], command = "prog")
    check spec.deprecated == true

  test "a flag with divergent per-variant ops repeats the shared help and action on every row":
    let spec = (
      verbosity: flag[int]("-v, --verbose",
        ops = [flagOp("--quiet", "=", 0), flagOp("--boost", "+=", 5), flagOp("--dampen", "-=", 2)],
        default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0, style = nil), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let colWidth = "-v, --verbose".len
    check ("  " & "-v, --verbose".alignLeft(colWidth) & "  Adjust verbosity [action: Increment by 1]") in helpText
    check ("  " & "--quiet".alignLeft(colWidth) & "  Adjust verbosity [action: Set to 0]") in helpText
    check ("  " & "--boost".alignLeft(colWidth) & "  Adjust verbosity [action: Increase by 5]") in helpText
    check ("  " & "--dampen".alignLeft(colWidth) & "  Adjust verbosity [action: Decrease by 2]") in helpText

  test "every row shows its own variantDesc plainly, with no shared text to repeat, when arg.help is empty":
    let spec = (
      verbosity: flag[int]("-v, --verbose", ops = [flagOp("--quiet", "=", 0)], default = 0, help = ""),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0, style = nil), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    let colWidth = "-v, --verbose".len
    check ("  " & "-v, --verbose".alignLeft(colWidth) & "  Increment by 1") in helpText
    check ("  " & "--quiet".alignLeft(colWidth) & "  Set to 0") in helpText

  test "flagOp's own help param overrides the auto-generated description for a specific variant":
    let spec = (
      verbosity: flag[int]("-v, --verbose",
        ops = [flagOp("--quiet", "=", 0, "Reset to silent"), flagOp("--boost", "+=", 5), flagOp("--dampen", "-=", 2)],
        default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Reset to silent" in helpText
    check "Set to 0" notin helpText

  test "a bool flag's blank-op variants show \"Set to the opposite of the default\" when grouped with a divergent peer":
    let spec = (
      moored: flag("-m, --moored", ops = [flagOp("--docked", "=", true)], default = false, help = "Ship status"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Ship status" in helpText
    check "Set to the opposite of the default" in helpText
    check "Toggle" notin helpText

  test "same-op variants collapse into a single ungrouped row (no divergence to disambiguate)":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0, style = nil), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "  -v, --verbose  Adjust verbosity" in helpText
    check "Increment by 1" notin helpText

  test "maxVariantsWidth defaults to DefaultMaxVariantsWidth and is configurable":
    proc mkSpec(): auto = (verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = "Adjust verbosity"), help: help())
    let default = newSpec(mkSpec())
    let narrow = newSpec(mkSpec(), settings = newSpecSettings(maxVariantsWidth = 20))
    let unlimited = newSpec(mkSpec(), settings = newSpecSettings(maxVariantsWidth = 0))
    check default.settings.maxVariantsWidth == DefaultMaxVariantsWidth
    check narrow.settings.maxVariantsWidth == 20
    check unlimited.settings.maxVariantsWidth == 0

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
    let settings = newSpecSettings(maxVariantsWidth = 0, style = nil)
    proc widenColumn(spec: tuple, info: HookInfo) = settings.maxVariantsWidth = 100

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
      spec.parse(settings = newSpecSettings(style = nil), usage = "<x> <name> <file>...\n[--speed=<speed>] [--verbose]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Speed in knots [default: 10]" in helpText
    check "Files [default: \"a.txt\", \"b.txt\"]" in helpText
    check "who to greet" in helpText
    check "who to greet [default" notin helpText
    check "Verbose output [default" notin helpText

  test "string and char defaults are quoted the way choices are":
    let spec = (
      sep: opt("--sep=<c>", default = ',', help = "Separator"),
      list: opt("--list=<l>", default = "a; b", help = "List"),
      drink: opt("--drink=<d>", default = "café", help = "Drink"),
      n: opt("-n=<n>", default = 3, help = "Count"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(style = nil), usage = "[options]", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Separator [default: \",\"]" in helpText
    check "List [default: \"a; b\"]" in helpText
    check "Drink [default: \"café\"]" in helpText
    check "Count [default: 3]" in helpText

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

  test "help text shows a choice validator's help alongside its default in one bracket":
    let spec = (
      action: arg("<action>", default = "foo", help = "Action to perform",
        validator = choice(["foo", "bar", "baz"])),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(style = nil), usage = "<action>\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Action to perform [choices: \"foo\", \"bar\", \"baz\"; default: \"foo\"]" in helpText

  test "help text shows a range validator's help without a default when default is the zero value":
    let spec = (
      speed: opt("--speed=<speed>", default = 0, help = "Speed", validator = range(1..100)),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(style = nil), usage = "[--speed=<speed>]\n--help", args = @["--help"], command = "prog")
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
      spec.parse(settings = newSpecSettings(style = nil), usage = "[--amount=<amount>]\n--help", args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "  --amount=<amount>  [must be even]" in helpText

  test "an explicit width overrides terminal detection":
    let longHelp = "How fast the ship should move across the open water, measured in knots"
    let wide = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()), settings = newSpecSettings(width = 80, style = nil))
    let narrow = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()), settings = newSpecSettings(width = 40, style = nil))
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
    restoringEnv(["COLUMNS"]):
      putEnv("COLUMNS", "90")
      let spec = newSpec((speed: opt("--speed=<speed>", default = 1, help = ""), help: help()))
      check spec.settings.width == 90

  test "a detected width is capped at DefaultMaxWidth":
    restoringEnv(["COLUMNS"]):
      putEnv("COLUMNS", "200")
      check newSpecSettings().width == DefaultMaxWidth

  test "an explicit width is never capped":
    check newSpecSettings(width = 150).width == 150

  test "detectWidth is the raw detected width, uncapped":
    restoringEnv(["COLUMNS"]):
      putEnv("COLUMNS", "200")
      check detectWidth() == 200
      check newSpecSettings(width = detectWidth()).width == 200

  test "width is detected on first read, not when the settings are built":
    restoringEnv(["COLUMNS"]):
      let settings = newSpecSettings()
      putEnv("COLUMNS", "63")
      check settings.width == 63
      putEnv("COLUMNS", "70")
      check settings.width == 63 # kept
      settings.width = 0
      check settings.width == 70 # re-armed

  test "style is resolved on first read, not when the settings are built":
    restoringEnv(["FORCE_COLOR", "CLICOLOR_FORCE", "NO_COLOR"]):
      delEnv("FORCE_COLOR")
      delEnv("CLICOLOR_FORCE")
      putEnv("NO_COLOR", "1")
      let settings = newSpecSettings()
      putEnv("FORCE_COLOR", "1")
      check not settings.style.isNil
      delEnv("FORCE_COLOR")
      check not settings.style.isNil # kept
      settings.style = autoStyler
      check settings.style.isNil # re-armed

  test "a theme is what the auto-detected style colours with":
    restoringEnv(["FORCE_COLOR", "CLICOLOR_FORCE", "NO_COLOR"]):
      var theme = defaultTheme
      theme[srOption] = TextStyle(fg: fgMagenta, attrs: {styleBright})
      delEnv("CLICOLOR_FORCE")
      delEnv("NO_COLOR")
      putEnv("FORCE_COLOR", "1")
      check (newSpecSettings(theme = theme).style)(srOption, "--name") ==
        ansiStyler(theme)(srOption, "--name")
      check (newSpecSettings().style)(srOption, "--name") ==
        ansiStyler(defaultTheme)(srOption, "--name")
      delEnv("FORCE_COLOR")
      if not (stdout.isatty and stderr.isatty):
        check newSpecSettings(theme = theme).style.isNil
      putEnv("NO_COLOR", "1")
      check newSpecSettings(theme = theme).style.isNil

  test "a theme doesn't touch an explicit style":
    var theme = defaultTheme
    theme[srOption] = TextStyle(fg: fgMagenta)
    check newSpecSettings(style = nil, theme = theme).style.isNil
    let styler: Styler = proc (role: StyleRole, text: string): string = "!" & text
    check (newSpecSettings(style = styler, theme = theme).style)(srOption, "x") == "!x"

  test "an explicit style is used as given":
    let styler: Styler = proc (role: StyleRole, text: string): string = "!" & text
    check newSpecSettings(style = nil).style.isNil
    check (newSpecSettings(style = styler).style)(srPlain, "x") == "!x"

  test "the default command name is the binary's file name, minus any .exe":
    check appName() == getAppFilename().splitFile.name
    check not appName().endsWith(".exe")

  test "width defaults to the capped detected width when COLUMNS isn't set":
    restoringEnv(["COLUMNS"]):
      delEnv("COLUMNS")
      let spec = newSpec((speed: opt("--speed=<speed>", default = 1, help = ""), help: help()))
      check spec.settings.width == min(detectWidth(), DefaultMaxWidth)

  test "chooseWidth: a positive COLUMNS, else the terminal's width, else DefaultWidth":
    check chooseWidth("200", 120) == 200
    check chooseWidth("", 120) == 120
    check chooseWidth("0", 120) == 120
    check chooseWidth("abc", 120) == 120
    check chooseWidth("", 0) == DefaultWidth
    check chooseWidth("0", 0) == DefaultWidth

  test "the stock defaults, unless a -d: define overrides them":
    # A define only replaces its own constant; see
    # `tests/test_compile_defines.nim` for them set.
    when not defined(argumint.width): check DefaultWidth == 80
    when not defined(argumint.maxWidth): check DefaultMaxWidth == 100
    when not defined(argumint.maxVariantsWidth): check DefaultMaxVariantsWidth == 30
    when not defined(argumint.envDelim): check DefaultEnvDelim == ":"
    when not defined(argumint.strictOptions): check DefaultStrictOptions

  test "width cascades from the root spec into nested subcommand specs":
    let move = (name: arg("<name>", help = ""), help: help())
    let ship = (move: command("move", move, help = "Move a ship"), help: help())
    let s = newSpec((ship: command("ship", ship, help = "Ship commands"), help: help()), settings = newSpecSettings(width = 40))
    check s.settings.width == 40
    check s.commands["ship"].spec.settings.width == 40
    check s.commands["ship"].spec.commands["move"].spec.settings.width == 40

suite "Library-internal names `tests/test_public_api.nim` asserts are unreachable":
  # That file checks `not compiles(...)` for each of these from a bare
  # `import argumint`, which would also pass if the name simply stopped
  # existing (a rename, a deleted field). These positives are its other
  # half: together they mean "exists, but not exported". Keep the two lists
  # in sync -- see docs/adr/0030-core-types-exported-spec-opaque.md.
  test "the value-display helpers exist":
    check quoted("x") == "\"x\""
    check showValue(1) == "1"

  test "the FSM plumbing types exist":
    var
      state: State
      transition: Transition
      matcher: Matcher
      matcherKind: MatcherKind
    check (state.isNil, transition.isNil, matcher.isNil) == (true, true, true)
    check matcherKind == MatcherKind.mkOption # first declared value

  test "`Spec`'s read accessors exist":
    let spec = newSpec((name: arg("<name>", help = ""), go: command("go", (x: flag("-x", help = ""))),
      verbose: flag("-v", help = "")), prolog = "pro", epilog = "epi")
    check not spec.fsm.isNil
    check spec.usage.len > 0
    check spec.args.len == 3
    check "go" in spec.commands
    check "<name>" in spec.arguments
    check "-v" in spec.options
    check spec.groups.len > 0
    check spec.prolog == "pro"
    check spec.epilog == "epi"

  test "`SpecSettings`'s private `theme` field exists":
    privateAccess(SpecSettings)
    var theme = defaultTheme
    theme[srEnv] = TextStyle(fg: fgRed)
    check newSpecSettings(theme = theme).theme == theme

  test "`ValueArg`/`FlagArg`'s private fields exist":
    # Reached here only via the `privateAccess` calls at the top of this
    # file; `tests/test_public_api.nim` asserts the same names are
    # unreachable from a plain `import argumint`.
    let
      name = opt("-n, --name=<s>", default = "x", help = "")
      tags = opts("--tag=<t>", default = @["a"], help = "")
      verbose = flag("-v, --verbose", help = "")
    check name.default == "x"
    check name.value.isNone
    check name.validator.isNil
    check seq[string](name.cfgKey).len == 0
    check tags.default == @["a"]
    check tags.value.isNone
    check not verbose.value
    check verbose.ops.len == 2      # one per variant
    check verbose.aliases.len == 2  # only populated for a multi-variant flag
    check verbose.clamp.isNil

  test "`Spec`'s private bookkeeping fields exist":
    let s = newSpec((
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      name: arg("<name>", help = ""),
      verbose: flag("-v", help = ""),
      help: help()),
      prolog = "front", epilog = "back")
    check s.prolog == "front"
    check s.epilog == "back"
    check s.usage.len > 0
    check s.args.len > 0
    check "ship" in s.commands
    check "<name>" in s.arguments
    check "-v" in s.options
    check s.groups.len > 0
    check not s.fsm.isNil

  test "spec construction's plumbing exists in `argumint/specbuild`":
    # Exported from `specbuild` only so generic `newSpec` can instantiate in
    # the caller's file (ADR 0030), never re-exported by the facade -- see
    # issue #49.
    let s = beginSpec("<name>", "front", "back")
    s.addArgs((name: arg("<name>", help = ""),))
    s.finishSpec(newSpecSettings(width = 80))
    check "<name>" in s.arguments
    check not s.fsm.isNil
    check s.settings.width == 80

  test "the variant-format PEGs exist in `argumint/backend`":
    check "<name>".match(PositionalVariantFormat)
    check "NAME".match(PositionalVariantFormat)
    check "--name=<s>".match(OptionalVariantFormat)
    check "--name=NAME".match(OptionalVariantFormat)
    check "-v".match(FlagVariantFormat)

  test "the tier rule exists in `argumint/backend`":
    let arg = Arg(variants: @["--port"])
    check arg.arbitration(some(byCli)) == some(arReplace)

  test "the env tier's reading and splitting exist in `argumint/envvar`":
    check compiles(lookupEnv(EnvSource(name: "PORT"), ":"))
    check splitEnvValue("a:b", none(string), ":") == @["a", "b"]

  test "the `ValueArg`/`FlagArg` machinery exists in `argumint/argtypes`":
    # Exported from `argtypes` only so the facade's generic constructors,
    # accessors, and registration templates can reach it; never
    # re-exported -- see issue #51 and the ADR on the facade/machinery
    # seam. `declared` for the two method generators, whose untyped
    # `flagHandler` block has no spelling that fits inside `compiles(...)`.
    check declared(defineFlagArg)
    check declared(defineSetFlagArg)
    checkFlagOp[int]("+=")  # the supported case raises nothing
    expect SpecDefect:
      checkFlagOp[int]("*=")
    check splitFlagSpellings("-v, --verbose") == @["-v", "--verbose"]
    check parseFlagOpsString[int]("--boost+=5") == @[(variants: @["--boost"], op: "+=", value: 5, help: "")]
    let name = initValueArg[string](Optional, "-n, --name=<s>", "x", "", "Options", false, noValidator[string]())
    check name.variants == @["-n", "--name=<s>"]
    let tags = initValuesArg[string](Optional, "--tag=<t>", @["x"], "", "Options", false, noValidator[string]())
    check tags.variants == @["--tag=<t>"]
    let verbose = initFlagArg[bool]("-v, --verbose", [], false, "", "Options", false,
      noClamp[bool](), none(EnvSource), noConfigKey())
    check verbose.ops.len == 2

  test "the untyped base under `ValueArg`/`ValuesArg` exists in `argumint/argtypes`":
    let base: ValueArgBase = opt("--num=<n>", default = 1)
    check not base.multi
    check ValueArgBase(opts[int]("--num=<n>")).multi

  test "a `ValueArg`/`ValuesArg` constructor sets every hook on its base":
    # A hook left unset compiles, then crashes the first time a base method
    # calls it.
    for base in [ValueArgBase(opt("--num=<n>", default = 1)),
                 ValueArgBase(opts[int]("--num=<n>"))]:
      for name, field in base[].fieldPairs:
        when (field is proc):
          checkpoint name & ", multi = " & $base.multi
          check not field.isNil

  test "the read accessors behind `get` exist in `argumint/argtypes`":
    let
      name = opt("-n, --name=<s>", default = "x", help = "")
      tags = opts("--tag=<t>", default = @["a"], help = "")
      verbose = flag("-v", help = "")
    check name.rawValue.isNone
    check name.rawDefault == "x"
    check tags.rawValue.isNone
    check tags.rawDefault == @["a"]
    check not verbose.rawValue

  test "the comma separator and the flag-op variant format exist in `argumint/backend`":
    # `Comma` has consumers on both sides of issue #51's seam (the Arg
    # constructors in the facade, `initValueArg`/`splitFlagSpellings` in
    # `argtypes`), so it lives below both; `FlagOpVariantFormat` followed
    # it rather than being stranded alone.
    check "-v, --verbose".split(Comma) == @["-v", "--verbose"]
    check "--boost+=5".match(FlagOpVariantFormat)

suite "accumulates":
  test "is true only for args that build their value from more than one match":
    check args("<a>", help = "").accumulates
    check opts("--o=<o>", help = "").accumulates
    check flag("-f", help = "").accumulates
    check not arg("<a>", help = "").accumulates
    check not opt("--o=<o>", help = "").accumulates
    check not command("c", (x: arg("<x>", help = "")), help = "").accumulates
    check not help().accumulates

suite "autoFillUsage":
  test "MessageArgs are filled in individually; a single unreachable command needs no parens":
    let spec = (
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      mine: command("mine", (y: arg("<y>", help = "")), help = "Mine"),
      help: help(),
      version: version("-v, --version", "1.0.0"),
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

  test "a standalone [options] line comes before the Message Argument lines":
    let spec = (
      verbose: flag("--verbose", help = ""),
      help: help(),
    )
    check newSpec(spec).usage == "[options]\n(-h | --help)"

  test "a spec holding only Message Arguments gets a Bare Call (#175)":
    let plain = newSpecSettings(style = nil)
    check newSpec((help: help())).usage == "{cmd}\n(-h | --help)"
    parse((help: help()), args = @[], command = "prog", settings = plain)

    var listed = false
    proc listNotes(spec: tuple, _: HookInfo) = listed = true
    let spec = (
      list: command("list", (help: help()), action = listNotes, help = ""),
      help: help(),
    )
    spec.parse(args = @["list"], command = "prog", settings = plain)
    check listed
    try:
      spec.parse(args = @["list", "-h"], command = "prog", settings = plain)
      fail()
    except HelpError as e:
      check e.msg.startsWith("Usage:\n  prog list\n  prog list (-h | --help)\n")

  test "a hand-written usage gets no Bare Call (#175)":
    let tag = (
      tag: command("tag", (help: help()), usage = "(-h | --help)", help = ""),
    )
    expect ParseError:
      tag.parse(args = @["tag"], command = "prog",
        settings = newSpecSettings(style = nil))
    check newSpec((x: arg("<x>", help = ""), help: help()), usage = "<x>").usage ==
      "<x>\n(-h | --help)"

  test "a spec without Message Arguments gets no Bare Call (#175)":
    check newSpec(()).usage == ""
    check newSpec((v: flag("-v", help = ""))).usage == "[options]"

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

  test "a multi-value positional is auto-filled with ..., and takes several values":
    let spec = (
      files: args("<file>", help = ""),
      dest: arg("<dest>", help = ""),
    )
    let s = newSpec(spec, usage = "")
    check s.usage == "<file>... <dest>"
    s.parse(@["a", "b", "out"], "prog")
    check spec.files.get == @["a", "b"]
    check spec.dest == "out"

  test "an auto-filled multi-value positional keeps the [options] prefix":
    let spec = (
      tags: opts("-t, --tag=<tag>", help = ""),
      text: args("<text>", help = ""),
    )
    let s = newSpec(spec, usage = "")
    check s.usage == "[options] <text>..."
    s.parse(@["buy", "milk", "-t", "errands"], "prog")
    check spec.text.get == @["buy", "milk"]
    check spec.tags.get == @["errands"]

  test "auto-filling more than one multi-value positional is a SpecDefect":
    let spec = (
      foo: args("<foo>", help = ""),
      bar: args("<bar>", help = ""),
    )
    try:
      discard newSpec(spec, usage = "")
      fail()
    except SpecDefect as e:
      check "<foo>" in e.msg and "<bar>" in e.msg
      check "usage" in e.msg

  test "a hand-written usage line may still repeat more than one positional":
    let spec = (
      foo: args("<foo>", help = ""),
      bar: args("<bar>", help = ""),
    )
    let s = newSpec(spec, usage = "<foo>... <bar>...")
    s.parse(@["a", "b"], "prog")
    check spec.foo.get == @["a"]
    check spec.bar.get == @["b"]

  test "a hand-written usage line still limits a multi-value positional to one value":
    let spec = (files: args("<file>", help = ""))
    let s = newSpec(spec, usage = "<file>")
    expect ParseError:
      s.parse(@["a", "b"], "prog")

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

  test "splicing onto an already-skippable line preserves skippability (#6)":
    ## Regression coverage for every autoFillUsage category (see
    ## docs/gotchas.md's "terminal flag" entry) -- each spec below has an
    ## explicit usage line that's itself fully skippable, plus one more Arg
    ## left unreferenced so autoFillUsage must splice a second line onto the
    ## already-built-and-simplified root. A zero-arg parse must still
    ## succeed via the first line's skip path in every case.
    block: # MessageArgs (help())
      let spec = (
        rest: args("<rest>", help = "", default = @["untouched"]),
        help: help(),
      )
      spec.parse(usage = "[-- <rest>...]", args = @[], command = "prog")
      check spec.rest == @["untouched"]

    block: # unreachable commands
      let spec = (
        verbose: flag("--verbose", help = "", default = false),
        ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      )
      spec.parse(usage = "[--verbose]", args = @[], command = "prog")
      check spec.verbose == false

    block: # unreachable positionals
      let spec = (
        verbose: flag("--verbose", help = "", default = false),
        a: arg("<a>", help = ""),
        b: arg("<b>", help = ""),
      )
      spec.parse(usage = "[--verbose]", args = @[], command = "prog")
      check spec.verbose == false

    block: # standalone [options] fallback
      let spec = (
        rest: args("<rest>", help = "", default = @["untouched"]),
        verbose: flag("--verbose", help = "", default = false),
      )
      spec.parse(usage = "[<rest>...]", args = @[], command = "prog")
      check spec.rest == @["untouched"]
      check spec.verbose == false

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
      a: opts("--av=<a>", help = ""),
      b: opts("--bv=<b>", help = ""),
    )
    discard newSpec(spec, usage = "[--av=<a>]... [--bv=<b>]...")

  test "the first atom doesn't need its own repeat for the hang to occur":
    let spec = (
      a: opt("--av=<a>", default = "", help = ""),
      b: opts("--bv=<b>", help = ""),
    )
    discard newSpec(spec, usage = "[--av=<a>] [--bv=<b>]...")

  test "three or more adjacent optional-and-repeated atoms don't hang":
    let spec = (
      a: opts("--av=<a>", help = ""),
      b: opts("--bv=<b>", help = ""),
      c: opts("--cv=<c>", help = ""),
    )
    discard newSpec(spec, usage = "[--av=<a>]... [--bv=<b>]... [--cv=<c>]...")

  test "two independently-repeatable env-configured options in one usage line resolve correctly, not just avoid hanging":
    putEnv("ARGUMINT_TEST_SHORTCUT_A", "foo:bar")
    defer: delEnv("ARGUMINT_TEST_SHORTCUT_A")
    putEnv("ARGUMINT_TEST_SHORTCUT_B", "baz:qux")
    defer: delEnv("ARGUMINT_TEST_SHORTCUT_B")
    let spec = (
      a: opts("--av=<a>", env = "ARGUMINT_TEST_SHORTCUT_A", help = ""),
      b: opts("--bv=<b>", env = "ARGUMINT_TEST_SHORTCUT_B", help = ""),
    )
    spec.parse(usage = "[--av=<a>]... [--bv=<b>]...", args = @[], command = "prog")
    check spec.a == @["foo", "bar"]
    check spec.b == @["baz", "qux"]

suite "Fallback tiers (env and Config Source)":
  # Behaviour both fallback tiers share, run once per tier. What only one
  # tier does lives in its own suite below.
  for t in FallbackTier:
    let tier = t.tierName

    test tier & ": an opt's value is used and converted like a CLI value":
      let settings = t.supply("9090")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 8080, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
      check spec.port == 9090

    test tier & ": an explicit CLI value overrides it":
      let settings = t.supply("9090")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 8080, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--port=<port>]", settings = settings, args = @["--port=1234"], command = "prog")
      check spec.port == 1234

    test tier & ": the value still goes through the option's validator":
      let settings = t.supply("99999")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 8080, env = envFor(t), configKey = keyFor(t),
          validator = range(1..65535), help = ""),
      )
      expect ValidationError:
        spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")

    test tier & ": configured but empty falls back to the coded default":
      let settings = t.supplyNothing
      let spec = (
        port: opt("--port=<port>", default = 8080, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
      check spec.port == 8080

    test tier & ": a flag's value names a variant, applied via that variant's own op; a CLI flag overrides":
      let settings = t.supply("--verbose")
      defer: clearFallback()
      let spec = (
        verbosity: flag[int]("--verbose", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--verbose]...", settings = settings, args = @[], command = "prog")
      check spec.verbosity == 1 # blank-op variant's own increment-by-1, not an arbitrary value

      let spec2 = (
        verbosity: flag[int]("--verbose", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec2.parse(usage = "[--verbose]...", settings = settings, args = @["--verbose"], command = "prog")
      check spec2.verbosity == 1 # CLI's own increment op wins; the tier is skipped entirely

    test tier & ": a flag value naming no declared variant raises ParseError":
      let settings = t.supply("--verbse") # typo
      defer: clearFallback()
      let spec = (
        verbosity: flag[int]("--verbose", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      expect ParseError:
        spec.parse(usage = "[--verbose]...", settings = settings, args = @[], command = "prog")

    test tier & ": a repeatable flag consumes several named variants, composing via each one's own op":
      let settings = t.supply("--verbose", "--verbose", "--verbose")
      defer: clearFallback()
      let spec = (
        verbosity: flag[int]("--verbose", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--verbose]...", settings = settings, args = @[], command = "prog")
      check spec.verbosity == 3

    test tier & ": a flag of a type with no = support applies its own declared op":
      # Speed's handler only supports `+=` (see its `defineArg` above). The
      # value names the variant's bare spelling, not the flagOp's op/value.
      let settings = t.supply("--speed")
      defer: clearFallback()
      let spec = (
        speed: flag[Speed](ops = [flagOp("--speed", "+=", slow)], default = slow,
          env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--speed]", settings = settings, args = @[], command = "prog")
      check spec.speed == medium2

    test tier & ": satisfies a required option":
      let settings = t.supply("9090")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "--port=<port>", settings = settings, args = @[], command = "prog")
      check spec.port == 9090

    test tier & ": satisfies a required flag":
      let settings = t.supply("--verbose")
      defer: clearFallback()
      let spec = (
        verbosity: flag[int]("--verbose", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "--verbose", settings = settings, args = @[], command = "prog")
      check spec.verbosity == 1

    test tier & ": an explicit CLI value overrides it for a required option too":
      let settings = t.supply("9090")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "--port=<port>", settings = settings, args = @["--port=1234"], command = "prog")
      check spec.port == 1234

    test tier & ": an option required twice errors if given only one value":
      let settings = t.supply("9090")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      expect ParseError:
        spec.parse(usage = "--port=<port> --port=<port>", settings = settings, args = @[], command = "prog")

    test tier & ": a single-value option named twice still takes only one value":
      let settings = t.supply("9090", "9091")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      expect ParseError:
        spec.parse(usage = "--port=<port> --port=<port>", settings = settings, args = @[], command = "prog")

    test tier & ": an option reachable only via a repeatable [options] doesn't hang":
      let settings = t.supply("9090")
      defer: clearFallback()
      let spec = (
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[options]", settings = settings, args = @[], command = "prog")
      check spec.port == 9090

    test tier & ": opts takes several values":
      let settings = t.supply("foo", "bar", "baz")
      defer: clearFallback()
      let spec = (
        tags: opts("--tag=<tag>", env = envFor(t), configKey = keyFor(t), help = ""),
      )
      spec.parse(usage = "[--tag=<tag>]...", settings = settings, args = @[], command = "prog")
      check spec.tags == @["foo", "bar", "baz"]

    # The walk accepts after `<a>`, so `--port`'s matcher is never visited.
    proc unwalkedPortSpec(t: FallbackTier): auto =
      (
        a: arg("<a>", help = ""),
        b: arg("<b>", help = ""),
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
      )

    test tier & ": an Arg whose position is never reached this walk still gets its value":
      let settings = t.supply("1234")
      defer: clearFallback()
      let spec = unwalkedPortSpec(t)
      spec.parse(usage = "<a> [<b> --port=<port>]", settings = settings, args = @["foo"], command = "prog")
      check spec.port == 1234

    test tier & ": two values for a never-reached single-value Arg are an error":
      let settings = t.supply("1234", "5678")
      defer: clearFallback()
      let spec = unwalkedPortSpec(t)
      expect ParseError:
        spec.parse(usage = "<a> [<b> --port=<port>]", settings = settings, args = @["foo"], command = "prog")

    # #189: a single-value Arg never takes more than one value from a tier,
    # whatever its slot.
    let source = if t == ftEnv: "env: " & FallbackVar else: "configKey: fallback"
    for (usage, values, args, fits, url) in [
      ("[--url=<url>]", @["a", "b"], newSeq[string](), false, ""),
      ("--url=<url>", @["a", "b"], newSeq[string](), false, ""),
      ("[options]", @["a", "b"], newSeq[string](), false, ""),
      ("[options]", @["a", "b"], @["-v"], false, ""),
      ("[options]", @["plain"], @["-v"], true, "plain"),
      ("[options]", @["a", "b"], @["--url=y"], true, "y"),
    ]:
      test tier & ": a single-value opt given " & $values & " under " & usage & " with " & $args:
        let settings = t.supply(values)
        defer: clearFallback()
        let spec = (
          url: opt("--url=<url>", env = envFor(t), configKey = keyFor(t), help = ""),
          verbose: flag("-v", help = ""),
        )
        var msg = ""
        try:
          spec.parse(usage = usage, settings = settings, args = args, command = "prog")
        except ParseError as e:
          msg = e.msg
        if fits:
          check msg == ""
          check spec.url == url
        else:
          check ("unexpected option: --url (" & source & ")") in msg

    test tier & ": a top-level option's value still applies when a nested command is also invoked":
      let settings = t.supply("9090")
      defer: clearFallback()
      let move = (name: arg("<name>", help = ""))
      let spec = (
        port: opt("--port=<port>", default = 0, env = envFor(t), configKey = keyFor(t), help = ""),
        ship: command("ship", move, usage = "<name>", help = ""),
      )
      spec.parse(usage = "[--port=<port>] ship", settings = settings, args = @["ship", "Titanic"], command = "prog")
      check spec.port == 9090
      check move.name == "Titanic"

    test tier & ": the same Arg reachable at an ancestor and a nested command isn't applied twice":
      let settings = t.supply("foo")
      defer: clearFallback()
      let tag = opts("--tag=<tag>", env = envFor(t), configKey = keyFor(t), help = "")
      let ship = (tag: tag)
      let spec = (
        tag: tag,
        ship: command("ship", ship, usage = "[--tag=<tag>]", help = ""),
      )
      spec.parse(usage = "[--tag=<tag>] ship", settings = settings, args = @["ship"], command = "prog")
      check tag == @["foo"]

    # #188: under the Options Catch-all, each fallback value used to need a
    # CLI token to loop it round again.
    proc verboseSpec(t: FallbackTier): auto =
      (
        name: opt("--name=<n>", help = ""),
        verbose: flag[int]("-v, --verbose", env = envFor(t), configKey = keyFor(t), help = ""),
      )

    for (values, args, name, verbose) in [
      (@["-v", "-v"], newSeq[string](), "", 2),
      (@["-v", "-v"], @["--name", "a"], "a", 2),
      (@["-v", "-v"], @["--name", "a", "--name", "b"], "b", 2),
      (@["-v", "-v", "-v"], @["-v"], "", 1),
    ]:
      test tier & ": the Options Catch-all applies every flag value with " & $args & " given":
        let settings = t.supply(values)
        defer: clearFallback()
        let spec = verboseSpec(t)
        spec.parse(settings = settings, args = args, command = "prog")
        check spec.name == name
        check spec.verbose == verbose

    test tier & ": an explicit repeatable flag applies every value beside another option":
      let settings = t.supply("-v", "-v")
      defer: clearFallback()
      let spec = verboseSpec(t)
      spec.parse(usage = "[--name=<n>] [-v]...", settings = settings, args = @["--name", "a"], command = "prog")
      check spec.name == "a"
      check spec.verbose == 2

    proc tagsSpec(t: FallbackTier): auto =
      (
        port: opt("-p, --port=<port>", default = 0, help = ""),
        tags: opts("-t, --tag=<tag>", env = envFor(t), configKey = keyFor(t), help = ""),
      )

    for (args, port, tags) in [
      (@["-p", "1"], 1, @["a", "b", "c"]),
      (newSeq[string](), 0, @["a", "b", "c"]),
      (@["-t", "d"], 0, @["d"]),
    ]:
      test tier & ": the Options Catch-all applies every opts value with " & $args & " given":
        let settings = t.supply("a", "b", "c")
        defer: clearFallback()
        let spec = tagsSpec(t)
        spec.parse(settings = settings, args = args, command = "prog")
        check spec.port == port
        check spec.tags == tags

    # A parent's Options Catch-all mustn't take the values a nested command's
    # own slots need.
    for (shipUsage, values) in [
      ("--tag=<tag>", @["a"]),
      ("--tag=<tag> --tag=<tag>", @["a", "b"]),
      ("--tag=<tag>...", @["a", "b"]),
      ("[options]", @["a", "b"]),
    ]:
      test tier & ": a parent's Options Catch-all leaves every value for a nested " & shipUsage:
        let settings = t.supply(values)
        defer: clearFallback()
        let tag = opts("--tag=<tag>", env = envFor(t), configKey = keyFor(t), help = "")
        let spec = (
          tag: tag,
          verbose: flag("-v", help = ""),
          ship: command("ship", (tag: tag), usage = shipUsage, help = ""),
        )
        spec.parse(usage = "[options] ship", settings = settings, args = @["-v", "ship"], command = "prog")
        check tag == values

    test tier & ": a parent's Options Catch-all leaves a single-value opt's value for a nested slot":
      let settings = t.supply("a")
      defer: clearFallback()
      let tag = opt("--tag=<tag>", env = envFor(t), configKey = keyFor(t), help = "")
      let spec = (
        tag: tag,
        verbose: flag("-v", help = ""),
        ship: command("ship", (tag: tag), usage = "--tag=<tag>", help = ""),
      )
      spec.parse(usage = "[options] ship", settings = settings, args = @["-v", "ship"], command = "prog")
      check tag == "a"

    # The parent's Options Catch-all has room for any number of --tag, so a
    # nested one-slot limit only holds when the parent has no room (ADR 0005).
    for (parentUsage, fits) in [("[options] ship", true), ("[-v] ship", false)]:
      test tier & ": two values for a nested one-slot opts fit=" & $fits & " under " & parentUsage:
        let settings = t.supply("a", "b")
        defer: clearFallback()
        let tag = opts("--tag=<tag>", env = envFor(t), configKey = keyFor(t), help = "")
        let spec = (
          tag: tag,
          verbose: flag("-v", help = ""),
          ship: command("ship", (tag: tag), usage = "--tag=<tag>", help = ""),
        )
        if fits:
          spec.parse(usage = parentUsage, settings = settings, args = @["-v", "ship"], command = "prog")
          check tag == @["a", "b"]
        else:
          expect ParseError:
            spec.parse(usage = parentUsage, settings = settings, args = @["-v", "ship"], command = "prog")

suite "Environment variables":
  test "opts: env var supplies multiple values via the delimiter":
    putEnv("ARGUMINT_TEST_TAGS", "foo:bar:baz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "empty segments from a doubled delimiter are kept as literal values, not dropped":
    putEnv("ARGUMINT_TEST_TAGS", "foo::bar")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "", "bar"]

  test "a space delimiter splits a list fish exported (#190)":
    # fish 3.0+ exports `set -x TAGS a b c` as `TAGS=a b c`.
    putEnv("ARGUMINT_TEST_TAGS", "a b c")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts("--tag=<tag>", env = env("ARGUMINT_TEST_TAGS", " "), help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["a", "b", "c"]

  test "\\x1e is not a delimiter (#190)":
    putEnv("ARGUMINT_TEST_TAGS", "foo:bar\x1ebaz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "bar\x1ebaz"]

  test "a custom envDelim splits on something other than colon":
    putEnv("ARGUMINT_TEST_TAGS", "foo,bar,baz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts("--tag=<tag>", env = "ARGUMINT_TEST_TAGS", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", settings = newSpecSettings(envDelim = ","), args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "a per-arg env(name, delim) override splits on something other than the spec's envDelim":
    putEnv("ARGUMINT_TEST_TAGS", "foo;bar;baz")
    defer: delEnv("ARGUMINT_TEST_TAGS")
    let spec = (
      tags: opts("--tag=<tag>", env = env("ARGUMINT_TEST_TAGS", ";"), help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "a per-arg delim override applies only to that arg, not the whole spec":
    putEnv("ARGUMINT_TEST_A", "foo;bar")
    defer: delEnv("ARGUMINT_TEST_A")
    putEnv("ARGUMINT_TEST_B", "foo:bar")
    defer: delEnv("ARGUMINT_TEST_B")
    let spec = (
      a: opts("--av=<a>", env = env("ARGUMINT_TEST_A", ";"), help = ""),
      b: opts("--bv=<b>", env = "ARGUMINT_TEST_B", help = ""),
    )
    spec.parse(usage = "[--av=<a>]... [--bv=<b>]...", args = @[], command = "prog")
    check spec.a == @["foo", "bar"]
    check spec.b == @["foo", "bar"]

  test "an empty per-arg delim override disables splitting entirely":
    putEnv("ARGUMINT_TEST_TOKEN", "a:b;c")
    defer: delEnv("ARGUMINT_TEST_TOKEN")
    let spec = (
      token: opt("--token=<token>", env = env("ARGUMINT_TEST_TOKEN", ""), help = ""),
    )
    spec.parse(usage = "[--token=<token>]", args = @[], command = "prog")
    check spec.token == "a:b;c"

  test "flag: env-named variants split on the default envDelim":
    # The shared suite splits on its own delimiter, so this pins the `:` path
    # for a Flag.
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbose:--verbose")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 2

  test "flag: a per-arg delim override applies to how env-named variants are split":
    putEnv("ARGUMINT_TEST_VERBOSE", "--verbose;--verbose")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = env("ARGUMINT_TEST_VERBOSE", ";"), help = ""),
    )
    spec.parse(usage = "[--verbose]...", args = @[], command = "prog")
    check spec.verbosity == 2

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
    proc outerBefore(spec: tuple, info: HookInfo) = log.add "outer-before"
    proc outerAfter(spec: tuple, info: HookInfo) = log.add "outer-after"

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
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0, style = nil), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Port [default: 8080; env: ARGUMINT_TEST_PORT]" in helpText
    check "Verbosity [env: ARGUMINT_TEST_VERBOSE]" in helpText

suite "Config Source":
  test "opt: an env value overrides the config value":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let settings = newSpecSettings(configSources = @[fakeSource((configKey("port"), @["7070"]))])
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", configKey = "port", help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 9090

  test "opt: a config-sourced failure names the Config Key as a flat path, not a raw seq":
    # ADR 0029: the error context goes through ConfigKey.join, so a
    # multi-segment path reads `server.port` the way help text renders it,
    # not `@["server", "port"]`.
    let settings = newSpecSettings(
      configSources = @[fakeSource((configKey("server", "port"), @["notanint"]))])
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = configKey("server", "port"), help = ""),
    )
    try:
      spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
      check false
    except ParseError as e:
      check "server.port" in e.msg
      check "@[" notin e.msg

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
      tags: opts("--tag=<tag>", configKey = "tags", help = ""),
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
    # (architecture.md's "Env var / Config Source mechanics"). The mutation
    # *is* visible to a later, separate parse() call reusing the same held
    # SpecSettings.
    let settings = newSpecSettings()
    proc addLocalSource(spec: tuple, info: HookInfo) =
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
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0, style = nil), args = @["--help"], command = "prog")
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
      tags: opts("--tag=<tag>", configKey = "tags", help = ""),
    )
    spec.parse(usage = "[--tag=<tag>]...", settings = settings, args = @[], command = "prog")
    check spec.tags == @["foo", "bar", "baz"]

  test "end-to-end: a jsonConfigSource array applies in full under the Options Catch-all beside another option (#188)":
    let path = getTempDir() / "argumint_test_config_188.json"
    writeFile(path, """{"verbose": ["--verbose", "--verbose"]}""")
    defer: removeFile(path)
    let settings = newSpecSettings(style = nil, configSources = @[jsonConfigSource(path)])
    let spec = (
      name: opt("--name=<n>", help = ""),
      verbose: flag[int]("-v, --verbose", configKey = "verbose", help = ""),
    )
    spec.parse(settings = settings, args = @["--name", "a"], command = "prog")
    check spec.name == "a"
    check spec.verbose == 2

  test "end-to-end: a Config Source file missing the configured key falls through to the coded default":
    let path = getTempDir() / "argumint_test_config_missing.ini"
    writeFile(path, "[server]\nhost=example.com\n")
    defer: removeFile(path)
    let settings = newSpecSettings(configSources = @[iniConfigSource(path)])
    let spec = (
      port: opt("--port=<port>", default = 8080, configKey = configKey("server", "port"), help = ""),
    )
    spec.parse(usage = "[--port=<port>]", settings = settings, args = @[], command = "prog")
    check spec.port == 8080

  test "a malformed INI config file raises an ordinary ValueError at construction, before any parse() call":
    let path = getTempDir() / "argumint_test_config_malformed.ini"
    writeFile(path, "[unterminated\n")
    defer: removeFile(path)
    expect ValueError:
      discard iniConfigSource(path)

  test "a malformed JSON config file raises an ordinary JsonParsingError at construction, before any parse() call":
    let path = getTempDir() / "argumint_test_config_malformed.json"
    writeFile(path, """{"unterminated": """)
    defer: removeFile(path)
    expect JsonParsingError:
      discard jsonConfigSource(path)

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
