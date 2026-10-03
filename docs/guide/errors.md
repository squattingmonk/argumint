# Error Handling

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Error Handling

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
  (see [Validating Values](args-and-options.md#validating-values)) — never
  raised for a `flag`, since a `Validator` doesn't apply there; `clamp` silently
  corrects instead (see
  [Keeping Values in Bounds](flags.md#keeping-values-in-bounds))
- `MessageError` — a `message()`/`version()` flag was matched (see
  [Custom Messages](help.md#custom-messages))
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
Validation error:
  - for --num, got 999 but expected a value in 1..10

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

Each of these exits `1`, except a matched `help()`/`message()`/`version()`
or completion request, which exits `0` — `parseOrQuit` treats "printed
something and stopped" as success whenever that's what the user actually
asked for.

Every failure message has the same shape: a bulleted list of complaints,
then the `Usage:` block — a conversion or validation failure included, as
above. Within that, argumint tries hard to point at the token you actually
got wrong rather than at what the grammar wanted:

```console
$ ./naval_fate shp move a 1 2
Parsing error:
  - unrecognized command: shp; did you mean ship?

Usage:
  naval_fate (ship | mine)
  naval_fate (-h | --help)
  naval_fate (-v | --version)

$ ./naval_fate ship move a 1 2 --sped 9
Parsing error:
  - unrecognized option: --sped; did you mean --speed?

Usage:
  naval_fate ship (new | move | shoot)
  naval_fate ship (-h | --help)
```

The did-you-mean suggestion covers commands and options alike, tolerates a
transposition (`--prot` finds `--port`), and offers every equally-close
candidate rather than the first one it happens to find. Short options are left
out of it entirely, in both directions: one is never suggested (every
one-character name is one edit from every other, so offering them says nothing),
and one never receives a suggestion (`-ab` is cluster syntax, so `--ab` is not
what it "meant"). Once a specific token is named, complaints about options the
parser merely had left to try are dropped — an option covered by `[options]`, or
one you already supplied, is never reported missing. See
[`docs/adr/0035-parse-failure-reporting.md`](https://github.com/squattingmonk/argumint/blob/main/docs/adr/0035-parse-failure-reporting.md).

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

### Strict Option Checking

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
  - unrecognized option: --recrusive

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
  - missing value: option --port requires a value
  - unrecognized option: --verbose

Usage:
  demo [options] [<rest>...]
  demo (-h | --help)
```

`--port` doesn't swallow `--verbose` as its value. Both complaints appear
rather than one masking the other.

An option left with nothing at all after it is *starved*, and that is an
error whether or not strict checking is on — there's no value to be had
either way.

#### What stays literal

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
End-of-Options Marker](usage-strings.md#the-end-of-options-marker)), a leading
space (`" -x"`), or the attached form (`--name=--nope`) — and reach for the
setting only to turn the check off everywhere:

```nim
spec.parseOrQuit(usage = "[options] [<rest>...]",
                 settings = newSpecSettings(strictOptions = false))
```
