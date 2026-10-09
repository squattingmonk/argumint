# Custom types from a file that imports *only* `argumint`.
#
# This is the caller's-eye view of `docs/adr/0017-argumint-reexports-for-
# custom-arg-types.md`: `opt` finds a value type's converter here (ADR
# 0068), and `flagOp`/`flagOpIt` build Flag Operations from this file's own
# procs and operators. Every other test of custom types
# (`tests/test_argumint.nim`) also imports the internals, which would mask a
# broken re-export -- so this file must not.
#
# Issue #51 split the machinery (`argumint/argtypes`) from its public names
# (`argumint.nim`); that boundary is exactly what this file guards. See
# `docs/adr/0043-facade-machinery-seam.md`. It also covers a hand-written
# `ref object of Arg`, which needs the same bare import.

import std/[os, osproc, strutils, unittest]

import argumint

# A value type with a hand-written converter, and a set flag below.
type Rank = enum
  rLow, rMid, rHigh

converter toRank(value: string): Rank = parseEnum[Rank](value)

# A caller's own helper sharing a name with argumint's internal one: the
# generated `defaultStr` must still call argumint's (`display.showValue`).
proc showValue[T](value: T): string = "decoy"

type Size = enum
  small, medium, large

converter toSize(value: string): Size = parseEnum[Size](value)

type Mood = enum
  calm, brisk, wild

converter toMood(value: string): Mood = parseEnum[Mood](value)

# A type with no `<=`, so no `range` validator: it must still be a value
# type (#206).
type Point = object
  x, y: int

converter toPoint(value: string): Point =
  let parts = value.split(',')
  Point(x: parseInt(parts[0]), y: parseInt(parts[1]))

suite "registering a custom type through a bare `import argumint`":
  test "a value type's converter parses it with no registration":
    let spec = (rank: arg[Rank]("<rank>", help = ""), help: help())
    spec.parse(args = @["rHigh"], command = "prog")
    check spec.rank.get == rHigh

  test "a value type and a flag type parse side by side":
    let spec = (
      rank: arg[Rank]("<rank>", help = ""),
      size: opt[Size]("--size=<s>", default = small, help = ""),
      help: help())
    spec.parse(args = @["rMid", "--size", "large"], command = "prog")
    check spec.rank.get == rMid
    check spec.size.get == large

  test "the implicit converter still fires without an explicit `get`":
    let spec = (name: arg("<name>", help = ""), rank: arg[Rank]("<rank>", help = ""), help: help())
    spec.parse(args = @["ada", "rLow"], command = "prog")
    let
      name: string = spec.name
      rank: Rank = spec.rank
    check name == "ada"
    check rank == rLow

  test "a custom flag type applies a proc, declared via `flagOpIt`":
    let spec = (
      size: flag[Size](ops = [flagOpIt[Size]("-b, --bigger", (if it < large: succ(it) else: it),
                                             "Bump the size")],
        default = small, help = ""),
      help: help())
    spec.parse(args = @["--bigger"], command = "prog")
    check spec.size.get == medium

  test "a custom flag type applies its ops, declared via the `ops: string` sugar":
    # `parseFlagOpsString` moved to `argumint/argtypes` with the rest of the
    # machinery; `flag*`'s string overload in the facade instantiates it.
    let spec = (size: flag[Size](ops = "--huge=large", default = small, help = ""), help: help())
    spec.parse(args = @["--huge"], command = "prog")
    check spec.size.get == large

  test "an op the type can't do doesn't compile":
    check not compiles(flagOp("--shrink", "-=", small))

  test "an enum's Implicit Operation reaches the generated help text":
    # A bare variant only shows its description when it diverges from a
    # sibling, so `--wild` is here to give `-m, --mood` something to differ
    # from -- same shape as `test_argumint.nim`'s bool/int coverage.
    let spec = (
      mood: flag[Mood]("-m, --mood", ops = [flagOp("--wild", "=", wild)], default = calm, help = ""),
      help: help())
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0, style = nil), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Move to the next value" in helpText
    check "Set to wild" in helpText

  test "a caller's same-named helper doesn't replace the default's rendering":
    let spec = (rank: opt("--rank=<r>", default = rHigh, help = "Rank"),
                help: help())
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "app",
                 settings = newSpecSettings(style = nil))
    except HelpError as e:
      helpText = e.msg
    check "Rank [default: rHigh]" in helpText
    check showValue(1) == "decoy" # the decoy is really in scope here

  test "a set of the same enum is a flag type with no registration":
    let spec = (
      ranks: flag[set[Rank]](ops = [flagOp("--mid", "+=", {rMid}), flagOp("--high", "+=", {rHigh})],
        default = {}, help = ""),
      help: help())
    spec.parse(args = @["--mid", "--high"], command = "prog")
    check spec.ranks.get == {rMid, rHigh}

  test "a type with no `<=` is a value type, and shows its default":
    let spec = (at: opt("--at=<point>", default = Point(x: 1, y: 2), help = "Where"),
                help: help())
    spec.parse(args = @["--at", "3,4"], command = "prog")
    check spec.at.get == Point(x: 3, y: 4)
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog",
                 settings = newSpecSettings(style = nil))
    except HelpError as e:
      helpText = e.msg
    check "Where [default: (x: 1, y: 2)]" in helpText

  test "a type with no `<=` takes every other validator":
    let spec = (at: opt("--at=<point>", default = Point(x: 1, y: 2), help = "",
                        validator = any(choice([Point(x: 0, y: 0)]),
                                        checkIt[Point](it.x == it.y, "on the diagonal"))),
                help: help())
    spec.parse(args = @["--at", "5,5"], command = "prog")
    check spec.at.get == Point(x: 5, y: 5)
    expect ValidationError:
      spec.parse(args = @["--at", "1,2"], command = "prog")

# A custom Arg describing the values it takes in help, the way a validator
# does (#209).
type PortArg = ref object of Arg
  port: int

method accept(self: PortArg, c: Contribution, how: Arbitration) =
  self.port = parseInt(c.value)

method clear(self: PortArg) =
  procCall clear(Arg(self))
  self.port = 0

method validatorHelp(self: PortArg): StyledText =
  styled("(1-") & styled(srLiteral, "65535") & styled(")")

suite "a custom Arg through a bare `import argumint`":
  test "can describe its values in help with `validatorHelp`":
    let spec = (
      port: PortArg(kind: Optional, variants: @["--port=<n>"], help: "Port",
                    group: "Options"),
      help: help(),
    )
    var helpText = ""
    try:
      spec.parse(args = @["--help"], command = "prog",
                 settings = newSpecSettings(style = nil))
    except HelpError as e:
      helpText = e.msg
    check "--port=<n>  Port [(1-65535)]" in helpText

type Unconvertible = distinct int

proc checkErrors(code: string): string =
  ## What `nim check` says about `code`, after a prelude declaring `Hue`, a
  ## type with no converter.
  let
    dir = getTempDir() / "argumint_t167_" & $getCurrentProcessId()
    src = dir / "snippet.nim"
  createDir(dir)
  defer: removeDir(dir)
  writeFile(src, "import std/strutils\nimport argumint\ntype Hue = distinct int\n" & code)
  let src2 = currentSourcePath().parentDir.parentDir / "src"
  execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "check", "--hints:off",
    "--path:" & src2, src])).output

suite "a type with no converter from string (#167, #213)":
  test "doesn't compile in `arg`, `args`, `opt` or `opts`":
    check not compiles(arg("<unconv>", default = Unconvertible(1)))
    check not compiles(args[Unconvertible]("<unconv>"))
    check not compiles(opt("--unconv=<unconv>", default = Unconvertible(1)))
    check not compiles(opts[Unconvertible]("--unconv=<unconv>"))

  test "an alias of a value type is the same type":
    type
      Port = int
      RankAlias = Rank
    let spec = (port: opt[Port]("--port=<n>"), rank: opt[RankAlias]("--rank=<r>"))
    spec.parse(args = @["--port", "80", "--rank", "rMid"], command = "prog")
    check spec.port.get == 80
    check spec.rank.get == rMid

  test "the compile error names the converter to define":
    check "Hue is not a value type: define `converter toHue(value: string): Hue` where its Arg is built" in
      checkErrors("let a = opt(\"--hue=<hue>\", default = Hue(1))\n")

  test "the converter has to come before the Arg is built":
    check "Hue is not a value type" in checkErrors(
      "let a = opt(\"--hue=<hue>\", default = Hue(1))\n" &
      "converter toHue(s: string): Hue = Hue(parseInt(s))\n")

  test "every built-in value type still works directly":
    let spec = (
      n: arg[int]("<num>"),
      f: opt[float]("--fl=<num>"),
      g: opt[float64]("--fl64=<num>"),
      b: opt[bool]("--yes=<bool>"),
      c: args[char]("<chr>"),
      s: opts[string]("--str=<str>"),
    )
    spec.parse(args = @["3", "x", "y", "--fl", "1.5", "--fl64", "2.5", "--yes", "true", "--str", "a"],
               command = "prog")
    check spec.n.get == 3
    check spec.f.get == 1.5
    check spec.g.get == 2.5
    check spec.b.get == true
    check spec.c.get == @['x', 'y']
    check spec.s.get == @["a"]
