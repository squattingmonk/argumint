## Styled text: the span model help and error output render through. Layout
## (wrap, pad, column width) runs on plain span text; a `Styler` is applied
## per span only at `render` time, so it can emit anything without skewing
## widths -- see `docs/architecture.md`.
##
## A leaf module with no local imports.

import std/[strutils, unicode]

type
  StyleRole* = enum
    ## The semantic part of a message a span holds.
    srPlain
    srHeader
    srProgram
    srCommand
    srOption
    srPositional
    srMetavar
    srEnv
    srLiteral
    srAnnotation
    srError

  Span* = object
    ## A run of text sharing one role. Never contains `\n` once wrapped.
    role*: StyleRole
      ## What part of the message `text` is
    text*: string
      ## The plain text, with no escape codes

  StyledText* = object
    ## A sequence of spans. Kept normalized by `add`: no empty spans, and no
    ## two adjacent spans sharing a role, so equal text compares equal.
    spans*: seq[Span]
      ## The spans, in order

  Styler* = proc (role: StyleRole, text: string): string
    ## Decorates one span's text for display; nil renders plain.

proc add*(t: var StyledText, span: Span) =
  ## Appends `span`, merging it into the last span if they share a role.
  if span.text.len == 0:
    return
  if t.spans.len > 0 and t.spans[^1].role == span.role:
    t.spans[^1].text.add span.text
  else:
    t.spans.add span

proc add*(t: var StyledText, other: StyledText) =
  ## Appends each of `other`'s spans.
  for span in other.spans:
    t.add span

proc styled*(role: StyleRole, text: string): StyledText =
  ## `text` as a single span with `role` (no spans if `text` is empty).
  result.add Span(role: role, text: text)

proc styled*(text: string): StyledText =
  ## `text` as a single `srPlain` span.
  styled(srPlain, text)

proc `&`*(a, b: StyledText): StyledText =
  ## `a` followed by `b`.
  result = a
  result.add b

proc plain*(t: StyledText): string =
  ## The text with all styling dropped.
  for span in t.spans:
    result.add span.text

proc graphemeCount(s: string; start, lastExclusive: int): int =
  ## The number of graphemes in `s[start ..< lastExclusive]`: its visible
  ## width, as `wrapWords` measures it.
  var i = start
  while i < lastExclusive:
    inc result
    inc i, graphemeLen(s, i)

proc len*(t: StyledText): int =
  ## The visible width of `t`: its plain text's grapheme count, the same
  ## measure `wrap` uses.
  let s = t.plain
  graphemeCount(s, 0, s.len)

proc alignLeft*(t: StyledText, width: int): StyledText =
  ## `t` padded with plain spaces to `width` visible columns; unchanged if
  ## already that wide.
  result = t
  result.add styled(' '.repeat(max(width - t.len, 0)))

proc wrapWords(s: string, maxLineWidth: int, newLine = "\n"): string =
  ## Word-wraps `s`, splitting a word longer than `maxLineWidth` at the
  ## character level instead of overflowing it whole. Forked from
  ## `std/wordwrap.wrapWords(splitLongWords = true)` to fix a bug there: it
  ## drops the separator immediately before a word that needs splitting (e.g.
  ## wrapping "-x, --longflag" at width 9 comes back as "-x,--lon", eating
  ## the space) instead of flushing it first, like the "word fits" path does.
  ## See docs/gotchas.md.
  result = newStringOfCap(s.len + s.len shr 6)
  var spaceLeft = maxLineWidth
  var lastSep = ""

  var i = 0
  while true:
    var j = i
    let isSep = j < s.len and s[j] in Whitespace
    while j < s.len and (s[j] in Whitespace) == isSep: inc(j)
    if j <= i: break
    if isSep:
      lastSep.setLen 0
      for k in i..<j:
        if s[k] notin {'\L', '\C'}: lastSep.add s[k]
      if lastSep.len == 0:
        lastSep.add ' '
        dec spaceLeft
      else:
        spaceLeft -= graphemeCount(lastSep, 0, lastSep.len)
    else:
      let wlen = graphemeCount(s, i, j)
      if wlen > spaceLeft:
        if wlen > maxLineWidth:
          if lastSep.len > 0 and spaceLeft > 0:
            result.add(lastSep)
          var k = 0
          while k < j - i:
            if spaceLeft <= 0:
              spaceLeft = maxLineWidth
              result.add newLine
            dec spaceLeft
            let L = graphemeLen(s, k + i)
            for m in 0 ..< L: result.add s[i + k + m]
            inc k, L
        else:
          spaceLeft = maxLineWidth - wlen
          result.add(newLine)
          for k in i..<j: result.add(s[k])
      else:
        spaceLeft -= wlen
        result.add(lastSep)
        for k in i..<j: result.add(s[k])
    i = j

proc wrap*(t: StyledText, width: int): seq[StyledText] =
  ## Word-wraps `t` to `width` visible columns, one `StyledText` per line,
  ## splitting any span that crosses a line break. Measures plain text only.
  ## Always yields at least one (possibly empty) line.
  let src = t.plain
  var roles = newSeqOfCap[StyleRole](src.len)
  for span in t.spans:
    for _ in 0 ..< span.text.len:
      roles.add span.role

  # Maps each wrapped byte back to `src`'s role -- see docs/architecture.md.
  var
    line: StyledText
    p = 0
  for c in src.wrapWords(width):
    if c == '\n':
      result.add line
      line = StyledText()
    elif c in Whitespace:
      var q = p
      while q < src.len and src[q] in {'\L', '\C'}: inc q
      if q < src.len and src[q] == c:
        line.add Span(role: roles[q], text: $c)
        p = q + 1
      else:
        line.add Span(role: roles[p], text: $c)
        p = q
    else:
      while src[p] != c: inc p
      line.add Span(role: roles[p], text: $c)
      inc p
  result.add line

proc render*(t: StyledText, styler: Styler = nil): string =
  ## `t`'s spans passed through `styler` and concatenated; plain if nil.
  if styler.isNil:
    return t.plain
  for span in t.spans:
    result.add styler(span.role, span.text)

proc render*(lines: openArray[StyledText], styler: Styler = nil): string =
  ## Each of `lines` rendered with `styler`, joined with `\n`.
  for i, line in lines:
    if i > 0: result.add '\n'
    result.add line.render(styler)

when isMainModule:
  import std/[sequtils, unittest]

  proc tagged(role: StyleRole, text: string): string =
    "<" & $role & ">" & text & "</" & $role & ">"

  suite "StyledText":
    test "adjacent spans with the same role merge":
      check (styled(srOption, "-x") & styled(srOption, ", -y")).spans ==
        @[Span(role: srOption, text: "-x, -y")]

    test "empty spans are dropped":
      check styled(srOption, "").spans.len == 0
      check (styled(srPlain, "a") & styled(srOption, "") & styled(srPlain, "b")) ==
        styled(srPlain, "ab")

    test "plain drops the roles":
      check (styled(srOption, "-x") & styled(srPlain, " ok")).plain == "-x ok"

    test "styled with no role is plain":
      check styled("x") == styled(srPlain, "x")

    test "len is the visible width, not the byte count":
      check (styled(srOption, "-x") & styled(srPlain, " ok")).len == 5
      check styled(srPlain, "héllo").len == 5

  suite "alignLeft":
    test "pads with plain spaces to the width":
      check styled(srOption, "-x").alignLeft(4) ==
        styled(srOption, "-x") & styled(srPlain, "  ")

    test "text at or past the width is unchanged":
      check styled(srOption, "-xyz").alignLeft(2) == styled(srOption, "-xyz")

    test "pads to the visible width, not the byte count":
      check styled("é").alignLeft(3).plain == "é  "

  suite "wrap":
    test "text that fits is one line, spans intact":
      let t = styled(srOption, "-x") & styled(srPlain, " fits")
      check t.wrap(20) == @[t]

    test "empty text is one empty line":
      check StyledText().wrap(20) == @[StyledText()]

    test "a span crossing a wrap point splits into per-line spans":
      let
        t = styled(srPlain, "see ") & styled(srLiteral, "one two three") &
          styled(srPlain, " end")
        expected = @[
          styled(srPlain, "see ") & styled(srLiteral, "one"),
          styled(srLiteral, "two three"),
          styled(srPlain, "end")]
      check t.wrap(9) == expected

    test "no span contains a newline, even one from the input":
      let t = styled(srPlain, "a\nb ") & styled(srOption, "--long-option-name")
      for line in t.wrap(8):
        for span in line.spans:
          check '\n' notin span.text

    test "width is measured on plain text, not rendered text":
      let
        t = styled(srOption, "-x") & styled(srPlain, " y")
        lines = t.wrap(4)
      check lines == @[t]
      check lines[0].render(tagged).len > 4

    test "a word longer than the width splits across lines, keeping its role":
      let t = styled(srOption, "--abcdef")
      check t.wrap(4) == @[styled(srOption, "--ab"), styled(srOption, "cdef")]

    test "the plain lines match the plain wrap":
      let t = styled(srPlain, "-x, ") & styled(srOption, "--longflag") &
        styled(srPlain, " and\nmore text here")
      check t.wrap(10).mapIt(it.plain) ==
        t.plain.wrapWords(10).splitLines

  suite "render":
    test "a nil styler concatenates the plain text":
      let t = styled(srOption, "-x") & styled(srPlain, " ok")
      check t.render(nil) == "-x ok"
      check t.render() == "-x ok"

    test "a styler decorates each span by its role":
      let t = styled(srOption, "-x") & styled(srPlain, " ok")
      check t.render(tagged) == "<srOption>-x</srOption><srPlain> ok</srPlain>"

    test "lines render joined with a newline":
      let lines = @[styled(srOption, "-x"), styled(srPlain, "ok")]
      check lines.render(tagged) == "<srOption>-x</srOption>\n<srPlain>ok</srPlain>"
      check lines.render() == "-x\nok"
