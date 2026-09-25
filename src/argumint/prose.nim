## Prose: help text re-flowed into blocks -- paragraphs, list items,
## indented lines, and blank lines -- and laid out by wrapping. Owns the
## re-flow rule (`docs/adr/0054-reflow-prolog-and-epilog.md`), where an Arg's
## `[...]` bracket goes (`docs/adr/0055-reflow-arg-help-text.md`), and
## completion's one-line `summary`. Help Markup inside a block is `style`'s.
##
## Only `Prose` and `wrap` reach formatters, through `argumint/help`; the
## rest is withheld.

import std/strutils

import ./style

type
  ProseKind = enum
    pkBlank, pkParagraph, pkItem, pkLine

  ProseBlock = object
    ## One paragraph, list item, indented line, or blank line, still
    ## unwrapped.
    kind: ProseKind
      ## What the block is; a `pkBlank` has no `text`
    indent: int
      ## Columns before the first line's `marker` (or text, if none)
    marker: string
      ## A `pkItem`'s marker and its space (`- `, `10. `), or empty
    text: StyledText
      ## The joined text, with Help Markup applied

  Prose* = object
    ## Help text re-flowed into blocks (paragraphs, list items, indented
    ## lines, blank lines), with Help Markup applied. Lay it out with `wrap`.
    ## See `docs/adr/0060-prose-type.md`, and
    ## `docs/adr/0054-reflow-prolog-and-epilog.md` for the rule.
    blocks: seq[ProseBlock]

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
  var expanded: seq[string]
  for line in text.splitLines:
    expanded.add line.expandIndent
  for line in expanded.join("\n").dedent.splitLines:
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

proc toProse*(text: string, metavars: openArray[string] = []): Prose =
  ## `text` dedented and joined into blocks, each with Help Markup against
  ## `metavars`:
  ##
  ## - Consecutive unindented lines join into a paragraph; a blank line
  ##   separates paragraphs and is kept.
  ## - A line starting with `- `, `* `, or `1. ` starts a list item. A line
  ##   indented to exactly the item's text column continues it.
  ## - Any other indented line is its own block.
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
    result.blocks.add shape
    result.blocks[^1].text = markup(raw, metavars)

proc withoutTicks*(p: Prose): Prose =
  ## `p` without Help Markup's ticks, as styled output shows it.
  result = p
  for b in result.blocks.mitems:
    b.text = b.text.withoutTicks

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

proc annotate*(p: var Prose, parts: openArray[StyledText]) =
  ## Adds `parts` to `p` as a `[...]` bracket, each part flattened to one line
  ## and joined with `; `: after a space if `p` is one block, as its own block
  ## after a blank line if it's several. Nothing if `parts` is empty. See
  ## `docs/adr/0055-reflow-arg-help-text.md`.
  if parts.len == 0:
    return
  var bracket = styled(srAnnotation, "[")
  for i, part in parts:
    if i > 0: bracket.add styled(srAnnotation, "; ")
    bracket.add part.oneLine
  bracket.add styled(srAnnotation, "]")
  case p.blocks.len
  of 0:
    p.blocks.add ProseBlock(kind: pkParagraph, text: bracket)
  of 1:
    p.blocks[0].text.add styled(" ") & bracket
  else:
    p.blocks.add ProseBlock(kind: pkBlank)
    p.blocks.add ProseBlock(kind: pkParagraph, text: bracket)

proc wrap*(p: Prose, width: int): seq[StyledText] =
  ## Lays out `p` as wrapped lines, one `StyledText` per line, none
  ## containing `\n`; empty if `p` is. A block starts at its indent, a list
  ## item with its marker, and its continuation lines hang under its text. A
  ## blank block comes out empty. A paragraph wraps at exactly `width`; hung
  ## text gets at least 20 columns (or `width`, if narrower), so a deep
  ## indent overflows instead of looping. See
  ## `docs/adr/0055-reflow-arg-help-text.md`.
  for b in p.blocks:
    if b.kind == pkBlank:
      result.add StyledText()
      continue
    let hang = b.indent + b.marker.len
    if b.text.len == 0:
      result.add styled(' '.repeat(b.indent) & b.marker.strip(leading = false))
      continue
    for i, line in b.text.wrap(max(width - hang, min(width, 20))):
      let lead = if i == 0: ' '.repeat(b.indent) & b.marker else: ' '.repeat(hang)
      result.add styled(lead) & line

proc summary*(text: string): string =
  ## `text`'s first paragraph on one line, as it reads with no Styler, for a
  ## completion description: dedented, cut at the first blank line, its lines
  ## stripped and joined with a space, any tab turned into a space, and Help
  ## Markup's ticks kept. See
  ## `docs/adr/0022-completion-candidate-help-text.md`.
  var first: string
  for line in text.dedentLines:
    if line.len == 0:
      break
    first.addSep " "
    first.add line.strip.replace('\t', ' ')
  plainMarkup(first)

when isMainModule:
  import std/[sequtils, unittest]

  proc tagged(role: StyleRole, text: string): string =
    if role == srPlain: text
    else: "{" & ($role)[2 .. ^1].toLowerAscii & ":" & text & "}"

  proc lines(p: Prose, width = 20): seq[string] =
    p.wrap(width).mapIt(it.plain)

  proc lines(text: string, width = 20): seq[string] =
    text.toProse.lines(width)

  suite "toProse":
    test "empty or all-blank text has no blocks":
      check "".toProse.blocks.len == 0
      check " \n\n  \n".toProse.blocks.len == 0

    test "a `\"\"\"` string loses its shared indentation":
      check "\n    one\n      two\n    three\n".toProse.blocks.mapIt(it.kind) ==
        @[pkParagraph, pkLine, pkParagraph]

    test "unindented lines join into a paragraph, a blank line separating them":
      let p = "one\ntwo\n\nthree".toProse
      check p.blocks.mapIt(it.kind) == @[pkParagraph, pkBlank, pkParagraph]
      check p.blocks[0].text.plain == "one two"

    test "a list item continues on a line indented to its text":
      let p = "- one\n  two\n 3. x\n    y".toProse
      check p.blocks.mapIt((it.kind, it.indent, it.marker, it.text.plain)) == @[
        (pkItem, 0, "- ", "one two"), (pkItem, 1, "3. ", "x y")]

    test "any other indented line is its own block":
      check "a\n   b\n   c".toProse.blocks.mapIt((it.kind, it.indent)) ==
        @[(pkParagraph, 0), (pkLine, 3), (pkLine, 3)]

    test "Help Markup applies inside each block, against the metavars":
      check "- `<n>` times".toProse(["n"]).blocks[0].text.render(tagged) ==
        "{tick:`}{metavar:<n>}{tick:`} times"

    test "withoutTicks drops the ticks from every block":
      check "`-x`\n\n- `y`".toProse.withoutTicks.lines ==
        @["-x", "", "- y"]

  suite "annotate":
    let parts = @[styled(srAnnotation, "default: ") & styled(srLiteral, "3")]

    test "nothing to add leaves the prose as it was":
      var p = "one".toProse
      p.annotate([])
      check p == "one".toProse

    test "the bracket ends one-block text after a space":
      var p = "- one".toProse
      p.annotate(parts)
      check p.blocks.mapIt((it.kind, it.marker, it.text.plain)) ==
        @[(pkItem, "- ", "one [default: 3]")]

    test "the bracket follows several blocks after a blank line":
      var p = "one\n\ntwo".toProse
      p.annotate(parts)
      check p.blocks.mapIt((it.kind, it.text.plain)) == @[(pkParagraph, "one"),
        (pkBlank, ""), (pkParagraph, "two"), (pkBlank, ""), (pkParagraph, "[default: 3]")]

    test "empty prose gets the bracket alone":
      var p = "".toProse
      p.annotate(parts)
      check p.blocks.mapIt((it.kind, it.text.plain)) == @[(pkParagraph, "[default: 3]")]

    test "parts are joined with `; ` and each flattened to one line":
      var p = "".toProse
      p.annotate([styled("a\n  b"), styled("\nc\n")])
      check p.blocks[0].text.render(tagged) ==
        "{annotation:[}a b{annotation:; }c{annotation:]}"

  suite "wrap":
    test "empty prose has no lines":
      check "".toProse.wrap(20).len == 0

    test "a paragraph wraps at exactly the width":
      check lines("a line that wraps at ten", 10) == @["a line", "that wraps", "at ten"]

    test "a blank block comes out empty":
      check lines("one\n\ntwo") == @["one", "", "two"]

    test "a list item hangs under its text":
      check lines("- an item that wraps under its text") ==
        @["- an item that wraps", "  under its text"]
      check lines("x\n  10. a nested item that wraps", 24) ==
        @["x", "  10. a nested item that", "      wraps"]

    test "an indented line keeps its indent":
      check lines("x\n    an indented line that wraps") ==
        @["x", "    an indented line", "    that wraps"]

    test "hung text gets at least 20 columns, or the width if narrower":
      check lines("- a list item wrapping at twenty", 21) ==
        @["- a list item wrapping", "  at twenty"]
      check lines("- a list item", 10) == @["- a list", "  item"]

    test "a bare marker comes out trimmed":
      check lines("one\n  - ") == @["one", "  -"]

    test "a backticked marker is a literal, not an item":
      check lines("`- x` reads stdin, which wraps") ==
        @["`- x` reads stdin,", "which wraps"]
      check "`- x` reads stdin".toProse.blocks[0].kind == pkParagraph

    test "roles survive the wrap, and no span holds a newline":
      let wrapped = "- use `--speed` to\n  go faster than before".toProse.withoutTicks.wrap(20)
      check wrapped.mapIt(it.render(tagged)) ==
        @["- use {option:--speed} to go", "  faster than before"]
      for line in wrapped:
        for span in line.spans:
          check '\n' notin span.text

  suite "summary":
    test "a single line is unchanged":
      check summary("Logging verbosity") == "Logging verbosity"

    test "empty or all-blank text is empty":
      check summary("") == ""
      check summary("\n  \n\n") == ""

    test "stops at the first blank line, joining lines with a space":
      check summary("First line\nsecond line\n\nMore.") == "First line second line"

    test "a list without a blank line before it is part of the paragraph":
      check summary("Modes:\n- fast\n- safe") == "Modes: - fast - safe"

    test "a `\"\"\"` string loses its source indentation":
      check summary("""
        Picks how blocks are checked,
        and how often.

        More.""") == "Picks how blocks are checked, and how often."

    test "inner spacing is kept, and tabs become spaces":
      check summary("  Just  one  line  ") == "Just  one  line"
      check summary("has\ta tab") == "has a tab"

    test "Help Markup reads as plain: ticks kept, doubled backticks collapsed":
      check summary("use `-x`, not ``y``") == "use `-x`, not `y`"
