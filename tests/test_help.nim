# Locks `genHelp`'s semi-public status -- see
# `docs/adr/0042-genhelp-opt-in-via-submodule.md`.
# `tests/test_public_api.nim` holds the other half (a bare `import argumint`
# can't reach it); neither half means much alone.

import std/[strutils, sugar, unittest]

import argumint
import argumint/help

proc greeter(): Spec =
  newSpec((
    name: arg("<name>", help = "Who to greet"),
    times: opt("--times=<n>", default = 1, help = "How many times"),
    help: help(),
  ), prolog = "Greeter.", epilog = "See the README.",
     usage = "<name> [--times=<n>]", settings = newSpecSettings(style = nil))

proc helpRaised(spec: Spec, command: string): ref HelpError =
  ## The `HelpError` that `--help` raises for `spec`.
  try: spec.parse(args = @["--help"], command = command)
  except HelpError as e: result = e
  doAssert not result.isNil, "--help raised no HelpError"

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
    check greeter().helpRaised("greet").msg == greeter().genHelp("greet")

  test "with a styler, msg stays plain and styledMsg is what genHelp renders":
    proc tagged(role: StyleRole, text: string): string = "{" & $role & ":" & text & "}"
    proc build(style: Styler): Spec =
      newSpec((name: arg("<name>", help = "Who to `greet`"), help: help()),
        settings = newSpecSettings(style = style))
    let e = build(tagged).helpRaised("greet")
    check e.msg == build(nil).genHelp("greet")
    check e.styledMsg == build(tagged).genHelp("greet")
    check e.styledMsg != e.msg

  test "without a styler, styledMsg is msg":
    let e = greeter().helpRaised("greet")
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
    check not declared(wrapProse)
    check not declared(toProse)
    check not declared(annotate)
    check not declared(summary)
    check not declared(splitUsage)
    check not declared(usageBlock)
    check declared(Prose)
    check declared(joinSections)
    check declared(longOrShort)

  test "the toolkit has no pass-throughs for what the context hands out":
    # See docs/adr/0075-help-formatters-build-on-the-help-frame.md.
    check not declared(usageLines)
    check not compiles(greeter().helpContext("p").heading("Options"))
    check not compiles(greeter().usage)
    check not declared(Span)
    check not compiles([styled("a")].render)
    check not compiles(styled("a").plain)
    check not compiles(styled("a").withoutTicks)
    check declared(frame)
    check declared(RowRenderer)
    check declared(HelpTextForm)
    check MinWidth == 20

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
    var groups: seq[string]
    for name, args in ctx.groups:
      var lines = @[name.toUpperAscii & ":"]
      for arg in args:
        for row in ctx.rows(arg):
          lines.add "  " & ctx.render(row.variants)
          for line in row.text.wrap(ctx.width - 4):
            lines.add "    " & ctx.render(line)
      groups.add lines.join("\n")
    joinSections(ctx.render(ctx.prose(ctx.spec.prolog).wrap(ctx.width)),
      "USAGE:\n" & ctx.render(ctx.usage),
      joinSections(groups), ctx.render(ctx.prose(ctx.spec.epilog).wrap(ctx.width)))

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
    check spec.helpRaised("greet").msg.startsWith("USAGE:\n  greet <name>")

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
    let
      ctx = greeter().helpContext("greet")
      row = ctx.rows(flag("-x", help = "some help text"))[0]
    var lines: seq[StyledText]
    for i, text in row.text.wrap(9):
      let variants = if i == 0: row.variants else: StyledText()
      lines.add variants.alignLeft(4) & text
    check ctx.render(lines) == "-x  some help\n    text"

  test "the Spec accessors read with or without parentheses, but can't be assigned":
    let spec = greeter()
    check spec.prolog == "Greeter."
    check spec.epilog() == "See the README."
    check not compiles(spec.prolog = "Changed.")

suite "a custom `HelpFormatter` can build on the Help Frame":
  # See the Help Frame entry in GLOSSARY.md.
  proc formatCompact(ctx: HelpContext): string =
    ctx.frame(proc (rows: seq[Row]): seq[StyledText] =
      for row in rows:
        result.add styled("  ") & row.variants
        for line in row.text.wrap(ctx.width - 6):
          result.add styled("      ") & line)

  test "it writes only the rows; the frame writes the rest":
    let expected = """
      Greeter.

      Usage:
        greet <name> [--times=<n>]
        greet (-h | --help)

      Arguments:
        <name>
            Who to greet

      Options:
        --times=<n>
            How many times [default: 1]
        -h, --help
            Display this help message

      See the README.""".dedent
    check greeter().genHelp("greet", formatCompact) == expected

  test "the frame renders the rows with the Spec's Styler":
    proc tagged(role: StyleRole, text: string): string =
      if role == srPlain: text else: "{" & $role & ":" & text & "}"
    let spec = newSpec((name: arg("<name>", help = "Who"),),
      usage = "<name>", settings = newSpecSettings(style = tagged))
    check "  {srPositional:<name>}\n      Who" in spec.genHelp("greet", formatCompact)

  test "a Long form shows Long-Form Help Text where declared":
    let spec = newSpec((
      name: arg("<name>", help = (short: "Who", long: "Who, at length")),
      times: opt("--times=<n>", help = "How many"),
    ), usage = "<name> [--times=<n>]", settings = newSpecSettings(style = nil))
    let long = proc (ctx: HelpContext): string =
      let textOnly = proc (rows: seq[Row]): seq[StyledText] =
        for row in rows: result.add row.text.wrap(ctx.width)[0]
      ctx.frame(textOnly, HelpTextForm.Long)
    let help = spec.genHelp("p", long)
    check "Who, at length" in help
    check "How many" in help

suite "a custom `HelpFormatter` can show fewer Args with `filter`":
  # The Args stay in the Spec, so they parse; only help leaves them out.
  let format = opt("--format=<fmt>", default = "json", help = "Output format")

  proc withoutFormat(ctx: HelpContext): string =
    formatColumn(ctx.filter((arg) => arg != Arg(format)))

  proc helpOf(spec: tuple): string =
    newSpec(spec, settings = newSpecSettings(style = nil)).helpRaised("cfg").msg

  test "help leaves out the Args the filter drops":
    check helpOf((format: format, verbose: flag("-v", help = "Talk more"),
      help: help(formatter = withoutFormat))) == """
      Usage:
        cfg [options]
        cfg (-h | --help)

      Options:
        -v          Talk more
        -h, --help  Display this help message""".dedent

  test "another Spec holding the same Arg still shows it":
    check helpOf((format: format, help: help())) == """
      Usage:
        cfg [options]
        cfg (-h | --help)

      Options:
        --format=<fmt>  Output format [default: "json"]
        -h, --help      Display this help message""".dedent

  test "the Args it drops still parse":
    let spec = (format: format, help: help(formatter = withoutFormat))
    spec.parse(args = @["--format=yaml"], command = "cfg")
    check spec.format == "yaml"

suite "a custom `HelpFormatter` can leave out Help Annotations with `filterAnnotations`":
  # Issue #345's program: every option has a Config Key, and the Flag's
  # `validator` help repeats on each of its rows.
  type Level {.pure.} = enum debug, verbose, normal, quiet

  proc logging(formatter: HelpFormatter = formatColumn): tuple =
    (level: flag(default = Level.normal, configKey = "logLevel",
      validator = choice([Level.debug, Level.verbose, Level.normal, Level.quiet]),
      ops = [
        flagOp("--quiet", "=", Level.quiet, help = "Log errors only"),
        flagOp("--verbose", "=", Level.verbose, help = "Log more"),
      ]),
    port: opt("--port=<n>", default = 80, configKey = configKey("server", "port"),
      help = "Port"),
    help: help(formatter = formatter))

  proc helpOf(spec: tuple): string =
    newSpec(spec, settings = newSpecSettings(style = nil)).helpRaised("ann").msg

  test "with no filter, every Help Annotation shows":
    check helpOf(logging()) == """
      Usage:
        ann [options]
        ann (-h | --help)

      Options:
        --quiet     Log errors only [env/config values: choices: debug, verbose,
                    normal, quiet; configKey: logLevel]
        --verbose   Log more [env/config values: choices: debug, verbose, normal,
                    quiet; configKey: logLevel]
        --port=<n>  Port [default: 80; configKey: server.port]
        -h, --help  Display this help message""".dedent

  test "help leaves out the kinds the predicate drops":
    proc terse(ctx: HelpContext): string =
      formatColumn(ctx.filterAnnotations((arg, a) => a.kind notin {haConfigKey, haValidator}))
    check helpOf(logging(terse)) == """
      Usage:
        ann [options]
        ann (-h | --help)

      Options:
        --quiet     Log errors only
        --verbose   Log more
        --port=<n>  Port [default: 80]
        -h, --help  Display this help message""".dedent

  test "the predicate can decide by the Arg":
    proc noFlagValues(ctx: HelpContext): string =
      formatColumn(ctx.filterAnnotations((arg, a) =>
        not (arg.kind == ArgKind.Flag and a.kind == haValidator)))
    check helpOf((
      verbose: flag("-v", env = "VERBOSE", validator = range(0..3), help = "Talk more"),
      port: opt("--port=<n>", default = 80, validator = range(1..65535), help = "Port"),
      help: help(formatter = noFlagValues))) == """
      Usage:
        ann [options]
        ann (-h | --help)

      Options:
        -v          Talk more [env: VERBOSE]
        --port=<n>  Port [range: 1..65535; default: 80]
        -h, --help  Display this help message""".dedent
