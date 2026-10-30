# Validator messages as a program importing nothing but `argumint` sees
# them. Not a guard against caller-scope symbol binding (docs/gotchas.md):
# the library instantiates these generics first, so a regression there
# breaks its own build. Keep the imports this bare all the same.

import std/unittest

import argumint

suite "validator messages after a bare `import argumint`":
  test "a failed choice lists its quoted choices":
    var caught = ""
    try:
      choice(["date", "café au lait"]).validate("size")
    except ValidationError as e:
      caught = e.msg
    check caught == "got \"size\" but expected one of \"date\", \"café au lait\""
    check choice(['a', 'b']).help() == "choices: \"a\", \"b\""

  test "a failed range shows its bounds":
    var caught = ""
    try:
      range(1..10).validate(99)
    except ValidationError as e:
      caught = e.msg
    check caught == "got 99 but expected a value in 1..10"
    check range(1..10).help() == "range: 1..10"
