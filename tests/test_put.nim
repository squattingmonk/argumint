# Tests for `put` -- the typed write surface (#29): `parse` minus the
# string conversion. Arbitrates identically to `parse` (see
# `tests/test_write_side.nim` for the exhaustive tier-table coverage on
# `parse`); this file focuses on what's different about `put`: no
# conversion, a `validate` opt-out at every arity, and the `FlagArg`
# overload's narrower signature.
#
# Imports `argumint` alone on purpose, matching `test_write_side.nim` --
# reaching the write side must not require a backend import.

import std/[options, unittest]

import argumint

suite "put is reachable from the facade and replaces/appends without converting":
  test "put on a scalar ValueArg replaces its one slot":
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(77, seenBy = some(byCli))
    check port.get == 77
    port.put(99, seenBy = some(byCli))
    check port.get == 99

  test "put on a multi ValueArg appends":
    let tags = opts("--tag=<t>", help = "")
    tags.put("a", seenBy = some(byCli))
    tags.put("b", seenBy = some(byCli))
    check tags.get == @["a", "b"]

  test "put never raises ParseError, even for a value no string could convert to":
    # There's no conversion step to fail -- put takes a T directly. This is
    # trivially true for `int`, so the point is the absence of the
    # try/except ValueError wrapping parseImpl has; nothing to assert beyond
    # "it doesn't raise".
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(-1, seenBy = some(byCli))
    check port.get == -1

suite "put arbitrates identically to parse":
  test "a stronger declared tier clears first, then applies":
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(77, seenBy = some(byEnv))
    port.put(99, seenBy = some(byCli))
    check port.get == 99
    check port.seenBy == byCli

  test "an equal declared tier applies without clearing":
    let tags = opts("--tag=<t>", help = "")
    tags.put("a", seenBy = some(byEnv))
    tags.put("b", seenBy = some(byEnv))
    check tags.get == @["a", "b"]
    check tags.seenBy == byEnv

  test "a weaker declared tier is refused and the Arg is unchanged":
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(77, seenBy = some(byCli))
    port.put(99, seenBy = some(byConfig))
    check port.get == 77
    check port.seenBy == byCli

suite "put validates by default, with an opt-out at every arity":
  test "a scalar ValueArg raises ValidationError for a value its Validator rejects, and leaves the Arg unchanged":
    let port = opt("--port=<n>", default = 80, validator = range(1..10), help = "")
    expect ValidationError:
      port.put(99, seenBy = some(byCli))
    check not port.seen
    check port.get == 80 # unwritten -- still the coded default

  test "a rejected put leaves a weaker tier's existing value and provenance intact":
    let port = opt("--port=<n>", default = 80, validator = range(1..10), help = "")
    port.put(5, seenBy = some(byConfig))
    expect ValidationError:
      port.put(99, seenBy = some(byCli))
    check port.get == 5
    check port.seenBy == byConfig

  test "a multi ValueArg raises ValidationError for a value its Validator rejects, and leaves the Arg unchanged":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.put("a", seenBy = some(byCli))
    expect ValidationError:
      tags.put("a", seenBy = some(byCli))
    check tags.get == @["a"]
    check tags.seenBy == byCli

  test "validate = false stores a rejected value on a scalar ValueArg without raising":
    let port = opt("--port=<n>", default = 80, validator = range(1..10), help = "")
    port.put(99, seenBy = some(byCli), validate = false)
    check port.get == 99

  test "validate = false stores a rejected value on a multi ValueArg without raising":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.put("a", seenBy = some(byCli))
    tags.put("a", seenBy = some(byCli), validate = false)
    check tags.get == @["a", "a"]

suite "FlagArg.put always clamps, never validates":
  test "put stores a clamp-coerced value":
    let level = flag[int](ops = [flagOp("-l", "+=", 1)], default = 0,
                          clamp = clamp(0..2), help = "")
    level.put(5, seenBy = some(byCli))
    check level.get == 2

  test "put never raises for an out-of-clamp value":
    let level = flag[int](ops = [flagOp("-l", "+=", 1)], default = 0,
                          clamp = clamp(0..2), help = "")
    level.put(-5, seenBy = some(byCli))
    check level.get == 0

suite "ValueArg's read accessors test the stored value, not seen":
  test "a tier-less put is visible via get and get(otherwise), though seenBy stays byNone":
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(77)
    check port.seenBy == byNone
    check not port.seen
    check port.get == 77
    check port.get(otherwise = 1) == 77

  test "a tier-less multi put is visible via get and get(otherwise)":
    let tags = opts("--tag=<t>", help = "")
    tags.put("x")
    check tags.seenBy == byNone
    check not tags.seen
    check tags.get == @["x"]
    check tags.get(otherwise = @["z"]) == @["x"]

  test "get(otherwise) still returns otherwise when the value seq is empty, even with seenBy != byNone":
    # The Config Source `some(@[])` residue: a source can declare a tier
    # without ever storing a value (see backend's arbitrate -- the apply
    # branch that resolves nothing must not stamp provenance either, but
    # this pins the *reader*'s side of that invariant regardless of how the
    # empty-but-seen state was reached).
    let port = opt("--port=<n>", default = 80, help = "")
    port.seenBy = byConfig # a tier declared with nothing ever stored
    check port.get(otherwise = 1234) == 1234

  test "seen/seenBy themselves are unchanged: a tier-less write still leaves seenBy byNone":
    let port = opt("--port=<n>", default = 80, help = "")
    port.put(77)
    check port.seenBy == byNone
    check not port.seen

  test "a multi ValueArg explicitly marked Seen with nothing stored reads as its own empty seq, not otherwise":
    # Unlike the scalar case above, "Seen with nothing stored" is a
    # renderable state for a multi Arg -- @[] -- so it's distinguished from
    # "never touched" instead of falling back. There's no write call that
    # produces this today (`put`/`parse` always append at least one value
    # once a tier is declared); it's reached by claiming the tier directly,
    # the same way `ConfigSource`/env resolution would if a tier ever
    # legitimately supplied zero values for a multi Arg.
    let tags = opts("--tag=<t>", default = @["x"], help = "")
    tags.seenBy = byCli
    check tags.seen
    check tags.get == newSeq[string]()
    check tags.get(otherwise = @["z"]) == newSeq[string]()

suite "FlagArg's read accessors also see a tier-less write that changes the value":
  test "a tier-less put is visible via get(otherwise) once it moves the value off the default":
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 0, help = "")
    verbose.put(3)
    check not verbose.seen
    check verbose.get == 3
    check verbose.get(otherwise = 1) == 3

  test "a tier-less put is still invisible to get(otherwise) when it happens to equal the default":
    # The residue ADR 0044 documents: a Flag has no representable "nothing
    # here" state, so a written value indistinguishable from the untouched
    # default reads as untouched too. Declare a tier if that distinction
    # matters.
    let verbose = flag[int](ops = [flagOp("-v", "+=", 1)], default = 3, help = "")
    verbose.put(3)
    check not verbose.seen
    check verbose.get == 3
    check verbose.get(otherwise = 99) == 99

suite "put does not disturb parse's own conversion-failure behavior":
  test "a bad string passed to parse still raises ParseError, not a raw ValueError":
    # Regression guard for the try-expression trap: the string -> T
    # conversion has to happen *inside* putImpl's try, or the converter's
    # ValueError escapes uncaught instead of becoming a ParseError. See
    # docs/gotchas.md.
    let port = opt("--port=<n>", default = 80, help = "")
    expect ParseError:
      port.parse("notanumber", seenBy = some(byCli))
