## A generic proc that walks a Spec Tuple with `eachArg`, for
## tests/test_each_arg.nim. It imports only `argumint`, and names its loop
## variables `name` and `arg`, like argumint's own procs.

import argumint

proc seenValues*(spec: tuple): seq[string] =
  ## `name=value` for each Arg the command line gave a value.
  spec.eachArg(name, arg):
    when arg is ValuesArg:
      if arg.seen:
        for value in arg.get:
          result.add name & "=" & $value
    elif arg is ValueArg or arg is FlagArg:
      if arg.seen:
        result.add name & "=" & $arg.get
