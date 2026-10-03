# Specs and Values

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Basics

argumint uses a tuple (optionally nested) to represent the arguments, options,
and commands available to the parser — this is called the **spec**. Each member
of the spec must be an `Arg` or another spec tuple. The spec tuple is then
passed to `parse` or `parseOrQuit` along with an optional usage string. If the
parse is successful, the parsed values are assigned to their respective `Arg`s.
You can then get the values with implicit conversion from the spec tuple itself.

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
[Value Precedence](precedence.md#value-precedence).

### Changing the Defaults at Compile Time

The defaults `newSpecSettings` uses can be changed when the program is
built, without touching its code. Pass a `-d:` define to `nim c`, or put
`switch("define", "argumint.maxWidth=80")` in the program's `config.nims`:

| Define | Constant | Default | Allowed |
|---|---|---|---|
| `-d:argumint.width=N` | `DefaultWidth` | `80` | at least `20` |
| `-d:argumint.maxWidth=N` | `DefaultMaxWidth` | `100` | at least `20` |
| `-d:argumint.maxVariantsWidth=N` | `DefaultMaxVariantsWidth` | `30` | `0` (unlimited) or more |
| `-d:argumint.envDelim=S` | `DefaultEnvDelim` | `:` | any; empty means env values aren't split |
| `-d:argumint.strictOptions=B` | `DefaultStrictOptions` | `true` | `true`/`false` |

`width` is the fallback used when no terminal width can be detected, and
`maxWidth` caps a detected width (see
[Displaying Help](help.md#displaying-help)). A value outside the allowed range
fails the build with a message naming the define. A setting passed to
`newSpecSettings` explicitly still wins over its define.

`argumint.strictOptions` changes what the program's own grammar accepts (see
[Strict Option Checking](errors.md#strict-option-checking)), so it's meant for
the program's author. The width and delimiter defines are safe for anyone
building the program, such as a packager.

## Getting Values Out

An `Arg` converts implicitly to its value type, so most of the time you can
use it as if it were that value:

```nim
let spec = (
  name: opt("--name=<n>", default = "Bob"),
  count: opt("--count=<n>", default = 1),
  tags: opts("--tag=<t>"),
  verbose: flag("-v, --verbose"))

echo fmt"Hello, {spec.name}!"     # interpolation
if spec.name == "Bob": ...        # comparison
for t in spec.tags: ...           # iteration
let n = spec.count + 1            # arithmetic
if spec.verbose: ...              # a flag as a condition
```

A conversion fires only where the expected type is already known. It can't
fire where a generic parameter has to be inferred *from* the `Arg` — the
type variable binds to the `Arg` instead of to its value, and you get an
error mentioning `ValueArg`. Reach for `get` there:

```nim
spec.tags.get.join(",")               # generic over openArray[T]
"a" in spec.tags.get                  # generic over the container
some(spec.name.get)                   # Option[T]
case spec.name.get                    # a case selector
of "Bob": discard
%*{"name": spec.name.get}             # JSON construction
let xs: seq[string] = @[spec.name.get]
var s = spec.name.get                 # var inference
```

`get` works on every kind of `Arg` and always returns exactly what the
implicit conversion would: the parsed value for a scalar `arg`/`opt`, the
accumulated `seq` for `args`/`opts`, the composed value for a `flag`, and
the coded `default` if nothing supplied one.

`some(spec.name)` deserves special mention: it *compiles*, silently
inferring `Option[ValueArg[...]]`, and only fails wherever the expected
type is finally named. `some(spec.name.get)` is the fix.

### Overriding the default at the point of use

`get(otherwise)` returns the parsed value when the command line, an
environment variable, or a Config Source supplied one, and `otherwise` when
none did — the coded `default` is ignored for that call:

```nim
let spec = (port: opt("--port=<n>", default = 8080))
spec.parseOrQuit(usage = "[--port=<n>]")

echo spec.port.get           # 8080 if unsupplied -- the coded default
echo spec.port.get(freePort())   # freePort() if unsupplied
```

`otherwise` is not evaluated when a value was supplied, so an expensive or
side-effecting fallback like `freePort()` above costs nothing on the path
that discards it.

This is not a fifth tier of [Value Precedence](precedence.md#value-precedence):
it substitutes for the coded `default` at read time, per call site, so two reads
of the same `Arg` may legitimately differ. Like the `default` it replaces,
`otherwise` is never validated and never marks the `Arg` as supplied — asking
which tier a value actually came from is a separate question, answered by an
`Arg`'s `seenBy`/`seen` (see `CONTEXT.md`'s *Seen Arg* entry and
`docs/adr/0039-per-arg-provenance.md`).

## Setting Values Yourself

`parse` is the write side of the same coin. It takes a raw string and puts
it through exactly the path a command-line value takes — the same
converter, the same validator, the same clamp — so a programmatic write
can't end up holding something a real one couldn't:

```nim
let port = opt("--port=<n>", default = 80, help = "")

port.parse("8080", seenBy = some(byCli))   # seed it as if the user typed it
port.get                                   # => 8080
port.seenBy                                # => byCli

port.clear()                               # back to the coded default
port.get                                   # => 80
```

The `seenBy` argument names which [Value
Precedence](precedence.md#value-precedence) tier you're writing as. Omitting it
means "extend whatever tier is current" — useful for adding to an `Arg` a tier
already supplied, and for seeding one nothing has: the value is stored and
`get`/`get(otherwise)` return it, but the `Arg` itself stays unseen (`seenBy`
stays `byNone`), so a real tier can still arbitrate against it exactly as a
supplied one would (see below).

A tier you declare is then arbitrated against by the real ones, so a value
written *before* `parse*` runs is a seed rather than something that gets
silently clobbered:

```nim
tags.parse("built-in", seenBy = some(byCli))
spec.parse(args = @["--tag", "mine"])
tags.get                     # => @["built-in", "mine"] — same tier, so appended

tags.parse("built-in")       # no tier declared
spec.parse(args = @["--tag", "mine"])
tags.get                     # => @["mine"] — the command line outranks it, so it replaced
```

A stronger tier replaces, an equal tier appends, and a weaker one is
refused — `parse` never demotes an `Arg`. Call `clear` first if handing it
to a weaker tier is what you actually want. A multi-value `Arg` appends on
each call, so `clear` plus one `parse` per value replaces the whole set —
or use `replace` (below) for the typed, one-call, atomic version of the
same idiom. A `Flag` is the one shape that reads differently: the value you
pass *is* the variant whose operation to apply, so one call is one bump:

```nim
verbose.parse("--verbose", seenBy = some(byCli))
```

### Writing an Already-Typed Value

`parse` takes a raw `string` and converts it, which is a problem if you
already have the `T` you want and no reason to round-trip it back through
`$`. `put` is `parse` with the conversion step removed — same arbitration,
same provenance rules, same replace-for-scalar/append-for-multi shape —
just handed a typed value directly:

```nim
port.put(8080, seenBy = some(byCli))   # no string, no conversion
port.get                               # => 8080
```

It validates by default, same as `parse`, but — unlike `parse` — you can
opt out at any arity:

```nim
tags.put("unchecked", seenBy = some(byCli), validate = false)
```

A `Flag`'s `put` always applies its clamp and never validates — there's no
`validate` parameter to pass, since a `Flag` has no validator to skip, and
no `variant` parameter either, since nothing on that path can fail:

```nim
let level = flag[int](ops = [flagOp("-l", "+=", 1)], default = 0,
                       clamp = clamp(0..2), help = "")
level.put(99, seenBy = some(byCli))
level.get                             # => 2, clamp-coerced like any other write
```

### Replacing a Multi Arg's Values in One Call

`clear` then one `put`/`parse` per value works, but it isn't atomic: if a
value partway through the batch fails validation, the `Arg` is left
holding a prefix of the new values with the old ones already gone.
`replace` is a typed, one-call, atomic version of the same idiom — every
value is validated before anything is written, so a rejected batch leaves
the `Arg` exactly as it was:

```nim
tags.put("old", seenBy = some(byCli))
tags.replace(@["a", "b"], seenBy = some(byCli))
tags.get                               # => @["a", "b"] -- "old" is gone

tags.replace(@["a", "a"], seenBy = some(byCli))  # fails against a unique validator
tags.get                               # => @["a", "b"] -- untouched by the failed call
```

Each candidate is validated against the other new values already accepted
in the same call, never against the values it's replacing — the `Arg`'s
own prior values are about to be discarded, so checking against them would
reject a value the batch is about to be the only holder of.

Unlike `put`/`parse`, `replace` never arbitrates against the `Arg`'s
current tier: it always applies, which means it can demote — the explicit
spelling for handing an `Arg` to a weaker tier, in one call instead of
`clear` followed by a loop. Omitting `seenBy` keeps whichever tier the
`Arg` already carries rather than clearing it, since `replace` overwrites
the value and the provenance together and there's nothing left for a
`clear` to undo.

A `Spec` is still single-use either way — see
[Parsing More Than Once](#parsing-more-than-once).

## Parsing More Than Once

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

One limit: values for a command's own nested spec are readable only through that
command's [hooks](commands.md#before-action-and-after-hooks), not off the
returned tuple — a spec tuple holds a `CommandArg`, not the nested tuple.
