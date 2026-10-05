# Custom Types

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

argumint converts values to `string`, `int`, `float`, `bool`, and `char` on
its own. For any other type, you tell it how to read one from the command
line, and the type then works anywhere a built-in one does: as an argument,
an option, or a flag, with defaults, validators, and help.

If your values don't fit one type at all, you can write your own kind of
`Arg` instead. See [Your Own Arg](#your-own-arg).

## A Value Type

A value type needs a `converter` from `string`. Pass the type to
`defineArg`, and argumint uses the converter for every value of that type:

```nim
import std/times
import argumint

converter toDateTime(value: string): DateTime = parse(value, "yyyy-MM-dd")
defineArg(DateTime)

let spec = (
  since: opt("--since=<date>", default = dateTime(2026, mJan, 1),
             help = "Show entries from this date"),
  help: help(),
)

spec.parseOrQuit()
echo "since ", spec.since.format("yyyy-MM-dd")
```

```console
$ ./history --since 2026-03-15
since 2026-03-15
$ ./history --since 15/03/2026
Parsing error:
  - expected DateTime for --since but got "15/03/2026"

Usage:
  history [options]
  history (-h | --help)
```

When the converter raises a `ValueError`, argumint reports it as a parsing
error, with a message of its own in place of the converter's.
`times.parse` raises a `ValueError` for a bad date, so `toDateTime` needs no
checks of its own.

Call `defineArg` once per type, at the top level of a module, where the
converter is in scope, and before anything uses the type. The module that
defines the type is the safest place. Using a type in an `arg` or `opt` before
its `defineArg` call, or with none, is a compile error that names the call to
add. The same goes for a type like `int8` or `range[0..10]`, which converts to
`int` but isn't `int`. A plain alias, like `type Port = int`, needs nothing.

### Without a Default

Without a `default`, an `Arg` holds the type's zero value, the same as a
`var` you never assigned. For `int` that's `0`, but for `DateTime` it's a
value that isn't a real date:

```nim
let spec = (
  until: opt[DateTime]("--until=<date>", help = "Show entries before this date"),
  help: help(),
)

spec.parseOrQuit()
echo spec.until
```

```console
$ ./history
Uninitialized DateTime
```

Give the `Arg` a default, or check `seen` before using the value. See
[Where a Value Came From](specs.md#where-a-value-came-from).

```nim
if spec.until.seen:
  echo "until ", spec.until.format("yyyy-MM-dd")
```

### Validators and Lists

Everything in [Arguments and Options](args-and-options.md) works for your type
too. `args` and `opts` hold a `seq` of it, and a `check` validator tests each
value:

```nim
let spec = (
  dates: opts[DateTime]("--date=<date>",
    validator = checkIt[DateTime](it.year >= 2000, "in 2000 or later"),
    help = "Dates to show"),
  help: help(),
)
```

```console
$ ./history --date 1999-12-31
Validation error:
  - for --date, 1999-12-31T00:00:00-06:00 did not meet condition: in 2000 or later

Usage:
  history [options]
  history (-h | --help)
```

The error shows the value with `DateTime`'s own `$`, which includes the time
and your time zone. See [What a Type Needs](#what-a-type-needs).

## What a Type Needs

Help and error messages show a value with `$`, and argumint compares values
with `==`. Most types have both, but an object's own `$` shows every field by
name, so you may want to write a shorter one:

```nim
import std/strutils
import argumint

type Point = object
  x, y: int

converter toPoint(value: string): Point =
  let parts = value.split(',')
  if parts.len != 2:
    raise newException(ValueError, "expected x,y")
  Point(x: parseInt(parts[0]), y: parseInt(parts[1]))

proc `$`(p: Point): string = $p.x & "," & $p.y

defineArg(Point)

let spec = (
  at: opt("--at=<point>", default = Point(x: 1, y: 1), help = "Where to draw"),
  help: help(),
)

spec.parseOrQuit()
echo "drawing at ", spec.at
```

```console
$ ./draw --at 3,4
drawing at 3,4
$ ./draw --help
Usage:
  draw [options]
  draw (-h | --help)

Options:
  --at=<point>  Where to draw [default: 1,1]
  -h, --help    Display this help message
```

A converter that might raise something other than a `ValueError` should
check first. Without the `len` check, `parts[1]` would raise an `IndexDefect`
for `3`, which stops the program instead of reporting a parsing error.

A type also needs `<=` to use a `range` validator. A type without one, like
`Point`, still works with every other validator.

Help leaves out a default equal to the type's zero value, since that's what
the `Arg` would hold anyway. A default of `Point(x: 0, y: 0)` shows no
`[default: ...]`.

A type marked `{.requiresInit.}`, or one with a field that is, has no zero
value, and can't be a value type. If you need one, comment on
[issue #207](https://github.com/squattingmonk/argumint/issues/207).

## Flags

To use a type for a [flag](flags.md), give `defineArg` a block that applies
an operation. Inside it, `value` is the flag's value, `op` is the operation,
and `arg` is the operation's value:

```nim
import std/times
import argumint

converter toDateTime(value: string): DateTime = parse(value, "yyyy-MM-dd")

defineArg(DateTime):
  case op
  of "=": value = arg
  else: discard

let today = now()

let spec = (
  day: flag(default = today, help = "Day to report on",
    ops = [flagOp("--yesterday", "=", today - 1.days, help = "Yesterday"),
           flagOp("--last-week", "=", today - 1.weeks, help = "A week ago")]),
  help: help(),
)

spec.parseOrQuit()
echo spec.day.format("ddd d MMM")
```

```console
$ ./report
Sat 3 Oct
$ ./report --yesterday
Fri 2 Oct
```

Each `of` branch names an operation the type supports, and argumint rejects
any other when it builds the spec. Here, only `=` works, and with no `""`
branch every name needs `ops`: `flag[DateTime]("--day")` is rejected too. A
flag's operation value has the flag's own type, so a `DateTime` flag can't
add a `Duration`.

The block replaces a separate `defineArg(DateTime)`, so the type also works
for an `arg` or `opt`. The `ops` string form uses your converter, so
`ops = "--new-year=2026-01-01"` works too.

`defineFlag` does the same, and also takes a description of the `""`
operation, which is what a flag's own names do. For an example, and for
`defineSetFlag`, which makes a flag of a `set` of an enum, see
[Your Own Flag Types](flags.md#your-own-flag-types).

## Your Own Arg

A value type gives each match one value. When that doesn't fit, you can
write your own kind of `Arg`, starting from `Arg` itself. The `ValueArg` and
`FlagArg` that `arg`, `opt`, and `flag` build keep their fields private, so
a type built on either couldn't reach its own value. This one collects `-D name=value` options into
a table:

```nim
import std/[strutils, tables]
import argumint

type VarsArg = ref object of Arg
  vars: OrderedTable[string, string]

proc vars(variants: string, help = ""): VarsArg =
  VarsArg(kind: Optional, variants: variants.split(", "), help: help,
          group: "Options")

method accept(self: VarsArg, c: Contribution, how: Arbitration) =
  let parts = c.value.split('=', maxsplit = 1)
  if parts.len != 2 or parts[0].len == 0:
    raise newException(ParseError,
      "expected name=value for " & self.subject(c) & " but got " & c.value)
  if how == arReplace:
    self.clear
  self.vars[parts[0]] = parts[1]

method clear(self: VarsArg) =
  procCall clear(Arg(self))
  self.vars.clear

let spec = (
  defines: vars("-D, --define=<var>", help = "Set a variable (name=value)"),
  help: help(),
)

spec.parseOrQuit()
for name, value in spec.defines.vars:
  echo name, " = ", value
```

```console
$ ./build -D name=site -D port=8080
name = site
port = 8080
$ ./build -D port
Parsing error:
  - expected name=value for -D but got port

Usage:
  build [options]
  build (-h | --help)
```

The constructor sets the fields every `Arg` has:

- `kind` is `Positional` for an argument and `Optional` for an option.
- `variants` holds its names, written the same way as for `arg` or `opt`.
- `help` describes it in help.
- `group` is the heading it appears under in help. `opt` uses `"Options"`,
  and `arg` uses `"Arguments"`.

`accept` stores one value. `c.value` is the text, and `self.subject(c)`
names the `Arg` in an error the way argumint does, including where the value
came from. `how` is `arReplace` when the value should replace what's there
rather than add to it, for example when the command line overrides an
environment variable. Check the value first, then call `clear` on
`arReplace`, so a bad value leaves the `Arg` as it was.

`clear` empties the value. It must call the base `clear` too, which resets
`seen`.

### Optional Methods

Override any of these to do more:

- `envSource` and `configKey` read the value from an
  [environment variable or a config file](precedence.md). Return
  `toEnvSource("NAME")` or `configKey("server", "port")`.
- `defaultStr` is shown in help as `[default: ...]`.
- `completions` lists values for [shell completion](completion.md).
