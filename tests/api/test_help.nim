# Pins for what `import argumint/help` alone reaches (ADR 0090). With no
# `newSpec` in scope there's no Spec to render, so the formatter below is
# compiled, not run: each call in it reaches its name. tests/api/
# test_customarg.nim explains `paramType`.

import std/[macros, unittest]

import argumint/help

# pins: argumint/help.HelpContext
proc formatter(ctx: HelpContext): string =
  # pins: argumint/help.spec,HelpContext
  # pins: argumint/help.prolog,Spec
  # pins: argumint/help.epilog,Spec
  var sections = @[ctx.spec.prolog, ctx.spec.epilog]
  # pins: argumint/help.helpContext,Spec,string
  # pins: argumint/help.genHelp,Spec,string,HelpFormatter
  # pins: argumint/help.formatParagraph,HelpContext
  sections.add genHelp(ctx.spec, "prog", formatParagraph)
  discard helpContext(ctx.spec, "prog")
  # pins: argumint/help.width,HelpContext
  # pins: argumint/help.MinWidth
  let columns = max(ctx.width, MinWidth)
  # pins: argumint/help.usage,HelpContext
  # pins: argumint/help.render,HelpContext,openArray[StyledText]
  sections.add ctx.render(ctx.usage)
  # pins: argumint/help.command,HelpContext
  # pins: argumint/help.markup,HelpContext,string
  var title = ctx.markup("`" & ctx.command & "`")
  # pins: argumint/help.StyledText.spans
  # pins: argumint/help.Span.role
  # pins: argumint/help.Span.text
  let first = title.spans[0]
  sections.add $first.role & first.text
  # pins: argumint/help.add,StyledText,Span
  title.add first
  # pins: argumint/help.add,StyledText,StyledText
  title.add ctx.markup("more")
  # pins: argumint/help.render,HelpContext,StyledText
  # pins: argumint/help.len,StyledText
  # pins: argumint/help.alignLeft,StyledText,int
  sections.add ctx.render(title.alignLeft(title.len + 2))
  # pins: argumint/help.wrap,StyledText,int
  sections.add ctx.render(title.wrap(columns))
  # pins: argumint/help.prose,HelpContext,string
  # pins: argumint/help.Prose
  let para: Prose = ctx.prose("Some *text*.")
  # pins: argumint/help.wrap,Prose,int
  sections.add ctx.render(para.wrap(columns))
  # pins: argumint/help.groups.i,HelpContext
  for group in ctx.groups:
    sections.add group.name
    for arg in group.args:
      # pins: argumint/help.Arg.help
      # pins: argumint/help.HelpText.short
      # pins: argumint/help.HelpText.long
      # pins: argumint/help.longOrShort,HelpText
      sections.add arg.help.short & arg.help.long & arg.help.longOrShort
      # pins: argumint/help.Arg.group
      # pins: argumint/help.Arg.hidden
      # pins: argumint/help.Arg.complete
      if arg.hidden or arg.group.len == 0: discard arg.complete
      # pins: argumint/help.HelpArg
      # pins: argumint/help.HelpArg.formatter
      # pins: argumint/help.MessageArg.message
      if arg of HelpArg and not HelpArg(arg).formatter.isNil:
        sections.add HelpArg(arg).message
      # pins: argumint/help.rows,HelpContext,Arg,string
      # pins: argumint/help.Row
      # pins: argumint/help.Row.variants
      # pins: argumint/help.Row.text
      for row in ctx.rows(arg, help = arg.help.longOrShort):
        sections.add ctx.render(row.variants & row.text.wrap(columns))
      # pins: argumint/help.filter,HelpContext,proc(Arg)
      let visible = ctx.filter(proc (a: typeof(arg)): bool = not a.hidden)
      # pins: argumint/help.filterAnnotations,HelpContext,proc(Arg,HelpAnnotation)
      # pins: argumint/help.HelpAnnotation
      # pins: argumint/help.HelpAnnotation.kind
      # pins: argumint/help.HelpAnnotation.text
      # pins: argumint/help.HelpAnnotationKind
      # pins: argumint/help.HelpAnnotationKind.haDefault
      let plain = visible.filterAnnotations(proc (a: typeof(arg),
          annotation: HelpAnnotation): bool =
        annotation.kind != haDefault and annotation.text.len > 0)
      # pins: argumint/help.formatColumn,HelpContext
      sections.add formatColumn(plain)
  # pins: argumint/help.frame,HelpContext,RowRenderer
  # pins: argumint/help.RowRenderer
  # pins: argumint/help.HelpTextForm
  # pins: argumint/help.HelpTextForm.Long
  let renderRows: RowRenderer = proc (rows: seq[Row]): seq[typeof(title)] =
    for row in rows: result.add row.variants
  sections.add ctx.frame(renderRows, HelpTextForm.Long)
  # pins: argumint/help.joinSections,varargs[string]
  joinSections(sections)

macro paramType(p: typed, i: static int): untyped =
  ## The type of proc `p`'s `i`th parameter, which may have no name here.
  p.getTypeImpl[0][i + 1][1]

proc onHelp(info: paramType(showHelp, 0)) =
  # pins: argumint/help.showHelp,HookInfo
  showHelp(info)

suite "`import argumint/help` alone":
  test "a formatter can be written from it":
    # pins: argumint/help.HelpFormatter
    let f: HelpFormatter = formatter
    check not f.isNil

  test "the rest of what a formatter reaches":
    # pins: argumint/help.HelpTextForm.Short
    check HelpTextForm.Short != HelpTextForm.Long
    # pins: argumint/help.HelpAnnotationKind.haValidator
    # pins: argumint/help.HelpAnnotationKind.haClamp
    # pins: argumint/help.HelpAnnotationKind.haEnv
    # pins: argumint/help.HelpAnnotationKind.haConfigKey
    # pins: argumint/help.HelpAnnotationKind.haAction
    check {haValidator, haClamp, haDefault, haEnv, haConfigKey, haAction}.len == 6
    check not onHelp.isNil
