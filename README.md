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
(not possible in docopt) or `mine (set|remove) <x> <y> [--moored|--drifting]`
just work, without hand-written validation code.

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
    src: args[string]("<src>", help = "The source file(s) to copy"),
    dest: arg[string]("<dest>", help = "The destination to copy to"),
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

- **Positional args, options, flags, and commands** — declared uniformly as
  fields of one spec tuple, freely combinable in a usage string.
- **Nested subcommands** — a `command()` field owns its own nested spec, so a
  CLI like `myapp ship move <x> <y>` can be built out of independently
  testable pieces. See `examples/naval_fate.nim` for a full multi-level
  example (docopt's canonical Naval Fate demo).
- **Flag operations** — a flag isn't just a boolean; variants can set,
  increment, decrement, or reset a shared value (`-v, --verbose,
  --quiet=0`). See `examples/verbosity.nim`.
- **Validators** — attach choice, range, or arbitrary-predicate constraints
  to an arg, composable with `all()`/`any()`, with generated help text and
  clear `ValidationError`s.
- **Env var fallback** — an option or flag can fall back to an environment
  variable (including multi-value, delimiter-aware fallback) when not given
  on the command line.
- **Config Source fallback** — an option or flag can also fall back to a
  registered, read-only Config Source (built-in INI/JSON adapters, or your
  own) below env vars and above the coded default. See
  `examples/config_bootstrap.nim`.
- **Auto-generated, wrapped help** — usage lines and per-arg help text are
  generated from the spec and wrapped to a configurable width; `[default:
  ...]` and validator constraints are folded into the help text
  automatically.
- **Shell completion** — dynamic, FSM-driven `bash`/`zsh`/`fish` completion
  generated from the same spec that drives parsing, so completions can never
  drift out of sync with what actually parses. `fish` and `zsh` also show
  each candidate's help text inline as you complete it; `bash` has no
  equivalent to render one into. See `examples/completion.nim`.

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
