## Help-text rendering: turns a built `Spec` into the message `--help`
## prints. Sits directly above `argumint/backend` -- see
## `docs/architecture.md` for why, and for how the variants column wraps.
##
## `import argumint` alone does not bring `genHelp` into scope; importing
## this module directly is what makes it callable, so a program can render
## its own help instead of only receiving it via the `HelpError` a matched
## `help*` Arg raises -- see
## `docs/adr/0042-genhelp-opt-in-via-submodule.md`.

import std/[pegs, sequtils, strformat, strutils, tables]

import ./[backend, errors, lexer, style]

export backend.prolog, backend.epilog, backend.usage
export style.StyleRole, style.Span, style.StyledText, style.Styler,
  style.styled, style.`&`, style.add, style.wrap, style.len, style.alignLeft,
  style.render, style.plain, style.markup

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

proc annotations*(arg: Arg, action = "", keepTicks = true): seq[StyledText] =
  ## The `[...]` bracket's parts, in display order: validator, default, env,
  ## configKey, then `action` (non-empty only for a divergent flag's own
  ## `variantDesc`). Key labels are `srAnnotation`; values are `srLiteral`,
  ## except env's `srEnv` and action's Help Markup. `keepTicks` is passed on
  ## to `markup` for the action and a validator's `desc`.
  proc entry(key: string, value: StyledText): StyledText =
    styled(srAnnotation, key & ": ") & value

  let validatorHelp = arg.validatorHelp(keepTicks)
  if validatorHelp.len > 0:
    result.add validatorHelp
  if arg.defaultStr.len > 0:
    result.add entry("default", styled(srLiteral, arg.defaultStr))
  if arg.envName.len > 0:
    result.add entry("env", styled(srEnv, arg.envName))
  let configKey = arg.configKey()
  if configKey.len > 0:
    result.add entry("configKey", styled(srLiteral, configKey.join))
  if action.len > 0:
    result.add entry("action", markup(action, keepTicks = keepTicks))

proc styledVariant(arg: Arg, variant: string): StyledText =
  ## `variant` with its role: `srCommand`, `srPositional`, or `srOption`
  ## plus `srMetavar` for a value placeholder (`--speed=<kn>`).
  case arg.kind
  of ArgKind.Command: styled(srCommand, variant)
  of ArgKind.Positional: styled(srPositional, variant)
  of ArgKind.Optional, ArgKind.Flag:
    let placeholder = variant.find('<')
    if placeholder > 1:
      styled(srOption, variant[0 ..< placeholder - 1]) &
        styled(variant[placeholder - 1 .. placeholder - 1]) &
        styled(srMetavar, variant[placeholder .. ^1])
    else:
      styled(srOption, variant)

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

proc rows*(arg: Arg, help = arg.help.short, keepTicks = true): seq[Row] =
  ## One Row per `arg.variantsByDesc()` bucket. Text is `help` (e.g.
  ## `arg.help.longOrShort` for Paragraph Style), falling back to the
  ## bucket's own `variantDesc` when the arg's variants diverge and that
  ## bucket's `variantDesc` is non-empty, plus the `[...]` bracket from
  ## `annotations` (`action` included only when divergent AND `help` is
  ## non-empty). Callers filter `arg.hidden` themselves.
  ##
  ## Variants get their roles (`srCommand`, `srOption`, `srPositional`,
  ## `srMetavar`), and the text gets Help Markup against `arg.metavars`.
  ## Pass `keepTicks = false` when rendering with a styler, so Help
  ## Markup's backticks are dropped.
  let buckets = arg.variantsByDesc()
  for bucket in buckets:
    let
      divergent = buckets.len > 1 and bucket.desc.len > 0
      primary = if help.len > 0: help elif divergent: bucket.desc else: ""
      action = if divergent and help.len > 0: bucket.desc else: ""
      annotations = arg.annotations(action, keepTicks)
    var text = markup(primary, arg.metavars, keepTicks)
    if annotations.len > 0:
      if primary.len > 0:
        text.add styled(" ")
      text.add styled(srAnnotation, "[")
      for i, annotation in annotations:
        if i > 0: text.add styled(srAnnotation, "; ")
        text.add annotation
      text.add styled(srAnnotation, "]")
    var variants: StyledText
    for i, name in bucket.names:
      if i > 0: variants.add styled(", ")
      variants.add arg.styledVariant(name)
    result.add Row(variants: variants, text: text)

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

proc renderColumn(rows: seq[Row], width: int, colWidth: int, styler: Styler = nil): string =
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
  lines.render(styler)

proc splitUsage(usage: string): seq[string] =
  ## Splits a usage message into usage lines. Lines prefixed with whitespace are
  ## treated as belonging to the previous usage line. Blank lines (and even a
  ## blank usage message) are treated as a blank usage line.
  for line in usage.splitLines:
    if result.len > 0 and line.startsWith(peg"\s"):
      result[^1] = fmt"{result[^1]} {line.strip}".strip
    else:
      result.add line.strip

proc styledUsage(line: string): StyledText =
  ## One usage line's tokens with their roles: options (and `[options]`)
  ## `srOption`, commands `srCommand`, arguments `srPositional`, a value
  ## placeholder's `<x>` `srMetavar`, and punctuation `srPlain`.
  for (kind, text) in line.displayTokens:
    case kind
    of tkShortOption, tkShortOptions, tkLongOption, tkAnyOption:
      result.add styled(srOption, text)
    of tkOptsEnd:
      if text.startsWith('['):
        result.add styled("[") & styled(srOption, text[1 .. ^2]) & styled("]")
      else:
        result.add styled(srOption, text)
    of tkCommand:
      result.add styled(srCommand, text)
    of tkArgument:
      result.add styled(srPositional, text)
    of tkOptionValue:
      result.add styled(text[0 .. 0]) & styled(srMetavar, text[1 .. ^1])
    else:
      result.add styled(text)

proc usageLines*(usage: string, command: string, width = DefaultWidth): seq[StyledText] =
  ## Lays out `usage` (a spec's raw usage string, one alternative per line) as
  ## indented usage lines, prefixing each alternative with `command`
  ## (`srProgram`). Lines longer than `width` are wrapped, with continuations
  ## hanging-indented to align under the first token after `command` rather
  ## than restarting at the left margin. Adds no "Usage:" label -- the caller
  ## writes its own.
  let
    prefix = styled(Margin) & styled(srProgram, command) & styled(" ")
    indent = styled(' '.repeat(prefix.len))
    lineWidth = max(width, 20)

  for line in usage.splitUsage:
    for i, wrapped in (prefix & line.styledUsage).wrap(lineWidth):
      result.add(if i == 0: wrapped else: indent & wrapped)

proc header(name: string, styler: Styler): string =
  ## A section header (`Usage`, a group name), rendered with its colon.
  heading(name).render(styler)

proc usageSection(spec: Spec, command: string): string =
  ## The built-ins' labeled usage block.
  let styler = spec.settings.style
  header("Usage", styler) & "\n" &
    spec.usage.usageLines(command, spec.settings.width).render(styler)

type
  ProseKind = enum
    pkBlank, pkParagraph, pkItem, pkLine

  ProseBlock = object
    ## One paragraph, list item, indented line, or blank line of prose, still
    ## unwrapped.
    kind: ProseKind
      ## What the block is; a `pkBlank` has no `text`
    indent: int
      ## Columns before the first line's `marker` (or text, if none)
    marker: string
      ## A `pkItem`'s marker and its space (`- `, `10. `), or empty
    text: StyledText
      ## The joined text, with Help Markup applied

proc expandIndent(line: string): string =
  ## `line` with the tabs in its indentation expanded to 8-column tab stops.
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}:
    result.add ' '.repeat(if line[i] == '\t': 8 - result.len mod 8 else: 1)
    inc i
  result.add line[i .. ^1]

proc dedentLines(text: string): seq[string] =
  ## `text`'s lines with the indentation they share removed (`dedent`, after
  ## expanding tabs), trailing whitespace stripped, and leading and trailing
  ## blank lines dropped. A `"""` string starting on the line after its
  ## quotes loses its source indentation this way -- see
  ## `docs/adr/0054-reflow-prolog-and-epilog.md`.
  for line in text.splitLines.map(expandIndent).join("\n").dedent.splitLines:
    result.add line.strip(leading = false)
  while result.len > 0 and result[0].len == 0: result.delete 0
  while result.len > 0 and result[^1].len == 0: result.setLen result.len - 1

proc listMarker(line: string): string =
  ## `line`'s list marker and its space (`- `, `* `, `12. `), or empty.
  if line.startsWith("- ") or line.startsWith("* "):
    return line[0 .. 1]
  var i = 0
  while i < line.len and line[i] in Digits: inc i
  if i > 0 and line.continuesWith(". ", i):
    result = line[0 .. i + 1]

proc proseBlocks(text: string, metavars: openArray[string] = [],
    keepTicks = true): seq[ProseBlock] =
  ## Stage one of `proseLines`: `text` dedented and joined into paragraphs,
  ## list items, and indented lines, each with Help Markup against
  ## `metavars`. See `proseLines` for the rule.
  var pending: seq[tuple[shape: ProseBlock, raw: string]]
  for line in text.dedentLines:
    let
      body = line.strip(trailing = false)
      indent = line.len - body.len
      marker = body.listMarker
    if line.len == 0:
      pending.add (ProseBlock(kind: pkBlank), "")
    elif marker.len > 0:
      pending.add (ProseBlock(kind: pkItem, indent: indent, marker: marker),
        body[marker.len .. ^1].strip)
    elif pending.len > 0 and (
        (indent == 0 and pending[^1].shape.kind == pkParagraph) or
        (indent > 0 and pending[^1].shape.kind == pkItem and
          indent == pending[^1].shape.indent + pending[^1].shape.marker.len)):
      pending[^1].raw.add ' ' & body
    elif indent == 0:
      pending.add (ProseBlock(kind: pkParagraph), body)
    else:
      pending.add (ProseBlock(kind: pkLine, indent: indent), body)
  for (shape, raw) in pending:
    result.add shape
    result[^1].text = markup(raw, metavars, keepTicks)

proc wrap(blocks: seq[ProseBlock], width: int): seq[StyledText] =
  ## Stage two of `proseLines`: each block wrapped to `width`, continuation
  ## lines hanging under its text. Text always gets at least 20 columns, like
  ## row help text, so a deep indent overflows instead of looping.
  for b in blocks:
    if b.kind == pkBlank:
      result.add StyledText()
      continue
    let hang = b.indent + b.marker.len
    for i, line in b.text.wrap(max(width - hang, 20)):
      let prefix =
        if i == 0: ' '.repeat(b.indent) & b.marker else: ' '.repeat(hang)
      result.add styled(prefix) & line

proc proseLines*(text: string, width = DefaultWidth, keepTicks = true): seq[StyledText] =
  ## Lays out `text` (a prolog or epilog) as wrapped lines with Help Markup,
  ## one `StyledText` per line, none containing `\n`; empty for blank text.
  ## `text` is re-flowed, since a `"""` string's line breaks are incidental:
  ##
  ## - The indentation every line shares is removed (`dedent`).
  ## - Consecutive unindented lines join into a paragraph; a blank line
  ##   separates paragraphs and is kept.
  ## - A line starting with `- `, `* `, or `1. ` starts a list item. A line
  ##   indented to exactly the item's text column continues it; the item wraps
  ##   hanging at that column.
  ## - Any other indented line is kept as its own line, wrapping at its indent.
  ##
  ## Pass `keepTicks = false` when rendering with a styler, as for `rows`.
  ## See `docs/adr/0054-reflow-prolog-and-epilog.md`.
  text.proseBlocks(keepTicks = keepTicks).wrap(width)

proc proseSection(text: string, settings: SpecSettings): string =
  ## The built-ins' prolog or epilog, wrapped at `settings.width`.
  let styler = settings.style
  text.proseLines(settings.width, keepTicks = styler.isNil).render(styler)

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
  let
    colWidth = spec.variantsColWidth()
    styler = spec.settings.style
  var groups: seq[string]
  for name, args in spec.helpGroups:
    var rows: seq[Row]
    for arg in args:
      rows.add arg.rows(keepTicks = styler.isNil)
    groups.add header(name, styler) & "\n" &
      rows.renderColumn(spec.settings.width, colWidth, styler)
  joinSections(spec.prolog.proseSection(spec.settings), spec.usageSection(command),
    joinSections(groups), spec.epilog.proseSection(spec.settings))

proc renderParagraph(rows: seq[Row], width = DefaultWidth, styler: Styler = nil): string =
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
      result.add lines.render(styler)

proc formatParagraph*(spec: Spec, command: string): string =
  ## Paragraph Style: prolog, usage, then each group's rows with variants on
  ## their own line and (long-form, if given) help text wrapped as an indented
  ## paragraph below, then epilog.
  let styler = spec.settings.style
  var groups: seq[string]
  for name, args in spec.helpGroups:
    var rows: seq[Row]
    for arg in args:
      rows.add arg.rows(arg.help.longOrShort, keepTicks = styler.isNil)
    groups.add header(name, styler) & "\n" &
      rows.renderParagraph(spec.settings.width, styler)
  joinSections(spec.prolog.proseSection(spec.settings), spec.usageSection(command),
    joinSections(groups), spec.epilog.proseSection(spec.settings))

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

  method validatorHelp(self: TestArg, keepTicks = true): StyledText =
    styled(self.validatorHelpVal)
  method defaultStr(self: TestArg): string = self.defaultStrVal
  method envSource(self: TestArg): Option[EnvSource] = self.env
  method configKey(self: TestArg): ConfigKey = self.cfg
  method variantDesc(self: TestArg, variant: string): string =
    self.descs.getOrDefault(variant, "")

  proc plainSpec(spec: tuple, usage = "", prolog = "", epilog = "",
      settings = newSpecSettings(style = nil)): Spec =
    ## `newSpec`, rendering plain unless told otherwise.
    newSpec(spec, usage, prolog, epilog, settings)

  proc row(variants, text: string): Row =
    Row(variants: styled(variants), text: styled(text))

  proc tagged(role: StyleRole, text: string): string =
    ## Marks each styled span as `{role:text}`, leaving plain ones bare.
    if role == srPlain: text
    else: "{" & ($role)[2 .. ^1].toLowerAscii & ":" & text & "}"

  proc plain(rows: seq[Row]): seq[Row] =
    ## `rows` with their roles dropped, to compare layout alone.
    rows.mapIt(row(it.variants.plain, it.text.plain))

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
      check TestArg(variants: @["<name>"], help: "Who to greet").rows().plain ==
        @[row("<name>", "Who to greet")]

    test "a single bucket is non-divergent and ignores variantDesc":
      let
        arg = TestArg(
          variants: @["-v"],
          help: "Verbosity",
          descs: {"-v": "Increase verbosity"}.toTable)
        expected = @[row("-v", "Verbosity")]
      check arg.rows().plain == expected

    test "a non-divergent bucket's help text is blank if arg.help is empty":
      let
        arg = TestArg(
          variants: @["-v"],
          descs: {"-v": "Increase verbosity"}.toTable)
        expected = @[row("-v", "")]
      check arg.rows().plain == expected

    test "a divergent bucket's help text matches variantDesc if arg.help is empty":
      let
        arg = TestArg(
          variants: @["--direction", "--up", "--down"],
          descs: { "--up": "Move up", "--down": "Move down"}.toTable)
        expected = @[
          row("--direction", ""),
          row("--up", "Move up"),
          row("--down", "Move down")]
      check arg.rows().plain == expected

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
      check arg.rows().plain == expected

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
      check arg.rows().plain == expected

    test "a non-divergent bucket's bracket appears alone, with no leading space, when arg.help is empty":
      let arg = TestArg(variants: @["--speed=<speed>"], defaultStrVal: "5")
      check arg.rows().plain == @[row("--speed=<speed>", "[default: 5]")]

    test "help defaults to the arg's short help text":
      let arg = TestArg(variants: @["-x"], help: ("short help text", "long help text"))
      check arg.rows().plain == @[row("-x", "short help text")]

    test "the given help text replaces the arg's own":
      let arg = TestArg(variants: @["-x"], help: ("short help text", "long help text"))
      check arg.rows("other text").plain == @[row("-x", "other text")]

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
        spec = plainSpec((
          c: CommandArg(kind: Command, variants: @["c"], group: "Commands", spec: plainSpec(())),
          v: Arg(kind: Flag, variants: @["-v"], group: "Flags"),
          x: Arg(kind: Optional, variants: @["-x"], group: "Options"),
          y: Arg(kind: Positional, variants: @["<y>"], group: "Arguments")))
        groups = spec.helpGroups.toSeq.mapIt(it.name)
      check groups == @["Commands", "Arguments", "Options", "Flags"]

    test "hidden args are not shown":
      let spec = plainSpec((
        foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
        bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Options", hidden: true)))
      check spec.helpGroups.toSeq[0].args.mapIt(it.name) == @["--foo"]

    test "a group is not shown when all of its args are hidden":
      let spec = plainSpec((
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

  suite "proseLines":
    proc lines(text: string, width = 40): seq[string] =
      text.proseLines(width).mapIt(it.plain)

    test "empty or all-blank text has no lines":
      check lines("").len == 0
      check lines(" \n\n  \n").len == 0

    test "a single line that fits is unchanged":
      check lines("Copy files around") == @["Copy files around"]

    test "a long line wraps at the width":
      check lines("A long description that has to wrap at the width given") ==
        @["A long description that has to wrap at", "the width given"]

    test "consecutive unindented lines join into a paragraph":
      check lines("Copyright 2026\nMIT License") == @["Copyright 2026 MIT License"]

    test "a blank line separates paragraphs and is kept":
      check lines("one\ntwo\n\nthree") == @["one two", "", "three"]

    test "leading and trailing blank lines are dropped":
      check lines("\n\none\n\n") == @["one"]

    test "source indentation is removed when text starts on the next line":
      check lines("""
        Naval Fate.

        A long description of the program that
        wraps.
        """) == @["Naval Fate.", "", "A long description of the program that",
          "wraps."]

    test "text right after the quotes keeps the next lines' indentation":
      check lines("""Naval Fate.
        Moves ships.""") == @["Naval Fate.", "        Moves ships."]

    test "an indented line stays on its own line":
      check lines("Run:\n  prog --fast\nthen check.") ==
        @["Run:", "  prog --fast", "then check."]
      check lines("Run:\n  prog --fast") == @["Run:", "  prog --fast"]

    test "an overlong indented line wraps at its indent":
      check lines("x\n    an indented line that is too long to fit\ny") ==
        @["x", "    an indented line that is too long to", "    fit", "y"]

    test "an indent at or beyond the width still gets 20 columns":
      let deep = ' '.repeat(40)
      check lines("x\n" & deep & "words that wrap somewhere after twenty\ny") ==
        @["x", deep & "words that wrap", deep & "somewhere after", deep & "twenty",
          "y"]

    test "a width under 20 still wraps at 20":
      check lines("A paragraph that wraps at twenty columns", 10) ==
        @["A paragraph that", "wraps at twenty", "columns"]
      check lines("a b c", 0) == @["a b c"]

    test "leading tabs expand to 8-column tab stops":
      check lines("\tone\n\ttwo") == @["one two"]
      check lines("x\n\t  y\nz") == @["x", "          y", "z"]
      check lines("- a\n\tb\nz") == @["- a", "        b", "z"]

    test "list markers start items, which stay separate":
      check lines("Modes:\n- fast\n* safe\n10. slow") ==
        @["Modes:", "- fast", "* safe", "10. slow"]

    test "a line indented to an item's text column continues it":
      check lines("- fast: skips\n  verification\n10. safe\n    too") ==
        @["- fast: skips verification", "10. safe too"]

    test "a long item wraps hanging at its text column":
      check lines("- fast: skips verification entirely, which is quick") ==
        @["- fast: skips verification entirely,", "  which is quick"]

    test "an item's text column counts one space after its marker":
      check lines("3.  two\n   joined\n    kept\nx") ==
        @["3. two joined", "    kept", "x"]

    test "a line indented past an item's text column stays separate":
      check lines("- fast\n    detail\nx") == @["- fast", "    detail", "x"]

    test "an unindented line after an item starts a paragraph":
      check lines("- fast\nThen more.") == @["- fast", "Then more."]

    test "a nested item and its continuation follow the rule at their depth":
      check lines("- top\n  - sub item that is long enough to wrap here\n" &
          "    continued\n  not continued\n- next") ==
        @["- top", "  - sub item that is long enough to wrap", "    here continued",
          "  not continued", "- next"]

    test "a marker needs its space":
      check lines("-x\n1.5 times") == @["-x 1.5 times"]

    test "Help Markup spans a joined line break":
      check "Use `--speed\n<kn>` now".proseLines(keepTicks = false).mapIt(
        it.render(tagged)) == @["Use {option:--speed} {positional:<kn>} now"]

    test "keepTicks keeps or drops the backticks":
      check lines("See `-x` and ``y``") == @["See `-x` and `y`"]
      check "See `-x`".proseLines(keepTicks = false).mapIt(it.plain) == @["See -x"]

    test "a wrapped span keeps its role and no span holds a newline":
      let wrapped = "Now pass `--long-option` to\nturn it on".proseLines(
        20, keepTicks = false)
      check wrapped.mapIt(it.render(tagged)) ==
        @["Now pass", "{option:--long-option} to", "turn it on"]
      for line in wrapped:
        for span in line.spans:
          check '\n' notin span.text

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
    let builtins = @[HelpFormatter(formatColumn), HelpFormatter(formatParagraph)]

    test "a spec with no prolog, epilog, or args is a usage block with a bare command usage line":
      for formatter in builtins:
        check formatter(Spec(settings: newSpecSettings(style = nil)), "prog") == "Usage:\n  prog"

    test "the usage block shows the spec's usage string after the command":
      let spec = Spec(settings: newSpecSettings(style = nil), usage: "<foo> [--bar]")
      for formatter in builtins:
        check formatter(spec, "prog") == "Usage:\n  prog <foo> [--bar]"

    test "prolog comes first, separated from the usage block by a blank line":
      let spec = Spec(settings: newSpecSettings(style = nil), prolog: "foo")
      for formatter in builtins:
        check formatter(spec, "prog") == "foo\n\nUsage:\n  prog"

    test "epilog comes last, separated from the usage block by a blank line":
      let spec = Spec(settings: newSpecSettings(style = nil), epilog: "bar")
      for formatter in builtins:
        check formatter(spec, "prog") == "Usage:\n  prog\n\nbar"

    test "a long prolog and epilog wrap at the width":
      let
        long = "A prolog long enough that it cannot possibly fit in forty columns."
        spec = Spec(settings: newSpecSettings(width = 40, style = nil),
          prolog: long, epilog: long)
      for formatter in builtins:
        let help = formatter(spec, "prog")
        check help.startsWith("A prolog long enough that it cannot\npossibly fit in forty columns.\n\n")
        for line in help.splitLines:
          check line.len <= 40

    test "a multi-line prolog re-flows into paragraphs":
      let spec = Spec(settings: newSpecSettings(width = 40, style = nil),
        prolog: """
          Naval Fate.

          Moves ships and
          mines around.""")
      for formatter in builtins:
        check formatter(spec, "prog").startsWith(
          "Naval Fate.\n\nMoves ships and mines around.\n\nUsage:")

    test "a subcommand's prolog wraps at its own width":
      let
        child = plainSpec((), prolog = "A subcommand prolog long enough to wrap at forty.")
        parent = plainSpec(
          (ship: CommandArg(kind: ArgKind.Command, variants: @["ship"], spec: child)),
          settings = newSpecSettings(width = 40, style = nil))
      for formatter in builtins:
        check formatter(parent.commands["ship"].spec, "p ship").startsWith(
          "A subcommand prolog long enough to wrap\nat forty.\n\n")

    test "groups come between the usage block and the epilog, each separated by a blank line":
      let spec = plainSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Arguments")),
        usage = "<foo>", prolog = "foo", epilog = "bar")
      for formatter in builtins:
        check formatter(spec, "prog") == "foo\n\nUsage:\n  prog <foo>\n\nArguments:\n  <foo>\n\nbar"

    test "a custom group's header gets a colon too":
      let spec = plainSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Output")),
        usage = "<foo>")
      for formatter in builtins:
        check "\n\nOutput:\n  <foo>" in formatter(spec, "prog")

  suite "formatColumn":
    test "a group's header is followed by its args in column format":
      let
        spec = plainSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
          usage = "<foo>")
        expected = """
        Usage:
          prog <foo>

        Arguments:
          <foo>  A sample arg""".dedent
      check spec.formatColumn("prog") == expected

    test "a hidden arg is not shown":
      let
        spec = plainSpec((
          foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Options", hidden: true)),
          usage = "[--foo] [--bar]")
        expected = """
        Usage:
          prog [--foo] [--bar]

        Options:
          --foo  A sample option""".dedent
      check spec.formatColumn("prog") == expected

    test "a group is not shown if its only member is hidden":
      let
        spec = plainSpec((
          foo: Arg(kind: Optional, variants: @["--foo"], help: "A sample option", group: "Options"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample hidden option", group: "Hidden Options", hidden: true)),
          usage = "[--foo] [--bar]")
        expected = """
        Usage:
          prog [--foo] [--bar]

        Options:
          --foo  A sample option""".dedent
      check spec.formatColumn("prog") == expected

    test "multiple groups appear in canonical order, each separated by a blank line":
      let
        spec = plainSpec(
          (
            bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample option", group: "Options"),
            foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
          usage = "<foo> [--bar]")
        expected = """
        Usage:
          prog <foo> [--bar]

        Arguments:
          <foo>  A sample arg

        Options:
          --bar  A sample option""".dedent
      check spec.formatColumn("prog") == expected

    test "each groups aligns its variants column based on the global max colWidth, not its own max colWidth":
      let
        spec = plainSpec(
          (
            bar: Arg(kind: Optional, variants: @["--foobar"], help: "A sample option that is longer than <foo>", group: "Options"),
            foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
          usage = "<foo> [--foobar]")
        expected = """
        Usage:
          prog <foo> [--foobar]

        Arguments:
          <foo>     A sample arg

        Options:
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
        spec = plainSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Arguments")),
          usage = "<foo>")
        expected = """
        Usage:
          prog <foo>

        Arguments:
          <foo>""".dedent
      check spec.formatParagraph("prog") == expected

    test "long help text is preferred if available, falling back to short help text if not":
      let
        spec = plainSpec((
          foo: Arg(kind: Positional, variants: @["<foo>"], help: ("Short help text", "Long help text"), group: "Arguments"),
          bar: Arg(kind: Positional, variants: @["<bar>"], help: "Fallback short text", group: "Arguments")),
          usage = "<foo> <bar>")
        expected = """
        Usage:
          prog <foo> <bar>

        Arguments:
          <foo>
            Long help text

          <bar>
            Fallback short text""".dedent
      check spec.formatParagraph("prog") == expected

    test "args are grouped in canonical order, with each group separated by a blank line":
      let
        spec = plainSpec((
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample option", group: "Options"),
          foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments"),
          baz: Arg(kind: Positional, variants: @["<baz>"], help: "Another sample arg", group: "Arguments")),
          usage = "<foo> <baz> [--bar]")
        expected = """
        Usage:
          prog <foo> <baz> [--bar]

        Arguments:
          <foo>
            A sample arg

          <baz>
            Another sample arg

        Options:
          --bar
            A sample option""".dedent
      check spec.formatParagraph("prog") == expected

    test "a hidden arg is not shown":
      let
        spec = plainSpec((
          foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments"),
          bar: Arg(kind: Positional, variants: @["<bar>"], help: "Another sample arg", group: "Arguments", hidden: true)),
          usage = "<foo> [<bar>]")
        expected = """
        Usage:
          prog <foo> [<bar>]

        Arguments:
          <foo>
            A sample arg""".dedent
      check spec.formatParagraph("prog") == expected

    test "a group with only hidden members is not shown":
      let
        spec = plainSpec((
          foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments"),
          bar: Arg(kind: Optional, variants: @["--bar"], help: "A sample option", group: "Options", hidden: true)),
          usage = "<foo> [--bar]")
        expected = """
        Usage:
          prog <foo> [--bar]

        Arguments:
          <foo>
            A sample arg""".dedent
      check spec.formatParagraph("prog") == expected

    test "spec width is successfully passed to renderParagraph":
      let
        spec = plainSpec(
          (foo: Arg(kind: Positional, variants: @["<foo>"], help: "This help text needs to be wrapped", group: "Arguments")),
          usage = "<foo>", settings = newSpecSettings(width = 20, style = nil))
        expected = """
        Usage:
          prog <foo>

        Arguments:
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
      let spec = plainSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
        prolog = "foo", epilog = "bar")
      check spec.genHelp("prog") == spec.formatColumn("prog")
      check spec.genHelp("prog") != spec.formatParagraph("prog")

  suite "action":
    test "a HelpArg with no defined formatter uses formatColumn":
      let
        help = HelpArg(kind: Flag, variants: @["--help"], help: "Display this help message", group: "Options")
        spec = plainSpec((help: help))
        expected = """
          Usage:
            prog --help

          Options:
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
        spec = plainSpec((help: help))
        expected = """
          Usage:
            prog --help

          Options:
            --help
              Display this help message""".dedent

      var raised = ""
      try:
        help.action(command = "prog", spec)
      except HelpError as e:
        raised = e.msg
      check raised == expected

  suite "roles":
    test "row variants are tagged by kind, with an option's placeholder a metavar":
      let
        cmd = Arg(kind: ArgKind.Command, variants: @["ship"])
        pos = Arg(kind: ArgKind.Positional, variants: @["<name>"])
        opt = Arg(kind: ArgKind.Optional, variants: @["-s", "--speed=<kn>"])
        flg = Arg(kind: ArgKind.Flag, variants: @["--moored"])
      check cmd.rows[0].variants.render(tagged) == "{command:ship}"
      check pos.rows[0].variants.render(tagged) == "{positional:<name>}"
      check opt.rows[0].variants.render(tagged) ==
        "{option:-s}, {option:--speed}={metavar:<kn>}"
      check flg.rows[0].variants.render(tagged) == "{option:--moored}"

    test "annotation brackets and keys are srAnnotation, values by kind":
      let
        arg = TestArg(kind: ArgKind.Optional, variants: @["--x=<x>"],
          defaultStrVal: "5", env: "X_ENV", cfg: configKey("sec", "key"))
      check arg.rows[0].text.render(tagged) ==
        "{annotation:[default: }{literal:5}{annotation:; env: }{env:X_ENV}" &
        "{annotation:; configKey: }{literal:sec.key}{annotation:]}"

    test "an action annotation's value is prose, with Help Markup":
      let
        arg = TestArg(kind: ArgKind.Flag, variants: @["--up", "--down"], help: "Move",
          descs: {"--up": "move `up`", "--down": "move ``down``"}.toTable)
      check arg.rows(keepTicks = false)[0].text.render(tagged) ==
        "Move {annotation:[action: }move {literal:up}{annotation:]}"
      check arg.rows[0].text.plain == "Move [action: move `up`]"
      check arg.rows[1].text.plain == "Move [action: move `down`]"

    test "a validator's help keeps its own roles":
      let arg = TestArg(kind: ArgKind.Optional, variants: @["--x=<x>"],
        validatorHelpVal: "v")
      check arg.rows[0].text.render(tagged) == "{annotation:[}v{annotation:]}"

    test "help text gets Help Markup, with the arg's own metavars":
      let arg = Arg(kind: ArgKind.Optional, variants: @["--speed=<kn>"],
        help: "`<kn>` knots, see `<name>` and `--moored`")
      check arg.rows(keepTicks = false)[0].text.render(tagged) ==
        "{metavar:<kn>} knots, see {positional:<name>} and {option:--moored}"

    test "help text keeps its backticks unless told otherwise":
      let arg = Arg(kind: ArgKind.Flag, variants: @["-x"], help: "like `-y`")
      check arg.rows[0].text.plain == "like `-y`"
      check arg.rows(keepTicks = false)[0].text.plain == "like -y"

    test "usage lines tag the program, commands, options, arguments and metavars":
      check usageLines("ship <name> move [--speed=<kn>] (-a | -bc) [options] [--] <x>...", "nf")
        .render(tagged) ==
        "  {program:nf} {command:ship} {positional:<name>} {command:move} " &
        "[{option:--speed}={metavar:<kn>}] ({option:-a} | {option:-bc}) " &
        "{option:[options]} [{option:--}] {positional:<x>}..."

    test "all-caps arguments and option values get the same roles":
      check usageLines("ship NAME [--speed=KN]", "p").render(tagged) ==
        "  {program:p} {command:ship} {positional:NAME} " &
        "[{option:--speed}={metavar:KN}]"

    test "an argument after an option in usage is still positional":
      check usageLines("-o <file>", "p").render(tagged) ==
        "  {program:p} {option:-o} {positional:<file>}"

    test "usage lines split across wraps keep their roles":
      check usageLines("--alpha --beta --gamma", "p", width = 20).render(tagged) ==
        "  {program:p} {option:--alpha} {option:--beta}\n    {option:--gamma}"

    test "unrecognized usage text is plain":
      check usageLines("a ~ b", "p").render(tagged) ==
        "  {program:p} {command:a} ~ {command:b}"

  suite "metavars":
    test "are the value placeholder names in an arg's variants, without brackets":
      check Arg(variants: @["-s", "--speed=<kn>", "--pace:<kn>", "--at=<x>"]).metavars ==
        @["kn", "x"]

    test "positionals, commands, and bare options have none":
      check Arg(variants: @["<name>"]).metavars.len == 0
      check Arg(variants: @["ship"]).metavars.len == 0
      check Arg(variants: @["-v", "--verbose"]).metavars.len == 0

  suite "styled formatters":
    let builtins = @[HelpFormatter(formatColumn), HelpFormatter(formatParagraph)]

    test "every row role reaches the rendered message":
      # Row-level roles are pinned in "roles"; this checks both built-ins
      # render them rather than dropping to plain.
      let spec = plainSpec(
        (ship: CommandArg(kind: ArgKind.Command, variants: @["ship"],
            group: "Commands", spec: newSpec(())),
         name: TestArg(kind: ArgKind.Positional, variants: @["<name>"],
            group: "Arguments"),
         speed: TestArg(kind: ArgKind.Optional, variants: @["--speed=<kn>"],
            group: "Options", defaultStrVal: "10", env: "SPEED",
            cfg: configKey("ship", "speed"), validatorHelpVal: "v")),
        usage = "ship\n<name> [--speed=<kn>]",
        settings = newSpecSettings(style = tagged))
      for formatter in builtins:
        let help = formatter(spec, "p")
        check "{header:Commands:}" in help
        check "  {command:ship}" in help
        check "  {positional:<name>}" in help
        check "{option:--speed}={metavar:<kn>}" in help
        check "{annotation:[}v{annotation:; default: }{literal:10}" &
          "{annotation:; env: }{env:SPEED}{annotation:; configKey: }" &
          "{literal:ship.speed}{annotation:]}" in help

    proc styledSpec(prolog = "", epilog = ""): Spec =
      plainSpec(
        (speed: Arg(kind: ArgKind.Optional, variants: @["--speed=<kn>"],
          help: "In `<kn>`", group: "Options")),
        usage = "[--speed=<kn>]", prolog = prolog, epilog = epilog,
        settings = newSpecSettings(style = tagged))

    test "headers are srHeader":
      for formatter in builtins:
        let help = formatter(styledSpec(), "p")
        check help.startsWith("{header:Usage:}\n  {program:p}")
        check "{header:Options:}\n" in help

    test "Column Style tags variants and markup":
      check formatColumn(styledSpec(), "p").splitLines[^1] ==
        "  {option:--speed}={metavar:<kn>}  In {metavar:<kn>}"

    test "Paragraph Style tags variants and markup":
      check formatParagraph(styledSpec(), "p").splitLines[^2 .. ^1] ==
        @["  {option:--speed}={metavar:<kn>}", "    In {metavar:<kn>}"]

    test "prolog and epilog get Help Markup, context-only":
      for formatter in builtins:
        let help = formatter(styledSpec("See `--speed <kn>` and `$HOME`.",
          "Try `ship`\nor `--speed=<kn>`.\n\n  `$HOME`"), "p")
        check help.startsWith(
          "See {option:--speed} {positional:<kn>} and {env:$HOME}.\n\n")
        check help.endsWith("\n\nTry {literal:ship} or " &
          "{option:--speed}={metavar:<kn>}.\n\n  {env:$HOME}")

    test "with no styler, prose keeps its backticks and collapses escapes":
      let spec = plainSpec(
        (x: Arg(kind: ArgKind.Flag, variants: @["-x"], help: "`-y` or ``z``", group: "Options")),
        usage = "[-x]", prolog = "`a` ``b``", settings = newSpecSettings(style = nil))
      for formatter in builtins:
        let help = formatter(spec, "p")
        check help.startsWith("`a` `b`\n\n")
        check "`-y` or `z`" in help
