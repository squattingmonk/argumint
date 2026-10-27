# A Flag's `validator` (#332): an env or config value no Variant or `=` op
# names is converted, checked and assigned. Imports only `argumint` (and
# `argumint/help` for its help), like `test_flag_ops.nim`, so it sees what a
# user sees.

import std/[options, os, strutils, sugar, unittest]

import argumint
import argumint/help

type
  Size = enum small, medium, large
  Mode = distinct string

proc `==`(a, b: Mode): bool {.borrow.}
proc `$`(a: Mode): string {.borrow.}
converter toMode(value: string): Mode = Mode(value)

const LevelVar = "ARGUMINT_FLAG_VALIDATOR_LEVEL"

type Three = ref object of ConfigSource

method lookup(self: Three, key: ConfigKey): Option[seq[string]] =
  some(@["3"])

proc fromEnv[T](flag: FlagArg[T], value: string): T =
  ## `flag`'s value after a parse of no args with `LevelVar` set to `value`.
  putEnv(LevelVar, value)
  defer: delEnv(LevelVar)
  flag.clear
  (f: Arg(flag),).parse(args = @[], command = "prog")
  flag.get

suite "an env or config value a Flag's `validator` allows":
  test "is assigned, though no `=` op sets it":
    let f = flag[int]("--level", ops = [flagOp("--l0", "=", 0), flagOp("--l5", "=", 5)],
      env = LevelVar, validator = range(0..5))
    check f.fromEnv("3") == 3

  test "so is one for the string form of `ops`":
    let f = flag[int]("--level", ops = "--l0=0, --l5=5", env = LevelVar, validator = range(0..5))
    check f.fromEnv("3") == 3

  test "so is one from a Config Source":
    let f = flag[int]("--level", ops = [flagOp("--l5", "=", 5)], configKey = configKey("level"),
      validator = range(0..5))
    (f: Arg(f),).parse(args = @[], command = "prog",
      settings = newSpecSettings(configSources = @[ConfigSource(Three())]))
    check f.get == 3

  test "each of several values resolves in order, a later one replacing it":
    let f = flag[int]("--level", ops = [flagOp("--boost", "+=", 1)], env = LevelVar,
      validator = range(0..5))
    check f.fromEnv("2:3") == 3
    check f.fromEnv("3:--boost") == 4

  test "a Flag Clamp applies afterward":
    let f = flag[int]("--level", ops = [flagOp("--l0", "=", 0)], clamp = clamp(0..5), env = LevelVar,
      validator = range(0..10))
    check f.fromEnv("8") == 5

  test "an enum value no `=` op sets":
    let f = flag[Size]("--size", ops = [flagOp("--small", "=", small)], env = LevelVar,
      validator = choice([small, large]))
    check f.fromEnv("large") == large

  test "a negative float":
    let f = flag[float](ops = [flagOp("--tilt", "=", 0.0)], env = LevelVar,
      validator = range(-2.0..2.0))
    check f.fromEnv("-1.5") == -1.5

proc complaintOf[T](flag: FlagArg[T], value: string): tuple[kind, msg: string] =
  ## The kind and first line of the error a parse with `LevelVar` set to
  ## `value` raises.
  try:
    discard flag.fromEnv(value)
  except ConversionError as e:
    result = ("ConversionError", e.msg.splitLines[0])
  except ValidationError as e:
    result = ("ValidationError", e.msg.splitLines[0])

suite "an env or config value a Flag's `validator` doesn't allow":
  setup:
    let f = flag[int]("--level", ops = [flagOp("--l0", "=", 0), flagOp("--l5", "=", 5)],
      env = LevelVar, validator = range(0..5))

  test "fails validation, naming its source":
    check f.complaintOf("7") == ("ValidationError",
      "  - for --level (env: ARGUMINT_FLAG_VALIDATOR_LEVEL), got 7 but expected a value in 0..5")

  test "fails conversion if it isn't a `T`":
    check f.complaintOf("abc") == ("ConversionError",
      "  - expected an integer for --level (env: ARGUMINT_FLAG_VALIDATOR_LEVEL) but got \"abc\"")

  test "an option-shaped one suggests one of the flag's own Variants":
    check f.complaintOf("--levle") == ("ConversionError",
      "  - expected an integer for --level (env: ARGUMINT_FLAG_VALIDATOR_LEVEL) but got \"--levle\"; " &
      "did you mean --level?")

suite "what a Flag's `validator` checks, and when":
  test "an `=` op's value at spec construction, but no Variant or `=` value at parse time":
    var calls = 0
    let accepts5 = argumint.check(proc (x: int): bool =
      inc calls
      x == 5)
    let f = flag[int]("--level", ops = [flagOp("--l5", "=", 5)], env = LevelVar, validator = accepts5)
    check calls == 1
    check f.fromEnv("5") == 5
    check f.fromEnv("--l5") == 5
    check calls == 1

  test "an `=` op its `validator` rejects is a SpecDefect naming it":
    let message = "flag --level's op --l10 sets 10, which its validator rejects: " &
      "got 10 but expected a value in 0..5"
    try:
      discard flag[int]("--level", ops = [flagOp("--l10", "=", 10)], env = LevelVar, validator = range(0..5))
      fail()
    except SpecDefect as e:
      check e.msg == message
    try:
      discard flag[int]("--level", ops = "--l10=10", env = LevelVar, validator = range(0..5))
      fail()
    except SpecDefect as e:
      check e.msg == message

  test "without one, an `=` op may set any value":
    let f = flag[int]("--level", ops = [flagOp("--l10", "=", 10)], env = LevelVar)
    check f.fromEnv("10") == 10

  test "a relative op is never checked":
    let f = flag[int]("--level", ops = [flagOp("--up", "+=", 10)], env = LevelVar, validator = range(0..5))
    check f.fromEnv("--up") == 10

proc specDefectOf(build: proc ()): string =
  ## The message of the `SpecDefect` `build` raises.
  try:
    build()
  except SpecDefect as e:
    result = e.msg

suite "a Flag's `validator` that could never run or fail":
  test "a history-aware one, alone or inside `all` or `any`, is a SpecDefect":
    let message = "flag --level's validator checks the values seen before, " &
      "but a flag holds one value: drop its unique, checkSeen or checkSeenIt"
    let unseen = checkSeenIt[int](it notin seen)
    for validator in [unique[int](), all(range(0..5), unseen), any(range(0..5), all(unseen))]:
      check specDefectOf(proc () =
        discard flag[int]("--level", env = LevelVar, validator = validator)) == message

  test "one with neither `env` nor `configKey` is a SpecDefect":
    check specDefectOf(proc () = discard flag[int]("--level", validator = range(0..5))) ==
      "flag --level has a validator but neither env nor configKey for it to check"

suite "a distinct string Flag's `validator`":
  test "compiles, and allows what its validator allows":
    let f = flag[Mode](ops = [flagOp("--fast", "=", Mode("fast"))], env = LevelVar,
      validator = choice([Mode("fast"), Mode("safe")]))
    check $f.fromEnv("safe") == "safe"

  test "stores a mistyped Variant its validator allows":
    # Pinned, not endorsed: the risk ADR 0086 leaves with the spec author.
    let f = flag[Mode](ops = [flagOp("--fast", "=", Mode("fast"))], env = LevelVar,
      validator = argumint.check(proc (m: Mode): bool = true, desc = "any mode"))
    check $f.fromEnv("--fats") == "--fats"

suite "the Flags that can't take a `validator`":
  test "a string, bool or set Flag doesn't compile with one, only without":
    check compiles(flag[string](ops = [flagOp("--fast", "=", "fast")], env = LevelVar))
    check not compiles(flag[string](ops = [flagOp("--fast", "=", "fast")], env = LevelVar,
      validator = choice(["fast"])))
    check not compiles(flag[string](ops = "--fast=fast", env = LevelVar, validator = choice(["fast"])))
    check compiles(flag[bool]("-q", env = LevelVar))
    check not compiles(flag[bool]("-q", env = LevelVar, validator = choice([true])))
    check compiles(flag[set[Size]](ops = [flagOp("--all", "=", {small, large})], env = LevelVar))
    check not compiles(flag[set[Size]](ops = [flagOp("--all", "=", {small, large})], env = LevelVar,
      validator = choice([{small}])))

proc bracketOf[T](flag: FlagArg[T],
    keep: proc (arg: Arg, annotation: HelpAnnotation): bool = nil): string =
  ## The `[...]` bracket help shows for a spec holding only `flag`, with
  ## only the Help Annotations `keep` (if not nil) accepts.
  let formatter = (ctx: HelpContext) => formatColumn(ctx.filterAnnotations(keep))
  try:
    (f: Arg(flag), help: help(formatter = formatter)).parse(args = @["--help"], command = "prog",
      settings = newSpecSettings(style = nil, width = 200))
  except HelpError as e:
    for line in e.msg.splitLines:
      if line.strip.startsWith("--level"):
        return line[line.find('[') .. ^1]

suite "help for a Flag's `validator`":
  test "is its own entry, labelled, before `env`":
    let f = flag[int]("--level", env = "LEVEL", validator = range(0..5))
    check f.bracketOf == "[env/config values: range: 0..5; env: LEVEL]"

  test "comes after a clamp's":
    let f = flag[int]("--level", clamp = clamp(0..9), env = "LEVEL", validator = range(0..5))
    check f.bracketOf == "[clamp: 0..9; env/config values: range: 0..5; env: LEVEL]"

  test "can be left out apart from a clamp's, and a clamp's apart from it":
    let f = flag[int]("--level", clamp = clamp(0..9), env = "LEVEL", validator = range(0..5))
    check f.bracketOf((arg, a) => a.kind != haValidator) == "[clamp: 0..9; env: LEVEL]"
    check f.bracketOf((arg, a) => a.kind != haClamp) == "[env/config values: range: 0..5; env: LEVEL]"

  test "shows a Validator's `desc` after the label, ticks kept as on an opt":
    let f = flag[int]("--level", configKey = configKey("level"),
      validator = range(0..5, desc = "a level from `0` to `5`"))
    check f.bracketOf == "[env/config values: a level from `0` to `5`; configKey: level]"
