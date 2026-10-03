# Usage Strings

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Usage Strings, Grammar, and the FSM

This is the thing that makes argumint different from other argument
parsers: the **usage string** isn't just a docstring shown to the user.
It's compiled, once, into a finite state machine (FSM), and that FSM is
what actually walks the real command line at parse time. There's no
separate imperative validation layer bolted on beside it — whatever the
usage string says is legal *is* what gets accepted, and nothing else.

A usage string is one or more **Usage Lines**, separated by newlines, each
one an independent, complete pattern — the whole string means "the command
line must match this line, *or* this one, *or* this one." An indented line
continues the Usage Line before it, so a long one can wrap, and blank lines
are ignored. Within a single Usage Line, these tokens combine into a
grammar:

| Syntax            | Meaning                                                                                     |
| ---               | ---                                                                                         |
| `command`         | A literal word naming a [command](commands.md#commands) (e.g. `ship`).                                 |
| `<name>` / `NAME` | A [positional argument](args-and-options.md#declaring-arguments-and-options).                                  |
| `-o` / `--option` | An [option or flag](args-and-options.md#declaring-arguments-and-options), by any one of its declared variants. |
| `-abc`            | A cluster of short options (sugar for `-a -b -c`)                                           |
| `[...]`           | Everything inside is optional.                                                              |
| `(...)`           | Groups tokens, usually so `\|` or `...` applies to the group.                               |
| `a \| b`          | Exactly one of `a` or `b` — mutually exclusive alternatives.                                |
| `...`             | The atom before it (an arg, option, or group) can repeat.                                   |
| `[options]`       | Catch-all for any option/flag not named elsewhere on this line.                             |
| `--`              | End-of-options marker: everything after it is a positional value.                           |
| `{cmd}`           | Only at a line's start: the command path. A line of just `{cmd}` is a Bare Call.            |

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

To write that name anyway, the way docopt does, start a line with `{cmd}`,
which stands for it. It's optional on each line, and a line that is only
`{cmd}` is a **Bare Call**: the command with nothing after it.

```nim
let spec = (x: arg("<x>"), y: arg("<y>"), help: help())
spec.parseOrQuit(usage = """
{cmd}
{cmd} <x> [<y>]
""")
```

```console
$ ./myapp --help
Usage:
  myapp
  myapp <x> [<y>]
  myapp (-h | --help)
```

A blank line isn't a Bare Call, since blank lines are ignored, so the
newline before the closing `"""` adds nothing. A usage string built with
`fmt` needs `{{cmd}}`.

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
  - unexpected flag: --drifting

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
grammar can be written on the same Usage Line.
`mine (set | remove) <x> <y> [--moored | --drifting]` looks tempting but isn't
legal — a matched Command consumes every remaining token, so nothing else on
that line could ever be reached. See [A Command's Own Usage
Line](commands.md#usage-lines-for-a-command) for why, and how a Command's own
nested spec compiles into its own FSM that gets spliced into the parent's.

### The `[options]` Catch-all

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
  - unexpected option: --name=b

Usage:
  myapp --name=<n> [options]
  myapp (-h | --help)
```

### The End of Options Marker

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

### Backtracking, not left-to-right scanning

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

### Auto-generated usage strings

`usage` is optional — and even when you do supply one, it's checked against
every `Arg` you've declared, not just taken as the whole truth: anything not
reachable anywhere in it gets a line appended automatically. This is why the
[Quickstart](https://github.com/squattingmonk/argumint#quickstart) and the
`[-r] <src>... <dest>` example [above](#visualizing-the-compiled-fsm) don't need
to spell out `-h`/`--help` themselves. The fill-in rule differs by kind:

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

### Visualizing the compiled FSM

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

![FSM compiled from `[-r] <src>... <dest>`](../images/cp-usage-fsm.png)

Reading this: from the start state `S1`, `-r` moves to `S2` (skippable, so
`S1` also reaches `S3` directly — that's the `[-r]`), `<src>` can loop on
`S3` any number of times (the `...`), and `<dest>` finally reaches the
terminal state `S4`. `S1 -> S5` is `-h`/`--help`, auto-filled in on its own
line since it wasn't mentioned in the `usage` given here.

For a bigger, real-world example, here's the full FSM compiled from
`examples/naval_fate.nim`'s entire spec — every level of nesting (`ship`/
`mine` and each of their own subcommands) shows up as one connected graph,
since a Command's nested FSM is spliced directly into its parent's (see
[Usage Lines for a Command](commands.md#usage-lines-for-a-command)):
[naval-fate-fsm.png](../images/naval-fate-fsm.png) (not embedded here —
it's a big graph).
