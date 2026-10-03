# Help and Messages

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Displaying Help

`help` builds a `HelpArg`: a flag that, when matched, prints an auto-generated
help message for the spec (usage lines, grouped args with their `help` text,
`[default: ...]`/validator constraints folded in — see the [Features
list](https://github.com/squattingmonk/argumint#features)) and exits
successfully, the same short-circuiting behavior as `message`/`version`. Every
spec throughout this guide declaring a `help: help()` field has been using this.

```nim
let spec = (
  name: arg("<name>", help = "The name to call you"),
  help: help()
)

spec.parseOrQuit(usage = "<name>", prolog = "Greets someone by name")
```

```console
$ ./hello --help
Greets someone by name

Usage:
  hello <name>
  hello (-h | --help)

Arguments:
  <name>      The name to call you

Options:
  -h, --help  Display this help message
```

Each `Arg` is printed with all its variants along with the `help` text specified
in its constructor. To hide an `Arg` from the help message (e.g., for an `Arg`
deprecated but supported for legacy reasons), set `hidden = true` in the `Arg`'s
constructor.

Front and end matter for the help message come from the `prolog` and `epilog`
fields in `parse()`/`parseOrQuit()`/`command()`.

Each `Arg`'s help entry is grouped by type: positional arguments are grouped
under `Arguments`, options and flags are grouped under `Options`, and commands
are grouped under `Commands`. You can control which group an `Arg` appears in
(and even add your own custom groups) using the `group` parameter in its
constructor. Within the group, `Arg`s are ordered in the order they are declared
in the spec.

Usage lines and help text wrap at `SpecSettings.width` (default: the
detected terminal width, capped at `DefaultMaxWidth` = 100 and falling back
to `DefaultWidth` = 80 columns, detected only when help or an error is
first rendered); the variants column (`-v, --verbose`)
wraps once it exceeds `SpecSettings.maxVariantsWidth` (default 30; `0`
means unlimited). Set either via `newSpecSettings`, passed as
`parse`/`parseOrQuit`'s `settings` argument:

```nim
spec.parseOrQuit(settings = newSpecSettings(width = 100, maxVariantsWidth = 40))
```

An explicit `width` is never capped. Pass `width = detectWidth()` to follow
the terminal however wide it is, or `width = min(detectWidth(), 120)` for a
cap of your own.

The prolog and epilog wrap at the same width. Their line breaks are
re-flowed, so a long one can be written as an indented `"""` string:

```nim
spec.parseOrQuit(prolog = """
  Naval Fate: moves ships and lays mines, and
  keeps lines that run on together in one paragraph.

  Modes:
  - fast: skips verification, which is quick
    but unsafe
  - safe: checks every block

      naval_fate ship new <name>
  """)
```

The indentation every line shares is removed (a tab counts as up to 8
spaces), so start the text on the line after the opening `"""`, not right
after it. Consecutive lines then join into a paragraph, and a blank line
separates paragraphs. A line starting with `-`, `*`, or `1.` and a space
starts a list item. A line indented to the item's text, like `but unsafe` above,
continues it, and a long item wraps under its text. Any other indented line
is kept as its own line. To break a line without starting a new paragraph,
leave a blank line or indent it.

A variant name or help-text word too long to fit its column splits at the
character level rather than overflowing it whole. If that's undesirable for
a particular spec (e.g. one with unusually long option names), raise
`maxVariantsWidth`/`width` to fit, or set `maxVariantsWidth = 0` to disable
the variants-column cap entirely.

### Paragraph Style and Long-Form Help Text

The help message is rendered by a pluggable `HelpFormatter` (`proc (spec:
Spec, command: string): string`). Two ship built-in. **Column Style**
(`formatColumn`, the default shown above) aligns every arg's variants and
help text into a two-column table. **Paragraph Style** (`formatParagraph`)
instead puts each arg's variants on their own line, with its help text
wrapped as an indented paragraph below — more room for args with long
variant names or long descriptions, at the cost of column alignment. Pass
it to `help()`'s `formatter` parameter:

```nim
let spec = (
  name: arg("<name>", help = "The name to call you"),
  help: help(formatter = formatParagraph)
)

spec.parseOrQuit(usage = "<name>", prolog = "Greets someone by name")
```

```console
$ ./hello --help
Greets someone by name

Usage:
  hello <name>
  hello (-h | --help)

Arguments:
  <name>
    The name to call you

Options:
  -h, --help
    Display this help message
```

A spec can declare more than one `help()` flag, each with its own
formatter — e.g. `-h`/`--help` for the default Column Style and a separate
`--help-verbose` for Paragraph Style.

An arg's `help` parameter can also take a `(short, long)` pair instead of a
plain string, giving it a longer, prose-form description for specs that
want more detail than fits comfortably in a two-column table. Paragraph
Style prefers the long form when it's given; Column Style always uses the
short form, since a fixed-width column has no room for a longer
description anyway:

```nim
let spec = (
  speed: opt[int]("--speed=<speed>", default = 10, help = (
    "Speed in knots",
    "Speed in knots. Must be between 1 and 100; higher speeds increase fuel consumption.")),
  help: help(formatter = formatParagraph)
)
```

```console
$ ./ship --help
Usage:
  ship [--speed=<speed>]
  ship (-h | --help)

Options:
  --speed=<speed>
    Speed in knots. Must be between 1 and 100; higher speeds increase fuel
    consumption. [default: 10]

  -h, --help
    Display this help message
```

The same spec under the default Column Style ignores the long form
entirely:

```console
$ ./ship --help
Usage:
  ship [--speed=<speed>]
  ship (-h | --help)

Options:
  --speed=<speed>  Speed in knots [default: 10]
  -h, --help       Display this help message
```

Help text is re-flowed by the same rule as the prolog and epilog, so a
long form can be a `"""` string with paragraphs and lists:

```nim
mode: opt("-m, --mode=<m>", default = "fast", help = ("Pick a mode.", """
  Picks how blocks are checked.

  Modes:
  - fast: skips verification
  - safe: checks every block"""))
```

```console
  -m, --mode=<m>
    Picks how blocks are checked.

    Modes:
    - fast: skips verification
    - safe: checks every block

    [default: "fast"]
```

When help text runs to more than one block, the `[...]` bracket follows it
as its own paragraph, so it never reads as part of a list item. Column
Style lays out a multi-block short form the same way, inside its column.
See `docs/adr/0054-reflow-prolog-and-epilog.md` for the rule and
`docs/adr/0055-reflow-arg-help-text.md` for how rows carry it.

A `HelpFormatter` renders the whole message, so a custom one controls
section order and labels as well as how each arg is laid out. It's a proc
taking a `HelpContext`: everything one render of one Spec needs, with its
width and styler already applied. To write one, `import argumint/help`
directly for the context's pieces, the same ones
`formatColumn`/`formatParagraph` are built from: `groups` (each group's
visible args, in display order), `rows`/`Row` (an arg's variants and
resolved help text), `prose` (a prolog or epilog re-flowed, as described
above), `usage` (the wrapped usage lines, without a label), `heading`, and
`markup` for styling your own prose; plus `spec` for the
`prolog`/`epilog`/`usage` accessors and `joinSections` (joins the non-empty
parts with a blank line between each). Variants, usage lines and headings
are `StyledText`, a sequence of spans that each carry a role (option,
positional, header, ...): lay them out with `wrap` and `len`, then turn
each line into a string with `ctx.render`, which colours it as the
built-ins do, or plain when the spec is unstyled. A `Row.text` and what
`prose` returns are `Prose`: help text re-flowed into paragraphs, list
items and indented lines. `wrap` is the only way to lay it out, giving
`StyledText` lines with each block's continuation lines hung under its
text:

```nim
import std/strutils
import argumint, argumint/help

proc formatShouty(ctx: HelpContext): string =
  let width = max(ctx.width, 24)
  var groups: seq[string]
  for name, args in ctx.groups:
    var lines = @[name.toUpperAscii & ":"]
    for arg in args:
      for row in ctx.rows(arg):
        lines.add "  " & ctx.render(row.variants)
        for line in row.text.wrap(width - 4):
          lines.add "    " & ctx.render(line)
    groups.add lines.join("\n")
  joinSections(ctx.render(ctx.prose(ctx.spec.prolog).wrap(width)),
    "USAGE:\n" & ctx.render(ctx.usage),
    joinSections(groups), ctx.render(ctx.prose(ctx.spec.epilog).wrap(width)))
```

These stay reachable only through that direct import rather than a plain
`import argumint`, keeping this lower-level surface opt-in for anyone who
doesn't need it (the `HelpContext` type itself is nameable from either, as
`HelpFormatter` is). A parse error's usage block doesn't go through a
formatter; it always uses the standard `Usage:` layout.

### Styling Help and Errors

When stdout and stderr are both a terminal, help and parse-error output are
coloured by role: headers bold, options and commands bold cyan,
`<positionals>` and `<metavars>` cyan, env var names yellow, literal values
green, URLs blue and underlined, the `[...]` annotation brackets dim, the
`Parsing error:` label bold red, and the token a parse error blames
(`srInvalid`) bold yellow. Anywhere else, like a pipe, a file, or
`TERM=dumb`, the output is plain text, so escape codes never end up in a
log. `NO_COLOR` (set to anything) turns colour off; `FORCE_COLOR` (set to
anything) or `CLICOLOR_FORCE` (set to anything but `0`) turns it on even
without a terminal. On Windows, argumint turns on the console's ANSI
handling itself.

The styler is `SpecSettings.style`, which defaults to `autoStyler`, the
detection above, run only when help or an error is first rendered. Pass
`nil` for plain text always, or your own look:

```nim
var theme = defaultTheme
theme[srOption] = TextStyle(fg: fgMagenta, attrs: {styleBright})
theme[srHeader] = TextStyle(attrs: {styleBright})

spec.parseOrQuit(settings = newSpecSettings(style = ansiStyler(theme)))
```

A `Theme` sets a `TextStyle` (a `std/terminal` foreground colour plus a set
of attributes like bold and underline) for each `StyleRole`. For anything a
theme can't express, like true colour, backgrounds, or clickable `srUrl`
hyperlinks, write your own `Styler`, a proc that decorates one span of text:
`proc (role: StyleRole, text: string): string`. Since layout is measured
before styling, a styler can add whatever it likes without breaking
alignment. A caught exception's `msg` is always plain, help included. Its
`styledMsg` holds the styled form, the same text when there's no styler, and
is what `parseOrQuit` prints.

Help text, `prolog`, `epilog`, and a validator's or clamp's `desc` are
**Help Markup**: wrap a name in backticks and it gets the style of what it
looks like.

```nim
let spec = (
  speed: opt("--speed=<kn>", default = 10,
    help = "Speed in `<kn>`; overrides `$SHIP_SPEED`"),
  help: help()
)

spec.parseOrQuit(epilog = "See `ship move --help` for more.")
```

`-x`/`--xx` is styled as an option, `--xx=<m>` as an option and its
metavar, `<name>` (or all-caps `NAME`) as a metavar if the arg itself takes
a `<name>` value and as a positional otherwise, `$NAME` or `%NAME%` as an
env var, `https://...` (any `scheme://`) as a URL, and anything else as a
literal. When the output is styled, the backticks are dropped; when it's
plain, they're kept, so the text reads the same either way. Write a doubled
backtick (``` `` ```) for a literal one. Markup never fails: an unclosed
backtick is just a backtick, and a backticked `--flag` doesn't have to be
one of your spec's (since help may well mention another program's).

## Custom Messages

`message`/`version` each build a `MessageArg`: a flag that, when matched,
raises a `MessageError` printing a fixed string, short-circuiting the rest
of the spec's dispatch. `parse` lets you intercept the `MessageError`,
while `parseOrQuit` exits with `QuitSuccess` when one is raised.

- `message()` prints a given message.
- `version()` is a thin wrapper around `message` for the common case of a
  version flag (e.g. `version("-v, --version", "1.2.3")`)

```nim
let spec = (
  ver: version("-v, --version", "myapp 1.2.3"),
  license: message("--license", "MIT License. See LICENSE for details.",
    help = "Show license information"),
)

spec.parseOrQuit()
```

```console
$ ./myapp --version
myapp 1.2.3

$ ./myapp --license
MIT License. See LICENSE for details.
```

`version`/`message` both just take a plain `string`, so nothing stops that
string from coming from a compile-time define instead of a literal — handy for
keeping a `--version` flag in sync with your `.nimble` file (or a git revision)
without editing source on every release:

```nim
const NimblePkgVersion {.strdefine.} = "devel"

let
  spec = (
    ver: version("-v, --version", NimblePkgVersion),
    # ...
  )
```

Building with `nimble build`/`nimble c` sets `NimblePkgVersion` for you,
straight from the package's own `.nimble` file; a plain `nim c` falls back
to `"devel"` unless you pass `-d:NimblePkgVersion=...` yourself.
