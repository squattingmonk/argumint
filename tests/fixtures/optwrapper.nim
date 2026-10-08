## A library that wraps `opt` in a generic of its own, for
## tests/test_value_type_wrapper.nim. It sits in a subdirectory so the test
## runner doesn't build it alone.

import std/strutils

import argumint

type
  Shade* = enum
    sLight, sDark
  Grade* = distinct int

proc `==`*(a, b: Grade): bool {.borrow.}
proc `$`*(g: Grade): string = "grade " & $int(g)

# Exported: a generic's converter is looked up where the generic is
# instantiated, which for `parseOpt` is the caller's module.
converter toGrade*(value: string): Grade = Grade(parseInt(value))

proc parseOpt*[T](default: T, args: seq[string]): T =
  ## Parses `args` against a single `--val=<val>` option of type `T`.
  let spec = (val: opt("--val=<val>", default = default),)
  spec.parse(args = args, command = "prog")
  spec.val.get
