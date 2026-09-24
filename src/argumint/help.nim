## Help-text rendering: turns a built `Spec` into the message `--help`
## prints. Sits directly above `argumint/backend` -- see
## `docs/architecture.md` for why, and for how the variants column wraps.
##
## `import argumint` alone does not bring `genHelp` into scope; importing
## this module directly is what makes it callable, so a program can render
## its own help instead of only receiving it via the `HelpError` a matched
## `help*` Arg raises -- see
## `docs/adr/0042-genhelp-opt-in-via-submodule.md`.

import std/[pegs, sequtils, strformat, strutils, tables, unicode]

import ./[backend, errors, style]

export backend.prolog, backend.epilog, backend.usage
export style.StyleRole, style.Span, style.StyledText, style.Styler,
  style.styled, style.`&`, style.add, style.wrap, style.len, style.alignLeft,
  style.render, style.plain

type
  HelpArg* = ref object of MessageArg
    ## A Message Argument that raises `HelpError` with its Spec's help
    ## message, rendered by its own Help Formatter.
    formatter*: HelpFormatter
      ## Renders the message; `formatColumn` if nil

  HelpFormatter* = proc (spec: Spec, command: string): string
    ## Renders a Spec's whole help message for `command` -- see
    ## `docs/adr/0048-pluggable-help-formatters.md`.

  Row* = object
    ## One line-item in the help table, still unwrapped. An object rather than
    ## a tuple so fields can be added without breaking custom formatters.
    variants*: StyledText
      ## The names of variants sharing a description, joined by ", "
    text*: StyledText
      ## Their resolved help plus `[...]` annotations

const Margin = "  "
const ContinuationIndent = "    "
const CanonicalGroups = ["Commands", "Arguments", "Options"]

proc annotations*(arg: Arg, action = ""): seq[StyledText] =
  ## The `[...]` bracket's parts, in display order: validator, default, env,
  ## configKey, then `action` (non-empty only for a divergent flag's own
  ## `variantDesc`).
  let validatorHelp = arg.validatorHelp()
  if validatorHelp.len > 0:
    result.add styled(validatorHelp)
  if arg.defaultStr.len > 0:
    result.add styled(fmt"default: {arg.defaultStr}")
  if arg.envName.len > 0:
    result.add styled(fmt"env: {arg.envName}")
  let configKey = arg.configKey()
  if configKey.len > 0:
    result.add styled(fmt"configKey: {configKey.join}")
  if action.len > 0:
    result.add styled(fmt"action: {action}")

proc groupOrder(spec: Spec): seq[string] =
  ## Returns `spec.groups`' keys ordered as `Commands`, `Arguments`, `Options`,
  ## then any other (e.g. user-defined) groups in declaration order.
  for group in CanonicalGroups:
    if group in spec.groups:
      result.add group
  for group in spec.groups.keys:
    if group notin CanonicalGroups:
      result.add group

iterator helpGroups*(spec: Spec): tuple[name: string, args: seq[Arg]] =
  ## Yields each of `spec`'s Help Groups with its non-hidden args, in canonical
  ## order: `Commands`, `Arguments`, `Options`, then user-defined groups in
  ## declaration order. Groups whose args are all hidden are skipped.
  for group in spec.groupOrder:
    let args = spec.groups[group].filterIt(not it.hidden)
    if args.len > 0:
      yield (name: group, args: args)

proc variantsByDesc*(arg: Arg): seq[tuple[names: seq[string], desc: string]] =
  ## Buckets `arg.variants` by their `variantDesc` text, preserving declaration
  ## order (both across buckets and within one). Collapses to exactly one
  ## bucket (`desc` possibly `""`) whenever every variant shares the same
  ## description -- i.e. every arg that isn't a flag with genuinely divergent
  ## per-variant ops -- so callers that don't care about divergence still see
  ## a single bucket covering all of `arg.variants`.
  var byDesc = initOrderedTable[string, seq[string]]()
  for v in arg.variants:
    byDesc.mgetOrPut(arg.variantDesc(v), @[]).add v
  for desc, names in byDesc.pairs:
    result.add (names: names, desc: desc)

proc longOrShort*(help: HelpText): string =
  ## `help.long` if declared, else `help.short` -- the Long-Form Help Text
  ## fallback rule (ADR 0049).
  if help.long.len > 0: help.long else: help.short

proc rows*(arg: Arg, help = arg.help.short): seq[Row] =
  ## One Row per `arg.variantsByDesc()` bucket. Text is `help` (e.g.
  ## `arg.help.longOrShort` for Paragraph Style), falling back to the
  ## bucket's own `variantDesc` when the arg's variants diverge and that
  ## bucket's `variantDesc` is non-empty, plus the `[...]` bracket from
  ## `annotations` (`action` included only when divergent AND `help` is
  ## non-empty). Callers filter `arg.hidden` themselves.
  let buckets = arg.variantsByDesc()
  for bucket in buckets:
    let
      divergent = buckets.len > 1 and bucket.desc.len > 0
      primary = if help.len > 0: help elif divergent: bucket.desc else: ""
      action = if divergent and help.len > 0: bucket.desc else: ""
      annotations = arg.annotations(action = action)
    var text = styled(primary)
    if annotations.len > 0:
      if primary.len > 0:
        text.add styled(" ")
      text.add styled("[")
      for i, annotation in annotations:
        if i > 0: text.add styled("; ")
        text.add annotation
      text.add styled("]")
    result.add Row(variants: styled(bucket.names.join(", ")), text: text)

proc variantsColWidth(spec: Spec): int =
  ## Widest single `Row.variants` across every arg in `spec`
  ## (including hidden ones -- existing behavior unchanged), capped at
  ## `spec.settings.maxVariantsWidth` unless 0 (unlimited). Built on `rows()`.
  for arg in spec.args:
    for row in arg.rows:
      if row.variants.len > result:
        result = row.variants.len
  if spec.settings.maxVariantsWidth > 0 and result > spec.settings.maxVariantsWidth:
    result = spec.settings.maxVariantsWidth

proc renderColumn(rows: seq[Row], width: int, colWidth: int): string =
  ## Wraps + zips `rows` into the table's text block: variants wrap at
  ## `colWidth`, text wraps at `max(width - (2 + colWidth + 2), 20)`, zipped
  ## line-by-line. First line of a row gets `Margin`; wrap continuations get
  ## `ContinuationIndent`. Rows join with "\n".
  let helpWidth = max(width - (colWidth + 4), 20)
  var lines: seq[StyledText]
  for row in rows:
    let
      variantLines = row.variants.wrap(colWidth)
      textLines =
        if row.text.len > 0: row.text.wrap(helpWidth)
        else: newSeq[StyledText]()
    for j in 0 ..< max(variantLines.len, textLines.len):
      let
        margin = if j == 0: Margin else: ContinuationIndent
        v = if j < variantLines.len: variantLines[j] else: StyledText()
      var line = styled(margin)
      if j < textLines.len and textLines[j].len > 0:
        line.add v.alignLeft(colWidth) & styled(Margin) & textLines[j]
      else:
        line.add v
      lines.add line
  lines.render

proc splitUsage(usage: string): seq[string] =
  ## Splits a usage message into usage lines. Lines prefixed with whitespace are
  ## treated as belonging to the previous usage line. Blank lines (and even a
  ## blank usage message) are treated as a blank usage line.
  for line in usage.splitLines:
    if result.len > 0 and line.startsWith(peg"\s"):
      result[^1] = fmt"{result[^1]} {line.strip}".strip
    else:
      result.add line.strip

proc usageLines*(usage: string, command: string, width = DefaultWidth): seq[StyledText] =
  ## Lays out `usage` (a spec's raw usage string, one alternative per line) as
  ## indented usage lines, prefixing each alternative with `command`. Lines
  ## longer than `width` are wrapped, with continuations hanging-indented to
  ## align under the first token after `command` rather than restarting at
  ## the left margin. Adds no "Usage:" label -- the caller writes its own.
  let
    prefix = "{Margin}{command} ".fmt
    indent = styled(' '.repeat(styled(prefix).len))
    lineWidth = max(width, 20)

  for line in usage.splitUsage:
    for i, wrapped in styled(prefix & line).wrap(lineWidth):
      result.add(if i == 0: wrapped else: indent & wrapped)

proc usageSection(spec: Spec, command: string): string =
  ## The built-ins' labeled usage block.
  "Usage:\n" & spec.usage.usageLines(command, spec.settings.width).render

proc joinSections*(sections: varargs[string]): string =
  ## Joins the non-empty `sections` of a help message with a blank line
  ## between each, so a formatter never has to pad its own parts.
  for section in sections:
    if section.len > 0:
      result.addSep "\n\n"
      result.add section

proc formatColumn*(spec: Spec, command: string): string =
  ## Column Style: prolog, usage, then each group's rows with variants and
  ## help text aligned into two columns shared across every group, then
  ## epilog.
  let colWidth = spec.variantsColWidth()
  var groups: seq[string]
  for name, args in spec.helpGroups:
    var rows: seq[Row]
    for arg in args:
      rows.add arg.rows()
    groups.add "{name}\n{rows.renderColumn(spec.settings.width, colWidth)}".fmt
  joinSections(spec.prolog, spec.usageSection(command), joinSections(groups),
    spec.epilog)

proc renderParagraph(rows: seq[Row], width = DefaultWidth): string =
  let
    variantsWidth = max(width - Margin.len, 20 - Margin.len)
    helpWidth = max(width - ContinuationIndent.len, 20 - ContinuationIndent.len)
  for row in rows:
    var lines: seq[StyledText]
    for line in row.variants.wrap(variantsWidth):
      lines.add styled(Margin) & line
    if row.text.len > 0:
      for line in row.text.wrap(helpWidth):
        lines.add styled(ContinuationIndent) & line
    if lines.len > 0:
      result.addSep "\n\n"
      result.add lines.render

proc formatParagraph*(spec: Spec, command: string): string =
  ## Paragraph Style: prolog, usage, then each group's rows with variants on
  ## their own line and (long-form, if given) help text wrapped as an indented
  ## paragraph below, then epilog.
  var groups: seq[string]
  for name, args in spec.helpGroups:
    var rows: seq[Row]
    for arg in args:
      rows.add arg.rows(arg.help.longOrShort)
    groups.add "{name}\n{rows.renderParagraph(spec.settings.width)}".fmt
  joinSections(spec.prolog, spec.usageSection(command), joinSections(groups),
    spec.epilog)

proc genHelp*(spec: Spec, command: string, formatter: HelpFormatter = formatColumn): string =
  ## Renders `spec`'s full help message with `formatter`, which owns the
  ## whole message -- see `docs/adr/0048-pluggable-help-formatters.md`.
  ## `command` names the program in the usage lines (`HelpArg.action` passes
  ## the command path that reached this Spec, so a subcommand's help reads
  ## `prog ship move`).
  formatter(spec, command)

method action(self: HelpArg, command: string, spec: Spec, variant = "") =
  ## Raises `HelpError` with `spec`'s generated help text for `command`,
  ## short-circuiting the rest of parsing so `parse*`/`parseOrQuit*` can
  ## deliver it directly (see `help*`).
  # Explicit conversion needed -- see docs/gotchas.md.
  let formatter = if self.formatter.isNil: HelpFormatter(formatColumn) else: self.formatter
  raise newException(HelpError, spec.genHelp(command, formatter))

when isMainModule:
  import std/[importutils, options, unittest]
  import ./[configsource, specbuild]

  privateAccess(Spec) ## Builds bare `Spec`s for white-box tests (ADR 0030).

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

  proc row(variants, text: string): Row =
    Row(variants: styled(variants), text: styled(text))

  suite "annotations":
    test "an arg with nothing set has no annotations":
      check Arg().annotations().len == 0

    test "includes validatorHelp when non-empty":
      let arg = TestArg(validatorHelpVal: "validatorHelp")
      check arg.annotations().mapIt(it.plain) == @["validatorHelp"]

    test "includes default when non-empty":
      let arg = TestArg(defaultStrVal: "defaultStr")
      check arg.annotations().mapIt(it.plain) == @["default: defaultStr"]

    test "includes env if set":
      let arg = TestArg(env: "TEST_ARG_ENV")
      check arg.annotations().mapIt(it.plain) == @["env: TEST_ARG_ENV"]

    test "includes configKey if set":
      let arg = TestArg(cfg: configKey("section", "key"))
      check arg.annotations().mapIt(it.plain) == @["configKey: section.key"]

    test "includes action if non-empty":
      check Arg().annotations(action = "foo").mapIt(it.plain) == @["action: foo"]

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
      check arg.annotations(action = "a").mapIt(it.plain) == expected

  suite "variantsByDesc":
    test "an arg with no variants has no buckets":
      check Arg().variantsByDesc().len == 0

    test "variants with no variant-specific description share one bucket with an empty desc":
      check Arg(variants: @["-v", "--verbose"], help: "Verbosity").variantsByDesc() ==
        @[(names: @["-v", "--verbose"], desc: "")]

    test "variants with variant-specific descriptions are bucketed by desc":
      let
        arg = TestArg(
          variants: @["-d", "--down", "-u", "--up"],
          descs: {"-d": "Move down", "--down": "Move down", "-u": "Move up", "--up": "Move up"}.toTable)
        expected = @[
          (names: @["-d", "--down"], desc: "Move down"),
          (names: @["-u", "--up"], desc: "Move up")]
      check arg.variantsByDesc() == expected

  suite "rows":
    # Variants sharing a description share a row. A bucket is considered
    # divergent if it is not the only bucket and its variantDesc is non-empty.
    test "a non-divergent bucket gets one row with the arg's help text":
      check TestArg(variants: @["<name>"], help: "Who to greet").rows() ==
        @[row("<name>", "Who to greet")]

    test "a single bucket is non-divergent and ignores variantDesc":
      let
        arg = TestArg(
          variants: @["-v"],
          help: "Verbosity",
          descs: {"-v": "Increase verbosity"}.toTable)
        expected = @[row("-v", "Verbosity")]
      check arg.rows() == expected

    test "a non-divergent bucket's help text is blank if arg.help is empty":
      let
        arg = TestArg(
          variants: @["-v"],
          descs: {"-v": "Increase verbosity"}.toTable)
        expected = @[row("-v", "")]
      check arg.rows() == expected

    test "a divergent bucket's help text matches variantDesc if arg.help is empty":
      let
        arg = TestArg(
          variants: @["--direction", "--up", "--down"],
          descs: { "--up": "Move up", "--down": "Move down"}.toTable)
        expected = @[
          row("--direction", ""),
          row("--up", "Move up"),
          row("--down", "Move down")]
      check arg.rows() == expected

    test "a divergent bucket's help text uses arg.help + action annotation if arg.help is not empty":
      let
        arg = TestArg(
          variants: @["--direction", "--up", "--down"],
          help: "Direction",
          descs: { "--up": "move up", "--down": "move down"}.toTable)
        expected = @[
          row("--direction", "Direction"),
          row("--up", "Direction [action: move up]"),
          row("--down", "Direction [action: move down]")]
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
          row("-d, --direction", "Direction"),
          row("-u, --up", "Direction [action: move up]")]
      check arg.rows() == expected

    test "a non-divergent bucket's bracket appears alone, with no leading space, when arg.help is empty":
      let arg = TestArg(variants: @["--speed=<speed>"], defaultStrVal: "5")
      check arg.rows() == @[row("--speed=<speed>", "[default: 5]")]

    test "help defaults to the arg's short help text":
      let arg = TestArg(variants: @["-x"], help: ("short help text", "long help text"))
      check arg.rows() == @[row("-x", "short help text")]

    test "the given help text replaces the arg's own":
      let arg = TestArg(variants: @["-x"], help: ("short help text", "long help text"))
      check arg.rows("other text") == @[row("-x", "other text")]

  suite "longOrShort":
    test "long help text is preferred when declared":
      check longOrShort(("short", "long")) == "long"

    test "short help text is the fallback when no long form is declared":
      check longOrShort(("short", "")) == "short"
      check longOrShort("short") == "short"

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

    test "colWidth counts visible width, not bytes":
      let spec = Spec(args: @[Arg(variants: @["<héllo>"])], settings: SpecSettings(maxVariantsWidth: 0))
      check spec.variantsColWidth == 7

    test "colWidth is affected by hidden args":
      # Note: this matches existing behavior but is not desirable. Change this
      # later.
      let
        arg1 = Arg(variants: @["-x"])
        arg2 = Arg(variants: @["-s", "--speed=<speed>"], hidden: true)
        spec = Spec(args: @[arg1, arg2], settings: SpecSettings(maxVariantsWidth: 0))
      check spec.variantsColWidth == "-s, --speed=<speed>".len

  suite "renderColumn":
    test "a single row that fits on one line needs no wrapping":
      let
        row = row("-v", "Verbose")
        expected = "  -v          Verbose"
      check renderColumn(@[row], width = 80, colWidth = 10) == expected

    test "the variants column aligns to the given colWidth":
      let
        row = row("-v", "Verbose")
        expected = "  -v                    Verbose"
      check renderColumn(@[row], width = 80, colWidth = 20) == expected

    test "the variants column pads to visible width, not bytes":
      check renderColumn(@[row("<é>", "x"), row("<e>", "y")], width = 80, colWidth = 5) ==
        "  <é>    x\n  <e>    y"

    test "rows are joined with a newline, each keeping its own margin":
      let
        rows = @[
          row("-v", "Verbose"),
          row("--quiet", "Quiet")]
        expected = "  -v        Verbose\n  --quiet   Quiet"
      check renderColumn(rows, width = 80, colWidth = 8) == expected

    test "a row with no text shows only the variants, with no alignment padding or trailing whitespace":
      let
        row = row("-v, --verbose", "")
        expected  = "  -v, --verbose"
      check renderColumn(@[row], width = 80, colWidth = 20) == expected

    test "long help text wraps in its own column, indented deeper than the margin":
      let
        row = row("-x", "This is a moderately long help description")
        expected = "  -x     This is a moderately\n           long help description"
        rendered = renderColumn(@[row], width = 30, colWidth = 5)
      check rendered == expected

    test "a variant name longer than colWidth is split":
      let
        row = row("-x, --extraordinarily-long-option-name", "A really long option name")
        expected = "  -x, --extr  A really long option\n    aordinaril  name\n    y-long-opt\n    ion-name"
        rendered = renderColumn(@[row], width = 30, colWidth = 10)

      check rendered == expected

    test "a help text word longer than helpWidth is split":
      let
        row = row("-x", "aVeryLongSingleWordThatExceedsTwentyCharacters")
        expected = "  -x  aVeryLongSingleWordThatE\n        xceedsTwentyCharacters"
        rendered = renderColumn(@[row], width = 30, colWidth = 2)
      check rendered == expected

    test "variants column and text columns wrap independently":
      let
        arg = Arg(
          variants: @["-v", "--verbose", "--quiet", "--boost", "--dampen"],
          help: "This is some help text that will need to be wrapped")
        expected = """
          -v, --verbose,        This is some help text that will
            --quiet, --boost,     need to be wrapped
            --dampen""".dedent.indent(2)
        rendered = renderColumn(arg.rows(), width = 60, colWidth = 20)

      check rendered == expected

    test "multiple rows are wrapped independently, not interleaved":
      let
        rows = @[
          row("-x", "This is a moderately long help description"),
          row("-q", "Be quiet")]
        expected = """
          -x     This is a moderately
                   long help description
          -q     Be quiet""".dedent.indent(2)
        rendered = renderColumn(rows, width = 30, colWidth = 5)

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

  suite "helpGroups":
    test "a spec with no args has no groups":
      let spec = Spec(settings: newSpecSettings())
      check spec.helpGroups.toSeq.len == 0

    test "groups are displayed in canonical order":
      let
        spec = newSpec((
          c: CommandArg(kind: Command, variants: @["c"], group: "Commands", spec: newSpec(())),
          v: Arg(kind: Flag, variants: @["-v"], group: "Flags"),
          x: Arg(kind: Optional, variants: @["-x"], group: "Options"),
          y: Arg(kind: Positional, variants: @["<y>"], group: "Arguments")))
        groups = spec.helpGroups.toSeq.mapIt(it.name)
      check groups == @["Commands", "Arguments", "Options", "Flags"]

    test "hidden args are not shown":
      let spec = newSpec((
        foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
        bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Options", hidden: true)))
      check spec.helpGroups.toSeq[0].args.mapIt(it.name) == @["--foo"]

    test "a group is not shown when all of its args are hidden":
      let spec = newSpec((
        foo: Arg(kind: Optional, variants: @["--foo"], group: "Options"),
        baz: Arg(kind: Optional, variants: @["--baz"], group: "Global Options", hidden: true)))
      check spec.helpGroups.toSeq.mapIt(it.name) == @["Options"]


  suite "splitUsage":
    test "a blank usage message is one blank usage line":
      check splitUsage("") == @[""]

    test "a usage message with no newlines is one usage line":
      check splitUsage("<foo> [--bar]") == @["<foo> [--bar]"]

    test "each line in a usage message is another usage line":
      check splitUsage("<foo>\n--bar") == @["<foo>", "--bar"]

    test "blank lines count as their own usage lines":
      check splitUsage("<foo>\n") == @["<foo>", ""]
      check splitUsage("\n<foo>") == @["", "<foo>"]

    test "lines prefixed with whitespace belong to the previous usage line":
      check splitUsage("<foo>\n  --bar") == @["<foo> --bar"]

    test "if the first line is prefixed with whitespace, it is still its own line":
      check splitUsage("  <foo>") == @["<foo>"]

    test "leading and trailing whitespace are removed from usage lines":
      check splitUsage("<foo>  ") == @["<foo>"]
      check splitUsage("  <foo>") == @["<foo>"]

    test "a blank line can be continued if the following line is prefixed by whitespace":
      check splitUsage("\n  <foo>") == @["<foo>"]
      check splitUsage("<foo>\n\n  <bar>") == @["<foo>", "<bar>"]

    test "usage lines containing only whitespace belong to the previous usage line":
      check splitUsage("<foo>\n  ") == @["<foo>"]
      check splitUsage("<foo>\n  \n  <bar>") == @["<foo> <bar>"]

  suite "usageLines":
    test "no label is added; the caller writes its own":
      check usageLines("<foo>", "prog").render == "  prog <foo>"

    test "a blank usage message is still prefixed with the command name":
      check usageLines("", "prog").render == "  prog"

    test "a single usage line is prefixed with the command name":
      check usageLines("<foo> [--bar]", "prog").render == "  prog <foo> [--bar]"

    test "multiple usage lines are each prefixed by the command name":
      check usageLines("<foo>\n<bar>", "prog").render == "  prog <foo>\n  prog <bar>"

    test "blank lines get the command name prefix":
      check usageLines("\n<foo>", "prog").render == "  prog\n  prog <foo>"
      check usageLines("<foo>\n", "prog").render == "  prog <foo>\n  prog"
      check usageLines("<foo>\n\n", "prog").render == "  prog <foo>\n  prog\n  prog"
      check usageLines("<foo>\n\n<bar>", "prog").render == "  prog <foo>\n  prog\n  prog <bar>"
      check usageLines("<foo>\n\n  <bar>", "prog").render == "  prog <foo>\n  prog <bar>"

    test "lines beginning with whitespace are joined to the previous usage line":
      check usageLines("<foo>\n  <bar>\n<baz>", "prog").render == "  prog <foo> <bar>\n  prog <baz>"

    test "usage lines are wrapped to width with a hanging indent matching command prefix length":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)\n<foobar>"
      check usageLines(usage, "prog", width = 40).render == "  prog <foo> [--bar] (--baz |\n       --qux=<qux>)\n  prog <foobar>"

    test "the hanging indent matches the command's visible width, not bytes":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)"
      check usageLines(usage, "prög", width = 40).render == "  prög <foo> [--bar] (--baz |\n       --qux=<qux>)"

    test "min width for a usage line is 20":
      let usage = "<foo> [--bar] (--baz | --qux=<qux>)\n<foobar>"
      check usageLines(usage, "prog", width = 10).render == "  prog <foo> [--bar]\n       (--baz |\n       --qux=<qux>)\n  prog <foobar>"

    test "words longer than width are split when wrapping":
      let usage = "<foo> [--bar --aVeryLongOptionName]"
      check usageLines(usage, "prog", width = 20).render == "  prog <foo> [--bar\n       --aVeryLongOptionNam\n       e]"

  suite "joinSections":
    test "no sections yields an empty string":
      check joinSections() == ""

    test "sections are separated by a blank line":
      check joinSections("a", "b", "c") == "a\n\nb\n\nc"

    test "empty sections are skipped without leaving extra blank lines":
      check joinSections("", "a", "", "", "b", "") == "a\n\nb"

    test "a seq of sections can be passed directly":
      check joinSections(@["a", "", "b"]) == "a\n\nb"

  suite "built-in formatter layout":
    # Section order and spacing shared by formatColumn and formatParagraph;
    # each style's own row layout is covered in its own suite below.
    let formatters = @[HelpFormatter(formatColumn), HelpFormatter(formatParagraph)]

    test "a spec with no prolog, epilog, or args is a usage block with a bare command usage line":
      for formatter in formatters:
        check formatter(Spec(settings: newSpecSettings()), "prog") == "Usage:\n  prog"

    test "the usage block shows the spec's usage string after the command":
      let spec = Spec(settings: newSpecSettings(), usage: "<foo> [--bar]")
      for formatter in formatters:
        check formatter(spec, "prog") == "Usage:\n  prog <foo> [--bar]"

    test "prolog comes first, separated from the usage block by a blank line":
      let spec = Spec(settings: newSpecSettings(), prolog: "foo")
      for formatter in formatters:
        check formatter(spec, "prog") == "foo\n\nUsage:\n  prog"

    test "epilog comes last, separated from the usage block by a blank line":
      let spec = Spec(settings: newSpecSettings(), epilog: "bar")
      for formatter in formatters:
        check formatter(spec, "prog") == "Usage:\n  prog\n\nbar"

    test "groups come between the usage block and the epilog, each separated by a blank line":
      let spec = newSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Arguments")),
        usage = "<foo>", prolog = "foo", epilog = "bar")
      for formatter in formatters:
        check formatter(spec, "prog") == "foo\n\nUsage:\n  prog <foo>\n\nArguments\n  <foo>\n\nbar"

  suite "formatColumn":
    test "a group's header is followed by its args in column format":
      let
        spec = newSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
          usage = "<foo>")
        expected = """
        Usage:
          prog <foo>

        Arguments
          <foo>  A sample arg""".dedent
      check spec.formatColumn("prog") == expected

    test "a hidden arg is not shown":
      let
        spec = newSpec((
          foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Options", hidden: true)),
          usage = "[--foo] [--bar]")
        expected = """
        Usage:
          prog [--foo] [--bar]

        Options
          --foo  A sample option""".dedent
      check spec.formatColumn("prog") == expected

    test "a group is not shown if its only member is hidden":
      let
        spec = newSpec((
          foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Hidden Options", hidden: true)),
          usage = "[--foo] [--bar]")
        expected = """
        Usage:
          prog [--foo] [--bar]

        Options
          --foo  A sample option""".dedent
      check spec.formatColumn("prog") == expected

    test "multiple groups appear in canonical order, each separated by a blank line":
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
          --bar  A sample option""".dedent
      check spec.formatColumn("prog") == expected

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
          --foobar  A sample option that is longer than <foo>""".dedent
      check spec.formatColumn("prog") == expected

  suite "renderParagraph":
    test "no rows yields an empty string":
      check renderParagraph(@[]) == ""

    test "a single row with empty help text gets a margin and no blank line after":
      let rows = @[row("<foo>", "")]
      check renderParagraph(rows) == "  <foo>"

    test "a row's variants are wrapped to the spec's width (min 20), keeping the same left margin":
      let
        rows = @[row("-v, --verbose, --boost, --dampen, --quiet", "")]
        expected = "  -v, --verbose,\n  --boost, --dampen,\n  --quiet"
      check renderParagraph(rows, width = 20) == expected
      check renderParagraph(rows, width = 10) == expected

    test "a row's variants line is followed by the indented help line":
      let
        rows = @[row("-x", "This is help text")]
        expected = "  -x\n    This is help text"
      check renderParagraph(rows) == expected

    test "long help text is wrapped to the spec's width (min 20), keeping the left margin":
      let
        rows = @[row("-x", "This help text needs to be wrapped")]
        expected = "  -x\n    This help text\n    needs to be\n    wrapped"
      check renderParagraph(rows, width = 20) == expected
      check renderParagraph(rows, width = 10) == expected

    test "multiple rows have blank lines between them":
      let
        rows = @[
          row("<foo>", "This is some help text"),
          row("<bar>", "This is also some help text") ]
        expected = "  <foo>\n    This is some help text\n\n  <bar>\n    This is also some help text"
      check renderParagraph(rows) == expected

  suite "formatParagraph":
    test "a group's header is followed by its args, each on its own line":
      let
        spec = newSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Arguments")),
          usage = "<foo>")
        expected = """
        Usage:
          prog <foo>

        Arguments
          <foo>""".dedent
      check spec.formatParagraph("prog") == expected

    test "long help text is preferred if available, falling back to short help text if not":
      let
        spec = newSpec((
          foo: Arg(kind: Positional, variants: @["<foo>"], help: ("Short help text", "Long help text"), group: "Arguments"),
          bar: Arg(kind: Positional, variants: @["<bar>"], help: "Fallback short text", group: "Arguments")),
          usage = "<foo> <bar>")
        expected = """
        Usage:
          prog <foo> <bar>

        Arguments
          <foo>
            Long help text

          <bar>
            Fallback short text""".dedent
      check spec.formatParagraph("prog") == expected

    test "args are grouped in canonical order, with each group separated by a blank line":
      let
        spec = newSpec((
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample option", group: "Options"),
          foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments"),
          baz: Arg(kind: Positional, variants: @["<baz>"], help: "Another sample arg", group: "Arguments")),
          usage = "<foo> <baz> [--bar]")
        expected = """
        Usage:
          prog <foo> <baz> [--bar]

        Arguments
          <foo>
            A sample arg

          <baz>
            Another sample arg

        Options
          --bar
            A sample option""".dedent
      check spec.formatParagraph("prog") == expected

    test "a hidden arg is not shown":
      let
        spec = newSpec((
          foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments"),
          bar: Arg(kind: Positional, variants: @["<bar>"], help: "Another sample arg", group: "Arguments", hidden: true)),
          usage = "<foo> [<bar>]")
        expected = """
        Usage:
          prog <foo> [<bar>]

        Arguments
          <foo>
            A sample arg""".dedent
      check spec.formatParagraph("prog") == expected

    test "a group with only hidden members is not shown":
      let
        spec = newSpec((
          foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample option", group: "Options", hidden: true)),
          usage = "<foo> [--bar]")
        expected = """
        Usage:
          prog <foo> [--bar]

        Arguments
          <foo>
            A sample arg""".dedent
      check spec.formatParagraph("prog") == expected

    test "spec width is successfully passed to renderParagraph":
      let
        spec = newSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], help: "This help text needs to be wrapped", group: "Arguments")),
          usage = "<foo>", settings = newSpecSettings(width = 20))
        expected = """
        Usage:
          prog <foo>

        Arguments
          <foo>
            This help text
            needs to be
            wrapped""".dedent
      check spec.formatParagraph("prog") == expected

  suite "genHelp":
    test "returns the formatter's output verbatim":
      let custom = proc (spec: Spec, command: string): string = "custom help for " & command
      check Spec(settings: newSpecSettings()).genHelp("prog", custom) == "custom help for prog"

    test "defaults to formatColumn":
      let spec = newSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
        prolog = "foo", epilog = "bar")
      check spec.genHelp("prog") == spec.formatColumn("prog")
      check spec.genHelp("prog") != spec.formatParagraph("prog")

  suite "action":
    test "a HelpArg with no defined formatter uses formatColumn":
      let
        help = HelpArg(kind: Flag, variants: @["--help"], help: "Display this help message", group: "Options")
        spec = newSpec((help: help))
        expected = """
          Usage:
            prog --help

          Options
            --help  Display this help message""".dedent

      var raised = ""
      try:
        help.action(command = "prog", spec)
      except HelpError as e:
        raised = e.msg
      check raised == expected

    test "a HelpArg uses its formatter when explicitly defined":
      let
        help = HelpArg(kind: Flag, variants: @["--help"],
          help: "Display this help message", group: "Options",
          formatter: formatParagraph)
        spec = newSpec((help: help))
        expected = """
          Usage:
            prog --help

          Options
            --help
              Display this help message""".dedent

      var raised = ""
      try:
        help.action(command = "prog", spec)
      except HelpError as e:
        raised = e.msg
      check raised == expected
