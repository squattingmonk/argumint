# A generic wrapper around `opt`, called from a module that doesn't import
# argumint itself (#167). The check that `T` is a value type runs where the
# wrapper is instantiated, which is here.

import std/unittest

import fixtures/optwrapper

suite "a value type through another library's generic":
  test "built-in types still work":
    check parseOpt(1, @["--val", "3"]) == 3
    check parseOpt(1.0, @["--val", "2.5"]) == 2.5
    check parseOpt("a", @["--val", "b"]) == "b"

  test "a type the library registered works":
    check parseOpt(sLight, @["--val", "sDark"]) == sDark

  test "a type nobody registered is still rejected":
    check not compiles(parseOpt(3'i8, @[]))
