# Specs and Values

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

A **spec** is a tuple of `Arg`s that describes your program's command line.
To parse, argumint builds the spec into a `Spec`, its own internal structure,
so you usually don't need to think about the `Spec` at all. This page covers
declaring a spec, reading values out of it, writing values into it yourself,
and parsing more than once.

## Declaring a Spec

```nim
import argumint

let spec = (
  name: arg("<name>", help = "Who to greet"),
  times: opt("-t, --times=<n>", default = 1, help = "How many times to greet"),
  help: help(),
)

spec.parseOrQuit()
for _ in 1..spec.times:
  echo "Hello, ", spec.name, "!"
```

```console
$ ./hello Ada
Hello, Ada!
$ ./hello Ada --times 2
Hello, Ada!
Hello, Ada!
```

`parseOrQuit` parses the command line against the spec and stores each value
in its `Arg`. If parsing fails, or the user asks for help, it prints a message
and exits.

Each field of the spec is an `Arg`. These build them:

- `arg` declares a positional argument with one value. `args` takes one or
  more.
- `opt` declares an option with a value. `opts` can be given more than once.
- `flag` declares an option without a value. See [Flags](flags.md).
- `command` declares a subcommand with a spec of its own. See
  [Commands](commands.md).
- `help`, `message` and `version` print something and exit. See
  [Help and Messages](help.md).

A field can also be a tuple of `Arg`s. Its `Arg`s join the spec as if they
were listed directly, which is handy for sharing a group of options:

```nim
let common = (verbose: flag("-v, --verbose", help = "Show extra output"))
let spec = (common: common, name: arg("<name>", help = "Who to greet"))
```

### Variants

The first argument to each constructor lists the `Arg`'s **variants**: the
names it goes by, separated by commas.

- A positional argument is written `<name>`, or as an all-caps `NAME`.
- An option is written `-o` or `--option`. To name its value in help, add a
  placeholder after `=` or `:`, as in `--times=<n>` or `--times=N`. The `=`
  keeps the placeholder from reading as a positional argument.
- A flag is written like an option, without a placeholder.
- A command is a plain word, like `add`.

Usage strings refer to `Arg`s by these names (see
[Usage Strings](usage-strings.md)). A malformed variant is a bug in your
program, not in the user's input, so building the spec raises a `SpecDefect`:

```nim
let spec = (
  good: arg("<good>", help = "A positional argument"),
  bad: arg("bad", help = "Missing its angle brackets"),
)
spec.parseOrQuit()
```

```console
$ ./bad
Error constructing spec: invalid positional arg variant for bad: bad
```

## Keeping a Built Spec

Calling `parse` or `parseOrQuit` on a tuple builds it into a `Spec`, parses,
and throws the `Spec` away. To keep it, build it yourself with `newSpec`:

```nim
let cli = newSpec(spec, prolog = "Greets people")
cli.parseOrQuit()
echo spec.name
```

You need the built `Spec` for `completionScript` (see
[Shell Completion](completion.md)), to reach it later from a hook, or when you
build your command line in one place and parse it in another. Its values still
go to the `Arg`s in your tuple.

A `Spec` is opaque: you pass it to procs like `parseOrQuit` and
`completionScript`, but you don't look inside. The one exception is
`spec.settings`, the `newSpecSettings` value that controls things like help
width. It's shared with every nested command's spec, so changing it changes
the whole program.

### Changing the Defaults at Compile Time

The defaults `newSpecSettings` uses can be changed when the program is built,
without touching its code. Pass a `-d:` define to `nim c`, or put
`switch("define", "argumint.maxWidth=80")` in the program's `config.nims`:

| Define | Constant | Default | Allowed |
|---|---|---|---|
| `-d:argumint.width=N` | `DefaultWidth` | `80` | at least `20` |
| `-d:argumint.maxWidth=N` | `DefaultMaxWidth` | `100` | at least `20` |
| `-d:argumint.maxVariantsWidth=N` | `DefaultMaxVariantsWidth` | `30` | `0` (unlimited) or more |
| `-d:argumint.envDelim=S` | `DefaultEnvDelim` | `:` | any; empty means env values aren't split |
| `-d:argumint.strictOptions=B` | `DefaultStrictOptions` | `true` | `true`/`false` |

- `width` is the help width used when the terminal's width can't be detected.
  `maxWidth` caps a detected width. See
  [Fitting the Terminal](help.md#fitting-the-terminal).
- `maxVariantsWidth` limits how wide the column of option names in help can
  get.
- `envDelim` splits an environment variable into several values, for an
  `Arg` that takes several. See
  [Splitting a Variable into Several Values](precedence.md#splitting-a-variable-into-several-values).
- `strictOptions` changes what your program accepts (see
  [Strict Option Checking](errors.md#strict-option-checking)), so only the
  program's author should set it.
- The width and delimiter defines are safe for anyone building the program,
  such as a packager.

A value outside the allowed range fails the build with a message naming the
define. A setting passed to `newSpecSettings` still wins over its define.

## Getting Values Out

An `Arg` converts to its value wherever Nim knows the type it wants, so most of
the time you can use it as if it were the value:

```nim
let spec = (
  name: opt("--name=<n>", default = "Bob"),
  count: opt("--count=<n>", default = 1),
  tags: opts("--tag=<t>"),
  verbose: flag("-v, --verbose"))

echo "Hello, " & spec.name & "!"  # concatenation
if spec.name == "Bob": ...        # comparison
for t in spec.tags: ...           # iteration
let n = spec.count + 1            # arithmetic
if spec.verbose: ...              # a flag as a condition
```

The conversion can't happen when Nim has to work out a generic type from the
`Arg` itself. It picks the `Arg`'s own type instead, and you get an error
that mentions `ValueArg`. Use `get` to ask for the value explicitly:

```nim
spec.tags.get.join(",")               # join is generic
"a" in spec.tags.get                  # so is `in`
some(spec.name.get)                   # Option[T]
case spec.name.get                    # a case selector
of "Bob": discard
%*{"name": spec.name.get}             # JSON construction
var s = spec.name.get                 # type inference
```

`get` works on every kind of `Arg`. It returns the parsed value of an `arg` or
`opt`, all the values of an `args` or `opts`, and the result of a `flag`'s
operations. If the `Arg` holds no value, it returns the `default`.

Watch out for `some(spec.name)`. It compiles, but it makes an
`Option[ValueArg[...]]`, and the error only shows up where you use it.
Write `some(spec.name.get)`.

### Falling Back at the Point of Use

`get(otherwise)` returns the `Arg`'s value if it holds one, and `otherwise` if
it doesn't. It ignores the `default`:

```nim
let spec = (port: opt("--port=<n>", default = 8080))
spec.parseOrQuit(usage = "[--port=<n>]")

echo spec.port.get               # 8080 if the user gave no --port
echo spec.port.get(freePort())   # freePort() if the user gave no --port
```

`otherwise` is only evaluated when it's needed, so an expensive fallback like
`freePort()` costs nothing when the user gave a port. Like the `default`, it
isn't validated, and using it doesn't make the `Arg` count as `seen`.

### Where a Value Came From

`seen` says whether anything supplied a value, and `seenBy` says what did:
`byCli` (the command line), `byEnv` (an environment variable), `byConfig` (a
config file), or `byNone`:

```nim
if spec.port.seenBy == byEnv:
  echo "Using the port from $PORT"
```

The sources are ordered from weakest to strongest, so `spec.port.seenBy >
byConfig` means the value came from the environment or the command line. See
[Value Precedence](precedence.md).

## Setting Values Yourself

Sometimes your program needs to set a value itself, such as a default worked
out at startup. `parse` takes a string and gives it the same conversion and
validation a command-line value gets:

```nim
let port = opt("--port=<n>", default = 80)

port.parse("8080", seenBy = some(byCli))  # as if the user typed --port 8080
port.get                                  # 8080
port.seenBy                               # byCli

port.clear()                              # forget it
port.get                                  # 80, the default again
```

A value that doesn't convert raises a `ParseError`, and one the validator
rejects raises a `ValidationError`.

`seenBy` says which source your value counts as. It's an `Option`, so wrap
the source in `some`: a plain `byCli` won't convert.

Whenever a value arrives at an `Arg` that already has one, the two sources
decide what happens:

- A stronger source replaces the old value.
- The same source adds to it, for an `Arg` that takes several values, or
  replaces it, for one that takes a single value.
- A weaker source is ignored.

That works in both directions. A value you write is ignored if the `Arg`
already has one from a stronger source:

```nim
let spec = (port: opt("--port=<n>", default = 80))

spec.parse(args = @["--port", "81"])
spec.port.parse("90", seenBy = some(byConfig))
spec.port.get                # 81: the command line is stronger
```

And a value you write before parsing is a starting point, not something the
command line silently loses:

```nim
let tags = opts("--tag=<t>")
let spec = (tags: tags)

tags.parse("built-in", seenBy = some(byCli))
spec.parse(args = @["--tag", "mine"])
tags.get                     # @["built-in", "mine"]: same source, so added
```

`seenBy = none(SeenBy)`, the default when you leave `seenBy` out, means your
value counts as whatever source the `Arg` already has, so it's never ignored.
On an `Arg` nothing has set yet, the value is stored without a source: `get`
returns it, but `seen` stays `false`, so any real source replaces it:

```nim
let tags = opts("--tag=<t>")
let spec = (tags: tags)

tags.parse("built-in")       # the same as seenBy = none(SeenBy)
spec.parse(args = @["--tag", "mine"])
tags.get                     # @["mine"]: the command line replaced it
```

`some(byNone)` behaves the same way on an `Arg` nothing has set yet. Once
something has set it, though, `some(byNone)` counts as the weakest source and
is ignored, while `none(SeenBy)` still writes.

To let a weaker source take over, call `clear` first:

```nim
let spec = (port: opt("--port=<n>", default = 80))

spec.parse(args = @["--port", "81"])
spec.port.clear()
spec.port.parse("90", seenBy = some(byConfig))
spec.port.get                # 90
```

For a flag, the string you pass is the variant whose
[operation](flags.md) to apply, so each call is one use of the flag:

```nim
let verbose = flag[int](ops = [flagOp("-v, --verbose", "+=", 1)])

verbose.parse("--verbose", seenBy = some(byCli))
verbose.parse("-v", seenBy = some(byCli))
verbose.get                  # 2
```

### Writing a Typed Value

If you already have a value of the right type, `put` stores it without
converting it from a string. Otherwise it works like `parse`:

```nim
port.put(8080, seenBy = some(byCli))
port.get                     # 8080
```

`put` runs the `Arg`'s [validator](args-and-options.md#validating-values) on
the value. Pass `validate = false` to skip that:

```nim
tags.put("unchecked", seenBy = some(byCli), validate = false)
```

A flag has no validator, so its `put` has no `validate` parameter. It still
applies the flag's [clamp](flags.md):

```nim
let level = flag[int](ops = [flagOp("-l", "+=", 1)], default = 0,
                      clamp = clamp(0..2))
level.put(99, seenBy = some(byCli))
level.get                    # 2, clamped
```

### Replacing Every Value at Once

To swap all the values of an `args` or `opts` for new ones, you could call
`clear` and then `put` each value. But if a value partway through is rejected,
the `Arg` is left with only some of the new values. `replace` validates every
new value before changing anything, so if one is rejected, the `Arg` keeps
its old values:

```nim
let tags = opts("--tag=<t>", validator = unique[string]())

tags.put("old", seenBy = some(byCli))
tags.replace(@["a", "b"], seenBy = some(byCli))
tags.get                     # @["a", "b"]

tags.replace(@["a", "a"], seenBy = some(byCli))  # raises ValidationError
tags.get                     # still @["a", "b"]
```

Some validators, like `unique`, check a value against the ones the `Arg`
already holds. `replace` checks each new value against the other new values
only, since the old ones are about to go. Replacing `@["a"]` with
`@["a", "b"]` passes `unique`, even though `"a"` is already there.

Unlike `parse` and `put`, `replace` always applies, even from a weaker source.
So to let a weaker source take over, you can `replace` with that source
instead of calling `clear` first. With `none(SeenBy)`, the default, it keeps
the current source.

## Parsing More Than Once

A spec tuple is single-use. A second parse builds on the first instead of
starting fresh:

```nim
let spec = (tags: opts("--tag=<t>"), port: opt("--port=<n>", default = 80))

spec.parse(args = @["--tag", "a", "--port", "81"])
spec.parse(args = @["--tag", "b"])
spec.tags.get                # @["a", "b"]
spec.port.get                # 81, though the second command line had no --port
```

The port is the one to watch: nothing about `81` says it came from the first
parse.

To parse more than once, as a REPL, a server, or a table-driven test does, use
`parsed` or `parsedOrQuit`. Give it a proc that builds the spec. It builds a
fresh spec for each call, parses into it, and returns it:

```nim
import std/cmdline
import argumint

proc buildCli(): auto =
  (tags: opts("--tag=<t>"), port: opt("--port=<n>", default = 80), help: help())

for line in stdin.lines:
  let cli = parsed(buildCli, args = line.parseCmdLine, command = "repl")
  echo cli.port              # 80 unless this line set --port
```

A command's own values can't be read from the returned tuple, which only holds
the command itself. Read them in the command's
[hooks](commands.md#before-action-and-after-hooks) instead.
