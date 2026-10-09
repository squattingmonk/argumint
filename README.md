# argumint: a fresh command-line argument parsing library

argumint is a command-line argument parser for Nim. You describe your
program's arguments in a [docopt](http://docopt.org/)-style usage string, and
argumint compiles it into a state machine that parses the command line. If a
command line fits the usage string, it parses. If it doesn't, the user sees
what went wrong.

Because the usage string does the parsing, patterns like `[-r] <src>... <dest>`
or `<x> <y> [--moored | --drifting]` work without any checking code of your
own. Parsed values come back typed, on the same tuple you declared.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [Features](#features)
- [Documentation](#documentation)
- [Examples](#examples)
- [Prior Art and Alternatives](#prior-art-and-alternatives)
- [License](#license)

## Requirements

- Nim >= 2.2.4

## Installation

argumint is available on [Nimble's package
list](https://github.com/nim-lang/packages):

```console
nimble install argumint
```

If you'd rather use [Atlas](https://github.com/nim-lang/atlas) for dependency
management:

```console
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

```console
$ ./cp -r foo.txt bar.txt dest/
Copying foo.txt to dest/ (recursive: true)
Copying bar.txt to dest/ (recursive: true)
$ ./cp foo.txt
Parsing error:
  - missing argument: <dest>

Usage:
  cp [-r] <src>... <dest>
  cp (-h | --help)
$ ./cp --help
Copy files around

Usage:
  cp [-r] <src>... <dest>
  cp (-h | --help)

Arguments:
  <src>            The source file(s) to copy
  <dest>           The destination to copy to

Options:
  -r, --recursive  Whether to recurse into subdirectories
  -h, --help       Display this help message
```

A spec is a plain Nim tuple. Each field is an argument, option, or flag, and
after parsing it holds a typed value: `spec.dest` works as a `string`, and
`spec.recursive` as a `bool`. The [tutorial](docs/guide/tutorial.md) builds a
larger program step by step.

## Features

- **[Usage strings that parse](docs/guide/usage-strings.md):** optional,
  repeated, and alternative arguments, several usage lines, `[options]` for
  every option you don't name, and an end of options marker, all written the
  way you'd write them in help. Arguments, options, and commands mix freely.
- **Familiar syntax:** long (`--file`) and short (`-f`) options, combined short
  options (`-vx` for `-v -x`), and every common way to attach a value: `-f
  file`, `-ffile`, `-f=file`, `-f:file`, `--file file`, `--file=file`, and
  `--file:file`.
- **[Typed values](docs/guide/args-and-options.md#types-and-defaults):**
  `string`, `bool`, `char`, enums, every integer and float type, and range
  types like `Natural` out of the box, and
  [your own types](docs/guide/custom-types.md) with a converter.
- **[Validators](docs/guide/args-and-options.md#validating-values):** limit a
  value to a set of choices or a range, or write your own check, and combine
  them with `all` and `any`. Help lists each limit for you.
- **[Flags that do more than switch on](docs/guide/flags.md):** count how often
  a flag is given, step through an enum, or give several names to one value,
  each setting it, adding to it, or running your own code on it. A clamp keeps
  the result in bounds.
- **[Commands](docs/guide/commands.md):** nested to any depth, each with its
  own spec and any number of names, and `before`, `action`, and `after` hooks
  to run your code.
- **[Environment variables and config files](docs/guide/precedence.md):** an
  option or flag can take its value from either when the user doesn't give
  one, and one variable can hold several values. The command line wins, then
  the environment, then the config file, then the default. INI and JSON are
  built in, and you can add your own format. Every value
  [knows where it came from](docs/guide/specs.md#where-a-value-came-from).
- **[Generated help](docs/guide/help.md):** wrapped to the terminal, with
  each default, limit, and environment variable listed for you. Sort entries
  into groups, hide some, and choose a two-column layout or a paragraph layout
  with room for longer text. It's coloured in a terminal and plain elsewhere.
  Add `--version` and other messages, or write your own layout.
- **[Helpful errors](docs/guide/errors.md):** each error names the argument
  that went wrong and suggests the long option or command the user probably
  meant. By default, a mistyped option is never taken as a value, but a
  negative number is.
- **[Shell completion](docs/guide/completion.md):** bash, zsh, and fish
  completion of commands, options, and `choice` values, drawn from the same
  usage strings, so it always agrees with the parser. fish and zsh show each
  one's help beside it.
- **[Setting values yourself](docs/guide/specs.md#setting-values-yourself):**
  give an argument a value with the same conversion and validation the
  command line gets, and
  [parse more than once](docs/guide/specs.md#parsing-more-than-once).

## Documentation

- [Tutorial](https://squattingmonk.github.io/argumint/guide/tutorial.html):
  build a small program with commands, validation, and completion, step by
  step.
- [User guide](https://squattingmonk.github.io/argumint/guide/): every
  feature, one page each. The same pages are readable on GitHub in
  [`docs/guide/`](docs/guide/index.md).
- [API reference](https://squattingmonk.github.io/argumint/argumint.html):
  every public proc and type.

`nimble docs` builds both into `htmldocs/`.

If you'd like to work on argumint itself:

- [`CONTEXT.md`](CONTEXT.md) defines the terms used in the code and docs.
- [`docs/architecture.md`](docs/architecture.md) explains how parsing works,
  file by file.
- [`docs/adr/`](docs/adr/) records design decisions and the reasons for them.

## Examples

The `examples/` directory has programs you can build with
`nim c examples/<name>.nim`:

- `cp.nim`: the quickstart above, where `<src>...` leaves the last argument
  for `<dest>`.
- `naval_fate.nim`: docopt's Naval Fate program, with nested commands.
- `git.nim`: a program with two commands, `add` and `commit`.
- `notes.nim`: the notebook program built in the
  [tutorial](docs/guide/tutorial.md).
- `verbosity.nim`: several flag names that set, add to, and subtract from one
  value.
- `serve.nim`: options with validators and environment variables.
- `config_bootstrap.nim`: reading a config file named by a `--config` option,
  from a `before` hook.
- `flagfile_bootstrap.nim`: expanding `@file` arguments from a file before
  parsing.
- `completion.nim`: printing a shell completion script, and skipping slow
  setup when the shell asks for completions.
- `dot.nim`: drawing the state machine a usage string compiles to, as a
  Graphviz graph, to debug a usage string.

## Prior Art and Alternatives

- [docopt](http://docopt.org) gives argumint its usage-string grammar. See
  also its Nim version, [docopt.nim](https://github.com/docopt/docopt.nim).
- [mow.cli](https://github.com/jawher/mow.cli), a Go library, provided the
  approach to building and walking the state machine.
- [therapist](https://bitbucket.org/maxgrenderjones/therapist): argumint began
  as a fork of therapist, and many of its design decisions come from it.
- [parseopt](https://nim-lang.org/docs/parseopt.html), if you'd rather write
  a parser by hand.
- [blarg](https://github.com/squattingmonk/blarg), a drop-in replacement for
  parseopt that fixes bugs and adds small features like case-insensitive
  option matching.

## License

MIT. See [`LICENSE`](LICENSE).
