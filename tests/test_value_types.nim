# What makes a type a Value Type (#213): an enum, or a type with a converter
# from string in scope where its Arg is built -- no registration. Imports
# only `argumint`, like `test_custom_types.nim`, so a conversion that only
# works because some internal module is in scope fails here.

import std/[options, os, strutils, unittest]

import argumint
import fixtures/units

type
  Color = enum
    red, green, darkBlue = "dark-blue"
  Level = enum
    ## Not consecutive: listed with `std/enumutils`.
    low = 1, high = 5
  Shape = enum
    circle, square

converter toShape(value: string): Shape =
  ## Shape's own converter: `round` is a circle, anything else a square.
  if value == "round": circle else: square

proc helpOf(spec: tuple): string =
  try:
    spec.parse(args = @["--help"], command = "prog",
               settings = newSpecSettings(style = nil, maxVariantsWidth = 0))
  except HelpError as e:
    result = e.msg

proc wire(spec: tuple, words: varargs[string]): seq[string] =
  ## `__complete`'s output for `words`, one line each -- the candidates
  ## (with no help after the tab), then the directive.
  try:
    spec.parse(args = @["__complete"] & @words, command = "prog")
  except CompletionError as e:
    return e.msg.splitLines

proc parseError(spec: tuple, args: seq[string]): string =
  ## The first line of the error parsing `args` raises.
  try:
    spec.parse(args = args, command = "prog",
               settings = newSpecSettings(style = nil))
  except ParseError as e:
    result = e.msg.splitLines[0]

type Tags = ref object of ConfigSource

method lookup(self: Tags, key: ConfigKey): Option[seq[string]] =
  if key == configKey("color"): some(@["dark-blue"]) else: none(seq[string])

suite "an enum with no converter":
  test "parses by name":
    let spec = (color: opt("-c, --color=<color>", default = green),)
    spec.parse(args = @["--color", "red"], command = "prog")
    check spec.color.get == red

  test "matches a value's own string, not its identifier":
    let spec = (color: opt("--color=<color>", default = green),)
    spec.parse(args = @["--color", "dark-blue"], command = "prog")
    check spec.color.get == darkBlue
    check "--color" in spec.parseError(@["--color", "darkBlue"])

  test "ignores case after the first letter, and underscores":
    let spec = (color: opt("--color=<color>", default = green),)
    spec.parse(args = @["--color", "rED"], command = "prog")
    check spec.color.get == red
    spec.parse(args = @["--color", "g_r_een"], command = "prog")
    check spec.color.get == green
    check "--color" in spec.parseError(@["--color", "Red"])

  test "lists its values in a bad value's error":
    let spec = (color: opt("--color=<color>", default = green),)
    check spec.parseError(@["--color", "purple"]) ==
      "  - for --color, got \"purple\" but expected one of red, green, dark-blue"

  test "lists its values in help":
    let spec = (color: opt("--color=<color>", default = green, help = "Colour"),
                help: help())
    check "Colour [choices: red, green, dark-blue; default: green]" in spec.helpOf

  test "offers its values to completion, and no paths":
    let spec = (color: opt("--color=<color>", default = green),)
    check spec.wire("--color", "") == @["red\t", "green\t", "dark-blue\t", ":"]

  test "with gaps in its values still lists every one":
    let spec = (level: opt("--level=<level>", default = low, help = "Level"),
                help: help())
    check "[choices: low, high]" in spec.helpOf
    spec.parse(args = @["--level", "high"], command = "prog")
    check spec.level.get == high

  test "with gaps and no default holds its first value":
    let spec = (level: opt[Level]("--level=<level>"), color: opt[Color]("--color=<c>"))
    spec.parse(args = @[], command = "prog")
    check spec.level.get == low
    check spec.color.get == red

  test "works in multi-value `args` and `opts`":
    let spec = (colors: args[Color]("<color>"), levels: opts[Level]("--level=<l>"))
    spec.parse(args = @["--level", "high", "red", "dark-blue"], command = "prog")
    check spec.colors.get == @[red, darkBlue]
    check spec.levels.get == @[high]

  test "takes a value from an environment variable":
    putEnv("ARGUMINT_T213_COLOR", "dark-blue")
    defer: delEnv("ARGUMINT_T213_COLOR")
    let spec = (color: opt("--color=<color>", default = green, env = "ARGUMINT_T213_COLOR"),)
    spec.parse(args = @[], command = "prog")
    check spec.color.get == darkBlue

  test "takes a value from a Config Source":
    let spec = (color: opt("--color=<color>", default = green, configKey = "color"),)
    spec.parse(args = @[], command = "prog",
               settings = newSpecSettings(configSources = @[ConfigSource Tags()]))
    check spec.color.get == darkBlue

  test "clears back to its default":
    let spec = (color: opt("--color=<color>", default = green),
                colors: opts[Color]("--colors=<c>"))
    spec.parse(args = @["--color", "red", "--colors", "red"], command = "prog")
    spec.color.clear
    spec.colors.clear
    check spec.color.get == green
    check spec.colors.get.len == 0

suite "an enum's automatic list beside a validator":
  test "a validator that lists values replaces it":
    let spec = (color: opt("--color=<color>", default = green, help = "Colour",
                           validator = choice([red, green])),
                help: help())
    check "[choices: red, green;" in spec.helpOf
    check spec.wire("--color", "") == @["red\t", "green\t", ":"]
    check spec.parseError(@["--color", "purple"]) ==
      "  - for --color, got \"purple\" but expected one of red, green"

  test "one that doesn't list values leaves it in place":
    let spec = (color: opt("--color=<color>", default = green, help = "Colour",
                           validator = checkIt[Color](it != red, "not red")),
                help: help())
    check "[choices: red, green, dark-blue and not red;" in spec.helpOf
    check spec.wire("--color", "") == @["green\t", "dark-blue\t", ":"]

  test "one with nothing to say leaves it alone":
    let spec = (color: opt("--color=<color>", default = green, help = "Colour",
                           validator = check[Color](proc (c: Color): bool = c != red)),
                help: help())
    check "[choices: red, green, dark-blue;" in spec.helpOf
    check spec.wire("--color", "") == @["green\t", "dark-blue\t", ":"]

suite "an enum with its own converter":
  test "accepts what its converter does":
    let spec = (shape: opt("--shape=<shape>", default = square),)
    spec.parse(args = @["--shape", "round"], command = "prog")
    check spec.shape.get == circle
    spec.parse(args = @["--shape", "circle"], command = "prog")
    check spec.shape.get == square

  test "lists no values in help or completion":
    let spec = (shape: opt("--shape=<shape>", default = square, help = "Shape"),
                help: help())
    check "choices" notin spec.helpOf
    check spec.wire("--shape", "") == @[":files"]

suite "a type with a converter":
  test "defined in another module parses with no registration":
    let spec = (len: opt("--len=<n>", default = Meters(1)),)
    spec.parse(args = @["--len", "12m"], command = "prog")
    check spec.len.get == Meters(12)

  test "a built-in type built from this module parses":
    # argumint's own conversions aren't converters in scope here: see
    # docs/gotchas.md.
    let spec = (n: opt("-n=<n>", default = 1), f: opt("-f=<f>", default = 1.0),
                b: opt("-b=<b>", default = false), c: opt("-c=<c>", default = 'x'))
    spec.parse(args = @["-n", " 5", "-f", "2.5", "-b", "yes", "-c", "y"], command = "prog")
    check spec.n.get == 5
    check spec.f.get == 2.5
    check spec.b.get
    check spec.c.get == 'y'

suite "a set flag":
  test "converts each element in the string form of `ops`":
    let spec = (colors: flag[set[Color]](ops = "--warm+=red, --cool+=dark-blue", default = {}),)
    spec.parse(args = @["--warm", "--cool"], command = "prog")
    check spec.colors.get == {red, darkBlue}
