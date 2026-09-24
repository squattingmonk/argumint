# The `newSpecSettings` defaults overridden at compile time. The defines are
# set in `test_compile_defines.nims`, which applies to this file only -- see
# `docs/adr/0053-compile-time-defaults.md`.

import std/unittest

import argumint
import argumint/backend

suite "defaults set with -d: defines":
  test "each define replaces its constant":
    check DefaultWidth == 72
    check DefaultMaxWidth == 90
    check DefaultMaxVariantsWidth == 40
    check DefaultEnvDelim == ","
    check not DefaultStrictOptions

  test "newSpecSettings picks them up":
    let settings = newSpecSettings()
    check settings.maxVariantsWidth == 40
    check settings.envDelim == ","
    check not settings.strictOptions
    check settings.width <= 90

  test "with nothing detected, the width falls back to the defined DefaultWidth":
    check chooseWidth("", 0) == 72
