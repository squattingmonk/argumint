import std/[algorithm, os, sequtils, strutils, tables, unittest]

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

type Level = enum
  quiet, normal, loud

converter toLevel(value: string): Level =
  parseEnum[Level](value)

defineFlag(Level, "Bump up one level"):
  case op
  of "": value = Level((ord(value) + 1) mod 3)
  of "=": value = arg
  else: raise newException(SpecDefect, "level flags only support = operations")

type Speed = enum
  slow, medium2, fast

converter toSpeed(value: string): Speed =
  parseEnum[Speed](value)

defineArg(Speed):
  # Deliberately doesn't support "=" -- used to test that `flag*` raises
  # SpecDefect when `env` is given for a type whose handler can't apply it.
  case op
  of "+=": value = Speed((ord(value) + 1) mod 3)
  else: raise newException(SpecDefect, "speed flags only support += operations")

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
      files: args[string]("<file>", help = ""),
    )
    let s = newSpec(spec, usage = "<file>...")
    s.parseSpec(@["a", "b", "c", "d"], "prog")
    check spec.files == @["a", "b", "c", "d"]

  test "args[T] with no default given defaults to empty":
    let spec = (
      files: args[string]("<file>", help = ""),
    )
    let s = newSpec(spec, usage = "[<file>...]")
    s.parseSpec(@[], "prog")
    check spec.files == newSeq[string]()

  test "args() with a non-empty default infers T without a bracket":
    let spec = (
      files: args("<file>", default = @["a", "b"], help = ""),
    )
    let s = newSpec(spec, usage = "[<file>...]")
    s.parseSpec(@[], "prog")
    check spec.files == @["a", "b"]

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

  test "opts[T] with no default given defaults to empty":
    let spec = (
      tags: opts[string]("--tag=<tag>", help = ""),
    )
    let s = newSpec(spec, usage = "[--tag=<tag>]...")
    s.parseSpec(@[], "prog")
    check spec.tags == newSeq[string]()

  test "opts() with a non-empty default infers T without a bracket":
    let spec = (
      tags: opts("--tag=<tag>", default = @["a", "b"], help = ""),
    )
    let s = newSpec(spec, usage = "[--tag=<tag>]...")
    s.parseSpec(@[], "prog")
    check spec.tags == @["a", "b"]

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

  test "SpecDefect raised when variantHelp references an unknown variant":
    expect SpecDefect:
      discard flag[int]("-v, --verbose", default = 0, help = "",
        variantHelp = {"--bogus": "nope"}.toTable)

  test "custom flag types get auto-generated =/+=/-= descriptions for free":
    let spec = (
      p: flag[Priority]("--priority=high, --boost=medium", default = low, help = "Set priority"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try: s.parseSpec(@["--help"], "prog")
    except HelpError as e: helpText = e.msg
    # --priority is the primary (first-declared) group, so it keeps the
    # shared `help` text; only the divergent --boost group shows its own
    # auto-generated description.
    check "Set priority" in helpText
    check "Set to medium" in helpText

  test "a custom flag type can supply blank-op wording via defineFlag":
    let spec = (
      lvl: flag[Level]("--set=loud, -b, --bump", default = quiet, help = "Adjust level"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try: s.parseSpec(@["--help"], "prog")
    except HelpError as e: helpText = e.msg
    # --set is the primary group here, so -b/--bump (the divergent
    # blank-op group) is what shows the defineFlag-supplied blankDesc.
    check "Adjust level" in helpText
    check "Bump up one level" in helpText

suite "[options] catch-all":
  test "an option mentioned explicitly can't also be matched again via [options]":
    let spec = (
      verbose: flag("--verbose", help = ""),
      moored: flag("--moored", help = ""),
    )
    let s = newSpec(spec, usage = "[options] --verbose")
    s.parseSpec(@["--verbose"], "prog")

    let s2 = newSpec(spec, usage = "[options] --verbose")
    expect ParseError:
      s2.parseSpec(@["--verbose", "--verbose"], "prog")

  test "an option only reachable via [options] is unaffected":
    let spec = (
      verbose: flag("--verbose", help = ""),
      moored: flag("--moored", help = ""),
    )
    let s = newSpec(spec, usage = "[options] --verbose")
    s.parseSpec(@["--moored", "--verbose"], "prog")
    check spec.moored == true

  test "the exclusion also applies to value-taking options (opt())":
    let spec = (
      speed: opt("--speed=<speed>", default = 1, help = ""),
    )
    let s = newSpec(spec, usage = "[options] --speed=<speed>")
    expect ParseError:
      s.parseSpec(@["--speed=1", "--speed=2"], "prog")

  test "an explicit repeat (...) on the mentioned option still works":
    let spec = (
      verbose: flag[int]("--verbose", default = 0, help = ""),
    )
    let s = newSpec(spec, usage = "[options] --verbose...")
    s.parseSpec(@["--verbose", "--verbose", "--verbose"], "prog")
    check spec.verbose == 3

  test "the exclusion applies to options nested inside a mutually-exclusive choice group":
    let spec = (
      moored: flag("--moored", help = ""),
      drifting: flag("--drifting", help = ""),
    )
    let usage = "[options] [--moored | --drifting]"

    let s1 = newSpec(spec, usage = usage)
    s1.parseSpec(@["--moored"], "prog")
    check spec.moored == true

    let s2 = newSpec(spec, usage = usage)
    expect ParseError:
      s2.parseSpec(@["--moored", "--moored"], "prog")

    let s3 = newSpec(spec, usage = usage)
    expect ParseError:
      s3.parseSpec(@["--moored", "--drifting"], "prog")

    let s4 = newSpec(spec, usage = usage)
    s4.parseSpec(@[], "prog")

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

suite "Empty specs":
  test "a top-level spec with zero declared args parses successfully given zero input":
    let s = newSpec(())
    s.parseSpec(@[], "prog")

  test "two argument-less subcommands in a choice each parse correctly on their own":
    let spec = (
      ship: command("ship", (), help = "Ship"),
      mine: command("mine", (), help = "Mine"),
      help: help(),
    )
    let s = newSpec(spec, usage = "(ship | mine)\n--help")
    s.parseSpec(@["ship"], "prog")

    let spec2 = (
      ship: command("ship", (), help = "Ship"),
      mine: command("mine", (), help = "Mine"),
      help: help(),
    )
    let s2 = newSpec(spec2, usage = "(ship | mine)\n--help")
    s2.parseSpec(@["mine"], "prog")

  test "an argument-less subcommand nested inside another subcommand parses correctly":
    let inner = (status: command("status", (), help = "Status"), help: help())
    let spec = (ship: command("ship", inner, help = "Ship"), help: help())
    let s = newSpec(spec, usage = "ship")
    s.parseSpec(@["ship", "status"], "prog")

  test "an argument-less subcommand mixed with a normal one in the same choice still parses both":
    let spec = (
      status: command("status", (), help = "Status"),
      move: command("move", (x: arg("<x>", default = 0, help = "")), help = "Move"),
      help: help(),
    )
    let s = newSpec(spec, usage = "(status | move)\n--help")
    s.parseSpec(@["status"], "prog")

    let moveArgs = (x: arg("<x>", default = 0, help = ""))
    let spec2 = (
      status: command("status", (), help = "Status"),
      move: command("move", moveArgs, help = "Move"),
      help: help(),
    )
    let s2 = newSpec(spec2, usage = "(status | move)\n--help")
    s2.parseSpec(@["move", "5"], "prog")
    check moveArgs.x == 5

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

  test "an [options]-only flag failing doesn't produce a duplicate message":
    let spec = (
      verbose: flag("--verbose", help = ""),
      add: command("add", (help: help()), help = "Add"),
      help: help(),
    )
    let s = newSpec(spec)
    var caught = ""
    try:
      s.parseSpec(@[], "prog")
    except ParseError as e:
      caught = e.msg
    check caught.count("--verbose") == 1

  test "a satisfied repeated positional isn't reported missing when a later arg is":
    let spec = (
      src: args[string]("<src>", help = ""),
      dest: arg("<dest>", help = ""),
    )
    let s = newSpec(spec, usage = "<src>... <dest>")
    var caught = ""
    try:
      s.parseSpec(@["a.txt"], "prog")
    except ParseError as e:
      caught = e.msg
    check "missing argument: <dest>" in caught
    check "missing argument: <src>" notin caught

  test "same-kind alternatives are grouped onto one line joined by |":
    let spec = (
      ship: command("ship", (help: help()), help = "Ship"),
      mine: command("mine", (help: help()), help = "Mine"),
      help: help(),
    )
    let s = newSpec(spec, usage = "(ship | mine)\n(-h | --help)")
    var caught = ""
    try:
      s.parseSpec(@[], "prog")
    except ParseError as e:
      caught = e.msg
    check "missing command: (ship | mine)" in caught

  test "a single missing requirement renders without a | separator":
    let spec = (
      name: arg("<name>", help = ""),
    )
    let s = newSpec(spec, usage = "<name>")
    var caught = ""
    try:
      s.parseSpec(@[], "prog")
    except ParseError as e:
      caught = e.msg
    check "missing argument: <name>" in caught
    check "|" notin caught

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

  test "variants column wraps at maxVariantsWidth with help text aligned to the first wrapped line":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 20)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    let firstLine = "  " & "-v, --verbose,".alignLeft(20) & "  Adjust verbosity"
    let lines = helpText.splitLines
    let firstIdx = lines.find(firstLine)
    check firstIdx >= 0
    check lines[firstIdx + 1] == "    --quiet, --boost,"
    check lines[firstIdx + 2] == "    --dampen"

  test "variants column wraps without trailing whitespace when help text is empty":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = ""),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 20)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    let lines = helpText.splitLines
    check "  -v, --verbose," in lines
    check "    --quiet, --boost," in lines
    check "    --dampen" in lines
    for line in lines:
      check line == line.strip(leading = false, trailing = true)

  test "a flag with divergent per-variant ops groups into rows, primary row keeping the shared help":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    let colWidth = "-v, --verbose".len
    check ("  " & "-v, --verbose".alignLeft(colWidth) & "  Adjust verbosity [action: Increment by 1]") in helpText
    check ("    " & "--quiet".alignLeft(colWidth) & "  Set to 0") in helpText
    check ("    " & "--boost".alignLeft(colWidth) & "  Increase by 5") in helpText
    check ("    " & "--dampen".alignLeft(colWidth) & "  Decrease by 2") in helpText

  test "primary row shows [action: X] alone when arg.help is empty":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0", default = 0, help = ""),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "  -v, --verbose  [action: Increment by 1]" in helpText

  test "variantHelp overrides the auto-generated description for a specific variant":
    let spec = (
      verbosity: flag[int]("-v, --verbose, --quiet=0, --boost+=5, --dampen-=2", default = 0, help = "Adjust verbosity",
        variantHelp = {"--quiet": "Reset to silent"}.toTable),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "Reset to silent" in helpText
    check "Set to 0" notin helpText

  test "a bool flag's blank-op variants show \"Toggle the value\" when grouped with a divergent peer":
    let spec = (
      moored: flag("--docked=true, -m, --moored", default = false, help = "Ship status"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "Ship status" in helpText
    check "Toggle the value" in helpText

  test "same-op variants collapse into a single ungrouped row (no divergence to disambiguate)":
    let spec = (
      verbosity: flag[int]("-v, --verbose", default = 0, help = "Adjust verbosity"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "  -v, --verbose  Adjust verbosity" in helpText
    check "Increment by 1" notin helpText

  test "maxVariantsWidth defaults to 30 and is configurable":
    proc mkSpec(): auto = (verbosity: flag[int]("-v, --verbose, --quiet, --boost, --dampen", default = 0, help = "Adjust verbosity"), help: help())
    let default = newSpec(mkSpec())
    let narrow = newSpec(mkSpec(), maxVariantsWidth = 20)
    let unlimited = newSpec(mkSpec(), maxVariantsWidth = 0)
    check default.maxVariantsWidth == 30
    check narrow.maxVariantsWidth == 20
    check unlimited.maxVariantsWidth == 0

    var defaultText, unlimitedText = ""
    try: default.parseSpec(@["--help"], "prog")
    except HelpError as e: defaultText = e.msg
    try: unlimited.parseSpec(@["--help"], "prog")
    except HelpError as e: unlimitedText = e.msg

    check ("  " & "-v, --verbose, --quiet,".alignLeft(30) & "  Adjust verbosity") in defaultText
    check "    --boost, --dampen" in defaultText.splitLines
    check ("  -v, --verbose, --quiet, --boost, --dampen  Adjust verbosity") in unlimitedText

  test "maxVariantsWidth cascades from the root spec into nested subcommand specs":
    let move = (name: arg("<name>", help = ""), help: help())
    let ship = (move: command("move", move, help = "Move a ship"), help: help())
    let s = newSpec((ship: command("ship", ship, help = "Ship commands"), help: help()), maxVariantsWidth = 20)
    check s.maxVariantsWidth == 20
    check s.commands["ship"].spec.maxVariantsWidth == 20
    check s.commands["ship"].spec.commands["move"].spec.maxVariantsWidth == 20

  test "usage lines longer than 80 columns wrap with a hanging indent":
    let spec = (
      a: opt("--alpha=<a>", default = "", help = ""),
      b: opt("--bravo=<b>", default = "", help = ""),
      c: opt("--charlie=<c>", default = "", help = ""),
      d: opt("--delta=<d>", default = "", help = ""),
      e: opt("--echo=<e>", default = "", help = ""),
      f: args("<file>", default = @["x"], help = ""),
    )
    let s = newSpec(spec,
      usage = "[--alpha=<a>] [--bravo=<b>] [--charlie=<c>] [--delta=<d>] [--echo=<e>] <file>...")
    let lines = s.usage.formatUsage("prog").splitLines
    let indent = ' '.repeat("  prog ".len)
    check lines.len > 2
    check lines[1].len <= 80
    check lines[1].startsWith("  prog ")
    check lines[2].startsWith(indent)
    check not lines[2].startsWith(indent & " ")
    check lines[2].strip.len > 0

  test "help text for a single arg wraps at the configured width with a hanging indent":
    let longHelp = "How fast the ship should move across the open water, measured in knots"
    let s = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()))
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    let optionsLines = helpText.splitLines.filterIt(it.startsWith("  --speed") or it.startsWith("                   "))
    check optionsLines.len > 1
    for line in optionsLines:
      check line.len <= 80
    check optionsLines[1].startsWith("                   ")

  test "help text shows [default: X] for arg()/opt() but not flag()":
    let spec = (
      speed: opt("--speed=<speed>", default = 10, help = "Speed in knots"),
      x: arg("<x>", default = 0, help = "x grid reference"),
      name: arg("<name>", help = "who to greet"),
      files: args("<file>", default = @["a.txt", "b.txt"], help = "Files"),
      verbose: flag("--verbose", help = "Verbose output"),
      help: help(),
    )
    let s = newSpec(spec, usage = "<x> <name> <file>...\n[--speed=<speed>] [--verbose]\n--help")
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "Speed in knots [default: 10]" in helpText
    check "Files [default: a.txt, b.txt]" in helpText
    check "who to greet" in helpText
    check "who to greet [default" notin helpText
    check "Verbose output [default" notin helpText

  test "help text suppresses [default: X] when the default is T's zero value":
    let spec = (
      x: arg("<x>", default = 0, help = "x grid reference"),
      speed: opt("--speed=<speed>", default = 0, help = "Speed in knots"),
      verbose: flag[int]("--verbose", default = 0, help = "Verbosity"),
      help: help(),
    )
    let s = newSpec(spec, usage = "<x> [--speed=<speed>] [--verbose]\n--help")
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "x grid reference [default" notin helpText
    check "Speed in knots [default" notin helpText
    check "Verbosity [default" notin helpText

  test "help text shows [default: X] alone when help is empty":
    let s = newSpec((speed: opt("--speed=<speed>", default = 5, help = ""), help: help()),
      usage = "[--speed=<speed>]\n--help")
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "  --speed=<speed>  [default: 5]" in helpText

  test "help text shows a choice validator's help alongside its default in one bracket":
    let spec = (
      action: arg("<action>", default = "foo", help = "Action to perform",
        validator = choice(["foo", "bar", "baz"])),
      help: help(),
    )
    let s = newSpec(spec, usage = "<action>\n--help")
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "Action to perform [choices: foo, bar, baz; default: foo]" in helpText

  test "help text shows a range validator's help without a default when default is the zero value":
    let spec = (
      speed: opt("--speed=<speed>", default = 0, help = "Speed", validator = range(1..100)),
      help: help(),
    )
    let s = newSpec(spec, usage = "[--speed=<speed>]\n--help")
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "Speed [range: 1..100]" in helpText
    check "default" notin helpText

  test "help text shows a check validator's description alone, with no label":
    let spec = (
      amount: opt("--amount=<amount>", default = 0,
        validator = checkIt[int](it mod 2 == 0, "must be even"), help = ""),
      help: help(),
    )
    let s = newSpec(spec, usage = "[--amount=<amount>]\n--help")
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "  --amount=<amount>  [must be even]" in helpText

  test "width is configurable and defaults to 80":
    let longHelp = "How fast the ship should move across the open water, measured in knots"
    let wide = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()))
    let narrow = newSpec((speed: opt("--speed=<speed>", default = 1, help = longHelp), help: help()), width = 40)
    check wide.width == 80
    check narrow.width == 40

    var wideText, narrowText = ""
    try: wide.parseSpec(@["--help"], "prog")
    except HelpError as e: wideText = e.msg
    try: narrow.parseSpec(@["--help"], "prog")
    except HelpError as e: narrowText = e.msg

    check wideText.splitLines.allIt(it.len <= 80)
    check narrowText.splitLines.allIt(it.len <= 40)
    check narrowText.splitLines.len > wideText.splitLines.len

  test "width cascades from the root spec into nested subcommand specs":
    let move = (name: arg("<name>", help = ""), help: help())
    let ship = (move: command("move", move, help = "Move a ship"), help: help())
    let s = newSpec((ship: command("ship", ship, help = "Ship commands"), help: help()), width = 40)
    check s.width == 40
    check s.commands["ship"].spec.width == 40
    check s.commands["ship"].spec.commands["move"].spec.width == 40

suite "autoFillUsage":
  test "MessageArgs are filled in individually; a single unreachable command needs no parens":
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

  test "multiple unreachable commands are consolidated into one alternation line, not one per command":
    let spec = (
      verbose: flag("--verbose", help = ""),
      ship: command("ship", (x: arg("<x>", help = "")), help = "Ship"),
      mine: command("mine", (y: arg("<y>", help = "")), help = "Mine"),
    )
    let s = newSpec(spec)
    check s.usage == "[options] (ship | mine)"

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

suite "FSM choice deduplication":
  test "an auto-filled (-h | --help) line collapses to a single edge, both spellings still parse":
    let spec = (name: arg("<name>", help = ""), help: help())
    let s = newSpec(spec, usage = "<name>")
    check s.dot.count("Opt(-h)") == 1
    expect HelpError:
      s.parseSpec(@["-h"], "prog")
    expect HelpError:
      s.parseSpec(@["--help"], "prog")

  test "an explicitly-authored duplicate choice collapses the same way":
    let spec = (x: flag("-x, --xxx", help = ""), help: help())
    let s = newSpec(spec, usage = "(-x | --xxx)\n--help")
    check s.dot.count("Opt(-x)") == 1
    s.parseSpec(@["-x"], "prog")
    check spec.x == true

    let spec2 = (x: flag("-x, --xxx", help = ""), help: help())
    let s2 = newSpec(spec2, usage = "(-x | --xxx)\n--help")
    s2.parseSpec(@["--xxx"], "prog")
    check spec2.x == true

  test "a choice between distinct Args is not affected":
    let spec = (
      ship: command("ship", (v: flag("--verbose", help = "")), help = "Ship"),
      mine: command("mine", (v: flag("--verbose", help = "")), help = "Mine"),
      help: help(),
    )
    let s = newSpec(spec, usage = "(ship | mine)\n--help")
    check s.dot.count("Cmd(ship)") == 1
    check s.dot.count("Cmd(mine)") == 1
    s.parseSpec(@["ship"], "prog")

    let spec2 = (
      ship: command("ship", (v: flag("--verbose", help = "")), help = "Ship"),
      mine: command("mine", (v: flag("--verbose", help = "")), help = "Mine"),
      help: help(),
    )
    let s2 = newSpec(spec2, usage = "(ship | mine)\n--help")
    s2.parseSpec(@["mine"], "prog")

  test "three or more alternatives referencing the same Arg collapse to one edge":
    let spec = (v: flag("-a, -b, -c", help = ""), help: help())
    let s = newSpec(spec, usage = "(-a | -b | -c)\n--help")
    check s.dot.count("Opt(-a)") == 1

suite "Environment variables":
  test "opt: env var set, no CLI value, is used and converted like a CLI value":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    let s = newSpec(spec, usage = "[--port=<port>]")
    s.parseSpec(@[], "prog")
    check spec.port == 9090

  test "opt: an explicit CLI value overrides the env var":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    let s = newSpec(spec, usage = "[--port=<port>]")
    s.parseSpec(@["--port=1234"], "prog")
    check spec.port == 1234

  test "opt: an env value still goes through the option's validator":
    putEnv("ARGUMINT_TEST_PORT", "99999")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT",
        validator = range(1..65535), help = ""),
    )
    let s = newSpec(spec, usage = "[--port=<port>]")
    expect ValidationError:
      s.parseSpec(@[], "prog")

  test "opt: neither CLI nor env set falls back to the coded default":
    delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = ""),
    )
    let s = newSpec(spec, usage = "[--port=<port>]")
    s.parseSpec(@[], "prog")
    check spec.port == 8080

  test "flag: env value is converted and applied via =, CLI flag overrides":
    putEnv("ARGUMINT_TEST_VERBOSE", "5")
    defer: delEnv("ARGUMINT_TEST_VERBOSE")
    let spec = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    let s = newSpec(spec, usage = "[--verbose]...")
    s.parseSpec(@[], "prog")
    check spec.verbosity == 5

    let spec2 = (
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = ""),
    )
    let s2 = newSpec(spec2, usage = "[--verbose]...")
    s2.parseSpec(@["--verbose"], "prog")
    check spec2.verbosity == 1 # CLI's own increment op wins; env is skipped entirely

  test "a required option's env var does not satisfy the requirement":
    putEnv("ARGUMINT_TEST_PORT", "9090")
    defer: delEnv("ARGUMINT_TEST_PORT")
    let spec = (
      port: opt("--port=<port>", env = "ARGUMINT_TEST_PORT", help = ""),
    )
    let s = newSpec(spec, usage = "--port=<port>")
    expect ParseError:
      s.parseSpec(@[], "prog")

  test "[env: X] appears in help text for opt and flag, combined with other annotations":
    let spec = (
      port: opt("--port=<port>", default = 8080, env = "ARGUMINT_TEST_PORT", help = "Port"),
      verbosity: flag[int]("--verbose", default = 0, env = "ARGUMINT_TEST_VERBOSE", help = "Verbosity"),
      help: help(),
    )
    let s = newSpec(spec, maxVariantsWidth = 0)
    var helpText = ""
    try:
      s.parseSpec(@["--help"], "prog")
    except HelpError as e:
      helpText = e.msg
    check "Port [default: 8080; env: ARGUMINT_TEST_PORT]" in helpText
    check "Verbosity [env: ARGUMINT_TEST_VERBOSE]" in helpText

  test "SpecDefect raised when env is given for a flag type whose handler doesn't support =":
    expect SpecDefect:
      discard flag[Speed]("--speed", default = slow, env = "ARGUMINT_TEST_SPEED", help = "")
