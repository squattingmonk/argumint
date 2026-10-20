# Which `ParseError` subtype each way a parse can fail raises, checked by
# exact type, since `expect ParseError` passes for every subtype. See
# docs/adr/0078-parse-error-hierarchy.md.

import std/[os, unittest]

import argumint, argumint/customarg

template raised(body: untyped): string =
  ## The exact type `body` raises, or "nothing".
  var name = "nothing"
  try:
    body
  except ParseError as e:
    name = $e.name
  name

proc plain(): SpecSettings = newSpecSettings(style = nil)

type
  BareArg = ref object of Arg
  ConvertingArg = ref object of Arg

method accept(self: BareArg, c: Contribution, how: Arbitration) =
  raise newException(ParseError, "bare for " & self.subject(c))

method accept(self: ConvertingArg, c: Contribution, how: Arbitration) =
  raise newException(ConversionError, "converting for " & self.subject(c))

proc initCustom[A: Arg](arg: A, variants: string): A =
  arg.help = ""
  arg.group = "Options"
  arg.initArg(Optional, variants)
  arg

suite "every user-input failure is a ParseError":
  test "except ParseError catches a validation failure":
    let s = (num: opt("--num=<n>", default = 1, validator = range(1..3), help = ""))
    expect ParseError:
      s.parse(args = @["--num", "9"], command = "app", settings = plain())

suite "a walk that fails raises UsageError":
  test "an unrecognized option":
    let s = (num: opt("--num=<n>", default = 1, help = ""))
    check raised(s.parse(args = @["--nope"], command = "app",
      settings = plain())) == "UsageError"

  test "a missing argument":
    let s = (name: arg("<name>", help = ""))
    check raised(s.parse(args = @[], command = "app",
      settings = plain())) == "UsageError"

  test "a missing command":
    let s = (go: command("go", (help: help())))
    check raised(s.parse(args = @[], command = "app",
      settings = plain())) == "UsageError"

suite "a value that won't convert raises ConversionError":
  test "a value that isn't its type":
    let s = (num: opt("--num=<n>", default = 1, help = ""))
    check raised(s.parse(args = @["--num", "x"], command = "app",
      settings = plain())) == "ConversionError"

  test "a value out of its type's range":
    let s = (num: opt[uint8]("--num=<n>", default = 1, help = ""))
    check raised(s.parse(args = @["--num", "300"], command = "app",
      settings = plain())) == "ConversionError"

  test "an unknown enum name":
    type Mode = enum fast, slow
    let s = (mode: opt("--mode=<m>", default = fast, help = ""))
    check raised(s.parse(args = @["--mode", "medium"], command = "app",
      settings = plain())) == "ConversionError"

  test "a Variant the flag doesn't have":
    let verbose = flag("-v, --verbose", help = "")
    check raised(verbose.parse("--nope")) == "ConversionError"

suite "a Validator's rejection raises ValidationError":
  test "a value outside its Validator's range":
    let s = (num: opt("--num=<n>", default = 1, validator = range(1..3), help = ""))
    check raised(s.parse(args = @["--num", "9"], command = "app",
      settings = plain())) == "ValidationError"

suite "fallback-tier oversupply raises UsageError":
  setup:
    putEnv "ARGUMINT_TEST_PORTS", "1,2"
  teardown:
    delEnv "ARGUMINT_TEST_PORTS"

  test "alone":
    let s = (port: opt("--port=<n>", default = 1,
      env = env("ARGUMINT_TEST_PORTS", ","), help = ""))
    check raised(s.parse(args = @[], command = "app",
      settings = plain())) == "UsageError"

suite "failures of more than one subtype raise ParseError":
  setup:
    putEnv "ARGUMINT_TEST_PORTS", "1,2"
  teardown:
    delEnv "ARGUMINT_TEST_PORTS"

  test "oversupply beside a conversion failure":
    let s = (port: opt("--port=<n>", default = 1,
               env = env("ARGUMINT_TEST_PORTS", ","), help = ""),
             num: opt("--num=<n>", default = 1, help = ""))
    check raised(s.parse(args = @["--num", "x"], command = "app",
      settings = plain())) == "ParseError"

  test "a validation failure beside a conversion failure":
    let s = (num: opt("--num=<n>", default = 1, validator = range(1..3), help = ""),
             max: opt("--max=<n>", default = 1, help = ""))
    check raised(s.parse(args = @["--num", "9", "--max", "x"], command = "app",
      settings = plain())) == "ParseError"

suite "a Custom Arg's failure is classified by its type":
  test "a bare ParseError stays a ParseError":
    let s = (bare: BareArg().initCustom("--bare=<v>"))
    check raised(s.parse(args = @["--bare", "x"], command = "app",
      settings = plain())) == "ParseError"

  test "a ConversionError stays a ConversionError":
    let s = (conv: ConvertingArg().initCustom("--conv=<v>"))
    check raised(s.parse(args = @["--conv", "x"], command = "app",
      settings = plain())) == "ConversionError"
