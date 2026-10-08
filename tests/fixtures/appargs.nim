## House-style Arg factories in their own module, for
## tests/test_arg_factories.nim: `ValueArg[int]` and `ValuesArg[int]` named in
## signatures on both sides of a module boundary.

import argumint

proc portOpt*(variants: string): ValueArg[int] =
  opt[int](variants, default = 80, group = "App")

proc portsOpt*(variants: string): ValuesArg[int] =
  opts[int](variants, group = "App")

proc total*(port: ValueArg[int], extra: ValuesArg[int]): int =
  ## Reads both Args after the caller has parsed them.
  result = port.get
  for p in extra.get: result += p
