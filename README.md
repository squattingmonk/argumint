# argumint: freshen up your arg parsing

A Nim command-line argument parsing library where a [docopt](http://docopt.org/)-style
usage string is compiled into a finite state machine (FSM) that drives actual
parsing.

Most argument parsers make you register flags imperatively and then bolt on
extra logic for anything that doesn't fit that flat model: mutually exclusive
options, optional-but-positional arguments, repeated values. argumint inverts
this — you declare a usage string like docopt's, and it's compiled once into
an FSM that *is* the grammar. Backtracking through that FSM is what decides
whether a given command line is valid, so patterns like `[-r] <src>... <dest>`
(not possible in docopt) or `(set|remove) <x> <y> [--moored|--drifting]` just
work, without hand-written validation code.

## Requirements

- Nim >= 2.2.4

## Installation

argumint uses [Atlas](https://github.com/nim-lang/atlas) for dependency
management rather than a classic `nimble.lock`. From your project's root:

```
atlas use https://github.com/squattingmonk/argumint
```

## Quickstart

```nim
import std/strformat
import argumint

let
  spec = (
    src: args[string]("<src>", help = "The source file(s) to copy"),
    dest: arg("<dest>", help = "The destination to copy to"),
    recursive: flag("-r, --recursive", help = "Whether to recurse into subdirectories"),
    help: help()
  )

spec.parseOrQuit(usage = "[-r] <src>... <dest>", prolog = "Copy files around")
for file in spec.src:
  echo fmt"Copying {file} to {spec.dest} (recursive: {spec.recursive})"
```

```
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
- **Auto-generated, wrapped help** — usage lines and per-arg help text are
  generated from the spec and wrapped to a configurable width; `[default:
  ...]` and validator constraints are folded into the help text
  automatically.
- **Shell completion** — dynamic, FSM-driven `bash`/`zsh`/`fish` completion
  generated from the same spec that drives parsing, so completions can never
  drift out of sync with what actually parses.

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

## Learning more

- [`CONTEXT.md`](CONTEXT.md) — the domain vocabulary (Spec, Arg, Variant,
  Validator, Value Precedence, etc.) used throughout the docs and code.
- [`docs/architecture.md`](docs/architecture.md) — how spec construction, FSM
  compilation, runtime matching, and value conversion actually work, file by
  file.
- [`docs/adr/`](docs/adr/) — design decisions and the reasoning behind them.

## Prior Art and Alternatives

- [docopt](http://docopt.org) and [docopt.nim](https://github.com/docopt/docopt.nim)
  provide the grammar for the usage strings.
- [mow.cli](https://github.com/jawher/mow.cli): provided the framework for fsm
  construction and parsing.
- [therapist](https://bitbucket.org/maxgrenderjones/therapist): argumint
  originally began as a fork of therapist, and many of its design decisions come
  from it.
- [parseopt](https://nim-lang.org/docs/parseopt.html): if you want to hand-roll
  a parser.
- [blarg](https://github.com/squattingmonk/blarg): an alternative to parseopt
that fixes bugs and adds some small QOL features.

## License

MIT. See [`LICENSE`](LICENSE).
