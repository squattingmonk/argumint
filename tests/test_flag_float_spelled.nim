# Float flags under every spelling of `float` (#212), leading with
# `flag[float]`. Keep this order; test_flag_float_inferred.nim pins the
# other. See docs/gotchas.md on `$T`.

import std/unittest

import argumint

type Meters = float

suite "float flags, spelled first":
  test "every spelling of float finds float's Flag Operations":
    let spec = (
      a: flag[float](ops = "--up+=1.5"),
      b: flag[float64](ops = "--down-=2"),
      c: flag[float](ops = @[flagOp("--set", "=", 9.0)]),
      d: flag[Meters](ops = "--mm+=1"),
      speed: flag(default = 1.0, ops = "--fast=2.0"),
    )
    spec.parse(usage = "[--fast] [--up]... [--down] [--set] [--mm]",
      args = @["--fast", "--up", "--up", "--down", "--set", "--mm"], command = "prog")
    check spec.speed == 2.0
    check spec.a == 3.0
    check spec.b == -2.0
    check spec.c == 9.0
    check spec.d == 1.0
