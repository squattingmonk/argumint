## Help-text rendering: turns a built `Spec` into the message `--help`
## prints. Sits directly above `argumint/backend` -- see
## `docs/architecture.md` for why, and for how the variants column wraps.
##
## `import argumint` alone does not bring `genHelp` into scope; importing
## this module directly is what makes it callable, so a program can render
## its own help instead of only receiving it via the `HelpError` a matched
## `help*` Arg raises -- see
## `docs/adr/0042-genhelp-opt-in-via-submodule.md`.

import std/[importutils, strformat, strutils, tables, wordwrap]

import ./backend

privateAccess(Spec) ## Reaches `Spec`'s private fields (ADR 0030) from
  ## non-generic code only -- see docs/gotchas.md.

const CanonicalGroups = ["Commands", "Arguments", "Options"]

proc groupOrder(spec: Spec): seq[string] =
  ## Returns `spec.groups`' keys ordered as `Commands`, `Arguments`,
  ## `Options`, then any other (e.g. user-defined) groups in the order they
  ## were first declared.
  for group in CanonicalGroups:
    if group in spec.groups:
      result.add group
  for group in spec.groups.keys:
    if group notin CanonicalGroups:
      result.add group

proc variantGroups(arg: Arg): seq[tuple[names: seq[string], desc: string]] =
  ## Groups `arg.variants` by their `variantDesc` text, preserving
  ## declaration order (both across groups and within one). Collapses to
  ## exactly one group (`desc` possibly `""`) whenever every variant shares
  ## the same description -- i.e. every arg that isn't a flag with
  ## genuinely divergent per-variant ops -- so callers that don't care
  ## about grouping still see a single group covering all of `arg.variants`.
  var byDesc = initOrderedTable[string, seq[string]]()
  for v in arg.variants:
    byDesc.mgetOrPut(arg.variantDesc(v), @[]).add v
  for desc, names in byDesc.pairs:
    result.add (names: names, desc: desc)

proc genHelp*(spec: Spec, command: string): string =
  ## Renders `spec`'s full help message -- prolog, wrapped usage lines, one
  ## row per arg grouped per `groupOrder`, then epilog. `command` names the
  ## program in the usage lines (`HelpArg.action` passes the command path
  ## that reached this Spec, so a subcommand's help reads `prog ship move`).
  ## Wrapping is governed by `spec.settings.width`/`maxVariantsWidth`.
  let prolog = if spec.prolog.len > 0: spec.prolog & "\n\n" else: ""
  let epilog = if spec.epilog.len > 0: spec.epilog else: ""
  let usage = spec.usage.formatUsage(command, spec.settings.width) & "\n"

  var rawColWidth = 0
  for arg in spec.args:
    for vg in arg.variantGroups():
      rawColWidth = max(rawColWidth, vg.names.join(", ").len)
  let colWidth =
    if spec.settings.maxVariantsWidth > 0: min(rawColWidth, spec.settings.maxVariantsWidth)
    else: rawColWidth

  let continuationIndent = "    " # deeper than the "  " row margin, so a wrapped
                                   # variants continuation (or a divergent-op
                                   # sub-row) isn't mistaken for a new arg

  var lines: seq[string]
  for group in spec.groupOrder:
    var argLines: seq[string]
    for arg in spec.groups[group]:
      if arg.hidden:
        continue
      let groups = arg.variantGroups()
      for vg in groups:
        let variants = vg.names.join(", ")
        let margin = "  " # every group is a peer row, not a wrap continuation -- see
                           # continuationIndent's own use below for actual wrapping
        # Every group of a divergent flag repeats the arg's shared `help` and
        # arg-level annotations (validator/default/env/configKey), not just
        # the first-declared variant -- that repetition is what visually ties
        # the rows together as variants of the same value now that they're no
        # longer indented as a nested continuation of the first row.
        let divergent = groups.len > 1 and vg.desc.len > 0
        let primary = if arg.help.len > 0: arg.help elif divergent: vg.desc else: ""
        var annotations: seq[string]
        if arg.validatorHelp.len > 0: annotations.add arg.validatorHelp
        if arg.defaultStr.len > 0: annotations.add "default: {arg.defaultStr}".fmt
        if arg.envName.len > 0: annotations.add "env: {arg.envName}".fmt
        if arg.configKey.len > 0: annotations.add "configKey: {arg.configKey.join}".fmt
        if divergent and arg.help.len > 0: annotations.add "action: {vg.desc}".fmt
        let bracket = if annotations.len > 0: "[{annotations.join(\"; \")}]".fmt else: ""
        let text =
          if bracket.len == 0: primary
          elif primary.len == 0: bracket
          else: "{primary} {bracket}".fmt
        let variantLines = variants.wrapWords(colWidth, splitLongWords = false).splitLines
        if text.len > 0:
          let helpWidth = max(spec.settings.width - (2 + colWidth + 2), 20)
          let textLines = text.wrapWords(helpWidth, splitLongWords = false).splitLines
          for j in 0 ..< max(variantLines.len, textLines.len):
            let v = if j < variantLines.len: variantLines[j] else: ""
            let t = if j < textLines.len: textLines[j] else: ""
            if t.len > 0:
              let rowMargin = if j == 0: margin else: continuationIndent
              argLines.add(rowMargin & v.alignLeft(colWidth) & "  " & t)
            elif j > 0:
              argLines.add(continuationIndent & v)
            else:
              argLines.add(margin & v)
        else:
          for j, v in variantLines:
            if j > 0:
              argLines.add(continuationIndent & v)
            else:
              argLines.add(margin & v)
    if argLines.len > 0:
      lines.add("\n{group}".fmt)
      lines.add(argLines)

  let args = lines.join("\n")
  result = fmt"{prolog}{usage}{args}{epilog}"
