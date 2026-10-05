# Float flags under every spelling of `float` (#212), leading with an
# inferred `1.0` (a `float64`). Keep this order;
# test_flag_float_spelled.nim pins the other. See docs/gotchas.md on `$T`.

import std/unittest

import argumint

type Meters = float

suite "float flags, inferred first":
  test "every spelling of float finds float's Flag Operations":
    let spec = (
      speed: flag(default = 1.0, ops = "--fast=2.0"),
      a: flag[float](ops = "--up+=1.5"),
      b: flag[float64](ops = "--down-=2"),
      c: flag[float](ops = @[flagOp("--set", "=", 9.0)]),
      d: flag[Meters](ops = "--mm+=1"),
    )
    spec.parse(usage = "[--fast] [--up]... [--down] [--set] [--mm]",
      args = @["--fast", "--up", "--up", "--down", "--set", "--mm"], command = "prog")
    check spec.speed == 2.0
    check spec.a == 3.0
    check spec.b == -2.0
    check spec.c == 9.0
    check spec.d == 1.0
