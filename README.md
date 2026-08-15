# argumint: a fresh command-line argument parsing library

A Nim command-line argument parsing library where a [docopt](http://docopt.org/)-style
usage string is compiled into a finite state machine (FSM) that drives actual
parsing.

Most argument parsers make you register flags imperatively and then bolt on
extra logic for anything that doesn't fit that flat model: mutually exclusive
options, optional-but-positional arguments, repeated values. argumint inverts
this — you declare a usage string like docopt's, and it's compiled once into
an FSM that *is* the grammar. Backtracking through that FSM is what decides
whether a given command line is valid, so patterns like `[-r] <src>... <dest>`
(not possible in docopt) or `<x> <y> [--moored|--drifting]` just work, without
hand-written validation code.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [Features](#features)
- [Detailed Documentation](#detailed-documentation)
  - [Basics](#basics)
  - [Usage Strings, Grammar, and the FSM](#usage-strings-grammar-and-the-fsm)
    - [The `[options]` Catch-all](#the-options-catch-all)
    - [The End-of-Options Marker](#the-end-of-options-marker)
    - [Backtracking, not left-to-right scanning](#backtracking-not-left-to-right-scanning)
    - [Auto-generated usage strings](#auto-generated-usage-strings)
    - [Visualizing the compiled FSM](#visualizing-the-compiled-fsm)
  - [Declaring Arguments and Options](#declaring-arguments-and-options)
    - [Validating Values](#validating-values)
  - [Declaring Flags](#declaring-flags)
    - [Variant Exclusivity and Composition Order](#variant-exclusivity-and-composition-order)
    - [Custom Flag Types](#custom-flag-types)
    - [Clamping Flag Values](#clamping-flag-values)
  - [Value Precedence](#value-precedence)
    - [Env Vars](#env-vars)
    - [Config Sources](#config-sources)
  - [Commands](#commands)
    - [A Command's Own Usage Line](#a-commands-own-usage-line)
    - [Before, Action, and After Hooks](#before-action-and-after-hooks)
    - [`HookInfo`](#hookinfo)
    - [Passing Extra Context to Hooks](#passing-extra-context-to-hooks)
  - [Custom Messages](#custom-messages-message-and-version)
  - [Displaying Help](#displaying-help-help)
  - [Shell Completion](#shell-completion)
  - [Parsing More Than Once](#parsing-more-than-once)
  - [Error Handling](#error-handling)
    - [Strict Option Checking](#strict-option-checking)
- [Examples](#examples)
- [Learning more](#learning-more)
- [Prior Art and Alternatives](#prior-art-and-alternatives)
  - [Why argumint over docopt.nim?](#why-argumint-over-docoptnim)
- [License](#license)

## Requirements

- Nim >= 2.2.4

## Installation

argumint is available on [Nimble's package
list](https://github.com/nim-lang/packages):

```shell
nimble install argumint
```

If you'd rather use [Atlas](https://github.com/nim-lang/atlas) for dependency
management:

```shell
atlas use https://github.com/squattingmonk/argumint
```

## Quickstart

```nim
import std/strformat
import argumint

let
  spec = (
    src: args("<src>", help = "The source file(s) to copy"),
    dest: arg("<dest>", help = "The destination to copy to"),
    recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
    help: help()
  )

spec.parseOrQuit(usage = "[-r] <src>... <dest>", prolog = "Copy files around")
for file in spec.src:
  echo fmt"Copying {file} to {spec.dest} (recursive: {spec.recursive})"
```

```shell
$ ./cp -r foo.txt bar.txt dest/
Copying foo.txt to dest/ (recursive: true)
Copying bar.txt to dest/ (recursive: true)
```

A spec is a plain Nim tuple: each field is built with `arg`/`args`, `opt`/
`opts`, or `flag`, and the whole tuple is handed to `parse`/`parseOrQuit`
alongside a usage string. Parsed values come back on the same tuple you
declared, so `spec.dest` and `spec.recursive` above are plain, statically
typed fields — no stringly-typed lookup by flag name.

## Features

- **[Usage strings compiled to a real FSM](#usage-strings-grammar-and-the-fsm)**
  — a docopt-style usage string is compiled once into a finite state
  machine, and that FSM is what actually parses the command line, so
  patterns like `[-r] <src>... <dest>` or mutually exclusive
  `(--moored | --drifting)` just work — no hand-written validation code,
  and no separate imperative registration step to keep in sync.
- **Familiar CLI syntax** — long (`--option`) and short (`-o`) options, short
  option folding (`-vx` for `-v -x`), and every common way to attach a value:
  `-f File`, `-fFile`, `-f=File`, `-f:File` (and the long-form equivalents
  `--file File`, `--file=File`, `--file:File`).
- Fully type-safe. Common value types (`string`, `int`, `float`, `bool` and
  `char`) are supported out of the box, and it's easy to add support for more.
- **[Positional args, options](#declaring-arguments-and-options)**,
  **[flags](#declaring-flags)**, and **[commands](#commands)** — declared
  uniformly as fields of one spec tuple, freely combinable in a usage string.
- **[Nested subcommands](#commands)** — a `command()` field owns its own
  nested spec, so a CLI like `myapp ship move <x> <y>` can be built out of
  independently testable pieces. See `examples/naval_fate.nim` for a full
  multi-level example (docopt's canonical Naval Fate demo).
- **[Flag operations](#declaring-flags)** — a flag isn't just a boolean;
  variants can set, increment, decrement, or reset a shared value (`-v,
  --verbose, --quiet=0`). See `examples/verbosity.nim`.
- **[Validators](#validating-values)** — attach choice, range, or
  arbitrary-predicate constraints to an arg, composable with `all()`/`any()`,
  with generated help text and clear `ValidationError`s.
- **[Env var fallback](#env-vars)** — an option or flag can fall back to an
  environment variable (including multi-value, delimiter-aware fallback)
  when not given on the command line.
- **[Config Source fallback](#config-sources)** — an option or flag can
  also fall back to a registered, read-only Config Source (built-in
  INI/JSON adapters, or your own) below env vars and above the coded
  default. See `examples/config_bootstrap.nim`.
- **[Auto-generated, wrapped help](#displaying-help-help)** — usage lines
  and per-arg help text are generated from the spec and wrapped to a
  configurable width; `[default: ...]` and validator constraints are
  folded into the help text automatically.
- **[Shell completion](#shell-completion)** — dynamic, FSM-driven
  `bash`/`zsh`/`fish` completion generated from the same spec that drives
  parsing, so completions can never drift out of sync with what actually
  parses. `fish` and `zsh` also show each candidate's help text inline as
  you complete it; `bash` has no equivalent to render one into. See
  `examples/completion.nim`.

## Detailed Documentation

### Basics

argumint uses a tuple (optionally nested) to represent the arguments, options,
and commands available to the parser — this is called the **spec**. Each member of
the spec must be an `Arg` or another spec tuple. The spec tuple is then passed
to `parse` or `parseOrQuit` along with an optional usage string. If the parse is
successful, the parsed values are assigned to their respective `Arg`s. You can
then get the values with implicit conversion from the spec tuple itself.

```nim
import std/strformat
import argumint

let
  spec = (
    name: arg("<name>", help = "The name to call you"),
    times: opt("-t, --times=<t>", default = 1, help = "The number of times to say hello")
  )

spec.parseOrQuit(usage = "<name> [--times=<t>]")
for _ in 1..spec.times:
  echo fmt"Hello, {spec.name}!"
```

```console
$ ./hello "Michael"
Hello, Michael!

$ ./hello "Michael" --times 2
Hello, Michael!
Hello, Michael!
```

`Arg`s come in several flavors, each with distinct **variants** — names by which
the `Arg` may be indexed. Each `Arg`'s constructor can accept a comma-separated
list of variants (e.g., `opt("-v, --verbosity")`). These variants are how the
`Arg` is referenced in a usage string.

- **positional arguments**, often just called arguments, have their value known
  based on their position in the usage string. A positional argument's variants
  are either uppercase (`VALUE`) or surrounded by angle brackets (`<value>`).
- **optional arguments**, often just called options, have a key-value syntax.
  The key may take either a short form (`-o`) or a long form (`--option`). While
  a value placeholder is not required to be present in the variant, one can be
  included for clarity in help messages and usage strings. A value placeholder
  takes the same form as a positional argument. To prevent ambiguity between
  value placeholders and positional arguments, value placeholders must be
  separated from the option by `=` or `:` (e.g., `-o=<value>` or
  `--option:<value>`).
- **flags** are a special form of optional argument that do *not* take a value;
  instead, their value is set based on their seen variant (e.g., `-y`/`-n` or
  `--yes`/`--no`). They take the same form as an optional argument but should
  not be given a value placeholder.
- **commands** are words that don't look like a positional argument or optional
  argument (e.g., `ship` or `move`). Commands have their own sub-spec including
  their own arguments, options, and subcommands.

`parse`/`parseOrQuit` build the spec tuple into a `Spec` for you and throw it
away. Call `newSpec` instead when you want to hold onto it — to build your CLI
somewhere other than where you parse it, or to reach it later from a hook:

```nim
proc buildCli(): Spec =
  newSpec((
    name: arg("<name>", help = "The name to call you"),
    help: help()),
    usage = "<name>")

let spec = buildCli()
spec.parseOrQuit()
```

A `Spec` is an opaque handle: you can name it, pass it around, and hand it to
`parse`/`parseOrQuit`/`dot`/`completionScript`/`completeArgs`, but its
internals belong to argumint. The exception is `spec.settings`, the
`newSpecSettings` value shared by reference with every nested command's spec,
which is meant to be read and mutated — see
[Value Precedence](#value-precedence).

### Usage Strings, Grammar, and the FSM

This is the thing that makes argumint different from other argument
parsers: the **usage string** isn't just a docstring shown to the user.
It's compiled, once, into a finite state machine (FSM), and that FSM is
what actually walks the real command line at parse time. There's no
separate imperative validation layer bolted on beside it — whatever the
usage string says is legal *is* what gets accepted, and nothing else.

A usage string is one or more **Usage Lines**, separated by newlines, each
one an independent, complete pattern — the whole string means "the command
line must match this line, *or* this one, *or* this one." Within a single
Usage Line, these tokens combine into a grammar:

| Syntax            | Meaning                                                                                     |
| ---               | ---                                                                                         |
| `command`         | A literal word naming a [command](#commands) (e.g. `ship`).                                 |
| `<name>` / `NAME` | A [positional argument](#declaring-arguments-and-options).                                  |
| `-o` / `--option` | An [option or flag](#declaring-arguments-and-options), by any one of its declared variants. |
| `-abc`            | A cluster of short options (sugar for `-a -b -c`)                                           |
| `[...]`           | Everything inside is optional.                                                              |
| `(...)`           | Groups tokens, usually so `\|` or `...` applies to the group.                               |
| `a \| b`          | Exactly one of `a` or `b` — mutually exclusive alternatives.                                |
| `...`             | The atom before it (an arg, option, or group) can repeat.                                   |
| `[options]`       | Catch-all for any option/flag not named elsewhere on this line.                             |
| `--`              | End-of-options marker: everything after it is a positional value.                           |

Note: unlike docopt, atoms inside `[]` are not independently optional (e.g.,
`[-a -b -c]` is not equivalent to `[-a] [-b] [-c]`).

Every name in a usage string is checked against the `Arg`s you've actually
declared, once, at spec construction — a typo like `--verbos` when you
declared `--verbose` is a `SpecDefect` raised before your program ever
runs, not a bug that surfaces later from a mismatch nobody caught:

```console
$ ./demo
Error constructing spec: Error at (1:1): Undeclared option: --verbos
[--verbos]
 ^
```

This is also why a usage line never mentions the binary's own name or its
own (sub)command's name — neither one is a declared `Arg`, so writing it
would be exactly the same kind of "undeclared" mistake:

```nim
let spec = (x: arg("<x>"), y: arg("<y>"), help: help())
spec.parseOrQuit(usage = "myapp <x> <y>")  # WRONG: "myapp" isn't declared
```

```console
Error constructing spec: Error at (1:0): Undeclared command: myapp
myapp <x> <y>
^
```

Dropping `myapp` fixes it — and the generated help still shows it, because
`parse*`/`parseOrQuit*`/`command()` prepend the binary's (or, for a nested
command, that command's own) name to every line of the `Usage:` block
they display, entirely separately from what you write in `usage`:

```console
$ ./myapp --help
Usage:
  myapp <x> <y>
  myapp (-h | --help)
```

None of this is enforced by hand-written `if`/`case` code — every one of
these constructs becomes a specific piece of the compiled FSM (a
`Matcher`), and matching a real command line against it is just walking
that graph with backtracking. That's what lets patterns docopt itself
can't express work here without any special-casing:

```nim
usage = "[-r] <src>... <dest>"
```

is *optional* flag, *repeated* positional, *required* positional, in that
order. Mutually exclusive alternatives compose the same way:

```nim
usage = "<x> <y> [--moored | --drifting]"
```

accepts two required positionals followed by *at most one* of
`--moored`/`--drifting`. Passing both in the same invocation is a
`ParseError`, not something you'd need to check for by hand:

```console
$ ./mine 1 2 --moored --drifting
Parsing error:
  - unexpected flag: --moored

Usage:
  mine <x> <y> [--moored | --drifting]
  mine (-h | --help)
```

Separate Usage Lines let you express invocation shapes that don't share a
common optional/required structure at all — not just alternatives within
one line:

```nim
let spec = (
  src: arg("<src>", default = ""),
  dest: arg("<dest>", default = ""),
  list: flag("--list", help = "List existing backups instead"),
  help: help()
)

spec.parseOrQuit(usage = "<src> <dest>\n--list")
```

`<src> <dest>` and `--list` are two entirely independent Usage Lines here,
not one line with everything optional — so a bare invocation (neither
positionals nor `--list`) and a mixed one (`--list` plus a stray
positional) are both rejected, rather than silently accepted the way an
all-optional single line (`[<src> <dest>] [--list]`) would allow either
one:

```console
$ ./backup a.txt dest/
Backing up a.txt to dest/

$ ./backup --list
Listing backups...

$ ./backup
Parsing error:
  - missing option: (--list | -h)
  - missing argument: <src>

Usage:
  backup <src> <dest>
  backup --list
  backup (-h | --help)
```

One thing this *doesn't* mean: that a command word and its subcommand's own
grammar can be written on the same Usage Line. `mine (set | remove) <x> <y>
[--moored | --drifting]` looks tempting but isn't legal — a matched Command
consumes every remaining token, so nothing else on that line could ever be
reached. See [A Command's Own Usage
Line](#a-commands-own-usage-line) for why, and how a Command's own nested
spec compiles into its own FSM that gets spliced into the parent's.

#### The `[options]` Catch-all

`[options]` matches any declared option or flag *not explicitly named
elsewhere on that same Usage Line* — mentioning one explicitly only
excludes it from the catch-all on the line it's mentioned on; a different
Usage Line's own `[options]` still covers it. Whatever ends up reachable
only through the catch-all can be matched an arbitrary number of times,
with no `...` needed — unlike an explicitly-named option or flag, which
can only match once per line unless you add `...` yourself:

```nim
import std/strformat
import argumint

let spec = (
  name: opt("--name=<n>", default = ""),
  verbosity: flag[int](ops = [flagOp("--verbose", "+=", 1)], default = 0),
  help: help()
)

spec.parseOrQuit(usage = "--name=<n> [options]")
echo fmt"name={spec.name} verbosity={spec.verbosity}"
```

`--name` is explicitly named on this line, so it can appear at most once;
`--verbose` isn't, so it's covered by `[options]` and can repeat freely:

```console
$ ./myapp --name=a --verbose --verbose --verbose
name=a verbosity=3

$ ./myapp --name=a --name=b
Parsing error:
  - missing option: --verbose
  - unexpected option: --name=b

Usage:
  myapp --name=<n> [options]
  myapp (-h | --help)
```

#### The End-of-Options Marker

A literal `--` can be typed anywhere on the actual command line to force
every token after it to be treated as a positional value, even one that's
option- or command-shaped — this works unconditionally, whether or not any
Usage Line declares `--` at all:

```nim
let spec = (files: args("<file>"), verbose: flag("-v, --verbose"), help: help())
spec.parseOrQuit(usage = "<file>... [options]")
```

```console
$ ./myapp a.txt -- --verbose -v.txt
files=@["a.txt", "--verbose", "-v.txt"] verbose=false
```

`--verbose` and `-v.txt` land in `files` as literal text instead of being
parsed as a flag/option, because the typed `--` came first.

Declaring `--` *in a Usage Line* is a different, related thing: once a
matched path reaches that position, the marker counts as seen whether or
not the user actually typed a literal `--` there — it's a permanent
grammar-level switch to positional-only, not a token that has to show up
on the command line:

```nim
let spec2 = (a: arg("<a>"), rest: args("<b>"))
spec2.parseOrQuit(usage = "<a> -- <b>...")
```

```console
$ ./myapp2 first --flag-looking second
a=first rest=@["--flag-looking", "second"]

$ ./myapp2 first -- --flag-looking second
a=first rest=@["--flag-looking", "second"]
```

Both invocations give identical results — the second `--` is redundant
once the Usage Line itself already declares the marker at that position.
Only a Positional Argument may follow `--` within the same Usage Line — an
Option, Flag, `[options]`, Command, or a second `--` can never be reached
there, so each is rejected at spec-construction time:

```nim
spec2.parseOrQuit(usage = "<a> -- <b>... --")
```

```console
Error constructing spec: Error at (1:14): Only a Positional Argument may follow
  the End-of-Options Marker ('--') earlier in the same Usage Line -- an Option,
  Flag, [options], Command, or a second '--' can never be reached there, since a
  matched Marker forces every later token to be treated as a positional value
<a> -- <b>... --
              ^
```

#### Backtracking, not left-to-right scanning

Because matching walks the compiled FSM rather than scanning the raw
argument array once, left-to-right, an option or flag doesn't have to
appear in any particular position relative to repeated positionals — it
only has to appear *somewhere* the grammar allows it. Given:

```nim
import std/strformat
import argumint

let spec = (
  files: args("<file>", help = "Files to process"),
  verbose: flag("-v, --verbose", help = "Be verbose"),
  help: help()
)

spec.parseOrQuit(usage = "<file>... [options]")
echo fmt"files={spec.files} verbose={spec.verbose}"
```

all three of these are accepted identically:

```console
$ ./myapp a.txt --verbose b.txt
files=@["a.txt", "b.txt"] verbose=true

$ ./myapp --verbose a.txt b.txt
files=@["a.txt", "b.txt"] verbose=true

$ ./myapp a.txt b.txt --verbose
files=@["a.txt", "b.txt"] verbose=true
```

`--verbose` is recognized and pulled out of the stream wherever it shows
up, instead of being greedily swallowed as a positional value. This falls
out of how the FSM's transitions are ordered (options/flags/commands are
always tried before a plain positional at the same position) — it's not a
special rule for `[options]` specifically.

#### Auto-generated usage strings

`usage` is optional — and even when you do supply one, it's checked
against every `Arg` you've declared, not just taken as the whole truth:
anything not reachable anywhere in it gets a line appended automatically.
This is why the [Quickstart](#quickstart) and the `[-r] <src>... <dest>`
example [above](#visualizing-the-compiled-fsm) don't need to spell out
`-h`/`--help` themselves. The fill-in rule differs by kind:

- **Positional args** are all-or-nothing: they're only auto-appended (as
  one joined `<a> <b>` line, in declaration order) when *none* of them are
  reachable yet. If your `usage` already mentions even one, the rest are
  left alone rather than guessed at.
- **Commands** left unreachable are joined into a single `(cmd1 | cmd2)`
  alternation line, so a shared `[options]` prefix isn't repeated once per
  command.
- **Message args** (`help()`, `version()`, `message()`) are filled in
  individually — each missing one gets its own line, since they're
  independently optional and never carry a `[options]` prefix.
- **Options and flags** never get a line of their own; `[options]` just
  rides along as a prefix on whichever line above got appended. If
  nothing else needed appending but an option is still unreachable, a
  standalone `[options]` line is added as a fallback.

#### Visualizing the compiled FSM

Since the usage string really does compile into a graph, you can look at
that graph directly — useful when a usage string isn't matching the way
you expect. `spec.dot(usage = ...)` renders it as
[Graphviz](https://graphviz.org/) dot source (`scripts/dot2png.sh` in this
repo turns that into a viewable PNG):

```nim
import argumint

let spec = (
  src: args("<src>", help = "Source file(s)"),
  dest: arg("<dest>", help = "Destination"),
  recursive: flag("-r, --recursive"),
  help: help()
)

echo spec.dot(usage = "[-r] <src>... <dest>")
```

```console
digraph G {
    rankdir=LR

    S1 [label="S1"]
    S1 -> S2 [label="Opt(-r)"]
    S1 -> S5 [label="Opt(-h)"]
    S1 -> S3 [label="Arg(<src>)"]

    S2 [label="S2"]
    S2 -> S3 [label="Arg(<src>)"]

    S3 [label="S3"]
    S3 -> S4 [label="Arg(<dest>)"]
    S3 -> S3 [label="Arg(<src>)"]

    S4 [peripheries=2] [label="S4"]

    S5 [peripheries=2] [label="S5"]
}
```

Feeding that into `scripts/dot2png.sh` gives:

![FSM compiled from `[-r] <src>... <dest>`](docs/images/cp-usage-fsm.png)

Reading this: from the start state `S1`, `-r` moves to `S2` (skippable, so
`S1` also reaches `S3` directly — that's the `[-r]`), `<src>` can loop on
`S3` any number of times (the `...`), and `<dest>` finally reaches the
terminal state `S4`. `S1 -> S5` is `-h`/`--help`, auto-filled in on its own
line since it wasn't mentioned in the `usage` given here.

For a bigger, real-world example, here's the full FSM compiled from
`examples/naval_fate.nim`'s entire spec — every level of nesting (`ship`/
`mine` and each of their own subcommands) shows up as one connected graph,
since a Command's nested FSM is spliced directly into its parent's (see
[A Command's Own Usage Line](#a-commands-own-usage-line)):
[naval-fate-fsm.png](docs/images/naval-fate-fsm.png) (not embedded here —
it's a big graph).

### Declaring Arguments and Options

Every field in a spec tuple is built with a constructor: `arg[T]()` for
positional arguments or `opt[T]()` for options, where `T` is the value type for
the argument. `T` and `default` can each be given explicitly, or left for
argumint to infer:

- explicit `[T]`, no `default` — falls back to `default(T)` (e.g. `0`, `0.0`,
  `false`)
- no `[T]`, explicit `default` — `T` is inferred from the default value's type
- neither — `T` falls back to `string`, `default` to `""`

The implicit forms are more friendly, so they are preferred in the examples.

```nim
let
  spec = (
    foo: arg("<foo>"),              # T implicitly string, default ""
    bar: arg("<bar>", default = 3), # T implicitly int, default 3
    baz: opt[int]("--baz=<n>"),     # T explicitly int, default 0
    qux: opt[int]("--qux=<n>", 5)   # T explicitly int, default 5
  )
```

**`arg` and `opt` can each capture a single value.** If the argument or option
is matched more than once (e.g., usage string is `<name>...`), only the last
value seen is kept. `args[T]()` and `opts[T]()` are their **multi-value
counterparts**: instead of a plain `T`, their stored value is a `seq[T]`,
collecting every value matched. `T` and `default` follow the same rules as
`arg[T]()`/`opt[T]()`, with one difference — `T` can't be inferred from a bare
`@[]`, so an explicit `default` needs at least one element:

- explicit `[T]`, no `default` — falls back to `newSeq[T]()` (`@[]`)
- no `[T]`, explicit `default` (non-empty) — `T` is inferred from the
  default's element type
- neither — `T` falls back to `string`, `default` to `@[]`

```nim
let
  spec = (
    foo: args("<foo>"),                    # T implicitly string, default @[]
    bar: opts[int]("--bar=<n>"),           # T explicitly int, default @[]
    baz: opts("--baz=<n>", default = @[1]) # T implicitly int, default @[1]
  )

spec.parseOrQuit(
  usage = "<foo>... [--bar=<n>]... [--baz=<n>]...",
  args = @["a.txt", "b.txt", "--bar", "3", "--bar", "4", "--baz", "5"])
assert spec.foo == @["a.txt", "b.txt"]
assert spec.bar == @[3, 4]
assert spec.baz == @[5]
```

The default value of `arg[T]()`/`args[T]()`/`opt[T]()`/`opts[T]()` fall back to
`default` for their value if the `Arg` is not seen during parsing. `opt[T]()`
and `opts[T]()` can also fall back to an environment variable via `env` or a
config file via `configKey` if the user doesn't specify a value on the
command-line. See [Value Precedence](#value-precedence) below.

#### Validating Values

`arg`/`opt`/`args`/`opts` each take an optional `validator: Validator[T]`
(`argumint/validators`), checked against every value the user actually
supplies — never against a coded `default`, so an `Arg` the user never
touches is exempt (see
`docs/adr/0008-validators-dont-run-against-defaults.md`). A failing value
raises `ValidationError` (contrast `flag`'s `clamp`, which never raises —
see below).

- `choice(values)` — must be one of `values`
- `range(bounds)` — must fall within `bounds`
- `check(pred)` / `checkIt(pred)` — must satisfy an arbitrary predicate
  (`checkIt` lets you write the predicate inline, using `it` for the value)
- `unique()` — for `args`/`opts`, must not repeat a value already matched
  for the same `Arg`
- `all(...)` / `any(...)` — combine several validators with AND/OR
  semantics, nesting freely

`choice`/`range` infer `T` from their arguments, and `all`/`any` infer it
from their child validators; `check`/`checkIt`/`checkSeen`/`checkSeenIt`/
`unique` always need an explicit `[T]` (e.g. `unique[string]()`), no matter
how `T` is determined elsewhere in the same `arg`/`opt`/`args`/`opts` call.

```nim
let spec = (
  port: opt[int]("--port=<n>", default = 8080, validator = range(1..65535)),
  env: opt("--env=<name>", default = "dev",
    validator = choice(["dev", "staging", "prod"])),
  tags: opts("--tag=<t>", validator = unique[string]()),
  even: opt[int]("--even=<n>", default = 0,
    validator = check[int](proc (x: int): bool = x mod 2 == 0, "must be even")),
  word: arg("<word>",
    validator = checkIt[string](it.len <= 10, "must be at most 10 characters"))
)
```

Passing `--port=0` or `--env=test` above raises a `ValidationError` before
the value is ever stored; passing `--tag=a --tag=a` raises on the second
`a`; `--even=3` raises via `check`; a `<word>` longer than 10 characters
raises via `checkIt`.

Every validator also folds its constraint into the auto-generated help text
(e.g. `[choices: dev, staging, prod]`), so users see what's accepted without
needing `--help` to fail first.

### Declaring Flags

`flag[T]()` builds a flag: an optional argument that never takes a value from
the command line, changing its stored value instead based on which variant was
seen (e.g. `-v`/`--verbose` increments, `--quiet` resets — see
`examples/verbosity.nim`). `T` and `default` follow the same rules as
`arg[T]()`/`opt[T]()`, except the implicit fallback is `bool` instead of
`string`, since a plain on/off flag is by far the most common case:

- explicit `[T]`, no `default` — falls back to `default(T)` (e.g. `0`, `0.0`,
  `false`)
- no `[T]`, explicit `default` — `T` is inferred from the default value's type
- neither — `T` falls back to `bool`, `default` to `false`

```nim
let
  spec = (
    foo: flag("--foo"),                  # T implicitly bool, default false
    bar: flag("--bar", default = 3),     # T implicitly int, default 3
    baz: flag[int]("--baz"),             # T explicitly int, default 0
    qux: flag[int]("--qux", default = 5) # T explicitly int, default 5
  )
```

Beyond the type-specific implicit behavior above (`bool` toggles, `int`
increments by 1), a flag can declare **explicit Flag Operations** via
`flagOp`, passed to `ops`: each names its own spelling(s), an operation,
and a value, deciding how seeing that variant changes the flag's stored
value:

- `"="` — set the value directly
- `"+="` / `"-="` — add or subtract the value (`int`/`float64` only)

```nim
let spec = (
  verbosity: flag[int](
    "-v, --verbose",
    ops = [
      flagOp("--quiet", "=", 0),
      flagOp("--boost", "+=", 5),
    ],
    default = 0
  )
)
```

declares four variants sharing one value: `-v`/`--verbose` increment by 1
(the implicit blank-op behavior for `int`), `--quiet` resets to `0`, and
`--boost` jumps by 5 — see `examples/verbosity.nim` for the full runnable
version, including `clamp` to pin the result to a range.

Each `flagOp`'s `op`/`value` are spec metadata, decided when you write the
spec — they're never something the user types, and they never appear in
the usage string. Only the bare flag names do, e.g. `[-v | --verbose |
--quiet | --boost]...`.

When every explicit Variant's value has a natural string spelling (the
common case — no custom type, no multi-spelling group), `ops` also accepts
a plain comma-separated string instead of an array of `flagOp` calls, as
convenience sugar for exactly the same thing:

```nim
let spec = (
  verbosity: flag("-v, --verbose", default = 0, ops = "--quiet=0, --boost+=5, --dampen-=2")
)
```

is equivalent to the array form above. Each entry is `<flag><op><value>`,
becoming its own single-spelling group — a multi-spelling explicit group,
or a value with no string spelling (e.g. a multi-element `set[E]`), still
needs the array form directly. See
`docs/adr/0028-flag-ops-string-convenience.md`.

#### Variant Exclusivity and Composition Order

Variants declared together — either in `flag`'s own `variants` string, or
together in one `flagOp` call — are *aliases*, and are treated as
interchangeable. When a flag's variant is mentioned in a usage string, any
alias of that variant can be used to satisfy that position within the
grammar. Since each alias indexes the same flag and Flag Operation, you
don't need to reference all of them within the usage string (i.e., either
`-v` or `--verbose` will do) — though you may choose to do so for clarity
to the user. Variants declared in *different* `flagOp` calls are never
aliases of each other, even if their op/value happen to match, so they
cannot satisfy each others' positions in the usage string grammar (e.g.
`--quiet` cannot substitute for `--verbose`).

```nim
let spec = (direction: flag[int](ops = [
  flagOp("--up", "=", 1), flagOp("--down", "=", -1),
  flagOp("--left", "=", 2), flagOp("--right", "=", -2),
]))
spec.parseOrQuit(usage = "(--up | --down) (--left | --right)")
```

`--up --down` is a `ParseError` here: `--up` satisfies `(--up | --down)`'s
position, but `--down` isn't an alias of `--left` or `--right`, so it is
rejected as an unexpected option.

Note that since flags (like options) have order-independence, `--up --left` and
`--left --up` can both satisfy the above usage line. A flag's matched variants
always compose in the order they were actually typed on the command line — not
the order the usage string declares them in. This matters once operations stop
being commutative (see [Clamping Flag Values](#clamping-flag-values) below):
given `ops = [flagOp("-u", "+=", 5), flagOp("-d", "-=", 2)]` clamped to
`0..10`, `-u -d` and `-d -u` are both valid against `usage = "-u -d"`, but
land on different final values, since each composes strictly left-to-right
in typed order. For the full mechanics, see
`docs/adr/0026-flag-op-alias-exclusivity.md`.

#### Custom Flag Types

`bool`/`int`/`float64`/`char`/`string` work as `flag[T]` out of the box, but
any type can — argumint needs two things from you to make it work:

- a `converter` from `string` to `T` — `defineFlag` also wires up
  `arg[T]`/`opt[T]` support for the same type (shared machinery), which
  parses raw command-line strings, even though a `flagOp`'s own `value: T`
  is always a real, already-typed Nim value and never goes through this
  converter itself
- a `defineFlag(T, blankDesc): case op of ...` block declaring which
  operations `T` supports and what each one does to `value`

```nim
import std/strutils

type LogLevel = enum
  debug, info, warn, error

converter toLogLevel(value: string): LogLevel = parseEnum[LogLevel](value)

defineFlag(LogLevel, "Bump up one level"):
  case op
  of "": value = LogLevel((ord(value) + 1) mod (ord(high(LogLevel)) + 1))
  of "=": value = arg
  else: raise newException(SpecDefect, "log level flags only support = operations")

let spec = (
  level: flag[LogLevel](
    "-v, --verbose",
    ops = [
      flagOp("--debug", "=", debug),
      flagOp("--warn", "=", warn),
      flagOp("--error", "=", error),
    ],
    default = info, help = "Set the log level"
  )
)
```

Here `-v`/`--verbose` share the blank op (bump up a level each time seen),
while `--debug`/`--warn`/`--error` each set the level directly via their
own `flagOp`. See `docs/architecture.md`'s "Flags" section for the full
mechanism, including `defineArg`, which registers a type for
`arg`/`opt`/`args`/`opts` the same way `defineFlag` does for `flag`.

`set[E]` for any enum `E` is common enough to have a ready-made helper,
`defineSetFlag(E)`, instead of writing your own `case op` block — it wires up
`=` (set), `+=` (include/union), `-=` (exclude/difference), and `*=`
(intersect) for you:

```nim
type Color = enum
  red, green, blue

defineSetFlag(Color)

const warmColors = {red, green}

let spec = (
  palette: flag[set[Color]](
    ops = [
      flagOp("--red", "=", {red}),
      flagOp("--green", "=", {green}),
      flagOp("--blue", "=", {blue}),
      flagOp("--warm", "=", warmColors),
    ],
    default = {},
    help = "Select colors"
  )
)
```

`--red`/`--green`/`--blue` each set a single element; `--warm` sets *two*
at once, `{red, green}` — since a `flagOp`'s `value` is always a real,
already-typed `T`, there's no string-spelling limitation to work around:
any value expressible in Nim, however it's built, can be passed directly.

#### Clamping Flag Values

A flag's `clamp` param (`argumint/flagclamp`) silently adjusts its value after
every Flag Operation. Unlike a `Validator` (see above), which raises
`ValidationError` when a value doesn't qualify, `clamp` never raises — it just
corrects the value instead:

- `clamp(bounds: Slice[T])` pins the value to `bounds`, e.g. `clamp(0..10)`
- `adjust(fn: T -> T)` runs an arbitrary function instead, for a `T` with no
  natural ordering (e.g. `set[E]`)

```nim
import std/os

defineSetFlag(FilePermission)

let spec = (
  verbosity: flag[int](
    "-v, --verbose",
    ops = [
      flagOp("--quiet", "=", 0),
      flagOp("--boost", "+=", 5),
      flagOp("--dampen", "-=", 2),
    ],
    default = 0, clamp = clamp(0..10)
  ),
  permissions: flag[set[FilePermission]](
    ops = [
      flagOp("-r", "+=", {fpUserRead}),
      flagOp("-w", "+=", {fpUserWrite}),
      flagOp("-x", "+=", {fpUserExec}),
    ],
    default = {},
    clamp = adjust(proc (v: set[FilePermission]): set[FilePermission] =
      (if fpUserWrite in v: v + {fpUserRead} else: v))
  )
)
```

- Repeating `-v`/`--boost` past 10 (or `--dampen` below 0) silently keeps
  `verbosity`'s value pinned at the bound instead of over/underflowing.
- `permissions`'s set type has no natural ordering, so `adjust` is used instead:
  a write-only file is rarely what anyone actually wants, so whenever `-w` is
  granted without `-r`, `adjust` silently adds read access too rather than
  leaving a write-only permission set.

Note: `default` must already satisfy `clamp`/`adjust`, or spec construction
raises `SpecDefect` — see `examples/verbosity.nim` for the full runnable demo of
`clamp`.

### Value Precedence

`opt`/`opts`/`flag` (not `arg`/`args` — there's no env var or config key to
name a positional argument by) can fall back to more than a coded `default`
when the user gives no value on the command line. In order, **Value
Precedence** tries:

1. an explicit value from the command line
2. an environment variable (`env`)
3. a registered Config Source (`configKey`)
4. the coded `default`

The most specific tier present always wins outright — nothing is ever
merged across tiers — and this applies whether the Option/Flag is required
or optional in the usage grammar.

#### Env Vars

`env` names an environment variable to consult: a plain string is the
common case, or `env(name, delim)` overrides how a multi-value env string
is split (default `:`, `Spec.settings.envDelim`'s own default; `delim = ""`
disables splitting entirely).

```nim
let spec = (
  port: opt("--port=<n>", default = 8080, env = "PORT"),
  tags: opts("--tag=<t>", env = env("TAGS", ","))
)
```

`PORT=9000` sets `spec.port` to `9000` with no `--port` on the command
line; `TAGS=a,b,c` sets `spec.tags` to `@["a", "b", "c"]`. A CLI value
always wins over either. For a `flag`, each env value must instead name one
of the flag's own variants (e.g. `LOGGING=--verbose`), applied via that
variant's own Flag Operation.

#### Config Sources

`configKey` names a structured path into a registered Config Source,
consulted below env vars, above the coded default:

```nim
import argumint/configsource/json

let spec = (
  port: opt[int]("--port=<n>", default = 8080, configKey = "port")
)

spec.parseOrQuit(
  settings = newSpecSettings(configSources = @[jsonConfigSource("config.json")]))
```

A bare string is a one-segment path; nest with `configKey("server",
"port")`. A `ConfigKey` is a `distinct seq[string]`, so a custom
`ConfigSource` addresses it with `key.len`, `key[i]`, and `for segment in
key`, and calls `key.segments` for the underlying `seq[string]` — see
`docs/adr/0029-config-key-distinct.md` for why it isn't a plain alias.

Built-in adapters: `iniConfigSource(path)` (`std/parsecfg`-backed) and
`jsonConfigSource(path)` (`std/json`-backed), both reading and parsing
eagerly at that call. Write your own by subclassing `ConfigSource` and
overriding `lookup`. `SpecSettings.configSources` can hold more than one —
the last one with a hit for a given `configKey` wins outright, the same
never-merge rule as the rest of Value Precedence. See
`examples/config_bootstrap.nim` for a full runnable demo bootstrapping a
Config Source from a `--config=<file>` option via a `before` hook, and
`docs/adr/0018-config-source.md` for the full design.

### Commands

`command(variants, spec, help, prolog, epilog, usage, group, hidden)` builds a
`CommandArg`: a field whose `variants` are words (e.g., `ship`, `move`) rather
than `-o`/`--option`/`<arg>` forms, and whose `spec` is a full nested spec tuple
with its own args/options/flags — and its own nested commands, to any depth.
Matching a command word hands the rest of the command line off to that command's
own `spec`/`usage`, the same way the top-level `spec`/`usage` governs everything
before it.

```nim
import std/strformat
import argumint

proc cmdAdd(spec: tuple, info: HookInfo) =
  for file in spec.files:
    echo fmt"Staging {file}"

let
  add = (files: args("<file>", help = "Files to stage"), help: help())

  spec = (
    add: command("add", add, action = cmdAdd, usage = "<file>...",
      help = "Add file contents to the index"),
    help: help()
  )

spec.parseOrQuit(prolog = "A tiny git-like CLI")
```

```console
$ ./git add a.txt b.txt
Staging a.txt
Staging b.txt

$ ./git --help
A tiny git-like CLI

Usage:
  git add
  git (-h | --help)

Commands
  add         Add file contents to the index

Options
  -h, --help  Display this help message
```

Like a top-level spec, a command's own `usage` is auto-generated from its
declared args if omitted — that's why the top-level `spec` above needs no
explicit `usage` at all: `add`/`(-h | --help)` are derived straight from its two
fields. `add --help` shows `add`'s own usage (`add <file>...`), generated the
same way, one level down.

#### A Command's Own Usage Line

A Command's nested spec compiles to its own FSM exactly like a top-level
spec, and that FSM is spliced into the parent's as a single `Command`
transition. Matching a command word hands the *entire* remaining command
line to the nested spec's own grammar — it never returns control to the
parent Usage Line afterward. That's why a Command's own args, options, and
flags always belong on the Command's *own* `usage`, never tacked onto the
same Usage Line as the command word itself:

```nim
let mineArgs = (
  x: arg("<x>"),
  y: arg("<y>"),
  moored: flag("--moored"),
  drifting: flag("--drifting")
)

let mine = (
  set: command("set", mineArgs),
  remove: command("remove", mineArgs)
)

let spec = (mine: command("mine", mine))
spec.parseOrQuit(
  usage = "mine (set | remove) <x> <y> [--moored | --drifting]"
)
```

```console
Error constructing spec: Error at (1:5): Nothing may follow a Command earlier in
  the same Usage Line -- a matched Command consumes every remaining argument, so
  anything after it can never be reached; use '(a | b)' for alternatives, or
  move it into the earlier Command's own usage
mine (set | remove) <x> <y> [--moored | --drifting]
     ^
```

`<x> <y> [--moored | --drifting]` belongs on `set`/`remove`'s own `usage`
instead — the parent's line stops at `(set | remove)`:

```nim
let mine = (
  set: command("set", mineArgs,
    usage = "<x> <y> [--moored | --drifting]"),
  remove: command("remove", mineArgs,
    usage = "<x> <y> [--moored | --drifting]")
)
```

This mirrors `examples/naval_fate.nim`'s `mine` command, whose `set`/
`remove` subcommands each declare their own `<x> <y> [--moored |
--drifting]` usage rather than sharing one line with `mine` itself.

#### Before, Action, and After Hooks

Every `command()` (and the top-level `parse`/`parseOrQuit` itself) accepts
`before`/`action`/`after` hooks, each a `proc(spec: S, info: HookInfo)` (`spec`
is that level's own parsed tuple). Firing order across a whole matched chain,
root to leaf and back:

1. `before` fires once each level's own values are parsed, root-to-leaf — an
   outer command's `before` always runs, and sees its own values, before a
   nested one's does.
2. `action` fires exactly once, at the dynamic leaf — the deepest level actually
   matched *this invocation*, whether or not that's the deepest level the spec
   could reach. A command with no nested command matched is the leaf; one that
   routes into a subcommand is not, and its own `action` (if any) doesn't fire
   that time.
3. `after` fires leaf-to-root, guaranteed once a level's own `before` has
   completed — success or failure, via nested `try`/`finally`, so a deeper level
   failing still lets every already-entered ancestor's `after` run for cleanup.

```nim
var log: seq[string]

proc shipBefore(spec: tuple, info: HookInfo) = log.add "ship: before"
proc shipAfter(spec: tuple, info: HookInfo) = log.add "ship: after"
proc moveBefore(spec: tuple, info: HookInfo) = log.add "move: before"
proc moveAction(spec: tuple, info: HookInfo) = log.add "move: action (" & spec.name & ")"
proc moveAfter(spec: tuple, info: HookInfo) = log.add "move: after"

let
  move = (name: arg("<name>", help = "Ship to move"))
  ship = (
    move: command("move", move, before = moveBefore, action = moveAction,
      after = moveAfter, usage = "<name>", help = "Move a ship"),
  )
  spec = (
    ship: command("ship", ship, before = shipBefore, after = shipAfter,
      help = "Ship commands"),
  )

spec.parseOrQuit(usage = "ship", args = @["ship", "move", "Titanic"])
echo log
```

```console
$ ./naval_fate ship move Titanic
@["ship: before", "move: before", "move: action (Titanic)", "move: after", "ship: after"]
```

If `move`'s own `before` raised instead of `move`'s `action` ever running,
`ship`'s `after` still fires (`ship` already completed its own `before`, so it's
a fully "entered" level), even though `move`'s never does (it never finished
entering) — the log would end up `@["ship: before", "ship: after"]`, with the
exception still propagating to the caller afterward.

#### `HookInfo`

Every hook receives `info: HookInfo`, a flat view of every `Arg` matched
during the *whole* invocation — not just that level's own spec — so an
outer router command's `before` can see what a nested command matched too.

- `info.matched: seq[Arg]` — every matched `Arg`, across every level
- `info.showsMessage: bool` — true if any matched `Arg` is a `MessageArg`
  (`help()`/`message()`/`version()`), i.e. this invocation is just going to
  print something and exit rather than reach a real `action`

```nim
proc connectToDatabase() = echo "Connecting to the database..."

proc appBefore(spec: tuple, info: HookInfo) =
  if not info.showsMessage:
    connectToDatabase()

let spec = (
  name: arg("<name>", help = "The name to call you"),
  help: help()
)

spec.parseOrQuit(usage = "<name>", before = appBefore)
```

`./hello --help` never connects to the database; `./hello Michael` does,
right before printing its greeting — `info.showsMessage` lets expensive
`before`-time setup skip itself for a request that's just going to print
help/version/a message and exit anyway.

#### Passing Extra Context to Hooks

`command(variants, spec, options, ...)` — with an extra positional argument
between `spec` and `help` — gives every hook a second parameter,
`proc(spec: S, opts: O, info: HookInfo)`. `options` is arbitrary caller-chosen
context, not necessarily CLI-shaped: typically the enclosing spec (or a piece of
it) that a deeply nested command's hooks otherwise have no way to reach, since
`spec: S` alone is scoped to just that command's own tuple.

```nim
proc cmdAdd(spec: tuple, opts: tuple, info: HookInfo) =
  if opts.verbose:
    echo fmt"(verbose) staging {spec.files.len} file(s)"
  for file in spec.files:
    echo fmt"Staging {file}"

let
  verboseFlag = flag("--verbose", help = "Show extra output")
  globalOpts = (verbose: verboseFlag)
  add = (files: args("<file>", help = "Files to stage"), help: help())

  spec = (
    verbose: verboseFlag,
    add: command("add", add, globalOpts, action = cmdAdd,
      usage = "<file>...", help = "Add file contents to the index"),
    help: help()
  )

spec.parseOrQuit(prolog = "A tiny git-like CLI")
```

`--verbose add a.txt` prints the extra count line; `add a.txt` alone doesn't.
Note that `verboseFlag` is declared once and reused by reference in both
`spec.verbose` (so it's reachable/settable from the command line) and
`globalOpts.verbose` (so `cmdAdd` can read it) — since `Arg`s are `ref` objects,
this same trick works for sharing any single `Arg` (not just a whole tuple's
worth) across a spec and its nested commands, and is usually simpler than
threading a whole extra `options: O` tuple through just to share one flag's
value.

### Custom Messages: `message` and `version`

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

### Displaying Help: `help`

`help` builds a `HelpArg`: a flag that, when matched, prints an
auto-generated help message for the spec (usage lines, grouped args with
their `help` text, `[default: ...]`/validator constraints folded in — see
the Features list above) and exits successfully, the same short-circuiting
behavior as `message`/`version`. Every spec throughout this README
declaring a `help: help()` field has been using this.

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

Arguments
  <name>      The name to call you

Options
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

### Shell Completion

Completion candidates are resolved dynamically: a shell asks for them by
re-invoking the real compiled binary with a reserved leading argument,
`<binary> __complete <partial words...>`, and `parse`/`parseOrQuit` intercept
that automatically — re-walking the same FSM real parsing uses, rather than
reimplementing the grammar a second time in bash/zsh/fish. Candidates can never
drift out of sync with what real parsing would actually accept, since both come
from the exact same compiled FSM.

Two things you wire up yourself:

- **Installing a completion script.** `spec.completionScript(shell, binaryName)`
  (`shell` is `Shell = bash | zsh | fish`) returns a script string for that
  shell — author-driven: write it to a file, expose it via a subcommand,
  whatever your packaging needs.
- **Guarding expensive pre-parse setup.** Every completion request re-invokes
  your binary as a fresh process, so anything that runs *before*
  `parse`/`parseOrQuit` is even called (opening a DB connection, loading config)
  reruns on every keystroke, not just real invocations. `isCompletionRequest()`
  lets you skip it. (A `before` hook doesn't need this — see `info.showsMessage`
  in Commands above — since completion requests never reach `dispatch` at all.)

```nim
import std/strformat
import argumint

proc cmdDeploy(spec: tuple, info: HookInfo) =
  echo fmt"Deploying to {spec.env}"

let
  deploy = (
    env: arg("<env>", validator = choice(["staging", "production"]),
      help = "Environment to deploy to"),
  )
  spec = (
    logLevel: opt("--log-level=<level>", default = "info",
      validator = choice(["debug", "info", "warn", "error"]),
      help = "Logging verbosity"),
    deploy: command("deploy", deploy, action = cmdDeploy, usage = "<env>",
      help = "Deploy to an environment"),
    help: help(),
  )

spec.parseOrQuit(prolog = "A tiny CLI demonstrating dynamic shell completion")
```

Once installed, TAB-completing this CLI in a live shell walks the FSM under the
hood — shown here as the literal `__complete` calls a shell's adapter script
makes on your behalf:

<!-- markdownlint-disable MD010 -- these tabs are the literal "value\thelp" wire format, not indentation -->
```console
$ ./deploy __complete ""
-h	Display this help message
--help	Display this help message
--log-level	Logging verbosity
deploy	Deploy to an environment

$ ./deploy __complete dep
deploy	Deploy to an environment

$ ./deploy __complete --log-level ""
debug	
info	
warn	
error	

$ ./deploy __complete deploy ""
staging	
production	
```
<!-- markdownlint-enable MD010 -->

Each candidate is one `value\thelp` line (`help` may be empty, but the tab is
always present). `debug`/`info`/`staging`/`production` above come straight from
each option/arg's own `choice()` validator (`Validator[T].completions()` — see
Validating Values above) — there's no separate place to declare completion
values, so they can never drift out of sync with what the validator would
actually accept. **Only fish and zsh render `help` inline** in their own
completion menu; bash's `compgen`/`COMPREPLY` has no per-candidate description
slot at all, so its generated script strips it before completing bare words.

### Parsing More Than Once

A spec tuple is **single-use**. `parse`/`parseOrQuit` assign into the `Arg`s
you declared, and Match Accumulation is per-`Arg` lifetime rather than
per-parse — so a second parse against the same spec doesn't start fresh:

```nim
let spec = (tags: opts("--tag=<t>"), port: opt("--port=<n>", default = 80))

spec.parse(args = @["--tag", "a", "--port", "81"], command = "app")
spec.parse(args = @["--tag", "b"], command = "app")
# spec.tags is now @["a", "b"], and spec.port is still 81 -- from a command
# line that never mentioned --port
```

That last part is the one to watch: `port` reads as a perfectly ordinary
value, with nothing to indicate it came from the previous parse.

Use **`parsed`** (or `parsedOrQuit`) when you need to parse repeatedly — in a
REPL or server, or in a test with a table of `(argv, expected)` cases. It
parses a *fresh* spec and returns it, so each call is independent and a parse
becomes a pure function of its arguments. Give it a builder proc:

```nim
import std/cmdline

proc buildCli(): auto =
  (tags: opts("--tag=<t>"), port: opt("--port=<n>", default = 80), help: help())

for line in stdin.lines:
  let cli = parsed(buildCli, args = line.parseCmdLine, command = "repl")
  echo cli.port          # 80 unless *this* line set it
```

One limit: values for a command's own nested spec are readable only through
that command's [hooks](#before-action-and-after-hooks), not off the returned
tuple — a spec tuple holds a `CommandArg`, not the nested tuple.

### Error Handling

`parse` and `parseOrQuit` cover the same ground in two different styles: `parse`
raises and lets every exception propagate to the caller — the right choice when
embedding argumint in a larger program that wants to handle failures itself.
`parseOrQuit` catches the same exceptions, prints a formatted message, and
`quit()`s — the right choice for a bare CLI `main()`. Every one of this
section's examples so far has used `parseOrQuit`.

Every parse-time failure derives from `CatchableError`:

- `ParseError` — the command line doesn't match any Usage Line (a
  missing/unrecognized/duplicate option, wrong argument count, etc.)
- `ValidationError` — a value matched the grammar but failed its `validator`
  (see [Validating Values](#validating-values) above) — never raised for a
  `flag`, since a `Validator` doesn't apply there; `clamp` silently corrects
  instead (see [Clamping Flag Values](#clamping-flag-values) above)
- `MessageError` — a `message()`/`version()` flag was matched (see
  [Custom Messages](#custom-messages-message-and-version) above)
- `HelpError`/`CompletionError` — both subtypes of `MessageError`, raised for a
  matched `help()` flag or a shell-completion request respectively, carrying the
  rendered help text/candidates as `.msg`

```nim
import argumint

let spec = (
  n: opt[int]("--num=<n>", default = 0, validator = range(1..10)),
  help: help(),
)

spec.parseOrQuit(usage = "[--num=<n>]")
echo spec.n
```

```console
$ ./demo --num 5
5

$ ./demo --num 999
Validation error: for --num, got 999 but expected one of 1 .. 10

$ ./demo --nope
Parsing error:
  - missing option: (--num=<n> | -h)
  - unexpected option: unrecognized option --nope

Usage:
  demo [--num=<n>]
  demo (-h | --help)
```

Each of these exits `1`, except a matched `help()`/`message()`/`version()`
or completion request, which exits `0` — `parseOrQuit` treats "printed
something and stopped" as success whenever that's what the user actually
asked for.

To handle failures yourself instead of quitting, use `parse` and catch
what you care about:

```nim
try:
  spec.parse(usage = "[--num=<n>]")
except ValidationError as e:
  echo "bad value: ", e.msg
except ParseError as e:
  echo "bad usage: ", e.msg
except MessageError as e:
  echo e.msg
```

Catch `MessageError` alone if you don't need to distinguish `help()` from
`message()`/`version()`/a completion request; catch `HelpError`/
`CompletionError` first if you do, since a broad `except MessageError` would
otherwise catch those subtypes too.

`SpecDefect` is different in kind: it's a `Defect`, not a `CatchableError`,
raised when the *spec itself* is malformed (a bad variant string, a `default`
that fails its own `clamp`, etc.) — a programming mistake caught at construction
time, not a runtime condition to branch on. Nim doesn't technically stop you
from catching a `Defect` (unless compiled with `--panics:on`), but doing so
isn't the intended use here — fix the spec instead. Of the four public entry
points, only `parseOrQuit`'s tuple overload catches it anyway, purely for
bare-`main()` convenience:

```nim
let spec = (n: opt("--n=<n>", default = ""))  # "--n" is too short to be a long option
spec.parseOrQuit(usage = "[--n=<n>]")
```

```console
$ ./demo
Error constructing spec: invalid optional arg variant for n: --n=<n>
```

(exits `1`, same as any other `parseOrQuit` failure). The `Spec`-overloads of
`parse`/`parseOrQuit` never see this at all — by the time you have a `Spec` to
call them with, `newSpec` has already succeeded — and `parse`'s tuple overload
leaves it uncaught, so it propagates like any other `Defect` would.

#### Strict Option Checking

An option-shaped token is never silently accepted as data. This is on by
default (`SpecSettings.strictOptions`) and governs two slots.

**A positional slot,** even when the grammar has a catch-all positional that
could otherwise take the token as literal text:

```nim
let spec = (
  port: opt("--port=<n>", default = 80),
  rest: args("<rest>"),
  help: help())

spec.parseOrQuit(usage = "[options] [<rest>...]")
```

```console
$ ./demo --recrusive
Parsing error:
  - missing option: (-h | --port=<n>)
  - unexpected option: unrecognized option --recrusive
  - missing argument: <rest>

Usage:
  demo [options] [<rest>...]
  demo (-h | --help)

$ ./demo -- --recrusive      # a typed `--` forces it through as literal text
rest = @["--recrusive"]
```

The alternative would be putting `--recrusive` into `rest` and leaving your
program to go looking for a file by that name — in the
`myapp [options] <file>...` shape, guessing "the user meant this literally"
is usually wrong.

**An option's value slot,** which needs no catch-all at all:

```console
$ ./demo --port --verbose
Parsing error:
  - missing option: (-h | --port=<n>)
  - missing value: option --port requires a value
  - unexpected option: unrecognized option --verbose
  - missing argument: <rest>

Usage:
  demo [options] [<rest>...]
  demo (-h | --help)
```

`--port` doesn't swallow `--verbose` as its value. Both complaints appear
rather than one masking the other.

An option left with nothing at all after it is *starved*, and that is an
error whether or not strict checking is on — there's no value to be had
either way.

##### What stays literal

An **undeclared** token with one leading dash whose second character isn't
an ASCII letter is a **Non-Option Short**, and is always accepted as data in
both slots:

```
-5   -12   -3.5   -.5   -1e9   -5.   -0x1F   -+3   -5x   -1_000
```

So `-5` reaches a positional, and `--num -5` sets `num` to `-5`, with no
ceremony. Two leading dashes never qualify. The rule is about shape rather
than "is it a number" — the latter admits `-inf`/`-nan` while rejecting
`-0x1F`.

**Declaring one wins.** The exemption only ever applies to tokens that match
nothing in your spec, so a digit is a perfectly good short option:

```nim
let spec = (
  one: flag("-1, --one", help = "Level one"),
  num: opt("--num=<n>", default = 0),
  rest: args("<rest>"),
  help: help())

spec.parseOrQuit(usage = "[options] [<rest>...]")
```

```console
$ ./demo -1
one = true                 # the declared flag, not a positional

$ ./demo -2
rest = @["-2"]             # undeclared, so Non-Option Short

$ ./demo --num -5
num = -5                   # undeclared, so a value slot takes it literally
```

The same holds for `opt("-2=<n>")`, `-0`, or any other digit spelling.

Declaring one does mean argumint reads it as an option everywhere it can,
which is worth knowing in two places. A same-prefixed token is a cluster
(`-abc` is sugar for `-a -b -c`) like any other, so with `-1` declared,
`-1.5` is `-1` plus a leftover `-.5` — and since `-.` isn't declared either,
that's an error. And `--num -1` gives `-1` to the declared flag, leaving
`--num` with no value. Write the number so it can't be read as your option —
`--num=-1`, or `" -1.5"` with a leading space:

```console
$ ./demo --num=-1
num = -1

$ ./demo " -1.5"
rest = @[" -1.5"]
```

If your grammar genuinely takes dash-leading literal text, prefer forcing it
per-token — a typed `--`, a `[--]` marker in the usage string (see [The
End-of-Options Marker](#the-end-of-options-marker)), a leading space
(`" -x"`), or the attached form (`--name=--nope`) — and reach for the
setting only to turn the check off everywhere:

```nim
spec.parseOrQuit(usage = "[options] [<rest>...]",
                 settings = newSpecSettings(strictOptions = false))
```

## Examples

The `examples/` directory has runnable demos, each compilable with `nim c
examples/<name>.nim`:

- `cp.nim` — the quickstart above; backtracking over a greedy `<src>...`.
- `naval_fate.nim` — docopt's canonical Naval Fate CLI, showing nested
  commands.
- `verbosity.nim` — flag operations (`=`, `+=`, `-=`) driving one shared
  value from several variants.
- `git.nim` — a git-like CLI with several sibling subcommands.
- `serve.nim` — options with validators and env var fallback.
- `dot.nim` — rendering a spec's FSM as a Graphviz `.dot` file, for
  debugging a usage string's compiled grammar.
- `config_bootstrap.nim` — bootstrapping a Config Source from a
  `--config=<file>` option via a `before` hook.
- `flagfile_bootstrap.nim` — GNU-style `@file` flagfile expansion as a plain
  pre-parse `seq[string]` transform, no library support needed.
- `completion.nim` — generating a `bash`/`zsh`/`fish` completion script on
  demand, and guarding expensive pre-parse setup against completion
  requests with `isCompletionRequest()`.

## Learning more

- [API docs](https://squattingmonk.github.io/argumint/) — generated with `nim
  doc` (`nimble docs` builds them locally into `htmldocs/`).
- [`CONTEXT.md`](CONTEXT.md) — the domain vocabulary (Spec, Arg, Variant,
  Validator, Value Precedence, etc.) used throughout the docs and code.
- [`docs/architecture.md`](docs/architecture.md) — how spec construction, FSM
  compilation, runtime matching, and value conversion actually work, file by
  file.
- [`docs/adr/`](docs/adr/) — design decisions and the reasoning behind them.

## Prior Art and Alternatives

- [docopt](http://docopt.org) provides the grammar for usage strings. See also
  the nim implementation [docopt.nim](https://github.com/docopt/docopt.nim)
- [mow.cli](https://github.com/jawher/mow.cli): provided the framework for fsm
  construction and parsing. Note this is a go library, not nim.
- [therapist](https://bitbucket.org/maxgrenderjones/therapist): argumint
  originally began as a fork of therapist, and many of its design decisions come
  from it.
- [parseopt](https://nim-lang.org/docs/parseopt.html): if you want to hand-roll
  a parser.
- [blarg](https://github.com/squattingmonk/blarg): a drop-in replacement to
  parseopt that fixes bugs and adds some small QOL features like
  case-insensitive option matching.

### Why argumint over docopt.nim?

[docopt.nim](https://github.com/docopt/docopt.nim) uses the same usage-string
grammar as argumint, but its matcher and output model stop well short of what a
real CLI needs:

- **No routing, just a table:** After parsing, docopt.nim hands the user a flat
  `Table[string, Value]` containing every option, argument, and command name as
  a stringly-typed key, regardless of how deeply nested the usage pattern was.
  Dispatching on a subcommand means checking `table["ship"]` and `table["move"]`
  by hand. The `dispatchProc` can automate away some of that tedium by calling a
  proc with parameters type-converted from the table, but it quickly gets
  unwieldy for complicated usage patterns or when you have a lot of options.
  argumint's spec is a typed tuple and commands can have their own nested specs.
  Commands also support `before`/`action`/`after` hook procs, so a multi-level
  CLI like Naval Fate is built out of independently testable, independently
  routed pieces instead of one flat bag of strings.
- **No backtracking:** docopt.nim's matcher walks the pattern once, greedily,
  and gives up on ambiguity. A pattern as ordinary as `cp`'s `<src>... <dest>`
  — "one or more source files, then a destination" — can't be expressed,
  because `<src>...` greedily consumes all args, leaving no args to satisfy
  `<dest>`. argumint compiles the usage string into an FSM and can backtrack
  through it, so `cp`'s `[-r] <src>... <dest>` (this library's quickstart
  example) just works. The FSM still supports all the complicated usage patterns
  that docopt.nim does.
- **No contextual errors:** docopt.nim's contract is binary: parsing succeeds
  and the program runs or it fails and the *entire* help/usage text is dumped,
  regardless of what actually went wrong. There's no way to tell the user they
  passed an unrecognized option or didn't pass enough arguments — both just
  reprint the same block. argumint raises distinct errors with specific messages
  so users can identify their errors.
- **Limited type support:** docopt.nim's `Value` is a variant object type
  that has to be converted to a `string`/`int`/`bool`/`seq[string]` by the user.
  That conversion can also be a little arcane (`table["--speed"].len` to get the
  int value of `--speed`? Why???). argumint's arg values have declared types and
  are automatically converted by the parser, raising informative errors at parse
  time if the conversion fails. Implicit conversion at the usage site also means
  you don't need to access fields directly (e.g., `echo fmt"moving at
  {spec.speed} knots"`. argumint can also be extended to handle additional
  types (e.g., automatic conversion to a `DateTime`).
- **No low-level value validation:** docopt.nim does not let the user constrain
  option or argument values; low-level validation has to be done by hand.
  argumint supports validation, so you can attach choice/range/predicate
  validators (composable with `all()`/`any()`) that run at parse time. The
  constraints are even automatically added to help text.
- **No support for env vars or config files:** docopt.nim would require you to
  check for env vars or config values by hand after parsing, and nothing tells
  you whether the value supplied by docopt actually came from the user or is
  just the default value of the option. argumint's options and flags can fall
  back to an env var or config value before hitting its coded default — a
  tiered precedence docopt.nim has no concept of. These values are
  type-converted and validated in the same way as explicitly passed values.

## License

MIT. See [`LICENSE`](LICENSE).
