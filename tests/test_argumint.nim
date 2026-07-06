import std/[algorithm, sequtils, strutils, unittest]

import argumint
import argumint/backend
import argumint/fsm
import argumint/lexer
import argumint/validators

type Priority = enum
  low, medium, high

converter toPriority(value: string): Priority =
  parseEnum[Priority](value)

defineArg(Priority):
  case op
  of "=": value = arg
  else: raise newException(SpecDefect, "priority flags only support =")

suite "Positional args":
  test "parse scalar values and fall back to defaults when absent":
    let spec = (
      name: arg("<name>", default = "nobody", help = ""),
    )
    let s = newSpec(spec, usage = "[<name>]")
    s.parseSpec(@["ship"], "prog")
    check spec.name == "ship"

    let spec2 = (
      name: arg("<name>", default = "nobody", help = ""),
    )
    let s2 = newSpec(spec2, usage = "[<name>]")
    s2.parseSpec(@[], "prog")
    check spec2.name == "nobody"

  test "parse multiple values without corrupting earlier elements (ORC regression)":
    let spec = (
      files: arg("<file>", default = newSeq[string](), help = ""),
    )
    let s = newSpec(spec, usage = "<file>...")
    s.parseSpec(@["a", "b", "c", "d"], "prog")
    check spec.files == @["a", "b", "c", "d"]

suite "Optional args":
  test "parse `--option=value` and validate it":
    let spec = (
      speed: opt("--speed=<speed>", default = 1, validator = range(1..100), help = ""),
    )
    let s = newSpec(spec, usage = "[--speed=<speed>]")
    s.parseSpec(@["--speed=42"], "prog")
    check spec.speed == 42

  test "raise ValidationError for values outside the validator's range":
    let spec = (
      speed: opt("--speed=<speed>", default = 1, validator = range(1..100), help = ""),
    )
    let s = newSpec(spec, usage = "[--speed=<speed>]")
    expect ValidationError:
      s.parseSpec(@["--speed=999"], "prog")

suite "Flags":
  test "bool flags toggle from their default":
    let spec = (
      moored: flag("--moored", default = false, help = ""),
    )
    let s = newSpec(spec, usage = "[--moored]")
    s.parseSpec(@["--moored"], "prog")
    check spec.moored == true

  test "int flags apply their default increment op across repeats":
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, help = ""),
    )
    let s = newSpec(spec, usage = "[--verbose]...")
    s.parseSpec(@["--verbose", "--verbose", "--verbose"], "prog")
    check spec.verbosity == 3

  test "user-defined types work via the user's own converter (extensibility regression)":
    let spec = (
      p: flag[Priority]("--priority=high", default = low, help = ""),
    )
    let s = newSpec(spec, usage = "[--priority]")
    s.parseSpec(@["--priority"], "prog")
    check spec.p == high

suite "Commands":
  test "dispatch a matched subcommand to its handler":
    var moved = ""
    proc cmdMove(spec: tuple) =
      moved = spec.name

    let move = (name: arg("<name>", help = ""))
    let spec = (
      ship: command("ship", move, handler = cmdMove, usage = "<name>", help = ""),
    )
    let s = newSpec(spec, usage = "ship")
    s.parseSpec(@["ship", "Titanic"], "prog")
    check moved == "Titanic"

suite "Errors":
  test "raise ParseError for unrecognized options":
    let spec = (
      name: arg("<name>", help = ""),
    )
    let s = newSpec(spec, usage = "<name>")
    expect ParseError:
      s.parseSpec(@["--nope"], "prog")

  test "raise SpecDefect for a malformed positional variant":
    expect SpecDefect:
      discard newSpec((bad: arg("bad", help = "")))

  test "raise SpecDefect for a duplicate arg name":
    expect SpecDefect:
      discard newSpec((a: arg("<x>", help = ""), b: arg("<x>", help = "")))

suite "Messages":
  test "help() raises HelpError with the generated help text":
    let spec = (
      name: arg("<name>", help = "who to greet"),
      help: help(),
    )
    let s = newSpec(spec, usage = "<name>\n--help")
    expect HelpError:
      s.parseSpec(@["--help"], "prog")

  test "version() raises MessageError with the configured text":
    let spec = (
      ver: version("myapp 1.2.3"),
    )
    let s = newSpec(spec, usage = "--version")
    var caught = ""
    try:
      s.parseSpec(@["--version"], "prog")
    except MessageError as e:
      caught = e.msg
    check caught == "myapp 1.2.3"

  test "help text lists groups as Commands, Arguments, Options, then user-defined groups":
    let spec = (
      verbose: flag("--verbose", help = "Verbose", group = "Global Options"),
      speed: opt("--speed=<speed>", default = 1, help = "Speed"),
      file: arg("<file>", help = "The file"),
      cmd: command("cmd", (x: arg("<x>", help = "x")), help = "A subcommand"),
      help: help(),
    )
    let s = newSpec(spec)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    let order = @["Commands", "Arguments", "Options", "Global Options"].mapIt(helpText.find(it))
    check order == order.sorted
    check order.allIt(it >= 0)

  test "help text aligns variant columns across groups and skips padding for empty help":
    let spec = (
      verbose: flag("--verbose", help = "", group = "Global Options"),
      speed: opt("--speed=<speed>", default = 1, help = "Speed"),
      file: arg("<file>", help = "The file"),
      cmd: command("cmd", (x: arg("<x>", help = "x")), help = "A subcommand"),
      help: help(),
    )
    let s = newSpec(spec)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    let width = "--speed=<speed>".len
    check ("  " & "cmd".alignLeft(width) & "  A subcommand") in helpText
    check ("  " & "<file>".alignLeft(width) & "  The file") in helpText
    check ("  --speed=<speed>  Speed") in helpText
    check "  --verbose" in helpText.splitLines

suite "autoFillUsage":
  test "commands and MessageArgs are filled in individually":
    let spec = (
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      mine: command("mine", (y: arg("<y>", help = "")), help = "Mine"),
      help: help(),
      version: version("1.0.0"),
    )
    let s = newSpec(spec, usage = "ship")
    check "mine" in s.usage
    check "-h" in s.usage
    check "-v" in s.usage

  test "positional args are only filled in when none of them are reachable":
    let spec = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
    )
    let s = newSpec(spec, usage = "")
    check "<a>" in s.usage and "<b>" in s.usage

    let spec2 = (
      a: arg("<a>", help = ""),
      b: arg("<b>", help = ""),
    )
    let s2 = newSpec(spec2, usage = "<a>")
    check s2.usage == "<a>"

  test "a standalone [options] line is added when nothing else needs appending":
    let spec = (
      verbose: flag("--verbose", default = false, help = ""),
    )
    let s = newSpec(spec, usage = "")
    check s.usage == "[options]"

  test "an appended command line is prefixed with [options] when needed":
    let spec = (
      verbose: flag("--verbose", default = false, help = ""),
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
    )
    let s = newSpec(spec, usage = "")
    check s.usage == "[options] ship"
