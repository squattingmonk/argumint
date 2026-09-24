## Styled text: the span model help and error output render through. Layout
## (wrap, pad, column width) runs on plain span text; a `Styler` is applied
## per span only at `render` time, so it can emit anything without skewing
## widths -- see `docs/architecture.md`. Also home to the built-in ANSI
## `Theme`, `autoStyler`'s terminal detection, and Help Markup -- see
## `docs/adr/0051-help-and-error-styling.md`.
##
## A leaf module with no local imports.

import std/[os, pegs, strutils, terminal, unicode]

when defined(windows):
  import std/winlean

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
  srError: TextStyle(fg: fgRed, attrs: {styleBright})]
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

proc wantsColor(env: proc (key: string): string, ttys: bool): bool =
  ## `autoStyler`'s rule, given how to read an env var and whether stdout and
  ## stderr are both terminals.
  let clicolorForce = env("CLICOLOR_FORCE")
  if env("FORCE_COLOR").len > 0 or clicolorForce notin ["", "0"]:
    true
  elif env("NO_COLOR").len > 0 or env("TERM") == "dumb":
    false
  else:
    ttys

when defined(windows):
  const EnableVirtualTerminalProcessing = 0x0004

  proc enableVirtualTerminal(): bool =
    ## Turns on ANSI escape handling for stdout and stderr; false if either
    ## isn't a console that supports it.
    for id in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
      let handle = getStdHandle(id)
      var mode: DWORD
      if getConsoleMode(handle, addr mode) == 0 or
          setConsoleMode(handle, mode or EnableVirtualTerminalProcessing) == 0:
        return false
    true

proc autoStyler*(): Styler =
  ## `ansiStyler(defaultTheme)` if output is going to a terminal, else nil
  ## (plain). Nil when `NO_COLOR` is non-empty, `TERM` is `dumb`, or stdout and
  ## stderr aren't both terminals -- unless `FORCE_COLOR` is non-empty or
  ## `CLICOLOR_FORCE` is set to anything but `0`, which force colour on. On
  ## Windows it also enables the console's ANSI handling, and is nil if that
  ## fails and colour wasn't forced.
  let env = proc (key: string): string = getEnv(key)
  if not wantsColor(env, ttys = stdout.isatty and stderr.isatty):
    return nil
  when defined(windows):
    let forced = wantsColor(env, ttys = false)
    if not enableVirtualTerminal() and not forced:
      return nil
  ansiStyler(defaultTheme)

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

proc markup*(prose: string, metavars: openArray[string] = [], keepTicks = true): StyledText =
  ## `prose` with Help Markup applied: each backticked span gets a role based on
  ## its shape -- `-x`/`--xx` is `srOption` (`--xx=<m>` adds `srMetavar`),
  ## `<name>` (or all-caps `NAME`) is `srMetavar` if `name` is in `metavars` and
  ## `srPositional` otherwise (as is one after an option and a space instead of
  ## a separator: `--speed <kn>`), `$NAME` or `%NAME%` is `srEnv`,
  ## `scheme://...` is `srUrl`, anything else is `srLiteral`. The rest is `srPlain`. Backticks are kept if `keepTicks`
  ## (for plain output) and dropped otherwise. A doubled backtick is a literal
  ## one, and so is an unclosed one; markup never fails. See
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
      if keepTicks:
        text.add '`'
      result.add styled(text)
      result.add classify(code, metavars)
      text = if keepTicks: "`" else: ""
      i = j + 1
  result.add styled(text)

proc plainMarkup*(prose: string): string =
  ## `prose` as it reads with no styler: Help Markup's ticks kept, doubled
  ## backticks collapsed. For prose shown outside help, like completion
  ## descriptions and validation errors.
  markup(prose).plain

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

  suite "wantsColor":
    proc env(vars: varargs[(string, string)]): proc (key: string): string =
      let vars = @vars
      result = proc (key: string): string =
        for (k, v) in vars:
          if k == key: return v

    test "colour follows whether both streams are terminals":
      check wantsColor(env(), ttys = true)
      check not wantsColor(env(), ttys = false)

    test "a non-empty NO_COLOR turns it off":
      check not wantsColor(env(("NO_COLOR", "1")), ttys = true)
      check wantsColor(env(("NO_COLOR", "")), ttys = true)

    test "TERM=dumb turns it off":
      check not wantsColor(env(("TERM", "dumb")), ttys = true)
      check wantsColor(env(("TERM", "xterm")), ttys = true)

    test "a non-empty FORCE_COLOR turns it on, even over NO_COLOR":
      check wantsColor(env(("FORCE_COLOR", "1")), ttys = false)
      check wantsColor(env(("FORCE_COLOR", "0")), ttys = false)
      check wantsColor(env(("FORCE_COLOR", "1"), ("NO_COLOR", "1")), ttys = false)
      check not wantsColor(env(("FORCE_COLOR", "")), ttys = false)

    test "CLICOLOR_FORCE turns it on unless it's 0":
      check wantsColor(env(("CLICOLOR_FORCE", "1")), ttys = false)
      check wantsColor(env(("CLICOLOR_FORCE", "1"), ("TERM", "dumb")), ttys = false)
      check not wantsColor(env(("CLICOLOR_FORCE", "0")), ttys = false)

  suite "autoStyler":
    test "is nil when output isn't a terminal and colour isn't forced":
      let forced = getEnv("FORCE_COLOR").len > 0 or
        getEnv("CLICOLOR_FORCE") notin ["", "0"]
      if not forced and not (stdout.isatty and stderr.isatty):
        check autoStyler().isNil
      else:
        skip()

    when defined(windows):
      test "enabling ANSI handling fails without crashing when not a console":
        if not (stdout.isatty and stderr.isatty):
          check not enableVirtualTerminal()
          putEnv("FORCE_COLOR", "1")
          defer: delEnv("FORCE_COLOR")
          check not autoStyler().isNil # forced, despite the failure
        else:
          skip()

  suite "markup":
    proc roles(t: StyledText): seq[(StyleRole, string)] =
      t.spans.mapIt((it.role, it.text))

    test "prose with no backticks is one plain span":
      check markup("plain text").roles == @[(srPlain, "plain text")]

    test "options are srOption":
      check markup("`-x` or `--long-name`", keepTicks = false).roles == @[
        (srOption, "-x"), (srPlain, " or "), (srOption, "--long-name")]

    test "an option's value placeholder is srMetavar":
      check markup("`--speed=<kn>`", keepTicks = false).roles ==
        @[(srOption, "--speed"), (srPlain, "="), (srMetavar, "<kn>")]
      check markup("`-s:<kn>`", keepTicks = false).roles ==
        @[(srOption, "-s"), (srPlain, ":"), (srMetavar, "<kn>")]

    test "<name> is srPositional unless it's one of the given metavars":
      check markup("`<kn>`", keepTicks = false).roles == @[(srPositional, "<kn>")]
      check markup("`<kn>`", @["kn"], keepTicks = false).roles == @[(srMetavar, "<kn>")]
      check markup("`<name>`", @["kn"], keepTicks = false).roles == @[(srPositional, "<name>")]

    test "a placeholder after an option and a space follows the <name> rule":
      check markup("`--speed <kn>`", keepTicks = false).roles ==
        @[(srOption, "--speed"), (srPlain, " "), (srPositional, "<kn>")]
      check markup("`--speed <kn>`", @["kn"], keepTicks = false).roles ==
        @[(srOption, "--speed"), (srPlain, " "), (srMetavar, "<kn>")]

    test "an option with an = placeholder is always a metavar":
      check markup("`--speed=<kn>`", @["other"], keepTicks = false).roles ==
        @[(srOption, "--speed"), (srPlain, "="), (srMetavar, "<kn>")]

    test "$NAME and %NAME% are srEnv":
      check markup("`$HOME`", keepTicks = false).roles == @[(srEnv, "$HOME")]
      check markup("`%USERPROFILE%`", keepTicks = false).roles ==
        @[(srEnv, "%USERPROFILE%")]
      check markup("`%HOME`", keepTicks = false).roles == @[(srLiteral, "%HOME")]

    test "scheme://... is srUrl":
      check markup("`https://example.com/a?b=c`", keepTicks = false).roles ==
        @[(srUrl, "https://example.com/a?b=c")]
      check markup("`git+ssh://host/repo`", keepTicks = false).roles ==
        @[(srUrl, "git+ssh://host/repo")]

    test "a URL needs a scheme, a host part, and no spaces":
      for code in ["example.com", "https://", "://x", "https://a b", "1http://x"]:
        check markup("`" & code & "`", keepTicks = false).roles == @[(srLiteral, code)]

    test "an all-caps NAME is a placeholder, like <name>":
      check markup("`FILE`", keepTicks = false).roles == @[(srPositional, "FILE")]
      check markup("`SHIP-NAME_2`", keepTicks = false).roles ==
        @[(srPositional, "SHIP-NAME_2")]
      check markup("`KN`", @["KN"], keepTicks = false).roles == @[(srMetavar, "KN")]
      check markup("`--speed=KN`", keepTicks = false).roles ==
        @[(srOption, "--speed"), (srPlain, "="), (srMetavar, "KN")]
      check markup("`--speed KN`", keepTicks = false).roles ==
        @[(srOption, "--speed"), (srPlain, " "), (srPositional, "KN")]

    test "a caps word must start with a letter and stay caps to be a placeholder":
      check markup("`42`", keepTicks = false).roles == @[(srLiteral, "42")]
      check markup("`File`", keepTicks = false).roles == @[(srLiteral, "File")]
      check markup("`FILE-`", keepTicks = false).roles == @[(srLiteral, "FILE-")]

    test "anything else is srLiteral":
      check markup("`a.txt`", keepTicks = false).roles == @[(srLiteral, "a.txt")]

    test "ticks are kept as plain text if keepTicks":
      check markup("use `-x` here").roles ==
        @[(srPlain, "use `"), (srOption, "-x"), (srPlain, "` here")]

    test "ticks are dropped if not keepTicks":
      check markup("use `-x` here", keepTicks = false).plain == "use -x here"

    test "a doubled backtick is a literal backtick":
      check markup("a``b").roles == @[(srPlain, "a`b")]
      check markup("`a``b`", keepTicks = false).roles == @[(srLiteral, "a`b")]

    test "an unclosed backtick is a literal backtick":
      check markup("a `b").roles == @[(srPlain, "a `b")]
      check markup("`").roles == @[(srPlain, "`")]

    test "with ticks kept, the plain text is the prose, escapes collapsed":
      for prose in ["", "a `-x` b", "`--y=<z>`", "a `b", "``x``", "`$A` and `<b>`"]:
        check markup(prose).plain == prose.replace("``", "`")

  suite "plainMarkup":
    test "keeps ticks and collapses escapes":
      check plainMarkup("use `-x`, not ``y``") == "use `-x`, not `y`"
