# Error Handling

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

When the user makes a mistake, `parseOrQuit` says what went wrong, shows the
usage, and exits with `1`:

```nim
import argumint

let spec = (
  n: opt[int]("--num=<n>", default = 1, validator = range(1..10)),
  help: help(),
)

spec.parseOrQuit(usage = "[--num=<n>]")
echo spec.n
```

```console
$ ./demo --num 5
5
$ ./demo --num 999
Validation error:
  - for --num, got 999 but expected a value in 1..10

Usage:
  demo [--num=<n>]
  demo (-h | --help)
$ ./demo --num x
Parsing error:
  - expected an integer for --num but got "x"

Usage:
  demo [--num=<n>]
  demo (-h | --help)
$ ./demo --nope
Parsing error:
  - unrecognized option: --nope

Usage:
  demo [--num=<n>]
  demo (-h | --help)
```

Errors go to stderr. Help, a [message](help.md#messages-and-versions), and
[completion](completion.md) aren't errors: they go to stdout, and the program
exits with `0`.

## Did You Mean

When the user mistypes an option or a command, argumint suggests the closest
names. A swapped pair of letters counts as one mistake, and when two names
are equally close, it offers both:

```nim
import argumint

let spec = (
  port: opt("--port=<n>", default = 80, help = "Port to listen on"),
  host: opt("--host=<name>", default = "localhost", help = "Host to listen on"),
  verbose: flag("-v, --verbose", help = "Log every request"),
  help: help(),
)

spec.parseOrQuit()
```

```console
$ ./serve --prot 8080
Parsing error:
  - unrecognized option: --prot; did you mean --port?

Usage:
  serve [options]
  serve (-h | --help)
$ ./serve --hort example.com
Parsing error:
  - unrecognized option: --hort; did you mean --host or --port?

Usage:
  serve [options]
  serve (-h | --help)
```

A mistyped short option gets no suggestions. Every one-letter name is one
mistake away from every other, so a suggestion like `-v` for `-x` wouldn't
help.

## Handling Errors Yourself

`parse` doesn't print or exit. It raises an exception, so a larger program
can decide what to do:

- `ParseError`: the command line doesn't fit the usage, or a value can't be
  converted to its type.
- `ValidationError`: a value failed its
  [validator](args-and-options.md#validating-values).
- `MessageError`: the user asked for a
  [message](help.md#messages-and-versions), such as `--version`. Its two
  subtypes are `HelpError`, for help, and `CompletionError`, for a
  [completion](completion.md) request.

Each one's `msg` says what went wrong and shows the usage. This program
prints it and exits with `2` for a mistake, as many tools do:

```nim
import argumint

let spec = (
  n: opt[int]("--num=<n>", default = 1, validator = range(1..10)),
  help: help(),
)

try:
  spec.parse(usage = "[--num=<n>]")
except ParseError, ValidationError:
  stderr.writeLine getCurrentExceptionMsg()
  quit 2
except MessageError as e:
  echo e.msg
  quit 0

echo spec.n
```

```console
$ ./demo --num 99
  - for --num, got 99 but expected a value in 1..10

Usage:
  demo [--num=<n>]
  demo (-h | --help)
$ echo $?
2
```

A mistake's `msg` leaves out the `Parsing error:` or `Validation error:`
line, so you can write your own. `msg` is always plain text. For the
coloured text `parseOrQuit` prints in a terminal, use `styledMsg`. See
[Colour](help.md#colour).

To handle help or completion differently from other messages, put
`except HelpError` or `except CompletionError` above `except MessageError`.

## Strict Option Checking

argumint never takes something that looks like an option as a value. A typo
like `--recrusive` is an error, even where a positional argument could take
any text:

```nim
import argumint

let spec = (
  port: opt("--port=<n>", default = 80, help = "Port to listen on"),
  verbose: flag("-v, --verbose", help = "Log every request"),
  files: args("<file>", help = "Files to serve"),
  help: help(),
)

spec.parseOrQuit(usage = "[options] [<file>...]")
echo "port = ", spec.port, ", files = ", spec.files
```

```console
$ ./serve --recrusive
Parsing error:
  - unrecognized option: --recrusive

Usage:
  serve [options] [<file>...]
  serve (-h | --help)
```

Otherwise, the program would go looking for a file named `--recrusive`. If
the user really means that file, they can type `--` before it. Everything
after `--` is a value:

```console
$ ./serve -- --recrusive
port = 80, files = @["--recrusive"]
```

The same goes for an option's value. If the user forgets the port, `--port`
doesn't take `--verbose` as its value:

```console
$ ./serve --port --verbose
Parsing error:
  - missing value: option --port requires a value

Usage:
  serve [options] [<file>...]
  serve (-h | --help)
```

### Negative Numbers

A dash followed by anything but an ASCII letter, like `-5`, `-.5`, or
`-0x1F`, doesn't look like an option. argumint takes it as a value, both for
a positional argument and for an option:

```console
$ ./serve -5
port = 80, files = @["-5"]
$ ./serve --port -5
port = -5, files = @[]
```

This doesn't apply when your program declares an option like that, such as
`gzip`'s `-1` to `-9`:

```nim
import argumint

let spec = (
  fast: flag("-1, --fast", help = "Compress faster"),
  best: flag("-9, --best", help = "Compress better"),
  level: opt("--level=<n>", default = 6, help = "Compression level"),
  files: args("<file>", help = "Files to compress"),
  help: help(),
)

spec.parseOrQuit(usage = "[options] [<file>...]")
echo "fast = ", spec.fast, ", level = ", spec.level, ", files = ", spec.files
```

```console
$ ./compress -1 a.txt
fast = true, level = 6, files = @["a.txt"]
$ ./compress -2
fast = false, level = 6, files = @["-2"]
$ ./compress --level -1
Parsing error:
  - missing value: option --level requires a value

Usage:
  compress [options] [<file>...]
  compress (-h | --help)
```

`-2` isn't declared, so it's a value. `-1` is, so `--level -1` gives `-1` to
the `--fast` flag and leaves `--level` with no value. The user can attach the
value with `=` instead:

```console
$ ./compress --level=-1
fast = false, level = -1, files = @[]
```

Or they can put a space in front of it, inside quotes. A number ignores the
space, but a string keeps it:

```console
$ ./compress --level " -1"
fast = false, level = -1, files = @[]
$ ./compress " -1.5"
fast = false, level = 6, files = @[" -1.5"]
```

Short options combine, so `-19` means `-1 -9`. In the same way, `-1.5` is
read as `-1`, `-.`, and `-5`, and `-.` isn't declared. The user can type `--`
before it:

```console
$ ./compress -1.5
Parsing error:
  - unrecognized option: -. (in -1.5)

Usage:
  compress [options] [<file>...]
  compress (-h | --help)
$ ./compress -- -1.5
fast = false, level = 6, files = @["-1.5"]
```

### Turning Off Strict Checking

If your program takes values that start with a dash, the user can type `--`
before them, or you can add `[--]` to the usage. See
[The End of Options Marker](usage-strings.md#the-end-of-options-marker). To
turn the check off everywhere, set `strictOptions` to `false`:

```nim
spec.parseOrQuit(usage = "[options] [<file>...]",
                 settings = newSpecSettings(strictOptions = false))
```

```console
$ ./serve --recrusive
port = 80, files = @["--recrusive"]
```

An option that needs a value then takes whatever follows it, even another
option. A declared option in any other place is still an option.

## Mistakes in the Spec

A mistake in the spec itself, like a badly formed name, raises a
`SpecDefect` when the spec is built, before any argument is read:

```nim
import argumint

let spec = (n: opt("--n=<n>", default = ""))  # "--n" is too short

spec.parseOrQuit(usage = "[--n=<n>]")
```

```console
$ ./demo
Error constructing spec: invalid optional arg variant for n: --n=<n>
```

`parseOrQuit` and `parsedOrQuit` print this and exit with `1` when they build
the spec from a tuple. Anywhere else, including `parse` and `newSpec`, the
`SpecDefect` isn't caught and the program stops with a stack trace. It's a bug
in your program, not the user's mistake, so fix the spec rather than catching
it. See also
[Mistakes in a Usage String](usage-strings.md#mistakes-in-a-usage-string).
