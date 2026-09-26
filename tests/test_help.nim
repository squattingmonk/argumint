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

  test "with a styler, msg stays plain and styledMsg is what genHelp renders":
    proc tagged(role: StyleRole, text: string): string = "{" & $role & ":" & text & "}"
    proc build(style: Styler): Spec =
      newSpec((name: arg("<name>", help = "Who to `greet`"), help: help()),
        settings = newSpecSettings(style = style))
    var e: ref HelpError
    try: build(tagged).parse(args = @["--help"], command = "greet")
    except HelpError as err: e = err
    check e.msg == build(nil).genHelp("greet")
    check e.styledMsg == build(tagged).genHelp("greet")
    check e.styledMsg != e.msg

  test "without a styler, styledMsg is msg":
    var e: ref HelpError
    try: greeter().parse(args = @["--help"], command = "greet")
    except HelpError as err: e = err
    check e.styledMsg == e.msg

  test "a formatter reaches rows and prose only through the Help Context":
    # Raw builders skip the tick decision; see docs/adr/0057-help-context.md.
    let a = arg("<name>", help = "Who")
    check not compiles(a.rows)
    check not compiles("Some `-x`.".markup)
    check not declared(proseLines)
    check not declared(annotations)
    check not declared(variantsByDesc)
    check not declared(helpGroups)
    check declared(helpContext)
    check declared(usageLines)
    check not declared(wrapProse)
    check not declared(toProse)
    check not declared(annotate)
    check not declared(summary)
    check not declared(splitUsage)
    check not declared(usageBlock)
    check declared(Prose)
    check declared(joinSections)
    check declared(longOrShort)

  test "style.nim's shared plain-text and option helpers stay withheld":
    check not declared(firstParagraph)
    check not declared(dedentLines)
    check not declared(styledOption)
    check not compiles([styled("a")].join(styled(", ")))

suite "a custom `HelpFormatter` can be written with only `argumint/help`":
  # Regression for the formatter seam being unusable outside the library --
  # see `docs/adr/0048-pluggable-help-formatters.md`, and
  # `docs/adr/0057-help-context.md` for what a formatter is handed.
  proc formatShouty(ctx: HelpContext): string =
    let width = max(ctx.width, 24)
    var groups: seq[string]
    for name, args in ctx.groups:
      var lines = @[name.toUpperAscii & ":"]
      for arg in args:
        for row in ctx.rows(arg):
          lines.add "  " & ctx.render(row.variants)
          for line in row.text.wrap(width - 4):
            lines.add "    " & ctx.render(line)
      groups.add lines.join("\n")
    joinSections(ctx.render(ctx.prose(ctx.spec.prolog).wrap(width)),
      "USAGE:\n" & ctx.render(ctx.usage),
      joinSections(groups), ctx.render(ctx.prose(ctx.spec.epilog).wrap(width)))

  proc tagged(role: StyleRole, text: string): string =
    ## Marks each styled span as `{role:text}`, leaving plain ones bare.
    if role == srPlain: text
    else: "{" & ($role)[2 .. ^1].toLowerAscii & ":" & text & "}"

  test "it controls the whole message, including section labels":
    let expected = """
      Greeter.

      USAGE:
        greet <name> [--times=<n>]
        greet (-h | --help)

      ARGUMENTS:
        <name>
          Who to greet

      OPTIONS:
        --times=<n>
          How many times [default: 1]
        -h, --help
          Display this help message

      See the README.""".dedent
    check greeter().genHelp("greet", formatShouty) == expected

  test "a matched `help()` renders through it":
    let spec = newSpec((
      name: arg("<name>", help = "Who to greet"),
      help: help(formatter = formatShouty),
    ), usage = "<name>", settings = newSpecSettings(style = nil))
    var raised = ""
    try:
      spec.parse(args = @["--help"], command = "greet")
    except HelpError as e:
      raised = e.msg
    check raised.startsWith("USAGE:\n  greet <name>")

  test "styled, it drops Help Markup's backticks like the built-ins":
    # See docs/adr/0057-help-context.md.
    let spec = newSpec((
      name: arg("<name>", help = "Who to greet, or `--all`"),
    ), prolog = "Greets `<name>`.", usage = "<name>",
       settings = newSpecSettings(style = tagged))
    let help = spec.genHelp("greet", formatShouty)
    check "{option:--all}" in help
    check "{positional:<name>}." in help
    check '`' notin help

  test "it reads the command path from the context":
    # Also in scope: `argumint`'s `command` constructors, which need a spec.
    let echoing = proc (ctx: HelpContext): string = ctx.command
    check greeter().genHelp("greet sub", echoing) == "greet sub"

  test "`Row`'s variants are styled text, and its text is Prose":
    let
      ctx = greeter().helpContext("greet")
      row = ctx.rows(arg("<name>", help = "Who to greet"))[0]
    check row.variants is StyledText
    check row.text is Prose
    check ctx.render(row.text.wrap(80)) == "Who to greet"
    check not compiles(ctx.render(row.text))
    check not compiles(row.text.plain)

  test "the span helpers are enough to lay out a row":
    # The built-ins' layout rule -- see docs/architecture.md.
    let row = greeter().helpContext("greet").rows(flag("-x", help = "some help text"))[0]
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
