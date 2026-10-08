## A distinct type whose converter lives in its own module, for
## tests/test_value_types.nim. It sits in a subdirectory so the test runner
## doesn't build it alone.

import std/strutils

type Meters* = distinct int

proc `==`*(a, b: Meters): bool {.borrow.}
proc `$`*(m: Meters): string = $int(m) & "m"

converter toMeters*(value: string): Meters =
  Meters(parseInt(value.strip(chars = {'m'}, leading = false)))
