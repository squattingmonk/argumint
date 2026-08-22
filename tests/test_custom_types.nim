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

  test "`defineSetFlag` registers set support for the same enum":
    let spec = (
      ranks: flag[set[Rank]](ops = [flagOp("--mid", "+=", {rMid}), flagOp("--high", "+=", {rHigh})],
        default = {}, help = ""),
      help: help())
    spec.parse(args = @["--mid", "--high"], command = "prog")
    check spec.ranks.get == {rMid, rHigh}
