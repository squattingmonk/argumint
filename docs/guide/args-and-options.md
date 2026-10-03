# Arguments and Options

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

Most of a command line is positional arguments and options that take a
value. This page covers declaring them, giving them types and defaults,
taking more than one value, and checking the values the user gives.

```nim
import argumint

let spec = (
  src: args("<src>", help = "Files to copy"),
  dest: arg("<dest>", help = "Where to copy them"),
  mode: opt("-m, --mode=<mode>", default = "644", help = "Permissions for the copies"),
  retries: opt[int]("-r, --retries=<n>", help = "How many times to retry"),
  exclude: opts("-x, --exclude=<glob>", help = "Skip files matching this pattern"),
  help: help(),
)

spec.parseOrQuit()
echo "src: ", spec.src
echo "dest: ", spec.dest
echo "mode: ", spec.mode
echo "retries: ", spec.retries
echo "exclude: ", spec.exclude
```

```console
$ ./copy a.txt b.txt backup/ -x '*.tmp' --exclude '*.bak'
src: @["a.txt", "b.txt"]
dest: backup/
mode: 644
retries: 0
exclude: @["*.tmp", "*.bak"]
```

- `arg` declares a positional argument with one value. `args` takes one or
  more.
- `opt` declares an option with a value. `opts` can be given more than once.

Options can come before, after, or between the positional values. If an `opt`
is given more than once, the last value wins.

## Types and Defaults

Each `Arg` has a value type and a default. The default is used when the user
doesn't give a value. You can write the type in brackets, give a default, do
both, or do neither:

```nim
let spec = (
  name: arg("<name>"),                             # string, default ""
  count: arg[int]("<count>"),                      # int, default 0
  level: opt("-l, --level=<n>", default = 1),      # int, default 1
  ratio: opt[float]("--ratio=<x>", default = 0.5), # float, default 0.5
)
```

With only a default, the type comes from the default. With only a type, the
default is that type's zero value. With neither, the value is a `string`.

These types work out of the box:

- `string`
- `int` and `float`
- `bool`, which accepts `true`/`false`, `yes`/`no`, `y`/`n`, `on`/`off`, and
  `1`/`0`. For an option that's simply present or absent, use a
  [flag](flags.md) instead.
- `char`, which must be a single character

A value that doesn't convert is reported with the usage:

```console
$ ./copy a.txt out -r x
Parsing error:
  - expected int for -r but got "x"

Usage:
  copy [options] <src>... <dest>
  copy (-h | --help)
```

An option can also take its value from an environment variable or a config
file. See [Value Precedence](precedence.md).

## Taking More Than One Value

`args` and `opts` hold a `seq` of values instead of a single one. Their type
and default work the same way, but the default is a `seq`:

```nim
let spec = (
  files: args("<file>"),                        # seq[string], default @[]
  nums: opts[int]("--num=<n>"),                 # seq[int], default @[]
  sizes: opts("--size=<n>", default = @[1, 2]), # seq[int], default @[1, 2]
)
```

Nim can't work out a type from an empty `@[]`, so to give an empty default
you write the type in brackets instead. Values the user gives replace the
default rather than adding to it, so `--size 7 --size 8` gives `@[7, 8]`.

## Your Own Types

Any type can be a value type if you write a `converter` from `string` and call
`defineArg`:

```nim
import std/strutils
import argumint

type Color = enum
  red, green, blue

converter toColor(value: string): Color = parseEnum[Color](value)
defineArg(Color)

let spec = (
  color: opt("-c, --color=<color>", default = green, help = "Colour to use"),
  help: help(),
)

spec.parseOrQuit()
echo spec.color
```

```console
$ ./paint -c blue
blue
$ ./paint -c purple
Parsing error:
  - expected Color for -c but got "purple"

Usage:
  paint [options]
  paint (-h | --help)
```

The converter raises a `ValueError` for a value it can't convert, and argumint
reports it. To use the type for a flag too, see
[Custom Flag Types](flags.md#custom-flag-types).

## Validating Values

A **validator** checks each value the user gives. Pass one as `validator`:

```nim
import argumint

let spec = (
  port: opt("-p, --port=<n>", default = 8080, help = "Port to listen on",
    validator = range(1..65535)),
  env: opt("-e, --env=<name>", default = "dev", help = "Settings to load",
    validator = choice(["dev", "staging", "prod"])),
  workers: opt("-w, --workers=<n>", default = 2, help = "Worker processes",
    validator = checkIt[int](it mod 2 == 0, "must be even")),
  tags: opts("-t, --tag=<tag>", help = "Tag the server",
    validator = unique[string]()),
  help: help(),
)

spec.parseOrQuit()
```

Help shows what each option accepts:

```console
$ ./serve --help
Usage:
  serve [options]
  serve (-h | --help)

Options:
  -p, --port=<n>     Port to listen on [range: 1..65535; default: 8080]
  -e, --env=<name>   Settings to load [choices: "dev", "staging", "prod";
                     default: "dev"]
  -w, --workers=<n>  Worker processes [must be even; default: 2]
  -t, --tag=<tag>    Tag the server [must be unique]
  -h, --help         Display this help message
```

A value that fails is reported before your program sees it:

```console
$ ./serve -p 0
Validation error:
  - for -p, got 0 but expected a value in 1..65535

Usage:
  serve [options]
  serve (-h | --help)
$ ./serve -t web -t web
Validation error:
  - for -t, "web" did not meet condition: must be unique

Usage:
  serve [options]
  serve (-h | --help)
```

These validators are built in:

- `range(a..b)` accepts a value from `a` to `b`.
- `choice([...])` accepts one of the listed values.
- `check(proc)` accepts a value the proc returns `true` for. `checkIt` is the
  same, but takes an expression that uses `it` for the value.
- `unique()` accepts a value of an `args` or `opts` that hasn't been given
  already.
- `checkSeen(proc)` and `checkSeenIt` are like `check` and `checkIt`, but
  also see the values given before this one, as `seen`.

`range`, `choice`, `check` and `checkSeen` work out the value type from what
you pass them. `checkIt`, `checkSeenIt` and `unique` have nothing to work it
out from, so write it in brackets, as in `unique[string]()`.

A validator checks only the values the user gives, whether on the command
line, in an environment variable, or in a config file. It never checks your
own default, so a default outside the range is fine.

### Writing Your Own Checks

Give `check` a proc that takes the value and returns whether it's good. The
last argument describes the rule for help and errors:

```nim
import argumint

proc isPrime(n: int): bool =
  if n < 2: return false
  for d in 2..<n:
    if n mod d == 0: return false
  true

let spec = (
  seed: opt("--seed=<n>", default = 7, help = "Random seed",
    validator = check(isPrime, "must be prime")),
  steps: opts("--step=<n>", help = "Steps, each larger than the last",
    validator = checkSeenIt[int](seen.len == 0 or it > seen[^1], "must increase")),
)

spec.parseOrQuit()
```

```console
$ ./seeds --seed 8
Validation error:
  - for --seed, 8 did not meet condition: must be prime

Usage:
  seeds [options]
$ ./seeds --step 3 --step 2
Validation error:
  - for --step, 2 did not meet condition: must increase

Usage:
  seeds [options]
```

Without a description, `checkIt` and `checkSeenIt` show the expression
itself.

### Combining Validators

`all` passes when every validator passes. `any` passes when at least one
does. Each takes any number of validators, including other `all`s and `any`s,
and works out the value type from them:

```nim
import std/strutils
import argumint

let spec = (
  size: opt("-s, --size=<n>", default = 4, help = "Block size",
    validator = all(range(1..64), checkIt[int](it mod 4 == 0, "a multiple of 4"))),
  level: opt("-l, --level=<level>", default = "info", help = "Log level",
    validator = any(choice(["debug", "info"]), checkIt[string](it.startsWith("x-")),
      desc = "debug, info, or a custom x- level")),
  help: help(),
)

spec.parseOrQuit()
```

```console
$ ./blocks --help
Usage:
  blocks [options]
  blocks (-h | --help)

Options:
  -s, --size=<n>       Block size [range: 1..64 and a multiple of 4; default: 4]
  -l, --level=<level>  Log level [debug, info, or a custom x- level; default:
                       "info"]
  -h, --help           Display this help message
$ ./blocks -s 6
Validation error:
  - for -s, 6 did not meet condition: a multiple of 4

Usage:
  blocks [options]
  blocks (-h | --help)
```

`all` reports the first validator that fails. Without a description, `any`
lists all of its validators, joined with "or". Every validator takes an
optional `desc` to replace its text in help and errors, as `any` does above.
