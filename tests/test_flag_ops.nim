# Flag Operations as closures (#248): named ops on any type that supports
# them, procs, `flagOpIt`, Implicit Operations, and the bounds every
# built-in type stops at. Imports only `argumint`, like
# `test_custom_types.nim`, so it sees what a user sees.

import std/[options, os, strutils, times, unittest]

import argumint

type
  Size = enum small, medium, large
  Gap = enum gOne = 1, gFive = 5, gNine = 9
  Hue = distinct int
  Ten = range[1..10]
  Tally = object
    ## Records which spelling of `+` it was given.
    total: int
    via: string

proc `+`(a, b: Hue): Hue {.borrow.}
proc `-`(a, b: Hue): Hue {.borrow.}
proc `*`(a, b: Hue): Hue {.borrow.}
proc `==`(a, b: Hue): bool {.borrow.}
proc `$`(a: Hue): string {.borrow.}

proc `+`(a, b: Tally): Tally = Tally(total: a.total + b.total, via: "+")
proc `+=`(a: var Tally, b: Tally) =
  a.total += b.total
  a.via = "+="
proc `$`(a: Tally): string = $a.total

type Fives = ref object of ConfigSource

method lookup(self: Fives, key: ConfigKey): Option[seq[string]] =
  some(@["--up"])

# Each spec holds its flag as a plain `Arg`: two tuples that differ only in
# a range type miscompile (docs/gotchas.md).

proc run[T](flag: FlagArg[T], args: varargs[string]): T =
  ## `flag`'s value after parsing `args`, from its default.
  flag.clear
  (f: Arg(flag),).parse(args = @args, command = "prog")
  flag.get

proc helpOf[T](flag: FlagArg[T]): string =
  ## The help text for a spec holding only `flag`.
  try:
    (f: Arg(flag), help: help()).parse(args = @["--help"], command = "prog",
      settings = newSpecSettings(style = nil))
  except HelpError as e:
    result = e.msg

proc lineOf(text, variant: string): string =
  ## What help shows beside `variant`.
  for line in text.splitLines:
    if line.strip.startsWith(variant & " "):
      return line.strip[variant.len .. ^1].strip

proc defectMsg(build: proc ()): string =
  ## The message of the `SpecDefect` `build` raises.
  try: build()
  except SpecDefect as e: result = e.msg

suite "named ops":
  test "on every built-in number type":
    template checkOps(T: typedesc) =
      let f = flag[T](ops = [flagOp("--set", "=", T(6)), flagOp("--up", "+=", T(2)),
                             flagOp("--down", "-=", T(1)), flagOp("--times", "*=", T(3))],
                      default = T(1))
      check f.run("--set") == T(6)
      check f.run("--set", "--up") == T(8)
      check f.run("--set", "--down") == T(5)
      check f.run("--set", "--times") == T(18)
    checkOps(int)
    checkOps(int8)
    checkOps(uint8)
    checkOps(float)
    checkOps(float32)
    checkOps(Natural)

  test "on a distinct type, through its own operators":
    let f = flag[Hue](ops = [flagOp("--up", "+=", Hue(2)), flagOp("--down", "-=", Hue(5)),
                             flagOp("--times", "*=", Hue(3))], default = Hue(1))
    check f.run("--up", "--times") == Hue(9)
    check f.run("--down") == Hue(-4)

  test "on a set, as union, difference and intersection":
    let f = flag[set[Size]](ops = [flagOp("--only", "=", {small}),
                                   flagOp("--add", "+=", {medium, large}),
                                   flagOp("--drop", "-=", {large}),
                                   flagOp("--keep", "*=", {small, large})],
                            default = {medium})
    check f.run("--only") == {small}
    check f.run("--add") == {medium, large}
    check f.run("--add", "--drop") == {medium}
    check f.run("--add", "--keep") == {large}

  test "`+=` is preferred when a type defines it":
    let f = flag[Tally](ops = [flagOp("--up", "+=", Tally(total: 2))])
    check f.run("--up") == Tally(total: 2, via: "+=")

  test "a type without the operator doesn't compile":
    check not compiles(flagOp("--up", "+=", medium))
    check not compiles(flagOp("--twice", "*=", "s"))
    check not compiles(flagOp("--up", "^=", 1))

  test "the string form rejects an unsupported op at run time":
    check defectMsg(proc () = discard flag[Size](ops = "--up+=large")) ==
      "`+=` needs `+` for Size"
    check defectMsg(proc () = discard flag[string](ops = "--twice*=s")) ==
      "`*=` needs `*` for string"

  test "the string form rejects an unknown op, listing the four":
    check defectMsg(proc () = discard flag[int](ops = "--boost^=5")) ==
      "`^=` is not a Flag Operation: use `=`, `+=`, `-=` or `*=`"
    check defectMsg(proc () = discard flag[int](ops = "--boost:5")) ==
      "`:` is not a Flag Operation: use `=`, `+=`, `-=` or `*=`"

  test "the string form reads one element of a set":
    let f = flag[set[Size]](ops = "--big+=large, --none=small")
    check f.run("--big") == {large}
    check f.run("--big", "--none") == {small}

suite "procs":
  test "a proc op runs on the flag's value":
    let shout = proc (value: var string) = value = value.toUpperAscii
    let f = flag[string](ops = [flagOp("--shout", shout)], default = "hey")
    check f.run("--shout") == "HEY"

  test "`flagOpIt` assigns its expression, reading `it`":
    let start = dateTime(2026, mOct, 8, zone = utc())
    let f = flag[DateTime](ops = [flagOpIt[DateTime]("--tomorrow", it + 1.days, "Tomorrow")],
                           default = start)
    check f.run("--tomorrow", "--tomorrow") == dateTime(2026, mOct, 10, zone = utc())

  test "a proc op shows its description, and nothing without one":
    let f = flag[int](ops = [flagOpIt[int]("--double", it * 2, "Double it"),
                             flagOpIt[int]("--halve", it div 2),
                             flagOp("--zero", proc (value: var int) = value = 0),
                             flagOp("--up", "+=", 1)], help = "Size")
    let text = f.helpOf
    check text.lineOf("--double") == "Size [action: Double it]"
    check text.lineOf("--halve, --zero") == "Size"
    check text.lineOf("--up") == "Size [action: Increase by 1]"

suite "Implicit Operations":
  test "bool sets the opposite of its default":
    check flag("-v").run("-v") == true
    check flag("-q", default = true).run("-q", "-q") == false

  test "an integer increases by 1, stopping at its type's top":
    check flag[int]("-v").run("-v", "-v") == 2
    check flag[int]("-v", default = high(int)).run("-v") == high(int)
    check flag[uint8]("-v", default = 254).run("-v", "-v") == 255
    check flag[Ten]("-v", default = 9).run("-v", "-v") == 10

  test "an enum moves to the next declared value, stopping at the last":
    check flag[Size]("-s").run("-s") == medium
    check flag[Size]("-s").run("-s", "-s", "-s") == large
    check flag[Gap]("-g").run("-g") == gFive
    check flag[Gap]("-g").run("-g", "-g", "-g") == gNine

  test "a type with none rejects bare variants, pointing to `flagOp`":
    check defectMsg(proc () = discard flag[float]("-x")) ==
      "-x has no operation: float has no Implicit Operation; give it a proc with `flagOp`"

suite "bounds":
  test "named ops on `int8` stop at its bounds":
    let f = flag[int8](ops = [flagOp("--up", "+=", 100'i8), flagOp("--down", "-=", 100'i8),
                              flagOp("--times", "*=", 100'i8), flagOp("--neg", "=", -100'i8)])
    check f.run("--up", "--up") == 127
    check f.run("--down", "--down") == -128
    check f.run("--up", "--times") == 127
    check f.run("--neg", "--times") == -128

  test "named ops on a range type stop at its own bounds":
    let f = flag[Ten](ops = [flagOp("--up", "+=", Ten(6)), flagOp("--down", "-=", Ten(6)),
                             flagOp("--times", "*=", Ten(4))], default = 5)
    check f.run("--up") == 10
    check f.run("--down") == 1
    check f.run("--times") == 10

  test "a declared clamp narrows them":
    let f = flag[int8](ops = [flagOp("--up", "+=", 100'i8)], clamp = clamp(0'i8..50'i8))
    check f.run("--up", "--up") == 50

  test "`clamp` needs `<` for its type":
    check not compiles(clamp(Tally()..Tally()))

  test "floats reach infinity":
    let f = flag[float32](ops = [flagOp("--times", "*=", 1e30'f32)], default = 1e30)
    check f.run("--times", "--times") == Inf

suite "generated descriptions":
  test "for each named op, values shown as help shows them":
    let text = flag[string](ops = [flagOp("--loud", "=", "loud"), flagOp("--soft", "=", "soft")]).helpOf
    check text.lineOf("--loud") == "Set to \"loud\""
    let num = flag[int](ops = [flagOp("--set", "=", 1), flagOp("--up", "+=", 2),
                               flagOp("--down", "-=", 3), flagOp("--times", "*=", 4)]).helpOf
    check num.lineOf("--set") == "Set to 1"
    check num.lineOf("--up") == "Increase by 2"
    check num.lineOf("--down") == "Decrease by 3"
    check num.lineOf("--times") == "Multiply by 4"

  test "for sets, as their elements":
    let text = flag[set[Size]](ops = [flagOp("--set", "=", {small, large}),
                                      flagOp[set[Size]]("--clear", "=", {}),
                                      flagOp("--add", "+=", {medium}),
                                      flagOp("--drop", "-=", {small}),
                                      flagOp("--keep", "*=", {small, medium})]).helpOf
    check text.lineOf("--set") == "Set to small, large"
    check text.lineOf("--clear") == "Set to none"
    check text.lineOf("--add") == "Add medium"
    check text.lineOf("--drop") == "Remove small"
    check text.lineOf("--keep") == "Keep only small, medium"

  test "for each Implicit Operation":
    check flag("-v", ops = [flagOp("-q", "=", false)]).helpOf.lineOf("-v") == "Set to true"
    check flag("-q", ops = [flagOp("-v", "=", true)], default = true).helpOf.lineOf("-q") ==
      "Set to false"
    check flag[int]("-v", ops = [flagOp("-q", "=", 0)]).helpOf.lineOf("-v") == "Increase by 1"
    check flag[Size]("-s", ops = [flagOp("--big", "=", large)]).helpOf.lineOf("-s") ==
      "Move to the next value"

  test "`help` replaces it":
    check flag[int]("-v", ops = [flagOp("--up", "+=", 5, "Louder")]).helpOf.lineOf("--up") ==
      "Louder"

suite "where a flag's value comes from":
  test "FlagOp Alias groups are the spellings of one `flagOp`":
    # A usage line naming one spelling accepts only its aliases.
    let f = flag[int]("-v, --verbose", ops = [flagOp("-u, --up", "+=", 5), flagOp("--more", "+=", 5)])
    proc accepts(usage, typed: string): bool =
      try:
        (f: Arg(f),).parse(usage = usage, args = @[typed], command = "prog")
        true
      except ParseError: false
    check accepts("-v", "--verbose")
    check accepts("-u", "--up")
    check not accepts("--up", "--more")
    check not accepts("-v", "-u")

  test "env names a Variant, whose op runs":
    putEnv("ARGUMINT_FLAG_OPS_UP", "--up,--up")
    defer: delEnv("ARGUMINT_FLAG_OPS_UP")
    let f = flag[int8](ops = [flagOp("--up", "+=", 100'i8)], env = env("ARGUMINT_FLAG_OPS_UP", ","))
    check f.run() == 127

  test "a Config Source names a Variant, whose op runs":
    let f = flag[int](ops = [flagOp("--up", "+=", 5)], configKey = configKey("up"))
    (f: Arg(f),).parse(args = @[], command = "prog",
      settings = newSpecSettings(configSources = @[ConfigSource(Fives())]))
    check f.get == 5

  test "a stronger tier starts again from the default":
    let f = flag[int](ops = [flagOp("--up", "+=", 5)])
    f.put(100, seenBy = some(byEnv))
    f.parse("--up", seenBy = some(byCli))
    check f.get == 5

  test "`put` clamps":
    let f = flag[int](ops = [flagOp("--up", "+=", 5)], clamp = clamp(0..10))
    f.put(20)
    check f.get == 10
