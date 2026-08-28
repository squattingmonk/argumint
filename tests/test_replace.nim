# Tests for `replace` -- the typed one-call replace for a multi-valued
# ValueArg (#56). Unlike `put`, which appends onto a multi Arg, `replace`
# overwrites the whole value seq in one call; unlike `parse`/`put`, it
# never arbitrates against the Arg's current tier, so it can demote. See
# `tests/test_put.nim` for the typed-write-accessor coverage this mirrors.
#
# Imports `argumint` alone on purpose, matching `test_put.nim`/
# `test_write_side.nim` -- reaching the write side must not require a
# backend import.

import std/[options, unittest]

import argumint

suite "replace overwrites a multi ValueArg's values in one call":
  test "replace on an unsupplied Arg stores exactly the given values":
    let tags = opts("--tag=<t>", help = "")
    tags.replace(@["a", "b"], seenBy = some(byCli))
    check tags.get == @["a", "b"]
    check tags.seenBy == byCli

  test "replace overwrites values a prior put/parse appended, not just adds to them":
    let tags = opts("--tag=<t>", help = "")
    tags.put("old", seenBy = some(byCli))
    tags.replace(@["x", "y"], seenBy = some(byCli))
    check tags.get == @["x", "y"]

  test "replace with an empty seq clears the values while keeping the Arg readable":
    let tags = opts("--tag=<t>", help = "")
    tags.put("old", seenBy = some(byCli))
    tags.replace(newSeq[string](), seenBy = some(byCli))
    check tags.get == newSeq[string]()
    check tags.seen

suite "replace never arbitrates -- it may demote, unlike put/parse":
  test "replace at a weaker tier than the Arg's current one still applies":
    let tags = opts("--tag=<t>", help = "")
    tags.put("a", seenBy = some(byCli))
    tags.replace(@["b"], seenBy = some(byConfig))
    check tags.get == @["b"]
    check tags.seenBy == byConfig

  test "replace at an equal tier overwrites rather than appending":
    let tags = opts("--tag=<t>", help = "")
    tags.put("a", seenBy = some(byCli))
    tags.replace(@["b", "c"], seenBy = some(byCli))
    check tags.get == @["b", "c"]

  test "a tier-less replace keeps the Arg's existing provenance but stores the new values":
    let tags = opts("--tag=<t>", help = "")
    tags.put("a", seenBy = some(byCli))
    tags.replace(@["b", "c"])
    check tags.get == @["b", "c"]
    check tags.seenBy == byCli

  test "a tier-less replace on a never-supplied Arg leaves seenBy at byNone but is still readable":
    let tags = opts("--tag=<t>", help = "")
    tags.replace(@["x"])
    check tags.seenBy == byNone
    check tags.get == @["x"]
    check tags.get(otherwise = @["z"]) == @["x"]

suite "replace validates by default, against the new batch's own history":
  test "a batch with no duplicates among itself passes a unique Validator even if it repeats an old value":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.put("a", seenBy = some(byCli))
    tags.replace(@["a", "b"], seenBy = some(byCli))
    check tags.get == @["a", "b"]

  test "a batch with an internal duplicate is rejected by a unique Validator":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    expect ValidationError:
      tags.replace(@["a", "a"], seenBy = some(byCli))

  test "validate = false stores a batch a Validator would otherwise reject":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.replace(@["a", "a"], seenBy = some(byCli), validate = false)
    check tags.get == @["a", "a"]

suite "a rejected replace leaves the Arg exactly as it was":
  test "a failure at the first value leaves the prior values and provenance untouched":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.put("old", seenBy = some(byCli))
    expect ValidationError:
      tags.replace(@["a", "a", "b"], seenBy = some(byConfig))
    check tags.get == @["old"]
    check tags.seenBy == byCli

  test "a failure partway through the batch leaves the prior values and provenance untouched":
    let tags = opts("--tag=<t>", validator = unique[string](), help = "")
    tags.put("old", seenBy = some(byCli))
    expect ValidationError:
      tags.replace(@["x", "y", "y"], seenBy = some(byConfig))
    check tags.get == @["old"]
    check tags.seenBy == byCli

  test "a failure on a never-supplied Arg leaves it unsupplied":
    let tags = opts("--tag=<t>", default = @["d"], validator = unique[string](), help = "")
    expect ValidationError:
      tags.replace(@["a", "a"], seenBy = some(byCli))
    check not tags.seen
    check tags.get == @["d"]
