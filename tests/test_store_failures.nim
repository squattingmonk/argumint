# What a parse reports when the walk succeeds but values fail to convert or
# validate: every failure at once, in one message. See
# docs/adr/0077-report-every-bad-value.md.

import std/[os, strutils, unittest]

import argumint, argumint/customarg

proc complaints(msg: string): seq[string] =
  ## Just the bulleted complaint lines, without the usage block below them.
  for line in msg.splitLines:
    if line.startsWith("  - "):
      result.add line[4 .. ^1]

proc spec(): auto =
  (port: opt("--port=<n>", default = 0, help = ""),
   count: opt("--count=<n>", default = 0, help = ""),
   num: opt("--num=<n>", default = 0, env = "ARGUMINT_TEST_NUM", help = ""),
   tags: opts[string]("--tag=<t>", validator = unique[string](), help = ""),
   name: opt("--name=<s>", default = "", help = ""))

suite "every bad value is reported at once":
  setup:
    delEnv "ARGUMINT_TEST_NUM"
  teardown:
    delEnv "ARGUMINT_TEST_NUM"

  test "in typed order, then the fallback tiers, each naming its tier":
    putEnv "ARGUMINT_TEST_NUM", "zz"
    let s = spec()
    try:
      s.parse(args = @["--count", "y", "--name", "ok", "--port", "x"],
        command = "app", settings = newSpecSettings(style = nil))
      fail()
    except ParseError as e:
      check e.msg.complaints == @[
        "expected an integer for --count but got \"y\"",
        "expected an integer for --port but got \"x\"",
        "expected an integer for --num (env: ARGUMINT_TEST_NUM) but got \"zz\""]

  test "typed order holds where the grammar's order differs":
    # The walk matches `[options]` before `<n>`, whatever order they're typed.
    let s = newSpec((port: opt("--port=<n>", default = 0, help = ""),
                     n: arg[int]("<n>", help = "")),
      usage = "[options] <n>", settings = newSpecSettings(style = nil))
    try:
      s.parse(args = @["x", "--port", "y"], command = "app")
      fail()
    except ParseError as e:
      check e.msg.complaints == @[
        "expected an integer for <n> but got \"x\"",
        "expected an integer for --port but got \"y\""]

  test "every valid value is still written; a failing one is not":
    putEnv "ARGUMINT_TEST_NUM", "zz"
    let s = spec()
    expect ParseError:
      s.parse(args = @["--port", "x", "--name", "ok", "--count", "y"],
        command = "app", settings = newSpecSettings(style = nil))
    check s.name.get == "ok"
    check not s.port.seen
    check not s.count.seen
    check not s.num.seen

  test "a single failure reads as it always has":
    let s = spec()
    try:
      s.parse(args = @["--port", "x"], command = "app",
        settings = newSpecSettings(style = nil))
      fail()
    except ParseError as e:
      check e.msg == "  - expected an integer for --port but got \"x\"\n\n" &
        "Usage:\n  app [options]"

suite "the exception covers every failure":
  test "validation failures alone stay ValidationError":
    let s = spec()
    try:
      s.parse(args = @["--tag", "a", "--tag", "b", "--tag", "a", "--tag", "b"],
        command = "app", settings = newSpecSettings(style = nil))
      fail()
    except ValidationError as e:
      check e.msg.complaints == @[
        "for --tag, \"a\" did not meet condition: must be unique",
        "for --tag, \"b\" did not meet condition: must be unique"]

  test "a Validator sees only what was stored":
    let s = spec()
    expect ValidationError:
      s.parse(args = @["--tag", "a", "--tag", "b", "--tag", "a", "--tag", "b"],
        command = "app", settings = newSpecSettings(style = nil))
    check s.tags.get == @["a", "b"]

  test "a validation failure beside a conversion failure is a ParseError":
    let s = spec()
    try:
      s.parse(args = @["--tag", "a", "--tag", "a", "--port", "x"],
        command = "app", settings = newSpecSettings(style = nil))
      fail()
    except ParseError as e:
      check e.name == "ParseError"
      check e.msg.complaints.len == 2

  test "a validation failure beside oversupply is a ParseError":
    putEnv "ARGUMINT_TEST_NAMES", "a,b"
    defer: delEnv "ARGUMINT_TEST_NAMES"
    let s = (tags: opts[string]("--tag=<t>", validator = unique[string](), help = ""),
             name: opt("--name=<s>", env = env("ARGUMINT_TEST_NAMES", ","),
                       default = "", help = ""))
    try:
      s.parse(args = @["--tag", "a", "--tag", "a"], command = "app",
        settings = newSpecSettings(style = nil))
      fail()
    except ParseError as e:
      check e.name == "ParseError"
      check e.msg.complaints == @[
        "for --tag, \"a\" did not meet condition: must be unique",
        "unexpected option: --name (env: ARGUMINT_TEST_NAMES)"]

suite "a failed value closes the weaker tiers":
  setup:
    delEnv "ARGUMINT_TEST_NUM"
  teardown:
    delEnv "ARGUMINT_TEST_NUM"

  test "a bad env value isn't reported under a bad command-line one":
    putEnv "ARGUMINT_TEST_NUM", "zz"
    let s = spec()
    try:
      s.parse(args = @["--num", "x"], command = "app",
        settings = newSpecSettings(style = nil))
      fail()
    except ParseError as e:
      check e.msg.complaints == @["expected an integer for --num but got \"x\""]

  test "a good env value doesn't fill in for a bad command-line one":
    putEnv "ARGUMINT_TEST_NUM", "5"
    let s = spec()
    expect ParseError:
      s.parse(args = @["--num", "x"], command = "app",
        settings = newSpecSettings(style = nil))
    check not s.num.seen

type Boom = ref object of Arg
  ## Fails storing with something other than a parse or validation error.

method accept(self: Boom, c: Contribution, how: Arbitration) =
  raise newException(IOError, "disk on fire")

proc boom(variants: string): Boom =
  result = Boom(help: "")
  result.initArg(Optional, variants)

suite "only a ParseError is collected":
  test "anything else propagates from parse as it is":
    let s = (boom: boom("--boom=<b>"),
             port: opt("--port=<n>", default = 0, help = ""))
    expect IOError:
      s.parse(args = @["--port", "x", "--boom", "a"], command = "app",
        settings = newSpecSettings(style = nil))
