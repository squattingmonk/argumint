# Flags

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

A **flag** is an option that doesn't take a value. Instead, giving the flag
changes a value that it holds. A flag can be switched on, count how many times
it's given, or do something you choose for each of its names.

```nim
import argumint

let spec = (
  verbose: flag[int]("-v, --verbose", help = "Show more"),
  force: flag("-f, --force", help = "Overwrite existing files"),
  color: flag("--no-color", default = true, help = "Turn off colour"),
  help: help(),
)

spec.parseOrQuit()
echo "verbose=", spec.verbose, " force=", spec.force, " color=", spec.color
```

```console
$ ./build
verbose=0 force=false color=true
$ ./build -vvv -f --no-color
verbose=3 force=true color=false
```

- A `bool` flag is the opposite of its default once it's given. Giving it
  again doesn't flip it back.
- An `int` flag adds 1 each time it's given, so `-vvv` gives 3.
- An enum flag moves to the next value each time it's given.

A flag can also be set by an environment variable or a config file, whose
value is one of the flag's names. See [Value Precedence](precedence.md).

## Types and Defaults

A flag's type and default follow the same rules as an
[option's](args-and-options.md#types-and-defaults), except that with neither,
the flag is a `bool`:

```nim
let spec = (
  force: flag("--force"),                    # bool, default false
  color: flag("--no-color", default = true), # bool, default true
  verbose: flag[int]("-v"),                  # int, default 0
  level: flag("-l", default = 2),            # int, default 2
)
```

A flag can have any type. The names you give `flag` itself work for three
kinds of type:

- A `bool` becomes the opposite of its default.
- An integer of any size, like `int` or `uint8`, adds 1. It stops at the
  largest value the type can hold, so a `uint8` flag stops at 255.
- An enum moves to its next value, stopping at the last one.

A flag of any other type, like `float` or `string`, needs
[operations](#flag-operations) to say what each name does. Giving one a name
of its own, as in `flag[float]("--speed")`, raises a `SpecDefect` when the
spec is built.

## Flag Operations

An **operation** says what a name does to the flag's value. Pass `flagOp`
calls as `ops`, each with its names, its operation, and a value:

```nim
import argumint

let spec = (
  verbosity: flag("-v, --verbose", default = 1, help = "How much to say",
    ops = [flagOp("-q, --quiet", "=", 0), flagOp("--loud", "+=", 5)]),
  help: help(),
)

spec.parseOrQuit()
echo "verbosity=", spec.verbosity
```

`-v` and `--verbose` add 1, as for any `int` flag. `-q` and `--quiet` set the
value to 0, and `--loud` adds 5. Help describes what each name does:

```console
$ ./talk --loud -v
verbosity=7
$ ./talk --help
Usage:
  talk [options]
  talk (-h | --help)

Options:
  -v, --verbose  How much to say [action: Increase by 1]
  -q, --quiet    How much to say [action: Set to 0]
  --loud         How much to say [action: Increase by 5]
  -h, --help     Display this help message
```

Pass `help` to a `flagOp` to replace its description, as in
`flagOp("--loud", "+=", 5, help = "Shout")`.

These operations are built in:

- `=` sets the value. It works for every type.
- `+=` adds to the value, `-=` subtracts from it, and `*=` multiplies it.
  They work for any type with `+`, `-` or `*`, like numbers and
  [sets](#sets-of-enum-values). Using one on a type without it, like `+=` on
  a `string`, is a compile error.

On an integer, `+=`, `-=` and `*=` stop at the smallest and largest values
the type can hold, rather than wrapping around. A range type, like
`range[0..10]`, stops at its own bounds. For other bounds, see
[Keeping Values in Bounds](#keeping-values-in-bounds).

The operations run in the order the user typed the names, so the same names in
a different order can give a different value:

```console
$ ./talk -vv -q
verbosity=0
$ ./talk -q -v
verbosity=1
```

### Writing Operations as a String

`ops` can also be a string, with each entry written as a name, an operation,
and a value. argumint converts each value from text to the flag's type, here a
`float`:

```nim
import argumint

let spec = (
  speed: flag(default = 1.0, help = "Playback speed",
    ops = "--slow=0.5, --fast=2.0"),
  help: help(),
)

spec.parseOrQuit()
echo "speed=", spec.speed
```

```console
$ ./play
speed=1.0
$ ./play --fast
speed=2.0
```

Each entry has only one name, and one of the operations above. Its value is
read the way an `opt` would read it: an enum by name, and any other type with
its `converter` from `string`. For an operation with more than one name, a
value you can't write as a string, or an [operation of your
own](#your-own-flag-operations), use `flagOp`.

## Flags in a Usage String

A [usage string](usage-strings.md) names only a flag's names, never an
operation or its value. Like options, flags can come in any order. A flag can
be given only once in each place that names it, so add `...` to let it
repeat:

```nim
import argumint

let spec = (
  file: arg("<file>"),
  verbose: flag[int]("-v, --verbose", help = "Show more"),
)

spec.parseOrQuit(usage = "[-v]... <file>")
echo "verbose=", spec.verbose
```

```console
$ ./show -vv notes.txt
verbose=2
```

With `[-v] <file>`, `-vv` would be an unexpected flag. Flags covered by
`[options]` can always repeat.

Names declared together are interchangeable, so `-v` in the usage string also
accepts `--verbose`. Names from different operations aren't, even when they
belong to the same flag. Each one needs its own place in the usage string:

```nim
import argumint

let spec = (
  direction: flag(default = "", help = "Direction to move",
    ops = "--up=up, --down=down, --left=left, --right=right"),
)

spec.parseOrQuit(usage = "(--up | --down)")
echo spec.direction
```

Here `--left` and `--right` can never be given, since the usage string names
neither of them:

```console
$ ./move --up
up
$ ./move --left
Parsing error:
  - missing option: (--up | --down)

Usage:
  move (--up | --down)
```

## Your Own Flag Operations

An operation can be code of your own. `flagOpIt` takes an expression for the
flag's new value, in which `it` is the value it has now:

```nim
import argumint

type Level = enum
  debug, info, warn, error

let spec = (
  level: flag("-q, --quieter", default = info, help = "Log level",
    ops = [flagOp("--debug", "=", debug),
           flagOpIt[Level]("-v, --louder", (if it > debug: pred(it) else: it),
                           "Show more")]),
  help: help(),
)

spec.parseOrQuit()
echo spec.level
```

`-q` and `--quieter` move to the next level, as for any enum flag, and `-v`
and `--louder` move back one. The last argument to `flagOpIt` describes it in
help. Without one, help shows no action for it.

```console
$ ./log -qqqq
error
$ ./log -vvv
debug
$ ./log --help
Usage:
  log [options]
  log (-h | --help)

Options:
  -q, --quieter  Log level [action: Move to the next value]
  --debug        Log level [action: Set to debug]
  -v, --louder   Log level [action: Show more]
  -h, --help     Display this help message
```

`flagOp` takes a proc instead, which changes the value it's given:

```nim
flagOp("-v, --louder", proc (level: var Level) =
  if level > debug: dec level)
```

An operation of your own works for a flag of any type, including one that
argumint can't read from a string. See [Custom Types](custom-types.md#flags).

### Sets of Enum Values

A flag can hold a `set` of an enum. Each operation's value is a set:

- `=` replaces the flag's set.
- `+=` adds the elements, and `-=` removes them.
- `*=` keeps only the elements in both sets.

```nim
import argumint

type Topping = enum
  cheese, ham, olives

let spec = (
  toppings: flag(default = {cheese}, help = "Toppings",
    ops = [
      flagOp("--ham", "+=", {ham}, help = "Add ham"),
      flagOp("--olives", "+=", {olives}, help = "Add olives"),
      flagOp("--no-cheese", "-=", {cheese}, help = "Leave off the cheese"),
      flagOp("--deluxe", "=", {cheese, ham, olives}, help = "Everything"),
    ]),
  help: help(),
)

spec.parseOrQuit()
echo spec.toppings
```

```console
$ ./pizza --ham --olives
{cheese, ham, olives}
$ ./pizza --no-cheese --olives
{olives}
```

Without `help`, help describes each operation by its elements, as in "Add
ham". In the string form of `ops`, each value is one element, as in
`ops = "--ham+=ham, --olives+=olives"`.

## Keeping Values in Bounds

A flag can't have a [validator](args-and-options.md#validating-values), since
its value comes from its operations. Instead, `clamp` keeps the value in a
range. It runs after every operation, and never raises an error:

```nim
import argumint

let spec = (
  volume: flag(default = 5, help = "Volume",
    ops = "--up+=3, --down-=3, --mute=0",
    clamp = clamp(0..10)),
  help: help(),
)

spec.parseOrQuit()
echo "volume=", spec.volume
```

```console
$ ./vol --up --up
volume=10
$ ./vol --down --down --up
volume=3
$ ./vol --help
Usage:
  vol [options]
  vol (-h | --help)

Options:
  --up        Volume [clamp: 0..10; action: Increase by 3]
  --down      Volume [clamp: 0..10; action: Decrease by 3]
  --mute      Volume [clamp: 0..10; action: Set to 0]
  -h, --help  Display this help message
```

`--down --down` takes the volume to 0, not -1, so `--up` then gives 3. Pass
`desc` to replace the clamp's text in help, or `desc = some("")` to hide it.

The default has to be in the range too. If it isn't, building the spec raises
a `SpecDefect`.

For a type with no order, like a set, `adjust` runs a proc of your own after
every operation instead. In the pizza example, this adds cheese to any pizza
with ham:

```nim
clamp = adjust(proc (t: set[Topping]): set[Topping] =
  if ham in t: t + {cheese} else: t)
```

```console
$ ./pizza --no-cheese --ham
{cheese, ham}
```
