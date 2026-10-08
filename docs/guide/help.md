# Help and Messages

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

`help()` adds a `-h, --help` flag that prints help for your program, built
from its spec, and exits:

```nim
import argumint

let spec = (
  name: arg("<name>", help = "Ship to move"),
  speed: opt("-s, --speed=<kn>", default = 10, env = "SHIP_SPEED",
    validator = range(1..30), help = "Speed in knots"),
  dock: flag("--dock", help = "Dock when it arrives"),
  help: help(),
)

spec.parseOrQuit(prolog = "Moves a ship to its next port.",
  epilog = "Ships never move faster than 30 knots.")
echo "Moving ", spec.name, " at ", spec.speed
```

```console
$ ./ship --help
Moves a ship to its next port.

Usage:
  ship [options] <name>
  ship (-h | --help)

Arguments:
  <name>            Ship to move

Options:
  -s, --speed=<kn>  Speed in knots [range: 1..30; default: 10; env: SHIP_SPEED]
  --dock            Dock when it arrives
  -h, --help        Display this help message

Ships never move faster than 30 knots.
```

From the top, help shows:

- The `prolog`, if you gave one.
- The usage lines. See [Usage Strings](usage-strings.md).
- Each `Arg` with its names and its `help` text. The brackets after the text
  list what argumint knows about the value: its default, its validator, and
  where else it can come from. See
  [Arguments and Options](args-and-options.md) and
  [Value Precedence](precedence.md).
- The `epilog`, if you gave one.

`parse` and `parseOrQuit` take `prolog` and `epilog` for the program's help,
and `command` takes them for a command's help.

To give the flag other names, pass them first. For example, `help("--help")`
leaves `-h` free for a `--host` option. Pass `help = "..."` to change the
flag's own description.

## Groups

Help lists each `Arg` under a heading:

- **Commands** for commands.
- **Arguments** for positional arguments.
- **Options** for options and flags.

Pass `group` to put an `Arg` under a heading of your own:

```nim
import argumint

let spec = (
  name: arg("<name>", help = "Ship to move"),
  speed: opt("-s, --speed=<kn>", default = 10, help = "Speed in knots"),
  verbose: flag("-v, --verbose", help = "Show each step", group = "Output"),
  quiet: flag("-q, --quiet", help = "Show nothing", group = "Output"),
  warp: flag("--warp", help = "Old name for a fast speed", hidden = true),
  help: help(),
)

spec.parseOrQuit()
echo "Moving ", spec.name, if spec.warp: " at warp" else: ""
```

```console
$ ./ship --help
Usage:
  ship [options] <name>
  ship (-h | --help)

Arguments:
  <name>            Ship to move

Options:
  -s, --speed=<kn>  Speed in knots [default: 10]
  -h, --help        Display this help message

Output:
  -v, --verbose     Show each step
  -q, --quiet       Show nothing
```

The built-in groups come first, in the order above, and then your own groups
in the order you first use them. Within a group, `Arg`s are listed in the
order you declared them.

`hidden = true` leaves an `Arg` out of these lists, and out of
[shell completion](completion.md), but the user can still give it, as with
`--warp` above:

```console
$ ./ship --warp Titanic
Moving Titanic at warp
```

A hidden `Arg` still shows in any usage line that names it. A positional
argument or a command is always named in a usage line, so hiding one only
removes it from the lists.

## Writing Longer Text

The prolog, the epilog and each `Arg`'s help text wrap to fit. Their line
breaks are re-flowed, so you can write a long one as an indented `"""`
string:

```nim
import argumint

let spec = (
  name: arg("<name>", help = "Ship to move"),
  help: help(),
)

spec.parseOrQuit(prolog = """
  Moves a ship to its next port. Each ship keeps a log of every
  port it visits, and these lines join into one paragraph.

  A ship takes one of two routes:
  - coastal: stays near land, which is slower but keeps the ship
    out of rough water
  - open sea: the fastest way between ports

      ship Titanic
  """)
```

```console
$ ./ship --help
Moves a ship to its next port. Each ship keeps a log of every port it visits,
and these lines join into one paragraph.

A ship takes one of two routes:
- coastal: stays near land, which is slower but keeps the ship out of rough
  water
- open sea: the fastest way between ports

    ship Titanic

Usage:
  ship <name>
  ship (-h | --help)

Arguments:
  <name>      Ship to move

Options:
  -h, --help  Display this help message
```

These rules turn the text into paragraphs:

- The indent that every line shares is removed, so start the text on the
  line after the opening `"""`.
- Lines next to each other join into one paragraph, and a blank line starts a
  new one.
- A line starting with `-`, `*` or a number and a dot, then a space, starts a
  list item. A
  line indented to the item's text, like `out of rough water`, continues it.
- Any other indented line stays a line of its own, like the example command
  above.

## Fitting the Terminal

Help wraps to the terminal's width, or to `COLUMNS` if it's set, up to 100
columns. When there's no terminal to measure, as when help is piped to a file,
it wraps at 80. Pass
`width` to `newSpecSettings` to choose your own:

```nim
spec.parseOrQuit(settings = newSpecSettings(width = 60))
```

A width you choose is used as given. Pass `width = detectWidth()` to use the
whole terminal however wide it is, or `width = min(detectWidth(), 120)` to
pick a different limit. To change the 100 and the 80 when you compile, see
[Changing the Defaults at Compile Time](specs.md#changing-the-defaults-at-compile-time).

The column of names wraps too, once it's wider than `maxVariantsWidth`
(30 by default):

```nim
import argumint

let spec = (
  speed: opt("-s, --speed=<kn>", default = 10,
    help = "Speed in knots, which the ship keeps until it reaches port"),
  log: opt("-l, --log, --log-file=<path>", help = "Where to write the ship's log"),
  help: help(),
)

spec.parseOrQuit(settings = newSpecSettings(width = 50, maxVariantsWidth = 20))
```

```console
$ ./ship --help
Usage:
  ship [options]
  ship (-h | --help)

Options:
  -s, --speed=<kn>      Speed in knots, which the
                        ship keeps until it
                        reaches port [default: 10]
  -l, --log,            Where to write the ship's
    --log-file=<path>   log
  -h, --help            Display this help message
```

A name or word too long for its column is split in the middle. To avoid that,
raise `maxVariantsWidth` or `width`, or pass `maxVariantsWidth = 0` to let
the column of names grow as wide as it needs.

## Paragraph Style

By default, help uses Column Style (`formatColumn`), which lines up names and
descriptions in two columns. Paragraph Style (`formatParagraph`) puts each
description in a paragraph under its names instead, which leaves more room for
long text. Pass it to `help` as `formatter`.

An `Arg`'s `help` can also be a pair of a short and a long description.
Paragraph Style shows the long one, and the default style shows the short
one. This spec has a second help flag for the long form:

```nim
import argumint

let spec = (
  name: arg("<name>", help = "Ship to move"),
  speed: opt("-s, --speed=<kn>", default = 10, help = ("Speed in knots",
    "Speed in knots. Faster ships burn more fuel, and no ship goes faster than 30.")),
  help: help(),
  helpLong: help("--help-long", help = "Display this help with more detail",
    formatter = formatParagraph),
)

spec.parseOrQuit()
```

```console
$ ./ship --help
Usage:
  ship [options] <name>
  ship (-h | --help)
  ship --help-long

Arguments:
  <name>            Ship to move

Options:
  -s, --speed=<kn>  Speed in knots [default: 10]
  -h, --help        Display this help message
  --help-long       Display this help with more detail

$ ./ship --help-long
Usage:
  ship [options] <name>
  ship (-h | --help)
  ship --help-long

Arguments:
  <name>
    Ship to move

Options:
  -s, --speed=<kn>
    Speed in knots. Faster ships burn more fuel, and no ship goes faster than
    30. [default: 10]

  -h, --help
    Display this help message

  --help-long
    Display this help with more detail
```

A long description follows the rules in
[Writing Longer Text](#writing-longer-text), so it can have paragraphs and
lists too.

## Colour

When both standard output and standard error go to a terminal, help and error
messages are in colour:
headings in bold, option and command names in bold cyan, placeholders like
`<name>` in cyan, environment variables in yellow, values in green, and the
brackets after each description dimmed. Piped to a file or another program,
or with `TERM=dumb`, the output is plain text.

The user can choose too:

- `NO_COLOR`, set to anything but an empty value, turns colour off.
- `FORCE_COLOR`, set to anything but an empty value, or `CLICOLOR_FORCE`, set
  to anything but `0`, turns it on even without a terminal. Either one wins
  over `NO_COLOR` and `TERM=dumb`.

On Windows, argumint turns on the console's colour support itself.

To change the colours, copy `defaultTheme`, change the roles you want, and
pass an `ansiStyler` built from it as `style`:

```nim
var theme = defaultTheme
theme[srOption] = TextStyle(fg: fgMagenta, attrs: {styleBright})
theme[srHeader] = TextStyle(attrs: {styleUnderscore})

spec.parseOrQuit(settings = newSpecSettings(style = ansiStyler(theme)))
```

Each `TextStyle` has a colour and a set of attributes from `std/terminal`.
The roles start with `sr`. See `StyleRole` in the
[API reference](https://squattingmonk.github.io/argumint/argumint.html) for
the full list. Pass `style = nil` for plain text everywhere.

A style you pass is always used, even when the output isn't a terminal or
`NO_COLOR` is set. Check for those yourself if your program should still
honour them.

For anything a theme can't do, like true colour, write your own `Styler`: a
proc that takes a role and a piece of text, and returns the text to print.
argumint calls it once for each piece of the message, such as an option's
name or a heading. This one colours names orange and makes headings bold:

```nim
import argumint

proc orange(role: StyleRole, text: string): string =
  case role
  of srOption, srCommand: "\e[38;2;255;135;0m" & text & "\e[0m"
  of srHeader: "\e[1m" & text & "\e[0m"
  else: text

let spec = (
  speed: opt("-s, --speed=<kn>", default = 10, help = "Speed in knots"),
  help: help(),
)

spec.parseOrQuit(settings = newSpecSettings(style = orange))
```

`cat -v` shows the escape codes it adds:

```console
$ ./ship --help | cat -v
^[[1mUsage:^[[0m
  ship ^[[38;2;255;135;0m[options]^[[0m
  ship (^[[38;2;255;135;0m-h^[[0m | ^[[38;2;255;135;0m--help^[[0m)

^[[1mOptions:^[[0m
  ^[[38;2;255;135;0m-s^[[0m, ^[[38;2;255;135;0m--speed^[[0m=<kn>  Speed in knots [default: 10]
  ^[[38;2;255;135;0m-h^[[0m, ^[[38;2;255;135;0m--help^[[0m        Display this help message
```

argumint lines up the columns before calling the styler, so what it adds
doesn't throw off the layout. Return `text` unchanged for any role you don't
want to style.

When you catch an error or help from `parse`, its `msg` is always plain text.
Its `styledMsg` holds the coloured form, which is what `parseOrQuit` prints.

### Marking Up Text

In help text, the prolog, the epilog, and a validator's or clamp's
description, wrap text in backticks to colour it as what it looks like:

```nim
import argumint

let spec = (
  speed: opt("-s, --speed=<kn>", default = 10, env = "SHIP_SPEED",
    help = "Speed in `<kn>`; overrides `$SHIP_SPEED`"),
  help: help(),
)

spec.parseOrQuit(epilog = "Ports are listed at `https://example.com/ports`.")
```

- `-x` or `--name` is coloured as an option, and `--name=<value>` as an
  option and its placeholder.
- `<name>` is coloured as a placeholder.
- `$NAME` or `%NAME%` is coloured as an environment variable.
- A URL like `https://...` is coloured as a link.
- Anything else is coloured as a value.

In colour, the backticks are dropped. In plain text they stay, so the text
reads the same either way:

```console
$ ./ship --help
Usage:
  ship [options]
  ship (-h | --help)

Options:
  -s, --speed=<kn>  Speed in `<kn>`; overrides `$SHIP_SPEED` [default: 10; env:
                    SHIP_SPEED]
  -h, --help        Display this help message

Ports are listed at `https://example.com/ports`.
```

Write two backticks for a literal one. A backtick with no partner is left as
it is.

## Your Own Help Layout

A **formatter** writes the whole help message. To write your own,
`import argumint/help` and write a proc that takes a `HelpContext` and
returns the text:

```nim
import std/strutils
import argumint, argumint/help

proc formatShouty(ctx: HelpContext): string =
  var groups: seq[string]
  for name, args in ctx.groups:
    var lines = @[name.toUpperAscii & ":"]
    for arg in args:
      for row in ctx.rows(arg):
        lines.add "  " & ctx.render(row.variants)
        for line in row.text.wrap(ctx.width - 4):
          lines.add "    " & ctx.render(line)
    groups.add lines.join("\n")
  joinSections(
    ctx.render(ctx.prose(ctx.spec.prolog).wrap(ctx.width)),
    "USAGE:\n" & ctx.render(ctx.usage),
    joinSections(groups),
    ctx.render(ctx.prose(ctx.spec.epilog).wrap(ctx.width)))

let spec = (
  name: arg("<name>", help = "Ship to move"),
  speed: opt("-s, --speed=<kn>", default = 10, help = "Speed in knots"),
  help: help(formatter = formatShouty),
)

spec.parseOrQuit(prolog = "Moves a ship to its next port.")
```

```console
$ ./ship --help
Moves a ship to its next port.

USAGE:
  ship [options] <name>
  ship (-h | --help)

ARGUMENTS:
  <name>
    Ship to move

OPTIONS:
  -s, --speed=<kn>
    Speed in knots [default: 10]
  -h, --help
    Display this help message
```

The context gives you the pieces the built-in formatters use:

- `ctx.groups` gives each group's name and the `Arg`s it shows, in order.
- `ctx.rows(arg)` gives an `Arg`'s names and its help text, with the
  brackets added.
- `ctx.prose(text)` re-flows a prolog or epilog, and `wrap` lays it out at a
  width.
- `ctx.usage` gives the usage lines, and `ctx.width` the width to wrap at.
- `ctx.render` turns any of these into a string, in colour when the output
  is.
- `joinSections` joins the parts that aren't empty with a blank line between
  them.

A parse error always shows its usage lines in the standard layout, whatever
the formatter.

## Messages and Versions

`version` and `message` add a flag that prints some text and exits, the way
`--help` does:

```nim
import argumint

const NimblePkgVersion {.strdefine.} = "devel"

let spec = (
  name: arg("<name>", help = "Ship to move"),
  version: version("-V, --version", "ship " & NimblePkgVersion),
  license: message("--license", "MIT License. See LICENSE for details.",
    help = "Show the license"),
  help: help(),
)

spec.parseOrQuit()
echo "Moving ", spec.name
```

```console
$ ./ship --version
ship devel
$ ./ship --license
MIT License. See LICENSE for details.
$ ./ship Titanic
Moving Titanic
```

The user doesn't need to give `<name>` with `--version`, since argumint adds
a usage line for each of these flags.

Nimble sets `NimblePkgVersion` to your package's version when it builds your
program, so `--version` stays in step with your `.nimble` file. A plain
`nim c` gives `devel` unless you pass `-d:NimblePkgVersion=1.2.3`.

`parseOrQuit` prints the text and exits with status 0. `parse` raises a
`MessageError` instead, or a `HelpError` for help, with the text as its
`msg`. See [Error Handling](errors.md).
