# Registering a custom Arg type from a file that imports *only* `argumint`.
#
# This is the caller's-eye view of `docs/adr/0017-argumint-reexports-for-
# custom-arg-types.md`: `defineArg`/`defineFlag`/`defineSetFlag` expand into
# this file, generating methods whose bodies call into `validators`,
# `backend`, and `std/strutils` by bare name. Every other test that
# registers a type (`tests/test_argumint.nim`) also imports the internals,
# which would mask a broken re-export -- so this file must not.
#
# Issue #51 split the templates' bodies (`argumint/argtypes`) from their
# public names (`argumint.nim`); that boundary is exactly what this file
# guards. See `docs/adr/0043-facade-machinery-seam.md`.

import std/[strutils, unittest]

import argumint

type Rank = enum
  rLow, rMid, rHigh

converter toRank(value: string): Rank = parseEnum[Rank](value)

# A caller's own helper sharing a name with argumint's internal one: the
# generated `defaultStr` must still call argumint's (`display.showValue`).
proc showValue[T](value: T): string = "decoy"

# The one-argument overload: a value type with a hand-written converter and
# no flag support at all.
defineArg Rank

type Size = enum
  small, medium, large

converter toSize(value: string): Size = parseEnum[Size](value)

# The two-argument overload: flag support, blank op left undescribed.
defineArg(Size):
  case op
  of "=": value = arg
  of "+=": value = Size(min(ord(value) + ord(arg) + 1, ord(large)))
  else: raise newException(SpecDefect, "size flags only support = and +=")

type Mood = enum
  calm, brisk, wild

converter toMood(value: string): Mood = parseEnum[Mood](value)

# `defineFlag`: same as above, plus a description for the blank op.
defineFlag(Mood, "Cycle to the next mood"):
  case op
  of "": value = Mood((ord(value) + 1) mod 3)
  of "=": value = arg
  else: raise newException(SpecDefect, "mood flags only support blank and =")

defineSetFlag(Rank)

type Point = object
  x, y: int

converter toPoint(value: string): Point =
  let parts = value.split(',')
  Point(x: parseInt(parts[0]), y: parseInt(parts[1]))

# A type with no `<=`, so no `range` validator: registering it must still
# compile (#206).
defineArg Point

suite "registering a custom type through a bare `import argumint`":
  test "the one-argument `defineArg` gives a value type its parse method":
    let spec = (rank: arg[Rank]("<rank>", help = ""), help: help())
    spec.parse(args = @["rHigh"], command = "prog")
    check spec.rank.get == rHigh

  test "both `defineArg` overloads coexist in one file":
    # The split overload set -- one arity in each of two modules before
    # issue #51, both in the facade after it -- has to resolve either way.
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

  test "a custom flag type applies its ops, declared via `flagOp`":
    let spec = (
      size: flag[Size](ops = [flagOp("-b, --bigger", "+=", small, "Bump the size")],
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

  test "an op the type never registered raises SpecDefect":
    # The `getFlagOps` read path, reached from the facade's `flagOp*`.
    expect SpecDefect:
      discard flagOp("--shrink", "-=", small)

  test "`defineFlag`'s blankDesc reaches the generated help text":
    # A blank-op variant only shows its description when it diverges from a
    # sibling, so `--wild` is here to give `-m, --mood` something to differ
    # from -- same shape as `test_argumint.nim`'s bool/int coverage.
    let spec = (
      mood: flag[Mood]("-m, --mood", ops = [flagOp("--wild", "=", wild)], default = calm, help = ""),
      help: help())
    var helpText = ""
    try:
      spec.parse(settings = newSpecSettings(maxVariantsWidth = 0), args = @["--help"], command = "prog")
    except HelpError as e:
      helpText = e.msg
    check "Cycle to the next mood" in helpText
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

  test "`defineSetFlag` registers set support for the same enum":
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
