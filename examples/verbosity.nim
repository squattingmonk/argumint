# This example demonstrates flag operations (`=`, `+=`, `-=`). A single
# `verbosity` field is driven by several *different* flag names, each baking
# in its own op+value at spec-construction time -- e.g. the variant string
# `--quiet=0` means the flag the user types is `--quiet`, and matching it
# always resets the value to 0. The `<op><value>` suffix is spec metadata,
# never something the user types on the command line.
#
# `-v`/`--verbose` (no op) fall back to the default int-flag behavior:
# increment by 1 each time they're seen. `--boost+=5`/`--dampen-=2` jump by a
# fixed amount, and `--quiet=0` resets outright.

import std/strformat

import argumint

let
  spec = (
    verbosity: flag[int](
      "-v, --verbose, --quiet=0, --boost+=5, --dampen-=2",
      default = 0, help = "Adjust verbosity"
    ),
    help: help()
  )

spec.parseOrQuit(usage = "[-v | --verbose | --quiet | --boost | --dampen]...", prolog = "Adjustable verbosity demo")
echo fmt"Verbosity: {spec.verbosity}"
