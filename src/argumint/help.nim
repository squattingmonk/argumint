## Help-text rendering: turns a built `Spec` into the message `--help`
## prints. Sits directly above `argumint/backend` -- see
## `docs/architecture.md` for why, and for how the variants column wraps.
##
## `import argumint` alone does not bring `genHelp` into scope; importing
## this module directly is what makes it callable, so a program can render
## its own help instead of only receiving it via the `HelpError` a matched
## `help*` Arg raises -- see
## `docs/adr/0042-genhelp-opt-in-via-submodule.md`.

import std/[importutils, pegs, strformat, strutils, tables, wordwrap]

import ./backend

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see docs/gotchas.md.

type
  Row = tuple[variants, text: string]
    ## One line-item in the help table, still unwrapped: `variants` is a
    ## variant-group's names joined by ", "; `text` is its resolved help plus
    ## `[...]` annotations. `render` turns this into output lines.

const Margin = "  "
const ContinuationIndent = "    "
const CanonicalGroups = ["Commands", "Arguments", "Options"]

proc annotations(arg: Arg, action = ""): seq[string] =
  ## The `[...]` bracket's parts, in display order: validator, default, env,
  ## configKey, then `action` (non-empty only for a divergent flag's own
  ## `variantDesc`).
  let validatorHelp = arg.validatorHelp()
  if validatorHelp.len > 0:
    result.add validatorHelp
  if arg.defaultStr.len > 0:
    result.add fmt"default: {arg.defaultStr}"
  if arg.envName.len > 0:
    result.add fmt"env: {arg.envName}"
  let configKey = arg.configKey()
  if configKey.len > 0:
    result.add fmt"configKey: {configKey.join}"
  if action.len > 0:
    result.add fmt"action: {action}"

proc groupOrder(spec: Spec): seq[string] =
  ## Returns `spec.groups`' keys ordered as `Commands`, `Arguments`, `Options`,
  ## then any other (e.g. user-defined) groups in declaration order.
  for group in CanonicalGroups:
    if group in spec.groups:
      result.add group
  for group in spec.groups.keys:
    if group notin CanonicalGroups:
      result.add group

proc variantGroups(arg: Arg): seq[tuple[names: seq[string], desc: string]] =
  ## Groups `arg.variants` by their `variantDesc` text, preserving declaration
  ## order (both across groups and within one). Collapses to exactly one group
  ## (`desc` possibly `""`) whenever every variant shares the same description
  ## -- i.e. every arg that isn't a flag with genuinely divergent per-variant
  ## ops -- so callers that don't care about grouping still see a single group
  ## covering all of `arg.variants`.
  var byDesc = initOrderedTable[string, seq[string]]()
  for v in arg.variants:
    byDesc.mgetOrPut(arg.variantDesc(v), @[]).add v
  for desc, names in byDesc.pairs:
    result.add (names: names, desc: desc)

proc rows(arg: Arg): seq[Row] =
  ## One Row per `arg.variantGroups()`. Text is `arg.help`, falling back to the
  ## group's own `variantDesc` when the arg's variants diverge and that group's
  ## `variantDesc` is non-empty, plus the `[...]` bracket from `annotations`
  ## (`action` included only when divergent AND `arg.help` is non-empty).
  ## Callers filter `arg.hidden` on themselves.
  let groups = arg.variantGroups()
  for vg in groups:
    let
      divergent = groups.len > 1 and vg.desc.len > 0
      primary = if arg.help.len > 0: arg.help elif divergent: vg.desc else: ""
      action = if divergent and arg.help.len > 0: vg.desc else: ""
      annotations = arg.annotations(action = action)
      bracket = if annotations.len > 0: "[{annotations.join(\"; \")}]".fmt else: ""
      text = if bracket.len == 0: primary elif primary.len == 0: bracket else: fmt"{primary} {bracket}"
    result.add (variants: vg.names.join(", "), text: text)

proc variantsColWidth(spec: Spec): int =
  ## Widest single variant-group's joined names across every arg in `spec`
  ## (including hidden ones -- existing behavior unchanged), capped at
  ## `spec.settings.maxVariantsWidth` unless 0 (unlimited). Built on `rows()`.
  for arg in spec.args:
    for row in arg.rows:
      if row.variants.len > result:
        result = row.variants.len
  if spec.settings.maxVariantsWidth > 0 and result > spec.settings.maxVariantsWidth:
    result = spec.settings.maxVariantsWidth

proc render(rows: seq[Row], width: int, colWidth: int): string =
  ## Wraps + zips `rows` into the table's text block: variants wrap at
  ## `colWidth`, text wraps at `max(width - (2 + colWidth + 2), 20)`, zipped
  ## line-by-line. First line of a row gets `Margin`; wrap continuations get
  ## `ContinuationIndent`. Rows join with "\n".
  let helpWidth = max(width - (colWidth + 4), 20)
  var argLines = newSeq[string]()
  for row in rows:
    let variantLines = row.variants.wrapWords(colWidth, splitLongWords = false).splitLines
    if row.text.len > 0:
      let textLines = row.text.wrapWords(helpWidth, splitLongWords = false).splitLines
      for j in 0 ..< max(variantLines.len, textLines.len):
        let
          v = if j < variantLines.len: variantLines[j] else: ""
          t = if j < textLines.len: textLines[j] else: ""
        if t.len > 0:
          let rowMargin = if j == 0: Margin else: ContinuationIndent
          argLines.add(fmt"{rowMargin}{v.alignLeft(colWidth)}{Margin}{t}")
        elif j > 0:
          argLines.add(fmt"{ContinuationIndent}{v}")
        else:
          argLines.add(fmt"{Margin}{v}")
    else:
      for j, v in variantLines:
        if j > 0:
          argLines.add(fmt"{ContinuationIndent}{v}")
        else:
          argLines.add(fmt"{Margin}{v}")
  if argLines.len > 0:
    result.addSep("\n")
    result.add argLines.join("\n")

proc usageLines(usage: string): seq[string] =
  ## Splits a usage message into usage lines. Lines prefixed with whitespace are
  ## treated as belonging to the previous usage line. Blank lines (and even a
  ## blank usage message) are treated as a blank usage line.
  for line in usage.splitLines:
    if result.len > 0 and line.startsWith(peg"\s"):
      result[^1] = fmt"{result[^1]} {line.strip}".strip
    else:
      result.add line.strip

proc formatUsage*(usage: string, command: string, width = DefaultWidth): string =
  ## Formats `usage` (a spec's raw usage string, one alternative per line) as
  ## a "Usage:" block, prefixing each alternative with `command`. Lines
  ## longer than `width` are wrapped, with continuations hanging-indented to
  ## align under the first token after `command` rather than restarting at
  ## the left margin.
  var lines = @["Usage:"]
  let
    prefix = "{Margin}{command} ".fmt
    indent = ' '.repeat(prefix.len)
    lineWidth = max(width, 20)

  for line in usage.usageLines:
    lines.add fmt"{prefix}{line}".wrapWords(lineWidth,
      splitLongWords = false, newLine = "\n{indent}".fmt)
  result = lines.join("\n")

proc genHelp*(spec: Spec, command: string): string =
  ## Renders `spec`'s full help message -- prolog, wrapped usage lines, one row
  ## per arg grouped per `groupOrder`, then epilog. `command` names the program
  ## in the usage lines (`HelpArg.action` passes the command path that reached
  ## this Spec, so a subcommand's help reads `prog ship move`). Wrapping is
  ## governed by `spec.settings.width`/`maxVariantsWidth`.
  let
    prolog = if spec.prolog.len > 0: spec.prolog & "\n\n" else: ""
    epilog = if spec.epilog.len > 0: "\n\n" & spec.epilog else: ""
    usage = spec.usage.formatUsage(command, spec.settings.width)
    colWidth = spec.variantsColWidth()

  var lines: seq[string]
  for group in spec.groupOrder:
    var groupRows: seq[Row]
    for arg in spec.groups[group]:
      if arg.hidden:
        continue
      groupRows.add arg.rows()
    if groupRows.len > 0:
      lines.add("\n{group}".fmt)
      lines.add(groupRows.render(spec.settings.width, colWidth))

  if lines.len > 0:
    lines.insert ""
  let args = lines.join("\n")
  result = fmt"{prolog}{usage}{args}{epilog}"

when isMainModule:
  import std/[options, unittest]
  import ./[configsource, specbuild]

  type
    TestArg = ref object of Arg
      validatorHelpVal, defaultStrVal: string
      env: Option[EnvSource]
      cfg: ConfigKey
      descs: Table[string, string]

  method validatorHelp(self: TestArg): string = self.validatorHelpVal
  method defaultStr(self: TestArg): string = self.defaultStrVal
  method envSource(self: TestArg): Option[EnvSource] = self.env
  method configKey(self: TestArg): ConfigKey = self.cfg
  method variantDesc(self: TestArg, variant: string): string =
    self.descs.getOrDefault(variant, "")

  suite "annotations":
    test "an arg with nothing set has no annotations":
      check Arg().annotations().len == 0

    test "includes validatorHelp when non-empty":
      let arg = TestArg(validatorHelpVal: "validatorHelp")
      check arg.annotations() == @["validatorHelp"]

    test "includes default when non-empty":
      let arg = TestArg(defaultStrVal: "defaultStr")
      check arg.annotations() == @["default: defaultStr"]

    test "includes env if set":
      let arg = TestArg(env: "TEST_ARG_ENV")
      check arg.annotations() == @["env: TEST_ARG_ENV"]

    test "includes configKey if set":
      let arg = TestArg(cfg: configKey("section", "key"))
      check arg.annotations() == @["configKey: section.key"]

    test "includes action if non-empty":
      check Arg().annotations(action = "foo") == @["action: foo"]

    test "order: validatorHelp, default, env, config, action":
      let
        arg = TestArg(
          validatorHelpVal: "v",
          defaultStrVal: "d",
          env: "e",
          cfg: "k"
        )
        expected = @[
          "v",
          "default: d",
          "env: e",
          "configKey: k",
          "action: a"
        ]
      check arg.annotations(action = "a") == expected

  suite "variantGroups":
    test "an arg with no variants has no groups":
      check Arg().variantGroups().len == 0

    test "variants with no variant-specific description are grouped with an empty desc":
      check Arg(variants: @["-v", "--verbose"], help: "Verbosity").variantGroups() ==
        @[(names: @["-v", "--verbose"], desc: "")]

    test "variants with variant-specific descriptions are grouped by desc":
      let
        arg = TestArg(
          variants: @["-d", "--down", "-u", "--up"],
          descs: {"-d": "Move down", "--down": "Move down", "-u": "Move up", "--up": "Move up"}.toTable)
        expected = @[
          (names: @["-d", "--down"], desc: "Move down"),
          (names: @["-u", "--up"], desc: "Move up")]
      check arg.variantGroups() == expected

  suite "rows":
    # Variants are grouped into a row by description. A group is considered
    # divergent if it is not the only group and if its variantDesc is non-empty.
    test "a non-divergent variant group gets one row with the arg's help text":
      check TestArg(variants: @["<name>"], help: "Who to greet").rows() ==
        @[(variants: "<name>", text: "Who to greet")]

    test "a single group is non-divergent and ignores variantDesc":
      let
        arg = TestArg(
          variants: @["-v"],
          help: "Verbosity",
          descs: {"-v": "Increase verbosity"}.toTable)
        expected = @[(variants: "-v", text: "Verbosity")]
      check arg.rows() == expected

    test "a non-divergent group's help text is blank if arg.help is empty":
      let
        arg = TestArg(
          variants: @["-v"],
          descs: {"-v": "Increase verbosity"}.toTable)
        expected = @[(variants: "-v", text: "")]
      check arg.rows() == expected

    test "a divergent group's help text matches variantDesc if arg.help is empty":
      let
        arg = TestArg(
          variants: @["--direction", "--up", "--down"],
          descs: { "--up": "Move up", "--down": "Move down"}.toTable)
        expected = @[
          (variants: "--direction", text: ""),
          (variants: "--up", text: "Move up"),
          (variants: "--down", text: "Move down")]
      check arg.rows() == expected

    test "a divergent group's help text uses arg.help + action annotation if arg.help is not empty":
      let
        arg = TestArg(
          variants: @["--direction", "--up", "--down"],
          help: "Direction",
          descs: { "--up": "move up", "--down": "move down"}.toTable)
        expected = @[
          (variants: "--direction", text: "Direction"),
          (variants: "--up", text: "Direction [action: move up]"),
          (variants: "--down", text: "Direction [action: move down]")]
      check arg.rows() == expected

    test "variants with the same descriptions are joined with commas on one row":
      let
        arg = TestArg(
          variants: @["-d", "--direction", "-u", "--up"],
          help: "Direction",
          descs: {
            "-u": "move up",
            "--up": "move up"}.toTable)
        expected = @[
          (variants: "-d, --direction", text: "Direction"),
          (variants: "-u, --up", text: "Direction [action: move up]")]
      check arg.rows() == expected

    test "a non-divergent group's bracket appears alone, with no leading space, when arg.help is empty":
      let arg = TestArg(variants: @["--speed=<speed>"], defaultStrVal: "5")
      check arg.rows() == @[(variants: "--speed=<speed>", text: "[default: 5]")]

  suite "variantsColWidth":
    test "colWidth matches the length of the longest joined variants row across all args in the spec":
      let
        arg1 = Arg(variants: @["-x"])
        arg2 = Arg(variants: @["-s", "--speed=<speed>"])
        spec1 = Spec(args: @[arg1, arg2], settings: SpecSettings(maxVariantsWidth: 0))
        spec2 = Spec(args: @[arg2, arg1], settings: SpecSettings(maxVariantsWidth: 0))
      check spec1.variantsColWidth == "-s, --speed=<speed>".len
      check spec2.variantsColWidth == "-s, --speed=<speed>".len

    test "colWidth does not exceed maxVariantsWidth":
      let
        arg1 = Arg(variants: @["-x"])
        arg2 = Arg(variants: @["-s", "--speed=<speed>"])
        spec1 = Spec(args: @[arg1], settings: SpecSettings(maxVariantsWidth: 10))
        spec2 = Spec(args: @[arg2], settings: SpecSettings(maxVariantsWidth: 10))
      check spec1.variantsColWidth == "-x".len
      check spec2.variantsColWidth == 10

    test "colWidth is affected by hidden args":
      # Note: this matches existing behavior but is not desirable. Change this
      # later.
      let
        arg1 = Arg(variants: @["-x"])
        arg2 = Arg(variants: @["-s", "--speed=<speed>"], hidden: true)
        spec = Spec(args: @[arg1, arg2], settings: SpecSettings(maxVariantsWidth: 0))
      check spec.variantsColWidth == "-s, --speed=<speed>".len

  suite "render":
    test "a single row that fits on one line needs no wrapping":
      let
        row: Row = (variants: "-v", text: "Verbose")
        expected = "  -v          Verbose"
      check render(@[row], width = 80, colWidth = 10) == expected

    test "the variants column aligns to the given colWidth":
      let
        row: Row = (variants: "-v", text: "Verbose")
        expected = "  -v                    Verbose"
      check render(@[row], width = 80, colWidth = 20) == expected

    test "rows are joined with a newline, each keeping its own margin":
      let
        rows = @[
          (variants: "-v", text: "Verbose"),
          (variants: "--quiet", text: "Quiet")]
        expected = "  -v        Verbose\n  --quiet   Quiet"
      check render(rows, width = 80, colWidth = 8) == expected

    test "a row with no text shows only the variants, with no alignment padding or trailing whitespace":
      let
        row: Row = (variants: "-v, --verbose", text: "")
        expected  = "  -v, --verbose"
      check render(@[row], width = 80, colWidth = 20) == expected

    test "long help text wraps in its own column, indented deeper than the margin":
      let
        row: Row = (variants: "-x", text: "This is a moderately long help description")
        expected = "  -x     This is a moderately\n           long help description"
        rendered = render(@[row], width = 30, colWidth = 5)
      check rendered == expected

    test "a variant name longer than colWidth is not split mid-word":
      # FIXME: The split here is ugly. Filed as #70.
      let
        row = (variants: "--extraordinarily-long-option-name", text: "A really long option name")
        expected = "              A really long option\n    --extraordinarily-long-option-name  name"
        rendered = render(@[row], width = 30, colWidth = 10)

      check rendered == expected

    test "long help text words are not split mid-word":
      # FIXME: The split here is ugly. Filed as #70.
      let
        row = (variants: "-x", text: "a veryLongSingleWordThatExceedsTwentyCharacters")
        expected = "  -x          a\n                veryLongSingleWordThatExceedsTwentyCharacters"
        rendered = render(@[row], width = 30, colWidth = 10)

      check rendered == expected

    test "variants column and text columns wrap independently":
      let
        arg = Arg(
          variants: @["-v", "--verbose", "--quiet", "--boost", "--dampen"],
          help: "This is some help text that will need to be wrapped")
        expected = """
          -v, --verbose,        This is some help text that will
            --quiet, --boost,     need to be wrapped
            --dampen
        """.strip(leading = false).dedent.indent(2)
        rendered = render(arg.rows(), width = 60, colWidth = 20)

      check rendered == expected

    test "multiple rows are wrapped independently, not interleaved":
      let
        rows = @[
          (variants: "-x", text: "This is a moderately long help description"),
          (variants: "-q", text: "Be quiet")]
        expected = """
          -x     This is a moderately
                   long help description
          -q     Be quiet
        """.strip(leading = false).dedent.indent(2)
        rendered = render(rows, width = 30, colWidth = 5)

      check rendered == expected

  suite "groupOrder":
    test "canonical groups appear in Commands, Arguments, Options order regardless of insertion order":
      var groups = initOrderedTable[string, seq[Arg]]()
      groups["Options"] = @[]
      groups["Commands"] = @[]
      groups["Arguments"] = @[]
      check Spec(groups: groups).groupOrder() == @["Commands", "Arguments", "Options"]

    test "a spec missing a canonical group skips it without leaving a gap":
      for group in CanonicalGroups:
        var groups = initOrderedTable[string, seq[Arg]]()
        for g in CanonicalGroups:
          groups[g] = @[]
        groups.del(group)
        var expected: seq[string]
        for g in CanonicalGroups:
          if g != group: expected.add g
        check Spec(groups: groups).groupOrder() == expected

    test "user-defined groups are appended after canonical groups in insertion order":
      var groups = initOrderedTable[string, seq[Arg]]()
      groups["Global Options"] = @[]
      groups["Options"] = @[]
      groups["Another Group"] = @[]
      check Spec(groups: groups).groupOrder() == @["Options", "Global Options", "Another Group"]

  suite "usageLines":
    test "a blank usage message is one blank usage line":
      check usageLines("") == @[""]

    test "a usage message with no newlines is one usage line":
      check usageLines("<foo> [--bar]") == @["<foo> [--bar]"]

    test "each line in a usage message is another usage line":
      check usageLines("<foo>\n--bar") == @["<foo>", "--bar"]

    test "blank lines count as their own usage lines":
      check usageLines("<foo>\n") == @["<foo>", ""]
      check usageLines("\n<foo>") == @["", "<foo>"]

    test "lines prefixed with whitespace belong to the previous usage line":
      check usageLines("<foo>\n  --bar") == @["<foo> --bar"]

    test "if the first line is prefixed with whitespace, it is still its own line":
      check usageLines("  <foo>") == @["<foo>"]

    test "leading and trailing whitespace are removed from usage lines":
      check usageLines("<foo>  ") == @["<foo>"]
      check usageLines("  <foo>") == @["<foo>"]

    test "a blank line can be continued if the following line is prefixed by whitespace":
      check usageLines("\n  <foo>") == @["<foo>"]
      check usageLines("<foo>\n\n  <bar>") == @["<foo>", "<bar>"]

    test "usage lines containing only whitespace belong to the previous usage line":
      check usageLines("<foo>\n  ") == @["<foo>"]
      check usageLines("<foo>\n  \n  <bar>") == @["<foo> <bar>"]

  suite "formatUsage":
    test "a blank usage message is still prefixed with the command name":
      check formatUsage("", "prog") == "Usage:\n  prog"

    test "a single usage line is prefixed with the command name":
      check formatUsage("<foo> [--bar]", "prog") == "Usage:\n  prog <foo> [--bar]"

    test "multiple usage lines are each prefixed by the command name":
      check formatUsage("<foo>\n<bar>", "prog") == "Usage:\n  prog <foo>\n  prog <bar>"

    test "blank lines get the command name prefix":
      check formatUsage("\n<foo>", "prog") == "Usage:\n  prog\n  prog <foo>"
      check formatUsage("<foo>\n", "prog") == "Usage:\n  prog <foo>\n  prog"
      check formatUsage("<foo>\n\n", "prog") == "Usage:\n  prog <foo>\n  prog\n  prog"
      check formatUsage("<foo>\n\n<bar>", "prog") == "Usage:\n  prog <foo>\n  prog\n  prog <bar>"
      check formatUsage("<foo>\n\n  <bar>", "prog") == "Usage:\n  prog <foo>\n  prog <bar>"

    test "lines beginning with whitespace are joined to the previous usage line":
      check formatUsage("<foo>\n  <bar>\n<baz>", "prog") == "Usage:\n  prog <foo> <bar>\n  prog <baz>"

    test "usage lines are wrapped to width with a hanging indent matching command prefix length":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)\n<foobar>"
      check formatUsage(usage, "prog", width = 40) == "Usage:\n  prog <foo> [--bar] (--baz |\n       --qux=<qux>)\n  prog <foobar>"

    test "min width for a usage line is 20":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)\n<foobar>"
      check formatUsage(usage, "prog", width = 10) == "Usage:\n  prog <foo> [--bar]\n       (--baz |\n       --qux=<qux>)\n  prog <foobar>"

    test "words longer than width are not split when wrapping":
      let usage = "<foo> [--bar --aVeryLongOptionName"
      check formatUsage(usage, "prog", width = 20) == "Usage:\n  prog <foo> [--bar\n       --aVeryLongOptionName"

  suite "genHelp":
    test "a spec with no prolog, epilog, args, or groups returns a usage block with a bare command usage line":
      let spec = Spec(settings: newSpecSettings())
      check spec.genHelp(command = "prog") == "Usage:\n  prog"

    test "a spec with nothing but a usage string shows a usage block with that usage string":
      let
        spec = Spec(settings: newSpecSettings(), usage: "<foo> [--bar]")
        actual = spec.genHelp(command = "prog")
        expected = "Usage:\n  prog <foo> [--bar]"

      check actual == expected

    test "prolog appears at the beginning of the message when set, separated by two newlines":
      let spec = Spec(settings: newSpecSettings(), prolog: "foo")
      check spec.genHelp(command = "prog") == "foo\n\nUsage:\n  prog"

    test "epilog appears at the end of the message when set, separated by two newlines":
      let spec = Spec(settings: newSpecSettings(), epilog: "bar")
      check spec.genHelp(command = "prog") == "Usage:\n  prog\n\nbar"

    test "a spec with one group containing one arg lists the arg's row under the group name, below usage":
      let
        spec = newSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")))
        expected = """
        Usage:
          prog <foo>

        Arguments
          <foo>  A sample arg
        """.strip(leading = false).dedent()
      check spec.genHelp(command = "prog") == expected

    test "arg groups are separated from the epilog by a blank line":
      let
        spec = newSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
          epilog = "bar")
        expected = """
        Usage:
          prog <foo>

        Arguments
          <foo>  A sample arg

        bar
        """.strip(leading = false).dedent()
      check spec.genHelp(command = "prog") == expected
    
    test "a hidden arg is not shown":
      let
        spec = newSpec((
          foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Options", hidden: true)))

        expected = """
        Usage:
          prog [options]

        Options
          --foo  A sample option
        """.strip(leading = false).dedent()
      check spec.genHelp(command = "prog") == expected

    test "a group is not shown if its only member is hidden":
      let
        spec = newSpec((
          foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Hidden Options", hidden: true)))

        expected = """
        Usage:
          prog [options]

        Options
          --foo  A sample option
        """.strip(leading = false).dedent()
      check spec.genHelp(command = "prog") == expected

    test "multiple groups appear in groupOrder's order, each separated by a blank line":
      let
        spec = newSpec(
          (
            bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample option", group: "Options"),
            foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
          usage = "<foo> [--bar]")
        expected = """
        Usage:
          prog <foo> [--bar]

        Arguments
          <foo>  A sample arg

        Options
          --bar  A sample option
        """.strip(leading = false).dedent()
      check spec.genHelp(command = "prog") == expected

    test "each groups aligns its variants column based on the global max colWidth, not its own max colWidth":
        let
          spec = newSpec(
            (
              bar: Arg(kind: Optional, variants: @["--foobar"], help: "A sample option that is longer than <foo>", group: "Options"),
              foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
            usage = "<foo> [--foobar]")
          expected = """
          Usage:
            prog <foo> [--foobar]

          Arguments
            <foo>     A sample arg

          Options
            --foobar  A sample option that is longer than <foo>
          """.strip(leading = false).dedent()
        check spec.genHelp(command = "prog") == expected
