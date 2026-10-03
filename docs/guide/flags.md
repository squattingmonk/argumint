# Flags

[Guide](index.md) ·
[API reference](https://squattingmonk.github.io/argumint/argumint.html)

## Declaring Flags

`flag[T]()` builds a flag: an optional argument that never takes a value from
the command line, changing its stored value instead based on which variant was
seen (e.g. `-v`/`--verbose` increments, `--quiet` resets — see
`examples/verbosity.nim`). `T` and `default` follow the same rules as
`arg[T]()`/`opt[T]()`, except the implicit fallback is `bool` instead of
`string`, since a plain on/off flag is by far the most common case:

- explicit `[T]`, no `default` — falls back to `default(T)` (e.g. `0`, `0.0`,
  `false`)
- no `[T]`, explicit `default` — `T` is inferred from the default value's type
- neither — `T` falls back to `bool`, `default` to `false`

```nim
let
  spec = (
    foo: flag("--foo"),                  # T implicitly bool, default false
    bar: flag("--bar", default = 3),     # T implicitly int, default 3
    baz: flag[int]("--baz"),             # T explicitly int, default 0
    qux: flag[int]("--qux", default = 5) # T explicitly int, default 5
  )
```

Beyond the type-specific implicit behavior above (`bool` toggles, `int`
increments by 1), a flag can declare **explicit Flag Operations** via
`flagOp`, passed to `ops`: each names its own spelling(s), an operation,
and a value, deciding how seeing that variant changes the flag's stored
value:

- `"="` — set the value directly
- `"+="` / `"-="` — add or subtract the value (`int`/`float64` only)

```nim
let spec = (
  verbosity: flag[int](
    "-v, --verbose",
    ops = [
      flagOp("--quiet", "=", 0),
      flagOp("--boost", "+=", 5),
    ],
    default = 0
  )
)
```

declares four variants sharing one value: `-v`/`--verbose` increment by 1
(the implicit blank-op behavior for `int`), `--quiet` resets to `0`, and
`--boost` jumps by 5 — see `examples/verbosity.nim` for the full runnable
version, including `clamp` to pin the result to a range.

Each `flagOp`'s `op`/`value` are spec metadata, decided when you write the
spec — they're never something the user types, and they never appear in
the usage string. Only the bare flag names do, e.g. `[-v | --verbose |
--quiet | --boost]...`.

When every explicit Variant's value has a natural string spelling (the
common case — no custom type, no multi-spelling group), `ops` also accepts
a plain comma-separated string instead of an array of `flagOp` calls, as
convenience sugar for exactly the same thing:

```nim
let spec = (
  verbosity: flag("-v, --verbose", default = 0, ops = "--quiet=0, --boost+=5, --dampen-=2")
)
```

is equivalent to the array form above. Each entry is `<flag><op><value>`,
becoming its own single-spelling group — a multi-spelling explicit group,
or a value with no string spelling (e.g. a multi-element `set[E]`), still
needs the array form directly. See
`docs/adr/0028-flag-ops-string-convenience.md`.

### Variant Exclusivity and Composition Order

Variants declared together — either in `flag`'s own `variants` string, or
together in one `flagOp` call — are *aliases*, and are treated as
interchangeable. When a flag's variant is mentioned in a usage string, any
alias of that variant can be used to satisfy that position within the
grammar. Since each alias indexes the same flag and Flag Operation, you
don't need to reference all of them within the usage string (i.e., either
`-v` or `--verbose` will do) — though you may choose to do so for clarity
to the user. Variants declared in *different* `flagOp` calls are never
aliases of each other, even if their op/value happen to match, so they
cannot satisfy each others' positions in the usage string grammar (e.g.
`--quiet` cannot substitute for `--verbose`).

```nim
let spec = (direction: flag[int](ops = [
  flagOp("--up", "=", 1), flagOp("--down", "=", -1),
  flagOp("--left", "=", 2), flagOp("--right", "=", -2),
]))
spec.parseOrQuit(usage = "(--up | --down) (--left | --right)")
```

`--up --down` is a `ParseError` here: `--up` satisfies `(--up | --down)`'s
position, but `--down` isn't an alias of `--left` or `--right`, so it is
rejected as an unexpected option.

Note that since flags (like options) have order-independence, `--up --left` and
`--left --up` can both satisfy the above usage line. A flag's matched variants
always compose in the order they were actually typed on the command line — not
the order the usage string declares them in. This matters once operations stop
being commutative (see [Clamping Flag Values](#clamping-flag-values) below):
given `ops = [flagOp("-u", "+=", 5), flagOp("-d", "-=", 2)]` clamped to
`0..10`, `-u -d` and `-d -u` are both valid against `usage = "-u -d"`, but
land on different final values, since each composes strictly left-to-right
in typed order. For the full mechanics, see
`docs/adr/0026-flag-op-alias-exclusivity.md`.

### Custom Flag Types

`bool`/`int`/`float64`/`char`/`string` work as `flag[T]` out of the box, but
any type can — argumint needs two things from you to make it work:

- a `converter` from `string` to `T` — `defineFlag` also wires up
  `arg[T]`/`opt[T]` support for the same type (shared machinery), which
  parses raw command-line strings, even though a `flagOp`'s own `value: T`
  is always a real, already-typed Nim value and never goes through this
  converter itself
- a `defineFlag(T, blankDesc): case op of ...` block declaring which
  operations `T` supports and what each one does to `value`

```nim
import std/strutils

type LogLevel = enum
  debug, info, warn, error

converter toLogLevel(value: string): LogLevel = parseEnum[LogLevel](value)

defineFlag(LogLevel, "Bump up one level"):
  case op
  of "": value = LogLevel((ord(value) + 1) mod (ord(high(LogLevel)) + 1))
  of "=": value = arg
  else: raise newException(SpecDefect, "log level flags only support = operations")

let spec = (
  level: flag[LogLevel](
    "-v, --verbose",
    ops = [
      flagOp("--debug", "=", debug),
      flagOp("--warn", "=", warn),
      flagOp("--error", "=", error),
    ],
    default = info, help = "Set the log level"
  )
)
```

Here `-v`/`--verbose` share the blank op (bump up a level each time seen),
while `--debug`/`--warn`/`--error` each set the level directly via their
own `flagOp`. See `docs/architecture.md`'s "Flags" section for the full
mechanism, including `defineArg`, which registers a type for
`arg`/`opt`/`args`/`opts` the same way `defineFlag` does for `flag`.

`set[E]` for any enum `E` is common enough to have a ready-made helper,
`defineSetFlag(E)`, instead of writing your own `case op` block — it wires up
`=` (set), `+=` (include/union), `-=` (exclude/difference), and `*=`
(intersect) for you:

```nim
type Color = enum
  red, green, blue

defineSetFlag(Color)

const warmColors = {red, green}

let spec = (
  palette: flag[set[Color]](
    ops = [
      flagOp("--red", "=", {red}),
      flagOp("--green", "=", {green}),
      flagOp("--blue", "=", {blue}),
      flagOp("--warm", "=", warmColors),
    ],
    default = {},
    help = "Select colors"
  )
)
```

`--red`/`--green`/`--blue` each set a single element; `--warm` sets *two*
at once, `{red, green}` — since a `flagOp`'s `value` is always a real,
already-typed `T`, there's no string-spelling limitation to work around:
any value expressible in Nim, however it's built, can be passed directly.

### Clamping Flag Values

A flag's `clamp` param (`argumint/flagclamp`) silently adjusts its value after
every Flag Operation. Unlike a `Validator` (see above), which raises
`ValidationError` when a value doesn't qualify, `clamp` never raises — it just
corrects the value instead:

- `clamp(bounds: Slice[T])` pins the value to `bounds`, e.g. `clamp(0..10)`
- `adjust(fn: T -> T)` runs an arbitrary function instead, for a `T` with no
  natural ordering (e.g. `set[E]`)

```nim
import std/os

defineSetFlag(FilePermission)

let spec = (
  verbosity: flag[int](
    "-v, --verbose",
    ops = [
      flagOp("--quiet", "=", 0),
      flagOp("--boost", "+=", 5),
      flagOp("--dampen", "-=", 2),
    ],
    default = 0, clamp = clamp(0..10)
  ),
  permissions: flag[set[FilePermission]](
    ops = [
      flagOp("-r", "+=", {fpUserRead}),
      flagOp("-w", "+=", {fpUserWrite}),
      flagOp("-x", "+=", {fpUserExec}),
    ],
    default = {},
    clamp = adjust(proc (v: set[FilePermission]): set[FilePermission] =
      (if fpUserWrite in v: v + {fpUserRead} else: v))
  )
)
```

- Repeating `-v`/`--boost` past 10 (or `--dampen` below 0) silently keeps
  `verbosity`'s value pinned at the bound instead of over/underflowing.
- `permissions`'s set type has no natural ordering, so `adjust` is used instead:
  a write-only file is rarely what anyone actually wants, so whenever `-w` is
  granted without `-r`, `adjust` silently adds read access too rather than
  leaving a write-only permission set.

Note: `default` must already satisfy `clamp`/`adjust`, or spec construction
raises `SpecDefect` — see `examples/verbosity.nim` for the full runnable demo of
`clamp`.
