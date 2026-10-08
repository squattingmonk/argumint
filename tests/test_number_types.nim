# Every integer and float type, and range types, as Value Types (#247).
# Imports only `argumint`, like `test_value_types.nim`.

import std/[fenv, math, options, os, strutils, unittest]

import argumint

type
  Ten = range[1..10]
  Hue = distinct int

type Fours = ref object of ConfigSource

method lookup(self: Fours, key: ConfigKey): Option[seq[string]] =
  some(@["4"])

# Flags still need registering until #248.
defineArg(Positive):
  case op
  of "": value.inc
  else: value = arg

# Each spec holds its Arg as a plain `Arg`: two tuples that differ only in
# `int` and `Natural` miscompile (docs/gotchas.md).

proc parsed[T](text: string): T =
  ## `text` given to an `opt[T]`, read back.
  let n = opt[T]("--num=<n>")
  (n: Arg(n),).parse(args = @["--num", text], command = "prog")
  n.get

proc failure[T](text: string): string =
  ## The first line of the error `text` given to an `opt[T]` raises.
  try:
    (n: Arg(opt[T]("--num=<n>")),).parse(args = @["--num", text], command = "prog",
                                       settings = newSpecSettings(style = nil))
  except ParseError as e:
    result = e.msg.splitLines[0].strip(trailing = false)
    result.removePrefix("- ")

proc helpOf(spec: tuple): string =
  try:
    spec.parse(args = @["--help"], command = "prog",
               settings = newSpecSettings(style = nil))
  except HelpError as e:
    result = e.msg

proc isOutOfRange[T](text: string): bool =
  ## Whether `text` is rejected as outside `T`'s own bounds.
  failure[T](text) == "for --num, got \"" & text & "\" but expected a value in " &
    $low(T) & ".." & $high(T)

template checkBounds(T: typedesc, below, above: string) =
  check parsed[T]($low(T)) == low(T)
  check parsed[T]($high(T)) == high(T)
  check isOutOfRange[T](below)
  check isOutOfRange[T](above)

suite "every integer width":
  test "signed, at both bounds and one past each":
    checkBounds(int8, "-129", "128")
    checkBounds(int16, "-32769", "32768")
    checkBounds(int32, "-2147483649", "2147483648")
    checkBounds(int64, "-9223372036854775809", "9223372036854775808")
    checkBounds(int, "-9223372036854775809", "9223372036854775808")

  test "unsigned, at both bounds and one past each":
    checkBounds(uint8, "-1", "256")
    checkBounds(uint16, "-1", "65536")
    checkBounds(uint32, "-1", "4294967296")
    checkBounds(uint64, "-1", "18446744073709551616")
    checkBounds(uint, "-1", "18446744073709551616")

  test "a negative number may lead with a space":
    check parsed[int8](" -5") == -5
    check parsed[int16](" -300") == -300

  test "a non-number expects an integer, `int` included":
    check failure[int]("abc") == "expected an integer for --num but got \"abc\""
    check failure[int8]("abc") == "expected an integer for --num but got \"abc\""
    check failure[uint16]("1.5") == "expected an integer for --num but got \"1.5\""
    check failure[Natural]("x") == "expected an integer for --num but got \"x\""

suite "floats":
  test "`float32` takes a value it can hold":
    check parsed[float32]("2.5") == 2.5'f32
    check parsed[float32](" -2.5") == -2.5'f32

  test "`float32` rejects a finite value too large for it":
    let bound = $maximumPositiveValue(float32)
    check failure[float32]("1e300") ==
      "for --num, got \"1e300\" but expected a value in -" & bound & ".." & bound
    check failure[float32]("-1e300") ==
      "for --num, got \"-1e300\" but expected a value in -" & bound & ".." & bound

  test "`float32` takes a literal infinity":
    check parsed[float32]("inf") == Inf.float32
    check parsed[float32](" -inf") == NegInf.float32

  test "a non-number expects a number":
    check failure[float32]("abc") == "expected a number for --num but got \"abc\""
    check failure[float]("abc") == "expected a number for --num but got \"abc\""

  test "a float range type stays in its bounds":
    check parsed[range[0.0..1.0]]("0.5") == 0.5
    check isOutOfRange[range[0.0..1.0]]("1.5")
    check isOutOfRange[range[0.0..1.0]]("nan")

  test "a plain float still takes `nan`":
    check parsed[float]("nan").isNaN

suite "range types":
  test "`Natural` and `Positive`":
    checkBounds(Natural, "-1", "9223372036854775808")
    checkBounds(Positive, "0", "9223372036854775808")

  test "a named range":
    checkBounds(Ten, "0", "11")

  test "an inline range":
    checkBounds(range[0..3], "-1", "4")

  test "an unsigned range":
    checkBounds(range[2'u8..9'u8], "1", "10")

suite "the fallback default":
  test "is the lowest value of a range that excludes zero":
    let spec = (n: opt[Positive]("--num=<n>"), t: arg[Ten]("<t>"))
    spec.parse(args = @["3"], command = "prog")
    check spec.n.get == 1

  test "isn't shown in help":
    let help = helpOf (n: opt[Positive]("--num=<n>", help = "Count."), h: help())
    check "Count." in help
    check "default" notin help
    check "range" notin help

  test "a default other than it is shown":
    check "Count. [default: 2]" in
      helpOf (n: opt[Positive]("--num=<n>", default = 2, help = "Count."), h: help())

  test "applies to a flag":
    let spec = (n: flag[Positive]("-n"),)
    spec.parse(args = @[], command = "prog")
    check spec.n.get == 1

suite "number and range types everywhere a value comes from":
  test "multi-value `args` and `opts`":
    let spec = (sizes: opts[uint8]("--size=<n>"), levels: args[Ten]("<level>"))
    spec.parse(args = @["--size", "1", "--size", "255", "2", "10"], command = "prog")
    check spec.sizes.get == @[1'u8, 255]
    check spec.levels.get == @[Ten(2), Ten(10)]
    check isOutOfRange[Ten]("11")

  test "an environment variable":
    putEnv("ARGUMINT_T247_SMALL", "-7")
    defer: delEnv("ARGUMINT_T247_SMALL")
    let spec = (n: opt[int8]("--num=<n>", env = "ARGUMINT_T247_SMALL"),)
    spec.parse(args = @[], command = "prog")
    check spec.n.get == -7

  test "an environment variable out of range":
    putEnv("ARGUMINT_T247_SMALL", "300")
    defer: delEnv("ARGUMINT_T247_SMALL")
    let spec = (n: opt[int8]("--num=<n>", env = "ARGUMINT_T247_SMALL"),)
    expect ParseError:
      spec.parse(args = @[], command = "prog",
                 settings = newSpecSettings(style = nil))

  test "a Config Source":
    let spec = (n: opt[Ten]("--num=<n>", configKey = "n"),)
    spec.parse(args = @[], command = "prog",
               settings = newSpecSettings(configSources = @[ConfigSource Fours()]))
    check spec.n.get == 4

suite "the string form of a flag's `ops`":
  test "names the bounds of a value out of range":
    var caught = ""
    try:
      discard flag[int](ops = "--big=99999999999999999999")
    except SpecDefect as e:
      caught = e.msg
    check caught == "unexpected flag value for --big: expected a value in " &
      $low(int) & ".." & $high(int)

suite "a `distinct` number":
  test "still needs a converter":
    check not compiles(opt("--hue=<hue>", default = Hue(1)))
