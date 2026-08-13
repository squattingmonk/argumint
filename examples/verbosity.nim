# This example demonstrates flag operations (`=`, `+=`, `-=`). A single
# `verbosity` field is driven by several *different* flag names: `-v`/
# `--verbose` fall back to the default int-flag behavior (increment by 1
# each time they're seen), while `--quiet`/`--boost`/`--dampen` each
# declare their own explicit Flag Operation via `ops`'s comma-separated
# string convenience form -- e.g. `--quiet=0` means the flag the user
# types is `--quiet`, and matching it always resets the value to 0. The
# op/value are spec metadata, never something the user types on the
# command line -- see `docs/adr/0028-flag-ops-string-convenience.md` for
# when the array-of-`flagOp` form is needed instead (a multi-spelling
# group, or a value with no string spelling).
#
# `clamp = clamp(0..10)` pins the resulting value to 0..10 no matter how
# many times `--boost`/`--verbose` are repeated -- silently, not by raising
# an error -- so code reading `spec.verbosity` never has to re-check its
# bounds. `desc = some("")` suppresses clamp's own `[clamp: 0..10]` help
# annotation, which would otherwise repeat identically on every variant's
# row alongside each row's own `[action: ...]` (see issue #12).

import std/strformat

import argumint

let
  spec = (
    verbosity: flag("-v, --verbose", default = 0, help = "Adjust verbosity",
      ops = "--quiet=0, --boost+=5, --dampen-=2",
      clamp = clamp(0..10, desc = some(""))
    ),
    help: help()
  )

spec.parseOrQuit(usage = "[-v | --verbose | --quiet | --boost | --dampen]...", prolog = "Adjustable verbosity demo")
echo fmt"Verbosity: {spec.verbosity}"
