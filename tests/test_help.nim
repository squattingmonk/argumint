# Locks `genHelp`'s semi-public status -- see
# `docs/adr/0042-genhelp-opt-in-via-submodule.md`.
# `tests/test_public_api.nim` holds the other half (a bare `import argumint`
# can't reach it); neither half means much alone.

import std/[strutils, unittest]

import argumint
import argumint/help

proc greeter(): Spec =
  newSpec((
    name: arg("<name>", help = "Who to greet"),
    times: opt("--times=<n>", default = 1, help = "How many times"),
    help: help(),
  ), prolog = "Greeter.", epilog = "See the README.",
     usage = "<name> [--times=<n>]", settings = newSpecSettings(style = nil))

suite "`genHelp` is callable by importing `argumint/help` directly":
  test "it renders the full message without raising":
    let text = greeter().genHelp("greet")
    check text.startsWith("Greeter.")
    check text.endsWith("See the README.")
    check "  greet <name> [--times=<n>]" in text
    check "Who to greet" in text
    check "How many times [default: 1]" in text

  test "`command` names the program in the usage lines":
    # `HelpArg.action` passes the command path that reached the Spec, which
    # is why a subcommand's help reads `prog ship move`.
    check "  navalfate <name>" in greeter().genHelp("navalfate")

  test "it returns exactly what `--help` would have raised":
    # The affordance is "render it yourself instead of catching HelpError",
    # so the two must not drift apart.
    let direct = greeter().genHelp("greet")
    var raised = ""
    try:
      greeter().parse(args = @["--help"], command = "greet")
    except HelpError as e:
      raised = e.msg
    check raised == direct

suite "a custom `HelpFormatter` can be written with only `argumint/help`":
  # Regression for the formatter seam being unusable outside the library:
  # before `helpGroups` and the `prolog`/`epilog`/`usage` accessors, a
  # formatter had no way to reach a Spec's groups -- see
  # `docs/adr/0048-pluggable-help-formatters.md`.
  proc formatShouty(spec: Spec, command: string): string =
    var groups: seq[string]
    for name, args in spec.helpGroups:
      var lines = @[name.toUpperAscii & ":"]
      for arg in args:
        for row in arg.rows:
          lines.add "  " & row.variants.render & " -- " & row.text.render
      groups.add lines.join("\n")
    let usage = "USAGE:\n" & spec.usage.usageLines(command, spec.settings.width).render
    joinSections(spec.prolog, usage, joinSections(groups), spec.epilog)

  test "it controls the whole message, including section labels":
    let expected = """
      Greeter.

      USAGE:
        greet <name> [--times=<n>]
        greet (-h | --help)

      ARGUMENTS:
        <name> -- Who to greet

      OPTIONS:
        --times=<n> -- How many times [default: 1]
        -h, --help -- Display this help message

      See the README.""".dedent
    check greeter().genHelp("greet", formatShouty) == expected

  test "a matched `help()` renders through it":
    let spec = newSpec((
      name: arg("<name>", help = "Who to greet"),
      help: help(formatter = formatShouty),
    ), usage = "<name>")
    var raised = ""
    try:
      spec.parse(args = @["--help"], command = "greet")
    except HelpError as e:
      raised = e.msg
    check raised.startsWith("USAGE:\n  greet <name>")

  test "`Row`'s fields are styled text":
    let row = arg("<name>", help = "Who to greet").rows[0]
    check row.variants is StyledText
    check row.text.plain == "Who to greet"

  test "the span helpers are enough to lay out a row":
    # The built-ins' layout rule -- see docs/architecture.md.
    let row = Row(variants: styled("-x"), text: styled("some help text"))
    var lines: seq[StyledText]
    for i, text in row.text.wrap(9):
      let variants = if i == 0: row.variants else: StyledText()
      lines.add variants.alignLeft(4) & text
    check lines.render == "-x  some help\n    text"

  test "the Spec accessors read with or without parentheses, but can't be assigned":
    let spec = greeter()
    check spec.prolog == "Greeter."
    check spec.epilog() == "See the README."
    check spec.usage == "<name> [--times=<n>]\n(-h | --help)"
    check not compiles(spec.prolog = "Changed.")
    check not compiles(spec.usage = "<other>")
