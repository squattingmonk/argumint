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
  style.render, style.plain, style.withoutTicks

type
  HelpArg* = ref object of MessageArg
    ## A Message Argument that raises `HelpError` with its Spec's help
    ## message, rendered by its own Help Formatter.
    formatter*: HelpFormatter
      ## Renders the message; `formatColumn` if nil

  HelpFormatter* = proc (ctx: HelpContext): string
    ## Renders a Spec's whole help message from `ctx` -- see
    ## `docs/adr/0048-pluggable-help-formatters.md` and
    ## `docs/adr/0057-help-context.md`. `--help` may call it twice, with and
    ## without a Styler (ADR 0059), so it should have no side effects.

  HelpContext* = object
    ## What a Help Formatter is handed for one render: the Spec, the command
    ## path, the width, and the Styler, with whether Help Markup's backticks
    ## survive already decided (only with no Styler). Everything it hands out
    ## is ready to lay out; render it with `ctx.render`.
    spec: Spec
    command: string
    width: int
    styler: Styler

  Row* = object
    ## One line-item in the help table, still unwrapped. An object rather than
    ## a tuple so fields can be added without breaking custom formatters.
    variants*: StyledText
      ## The names of variants sharing a description, joined by ", "
    text*: StyledText
      ## Their resolved help plus `[...]` annotations, one block per line
      ## (paragraph, list item, indented line, or blank); lay it out with
      ## `wrapProse`

const Margin = "  "
const ContinuationIndent = "    "
const CanonicalGroups = ["Commands", "Arguments", "Options"]

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

proc listMarker(line: string): string =
  ## `line`'s list marker and its space (`- `, `* `, `12. `), or empty.
  if line.startsWith("- ") or line.startsWith("* "):
    return line[0 .. 1]
  var i = 0
  while i < line.len and line[i] in Digits: inc i
  if i > 0 and line.continuesWith(". ", i):
    result = line[0 .. i + 1]

proc proseBlocks(text: string, metavars: openArray[string] = []): seq[ProseBlock] =
  ## Stage one of `HelpContext.prose` and `rows`: `text` dedented and joined
  ## into paragraphs, list items, and indented lines, each with Help Markup
  ## against `metavars`. See `HelpContext.prose` for the rule.
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
    result[^1].text = markup(raw, metavars)

proc proseText(blocks: seq[ProseBlock]): StyledText =
  ## `blocks` as one `StyledText`, a line per block, each starting with its
  ## indent and marker as `srPlain`: the form `Row.text` takes and `wrapProse`
  ## lays out.
  for i, b in blocks:
    if i > 0: result.add styled("\n")
    result.add styled(' '.repeat(b.indent) & b.marker)
    result.add b.text

proc blockLines(t: StyledText): seq[StyledText] =
  ## `t` split at its newlines, keeping each span's role.
  result = @[StyledText()]
  for span in t.spans:
    let parts = span.text.split('\n')
    for i, part in parts:
      if i > 0: result.add StyledText()
      result[^1].add Span(role: span.role, text: part)

proc wrapProse*(t: StyledText, width: int): seq[StyledText] =
  ## Lays out `t` (a `Row.text`, say) as wrapped lines, one `StyledText` per
  ## line, none containing `\n`; empty if `t` is. Each of `t`'s lines is a
  ## block: its leading spaces are its indent, followed in the same `srPlain`
  ## span by an optional list marker (`- `, `* `, `1. `), and its continuation
  ## lines hang under its text. A blank line comes out empty. A block with no
  ## indent or marker wraps at exactly `width`; hung text gets at least 20
  ## columns (or `width`, if narrower), so a deep indent overflows instead of
  ## looping. See `docs/adr/0055-reflow-arg-help-text.md`.
  if t.len == 0:
    return
  for line in t.blockLines:
    if line.len == 0:
      result.add StyledText()
      continue
    # Only an `srPlain` marker counts: "`-`" is a literal, not an item.
    let
      lead = if line.spans[0].role == srPlain: line.spans[0].text else: ""
      indent = lead.len - lead.strip(trailing = false).len
      hang = indent + lead[indent .. ^1].listMarker.len
    var body = line
    if hang > 0:
      body.spans[0].text = lead[hang .. ^1]
      if body.spans[0].text.len == 0:
        body.spans.delete 0
    if body.len == 0:
      result.add styled(lead.strip(leading = false))
      continue
    for i, wrapped in body.wrap(max(width - hang, min(width, 20))):
      let prefix = if i == 0: lead[0 ..< hang] else: ' '.repeat(hang)
      result.add styled(prefix) & wrapped

proc oneLine(t: StyledText): StyledText =
  ## `t` with each whitespace run containing a newline collapsed to a space,
  ## or dropped at either end of `t`.
  for n, span in t.spans:
    var
      text = ""
      i = 0
    while i < span.text.len:
      var j = i
      while j < span.text.len and span.text[j] in Whitespace: inc j
      if j == i:
        text.add span.text[i]
        inc j
      elif '\n' notin span.text[i ..< j]:
        text.add span.text[i ..< j]
      elif not (result.len == 0 and text.len == 0) and
          not (n == t.spans.high and j == span.text.len):
        text.add ' '
      i = j
    result.add Span(role: span.role, text: text)

proc annotations(arg: Arg, action = ""): seq[StyledText] =
  ## The `[...]` bracket's parts, in display order: validator, default, env,
  ## configKey, then `action` (non-empty only for a divergent flag's own
  ## `variantDesc`). Key labels are `srAnnotation`; values are `srLiteral`,
  ## except env's `srEnv` and action's Help Markup, ticks kept. Each part is
  ## one line: whitespace around a newline collapses to a space.
  proc entry(key: string, value: StyledText): StyledText =
    styled(srAnnotation, key & ": ") & value

  let validatorHelp = arg.validatorHelp
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
    result.add entry("action", markup(action))
  for part in result.mitems:
    part = part.oneLine

proc styledVariant(arg: Arg, variant: string): StyledText =
  ## `variant` with its role: `srCommand`, `srPositional`, or `srOption`
  ## plus `srMetavar` for a value placeholder (`--speed=<kn>`).
  case arg.kind
  of ArgKind.Command: styled(srCommand, variant)
  of ArgKind.Positional: styled(srPositional, variant)
  of ArgKind.Optional, ArgKind.Flag: styledOption(variant)

proc groupOrder(spec: Spec): seq[string] =
  ## Returns `spec.groups`' keys ordered as `Commands`, `Arguments`, `Options`,
  ## then any other (e.g. user-defined) groups in declaration order.
  for group in CanonicalGroups:
    if group in spec.groups:
      result.add group
  for group in spec.groups.keys:
    if group notin CanonicalGroups:
      result.add group

iterator helpGroups(spec: Spec): tuple[name: string, args: seq[Arg]] =
  ## Yields each of `spec`'s Help Groups with its non-hidden args, in canonical
  ## order: `Commands`, `Arguments`, `Options`, then user-defined groups in
  ## declaration order. Groups whose args are all hidden are skipped.
  for group in spec.groupOrder:
    let args = spec.groups[group].filterIt(not it.hidden)
    if args.len > 0:
      yield (name: group, args: args)

proc variantsByDesc(arg: Arg): seq[tuple[names: seq[string], desc: string]] =
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

proc rows(arg: Arg, help = arg.help.short): seq[Row] =
  ## One Row per `arg.variantsByDesc()` bucket. Text is `help` (e.g.
  ## `arg.help.longOrShort` for Paragraph Style), falling back to the
  ## bucket's own `variantDesc` when the arg's variants diverge and that
  ## bucket's `variantDesc` is non-empty, plus the `[...]` bracket from
  ## `annotations` (`action` included only when divergent AND `help` is
  ## non-empty). Callers filter `arg.hidden` themselves.
  ##
  ## Variants get their roles (`srCommand`, `srOption`, `srPositional`,
  ## `srMetavar`). The text is re-flowed into blocks like `HelpContext.prose`,
  ## with Help Markup against `arg.metavars`; the bracket ends a one-block
  ## text, and follows a longer one as its own block after a blank line. Help
  ## Markup's ticks are kept; `HelpContext.rows` drops them for a Styler.
  let buckets = arg.variantsByDesc()
  for bucket in buckets:
    let
      divergent = buckets.len > 1 and bucket.desc.len > 0
      primary = if help.len > 0: help elif divergent: bucket.desc else: ""
      action = if divergent and help.len > 0: bucket.desc else: ""
      annotations = arg.annotations(action)
    let blocks = proseBlocks(primary, arg.metavars)
    var text = blocks.proseText
    if annotations.len > 0:
      if blocks.len > 1:
        text.add styled("\n\n")
      elif blocks.len == 1:
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
  ## line-by-line. A row's first line gets `Margin`, and later variant lines
  ## `ContinuationIndent`. Every text line starts at the text column. Rows join
  ## with "\n".
  let
    helpWidth = max(width - (colWidth + 4), 20)
    textColumn = Margin.len + colWidth + Margin.len
  var lines: seq[StyledText]
  for row in rows:
    let
      variantLines = row.variants.wrap(colWidth)
      textLines = row.text.wrapProse(helpWidth)
    for j in 0 ..< max(variantLines.len, textLines.len):
      var line =
        if j == 0: styled(Margin) & variantLines[0]
        elif j < variantLines.len: styled(ContinuationIndent) & variantLines[j]
        else: StyledText()
      if j < textLines.len and textLines[j].len > 0:
        line = line.alignLeft(max(textColumn, line.len + Margin.len)) &
          textLines[j]
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

proc helpContext(spec: Spec, command: string, styler: Styler): HelpContext =
  ## As the public one, but with `styler` in place of the settings' style.
  HelpContext(spec: spec, command: command, width: spec.settings.width,
    styler: styler)

proc helpContext*(spec: Spec, command: string): HelpContext =
  ## The context `genHelp` hands its formatter: `spec.settings`' width and
  ## style, for `command`. Build one to call a formatter directly.
  helpContext(spec, command, spec.settings.style)

proc spec*(ctx: HelpContext): Spec =
  ## The Spec being rendered, for anything the context doesn't hand out
  ## (`prolog`, `epilog`, `settings`).
  ctx.spec

proc command*(ctx: HelpContext): string =
  ## The command path that names the program in the usage lines.
  ctx.command

proc width*(ctx: HelpContext): int =
  ## The width everything the context hands out is wrapped at.
  ctx.width

proc resolved(ctx: HelpContext, t: StyledText): StyledText =
  ## `t` with Help Markup's ticks dropped if there's a Styler.
  if ctx.styler.isNil: t else: t.withoutTicks

iterator groups*(ctx: HelpContext): tuple[name: string, args: seq[Arg]] =
  ## Each Help Group's name and its non-hidden Args, in display order:
  ## `Commands`, `Arguments`, `Options`, then user-defined groups in
  ## declaration order. A group whose Args are all hidden is skipped.
  for group in ctx.spec.helpGroups:
    yield group

proc rows*(ctx: HelpContext, arg: Arg, help = arg.help.short): seq[Row] =
  ## `arg`'s Rows: one per set of variants sharing a description, with
  ## `help` (e.g. `arg.help.longOrShort` for long-form text) re-flowed like
  ## `prose` and the `[...]` annotations appended. Callers skip hidden Args
  ## (`groups` already does).
  for row in arg.rows(help):
    result.add Row(variants: row.variants, text: ctx.resolved(row.text))

proc prose*(ctx: HelpContext, text: string): seq[StyledText] =
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
  ## Lines wrap at `ctx.width`. See
  ## `docs/adr/0054-reflow-prolog-and-epilog.md`.
  # Ticks go before wrapping, so a styled line isn't measured with them.
  ctx.resolved(text.proseBlocks.proseText).wrapProse(max(ctx.width, 20))

proc usage*(ctx: HelpContext): seq[StyledText] =
  ## The Spec's usage lines for `ctx.command`, wrapped at `ctx.width`, with
  ## no label.
  ctx.spec.usage.usageLines(ctx.command, ctx.width)

proc heading*(ctx: HelpContext, name: string): StyledText =
  ## `name` as a section heading (`srHeader`), with its colon.
  heading(name)

proc markup*(ctx: HelpContext, prose: string): StyledText =
  ## `prose` with Help Markup, for a formatter's own text.
  ctx.resolved(markup(prose))

proc render*(ctx: HelpContext, t: StyledText): string =
  ## `t` rendered with the Spec's Styler.
  t.render(ctx.styler)

proc render*(ctx: HelpContext, lines: openArray[StyledText]): string =
  ## Each of `lines` rendered with the Spec's Styler, joined with `\n`.
  lines.render(ctx.styler)

proc joinSections*(sections: varargs[string]): string =
  ## Joins the non-empty `sections` of a help message with a blank line
  ## between each, so a formatter never has to pad its own parts.
  for section in sections:
    if section.len > 0:
      result.addSep "\n\n"
      result.add section

proc frame(ctx: HelpContext, groups: seq[string]): string =
  ## The built-ins' message around their `groups`: prolog, labeled usage
  ## block, the groups, then epilog.
  joinSections(ctx.render(ctx.prose(ctx.spec.prolog)),
    ctx.render(ctx.heading("Usage")) & "\n" & ctx.render(ctx.usage),
    joinSections(groups), ctx.render(ctx.prose(ctx.spec.epilog)))

proc formatColumn*(ctx: HelpContext): string =
  ## Column Style: prolog, usage, then each group's rows with variants and
  ## help text aligned into two columns shared across every group, then
  ## epilog.
  let colWidth = ctx.spec.variantsColWidth()
  var groups: seq[string]
  for name, args in ctx.groups:
    var rows: seq[Row]
    for arg in args:
      rows.add ctx.rows(arg)
    groups.add ctx.render(ctx.heading(name)) & "\n" &
      rows.renderColumn(ctx.width, colWidth, ctx.styler)
  ctx.frame(groups)

proc renderParagraph(rows: seq[Row], width = DefaultWidth, styler: Styler = nil): string =
  let
    variantsWidth = max(width - Margin.len, 20 - Margin.len)
    helpWidth = max(width - ContinuationIndent.len, 20 - ContinuationIndent.len)
  for row in rows:
    var lines: seq[StyledText]
    for line in row.variants.wrap(variantsWidth):
      lines.add styled(Margin) & line
    for line in row.text.wrapProse(helpWidth):
      lines.add(if line.len > 0: styled(ContinuationIndent) & line else: line)
    if lines.len > 0:
      result.addSep "\n\n"
      result.add lines.render(styler)

proc formatParagraph*(ctx: HelpContext): string =
  ## Paragraph Style: prolog, usage, then each group's rows with variants on
  ## their own line and (long-form, if given) help text wrapped as an indented
  ## paragraph below, then epilog.
  var groups: seq[string]
  for name, args in ctx.groups:
    var rows: seq[Row]
    for arg in args:
      rows.add ctx.rows(arg, arg.help.longOrShort)
    groups.add ctx.render(ctx.heading(name)) & "\n" &
      rows.renderParagraph(ctx.width, ctx.styler)
  ctx.frame(groups)

proc genHelp*(spec: Spec, command: string, formatter: HelpFormatter = formatColumn): string =
  ## Renders `spec`'s full help message with `formatter`, which owns the
  ## whole message -- see `docs/adr/0048-pluggable-help-formatters.md`.
  ## `command` names the program in the usage lines (`HelpArg.action` passes
  ## the command path that reached this Spec, so a subcommand's help reads
  ## `prog ship move`).
  formatter(helpContext(spec, command))

method action(self: HelpArg, command: string, spec: Spec, variant = "") =
  ## Raises `HelpError` with `spec`'s generated help text for `command`,
  ## short-circuiting the rest of parsing so `parse*`/`parseOrQuit*` can
  ## deliver it directly (see `help*`). `msg` is rendered without a Styler,
  ## and `styledMsg` with the Spec's.
  # Explicit conversion needed -- see docs/gotchas.md.
  let formatter = if self.formatter.isNil: HelpFormatter(formatColumn) else: self.formatter
  let plain = formatter(helpContext(spec, command, nil))
  let styled = if spec.settings.style.isNil: plain else: spec.genHelp(command, formatter)
  raise (ref HelpError)(msg: plain, styledMsg: styled)

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

  method validatorHelp(self: TestArg): StyledText =
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

    test "each part is one line, whitespace around a newline collapsing to a space":
      let arg = TestArg(validatorHelpVal: "one of\n    fast, safe",
        variants: @["--up", "--down"], descs: {"--up": "a\nb"}.toTable)
      check arg.annotations("go\n  up").mapIt(it.plain) ==
        @["one of fast, safe", "action: go up"]

    test "a newline at either end of a part is dropped, not collapsed":
      let arg = TestArg(validatorHelpVal: "\n  one of fast\n")
      check arg.annotations("go up\n").mapIt(it.plain) ==
        @["one of fast", "action: go up"]

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

    test "help text is re-flowed into blocks, one per line":
      let arg = TestArg(variants: @["-x"], help: """
        Picks a mode,
        quickly.

        Modes:
        - fast""")
      check arg.rows().plain == @[row("-x", "Picks a mode, quickly.\n\nModes:\n- fast")]

    test "the bracket ends one-block text":
      let arg = TestArg(variants: @["-x"], help: "First line\nsecond line",
        defaultStrVal: "5")
      check arg.rows().plain == @[row("-x", "First line second line [default: 5]")]

    test "the bracket follows several blocks after a blank line":
      let arg = TestArg(variants: @["-x"], help: "One.\n\nTwo.", defaultStrVal: "5")
      check arg.rows().plain == @[row("-x", "One.\n\nTwo.\n\n[default: 5]")]

    test "a divergent bucket's variantDesc as main text is re-flowed":
      let arg = TestArg(variants: @["--up", "--down"],
        descs: {"--up": "Move\n  up", "--down": "Move down"}.toTable)
      check arg.rows().plain == @[row("--up", "Move\n  up"), row("--down", "Move down")]

    test "single-line help starting with a list marker is a list item":
      let arg = TestArg(variants: @["-x"], help: "- reads as an item and hangs when it wraps")
      check arg.rows().mapIt(it.text.wrapProse(24).mapIt(it.plain)) ==
        @[@["- reads as an item and", "  hangs when it wraps"]]

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

    test "long help text wraps in its own column, continuing at the text column":
      let
        row = row("-x", "This is a moderately long help description")
        expected = "  -x     This is a moderately\n         long help description"
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
        expected = "  -x  aVeryLongSingleWordThatE\n      xceedsTwentyCharacters"
        rendered = renderColumn(@[row], width = 30, colWidth = 2)
      check rendered == expected

    test "variants column and text columns wrap independently":
      let
        arg = Arg(
          variants: @["-v", "--verbose", "--quiet", "--boost", "--dampen"],
          help: "This is some help text that will need to be wrapped")
        expected = """
          -v, --verbose,        This is some help text that will
            --quiet, --boost,   need to be wrapped
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

    test "each block of a row's text starts at the text column":
      let rows = @[row("-m", "Picks how blocks are checked.\n\nModes:\n" &
        "- fast: skips verification entirely\n    an indented line that wraps at its indent")]
      check renderColumn(rows, width = 40, colWidth = 2) ==
        "  -m  Picks how blocks are checked.\n" &
        "\n" &
        "      Modes:\n" &
        "      - fast: skips verification\n" &
        "        entirely\n" &
        "          an indented line that wraps at\n" &
        "          its indent"

    test "a paragraph's wrap continuations start at the text column":
      check renderColumn(@[row("-m", "One.\n\nA second paragraph that wraps")],
          width = 30, colWidth = 2) ==
        "  -m  One.\n\n      A second paragraph that\n      wraps"

    test "a paragraph's wrap continuations stay within the width":
      # Regression: they used to hang 2 columns past it.
      let rendered = renderColumn(@[row("-a, --alpha", "one two three four five " &
        "six seven eight nine ten eleven twelve")], width = 40, colWidth = 11)
      check rendered.splitLines.allIt(it.len <= 40)

    test "a block starts at the text column while the variants still wrap":
      check renderColumn(@[row("-m, --mode, --method", "One.\n\nModes:\n" &
          "- fast: skips verification entirely")], width = 44, colWidth = 10) ==
        "  -m,         One.\n" &
        "    --mode,\n" &
        "    --method  Modes:\n" &
        "              - fast: skips verification\n" &
        "                entirely"

    test "text keeps a gap after a variants line that fills its column":
      check renderColumn(@[row("-m, --abcdefgh", "One.\nTwo.")],
          width = 40, colWidth = 10) ==
        "  -m,         One.\n    --abcdefgh  Two."

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

  suite "HelpContext.prose":
    proc ctxAt(width: int, style: Styler = nil): HelpContext =
      plainSpec((), settings = newSpecSettings(style = style, width = width)
        ).helpContext("p")

    proc lines(text: string, width = 40): seq[string] =
      ctxAt(width).prose(text).mapIt(it.plain)

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
      let ctx = ctxAt(40, tagged)
      check ctx.prose("Use `--speed\n<kn>` now").mapIt(ctx.render(it)) ==
        @["Use {option:--speed} {positional:<kn>} now"]

    test "the backticks are kept":
      check lines("See `-x` and ``y``") == @["See `-x` and `y`"]

    test "a wrapped span keeps its role and no span holds a newline":
      let wrapped = ctxAt(20, tagged).prose("Now pass `--long-option` to\nturn it on")
      check wrapped.mapIt(it.render(tagged)) ==
        @["Now pass", "{option:--long-option} to", "turn it on"]
      for line in wrapped:
        for span in line.spans:
          check '\n' notin span.text

  suite "wrapProse":
    proc lines(t: StyledText, width = 20): seq[string] =
      t.wrapProse(width).mapIt(it.plain)

    test "empty text has no lines":
      check StyledText().wrapProse(20).len == 0

    test "a line with no indent or marker wraps at exactly the width":
      check lines(styled("a line that wraps at ten"), 10) ==
        @["a line", "that wraps", "at ten"]

    test "each line is a block, and an empty line stays empty":
      check lines(styled("one\n\ntwo")) == @["one", "", "two"]

    test "a list item hangs under its text":
      check lines(styled("- an item that wraps under its text")) ==
        @["- an item that wraps", "  under its text"]
      check lines(styled("  10. a nested item that wraps"), 24) ==
        @["  10. a nested item that", "      wraps"]

    test "an indented line keeps its indent":
      check lines(styled("    an indented line that wraps")) ==
        @["    an indented line", "    that wraps"]

    test "hung text gets at least 20 columns, or the width if narrower":
      check lines(styled("- a list item wrapping at twenty"), 21) ==
        @["- a list item wrapping", "  at twenty"]
      check lines(styled("- a list item"), 10) == @["- a list", "  item"]

    test "a line of only spaces comes out empty, and a bare marker trimmed":
      check lines(styled("one\n   \n  - ")) == @["one", "", "  -"]

    test "only an srPlain marker makes a list item":
      check lines(styled(srLiteral, "- x") & styled(" reads stdin, which wraps")) ==
        @["- x reads stdin,", "which wraps"]

    test "roles survive the wrap, and no span holds a newline":
      let wrapped = (styled("- use ") & styled(srOption, "--speed") &
        styled(" to\ngo faster than before")).wrapProse(20)
      check wrapped.mapIt(it.render(tagged)) ==
        @["- use {option:--speed} to", "go faster than", "before"]
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
        check Spec(settings: newSpecSettings(style = nil)).genHelp("prog", formatter) == "Usage:\n  prog"

    test "the usage block shows the spec's usage string after the command":
      let spec = Spec(settings: newSpecSettings(style = nil), usage: "<foo> [--bar]")
      for formatter in builtins:
        check spec.genHelp("prog", formatter) == "Usage:\n  prog <foo> [--bar]"

    test "prolog comes first, separated from the usage block by a blank line":
      let spec = Spec(settings: newSpecSettings(style = nil), prolog: "foo")
      for formatter in builtins:
        check spec.genHelp("prog", formatter) == "foo\n\nUsage:\n  prog"

    test "epilog comes last, separated from the usage block by a blank line":
      let spec = Spec(settings: newSpecSettings(style = nil), epilog: "bar")
      for formatter in builtins:
        check spec.genHelp("prog", formatter) == "Usage:\n  prog\n\nbar"

    test "a long prolog and epilog wrap at the width":
      let
        long = "A prolog long enough that it cannot possibly fit in forty columns."
        spec = Spec(settings: newSpecSettings(width = 40, style = nil),
          prolog: long, epilog: long)
      for formatter in builtins:
        let help = spec.genHelp("prog", formatter)
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
        check spec.genHelp("prog", formatter).startsWith(
          "Naval Fate.\n\nMoves ships and mines around.\n\nUsage:")

    test "a subcommand's prolog wraps at its own width":
      let
        child = plainSpec((), prolog = "A subcommand prolog long enough to wrap at forty.")
        parent = plainSpec(
          (ship: CommandArg(kind: ArgKind.Command, variants: @["ship"], spec: child)),
          settings = newSpecSettings(width = 40, style = nil))
      for formatter in builtins:
        check parent.commands["ship"].spec.genHelp("p ship", formatter).startsWith(
          "A subcommand prolog long enough to wrap\nat forty.\n\n")

    test "groups come between the usage block and the epilog, each separated by a blank line":
      let spec = plainSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Arguments")),
        usage = "<foo>", prolog = "foo", epilog = "bar")
      for formatter in builtins:
        check spec.genHelp("prog", formatter) == "foo\n\nUsage:\n  prog <foo>\n\nArguments:\n  <foo>\n\nbar"

    test "a custom group's header gets a colon too":
      let spec = plainSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], group: "Output")),
        usage = "<foo>")
      for formatter in builtins:
        check "\n\nOutput:\n  <foo>" in spec.genHelp("prog", formatter)

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
      check spec.genHelp("prog", formatColumn) == expected

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
      check spec.genHelp("prog", formatColumn) == expected

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
      check spec.genHelp("prog", formatColumn) == expected

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
      check spec.genHelp("prog", formatColumn) == expected

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
      check spec.genHelp("prog", formatColumn) == expected

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

    test "a blank line in a row's text renders empty, with no indent":
      check renderParagraph(@[row("-x", "One.\n\nTwo.")]) ==
        "  -x\n    One.\n\n    Two."

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
      check spec.genHelp("prog", formatParagraph) == expected

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
      check spec.genHelp("prog", formatParagraph) == expected

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
      check spec.genHelp("prog", formatParagraph) == expected

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
      check spec.genHelp("prog", formatParagraph) == expected

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
      check spec.genHelp("prog", formatParagraph) == expected

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
      check spec.genHelp("prog", formatParagraph) == expected

    test "multi-block help renders as paragraphs and a list under the variants":
      let spec = plainSpec(
        (mode: TestArg(kind: ArgKind.Optional, variants: @["-m", "--mode=<m>"],
          group: "Options", defaultStrVal: "fast", help: (short: "Pick a mode.",
          long: """
            Picks how blocks are checked.

            Modes:
            - fast: skips verification
            - safe: checks every block"""))),
        usage = "[options]", settings = newSpecSettings(width = 50, style = nil))
      check spec.genHelp("p", formatParagraph).split("Options:\n")[1] == @[
        "  -m, --mode=<m>",
        "    Picks how blocks are checked.",
        "",
        "    Modes:",
        "    - fast: skips verification",
        "    - safe: checks every block",
        "",
        "    [default: fast]"].join("\n")

  suite "HelpContext":
    proc ctxFor(style: Styler): HelpContext =
      plainSpec(
        (speed: Arg(kind: ArgKind.Optional, variants: @["--speed=<kn>"],
          help: "In `<kn>`", group: "Options")),
        usage = "[--speed=<kn>]", prolog = "See `-x`.",
        settings = newSpecSettings(style = style, width = 50)).helpContext("p")

    test "takes the command, width and Styler from the Spec":
      let ctx = ctxFor(tagged)
      check ctx.command == "p"
      check ctx.width == 50
      check ctx.render(styled(srOption, "-x")) == "{option:-x}"
      check ctx.render([styled("a"), styled(srOption, "-x")]) == "a\n{option:-x}"

    test "keeps Help Markup's ticks with no Styler":
      let ctx = ctxFor(nil)
      check ctx.rows(ctx.spec.args[0])[0].text.plain == "In `<kn>`"
      check ctx.prose(ctx.spec.prolog).mapIt(it.plain) == @["See `-x`."]
      check ctx.markup("`-y`").plain == "`-y`"

    test "drops them with a Styler":
      let ctx = ctxFor(tagged)
      check ctx.render(ctx.rows(ctx.spec.args[0])[0].text) == "In {metavar:<kn>}"
      check ctx.render(ctx.prose(ctx.spec.prolog)) == "See {option:-x}."
      check ctx.render(ctx.markup("`-y`")) == "{option:-y}"

    test "prose drops the ticks before wrapping, not after":
      # 20 columns fit "aaaaaaaaaa bbbbbb -x" only once the ticks are gone.
      let ctx = plainSpec((), settings = newSpecSettings(style = tagged,
        width = 20)).helpContext("p")
      check ctx.prose("aaaaaaaaaa bbbbbb `-x`").mapIt(it.plain) ==
        @["aaaaaaaaaa bbbbbb -x"]

    test "hands out the usage lines and headings":
      let ctx = ctxFor(tagged)
      check ctx.render(ctx.usage) ==
        "  {program:p} [{option:--speed}={metavar:<kn>}]"
      check ctx.render(ctx.heading("Options")) == "{header:Options:}"

    test "groups skips hidden Args":
      let ctx = plainSpec((
        a: Arg(kind: Positional, variants: @["<a>"], group: "Arguments"),
        b: Arg(kind: ArgKind.Flag, variants: @["--bee"], group: "Secret",
          hidden: true))).helpContext("p")
      var names: seq[string]
      for name, args in ctx.groups: names.add name
      check names == @["Arguments"]

  suite "genHelp":
    test "returns the formatter's output verbatim":
      let custom = proc (ctx: HelpContext): string = "custom help for " & ctx.command
      check Spec(settings: newSpecSettings()).genHelp("prog", custom) == "custom help for prog"

    test "defaults to formatColumn":
      let spec = plainSpec(
        (foo: Arg(kind: Positional, variants: @["<foo>"], help: "A sample arg", group: "Arguments")),
        prolog = "foo", epilog = "bar")
      check spec.genHelp("prog") == spec.genHelp("prog", formatColumn)
      check spec.genHelp("prog") != spec.genHelp("prog", formatParagraph)

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
      check arg.rows[0].text.withoutTicks.render(tagged) ==
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
      check arg.rows[0].text.withoutTicks.render(tagged) ==
        "{metavar:<kn>} knots, see {positional:<name>} and {option:--moored}"

    test "help text keeps its backticks, as srTick spans":
      let arg = Arg(kind: ArgKind.Flag, variants: @["-x"], help: "like `-y`")
      check arg.rows[0].text.plain == "like `-y`"
      check arg.rows[0].text.withoutTicks.plain == "like -y"

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
        let help = spec.genHelp("p", formatter)
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
        let help = styledSpec().genHelp("p", formatter)
        check help.startsWith("{header:Usage:}\n  {program:p}")
        check "{header:Options:}\n" in help

    test "Column Style tags variants and markup":
      check styledSpec().genHelp("p", formatColumn).splitLines[^1] ==
        "  {option:--speed}={metavar:<kn>}  In {metavar:<kn>}"

    test "Paragraph Style tags variants and markup":
      check styledSpec().genHelp("p", formatParagraph).splitLines[^2 .. ^1] ==
        @["  {option:--speed}={metavar:<kn>}", "    In {metavar:<kn>}"]

    test "prolog and epilog get Help Markup, context-only":
      for formatter in builtins:
        let help = styledSpec("See `--speed <kn>` and `$HOME`.",
          "Try `ship`\nor `--speed=<kn>`.\n\n  `$HOME`").genHelp("p", formatter)
        check help.startsWith(
          "See {option:--speed} {positional:<kn>} and {env:$HOME}.\n\n")
        check help.endsWith("\n\nTry {literal:ship} or " &
          "{option:--speed}={metavar:<kn>}.\n\n  {env:$HOME}")

    test "with no styler, prose keeps its backticks and collapses escapes":
      let spec = plainSpec(
        (x: Arg(kind: ArgKind.Flag, variants: @["-x"], help: "`-y` or ``z``", group: "Options")),
        usage = "[-x]", prolog = "`a` ``b``", settings = newSpecSettings(style = nil))
      for formatter in builtins:
        let help = spec.genHelp("p", formatter)
        check help.startsWith("`a` `b`\n\n")
        check "`-y` or `z`" in help
