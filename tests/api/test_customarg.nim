# Pins for what `import argumint/customarg` alone reaches (ADR 0090). An Arg
# can't be named or built without `import argumint`, so `paramType` reads
# the types off `initArg` and `action`, and `probe` is compiled, not run;
# docs/guide/custom-types.md and tests/test_customarg.nim write a whole
# Custom Arg with both imports.

import std/[macros, options, unittest]

import argumint/customarg

macro paramType(p: typed, i: static int): untyped =
  ## The type of proc `p`'s `i`th parameter, which may have no name here.
  p.getTypeImpl[0][i + 1][1]

type
  CustomArg = paramType(initArg, 0)
  Kind = paramType(initArg, 1)
  Info = paramType(action, 1)

proc probe(arg: CustomArg, info: Info): string =
  # pins: argumint/customarg.initArg,Arg,ArgKind,string
  initArg(arg, default(Kind), "--x")
  # pins: argumint/customarg.accept.e,Arg,Contribution,Arbitration
  arg.accept(Contribution(value: "v"), arExtend)
  # pins: argumint/customarg.action.e,Arg,HookInfo,string
  arg.action(info, "--x")
  # pins: argumint/customarg.isMessage.e,Arg
  # pins: argumint/customarg.envSource.e,Arg
  # pins: argumint/customarg.envName,Arg
  if arg.isMessage or arg.envSource.isSome: result.add arg.envName
  # pins: argumint/customarg.configKey.e,Arg
  discard arg.configKey()
  # pins: argumint/customarg.subject,Arg,Contribution
  result.add arg.subject(Contribution(value: "v"))

suite "`import argumint/customarg` alone":
  test "what an `accept` override is handed":
    # pins: argumint/customarg.Contribution
    # pins: argumint/customarg.Contribution.value
    # pins: argumint/customarg.Contribution.variant
    # pins: argumint/customarg.Contribution.tier
    let c = Contribution(value: "8080", variant: "--port")
    check c.value == "8080"
    check c.variant == "--port"
    check c.tier.isNone
    # pins: argumint/customarg.Arbitration
    # pins: argumint/customarg.Arbitration.arExtend
    # pins: argumint/customarg.Arbitration.arReplace
    check arExtend != arReplace

  test "what a Custom Arg calls or overrides":
    check not probe.isNil
