## Styled text: the span model help and error output render through. Layout
## (wrap, pad, column width) runs on plain span text; a `Styler` is applied
## per span only at `render` time, so it can emit anything without skewing
## widths -- see `docs/architecture.md`. Also home to the built-in ANSI
## `Theme` and Help Markup -- see
## `docs/adr/0051-help-and-error-styling.md` -- plus the plain-text helpers
## help's re-flow and completion's descriptions share (`dedentLines`,
## `firstParagraph`), kept here because `completion` doesn't import `help`,
## and the Styled Text helpers help rows and parse-error complaints share
## (`styledOption`, `join`), since `complaints` builds its own text.
##
## A leaf module with no local imports.

import std/[pegs, strutils, terminal]
import std/unicode except strip # Buggy -- see docs/gotchas.md.

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
    srUrl
    srAnnotation
    srTick
    srError
    srInvalid

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

  TextStyle* = object
    ## How `ansiStyler` shows one role.
    fg*: ForegroundColor = fgDefault
      ## The text colour; `fgDefault` leaves it unchanged
    attrs*: set[Style]
      ## Bold, dim, underline, etc.

  Theme* = array[StyleRole, TextStyle]
    ## A `TextStyle` per role. Start from a copy of `defaultTheme`: a bare
    ## `var` of this type isn't initialized with `fgDefault`.

const defaultTheme*: Theme = [
  srPlain: TextStyle(),
  srHeader: TextStyle(attrs: {styleBright}),
  srProgram: TextStyle(attrs: {styleBright}),
  srCommand: TextStyle(fg: fgCyan, attrs: {styleBright}),
  srOption: TextStyle(fg: fgCyan, attrs: {styleBright}),
  srPositional: TextStyle(fg: fgCyan),
  srMetavar: TextStyle(fg: fgCyan),
  srEnv: TextStyle(fg: fgYellow),
  srLiteral: TextStyle(fg: fgGreen),
  srUrl: TextStyle(fg: fgBlue, attrs: {styleUnderscore}),
  srAnnotation: TextStyle(attrs: {styleDim}),
  srTick: TextStyle(),
  srError: TextStyle(fg: fgRed, attrs: {styleBright}),
  srInvalid: TextStyle(fg: fgYellow, attrs: {styleBright})]
  ## The built-in look `autoStyler` uses.

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

proc heading*(name: string): StyledText =
  ## A section heading (`Usage`, a group name) with its colon, as `srHeader`.
  ## Shared by help and parse-error output so the two can't drift.
  styled(srHeader, name & ":")

proc `&`*(a, b: StyledText): StyledText =
  ## `a` followed by `b`.
  result = a
  result.add b

proc join*(parts: openArray[StyledText], sep: StyledText): StyledText =
  ## `parts` in order, with `sep` between each pair.
  for i, part in parts:
    if i > 0:
      result.add sep
    result.add part

proc styledOption*(variant: string): StyledText =
  ## An option's `variant` as `srOption`, with a value placeholder split off
  ## (`--speed=<kn>` is `srOption`, `srPlain`, `srMetavar`). Shared by help
  ## rows and parse-error complaints so the two can't drift.
  let placeholder = variant.find('<')
  if placeholder > 1:
    styled(srOption, variant[0 ..< placeholder - 1]) &
      styled(variant[placeholder - 1 .. placeholder - 1]) &
      styled(srMetavar, variant[placeholder .. ^1])
  else:
    styled(srOption, variant)

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

proc ansiStyler*(theme: Theme): Styler =
  ## A `Styler` wrapping each span in the ANSI codes for its role's `TextStyle`,
  ## and leaving a role with no style as plain text.
  result = proc (role: StyleRole, text: string): string =
    let style = theme[role]
    if style.fg == fgDefault and style.attrs == {}:
      return text
    for attr in style.attrs:
      result.add ansiStyleCode(attr)
    if style.fg != fgDefault:
      result.add ansiForegroundColorCode(style.fg)
    result.add text
    result.add ansiResetCode

proc autoStyler*(role: StyleRole, text: string): string =
  ## `newSpecSettings`'s default `style`: a marker, not a styler. The first
  ## read of `SpecSettings.style` replaces it with `ansiStyler(defaultTheme)`
  ## if output is going to a terminal, else nil. Called directly, it leaves
  ## `text` plain.
  text

let
  # Placeholders take the lexer's two argument forms, `<name>` and `NAME`,
  # but a caps one must start with a letter so `42` stays a literal.
  OptionShape = peg"""
    option <- ^ {'--' name / '-' \w+} ({[=:] / \s+} {placeholder})? $
    placeholder <- '<' name '>' / caps
    name <- \w (\w / ('-' \w))*
    caps <- [A-Z] ([A-Z0-9] / ([_-] [A-Z0-9]))*
  """
  PlaceholderShape = peg"""
    placeholder <- ^ ('<' name '>' / caps) $
    name <- \w (\w / ('-' \w))*
    caps <- [A-Z] ([A-Z0-9] / ([_-] [A-Z0-9]))*
  """
  UrlShape = peg"^ [a-zA-Z] [a-zA-Z0-9+.-]* '://' \S+ $"
  EnvShape = peg"""
    env <- ^ ('$' name / '%' name '%') $
    name <- [A-Za-z_] \w*
  """

proc placeholder(code: string, metavars: openArray[string]): StyledText =
  ## A `<name>` or `NAME`: `srMetavar` if `name`/`NAME` is in `metavars`, else
  ## `srPositional`.
  let name = if code.startsWith('<'): code[1 ..< ^1] else: code
  styled(if name in metavars: srMetavar else: srPositional, code)

proc classify(code: string, metavars: openArray[string]): StyledText =
  ## A backticked span's roles, by shape alone -- see `markup`.
  var m: array[3, string]
  if code.match(OptionShape, m):
    result = styled(srOption, m[0]) & styled(m[1])
    if m[1] in ["=", ":"]:
      result.add styled(srMetavar, m[2])
    elif m[2].len > 0:
      result.add placeholder(m[2], metavars)
  elif code.match(PlaceholderShape):
    result = placeholder(code, metavars)
  elif code.match(EnvShape):
    result = styled(srEnv, code)
  elif code.match(UrlShape):
    result = styled(srUrl, code)
  else:
    result = styled(srLiteral, code)

proc markup*(prose: string, metavars: openArray[string] = []): StyledText =
  ## `prose` with Help Markup applied: each backticked span gets a role based on
  ## its shape -- `-x`/`--xx` is `srOption` (`--xx=<m>` adds `srMetavar`),
  ## `<name>` (or all-caps `NAME`) is `srMetavar` if `name` is in `metavars` and
  ## `srPositional` otherwise (as is one after an option and a space instead of
  ## a separator: `--speed <kn>`), `$NAME` or `%NAME%` is `srEnv`,
  ## `scheme://...` is `srUrl`, anything else is `srLiteral`. The rest is
  ## `srPlain`, and the backticks themselves are `srTick`, kept for plain
  ## output and dropped with `withoutTicks` for styled. A doubled backtick is a
  ## literal one, and so is an unclosed one; markup never fails. See
  ## `docs/adr/0051-help-and-error-styling.md`.
  var
    text = ""
    i = 0
  while i < prose.len:
    if prose[i] != '`':
      text.add prose[i]
      inc i
    elif prose.continuesWith("``", i):
      text.add '`'
      inc i, 2
    else:
      var
        code = ""
        j = i + 1
      while j < prose.len and (prose[j] != '`' or prose.continuesWith("``", j)):
        if prose[j] == '`':
          code.add '`'
          inc j, 2
        else:
          code.add prose[j]
          inc j
      if j == prose.len:
        text.add '`'
        inc i
        continue
      result.add styled(text)
      result.add styled(srTick, "`")
      result.add classify(code, metavars)
      result.add styled(srTick, "`")
      text = ""
      i = j + 1
  result.add styled(text)

proc withoutTicks*(t: StyledText): StyledText =
  ## `t` without its `srTick` spans: Help Markup as styled output shows it.
  for span in t.spans:
    if span.role != srTick: result.add span

proc plainMarkup*(prose: string): string =
  ## `prose` as it reads with no styler: Help Markup's ticks kept, doubled
  ## backticks collapsed. For prose shown outside help, like completion
  ## descriptions and validation errors.
  markup(prose).plain

proc expandIndent(line: string): string =
  ## `line` with the tabs in its indentation expanded to 8-column tab stops.
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}:
    result.add ' '.repeat(if line[i] == '\t': 8 - result.len mod 8 else: 1)
    inc i
  result.add line[i .. ^1]

proc dedentLines*(text: string): seq[string] =
  ## `text`'s lines with the indentation they share removed (`dedent`, after
  ## expanding tabs), trailing whitespace stripped, and leading and trailing
  ## blank lines dropped. A `"""` string starting on the line after its
  ## quotes loses its source indentation this way -- see
  ## `docs/adr/0054-reflow-prolog-and-epilog.md`. Shared by help's re-flow
  ## and `firstParagraph`.
  var expanded: seq[string]
  for line in text.splitLines:
    expanded.add line.expandIndent
  for line in expanded.join("\n").dedent.splitLines:
    result.add line.strip(leading = false)
  while result.len > 0 and result[0].len == 0: result.delete 0
  while result.len > 0 and result[^1].len == 0: result.setLen result.len - 1

proc firstParagraph*(text: string): string =
  ## `text`'s first paragraph on one line, for a completion description:
  ## dedented as `dedentLines` does, cut at the first blank line, its lines
  ## stripped and joined with a space, and any tab turned into a space. Help
  ## Markup is left for the caller. See
  ## `docs/adr/0022-completion-candidate-help-text.md`.
  for line in text.dedentLines:
    if line.len == 0:
      break
    result.addSep " "
    result.add line.strip.replace('\t', ' ')

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

  suite "heading":
    test "is the name plus a colon, all srHeader":
      check heading("Options") == styled(srHeader, "Options:")

  suite "join":
    test "puts the separator between parts, keeping their roles":
      check [styled(srOption, "-a"), styled(srOption, "-b")].join(styled(" | ")) ==
        styled(srOption, "-a") & styled(" | ") & styled(srOption, "-b")

    test "no parts is empty, and one part has no separator":
      check join(newSeq[StyledText](), styled(", ")) == StyledText()
      check [styled("a")].join(styled(", ")) == styled("a")

  suite "styledOption":
    test "splits a value placeholder off, after its separator":
      check styledOption("--speed=<kn>") ==
        styled(srOption, "--speed") & styled("=") & styled(srMetavar, "<kn>")

    test "an option with no placeholder is all srOption":
      check styledOption("-v") == styled(srOption, "-v")

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

  suite "ansiStyler":
    let styler = ansiStyler(defaultTheme)

    test "a role with no style is left plain":
      check styler(srPlain, "x") == "x"

    test "a styled role is wrapped in its codes and a reset":
      check styler(srPositional, "<x>") ==
        ansiForegroundColorCode(fgCyan) & "<x>" & ansiResetCode
      check styler(srAnnotation, "[") ==
        ansiStyleCode(styleDim) & "[" & ansiResetCode

    test "a custom theme is used as given":
      var theme = defaultTheme
      theme[srPlain] = TextStyle(fg: fgRed)
      check ansiStyler(theme)(srPlain, "x") ==
        ansiForegroundColorCode(fgRed) & "x" & ansiResetCode

  suite "markup":
    proc roles(t: StyledText): seq[(StyleRole, string)] =
      t.spans.mapIt((it.role, it.text))

    test "prose with no backticks is one plain span":
      check markup("plain text").roles == @[(srPlain, "plain text")]

    test "options are srOption":
      check markup("`-x` or `--long-name`").withoutTicks.roles == @[
        (srOption, "-x"), (srPlain, " or "), (srOption, "--long-name")]

    test "an option's value placeholder is srMetavar":
      check markup("`--speed=<kn>`").withoutTicks.roles ==
        @[(srOption, "--speed"), (srPlain, "="), (srMetavar, "<kn>")]
      check markup("`-s:<kn>`").withoutTicks.roles ==
        @[(srOption, "-s"), (srPlain, ":"), (srMetavar, "<kn>")]

    test "<name> is srPositional unless it's one of the given metavars":
      check markup("`<kn>`").withoutTicks.roles == @[(srPositional, "<kn>")]
      check markup("`<kn>`", @["kn"]).withoutTicks.roles == @[(srMetavar, "<kn>")]
      check markup("`<name>`", @["kn"]).withoutTicks.roles == @[(srPositional, "<name>")]

    test "a placeholder after an option and a space follows the <name> rule":
      check markup("`--speed <kn>`").withoutTicks.roles ==
        @[(srOption, "--speed"), (srPlain, " "), (srPositional, "<kn>")]
      check markup("`--speed <kn>`", @["kn"]).withoutTicks.roles ==
        @[(srOption, "--speed"), (srPlain, " "), (srMetavar, "<kn>")]

    test "an option with an = placeholder is always a metavar":
      check markup("`--speed=<kn>`", @["other"]).withoutTicks.roles ==
        @[(srOption, "--speed"), (srPlain, "="), (srMetavar, "<kn>")]

    test "$NAME and %NAME% are srEnv":
      check markup("`$HOME`").withoutTicks.roles == @[(srEnv, "$HOME")]
      check markup("`%USERPROFILE%`").withoutTicks.roles ==
        @[(srEnv, "%USERPROFILE%")]
      check markup("`%HOME`").withoutTicks.roles == @[(srLiteral, "%HOME")]

    test "scheme://... is srUrl":
      check markup("`https://example.com/a?b=c`").withoutTicks.roles ==
        @[(srUrl, "https://example.com/a?b=c")]
      check markup("`git+ssh://host/repo`").withoutTicks.roles ==
        @[(srUrl, "git+ssh://host/repo")]

    test "a URL needs a scheme, a host part, and no spaces":
      for code in ["example.com", "https://", "://x", "https://a b", "1http://x"]:
        check markup("`" & code & "`").withoutTicks.roles == @[(srLiteral, code)]

    test "an all-caps NAME is a placeholder, like <name>":
      check markup("`FILE`").withoutTicks.roles == @[(srPositional, "FILE")]
      check markup("`SHIP-NAME_2`").withoutTicks.roles ==
        @[(srPositional, "SHIP-NAME_2")]
      check markup("`KN`", @["KN"]).withoutTicks.roles == @[(srMetavar, "KN")]
      check markup("`--speed=KN`").withoutTicks.roles ==
        @[(srOption, "--speed"), (srPlain, "="), (srMetavar, "KN")]
      check markup("`--speed KN`").withoutTicks.roles ==
        @[(srOption, "--speed"), (srPlain, " "), (srPositional, "KN")]

    test "a caps word must start with a letter and stay caps to be a placeholder":
      check markup("`42`").withoutTicks.roles == @[(srLiteral, "42")]
      check markup("`File`").withoutTicks.roles == @[(srLiteral, "File")]
      check markup("`FILE-`").withoutTicks.roles == @[(srLiteral, "FILE-")]

    test "anything else is srLiteral":
      check markup("`a.txt`").withoutTicks.roles == @[(srLiteral, "a.txt")]

    test "ticks are srTick spans of their own":
      check markup("use `-x` here").roles == @[(srPlain, "use "), (srTick, "`"),
        (srOption, "-x"), (srTick, "`"), (srPlain, " here")]

    test "withoutTicks drops them":
      check markup("use `-x` here").withoutTicks.plain == "use -x here"

    test "a doubled backtick is a literal backtick":
      check markup("a``b").roles == @[(srPlain, "a`b")]
      check markup("`a``b`").withoutTicks.roles == @[(srLiteral, "a`b")]

    test "an unclosed backtick is a literal backtick":
      check markup("a `b").roles == @[(srPlain, "a `b")]
      check markup("`").roles == @[(srPlain, "`")]

    test "with ticks kept, the plain text is the prose, escapes collapsed":
      for prose in ["", "a `-x` b", "`--y=<z>`", "a `b", "``x``", "`$A` and `<b>`"]:
        check markup(prose).plain == prose.replace("``", "`")

  suite "plainMarkup":
    test "keeps ticks and collapses escapes":
      check plainMarkup("use `-x`, not ``y``") == "use `-x`, not `y`"

  suite "firstParagraph":
    test "a single line is unchanged":
      check firstParagraph("Logging verbosity") == "Logging verbosity"

    test "empty or all-blank text is empty":
      check firstParagraph("") == ""
      check firstParagraph("\n  \n\n") == ""

    test "the first paragraph's lines join with a space":
      check firstParagraph("First line\nsecond line\n\nMore.") == "First line second line"

    test "a paragraph running into a list keeps the list on the line":
      check firstParagraph("Modes:\n- fast\n- safe") == "Modes: - fast - safe"

    test "source indentation and leading blank lines are dropped":
      check firstParagraph("""

        Picks a mode.

        Modes:
        - fast""") == "Picks a mode."

    test "surrounding whitespace is trimmed, inner runs kept":
      check firstParagraph("  Just  one  line  ") == "Just  one  line"

    test "a tab becomes a space":
      check firstParagraph("has\ta tab") == "has a tab"
