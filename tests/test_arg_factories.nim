# `ValueArg[T]` and `ValuesArg[T]` cross a module boundary both ways: built
# by another module's factories, parsed here, and read back there.

import std/unittest

import argumint
import fixtures/appargs

suite "Arg factories in another module":
  test "build Args this module parses and that module reads":
    let spec = (port: portOpt("--port=<n>"), extra: portsOpt("--extra=<n>"))
    spec.parse(usage = "[options]", args = @["--port", "8000", "--extra", "1",
               "--extra", "2"], command = "prog")
    check spec.port.get == 8000
    check spec.extra.get == @[1, 2]
    check total(spec.port, spec.extra) == 8003

  test "a typed variable here holds what they return":
    let port: ValueArg[int] = portOpt("--port=<n>")
    let extra: ValuesArg[int] = portsOpt("--extra=<n>")
    check port.get == 80
    check extra.get.len == 0
